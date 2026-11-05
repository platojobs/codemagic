import Foundation

/// 账号导出失败原因；文案直接用于界面提示与重试判断。
enum AccountExportError: Error, Equatable, LocalizedError {
    case unauthorized
    case network(AppError)
    case decoding(String)
    case invalidCursor
    case noData
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "登录已失效，请先重新登录后再导出。"
        case .network(let error):
            return "\(error.code) \(error.message)，请检查网络后重试。"
        case .decoding(let detail):
            return "导出响应无法解析：\(detail)"
        case .invalidCursor:
            return "服务端返回的分页游标异常，请重试。"
        case .noData:
            return "账号暂无可导出的数据。"
        case .writeFailed(let detail):
            return "写入导出文件失败：\(detail)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network, .invalidCursor, .writeFailed: return true
        default: return false
        }
    }
}

/// 账号数据导出：`GET /api/v1/me/export` 按 `hasMore` / `nextCursor` 循环拉全。
///
/// - `cursor` 对客户端不透明，只原样回传，不解析、不构造；
/// - 合并每一页 `readings`，`user` / `devices` / `exportedAt` 取第一页；
/// - 写入临时 JSON 后用 `UIActivityViewController` 分享，分享结束删除文件；
/// - 进度回调传递真实已读取读数条数，始终在主线程。
final class AccountExportService {
    static let pageLimit = 5000
    static let maxPages = 1000

    private let api: AccountAPIServicing
    private let tokenStore: TokenStoring
    private let fileManager: FileManager
    private let directoryURL: URL
    private let pageLimit: Int

    init(
        api: AccountAPIServicing,
        tokenStore: TokenStoring,
        pageLimit: Int = AccountExportService.pageLimit,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.pageLimit = pageLimit
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("codemagic-account-export", isDirectory: true)
    }

    func export(
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, AccountExportError>) -> Void
    ) {
        guard let token = tokenStore.load()?.token, !token.isEmpty else {
            completion(.failure(.unauthorized))
            return
        }
        cleanupStaleFiles()
        fetchPage(
            cursor: nil,
            token: token,
            accumulator: Accumulator(),
            seenCursors: [],
            page: 0,
            progress: progress,
            completion: completion
        )
    }

    /// 分享结束后删除临时文件，避免长期占用空间。
    func removeExportedFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Paging

    private struct Accumulator {
        var user: [String: Any]?
        var devices: [[String: Any]]?
        var exportedAt: Any?
        var readings: [[String: Any]] = []
        var total: Int { readings.count }
    }

    private func fetchPage(
        cursor: String?,
        token: String,
        accumulator: Accumulator,
        seenCursors: Set<String>,
        page: Int,
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, AccountExportError>) -> Void
    ) {
        guard page < Self.maxPages else {
            completion(.failure(.invalidCursor))
            return
        }

        api.fetchExportPage(cursor: cursor, limit: pageLimit, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                switch error {
                case .unauthorized:
                    self.deliver(.failure(.unauthorized), completion)
                default:
                    self.deliver(.failure(.network(.network(error.userMessage))), completion)
                }

            case .success(let data):
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    self.deliver(.failure(.decoding("响应不是 JSON 对象")), completion)
                    return
                }

                var accumulator = accumulator
                let readings = (object["readings"] as? [[String: Any]]) ?? []
                accumulator.readings.append(contentsOf: readings)
                if page == 0 {
                    accumulator.user = object["user"] as? [String: Any]
                    accumulator.devices = object["devices"] as? [[String: Any]]
                    accumulator.exportedAt = object["exportedAt"]
                }
                self.deliverProgress(accumulator.total, progress)

                let hasMore = (object["hasMore"] as? Bool) ?? false
                let nextCursor = (object["nextCursor"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if hasMore {
                    // 游标必须非空且未见过，否则视为异常，避免无限翻页或死循环。
                    guard !nextCursor.isEmpty, !seenCursors.contains(nextCursor) else {
                        self.deliver(.failure(.invalidCursor), completion)
                        return
                    }
                    var nextSeen = seenCursors
                    nextSeen.insert(nextCursor)
                    self.fetchPage(
                        cursor: nextCursor,
                        token: token,
                        accumulator: accumulator,
                        seenCursors: nextSeen,
                        page: page + 1,
                        progress: progress,
                        completion: completion
                    )
                    return
                }

                guard accumulator.total > 0 || !(accumulator.devices ?? []).isEmpty else {
                    self.deliver(.failure(.noData), completion)
                    return
                }
                self.writeFile(accumulator, completion: completion)
            }
        }
    }

    // MARK: - File

    private func writeFile(
        _ accumulator: Accumulator,
        completion: @escaping (Result<URL, AccountExportError>) -> Void
    ) {
        var payload: [String: Any] = ["readings": accumulator.readings]
        if let user = accumulator.user { payload["user"] = user }
        if let devices = accumulator.devices { payload["devices"] = devices }
        if let exportedAt = accumulator.exportedAt { payload["exportedAt"] = exportedAt }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            let userID = (accumulator.user?["id"] as? String) ?? "account"
            let stamp = Int(Date().timeIntervalSince1970)
            let filename = "account-export-\(userID)-\(stamp)-\(UUID().uuidString.prefix(8)).json"
            let url = directoryURL.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            deliver(.success(url), completion)
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

    // MARK: - Delivery

    private func deliver(
        _ result: Result<URL, AccountExportError>,
        _ completion: @escaping (Result<URL, AccountExportError>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private func deliverProgress(_ count: Int, _ progress: @escaping (Int) -> Void) {
        DispatchQueue.main.async { progress(count) }
    }
}
