import Foundation

/// 本地扫描日志分类。
enum ScanLogCategory: String, Codable, CaseIterable {
    case session
    case device
    case rule
    case sync

    var title: String {
        switch self {
        case .session: return "扫描"
        case .device: return "设备"
        case .rule: return "规则"
        case .sync: return "同步"
        }
    }
}

enum ScanLogLevel: String, Codable {
    case info
    case warning
}

/// 一条本地扫描日志，参与同步字段与业务表一致。
struct ScanLogEntry: Identifiable, Equatable {
    let id: UUID
    let occurredAt: Date
    let category: ScanLogCategory
    let level: ScanLogLevel
    let message: String
    var updatedAt: Date
    var deletedAt: Date?
    var syncState: SyncState

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        category: ScanLogCategory,
        level: ScanLogLevel = .info,
        message: String,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        syncState: SyncState = .pending
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.category = category
        self.level = level
        self.message = message
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncState = syncState
    }
}
