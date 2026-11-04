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

    /// 按主键读取，包含 tombstone；同步冲突比对需要看到已删除记录。
    func fetch(id: UUID) throws -> SavedDevice? {
        let rows = try database.query(
            "SELECT * FROM saved_devices WHERE id = ? LIMIT 1;",
            [.text(id.uuidString)]
        )
        return rows.compactMap(Self.makeDevice).first
    }

    /// 按服务端唯一键读取活动记录（不含 tombstone）。
    func fetch(platform: String, externalID: String) throws -> SavedDevice? {
        let rows = try database.query(
            """
            SELECT * FROM saved_devices
            WHERE platform = ? AND external_id = ? AND deleted_at IS NULL
            LIMIT 1;
            """,
            [.text(platform), .text(externalID.uppercased())]
        )
        return rows.compactMap(Self.makeDevice).first
    }

    /// 待上传记录：本地新增/修改/删除但尚未同步的行，包含 tombstone。
    func fetchPending() throws -> [SavedDevice] {
        let rows = try database.query(
            """
            SELECT * FROM saved_devices
            WHERE sync_state != ?
            ORDER BY updated_at ASC;
            """,
            [.text(SyncState.synced.rawValue)]
        )
        return rows.compactMap(Self.makeDevice)
    }

    func pendingCount() throws -> Int {
        let rows = try database.query(
            "SELECT COUNT(*) AS total FROM saved_devices WHERE sync_state != ?;",
            [.text(SyncState.synced.rawValue)]
        )
        return Int(rows.first?.integer("total") ?? 0)
    }

    func upsert(_ device: SavedDevice) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO saved_devices
            (id, peripheral_id, platform, external_id, name, remark, group_name, mac, vendor,
             firmware_version, last_seen_at, created_at, updated_at, deleted_at, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(device.id.uuidString),
                .text(device.peripheralID.uuidString),
                .text(device.platform),
                .text(device.externalID),
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

    /// 服务端已删除（tombstone）：本地同步为已删除且不再待上传。
    func applyRemoteDelete(id: UUID, at date: Date) throws {
        try database.execute(
            """
            UPDATE saved_devices
            SET deleted_at = ?, sync_state = ?, updated_at = MAX(updated_at, ?)
            WHERE id = ?;
            """,
            [
                .double(date.timeIntervalSince1970),
                .text(SyncState.synced.rawValue),
                .double(date.timeIntervalSince1970),
                .text(id.uuidString),
            ]
        )
    }

    /// 标记一批记录已同步（新增/修改/删除均适用）。
    func markSynced(ids: [UUID], at date: Date) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try database.execute(
                "UPDATE saved_devices SET sync_state = ? WHERE id = ?;",
                [.text(SyncState.synced.rawValue), .text(id.uuidString)]
            )
        }
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
            platform: row.text("platform") ?? SavedDevice.iosPlatform,
            externalID: row.text("external_id"),
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
