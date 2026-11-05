import Foundation

/// 本地规则引擎：只消费扫描结果与落库读数，不向设备发送任何指令。
///
/// 判定口径：
/// - 断开：设备在上一轮扫描中出现、本轮未出现，视为断开；重新出现时发恢复事件，再次消失才再次告警。
/// - 信号：RSSI ≤ 阈值时告警一次，回到阈值以上后发恢复事件并重新武装。
/// - 读数：指标读数满足「比较符 + 阈值」并连续 N 条才告警一次（防抖），之后任一条不满足即发恢复并重新武装。
///   恢复事件只代表「状态解除」，是否真正发通知由 `RuleAlertCoordinator` 按「确认发过告警」决定。
final class RuleEvaluator {
    private var previouslySeen: Set<UUID> = []
    private var alertedKey: Set<String> = []
    private var disconnectedKey: Set<String> = []
    /// 读数规则：规则 + 设备维度的连续满足条数。
    private var readingStreaks: [String: Int] = [:]
    /// 已经告警、尚未恢复的读数规则。
    private var readingAlertedKey: Set<String> = []

    /// 每次新的扫描会话前调用，避免上一次会话的「已出现」状态造成误判。
    func reset() {
        previouslySeen.removeAll()
        alertedKey.removeAll()
        disconnectedKey.removeAll()
        readingStreaks.removeAll()
        readingAlertedKey.removeAll()
    }

    func evaluate(
        rules: [DeviceRule],
        devices: [SavedDevice],
        observedRSSI: [UUID: Int],
        date: Date = Date()
    ) -> [RuleTriggerEvent] {
        var events: [RuleTriggerEvent] = []

        for rule in rules where rule.isEnabled {
            let targets = devices.filter { device in
                guard let targetID = rule.deviceID else { return true }
                return device.id == targetID
            }

            for device in targets {
                let rssi = observedRSSI[device.peripheralID]
                let key = Self.alertKey(rule: rule, device: device)

                switch rule.trigger {
                case .disconnect:
                    let wasSeen = previouslySeen.contains(device.peripheralID)
                    let isSeenNow = rssi != nil
                    if wasSeen && !isSeenNow && !disconnectedKey.contains(key) {
                        disconnectedKey.insert(key)
                        events.append(
                            RuleTriggerEvent(
                                ruleID: rule.id,
                                ruleName: rule.name,
                                deviceID: device.id,
                                deviceName: device.displayName,
                                kind: .triggered,
                                message: L10n.f("rule.event.disappeared", String(describing: rule.name), String(describing: device.displayName)),
                                occurredAt: date
                            )
                        )
                    } else if isSeenNow && disconnectedKey.contains(key) {
                        disconnectedKey.remove(key)
                        events.append(
                            RuleTriggerEvent(
                                ruleID: rule.id,
                                ruleName: rule.name,
                                deviceID: device.id,
                                deviceName: device.displayName,
                                kind: .recovered,
                                message: L10n.f("rule.event.reappeared", String(describing: rule.name), String(describing: device.displayName)),
                                occurredAt: date
                            )
                        )
                    }

                case .rssiBelowThreshold:
                    if let rssi, rssi <= rule.threshold {
                        if !alertedKey.contains(key) {
                            alertedKey.insert(key)
                            events.append(
                                RuleTriggerEvent(
                                    ruleID: rule.id,
                                    ruleName: rule.name,
                                    deviceID: device.id,
                                    deviceName: device.displayName,
                                    kind: .triggered,
                                    message: L10n.f("rule.event.rssiLow", String(describing: rule.name), String(describing: device.displayName), String(describing: rssi), String(describing: rule.threshold)),
                                    occurredAt: date,
                                    value: Double(rssi),
                                    threshold: Double(rule.threshold),
                                    unit: "dBm"
                                )
                            )
                        }
                    } else if alertedKey.contains(key) {
                        alertedKey.remove(key)
                        let current = rssi.map { "\($0) dBm" } ?? L10n.t("rule.event.invisible")
                        events.append(
                            RuleTriggerEvent(
                                ruleID: rule.id,
                                ruleName: rule.name,
                                deviceID: device.id,
                                deviceName: device.displayName,
                                kind: .recovered,
                                message: L10n.f("rule.event.rssiRecovered", String(describing: rule.name), String(describing: device.displayName), String(describing: current), String(describing: rule.threshold)),
                                occurredAt: date
                            )
                        )
                    }

                case .readingThreshold:
                    // 读数规则由 `evaluateReadings` 按每个读数样本推进，扫描回调不参与。
                    break
                }
            }
        }

        previouslySeen = Set(observedRSSI.keys)
        return events
    }

    /// 按「规则 + 设备 + 指标」推进连续计数。
    ///
    /// - 只有指标匹配、且规则未停用 / 设备在范围内时才计数；
    /// - 连续 N 条满足才告警一次，之后的满足条数继续累加但不再重复告警；
    /// - 任一条不满足即清零并（若已告警）发一条恢复事件。
    func evaluateReadings(
        rules: [DeviceRule],
        device: SavedDevice,
        readings: [DeviceReading]
    ) -> [RuleTriggerEvent] {
        var events: [RuleTriggerEvent] = []

        for rule in rules where rule.isEnabled && rule.trigger == .readingThreshold {
            guard let metric = rule.metric else { continue }
            if let targetID = rule.deviceID, targetID != device.id { continue }

            let key = Self.alertKey(rule: rule, device: device)
            let unit = metric.defaultUnit
            let condition = rule.readingConditionText
            let matching = readings
                .filter { $0.metric == metric }
                .sorted { $0.recordedAt < $1.recordedAt }
            guard !matching.isEmpty else { continue }

            var streak = readingStreaks[key] ?? 0
            var isAlerted = readingAlertedKey.contains(key)

            for reading in matching {
                let satisfied = rule.comparison.isSatisfied(
                    by: reading.value,
                    threshold: rule.readingThreshold
                )
                if satisfied {
                    streak += 1
                    if !isAlerted && streak >= rule.consecutive {
                        isAlerted = true
                        readingAlertedKey.insert(key)
                        let value = DeviceRule.formatReading(reading.value, unit: unit)
                        let threshold = DeviceRule.formatReading(rule.readingThreshold, unit: unit)
                        let suffix = rule.consecutive > 1 ? L10n.f("rule.event.consecutiveSuffix", String(describing: streak)) : ""
                        events.append(
                            RuleTriggerEvent(
                                ruleID: rule.id,
                                ruleName: rule.name,
                                deviceID: device.id,
                                deviceName: device.displayName,
                                kind: .triggered,
                                message: L10n.f("rule.event.readingTriggered", String(describing: rule.name), String(describing: device.displayName), String(describing: metric.displayName), String(describing: value), String(describing: rule.comparison.symbol), String(describing: threshold), String(describing: suffix)),
                                occurredAt: reading.recordedAt,
                                value: reading.value,
                                threshold: rule.readingThreshold,
                                unit: unit
                            )
                        )
                    }
                } else {
                    streak = 0
                    if isAlerted {
                        isAlerted = false
                        readingAlertedKey.remove(key)
                        let current = DeviceRule.formatReading(reading.value, unit: unit)
                        let threshold = DeviceRule.formatReading(rule.readingThreshold, unit: unit)
                        events.append(
                            RuleTriggerEvent(
                                ruleID: rule.id,
                                ruleName: rule.name,
                                deviceID: device.id,
                                deviceName: device.displayName,
                                kind: .recovered,
                                message: L10n.f("rule.event.readingRecovered", String(describing: rule.name), String(describing: device.displayName), String(describing: metric.displayName), String(describing: current), String(describing: threshold), String(describing: condition)),
                                occurredAt: reading.recordedAt,
                                value: reading.value,
                                threshold: rule.readingThreshold,
                                unit: unit
                            )
                        )
                    }
                }
            }

            readingStreaks[key] = streak
        }

        return events
    }

    private static func alertKey(rule: DeviceRule, device: SavedDevice) -> String {
        "\(rule.id.uuidString)-\(device.peripheralID.uuidString)"
    }
}
