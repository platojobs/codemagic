import XCTest
@testable import codemagic

final class NetworkingTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8080")!

    private func waitForResult<T>(
        _ call: (@escaping (Result<T, AppError>) -> Void) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result<T, AppError> {
        var captured: Result<T, AppError>?
        let expectation = expectation(description: "completion")
        call { result in
            captured = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)
        guard let captured else {
            XCTFail("回调未返回", file: file, line: line)
            return .failure(.network("no callback"))
        }
        return captured
    }

    // MARK: - Decoding

    func testProductDecodingIgnoresUnknownFields() throws {
        let json = """
        {
          "mac": "AA:BB:CC:DD:EE:FF",
          "vendor": "Acme",
          "deviceType": "Panel",
          "firmwareVersion": "1.2.0",
          "gattServices": [
            {"uuid": "180F", "name": "Battery", "extra": true}
          ],
          "compatibility": ["X1", "X2"],
          "unknownField": 123
        }
        """
        let product = try JSONDecoder().decode(ProductModel.self, from: Data(json.utf8))

        XCTAssertEqual(product.mac, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(product.gattServices.first?.uuid, "180F")
        XCTAssertEqual(product.gattServices.first?.name, "Battery")
        XCTAssertEqual(product.compatibility, ["X1", "X2"])
    }

    func testProductDecodingFillsDefaultsForMissingFields() throws {
        let json = #"{"mac":"AA:BB"}"#
        let product = try JSONDecoder().decode(ProductModel.self, from: Data(json.utf8))

        XCTAssertEqual(product.mac, "AA:BB")
        XCTAssertEqual(product.vendor, "")
        XCTAssertEqual(product.deviceType, "")
        XCTAssertEqual(product.firmwareVersion, "")
        XCTAssertTrue(product.gattServices.isEmpty)
        XCTAssertTrue(product.compatibility.isEmpty)
        XCTAssertEqual(product.id, "AA:BB")
    }

    func testProductCompatibilityAcceptsSingleString() throws {
        let json = """
        {"mac":"M1","compatibility":"仅兼容 2.4G 网关"}
        """
        let product = try JSONDecoder().decode(ProductModel.self, from: Data(json.utf8))
        XCTAssertEqual(product.compatibility, ["仅兼容 2.4G 网关"])
    }

    func testMarketItemUnknownKindFallsBackToOther() throws {
        let json = """
        {
          "id": "fw-1",
          "kind": "sensor",
          "name": "固件包",
          "vendor": "Acme",
          "version": "2.0",
          "compatibility": ["X1", "X2"],
          "summary": "升级说明"
        }
        """
        let item = try JSONDecoder().decode(MarketItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.kind, .other)
        XCTAssertEqual(item.compatibility, "X1、X2")
        XCTAssertEqual(item.displayIdentifier, "fw-1")
    }

    // MARK: - Client

    /// 模拟契约 0.14.0 后端：目录接口 + 逐型号 catalog（固件 / 配件）。
    private func makeCatalogStub() -> StubHTTPClient {
        StubHTTPClient { url in
            switch url.path {
            case "/api/v1/catalog/device-types":
                let json = """
                {"version":3,"generatedAt":"2026-10-01T00:00:00Z","items":[
                  {"type":"tracker","displayName":"BLE Tracker","description":"支持 BLE 5.0",
                   "gattServices":[{"uuid":"180F","name":"Battery"}],
                   "metrics":[{"key":"battery","unit":"%","characteristicUuid":"2A19"}],
                   "limitations":["仅支持单连接"],
                   "compatibility":{"platforms":["ios","android"],"protocol":"ble-gatt"},
                   "updatedAt":"2026-10-01T00:00:00Z"}]}
                """
                return .success(Data(json.utf8))
            case "/api/v1/device-types/tracker/catalog":
                let json = """
                {"deviceType":{"type":"tracker","name":"BLE Tracker","vendor":"Nordic Semiconductor",
                   "description":"支持 BLE 5.0","gattServices":[{"uuid":"180F","name":"Battery"}],
                   "compatibility":{"platforms":["ios","android"],"protocol":"ble-gatt"}},
                 "firmwares":[{"id":"fw-1","deviceType":"tracker","version":"1.2.3",
                   "releaseNotes":"修复断连重试问题","releasedAt":"2026-10-01T00:00:00Z",
                   "vendor":"Acme Firmware",
                   "compatibility":{"platforms":["ios"],"protocol":"ble-gatt","features":["dfu"]}}],
                 "accessories":[{"id":"acc-1","deviceType":"tracker","name":"磁吸底座",
                   "sku":"SKU-1","description":"金属底座","vendor":"Acme Accessories",
                   "compatibility":{"deviceTypes":["tracker"]}}]}
                """
                return .success(Data(json.utf8))
            default:
                return .failure(.server(statusCode: 404))
            }
        }
    }

    func testProductAPIClientUsesDeviceTypeCatalog() throws {
        let client = makeCatalogStub()
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchProducts(completion: $0) }
        let products = try XCTUnwrap(try? result.get())

        XCTAssertEqual(products.count, 1)
        XCTAssertEqual(products.first?.deviceType, "BLE Tracker")
        XCTAssertEqual(products.first?.vendor, "Nordic Semiconductor")
        XCTAssertEqual(products.first?.firmwareVersion, "1.2.3")
        XCTAssertEqual(products.first?.gattServices.first?.uuid, "180F")
        XCTAssertEqual(products.first?.compatibility, ["平台：ios、android", "协议：ble-gatt"])
        XCTAssertEqual(products.first?.id, "tracker")
        XCTAssertEqual(products.first?.typeIdentifier, "tracker")
        XCTAssertEqual(products.first?.catalogMetrics.first?.key, "battery")
        XCTAssertEqual(products.first?.catalogLimitations, ["仅支持单连接"])
        XCTAssertTrue(products.first?.note.contains("支持 BLE 5.0") == true)
        XCTAssertTrue(client.requestedURLs.contains { $0.path == "/api/v1/catalog/device-types" })
        XCTAssertTrue(client.requestedURLs.contains { $0.path.hasSuffix("/catalog") })
        XCTAssertFalse(client.requestedURLs.contains { $0.path == "/api/v1/device-types" })
        XCTAssertFalse(client.requestedURLs.contains { $0.path.contains("/api/products") })
    }

    func testHTTPErrorMapsToServerErrorCode() throws {
        let client = StubHTTPClient { _ in .failure(.server(statusCode: 500)) }
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchProducts(completion: $0) }
        guard case .failure(let error) = result else {
            return XCTFail("应返回失败")
        }
        XCTAssertEqual(error, .server(statusCode: 500))
        XCTAssertEqual(error.code, "NET-002")
    }

    func testInvalidJSONMapsToDecodingError() throws {
        let client = StubHTTPClient { _ in .success(Data("not-json".utf8)) }
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchProducts(completion: $0) }
        guard case .failure(let error) = result else {
            return XCTFail("应返回失败")
        }
        guard case .decoding = error else {
            return XCTFail("应为解析错误")
        }
        XCTAssertEqual(error.code, "NET-003")
    }

    func testMarketItemsAggregateCatalog() throws {
        let client = makeCatalogStub()
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchMarketItems(completion: $0) }
        let items = try XCTUnwrap(try? result.get())

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].kind, .firmware)
        XCTAssertEqual(items[0].name, "固件 1.2.3")
        XCTAssertEqual(items[0].vendor, "Acme Firmware", "厂商取固件自身真实字段")
        XCTAssertEqual(items[0].compatibility, "平台：ios；协议：ble-gatt；特性：dfu")
        XCTAssertEqual(items[0].compatibilityTags, ["平台：ios", "协议：ble-gatt"])
        XCTAssertEqual(items[0].summary, "修复断连重试问题")
        XCTAssertEqual(items[1].kind, .accessory)
        XCTAssertEqual(items[1].name, "磁吸底座")
        XCTAssertEqual(items[1].version, "SKU-1")
        XCTAssertEqual(items[1].vendor, "Acme Accessories")
        XCTAssertEqual(items[1].compatibility, "型号：tracker")
        XCTAssertEqual(items[1].compatibilityTags, ["型号：tracker"])
        XCTAssertTrue(client.requestedURLs.contains { $0.path.hasSuffix("/catalog") })
        XCTAssertFalse(client.requestedURLs.contains { $0.path.contains("/api/market") })
    }

    func testDeviceInfoUsesCompositeKeyAndBearerToken() throws {
        let peripheralID = UUID()
        let recordJSON = """
        {"id":"dev-1","clientId":"ios-client","platform":"ios",
         "externalId":"\(peripheralID.uuidString.lowercased())","mac":"AA:BB:CC:DD:EE:FF",
         "alias":"我的追踪器","group":"客厅","updatedAt":"2026-11-05T00:00:00Z","serverSeq":9,
         "deviceType":"tracker","vendor":"Nordic Semiconductor","firmwareVersion":"1.2.3",
         "compatibility":{"platforms":["ios"],"protocol":"ble-gatt","minAppVersion":"0.3.3"}}
        """
        let client = StubHTTPClient { _ in .success(Data(recordJSON.utf8)) }
        let tokenStore = InMemoryTokenStore()
        try tokenStore.save(AnonymousSession(userID: "user-1", token: "test-token"))
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client,
            tokenStore: tokenStore
        )

        let result = waitForResult { api.fetchDeviceInfo(peripheralID: peripheralID, completion: $0) }
        let product = try XCTUnwrap(try? result.get())

        XCTAssertEqual(product.mac, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(product.id, "dev-1")
        XCTAssertEqual(product.deviceType, "tracker", "云端 deviceType 优先展示")
        XCTAssertEqual(product.vendor, "Nordic Semiconductor")
        XCTAssertEqual(product.firmwareVersion, "1.2.3")
        XCTAssertEqual(
            product.compatibility,
            ["平台：ios", "协议：ble-gatt", "最低 App：0.3.3"]
        )
        XCTAssertTrue(product.note.contains("我的追踪器"))
        XCTAssertTrue(product.note.contains(peripheralID.uuidString.uppercased()))

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url.path, "/api/v1/my/devices/ios/\(peripheralID.uuidString.uppercased())")
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-token")
        XCTAssertFalse(request.url.path.contains("/api/device/"))
    }

    func testDeviceInfoWithoutTokenDoesNotCreateAnonymousAccount() throws {
        let client = StubHTTPClient { _ in .failure(.network("不应发起请求")) }
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchDeviceInfo(peripheralID: UUID(), completion: $0) }
        guard case .failure(let error) = result else {
            return XCTFail("缺少 token 时应失败")
        }
        XCTAssertEqual(error.code, "SYNC-001")
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testCatalogDecodingToleratesMissingFields() throws {
        let json = """
        {"deviceType":{"type":"tracker"},"firmwares":[{"id":"fw-1"}],"unknownField":true}
        """
        let catalog = try JSONDecoder().decode(DeviceCatalog.self, from: Data(json.utf8))

        XCTAssertEqual(catalog.deviceType.type, "tracker")
        XCTAssertEqual(catalog.deviceType.name, "")
        XCTAssertEqual(catalog.firmwares.first?.id, "fw-1")
        XCTAssertEqual(catalog.firmwares.first?.version, "")
        XCTAssertEqual(catalog.firmwares.first?.vendor, "", "缺失 vendor 时为空串")
        XCTAssertNil(catalog.firmwares.first?.compatibility, "缺失 compatibility 时为 nil")
        XCTAssertTrue(catalog.accessories.isEmpty)
    }

    func testUserDeviceNullFieldsMapToNil() throws {
        let json = """
        {"id":"dev-2","platform":"ios","externalId":"UUID",
         "updatedAt":"2026-11-05T00:00:00Z",
         "deviceType":null,"vendor":null,"firmwareVersion":null,"compatibility":null}
        """
        let record = try JSONDecoder().decode(UserDeviceInfo.self, from: Data(json.utf8))
        XCTAssertNil(record.deviceType)
        XCTAssertNil(record.vendor)
        XCTAssertNil(record.firmwareVersion)
        XCTAssertNil(record.compatibility)

        let emptyJSON = """
        {"id":"dev-3","platform":"ios","externalId":"UUID",
         "updatedAt":"2026-11-05T00:00:00Z",
         "deviceType":"","vendor":"  ","firmwareVersion":"","compatibility":{}}
        """
        let empty = try JSONDecoder().decode(UserDeviceInfo.self, from: Data(emptyJSON.utf8))
        XCTAssertNil(empty.deviceType, "空串按 null 渲染")
        XCTAssertNil(empty.vendor, "空白按 null 渲染")
        XCTAssertNil(empty.firmwareVersion)
        XCTAssertEqual(empty.compatibility?.displayItems, [])
    }

    func testUnauthorizedMapsToAPIError() throws {
        let client = StubHTTPClient(statusCode: 401) { _ in
            .success(Data(#"{"error":{"code":"UNAUTHORIZED","message":"token 无效"}}"#.utf8))
        }
        let tokenStore = InMemoryTokenStore()
        try tokenStore.save(AnonymousSession(userID: "user-1", token: "expired"))
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client,
            tokenStore: tokenStore
        )

        let result = waitForResult { api.fetchDeviceInfo(peripheralID: UUID(), completion: $0) }
        guard case .failure(.api(let code, let statusCode, _)) = result else {
            return XCTFail("应保留服务端错误码")
        }
        XCTAssertEqual(code, "UNAUTHORIZED")
        XCTAssertEqual(statusCode, 401)
    }

    func testPushDeviceEncodesDeviceTypeOnlyWhenKnown() throws {
        let base = PushDevice(
            id: "d1",
            platform: "ios",
            externalID: "UUID-1",
            mac: nil,
            alias: .set("设备"),
            group: .set("未分组"),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deleted: false,
            deviceType: "tracker"
        )
        let knownData = try JSONEncoder().encode(base)
        let known = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: knownData) as? [String: Any]
        )
        XCTAssertEqual(known["deviceType"] as? String, "tracker")

        let unknown = PushDevice(
            id: "d2",
            platform: "ios",
            externalID: "UUID-2",
            mac: nil,
            alias: .set("设备"),
            group: .set("未分组"),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deleted: false,
            deviceType: "   "
        )
        let unknownData = try JSONEncoder().encode(unknown)
        let unknownObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: unknownData) as? [String: Any]
        )
        XCTAssertNil(unknownObject["deviceType"], "未知型号不得写入空串或假值")
    }

    func testErrorCodesAreStable() {
        XCTAssertEqual(AppError.network("").code, "NET-001")
        XCTAssertEqual(AppError.configuration("").code, "NET-004")
        XCTAssertEqual(AppError.database("").code, "DB-001")
        XCTAssertEqual(AppError.bluetooth("").code, "BT-004")
    }

    // MARK: - 分页上限（服务端 readings 500 / export 5000 / changes 500）

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    func testChangesLimitIsClampedTo500() {
        let stub = StubHTTPClient(handler: { _ in
            .success(Data(#"{"changes":[],"nextCursor":0,"hasMore":false}"#.utf8))
        })
        let client = SyncAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: stub
        )
        _ = waitForResult {
            client.fetchChanges(cursor: 3, limit: 9_000, token: "token", completion: $0)
        }
        let url = stub.requestedURLs.last
        XCTAssertEqual(queryValue("limit", in: url!), "500")
        XCTAssertEqual(queryValue("cursor", in: url!), "3")
    }

    func testReadingsLimitIsClampedTo500() {
        let stub = StubHTTPClient(handler: { _ in
            .success(Data(#"{"items":[],"hasMore":false}"#.utf8))
        })
        let tokenStore = InMemoryTokenStore()
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        let client = ReadingsAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: stub,
            tokenStore: tokenStore
        )
        _ = waitForResult {
            client.fetchReadings(
                platform: "ios",
                externalID: "UUID-1",
                metric: .temperature,
                limit: 12_345,
                completion: $0
            )
        }
        XCTAssertEqual(queryValue("limit", in: stub.requestedURLs.last!), "500")
    }

    func testExportLimitIsClampedTo5000() {
        let stub = StubHTTPClient(handler: { _ in .success(Data("{}".utf8)) })
        let client = AccountAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: stub
        )
        client.fetchExportPage(cursor: nil, limit: 9_999, token: "token") { _ in }
        XCTAssertEqual(queryValue("limit", in: stub.requestedURLs.last!), "5000")
    }

    func testErrorCatalogMapsResyncTimeoutAndUnauthorized() {
        let resync = AppError.api(code: "RESYNC_REQUIRED", statusCode: 410, message: "gone")
        XCTAssertTrue(resync.isResyncRequired)
        XCTAssertFalse(resync.isRetryable, "410 属终态，不进指数退避")
        XCTAssertEqual(APIErrorCatalog.entry(for: "RESYNC_REQUIRED").handling, .resyncRequired)

        let timeout = AppError.api(code: "TIMEOUT", statusCode: 503, message: "query timeout")
        XCTAssertTrue(timeout.isServerBusy)
        XCTAssertTrue(timeout.isRetryable)
        XCTAssertFalse(timeout.isResyncRequired, "503 不得当作 410")
        XCTAssertEqual(APIErrorCatalog.entry(for: "TIMEOUT").handling, .retryWithBackoff)

        let conflict = AppError.api(code: "IDEMPOTENCY_CONFLICT", statusCode: 409, message: "conflict")
        XCTAssertEqual(APIErrorCatalog.entry(for: "IDEMPOTENCY_CONFLICT").handling, .terminal)
        XCTAssertTrue(conflict.message.contains("幂等键冲突"))

        let unauthorized = AppError.api(code: "UNAUTHORIZED", statusCode: 401, message: "expired")
        XCTAssertTrue(unauthorized.isUnauthorized)
    }
}
