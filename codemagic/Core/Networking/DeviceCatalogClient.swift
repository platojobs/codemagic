import Foundation

/// 目录数据从哪来：首次网络命中、304 命中缓存、首屏本地缓存或网络失败后的缓存兜底。
enum DeviceCatalogSource: Equatable {
    case network
    case notModified
    /// 刷新尚未返回时先渲染的本地缓存。
    case cache
    /// 网络失败后降级使用的本地缓存。
    case cacheFallback

    /// 只有网络失败回退时需要额外提示离线。
    var isOfflineFallback: Bool { self == .cacheFallback }
}

/// 交给界面的目录快照，带来源与时间，便于如实标注「目录更新时间」。
struct DeviceCatalogSnapshot: Equatable {
    let catalog: DeviceTypeCatalog
    let etag: String?
    let lastModified: String?
    let fetchedAt: Date
    let lastUsedAt: Date
    let source: DeviceCatalogSource

    /// 页面底部标注：目录更新时间；离线兜底时明确说明当前是本地缓存。
    var statusText: String {
        let updated = catalog.generatedAt.timeIntervalSince1970 > 0
            ? AppDateFormat.absolute(catalog.generatedAt)
            : L10n.t("common.unknown")
        var parts = [L10n.f("catalog.updatedAt", updated)]
        if source.isOfflineFallback {
            parts.append(L10n.t("catalog.offlineCache"))
        }
        return parts.joined(separator: L10n.t("common.semicolonSeparator"))
    }
}

/// 目录服务：同步读缓存 + 条件请求刷新。
protocol DeviceCatalogServicing {
    /// 同步读取本地缓存，供首屏先渲染；不存在时返回 nil。
    func cachedSnapshot() -> DeviceCatalogSnapshot?
    /// 发送条件请求；有缓存时即使断网也返回 `cacheFallback`，无缓存才失败。
    func refresh(completion: @escaping (Result<DeviceCatalogSnapshot, AppError>) -> Void)
}

/// `GET /catalog/device-types` 客户端。
///
/// 缓存策略：SQLite 单行保存原始响应 JSON 与 `ETag` / `Last-Modified`。
/// 下次请求优先带 `If-None-Match`，其次 `If-Modified-Since`；304 直接复用缓存并刷新
/// `last_used_at`。断网且缓存存在时返回缓存，页面不会空白；无缓存则把错误交给界面。
final class DeviceCatalogClient: DeviceCatalogServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let cache: DeviceCatalogCaching
    private let now: () -> Date
    private let decoder = JSONDecoder()

    init(
        configuration: APIConfiguration,
        httpClient: HTTPClient = URLSessionHTTPClient(),
        cache: DeviceCatalogCaching = InMemoryDeviceCatalogCache(),
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.cache = cache
        self.now = now
    }

    func cachedSnapshot() -> DeviceCatalogSnapshot? {
        cache.load().map { snapshot(from: $0, source: .cache) }
    }

    func refresh(completion: @escaping (Result<DeviceCatalogSnapshot, AppError>) -> Void) {
        let cached = cache.load()
        var headers: [String: String] = [:]
        if let etag = cached?.etag, !etag.isEmpty {
            headers["If-None-Match"] = etag
        } else if let lastModified = cached?.lastModified, !lastModified.isEmpty {
            headers["If-Modified-Since"] = lastModified
        }

        let request = HTTPRequest(
            url: configuration.baseURL.appendingPathComponent("api/v1/catalog/device-types"),
            headers: headers
        )

        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finishWithCacheOrFailure(cached, error: error, completion: completion)
            case .success(let response):
                switch response.statusCode {
                case 200:
                    self.handleSuccess(response, completion: completion)
                case 304:
                    self.handleNotModified(cached, completion: completion)
                default:
                    self.finishWithCacheOrFailure(
                        cached,
                        error: Self.mapError(response),
                        completion: completion
                    )
                }
            }
        }
    }

    // MARK: - Branches

    private func handleSuccess(
        _ response: HTTPResponse,
        completion: @escaping (Result<DeviceCatalogSnapshot, AppError>) -> Void
    ) {
        guard let catalog = try? decoder.decode(DeviceTypeCatalog.self, from: response.data),
              !catalog.items.isEmpty || catalog.version > 0 else {
            finishWithCacheOrFailure(
                cache.load(),
                error: .decoding(L10n.t("catalog.decodeFailed")),
                completion: completion
            )
            return
        }
        let time = now()
        let etag = response.header("ETag")
        let lastModified = response.header("Last-Modified")
        cache.save(
            catalog: catalog,
            rawPayload: response.data,
            etag: etag,
            lastModified: lastModified,
            fetchedAt: time
        )
        completion(.success(DeviceCatalogSnapshot(
            catalog: catalog,
            etag: etag,
            lastModified: lastModified,
            fetchedAt: time,
            lastUsedAt: time,
            source: .network
        )))
    }

    private func handleNotModified(
        _ cached: CachedDeviceCatalog?,
        completion: @escaping (Result<DeviceCatalogSnapshot, AppError>) -> Void
    ) {
        guard let cached else {
            completion(.failure(.api(
                code: "CATALOG_CACHE_MISSING",
                statusCode: 304,
                message: L10n.t("catalog.cacheMissing")
            )))
            return
        }
        let time = now()
        cache.touchLastUsed(at: time)
        completion(.success(snapshot(
            from: cached,
            source: .notModified,
            lastUsedAt: time
        )))
    }

    /// 网络失败 / 非 2xx / 解析失败：有缓存就降级展示缓存，没有才返回错误。
    private func finishWithCacheOrFailure(
        _ cached: CachedDeviceCatalog?,
        error: AppError?,
        completion: @escaping (Result<DeviceCatalogSnapshot, AppError>) -> Void
    ) {
        if let cached {
            completion(.success(snapshot(from: cached, source: .cacheFallback)))
            return
        }
        completion(.failure(error ?? .network(L10n.t("error.network"))))
    }

    private func snapshot(
        from cached: CachedDeviceCatalog,
        source: DeviceCatalogSource,
        lastUsedAt: Date? = nil
    ) -> DeviceCatalogSnapshot {
        DeviceCatalogSnapshot(
            catalog: cached.catalog,
            etag: cached.etag,
            lastModified: cached.lastModified,
            fetchedAt: cached.fetchedAt,
            lastUsedAt: lastUsedAt ?? cached.lastUsedAt,
            source: source
        )
    }

    private static func mapError(_ response: HTTPResponse) -> AppError {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: response.data) {
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
        }
    }
}
