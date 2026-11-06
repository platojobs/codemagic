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
    /// 仅存在本机、不参与云端同步（例如旧版本留下的手动场景）。
    case localOnly
    /// 服务端明确拒绝（`SCENE_*` 4xx）：终态，不自动重试，用户编辑后才回到 `pending`。
    case rejected

    var title: String {
        switch self {
        case .pending: return L10n.t("sync.state.pending")
        case .synced: return L10n.t("sync.state.synced")
        case .pendingDelete: return L10n.t("sync.state.pendingDelete")
        case .localOnly: return L10n.t("sync.state.localOnly")
        case .rejected: return L10n.t("sync.state.rejected")
        }
    }
}
