import CoreBluetooth
import Foundation

/// 订阅的 BLE 特征。UUID 统一大写，短 UUID 与 128 位 UUID 都由 CoreBluetooth 规范化。
enum ReadingCharacteristic: String, CaseIterable, Equatable {
    /// 心率测量 Heart Rate Measurement（服务 0x180D）。
    case heartRate = "2A37"
    /// 电池电量 Battery Level（服务 0x180F）。
    case battery = "2A19"
    /// 温度测量 Temperature Measurement（服务 0x1809）。
    case temperature = "2A6E"
    /// Nordic UART TX（服务 6E400001-B5A3-F393-E0A9-E50E24DCCA9E）。
    case nordicUART = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

    var title: String {
        switch self {
        case .heartRate: return L10n.t("metric.heartRate")
        case .battery: return L10n.t("metric.battery")
        case .temperature: return L10n.t("metric.temperature")
        case .nordicUART: return "Nordic UART"
        }
    }

    var serviceUUID: String {
        switch self {
        case .heartRate: return "180D"
        case .battery: return "180F"
        case .temperature: return "1809"
        case .nordicUART: return "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        }
    }

    static func from(uuid: CBUUID) -> ReadingCharacteristic? {
        let normalized = uuid.uuidString.uppercased()
        return allCases.first { $0.rawValue == normalized }
    }
}

/// 一条原始通知数据，交给解析器处理；解析与存储分离，便于单测覆盖。
struct BluetoothReadingSample: Equatable {
    let peripheralID: UUID
    let characteristic: ReadingCharacteristic
    let data: Data
    let receivedAt: Date
}

/// 解析后的读数（尚未落库）。
struct ParsedReading: Equatable {
    let metric: ReadingMetric
    let value: Double
    let unit: String
}

/// 解析结果：合法读数 + 失败原因。失败原因进本地日志，读数不落库。
struct ReadingParseResult: Equatable {
    var readings: [ParsedReading] = []
    var failures: [String] = []

    var isEmpty: Bool { readings.isEmpty && failures.isEmpty }

    static func success(_ reading: ParsedReading) -> ReadingParseResult {
        ReadingParseResult(readings: [reading], failures: [])
    }

    static func failure(_ reason: String) -> ReadingParseResult {
        ReadingParseResult(readings: [], failures: [reason])
    }
}

/// 各特征独立解析器。
///
/// 约束：解析失败必须静默丢弃（仅本地日志），绝不崩溃、不写脏数据。
/// 所有数值都做有限性与物理范围校验，NaN / Inf / 越界一律视为失败。
enum ReadingParser {
    static func parse(_ sample: BluetoothReadingSample) -> ReadingParseResult {
        switch sample.characteristic {
        case .heartRate: return parseHeartRate(sample.data)
        case .battery: return parseBattery(sample.data)
        case .temperature: return parseTemperature(sample.data)
        case .nordicUART: return parseNordicUART(sample.data)
        }
    }

    // MARK: - 心率 0x2A37

    /// 首字节为 flags：bit0 = 0 表示测量值 uint8，bit0 = 1 表示 uint16。
    /// 只接受 1…300 bpm 的生理范围，0 与越界值视为无效。
    static func parseHeartRate(_ data: Data) -> ReadingParseResult {
        guard data.count >= 2 else {
            return .failure("心率数据长度不足（\(data.count) 字节）")
        }
        let flags = data[data.startIndex]
        let isUInt16 = (flags & 0x01) != 0
        let raw: Int
        if isUInt16 {
            guard data.count >= 3 else {
                return .failure("心率 16 位数据长度不足（\(data.count) 字节）")
            }
            raw = Int(data[data.startIndex + 1]) | (Int(data[data.startIndex + 2]) << 8)
        } else {
            raw = Int(data[data.startIndex + 1])
        }
        guard raw > 0, raw <= 300 else {
            return .failure("心率数值越界（\(raw)）")
        }
        return .success(ParsedReading(metric: .heartRate, value: Double(raw), unit: "bpm"))
    }

    // MARK: - 电池 0x2A19

    /// 单字节百分比 0…100。
    static func parseBattery(_ data: Data) -> ReadingParseResult {
        guard let first = data.first else {
            return .failure("电池数据为空")
        }
        let percent = Int(first)
        guard percent <= 100 else {
            return .failure("电池百分比越界（\(percent)）")
        }
        return .success(ParsedReading(metric: .battery, value: Double(percent), unit: "%"))
    }

    // MARK: - 温度 0x2A6E

    /// 温度有两种常见编码：
    /// - 2 字节：优先按 BLE 规范的 sint16、0.01 ℃ 放大值；不合法时尝试 IEEE-754 binary16（半精度）。
    /// - 4 字节：IEEE-754 binary32，单位为 ℃。
    /// 只接受 -50…150 ℃，超出视为坏数据。
    static func parseTemperature(_ data: Data) -> ReadingParseResult {
        switch data.count {
        case 2:
            let bits = uint16LE(data)
            let scaled = Double(Int16(bitPattern: bits)) * 0.01
            if isPlausibleTemperature(scaled) {
                return .success(ParsedReading(metric: .temperature, value: scaled, unit: "℃"))
            }
            let half = Double(Float16(bitPattern: bits))
            if isPlausibleTemperature(half) {
                return .success(ParsedReading(metric: .temperature, value: half, unit: "℃"))
            }
            return .failure("温度数值越界（0.01℃=\(scaled)，half=\(half)）")
        case 4:
            let bits = uint32LE(data)
            let value = Double(Float(bitPattern: bits))
            guard value.isFinite, isPlausibleTemperature(value) else {
                return .failure("温度 float32 数值非法（\(value)）")
            }
            return .success(ParsedReading(metric: .temperature, value: value, unit: "℃"))
        default:
            return .failure("温度数据长度不支持（\(data.count) 字节）")
        }
    }

    // MARK: - Nordic UART TX

    /// 支持两种文本行：
    /// - `metric=value`，如 `temperature=23.5`、`co2=800`；未知指标记 `other`。
    /// - 纯数字行，如 `36.6`；指标记 `other`、单位留空（无法推断就不编造）。
    ///
    /// 一个通知可包含多行；单行失败只丢弃该行并记录原因，其余行照常入库。
    /// 载荷超过 256 字节或单行超过 64 字符视为超长，整帧拒绝。
    static func parseNordicUART(_ data: Data) -> ReadingParseResult {
        guard !data.isEmpty else {
            return .failure("NUS 数据为空")
        }
        guard data.count <= 256 else {
            return .failure("NUS 数据超长（\(data.count) 字节）")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure("NUS 数据不是合法 UTF-8")
        }

        let lines = text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return .failure("NUS 数据没有有效文本行")
        }

        var result = ReadingParseResult()
        for line in lines {
            if line.count > 64 {
                result.failures.append("NUS 文本行超长（\(line.count) 字符）")
                continue
            }
            if let separator = line.firstIndex(of: "=") {
                let key = String(line[line.startIndex..<separator])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let valueText = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else {
                    result.failures.append("NUS 文本行缺少指标名：\(line)")
                    continue
                }
                let metric = ReadingMetric.normalized(key)
                guard let value = finiteDouble(valueText) else {
                    result.failures.append("NUS 数值非法：\(line)")
                    continue
                }
                result.readings.append(
                    ParsedReading(metric: metric, value: value, unit: metric.defaultUnit)
                )
            } else {
                guard let value = finiteDouble(line) else {
                    result.failures.append("NUS 文本行不是 metric=value 或纯数字：\(line)")
                    continue
                }
                result.readings.append(
                    ParsedReading(metric: .other, value: value, unit: ReadingMetric.other.defaultUnit)
                )
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func isPlausibleTemperature(_ value: Double) -> Bool {
        value.isFinite && value >= -50 && value <= 150
    }

    private static func finiteDouble(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private static func uint16LE(_ data: Data) -> UInt16 {
        let bytes = Array(data.prefix(2))
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    private static func uint32LE(_ data: Data) -> UInt32 {
        let bytes = Array(data.prefix(4))
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }
}
