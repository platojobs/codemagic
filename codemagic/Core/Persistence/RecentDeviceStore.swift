import Foundation

/// 最近扫描设备的数据访问层，供首页冷启动展示。
final class RecentDeviceStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func fetchAll(limit: Int = 20) throws -> [RecentDevice] {
        let rows = try database.query(
            """
            SELECT * FROM recent_devices WHERE deleted_at IS NULL
            ORDER BY last_seen_at DESC LIMIT ?;
            """,
            [.integer(Int64(limit))]
        )
        return rows.compactMap(Self.makeDevice)
    }

    /// 单个设备最近一次扫描记录；详情页需要展示 dBm 与读数时间。
    func fetch(peripheralID: UUID) throws -> RecentDevice? {
        let rows = try database.query(
            """
            SELECT * FROM recent_devices
            WHERE peripheral_id = ? AND deleted_at IS NULL
            LIMIT 1;
            """,
            [.text(peripheralID.uuidString)]
        )
        return rows.compactMap(Self.makeDevice).first
    }

    func upsert(peripheralID: UUID, name: String, rssi: Int, lastSeenAt: Date) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO recent_devices
            (peripheral_id, name, rssi, last_seen_at, updated_at, deleted_at, sync_state)
            VALUES (?, ?, ?, ?, ?, NULL, ?);
            """,
            [
                .text(peripheralID.uuidString),
                .text(name),
                .integer(Int64(rssi)),
                .double(lastSeenAt.timeIntervalSince1970),
                .double(lastSeenAt.timeIntervalSince1970),
                .text(SyncState.pending.rawValue),
            ]
        )
    }

    private static func makeDevice(from row: SQLRow) -> RecentDevice? {
        guard let peripheralText = row.text("peripheral_id"),
              let peripheralID = UUID(uuidString: peripheralText)
        else { return nil }

        return RecentDevice(
            peripheralID: peripheralID,
            name: row.text("name") ?? "",
            rssi: Int(row.integer("rssi") ?? 0),
            lastSeenAt: Date(timeIntervalSince1970: row.double("last_seen_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0),
            deletedAt: row.double("deleted_at").map(Date.init(timeIntervalSince1970:)),
            syncState: SyncState(rawValue: row.text("sync_state") ?? "") ?? .pending
        )
    }
}
