import Foundation

/// 设备列表排序方式；默认「最近出现」并持久化到 `SettingsStore`。
enum DeviceSort: String, CaseIterable, Equatable {
    case recent
    case name
    case signal
    case addedAt

    var title: String {
        switch self {
        case .recent: return "最近出现"
        case .name: return "名称"
        case .signal: return "信号强度"
        case .addedAt: return "添加时间"
        }
    }
}
