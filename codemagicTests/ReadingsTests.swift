import UIKit
import XCTest
@testable import codemagic

final class ReadingParserTests: XCTestCase {
    private func sample(
        _ kind: ReadingCharacteristic,
        _ bytes: [UInt8]
    ) -> BluetoothReadingSample {
        BluetoothReadingSample(
            peripheralID: UUID(),
            characteristic: kind,
            data: Data(bytes),
            receivedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    // MARK: - 心率

    func testHeartRateUInt8() {
        let result = ReadingParser.parse(sample(.heartRate, [0x00, 72]))
        XCTAssertEqual(result.readings, [ParsedReading(metric: .heartRate, value: 72, unit: "bpm")])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testHeartRateUInt16() {
        let result = ReadingParser.parse(sample(.heartRate, [0x01, 0x2C, 0x01]))
        XCTAssertEqual(result.readings, [ParsedReading(metric: .heartRate, value: 300, unit: "bpm")])
    }

    func testHeartRateRejectsEmptyShortAndZero() {
        let empty = ReadingParser.parse(sample(.heartRate, []))
        XCTAssertTrue(empty.readings.isEmpty)
        XCTAssertEqual(empty.failures.count, 1)

        let flagsOnly = ReadingParser.parse(sample(.heartRate, [0x00]))
        XCTAssertTrue(flagsOnly.readings.isEmpty)

        let zero = ReadingParser.parse(sample(.heartRate, [0x00, 0x00]))
        XCTAssertTrue(zero.readings.isEmpty, "0 bpm 视为无效读数，不写脏数据")
    }

    func testHeartRateRejectsOutOfRangeUInt16() {
        let result = ReadingParser.parse(sample(.heartRate, [0x01, 0xFF, 0xFF]))
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertFalse(result.failures.isEmpty)
    }

    // MARK: - 电池

    func testBatteryValidAndInvalid() {
        let valid = ReadingParser.parse(sample(.battery, [88]))
        XCTAssertEqual(valid.readings, [ParsedReading(metric: .battery, value: 88, unit: "%")])

        let empty = ReadingParser.parse(sample(.battery, []))
        XCTAssertTrue(empty.readings.isEmpty)

        let tooHigh = ReadingParser.parse(sample(.battery, [120]))
        XCTAssertTrue(tooHigh.readings.isEmpty, "超过 100% 的百分比丢弃")
    }

    // MARK: - 温度

    func testTemperatureScaledCentiseconds() {
        // 2350 = 23.50 ℃
        let result = ReadingParser.parse(sample(.temperature, [0x2E, 0x09]))
        XCTAssertEqual(result.readings, [ParsedReading(metric: .temperature, value: 23.5, unit: "℃")])
    }

    func testTemperatureNegativeScaledCentiseconds() {
        // -500 = -5.00 ℃
        let bytes = Data([0x0C, 0xFE])
        let result = ReadingParser.parse(sample(.temperature, Array(bytes)))
        XCTAssertEqual(result.readings.first?.value, -5.0)
    }

    func testTemperatureHalfPrecisionFallback() {
        // binary16: 0x4200 = 3.0；按 0.01℃ 缩放则是 168.96，超出合理范围后回退半精度。
        let result = ReadingParser.parse(sample(.temperature, [0x00, 0x42]))
        XCTAssertEqual(result.readings, [ParsedReading(metric: .temperature, value: 3.0, unit: "℃")])
    }

    func testTemperatureFloat32() {
        var bytes: [UInt8] = []
        var value: Float = 21.5
        withUnsafeBytes(of: &value) { raw in
            bytes = [raw[0], raw[1], raw[2], raw[3]]
        }
        let result = ReadingParser.parse(sample(.temperature, bytes))
        XCTAssertEqual(result.readings.first?.value, 21.5)
    }

    func testTemperatureUnsupportedLengthAndOutOfRange() {
        let short = ReadingParser.parse(sample(.temperature, [1, 2, 3]))
        XCTAssertTrue(short.readings.isEmpty)

        // 0x7FFF 按 0.01℃ 缩放为 327.67 ℃、按半精度为 NaN，两种解释都不合法。
        let outOfRange = ReadingParser.parse(sample(.temperature, [0xFF, 0x7F]))
        XCTAssertTrue(outOfRange.readings.isEmpty)

        // float32 500 ℃ 同样越界。
        let floatOutOfRange = ReadingParser.parse(sample(.temperature, [0x00, 0x00, 0xFA, 0x43]))
        XCTAssertTrue(floatOutOfRange.readings.isEmpty)
    }

    // MARK: - Nordic UART

    func testNordicMetricValue() {
        let result = ReadingParser.parse(sample(.nordicUART, Array("temperature=23.5".utf8)))
        XCTAssertEqual(result.readings, [ParsedReading(metric: .temperature, value: 23.5, unit: "℃")])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testNordicUnknownMetricBecomesOther() {
        let result = ReadingParser.parse(sample(.nordicUART, Array("lux=120".utf8)))
        XCTAssertEqual(result.readings, [ParsedReading(metric: .other, value: 120, unit: "")])
    }

    func testNordicPlainNumericLine() {
        let result = ReadingParser.parse(sample(.nordicUART, Array("36.6\r\n".utf8)))
        XCTAssertEqual(result.readings, [ParsedReading(metric: .other, value: 36.6, unit: "")])
    }

    func testNordicMultipleLinesKeepsPartialFailures() {
        let text = "heart_rate=72\nco2=800\nbroken line\n"
        let result = ReadingParser.parse(sample(.nordicUART, Array(text.utf8)))
        XCTAssertEqual(result.readings.count, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.readings.last?.metric, .co2)
    }

    func testNordicRejectsNonNumericAndNaNAndEmptyKey() {
        let text = "temperature=hot\npressure=NaN\n=42"
        let result = ReadingParser.parse(sample(.nordicUART, Array(text.utf8)))
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(result.failures.count, 3)
    }

    func testNordicRejectsTooLongPayloadAndLine() {
        let longPayload = String(repeating: "a=1;", count: 80)
        let payload = ReadingParser.parse(sample(.nordicUART, Array(longPayload.utf8)))
        XCTAssertTrue(payload.readings.isEmpty)
        XCTAssertEqual(payload.failures.count, 1)

        let longLine = "temperature=" + String(repeating: "1", count: 70)
        let line = ReadingParser.parse(sample(.nordicUART, Array(longLine.utf8)))
        XCTAssertTrue(line.readings.isEmpty)
        XCTAssertEqual(line.failures.count, 1)
    }

    func testNordicEmptyAndNonUTF8AreRejected() {
        XCTAssertTrue(ReadingParser.parse(sample(.nordicUART, [])).readings.isEmpty)
        XCTAssertTrue(ReadingParser.parse(sample(.nordicUART, [0xFF, 0xFE])).readings.isEmpty)
    }
}

final class ReadingsStoreTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var store: ReadingsStore!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        store = ReadingsStore(database: testDatabase.database)
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        testDatabase = nil
    }

    func testInsertAndFetchRecentDescendingWithLimit() throws {
        let deviceID = UUID()
        let base = Date(timeIntervalSince1970: 1000)
        for index in 0..<61 {
            try store.insert(
                DeviceReading(
                    deviceID: deviceID,
                    metric: .heartRate,
                    value: Double(index),
                    unit: "bpm",
                    recordedAt: base.addingTimeInterval(Double(index))
                )
            )
        }

        let recent = try store.fetchRecent(deviceID: deviceID, metric: .heartRate, limit: 60)
        XCTAssertEqual(recent.count, 60, "最多返回 60 点")
        XCTAssertEqual(recent.first?.value, 60, "最新在最前")
        XCTAssertEqual(recent.last?.value, 1)

        let window = try store.fetch(
            deviceID: deviceID,
            metric: .heartRate,
            from: base.addingTimeInterval(50)
        )
        XCTAssertEqual(window.map(\.value), [50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60], "窗口查询升序")
    }

    func testDuplicateInsertIsIgnored() throws {
        let reading = DeviceReading(
            deviceID: UUID(),
            metric: .temperature,
            value: 20,
            unit: "℃",
            recordedAt: Date(timeIntervalSince1970: 10)
        )
        try store.insert(reading)
        try store.insert(reading)
        XCTAssertEqual(try store.count(deviceID: reading.deviceID), 1)
    }

    func testAvailableMetricsUsesWhitelistOrderAndUnknownFallsBackToOther() throws {
        let deviceID = UUID()
        let now = Date()
        for metric in [ReadingMetric.other, .battery, .heartRate] {
            try store.insert(
                DeviceReading(deviceID: deviceID, metric: metric, value: 1, unit: metric.defaultUnit, recordedAt: now)
            )
        }
        // 手工写入一个白名单外指标，读取侧必须归一为 other。
        try testDatabase.database.execute(
            """
            INSERT INTO readings (id, device_id, metric, value, unit, recorded_at, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(UUID().uuidString),
                .text(deviceID.uuidString),
                .text("lux"),
                .double(120),
                .text("lx"),
                .double(now.timeIntervalSince1970),
                .text(SyncState.pending.rawValue),
            ]
        )

        let metrics = try store.availableMetrics(deviceID: deviceID)
        XCTAssertEqual(metrics, [.battery, .heartRate, .other], "按白名单顺序，且未知指标归一为 other")
    }

    func testPendingFetchAndMarkSynced() throws {
        let deviceID = UUID()
        for index in 0..<3 {
            try store.insert(
                DeviceReading(
                    deviceID: deviceID,
                    metric: .co2,
                    value: Double(index),
                    unit: "ppm",
                    recordedAt: Date(timeIntervalSince1970: Double(index))
                )
            )
        }
        XCTAssertEqual(try store.pendingCount(), 3)

        let pending = try store.fetchPending(limit: 2)
        XCTAssertEqual(pending.count, 2)
        try store.markSynced(ids: pending.map(\.id))
        XCTAssertEqual(try store.pendingCount(), 1)
        XCTAssertEqual(try store.fetchPending().first?.value, 2, "剩余未同步读数按时间升序")
    }

    func testPruneRemovesSyncedOlderThanSevenDaysButKeepsPending() throws {
        let deviceID = UUID()
        let now = Date()
        let old = now.addingTimeInterval(-8 * 24 * 60 * 60)

        let syncedOld = DeviceReading(
            deviceID: deviceID, metric: .temperature, value: 1, unit: "℃",
            recordedAt: old, syncState: .synced
        )
        let pendingOld = DeviceReading(
            deviceID: deviceID, metric: .temperature, value: 2, unit: "℃",
            recordedAt: old, syncState: .pending
        )
        let syncedNew = DeviceReading(
            deviceID: deviceID, metric: .temperature, value: 3, unit: "℃",
            recordedAt: now.addingTimeInterval(-60), syncState: .synced
        )
        try store.insert(syncedOld)
        try store.insert(pendingOld)
        try store.insert(syncedNew)

        let removed = try store.prune(olderThan: now.addingTimeInterval(-7 * 24 * 60 * 60))
        XCTAssertEqual(removed, 1, "只删除超过 7 天且已同步的记录")
        XCTAssertEqual(try store.count(deviceID: deviceID), 2, "未上传读数保留以便补传，新读数保留")
        XCTAssertTrue(try store.fetchPending().contains { $0.id == pendingOld.id })
    }

    /// 离线超过 7 天（甚至 30 天）的 pending 读数不得被清理，必须留待补传。
    func testPruneKeepsThirtyDayOldPending() throws {
        let deviceID = UUID()
        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)

        let syncedOld = DeviceReading(
            deviceID: deviceID, metric: .heartRate, value: 70, unit: "bpm",
            recordedAt: thirtyDaysAgo, syncState: .synced
        )
        let pendingOld = DeviceReading(
            deviceID: deviceID, metric: .heartRate, value: 88, unit: "bpm",
            recordedAt: thirtyDaysAgo, syncState: .pending
        )
        try store.insert(syncedOld)
        try store.insert(pendingOld)

        let removed = try store.prune(olderThan: now.addingTimeInterval(-7 * 24 * 60 * 60))
        XCTAssertEqual(removed, 1, "只删已同步的过期记录")
        XCTAssertEqual(try store.count(deviceID: deviceID), 1)
        XCTAssertEqual(try store.fetchPending().map(\.id), [pendingOld.id], "30 天前的 pending 仍在")
    }

    /// 模拟 v4 数据库（无 readings 表）升级到 v5。
    func testMigrationFromV4CreatesReadingsTable() throws {
        let path = testDatabase.directory.appendingPathComponent("legacy-v4.sqlite").path
        let legacy = try SQLiteDatabase(path: path)
        try legacy.execute("DROP TABLE IF EXISTS readings;")
        try legacy.execute("PRAGMA user_version = 4;")
        legacy.close()

        let migrated = try SQLiteDatabase(path: path)
        defer { migrated.close() }

        let version = try migrated.query("PRAGMA user_version;").first?.integer("user_version")
        XCTAssertEqual(version, 13, "迁移后版本为 13")

        let store = ReadingsStore(database: migrated)
        let reading = DeviceReading(
            deviceID: UUID(),
            metric: .humidity,
            value: 45,
            unit: "%",
            recordedAt: Date(timeIntervalSince1970: 10)
        )
        try store.insert(reading)
        XCTAssertEqual(try store.count(deviceID: reading.deviceID), 1, "v5 readings 表可读写")
    }
}

final class ReadingsIngestorTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var deviceStore: SavedDeviceStore!
    private var readingsStore: ReadingsStore!
    private var logStore: ScanLogStore!
    private var device: SavedDevice!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        deviceStore = SavedDeviceStore(database: testDatabase.database)
        readingsStore = ReadingsStore(database: testDatabase.database)
        logStore = ScanLogStore(database: testDatabase.database)
        device = makeSavedDevice(name: "心率带")
        try deviceStore.upsert(device)
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        testDatabase = nil
    }

    private func makeIngestor() -> ReadingsIngestor {
        ReadingsIngestor(readingsStore: readingsStore, deviceStore: deviceStore, logStore: logStore)
    }

    func testValidSampleIsParsedAndSaved() throws {
        let ingestor = makeIngestor()
        var savedDeviceID: UUID?
        ingestor.onSaved = { savedDeviceID = $0 }

        let sample = BluetoothReadingSample(
            peripheralID: device.peripheralID,
            characteristic: .heartRate,
            data: Data([0x00, 80]),
            receivedAt: Date(timeIntervalSince1970: 500)
        )
        let saved = ingestor.ingest(sample)

        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.metric, .heartRate)
        XCTAssertEqual(saved.first?.value, 80)
        XCTAssertEqual(savedDeviceID, device.id)
        XCTAssertEqual(try readingsStore.count(deviceID: device.id), 1)
    }

    func testParseFailureIsLoggedAndNothingIsStored() throws {
        let ingestor = makeIngestor()
        _ = ingestor.ingest(
            BluetoothReadingSample(
                peripheralID: device.peripheralID,
                characteristic: .temperature,
                data: Data([0xFF]),
                receivedAt: Date()
            )
        )

        XCTAssertEqual(try readingsStore.count(deviceID: device.id), 0, "解析失败不写脏数据")
        let logs = try logStore.fetchRecent(limit: 10)
        XCTAssertEqual(logs.first?.category, .reading)
        XCTAssertEqual(logs.first?.level, .warning)
        XCTAssertTrue(logs.first?.message.contains("解析失败") ?? false)
    }

    func testUnknownPeripheralIsDroppedWithLog() throws {
        let ingestor = makeIngestor()
        _ = ingestor.ingest(
            BluetoothReadingSample(
                peripheralID: UUID(),
                characteristic: .battery,
                data: Data([50]),
                receivedAt: Date()
            )
        )
        XCTAssertEqual(try readingsStore.pendingCount(), 0)
        XCTAssertEqual(try logStore.fetchRecent(limit: 10).first?.category, .reading)
    }

    // MARK: - 读数阈值规则接入

    /// 温度 0x2A6E：uint16、0.01 ℃ 放大，小端序。
    private func temperatureSample(_ celsius: Double, at time: TimeInterval) -> BluetoothReadingSample {
        let raw = UInt16((celsius * 100).rounded())
        return BluetoothReadingSample(
            peripheralID: device.peripheralID,
            characteristic: .temperature,
            data: Data([UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF)]),
            receivedAt: Date(timeIntervalSince1970: time)
        )
    }

    private func makeRuleIngestor(
        rule: DeviceRule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ReadingsIngestor {
        let ruleStore = DeviceRuleStore(database: testDatabase.database)
        try ruleStore.upsert(rule)
        return ReadingsIngestor(
            readingsStore: readingsStore,
            deviceStore: deviceStore,
            logStore: logStore,
            ruleStore: ruleStore,
            ruleEvaluator: RuleEvaluator()
        )
    }

    func testReadingRuleTriggerIsLoggedWithValueThresholdAndUnit() throws {
        let rule = DeviceRule(
            name: "高温告警",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterOrEqual,
            readingThreshold: 30,
            consecutive: 2,
            deviceID: device.id
        )
        let ingestor = try makeRuleIngestor(rule: rule)

        _ = ingestor.ingest(temperatureSample(31.5, at: 500))
        XCTAssertEqual(try logStore.countRuleAlerts(since: Date(timeIntervalSince1970: 0)), 0, "第一条未满足防抖")

        _ = ingestor.ingest(temperatureSample(32.4, at: 501))
        let alerts = try logStore.fetchRecent(limit: 10).filter { $0.category == .rule }
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].level, .warning)
        XCTAssertTrue(alerts[0].message.contains("32.4 ℃"))
        XCTAssertTrue(alerts[0].message.contains("30 ℃"))
        XCTAssertTrue(alerts[0].message.contains("连续 2 条"))
        XCTAssertTrue(alerts[0].message.contains(device.displayName))
        XCTAssertEqual(alerts[0].occurredAt, Date(timeIntervalSince1970: 501))
        XCTAssertEqual(try readingsStore.count(deviceID: device.id), 2, "读数照常落库")
    }

    func testReadingRuleRecoveryLogsInfoOnlyAfterTrigger() throws {
        let rule = DeviceRule(
            name: "高温告警",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterOrEqual,
            readingThreshold: 30,
            consecutive: 1,
            deviceID: device.id
        )
        let ingestor = try makeRuleIngestor(rule: rule)

        _ = ingestor.ingest(temperatureSample(28, at: 600))
        XCTAssertEqual(try logStore.fetchRecent(limit: 10).filter { $0.category == .rule }.count, 0)

        _ = ingestor.ingest(temperatureSample(31, at: 601))
        _ = ingestor.ingest(temperatureSample(28.5, at: 602))
        let ruleLogs = try logStore.fetchRecent(limit: 10)
            .filter { $0.category == .rule }
            .sorted { $0.occurredAt < $1.occurredAt }
        XCTAssertEqual(ruleLogs.count, 2)
        XCTAssertEqual(ruleLogs[0].level, .warning)
        XCTAssertEqual(ruleLogs[1].level, .info, "恢复只记 info，不进「最近触发」")
        XCTAssertTrue(ruleLogs[1].message.contains("已恢复"))
        XCTAssertEqual(try logStore.countRuleAlerts(since: Date(timeIntervalSince1970: 0)), 1)
    }

    func testDisabledReadingRuleDoesNotTrigger() throws {
        let rule = DeviceRule(
            name: "停用规则",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterOrEqual,
            readingThreshold: 30,
            consecutive: 1,
            isEnabled: false
        )
        let ingestor = try makeRuleIngestor(rule: rule)
        _ = ingestor.ingest(temperatureSample(35, at: 700))
        XCTAssertEqual(try logStore.fetchRecent(limit: 10).filter { $0.category == .rule }.count, 0)
    }
}

final class ReadingsChartGeometryTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 300, height: 180)

    func testZeroPoints() {
        XCTAssertTrue(ReadingsChartGeometry.points(values: [], in: rect).isEmpty)
    }

    func testOnePointIsCentered() {
        let points = ReadingsChartGeometry.points(values: [42], in: rect)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].x, rect.midX)
        XCTAssertEqual(points[0].y, rect.midY)
    }

    func testSixtyPointsSpanWidthAndStayInsideRect() {
        let values = (0..<60).map { Double($0) }
        let points = ReadingsChartGeometry.points(values: values, in: rect)
        XCTAssertEqual(points.count, 60)
        XCTAssertEqual(points.first?.x, rect.minX)
        XCTAssertEqual(points.last?.x, rect.maxX)
        XCTAssertEqual(points.first?.y, rect.maxY, "最小值在底部")
        XCTAssertEqual(points.last?.y, rect.minY, "最大值在顶部")
        XCTAssertTrue(points.allSatisfy { $0.y >= rect.minY && $0.y <= rect.maxY })
    }

    func testFlatSeriesIsVerticallyCentered() {
        let points = ReadingsChartGeometry.points(values: Array(repeating: 21.5, count: 10), in: rect)
        XCTAssertEqual(points.count, 10)
        XCTAssertTrue(
            points.allSatisfy { abs($0.y - rect.midY) < 0.001 },
            "全相等时避免除零并居中"
        )
    }
}

/// 图表点选：命中判定是纯函数，空白、近邻阈值与最近桶都在这里覆盖。
final class ReadingsChartSelectionTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func buckets(_ values: [Double]) -> [ReadingsChartBucket] {
        values.enumerated().map { index, value in
            ReadingsChartBucket(
                start: base.addingTimeInterval(Double(index) * 3_600),
                end: base.addingTimeInterval(Double(index + 1) * 3_600),
                average: value,
                minValue: value - 1,
                maxValue: value + 1,
                count: 6,
                lastValue: value + 0.4
            )
        }
    }

    private func layout(_ values: [Double]) -> ReadingsChartLayout {
        let items = buckets(values)
        let interval = DateInterval(
            start: items.first!.start,
            end: items.last!.end
        )
        return ReadingsChartGeometry.layout(buckets: items, interval: interval, in: rect)
    }

    func testEmptyLayoutNeverHits() {
        let empty = ReadingsChartGeometry.layout(
            buckets: [],
            interval: DateInterval(start: base, duration: 86_400),
            in: rect
        )
        XCTAssertNil(ReadingsChartGeometry.hitIndex(for: CGPoint(x: rect.midX, y: rect.midY), layout: empty))
    }

    func testTapOnPointHitsItsBucket() {
        let layout = layout([20, 24, 22])
        for (index, point) in layout.points.enumerated() {
            XCTAssertEqual(ReadingsChartGeometry.hitIndex(for: point, layout: layout), index)
        }
    }

    func testTapNearPointStillHitsNearestBucket() {
        let layout = layout([20, 24, 22])
        let target = layout.points[1]
        let near = CGPoint(x: target.x + 8, y: target.y + 6)
        XCTAssertEqual(ReadingsChartGeometry.hitIndex(for: near, layout: layout), 1, "近邻阈值内按最近桶命中")
    }

    func testTapOnBlankAreaDoesNotHit() {
        let layout = layout([20, 24, 22])
        let point = layout.points[1]
        XCTAssertNil(
            ReadingsChartGeometry.hitIndex(
                for: CGPoint(x: point.x, y: point.y - 40),
                layout: layout
            ),
            "超出近邻阈值的空白区域不命中"
        )
        XCTAssertNil(
            ReadingsChartGeometry.hitIndex(
                for: CGPoint(x: rect.maxX - 4, y: rect.maxY - 4),
                layout: layout
            ),
            "远离折线不命中"
        )
    }

    func testProximityIsConfigurable() {
        let layout = layout([20])
        let point = layout.points[0]
        let offset = CGPoint(x: point.x, y: point.y + 15)
        XCTAssertEqual(ReadingsChartGeometry.hitIndex(for: offset, layout: layout), 0)
        XCTAssertNil(ReadingsChartGeometry.hitIndex(for: offset, layout: layout, proximity: 10))
    }

    func testSelectionDoesNotChangeYAxis() {
        let items = buckets([20, 24, 22])
        let interval = DateInterval(start: items.first!.start, end: items.last!.end)
        let before = ReadingsChartGeometry.layout(buckets: items, interval: interval, in: rect)
        // 选中只影响绘制状态；布局仍由全部桶决定，Y 轴范围不变。
        _ = ReadingsChartGeometry.hitIndex(for: before.points[1], layout: before)
        let after = ReadingsChartGeometry.layout(buckets: items, interval: interval, in: rect)
        XCTAssertEqual(before.yMin, after.yMin)
        XCTAssertEqual(before.yMax, after.yMax)
    }

    func testBucketSummaryUsesLocalTimeAndUnit() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 5, hour: 8, minute: 0
        ))!
        let bucket = ReadingsChartBucket(
            start: start,
            end: start.addingTimeInterval(3_600),
            average: 22.5,
            minValue: 21.5,
            maxValue: 23,
            count: 12,
            lastValue: 22.8
        )
        let summary = ReadingsChartGeometry.bucketSummary(
            bucket,
            unit: "℃",
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(
            summary,
            "08:00–09:00 · 最小 21.5 ℃ · 最大 23 ℃ · 平均 22.5 ℃ · 最新 22.8 ℃ · 12 条"
        )
    }

    func testBucketSummaryShowsDashWhenLastValueMissing() {
        let bucket = ReadingsChartBucket(
            start: base,
            end: base.addingTimeInterval(3_600),
            average: 30,
            minValue: 29,
            maxValue: 31,
            count: 2
        )
        let summary = ReadingsChartGeometry.bucketSummary(
            bucket,
            unit: "%",
            timeZone: TimeZone(identifier: "UTC")!,
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertTrue(summary.contains("最新 —"))
        XCTAssertTrue(summary.contains("最小 29 %"))
    }
}
