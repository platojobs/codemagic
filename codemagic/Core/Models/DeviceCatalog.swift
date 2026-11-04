import Foundation

/// openapi 0.3.2 `Compatibility`：固件 / 配件 / 型号 / 用户设备共用。
/// 结构为 `additionalProperties: true`，这里只读取可展示与可筛选的字符串字段，
/// 其它扩展字段按真实字段名保留，不做假分类。
struct CompatibilityInfo: Decodable, Equatable {
    struct Field: Equatable {
        let name: String
        let values: [String]
    }

    let platforms: [String]
    let minAppVersion: String
    let protocolName: String
    let features: [String]
    /// `platforms` / `protocol` / `features` / `minAppVersion` 之外的扩展字段（如配件 `deviceTypes`）。
    let extras: [Field]

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ name: String) { self.stringValue = name }
    }

    private static let knownKeys: Set<String> = ["platforms", "minAppVersion", "protocol", "features"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        platforms = Self.stringList(container, key: "platforms")
        features = Self.stringList(container, key: "features")
        minAppVersion = Self.stringValue(container, key: "minAppVersion")
        protocolName = Self.stringValue(container, key: "protocol")
        extras = container.allKeys
            .filter { !Self.knownKeys.contains($0.stringValue) }
            .sorted { $0.stringValue < $1.stringValue }
            .compactMap { key in
                let values = Self.anyStringList(container, key: key)
                return values.isEmpty ? nil : Field(name: key.stringValue, values: values)
            }
    }

    /// 详情 / 列表展示用文案：只列出真实存在的字段。
    var displayItems: [String] {
        var items: [String] = []
        if !platforms.isEmpty { items.append("平台：\(platforms.joined(separator: "、"))") }
        if !protocolName.isEmpty { items.append("协议：\(protocolName)") }
        if !features.isEmpty { items.append("特性：\(features.joined(separator: "、"))") }
        if !minAppVersion.isEmpty { items.append("最低 App：\(minAppVersion)") }
        items.append(
            contentsOf: extras.map {
                "\(Self.displayLabel(for: $0.name))：\($0.values.joined(separator: "、"))"
            }
        )
        return items
    }

    /// 市场筛选取值：来自真实字段，带字段名前缀避免不同维度重名。
    var filterTags: [String] {
        var tags = platforms.map { "平台：\($0)" }
        if !protocolName.isEmpty { tags.append("协议：\(protocolName)") }
        extras.forEach { field in
            field.values.forEach { tags.append("\(Self.displayLabel(for: field.name))：\($0)") }
        }
        return tags
    }

    /// 已文档化的扩展字段使用中文标签，其余保留原字段名（不编造维度）。
    private static func displayLabel(for field: String) -> String {
        field == "deviceTypes" ? "型号" : field
    }

    private static func stringValue(
        _ container: KeyedDecodingContainer<DynamicKey>,
        key: String
    ) -> String {
        (try? container.decodeIfPresent(String.self, forKey: DynamicKey(key))) ?? ""
    }

    private static func stringList(
        _ container: KeyedDecodingContainer<DynamicKey>,
        key: String
    ) -> [String] {
        anyStringList(container, key: DynamicKey(key))
    }

    private static func anyStringList(
        _ container: KeyedDecodingContainer<DynamicKey>,
        key: DynamicKey
    ) -> [String] {
        if let list = try? container.decodeIfPresent([String].self, forKey: key) {
            return list.filter { !$0.isEmpty }
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key), !text.isEmpty {
            return [text]
        }
        return []
    }
}

/// `GET /device-types/{type}/catalog` 中的固件条目（openapi 0.3.2 增加 vendor / compatibility）。
struct FirmwareInfo: Decodable, Equatable {
    let id: String
    let deviceType: String
    let version: String
    let releaseNotes: String
    let releasedAt: String
    let vendor: String
    let compatibility: CompatibilityInfo?

    private enum CodingKeys: String, CodingKey {
        case id
        case deviceType
        case version
        case releaseNotes
        case releasedAt
        case vendor
        case compatibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        deviceType = (try? container.decodeIfPresent(String.self, forKey: .deviceType)) ?? ""
        version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? ""
        releaseNotes = (try? container.decodeIfPresent(String.self, forKey: .releaseNotes)) ?? ""
        releasedAt = (try? container.decodeIfPresent(String.self, forKey: .releasedAt)) ?? ""
        // 未核实的记录为空字符串，不编造厂商。
        vendor = (try? container.decodeIfPresent(String.self, forKey: .vendor)) ?? ""
        compatibility = try? container.decodeIfPresent(CompatibilityInfo.self, forKey: .compatibility)
    }
}

/// `GET /device-types/{type}/catalog` 中的配件条目（openapi 0.3.2 增加 vendor / compatibility）。
struct AccessoryInfo: Decodable, Equatable {
    let id: String
    let deviceType: String
    let name: String
    let sku: String
    let descriptionText: String
    let vendor: String
    let compatibility: CompatibilityInfo?

    private enum CodingKeys: String, CodingKey {
        case id
        case deviceType
        case name
        case sku
        case description
        case vendor
        case compatibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        deviceType = (try? container.decodeIfPresent(String.self, forKey: .deviceType)) ?? ""
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        sku = (try? container.decodeIfPresent(String.self, forKey: .sku)) ?? ""
        descriptionText = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
        vendor = (try? container.decodeIfPresent(String.self, forKey: .vendor)) ?? ""
        compatibility = try? container.decodeIfPresent(CompatibilityInfo.self, forKey: .compatibility)
    }
}

/// `GET /device-types/{type}/catalog`：型号元数据 + 固件 + 配件一次返回。
struct DeviceCatalog: Decodable, Equatable {
    let deviceType: DeviceTypeInfo
    let firmwares: [FirmwareInfo]
    let accessories: [AccessoryInfo]

    private enum CodingKeys: String, CodingKey {
        case deviceType
        case firmwares
        case accessories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceType = (try? container.decodeIfPresent(DeviceTypeInfo.self, forKey: .deviceType))
            ?? DeviceTypeInfo.empty
        firmwares = (try? container.decodeIfPresent([FirmwareInfo].self, forKey: .firmwares)) ?? []
        accessories = (try? container.decodeIfPresent([AccessoryInfo].self, forKey: .accessories)) ?? []
    }
}

/// `GET /my/devices/{platform}/{externalId}`：iOS 用 UUID 定位自己的设备记录。
/// openapi 0.3.2 新增 `deviceType` / `vendor` / `firmwareVersion` / `compatibility`，
/// 四者均可为 null（未注册型号、未核实元数据），解码时归一为 nil。
/// openapi 0.3.3 新增 `advertisedName`（广播名，与用户别名 `alias` 分离），缺省按 absent 归一为 nil。
struct UserDeviceInfo: Decodable, Equatable {
    let id: String
    let clientID: String
    let platform: String
    let externalID: String
    let mac: String
    let alias: String
    let advertisedName: String?
    let group: String
    let updatedAt: Date
    let deletedAt: Date?
    let serverSeq: Int64?
    let deviceType: String?
    let vendor: String?
    let firmwareVersion: String?
    let compatibility: CompatibilityInfo?

    private enum CodingKeys: String, CodingKey {
        case id
        case clientId
        case platform
        case externalId
        case mac
        case alias
        case advertisedName
        case group
        case updatedAt
        case deletedAt
        case serverSeq
        case deviceType
        case vendor
        case firmwareVersion
        case compatibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        clientID = (try? container.decodeIfPresent(String.self, forKey: .clientId)) ?? ""
        platform = (try? container.decodeIfPresent(String.self, forKey: .platform)) ?? ""
        externalID = ((try? container.decodeIfPresent(String.self, forKey: .externalId)) ?? "").uppercased()
        mac = (try? container.decodeIfPresent(String.self, forKey: .mac)) ?? ""
        alias = (try? container.decodeIfPresent(String.self, forKey: .alias)) ?? ""
        advertisedName = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .advertisedName))
        group = (try? container.decodeIfPresent(String.self, forKey: .group)) ?? ""
        updatedAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        ) ?? Date(timeIntervalSince1970: 0)
        deletedAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .deletedAt)) ?? ""
        )
        serverSeq = try? container.decodeIfPresent(Int64.self, forKey: .serverSeq)
        deviceType = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .deviceType))
        vendor = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .vendor))
        firmwareVersion = Self.nonEmpty(
            try? container.decodeIfPresent(String.self, forKey: .firmwareVersion)
        )
        compatibility = try? container.decodeIfPresent(CompatibilityInfo.self, forKey: .compatibility)
    }

    /// null、缺失与空串统一为 nil，避免界面出现 "null" 或空行。
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension DeviceTypeInfo {
    /// 空对象，用于 catalog 缺少 `deviceType` 时保持页面可渲染。
    static let empty = DeviceTypeInfo(
        type: "",
        name: "",
        vendor: "",
        descriptionText: "",
        gattServices: [],
        compatibility: nil
    )
}
