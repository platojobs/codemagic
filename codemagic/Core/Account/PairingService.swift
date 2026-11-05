import Foundation

/// 接管结果：新账号与本机重新标记待上传的数据量。
struct PairingClaimResult: Equatable {
    let userID: String
    let deviceCount: Int
    let readingCount: Int
}

/// 配对流程错误：格式、接口与本地写入三类。
enum PairingError: Error, Equatable {
    case invalidFormat
    case api(AccountAPIError)
    case local(String)

    var userMessage: String {
        switch self {
        case .invalidFormat:
            return "请输入 8 位接管码（仅字母与数字，已自动过滤易混字符）。"
        case .api(let error):
            return error.userMessage
        case .local(let message):
            return message
        }
    }

    var isRetryable: Bool {
        switch self {
        case .api(let error): return error.isRetryable
        case .invalidFormat, .local: return false
        }
    }
}

protocol PairingServicing {
    func createCode(completion: @escaping (Result<PairingCode, PairingError>) -> Void)
    func claim(
        code: String,
        completion: @escaping (Result<PairingClaimResult, PairingError>) -> Void
    )
}

/// 跨设备接管：生成一次性配对码；用码换同一 `userId` 的新 token，并把本机设备与读数全部重新标记待上传。
///
/// 接管成功后保留本地数据，仅替换 Keychain token 与同步归属；旧账号云端数据不会自动合并。
final class PairingService: PairingServicing {
    private let api: AccountAPIServicing
    private let tokenStore: TokenStoring
    private let deviceStore: SavedDeviceStore
    private let readingsStore: ReadingsStore
    private let metadataStore: SyncMetadataStore
    private let logStore: ScanLogStore

    init(
        api: AccountAPIServicing,
        tokenStore: TokenStoring,
        deviceStore: SavedDeviceStore,
        readingsStore: ReadingsStore,
        metadataStore: SyncMetadataStore,
        logStore: ScanLogStore
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.deviceStore = deviceStore
        self.readingsStore = readingsStore
        self.metadataStore = metadataStore
        self.logStore = logStore
    }

    func createCode(completion: @escaping (Result<PairingCode, PairingError>) -> Void) {
        guard let token = tokenStore.load()?.token, !token.isEmpty else {
            completion(.failure(.api(.unauthorized)))
            return
        }
        api.createPairingCode(token: token) { result in
            completion(result.mapError { .api($0) })
        }
    }

    func claim(
        code: String,
        completion: @escaping (Result<PairingClaimResult, PairingError>) -> Void
    ) {
        let normalized = PairingCodeFormatter.normalize(code)
        guard PairingCodeFormatter.isComplete(normalized) else {
            completion(.failure(.invalidFormat))
            return
        }

        api.claimPairingCode(normalized) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(.api(error)))

            case .success(let session):
                do {
                    try self.tokenStore.save(session)
                } catch {
                    completion(.failure(.local("配对成功，但 token 写入 Keychain 失败：\(error.localizedDescription)")))
                    return
                }

                // 换号后游标必须归零：旧账号的游标对新账号没有意义。
                self.metadataStore.userID = session.userID
                self.metadataStore.resetCursor()
                self.metadataStore.sessionExpiresAt = session.expiresAt
                self.metadataStore.reloginRequired = false

                do {
                    let deviceCount = try self.deviceStore.markAllPendingForRelogin()
                    let readingCount = try self.readingsStore.markAllPending()
                    self.recordLog(
                        "从旧设备接管成功：本机 \(deviceCount) 台设备、\(readingCount) 条读数已标记待同步（账号 \(session.userID)）"
                    )
                    let claimResult = PairingClaimResult(
                        userID: session.userID,
                        deviceCount: deviceCount,
                        readingCount: readingCount
                    )
                    DispatchQueue.main.async { completion(.success(claimResult)) }
                } catch {
                    completion(.failure(.local("接管成功，但本地待同步标记失败：\(error.localizedDescription)")))
                }
            }
        }
    }

    private func recordLog(_ message: String) {
        try? logStore.append(ScanLogEntry(category: .sync, level: .info, message: message))
    }
}

private extension Result where Failure == AccountAPIError {
    func mapError(_ transform: (AccountAPIError) -> PairingError) -> Result<Success, PairingError> {
        switch self {
        case .success(let value): return .success(value)
        case .failure(let error): return .failure(transform(error))
        }
    }
}
