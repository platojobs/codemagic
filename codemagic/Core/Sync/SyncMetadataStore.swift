import Foundation

/// 同步游标、上次同步时间与客户端标识。
/// 这些不是敏感凭据，存 UserDefaults；token 由 `TokenStoring` 单独放 Keychain。
final class SyncMetadataStore {
    private enum Key {
        static let cursor = "sync.cursor"
        static let lastSyncAt = "sync.lastSyncAt"
        static let userID = "sync.userId"
        static let clientID = "sync.clientId"
        static let reloginRequired = "sync.reloginRequired"
        static let lastBackgroundPushAt = "sync.lastBackgroundPushAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 增量游标：上次响应的 `nextCursor`，首次为 0。
    var cursor: Int64 {
        get { Int64(defaults.double(forKey: Key.cursor)) }
        set { defaults.set(Double(newValue), forKey: Key.cursor) }
    }

    var lastSyncAt: Date? {
        get {
            guard defaults.object(forKey: Key.lastSyncAt) != nil else { return nil }
            let value = defaults.double(forKey: Key.lastSyncAt)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastSyncAt)
            } else {
                defaults.removeObject(forKey: Key.lastSyncAt)
            }
        }
    }

    /// 匿名用户 ID，与 Keychain 中的 token 对应。
    var userID: String? {
        get { defaults.string(forKey: Key.userID) }
        set { defaults.set(newValue, forKey: Key.userID) }
    }

    /// 登录已失效、等待用户确认重新登录。为 true 时不得静默新建匿名账号。
    var reloginRequired: Bool {
        get { defaults.bool(forKey: Key.reloginRequired) }
        set { defaults.set(newValue, forKey: Key.reloginRequired) }
    }

    /// 客户端标识，随安装持久；写入服务端 `clientId`，用于诊断最后写入方。
    var clientID: String {
        if let existing = defaults.string(forKey: Key.clientID), !existing.isEmpty {
            return existing
        }
        let generated = "ios-\(UUID().uuidString.uppercased())"
        defaults.set(generated, forKey: Key.clientID)
        return generated
    }

    func resetCursor() {
        cursor = 0
        lastSyncAt = nil
    }

    /// 后台唤醒推送的最小间隔记录：避免系统在省电窗口内频繁唤醒造成网络风暴。
    var lastBackgroundPushAt: Date? {
        get {
            guard defaults.object(forKey: Key.lastBackgroundPushAt) != nil else { return nil }
            let value = defaults.double(forKey: Key.lastBackgroundPushAt)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastBackgroundPushAt)
            } else {
                defaults.removeObject(forKey: Key.lastBackgroundPushAt)
            }
        }
    }

    /// 注销账号：清空同步归属与游标，保留 `clientID`（本安装标识用于诊断）与界面设置。
    func resetForAccountDeletion() {
        defaults.removeObject(forKey: Key.cursor)
        defaults.removeObject(forKey: Key.lastSyncAt)
        defaults.removeObject(forKey: Key.userID)
        defaults.removeObject(forKey: Key.reloginRequired)
        defaults.removeObject(forKey: Key.lastBackgroundPushAt)
    }
}
