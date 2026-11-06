import Foundation

/// 服务端场景绑定的设备：与同步接口一致的复合键。
struct SceneDeviceReference: Equatable, Codable {
    var platform: String
    var externalID: String

    init(platform: String, externalID: String) {
        self.platform = platform
        self.externalID = externalID
    }

    private enum CodingKeys: String, CodingKey {
        case platform, externalId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = try container.decode(String.self, forKey: .platform)
        externalID = try container.decode(String.self, forKey: .externalId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platform, forKey: .platform)
        try container.encode(externalID, forKey: .externalId)
    }
}

/// 指标比较符，与服务端 `comparator` 取值一致。
enum SceneComparator: String, Codable, CaseIterable {
    case lt
    case lte
    case gt
    case gte

    var symbol: String {
        switch self {
        case .lt: return "<"
        case .lte: return "<="
        case .gt: return ">"
        case .gte: return ">="
        }
    }

    func isSatisfied(by value: Double, threshold: Double) -> Bool {
        switch self {
        case .lt: return value < threshold
        case .lte: return value <= threshold
        case .gt: return value > threshold
        case .gte: return value >= threshold
        }
    }
}

/// 服务端场景触发条件。`kind` 决定哪些字段有效。
enum SceneTrigger: Equatable {
    case deviceOffline(device: SceneDeviceReference, offlineSeconds: Int)
    case rssiBelow(device: SceneDeviceReference, rssiThreshold: Int)
    case metricThreshold(
        device: SceneDeviceReference,
        deviceType: String,
        metric: String,
        comparator: SceneComparator,
        threshold: Double,
        consecutive: Int
    )
    case schedule(timeOfDay: String, timezone: String, daysOfWeek: [Int])

    var kind: String {
        switch self {
        case .deviceOffline: return "device_offline"
        case .rssiBelow: return "rssi_below"
        case .metricThreshold: return "metric_threshold"
        case .schedule: return "schedule"
        }
    }

    var device: SceneDeviceReference? {
        switch self {
        case .deviceOffline(let device, _), .rssiBelow(let device, _),
             .metricThreshold(let device, _, _, _, _, _):
            return device
        case .schedule:
            return nil
        }
    }

    var metricKey: String? {
        if case .metricThreshold(_, _, let metric, _, _, _) = self { return metric }
        return nil
    }

    /// 服务端代理写入时读回的时间，用于本地 LWW 比较。
    var title: String {
        switch self {
        case .deviceOffline(_, let seconds):
            return L10n.f("scene.trigger.offline", SceneDuration.text(seconds: seconds))
        case .rssiBelow(_, let threshold):
            return L10n.f("scene.trigger.rssi", String(threshold))
        case .metricThreshold(_, _, let metric, let comparator, let threshold, let consecutive):
            let name = ReadingMetric(rawValue: metric)?.displayName ?? metric
            return L10n.f(
                "scene.trigger.metric",
                name,
                comparator.symbol,
                SceneNumber.text(threshold),
                String(consecutive)
            )
        case .schedule(let timeOfDay, let timezone, let days):
            if days.isEmpty {
                return L10n.f("scene.trigger.scheduleDaily", timeOfDay, timezone)
            }
            return L10n.f("scene.trigger.scheduleWeekly", timeOfDay, SceneWeekday.text(days: days), timezone)
        }
    }
}

extension SceneTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, device, offlineSeconds, rssiThreshold, deviceType, metric
        case timeOfDay, timezone, daysOfWeek
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "device_offline":
            self = .deviceOffline(
                device: try container.decode(SceneDeviceReference.self, forKey: .device),
                offlineSeconds: try container.decodeIfPresent(Int.self, forKey: .offlineSeconds) ?? 300
            )
        case "rssi_below":
            self = .rssiBelow(
                device: try container.decode(SceneDeviceReference.self, forKey: .device),
                rssiThreshold: try container.decode(Int.self, forKey: .rssiThreshold)
            )
        case "metric_threshold":
            let metric = try container.decode(
                SceneMetricConditionPayload.self,
                forKey: .metric
            )
            self = .metricThreshold(
                device: try container.decode(SceneDeviceReference.self, forKey: .device),
                deviceType: try container.decodeIfPresent(String.self, forKey: .deviceType) ?? "",
                metric: metric.metric,
                comparator: metric.comparator,
                threshold: metric.threshold,
                consecutive: metric.consecutive
            )
        case "schedule":
            self = .schedule(
                timeOfDay: try container.decode(String.self, forKey: .timeOfDay),
                timezone: try container.decodeIfPresent(String.self, forKey: .timezone) ?? "UTC",
                daysOfWeek: try container.decodeIfPresent([Int].self, forKey: .daysOfWeek) ?? []
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "未知的场景触发条件"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .deviceOffline(let device, let seconds):
            try container.encode(device, forKey: .device)
            try container.encode(seconds, forKey: .offlineSeconds)
        case .rssiBelow(let device, let threshold):
            try container.encode(device, forKey: .device)
            try container.encode(threshold, forKey: .rssiThreshold)
        case .metricThreshold(let device, let deviceType, let metric, let comparator, let threshold, let consecutive):
            try container.encode(device, forKey: .device)
            try container.encode(deviceType, forKey: .deviceType)
            try container.encode(
                SceneMetricConditionPayload(
                    metric: metric,
                    comparator: comparator,
                    threshold: threshold,
                    consecutive: consecutive
                ),
                forKey: .metric
            )
        case .schedule(let timeOfDay, let timezone, let days):
            try container.encode(timeOfDay, forKey: .timeOfDay)
            try container.encode(timezone, forKey: .timezone)
            try container.encode(days, forKey: .daysOfWeek)
        }
    }
}

/// 服务端 `trigger.metric` 的 JSON 结构。
struct SceneMetricConditionPayload: Codable, Equatable {
    var metric: String
    var comparator: SceneComparator
    var threshold: Double
    var consecutive: Int
}

/// 场景动作。同一场景内动作种类不重复，数量 1...4。
enum SceneAction: Equatable {
    case notify(title: String, body: String)
    case log(message: String, level: SceneLogLevel)
    case markDevice(mark: String)

    var kind: String {
        switch self {
        case .notify: return "notify"
        case .log: return "log"
        case .markDevice: return "mark_device"
        }
    }

    var title: String {
        switch self {
        case .notify: return L10n.t("scene.action.notify")
        case .log: return L10n.t("scene.action.log")
        case .markDevice: return L10n.t("scene.action.markDevice")
        }
    }

    var detail: String {
        switch self {
        case .notify(let title, _): return title
        case .log(let message, _): return message
        case .markDevice(let mark): return mark
        }
    }
}

enum SceneLogLevel: String, Codable, CaseIterable {
    case info
    case warn
}

extension SceneAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, title, body, message, level, mark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "notify":
            self = .notify(
                title: try container.decode(String.self, forKey: .title),
                body: try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            )
        case "log":
            self = .log(
                message: try container.decode(String.self, forKey: .message),
                level: try container.decodeIfPresent(SceneLogLevel.self, forKey: .level) ?? .info
            )
        case "mark_device":
            self = .markDevice(mark: try container.decode(String.self, forKey: .mark))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "未知的场景动作"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .notify(let title, let body):
            try container.encode(title, forKey: .title)
            try container.encode(body, forKey: .body)
        case .log(let message, let level):
            try container.encode(message, forKey: .message)
            try container.encode(level.rawValue, forKey: .level)
        case .markDevice(let mark):
            try container.encode(mark, forKey: .mark)
        }
    }
}

/// 参与字段级 LWW 的 5 个字段。
enum SceneFieldKey: String, CaseIterable {
    case name
    case enabled
    case cooldownSeconds
    case trigger
    case actions
}

/// 本地场景记录：`kind = automation`，与服务端场景一一对应（或等待首次上传）。
struct Scene: Identifiable, Equatable {
    let id: UUID
    var remoteID: String?
    var name: String
    var enabled: Bool
    var cooldownSeconds: Int
    var trigger: SceneTrigger
    var actions: [SceneAction]
    /// 服务端版本号；0 表示尚未上传。
    var version: Int64
    var deviceMissing: Bool
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var syncState: SyncState
    var fieldUpdatedAt: [SceneFieldKey: Date]
    var lastSyncedAt: Date?
    var lastRunAt: Date?

    init(
        id: UUID = UUID(),
        remoteID: String? = nil,
        name: String,
        enabled: Bool = true,
        cooldownSeconds: Int = 300,
        trigger: SceneTrigger,
        actions: [SceneAction],
        version: Int64 = 0,
        deviceMissing: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        syncState: SyncState = .pending,
        fieldUpdatedAt: [SceneFieldKey: Date] = [:],
        lastSyncedAt: Date? = nil,
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.remoteID = remoteID
        self.name = name
        self.enabled = enabled
        self.cooldownSeconds = cooldownSeconds
        self.trigger = trigger
        self.actions = actions
        self.version = version
        self.deviceMissing = deviceMissing
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncState = syncState
        self.fieldUpdatedAt = fieldUpdatedAt
        self.lastSyncedAt = lastSyncedAt
        self.lastRunAt = lastRunAt
    }

    var summary: String {
        guard let first = actions.first else { return trigger.title }
        return "\(trigger.title) → \(first.title)"
    }

    var actionSummary: String {
        actions.map(\.title).joined(separator: " → ")
    }

    /// 本地时钟上该字段是否还有未推送的修改。
    func isFieldDirty(_ field: SceneFieldKey) -> Bool {
        guard let editedAt = fieldUpdatedAt[field] else { return false }
        guard let lastSyncedAt else { return true }
        return editedAt > lastSyncedAt
    }

    var hasLocalChanges: Bool {
        SceneFieldKey.allCases.contains { isFieldDirty($0) }
    }

    var dirtyFields: [SceneFieldKey] {
        SceneFieldKey.allCases.filter(isFieldDirty)
    }

    func field(_ key: SceneFieldKey) -> SceneFieldValue {
        switch key {
        case .name: return .init(text: name, date: fieldUpdatedAt[.name] ?? updatedAt)
        case .enabled: return .init(bool: enabled, date: fieldUpdatedAt[.enabled] ?? updatedAt)
        case .cooldownSeconds:
            return .init(number: cooldownSeconds, date: fieldUpdatedAt[.cooldownSeconds] ?? updatedAt)
        case .trigger: return .init(date: fieldUpdatedAt[.trigger] ?? updatedAt)
        case .actions: return .init(date: fieldUpdatedAt[.actions] ?? updatedAt)
        }
    }
    /// 内容签名：用于「POST 响应丢失后重试」时与服务端列表做对账，避免重复创建。
    var contentSignature: String {
        Self.signature(
            name: name,
            enabled: enabled,
            cooldownSeconds: cooldownSeconds,
            trigger: trigger,
            actions: actions
        )
    }

    static func signature(
        name: String,
        enabled: Bool,
        cooldownSeconds: Int,
        trigger: SceneTrigger,
        actions: [SceneAction]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let triggerJSON = (try? encoder.encode(trigger)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let actionsJSON = (try? encoder.encode(actions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "\(name)|\(enabled)|\(cooldownSeconds)|\(triggerJSON)|\(actionsJSON)"
    }
}

/// 字段快照，便于在合并 / 推送时统一处理时间戳。
struct SceneFieldValue: Equatable {
    var text: String?
    var bool: Bool?
    var number: Int?
    var date: Date

    init(text: String, date: Date) {
        self.text = text
        self.date = date
    }

    init(bool: Bool, date: Date) {
        self.bool = bool
        self.date = date
    }

    init(number: Int, date: Date) {
        self.number = number
        self.date = date
    }

    init(date: Date) {
        self.date = date
    }
}

/// 场景「下一次触发时间」与展示用的工具。
enum SceneNumber {
    static func text(_ value: Double) -> String {
        if value == Double(Int(value)) { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}

enum SceneDuration {
    static func text(seconds: Int) -> String {
        let minutes = seconds / 60
        if seconds % 60 == 0, minutes > 0 {
            return L10n.f("scene.duration.minutes", String(minutes))
        }
        return L10n.f("scene.duration.seconds", String(seconds))
    }
}

enum SceneWeekday {
    /// ISO 星期（1=周一）。
    static func text(days: [Int]) -> String {
        days.sorted().map { iso in
            let key = ["weekday.mon", "weekday.tue", "weekday.wed", "weekday.thu", "weekday.fri", "weekday.sat", "weekday.sun"]
            let index = min(max(iso - 1, 0), 6)
            return L10n.t(key[index])
        }.joined(separator: L10n.t("common.listSeparator"))
    }
}
