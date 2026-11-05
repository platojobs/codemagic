import Foundation

/// 一次 HTTP 请求的描述，同步接口需要自定义方法、鉴权头与幂等键。
struct HTTPRequest {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data?

    init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// 原始 HTTP 响应：保留状态码与响应头，供鉴权、幂等重放判断。
struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// HTTP 客户端抽象，便于单元测试注入桩实现。
protocol HTTPClient {
    func send(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, AppError>) -> Void)
    func get(_ url: URL, completion: @escaping (Result<Data, AppError>) -> Void)
}

extension HTTPClient {
    /// 旧的 GET 便捷入口：非 2xx 统一映射为 `.server`，兼容 `ProductAPIClient`。
    func get(_ url: URL, completion: @escaping (Result<Data, AppError>) -> Void) {
        send(HTTPRequest(url: url)) { result in
            switch result {
            case .success(let response):
                guard response.isSuccess else {
                    completion(.failure(.server(statusCode: response.statusCode)))
                    return
                }
                completion(.success(response.data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

/// URLSession 实现：超时 15 秒，不使用本地缓存，传输错误统一映射为 `AppError.network`。
final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func send(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, AppError>) -> Void) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        session.dataTask(with: urlRequest) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.network(L10n.t("error.noHTTPResponse"))))
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in httpResponse.allHeaderFields {
                if let name = name as? String, let value = value as? String {
                    headers[name] = value
                }
            }
            completion(.success(HTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: headers,
                data: data ?? Data()
            )))
        }.resume()
    }
}
