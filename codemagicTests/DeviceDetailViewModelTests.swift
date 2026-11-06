import XCTest
@testable import codemagic

final class DeviceDetailViewModelTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var bluetooth: FakeBluetoothService!
    private var productService: StubProductService!
    private var cacheStore: DeviceInfoCacheStore!
    private var savedDeviceStore: SavedDeviceStore!
    private var readingsStore: ReadingsStore!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        bluetooth = FakeBluetoothService()
        productService = StubProductService()
        cacheStore = DeviceInfoCacheStore(database: testDatabase.database)
        savedDeviceStore = SavedDeviceStore(database: testDatabase.database)
        readingsStore = ReadingsStore(database: testDatabase.database)
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
            savedDeviceStore: savedDeviceStore,
            readingsStore: readingsStore
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

    func testCloudDeviceTypePersistsForPush() throws {
        let device = makeSavedDevice(name: "面板")
        let product = ProductModel(
            mac: "",
            vendor: "厂商乙",
            deviceType: "tracker",
            firmwareVersion: "1.2.3",
            gattServices: [],
            compatibility: ["平台：ios"],
            note: ""
        )
        productService.deviceInfoResult = .success(product)
        let viewModel = try makeViewModel(device: device)
        viewModel.start()
        bluetooth.emitConnection(.connected(peripheralID: device.peripheralID))

        let saved = try XCTUnwrap(savedDeviceStore.fetch(peripheralID: device.peripheralID))
        XCTAssertEqual(saved.deviceType, "tracker", "云端 deviceType 应落库")
        XCTAssertEqual(saved.vendor, "厂商乙")
        XCTAssertEqual(PushDevice(device: saved).deviceType, "tracker", "已知型号时推送带上 deviceType")
    }

    func testNullDeviceFieldsAreNotPersistedOrPushed() throws {
        let device = makeSavedDevice(name: "未知型号设备")
        let product = ProductModel(
            mac: "",
            vendor: "",
            deviceType: "",
            firmwareVersion: "",
            gattServices: [],
            compatibility: [],
            note: ""
        )
        productService.deviceInfoResult = .success(product)
        let viewModel = try makeViewModel(device: device)
        viewModel.start()
        bluetooth.emitConnection(.connected(peripheralID: device.peripheralID))

        let saved = try XCTUnwrap(savedDeviceStore.fetch(peripheralID: device.peripheralID))
        XCTAssertNil(saved.deviceType, "null 型号保持为空，不写假值")
        XCTAssertNil(PushDevice(device: saved).deviceType, "未知型号不传 deviceType")
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

        guard case .loaded = viewModel.state else {
            return XCTFail("应加载成功")
        }
        XCTAssertFalse(viewModel.showSampleItems, "示例条目默认隐藏")
        viewModel.setShowSampleItems(true)
        let items = viewModel.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .firmware)
    }

    func testMarketFailure() {
        let service = StubProductService()
        service.productsResult = .failure(.decoding("bad json"))
        let viewModel = MarketViewModel(productService: service)
        viewModel.loadIfNeeded()

        guard case .failed(let error) = viewModel.state else {
            return XCTFail("型号目录失败应进入错误态")
        }
        XCTAssertEqual(error.code, "NET-003")
    }

    /// 示例条目接口失败只降级该区块，不拖垮兼容性查询。
    func testMarketItemsFailureDegradesWithoutFailingCatalog() {
        let service = StubProductService()
        service.productsResult = .success([makeProduct()])
        service.marketResult = .failure(.network("offline"))
        let viewModel = MarketViewModel(productService: service)
        viewModel.loadIfNeeded()

        guard case .loaded = viewModel.state else {
            return XCTFail("型号目录成功时整体应加载成功")
        }
        XCTAssertEqual(viewModel.profiles.count, 1)
        XCTAssertEqual(viewModel.marketItemsError?.code, "NET-001")
        XCTAssertTrue(viewModel.sampleItems.isEmpty)
    }

    func testMarketFiltersByVendorAndCompatibility() {
        let service = StubProductService()
        service.marketResult = .success([
            MarketItem(
                id: "fw-1", kind: .firmware, name: "固件 1.0", vendor: "Acme",
                version: "1.0", compatibility: "平台：ios；协议：ble-gatt",
                compatibilityTags: ["平台：ios", "协议：ble-gatt"], summary: ""
            ),
            MarketItem(
                id: "fw-2", kind: .firmware, name: "固件 2.0", vendor: "Acme",
                version: "2.0", compatibility: "平台：android",
                compatibilityTags: ["平台：android"], summary: ""
            ),
            MarketItem(
                id: "acc-1", kind: .accessory, name: "底座", vendor: "Other",
                version: "SKU-1", compatibility: "", summary: ""
            ),
        ])
        let viewModel = MarketViewModel(productService: service)
        viewModel.loadIfNeeded()
        viewModel.setShowSampleItems(true)
        XCTAssertEqual(viewModel.items.count, 3)
        XCTAssertEqual(viewModel.vendors, ["Acme", "Other"])
        XCTAssertEqual(
            Set(viewModel.compatibilityOptions),
            Set(["平台：android", "平台：ios", "协议：ble-gatt"])
        )

        viewModel.selectVendor("Acme")
        XCTAssertEqual(viewModel.items.count, 2)
        XCTAssertTrue(viewModel.hasActiveFilter)

        viewModel.selectCompatibility("平台：ios")
        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.items.first?.id, "fw-1")

        viewModel.selectVendor("Other")
        XCTAssertTrue(viewModel.items.isEmpty, "筛选组合无结果时为空列表而非错误")

        viewModel.resetFilters()
        XCTAssertEqual(viewModel.items.count, 3)
        XCTAssertFalse(viewModel.hasActiveFilter)
    }
}
