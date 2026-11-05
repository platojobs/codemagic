import Foundation

/// 推荐规则模板：只针对设备真实出现过的指标生成，复用 `readingThreshold` 规则结构。
struct RuleTemplate: Equatable {
    let metric: ReadingMetric
    let comparison: RuleComparison
    let threshold: Double
    let consecutive: Int

    /// 例如「温度超过 30℃」；名称在创建时按当前语言写入本地，之后不再随语言变化。
    var title: String {
        L10n.f(
            "rule.template.title",
            metric.displayName,
            comparison == .lessThan || comparison == .lessOrEqual
                ? L10n.t("rule.template.below")
                : L10n.t("rule.template.above"),
            Self.formatValue(threshold),
            metric.defaultUnit
        )
    }

    var detail: String {
        L10n.f("rule.template.detail", String(consecutive))
    }

    func makeRule(deviceID: UUID) -> DeviceRule {
        DeviceRule(
            name: title,
            trigger: .readingThreshold,
            metric: metric,
            comparison: comparison,
            readingThreshold: threshold,
            consecutive: consecutive,
            deviceID: deviceID
        )
    }

    static func formatValue(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", locale: Locale.current, rounded)
    }
}

/// 模板生成规则：指标必须真实出现过，阈值取产品默认值，不凭空生成设备没有的指标。
enum RuleTemplateCatalog {
    /// 支持生成模板的指标，顺序与指标白名单一致。
    static let supportedMetrics: [ReadingMetric] = [.temperature, .humidity, .battery, .heartRate, .co2]

    static func templates(for metrics: [ReadingMetric]) -> [RuleTemplate] {
        let present = Set(metrics)
        return supportedMetrics
            .filter { present.contains($0) }
            .compactMap { metric in
                guard let preset = preset(for: metric) else { return nil }
                return RuleTemplate(
                    metric: metric,
                    comparison: preset.comparison,
                    threshold: preset.threshold,
                    consecutive: 1
                )
            }
    }

    static func preset(for metric: ReadingMetric) -> (comparison: RuleComparison, threshold: Double)? {
        switch metric {
        case .temperature: return (.greaterThan, 30)
        case .humidity: return (.greaterThan, 70)
        case .battery: return (.lessThan, 20)
        case .heartRate: return (.greaterThan, 120)
        case .co2: return (.greaterThan, 1000)
        case .pressure, .other: return nil
        }
    }
}
