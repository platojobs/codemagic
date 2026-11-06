import XCTest
@testable import codemagic

/// 设备类型目录：缓存、条件请求、离线回退与能力对齐。
final class DeviceCatalogTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8080")!
    private var testDatabase: TestDatabase!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        testDatabase = nil
    }

    // MARK: - Helpers

    private func makeHTTPResponse(
        status: Int,
        json: String,
        etag: String? = nil,
        lastModified: String? = nil
    ) -> HTTPResponse {
        var headers: [String: String] = ["Content-Type": "application/json"]
        if let etag { headers["ETag"] = etag }
        if let lastModified { headers["Last-Modified"] = lastModified }
        return HTTPResponse(statusCode: status, headers: headers, data: Data(json.utf8))
    }

    private func catalogJSON(
        version: Int,
        generatedAt: String = "2026-10-01T00:00:00Z",
        types: [(type: String, name: String, metrics: String)] = [
            ("environmental_sensor", "环境传感器", """
             [{"key":"temperature_celsius","unit":"°C","characteristicUuid":"2A6E"},
              {"key":"relative_humidity","unit":"%","characteristicUuid":"2A6F"}]
             """)
        ]
    ) -> String {
        let items = types.map { item in
            """
            {"type":"\(item.type)","displayName":"\(item.name)",
             "description":"目录描述","gattServices":[{"uuid":"181A","name":"Environmental Sensing"}],
             "metrics":\(item.metrics),"limitations":["需保持连接"],
             "compatibility":{"platforms":["ios"],"protocol":"ble-gatt"},
             "updatedAt":"2026-10-01T00:00:00Z"}
            """
        }.joined(separator: ",")
        return """
        {"version":\(version),"generatedAt":"\(generatedAt)","items":[\(items)]}
        """
    }

    private func makeClient(
        cache: DeviceCatalogCaching = InMemoryDeviceCatalogCache(),
        httpClient: HTTPClient,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1000) }
    ) -> DeviceCatalogClient {
        DeviceCatalogClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: httpClient,
            cache: cache,
            now: now
        )
    }

    private func waitForRefresh(
        _ client: DeviceCatalogClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result<DeviceCatalogSnapshot, AppError> {
        var captured: Result<DeviceCatalogSnapshot, AppError>?
        let expectation = expectation(description: "catalog refresh")
        client.refresh { result in
            captured = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        guard let captured else {
            XCTFail("目录请求未返回", file: file, line: line)
            return .failure(.network("no callback"))
        }
        return captured
    }

    // MARK: - 200 / 304 / ETag

    func testFirstSuccessPersistsCacheAndETag() throws {
        let cache = InMemoryDeviceCatalogCache()
        let client = makeClient(
            cache: cache,
            httpClient: CatalogHTTPClient { _ in
                .success(self.makeHTTPResponse(
                    status: 200,
                    json: self.catalogJSON(version: 1),
                    etag: "\"catalog-v1\"",
                    lastModified: "Wed, 01 Oct 2026 00:00:00 GMT"
                ))
            }
        )

        let result = waitForRefresh(client)
        let snapshot = try XCTUnwrap(try? result.get())
        XCTAssertEqual(snapshot.source, .network)
        XCTAssertEqual(snapshot.catalog.version, 1)
        XCTAssertEqual(snapshot.etag, "\"catalog-v1\"")

        let cached = try XCTUnwrap(cache.load())
        XCTAssertEqual(cached.catalog.items.first?.type, "environmental_sensor")
        XCTAssertEqual(cached.etag, "\"catalog-v1\"")
        XCTAssertEqual(cached.lastModified, "Wed, 01 Oct 2026 00:00:00 GMT")
    }

    func testSecondRequestSendsIfNoneMatchAndHandles304() throws {
        let cache = InMemoryDeviceCatalogCache()
        let response = makeHTTPResponse(
            status: 200,
            json: catalogJSON(version: 2),
            etag: "\"catalog-v2\"",
            lastModified: "Thu, 02 Oct 2026 00:00:00 GMT"
        )
        var callCount = 0
        let http = CatalogHTTPClient { _ in
            callCount += 1
            if callCount == 1 {
                return .success(response)
            }
            return .success(self.makeHTTPResponse(status: 304, json: ""))
        }
        var clock = Date(timeIntervalSince1970: 1000)
        let client = makeClient(cache: cache, httpClient: http, now: { clock })

        _ = waitForRefresh(client)
        clock = Date(timeIntervalSince1970: 2000)
        let second = waitForRefresh(client)
        let snapshot = try XCTUnwrap(try? second.get())

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(http.requests[1].headers["If-None-Match"], "\"catalog-v2\"")
        XCTAssertEqual(snapshot.source, .notModified, "304 不重新落库，只复用缓存")
        XCTAssertEqual(snapshot.catalog.version, 2)
        XCTAssertEqual(snapshot.lastUsedAt, Date(timeIntervalSince1970: 2000))

        let cached = try XCTUnwrap(cache.load())
        XCTAssertEqual(cached.lastUsedAt, Date(timeIntervalSince1970: 2000), "304 刷新使用时间")
        XCTAssertEqual(cached.fetchedAt, Date(timeIntervalSince1970: 1000), "304 不改成功同步时间")
    }

    func testChangedETagTriggersUpdate() throws {
        let cache = InMemoryDeviceCatalogCache()
        var callCount = 0
        let http = CatalogHTTPClient { request in
            callCount += 1
            if callCount == 1 {
                return .success(self.makeHTTPResponse(
                    status: 200,
                    json: self.catalogJSON(version: 1),
                    etag: "\"catalog-v1\""
                ))
            }
            XCTAssertEqual(request.headers["If-None-Match"], "\"catalog-v1\"")
            return .success(self.makeHTTPResponse(
                status: 200,
                json: self.catalogJSON(
                    version: 5,
                    types: [
                        ("environmental_sensor", "环境传感器", "[]"),
                        ("smart_scale", "智能体重秤", """
                         [{"key":"weight_kg","unit":"kg","characteristicUuid":"2A9D"}]
                         """)
                    ]
                ),
                etag: "\"catalog-v5\""
            ))
        }
        let client = makeClient(cache: cache, httpClient: http)

        _ = waitForRefresh(client)
        let updated = waitForRefresh(client)
        let snapshot = try XCTUnwrap(try? updated.get())

        XCTAssertEqual(snapshot.source, .network)
        XCTAssertEqual(snapshot.catalog.version, 5)
        XCTAssertEqual(snapshot.catalog.items.count, 2)
        XCTAssertEqual(cache.load()?.catalog.items.count, 2)
        XCTAssertEqual(cache.load()?.etag, "\"catalog-v5\"")
    }

    // MARK: - 离线 / 无缓存

    func testOfflineWithCacheFallsBackToCachedCatalog() throws {
        let cache = InMemoryDeviceCatalogCache()
        let first = makeClient(
            cache: cache,
            httpClient: CatalogHTTPClient { _ in
                .success(self.makeHTTPResponse(status: 200, json: self.catalogJSON(version: 7)))
            }
        )
        let snapshot = try XCTUnwrap(try? waitForRefresh(first).get())
        XCTAssertEqual(snapshot.catalog.items.count, 1)

        let offline = makeClient(
            cache: cache,
            httpClient: CatalogHTTPClient { _ in .failure(.network("offline")) }
        )
        let fallback = try XCTUnwrap(try? waitForRefresh(offline).get())
        XCTAssertEqual(fallback.source, .cacheFallback)
        XCTAssertEqual(fallback.catalog.version, 7, "断网时展示缓存内容而不是空白")
        XCTAssertTrue(fallback.statusText.contains(L10n.t("catalog.offlineCache")))
    }

    func testOfflineWithoutCacheReturnsReadableFailure() throws {
        let client = makeClient(
            cache: InMemoryDeviceCatalogCache(),
            httpClient: CatalogHTTPClient { _ in .failure(.network("offline")) }
        )
        let result = waitForRefresh(client)
        guard case .failure(let error) = result else {
            return XCTFail("无缓存时必须失败，不能用写死清单冒充服务端数据")
        }
        XCTAssertEqual(error.code, "NET-001")
    }

    func test304WithoutLocalCacheIsFailure() throws {
        let client = makeClient(
            cache: InMemoryDeviceCatalogCache(),
            httpClient: CatalogHTTPClient { _ in
                .success(self.makeHTTPResponse(status: 304, json: ""))
            }
        )
        let result = waitForRefresh(client)
        guard case .failure(let error) = result, case .api(let code, _, _) = error else {
            return XCTFail("304 但无缓存属于异常状态")
        }
        XCTAssertEqual(code, "CATALOG_CACHE_MISSING")
    }

    // MARK: - SQLite 缓存与迁移

    func testSQLiteStoreRoundTripAndRefreshLastUsed() throws {
        let store = DeviceCatalogStore(database: testDatabase.database)
        let catalog = DeviceTypeCatalog(
            version: 3,
            generatedAt: Date(timeIntervalSince1970: 500),
            items: [DeviceTypeCatalogItem(type: "environmental_sensor", displayName: "环境传感器")]
        )
        let raw = Data(catalogJSON(version: 3).utf8)
        store.save(
            catalog: catalog,
            rawPayload: raw,
            etag: "\"catalog-v3\"",
            lastModified: "Wed, 01 Oct 2026 00:00:00 GMT",
            fetchedAt: Date(timeIntervalSince1970: 600)
        )

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.catalog.version, 3)
        XCTAssertEqual(loaded.catalog.items.first?.displayName, "环境传感器", "缓存以原始响应为准")
        XCTAssertEqual(loaded.etag, "\"catalog-v3\"")
        XCTAssertEqual(loaded.fetchedAt, Date(timeIntervalSince1970: 600))

        store.touchLastUsed(at: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(store.load()?.lastUsedAt, Date(timeIntervalSince1970: 900))
    }

    func testMigrationFromV12AddsCacheTableAndKeepsData() throws {
        let store = DeviceCatalogStore(database: testDatabase.database)
        store.save(
            catalog: DeviceTypeCatalog(
                version: 1,
                generatedAt: Date(timeIntervalSince1970: 100),
                items: [DeviceTypeCatalogItem(type: "tracker", displayName: "追踪器")]
            ),
            rawPayload: Data(catalogJSON(version: 1).utf8),
            etag: nil,
            lastModified: nil,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        try testDatabase.database.execute("DROP TABLE device_catalog_cache;")
        try testDatabase.database.execute("PRAGMA user_version = 12;")

        // 关闭后重新打开，触发 v13 迁移。
        testDatabase.database.close()
        let migrated = try testDatabase.makeDatabaseHandle()
        defer { migrated.close() }

        let version = try migrated.query("PRAGMA user_version;").first?.integer("user_version")
        XCTAssertEqual(version, 17)

        let columns = Set(try migrated.query("PRAGMA table_info(device_catalog_cache);")
            .compactMap { $0.text("name") })
        XCTAssertEqual(
            columns,
            ["id", "version", "generated_at", "etag", "last_modified", "payload", "fetched_at", "last_used_at"]
        )
        XCTAssertNil(DeviceCatalogStore(database: migrated).load(), "迁移后从空缓存开始，不伪造数据")
    }

    // MARK: - 能力对齐

    func testCatalogMetricsMarkUnsupportedParserCapabilities() throws {
        let item = DeviceTypeCatalogItem(
            type: "smart_scale",
            displayName: "智能体重秤",
            gattServices: [GATTService(uuid: "181D", name: "Weight Scale")],
            metrics: [
                CatalogMetric(key: "heart_rate", unit: "bpm", characteristicUUID: "2A37"),
                CatalogMetric(key: "weight_kg", unit: "kg", characteristicUUID: "2A9D")
            ],
            limitations: ["仅支持单次测量"]
        )
        let product = ProductModel(
            mac: "",
            vendor: "",
            deviceType: item.displayName,
            firmwareVersion: "",
            gattServices: item.gattServices,
            compatibility: [],
            apiIdentifier: item.type,
            typeIdentifier: item.type,
            catalogMetrics: item.metrics,
            catalogLimitations: item.limitations
        )
        let profile = MarketInsights.profile(from: product)

        XCTAssertEqual(profile.metrics, [.heartRate], "只保留本地阅读器能解析的指标")
        let weight = try XCTUnwrap(profile.declaredMetrics?.first { $0.key == "weight_kg" })
        XCTAssertFalse(weight.isSupportedLocally)
        XCTAssertTrue(
            profile.metricsText.contains(L10n.f("catalog.metricUnsupported", "weight_kg · kg")),
            "目录声明但本地解析不了的指标必须如实标注"
        )
        XCTAssertEqual(profile.limitationsText, "仅支持单次测量", "限制文案来自目录，不再本地编造")
    }

    func testCatalogEmptyMetricsIsTreatedAsPassthrough() throws {
        let product = ProductModel(
            mac: "",
            vendor: "",
            deviceType: "自定义透传设备",
            firmwareVersion: "",
            gattServices: [GATTService(uuid: ReadingCharacteristic.nordicUART.serviceUUID, name: "UART")],
            compatibility: [],
            apiIdentifier: "custom_uart",
            typeIdentifier: "custom_uart",
            catalogMetrics: [],
            catalogLimitations: []
        )
        let profile = MarketInsights.profile(from: product)
        XCTAssertEqual(profile.metricsText, L10n.t("catalog.metricsPassthrough"))
        XCTAssertEqual(profile.metrics, [.nordicUART], "透传设备仍需保留 NUS 解析能力")
    }

    // MARK: - 界面（视图模型）表现

    func testMarketShowsCachedCatalogBeforeRefreshCompletes() {
        let cachedProduct = makeProduct(type: "tracker", name: "旧目录追踪器")
        let cachedInfo = makeSnapshot(
            version: 1,
            items: [DeviceTypeCatalogItem(type: "tracker", displayName: "旧目录追踪器")],
            source: .cache
        )
        let service = FakeCatalogProductService(
            cached: ProductCatalogSnapshot(
                products: [cachedProduct],
                marketItems: [],
                marketItemsError: nil,
                catalogInfo: cachedInfo
            ),
            results: []
        )
        service.deferCompletions = true
        let viewModel = MarketViewModel(productService: service)
        viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.state, .loaded, "有缓存时先渲染，不等目录请求")
        XCTAssertEqual(viewModel.profiles.map(\.displayName), ["旧目录追踪器"])
        XCTAssertEqual(viewModel.catalogInfo?.source, .cache)
    }

    func testMarketAddsNewTypeFromRefreshAndKeepsSelection() {
        let service = FakeCatalogProductService(
            cached: ProductCatalogSnapshot(
                products: [makeProduct(type: "tracker", name: "追踪器")],
                marketItems: [],
                marketItemsError: nil,
                catalogInfo: makeSnapshot(
                    version: 1,
                    items: [DeviceTypeCatalogItem(type: "tracker", displayName: "追踪器")],
                    source: .cache
                )
            ),
            results: [
                .success(ProductCatalogSnapshot(
                    products: [
                        makeProduct(type: "tracker", name: "追踪器"),
                        makeProduct(type: "smart_scale", name: "智能体重秤")
                    ],
                    marketItems: [],
                    marketItemsError: nil,
                    catalogInfo: makeSnapshot(
                        version: 2,
                        items: [
                            DeviceTypeCatalogItem(type: "tracker", displayName: "追踪器"),
                            DeviceTypeCatalogItem(type: "smart_scale", displayName: "智能体重秤")
                        ],
                        source: .network
                    )
                ))
            ]
        )
        let viewModel = MarketViewModel(productService: service)
        viewModel.loadIfNeeded()
        viewModel.selectType("tracker")

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(Set(viewModel.profiles.map(\.id)), Set(["tracker", "smart_scale"]), "目录新增类型直接出现在列表")
        XCTAssertEqual(viewModel.selectedTypeID, "tracker", "已有选择不因新增类型被打断")
        XCTAssertEqual(viewModel.catalogInfo?.catalog.version, 2)
        XCTAssertEqual(viewModel.catalogInfo?.source, .network)
    }

    // MARK: - Fixtures

    private func makeProduct(type: String, name: String) -> ProductModel {
        ProductModel(
            mac: "",
            vendor: "",
            deviceType: name,
            firmwareVersion: "",
            gattServices: [GATTService(uuid: "180F", name: "Battery")],
            compatibility: [],
            apiIdentifier: type,
            typeIdentifier: type,
            catalogMetrics: [CatalogMetric(key: "battery", unit: "%", characteristicUUID: "2A19")],
            catalogLimitations: ["目录限制"]
        )
    }

    private func makeSnapshot(
        version: Int,
        items: [DeviceTypeCatalogItem],
        source: DeviceCatalogSource
    ) -> DeviceCatalogSnapshot {
        DeviceCatalogSnapshot(
            catalog: DeviceTypeCatalog(
                version: Int64(version),
                generatedAt: Date(timeIntervalSince1970: 100),
                items: items
            ),
            etag: "\"catalog-v\(version)\"",
            lastModified: nil,
            fetchedAt: Date(timeIntervalSince1970: 100),
            lastUsedAt: Date(timeIntervalSince1970: 100),
            source: source
        )
    }
}

// MARK: - Test doubles

private final class CatalogHTTPClient: HTTPClient {
    private let handler: (HTTPRequest) -> Result<HTTPResponse, AppError>
    private(set) var requests: [HTTPRequest] = []

    init(handler: @escaping (HTTPRequest) -> Result<HTTPResponse, AppError>) {
        self.handler = handler
    }

    func send(
        _ request: HTTPRequest,
        completion: @escaping (Result<HTTPResponse, AppError>) -> Void
    ) {
        requests.append(request)
        completion(handler(request))
    }
}

private final class FakeCatalogProductService: ProductServicing {
    var cached: ProductCatalogSnapshot?
    var results: [Result<ProductCatalogSnapshot, AppError>]
    var deferCompletions = false
    private var pending: [(Result<ProductCatalogSnapshot, AppError>) -> Void] = []

    init(cached: ProductCatalogSnapshot?, results: [Result<ProductCatalogSnapshot, AppError>]) {
        self.cached = cached
        self.results = results
    }

    func cachedCatalogSnapshot() -> ProductCatalogSnapshot? { cached }

    func fetchProducts(completion: @escaping (Result<[ProductModel], AppError>) -> Void) {
        completion(.success(cached?.products ?? []))
    }

    func fetchMarketItems(completion: @escaping (Result<[MarketItem], AppError>) -> Void) {
        completion(.success(cached?.marketItems ?? []))
    }

    func fetchDeviceInfo(
        peripheralID: UUID,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        completion(.failure(.network("not used")))
    }

    func fetchCatalogSnapshot(
        completion: @escaping (Result<ProductCatalogSnapshot, AppError>) -> Void
    ) {
        if deferCompletions || results.isEmpty {
            pending.append(completion)
            return
        }
        completion(results.removeFirst())
    }

    func flush(_ result: Result<ProductCatalogSnapshot, AppError>) {
        let callbacks = pending
        pending = []
        callbacks.forEach { $0(result) }
    }
}
