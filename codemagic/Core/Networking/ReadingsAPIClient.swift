import Foundation

/// 读数查询接口（后端契约已冻结，Go 端实现中）。
protocol ReadingsAPIServicing {
    func fetchReadings(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        from: Date?,
        to: Date?,
        limit: Int,
        cursor: String?,
        completion: @escaping (Result<ReadingsPage, AppError>) -> Void
    )
    func fetchSummary(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        hours: Int,
        completion: @escaping (Result<ReadingSummary, AppError>) -> Void
    )
    func fetchSeries(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        from: Date,
        to: Date,
        bucket: ReadingsBucket,
        completion: @escaping (Result<ReadingsSeries, AppError>) -> Void
    )
    func fetchMetrics(
        platform: String,
        externalID: String,
        completion: @escaping (Result<ReadingMetrics, AppError>) -> Void
    )
}

/// `GET /api/v1/my/devices/{platform}/{externalId}/readings` 与 `.../readings/summary`。
final class ReadingsAPIClient: ReadingsAPIServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let tokenStore: TokenStoring?
    private let decoder = JSONDecoder()

    init(
        configuration: APIConfiguration,
        httpClient: HTTPClient = URLSessionHTTPClient(),
        tokenStore: TokenStoring? = nil
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    func fetchReadings(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        from: Date? = nil,
        to: Date? = nil,
        limit: Int = 100,
        cursor: String? = nil,
        completion: @escaping (Result<ReadingsPage, AppError>) -> Void
    ) {
        var queryItems = [
            URLQueryItem(name: "metric", value: metric.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let from { queryItems.append(URLQueryItem(name: "from", value: SyncDateCodec.string(from: from))) }
        if let to { queryItems.append(URLQueryItem(name: "to", value: SyncDateCodec.string(from: to))) }
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        send(
            path: "api/v1/my/devices/\(pathComponent(platform))/\(pathComponent(externalID))/readings",
            queryItems: queryItems,
            as: ReadingsPage.self,
            completion: completion
        )
    }

    func fetchSummary(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        hours: Int = 24,
        completion: @escaping (Result<ReadingSummary, AppError>) -> Void
    ) {
        send(
            path: "api/v1/my/devices/\(pathComponent(platform))/\(pathComponent(externalID))/readings/summary",
            queryItems: [
                URLQueryItem(name: "metric", value: metric.rawValue),
                URLQueryItem(name: "hours", value: String(hours)),
            ],
            as: ReadingSummary.self,
            completion: completion
        )
    }

    func fetchSeries(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        from: Date,
        to: Date,
        bucket: ReadingsBucket,
        completion: @escaping (Result<ReadingsSeries, AppError>) -> Void
    ) {
        send(
            path: "api/v1/my/devices/\(pathComponent(platform))/\(pathComponent(externalID))/readings/series",
            queryItems: [
                URLQueryItem(name: "metric", value: metric.rawValue),
                URLQueryItem(name: "from", value: SyncDateCodec.string(from: from)),
                URLQueryItem(name: "to", value: SyncDateCodec.string(from: to)),
                URLQueryItem(name: "bucket", value: bucket.rawValue),
            ],
            as: ReadingsSeries.self,
            completion: completion
        )
    }

    func fetchMetrics(
        platform: String,
        externalID: String,
        completion: @escaping (Result<ReadingMetrics, AppError>) -> Void
    ) {
        send(
            path: "api/v1/my/devices/\(pathComponent(platform))/\(pathComponent(externalID))/readings/metrics",
            queryItems: [],
            as: ReadingMetrics.self,
            completion: completion
        )
    }

    // MARK: - Private

    private func pathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    private func send<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        as type: T.Type,
        completion: @escaping (Result<T, AppError>) -> Void
    ) {
        guard let session = tokenStore?.load(), !session.token.isEmpty else {
            completion(.failure(.sync("尚未创建匿名会话，无法查询云端读数")))
            return
        }
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else {
            completion(.failure(.configuration("无法构造读数 URL")))
            return
        }
        let request = HTTPRequest(url: url, headers: ["Authorization": "Bearer \(session.token)"])
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

/// BASE_URL 未配置时的降级实现：读数查询失败，界面回退本地数据。
final class UnavailableReadingsAPI: ReadingsAPIServicing {
    private let error = AppError.configuration("BASE_URL 未正确配置，云端读数不可用")

    func fetchReadings(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        from: Date?,
        to: Date?,
        limit: Int,
        cursor: String?,
        completion: @escaping (Result<ReadingsPage, AppError>) -> Void
    ) {
        completion(.failure(error))
    }

    func fetchSummary(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        hours: Int,
        completion: @escaping (Result<ReadingSummary, AppError>) -> Void
    ) {
        completion(.failure(error))
    }

    func fetchSeries(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        from: Date,
        to: Date,
        bucket: ReadingsBucket,
        completion: @escaping (Result<ReadingsSeries, AppError>) -> Void
    ) {
        completion(.failure(error))
    }

    func fetchMetrics(
        platform: String,
        externalID: String,
        completion: @escaping (Result<ReadingMetrics, AppError>) -> Void
    ) {
        completion(.failure(error))
    }
}
