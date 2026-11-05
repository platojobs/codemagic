import Foundation

/// 市场条目类型：配件或固件。仅信息展示，不含购物车、订单与支付。
enum MarketItemKind: String, Codable {
    case accessory
    case firmware
    case other

    var title: String {
        switch self {
        case .accessory: return L10n.t("market.kind.accessory")
        case .firmware: return L10n.t("market.kind.firmware")
        case .other: return L10n.t("metric.other")
        }
    }

    /// 容忍后端新增未知类型，统一落到 `.other`，不使整包解析失败。
    init(apiValue: String) {
        self = MarketItemKind(rawValue: apiValue) ?? .other
    }

    /// 兼容 Android 侧 mock 的 `category` 中文分类（如「调试配件」「固件版本」）。
    init(category: String) {
        if category.contains(L10n.t("market.kind.firmware")) {
            self = .firmware
        } else if category.contains(L10n.t("market.kind.accessory")) {
            self = .accessory
        } else {
            self = .other
        }
    }
}

/// 市场条目。字段以本项目契约为准，解析兼容 Android 侧 mock 的 `title` / `category` / `description`。
struct MarketItem: Identifiable, Decodable, Equatable {
    let id: String
    let kind: MarketItemKind
    let name: String
    let vendor: String
    let version: String
    let compatibility: String
    /// 来自兼容性对象的真实字段值（如「平台：ios」「协议：ble-gatt」），仅用于筛选。
    let compatibilityTags: [String]
    let summary: String

    init(
        id: String,
        kind: MarketItemKind,
        name: String,
        vendor: String,
        version: String,
        compatibility: String,
        compatibilityTags: [String] = [],
        summary: String
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.vendor = vendor
        self.version = version
        self.compatibility = compatibility
        self.compatibilityTags = compatibilityTags
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case category
        case name
        case title
        case vendor
        case version
        case compatibility
        case summary
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""

        if let kindValue = try? container.decode(String.self, forKey: .kind) {
            kind = MarketItemKind(apiValue: kindValue)
        } else {
            kind = MarketItemKind(category: (try? container.decode(String.self, forKey: .category)) ?? "")
        }

        name = (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .title))
            ?? ""
        vendor = (try? container.decode(String.self, forKey: .vendor)) ?? ""
        version = (try? container.decode(String.self, forKey: .version)) ?? ""
        summary = (try? container.decode(String.self, forKey: .summary))
            ?? (try? container.decode(String.self, forKey: .description))
            ?? ""

        if let text = try? container.decode(String.self, forKey: .compatibility) {
            compatibility = text
            compatibilityTags = []
        } else if let list = try? container.decode([String].self, forKey: .compatibility) {
            compatibility = list.joined(separator: L10n.t("common.listSeparator"))
            compatibilityTags = []
        } else if let info = try? container.decode(CompatibilityInfo.self, forKey: .compatibility) {
            compatibility = info.displayItems.joined(separator: L10n.t("common.semicolonSeparator"))
            compatibilityTags = info.filterTags
        } else {
            compatibility = ""
            compatibilityTags = []
        }
    }

    var displayIdentifier: String {
        id.isEmpty ? "\(vendor)-\(name)" : id
    }
}
