import CryptoKit
import Foundation

/// 匿名登录返回的会话；`token` 只存 Keychain，不落 UserDefaults。
struct AnonymousSession: Equatable {
    let userID: String
    let token: String
}

/// RFC 3339 时间解析 / 序列化。服务端可能带或不带毫秒，解析两者都接受。
enum SyncDateCodec {
    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum SyncHashing {
    /// 由任意种子派生稳定 UUID（SHA-256 前 32 位），用于无本地主键的远端设备。
    static func stableUUID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        // 版本位与变体位按 UUID v4 规则填充，保证是合法 UUID。
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// 幂等键：同一批（排序后）设备内容总是得到同一个 UUID；内容变化则键随之变化。
    /// 这样重试网络失败时服务端可命中幂等缓存，而不会因请求体不同触发 409。
    static func idempotencyKey(for devices: [PushDevice]) -> String {
        let signature = devices
            .map {
                [
                    $0.id,
                    $0.platform,
                    $0.externalID,
                    String(Int64($0.updatedAt.timeIntervalSince1970 * 1000)),
                    $0.deleted ? "1" : "0",
                ].joined(separator: "|")
            }
            .sorted()
            .joined(separator: ";")
        return stableUUID(seed: "push:\(signature)").uuidString
    }
}

// MARK: - 服务端模型（对未知字段与缺失字段容错）

/// `GET /sync/changes` 中的 `payload` 与 `POST /sync/push` 冲突里的 `server`。
struct RemoteDevice: Decodable, Equatable {
    let id: String
    let clientID: String
    let platform: String
    let externalID: String
    let mac: String?
    let alias: String
    let group: String
    let updatedAt: Date
    let deletedAt: Date?
    let serverSeq: Int64?

    private enum CodingKeys: String, CodingKey {
        case id
        case clientId
        case platform
        case externalId
        case mac
        case alias
        case group
        case updatedAt
        case deletedAt
        case serverSeq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        clientID = (try? container.decodeIfPresent(String.self, forKey: .clientId)) ?? ""
        platform = (try? container.decodeIfPresent(String.self, forKey: .platform)) ?? SavedDevice.iosPlatform
        externalID = ((try? container.decodeIfPresent(String.self, forKey: .externalId)) ?? "").uppercased()
        mac = try? container.decodeIfPresent(String.self, forKey: .mac)
        alias = (try? container.decodeIfPresent(String.self, forKey: .alias)) ?? ""
        group = (try? container.decodeIfPresent(String.self, forKey: .group)) ?? ""
        updatedAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        ) ?? Date(timeIntervalSince1970: 0)
        deletedAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .deletedAt)) ?? ""
        )
        serverSeq = try? container.decodeIfPresent(Int64.self, forKey: .serverSeq)
    }

    /// 视图层测试与冲突展示用。
    init(
        id: String,
        clientID: String = "",
        platform: String = SavedDevice.iosPlatform,
        externalID: String,
        mac: String? = nil,
        alias: String = "",
        group: String = "",
        updatedAt: Date,
        deletedAt: Date? = nil,
        serverSeq: Int64? = nil
    ) {
        self.id = id
        self.clientID = clientID
        self.platform = platform
        self.externalID = externalID.uppercased()
        self.mac = mac
        self.alias = alias
        self.group = group
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.serverSeq = serverSeq
    }

    /// 远端记录映射为本地行；远端没有广播名，`alias` 即展示名。
    func makeLocalDevice() -> SavedDevice {
        let remoteID = UUID(uuidString: id) ?? SyncHashing.stableUUID(seed: "device:\(platform):\(externalID)")
        let peripheralID: UUID
        if platform == SavedDevice.iosPlatform, let uuid = UUID(uuidString: externalID) {
            peripheralID = uuid
        } else {
            peripheralID = remoteID
        }
        let displayName = alias.isEmpty ? "未命名设备" : alias
        return SavedDevice(
            id: remoteID,
            peripheralID: peripheralID,
            platform: platform,
            externalID: externalID,
            name: displayName,
            remark: "",
            groupName: group.isEmpty ? SavedDevice.defaultGroupName : group,
            mac: (mac?.isEmpty ?? true) ? nil : mac,
            vendor: nil,
            firmwareVersion: nil,
            lastSeenAt: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            syncState: .synced
        )
    }
}

struct SyncChange: Decodable, Equatable {
    let seq: Int64
    let entity: String
    let entityID: String
    let op: String
    let payload: RemoteDevice
    let serverTimestamp: Date?

    private enum CodingKeys: String, CodingKey {
        case seq
        case entity
        case entityId
        case op
        case payload
        case serverTs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = (try? container.decodeIfPresent(Int64.self, forKey: .seq)) ?? 0
        entity = (try? container.decodeIfPresent(String.self, forKey: .entity)) ?? ""
        entityID = (try? container.decodeIfPresent(String.self, forKey: .entityId)) ?? ""
        op = (try? container.decodeIfPresent(String.self, forKey: .op)) ?? "upsert"
        payload = (try? container.decode(RemoteDevice.self, forKey: .payload))
            ?? RemoteDevice(id: "", externalID: "", updatedAt: Date(timeIntervalSince1970: 0))
        serverTimestamp = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .serverTs)) ?? ""
        )
    }

    var isDeletion: Bool { op == "delete" || payload.deletedAt != nil }
}

struct SyncChangesPage: Decodable, Equatable {
    let changes: [SyncChange]
    let nextCursor: Int64
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case changes
        case nextCursor
        case hasMore
    }

    init(changes: [SyncChange] = [], nextCursor: Int64 = 0, hasMore: Bool = false) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changes = (try? container.decodeIfPresent([SyncChange].self, forKey: .changes)) ?? []
        nextCursor = (try? container.decodeIfPresent(Int64.self, forKey: .nextCursor)) ?? 0
        hasMore = (try? container.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
    }
}

/// 推送条目，字段与 `PushDevice` 对齐；`rules` / `scanRecords` 本期不同步。
struct PushDevice: Encodable, Equatable {
    let id: String
    let platform: String
    let externalID: String
    let mac: String?
    let alias: String
    let group: String
    let updatedAt: Date
    let deleted: Bool
    /// openapi 0.3.2 可选字段；未知型号时为 nil，不填假值。
    let deviceType: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case platform
        case externalId
        case mac
        case alias
        case group
        case updatedAt
        case deleted
        case deviceType
    }

    init(
        id: String,
        platform: String,
        externalID: String,
        mac: String?,
        alias: String,
        group: String,
        updatedAt: Date,
        deleted: Bool,
        deviceType: String? = nil
    ) {
        self.id = id
        self.platform = platform
        self.externalID = externalID
        self.mac = mac
        self.alias = alias
        self.group = group
        self.updatedAt = updatedAt
        self.deleted = deleted
        let trimmed = deviceType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.deviceType = trimmed.isEmpty ? nil : trimmed
    }

    init(device: SavedDevice) {
        self.init(
            id: device.id.uuidString,
            platform: device.platform,
            externalID: device.externalID,
            mac: device.mac,
            alias: device.syncAlias,
            group: device.groupName,
            updatedAt: device.updatedAt,
            deleted: device.deletedAt != nil,
            deviceType: device.deviceType
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(platform, forKey: .platform)
        try container.encode(externalID, forKey: .externalId)
        try container.encodeIfPresent(mac, forKey: .mac)
        try container.encode(alias, forKey: .alias)
        try container.encode(group, forKey: .group)
        try container.encode(SyncDateCodec.string(from: updatedAt), forKey: .updatedAt)
        try container.encode(deleted, forKey: .deleted)
        try container.encodeIfPresent(deviceType, forKey: .deviceType)
    }
}

struct PushRequest: Encodable {
    let clientID: String
    let devices: [PushDevice]

    private enum CodingKeys: String, CodingKey {
        case clientId
        case devices
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientID, forKey: .clientId)
        try container.encode(devices, forKey: .devices)
    }
}

struct AppliedChange: Decodable, Equatable {
    let id: String
    let platform: String
    let externalID: String
    let status: String
    let serverSeq: Int64

    private enum CodingKeys: String, CodingKey {
        case id
        case platform
        case externalId
        case status
        case serverSeq
    }

    init(id: String, platform: String = SavedDevice.iosPlatform, externalID: String, status: String = "applied", serverSeq: Int64 = 0) {
        self.id = id
        self.platform = platform
        self.externalID = externalID.uppercased()
        self.status = status
        self.serverSeq = serverSeq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        platform = (try? container.decodeIfPresent(String.self, forKey: .platform)) ?? SavedDevice.iosPlatform
        externalID = ((try? container.decodeIfPresent(String.self, forKey: .externalId)) ?? "").uppercased()
        status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? ""
        serverSeq = (try? container.decodeIfPresent(Int64.self, forKey: .serverSeq)) ?? 0
    }
}

struct SyncConflict: Decodable, Equatable {
    let id: String
    let platform: String
    let externalID: String
    let mac: String?
    let reason: String
    let server: RemoteDevice

    private enum CodingKeys: String, CodingKey {
        case id
        case platform
        case externalId
        case mac
        case reason
        case server
    }

    init(id: String, platform: String = SavedDevice.iosPlatform, externalID: String, mac: String? = nil, reason: String = "server_newer", server: RemoteDevice) {
        self.id = id
        self.platform = platform
        self.externalID = externalID.uppercased()
        self.mac = mac
        self.reason = reason
        self.server = server
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        platform = (try? container.decodeIfPresent(String.self, forKey: .platform)) ?? SavedDevice.iosPlatform
        externalID = ((try? container.decodeIfPresent(String.self, forKey: .externalId)) ?? "").uppercased()
        mac = try? container.decodeIfPresent(String.self, forKey: .mac)
        reason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? "server_newer"
        server = (try? container.decode(RemoteDevice.self, forKey: .server))
            ?? RemoteDevice(id: id, externalID: externalID, updatedAt: Date(timeIntervalSince1970: 0))
    }

    var reasonText: String {
        switch reason {
        case "server_newer": return "云端版本更新"
        case "clock_clamped": return "本地时间超前，已按服务端时间纠正"
        case "key_taken": return "设备唯一键已被占用"
        default: return reason
        }
    }
}

struct PushResult: Decodable, Equatable {
    let applied: [AppliedChange]
    let conflicts: [SyncConflict]
    let nextCursor: Int64
    /// 命中服务端幂等缓存时 `Idempotent-Replayed: true`。
    let isIdempotentReplay: Bool

    private enum CodingKeys: String, CodingKey {
        case applied
        case conflicts
        case nextCursor
    }

    init(applied: [AppliedChange] = [], conflicts: [SyncConflict] = [], nextCursor: Int64 = 0, isIdempotentReplay: Bool = false) {
        self.applied = applied
        self.conflicts = conflicts
        self.nextCursor = nextCursor
        self.isIdempotentReplay = isIdempotentReplay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applied = (try? container.decodeIfPresent([AppliedChange].self, forKey: .applied)) ?? []
        conflicts = (try? container.decodeIfPresent([SyncConflict].self, forKey: .conflicts)) ?? []
        nextCursor = (try? container.decodeIfPresent(Int64.self, forKey: .nextCursor)) ?? 0
        isIdempotentReplay = false
    }

    func withIdempotentReplay(_ flag: Bool) -> PushResult {
        PushResult(applied: applied, conflicts: conflicts, nextCursor: nextCursor, isIdempotentReplay: flag)
    }
}

/// `GET /device-types/{type}`：iOS 无法拿到 MAC 时按型号查询元数据。
/// openapi 0.3.2 增加 `compatibility`（可为 null）。
struct DeviceTypeInfo: Decodable, Equatable {
    let type: String
    let name: String
    let vendor: String
    let descriptionText: String
    let gattServices: [GATTService]
    let compatibility: CompatibilityInfo?

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case vendor
        case description
        case gattServices
        case compatibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? ""
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        vendor = (try? container.decodeIfPresent(String.self, forKey: .vendor)) ?? ""
        descriptionText = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
        gattServices = (try? container.decodeIfPresent([GATTService].self, forKey: .gattServices)) ?? []
        compatibility = try? container.decodeIfPresent(CompatibilityInfo.self, forKey: .compatibility)
    }

    init(
        type: String,
        name: String,
        vendor: String,
        descriptionText: String,
        gattServices: [GATTService],
        compatibility: CompatibilityInfo? = nil
    ) {
        self.type = type
        self.name = name
        self.vendor = vendor
        self.descriptionText = descriptionText
        self.gattServices = gattServices
        self.compatibility = compatibility
    }
}
