import Foundation

/// 最近扫描到的设备（本地持久化，用于首页冷启动展示）。
struct RecentDevice: Equatable {
    let peripheralID: UUID
    var name: String
    var rssi: Int
    var lastSeenAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var syncState: SyncState
}

/// 设备详情的本地缓存，网络失败时降级读取。
struct DeviceInfoCache: Equatable {
    let peripheralID: UUID
    let product: ProductModel
    let fetchedAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var syncState: SyncState
}
