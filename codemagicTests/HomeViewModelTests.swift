import XCTest
@testable import codemagic

final class HomeViewModelTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var bluetooth: FakeBluetoothService!
    private var settingsStore: SettingsStore!
    private var suiteName: String!
    private var savedDeviceStore: SavedDeviceStore!
    private var recentDeviceStore: RecentDeviceStore!
    private var scanLogStore: ScanLogStore!
    private var ruleStore: DeviceRuleStore!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        bluetooth = FakeBluetoothService()
        let settings = makeSettingsStore()
        settingsStore = settings.store
        suiteName = settings.suiteName
        savedDeviceStore = SavedDeviceStore(database: testDatabase.database)
        recentDeviceStore = RecentDeviceStore(database: testDatabase.database)
        scanLogStore = ScanLogStore(database: testDatabase.database)
        ruleStore = DeviceRuleStore(database: testDatabase.database)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        testDatabase?.cleanUp()
        testDatabase = nil
        bluetooth = nil
    }

    private func makeViewModel(staleInterval: TimeInterval = 10) -> HomeViewModel {
        HomeViewModel(
            bluetooth: bluetooth,
            savedDeviceStore: savedDeviceStore,
            recentDeviceStore: recentDeviceStore,
            scanLogStore: scanLogStore,
            ruleStore: ruleStore,
            settingsStore: settingsStore,
            ruleEvaluator: RuleEvaluator(),
            staleInterval: staleInterval
        )
    }

    func testActivateReportsIdleAndDeactivateDoesNotStopWhenIdle() {
        let viewModel = makeViewModel()
        viewModel.activate()

        XCTAssertEqual(viewModel.status, .idle)
        XCTAssertTrue(viewModel.rows.isEmpty)

        viewModel.deactivate()
        XCTAssertEqual(bluetooth.stopScanningCount, 0)
        XCTAssertNil(bluetooth.discoveryHandler)
    }

    func testAutoScanStartsWhenEnabled() {
        settingsStore.autoScanOnLaunch = true
        let viewModel = makeViewModel()
        viewModel.activate()

        XCTAssertEqual(viewModel.status, .scanning)
        XCTAssertEqual(bluetooth.startScanningCount, 1)
        XCTAssertEqual(try? scanLogStore.fetchRecent().count, 1)
    }

    func testStartAndStopScanRecordsLogs() {
        let viewModel = makeViewModel()
        viewModel.activate()
        viewModel.startScan()

        XCTAssertEqual(viewModel.status, .scanning)
        XCTAssertEqual(bluetooth.startScanningCount, 1)

        let deviceID = UUID()
        bluetooth.emitDiscovery(
            makeScannedDevice(peripheralID: deviceID, rssi: -55, lastSeenAt: Date())
        )
        XCTAssertEqual(viewModel.rows.count, 1)
        XCTAssertEqual(viewModel.rows.first?.rssi, -55)

        viewModel.stopScan()
        XCTAssertEqual(viewModel.status, .idle)
        XCTAssertEqual(bluetooth.stopScanningCount, 1)
        XCTAssertEqual(try? scanLogStore.fetchRecent().count, 2)
    }

    func testDiscoveryPersistsRecentDevice() throws {
        let viewModel = makeViewModel()
        viewModel.activate()

        let deviceID = UUID()
        bluetooth.emitDiscovery(
            makeScannedDevice(peripheralID: deviceID, name: "客厅面板", rssi: -52, lastSeenAt: Date())
        )

        XCTAssertEqual(viewModel.rows.count, 1)
        XCTAssertEqual(viewModel.rows.first?.name, "客厅面板")
        XCTAssertFalse(try XCTUnwrap(viewModel.rows.first).isSaved)

        let recents = try recentDeviceStore.fetchAll()
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.peripheralID, deviceID)
        XCTAssertEqual(recents.first?.name, "客厅面板")
    }

    func testSaveDeviceMarksSavedAndPersists() throws {
        let viewModel = makeViewModel()
        viewModel.activate()

        bluetooth.emitDiscovery(
            makeScannedDevice(peripheralID: UUID(), name: "新设备", rssi: -60, lastSeenAt: Date())
        )
        let row = try XCTUnwrap(viewModel.rows.first)
        viewModel.saveDevice(row)

        XCTAssertEqual(try savedDeviceStore.fetchAll().count, 1)
        XCTAssertTrue(viewModel.rows.first?.isSaved == true)
        XCTAssertTrue(try XCTUnwrap(scanLogStore.fetchRecent().first).message.contains("保存设备"))
    }

    func testUnsupportedStateShowsUnavailableAndBlocksScan() {
        bluetooth.state = .unsupported
        let viewModel = makeViewModel()
        viewModel.activate()

        XCTAssertEqual(viewModel.status, .unavailable(.unsupported))
        XCTAssertEqual(viewModel.emptyState.title, "当前环境不支持蓝牙")

        viewModel.startScan()
        XCTAssertEqual(bluetooth.startScanningCount, 0)
        XCTAssertEqual(viewModel.status, .unavailable(.unsupported))
    }

    func testStateChangeToPoweredOffUpdatesStatus() {
        let viewModel = makeViewModel()
        viewModel.activate()
        bluetooth.emitState(.poweredOff)

        XCTAssertEqual(viewModel.status, .unavailable(.poweredOff))
        XCTAssertEqual(viewModel.statusText, "蓝牙已关闭")
    }

    func testDisconnectRuleTriggersWhenDeviceBecomesStale() throws {
        let saved = makeSavedDevice(name: "客厅面板")
        try savedDeviceStore.upsert(saved)
        try ruleStore.upsert(
            DeviceRule(name: "断开提醒", trigger: .disconnect, deviceID: saved.id)
        )

        let viewModel = makeViewModel(staleInterval: 5)
        viewModel.activate()

        let start = Date(timeIntervalSince1970: 1000)
        bluetooth.emitDiscovery(
            makeScannedDevice(peripheralID: saved.peripheralID, name: saved.name, rssi: -50, lastSeenAt: start)
        )
        XCTAssertNil(viewModel.lastRuleEvent)

        // 另一台设备在 20 秒后出现，原设备超过 5 秒窗口未再出现，应判定断开。
        bluetooth.emitDiscovery(
            makeScannedDevice(
                peripheralID: UUID(),
                name: "噪声设备",
                rssi: -70,
                lastSeenAt: start.addingTimeInterval(20)
            )
        )

        let event = try XCTUnwrap(viewModel.lastRuleEvent)
        XCTAssertTrue(event.message.contains("断开提醒"))
        XCTAssertTrue(try XCTUnwrap(scanLogStore.fetchRecent().first).message.contains("消失"))
    }

    func testRSSIRuleTriggersOnceThenRearms() throws {
        let saved = makeSavedDevice(name: "弱信号设备")
        try savedDeviceStore.upsert(saved)
        try ruleStore.upsert(
            DeviceRule(name: "弱信号", trigger: .rssiBelowThreshold, threshold: -70, deviceID: saved.id)
        )

        let viewModel = makeViewModel(staleInterval: 30)
        viewModel.activate()

        let now = Date(timeIntervalSince1970: 2000)
        func emit(_ rssi: Int, offset: TimeInterval) {
            bluetooth.emitDiscovery(
                makeScannedDevice(
                    peripheralID: saved.peripheralID,
                    name: saved.name,
                    rssi: rssi,
                    lastSeenAt: now.addingTimeInterval(offset)
                )
            )
        }

        emit(-85, offset: 0)
        XCTAssertEqual(viewModel.lastRuleEvent?.ruleName, "弱信号")
        XCTAssertEqual(try scanLogStore.fetchRecent().count, 1)

        emit(-60, offset: 1)
        XCTAssertEqual(try scanLogStore.fetchRecent().count, 1)

        emit(-88, offset: 2)
        XCTAssertEqual(try scanLogStore.fetchRecent().count, 2)
    }
}
