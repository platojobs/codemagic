import Foundation

/// 本地规则触发条件。
enum RuleTrigger: String, Codable, CaseIterable {
    /// 设备从扫描结果中消失（视为断开）。
    case disconnect
    /// RSSI 低于阈值。
    case rssiBelowThreshold
    /// 某指标读数满足「比较符 + 阈值」并连续 N 条。
    case readingThreshold

    var title: String {
        switch self {
        case .disconnect: return L10n.t("rule.trigger.disconnect")
        case .rssiBelowThreshold: return L10n.t("rule.trigger.rssi")
        case .readingThreshold: return L10n.t("rule.trigger.reading")
        }
    }
}

/// 指标阈值的比较符；只覆盖读数的四种常用判定。
enum RuleComparison: String, Codable, CaseIterable, Equatable {
    case greaterThan = "gt"
    case greaterOrEqual = "gte"
    case lessThan = "lt"
    case lessOrEqual = "lte"

    /// 界面与日志中的符号，与 Android 端一致。
    var symbol: String {
        switch self {
        case .greaterThan: return ">"
        case .greaterOrEqual: return ">="
        case .lessThan: return "<"
        case .lessOrEqual: return "<="
        }
    }

    /// 命中提示里的自然语言关系词。
    var relation: String {
        switch self {
        case .greaterThan, .greaterOrEqual: return L10n.t("rule.relation.above")
        case .lessThan, .lessOrEqual: return L10n.t("rule.relation.below")
        }
    }

    func isSatisfied(by value: Double, threshold: Double) -> Bool {
        switch self {
        case .greaterThan: return value > threshold
        case .greaterOrEqual: return value >= threshold
        case .lessThan: return value < threshold
        case .lessOrEqual: return value <= threshold
        }
    }
}

/// 本地规则：作用于某台已保存设备，或全部设备（deviceID 为空）。
/// 只做本地记录与提示，不向设备下发任何指令。
struct DeviceRule: Identifiable, Equatable {
    let id: UUID
    var name: String
    var trigger: RuleTrigger
    /// 仅 `rssiBelowThreshold` 使用，单位 dBm，范围为 -100...-20。
    var threshold: Int
    /// 仅 `readingThreshold` 使用：被判定指标；nil 表示该规则不针对读数（旧规则升级后保持 nil）。
    var metric: ReadingMetric?
    /// 仅 `readingThreshold` 使用：比较符。
    var comparison: RuleComparison
    /// 仅 `readingThreshold` 使用：阈值，单位随指标。
    var readingThreshold: Double
    /// 仅 `readingThreshold` 使用：连续满足的读数条数，1...5，默认 1（防抖）。
    var consecutive: Int
    /// 目标设备；nil 表示对所有已保存设备生效。
    var deviceID: UUID?
    var isEnabled: Bool
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var syncState: SyncState

    init(
        id: UUID = UUID(),
        name: String,
        trigger: RuleTrigger,
        threshold: Int = -80,
        metric: ReadingMetric? = nil,
        comparison: RuleComparison = .greaterOrEqual,
        readingThreshold: Double = 0,
        consecutive: Int = 1,
        deviceID: UUID? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        syncState: SyncState = .pending
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.threshold = threshold
        self.metric = metric
        self.comparison = comparison
        self.readingThreshold = readingThreshold
        self.consecutive = min(max(consecutive, 1), 5)
        self.deviceID = deviceID
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncState = syncState
    }

    /// 读数值与阈值都要带单位展示（`℃` / `%` / `bpm`），不显示裸数字。
    var thresholdUnit: String { metric?.defaultUnit ?? "" }

    /// 例如「温度 > 30 ℃」；无指标时为空。
    var readingConditionText: String {
        guard let metric else { return "" }
        return "\(metric.displayName) \(comparison.symbol) \(Self.formatValue(readingThreshold)) \(thresholdUnit)"
            .trimmingCharacters(in: .whitespaces)
    }

    var triggerDescription: String {
        switch trigger {
        case .disconnect:
            return L10n.t("rule.description.disconnect")
        case .rssiBelowThreshold:
            return L10n.f("rule.description.rssi", String(describing: threshold))
        case .readingThreshold:
            let text = readingConditionText
            guard !text.isEmpty else { return L10n.t("rule.description.readingUnset") }
            return consecutive > 1 ? L10n.f("rule.description.consecutive", String(describing: text), String(describing: consecutive)) : L10n.f("rule.description.reading", String(describing: text))
        }
    }

    /// 数值格式化：整数不带小数，其余保留 1 位；使用 POSIX 小数点，避免地区差异。
    static func formatValue(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded(), abs(rounded) < 1_000_000 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", locale: Locale.current, rounded)
    }

    /// 带单位的读数展示，如「31.5 ℃」；单位为空时不追加空格。
    static func formatReading(_ value: Double, unit: String) -> String {
        let text = formatValue(value)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }
}

/// 规则事件类型：命中告警 / 恢复。
enum RuleEventKind: String, Equatable {
    case triggered
    case recovered
}

/// 规则命中或恢复时产生的事件，写入本地扫描日志、发本地通知并在界面提示。
struct RuleTriggerEvent: Equatable {
    let ruleID: UUID
    let ruleName: String
    let deviceID: UUID
    let deviceName: String
    let kind: RuleEventKind
    let message: String
    let occurredAt: Date
    /// 读数规则命中时的实际读数、阈值与单位；信号 / 断开规则为 nil。
    var value: Double? = nil
    var threshold: Double? = nil
    var unit: String = ""
}
