import XCTest
@testable import codemagic

/// 两端（iOS / Android）共用的「读数解析黄金用例」。
///
/// 每条用例固定为 `特征 + 原始字节 → 唯一期望`；解析失败必须是「零读数 + 失败原因」，
/// 不崩溃、不写脏数据。新增特征或调整解析规则时，先在这里补行，再改实现。
/// 文档对照见 `docs/consistency.md` 的「读数解析黄金用例」章节。
final class ReadingGoldenTableTests: XCTestCase {
    private func result(
        _ characteristic: ReadingCharacteristic,
        _ bytes: [UInt8]
    ) -> ReadingParseResult {
        ReadingParser.parse(
            BluetoothReadingSample(
                peripheralID: UUID(),
                characteristic: characteristic,
                data: Data(bytes),
                receivedAt: Date(timeIntervalSince1970: 1000)
            )
        )
    }

    private func assertSingle(
        _ characteristic: ReadingCharacteristic,
        _ bytes: [UInt8],
        metric: ReadingMetric,
        value: Double,
        unit: String,
        accuracy: Double = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parsed = result(characteristic, bytes)
        XCTAssertEqual(parsed.failures, [], "不应记录失败原因", file: file, line: line)
        XCTAssertEqual(parsed.readings.count, 1, "应恰好解析出 1 条读数", file: file, line: line)
        XCTAssertEqual(parsed.readings.first?.metric, metric, file: file, line: line)
        XCTAssertEqual(parsed.readings.first?.unit, unit, file: file, line: line)
        XCTAssertEqual(parsed.readings.first?.value ?? .nan, value, accuracy: accuracy, file: file, line: line)
    }

    private func assertDropped(
        _ characteristic: ReadingCharacteristic,
        _ bytes: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parsed = result(characteristic, bytes)
        XCTAssertTrue(parsed.readings.isEmpty, "非法输入必须整体丢弃", file: file, line: line)
        XCTAssertFalse(parsed.failures.isEmpty, "丢弃需带失败原因供本地日志", file: file, line: line)
    }

    // MARK: - 心率 0x2A37

    /// `00 48` → flags bit0=0，uint8 72 bpm。
    func testHeartRateUInt8_72() {
        assertSingle(.heartRate, [0x00, 0x48], metric: .heartRate, value: 72, unit: "bpm")
    }

    /// `00 00` → 0 bpm 不是有效生理值，丢弃。
    func testHeartRateZeroDropped() {
        assertDropped(.heartRate, [0x00, 0x00])
    }

    /// `01 2C 01` → flags bit0=1，uint16 小端 300 bpm（上界闭区间）。
    func testHeartRateUInt16_300() {
        assertSingle(.heartRate, [0x01, 0x2C, 0x01], metric: .heartRate, value: 300, unit: "bpm")
    }

    /// `01 2D 01` → uint16 小端 301 bpm 越界，丢弃。
    func testHeartRateUInt16_301Dropped() {
        assertDropped(.heartRate, [0x01, 0x2D, 0x01])
    }

    // MARK: - 电池 0x2A19

    /// `64` → 100 %。
    func testBattery100() {
        assertSingle(.battery, [0x64], metric: .battery, value: 100, unit: "%")
    }

    /// `00` → 0 % 是真实电量（关机 / 耗尽），不是缺测，必须保留。
    func testBatteryZeroIsRealValue() {
        assertSingle(.battery, [0x00], metric: .battery, value: 0, unit: "%")
    }

    /// `65` → 101 % 超过物理上限，丢弃。
    func testBattery101Dropped() {
        assertDropped(.battery, [0x65])
    }

    // MARK: - 温度 0x2A6E

    /// `2A 08` → sint16 小端 2090 → 20.90 ℃。
    func testTemperatureScaled20_90() {
        assertSingle(.temperature, [0x2A, 0x08], metric: .temperature, value: 20.90, unit: "℃")
    }

    /// `70 FE` → sint16 小端 -400 → -4.00 ℃。
    func testTemperatureNegative4() {
        assertSingle(.temperature, [0x70, 0xFE], metric: .temperature, value: -4.00, unit: "℃")
    }

    /// `00 4A`：按 0.01 ℃ 解释为 189.44 ℃（越界），回退 IEEE-754 binary16。
    ///
    /// 规范依据：binary16 位型 `0x4A00` = 1.5 × 2³ = **12.0**；`0x4D00`（字节 `00 4D`）才是 20.0。
    /// 黄金表此行的期望「20.0」与位型不符，视为笔误；两种位型都已固化为用例，
    /// 实现不做任何针对 `0x4A00` 的特殊硬编码（详见汇总与 consistency.md 脚注）。
    func testTemperatureHalfPrecisionBits0x4A00() {
        assertSingle(.temperature, [0x00, 0x4A], metric: .temperature, value: 12.0, unit: "℃")
    }

    /// `00 4D` → 0.01 ℃ 解释为 197.12 ℃（越界），回退 binary16 → 20.0 ℃。
    func testTemperatureHalfPrecision20Degrees() {
        assertSingle(.temperature, [0x00, 0x4D], metric: .temperature, value: 20.0, unit: "℃")
    }

    /// `00 00 C0 3F` → float32 小端 1.5 ℃。
    func testTemperatureFloat32OnePointFive() {
        assertSingle(.temperature, [0x00, 0x00, 0xC0, 0x3F], metric: .temperature, value: 1.5, unit: "℃")
    }

    /// `FF FF` → sint16 -1 → -0.01 ℃；落在合理区间，绝不按半精度当成 NaN 丢弃。
    func testTemperatureMinusZeroPointZeroOne() {
        assertSingle(.temperature, [0xFF, 0xFF], metric: .temperature, value: -0.01, unit: "℃")
    }

    // MARK: - Nordic UART TX

    /// `temperature=23.5` → temperature 23.5，单位取白名单默认 ℃。
    func testNordicMetricValue() {
        assertSingle(
            .nordicUART,
            Array("temperature=23.5".utf8),
            metric: .temperature,
            value: 23.5,
            unit: "℃"
        )
    }

    /// `42` → 纯数字行，指标 `other`，单位留空（不编造）。
    func testNordicPlainNumericFallsBackToOther() {
        assertSingle(.nordicUART, Array("42".utf8), metric: .other, value: 42, unit: "")
    }

    /// `abc` → 非数字，丢弃。
    func testNordicNonNumericDropped() {
        assertDropped(.nordicUART, Array("abc".utf8))
    }

    /// `temperature=23.5\nbattery=88\nxx` → 前两行入库，第 3 行只丢该行并记录原因。
    func testNordicMultiLineDropsOnlyBadLine() {
        let parsed = result(.nordicUART, Array("temperature=23.5\nbattery=88\nxx".utf8))
        XCTAssertEqual(parsed.readings.count, 2, "前两行各一条读数")
        XCTAssertEqual(parsed.failures.count, 1, "只丢弃非法行")
        XCTAssertEqual(parsed.readings[0].metric, .temperature)
        XCTAssertEqual(parsed.readings[0].value, 23.5, accuracy: 1e-9)
        XCTAssertEqual(parsed.readings[0].unit, "℃")
        XCTAssertEqual(parsed.readings[1].metric, .battery)
        XCTAssertEqual(parsed.readings[1].value, 88, accuracy: 1e-9)
        XCTAssertEqual(parsed.readings[1].unit, "%")
    }

    // MARK: - 空字节

    /// 任意特征收到空字节：丢弃并带原因，不崩溃。
    func testEmptyPayloadDroppedForEveryCharacteristic() {
        for characteristic in ReadingCharacteristic.allCases {
            let parsed = result(characteristic, [])
            XCTAssertTrue(parsed.readings.isEmpty, "\(characteristic) 空字节应丢弃")
            XCTAssertFalse(parsed.failures.isEmpty, "\(characteristic) 应记录失败原因")
        }
    }
}
