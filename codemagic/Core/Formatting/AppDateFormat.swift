import Foundation

/// 统一时间展示口径：列表用相对时间，详情用绝对时间。
enum AppDateFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 60 {
            return "刚刚"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func absolute(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 日期型只读展示（如会话到期日）。
    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func rssi(_ value: Int) -> String {
        "\(value) dBm"
    }
}
