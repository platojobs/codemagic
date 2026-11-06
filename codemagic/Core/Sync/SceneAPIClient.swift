import Foundation

/// 服务端场景接口。全部成功响应为裸 JSON；失败固定为 `{"error":{...}}`。
protocol SceneAPIServicing {
    func listScenes(token: String, completion: @escaping (Result<[RemoteScene], AppError>) -> Void)
    func createScene(
        token: String,
        input: SceneCreateInput,
        completion: @escaping (Result<RemoteScene, AppError>) -> Void
    )
    func updateScene(
        token: String,
        id: String,
        patch: ScenePatchInput,
        completion: @escaping (Result<RemoteScene, AppError>) -> Void
    )
    func deleteScene(
        token: String,
        id: String,
        completion: @escaping (Result<Void, AppError>) -> Void
    )
}

final class SceneAPIClient: SceneAPIServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(configuration: APIConfiguration, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    func listScenes(token: String, completion: @escaping (Result<[RemoteScene], AppError>) -> Void) {
        let request = HTTPRequest(url: endpoint("api/v1/scenes"), headers: authorization(token))
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                do {
                    // 契约 0.17.0：GET /scenes 返回 {"items":[...]}，无分页。
                    let payload = try self.decoder.decode(SceneListBody.self, from: response.data)
                    self.deliver(.success(payload.items), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            case .failure(let error):
                self.deliver(.failure(error), completion)
            }
        }
    }

    func createScene(
        token: String,
        input: SceneCreateInput,
        completion: @escaping (Result<RemoteScene, AppError>) -> Void
    ) {
        var headers = authorization(token)
        headers["Content-Type"] = "application/json"
        let body: Data
        do {
            body = try encoder.encode(input)
        } catch {
            completion(.failure(.decoding(error.localizedDescription)))
            return
        }
        let request = HTTPRequest(url: endpoint("api/v1/scenes"), method: "POST", headers: headers, body: body)
        send(request, as: RemoteScene.self, completion: completion)
    }

    func updateScene(
        token: String,
        id: String,
        patch: ScenePatchInput,
        completion: @escaping (Result<RemoteScene, AppError>) -> Void
    ) {
        var headers = authorization(token)
        headers["Content-Type"] = "application/json"
        let body: Data
        do {
            body = try encoder.encode(patch)
        } catch {
            completion(.failure(.decoding(error.localizedDescription)))
            return
        }
        let request = HTTPRequest(
            url: endpoint("api/v1/scenes/\(id)"),
            method: "PUT",
            headers: headers,
            body: body
        )
        send(request, as: RemoteScene.self, completion: completion)
    }

    func deleteScene(
        token: String,
        id: String,
        completion: @escaping (Result<Void, AppError>) -> Void
    ) {
        let request = HTTPRequest(
            url: endpoint("api/v1/scenes/\(id)"),
            method: "DELETE",
            headers: authorization(token)
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                guard response.isSuccess || response.statusCode == 404 else {
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
        if let envelope = try? decoder.decode(SceneAPIErrorEnvelope.self, from: response.data) {
            return .api(
                code: envelope.error.code,
                statusCode: response.statusCode,
                message: envelope.error.message
            )
        }
        return .server(statusCode: response.statusCode)
    }

    private struct SceneListBody: Decodable {
        let items: [RemoteScene]
    }

    private struct SceneAPIErrorEnvelope: Decodable {
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
final class UnavailableSceneAPI: SceneAPIServicing {
    private let error = AppError.configuration(L10n.t("sync.api.baseUrlMissing"))

    func listScenes(token: String, completion: @escaping (Result<[RemoteScene], AppError>) -> Void) {
        completion(.failure(error))
    }

    func createScene(
        token: String,
        input: SceneCreateInput,
        completion: @escaping (Result<RemoteScene, AppError>) -> Void
    ) {
        completion(.failure(error))
    }

    func updateScene(
        token: String,
        id: String,
        patch: ScenePatchInput,
        completion: @escaping (Result<RemoteScene, AppError>) -> Void
    ) {
        completion(.failure(error))
    }

    func deleteScene(
        token: String,
        id: String,
        completion: @escaping (Result<Void, AppError>) -> Void
    ) {
        completion(.failure(error))
    }
}
