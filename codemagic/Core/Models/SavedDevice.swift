import Foundation

/// 已保存的蓝牙设备。
/// `id` 为客户端生成的 UUID，作为同步主键；`peripheralID` 为本机 CoreBluetooth 标识符。
struct SavedDevice: Identifiable, Equatable {
    let id: UUID
    let peripheralID: UUID
    var name: String
    var remark: String
    var groupName: String
    var mac: String?
    var vendor: String?
    var firmwareVersion: String?
    var lastSeenAt: Date?
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var syncState: SyncState

    static let defaultGroupName = "未分组"

    init(
        id: UUID = UUID(),
        peripheralID: UUID,
        name: String,
        remark: String = "",
        groupName: String = SavedDevice.defaultGroupName,
        mac: String? = nil,
        vendor: String? = nil,
        firmwareVersion: String? = nil,
        lastSeenAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        syncState: SyncState = .pending
    ) {
        self.id = id
        self.peripheralID = peripheralID
        self.name = name
        self.remark = remark
        self.groupName = groupName.isEmpty ? SavedDevice.defaultGroupName : groupName
        self.mac = mac
        self.vendor = vendor
        self.firmwareVersion = firmwareVersion
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncState = syncState
    }

    /// 列表展示名：优先备注名，其次广播名。
    var displayName: String {
        let trimmed = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }
}
