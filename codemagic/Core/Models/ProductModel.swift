import Foundation

/// GATT 服务与特征表条目。字段名与后端契约一致：`uuid` / `name`。
/// `characteristics` 为兼容 Android 侧 mock 的可选扩展字段，缺失时为空数组。
struct GATTService: Codable, Equatable {
    let uuid: String
    let name: String
    let characteristics: [String]

    init(uuid: String, name: String, characteristics: [String] = []) {
        self.uuid = uuid
        self.name = name
        self.characteristics = characteristics
    }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case characteristics
    }

    /// 容忍未知字段与缺失字段：缺失时填空值，避免整条响应解析失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = (try? container.decode(String.self, forKey: .uuid)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        characteristics = (try? container.decode([String].self, forKey: .characteristics)) ?? []
    }
}

/// 产品型号 / 设备信息，二者共用同一份字段契约：
/// `mac, vendor, deviceType, firmwareVersion, gattServices, compatibility`。
///
/// 为与 Android 端共用同一份 mock/后端，解析时兼容以下别名：
/// - `deviceType` ← `model`（Android `ProductDto`）
/// - `gattServices` ← `services`（Android `ProductDto`）
/// - `compatibility` 同时接受字符串、字符串数组与对象
struct ProductModel: Identifiable, Codable, Equatable {
    let mac: String
    let vendor: String
    let deviceType: String
    let firmwareVersion: String
    let gattServices: [GATTService]
    let compatibility: [String]
    let note: String

    /// 产品库唯一键：优先服务端 id，其次 mac，最后退化为厂商 + 型号，保证列表可用。
    var id: String {
        if !apiIdentifier.isEmpty { return apiIdentifier }
        if !mac.isEmpty { return mac }
        return "\(vendor)-\(deviceType)"
    }

    private let apiIdentifier: String

    init(
        mac: String,
        vendor: String,
        deviceType: String,
        firmwareVersion: String,
        gattServices: [GATTService],
        compatibility: [String],
        note: String = "",
        apiIdentifier: String = ""
    ) {
        self.mac = mac
        self.vendor = vendor
        self.deviceType = deviceType
        self.firmwareVersion = firmwareVersion
        self.gattServices = gattServices
        self.compatibility = compatibility
        self.note = note
        self.apiIdentifier = apiIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case mac
        case vendor
        case deviceType
        case model
        case firmwareVersion
        case gattServices
        case services
        case compatibility
        case note
    }

    /// 宽松解析：忽略未知字段；缺失字段给默认值；列表字段同时接受契约名与 Android 别名。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiIdentifier = (try? container.decode(String.self, forKey: .id)) ?? ""
        mac = (try? container.decode(String.self, forKey: .mac)) ?? ""
        vendor = (try? container.decode(String.self, forKey: .vendor)) ?? ""
        firmwareVersion = (try? container.decode(String.self, forKey: .firmwareVersion)) ?? ""
        note = (try? container.decode(String.self, forKey: .note)) ?? ""

        let deviceTypeAlias = (try? container.decode(String.self, forKey: .deviceType))
            ?? (try? container.decode(String.self, forKey: .model))
        deviceType = deviceTypeAlias ?? ""

        let canonicalServices = try? container.decode([GATTService].self, forKey: .gattServices)
        gattServices = canonicalServices
            ?? (try? container.decode([GATTService].self, forKey: .services))
            ?? []

        compatibility = Self.decodeCompatibility(from: container)
    }

    /// 缓存写入时只输出规范字段名，不回写 Android 别名。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apiIdentifier, forKey: .id)
        try container.encode(mac, forKey: .mac)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(deviceType, forKey: .deviceType)
        try container.encode(firmwareVersion, forKey: .firmwareVersion)
        try container.encode(gattServices, forKey: .gattServices)
        try container.encode(compatibility, forKey: .compatibility)
        try container.encode(note, forKey: .note)
    }

    private static func decodeCompatibility(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [String] {
        if let list = try? container.decode([String].self, forKey: .compatibility) {
            return list
        }
        if let single = try? container.decode(String.self, forKey: .compatibility) {
            return single.isEmpty ? [] : [single]
        }
        // openapi.yaml 中 compatibility 是对象，这里把其中的字符串与字符串数组摊平展示。
        if let object = try? container.decode([String: CompatibilityValue].self, forKey: .compatibility) {
            return object
                .sorted { $0.key < $1.key }
                .flatMap { entry -> [String] in
                    switch entry.value {
                    case .text(let text): return text.isEmpty ? [] : [text]
                    case .list(let list): return list
                    }
                }
        }
        return []
    }
}

/// `compatibility` 对象的宽松值：字符串或字符串数组，其余类型忽略。
private enum CompatibilityValue: Decodable {
    case text(String)
    case list([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .list(list)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .text("")
        }
    }
}
