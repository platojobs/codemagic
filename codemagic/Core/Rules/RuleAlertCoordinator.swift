import Foundation

/// 规则事件 → 本地通知：按「规则 + 设备」维度做节流，恢复时补发「已恢复」。
///
/// - 开关关闭时不发任何通知，也不请求授权；
/// - 首次真正需要通知时才请求系统授权，拒绝后由「我的」页提示去设置；
/// - 节流窗口默认 5 分钟（可配 1 / 5 / 30），窗口内同一规则同一设备只报一次；
/// - 只有实际发出过告警的设备才会收到「已恢复」，避免无对应告警的噪音。
final class RuleAlertCoordinator {
    private let settingsStore: SettingsStore
    private let notifications: LocalNotificationServing

    private var lastAlertAt: [String: Date] = [:]
    private var deliveredKeys: Set<String> = []

    init(settingsStore: SettingsStore, notifications: LocalNotificationServing) {
        self.settingsStore = settingsStore
        self.notifications = notifications
    }

    func handle(_ events: [RuleTriggerEvent], now: Date = Date()) {
        guard settingsStore.ruleAlertsEnabled else { return }
        for event in events {
            handle(event, now: now)
        }
    }

    /// 打开告警开关时提前请求授权，便于在「我的」页即时展示被拒绝的引导。
    func prepareAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard settingsStore.ruleAlertsEnabled else {
            completion?(false)
            return
        }
        notifications.requestAuthorizationIfNeeded { granted in
            completion?(granted)
        }
    }

    func resetThrottle() {
        lastAlertAt.removeAll()
        deliveredKeys.removeAll()
    }

    // MARK: - Private

    private func handle(_ event: RuleTriggerEvent, now: Date) {
        let key = "\(event.ruleID.uuidString)-\(event.deviceID.uuidString)"

        switch event.kind {
        case .triggered:
            if let last = lastAlertAt[key], now.timeIntervalSince(last) < settingsStore.ruleAlertThrottleInterval {
                return
            }
            lastAlertAt[key] = now
            notifications.requestAuthorizationIfNeeded { [weak self] granted in
                guard let self, granted else { return }
                self.deliveredKeys.insert(key)
                self.notifications.schedule(event: event, completion: nil)
            }

        case .recovered:
            guard deliveredKeys.contains(key) else { return }
            deliveredKeys.remove(key)
            lastAlertAt.removeValue(forKey: key)
            notifications.schedule(event: event, completion: nil)
        }
    }
}
