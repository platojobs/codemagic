import UserNotifications

/// 基于 `UNUserNotificationCenter` 的本地通知实现。
///
/// 通知只用于阈值告警与恢复提示；点击通知携带 `deviceID`，由 SceneDelegate 路由到设备详情。
final class UserNotificationService: LocalNotificationServing {
    static let shared = UserNotificationService()

    static let deviceIDKey = "codemagic.deviceID"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { completion(true) }
            case .denied:
                DispatchQueue.main.async { completion(false) }
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
            @unknown default:
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    func schedule(event: RuleTriggerEvent, completion: ((Error?) -> Void)? = nil) {
        let content = UNMutableNotificationContent()
        content.title = event.kind == .triggered
            ? L10n.f("notification.ruleAlert.title", String(describing: event.ruleName))
            : L10n.f("notification.ruleAlert.recovered", String(describing: event.ruleName))
        content.body = event.message
        content.sound = .default
        content.userInfo = [Self.deviceIDKey: event.deviceID.uuidString]

        let identifier = [
            "rule",
            event.ruleID.uuidString,
            event.deviceID.uuidString,
            event.kind.rawValue,
            String(Int(event.occurredAt.timeIntervalSince1970)),
        ].joined(separator: "-")
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request, withCompletionHandler: completion)
    }
}
