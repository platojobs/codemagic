import Foundation

/// 触发时可用于渲染占位符的上下文。
struct SceneTriggerContext: Equatable {
    var deviceName: String?
    var metricName: String?
    var value: Double?
    var unit: String?

    static let empty = SceneTriggerContext()
}

/// `notify` 的 title / body 占位符渲染。
///
/// 约定（与 `docs/consistency.md` 同步）：
/// - `{device}`：设备展示名（别名优先）。
/// - `{metric}`：指标展示名（如「温度」）。
/// - `{value}`：读数数值，保留整数或 1 位小数，不含单位。
/// - 上下文缺失时替换为 `—`，不会把占位符原样展示给用户。
/// - 未知占位符（如 `{foo}`）保持原样，避免误吞用户文本。
enum SceneTemplate {
    static func render(_ template: String, context: SceneTriggerContext) -> String {
        var result = template
        result = result.replacingOccurrences(
            of: "{device}",
            with: context.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "—"
        )
        result = result.replacingOccurrences(
            of: "{metric}",
            with: context.metricName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "—"
        )
        result = result.replacingOccurrences(
            of: "{value}",
            with: context.value.map(SceneNumber.text) ?? "—"
        )
        return result
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
