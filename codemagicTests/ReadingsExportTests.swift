import XCTest
@testable import codemagic

/// CSV 格式：BOM、表头、ISO8601 UTC、字段转义与稳定排序。
final class ReadingsCSVTests: XCTestCase {
    func testDataStartsWithUTF8BOMAndFixedHeader() {
        let rows = [ReadingsCSV.Row(recordedAt: Date(), metric: "temperature", value: 22, unit: "℃")]
        let data = ReadingsCSV.data(rows: rows)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("recordedAt,metric,value,unit\n"))
    }

    func testRowsSortedAscendingAndTimestampsAreUTCISO8601() {
        let later = Date(timeIntervalSince1970: 1_700_000_600)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let text = ReadingsCSV.text(rows: [
            ReadingsCSV.Row(recordedAt: later, metric: "temperature", value: 23.5, unit: "℃"),
            ReadingsCSV.Row(recordedAt: earlier, metric: "humidity", value: 55, unit: "%"),
        ])
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        for line in lines.dropFirst() {
            let timestamp = line.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
            XCTAssertTrue(timestamp.hasSuffix("Z"), "ISO8601 UTC：\(timestamp)")
        }
        XCTAssertTrue(lines[1].contains("humidity"))
        XCTAssertTrue(lines[2].contains("23.5"))
    }

    func testFieldsWithCommaQuoteOrNewlineAreEscaped() {
        XCTAssertEqual(ReadingsCSV.escape("room,1"), "\"room,1\"")
        XCTAssertEqual(ReadingsCSV.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ReadingsCSV.escape("line\nbreak"), "\"line\nbreak\"")
        XCTAssertEqual(ReadingsCSV.escape("plain"), "plain")
    }

    func testValueFormattingUsesPOSIXDecimalPointAndTrimsZeros() {
        XCTAssertEqual(ReadingsCSV.formatValue(22), "22")
        XCTAssertEqual(ReadingsCSV.formatValue(22.5), "22.5")
        XCTAssertEqual(ReadingsCSV.formatValue(-0.0), "0")
        XCTAssertEqual(ReadingsCSV.formatValue(.nan), "")
    }
}

/// 导出服务：7 天内本地、更长远端分页、5 万条上限与进度。
final class ReadingsExportServiceTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var readingsStore: ReadingsStore!
    private var device: SavedDevice!
    private var exportDirectory: URL!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        readingsStore = ReadingsStore(database: testDatabase.database)
        device = makeSavedDevice(name: "温湿度计")
        exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemagic-export-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let exportDirectory {
            try? FileManager.default.removeItem(at: exportDirectory)
        }
        testDatabase?.cleanUp()
        testDatabase = nil
    }

    func testSevenDaysReadsLocalAndDoesNotCallServer() throws {
        let now = Date()
        try readingsStore.insert(DeviceReading(
            deviceID: device.id, metric: .temperature, value: 21, unit: "℃",
            recordedAt: now.addingTimeInterval(-3_600)
        ))
        let service = ReadingPageFake()
        let exporter = ReadingsExportService(
            readingsStore: readingsStore,
            readingsService: service,
            directoryURL: exportDirectory
        )

        let expectation = expectation(description: "export")
        var progressValues: [Int] = []
        exporter.export(device: device, metric: .temperature, range: .day7, progress: { progressValues.append($0) }) { result in
            defer { expectation.fulfill() }
            guard case .success(let url) = result else {
                return XCTFail("导出失败：\(result)")
            }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertTrue(text.contains("temperature"))
            XCTAssertTrue(text.contains("21"))
            try? FileManager.default.removeItem(at: url)
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(service.readingsRequests.isEmpty, "7 天内读本地，不打服务端")
        XCTAssertEqual(progressValues.last, 1)
    }

    func testLongerRangePaginatesWithCursorAndWritesAllRows() {
        let service = ReadingPageFake()
        let now = Date()
        service.pages = [
            ReadingsPage(
                items: [
                    ReadingItem(id: "1", metric: "temperature", value: 1, unit: "℃", recordedAt: now.addingTimeInterval(-3_600)),
                    ReadingItem(id: "2", metric: "temperature", value: 2, unit: "℃", recordedAt: now.addingTimeInterval(-7_200)),
                ],
                nextCursor: "cursor-2",
                hasMore: true
            ),
            ReadingsPage(
                items: [
                    ReadingItem(id: "3", metric: "temperature", value: 3, unit: "℃", recordedAt: now.addingTimeInterval(-10_800))
                ],
                nextCursor: nil,
                hasMore: false
            ),
        ]
        let exporter = ReadingsExportService(
            readingsStore: readingsStore,
            readingsService: service,
            directoryURL: exportDirectory
        )

        let expectation = expectation(description: "export")
        exporter.export(device: device, metric: .temperature, range: .day30, progress: { _ in }) { result in
            defer { expectation.fulfill() }
            guard case .success(let url) = result else {
                return XCTFail("导出失败：\(result)")
            }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertEqual(text.split(separator: "\n").count, 4, "表头 + 3 行")
            try? FileManager.default.removeItem(at: url)
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(service.readingsRequests.count, 2)
        XCTAssertEqual(service.readingsRequests.last?.cursor, "cursor-2")
    }

    func testTooManyRowsFailsWithActionableMessage() {
        let service = ReadingPageFake()
        let now = Date()
        service.pages = [
            ReadingsPage(
                items: (0..<6).map {
                    ReadingItem(id: "\($0)", metric: "temperature", value: Double($0), unit: "℃", recordedAt: now)
                },
                nextCursor: nil,
                hasMore: false
            )
        ]
        let exporter = ReadingsExportService(
            readingsStore: readingsStore,
            readingsService: service,
            maxRows: 5,
            directoryURL: exportDirectory
        )

        let expectation = expectation(description: "export")
        exporter.export(device: device, metric: .temperature, range: .day30, progress: { _ in }) { result in
            defer { expectation.fulfill() }
            guard case .failure(let error) = result else {
                return XCTFail("应返回超限错误")
            }
            XCTAssertEqual(error, .tooManyRows(limit: 5))
            XCTAssertTrue(error.errorDescription?.contains("缩短导出区间") == true)
        }
        wait(for: [expectation], timeout: 5)
    }

    func testEmptyLocalResultReportsNoData() {
        let exporter = ReadingsExportService(
            readingsStore: readingsStore,
            readingsService: ReadingPageFake(),
            directoryURL: exportDirectory
        )
        let expectation = expectation(description: "export")
        exporter.export(device: device, metric: .temperature, range: .hour24, progress: { _ in }) { result in
            defer { expectation.fulfill() }
            guard case .failure(let error) = result else {
                return XCTFail("空数据应失败")
            }
            XCTAssertEqual(error, .noData)
        }
        wait(for: [expectation], timeout: 5)
    }

    /// 文件名：设备名 + 设备标识 + 指标 + 区间起止（UTC）+ 随机后缀。
    func testFilenameCarriesDeviceMetricAndUTCRange() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let from = utc.date(from: DateComponents(
            year: 2026, month: 11, day: 5, hour: 1, minute: 0
        ))!
        let to = from.addingTimeInterval(3_600)
        let shortID = String(device.externalID.filter { $0.isLetter || $0.isNumber }.suffix(8))
        let name = ReadingsExportService.filename(
            device: device,
            metric: .temperature,
            interval: DateInterval(start: from, end: to),
            suffix: "abcd1234"
        )
        XCTAssertEqual(
            name,
            "readings-温湿度计-\(shortID)-temperature-20261105T010000Z-20261105T020000Z-abcd1234.csv"
        )
        XCTAssertTrue(name.hasSuffix(".csv"))
    }

    func testFilenameReplacesPathSeparatorsAndSpaces() {
        var special = makeSavedDevice(name: "厨房/阳台 探头")
        special.externalID = "AA:BB:CC:DD:EE:FF"
        let name = ReadingsExportService.filename(
            device: special,
            metric: .humidity,
            interval: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60)),
            suffix: "deadbeef"
        )
        XCTAssertTrue(name.hasPrefix("readings-厨房_阳台_探头-CCDDEEFF-"), name)
        XCTAssertFalse(name.contains("/"), "文件名不能带路径分隔符")
        XCTAssertFalse(name.contains(" "), "空格替换为下划线")
        XCTAssertTrue(name.contains("-humidity-"))
        XCTAssertTrue(name.contains("19700101T000000Z-19700101T000100Z"))
    }

    func testExportedFileIsCreatedInsideDirectoryWithBOM() throws {
        let now = Date()
        try readingsStore.insert(DeviceReading(
            deviceID: device.id, metric: .temperature, value: 21, unit: "℃",
            recordedAt: now.addingTimeInterval(-3_600)
        ))
        let exporter = ReadingsExportService(
            readingsStore: readingsStore,
            readingsService: ReadingPageFake(),
            directoryURL: exportDirectory
        )
        let expectation = expectation(description: "export")
        exporter.export(device: device, metric: .temperature, range: .day7, progress: { _ in }) { result in
            defer { expectation.fulfill() }
            guard case .success(let url) = result else {
                return XCTFail("导出失败：\(result)")
            }
            XCTAssertEqual(url.deletingLastPathComponent(), self.exportDirectory)
            let data = (try? Data(contentsOf: url)) ?? Data()
            XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 BOM 让 Excel 正确识别中文")
            let text = String(data: data.dropFirst(3), encoding: .utf8) ?? ""
            XCTAssertTrue(text.hasPrefix("recordedAt,metric,value,unit\n"))
            try? FileManager.default.removeItem(at: url)
        }
        wait(for: [expectation], timeout: 5)
    }
}

/// 分页假实现：按顺序返回预置页，并记录每次请求参数。
private final class ReadingPageFake: ReadingsAPIServicing {
    struct Request {
        let metric: ReadingMetric
        let from: Date?
        let to: Date?
        let limit: Int
        let cursor: String?
    }

    var pages: [ReadingsPage] = []
    private(set) var readingsRequests: [Request] = []

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
        readingsRequests.append(Request(metric: metric, from: from, to: to, limit: limit, cursor: cursor))
        guard !pages.isEmpty else {
            completion(.failure(.network("没有更多页")))
            return
        }
        completion(.success(pages.removeFirst()))
    }

    func fetchSummary(
        platform: String,
        externalID: String,
        metric: ReadingMetric,
        hours: Int,
        completion: @escaping (Result<ReadingSummary, AppError>) -> Void
    ) {
        completion(.failure(.network("未使用")))
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
        completion(.failure(.network("未使用")))
    }

    func fetchMetrics(
        platform: String,
        externalID: String,
        completion: @escaping (Result<ReadingMetrics, AppError>) -> Void
    ) {
        completion(.failure(.network("未使用")))
    }
}
