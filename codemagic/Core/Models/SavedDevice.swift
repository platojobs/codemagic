import Foundation

/// 可缺省字段的三态，对齐 openapi 0.3.3：
/// - `absent`：本次不上报，服务端保持原值（JSON 中省略该字段）；
/// - `clear`：显式清除，编码为 `""`（例如 `"group": ""`）；
/// - `set`：上报具体值。
///
/// `nil`（未上报）与空串（显式清除）是两种不同语义，必须用本类型区分。
enum Patch<Value: Equatable>: Equatable {
    case absent
    case clear
    case set(Value)

    var isReported: Bool {
        if case .absent = self { return false }
        return true
    }

    /// 持久化用的状态字符串，与数据库 `*_patch` 列对应。
    var persistedState: String {
        switch self {
        case .absent: return "absent"
        case .clear: return "clear"
        case .set: return "set"
        }
    }

    /// 从数据库状态恢复；`set` 的关联值取当前列值。
    static func restored(_ state: String?, value: @autoclosure () -> Value) -> Patch<Value> {
        switch state ?? "absent" {
        case "clear": return .clear
        case "set": return .set(value())
        default: return .absent
        }
    }
}

/// 已保存的蓝牙设备。
/// `id` 为客户端生成的 UUID，作为同步主键；`peripheralID` 为本机 CoreBluetooth 标识符。
/// 服务端设备唯一键为 `(platform, externalId)`，iOS 的 `externalId` 为
/// `CBPeripheral.identifier`（UUID 大写），`mac` 可为空。
///
/// 名称语义（openapi 0.3.3）：
/// - `advertisedName`：设备广播名（BLE Local Name），由扫描写入；
/// - `remark`：用户别名，只在用户编辑时写入；
/// - `deviceType`：型号键，用于兜底展示。
/// 两者互不覆盖。`aliasPatch` / `advertisedNamePatch` / `groupPatch` 记录本次待上报的字段状态，
/// 未修改的字段保持 `absent`，推送时直接省略。
struct SavedDevice: Identifiable, Equatable {
    let id: UUID
    let peripheralID: UUID
    var platform: String
    var externalID: String
    /// 设备广播名（BLE Local Name）；扫描路径写入，用户编辑不触碰。
    var advertisedName: String
    /// 用户别名；用户编辑写入，扫描路径不触碰。
    var remark: String
    var groupName: String
    /// 本机房间归属；`nil` 表示未分配。与服务端 `remoteRoomID` 通过房间远端 id 映射。
    var roomID: UUID?
    /// 本地家庭归属；`nil` 表示尚未接入家庭 / 离线新增，界面标注「未同步」。
    var householdID: UUID?
    /// 服务端房间真值（`roomId`），用于判断本机归属是否已上报成功。
    var remoteRoomID: String?
    /// 服务端家庭真值（`householdId`）。
    var remoteHouseholdID: String?
    var mac: String?
    var vendor: String?
    var deviceType: String?
    var firmwareVersion: String?
    var lastSeenAt: Date?
    /// 用户「标记设备」的时间（契约 0.20.0）；`nil` 表示未标记。
    /// 同时作为该字段的字段级 LWW 版本，未标记时服务端返回 JSON `null`。
    var markedAt: Date?
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var syncState: SyncState
    var aliasPatch: Patch<String>
    var advertisedNamePatch: Patch<String>
    var groupPatch: Patch<String>
    /// 待上报的标记三态：`absent` 保持原值，`clear` 取消标记，`set` 标记。
    var markedAtPatch: Patch<Date>

    static let defaultGroupName = L10n.t("device.group.none")
    /// iOS 端固定平台标识，与后端 `platform` 枚举一致。
    static let iosPlatform = "ios"

    init(
        id: UUID = UUID(),
        peripheralID: UUID,
        platform: String = SavedDevice.iosPlatform,
        externalID: String? = nil,
        advertisedName: String,
        remark: String = "",
        groupName: String = SavedDevice.defaultGroupName,
        roomID: UUID? = nil,
        householdID: UUID? = nil,
        remoteRoomID: String? = nil,
        remoteHouseholdID: String? = nil,
        mac: String? = nil,
        vendor: String? = nil,
        deviceType: String? = nil,
        firmwareVersion: String? = nil,
        lastSeenAt: Date? = nil,
        markedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        syncState: SyncState = .pending,
        aliasPatch: Patch<String> = .absent,
        advertisedNamePatch: Patch<String> = .absent,
        groupPatch: Patch<String> = .absent,
        markedAtPatch: Patch<Date> = .absent
    ) {
        self.id = id
        self.peripheralID = peripheralID
        self.platform = platform.isEmpty ? SavedDevice.iosPlatform : platform
        let trimmedExternalID = externalID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.externalID = trimmedExternalID.isEmpty
            ? peripheralID.uuidString.uppercased()
            : trimmedExternalID.uppercased()
        self.advertisedName = advertisedName
        self.remark = remark
        self.groupName = groupName.isEmpty ? SavedDevice.defaultGroupName : groupName
        self.roomID = roomID
        self.householdID = householdID
        self.remoteRoomID = remoteRoomID
        self.remoteHouseholdID = remoteHouseholdID
        self.mac = mac
        self.vendor = vendor
        self.deviceType = deviceType
        self.firmwareVersion = firmwareVersion
        self.lastSeenAt = lastSeenAt
        self.markedAt = markedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncState = syncState
        self.aliasPatch = aliasPatch
        self.advertisedNamePatch = advertisedNamePatch
        self.groupPatch = groupPatch
        self.markedAtPatch = markedAtPatch
    }

    /// 服务端唯一键的本地拼写，仅用于日志与断言。
    var syncKey: String { "\(platform):\(externalID)" }

    /// 只有本机扫描得到的 iOS 设备有可用的 `CBPeripheral.identifier`，可直接连接。
    /// 从服务端拉回的 Android 设备只在本机占位展示，无法通过 CoreBluetooth 连接。
    var isConnectable: Bool { platform == SavedDevice.iosPlatform }

    /// 跨平台设备的展示文案；本机可连接时为 nil。
    var connectUnavailableText: String? {
        guard !isConnectable else { return nil }
        return L10n.f("device.remoteOnly", String(describing: platformDisplayName))
    }

    var platformDisplayName: String {
        switch platform {
        case SavedDevice.iosPlatform: return "iOS"
        case "android": return "Android"
        default: return platform
        }
    }

    /// 同步别名：与列表展示名一致，长度受后端限制（100）。
    var syncAlias: String {
        String(displayName.prefix(100))
    }

    /// 列表/详情展示名：用户别名 → 广播名 → 型号名/型号键。
    var displayName: String {
        let alias = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alias.isEmpty { return alias }
        let advertised = advertisedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !advertised.isEmpty { return advertised }
        let model = deviceType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? L10n.t("bluetooth.unnamedDevice") : model
    }

    /// 推送时的别名三态：`.set` 使用当前值，避免关联值过期。
    var resolvedAliasPatch: Patch<String> {
        switch aliasPatch {
        case .absent: return .absent
        case .clear: return .clear
        case .set: return .set(remark)
        }
    }

    var resolvedAdvertisedNamePatch: Patch<String> {
        switch advertisedNamePatch {
        case .absent: return .absent
        case .clear: return .clear
        case .set: return .set(advertisedName)
        }
    }

    /// 推送时的分组三态：本地「未分组」等价于服务端空串，因此 `.set` 到默认分组时按显式清除上报。
    var resolvedGroupPatch: Patch<String> {
        switch groupPatch {
        case .absent: return .absent
        case .clear: return .clear
        case .set:
            return groupName == SavedDevice.defaultGroupName ? .clear : .set(groupName)
        }
    }

    /// 推送时的标记三态：`.clear` 编码为 JSON `null`（取消标记），`.set` 编码 RFC3339 时间。
    var resolvedMarkedAtPatch: Patch<Date> {
        switch markedAtPatch {
        case .absent: return .absent
        case .clear: return .clear
        case .set:
            guard let markedAt else { return .clear }
            return .set(markedAt)
        }
    }

    /// 列表 / 详情展示用：已标记时返回标记状态；未标记返回 nil。
    /// 本地尚未同步（未登录或离线先写本机）时明确标注「待同步」，不显示为已同步。
    var markStatusText: String? {
        guard markedAt != nil else { return nil }
        return syncState == .synced ? L10n.t("device.marked") : L10n.t("device.markedPending")
    }
}
