import UserNotifications

/// 本地通知抽象：便于在单测中替换 `UNUserNotificationCenter`。
protocol LocalNotificationServing: AnyObject {
    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void)
    /// 首次使用时请求授权；已授权直接回调 true，被拒绝回调 false。
    func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void)
    func schedule(event: RuleTriggerEvent, completion: ((Error?) -> Void)?)
}
