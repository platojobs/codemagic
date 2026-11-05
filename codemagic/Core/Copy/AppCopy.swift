import Foundation

/// 高频用户文案集中定义，便于术语审计与单测。
/// 术语口径见设计规范第 7 节：设备 / 读数 / 同步 / 告警（不用装置、上传、数值）。
enum AppCopy {
    enum Onboarding {
        static let stepCount = 3

        static let bluetoothTitle = "为什么需要蓝牙"
        static let bluetoothMessage = "用于扫描附近的设备、建立连接并读取读数。拒绝后仅本机可用，无法发现新设备。"
        static let bluetoothFootnote = "系统授权框只在你点「继续」后出现，可随时在系统设置关闭。"

        static let notificationTitle = "为什么需要通知"
        static let notificationMessage = "阈值告警由本机生成通知，提醒你设备读数越界；不用于营销，也不含广告。"
        static let notificationFootnote = "不开启通知时，规则触发仍会记录在「智能」页的触发历史中。"

        static let backgroundTitle = "后台只在已连接时继续"
        static let backgroundMessage = "iOS 的 bluetooth-central 仅在设备保持连接时允许后台接收读数；系统可能延后唤醒，断开后不再采集。"
        static let backgroundFootnote = "可随时在「我的」关闭后台采集，关闭后进入后台会断开连接。"

        static let skip = "跳过"
        static let next = "继续"
        static let finish = "开始使用"
    }

    enum Permission {
        static let localOnlyTitle = "仅本机可用"
        static let localOnlyMessage = "蓝牙权限已关闭，无法扫描新设备；已保存设备与历史读数仍可查看。"
        static let openSettings = "去系统设置"

        static let notificationOffMessage = "通知未开启，阈值告警仍会记录在「智能」页，可在系统设置开启通知。"
        static let notificationOffAction = "去系统设置"
    }

    enum Home {
        static let emptyTitle = "还没有设备"
        static let emptyMessage = "扫描附近的设备，添加后可查看读数、历史曲线与规则。"
        static let emptyAction = "开始扫描"
        static let scanAction = "扫描附近设备"
        static let filteredTitle = "没有匹配的设备"
        static let filteredMessage = "试试修改搜索词或切换分组。"
        static let filteredAction = "清除筛选"
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
