import Foundation

/// 已保存的蓝牙设备。
/// `id` 为客户端生成的 UUID，作为同步主键；`peripheralID` 为本机 CoreBluetooth 标识符。
/// 服务端设备唯一键为 `(platform, externalId)`，iOS 的 `externalId` 为
/// `CBPeripheral.identifier`（UUID 大写），`mac` 可为空。
struct SavedDevice: Identifiable, Equatable {
    let id: UUID
    let peripheralID: UUID
    var platform: String
    var externalID: String
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
    /// iOS 端固定平台标识，与后端 `platform` 枚举一致。
    static let iosPlatform = "ios"

    init(
        id: UUID = UUID(),
        peripheralID: UUID,
        platform: String = SavedDevice.iosPlatform,
        externalID: String? = nil,
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
        self.platform = platform.isEmpty ? SavedDevice.iosPlatform : platform
        let trimmedExternalID = externalID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.externalID = trimmedExternalID.isEmpty
            ? peripheralID.uuidString.uppercased()
            : trimmedExternalID.uppercased()
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

    /// 服务端唯一键的本地拼写，仅用于日志与断言。
    var syncKey: String { "\(platform):\(externalID)" }

    /// 同步别名：优先备注名，其次广播名，长度受后端限制（100）。
    var syncAlias: String {
        String(displayName.prefix(100))
    }

    /// 列表展示名：优先备注名，其次广播名。
    var displayName: String {
        let trimmed = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }
}
