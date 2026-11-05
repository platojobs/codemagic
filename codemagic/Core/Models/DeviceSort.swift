import Foundation

/// 设备列表排序方式；默认「最近出现」并持久化到 `SettingsStore`。
enum DeviceSort: String, CaseIterable, Equatable {
    case recent
    case name
    case signal
    case addedAt

    var title: String {
        switch self {
        case .recent: return L10n.t("sort.lastSeen")
        case .name: return L10n.t("sort.name")
        case .signal: return L10n.t("sort.rssi")
        case .addedAt: return L10n.t("sort.addedAt")
        }
    }
}
