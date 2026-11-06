import Foundation

extension Notification.Name {
    /// 账号已删除且本地已清空；界面收到后重建各页，避免旧对象残留已删除数据。
    static let accountDeleted = Notification.Name("codemagic.account.deleted")
}

/// 服务端删除结果。404（同一令牌重放）也意味着账号已不存在，按已删除处理。
enum AccountDeletionOutcome: Equatable {
    case deleted
    case alreadyDeleted
}

/// 注销账号错误。401、家庭阻塞、令牌失效与网络错误语义不同，界面必须分别提示，不得静默。
enum AccountDeletionError: Error, Equatable, LocalizedError {
    case unauthorized
    case blocked
    case tokenInvalid
    case tokenExpired
    case network(AppError)
    case api(AppError)
    case localCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return L10n.t("account.delete.sessionExpired")
        case .blocked:
            return L10n.t("account.delete.blocked")
        case .tokenInvalid:
            return L10n.t("account.delete.tokenInvalid")
        case .tokenExpired:
            return L10n.t("account.delete.tokenExpired")
        case .network(let error):
            return L10n.f("account.delete.failed", String(describing: error.code), String(describing: error.message))
        case .api(let error):
            return L10n.f("account.delete.failed", String(describing: error.code), String(describing: error.message))
        case .localCleanupFailed(let detail):
            return L10n.f("account.delete.localCleanupFailed", String(describing: detail))
        }
    }

    /// 需要重新申请删除令牌（403 / 410）。
    var requiresReapply: Bool {
        switch self {
        case .tokenInvalid, .tokenExpired:
            return true
        default:
            return false
        }
    }

    /// owner 家庭仍有其他成员（409）。
    var needsHouseholdAction: Bool {
        switch self {
        case .blocked:
            return true
        default:
            return false
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network:
            return true
        case .api(let error):
            switch error {
            case .network, .server:
                return true
            default:
                return false
            }
        case .unauthorized, .blocked, .tokenInvalid, .tokenExpired, .localCleanupFailed:
            return false
        }
    }
}

/// 两步注销：先申请 10 分钟删除令牌（`POST /me/deletion-request`），
/// 二次确认后带 `X-Deletion-Token` 提交 `DELETE /me`（刻意不带 Bearer）。
///
/// 服务端成功或返回 404（令牌重放，账号已不存在）后才清空本地：
/// 断开蓝牙 → Keychain → 全部业务表（含目录缓存与反馈草稿）→ 同步元数据 → URL 缓存 → 导出临时文件。
/// 其它失败不做任何本地清理，保留用户可重试的完整状态。
final class AccountDeletionService {
    private let api: AccountAPIServicing
    private let tokenStore: TokenStoring
    private let database: SQLiteDatabase
    private let metadataStore: SyncMetadataStore
    private let clearURLCache: () -> Void
    private let disconnectBluetooth: () -> Void
    private let additionalCleanup: () -> Void

    init(
        api: AccountAPIServicing,
        tokenStore: TokenStoring,
        database: SQLiteDatabase,
        metadataStore: SyncMetadataStore,
        clearURLCache: @escaping () -> Void = { URLCache.shared.removeAllCachedResponses() },
        disconnectBluetooth: @escaping () -> Void = {},
        additionalCleanup: @escaping () -> Void = {}
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.database = database
        self.metadataStore = metadataStore
        self.clearURLCache = clearURLCache
        self.disconnectBluetooth = disconnectBluetooth
        self.additionalCleanup = additionalCleanup
    }

    func requestDeletionToken(
        completion: @escaping (Result<DeletionChallenge, AccountDeletionError>) -> Void
    ) {
        guard let token = tokenStore.load()?.token, !token.isEmpty else {
            deliver(.failure(.unauthorized), completion)
            return
        }
        api.createDeletionRequest(token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let challenge):
                self.deliver(.success(challenge), completion)
            case .failure(.unauthorized):
                self.deliver(.failure(.unauthorized), completion)
            case .failure(.rateLimited(let seconds)):
                self.deliver(.failure(.api(Self.rateLimitError(seconds: seconds))), completion)
            case .failure(.failure(let error)):
                if case .network = error {
                    self.deliver(.failure(.network(error)), completion)
                } else {
                    self.deliver(.failure(.api(error)), completion)
                }
            case .failure(.decoding(let detail)):
                self.deliver(.failure(.api(.decoding(detail))), completion)
            default:
                self.deliver(.failure(.api(.server(statusCode: 500))), completion)
            }
        }
    }

    func confirmDeletion(
        _ challenge: DeletionChallenge,
        completion: @escaping (Result<AccountDeletionOutcome, AccountDeletionError>) -> Void
    ) {
        api.deleteAccount(deletionToken: challenge.token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.finish(.deleted, completion: completion)
            case .failure(.accountDeleted):
                // 404：同一令牌重放，服务端账号已不存在；本地同样必须清空，避免重启复活。
                self.finish(.alreadyDeleted, completion: completion)
            case .failure(.deletionBlocked):
                self.deliver(.failure(.blocked), completion)
            case .failure(.deletionTokenInvalid):
                self.deliver(.failure(.tokenInvalid), completion)
            case .failure(.deletionTokenExpired):
                self.deliver(.failure(.tokenExpired), completion)
            case .failure(.unauthorized):
                self.deliver(.failure(.unauthorized), completion)
            case .failure(.rateLimited(let seconds)):
                self.deliver(.failure(.api(Self.rateLimitError(seconds: seconds))), completion)
            case .failure(.failure(let error)):
                if case .network = error {
                    self.deliver(.failure(.network(error)), completion)
                } else {
                    self.deliver(.failure(.api(error)), completion)
                }
            case .failure(.decoding(let detail)):
                self.deliver(.failure(.api(.decoding(detail))), completion)
            default:
                self.deliver(.failure(.api(.server(statusCode: 500))), completion)
            }
        }
    }

    // MARK: - Private

    private func finish(
        _ outcome: AccountDeletionOutcome,
        completion: @escaping (Result<AccountDeletionOutcome, AccountDeletionError>) -> Void
    ) {
        // 先断开连接，避免清理后仍有读数继续写入业务表。
        disconnectBluetooth()
        tokenStore.clear()

        var cleanupFailures: [String] = []
        do {
            try database.resetBusinessData()
        } catch {
            cleanupFailures.append(L10n.f(
                "account.delete.cleanupFailed",
                String(describing: error.localizedDescription)
            ))
        }
        metadataStore.resetForAccountDeletion()
        clearURLCache()
        additionalCleanup()

        if let failure = cleanupFailures.first {
            deliver(.failure(.localCleanupFailed(failure)), completion)
        } else {
            deliver(.success(outcome), completion)
        }
    }

    private func deliver<T>(
        _ result: Result<T, AccountDeletionError>,
        _ completion: @escaping (Result<T, AccountDeletionError>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private static func rateLimitError(seconds: Int?) -> AppError {
        let detail = seconds.map {
            L10n.f("account.retryInSeconds", String(describing: $0))
        } ?? L10n.t("account.retryLater")
        return .api(
            code: "NET-002",
            statusCode: 429,
            message: L10n.f("account.rateLimitedDetail", String(describing: detail))
        )
    }
}
