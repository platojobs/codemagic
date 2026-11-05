import Foundation

/// 本地规则引擎：只消费扫描结果，不向设备发送任何指令。
///
/// 判定口径：
/// - 断开：设备在上一轮扫描中出现、本轮未出现，视为断开；重新出现时发恢复事件，再次消失才再次告警。
/// - 信号：RSSI ≤ 阈值时告警一次，回到阈值以上后发恢复事件并重新武装。
final class RuleEvaluator {
    private var previouslySeen: Set<UUID> = []
    private var alertedKey: Set<String> = []
    private var disconnectedKey: Set<String> = []

    /// 每次新的扫描会话前调用，避免上一次会话的「已出现」状态造成误判。
    func reset() {
        previouslySeen.removeAll()
        alertedKey.removeAll()
        disconnectedKey.removeAll()
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
                                message: "规则「\(rule.name)」：设备「\(device.displayName)」已从扫描结果中消失",
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
                                message: "规则「\(rule.name)」：设备「\(device.displayName)」已重新出现在扫描结果中",
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
                                    message: "规则「\(rule.name)」：设备「\(device.displayName)」信号 \(rssi) dBm 低于阈值 \(rule.threshold) dBm",
                                    occurredAt: date
                                )
                            )
                        }
                    } else if alertedKey.contains(key) {
                        alertedKey.remove(key)
                        let current = rssi.map { "\($0) dBm" } ?? "已不可见"
                        events.append(
                            RuleTriggerEvent(
                                ruleID: rule.id,
                                ruleName: rule.name,
                                deviceID: device.id,
                                deviceName: device.displayName,
                                kind: .recovered,
                                message: "规则「\(rule.name)」：设备「\(device.displayName)」信号已恢复（\(current)，阈值 \(rule.threshold) dBm）",
                                occurredAt: date
                            )
                        )
                    }
                }
            }
        }

        previouslySeen = Set(observedRSSI.keys)
        return events
    }

    private static func alertKey(rule: DeviceRule, device: SavedDevice) -> String {
        "\(rule.id.uuidString)-\(device.peripheralID.uuidString)"
    }
}
