import XCTest
@testable import codemagic

/// 后台采集路径：相信读写入库、7 天保留保护 pending、后台推送限流与节流。
final class BackgroundCollectionTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var deviceStore: SavedDeviceStore!
    private var readingsStore: ReadingsStore!
    private var logStore: ScanLogStore!
    private var metadata: SyncMetadataStore!
    private var tokenStore: InMemoryTokenStore!
    private var api: FakeSyncAPI!
    private var now: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        suiteName = "codemagic.background.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        metadata = SyncMetadataStore(defaults: defaults)
        deviceStore = SavedDeviceStore(database: testDatabase.database)
        readingsStore = ReadingsStore(database: testDatabase.database)
        logStore = ScanLogStore(database: testDatabase.database)
        tokenStore = InMemoryTokenStore()
        api = FakeSyncAPI()
        now = Date(timeIntervalSince1970: 1_000_000)
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    func testBackgroundPushIsLimitedAndThrottled() throws {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        let device = makeSavedDevice(name: "后台设备")
        try deviceStore.upsert(device)
        for index in 0..<250 {
            try readingsStore.insert(
                DeviceReading(
                    deviceID: device.id,
                    metric: .heartRate,
                    value: 70,
                    unit: "bpm",
                    recordedAt: now.addingTimeInterval(-Double(index))
                )
            )
        }
        let engine = makeEngine()

        var pushCount = 0
        let first = expectation(description: "第一次后台推送")
        engine.pushPendingInBackground { result in
            if case .failure(let error) = result { XCTFail("后台推送失败：\(error)") }
            pushCount += 1
            first.fulfill()
        }
        wait(for: [first], timeout: 2)

        XCTAssertEqual(pushCount, 1)
        XCTAssertTrue(api.changesRequests.isEmpty, "后台唤醒不得拉取增量")
        XCTAssertEqual(api.pushRequests.count, 1)
        XCTAssertEqual(api.pushRequests.first?.readings.count, 200)
        XCTAssertEqual(try readingsStore.fetchPending().count, 50)

        // 15 分钟内再次唤醒：直接跳过，不发任何请求。
        let throttled = expectation(description: "节流跳过")
        engine.pushPendingInBackground { result in
            if case .failure(let error) = result { XCTFail("节流应成功返回：\(error)") }
            throttled.fulfill()
        }
        wait(for: [throttled], timeout: 1)
        XCTAssertEqual(api.pushRequests.count, 1)

        now = now.addingTimeInterval(16 * 60)
        let resumed = expectation(description: "间隔后继续推送")
        engine.pushPendingInBackground { result in
            if case .failure(let error) = result { XCTFail("继续推送失败：\(error)") }
            resumed.fulfill()
        }
        wait(for: [resumed], timeout: 2)
        XCTAssertEqual(api.pushRequests.count, 2)
        XCTAssertEqual(api.pushRequests.last?.readings.count, 50)
        XCTAssertEqual(try readingsStore.fetchPending().count, 0)
    }

    func testBackgroundPushSkipsWithoutSessionAndNeverCreatesAccount() throws {
        let engine = makeEngine()
        let expectation = expectation(description: "无 token 跳过")
        engine.pushPendingInBackground { result in
            if case .failure(let error) = result { XCTFail("无 token 应静默跳过：\(error)") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(api.authCount, 0)
        XCTAssertTrue(api.pushRequests.isEmpty)
    }

    func testBackgroundIngestKeepsPendingBeyondRetentionUntilSynced() throws {
        let device = makeSavedDevice(name: "旧设备")
        try deviceStore.upsert(device)
        let ingestor = ReadingsIngestor(
            readingsStore: readingsStore,
            deviceStore: deviceStore,
            logStore: logStore
        )
        let receivedAt = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let saved = ingestor.ingest(
            BluetoothReadingSample(
                peripheralID: device.peripheralID,
                characteristic: .heartRate,
                data: Data([0x00, 80]),
                receivedAt: receivedAt
            )
        )
        XCTAssertEqual(saved.count, 1)

        // 后台路径同样是「先入库」；超过 7 天但仍是 pending 的数据不得被保留清理误删。
        let removedPending = try readingsStore.prune(olderThan: now.addingTimeInterval(-7 * 24 * 60 * 60))
        XCTAssertEqual(removedPending, 0)
        XCTAssertEqual(try readingsStore.fetchPending().count, 1)

        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        let engine = makeEngine()
        let pushed = expectation(description: "后台推送旧读数")
        engine.pushPendingInBackground { result in
            if case .failure(let error) = result { XCTFail("后台推送失败：\(error)") }
            pushed.fulfill()
        }
        wait(for: [pushed], timeout: 2)
        XCTAssertEqual(api.pushRequests.first?.readings.count, 1)
        XCTAssertEqual(try readingsStore.fetchPending().count, 0)
        // 推送成功即标记 synced，后台路径随后的 7 天保留清理会删除这条旧记录（pending 保护已在前一步验证）。
        XCTAssertEqual(try readingsStore.count(deviceID: device.id), 0)
    }

    private func makeEngine() -> SyncEngine {
        SyncEngine(
            api: api,
            tokenStore: tokenStore,
            metadataStore: metadata,
            deviceStore: deviceStore,
            readingsStore: readingsStore,
            logStore: logStore,
            now: { [unowned self] in self.now }
        )
    }
}
