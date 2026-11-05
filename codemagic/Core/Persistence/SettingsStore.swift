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
        static let backgroundCollection = "settings.backgroundCollection"
        static let ruleAlertsMutedUntil = "settings.ruleAlertsMutedUntil"
        static let onboardingCompleted = "settings.onboardingCompleted"
        static let onboardingStep = "settings.onboardingStep"
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

    /// 后台采集：开启时利用 `bluetooth-central` 在后台保持连接并接收 notify；
    /// 关闭时进入后台立即断开连接。默认开启，需在界面明确告知耗电影响。
    var backgroundCollectionEnabled: Bool {
        get { defaults.object(forKey: Key.backgroundCollection) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.backgroundCollection) }
    }

    /// 首启引导是否已走完（或已跳过）。true 时不再出现。
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    /// 首启引导停留的步骤（0 起）。中途退出下次从该步继续。
    var onboardingStep: Int {
        get {
            let stored = defaults.object(forKey: Key.onboardingStep) as? Int ?? 0
            return min(max(stored, 0), AppCopy.Onboarding.stepCount - 1)
        }
        set {
            defaults.set(min(max(newValue, 0), AppCopy.Onboarding.stepCount - 1), forKey: Key.onboardingStep)
        }
    }

    /// 走完或跳过引导：持久化完成标记并重置步骤。
    func completeOnboarding() {
        onboardingCompleted = true
        onboardingStep = 0
    }

    /// 告警静音截止时间；由场景动作写入，重启后继续生效。
    var ruleAlertsMutedUntil: Date? {
        get {
            let value = defaults.double(forKey: Key.ruleAlertsMutedUntil)
            guard value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.ruleAlertsMutedUntil)
            } else {
                defaults.removeObject(forKey: Key.ruleAlertsMutedUntil)
            }
        }
    }

    func isRuleAlertsMuted(at date: Date = Date()) -> Bool {
        guard let until = ruleAlertsMutedUntil else { return false }
        return until > date
    }

    func remainingMuteMinutes(at date: Date = Date()) -> Int {
        guard let until = ruleAlertsMutedUntil, until > date else { return 0 }
        return max(1, Int(ceil(until.timeIntervalSince(date) / 60)))
    }

    /// 「我的」页展示的后台采集状态说明。
    func backgroundCollectionStatusText(connectedCount: Int = 0) -> String {
        if backgroundCollectionEnabled {
            let connection = connectedCount > 0 ? L10n.f("settings.background.connected", String(describing: connectedCount)) : L10n.t("settings.background.none")
            return L10n.f("settings.background.on", String(describing: connection))
        }
        return L10n.t("settings.background.off")
    }
}
