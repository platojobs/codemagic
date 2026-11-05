import Foundation

/// 本地规则触发条件。
enum RuleTrigger: String, Codable, CaseIterable {
    /// 设备从扫描结果中消失（视为断开）。
    case disconnect
    /// RSSI 低于阈值。
    case rssiBelowThreshold

    var title: String {
        switch self {
        case .disconnect: return "设备断开"
        case .rssiBelowThreshold: return "信号低于阈值"
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
        self.deviceID = deviceID
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncState = syncState
    }

    var triggerDescription: String {
        switch trigger {
        case .disconnect:
            return "设备从扫描结果中消失时记录"
        case .rssiBelowThreshold:
            return "RSSI ≤ \(threshold) dBm 时记录并提示"
        }
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
}
