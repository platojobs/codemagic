import Foundation

/// 一次场景执行的结果；用于界面提示与测试断言。
struct SceneRunOutcome: Equatable {
    let sceneID: UUID
    let sceneName: String
    let triggered: Bool
    let skippedDeviceMissing: Bool
    let messages: [String]
}

/// 服务端场景的本地执行引擎。
///
/// - 触发条件映射到本地已有的判定方式：离线时长、RSSI 阈值、读数连续条数。
/// - `schedule` 不在这里轮询，由 `SceneScheduler` 交给系统日历通知。
/// - 引用设备不存在时跳过执行并写失败日志，绝不静默失效；场景本身保持启用。
final class SceneEngine {
    private let store: SceneStore
    private let deviceStore: SavedDeviceStore
    private let logStore: ScanLogStore
    private let notifications: SceneNotificationServing?
    private let now: () -> Date

    /// 场景 + 设备级别的状态，避免同一次越界反复触发。
    private var lastSeen: [UUID: Date] = [:]
    private var offlineFired: Set<UUID> = []
    private var rssiFired: Set<UUID> = []
    private var metricStreaks: [String: Int] = [:]
    private var metricFired: Set<UUID> = []
    private var missingLoggedAt: [UUID: Date] = [:]

    init(
        store: SceneStore,
        deviceStore: SavedDeviceStore,
        logStore: ScanLogStore,
        notifications: SceneNotificationServing? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.deviceStore = deviceStore
        self.logStore = logStore
        self.notifications = notifications
        self.now = now
    }

    /// 扫描回调：处理离线与 RSSI 条件。`observedRSSI` 的键是设备 peripheralID。
    @discardableResult
    func evaluateScans(observedRSSI: [UUID: Int], at date: Date) -> [SceneRunOutcome] {
        guard let scenes = try? store.fetchAll() else { return [] }
        var outcomes: [SceneRunOutcome] = []
        for scene in scenes {
            switch scene.trigger {
            case .deviceOffline(let reference, let seconds):
                guard let device = resolve(reference, scene: scene, now: date) else { continue }
                if observedRSSI[device.peripheralID] != nil {
                    lastSeen[device.peripheralID] = date
                    offlineFired.remove(scene.id)
                    continue
                }
                let base = lastSeen[device.peripheralID] ?? device.lastSeenAt
                guard let base else { continue }
                let elapsed = date.timeIntervalSince(base)
                guard elapsed >= Double(seconds) else { continue }
                guard !offlineFired.contains(scene.id) else { continue }
                offlineFired.insert(scene.id)
                if let outcome = fire(scene, context: context(device: device), at: date) {
                    outcomes.append(outcome)
                }

            case .rssiBelow(let reference, let threshold):
                guard let device = resolve(reference, scene: scene, now: date) else { continue }
                guard let rssi = observedRSSI[device.peripheralID] else { continue }
                if rssi > threshold {
                    rssiFired.remove(scene.id)
                    continue
                }
                guard !rssiFired.contains(scene.id) else { continue }
                rssiFired.insert(scene.id)
                var context = context(device: device)
                context.value = Double(rssi)
                if let outcome = fire(scene, context: context, at: date) {
                    outcomes.append(outcome)
                }

            default:
                continue
            }
        }
        return outcomes
    }

    /// 读数回调：处理指标阈值与连续条数。
    @discardableResult
    func evaluateReadings(
        _ readings: [DeviceReading],
        device: SavedDevice,
        at date: Date? = nil
    ) -> [SceneRunOutcome] {
        guard let scenes = try? store.fetchAll(), !readings.isEmpty else { return [] }
        let reference = date ?? now()
        var outcomes: [SceneRunOutcome] = []
        for scene in scenes {
            guard case .metricThreshold(
                let referenceDevice,
                _,
                let metric,
                let comparator,
                let threshold,
                let consecutive
            ) = scene.trigger else { continue }
            guard referenceDevice.platform == device.platform,
                  referenceDevice.externalID.caseInsensitiveCompare(device.externalID) == .orderedSame
            else { continue }
            guard resolve(referenceDevice, scene: scene, now: reference) != nil else { continue }

            let matching = readings
                .filter { $0.metric.rawValue.caseInsensitiveCompare(metric) == .orderedSame }
                .sorted { $0.recordedAt < $1.recordedAt }
            guard !matching.isEmpty else { continue }

            let key = "\(scene.id.uuidString)|\(device.id.uuidString)"
            var streak = metricStreaks[key] ?? 0
            for reading in matching {
                if comparator.isSatisfied(by: reading.value, threshold: threshold) {
                    streak += 1
                } else {
                    streak = 0
                    metricFired.remove(scene.id)
                }
                if streak >= consecutive, !metricFired.contains(scene.id) {
                    metricFired.insert(scene.id)
                    var context = context(device: device)
                    context.metricName = ReadingMetric(rawValue: metric)?.displayName ?? metric
                    context.value = reading.value
                    context.unit = reading.unit
                    if let outcome = fire(scene, context: context, at: reference) {
                        outcomes.append(outcome)
                    }
                }
            }
            metricStreaks[key] = streak
        }
        return outcomes
    }

    /// 主动刷新「设备已移除」标记（列表展示用），不执行场景。
    func refreshMissingFlags() {
        guard let scenes = try? store.fetchAll() else { return }
        for scene in scenes {
            guard let reference = scene.trigger.device else { continue }
            let existing: SavedDevice? = (try? deviceStore.fetch(
                platform: reference.platform,
                externalID: reference.externalID
            )) ?? nil
            try? store.updateDeviceMissing(id: scene.id, missing: existing == nil)
        }
    }

    // MARK: - Private

    private func resolve(
        _ reference: SceneDeviceReference,
        scene: Scene,
        now date: Date
    ) -> SavedDevice? {
        let fetched: SavedDevice? = (try? deviceStore.fetch(
            platform: reference.platform,
            externalID: reference.externalID
        )) ?? nil
        guard let device = fetched, device.deletedAt == nil else {
            try? store.updateDeviceMissing(id: scene.id, missing: true)
            logMissing(scene, at: date)
            return nil
        }
        if scene.deviceMissing {
            try? store.updateDeviceMissing(id: scene.id, missing: false)
        }
        return device
    }

    /// 设备缺失：执行跳过并写失败日志；同一场景在一个冷却窗口内只记一次，避免刷屏。
    private func logMissing(_ scene: Scene, at date: Date) {
        let window = max(Double(scene.cooldownSeconds), 300)
        if let last = missingLoggedAt[scene.id], date.timeIntervalSince(last) < window {
            return
        }
        missingLoggedAt[scene.id] = date
        try? logStore.append(
            ScanLogEntry(
                occurredAt: date,
                category: .rule,
                level: .warning,
                message: L10n.f("scene.run.skippedMissing", scene.name)
            )
        )
    }

    private func context(device: SavedDevice) -> SceneTriggerContext {
        SceneTriggerContext(deviceName: device.displayName)
    }

    /// 执行动作；返回 nil 表示被禁用或处于冷却窗口。
    private func fire(_ scene: Scene, context: SceneTriggerContext, at date: Date) -> SceneRunOutcome? {
        guard scene.enabled, scene.deletedAt == nil else { return nil }
        if let last = scene.lastRunAt, scene.cooldownSeconds > 0,
           date.timeIntervalSince(last) < Double(scene.cooldownSeconds) {
            return nil
        }

        var messages: [String] = []
        for action in scene.actions {
            switch action {
            case .notify(let title, let body):
                let renderedTitle = SceneTemplate.render(title, context: context)
                let renderedBody = SceneTemplate.render(body, context: context)
                notifications?.scheduleScene(
                    SceneNotificationRequest(
                        identifier: "scene-\(scene.id.uuidString)-run-\(Int(date.timeIntervalSince1970))",
                        title: renderedTitle,
                        body: renderedBody,
                        userInfo: [SceneNotificationKeys.sceneID: scene.id.uuidString],
                        fireDate: date
                    ),
                    completion: nil
                )
                messages.append("\(renderedTitle) / \(renderedBody)")

            case .log(let message, let level):
                let rendered = SceneTemplate.render(message, context: context)
                try? logStore.append(
                    ScanLogEntry(
                        occurredAt: date,
                        category: .rule,
                        level: level == .warn ? .warning : .info,
                        message: rendered
                    )
                )
                messages.append(rendered)

            case .markDevice(let mark):
                let deviceName = context.deviceName ?? "—"
                let message = L10n.f("scene.run.markApplied", deviceName, mark)
                try? logStore.append(
                    ScanLogEntry(
                        occurredAt: date,
                        category: .rule,
                        level: .info,
                        message: message
                    )
                )
                messages.append(message)
            }
        }
        try? store.markRun(id: scene.id, at: date)
        return SceneRunOutcome(
            sceneID: scene.id,
            sceneName: scene.name,
            triggered: true,
            skippedDeviceMissing: false,
            messages: messages
        )
    }
}
