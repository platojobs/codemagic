import Foundation

/// 市场条目类型：配件或固件。仅信息展示，不含购物车、订单与支付。
enum MarketItemKind: String, Codable {
    case accessory
    case firmware
    case other

    var title: String {
        switch self {
        case .accessory: return "配件"
        case .firmware: return "固件"
        case .other: return "其他"
        }
    }

    /// 容忍后端新增未知类型，统一落到 `.other`，不使整包解析失败。
    init(apiValue: String) {
        self = MarketItemKind(rawValue: apiValue) ?? .other
    }

    /// 兼容 Android 侧 mock 的 `category` 中文分类（如「调试配件」「固件版本」）。
    init(category: String) {
        if category.contains("固件") {
            self = .firmware
        } else if category.contains("配件") {
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
    let summary: String

    init(
        id: String,
        kind: MarketItemKind,
        name: String,
        vendor: String,
        version: String,
        compatibility: String,
        summary: String
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.vendor = vendor
        self.version = version
        self.compatibility = compatibility
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
        } else if let list = try? container.decode([String].self, forKey: .compatibility) {
            compatibility = list.joined(separator: "、")
        } else {
            compatibility = ""
        }
    }

    var displayIdentifier: String {
        id.isEmpty ? "\(vendor)-\(name)" : id
    }
}
