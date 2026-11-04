import Foundation

/// 已保存设备的数据访问层。删除使用软删除，保留 `deletedAt` 与 `syncState = pendingDelete`。
final class SavedDeviceStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func fetchAll() throws -> [SavedDevice] {
        let rows = try database.query(
            "SELECT * FROM saved_devices WHERE deleted_at IS NULL ORDER BY updated_at DESC;"
        )
        return rows.compactMap(Self.makeDevice)
    }

    func fetch(peripheralID: UUID) throws -> SavedDevice? {
        let rows = try database.query(
            "SELECT * FROM saved_devices WHERE peripheral_id = ? AND deleted_at IS NULL LIMIT 1;",
            [.text(peripheralID.uuidString)]
        )
        return rows.compactMap(Self.makeDevice).first
    }

    func upsert(_ device: SavedDevice) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO saved_devices
            (id, peripheral_id, name, remark, group_name, mac, vendor, firmware_version,
             last_seen_at, created_at, updated_at, deleted_at, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(device.id.uuidString),
                .text(device.peripheralID.uuidString),
                .text(device.name),
                .text(device.remark),
                .text(device.groupName),
                device.mac.map(SQLValue.text) ?? .null,
                device.vendor.map(SQLValue.text) ?? .null,
                device.firmwareVersion.map(SQLValue.text) ?? .null,
                device.lastSeenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .double(device.createdAt.timeIntervalSince1970),
                .double(device.updatedAt.timeIntervalSince1970),
                device.deletedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(device.syncState.rawValue),
            ]
        )
    }

    func softDelete(id: UUID, at date: Date = Date()) throws {
        try database.execute(
            """
            UPDATE saved_devices
            SET deleted_at = ?, updated_at = ?, sync_state = ?
            WHERE id = ?;
            """,
            [
                .double(date.timeIntervalSince1970),
                .double(date.timeIntervalSince1970),
                .text(SyncState.pendingDelete.rawValue),
                .text(id.uuidString),
            ]
        )
    }

    // MARK: - Mapping

    private static func makeDevice(from row: SQLRow) -> SavedDevice? {
        guard let idText = row.text("id"),
              let id = UUID(uuidString: idText),
              let peripheralText = row.text("peripheral_id"),
              let peripheralID = UUID(uuidString: peripheralText)
        else { return nil }

        let createdAt = Date(timeIntervalSince1970: row.double("created_at") ?? 0)
        let updatedAt = Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
        let lastSeenAt = row.double("last_seen_at").map(Date.init(timeIntervalSince1970:))
        let deletedAt = row.double("deleted_at").map(Date.init(timeIntervalSince1970:))
        let syncState = SyncState(rawValue: row.text("sync_state") ?? "") ?? .pending

        return SavedDevice(
            id: id,
            peripheralID: peripheralID,
            name: row.text("name") ?? "",
            remark: row.text("remark") ?? "",
            groupName: row.text("group_name") ?? SavedDevice.defaultGroupName,
            mac: row.text("mac"),
            vendor: row.text("vendor"),
            firmwareVersion: row.text("firmware_version"),
            lastSeenAt: lastSeenAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            syncState: syncState
        )
    }
}
