import Foundation

/// 基础设置，使用 UserDefaults 保存。仅存开关类偏好，不涉及同步数据。
final class SettingsStore {
    private enum Key {
        static let autoSaveRecentDevices = "settings.autoSaveRecentDevices"
        static let autoScanOnLaunch = "settings.autoScanOnLaunch"
        static let ruleAlertsEnabled = "settings.ruleAlertsEnabled"
        static let ruleAlertThrottleMinutes = "settings.ruleAlertThrottleMinutes"
        static let appearance = "settings.appearance"
        static let deviceSort = "settings.deviceSort"
    }

    /// 告警节流窗口可选项，与「我的」页一致。
    static let ruleAlertThrottleOptions = [1, 5, 30]

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

    /// 阈值告警是否发送本地通知，默认开启；首次真正需要通知时才会请求系统授权。
    var ruleAlertsEnabled: Bool {
        get { defaults.object(forKey: Key.ruleAlertsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.ruleAlertsEnabled) }
    }

    /// 同一设备同一规则的通知节流窗口（分钟），仅允许 1 / 5 / 30，默认 5。
    var ruleAlertThrottleMinutes: Int {
        get {
            let stored = defaults.object(forKey: Key.ruleAlertThrottleMinutes) as? Int
            guard let stored, Self.ruleAlertThrottleOptions.contains(stored) else { return 5 }
            return stored
        }
        set {
            let normalized = Self.ruleAlertThrottleOptions.contains(newValue) ? newValue : 5
            defaults.set(normalized, forKey: Key.ruleAlertThrottleMinutes)
        }
    }

    var ruleAlertThrottleInterval: TimeInterval {
        TimeInterval(ruleAlertThrottleMinutes) * 60
    }

    /// 外观偏好，默认跟随系统。
    var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// 设备列表排序偏好，默认最近出现。
    var deviceSort: DeviceSort {
        get { DeviceSort(rawValue: defaults.string(forKey: Key.deviceSort) ?? "") ?? .recent }
        set { defaults.set(newValue.rawValue, forKey: Key.deviceSort) }
    }
}
