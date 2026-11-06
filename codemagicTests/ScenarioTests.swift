import XCTest
import UIKit
import UserNotifications
@testable import codemagic

/// 场景：存储 / 迁移 / 真实动作执行 / 结果汇总。
final class ScenarioTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var settings: SettingsStore!
    private var suiteName: String!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        suiteName = "scenario-tests-\(UUID().uuidString)"
        settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        testDatabase.cleanUp()
    }

    // MARK: - Store

    func testScenarioStoreRoundTripPreservesOrderAndActions() throws {
        let store = ScenarioStore(database: testDatabase.database)
        let deviceID = UUID()
        let scenario = Scenario(
            name: "回家",
            actions: [.connectDevice(deviceID), .startBackgroundCollection, .muteAlerts(minutes: 30), .syncNow]
        )
        try store.upsert(scenario)

        let loaded = try XCTUnwrap(store.fetchAll().first)
        XCTAssertEqual(loaded.id, scenario.id)
        XCTAssertEqual(loaded.name, "回家")
        XCTAssertEqual(loaded.actions, scenario.actions)

        try store.delete(id: scenario.id)
        XCTAssertTrue(try store.fetchAll().isEmpty)
    }

    func testScenarioTableCarriesSceneSyncColumns() throws {
        let columns = try testDatabase.database.query("PRAGMA table_info(scenarios);")
        let names = Set(columns.compactMap { $0.text("name") })
        XCTAssertTrue(names.contains("kind"), "需要区分手动场景与服务端场景")
        XCTAssertTrue(names.contains("remote_id"), "服务端场景必须能写回 remoteId")
        XCTAssertTrue(names.contains("sync_state"), "服务端场景参与同步")
        XCTAssertTrue(names.contains("deleted_at"), "服务端场景支持软删同步")
        XCTAssertTrue(names.contains("name_updated_at"), "5 个字段各带 LWW 时间戳")
        XCTAssertEqual(columns.count, 21)
    }

    func testMigrationFromVersion5AddsSceneColumnsAndPreservesLegacyRows() throws {
        let path = testDatabase.directory.appendingPathComponent("migration.sqlite").path
        let legacy = try SQLiteDatabase(path: path)
        let legacyID = UUID().uuidString
        try legacy.execute("DROP TABLE IF EXISTS scenarios;")
        try legacy.execute("""
        CREATE TABLE scenarios (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            actions TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        try legacy.execute(
            "INSERT INTO scenarios (id, name, actions, created_at, updated_at) VALUES (?, ?, ?, ?, ?);",
            [
                .text(legacyID),
                .text("旧的手动场景"),
                .text("[]"),
                .double(1_000),
                .double(1_000),
            ]
        )
        try legacy.execute("PRAGMA user_version = 5;")
        legacy.close()

        let migrated = try SQLiteDatabase(path: path)
        defer { migrated.close() }
        XCTAssertEqual(try migrated.query("PRAGMA user_version;").first?.integer("user_version"), 14)

        let columns = try migrated.query("PRAGMA table_info(scenarios);")
        XCTAssertEqual(columns.count, 21)
        XCTAssertEqual(Set(columns.compactMap { $0.text("name") }), [
            "id", "name", "actions", "created_at", "updated_at",
            "kind", "remote_id", "version", "enabled", "cooldown_seconds", "trigger",
            "sync_state", "deleted_at", "device_missing", "last_synced_at", "last_run_at",
            "name_updated_at", "enabled_updated_at", "cooldown_updated_at",
            "trigger_updated_at", "actions_updated_at",
        ])

        // 旧数据不丢：仍由手动场景存储读取，且没有混入服务端场景列表。
        let manual = try ScenarioStore(database: migrated).fetchAll()
        XCTAssertEqual(manual.count, 1)
        XCTAssertEqual(manual.first?.name, "旧的手动场景")
        let row = try XCTUnwrap(
            migrated.query("SELECT * FROM scenarios WHERE id = ?;", [.text(legacyID)]).first
        )
        XCTAssertEqual(row.text("kind"), "manual")
        XCTAssertEqual(row.text("sync_state"), "localOnly")
        XCTAssertTrue(try SceneStore(database: migrated).fetchAll(includeDeleted: true).isEmpty)
    }

    // MARK: - Executor

    func testConnectActionInvokesBluetooth() throws {
        let (executor, bluetooth, device) = try makeExecutor()
        let scenario = Scenario(name: "连接", actions: [.connectDevice(device.id)])
        let result = run(scenario, executor: executor)

        XCTAssertTrue(result.isFullySuccessful)
        XCTAssertEqual(bluetooth.connectedPeripheralIDs, [device.peripheralID], "必须真实调用连接")
    }

    func testConnectFailsWhenDeviceAlreadyConnected() throws {
        let (executor, bluetooth, device) = try makeExecutor()
        bluetooth.markConnected(device.peripheralID)
        let result = run(Scenario(name: "重复", actions: [.connectDevice(device.id)]), executor: executor)

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.actionResults.first?.message, "设备已连接，无需重复连接")
        XCTAssertEqual(bluetooth.connectedPeripheralIDs, [device.peripheralID], "重复执行不应再次连接")
    }

    func testConnectFailsWithoutBluetoothPermission() throws {
        let (executor, bluetooth, device) = try makeExecutor(authorization: .denied)
        let result = run(Scenario(name: "无权限", actions: [.connectDevice(device.id)]), executor: executor)

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.actionResults.first?.message, "蓝牙权限未授权，请到系统设置开启")
        XCTAssertTrue(bluetooth.connectedPeripheralIDs.isEmpty)
    }

    func testDisconnectFailsWhenDeviceNotConnected() throws {
        let (executor, bluetooth, device) = try makeExecutor()
        let result = run(Scenario(name: "断开", actions: [.disconnectDevice(device.id)]), executor: executor)

        XCTAssertEqual(result.actionResults.first?.message, "设备当前未连接")
        XCTAssertTrue(bluetooth.disconnectedPeripheralIDs.isEmpty)
    }

    func testBackgroundCollectionDuplicateActionsFailButDoNotBlockFollowingActions() throws {
        settings.backgroundCollectionEnabled = true
        let (executor, _, _) = try makeExecutor()
        let result = run(
            Scenario(name: "采集", actions: [.startBackgroundCollection, .stopBackgroundCollection]),
            executor: executor
        )

        XCTAssertEqual(result.actionResults.count, 2)
        XCTAssertEqual(result.actionResults[0].message, "后台采集已在运行，无需重复开启")
        XCTAssertTrue(result.actionResults[1].succeeded)
        XCTAssertFalse(settings.backgroundCollectionEnabled)
    }

    func testMuteAlertsPersistsAndBlocksDuplicateMinutes() throws {
        settings.ruleAlertsEnabled = true
        let (executor, _, _) = try makeExecutor(now: Date(timeIntervalSince1970: 1000))
        let first = run(Scenario(name: "静音", actions: [.muteAlerts(minutes: 30)]), executor: executor)

        XCTAssertTrue(first.isFullySuccessful)
        XCTAssertEqual(settings.ruleAlertsMutedUntil?.timeIntervalSince1970, 1000 + 30 * 60)

        let second = run(Scenario(name: "重复静音", actions: [.muteAlerts(minutes: 10)]), executor: executor)
        XCTAssertEqual(second.failedCount, 1)
        XCTAssertTrue(second.actionResults[0].message.contains("已在静音中"))
    }

    func testInvalidMuteDurationFailsWithoutChangingState() throws {
        settings.ruleAlertsEnabled = true
        let (executor, _, _) = try makeExecutor()
        let result = run(Scenario(name: "非法静音", actions: [.muteAlerts(minutes: 45)]), executor: executor)

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(result.actionResults[0].message.contains("10 / 30 / 60"))
        XCTAssertNil(settings.ruleAlertsMutedUntil)
    }

    func testScenarioSummaryAggregatesFailuresWithoutStopping() throws {
        var syncCalls = 0
        let (executor, bluetooth, device) = try makeExecutor(syncAction: { completion in
            syncCalls += 1
            completion(.success("同步完成"))
        })
        let scenario = Scenario(
            name: "汇总",
            actions: [
                .connectDevice(device.id),
                .muteAlerts(minutes: 45),
                .syncNow,
            ]
        )
        let result = run(scenario, executor: executor)

        XCTAssertEqual(result.actionResults.count, 3)
        XCTAssertEqual(result.succeededCount, 2)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.summaryText, "2 个成功，1 个失败")
        XCTAssertEqual(syncCalls, 1, "立即同步必须真实调用")
        XCTAssertEqual(bluetooth.connectedPeripheralIDs, [device.peripheralID])
    }

    func testUnconnectedDeviceActionFailureDoesNotBlockSync() throws {
        var syncCalls = 0
        let (executor, _, _) = try makeExecutor(syncAction: { completion in
            syncCalls += 1
            completion(.success("同步完成"))
        })
        let missingID = UUID()
        let result = run(
            Scenario(name: "缺失设备", actions: [.connectDevice(missingID), .syncNow]),
            executor: executor
        )

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.actionResults.first?.message, "设备不存在或已删除")
        XCTAssertEqual(syncCalls, 1)
    }

    // MARK: - Helpers

    private func run(_ scenario: Scenario, executor: ScenarioExecutor) -> ScenarioRunResult {
        var captured: ScenarioRunResult?
        executor.execute(scenario) { captured = $0 }
        return captured ?? ScenarioRunResult(scenarioID: scenario.id, scenarioName: scenario.name, actionResults: [])
    }

    private func makeExecutor(
        authorization: BluetoothAuthorization = .allowed,
        now: Date = Date(timeIntervalSince1970: 500),
        syncAction: @escaping (@escaping (Result<String, AppError>) -> Void) -> Void = { $0(.success("同步完成")) }
    ) throws -> (ScenarioExecutor, FakeBluetoothService, SavedDevice) {
        let bluetooth = FakeBluetoothService(authorization: authorization)
        let store = SavedDeviceStore(database: testDatabase.database)
        let device = makeSavedDevice(name: "床头灯")
        try store.upsert(device)
        let coordinator = RuleAlertCoordinator(
            settingsStore: settings,
            notifications: StubNotificationService()
        )
        let executor = ScenarioExecutor(
            dependencies: ScenarioExecutor.Dependencies(
                bluetooth: bluetooth,
                savedDeviceStore: store,
                settingsStore: settings,
                alertCoordinator: coordinator,
                syncAction: syncAction,
                now: { now }
            )
        )
        return (executor, bluetooth, device)
    }
}

/// 场景测试只关心静音动作，不实际发通知。
private final class StubNotificationService: LocalNotificationServing {
    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        completion(.authorized)
    }

    func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    func schedule(event: RuleTriggerEvent, completion: ((Error?) -> Void)?) {
        completion?(nil)
    }
}
