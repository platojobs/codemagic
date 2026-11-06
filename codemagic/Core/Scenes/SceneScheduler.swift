import Foundation

/// 计算定时场景的下一次触发时间。
///
/// 用 `Calendar.nextDate(after:matching:)` 而不是「当前时间 + 86400」：
/// - 按 `timezone` 指定的 IANA 时区解释 `timeOfDay` 的墙钟时间；
/// - 夏令时切换日 23/25 小时、以及春季跳过的 02:30 等不存在时刻，由系统按 `.nextTime` 顺延到有效时间；
/// - 秋季重复时刻取第一次（`.first`），避免同一分钟触发两次。
enum SceneScheduleCalculator {
    static func nextFire(after now: Date, trigger: SceneTrigger) -> Date? {
        guard case .schedule(let timeOfDay, let timezone, let days) = trigger else { return nil }
        return nextFire(after: now, timeOfDay: timeOfDay, timezoneID: timezone, daysOfWeek: days)
    }

    static func nextFire(
        after now: Date,
        timeOfDay: String,
        timezoneID: String,
        daysOfWeek: [Int]
    ) -> Date? {
        let parts = timeOfDay.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else {
            return nil
        }
        let timezone = TimeZone(identifier: timezoneID) ?? TimeZone(identifier: "UTC") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        if daysOfWeek.isEmpty {
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: minute, second: 0),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        }

        var earliest: Date?
        for isoDay in Set(daysOfWeek).sorted() where (1...7).contains(isoDay) {
            // ISO 1=周一；Calendar 的 weekday 1=周日。
            let weekday = isoDay == 7 ? 1 : isoDay + 1
            let candidate = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
            guard let candidate else { continue }
            if let current = earliest {
                earliest = min(current, candidate)
            } else {
                earliest = candidate
            }
        }
        return earliest
    }
}

/// 把定时场景写入系统日历通知。
///
/// 每个星期几各注册一条「每周重复」通知；星期为空时注册一条「每天重复」通知。
/// 重复组件里携带 `timeZone`，由系统按该时区的墙钟时间触发，跨 DST 无需客户端重算。
final class SceneScheduler {
    static let identifierPrefix = "scene-"

    private let notifications: SceneNotificationServing?
    private let now: () -> Date

    init(notifications: SceneNotificationServing?, now: @escaping () -> Date = Date.init) {
        self.notifications = notifications
        self.now = now
    }

    func nextFire(for scene: Scene, after date: Date? = nil) -> Date? {
        SceneScheduleCalculator.nextFire(after: date ?? now(), trigger: scene.trigger)
    }

    /// 重建全部场景通知：先取消旧的 `scene-` 前缀通知，再按当前场景注册。
    func reschedule(scenes: [Scene], completion: (() -> Void)? = nil) {
        guard let notifications else {
            completion?()
            return
        }
        notifications.cancelSceneNotifications { [weak self] in
            guard let self else { return }
            for scene in scenes where scene.enabled && scene.deletedAt == nil {
                for request in Self.notificationRequests(for: scene, now: self.now()) {
                    notifications.scheduleScene(request, completion: nil)
                }
            }
            completion?()
        }
    }

    /// 定时场景的通知请求；没有 `notify` 动作时不需要系统通知（只靠前台执行）。
    static func notificationRequests(for scene: Scene, now: Date) -> [SceneNotificationRequest] {
        guard case .schedule(let timeOfDay, let timezone, let days) = scene.trigger,
              let notify = scene.actions.compactMap({ action -> (String, String)? in
                  if case .notify(let title, let body) = action { return (title, body) }
                  return nil
              }).first else {
            return []
        }
        let parts = timeOfDay.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return [] }
        let timezoneObject = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezoneObject
        let context = SceneTriggerContext.empty
        let title = SceneTemplate.render(notify.0, context: context)
        let body = SceneTemplate.render(notify.1, context: context)

        let weekdayValues: [Int?] = days.isEmpty
            ? [nil]
            : Set(days).sorted().map { iso in
                guard (1...7).contains(iso) else { return nil }
                return iso == 7 ? 1 : iso + 1
            }
        return weekdayValues.compactMap { weekday in
            guard days.isEmpty || weekday != nil else { return nil }
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = timezoneObject
            components.hour = hour
            components.minute = minute
            components.weekday = weekday
            let suffix = weekday.map(String.init) ?? "daily"
            return SceneNotificationRequest(
                identifier: "\(identifierPrefix)\(scene.id.uuidString)-\(suffix)",
                title: title,
                body: body,
                userInfo: [SceneNotificationKeys.sceneID: scene.id.uuidString],
                repeatComponents: components
            )
        }
    }
}
