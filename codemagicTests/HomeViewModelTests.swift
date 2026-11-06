import UIKit
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
            makeScannedDevice(peripheralID: saved.peripheralID, name: saved.advertisedName, rssi: -50, lastSeenAt: start)
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
                    name: saved.advertisedName,
                    rssi: rssi,
                    lastSeenAt: now.addingTimeInterval(offset)
                )
            )
        }

        emit(-85, offset: 0)
        XCTAssertEqual(viewModel.lastRuleEvent?.ruleName, "弱信号")
        XCTAssertEqual(try scanLogStore.fetchRecent().count, 1)

        emit(-60, offset: 1)
        XCTAssertEqual(try scanLogStore.fetchRecent().count, 2, "恢复也写一条扫描日志")
        XCTAssertEqual(viewModel.lastRuleEvent?.kind, .recovered)

        emit(-88, offset: 2)
        XCTAssertEqual(try scanLogStore.fetchRecent().count, 3, "恢复后重新武装，可再次告警")
    }
}

/// 首页布局与家庭管理房间分区的回归：名称 / 状态分行、分区头复用、底部留白、房间行数。
final class HomeLayoutTests: XCTestCase {
    /// 名称过长时最多两行，状态词必须完整可见，不再和名称挤在同一行被省略号吃掉。
    func testDeviceCardShowsFullStatusUnderLongName() {
        let cell = DeviceCardCell(frame: CGRect(x: 0, y: 0, width: 179, height: 164))
        let device = SavedDevice(
            peripheralID: UUID(),
            advertisedName: "客厅环境传感器",
            remark: "客厅环境传感器一号机"
        )
        cell.configure(device: device, isConnected: false, readingText: "电量 66 %", rssi: -70, onTap: {})
        cell.layoutIfNeeded()
        cell.contentView.layoutIfNeeded()

        let nameLabel = firstLabel(in: cell, text: device.displayName)
        XCTAssertNotNil(nameLabel, "找到设备名标签")
        XCTAssertEqual(nameLabel?.numberOfLines, 2, "设备名最多两行")

        guard let statusLabel = firstLabel(in: cell, text: L10n.t("home.status.disconnected")) else {
            return XCTFail("找到状态标签")
        }
        XCTAssertGreaterThan(statusLabel.bounds.height, 0)
        XCTAssertGreaterThanOrEqual(
            statusLabel.bounds.width,
            statusLabel.intrinsicContentSize.width - 0.5,
            "状态独占一行后不应被截断"
        )
    }

    /// 分区头复用时会替换旧头视图，不能把上一个分区的标题叠在下面。
    func testHomeSectionHeaderReplacesPreviousTitleWhenReused() {
        let header = HomeSectionHeaderView(frame: CGRect(x: 0, y: 0, width: 370, height: 40))
        header.configure(title: "快捷场景")
        header.configure(title: "书房 · 2", collapsed: false, onToggle: {})
        let headers = header.subviews.compactMap { $0 as? SectionHeaderView }
        XCTAssertEqual(headers.count, 1, "复用后只保留一个分区头")
    }

    /// 悬浮 Tab 的重叠量要扣掉滚动视图已自动获得的 safe-area 补偿，只补差额。
    func testBottomOcclusionDeductsAutomaticInset() {
        XCTAssertEqual(BottomOcclusion.inset(overlap: 83, automaticInset: 83, spacing: 24), 24)
        XCTAssertEqual(BottomOcclusion.inset(overlap: 83, automaticInset: 34, spacing: 24), 73)
        XCTAssertEqual(BottomOcclusion.inset(overlap: -10, automaticInset: 0, spacing: 24), 24)
        XCTAssertEqual(BottomOcclusion.inset(overlap: 83, automaticInset: 100, spacing: 24), 24)
        XCTAssertEqual(BottomOcclusion.inset(overlap: 0, automaticInset: 0, spacing: 0), 0)
    }

    /// 底部条带从 Tab 顶边覆盖到屏幕底边，高度含底部安全区；越界时收敛到 0 / 整屏。
    func testBottomBandCoversTabTopToScreenBottom() {
        let screen = CGSize(width: 402, height: 874)
        let frame = BottomBand.frame(containerSize: screen, barTop: 791)
        XCTAssertEqual(frame.minY, 791)
        XCTAssertEqual(frame.height, 83, "条带高度 = 屏幕底边 - Tab 顶边（含 home indicator 安全区）")
        XCTAssertEqual(frame.width, 402)
        XCTAssertEqual(frame.maxY, 874)

        XCTAssertEqual(BottomBand.frame(containerSize: screen, barTop: 874).height, 0)
        XCTAssertEqual(BottomBand.frame(containerSize: screen, barTop: 900).height, 0, "顶边越界不再产生负高度")
        XCTAssertEqual(BottomBand.frame(containerSize: screen, barTop: -10).height, 874, "顶边越界收敛到 0")
        XCTAssertEqual(BottomBand.frame(containerSize: .zero, barTop: 0).height, 0)
    }

    /// 家庭房间分区只统计真实房间；「管理」入口移到分区头，不再占一行。
    func testHouseholdRoomSectionCountsOnlyRealRooms() {
        XCTAssertEqual(HouseholdRoomSection.rowCount(roomCount: 3), 3)
        XCTAssertEqual(HouseholdRoomSection.rowCount(roomCount: 0), 0)
    }

    /// 房间分区头的「管理」入口能触发房间管理，且带有稳定的无障碍标识。
    func testRoomsHeaderManageEntryTriggersManagement() {
        let header = RoomsSectionHeaderView(frame: CGRect(x: 0, y: 0, width: 370, height: 44))
        var triggered = false
        header.onManage = { triggered = true }
        header.layoutIfNeeded()

        guard let button = firstButton(in: header, identifier: "household.rooms.manage") else {
            return XCTFail("找到管理入口")
        }
        XCTAssertEqual(button.title(for: .normal) ?? button.configuration?.title, L10n.t("household.rooms.manage"))
        XCTAssertGreaterThanOrEqual(button.bounds.height, Layout.touchMin - 0.5, "管理入口满足触达高度")
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(triggered)
    }

    private func firstLabel(in view: UIView, text: String) -> UILabel? {
        if let label = view as? UILabel, label.text == text { return label }
        for subview in view.subviews {
            if let found = firstLabel(in: subview, text: text) { return found }
        }
        return nil
    }

    private func firstButton(in view: UIView, identifier: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        for subview in view.subviews {
            if let found = firstButton(in: subview, identifier: identifier) { return found }
        }
        return nil
    }
}
