import Foundation

/// 注销账号错误。401 与网络错误语义不同，界面必须分别提示，不得静默。
enum AccountDeletionError: Error, Equatable, LocalizedError {
    case unauthorized
    case network(AppError)
    case api(AppError)
    case localCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return L10n.t("account.delete.sessionExpired")
        case .network(let error):
            return L10n.f("account.delete.failed", String(describing: error.code), String(describing: error.message))
        case .api(let error):
            return L10n.f("account.delete.failedLocal", String(describing: error.code), String(describing: error.message))
        case .localCleanupFailed(let detail):
            return L10n.f("account.delete.localCleanupFailed", String(describing: detail))
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
        case .unauthorized, .localCleanupFailed:
            return false
        }
    }
}

/// 注销账号：先服务端 `DELETE /api/v1/me`，成功后再按 token → SQLite 业务表 → 同步元数据的顺序清理本地。
///
/// 服务端失败（401 / 网络 / 其他）时**不做任何本地清理**，保证用户重试时数据仍完整。
final class AccountDeletionService {
    private let api: AccountAPIServicing
    private let tokenStore: TokenStoring
    private let database: SQLiteDatabase
    private let metadataStore: SyncMetadataStore

    init(
        api: AccountAPIServicing,
        tokenStore: TokenStoring,
        database: SQLiteDatabase,
        metadataStore: SyncMetadataStore
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.database = database
        self.metadataStore = metadataStore
    }

    func deleteAccount(completion: @escaping (Result<Void, AccountDeletionError>) -> Void) {
        guard let token = tokenStore.load()?.token, !token.isEmpty else {
            completion(.failure(.unauthorized))
            return
        }

        api.deleteAccount(token: token) { [weak self] result in
            guard let self else { return }
            let finish: (Result<Void, AccountDeletionError>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }

            switch result {
            case .failure(.unauthorized):
                finish(.failure(.unauthorized))
            case .failure(.rateLimited(let seconds)):
                let detail = seconds.map { L10n.f("account.retryInSeconds", String(describing: $0)) } ?? L10n.t("account.retryLater")
                finish(.failure(.api(.api(
                    code: "NET-002",
                    statusCode: 429,
                    message: L10n.f("account.rateLimitedDetail", String(describing: detail))
                ))))
            case .failure(.invalidCode):
                finish(.failure(.api(.api(
                    code: "NET-002",
                    statusCode: 404,
                    message: L10n.t("account.delete.unsupported")
                ))))
            case .failure(.decoding(let detail)):
                finish(.failure(.api(.decoding(detail))))
            case .failure(.failure(let appError)):
                if case .network = appError {
                    finish(.failure(.network(appError)))
                } else {
                    finish(.failure(.api(appError)))
                }
            case .success:
                // 顺序：Keychain → 业务表 → 同步元数据。任何一步失败都明确上报，不假装成功。
                self.tokenStore.clear()
                do {
                    try self.database.resetBusinessData()
                } catch {
                    finish(.failure(.localCleanupFailed(L10n.f("account.delete.cleanupFailed", String(describing: error.localizedDescription)))))
                    return
                }
                self.metadataStore.resetForAccountDeletion()
                finish(.success(()))
            }
        }
    }
}
