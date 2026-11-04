import Foundation

/// 基础设置，使用 UserDefaults 保存。仅存开关类偏好，不涉及同步数据。
final class SettingsStore {
    private enum Key {
        static let autoSaveRecentDevices = "settings.autoSaveRecentDevices"
        static let autoScanOnLaunch = "settings.autoScanOnLaunch"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 是否把扫描结果写入最近设备列表，默认开启。
    var autoSaveRecentDevices: Bool {
        get { defaults.object(forKey: Key.autoSaveRecentDevices) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoSaveRecentDevices) }
    }

    /// 是否在进入首页时自动开始扫描，默认关闭（真机上更省电）。
    var autoScanOnLaunch: Bool {
        get { defaults.object(forKey: Key.autoScanOnLaunch) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.autoScanOnLaunch) }
    }
}
