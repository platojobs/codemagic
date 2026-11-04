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
            name: "Panel-A",
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

        XCTAssertEqual(try store.fetch(peripheralID: peripheralID)?.name, "新记录")
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
}
