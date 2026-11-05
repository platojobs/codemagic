import Foundation

/// 配对码响应；`expiresAt` 为服务端真实过期时间（UTC）。
struct PairingCode: Equatable {
    let code: String
    let expiresAt: Date
}

/// 账号相关接口错误。404 统一为「码无效或已过期」，429 携带服务端 `Retry-After` 秒数。
enum AccountAPIError: Error, Equatable {
    case invalidCode
    case unauthorized
    case rateLimited(retryAfterSeconds: Int?)
    case failure(AppError)
    case decoding(String)

    var userMessage: String {
        switch self {
        case .invalidCode:
            return "接管码无效或已过期，请重新生成后再试。"
        case .unauthorized:
            return "登录已失效，请先重新登录后再操作。"
        case .rateLimited(let seconds):
            if let seconds {
                return "尝试过于频繁，请 \(seconds) 秒后再试。"
            }
            return "尝试过于频繁，请稍后再试。"
        case .failure(let error):
            return "\(error.code) \(error.message)"
        case .decoding:
            return "服务端响应格式与约定不符，请稍后重试。"
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

/// 账号接口协议：配对码、数据导出、注销。返回分页原始 JSON，由导出服务按规范拼装。
protocol AccountAPIServicing {
    func createPairingCode(token: String, completion: @escaping (Result<PairingCode, AccountAPIError>) -> Void)
    func claimPairingCode(_ code: String, completion: @escaping (Result<AnonymousSession, AccountAPIError>) -> Void)
    func fetchExportPage(
        cursor: String?,
        limit: Int,
        token: String,
        completion: @escaping (Result<Data, AccountAPIError>) -> Void
    )
    func deleteAccount(token: String, completion: @escaping (Result<Void, AccountAPIError>) -> Void)
}

/// `PJGoIoT/api/openapi.yaml` 0.6.0 账号端点的客户端实现。
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
                        self.deliver(.failure(.decoding("配对码响应缺少有效 code / expiresAt")), completion)
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
            deliver(.failure(.decoding("配对请求编码失败")), completion)
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
                        self.deliver(.failure(.decoding("配对响应缺少 userId / token")), completion)
                        return
                    }
                    self.deliver(
                        .success(AnonymousSession(userID: payload.userId, token: payload.token)),
                        completion
                    )
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    // MARK: - Export / Delete

    func fetchExportPage(
        cursor: String?,
        limit: Int,
        token: String,
        completion: @escaping (Result<Data, AccountAPIError>) -> Void
    ) {
        var components = URLComponents(
            url: endpoint("api/v1/me/export"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            deliver(.failure(.failure(.configuration("无法构造导出 URL"))), completion)
            return
        }
        let request = HTTPRequest(url: url, headers: ["Authorization": "Bearer \(token)"])
        sendData(request, completion: completion)
    }

    func deleteAccount(token: String, completion: @escaping (Result<Void, AccountAPIError>) -> Void) {
        let request = HTTPRequest(
            url: endpoint("api/v1/me"),
            method: "DELETE",
            headers: ["Authorization": "Bearer \(token)"]
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
                self.deliver(.success(()), completion)
            }
        }
    }

    // MARK: - Private

    private func sendData(
        _ request: HTTPRequest,
        completion: @escaping (Result<Data, AccountAPIError>) -> Void
    ) {
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
                self.deliver(.success(response.data), completion)
            }
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
    private let error = AccountAPIError.failure(.configuration("BASE_URL 未正确配置，账号功能不可用"))

    func createPairingCode(token: String, completion: @escaping (Result<PairingCode, AccountAPIError>) -> Void) {
        completion(.failure(error))
    }

    func claimPairingCode(_ code: String, completion: @escaping (Result<AnonymousSession, AccountAPIError>) -> Void) {
        completion(.failure(error))
    }

    func fetchExportPage(
        cursor: String?,
        limit: Int,
        token: String,
        completion: @escaping (Result<Data, AccountAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func deleteAccount(token: String, completion: @escaping (Result<Void, AccountAPIError>) -> Void) {
        completion(.failure(error))
    }
}
