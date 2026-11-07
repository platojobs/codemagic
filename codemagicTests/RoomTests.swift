import SQLite3
import XCTest
import UserNotifications
@testable import codemagic

/// 房间：v7→v8 迁移、CRUD、删除房间后设备落点，以及首页房间分区顺序 / 搜索取舍。
final class RoomTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var database: SQLiteDatabase!
    private var deviceStore: SavedDeviceStore!
    private var roomStore: RoomStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        database = testDatabase.database
        deviceStore = SavedDeviceStore(database: database)
        roomStore = RoomStore(database: database)
    }

    override func tearDown() {
        testDatabase?.cleanUp()
        testDatabase = nil
        super.tearDown()
    }

    // MARK: - 迁移

    func testMigrationFromV7KeepsDevicesAndAddsRoomsAndRoomColumn() throws {
        let path = testDatabase.directory.appendingPathComponent("legacy-v7.sqlite").path
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        XCTAssertNotNil(handle)
        let legacySQL = """
        CREATE TABLE saved_devices (
            id TEXT PRIMARY KEY NOT NULL,
            peripheral_id TEXT NOT NULL,
            platform TEXT NOT NULL,
            external_id TEXT NOT NULL,
            name TEXT NOT NULL,
            advertised_name TEXT,
            remark TEXT NOT NULL,
            group_name TEXT NOT NULL,
            mac TEXT,
            vendor TEXT,
            device_type TEXT,
            firmware_version TEXT,
            last_seen_at REAL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            sync_state TEXT NOT NULL,
            alias_patch TEXT,
            advertised_name_patch TEXT,
            group_patch TEXT
        );
        INSERT INTO saved_devices
        (id, peripheral_id, platform, external_id, name, advertised_name, remark, group_name,
         created_at, updated_at, sync_state)
        VALUES ('11111111-1111-1111-1111-111111111111',
                '22222222-2222-2222-2222-222222222222',
                'ble', 'ext-1', '旧设备', '旧设备', '', '客厅',
                700000000, 700000000, 'synced');
        PRAGMA user_version = 7;
        """
        XCTAssertEqual(sqlite3_exec(handle, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let migrated = try SQLiteDatabase(path: path)
        defer { migrated.close() }

        let version = try migrated.query("PRAGMA user_version;").first?.integer("user_version")
        XCTAssertEqual(version, 18)

        let roomColumns = try migrated.query("PRAGMA table_info(rooms);").compactMap { $0.text("name") }
        XCTAssertEqual(
            Set(roomColumns),
            [
                "id", "name", "sort_order", "remote_id", "created_at", "updated_at",
                "household_id", "sync_state", "deleted",
            ]
        )

        let deviceColumns = try migrated.query("PRAGMA table_info(saved_devices);").compactMap { $0.text("name") }
        XCTAssertTrue(deviceColumns.contains("room_id"))
        XCTAssertTrue(deviceColumns.contains("household_id"))
        XCTAssertTrue(deviceColumns.contains("remote_room_id"))
        XCTAssertTrue(deviceColumns.contains("remote_household_id"))
        XCTAssertTrue(try migrated.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'households';").count == 1)
        XCTAssertTrue(try migrated.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'device_assignment_pending';"
        ).count == 1)

        let devices = try SavedDeviceStore(database: migrated).fetchAll()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.remark, "")
        XCTAssertEqual(devices.first?.groupName, "客厅", "旧分组字段作为兼容字段保留")
        XCTAssertNil(devices.first?.roomID, "旧设备迁移后为未分配")
    }

    // MARK: - CRUD

    func testCreateRenameAndSortOrder() throws {
        let first = try roomStore.create(name: "客厅")
        let second = try roomStore.create(name: "卧室")
        XCTAssertEqual(first.sortOrder, 1)
        XCTAssertEqual(second.sortOrder, 2)

        try roomStore.rename(id: first.id, name: "起居室")
        let rooms = try roomStore.fetchAll()
        XCTAssertEqual(rooms.map(\.name), ["起居室", "卧室"])
        XCTAssertEqual(rooms.first?.remoteID, nil, "本地房间预留远端映射字段")
    }

    func testDeleteRoomMovesDevicesToUnassigned() throws {
        let living = try roomStore.create(name: "客厅")
        let bedroom = try roomStore.create(name: "卧室")
        let a = makeSavedDevice(name: "温度计A")
        let b = makeSavedDevice(name: "温度计B")
        let c = makeSavedDevice(name: "面板C")
        for device in [a, b, c] {
            try deviceStore.upsert(device)
        }
        try deviceStore.setRoom(id: a.id, roomID: living.id)
        try deviceStore.setRoom(id: b.id, roomID: living.id)
        try deviceStore.setRoom(id: c.id, roomID: bedroom.id)

        XCTAssertEqual(try roomStore.deviceCounts()[living.id], 2)

        try roomStore.delete(id: living.id, deviceStore: deviceStore)

        let devices = try deviceStore.fetchAll()
        XCTAssertEqual(devices.count, 3, "删除房间不删除设备")
        XCTAssertNil(devices.first { $0.id == a.id }?.roomID)
        XCTAssertNil(devices.first { $0.id == b.id }?.roomID)
        XCTAssertEqual(devices.first { $0.id == c.id }?.roomID, bedroom.id)
        XCTAssertEqual(try roomStore.fetchAll().map(\.name), ["卧室"])
    }

    func testRoomAssignmentSurvivesDeviceUpsert() throws {
        let room = try roomStore.create(name: "客厅")
        let device = makeSavedDevice(name: "温度计")
        try deviceStore.upsert(device)
        try deviceStore.setRoom(id: device.id, roomID: room.id)

        var reloaded = try XCTUnwrap(try deviceStore.fetch(id: device.id))
        reloaded.remark = "新备注"
        try deviceStore.upsert(reloaded)

        XCTAssertEqual(try deviceStore.fetch(id: device.id)?.roomID, room.id)
        XCTAssertEqual(try deviceStore.fetch(id: device.id)?.remark, "新备注")
    }

    // MARK: - 首页分区

    func testRoomSectionsKeepUnassignedLastAndSortInsideRoom() throws {
        let living = try roomStore.create(name: "客厅")
        let bedroom = try roomStore.create(name: "卧室")
        let thermometer = makeSavedDevice(name: "温度计", remark: "温度计")
        let panel = makeSavedDevice(name: "面板", remark: "面板")
        let stray = makeSavedDevice(name: "未分配设备", remark: "未分配设备")
        for device in [thermometer, panel, stray] {
            try deviceStore.upsert(device)
        }
        try deviceStore.setRoom(id: thermometer.id, roomID: living.id)
        try deviceStore.setRoom(id: panel.id, roomID: bedroom.id)

        let viewModel = try makeViewModel()
        viewModel.reload()

        let sections = viewModel.roomSections
        XCTAssertEqual(sections.map(\.title), ["客厅", "卧室", L10n.t("room.unassigned")])
        XCTAssertEqual(sections.last?.isUnassigned, true)
        XCTAssertEqual(sections[0].devices.map(\.id), [thermometer.id])
    }

    func testSearchHidesEmptyRoomsButKeepsMatches() throws {
        let living = try roomStore.create(name: "客厅")
        let bedroom = try roomStore.create(name: "卧室")
        let thermometer = makeSavedDevice(name: "温度计", remark: "温度计")
        try deviceStore.upsert(thermometer)
        try deviceStore.setRoom(id: thermometer.id, roomID: living.id)

        let viewModel = try makeViewModel()
        viewModel.reload()
        XCTAssertEqual(viewModel.roomSections.map(\.title), ["客厅", "卧室"])

        viewModel.updateSearch("温度")
        XCTAssertEqual(viewModel.roomSections.map(\.title), ["客厅"])
        XCTAssertEqual(viewModel.roomSections.first?.devices.count, 1)

        viewModel.updateSearch("面板")
        XCTAssertTrue(viewModel.roomSections.isEmpty)
        XCTAssertTrue(viewModel.hasActiveFilter)
    }

    func testUnassignedSectionAppearsWhenDeviceHasNoRoom() throws {
        let room = try roomStore.create(name: "客厅")
        let device = makeSavedDevice(name: "面板")
        try deviceStore.upsert(device)

        let viewModel = try makeViewModel()
        viewModel.reload()

        XCTAssertEqual(viewModel.roomSections.map(\.title), ["客厅", L10n.t("room.unassigned")])
        XCTAssertEqual(viewModel.roomSections.last?.devices.map(\.id), [device.id])
        XCTAssertEqual(viewModel.roomName(for: device), L10n.t("room.unassigned"))

        try deviceStore.setRoom(id: device.id, roomID: room.id)
        viewModel.reload()
        let moved = try XCTUnwrap(viewModel.devices.first { $0.id == device.id })
        XCTAssertEqual(viewModel.roomSections.map(\.title), ["客厅"])
        XCTAssertEqual(viewModel.roomName(for: moved), "客厅")
    }

    // MARK: - 云端读数

    func testHomeCardUsesCloudReadingWhenLocalMissing() throws {
        let device = makeSavedDevice(name: "客厅温湿度计")
        var remote = device
        remote.platform = "android"
        remote.externalID = "AA:BB:CC:00:00:01"
        remote.serverLastSeenAt = Date()
        try deviceStore.upsert(remote)
        let cloud = FakeCloudReadings()
        cloud.states["android:\(remote.externalID)"] = .available(CloudLatestReading(
            metric: .temperature,
            rawMetric: "temperature_celsius",
            value: 24.5,
            unit: "celsius",
            reportedAt: Date(timeIntervalSince1970: 1_799_999_000)
        ))

        let viewModel = try makeViewModel(cloudReadings: cloud)
        viewModel.reload()

        // 数值与单位用不换行空格，避免 AX 字号下被拆行。
        XCTAssertEqual(viewModel.readingText(for: remote), "温度 24.5\u{00A0}℃")
        XCTAssertEqual(
            viewModel.cloudReportedAt(for: remote)?.timeIntervalSince1970,
            1_799_999_000,
            "时间行改用云端最近上报时间"
        )
    }

    func testHomeCardShowsUnavailableOnCloudFailureInsteadOfNoReadings() throws {
        let device = makeSavedDevice(name: "客厅温湿度计")
        var remote = device
        remote.platform = "android"
        remote.externalID = "AA:BB:CC:00:00:02"
        remote.serverLastSeenAt = Date()
        try deviceStore.upsert(remote)
        let cloud = FakeCloudReadings()
        cloud.states["android:\(remote.externalID)"] = .failed

        let viewModel = try makeViewModel(cloudReadings: cloud)
        viewModel.reload()

        XCTAssertEqual(viewModel.readingText(for: remote), L10n.t("home.reading.unavailable"))
        XCTAssertNil(viewModel.cloudReportedAt(for: remote))
        XCTAssertFalse(viewModel.isConnected(remote), "拉取失败不影响连接状态判定")
    }

    func testHomeSkipsCloudReadingsForUnknownPresence() throws {
        let device = makeSavedDevice(name: "从未上报")
        try deviceStore.upsert(device)
        let cloud = FakeCloudReadings()

        let viewModel = try makeViewModel(cloudReadings: cloud)
        viewModel.reload()

        XCTAssertTrue(cloud.requested.isEmpty, "presence=unknown 时不应再请求云端读数")
        XCTAssertEqual(viewModel.readingText(for: device), L10n.t("device.detail.noReadings"))
    }

    // MARK: - Helpers

    private func makeViewModel(
        cloudReadings: CloudLatestReadingsProviding? = nil
    ) throws -> HomeDashboardViewModel {
        let settings = makeSettingsStore().store
        let scanLogStore = ScanLogStore(database: database)
        let coordinator = RuleAlertCoordinator(settingsStore: settings, notifications: NoopNotificationService())
        let executor = ScenarioExecutor(
            dependencies: ScenarioExecutor.Dependencies(
                bluetooth: FakeBluetoothService(),
                savedDeviceStore: deviceStore,
                settingsStore: settings,
                alertCoordinator: coordinator,
                syncAction: { completion in completion(.success("")) },
                now: { Date() }
            )
        )
        return HomeDashboardViewModel(
            bluetooth: FakeBluetoothService(),
            savedDeviceStore: deviceStore,
            recentDeviceStore: RecentDeviceStore(database: database),
            settingsStore: settings,
            scanLogStore: scanLogStore,
            readingsStore: ReadingsStore(database: database),
            scenarioStore: ScenarioStore(database: database),
            roomStore: roomStore,
            executor: executor,
            cloudReadings: cloudReadings
        )
    }
}

private final class NoopNotificationService: LocalNotificationServing {
    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        completion(.denied)
    }

    func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func schedule(event: RuleTriggerEvent, completion: ((Error?) -> Void)?) {
        completion?(nil)
    }
}
