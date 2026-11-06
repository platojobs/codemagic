import CryptoKit
import Foundation

/// 匿名登录 / 接管返回的会话；`token` 只存 Keychain，不落 UserDefaults。
///
/// `expiresAt` 是服务端签发的 token 到期时间（默认 180 天），仅用于只读展示；
/// 旧后端不返回该字段时为 nil，不臆造日期。
struct AnonymousSession: Equatable {
    let userID: String
    let token: String
    let expiresAt: Date?

    init(userID: String, token: String, expiresAt: Date? = nil) {
        self.userID = userID
        self.token = token
        self.expiresAt = expiresAt
    }
}

/// RFC3339 编解码：保留**微秒**精度（6 位小数），兼容服务端带或不带小数。
///
/// `ISO8601DateFormatter` / `DateFormatter` 的分数秒只保留毫秒，服务端按微秒做字段级 LWW，
/// 因此这里手动拆分小数部分：解析时把 1–6 位小数换算为微秒后再加到整秒；
/// 序列化时按微秒四舍五入并固定输出 6 位，保证 `2026-11-05T08:09:10.123456Z` 完整往返。
enum SyncDateCodec {
    private static let baseFormatters: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [plain]
    }()

    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 仅在小数点后、时区标识之前读取数字；时区前的 '-'（如 2026-11-05）不参与拆分。
        var baseText = trimmed
        var fractionMicros = 0.0
        if let dot = trimmed.firstIndex(of: ".") {
            let afterDot = trimmed[trimmed.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            let rest = afterDot.dropFirst(digits.count)
            if !digits.isEmpty {
                let padded = digits.prefix(6) + String(repeating: "0", count: max(0, 6 - digits.count))
                fractionMicros = Double(Int(padded) ?? 0) / 1_000_000
                baseText = String(trimmed[..<dot]) + String(rest)
            }
        }

        for formatter in baseFormatters {
            if let base = formatter.date(from: baseText) {
                return base.addingTimeInterval(fractionMicros)
            }
        }
        return nil
    }

    static func string(from date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var wholeSeconds = interval.rounded(.down)
        var micros = Int(((interval - wholeSeconds) * 1_000_000).rounded())
        if micros >= 1_000_000 {
            micros -= 1_000_000
            wholeSeconds += 1
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let base = formatter.string(from: Date(timeIntervalSince1970: wholeSeconds))
        return base + String(format: ".%06dZ", micros)
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

    /// 幂等键：同一批（排序后）设备与读数内容总是得到同一个 UUID；内容变化则键随之变化。
    /// 这样重试网络失败时服务端可命中幂等缓存，而不会因请求体不同触发 409。
    ///
    /// 签名直接取各条目规范化编码后的 JSON（键排序）：
    /// - 未上报（`Patch.absent`）的字段根本不会出现在 JSON 里，因此不参与哈希；
    /// - 显式清除编码为 `""`，与「从未设置」区分开；
    /// - 读数按 `id` 幂等，同样需要参与签名，否则读数的重试会与设备内容撞键。
    static func idempotencyKey(for devices: [PushDevice], readings: [PushReading] = []) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let deviceSignature = devices
            .compactMap { try? encoder.encode($0) }
            .map { String(data: $0, encoding: .utf8) ?? "" }
            .sorted()
            .joined(separator: ";")
        let readingSignature = readings
            .compactMap { try? encoder.encode($0) }
            .map { String(data: $0, encoding: .utf8) ?? "" }
            .sorted()
            .joined(separator: ";")
        return stableUUID(seed: "push:devices:\(deviceSignature);readings:\(readingSignature)").uuidString
    }
}

// MARK: - 服务端模型（对未知字段与缺失字段容错）

/// `GET /sync/changes` 中的 `payload` 与 `POST /sync/push` 冲突里的 `server`。
///
/// openapi 0.3.3 起 `alias` / `advertisedName` / `group` 在部分响应（如冲突）中可以缺省，
/// 因此三个字段均为可选：`nil` 表示 absent（未上报），合并时必须保留本地原值；
/// 空串表示服务端已显式清除。
struct RemoteDevice: Decodable, Equatable {
    let id: String
    let clientID: String
    let platform: String
    let externalID: String
    let mac: String?
    let alias: String?
    let advertisedName: String?
    let group: String?
    /// 服务端家庭 id（openapi 0.8.0）。旧后端缺省时保持本地归属不变。
    let householdID: String?
    /// 服务端房间 id；`nil` 表示未分配。
    let roomID: String?
    /// 响应里是否真的出现了 `roomId` 键：缺省（旧后端）与显式 `null` 语义不同。
    let hasRoomField: Bool
    /// 设备标记（契约 0.20.0）：字段缺省=保持原值；`null`/`""`=取消标记；时间=标记。
    let markedAt: Patch<Date>
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
        case advertisedName
        case group
        case householdId
        case roomId
        case markedAt
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
        alias = try? container.decodeIfPresent(String.self, forKey: .alias)
        advertisedName = try? container.decodeIfPresent(String.self, forKey: .advertisedName)
        group = try? container.decodeIfPresent(String.self, forKey: .group)
        householdID = try? container.decodeIfPresent(String.self, forKey: .householdId)
        roomID = try? container.decodeIfPresent(String.self, forKey: .roomId)
        hasRoomField = container.contains(.roomId)
        // 三态：键缺省=保持本地原值；null 或 ""=取消标记；合法 RFC3339=标记。
        if container.contains(.markedAt) {
            let raw = (try? container.decodeIfPresent(String.self, forKey: .markedAt)) ?? nil
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                markedAt = .clear
            } else if let date = SyncDateCodec.parse(text) {
                markedAt = .set(date)
            } else {
                // 非法值不臆造日期，也不当作取消标记，按未上报处理。
                markedAt = .absent
            }
        } else {
            markedAt = .absent
        }
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
        alias: String? = nil,
        advertisedName: String? = nil,
        group: String? = nil,
        householdID: String? = nil,
        roomID: String? = nil,
        hasRoomField: Bool = true,
        markedAt: Patch<Date> = .absent,
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
        self.advertisedName = advertisedName
        self.group = group
        self.householdID = householdID
        self.roomID = roomID
        self.hasRoomField = hasRoomField
        self.markedAt = markedAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.serverSeq = serverSeq
    }

    /// 展示名：别名 → 广播名；都缺省时为空串，由调用方决定兜底文案。
    var displayName: String {
        let aliasText = (alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !aliasText.isEmpty { return aliasText }
        return (advertisedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 远端记录映射为本地行；缺省字段按 absent 处理（本地保持默认值）。
    func makeLocalDevice() -> SavedDevice {
        let remoteID = UUID(uuidString: id) ?? SyncHashing.stableUUID(seed: "device:\(platform):\(externalID)")
        let peripheralID: UUID
        if platform == SavedDevice.iosPlatform, let uuid = UUID(uuidString: externalID) {
            peripheralID = uuid
        } else {
            peripheralID = remoteID
        }
        let aliasText = alias ?? ""
        let advertisedText = advertisedName ?? ""
        let groupText = group ?? ""
        let markedDate: Date?
        if case .set(let date) = markedAt {
            markedDate = date
        } else {
            markedDate = nil
        }
        return SavedDevice(
            id: remoteID,
            peripheralID: peripheralID,
            platform: platform,
            externalID: externalID,
            advertisedName: advertisedText,
            remark: aliasText,
            groupName: groupText.isEmpty ? SavedDevice.defaultGroupName : groupText,
            remoteRoomID: roomID,
            remoteHouseholdID: householdID,
            mac: (mac?.isEmpty ?? true) ? nil : mac,
            vendor: nil,
            firmwareVersion: nil,
            lastSeenAt: nil,
            markedAt: markedDate,
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
    /// 设备实体 payload；非设备实体会解出空对象（不使用）。
    let payload: RemoteDevice
    /// `household` 实体的结构变更 payload（后端 v0.15.0 起）。
    let householdChange: HouseholdChangePayload?
    /// `room` 实体的结构变更 payload（后端 v0.15.0 起）。
    let roomChange: RoomChangePayload?
    /// `scene` 实体的完整快照（后端 v0.20.0 / 契约 0.16.0 起）。
    let sceneChange: RemoteScene?
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
        householdChange = try? container.decode(HouseholdChangePayload.self, forKey: .payload)
        roomChange = try? container.decode(RoomChangePayload.self, forKey: .payload)
        sceneChange = try? container.decode(RemoteScene.self, forKey: .payload)
        serverTimestamp = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .serverTs)) ?? ""
        )
    }

    init(
        seq: Int64,
        entity: String,
        entityID: String,
        op: String,
        payload: RemoteDevice,
        householdChange: HouseholdChangePayload? = nil,
        roomChange: RoomChangePayload? = nil,
        sceneChange: RemoteScene? = nil,
        serverTimestamp: Date? = nil
    ) {
        self.seq = seq
        self.entity = entity
        self.entityID = entityID
        self.op = op
        self.payload = payload
        self.householdChange = householdChange
        self.roomChange = roomChange
        self.sceneChange = sceneChange
        self.serverTimestamp = serverTimestamp
    }

    var isDeletion: Bool {
        op == "delete"
            || payload.deletedAt != nil
            || householdChange?.deleted == true
            || roomChange?.deleted == true
            || sceneChange?.deletedAt != nil
    }

    var isDeviceEntity: Bool {
        entity == SyncEntity.device || entity == SyncEntity.legacyDevice
    }
}

/// `change_log` 的实体名。未知实体必须跳过且照常推进游标。
enum SyncEntity {
    static let device = "user_device"
    /// 既有测试 / 旧客户端的实体名。
    static let legacyDevice = "device"
    static let household = "household"
    static let room = "room"
    static let scene = "scene"
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

/// 推送条目，字段与 openapi 0.3.3 的 `PushDevice` 对齐；`rules` / `scanRecords` 本期不同步。
///
/// `alias` / `advertisedName` / `group` 使用 `Patch<String>` 表达三态：
/// `absent` 时完全省略字段（服务端保持原值），`clear` 编码为 `""`（显式清除），
/// `set` 编码具体值。`nil` 与空串因此不会混淆。
/// `markedAt`（契约 0.20.0）用 `Patch<Date>`：缺省省略，取消标记编码 JSON `null`，
/// 标记编码 RFC3339 时间；与 `alias` 等字段共用设备级 `updatedAt` 的 LWW 通道。
struct PushDevice: Encodable, Equatable {
    let id: String
    let platform: String
    let externalID: String
    let mac: String?
    let alias: Patch<String>
    let advertisedName: Patch<String>
    let group: Patch<String>
    let markedAt: Patch<Date>
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
        case advertisedName
        case group
        case markedAt
        case updatedAt
        case deleted
        case deviceType
    }

    init(
        id: String,
        platform: String,
        externalID: String,
        mac: String?,
        alias: Patch<String> = .absent,
        advertisedName: Patch<String> = .absent,
        group: Patch<String> = .absent,
        markedAt: Patch<Date> = .absent,
        updatedAt: Date,
        deleted: Bool,
        deviceType: String? = nil
    ) {
        self.id = id
        self.platform = platform
        self.externalID = externalID
        self.mac = mac
        self.alias = alias
        self.advertisedName = advertisedName
        self.group = group
        self.markedAt = markedAt
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
            alias: device.resolvedAliasPatch,
            advertisedName: device.resolvedAdvertisedNamePatch,
            group: device.resolvedGroupPatch,
            markedAt: device.resolvedMarkedAtPatch,
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
        try encode(alias, forKey: .alias, into: &container)
        try encode(advertisedName, forKey: .advertisedName, into: &container)
        try encode(group, forKey: .group, into: &container)
        switch markedAt {
        case .absent:
            break
        case .clear:
            // 契约：`null`（或 `""`）表示取消标记；显式 null 语义最清晰。
            try container.encodeNil(forKey: .markedAt)
        case .set(let date):
            try container.encode(SyncDateCodec.string(from: date), forKey: .markedAt)
        }
        try container.encode(SyncDateCodec.string(from: updatedAt), forKey: .updatedAt)
        try container.encode(deleted, forKey: .deleted)
        try container.encodeIfPresent(deviceType, forKey: .deviceType)
    }

    /// absent 不写键；clear 写空串；set 写具体值。
    private func encode(
        _ patch: Patch<String>,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch patch {
        case .absent:
            break
        case .clear:
            try container.encode("", forKey: key)
        case .set(let value):
            try container.encode(value, forKey: key)
        }
    }
}

/// 推送读数条目，`id` 为客户端 UUID，服务端按 id 幂等。
struct PushReading: Encodable, Equatable {
    let id: String
    let platform: String
    let externalID: String
    let metric: String
    let value: Double
    let unit: String
    let recordedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case platform
        case externalId
        case metric
        case value
        case unit
        case recordedAt
    }

    init(
        id: String,
        platform: String,
        externalID: String,
        metric: String,
        value: Double,
        unit: String,
        recordedAt: Date
    ) {
        self.id = id
        self.platform = platform
        self.externalID = externalID
        self.metric = metric
        self.value = value
        self.unit = unit
        self.recordedAt = recordedAt
    }

    init(reading: DeviceReading, device: SavedDevice) {
        self.init(
            id: reading.id.uuidString,
            platform: device.platform,
            externalID: device.externalID,
            metric: reading.metric.rawValue,
            value: reading.value,
            unit: reading.unit,
            recordedAt: reading.recordedAt
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(platform, forKey: .platform)
        try container.encode(externalID, forKey: .externalId)
        try container.encode(metric, forKey: .metric)
        try container.encode(value, forKey: .value)
        try container.encode(unit, forKey: .unit)
        try container.encode(SyncDateCodec.string(from: recordedAt), forKey: .recordedAt)
    }
}

struct PushRequest: Encodable {
    let clientID: String
    let devices: [PushDevice]
    /// 后端旧版本不认识该字段，空数组时完全省略。
    let readings: [PushReading]

    private enum CodingKeys: String, CodingKey {
        case clientId
        case devices
        case readings
    }

    init(clientID: String, devices: [PushDevice], readings: [PushReading] = []) {
        self.clientID = clientID
        self.devices = devices
        self.readings = readings
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientID, forKey: .clientId)
        try container.encode(devices, forKey: .devices)
        if !readings.isEmpty {
            try container.encode(readings, forKey: .readings)
        }
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
        case "server_newer": return L10n.t("sync.conflict.cloudUpdated")
        case "clock_clamped": return L10n.t("sync.conflict.clockAdjusted")
        case "key_taken": return L10n.t("sync.conflict.uniqueKeyTaken")
        default: return reason
        }
    }
}

struct PushResult: Decodable, Equatable {
    let applied: [AppliedChange]
    let conflicts: [SyncConflict]
    let nextCursor: Int64
    /// 本次服务端实际写入 / 因 id 重复跳过的读数条数；旧后端缺省为 0。
    let appliedReadings: Int
    let skippedReadings: Int
    /// 命中服务端幂等缓存时 `Idempotent-Replayed: true`。
    let isIdempotentReplay: Bool

    private enum CodingKeys: String, CodingKey {
        case applied
        case conflicts
        case nextCursor
        case appliedReadings
        case skippedReadings
    }

    init(
        applied: [AppliedChange] = [],
        conflicts: [SyncConflict] = [],
        nextCursor: Int64 = 0,
        appliedReadings: Int = 0,
        skippedReadings: Int = 0,
        isIdempotentReplay: Bool = false
    ) {
        self.applied = applied
        self.conflicts = conflicts
        self.nextCursor = nextCursor
        self.appliedReadings = appliedReadings
        self.skippedReadings = skippedReadings
        self.isIdempotentReplay = isIdempotentReplay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applied = (try? container.decodeIfPresent([AppliedChange].self, forKey: .applied)) ?? []
        conflicts = (try? container.decodeIfPresent([SyncConflict].self, forKey: .conflicts)) ?? []
        nextCursor = (try? container.decodeIfPresent(Int64.self, forKey: .nextCursor)) ?? 0
        appliedReadings = (try? container.decodeIfPresent(Int.self, forKey: .appliedReadings)) ?? 0
        skippedReadings = (try? container.decodeIfPresent(Int.self, forKey: .skippedReadings)) ?? 0
        isIdempotentReplay = false
    }

    func withIdempotentReplay(_ flag: Bool) -> PushResult {
        PushResult(
            applied: applied,
            conflicts: conflicts,
            nextCursor: nextCursor,
            appliedReadings: appliedReadings,
            skippedReadings: skippedReadings,
            isIdempotentReplay: flag
        )
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
