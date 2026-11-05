import Foundation

/// 高频用户文案集中定义，便于术语审计与单测。
/// 术语口径见设计规范第 7 节：设备 / 读数 / 同步 / 告警（不用装置、上传、数值）。
enum AppCopy {
    enum Onboarding {
        static let stepCount = 3

        static let bluetoothTitle = L10n.t("onboarding.bluetooth.title")
        static let bluetoothMessage = L10n.t("onboarding.bluetooth.message")
        static let bluetoothFootnote = L10n.t("onboarding.bluetooth.footnote")

        static let notificationTitle = L10n.t("onboarding.notification.title")
        static let notificationMessage = L10n.t("onboarding.notification.message")
        static let notificationFootnote = L10n.t("onboarding.notification.footnote")

        static let backgroundTitle = L10n.t("onboarding.background.title")
        static let backgroundMessage = L10n.t("onboarding.background.message")
        static let backgroundFootnote = L10n.t("onboarding.background.footnote")

        static let skip = L10n.t("onboarding.action.skip")
        static let next = L10n.t("onboarding.action.continue")
        static let finish = L10n.t("onboarding.action.start")
    }

    enum Permission {
        static let localOnlyTitle = L10n.t("permission.localOnly.title")
        static let localOnlyMessage = L10n.t("permission.localOnly.message")
        static let openSettings = L10n.t("permission.openSettings")

        static let notificationOffMessage = L10n.t("permission.notificationOff.message")
        static let notificationOffAction = L10n.t("permission.openSettings")
    }

    enum Home {
        static let emptyTitle = L10n.t("home.empty.title")
        static let emptyMessage = L10n.t("home.empty.message")
        static let emptyAction = L10n.t("home.empty.action")
        static let scanAction = L10n.t("home.scan.action")
        static let filteredTitle = L10n.t("home.filtered.title")
        static let filteredMessage = L10n.t("home.filtered.message")
        static let filteredAction = L10n.t("home.filtered.action")
    }

    /// 术语审计与禁用词测试覆盖的高频字符串。
    static let highFrequencyStrings: [String] = [
        Onboarding.bluetoothTitle,
        Onboarding.bluetoothMessage,
        Onboarding.notificationTitle,
        Onboarding.notificationMessage,
        Onboarding.backgroundTitle,
        Onboarding.backgroundMessage,
        Permission.localOnlyTitle,
        Permission.localOnlyMessage,
        Permission.notificationOffMessage,
        Home.emptyTitle,
        Home.emptyMessage,
        Home.emptyAction,
        Home.filteredMessage,
    ]
}
