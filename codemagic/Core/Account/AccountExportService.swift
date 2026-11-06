import Foundation

/// 导出进度，界面据此更新「处理中」提示，不会把用户踢出当前页。
enum AccountExportPhase: Equatable {
    case creating
    case pending(attempt: Int)
    case downloading
    case refreshingDownload
}

/// 导出成功结果；`refreshedDownloadToken` 表示下载链接曾过期并被自动重新签发过。
struct AccountExportResult: Equatable {
    let fileURL: URL
    let refreshedDownloadToken: Bool
}

/// 账号导出失败原因；文案直接用于界面提示与重试判断。
enum AccountExportError: Error, Equatable, LocalizedError {
    case unauthorized
    case network(AppError)
    case api(AppError)
    case decoding(String)
    case taskFailed(reason: String?)
    case taskNotFound
    case timeout
    case downloadInvalid
    case downloadExpired
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return L10n.t("account.export.sessionExpired")
        case .network(let error):
            return L10n.f("account.export.failed", String(describing: error.code), String(describing: error.message))
        case .api(let error):
            return L10n.f("account.export.failed", String(describing: error.code), String(describing: error.message))
        case .decoding(let detail):
            return L10n.f("account.export.parseFailed", String(describing: detail))
        case .taskFailed(let reason):
            // 优先展示服务端原因（例如「导出任务因服务重启中断，请重新发起导出」）。
            if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                return reason
            }
            return L10n.t("account.export.taskFailed")
        case .taskNotFound:
            return L10n.t("account.export.taskNotFound")
        case .timeout:
            return L10n.t("account.export.timeout")
        case .downloadInvalid:
            return L10n.t("account.export.downloadInvalid")
        case .downloadExpired:
            return L10n.t("account.export.downloadExpired")
        case .writeFailed(let detail):
            return L10n.f("account.export.writeFailed", String(describing: detail))
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network, .taskFailed, .taskNotFound, .timeout, .downloadInvalid, .downloadExpired, .writeFailed:
            return true
        case .api(let error):
            switch error {
            case .network, .server:
                return true
            default:
                return false
            }
        case .unauthorized, .decoding:
            return false
        }
    }
}

/// 账号数据导出（`POST /me/export` + 轮询 `GET /me/export/{id}` + 一次性下载链接）。
///
/// - 创建后按 2.5 秒起步、1.4 倍增长、封顶 5 秒轮询，避免每秒打接口；
/// - `ready` 时服务端每次查询都会签发新的下载令牌，客户端只使用最新 `downloadUrl`；
/// - 下载遇 410 自动重新查询一次拿新链接后重试，并在结果中标记，界面据此提示；
/// - 文件写入临时目录，分享结束或账号删除时清理。
final class AccountExportService {
    typealias PollScheduler = (TimeInterval, @escaping () -> Void) -> Void

    private let api: AccountAPIServicing
    private let tokenStore: TokenStoring
    private let fileManager: FileManager
    private let directoryURL: URL
    private let pollInterval: TimeInterval
    private let maxPollInterval: TimeInterval
    private let maxPollAttempts: Int
    private let scheduler: PollScheduler
    private var generation = 0

    init(
        api: AccountAPIServicing,
        tokenStore: TokenStoring,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        pollInterval: TimeInterval = 2.5,
        maxPollInterval: TimeInterval = 5,
        maxPollAttempts: Int = 60,
        scheduler: PollScheduler? = nil
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("codemagic-account-export", isDirectory: true)
        self.pollInterval = pollInterval
        self.maxPollInterval = maxPollInterval
        self.maxPollAttempts = maxPollAttempts
        self.scheduler = scheduler ?? { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        }
    }

    func export(
        progress: @escaping (AccountExportPhase) -> Void,
        completion: @escaping (Result<AccountExportResult, AccountExportError>) -> Void
    ) {
        guard let token = tokenStore.load()?.token, !token.isEmpty else {
            deliver(.failure(.unauthorized), completion)
            return
        }
        generation += 1
        let generation = self.generation
        cleanupStaleFiles()
        deliverProgress(.creating, progress)

        api.createExport(token: token) { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case .success(let task):
                switch task.status {
                case .failed:
                    self.deliver(.failure(.taskFailed(reason: task.failureReason)), completion)
                case .ready:
                    guard let url = task.downloadURL else {
                        self.deliver(.failure(.decoding(L10n.t("account.export.missingDownloadUrl"))), completion)
                        return
                    }
                    self.download(
                        taskID: task.id,
                        url: url,
                        token: token,
                        refreshed: false,
                        generation: generation,
                        progress: progress,
                        completion: completion
                    )
                case .pending:
                    self.schedulePoll(
                        taskID: task.id,
                        token: token,
                        attempt: 1,
                        generation: generation,
                        progress: progress,
                        completion: completion
                    )
                }
            case .failure(let error):
                self.deliver(.failure(Self.map(error)), completion)
            }
        }
    }

    /// 取消轮询；后续回调不再触发。
    func cancel() {
        generation += 1
    }

    /// 分享结束后删除临时文件，避免长期占用空间。
    func removeExportedFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// 账号删除时清空全部导出临时文件。
    func removeAllExportedFiles() {
        try? fileManager.removeItem(at: directoryURL)
    }

    // MARK: - Polling

    private func schedulePoll(
        taskID: String,
        token: String,
        attempt: Int,
        generation: Int,
        progress: @escaping (AccountExportPhase) -> Void,
        completion: @escaping (Result<AccountExportResult, AccountExportError>) -> Void
    ) {
        guard attempt < maxPollAttempts else {
            deliver(.failure(.timeout), completion)
            return
        }
        let delay = pollDelay(for: attempt)
        deliverProgress(.pending(attempt: attempt), progress)
        scheduler(delay) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.fetchStatus(
                taskID: taskID,
                token: token,
                attempt: attempt + 1,
                generation: generation,
                progress: progress,
                completion: completion
            )
        }
    }

    private func fetchStatus(
        taskID: String,
        token: String,
        attempt: Int,
        generation: Int,
        progress: @escaping (AccountExportPhase) -> Void,
        completion: @escaping (Result<AccountExportResult, AccountExportError>) -> Void
    ) {
        api.fetchExport(id: taskID, token: token) { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case .success(let task):
                switch task.status {
                case .pending:
                    self.schedulePoll(
                        taskID: taskID,
                        token: token,
                        attempt: attempt,
                        generation: generation,
                        progress: progress,
                        completion: completion
                    )
                case .failed:
                    self.deliver(.failure(.taskFailed(reason: task.failureReason)), completion)
                case .ready:
                    guard let url = task.downloadURL else {
                        self.deliver(.failure(.decoding(L10n.t("account.export.missingDownloadUrl"))), completion)
                        return
                    }
                    self.download(
                        taskID: taskID,
                        url: url,
                        token: token,
                        refreshed: false,
                        generation: generation,
                        progress: progress,
                        completion: completion
                    )
                }
            case .failure(.exportNotReady):
                self.schedulePoll(
                    taskID: taskID,
                    token: token,
                    attempt: attempt,
                    generation: generation,
                    progress: progress,
                    completion: completion
                )
            case .failure(.exportNotFound):
                self.deliver(.failure(.taskNotFound), completion)
            case .failure(let error):
                self.deliver(.failure(Self.map(error)), completion)
            }
        }
    }

    private func pollDelay(for attempt: Int) -> TimeInterval {
        let exponential = pollInterval * pow(1.4, Double(max(0, attempt - 1)))
        return min(maxPollInterval, exponential)
    }

    // MARK: - Download

    private func download(
        taskID: String,
        url: URL,
        token: String,
        refreshed: Bool,
        generation: Int,
        progress: @escaping (AccountExportPhase) -> Void,
        completion: @escaping (Result<AccountExportResult, AccountExportError>) -> Void
    ) {
        if !refreshed {
            deliverProgress(.downloading, progress)
        }
        api.downloadExport(url: url) { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case .success(let data):
                self.writeFile(taskID: taskID, data: data, refreshed: refreshed, completion: completion)
            case .failure(.downloadExpired):
                guard !refreshed else {
                    self.deliver(.failure(.downloadExpired), completion)
                    return
                }
                // 410：链接已过期或被使用。重新查询任务拿新的一次性令牌，只重试一次。
                self.deliverProgress(.refreshingDownload, progress)
                self.refreshDownloadURL(
                    taskID: taskID,
                    token: token,
                    generation: generation,
                    progress: progress,
                    completion: completion
                )
            case .failure(.downloadInvalid):
                self.deliver(.failure(.downloadInvalid), completion)
            case .failure(.exportNotFound):
                self.deliver(.failure(.taskNotFound), completion)
            case .failure(let error):
                self.deliver(.failure(Self.map(error)), completion)
            }
        }
    }

    private func refreshDownloadURL(
        taskID: String,
        token: String,
        generation: Int,
        progress: @escaping (AccountExportPhase) -> Void,
        completion: @escaping (Result<AccountExportResult, AccountExportError>) -> Void
    ) {
        api.fetchExport(id: taskID, token: token) { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case .success(let task):
                guard task.status == .ready, let url = task.downloadURL else {
                    self.deliver(.failure(.downloadExpired), completion)
                    return
                }
                self.download(
                    taskID: taskID,
                    url: url,
                    token: token,
                    refreshed: true,
                    generation: generation,
                    progress: progress,
                    completion: completion
                )
            case .failure(.exportNotFound):
                self.deliver(.failure(.taskNotFound), completion)
            case .failure(let error):
                self.deliver(.failure(Self.map(error)), completion)
            }
        }
    }

    // MARK: - File

    private func writeFile(
        taskID: String,
        data: Data,
        refreshed: Bool,
        completion: @escaping (Result<AccountExportResult, AccountExportError>) -> Void
    ) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let filename = "account-export-\(taskID)-\(UUID().uuidString.prefix(8)).json"
            let url = directoryURL.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            deliver(.success(AccountExportResult(fileURL: url, refreshedDownloadToken: refreshed)), completion)
        } catch {
            deliver(.failure(.writeFailed(error.localizedDescription)), completion)
        }
    }

    /// 临时目录只保留 1 天内的文件，异常退出后自动回收。
    private func cleanupStaleFiles() {
        let cutoff = Date().addingTimeInterval(-86_400)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    // MARK: - Mapping & delivery

    private static func map(_ error: AccountAPIError) -> AccountExportError {
        switch error {
        case .unauthorized:
            return .unauthorized
        case .failure(let appError):
            if case .network = appError {
                return .network(appError)
            }
            return .api(appError)
        case .decoding(let detail):
            return .decoding(detail)
        case .exportNotFound:
            return .taskNotFound
        case .downloadInvalid:
            return .downloadInvalid
        case .downloadExpired:
            return .downloadExpired
        case .rateLimited(let seconds):
            let message = seconds.map {
                L10n.f("account.retryInSeconds", String(describing: $0))
            } ?? L10n.t("account.retryLater")
            return .api(.api(code: "NET-002", statusCode: 429, message: message))
        case .deletionBlocked, .deletionTokenInvalid, .deletionTokenExpired, .accountDeleted, .exportNotReady, .invalidCode:
            return .decoding(L10n.t("account.responseMismatch"))
        }
    }

    private func deliver(
        _ result: Result<AccountExportResult, AccountExportError>,
        _ completion: @escaping (Result<AccountExportResult, AccountExportError>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private func deliverProgress(
        _ phase: AccountExportPhase,
        _ progress: @escaping (AccountExportPhase) -> Void
    ) {
        DispatchQueue.main.async { progress(phase) }
    }
}
