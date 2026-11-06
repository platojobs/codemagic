import Foundation

/// 服务端登录会话（`GET /sessions`）。响应里不包含 token 本身。
struct RemoteSession: Equatable {
    let id: String
    let createdAt: Date
    let expiresAt: Date
    /// 是否为本次请求所用的会话；只有一条为 true。
    let isCurrent: Bool
}

/// 会话生命周期接口：刷新、退出、会话列表、吊销。
protocol AuthServicing {
    /// `POST /auth/refresh`：滚动刷新。成功后旧 token 立即失效。
    func refresh(token: String, completion: @escaping (Result<AnonymousSession, AppError>) -> Void)
    /// `POST /auth/logout`：吊销当前 token。
    func logout(token: String, completion: @escaping (Result<Void, AppError>) -> Void)
    /// `GET /sessions`
    func listSessions(token: String, completion: @escaping (Result<[RemoteSession], AppError>) -> Void)
    /// `DELETE /sessions/{id}`；重复吊销同一会话返回 204（幂等）。
    func revokeSession(id: String, token: String, completion: @escaping (Result<Void, AppError>) -> Void)
}

final class AuthAPIClient: AuthServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let decoder = JSONDecoder()

    init(configuration: APIConfiguration, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    func refresh(token: String, completion: @escaping (Result<AnonymousSession, AppError>) -> Void) {
        let request = HTTPRequest(
            url: endpoint("api/v1/auth/refresh"),
            method: "POST",
            headers: authorization(token)
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                do {
                    let body = try self.decoder.decode(SessionResponseBody.self, from: response.data)
                    guard !body.userId.isEmpty, !body.token.isEmpty else {
                        self.deliver(.failure(.decoding(L10n.t("error.decoding"))), completion)
                        return
                    }
                    let session = AnonymousSession(
                        userID: body.userId,
                        token: body.token,
                        expiresAt: body.expiresAt.flatMap(SyncDateCodec.parse)
                    )
                    self.deliver(.success(session), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            case .failure(let error):
                self.deliver(.failure(error), completion)
            }
        }
    }

    func logout(token: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        let request = HTTPRequest(
            url: endpoint("api/v1/auth/logout"),
            method: "POST",
            headers: authorization(token)
        )
        sendEmpty(request, completion: completion)
    }

    func listSessions(token: String, completion: @escaping (Result<[RemoteSession], AppError>) -> Void) {
        let request = HTTPRequest(url: endpoint("api/v1/sessions"), headers: authorization(token))
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                do {
                    let body = try self.decoder.decode(SessionListBody.self, from: response.data)
                    let sessions = body.sessions.compactMap { item -> RemoteSession? in
                        guard let createdAt = SyncDateCodec.parse(item.createdAt),
                              let expiresAt = SyncDateCodec.parse(item.expiresAt)
                        else { return nil }
                        return RemoteSession(
                            id: item.id,
                            createdAt: createdAt,
                            expiresAt: expiresAt,
                            isCurrent: item.current
                        )
                    }
                    self.deliver(.success(sessions), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            case .failure(let error):
                self.deliver(.failure(error), completion)
            }
        }
    }

    func revokeSession(id: String, token: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        let request = HTTPRequest(
            url: endpoint("api/v1/sessions/\(id)"),
            method: "DELETE",
            headers: authorization(token)
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                // 204 成功；重复吊销已返回 204。404 表示不属于本人，按终态展示。
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                self.deliver(.success(()), completion)
            case .failure(let error):
                self.deliver(.failure(error), completion)
            }
        }
    }

    // MARK: - Private

    private func sendEmpty(_ request: HTTPRequest, completion: @escaping (Result<Void, AppError>) -> Void) {
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                self.deliver(.success(()), completion)
            case .failure(let error):
                self.deliver(.failure(error), completion)
            }
        }
    }

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }

    private func authorization(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    private func deliver<T>(_ result: Result<T, AppError>, _ completion: @escaping (Result<T, AppError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    private func mapError(_ response: HTTPResponse) -> AppError {
        if response.statusCode == 429 {
            return .rateLimited(retryAfterSeconds: response.retryAfterSeconds)
        }
        if let envelope = try? decoder.decode(AuthAPIErrorEnvelope.self, from: response.data) {
            return .api(
                code: envelope.error.code,
                statusCode: response.statusCode,
                message: envelope.error.message
            )
        }
        return .server(statusCode: response.statusCode)
    }

    private struct SessionResponseBody: Decodable {
        let userId: String
        let token: String
        let expiresAt: String?
    }

    private struct SessionListBody: Decodable {
        struct Item: Decodable {
            let id: String
            let createdAt: String
            let expiresAt: String
            let current: Bool
        }

        let sessions: [Item]
    }

    private struct AuthAPIErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? "UNKNOWN"
                message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
            }

            private enum CodingKeys: String, CodingKey {
                case code, message
            }
        }

        let error: Body
    }
}

/// 未配置 BASE_URL 时的降级实现。
final class UnavailableAuthAPI: AuthServicing {
    private let error = AppError.configuration(L10n.t("sync.api.baseUrlMissing"))

    func refresh(token: String, completion: @escaping (Result<AnonymousSession, AppError>) -> Void) {
        completion(.failure(error))
    }

    func logout(token: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        completion(.failure(error))
    }

    func listSessions(token: String, completion: @escaping (Result<[RemoteSession], AppError>) -> Void) {
        completion(.failure(error))
    }

    func revokeSession(id: String, token: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        completion(.failure(error))
    }
}
