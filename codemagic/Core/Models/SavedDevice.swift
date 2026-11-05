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
    var mac: String?
    var vendor: String?
    var deviceType: String?
    var firmwareVersion: String?
    var lastSeenAt: Date?
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var syncState: SyncState
    var aliasPatch: Patch<String>
    var advertisedNamePatch: Patch<String>
    var groupPatch: Patch<String>

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
        mac: String? = nil,
        vendor: String? = nil,
        deviceType: String? = nil,
        firmwareVersion: String? = nil,
        lastSeenAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        syncState: SyncState = .pending,
        aliasPatch: Patch<String> = .absent,
        advertisedNamePatch: Patch<String> = .absent,
        groupPatch: Patch<String> = .absent
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
        self.mac = mac
        self.vendor = vendor
        self.deviceType = deviceType
        self.firmwareVersion = firmwareVersion
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncState = syncState
        self.aliasPatch = aliasPatch
        self.advertisedNamePatch = advertisedNamePatch
        self.groupPatch = groupPatch
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
}
