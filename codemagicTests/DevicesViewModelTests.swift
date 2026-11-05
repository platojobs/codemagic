import XCTest
@testable import codemagic

/// 设备列表可用性：搜索、排序持久化、分组筛选与两种空状态。
final class DevicesViewModelTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var savedDeviceStore: SavedDeviceStore!
    private var ruleStore: DeviceRuleStore!
    private var recentDeviceStore: RecentDeviceStore!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var viewModel: DevicesViewModel!

    private let alphaID = UUID()
    private let betaID = UUID()
    private let gammaID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        savedDeviceStore = SavedDeviceStore(database: testDatabase.database)
        ruleStore = DeviceRuleStore(database: testDatabase.database)
        recentDeviceStore = RecentDeviceStore(database: testDatabase.database)
        suiteName = "devices-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = SettingsStore(defaults: defaults)
        viewModel = DevicesViewModel(
            savedDeviceStore: savedDeviceStore,
            ruleStore: ruleStore,
            recentDeviceStore: recentDeviceStore,
            settingsStore: settings
        )

        let now = Date()
        try savedDeviceStore.upsert(SavedDevice(
            peripheralID: alphaID,
            externalID: alphaID.uuidString,
            advertisedName: "Alpha Sensor",
            remark: "Alpha Room",
            groupName: "客厅",
            deviceType: "TH-01",
            lastSeenAt: now.addingTimeInterval(-600),
            createdAt: now.addingTimeInterval(-86_400)
        ))
        try savedDeviceStore.upsert(SavedDevice(
            peripheralID: betaID,
            externalID: betaID.uuidString,
            advertisedName: "Beta Plug",
            groupName: SavedDevice.defaultGroupName,
            deviceType: "PL-01",
            lastSeenAt: now,
            createdAt: now.addingTimeInterval(-7_200)
        ))
        try savedDeviceStore.upsert(SavedDevice(
            peripheralID: gammaID,
            externalID: gammaID.uuidString,
            advertisedName: "Gamma Light",
            groupName: "卧室",
            deviceType: "LT-01",
            lastSeenAt: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-3_600)
        ))
        viewModel.reload()
    }

    override func tearDownWithError() throws {
        if let defaults, let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        testDatabase?.cleanUp()
        testDatabase = nil
        try super.tearDownWithError()
    }

    func testDefaultSortIsMostRecentAndPersists() throws {
        XCTAssertEqual(viewModel.sort, .recent)
        XCTAssertEqual(viewModel.filteredDevices.map(\.peripheralID), [betaID, alphaID, gammaID])

        viewModel.updateSort(.name)
        XCTAssertEqual(viewModel.sort, .name)
        XCTAssertEqual(viewModel.filteredDevices.map(\.displayName), ["Alpha Room", "Beta Plug", "Gamma Light"])
        XCTAssertEqual(settings.deviceSort, .name, "排序方式持久化")
    }

    func testSearchMatchesAliasBroadcastNameModelAndIdentifierCaseInsensitively() {
        viewModel.updateSearch("beta plug")
        XCTAssertEqual(viewModel.filteredDevices.map(\.peripheralID), [betaID])

        viewModel.updateSearch("TH-01")
        XCTAssertEqual(viewModel.filteredDevices.map(\.peripheralID), [alphaID])

        viewModel.updateSearch("alpha room")
        XCTAssertEqual(viewModel.filteredDevices.map(\.peripheralID), [alphaID])

        viewModel.updateSearch(betaID.uuidString.uppercased())
        XCTAssertEqual(viewModel.filteredDevices.map(\.peripheralID), [betaID])
    }

    func testGroupFilterIncludesRealValuesAndUngrouped() {
        XCTAssertEqual(Set(viewModel.availableGroups), Set(["卧室", "客厅", "未分组"]))
        viewModel.updateGroupFilter(SavedDevice.defaultGroupName)
        XCTAssertEqual(viewModel.filteredDevices.map(\.peripheralID), [betaID])

        viewModel.updateGroupFilter("客厅")
        XCTAssertEqual(viewModel.filteredDevices.map(\.peripheralID), [alphaID])

        viewModel.updateGroupFilter(nil)
        XCTAssertEqual(viewModel.filteredDevices.count, 3)
    }

    func testSignalSortUsesLatestRSSI() throws {
        try recentDeviceStore.upsert(peripheralID: alphaID, name: "Alpha", rssi: -90, lastSeenAt: Date())
        try recentDeviceStore.upsert(peripheralID: betaID, name: "Beta", rssi: -50, lastSeenAt: Date())
        viewModel.reload()
        viewModel.updateSort(.signal)
        XCTAssertEqual(viewModel.filteredDevices.map(\.peripheralID), [betaID, alphaID, gammaID], "信号强的在前，未知信号最后")
    }

    func testAddedAtSortNewestFirst() {
        viewModel.updateSort(.addedAt)
        XCTAssertEqual(viewModel.filteredDevices.map(\.peripheralID), [gammaID, betaID, alphaID])
    }

    func testTwoEmptyStates() throws {
        XCTAssertEqual(viewModel.emptyStateText, "没有匹配的设备，试试修改搜索词或切换分组。")
        viewModel.updateSearch("不存在的设备")
        XCTAssertTrue(viewModel.filteredDevices.isEmpty)
        XCTAssertEqual(viewModel.emptyStateText, "没有匹配的设备，试试修改搜索词或切换分组。")

        for device in try savedDeviceStore.fetchAll() {
            try savedDeviceStore.softDelete(id: device.id)
        }
        viewModel.reload()
        XCTAssertTrue(viewModel.filteredDevices.isEmpty)
        XCTAssertTrue(viewModel.emptyStateText.hasPrefix("还没有保存的设备"))
    }
}
