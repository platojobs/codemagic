import XCTest
@testable import codemagic

final class ReadingsSyncTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var suiteName: String!
    private var savedDeviceStore: SavedDeviceStore!
    private var readingsStore: ReadingsStore!
    private var logStore: ScanLogStore!
    private var metadata: SyncMetadataStore!
    private var tokenStore: InMemoryTokenStore!
    private var api: FakeSyncAPI!
    private var now: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        suiteName = "codemagic.readings.sync.tests.\(UUID().uuidString)"
        metadata = SyncMetadataStore(defaults: UserDefaults(suiteName: suiteName)!)
        savedDeviceStore = SavedDeviceStore(database: testDatabase.database)
        readingsStore = ReadingsStore(database: testDatabase.database)
        logStore = ScanLogStore(database: testDatabase.database)
        tokenStore = InMemoryTokenStore()
        api = FakeSyncAPI()
        now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    private func makeEngine() -> SyncEngine {
        SyncEngine(
            api: api,
            tokenStore: tokenStore,
            metadataStore: metadata,
            deviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            logStore: logStore,
            now: { self.now }
        )
    }

    @discardableResult
    private func runSync(_ engine: SyncEngine) -> Result<SyncEngine.Summary, AppError>? {
        var captured: Result<SyncEngine.Summary, AppError>?
        engine.sync { captured = $0 }
        return captured
    }

    private func seedReadings(
        device: SavedDevice,
        count: Int,
        metric: ReadingMetric = .temperature,
        since offset: TimeInterval = -3600
    ) throws -> [DeviceReading] {
        var saved: [DeviceReading] = []
        for index in 0..<count {
            let reading = DeviceReading(
                deviceID: device.id,
                metric: metric,
                value: 20 + Double(index),
                unit: "℃",
                recordedAt: now.addingTimeInterval(offset + Double(index))
            )
            try readingsStore.insert(reading)
            saved.append(reading)
        }
        return saved
    }

    func testReadingsRideAlongWithDeviceInSameBatch() throws {
        let device = makeSavedDevice(name: "温湿度计")
        try savedDeviceStore.upsert(device)
        let readings = try seedReadings(device: device, count: 3)
        api.pushResults = [.success(PushResult(appliedReadings: 3))]

        let engine = makeEngine()
        guard case .success(let summary) = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("同步应成功")
        }

        let request = try XCTUnwrap(api.pushRequests.first)
        XCTAssertEqual(request.devices.count, 1, "设备与读数同批推送")
        XCTAssertEqual(request.readings.count, 3)
        XCTAssertEqual(request.readings.first?.platform, device.platform)
        XCTAssertEqual(request.readings.first?.externalID, device.externalID)
        XCTAssertEqual(request.readings.first?.metric, "temperature")
        XCTAssertEqual(summary.pushedReadings, 3)
        XCTAssertEqual(try readingsStore.pendingCount(), 0, "成功后读数标记已同步")
        XCTAssertEqual(Set(request.readings.map(\.id)), Set(readings.map { $0.id.uuidString }))
    }

    func testReadingsBatchSizeIsTwoHundred() throws {
        let device = makeSavedDevice(name: "采样器")
        try savedDeviceStore.upsert(device)
        _ = try seedReadings(device: device, count: 250)
        api.pushResults = [
            .success(PushResult(appliedReadings: 200)),
            .success(PushResult(appliedReadings: 50)),
        ]

        let engine = makeEngine()
        guard case .success(let summary) = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("同步应成功")
        }

        XCTAssertEqual(api.pushRequests.count, 2)
        XCTAssertEqual(api.pushRequests[0].readings.count, 200, "单批读数上限 200")
        XCTAssertEqual(api.pushRequests[1].readings.count, 50)
        XCTAssertTrue(api.pushRequests[1].devices.isEmpty, "第二批只有读数")
        XCTAssertEqual(summary.pushedReadings, 250)
        XCTAssertEqual(try readingsStore.pendingCount(), 0)
    }

    func testFailedPushKeepsReadingsPendingAndRetryReusesPayload() throws {
        let device = makeSavedDevice(name: "心率带")
        try savedDeviceStore.upsert(device)
        let readings = try seedReadings(device: device, count: 2, metric: .heartRate)
        api.pushResults = [.failure(.network("offline")), .success(PushResult(appliedReadings: 2))]

        let engine = makeEngine()
        guard case .failure = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("断网应失败")
        }
        XCTAssertEqual(try readingsStore.pendingCount(), 2, "断网后本地累积，待恢复补传")

        guard case .success = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("恢复后应成功")
        }
        XCTAssertEqual(api.pushRequests.count, 2)
        XCTAssertEqual(api.pushRequests[0].key, api.pushRequests[1].key, "重试复用同一幂等体")
        XCTAssertEqual(
            Set(api.pushRequests[1].readings.map(\.id)),
            Set(readings.map { $0.id.uuidString })
        )
        XCTAssertEqual(try readingsStore.pendingCount(), 0)
    }

    func testSkippedReadingsAreSurfacedInSummaryMessage() throws {
        let device = makeSavedDevice(name: "重复读数")
        try savedDeviceStore.upsert(device)
        _ = try seedReadings(device: device, count: 2)
        api.pushResults = [.success(PushResult(appliedReadings: 0, skippedReadings: 2))]

        let engine = makeEngine()
        _ = runSync(engine)
        XCTAssertTrue(
            engine.status.lastOutcomeMessage?.contains("跳过重复 2 条") == true,
            "重复 id 的 skipped 结果需要明确展示：\(engine.status.lastOutcomeMessage ?? "nil")"
        )
        XCTAssertEqual(try readingsStore.pendingCount(), 0, "重复 id 也视为已处理，避免死循环重推")
    }

    func testReadingsArePrunedAfterSuccessfulSync() throws {
        let device = makeSavedDevice(name: "长期离线")
        try savedDeviceStore.upsert(device)

        let old = DeviceReading(
            deviceID: device.id,
            metric: .battery,
            value: 20,
            unit: "%",
            recordedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            syncState: .synced
        )
        try readingsStore.insert(old)
        let fresh = DeviceReading(
            deviceID: device.id,
            metric: .battery,
            value: 90,
            unit: "%",
            recordedAt: now.addingTimeInterval(-60)
        )
        try readingsStore.insert(fresh)
        api.pushResults = [.success(PushResult(appliedReadings: 1))]

        let engine = makeEngine()
        _ = runSync(engine)

        XCTAssertEqual(try readingsStore.count(deviceID: device.id), 1, "同步后清理 7 天前的已同步读数")
        XCTAssertEqual(try readingsStore.fetchRecent(deviceID: device.id, metric: .battery).first?.value, 90)
    }

    func testIdempotencyKeyIncludesReadings() {
        let device = makeSavedDevice(name: "键测试")
        let base = DeviceReading(
            deviceID: device.id,
            metric: .temperature,
            value: 21,
            unit: "℃",
            recordedAt: Date(timeIntervalSince1970: 100)
        )
        let other = DeviceReading(
            deviceID: device.id,
            metric: .temperature,
            value: 22,
            unit: "℃",
            recordedAt: Date(timeIntervalSince1970: 200)
        )
        let first = PushReading(reading: base, device: device)
        let second = PushReading(reading: other, device: device)

        XCTAssertEqual(
            SyncHashing.idempotencyKey(for: [], readings: [first]),
            SyncHashing.idempotencyKey(for: [], readings: [first]),
            "同内容重试键稳定"
        )
        XCTAssertNotEqual(
            SyncHashing.idempotencyKey(for: [], readings: [first]),
            SyncHashing.idempotencyKey(for: [], readings: [second]),
            "读数内容变化必须改变幂等键"
        )
        XCTAssertNotEqual(
            SyncHashing.idempotencyKey(for: [], readings: [first]),
            SyncHashing.idempotencyKey(for: [], readings: []),
            "空批次与含读数批次不同键"
        )
    }

    func testPushRequestOmitsReadingsWhenEmpty() throws {
        let request = PushRequest(clientID: "c1", devices: [], readings: [])
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"readings\""), "空读数不编码，兼容旧后端")
    }

    func testPushResultDecodesReadingCounters() throws {
        let json = """
        {"applied":[],"conflicts":[],"nextCursor":0,"appliedReadings":2,"skippedReadings":1}
        """
        let result = try JSONDecoder().decode(PushResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.appliedReadings, 2)
        XCTAssertEqual(result.skippedReadings, 1)
    }

    func testDetailViewModelShowsLocalReadingsAndMetricSwitch() throws {
        let device = makeSavedDevice(name: "温湿度计")
        try savedDeviceStore.upsert(device)
        let current = Date()
        let temperature = DeviceReading(
            deviceID: device.id, metric: .temperature, value: 22, unit: "℃",
            recordedAt: current.addingTimeInterval(-120)
        )
        let humidity = DeviceReading(
            deviceID: device.id, metric: .humidity, value: 55, unit: "%",
            recordedAt: current.addingTimeInterval(-60)
        )
        try readingsStore.insert(temperature)
        try readingsStore.insert(humidity)

        let viewModel = DeviceDetailViewModel(
            device: device,
            bluetooth: FakeBluetoothService(),
            productService: StubProductService(),
            cacheStore: DeviceInfoCacheStore(database: testDatabase.database),
            savedDeviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            readingsService: UnavailableReadingsAPI()
        )
        viewModel.start()
        viewModel.setVisible(true)

        XCTAssertEqual(
            viewModel.readings.metrics,
            [.humidity, .temperature],
            "离线兜底时指标清单按 lastAt 倒序"
        )
        XCTAssertEqual(viewModel.readings.selectedMetric, .humidity)
        XCTAssertEqual(viewModel.readings.points.map(\.value), [55])
        XCTAssertEqual(viewModel.readings.summary?.count, 1)
        XCTAssertTrue(viewModel.readings.isOfflineLocalData, "云端不可用标注离线")

        viewModel.selectReadingsMetric(.temperature)
        XCTAssertEqual(viewModel.readings.selectedMetric, .temperature)
        XCTAssertEqual(viewModel.readings.points.map(\.value), [22])
        XCTAssertEqual(viewModel.readings.unit, "℃")
    }

    func testDetailViewModelWithoutReadingsShowsGuidanceInsteadOfFakeData() throws {
        let device = makeSavedDevice(name: "新设备")
        try savedDeviceStore.upsert(device)
        let viewModel = DeviceDetailViewModel(
            device: device,
            bluetooth: FakeBluetoothService(),
            productService: StubProductService(),
            cacheStore: DeviceInfoCacheStore(database: testDatabase.database),
            savedDeviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            readingsService: UnavailableReadingsAPI()
        )
        viewModel.start()

        XCTAssertTrue(viewModel.readings.metrics.isEmpty)
        XCTAssertTrue(viewModel.readings.points.isEmpty)
        XCTAssertNil(viewModel.readings.summary, "没有数据就不展示汇总，不造 0 值")
        XCTAssertEqual(viewModel.readingsEmptyMessage, "连接设备后开始采集")
    }

    func testDetailViewModelReadingsEmptyMessagePointsToSettingsWhenBluetoothDenied() throws {
        let bluetooth = FakeBluetoothService(state: .poweredOn, authorization: .denied)
        let device = makeSavedDevice(name: "未授权")
        try savedDeviceStore.upsert(device)
        let viewModel = DeviceDetailViewModel(
            device: device,
            bluetooth: bluetooth,
            productService: StubProductService(),
            cacheStore: DeviceInfoCacheStore(database: testDatabase.database),
            savedDeviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            readingsService: UnavailableReadingsAPI()
        )
        XCTAssertTrue(viewModel.readingsEmptyMessage.contains("系统设置"))
    }
}
