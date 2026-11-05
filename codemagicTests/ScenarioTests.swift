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

    func testScenarioTableIsLocalOnly() throws {
        let columns = try testDatabase.database.query("PRAGMA table_info(scenarios);")
        let names = Set(columns.compactMap { $0.text("name") })
        XCTAssertEqual(names, ["id", "name", "actions", "created_at", "updated_at"])
        XCTAssertFalse(names.contains("sync_state"), "场景不得参与同步")
        XCTAssertFalse(names.contains("deleted_at"), "场景不做云端软删除")
    }

    func testMigrationFromVersion5CreatesScenarioTable() throws {
        let path = testDatabase.directory.appendingPathComponent("migration.sqlite").path
        let legacy = try SQLiteDatabase(path: path)
        try legacy.execute("DROP TABLE IF EXISTS scenarios;")
        try legacy.execute("PRAGMA user_version = 5;")
        legacy.close()

        let migrated = try SQLiteDatabase(path: path)
        defer { migrated.close() }
        XCTAssertEqual(try migrated.query("PRAGMA user_version;").first?.integer("user_version"), 8)
        XCTAssertEqual(try ScenarioStore(database: migrated).fetchAll().count, 0)
        let columns = try migrated.query("PRAGMA table_info(scenarios);")
        XCTAssertEqual(columns.count, 5)
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
