import XCTest
@testable import codemagic

final class DeviceDetailViewModelTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var bluetooth: FakeBluetoothService!
    private var productService: StubProductService!
    private var cacheStore: DeviceInfoCacheStore!
    private var savedDeviceStore: SavedDeviceStore!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        bluetooth = FakeBluetoothService()
        productService = StubProductService()
        cacheStore = DeviceInfoCacheStore(database: testDatabase.database)
        savedDeviceStore = SavedDeviceStore(database: testDatabase.database)
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        testDatabase = nil
    }

    private func makeViewModel(device: SavedDevice) throws -> DeviceDetailViewModel {
        try savedDeviceStore.upsert(device)
        return DeviceDetailViewModel(
            device: device,
            bluetooth: bluetooth,
            productService: productService,
            cacheStore: cacheStore,
            savedDeviceStore: savedDeviceStore
        )
    }

    func testConnectedThenNetworkSuccessUpdatesCacheAndDevice() throws {
        let device = makeSavedDevice(name: "面板")
        let viewModel = try makeViewModel(device: device)
        let product = makeProduct(vendor: "厂商甲", firmwareVersion: "2.3.1")
        productService.deviceInfoResult = .success(product)

        viewModel.start()
        XCTAssertEqual(bluetooth.connectedPeripheralIDs, [device.peripheralID])
        XCTAssertEqual(viewModel.state, .connecting)

        bluetooth.emitConnection(.connected(peripheralID: device.peripheralID))

        guard case .loaded(let loaded) = viewModel.state else {
            return XCTFail("应加载成功，实际为 \(viewModel.state)")
        }
        XCTAssertEqual(loaded.vendor, "厂商甲")
        XCTAssertEqual(loaded.firmwareVersion, "2.3.1")
        XCTAssertEqual(productService.deviceInfoRequestIDs, [device.peripheralID])

        let cache = try XCTUnwrap(cacheStore.fetch(peripheralID: device.peripheralID))
        XCTAssertEqual(cache.product.vendor, "厂商甲")

        let saved = try XCTUnwrap(savedDeviceStore.fetch(peripheralID: device.peripheralID))
        XCTAssertEqual(saved.vendor, "厂商甲")
        XCTAssertEqual(saved.firmwareVersion, "2.3.1")
        XCTAssertEqual(saved.syncState, .pending)
    }

    func testNetworkFailureFallsBackToLocalCache() throws {
        let device = makeSavedDevice()
        let cachedProduct = makeProduct(vendor: "缓存厂商", firmwareVersion: "0.9.0")
        try cacheStore.save(
            product: cachedProduct,
            peripheralID: device.peripheralID,
            fetchedAt: Date(timeIntervalSince1970: 5000)
        )
        productService.deviceInfoResult = .failure(.network("断网"))

        bluetooth.state = .poweredOff
        let viewModel = try makeViewModel(device: device)
        viewModel.start()

        guard case .cache(let product, let fetchedAt, let error) = viewModel.state else {
            return XCTFail("应命中缓存，实际为 \(viewModel.state)")
        }
        XCTAssertEqual(product.vendor, "缓存厂商")
        XCTAssertEqual(fetchedAt.timeIntervalSince1970, 5000)
        XCTAssertEqual(error.code, "NET-001")
        XCTAssertEqual(viewModel.product?.firmwareVersion, "0.9.0")
        XCTAssertTrue(viewModel.statusText.contains("本地缓存"))
    }

    func testNetworkFailureWithoutCacheShowsErrorState() throws {
        let device = makeSavedDevice()
        productService.deviceInfoResult = .failure(.server(statusCode: 503))
        bluetooth.state = .poweredOff

        let viewModel = try makeViewModel(device: device)
        viewModel.start()

        XCTAssertEqual(viewModel.state, .failed(.server(statusCode: 503)))
        XCTAssertNil(viewModel.product)
        XCTAssertTrue(viewModel.statusText.contains("NET-002"))
    }

    func testTeardownDisconnectsPeripheral() throws {
        let device = makeSavedDevice()
        let viewModel = try makeViewModel(device: device)
        viewModel.start()
        viewModel.teardown()

        XCTAssertEqual(bluetooth.disconnectedPeripheralIDs, [device.peripheralID])
        XCTAssertNil(bluetooth.connectionHandler)
    }

    func testAndroidDeviceSkipsBluetoothAndShowsUnavailableNotice() throws {
        var device = makeSavedDevice(name: "安卓同步设备")
        device.platform = "android"
        device.externalID = "AA:BB:CC:DD:EE:01"
        let viewModel = try makeViewModel(device: device)

        viewModel.start()

        XCTAssertTrue(bluetooth.connectedPeripheralIDs.isEmpty)
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(viewModel.notice, "来自 Android，本机不可连接")
        XCTAssertEqual(device.isConnectable, false)
        XCTAssertNil(makeSavedDevice().connectUnavailableText)
    }

    func testBluetoothUnavailableStillReadsNetwork() throws {
        let device = makeSavedDevice()
        productService.deviceInfoResult = .success(makeProduct(vendor: "云端厂商"))
        bluetooth.state = .unsupported

        let viewModel = try makeViewModel(device: device)
        viewModel.start()

        XCTAssertEqual(viewModel.notice?.contains("蓝牙不可用"), true)
        guard case .loaded(let product) = viewModel.state else {
            return XCTFail("应直接读取云端，实际为 \(viewModel.state)")
        }
        XCTAssertEqual(product.vendor, "云端厂商")
    }
}

final class ProductsAndMarketViewModelTests: XCTestCase {
    func testProductsLoadedFromNetwork() {
        let service = StubProductService()
        service.productsResult = .success([makeProduct(), makeProduct(mac: "M2", deviceType: "Sensor")])
        let viewModel = ProductsViewModel(productService: service)
        viewModel.loadIfNeeded()

        guard case .loaded(let products) = viewModel.state else {
            return XCTFail("应加载成功")
        }
        XCTAssertEqual(products.count, 2)
        XCTAssertEqual(viewModel.products.first?.deviceType, "Panel")
    }

    func testProductsFailureKeepsErrorState() {
        let service = StubProductService()
        service.productsResult = .failure(.network("offline"))
        let viewModel = ProductsViewModel(productService: service)
        viewModel.loadIfNeeded()

        guard case .failed(let error) = viewModel.state else {
            return XCTFail("应加载失败")
        }
        XCTAssertEqual(error.code, "NET-001")
        XCTAssertTrue(viewModel.products.isEmpty)
    }

    func testProductsReloadIssuesRequestAgain() {
        let service = StubProductService()
        service.productsResult = .success([makeProduct()])
        let viewModel = ProductsViewModel(productService: service)
        viewModel.loadIfNeeded()
        viewModel.reload()

        XCTAssertEqual(service.productsResult, .success([makeProduct()]))
        XCTAssertEqual(viewModel.products.count, 1)
    }

    func testMarketLoadedAndEmptyState() {
        let service = StubProductService()
        service.marketResult = .success([
            MarketItem(
                id: "1",
                kind: .firmware,
                name: "固件 2.0",
                vendor: "Acme",
                version: "2.0",
                compatibility: "X1",
                summary: "说明"
            )
        ])
        let viewModel = MarketViewModel(productService: service)
        viewModel.loadIfNeeded()

        guard case .loaded(let items) = viewModel.state else {
            return XCTFail("应加载成功")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .firmware)
    }

    func testMarketFailure() {
        let service = StubProductService()
        service.marketResult = .failure(.decoding("bad json"))
        let viewModel = MarketViewModel(productService: service)
        viewModel.loadIfNeeded()

        guard case .failed(let error) = viewModel.state else {
            return XCTFail("应加载失败")
        }
        XCTAssertEqual(error.code, "NET-003")
    }
}
