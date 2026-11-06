import Foundation

/// 配对码响应；`expiresAt` 为服务端真实过期时间（UTC）。
struct PairingCode: Equatable {
    let code: String
    let expiresAt: Date
}

/// `POST /me/deletion-request` 返回的删除二次确认令牌（10 分钟有效）。
struct DeletionChallenge: Equatable {
    let token: String
    let expiresAt: Date

    func isExpired(now: Date = Date()) -> Bool {
        expiresAt <= now
    }
}

/// `POST /me/export` 创建的异步导出任务；`ready` 时 `downloadURL` 由服务端签发一次性令牌。
struct AccountExportTask: Equatable {
    enum Status: String, Equatable {
        case pending
        case ready
        case failed
    }

    let id: String
    let status: Status
    let createdAt: Date
    let completedAt: Date?
    let downloadURL: URL?
    let downloadExpiresAt: Date?
    let expiresAt: Date
}

/// 账号相关接口错误。404 统一为「码无效或已过期」，429 携带服务端 `Retry-After` 秒数。
enum AccountAPIError: Error, Equatable {
    case invalidCode
    case unauthorized
    case rateLimited(retryAfterSeconds: Int?)
    case deletionBlocked
    case deletionTokenInvalid
    case deletionTokenExpired
    case accountDeleted
    case exportNotFound
    case exportNotReady
    case downloadInvalid
    case downloadExpired
    case failure(AppError)
    case decoding(String)

    var userMessage: String {
        switch self {
        case .invalidCode:
            return L10n.t("account.transfer.invalid")
        case .unauthorized:
            return L10n.t("account.auth.expired")
        case .rateLimited(let seconds):
            if let seconds {
                return L10n.f("account.rateLimitedSeconds", String(describing: seconds))
            }
            return L10n.t("account.rateLimited")
        case .deletionBlocked:
            return L10n.t("account.delete.blocked")
        case .deletionTokenInvalid:
            return L10n.t("account.delete.tokenInvalid")
        case .deletionTokenExpired:
            return L10n.t("account.delete.tokenExpired")
        case .accountDeleted:
            return L10n.t("account.delete.alreadyDeleted")
        case .exportNotFound:
            return L10n.t("account.export.taskNotFound")
        case .exportNotReady:
            return L10n.t("account.export.notReady")
        case .downloadInvalid:
            return L10n.t("account.export.downloadInvalid")
        case .downloadExpired:
            return L10n.t("account.export.downloadExpired")
        case .failure(let error):
            return "\(error.code) \(error.message)"
        case .decoding:
            return L10n.t("account.responseMismatch")
        }
    }

    /// 网络错误可安全重试；401 与 404 重试无意义。
    var isRetryable: Bool {
        switch self {
        case .failure(.network), .failure(.server), .rateLimited:
            return true
        default:
            return false
        }
    }
}

/// 账号接口协议：配对码、删除令牌、异步数据导出与注销。
protocol AccountAPIServicing {
    func createPairingCode(token: String, completion: @escaping (Result<PairingCode, AccountAPIError>) -> Void)
    func claimPairingCode(_ code: String, completion: @escaping (Result<AnonymousSession, AccountAPIError>) -> Void)
    func createDeletionRequest(
        token: String,
        completion: @escaping (Result<DeletionChallenge, AccountAPIError>) -> Void
    )
    func deleteAccount(
        deletionToken: String,
        completion: @escaping (Result<Void, AccountAPIError>) -> Void
    )
    func createExport(
        token: String,
        completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void
    )
    func fetchExport(
        id: String,
        token: String,
        completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void
    )
    func downloadExport(
        url: URL,
        completion: @escaping (Result<Data, AccountAPIError>) -> Void
    )
}

/// `PJGoIoT/api/openapi.yaml` 0.15.0 账号端点的客户端实现。
final class AccountAPIClient: AccountAPIServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let decoder = JSONDecoder()

    init(configuration: APIConfiguration, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    // MARK: - Pairing

    func createPairingCode(
        token: String,
        completion: @escaping (Result<PairingCode, AccountAPIError>) -> Void
    ) {
        let request = HTTPRequest(
            url: endpoint("api/v1/auth/pairing-code"),
            method: "POST",
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.failure(error)), completion)
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.accountError(response)), completion)
                    return
                }
                do {
                    let payload = try self.decoder.decode(PairingCodePayload.self, from: response.data)
                    guard payload.code.count == PairingCodeFormatter.codeLength,
                          let expiresAt = SyncDateCodec.parse(payload.expiresAt)
                    else {
                        self.deliver(.failure(.decoding(L10n.t("account.pairing.missingCode"))), completion)
                        return
                    }
                    self.deliver(
                        .success(PairingCode(code: payload.code.uppercased(), expiresAt: expiresAt)),
                        completion
                    )
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func claimPairingCode(
        _ code: String,
        completion: @escaping (Result<AnonymousSession, AccountAPIError>) -> Void
    ) {
        let body: Data
        do {
            body = try JSONEncoder().encode(ClaimRequest(code: code))
        } catch {
            deliver(.failure(.decoding(L10n.t("account.pairing.encodeFailed"))), completion)
            return
        }
        let request = HTTPRequest(
            url: endpoint("api/v1/auth/pairing-code/claim"),
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.failure(error)), completion)
            case .success(let response):
                if response.statusCode == 404 {
                    self.deliver(.failure(.invalidCode), completion)
                    return
                }
                guard response.isSuccess else {
                    self.deliver(.failure(self.accountError(response)), completion)
                    return
                }
                do {
                    let payload = try self.decoder.decode(ClaimPayload.self, from: response.data)
                    guard !payload.userId.isEmpty, !payload.token.isEmpty else {
                        self.deliver(.failure(.decoding(L10n.t("account.pairing.missingToken"))), completion)
                        return
                    }
                    self.deliver(
                        .success(AnonymousSession(
                            userID: payload.userId,
                            token: payload.token,
                            expiresAt: SyncDateCodec.parse(payload.expiresAt ?? "")
                        )),
                        completion
                    )
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    // MARK: - Deletion

    func createDeletionRequest(
        token: String,
        completion: @escaping (Result<DeletionChallenge, AccountAPIError>) -> Void
    ) {
        let request = HTTPRequest(
            url: endpoint("api/v1/me/deletion-request"),
            method: "POST",
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.failure(error)), completion)
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.accountError(response)), completion)
                    return
                }
                do {
                    let payload = try self.decoder.decode(DeletionChallengePayload.self, from: response.data)
                    guard !payload.token.isEmpty,
                          let expiresAt = SyncDateCodec.parse(payload.expiresAt)
                    else {
                        self.deliver(.failure(.decoding(L10n.t("account.delete.missingToken"))), completion)
                        return
                    }
                    self.deliver(
                        .success(DeletionChallenge(token: payload.token, expiresAt: expiresAt)),
                        completion
                    )
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func deleteAccount(
        deletionToken: String,
        completion: @escaping (Result<Void, AccountAPIError>) -> Void
    ) {
        // `DELETE /me` 只用二次确认令牌鉴权，刻意不带 Bearer。
        let request = HTTPRequest(
            url: endpoint("api/v1/me"),
            method: "DELETE",
            headers: ["X-Deletion-Token": deletionToken]
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.failure(error)), completion)
            case .success(let response):
                if response.isSuccess {
                    self.deliver(.success(()), completion)
                    return
                }
                self.deliver(.failure(Self.deletionError(response, decoder: self.decoder)), completion)
            }
        }
    }

    // MARK: - Async export

    func createExport(
        token: String,
        completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void
    ) {
        let request = HTTPRequest(
            url: endpoint("api/v1/me/export"),
            method: "POST",
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.failure(error)), completion)
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.accountError(response)), completion)
                    return
                }
                self.decodeTask(response.data, completion: completion)
            }
        }
    }

    func fetchExport(
        id: String,
        token: String,
        completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void
    ) {
        let request = HTTPRequest(
            url: endpoint("api/v1/me/export/\(id)"),
            headers: ["Authorization": "Bearer \(token)"]
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.failure(error)), completion)
            case .success(let response):
                switch response.statusCode {
                case 404:
                    self.deliver(.failure(.exportNotFound), completion)
                case 409:
                    self.deliver(.failure(.exportNotReady), completion)
                default:
                    guard response.isSuccess else {
                        self.deliver(.failure(self.accountError(response)), completion)
                        return
                    }
                    self.decodeTask(response.data, completion: completion)
                }
            }
        }
    }

    func downloadExport(
        url: URL,
        completion: @escaping (Result<Data, AccountAPIError>) -> Void
    ) {
        // 下载链接自带一次性 token，不再附加 Bearer。
        let request = HTTPRequest(url: url)
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.failure(error)), completion)
            case .success(let response):
                switch response.statusCode {
                case 200..<300:
                    self.deliver(.success(response.data), completion)
                case 403:
                    self.deliver(.failure(.downloadInvalid), completion)
                case 404:
                    self.deliver(.failure(.exportNotFound), completion)
                case 410:
                    self.deliver(.failure(.downloadExpired), completion)
                default:
                    self.deliver(.failure(self.accountError(response)), completion)
                }
            }
        }
    }

    // MARK: - Private

    private func decodeTask(
        _ data: Data,
        completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void
    ) {
        do {
            let payload = try decoder.decode(ExportTaskPayload.self, from: data)
            guard let status = AccountExportTask.Status(rawValue: payload.status),
                  !payload.id.isEmpty,
                  let createdAt = SyncDateCodec.parse(payload.createdAt),
                  let expiresAt = SyncDateCodec.parse(payload.expiresAt)
            else {
                deliver(.failure(.decoding(L10n.t("account.responseMismatch"))), completion)
                return
            }
            let downloadURL: URL?
            if status == .ready {
                guard let raw = payload.downloadUrl, !raw.isEmpty,
                      let url = URL(string: raw, relativeTo: configuration.baseURL)?.absoluteURL
                else {
                    deliver(.failure(.decoding(L10n.t("account.export.missingDownloadUrl"))), completion)
                    return
                }
                downloadURL = url
            } else {
                downloadURL = nil
            }
            deliver(
                .success(AccountExportTask(
                    id: payload.id,
                    status: status,
                    createdAt: createdAt,
                    completedAt: payload.completedAt.flatMap(SyncDateCodec.parse),
                    downloadURL: downloadURL,
                    downloadExpiresAt: payload.downloadExpiresAt.flatMap(SyncDateCodec.parse),
                    expiresAt: expiresAt
                )),
                completion
            )
        } catch {
            deliver(.failure(.decoding(error.localizedDescription)), completion)
        }
    }

    private func deliver<T>(
        _ result: Result<T, AccountAPIError>,
        _ completion: @escaping (Result<T, AccountAPIError>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private func accountError(_ response: HTTPResponse) -> AccountAPIError {
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 429:
            return .rateLimited(retryAfterSeconds: Self.retryAfterSeconds(response))
        default:
            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: response.data) {
                return .failure(.api(
                    code: envelope.error.code,
                    statusCode: response.statusCode,
                    message: envelope.error.message
                ))
            }
            return .failure(.server(statusCode: response.statusCode))
        }
    }

    private static func deletionError(_ response: HTTPResponse, decoder: JSONDecoder) -> AccountAPIError {
        switch response.statusCode {
        case 400:
            return envelopeError(response, decoder: decoder, fallbackCode: "DELETION_TOKEN_REQUIRED")
        case 401:
            return .unauthorized
        case 403:
            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: response.data),
               envelope.error.code == "DELETION_TOKEN_INVALID" {
                return .deletionTokenInvalid
            }
            return envelopeError(response, decoder: decoder, fallbackCode: "DELETION_TOKEN_INVALID")
        case 404:
            return .accountDeleted
        case 409:
            return .deletionBlocked
        case 410:
            return .deletionTokenExpired
        default:
            return envelopeError(response, decoder: decoder, fallbackCode: "ACCOUNT_DELETION_FAILED")
        }
    }

    private static func envelopeError(
        _ response: HTTPResponse,
        decoder: JSONDecoder,
        fallbackCode: String
    ) -> AccountAPIError {
        if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: response.data) {
            return .failure(.api(
                code: envelope.error.code,
                statusCode: response.statusCode,
                message: envelope.error.message
            ))
        }
        return .failure(.api(
            code: fallbackCode,
            statusCode: response.statusCode,
            message: L10n.f("error.httpStatus", String(describing: response.statusCode))
        ))
    }

    private static func retryAfterSeconds(_ response: HTTPResponse) -> Int? {
        guard let raw = response.header("Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Int(raw)
        else { return nil }
        return max(0, seconds)
    }

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }

    private struct PairingCodePayload: Decodable {
        let code: String
        let expiresAt: String
    }

    private struct ClaimRequest: Encodable {
        let code: String
    }

    private struct ClaimPayload: Decodable {
        let userId: String
        let token: String
        let expiresAt: String?
    }

    private struct DeletionChallengePayload: Decodable {
        let token: String
        let expiresAt: String
    }

    private struct ExportTaskPayload: Decodable {
        let id: String
        let status: String
        let createdAt: String
        let completedAt: String?
        let downloadUrl: String?
        let downloadExpiresAt: String?
        let expiresAt: String
    }

    private struct APIErrorEnvelope: Decodable {
        let error: Body

        struct Body: Decodable {
            let code: String
            let message: String
        }
    }
}

/// BASE_URL 未配置时的降级实现。
final class UnavailableAccountAPI: AccountAPIServicing {
    private let error = AccountAPIError.failure(.configuration(L10n.t("account.baseUrlMissing")))

    func createPairingCode(token: String, completion: @escaping (Result<PairingCode, AccountAPIError>) -> Void) {
        completion(.failure(error))
    }

    func claimPairingCode(_ code: String, completion: @escaping (Result<AnonymousSession, AccountAPIError>) -> Void) {
        completion(.failure(error))
    }

    func createDeletionRequest(
        token: String,
        completion: @escaping (Result<DeletionChallenge, AccountAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func deleteAccount(
        deletionToken: String,
        completion: @escaping (Result<Void, AccountAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func createExport(
        token: String,
        completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func fetchExport(
        id: String,
        token: String,
        completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func downloadExport(
        url: URL,
        completion: @escaping (Result<Data, AccountAPIError>) -> Void
    ) {
        completion(.failure(error))
    }
}
