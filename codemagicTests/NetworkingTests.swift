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

    func testProductAPIClientBuildsURLAndDecodesList() throws {
        let productJSON = """
        [{"mac":"AA:BB","vendor":"Acme","deviceType":"Panel","firmwareVersion":"1.0",
          "gattServices":[{"uuid":"180F","name":"Battery"}],"compatibility":["X1"]}]
        """
        let client = StubHTTPClient { _ in .success(Data(productJSON.utf8)) }
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchProducts(completion: $0) }
        let products = try XCTUnwrap(try? result.get())

        XCTAssertEqual(products.count, 1)
        XCTAssertFalse(products.isEmpty)
        XCTAssertTrue(client.requestedURLs.first?.absoluteString.contains("/api/products") == true)
    }

    func testProductsEnvelopeFromAndroidMockIsDecoded() throws {
        let json = """
        {
          "mac": "AA:BB:CC:DD:EE:FF",
          "vendor": "Nordic Semiconductor",
          "deviceType": "BLE Tracker",
          "firmwareVersion": "1.2.3",
          "products": [
            {"id":"nrf52840","vendor":"Nordic Semiconductor","model":"nRF52840 Dongle",
             "firmwareVersion":"2.4.1","note":"支持 BLE 5.0",
             "services":[{"uuid":"180F","name":"Battery Service","characteristics":["2A19"]}]}
          ],
          "marketItems": []
        }
        """
        let client = StubHTTPClient { _ in .success(Data(json.utf8)) }
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchProducts(completion: $0) }
        let products = try XCTUnwrap(try? result.get())

        XCTAssertEqual(products.count, 1)
        XCTAssertEqual(products.first?.deviceType, "nRF52840 Dongle")
        XCTAssertEqual(products.first?.gattServices.first?.uuid, "180F")
        XCTAssertEqual(products.first?.gattServices.first?.characteristics, ["2A19"])
        XCTAssertEqual(products.first?.note, "支持 BLE 5.0")
    }

    func testDeviceInfoURLUsesPeripheralIdentifier() throws {
        let peripheralID = UUID()
        let json = """
        {"mac":"AA:BB","vendor":"Acme","deviceType":"Panel","firmwareVersion":"1.0","gattServices":[],"compatibility":[]}
        """
        let client = StubHTTPClient { _ in .success(Data(json.utf8)) }
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchDeviceInfo(peripheralID: peripheralID, completion: $0) }
        _ = try? result.get()

        let requested = try XCTUnwrap(client.requestedURLs.first)
        XCTAssertTrue(requested.absoluteString.contains("/api/device/"))
        XCTAssertTrue(requested.absoluteString.contains(peripheralID.uuidString))
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

    func testMarketItemClientDecoding() throws {
        let json = """
        [{"id":"acc-1","kind":"accessory","name":"磁吸底座","vendor":"Acme","version":"",
          "compatibility":"X1 / X2","summary":"信息展示"}]
        """
        let client = StubHTTPClient { _ in .success(Data(json.utf8)) }
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchMarketItems(completion: $0) }
        let items = try XCTUnwrap(try? result.get())
        XCTAssertEqual(items.first?.kind, .accessory)
        XCTAssertEqual(items.first?.compatibility, "X1 / X2")
        XCTAssertTrue(client.requestedURLs.first?.absoluteString.contains("/api/market") == true)
    }

    func testMarketEnvelopeFromAndroidMockIsDecoded() throws {
        let json = """
        {
          "marketItems": [
            {"id":"fw-1","title":"BLE Tracker 固件","category":"固件版本","version":"1.2.3",
             "compatibility":"适用于 AA:BB:CC 前缀","description":"修复了断连重试问题"},
            {"id":"acc-1","title":"nRF52840 USB Dongle","category":"调试配件","version":"2.4.1",
             "compatibility":"支持 nRF52 系列","description":"用于固件烧录"}
          ]
        }
        """
        let client = StubHTTPClient { _ in .success(Data(json.utf8)) }
        let api = ProductAPIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            httpClient: client
        )

        let result = waitForResult { api.fetchMarketItems(completion: $0) }
        let items = try XCTUnwrap(try? result.get())

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].kind, .firmware)
        XCTAssertEqual(items[0].name, "BLE Tracker 固件")
        XCTAssertEqual(items[0].summary, "修复了断连重试问题")
        XCTAssertEqual(items[1].kind, .accessory)
        XCTAssertEqual(items[1].name, "nRF52840 USB Dongle")
    }

    func testErrorCodesAreStable() {
        XCTAssertEqual(AppError.network("").code, "NET-001")
        XCTAssertEqual(AppError.configuration("").code, "NET-004")
        XCTAssertEqual(AppError.database("").code, "DB-001")
        XCTAssertEqual(AppError.bluetooth("").code, "BT-004")
    }
}
