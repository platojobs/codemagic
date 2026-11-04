import Foundation

/// `GET /device-types/{type}/catalog` 中的固件条目。
struct FirmwareInfo: Decodable, Equatable {
    let id: String
    let deviceType: String
    let version: String
    let releaseNotes: String
    let releasedAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case deviceType
        case version
        case releaseNotes
        case releasedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        deviceType = (try? container.decodeIfPresent(String.self, forKey: .deviceType)) ?? ""
        version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? ""
        releaseNotes = (try? container.decodeIfPresent(String.self, forKey: .releaseNotes)) ?? ""
        releasedAt = (try? container.decodeIfPresent(String.self, forKey: .releasedAt)) ?? ""
    }
}

/// `GET /device-types/{type}/catalog` 中的配件条目。
struct AccessoryInfo: Decodable, Equatable {
    let id: String
    let deviceType: String
    let name: String
    let sku: String
    let descriptionText: String

    private enum CodingKeys: String, CodingKey {
        case id
        case deviceType
        case name
        case sku
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        deviceType = (try? container.decodeIfPresent(String.self, forKey: .deviceType)) ?? ""
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        sku = (try? container.decodeIfPresent(String.self, forKey: .sku)) ?? ""
        descriptionText = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
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
struct UserDeviceInfo: Decodable, Equatable {
    let id: String
    let clientID: String
    let platform: String
    let externalID: String
    let mac: String
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
        platform = (try? container.decodeIfPresent(String.self, forKey: .platform)) ?? ""
        externalID = ((try? container.decodeIfPresent(String.self, forKey: .externalId)) ?? "").uppercased()
        mac = (try? container.decodeIfPresent(String.self, forKey: .mac)) ?? ""
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
}

extension DeviceTypeInfo {
    /// 空对象，用于 catalog 缺少 `deviceType` 时保持页面可渲染。
    static let empty = DeviceTypeInfo(type: "", name: "", vendor: "", descriptionText: "", gattServices: [])

    /// 显式初始化，供映射与测试使用（Decodable 合成 init 被自定义 init 覆盖）。
    init(type: String, name: String, vendor: String, descriptionText: String, gattServices: [GATTService]) {
        self.type = type
        self.name = name
        self.vendor = vendor
        self.descriptionText = descriptionText
        self.gattServices = gattServices
    }
}
