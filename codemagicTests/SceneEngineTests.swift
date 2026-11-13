import XCTest
@testable import codemagic

/// 场景执行：离线 / RSSI / 指标连续条数、冷却、设备缺失跳过与占位符渲染。
final class SceneEngineTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var sceneStore: SceneStore!
    private var deviceStore: SavedDeviceStore!
    private var logStore: ScanLogStore!
    private var notifications: FakeSceneNotificationService!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        sceneStore = SceneStore(database: testDatabase.database)
        deviceStore = SavedDeviceStore(database: testDatabase.database)
        logStore = ScanLogStore(database: testDatabase.database)
        notifications = FakeSceneNotificationService()
    }

    override func tearDownWithError() throws {
        testDatabase.cleanUp()
    }

    // MARK: - Offline / RSSI

    func testOfflineTriggerFiresOnceAndRendersPlaceholders() throws {
        let device = makeDevice(name: "床头灯", lastSeenAt: Date(timeIntervalSince1970: 2_000))
        try deviceStore.upsert(device)
        let scene = try sceneStore.insert(
            makeScene(
                name: "离线提醒",
                trigger: .deviceOffline(device: reference(for: device), offlineSeconds: 300),
                actions: [
                    .notify(title: "设备离线", body: "{device} 已离线 {value}"),
                    .log(message: "离线：{device}", level: .warn),
                ]
            ),
            now: Date(timeIntervalSince1970: 2_000)
        )
        let engine = makeEngine()

        let outcomes = engine.evaluateScans(
            observedRSSI: [:],
            at: Date(timeIntervalSince1970: 2_400)
        )
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].triggered)
        XCTAssertEqual(outcomes[0].sceneID, scene.id)
        XCTAssertEqual(notifications.scheduled.count, 1)
        XCTAssertEqual(notifications.scheduled.first?.title, "设备离线")
        XCTAssertEqual(notifications.scheduled.first?.body, "床头灯 已离线 —")
        XCTAssertEqual(notifications.scheduled.first?.userInfo[SceneNotificationKeys.sceneID], scene.id.uuidString)

        let logs = try logStore.fetchRecent(limit: 10)
        XCTAssertEqual(logs.first?.level, .warning)
        XCTAssertTrue(logs.first?.message.contains("床头灯") == true)
        XCTAssertEqual(try sceneStore.fetch(id: scene.id)?.lastRunAt, Date(timeIntervalSince1970: 2_400))

        // 同一越界事件不重复触发。
        XCTAssertTrue(engine.evaluateScans(observedRSSI: [:], at: Date(timeIntervalSince1970: 2_500)).isEmpty)
    }

    func testRSSITriggerResetsAndHonorsCooldown() throws {
        let device = makeDevice(name: "门磁")
        try deviceStore.upsert(device)
        let scene = try sceneStore.insert(
            makeScene(
                name: "信号弱",
                cooldownSeconds: 300,
                trigger: .rssiBelow(device: reference(for: device), rssiThreshold: -70),
                actions: [.log(message: "信号 {value}", level: .warn)]
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let engine = makeEngine()

        XCTAssertEqual(engine.evaluateScans(observedRSSI: [device.peripheralID: -80], at: Date(timeIntervalSince1970: 1_100)).count, 1)
        XCTAssertTrue(engine.evaluateScans(observedRSSI: [device.peripheralID: -79], at: Date(timeIntervalSince1970: 1_200)).isEmpty)

        // 信号恢复后再次变弱，仍在冷却窗口内，不应触发。
        XCTAssertTrue(engine.evaluateScans(observedRSSI: [device.peripheralID: -60], at: Date(timeIntervalSince1970: 1_300)).isEmpty)
        XCTAssertTrue(engine.evaluateScans(observedRSSI: [device.peripheralID: -85], at: Date(timeIntervalSince1970: 1_399)).isEmpty)

        // 冷却结束后先恢复信号，再越界才允许再次触发。
        XCTAssertTrue(engine.evaluateScans(observedRSSI: [device.peripheralID: -60], at: Date(timeIntervalSince1970: 1_500)).isEmpty)
        XCTAssertEqual(engine.evaluateScans(observedRSSI: [device.peripheralID: -85], at: Date(timeIntervalSince1970: 1_600)).count, 1)
        XCTAssertEqual(try sceneStore.fetch(id: scene.id)?.lastRunAt, Date(timeIntervalSince1970: 1_600))
    }

    /// 场景 RSSI 触发是 `<=`：等于阈值必须触发，高于阈值不触发。
    func testRSSITriggerFiresAtEquality() throws {
        let device = makeDevice(name: "门磁")
        try deviceStore.upsert(device)
        let scene = try sceneStore.insert(
            makeScene(
                name: "信号弱",
                trigger: .rssiBelow(device: reference(for: device), rssiThreshold: -70),
                actions: [.log(message: "信号 {value}", level: .warn)]
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let engine = makeEngine()

        XCTAssertTrue(
            engine.evaluateScans(observedRSSI: [device.peripheralID: -69], at: Date(timeIntervalSince1970: 1_100)).isEmpty,
            "高于阈值不触发"
        )
        let equal = engine.evaluateScans(
            observedRSSI: [device.peripheralID: -70],
            at: Date(timeIntervalSince1970: 1_200)
        )
        XCTAssertEqual(equal.count, 1, "等于阈值必须触发")
        XCTAssertEqual(equal.first?.sceneID, scene.id)
        XCTAssertTrue(equal.first?.triggered == true)
    }

    // MARK: - Metric

    func testMetricThresholdRequiresConsecutiveReadings() throws {
        let device = makeDevice(name: "床头灯")
        try deviceStore.upsert(device)
        let scene = try sceneStore.insert(
            makeScene(
                name: "高温",
                cooldownSeconds: 0,
                trigger: .metricThreshold(
                    device: reference(for: device),
                    deviceType: "panel",
                    metric: "temperature",
                    comparator: .gte,
                    threshold: 30,
                    consecutive: 3
                ),
                actions: [
                    .log(message: "{device} {metric} {value}", level: .warn),
                    .notify(title: "高温告警", body: "{device} 当前 {value}"),
                ]
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let engine = makeEngine()

        let readings = [
            DeviceReading(deviceID: device.id, metric: .temperature, value: 31, unit: "℃", recordedAt: Date(timeIntervalSince1970: 100)),
            DeviceReading(deviceID: device.id, metric: .temperature, value: 32, unit: "℃", recordedAt: Date(timeIntervalSince1970: 200)),
            DeviceReading(deviceID: device.id, metric: .temperature, value: 33, unit: "℃", recordedAt: Date(timeIntervalSince1970: 300)),
        ]
        let outcomes = engine.evaluateReadings(readings, device: device, at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].messages.first, "床头灯 温度 33")
        XCTAssertEqual(notifications.scheduled.first?.title, "高温告警")
        XCTAssertEqual(notifications.scheduled.first?.body, "床头灯 当前 33")
        XCTAssertEqual(try sceneStore.fetch(id: scene.id)?.lastRunAt, Date(timeIntervalSince1970: 300))

        // 已触发后继续超阈值不再重复。
        XCTAssertTrue(
            engine.evaluateReadings(
                [DeviceReading(deviceID: device.id, metric: .temperature, value: 34, unit: "℃", recordedAt: Date(timeIntervalSince1970: 400))],
                device: device,
                at: Date(timeIntervalSince1970: 400)
            ).isEmpty
        )

        // 一条不满足即清零，需要重新连续 3 条。
        XCTAssertTrue(
            engine.evaluateReadings(
                [DeviceReading(deviceID: device.id, metric: .temperature, value: 20, unit: "℃", recordedAt: Date(timeIntervalSince1970: 500))],
                device: device,
                at: Date(timeIntervalSince1970: 500)
            ).isEmpty
        )
        XCTAssertTrue(
            engine.evaluateReadings(
                [
                    DeviceReading(deviceID: device.id, metric: .temperature, value: 31, unit: "℃", recordedAt: Date(timeIntervalSince1970: 600)),
                    DeviceReading(deviceID: device.id, metric: .temperature, value: 32, unit: "℃", recordedAt: Date(timeIntervalSince1970: 700)),
                ],
                device: device,
                at: Date(timeIntervalSince1970: 700)
            ).isEmpty
        )
        XCTAssertEqual(
            engine.evaluateReadings(
                [DeviceReading(deviceID: device.id, metric: .temperature, value: 33, unit: "℃", recordedAt: Date(timeIntervalSince1970: 800))],
                device: device,
                at: Date(timeIntervalSince1970: 800)
            ).count,
            1
        )
    }

    // MARK: - deviceMissing

    func testMissingDeviceSkipsExecutionAndLogsFailureOnce() throws {
        let scene = try sceneStore.insert(
            makeScene(
                name: "引用已删设备",
                cooldownSeconds: 300,
                trigger: .deviceOffline(device: makeSceneReference(externalID: "GONE-1"), offlineSeconds: 60),
                actions: [.log(message: "不应执行", level: .warn)]
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let engine = makeEngine()

        XCTAssertTrue(engine.evaluateScans(observedRSSI: [:], at: Date(timeIntervalSince1970: 2_000)).isEmpty)
        let missing = try XCTUnwrap(sceneStore.fetch(id: scene.id))
        XCTAssertTrue(missing.deviceMissing, "列表需要标注「设备已移除」")
        XCTAssertNil(missing.deletedAt, "设备被删不级联删场景")
        XCTAssertEqual(missing.syncState, .pending, "场景本身不应被静默失效")

        let logs = try logStore.fetchRecent(limit: 10)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.category, .rule)
        XCTAssertEqual(logs.first?.level, .warning)
        XCTAssertTrue(logs.first?.message.contains("引用已删设备") == true)

        // 同一冷却窗口内不重复刷日志。
        XCTAssertTrue(engine.evaluateScans(observedRSSI: [:], at: Date(timeIntervalSince1970: 2_100)).isEmpty)
        XCTAssertEqual(try logStore.fetchRecent(limit: 10).count, 1)
        XCTAssertFalse(try logStore.fetchRecent(limit: 10).contains { $0.message == "不应执行" })
    }

    func testRefreshMissingFlagsTracksDeviceDeletionAndRestore() throws {
        let device = makeDevice(name: "门磁")
        let reference = reference(for: device)
        let scene = try sceneStore.insert(
            makeScene(name: "门磁离线", trigger: .deviceOffline(device: reference, offlineSeconds: 60)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let engine = makeEngine()

        engine.refreshMissingFlags()
        XCTAssertTrue(try sceneStore.fetch(id: scene.id)?.deviceMissing == true, "设备未保存时标记缺失")

        try deviceStore.upsert(device)
        engine.refreshMissingFlags()
        XCTAssertTrue(try sceneStore.fetch(id: scene.id)?.deviceMissing == false, "设备恢复后清除标记")
    }

    func testDisabledSceneDoesNotRun() throws {
        let device = makeDevice(name: "床头灯", lastSeenAt: Date(timeIntervalSince1970: 2_000))
        try deviceStore.upsert(device)
        try sceneStore.insert(
            makeScene(
                name: "已停用",
                enabled: false,
                trigger: .deviceOffline(device: reference(for: device), offlineSeconds: 60)
            ),
            now: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertTrue(makeEngine().evaluateScans(observedRSSI: [:], at: Date(timeIntervalSince1970: 3_000)).isEmpty)
        XCTAssertTrue(notifications.scheduled.isEmpty)
    }

    // MARK: - Helpers

    private func makeEngine() -> SceneEngine {
        SceneEngine(
            store: sceneStore,
            deviceStore: deviceStore,
            logStore: logStore,
            notifications: notifications,
            now: { Date() }
        )
    }

    private func makeDevice(name: String, lastSeenAt: Date? = nil) -> SavedDevice {
        SavedDevice(
            peripheralID: UUID(),
            advertisedName: name,
            deviceType: "panel",
            lastSeenAt: lastSeenAt
        )
    }

    private func reference(for device: SavedDevice) -> SceneDeviceReference {
        SceneDeviceReference(platform: device.platform, externalID: device.externalID)
    }
}

// MARK: - Template

final class SceneTemplateTests: XCTestCase {
    func testRenderReplacesKnownPlaceholders() {
        let context = SceneTriggerContext(deviceName: "床头灯", metricName: "温度", value: 36.5)
        XCTAssertEqual(
            SceneTemplate.render("{device} / {metric} / {value}", context: context),
            "床头灯 / 温度 / 36.5"
        )
    }

    func testRenderFallsBackToDashWhenContextMissing() {
        XCTAssertEqual(
            SceneTemplate.render("{device}{metric}{value}", context: .empty),
            "———"
        )
        XCTAssertEqual(
            SceneTemplate.render("{device}", context: SceneTriggerContext(deviceName: "   ")),
            "—"
        )
    }

    func testRenderKeepsUnknownPlaceholder() {
        let context = SceneTriggerContext(deviceName: "床头灯")
        XCTAssertEqual(SceneTemplate.render("{foo} {device}", context: context), "{foo} 床头灯")
    }

    /// 服务端目录用 `temperature_celsius` 这类键，展示时应映射到本地指标名。
    func testMetricDisplayNameMapsCatalogKeys() {
        XCTAssertEqual(SceneTrigger.displayMetricName("temperature_celsius"), ReadingMetric.temperature.displayName)
        XCTAssertEqual(SceneTrigger.displayMetricName("relative_humidity"), ReadingMetric.humidity.displayName)
        XCTAssertEqual(SceneTrigger.displayMetricName("heart_rate_bpm"), ReadingMetric.heartRate.displayName)
        XCTAssertEqual(SceneTrigger.displayMetricName("temperature"), ReadingMetric.temperature.displayName)
        XCTAssertEqual(SceneTrigger.displayMetricName("custom_metric"), "custom_metric")
    }
}

// MARK: - Fake notifications

private final class FakeSceneNotificationService: SceneNotificationServing {
    private(set) var scheduled: [SceneNotificationRequest] = []
    private(set) var cancelCount = 0

    func scheduleScene(_ request: SceneNotificationRequest, completion: ((Error?) -> Void)?) {
        scheduled.append(request)
        completion?(nil)
    }

    func cancelSceneNotifications(completion: (() -> Void)?) {
        cancelCount += 1
        scheduled.removeAll()
        completion?()
    }
}
