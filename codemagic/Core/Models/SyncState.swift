import Foundation

/// 本地记录的同步状态，所有业务表共用。
/// 目前只做本地落库，后续接入云端同步时按此字段筛选待上传数据。
enum SyncState: String, Codable, CaseIterable {
    /// 只在本地修改过，尚未同步。
    case pending
    /// 已与云端一致。
    case synced
    /// 本地删除，等待同步删除操作。
    case pendingDelete

    var title: String {
        switch self {
        case .pending: return L10n.t("sync.state.pending")
        case .synced: return L10n.t("sync.state.synced")
        case .pendingDelete: return L10n.t("sync.state.pendingDelete")
        }
    }
}
