import UIKit

/// 外观三态：跟随系统 / 浅色 / 深色。持久化在 `SettingsStore`，启动与切换时应用到窗口。
enum AppAppearance: String, CaseIterable, Equatable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// 应用到当前所有窗口；图表与卡片使用语义色，切换后立即重绘。
    @MainActor
    static func apply(_ appearance: AppAppearance) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = appearance.userInterfaceStyle
            }
        }
    }

    @MainActor
    static func apply(_ appearance: AppAppearance, to window: UIWindow?) {
        window?.overrideUserInterfaceStyle = appearance.userInterfaceStyle
    }
}
