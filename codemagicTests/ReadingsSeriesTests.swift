import UIKit
import XCTest
@testable import codemagic

/// 长周期分桶、时间定位几何与云/端指标清单的回归用例。
final class ReadingsSeriesTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 300, height: 180)

    private func bucket(
        startOffset: TimeInterval,
        value: Double,
        low: Double? = nil,
        high: Double? = nil,
        count: Int = 1,
        duration: TimeInterval = 3_600,
        now: Date
    ) -> ReadingsChartBucket {
        let start = now.addingTimeInterval(startOffset)
        return ReadingsChartBucket(
            start: start,
            end: start.addingTimeInterval(duration),
            average: value,
            minValue: low ?? value,
            maxValue: high ?? value,
            count: count
        )
    }

    // MARK: - 区间与 bucket 映射

    func testRangeMapsToServerBucketAndStaysUnderFiveHundredBuckets() {
        XCTAssertEqual(ReadingsRange.hour1.bucket, .minute)
        XCTAssertEqual(ReadingsRange.hour24.bucket, .hour)
        XCTAssertEqual(ReadingsRange.day7.bucket, .hour)
        XCTAssertEqual(ReadingsRange.day30.bucket, .day)

        XCTAssertEqual(ReadingsRange.hour1.bucketCount, 60)
        XCTAssertEqual(ReadingsRange.hour24.bucketCount, 24)
        XCTAssertEqual(ReadingsRange.day7.bucketCount, 168)
        XCTAssertEqual(ReadingsRange.day30.bucketCount, 30)

        for range in ReadingsRange.allCases {
            XCTAssertTrue(range.isSupportedByServer, "\(range.title) 的桶数必须在 500 以内")
            XCTAssertLessThanOrEqual(range.bucketCount, 500)
        }
    }

    func testRangeIntervalMatchesDuration() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ReadingsRange.hour24.interval(now: now).duration, 86_400)
        XCTAssertEqual(ReadingsRange.day30.interval(now: now).duration, 30 * 86_400)
        XCTAssertEqual(ReadingsRange.day30.interval(now: now).end, now)
    }

    func testBucketAlignedStartFollowsUTCGrid() {
        // 2026-11-05T01:59:59.5Z：小时桶对齐 01:00，天桶对齐 00:00，分钟桶对齐 01:59。
        let date = Date(timeIntervalSince1970: 1_788_472_799.5)
        XCTAssertEqual(ReadingsBucket.hour.alignedStart(for: date).timeIntervalSince1970, 1_788_469_200)
        XCTAssertEqual(ReadingsBucket.day.alignedStart(for: date).timeIntervalSince1970, 1_788_393_600)
        XCTAssertEqual(ReadingsBucket.minute.alignedStart(for: date).timeIntervalSince1970, 1_788_472_740)
    }

    // MARK: - 服务端响应解码与本地兜底

    func testSeriesDecodingSortsAndDropsEmptyBuckets() throws {
        let json = """
        {
          "metric": "heart_rate",
          "unit": "bpm",
          "bucket": "1h",
          "from": "2026-11-04T00:00:00Z",
          "to": "2026-11-05T00:00:00Z",
          "buckets": [
            {"start": "2026-11-04T02:00:00Z", "end": "2026-11-04T03:00:00Z", "count": 5, "min": 60, "max": 90, "avg": 75, "last": 80},
            {"start": "2026-11-04T01:00:00Z", "end": "2026-11-04T02:00:00Z", "count": 0, "min": null, "max": null, "avg": null, "last": null},
            {"start": "2026-11-04T00:00:00Z", "end": "2026-11-04T01:00:00Z", "count": 2, "min": 70, "max": 72, "avg": 71, "last": 72}
          ]
        }
        """
        let series = try JSONDecoder().decode(ReadingsSeries.self, from: Data(json.utf8))
        XCTAssertEqual(series.unit, "bpm")
        XCTAssertEqual(series.bucket, .hour)
        XCTAssertEqual(series.buckets.count, 3, "解码保留服务端原样")
        XCTAssertEqual(series.chartBuckets.map(\.average), [71, 75], "按 start 升序且过滤空桶")

        let empty = try JSONDecoder().decode(
            ReadingsSeries.self,
            from: Data("""
            {"metric":"heart_rate","unit":"","bucket":"1d","from":"2026-11-03T00:00:00Z","to":"2026-11-04T00:00:00Z","buckets":[]}
            """.utf8)
        )
        XCTAssertTrue(empty.chartBuckets.isEmpty)
    }

    func testLocalSeriesAggregatesWithSameUTCBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deviceID = UUID()
        let readings = [
            DeviceReading(deviceID: deviceID, metric: .temperature, value: 20, unit: "℃", recordedAt: now.addingTimeInterval(-10_800)),
            DeviceReading(deviceID: deviceID, metric: .temperature, value: 24, unit: "℃", recordedAt: now.addingTimeInterval(-10_700)),
            DeviceReading(deviceID: deviceID, metric: .temperature, value: 22, unit: "℃", recordedAt: now.addingTimeInterval(-60)),
        ]

        let hourly = ReadingsSeries.local(readings: readings, range: .hour24, now: now)
        XCTAssertEqual(hourly.buckets.count, 2, "两个不同小时桶")
        XCTAssertEqual(hourly.buckets.map(\.count), [2, 1])
        XCTAssertEqual(hourly.buckets.first?.minValue, 20)
        XCTAssertEqual(hourly.buckets.first?.maxValue, 24)
        XCTAssertEqual(hourly.buckets.first?.avg, 22)
        XCTAssertEqual(hourly.unit, "℃")

        let daily = ReadingsSeries.local(readings: readings, range: .day30, now: now)
        XCTAssertEqual(daily.buckets.count, 1, "30 天区间按天分桶")
        XCTAssertEqual(daily.buckets.first?.count, 3)
        XCTAssertEqual(daily.chartBuckets.first?.maxValue, 24)

        let empty = ReadingsSeries.local(readings: [], range: .hour1, now: now)
        XCTAssertTrue(empty.buckets.isEmpty)
        XCTAssertEqual(empty.unit, "")
    }

    // MARK: - 时间定位几何

    func testEmptyBucketsProduceEmptyLayout() {
        let layout = ReadingsChartGeometry.layout(
            buckets: [],
            interval: DateInterval(start: Date(), duration: 86_400),
            in: rect
        )
        XCTAssertTrue(layout.isEmpty)
        XCTAssertTrue(layout.segments.isEmpty)
    }

    func testSingleBucketSitsOnItsTimePosition() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let interval = DateInterval(start: now, duration: 3_600)
        let layout = ReadingsChartGeometry.layout(
            buckets: [bucket(startOffset: 1_800, value: 42, now: now)],
            interval: interval,
            in: rect
        )
        XCTAssertEqual(layout.points.count, 1)
        XCTAssertEqual(layout.points[0].x, rect.midX, accuracy: 0.5, "单桶按真实时间落点，不居中臆造")
        XCTAssertTrue(layout.bandPolygons.isEmpty, "单桶无法组成区间带")
    }

    func testEqualSpacingBucketsSpanFullWidth() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let interval = DateInterval(start: now, duration: 24 * 3_600)
        let buckets = (0..<24).map { hour in
            bucket(startOffset: Double(hour) * 3_600, value: Double(hour), now: now)
        }
        let layout = ReadingsChartGeometry.layout(buckets: buckets, interval: interval, in: rect)
        XCTAssertEqual(layout.points.count, 24)
        XCTAssertEqual(layout.segments.count, 1, "等距桶连成一段")
        XCTAssertEqual(layout.points.first?.x ?? -1, rect.minX, accuracy: 0.5)
        XCTAssertEqual(layout.points.last?.x ?? -1, rect.minX + rect.width * 23 / 24, accuracy: 0.5, "最后一个桶按 start 定位")
        XCTAssertEqual(layout.bandPolygons.count, 1)
    }

    func testGapBreaksPolylineInsteadOfConnectingAcrossEmptyBuckets() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let interval = DateInterval(start: now, duration: 6 * 3_600)
        // 只有 0/1 点与 4/5 点有数据，2/3 点为空桶：必须断成两段。
        let buckets = [
            bucket(startOffset: 0, value: 10, now: now),
            bucket(startOffset: 3_600, value: 12, now: now),
            bucket(startOffset: 4 * 3_600, value: 20, now: now),
            bucket(startOffset: 5 * 3_600, value: 22, now: now),
        ]
        let layout = ReadingsChartGeometry.layout(buckets: buckets, interval: interval, in: rect)
        XCTAssertEqual(layout.segments.count, 2, "缺口处断线")
        XCTAssertEqual(layout.bandPolygons.count, 2, "区间带同样断开")
        XCTAssertEqual(layout.points.count, 4)
        // 缺口内的点不应出现：第 3 个点直接跳到 4 小时位置。
        let gapStart = rect.minX + rect.width * CGFloat(4.0 / 6.0)
        XCTAssertEqual(layout.points[2].x, gapStart, accuracy: 0.5)
    }

    func testThirtyDayRangeWithTwentyFourBucketsUsesTimeRatio() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let interval = DateInterval(start: now, duration: 30 * 86_400)
        // 第 3 天开始连续 24 天有数据，前后各有留白。
        let buckets = (0..<24).map { day in
            bucket(
                startOffset: Double(day + 3) * 86_400,
                value: Double(day),
                low: Double(day) - 0.5,
                high: Double(day) + 0.5,
                duration: 86_400,
                now: now
            )
        }
        let layout = ReadingsChartGeometry.layout(buckets: buckets, interval: interval, in: rect)
        XCTAssertEqual(layout.points.count, 24)
        XCTAssertEqual(layout.segments.count, 1)
        XCTAssertEqual(layout.points.first?.x ?? -1, rect.minX + rect.width * 3 / 30, accuracy: 0.5)
        XCTAssertEqual(layout.points.last?.x ?? -1, rect.minX + rect.width * 26 / 30, accuracy: 0.5)
        XCTAssertTrue(layout.points.allSatisfy { $0.y >= rect.minY && $0.y <= rect.maxY })
    }

    func testNonFiniteBucketsAreFiltered() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let interval = DateInterval(start: now, duration: 3_600)
        let bad = [
            ReadingsChartBucket(start: now, end: now.addingTimeInterval(3_600), average: .nan, minValue: 1, maxValue: 2, count: 1),
            ReadingsChartBucket(start: now, end: now.addingTimeInterval(3_600), average: 1, minValue: -.infinity, maxValue: 2, count: 1),
            ReadingsChartBucket(start: now.addingTimeInterval(3_600), end: now.addingTimeInterval(7_200), average: 5, minValue: 4, maxValue: 6, count: 1),
        ]
        let layout = ReadingsChartGeometry.layout(buckets: bad, interval: interval, in: rect)
        XCTAssertEqual(layout.points.count, 1, "只保留有限数值的桶")
        XCTAssertEqual(layout.yMin, 4)
        XCTAssertEqual(layout.yMax, 6)
    }

    func testYAxisAdaptsToRangeAndCentersFlatSeries() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let interval = DateInterval(start: now, duration: 3 * 3_600)
        let buckets = [
            bucket(startOffset: 0, value: 20, low: 10, high: 30, now: now),
            bucket(startOffset: 3_600, value: 35, low: 20, high: 50, now: now),
            bucket(startOffset: 2 * 3_600, value: 25, low: 18, high: 28, now: now),
        ]
        let layout = ReadingsChartGeometry.layout(buckets: buckets, interval: interval, in: rect)
        XCTAssertEqual(layout.yMin, 10, "Y 轴下限取区间最小 min")
        XCTAssertEqual(layout.yMax, 50, "Y 轴上限取区间最大 max")
        XCTAssertGreaterThan(layout.points[0].y, layout.points[2].y, "均值 20 比 25 更靠下")
        XCTAssertTrue(layout.points.allSatisfy { $0.y >= rect.minY && $0.y <= rect.maxY })

        let flat = [bucket(startOffset: 0, value: 21.5, now: now), bucket(startOffset: 3_600, value: 21.5, now: now)]
        let flatLayout = ReadingsChartGeometry.layout(buckets: flat, interval: interval, in: rect)
        XCTAssertLessThan(flatLayout.yMin, 21.5)
        XCTAssertGreaterThan(flatLayout.yMax, 21.5)
        XCTAssertTrue(flatLayout.points.allSatisfy { abs($0.y - rect.midY) < 0.5 }, "全相等时居中并留白")
    }

    // MARK: - 指标清单排序

    func testMetricInfosSortByLastAtDescendingThenMetric() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let items = [
            ReadingMetricInfo(metric: "temperature", unit: "℃", count: 7, lastAt: base.addingTimeInterval(-3_600)),
            ReadingMetricInfo(metric: "heart_rate", unit: "bpm", count: 42, lastAt: base),
            ReadingMetricInfo(metric: "battery", unit: "%", count: 3, lastAt: base.addingTimeInterval(-7_200)),
        ]
        XCTAssertEqual(
            ReadingMetricInfo.sortedByLastAt(items).map(\.metric),
            ["heart_rate", "temperature", "battery"]
        )

        let json = """
        {"items":[{"metric":"co2","unit":"ppm","count":9,"firstAt":"2026-11-04T00:00:00Z","lastAt":"2026-11-04T01:00:00Z"}]}
        """
        let decoded = try JSONDecoder().decode(ReadingMetrics.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.items.first?.count, 9)
        XCTAssertEqual(decoded.items.first?.readingMetric, .co2)
    }
}

/// 详情页「数据」区的服务端接入与降级用例。
final class DeviceDetailReadingsServiceTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var savedDeviceStore: SavedDeviceStore!
    private var readingsStore: ReadingsStore!
    private var service: FakeReadingsService!
    private var device: SavedDevice!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        savedDeviceStore = SavedDeviceStore(database: testDatabase.database)
        readingsStore = ReadingsStore(database: testDatabase.database)
        service = FakeReadingsService()
        device = makeSavedDevice(name: "温湿度计")
        try savedDeviceStore.upsert(device)
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        testDatabase = nil
    }

    private func makeViewModel() -> DeviceDetailViewModel {
        DeviceDetailViewModel(
            device: device,
            bluetooth: FakeBluetoothService(),
            productService: StubProductService(),
            cacheStore: DeviceInfoCacheStore(database: testDatabase.database),
            savedDeviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            readingsService: service
        )
    }

    func testServerMetricsDriveListCountsAndUnit() throws {
        service.metricsResult = .success(
            ReadingMetrics(items: [
                ReadingMetricInfo(metric: "heart_rate", unit: "bpm", count: 42, lastAt: Date()),
                ReadingMetricInfo(metric: "temperature", unit: "℃", count: 7, lastAt: Date().addingTimeInterval(-3_600)),
            ])
        )
        let now = Date()
        service.seriesResult = .success(
            ReadingsSeries(
                metric: "heart_rate",
                unit: "bpm",
                bucket: .hour,
                from: now.addingTimeInterval(-86_400),
                to: now,
                buckets: [
                    ReadingBucket(
                        start: now.addingTimeInterval(-3_600),
                        end: now,
                        count: 5,
                        minValue: 60,
                        maxValue: 90,
                        avg: 75,
                        last: 80
                    )
                ]
            )
        )
        service.summaryResult = .success(
            ReadingSummary(metric: "heart_rate", unit: "bpm", count: 5, minValue: 60, maxValue: 90, avg: 75, last: 80)
        )

        let viewModel = makeViewModel()
        viewModel.start()
        viewModel.setVisible(true)

        XCTAssertEqual(viewModel.readings.metrics, [.heartRate, .temperature])
        XCTAssertEqual(viewModel.readings.selectedMetric, .heartRate)
        XCTAssertEqual(viewModel.readings.unit, "bpm", "单位取服务端最新单位")
        XCTAssertEqual(viewModel.metricTitle(for: .heartRate), "心率 · 42 条")
        XCTAssertEqual(viewModel.readings.buckets.count, 1)
        XCTAssertEqual(viewModel.readings.interval.duration, 86_400)
        XCTAssertFalse(viewModel.readings.isOfflineLocalData)
        XCTAssertTrue(viewModel.readings.isSeriesFromCloud)
        XCTAssertEqual(viewModel.readings.sourceText, "云端分桶序列")
    }

    func testRangeSwitchRefetchesWithMatchingBucketAndFallsBackOffline() throws {
        let now = Date()
        try readingsStore.insert(
            DeviceReading(
                deviceID: device.id,
                metric: .temperature,
                value: 22,
                unit: "℃",
                recordedAt: now.addingTimeInterval(-30 * 60)
            )
        )
        service.metricsResult = .success(
            ReadingMetrics(items: [
                ReadingMetricInfo(metric: "temperature", unit: "℃", count: 1, lastAt: now.addingTimeInterval(-1_800))
            ])
        )
        service.seriesResult = .failure(.network("断网"))

        let viewModel = makeViewModel()
        viewModel.start()
        viewModel.setVisible(true)

        XCTAssertEqual(viewModel.readings.selectedRange, .hour24, "默认 24 小时")
        XCTAssertEqual(service.seriesRequests.last?.bucket, .hour)
        XCTAssertTrue(viewModel.readings.isOfflineLocalData)
        XCTAssertTrue(viewModel.readings.hasData, "网络失败回退本地分桶")

        viewModel.selectReadingsRange(.hour1)
        XCTAssertEqual(viewModel.readings.selectedRange, .hour1)
        XCTAssertEqual(service.seriesRequests.last?.bucket, .minute, "1 小时映射 1m")
        XCTAssertEqual(viewModel.readings.interval.duration, 3_600)

        viewModel.selectReadingsRange(.day7)
        XCTAssertEqual(service.seriesRequests.last?.bucket, .hour, "7 天映射 1h")

        viewModel.selectReadingsRange(.day30)
        XCTAssertEqual(service.seriesRequests.last?.bucket, .day, "30 天映射 1d")
        XCTAssertEqual(viewModel.readings.sourceText, "离线：仅本地 7 天数据")
    }

    func testOfflineMetricsFallBackToLocalList() throws {
        let now = Date()
        try readingsStore.insert(
            DeviceReading(deviceID: device.id, metric: .battery, value: 80, unit: "%", recordedAt: now)
        )
        service.metricsResult = .failure(.network("断网"))

        let viewModel = makeViewModel()
        viewModel.start()
        viewModel.setVisible(true)

        XCTAssertEqual(viewModel.readings.metrics, [.battery], "本地兜底仍展示真实已有指标")
        XCTAssertEqual(viewModel.readings.selectedMetric, .battery)
        XCTAssertEqual(viewModel.readings.sourceText, "离线：本地数据")
    }

    /// 详情页不可见时不发远端请求；变为可见后才合并刷新一次。
    func testNotVisibleSendsNoRemoteRequestsUntilVisible() throws {
        let now = Date()
        try readingsStore.insert(
            DeviceReading(deviceID: device.id, metric: .temperature, value: 22, unit: "℃", recordedAt: now)
        )
        service.metricsResult = .success(ReadingMetrics(items: [
            ReadingMetricInfo(metric: "temperature", unit: "℃", count: 1, lastAt: now)
        ]))
        service.seriesResult = .success(ReadingsSeries(
            metric: "temperature", unit: "℃", bucket: .hour,
            from: now.addingTimeInterval(-86_400), to: now,
            buckets: [ReadingBucket(start: now.addingTimeInterval(-3_600), end: now, count: 1,
                                    minValue: 22, maxValue: 22, avg: 22, last: 22)]
        ))
        service.summaryResult = .success(
            ReadingSummary(metric: "temperature", unit: "℃", count: 1, minValue: 22, maxValue: 22, avg: 22, last: 22)
        )

        let viewModel = makeViewModel()
        viewModel.start()
        XCTAssertTrue(service.seriesRequests.isEmpty, "不可见时读取本地即可")
        XCTAssertEqual(service.metricsRequests, 0)

        viewModel.setVisible(true)
        XCTAssertEqual(service.metricsRequests, 1, "可见时合并刷新一次")
        XCTAssertEqual(service.seriesRequests.count, 1)

        viewModel.setVisible(false)
        viewModel.setVisible(true)
        XCTAssertEqual(service.metricsRequests, 2, "回到前台再刷一次")
    }

    /// 服务端指标清单为空但本地有未同步读数：指标与序列都用本地，并标注待同步。
    func testEmptyServerMetricsFallsBackToPendingLocalData() throws {
        let now = Date()
        try readingsStore.insert(
            DeviceReading(deviceID: device.id, metric: .temperature, value: 21, unit: "℃",
                          recordedAt: now.addingTimeInterval(-60))
        )
        XCTAssertGreaterThan(try readingsStore.pendingCount(deviceID: device.id), 0)

        let emptySeries = ReadingsSeries(
            metric: "temperature", unit: "℃", bucket: .hour,
            from: now.addingTimeInterval(-86_400), to: now, buckets: []
        )
        service.metricsResult = .success(ReadingMetrics(items: []))
        service.seriesResult = .success(emptySeries)
        service.summaryResult = .success(
            ReadingSummary(metric: "temperature", unit: "℃", count: 0, minValue: 0, maxValue: 0, avg: 0, last: 0)
        )

        let viewModel = makeViewModel()
        viewModel.start()
        viewModel.setVisible(true)

        XCTAssertEqual(viewModel.readings.metrics, [.temperature], "沿用本地聚合出的指标")
        XCTAssertEqual(viewModel.readings.selectedMetric, .temperature)
        XCTAssertTrue(viewModel.readings.hasData, "本地 UTC 网格仍有数据，不能空图")
        XCTAssertTrue(viewModel.readings.isPendingLocalData)
        XCTAssertEqual(viewModel.readings.sourceText, "待同步：本地数据")
    }
}

/// 可注入成功/失败的读数服务，记录每次 series 请求参数。
private final class FakeReadingsService: ReadingsAPIServicing {
    var metricsResult: Result<ReadingMetrics, AppError> = .success(ReadingMetrics())
    var seriesResult: Result<ReadingsSeries, AppError> = .failure(.network("未配置"))
    var summaryResult: Result<ReadingSummary, AppError> = .failure(.network("未配置"))
    private(set) var seriesRequests: [(metric: ReadingMetric, from: Date, to: Date, bucket: ReadingsBucket)] = []
    private(set) var metricsRequests = 0

    func fetchReadings(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        from: Date?,
        to: Date?,
        limit: Int,
        cursor: String?,
        completion: @escaping (Result<ReadingsPage, AppError>) -> Void
    ) {
        completion(.failure(.network("未使用")))
    }

    func fetchSummary(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        hours: Int,
        completion: @escaping (Result<ReadingSummary, AppError>) -> Void
    ) {
        completion(summaryResult)
    }

    func fetchSeries(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        from: Date,
        to: Date,
        bucket: ReadingsBucket,
        completion: @escaping (Result<ReadingsSeries, AppError>) -> Void
    ) {
        seriesRequests.append((metric, from, to, bucket))
        completion(seriesResult)
    }

    func fetchMetrics(
        platform: String,
        externalID: String,
        completion: @escaping (Result<ReadingMetrics, AppError>) -> Void
    ) {
        metricsRequests += 1
        completion(metricsResult)
    }
}
