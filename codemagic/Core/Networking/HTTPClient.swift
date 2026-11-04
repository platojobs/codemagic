import Foundation

/// HTTP 客户端抽象，便于单元测试注入桩实现。
protocol HTTPClient {
    func get(_ url: URL, completion: @escaping (Result<Data, AppError>) -> Void)
}

/// URLSession 实现：超时 15 秒，不使用本地缓存，错误统一映射为 `AppError`。
final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func get(_ url: URL, completion: @escaping (Result<Data, AppError>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.network("未收到 HTTP 响应")))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(.server(statusCode: httpResponse.statusCode)))
                return
            }
            guard let data else {
                completion(.failure(.decoding("响应体为空")))
                return
            }
            completion(.success(data))
        }.resume()
    }
}
