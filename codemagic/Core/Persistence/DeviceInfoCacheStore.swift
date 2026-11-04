import Foundation

/// 设备详情的网络响应缓存：请求失败时读取最近一次成功结果，保证页面不白屏。
final class DeviceInfoCacheStore {
    private let database: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func save(
        product: ProductModel,
        peripheralID: UUID,
        fetchedAt: Date = Date()
    ) throws {
        let payload = try encoder.encode(product)
        guard let payloadText = String(data: payload, encoding: .utf8) else {
            throw AppError.database("设备信息缓存序列化失败")
        }
        try database.execute(
            """
            INSERT OR REPLACE INTO device_info_cache
            (peripheral_id, payload, fetched_at, updated_at, deleted_at, sync_state)
            VALUES (?, ?, ?, ?, NULL, ?);
            """,
            [
                .text(peripheralID.uuidString),
                .text(payloadText),
                .double(fetchedAt.timeIntervalSince1970),
                .double(fetchedAt.timeIntervalSince1970),
                .text(SyncState.pending.rawValue),
            ]
        )
    }

    func fetch(peripheralID: UUID) throws -> DeviceInfoCache? {
        let rows = try database.query(
            """
            SELECT * FROM device_info_cache
            WHERE peripheral_id = ? AND deleted_at IS NULL LIMIT 1;
            """,
            [.text(peripheralID.uuidString)]
        )
        guard let row = rows.first,
              let payload = row.text("payload"),
              let data = payload.data(using: .utf8),
              let product = try? decoder.decode(ProductModel.self, from: data)
        else { return nil }

        return DeviceInfoCache(
            peripheralID: peripheralID,
            product: product,
            fetchedAt: Date(timeIntervalSince1970: row.double("fetched_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0),
            deletedAt: row.double("deleted_at").map(Date.init(timeIntervalSince1970:)),
            syncState: SyncState(rawValue: row.text("sync_state") ?? "") ?? .pending
        )
    }
}
