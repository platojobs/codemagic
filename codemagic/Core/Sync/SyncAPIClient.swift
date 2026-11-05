import Foundation

/// 同步相关接口协议，便于用桩实现测试同步引擎。
protocol SyncAPIServicing {
    func createAnonymousSession(completion: @escaping (Result<AnonymousSession, AppError>) -> Void)
    func fetchChanges(
        cursor: Int64,
        limit: Int,
        token: String,
        completion: @escaping (Result<SyncChangesPage, AppError>) -> Void
    )
    func push(
        clientID: String,
        token: String,
        idempotencyKey: String,
        devices: [PushDevice],
        readings: [PushReading],
        completion: @escaping (Result<PushResult, AppError>) -> Void
    )
    func fetchDeviceType(
        _ type: String,
        completion: @escaping (Result<DeviceTypeInfo, AppError>) -> Void
    )
}

/// `PJGoIoT/api/openapi.yaml`（v0.2.0）的客户端实现。
///
/// 所有路径以 `/api/v1` 开头；成功响应为裸 JSON，失败响应固定为
/// `{"error":{"code":"...","message":"..."}}`，这里统一解析为 `AppError.api`。
final class SyncAPIClient: SyncAPIServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(configuration: APIConfiguration, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    // MARK: - Auth

    func createAnonymousSession(completion: @escaping (Result<AnonymousSession, AppError>) -> Void) {
        let url = endpoint("api/v1/auth/anonymous")
        let body = Data("{}".utf8)
        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body
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
                    let decoded = try self.decoder.decode(AnonymousResponse.self, from: response.data)
                    guard !decoded.token.isEmpty else {
                        self.deliver(.failure(.decoding("匿名登录响应缺少 token")), completion)
                        return
                    }
                    self.deliver(
                        .success(AnonymousSession(
                            userID: decoded.userId,
                            token: decoded.token,
                            expiresAt: SyncDateCodec.parse(decoded.expiresAt ?? "")
                        )),
                        completion
                    )
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            case .failure(let error):
                self.deliver(.failure(error), completion)
            }
        }
    }

    // MARK: - Sync

    func fetchChanges(
        cursor: Int64,
        limit: Int,
        token: String,
        completion: @escaping (Result<SyncChangesPage, AppError>) -> Void
    ) {
        var components = URLComponents(
            url: endpoint("api/v1/sync/changes"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "cursor", value: String(cursor)),
            // 服务端上限 500；越界会被 400，客户端先收敛。
            URLQueryItem(name: "limit", value: String(APILimits.clamp(limit, to: APILimits.changes))),
        ]
        guard let url = components?.url else {
            completion(.failure(.configuration("无法构造同步 URL")))
            return
        }
        let request = HTTPRequest(url: url, headers: authorization(token))
        send(request, as: SyncChangesPage.self, completion: completion)
    }

    func push(
        clientID: String,
        token: String,
        idempotencyKey: String,
        devices: [PushDevice],
        readings: [PushReading],
        completion: @escaping (Result<PushResult, AppError>) -> Void
    ) {
        let url = endpoint("api/v1/sync/push")
        var headers = authorization(token)
        headers["Content-Type"] = "application/json"
        headers["Idempotency-Key"] = idempotencyKey

        let body: Data
        do {
            body = try encoder.encode(
                PushRequest(clientID: clientID, devices: devices, readings: readings)
            )
        } catch {
            completion(.failure(.decoding("推送请求编码失败：\(error.localizedDescription)")))
            return
        }

        let request = HTTPRequest(url: url, method: "POST", headers: headers, body: body)
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                do {
                    let decoded = try self.decoder.decode(PushResult.self, from: response.data)
                    let replayed = response.header("Idempotent-Replayed")?.lowercased() == "true"
                    self.deliver(.success(decoded.withIdempotentReplay(replayed)), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            case .failure(let error):
                self.deliver(.failure(error), completion)
            }
        }
    }

    // MARK: - Metadata

    func fetchDeviceType(
        _ type: String,
        completion: @escaping (Result<DeviceTypeInfo, AppError>) -> Void
    ) {
        let encodedType = type.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? type
        let url = endpoint("api/v1/device-types/\(encodedType)")
        send(HTTPRequest(url: url), as: DeviceTypeInfo.self, completion: completion)
    }

    // MARK: - Private

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }

    private func authorization(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    private func send<T: Decodable>(
        _ request: HTTPRequest,
        as type: T.Type,
        completion: @escaping (Result<T, AppError>) -> Void
    ) {
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                do {
                    let decoded = try self.decoder.decode(T.self, from: response.data)
                    self.deliver(.success(decoded), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            case .failure(let error):
                self.deliver(.failure(error), completion)
            }
        }
    }

    private func deliver<T>(_ result: Result<T, AppError>, _ completion: @escaping (Result<T, AppError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    private func mapError(_ response: HTTPResponse) -> AppError {
        if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: response.data) {
            return .api(
                code: envelope.error.code,
                statusCode: response.statusCode,
                message: envelope.error.message
            )
        }
        return .server(statusCode: response.statusCode)
    }

    private struct AnonymousResponse: Decodable {
        let userId: String
        let token: String
        let expiresAt: String?

        private enum CodingKeys: String, CodingKey {
            case userId
            case token
            case expiresAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userId = (try? container.decodeIfPresent(String.self, forKey: .userId)) ?? ""
            token = (try? container.decodeIfPresent(String.self, forKey: .token)) ?? ""
            expiresAt = try? container.decodeIfPresent(String.self, forKey: .expiresAt)
        }
    }

    private struct APIErrorEnvelope: Decodable {
        let error: Body

        struct Body: Decodable {
            let code: String
            let message: String

            private enum CodingKeys: String, CodingKey {
                case code
                case message
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? "UNKNOWN"
                message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
            }
        }
    }
}

/// BASE_URL 未配置时的降级实现：同步请求直接返回配置错误，不影响本地功能。
final class UnavailableSyncAPI: SyncAPIServicing {
    private let error = AppError.configuration("BASE_URL 未正确配置，同步不可用")

    func createAnonymousSession(completion: @escaping (Result<AnonymousSession, AppError>) -> Void) {
        completion(.failure(error))
    }

    func fetchChanges(
        cursor: Int64,
        limit: Int,
        token: String,
        completion: @escaping (Result<SyncChangesPage, AppError>) -> Void
    ) {
        completion(.failure(error))
    }

    func push(
        clientID: String,
        token: String,
        idempotencyKey: String,
        devices: [PushDevice],
        readings: [PushReading],
        completion: @escaping (Result<PushResult, AppError>) -> Void
    ) {
        completion(.failure(error))
    }

    func fetchDeviceType(
        _ type: String,
        completion: @escaping (Result<DeviceTypeInfo, AppError>) -> Void
    ) {
        completion(.failure(error))
    }
}
