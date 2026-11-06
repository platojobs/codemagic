import Foundation

/// `POST /push/devices` 的请求体。字段名与后端 v0.23.0 一致；可选项为空时省略。
struct PushRegistrationPayload: Encodable, Equatable {
    let platform: String
    let token: String
    let appVersion: String?
    let deviceModel: String?
}

/// 服务端返回的推送设备。只需 `id` 用于后续 `DELETE`，`status` 用于确认是否 active。
struct RemotePushDevice: Equatable {
    let id: String
    let status: String
}

/// 注销结果：404 视为该设备已不存在，调用方可直接清理本地记录。
enum PushDeactivationOutcome: Equatable {
    case deactivated
    case alreadyAbsent
}

/// 推送设备注册接口。
protocol PushDeviceAPIServicing {
    func register(
        payload: PushRegistrationPayload,
        authToken: String,
        completion: @escaping (Result<RemotePushDevice, AppError>) -> Void
    )
    func deactivate(
        deviceID: String,
        authToken: String,
        completion: @escaping (Result<PushDeactivationOutcome, AppError>) -> Void
    )
}

final class PushDeviceAPIClient: PushDeviceAPIServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: APIConfiguration, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    func register(
        payload: PushRegistrationPayload,
        authToken: String,
        completion: @escaping (Result<RemotePushDevice, AppError>) -> Void
    ) {
        var request = HTTPRequest(
            url: endpoint("api/v1/push/devices"),
            method: "POST",
            headers: authorization(authToken)
        )
        request.headers["Content-Type"] = "application/json"
        do {
            request.body = try encoder.encode(payload)
        } catch {
            deliver(.failure(.decoding(error.localizedDescription)), completion)
            return
        }
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                do {
                    let body = try self.decoder.decode(RegistrationResponse.self, from: response.data)
                    guard !body.id.isEmpty else {
                        self.deliver(.failure(.decoding(L10n.t("error.decoding"))), completion)
                        return
                    }
                    self.deliver(.success(RemotePushDevice(id: body.id, status: body.status)), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            case .failure(let error):
                self.deliver(.failure(error), completion)
            }
        }
    }

    func deactivate(
        deviceID: String,
        authToken: String,
        completion: @escaping (Result<PushDeactivationOutcome, AppError>) -> Void
    ) {
        let request = HTTPRequest(
            url: endpoint("api/v1/push/devices/\(deviceID)"),
            method: "DELETE",
            headers: authorization(authToken)
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                if response.statusCode == 404 {
                    self.deliver(.success(.alreadyAbsent), completion)
                    return
                }
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                self.deliver(.success(.deactivated), completion)
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
        if let envelope = try? decoder.decode(PushAPIErrorEnvelope.self, from: response.data) {
            return .api(
                code: envelope.error.code,
                statusCode: response.statusCode,
                message: envelope.error.message
            )
        }
        return .server(statusCode: response.statusCode)
    }

    private struct RegistrationResponse: Decodable {
        let id: String
        let status: String
    }

    private struct PushAPIErrorEnvelope: Decodable {
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

/// 未配置 BASE_URL 时的降级实现；不访问网络，也不伪造成功。
final class UnavailablePushDeviceAPI: PushDeviceAPIServicing {
    private let error = AppError.configuration(L10n.t("sync.api.baseUrlMissing"))

    func register(
        payload: PushRegistrationPayload,
        authToken: String,
        completion: @escaping (Result<RemotePushDevice, AppError>) -> Void
    ) {
        completion(.failure(error))
    }

    func deactivate(
        deviceID: String,
        authToken: String,
        completion: @escaping (Result<PushDeactivationOutcome, AppError>) -> Void
    ) {
        completion(.failure(error))
    }
}
