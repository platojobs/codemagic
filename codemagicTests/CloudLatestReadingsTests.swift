import XCTest
@testable import codemagic

/// 云端最近读数服务：指标选择、404 / 网络失败语义、缓存与请求合并。
final class CloudLatestReadingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReturnsNewestMetricReadingWithMappedUnit() {
        let api = FakeReadingsAPI()
        api.metricsResult = .success(ReadingMetrics(items: [
            ReadingMetricInfo(metric: "relative_humidity", unit: "%", count: 2, lastAt: now.addingTimeInterval(-3_600)),
            ReadingMetricInfo(metric: "temperature_celsius", unit: "celsius", count: 3, lastAt: now.addingTimeInterval(-60)),
        ]))
        api.readingsResult = .success(ReadingsPage(items: [
            ReadingItem(
                id: "reading-1",
                metric: "temperature_celsius",
                value: 24.5,
                unit: "celsius",
                recordedAt: now.addingTimeInterval(-60)
            ),
        ]))
        let service = CloudLatestReadingsService(api: api, now: { [now] in now })

        let result = request(service, platform: "android", externalID: "AA:BB:CC:00:00:01")

        guard case .available(let reading) = result else {
            return XCTFail("expected available, got \(String(describing: result))")
        }
        XCTAssertEqual(reading.rawMetric, "temperature_celsius")
        XCTAssertEqual(reading.metricTitle, L10n.t("metric.temperature"))
        XCTAssertEqual(reading.displayText, "24.5 ℃")
        XCTAssertEqual(reading.reportedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(api.metricsCalls, 1)
        XCTAssertEqual(api.readingsCalls, 1)
        XCTAssertEqual(
            api.requestedMetricNames,
            ["temperature_celsius"],
            "必须用服务端原始指标名查询，不能归一化成 other"
        )
    }

    func testNoMetricsIsEmptyAndDoesNotRequestReadings() {
        let api = FakeReadingsAPI()
        api.metricsResult = .success(ReadingMetrics(items: []))
        let service = CloudLatestReadingsService(api: api, now: { [now] in now })

        let result = request(service, platform: "android", externalID: "AA:BB:CC:00:00:02")

        XCTAssertEqual(result, .empty)
        XCTAssertEqual(api.readingsCalls, 0)
    }

    func testNotFoundIsConfirmedEmptyNotFailure() {
        let api = FakeReadingsAPI()
        api.metricsResult = .failure(.server(statusCode: 404))
        let service = CloudLatestReadingsService(api: api, now: { [now] in now })

        XCTAssertEqual(request(service, platform: "android", externalID: "AA"), .empty)
    }

    func testNetworkFailureIsFailedNotOfflineOrEmpty() {
        let api = FakeReadingsAPI()
        api.metricsResult = .failure(.network("offline"))
        let service = CloudLatestReadingsService(api: api, now: { [now] in now })

        XCTAssertEqual(request(service, platform: "android", externalID: "AA"), .failed)
    }

    func testReadingsFailureAfterMetricsSuccessIsFailed() {
        let api = FakeReadingsAPI()
        api.metricsResult = .success(ReadingMetrics(items: [
            ReadingMetricInfo(metric: "heart_rate", unit: "bpm", count: 1, lastAt: now),
        ]))
        api.readingsResult = .failure(.network("offline"))
        let service = CloudLatestReadingsService(api: api, now: { [now] in now })

        XCTAssertEqual(request(service, platform: "android", externalID: "AA"), .failed)
    }

    func testResultIsCachedWithinLifetime() {
        let api = FakeReadingsAPI()
        api.metricsResult = .success(ReadingMetrics(items: [
            ReadingMetricInfo(metric: "heart_rate", unit: "bpm", count: 1, lastAt: now),
        ]))
        api.readingsResult = .success(ReadingsPage(items: [
            ReadingItem(id: "r", metric: "heart_rate", value: 72, unit: "bpm", recordedAt: now),
        ]))
        let service = CloudLatestReadingsService(api: api, now: { [now] in now })

        _ = request(service, platform: "android", externalID: "AA")
        _ = request(service, platform: "android", externalID: "AA")

        XCTAssertEqual(api.metricsCalls, 1, "同设备在缓存有效期内不重复请求")
    }

    // MARK: - Helpers

    private func request(
        _ service: CloudLatestReadingsProviding,
        platform: String,
        externalID: String
    ) -> CloudLatestReadingState {
        let expectation = expectation(description: "cloud reading \(externalID)")
        var received: CloudLatestReadingState?
        service.latestReading(platform: platform, externalID: externalID) { state in
            received = state
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return received ?? .failed
    }
}

private final class FakeReadingsAPI: ReadingsAPIServicing {
    var metricsResult: Result<ReadingMetrics, AppError> = .success(ReadingMetrics())
    var readingsResult: Result<ReadingsPage, AppError> = .success(ReadingsPage())
    private(set) var metricsCalls = 0
    private(set) var readingsCalls = 0
    private(set) var requestedMetricNames: [String] = []

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
        readingsCalls += 1
        completion(readingsResult)
    }

    func fetchReadings(
        platform: String,
        externalID: String,
        metricName: String,
        from: Date?,
        to: Date?,
        limit: Int,
        cursor: String?,
        completion: @escaping (Result<ReadingsPage, AppError>) -> Void
    ) {
        readingsCalls += 1
        requestedMetricNames.append(metricName)
        completion(readingsResult)
    }

    func fetchSummary(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        hours: Int,
        completion: @escaping (Result<ReadingSummary, AppError>) -> Void
    ) {
        completion(.failure(.server(statusCode: 500)))
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
        completion(.failure(.server(statusCode: 500)))
    }

    func fetchMetrics(
        platform: String,
        externalID: String,
        completion: @escaping (Result<ReadingMetrics, AppError>) -> Void
    ) {
        metricsCalls += 1
        completion(metricsResult)
    }
}
