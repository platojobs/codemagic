import Foundation

/// 场景通知 userInfo 的键；点击通知后可据此回到场景列表。
enum SceneNotificationKeys {
    static let sceneID = "codemagic.sceneID"
}

/// 一个服务端场景要显示的本地通知。
struct SceneNotificationRequest {
    let identifier: String
    let title: String
    let body: String
    let userInfo: [String: String]
    /// 即时通知使用；重复定时通知留空，改用 `repeatComponents`。
    let fireDate: Date?
    /// 日历重复组件（含 `timeZone`），由系统按本地墙钟时间触发，跨 DST 正确。
    let repeatComponents: DateComponents?

    init(
        identifier: String,
        title: String,
        body: String,
        userInfo: [String: String] = [:],
        fireDate: Date? = nil,
        repeatComponents: DateComponents? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.userInfo = userInfo
        self.fireDate = fireDate
        self.repeatComponents = repeatComponents
    }
}

protocol SceneNotificationServing: AnyObject {
    func scheduleScene(_ request: SceneNotificationRequest, completion: ((Error?) -> Void)?)
    func cancelSceneNotifications(completion: (() -> Void)?)
}
