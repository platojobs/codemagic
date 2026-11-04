import Foundation

/// 同步游标、上次同步时间与客户端标识。
/// 这些不是敏感凭据，存 UserDefaults；token 由 `TokenStoring` 单独放 Keychain。
final class SyncMetadataStore {
    private enum Key {
        static let cursor = "sync.cursor"
        static let lastSyncAt = "sync.lastSyncAt"
        static let userID = "sync.userId"
        static let clientID = "sync.clientId"
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
}
