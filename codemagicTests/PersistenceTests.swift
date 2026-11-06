import SQLite3
import XCTest
@testable import codemagic

final class PersistenceTests: XCTestCase {
    private var testDatabase: TestDatabase!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        testDatabase = nil
    }

    func testSavedDeviceRoundTripKeepsSyncFields() throws {
        let store = SavedDeviceStore(database: testDatabase.database)
        let id = UUID()
        let peripheralID = UUID()
        let device = SavedDevice(
            id: id,
            peripheralID: peripheralID,
            advertisedName: "Panel-A",
            remark: "客厅面板",
            groupName: "客厅",
            mac: "AA:BB",
            vendor: "Acme",
            firmwareVersion: "1.2.0",
            lastSeenAt: Date(timeIntervalSince1970: 1000),
            createdAt: Date(timeIntervalSince1970: 900),
            updatedAt: Date(timeIntervalSince1970: 1100),
            syncState: .pending
        )

        try store.upsert(device)
        let loaded = try XCTUnwrap(store.fetch(peripheralID: peripheralID))

        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.remark, "客厅面板")
        XCTAssertEqual(loaded.groupName, "客厅")
        XCTAssertEqual(loaded.mac, "AA:BB")
        XCTAssertEqual(loaded.vendor, "Acme")
        XCTAssertEqual(loaded.firmwareVersion, "1.2.0")
        XCTAssertEqual(loaded.syncState, .pending)
        XCTAssertEqual(loaded.displayName, "客厅面板")
        XCTAssertEqual(loaded.lastSeenAt?.timeIntervalSince1970, 1000)
    }

    func testSoftDeleteKeepsRowForSync() throws {
        let store = SavedDeviceStore(database: testDatabase.database)
        let device = makeSavedDevice()
        try store.upsert(device)
        try store.softDelete(id: device.id, at: Date(timeIntervalSince1970: 2000))

        XCTAssertTrue(try store.fetchAll().isEmpty)

        let rows = try testDatabase.database.query(
            "SELECT * FROM saved_devices WHERE id = ?;",
            [.text(device.id.uuidString)]
        )
        let row = try XCTUnwrap(rows.first)
        XCTAssertNotNil(row.double("deleted_at"))
        XCTAssertEqual(row.text("sync_state"), SyncState.pendingDelete.rawValue)
        XCTAssertEqual(row.double("updated_at"), 2000)
    }

    func testSavedDeviceCanBeReinsertedAfterSoftDelete() throws {
        let store = SavedDeviceStore(database: testDatabase.database)
        let peripheralID = UUID()
        let first = makeSavedDevice(peripheralID: peripheralID, name: "旧记录")
        try store.upsert(first)
        try store.softDelete(id: first.id)

        let second = makeSavedDevice(peripheralID: peripheralID, name: "新记录")
        try store.upsert(second)

        XCTAssertEqual(try store.fetch(peripheralID: peripheralID)?.advertisedName, "新记录")
        XCTAssertEqual(try store.fetchAll().count, 1)
    }

    func testRuleStorePersistsToggleState() throws {
        let store = DeviceRuleStore(database: testDatabase.database)
        var rule = DeviceRule(name: "断开", trigger: .disconnect)
        try store.upsert(rule)
        XCTAssertTrue(try store.fetchAll().first?.isEnabled == true)

        rule.isEnabled = false
        rule.threshold = -75
        try store.upsert(rule)
        let loaded = try XCTUnwrap(store.fetchAll().first)
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertEqual(loaded.threshold, -75)
        XCTAssertEqual(loaded.trigger, .disconnect)
    }

    func testReadingThresholdRuleRoundTripsAllFields() throws {
        let store = DeviceRuleStore(database: testDatabase.database)
        let rule = DeviceRule(
            name: "高温告警",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterOrEqual,
            readingThreshold: 30,
            consecutive: 3,
            deviceID: UUID()
        )
        try store.upsert(rule)
        let loaded = try XCTUnwrap(store.fetchAll().first)

        XCTAssertEqual(loaded.trigger, .readingThreshold)
        XCTAssertEqual(loaded.metric, .temperature)
        XCTAssertEqual(loaded.comparison, .greaterOrEqual)
        XCTAssertEqual(loaded.readingThreshold, 30)
        XCTAssertEqual(loaded.consecutive, 3)
        XCTAssertEqual(loaded.triggerDescription, "温度 >= 30 ℃，连续 3 条读数时告警")
    }

    /// v6 旧库升级到 v7：旧 RSSI / 断开规则不得丢失，且回填为 RSSI 语义（metric 为空、比较符 lte、连续 1 条）。
    func testLegacyRulesSurviveVersion7MigrationAndStillFire() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemagic-rules-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("legacy.sqlite").path

        let rssiID = UUID()
        let disconnectID = UUID()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        XCTAssertNotNil(handle)
        let legacySQL = """
        CREATE TABLE rules (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            trigger TEXT NOT NULL,
            threshold INTEGER NOT NULL,
            device_id TEXT,
            is_enabled INTEGER NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            sync_state TEXT NOT NULL
        );
        INSERT INTO rules VALUES ('\(rssiID.uuidString)', '旧弱信号规则', 'rssiBelowThreshold', -80, NULL, 1, 900, 1000, NULL, 'synced');
        INSERT INTO rules VALUES ('\(disconnectID.uuidString)', '旧断开规则', 'disconnect', -80, NULL, 1, 900, 1000, NULL, 'synced');
        CREATE TABLE scan_logs (
            id TEXT PRIMARY KEY NOT NULL,
            occurred_at REAL NOT NULL,
            category TEXT NOT NULL,
            level TEXT NOT NULL,
            message TEXT NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            sync_state TEXT NOT NULL
        );
        PRAGMA user_version = 6;
        """
        XCTAssertEqual(sqlite3_exec(handle, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let migrated = try SQLiteDatabase(path: path)
        defer { migrated.close() }

        let store = DeviceRuleStore(database: migrated)
        let rules = try store.fetchAll()
        XCTAssertEqual(rules.count, 2, "旧规则一条都不能丢")

        let rssiRule = try XCTUnwrap(rules.first { $0.id == rssiID })
        XCTAssertEqual(rssiRule.trigger, .rssiBelowThreshold)
        XCTAssertEqual(rssiRule.threshold, -80)
        XCTAssertNil(rssiRule.metric, "旧规则不回填指标")
        XCTAssertEqual(rssiRule.comparison, .lessOrEqual, "v7 默认比较符回填为 lte")
        XCTAssertEqual(rssiRule.consecutive, 1, "v7 默认连续 1 条")
        XCTAssertEqual(rssiRule.readingThreshold, 0)
        XCTAssertEqual(rssiRule.syncState, .synced, "同步状态保留")

        // 升级后规则仍然生效：RSSI ≤ -80 立即触发。
        let evaluator = RuleEvaluator()
        let device = makeSavedDevice()
        let events = evaluator.evaluate(
            rules: [rssiRule],
            devices: [device],
            observedRSSI: [device.peripheralID: -85],
            date: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].message.contains("-80 dBm"))
        XCTAssertEqual(try migrated.query("PRAGMA user_version;").first?.integer("user_version"),  17)
    }

    func testRecentDevicesSortedByLastSeen() throws {
        let store = RecentDeviceStore(database: testDatabase.database)
        let older = UUID()
        let newer = UUID()

        try store.upsert(peripheralID: older, name: "旧设备", rssi: -80, lastSeenAt: Date(timeIntervalSince1970: 100))
        try store.upsert(peripheralID: newer, name: "新设备", rssi: -50, lastSeenAt: Date(timeIntervalSince1970: 200))

        let devices = try store.fetchAll()
        XCTAssertEqual(devices.map { $0.peripheralID }, [newer, older])
        XCTAssertEqual(devices.first?.rssi, -50)
    }

    func testScanLogSoftDeleteAllMarksPendingDelete() throws {
        let store = ScanLogStore(database: testDatabase.database)
        try store.append(ScanLogEntry(category: .session, message: "开始扫描"))
        try store.append(ScanLogEntry(category: .rule, level: .warning, message: "规则命中"))

        XCTAssertEqual(try store.count(), 2)
        try store.softDeleteAll(at: Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(try store.count(), 0)
        XCTAssertTrue(try store.fetchRecent().isEmpty)

        let rows = try testDatabase.database.query("SELECT sync_state, deleted_at FROM scan_logs;")
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row.text("sync_state"), SyncState.pendingDelete.rawValue)
            XCTAssertNotNil(row.double("deleted_at"))
        }
    }

    func testDeviceInfoCacheRoundTrip() throws {
        let store = DeviceInfoCacheStore(database: testDatabase.database)
        let peripheralID = UUID()
        let product = makeProduct(vendor: "厂商甲", services: [
            GATTService(uuid: "180F", name: "电池"),
            GATTService(uuid: "FFF0", name: "私有服务"),
        ])

        try store.save(product: product, peripheralID: peripheralID, fetchedAt: Date(timeIntervalSince1970: 4000))
        let cache = try XCTUnwrap(store.fetch(peripheralID: peripheralID))

        XCTAssertEqual(cache.product, product)
        XCTAssertEqual(cache.fetchedAt.timeIntervalSince1970, 4000)
        XCTAssertEqual(cache.product.gattServices.count, 2)
    }

    func testDatabaseCanBeReopenedWithExistingData() throws {
        let store = SavedDeviceStore(database: testDatabase.database)
        let device = makeSavedDevice()
        try store.upsert(device)

        let reopened = try testDatabase.makeDatabaseHandle()
        let reopenedStore = SavedDeviceStore(database: reopened)
        XCTAssertEqual(try reopenedStore.fetchAll().count, 1)
    }

    // MARK: - v0.2.0 同步字段迁移

    func testSyncIdentityColumnsExistAndRoundTrip() throws {
        let store = SavedDeviceStore(database: testDatabase.database)
        let externalID = "AA:BB:CC:DD:EE:FF"
        let device = SavedDevice(
            peripheralID: SyncHashing.stableUUID(seed: externalID),
            platform: "android",
            externalID: externalID,
            advertisedName: "安卓设备",
            syncState: .synced
        )
        try store.upsert(device)

        let loaded = try XCTUnwrap(store.fetch(platform: "android", externalID: externalID.lowercased()))
        XCTAssertEqual(loaded.platform, "android")
        XCTAssertEqual(loaded.externalID, externalID)
        XCTAssertEqual(loaded.syncKey, "android:\(externalID)")

        let version = try testDatabase.database.query("PRAGMA user_version;").first?.integer("user_version")
        XCTAssertEqual(version, 17)
    }

    func testDeviceTypeColumnRoundTrip() throws {
        let store = SavedDeviceStore(database: testDatabase.database)
        let externalID = SyncHashing.stableUUID(seed: "ios-device").uuidString
        let device = SavedDevice(
            peripheralID: UUID(uuidString: externalID)!,
            platform: "ios",
            externalID: externalID,
            advertisedName: "iOS 设备",
            deviceType: "tracker",
            syncState: .pending
        )
        try store.upsert(device)

        let loaded = try XCTUnwrap(store.fetch(platform: "ios", externalID: externalID))
        XCTAssertEqual(loaded.deviceType, "tracker")
    }

    func testLegacyVersion1DatabaseMigratesToCurrentVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemagic-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("legacy.sqlite").path

        let peripheralID = UUID()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        XCTAssertNotNil(handle)
        let legacySQL = """
        CREATE TABLE saved_devices (
            id TEXT PRIMARY KEY NOT NULL,
            peripheral_id TEXT NOT NULL,
            name TEXT NOT NULL,
            remark TEXT NOT NULL DEFAULT '',
            group_name TEXT NOT NULL DEFAULT '未分组',
            mac TEXT,
            vendor TEXT,
            firmware_version TEXT,
            last_seen_at REAL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            sync_state TEXT NOT NULL
        );
        INSERT INTO saved_devices
            (id, peripheral_id, name, remark, group_name, updated_at, created_at, sync_state)
            VALUES ('\(UUID().uuidString)', '\(peripheralID.uuidString)', '旧版本设备', '', '未分组', 1000, 900, 'synced');
        PRAGMA user_version = 1;
        """
        XCTAssertEqual(sqlite3_exec(handle, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let migrated = try SQLiteDatabase(path: path)
        defer { migrated.close() }

        let store = SavedDeviceStore(database: migrated)
        let devices = try store.fetchAll()
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.platform, "ios", "旧记录平台兜底为 ios")
        XCTAssertEqual(device.externalID, peripheralID.uuidString.uppercased(), "externalId 由 peripheral_id 回填")
        XCTAssertNil(device.deviceType, "旧记录不知道型号，保持 NULL")
        XCTAssertEqual(device.syncState, .synced)
        XCTAssertEqual(device.advertisedName, "旧版本设备", "v4 从 name 列回填广播名")
        XCTAssertEqual(device.aliasPatch, .absent)
        XCTAssertEqual(device.groupPatch, .absent)

        let version = try migrated.query("PRAGMA user_version;").first?.integer("user_version")
        XCTAssertEqual(version, 17)
    }

    func testAdvertisedNameAndPatchStatesRoundTrip() throws {
        let store = SavedDeviceStore(database: testDatabase.database)
        let peripheralID = UUID()
        let device = SavedDevice(
            peripheralID: peripheralID,
            advertisedName: "PJ-Sensor",
            remark: "客厅面板",
            groupName: "厨房",
            aliasPatch: .clear,
            advertisedNamePatch: .set("PJ-Sensor"),
            groupPatch: .clear
        )
        try store.upsert(device)

        let loaded = try XCTUnwrap(store.fetch(peripheralID: peripheralID))
        XCTAssertEqual(loaded.advertisedName, "PJ-Sensor", "广播名与别名独立存储")
        XCTAssertEqual(loaded.remark, "客厅面板")
        XCTAssertEqual(loaded.displayName, "客厅面板", "展示顺序：别名优先")
        XCTAssertEqual(loaded.aliasPatch, .clear)
        XCTAssertEqual(loaded.advertisedNamePatch, .set("PJ-Sensor"))
        XCTAssertEqual(loaded.groupPatch, .clear)
    }

    func testMarkSyncedResetsPatchStates() throws {
        let store = SavedDeviceStore(database: testDatabase.database)
        var device = makeSavedDevice(name: "PJ-Sensor", remark: "别名")
        device.aliasPatch = .set("别名")
        device.advertisedNamePatch = .set("PJ-Sensor")
        device.groupPatch = .clear
        try store.upsert(device)

        try store.markSynced(ids: [device.id], at: Date())

        let loaded = try XCTUnwrap(store.fetch(id: device.id))
        XCTAssertEqual(loaded.syncState, .synced)
        XCTAssertEqual(loaded.aliasPatch, .absent, "已上报字段不得重复上报")
        XCTAssertEqual(loaded.advertisedNamePatch, .absent)
        XCTAssertEqual(loaded.groupPatch, .absent)
        XCTAssertEqual(loaded.remark, "别名", "三态归零不影响本地值")
    }
}
