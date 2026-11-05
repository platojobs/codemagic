import Foundation

/// 读数 CSV 生成：UTF-8 BOM、固定表头、ISO8601 UTC 时间与 RFC 4180 转义。
enum ReadingsCSV {
    struct Row: Equatable {
        let recordedAt: Date
        let metric: String
        let value: Double
        let unit: String

        init(recordedAt: Date, metric: String, value: Double, unit: String) {
            self.recordedAt = recordedAt
            self.metric = metric
            self.value = value
            self.unit = unit
        }

        init(reading: DeviceReading) {
            self.init(
                recordedAt: reading.recordedAt,
                metric: reading.metric.rawValue,
                value: reading.value,
                unit: reading.unit
            )
        }
    }

    static let header = "recordedAt,metric,value,unit"

    /// 生成完整文件数据（含 BOM）。行按记录时间升序，保证导出结果可复现。
    static func data(rows: [Row]) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: Data(text(rows: rows).utf8))
        return data
    }

    static func text(rows: [Row]) -> String {
        let sorted = rows.sorted { $0.recordedAt < $1.recordedAt }
        var lines = [header]
        lines.reserveCapacity(sorted.count + 1)
        for row in sorted {
            lines.append(
                [
                    SyncDateCodec.string(from: row.recordedAt),
                    escape(row.metric),
                    formatValue(row.value),
                    escape(row.unit),
                ].joined(separator: ",")
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// RFC 4180：含逗号、引号、换行时整体加引号，内部引号双写。
    static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 定点小数并去掉多余的 0；使用 POSIX locale，避免不同地区的小数分隔符破坏 CSV。
    static func formatValue(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains(".") && text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text == "-0" ? "0" : text
    }
}
