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

    /// 模拟 0.3.1 后端：型号列表 + catalog（含固件与配件）。
    private func makeCatalogStub() -> StubHTTPClient {
        StubHTTPClient { url in
            switch url.path {
            case "/api/v1/device-types":
                let json = """
                {"items":[{"type":"tracker","name":"BLE Tracker","vendor":"Nordic Semiconductor",
                  "description":"支持 BLE 5.0","gattServices":[{"uuid":"180F","name":"Battery"}]}]}
                """
                return .success(Data(json.utf8))
            case "/api/v1/device-types/tracker/catalog":
                let json = """
                {"deviceType":{"type":"tracker","name":"BLE Tracker","vendor":"Nordic Semiconductor",
                   "description":"支持 BLE 5.0","gattServices":[{"uuid":"180F","name":"Battery"}]},
                 "firmwares":[{"id":"fw-1","deviceType":"tracker","version":"1.2.3",
                   "releaseNotes":"修复断连重试问题","releasedAt":"2026-10-01T00:00:00Z"}],
                 "accessories":[{"id":"acc-1","deviceType":"tracker","name":"磁吸底座",
                   "sku":"SKU-1","description":"金属底座"}]}
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
        XCTAssertEqual(products.first?.id, "tracker")
        XCTAssertTrue(products.first?.note.contains("支持 BLE 5.0") == true)
        XCTAssertTrue(client.requestedURLs.contains { $0.path == "/api/v1/device-types" })
        XCTAssertTrue(client.requestedURLs.contains { $0.path.hasSuffix("/catalog") })
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
        XCTAssertEqual(items[0].vendor, "Nordic Semiconductor")
        XCTAssertEqual(items[0].compatibility, "BLE Tracker")
        XCTAssertEqual(items[0].summary, "修复断连重试问题")
        XCTAssertEqual(items[1].kind, .accessory)
        XCTAssertEqual(items[1].name, "磁吸底座")
        XCTAssertEqual(items[1].version, "SKU-1")
        XCTAssertTrue(client.requestedURLs.contains { $0.path.hasSuffix("/catalog") })
        XCTAssertFalse(client.requestedURLs.contains { $0.path.contains("/api/market") })
    }

    func testDeviceInfoUsesCompositeKeyAndBearerToken() throws {
        let peripheralID = UUID()
        let recordJSON = """
        {"id":"dev-1","clientId":"ios-client","platform":"ios",
         "externalId":"\(peripheralID.uuidString.lowercased())","mac":"AA:BB:CC:DD:EE:FF",
         "alias":"我的追踪器","group":"客厅","updatedAt":"2026-11-05T00:00:00Z","serverSeq":9}
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
        XCTAssertTrue(catalog.accessories.isEmpty)
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

    func testErrorCodesAreStable() {
        XCTAssertEqual(AppError.network("").code, "NET-001")
        XCTAssertEqual(AppError.configuration("").code, "NET-004")
        XCTAssertEqual(AppError.database("").code, "DB-001")
        XCTAssertEqual(AppError.bluetooth("").code, "BT-004")
    }
}
