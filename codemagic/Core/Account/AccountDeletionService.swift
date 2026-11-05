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
            return "登录已失效，服务端未删除账号；本地数据已保留，请重新登录后重试。"
        case .network(let error):
            return "\(error.code) \(error.message)。账号未删除，本地数据已保留，请检查网络后重试。"
        case .api(let error):
            return "\(error.code) \(error.message)。账号未删除，本地数据已保留。"
        case .localCleanupFailed(let detail):
            return "账号已在服务端删除，但本地清理失败：\(detail)"
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
                let detail = seconds.map { "请 \($0) 秒后再试" } ?? "请稍后再试"
                finish(.failure(.api(.api(
                    code: "NET-002",
                    statusCode: 429,
                    message: "尝试过于频繁，\(detail)"
                ))))
            case .failure(.invalidCode):
                finish(.failure(.api(.api(
                    code: "NET-002",
                    statusCode: 404,
                    message: "服务端未找到账号注销接口"
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
                    finish(.failure(.localCleanupFailed("业务表清理失败（\(error.localizedDescription)）")))
                    return
                }
                self.metadataStore.resetForAccountDeletion()
                finish(.success(()))
            }
        }
    }
}
