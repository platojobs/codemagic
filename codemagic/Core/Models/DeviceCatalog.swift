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
        if !platforms.isEmpty { items.append(L10n.f("catalog.platformItem", platforms.joined(separator: L10n.t("common.listSeparator")))) }
        if !protocolName.isEmpty { items.append(L10n.f("catalog.protocol", protocolName)) }
        if !features.isEmpty { items.append(L10n.f("catalog.features", features.joined(separator: L10n.t("common.listSeparator")))) }
        if !minAppVersion.isEmpty { items.append(L10n.f("catalog.minApp", String(describing: minAppVersion))) }
        items.append(
            contentsOf: extras.map {
                L10n.f("catalog.extraField", Self.displayLabel(for: $0.name), $0.values.joined(separator: L10n.t("common.listSeparator")))
            }
        )
        return items
    }

    /// 市场筛选取值：来自真实字段，带字段名前缀避免不同维度重名。
    var filterTags: [String] {
        var tags = platforms.map { L10n.f("catalog.platformItem", $0) }
        if !protocolName.isEmpty { tags.append(L10n.f("catalog.protocol", protocolName)) }
        extras.forEach { field in
            field.values.forEach { tags.append(L10n.f("catalog.extraField", Self.displayLabel(for: field.name), $0)) }
        }
        return tags
    }

    /// 已文档化的扩展字段使用中文标签，其余保留原字段名（不编造维度）。
    private static func displayLabel(for field: String) -> String {
        field == "deviceTypes" ? L10n.t("catalog.model") : field
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

/// `GET /catalog/device-types` 中的单个指标（openapi 0.3.4 / 契约 0.14.0）。
/// `characteristicUuid` 是特征 UUID，不是服务 UUID；客户端据此定位订阅目标。
struct CatalogMetric: Codable, Equatable {
    let key: String
    let unit: String
    let characteristicUUID: String

    private enum CodingKeys: String, CodingKey {
        case key
        case unit
        case characteristicUuid
    }

    init(key: String, unit: String, characteristicUUID: String) {
        self.key = key
        self.unit = unit
        self.characteristicUUID = characteristicUUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = (try? container.decodeIfPresent(String.self, forKey: .key)) ?? ""
        unit = (try? container.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        characteristicUUID = (try? container.decodeIfPresent(String.self, forKey: .characteristicUuid)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(unit, forKey: .unit)
        try container.encode(characteristicUUID, forKey: .characteristicUuid)
    }
}

/// `GET /catalog/device-types` 的目录项：服务端维护的设备类型事实。
/// 本地不再维护同名常量；这里只负责解码与展示，不复制一份能力表。
struct DeviceTypeCatalogItem: Decodable, Equatable {
    let type: String
    let displayName: String
    let descriptionText: String
    let gattServices: [GATTService]
    let metrics: [CatalogMetric]
    let limitations: [String]
    let compatibility: CompatibilityInfo?
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case type
        case displayName
        case description
        case gattServices
        case metrics
        case limitations
        case compatibility
        case updatedAt
    }

    init(
        type: String,
        displayName: String,
        descriptionText: String = "",
        gattServices: [GATTService] = [],
        metrics: [CatalogMetric] = [],
        limitations: [String] = [],
        compatibility: CompatibilityInfo? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.type = type
        self.displayName = displayName
        self.descriptionText = descriptionText
        self.gattServices = gattServices
        self.metrics = metrics
        self.limitations = limitations
        self.compatibility = compatibility
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? ""
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        descriptionText = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
        gattServices = (try? container.decodeIfPresent([GATTService].self, forKey: .gattServices)) ?? []
        metrics = (try? container.decodeIfPresent([CatalogMetric].self, forKey: .metrics)) ?? []
        limitations = (try? container.decodeIfPresent([String].self, forKey: .limitations)) ?? []
        compatibility = try? container.decodeIfPresent(CompatibilityInfo.self, forKey: .compatibility)
        updatedAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        ) ?? Date(timeIntervalSince1970: 0)
    }

    /// 展示名缺失时退回稳定 type，避免空标题；两者都为空才使用占位文案。
    var resolvedDisplayName: String {
        if !displayName.isEmpty { return displayName }
        return type
    }
}

/// `GET /catalog/device-types` 的完整快照。
struct DeviceTypeCatalog: Decodable, Equatable {
    let version: Int64
    let generatedAt: Date
    let items: [DeviceTypeCatalogItem]

    private enum CodingKeys: String, CodingKey {
        case version
        case generatedAt
        case items
    }

    init(
        version: Int64,
        generatedAt: Date,
        items: [DeviceTypeCatalogItem]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int64.self, forKey: .version)) ?? 0
        generatedAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .generatedAt)) ?? ""
        ) ?? Date(timeIntervalSince1970: 0)
        items = (try? container.decodeIfPresent([DeviceTypeCatalogItem].self, forKey: .items)) ?? []
    }
}

extension CatalogMetric {
    /// 目录里指标 key 与本地 `ReadingMetric` 的别名映射。
    /// 只用于展示名称与归类，不代表本地能解析；能否解析由特征 UUID 判定。
    var localMetric: ReadingMetric? {
        switch key.lowercased() {
        case "temperature", "temperature_celsius": return .temperature
        case "humidity", "relative_humidity": return .humidity
        case "pressure", "pressure_hpa": return .pressure
        case "heart_rate": return .heartRate
        case "battery": return .battery
        case "co2": return .co2
        default: return nil
        }
    }

    /// 本地阅读器订阅的特征是否与目录声明的来源特征一致。
    var localCharacteristic: ReadingCharacteristic? {
        guard !characteristicUUID.isEmpty else { return nil }
        return ReadingCharacteristic.allCases.first {
            MarketInsights.matches($0.rawValue, characteristicUUID)
        }
    }

    var isSupportedLocally: Bool { localCharacteristic != nil }

    /// 指标展示名：已知 key 用本地指标文案，未知 key 原样展示，不编造中文名。
    var displayName: String {
        localMetric?.displayName ?? (key.isEmpty ? L10n.t("common.unknown") : key)
    }

    var displayText: String {
        let unitText = unit.isEmpty ? "" : " · \(unit)"
        if isSupportedLocally {
            return "\(displayName)\(unitText)"
        }
        return L10n.f("catalog.metricUnsupported", "\(displayName)\(unitText)")
    }
}
