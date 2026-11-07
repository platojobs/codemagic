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
    /// `limit` 用于后台唤醒场景限制单次网络请求量，剩余记录留待下次同步。
    func fetchPending(limit: Int? = nil) throws -> [SavedDevice] {
        let sql = limit == nil
            ? """
              SELECT * FROM saved_devices
              WHERE sync_state != ?
              ORDER BY updated_at ASC;
              """
            : """
              SELECT * FROM saved_devices
              WHERE sync_state != ?
              ORDER BY updated_at ASC LIMIT ?;
              """
        var parameters: [SQLValue] = [.text(SyncState.synced.rawValue)]
        if let limit {
            parameters.append(.integer(Int64(limit)))
        }
        let rows = try database.query(sql, parameters)
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
            (id, peripheral_id, platform, external_id, name, advertised_name, remark, group_name, room_id, mac,
             vendor, device_type, firmware_version, last_seen_at, server_last_seen_at, created_at, updated_at, deleted_at,
             sync_state, alias_patch, advertised_name_patch, group_patch,
             household_id, remote_room_id, remote_household_id, marked_at, marked_at_patch)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(device.id.uuidString),
                .text(device.peripheralID.uuidString),
                .text(device.platform),
                .text(device.externalID),
                // `name` 为 v4 之前用于展示的遗留列，与 advertised_name 同值写入。
                .text(device.advertisedName),
                .text(device.advertisedName),
                .text(device.remark),
                .text(device.groupName),
                device.roomID.map { .text($0.uuidString) } ?? .null,
                device.mac.map(SQLValue.text) ?? .null,
                device.vendor.map(SQLValue.text) ?? .null,
                device.deviceType.map(SQLValue.text) ?? .null,
                device.firmwareVersion.map(SQLValue.text) ?? .null,
                device.lastSeenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                device.serverLastSeenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .double(device.createdAt.timeIntervalSince1970),
                .double(device.updatedAt.timeIntervalSince1970),
                device.deletedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(device.syncState.rawValue),
                .text(device.aliasPatch.persistedState),
                .text(device.advertisedNamePatch.persistedState),
                .text(device.groupPatch.persistedState),
                device.householdID.map { .text($0.uuidString) } ?? .null,
                device.remoteRoomID.map(SQLValue.text) ?? .null,
                device.remoteHouseholdID.map(SQLValue.text) ?? .null,
                device.markedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(device.markedAtPatch.persistedState),
            ]
        )
    }

    /// 只写入服务端 `lastSeenAt`：它是只读派生字段，绝不置 `pending`、不推进 `updated_at`。
    /// 本地有其他待同步修改时也可以安全调用，不会覆盖 `sync_state` 或字段级 LWW 三态。
    func applyServerLastSeenAt(id: UUID, at date: Date?) throws {
        try database.execute(
            "UPDATE saved_devices SET server_last_seen_at = ? WHERE id = ?;",
            [
                date.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(id.uuidString),
            ]
        )
    }

    /// 仅更新本机房间归属：不触碰同步状态与 `updated_at`，归属通过 `PATCH /my/devices` 单独上报。
    func setRoom(id: UUID, roomID: UUID?) throws {
        try database.execute(
            "UPDATE saved_devices SET room_id = ? WHERE id = ?;",
            [
                roomID.map { .text($0.uuidString) } ?? .null,
                .text(id.uuidString),
            ]
        )
    }

    /// 本地归属变更后同步家庭与服务端真值字段，并保留本机 `sync_state`（归属不进 push）。
    func setAssignment(
        id: UUID,
        householdID: UUID?,
        roomID: UUID?,
        remoteRoomID: String?,
        remoteHouseholdID: String?
    ) throws {
        try database.execute(
            """
            UPDATE saved_devices
            SET household_id = ?, room_id = ?, remote_room_id = ?, remote_household_id = ?
            WHERE id = ?;
            """,
            [
                householdID.map { .text($0.uuidString) } ?? .null,
                roomID.map { .text($0.uuidString) } ?? .null,
                remoteRoomID.map(SQLValue.text) ?? .null,
                remoteHouseholdID.map(SQLValue.text) ?? .null,
                .text(id.uuidString),
            ]
        )
    }

    /// 拉取后落库服务端归属真值：本地房间按 `roomID` 映射，`nil` 表示未分配。
    func applyRemoteAssignment(
        id: UUID,
        householdID: UUID?,
        roomID: UUID?,
        remoteRoomID: String?,
        remoteHouseholdID: String?
    ) throws {
        try setAssignment(
            id: id,
            householdID: householdID,
            roomID: roomID,
            remoteRoomID: remoteRoomID,
            remoteHouseholdID: remoteHouseholdID
        )
    }

    func devices(householdID: UUID) throws -> [SavedDevice] {
        let rows = try database.query(
            """
            SELECT * FROM saved_devices
            WHERE deleted_at IS NULL AND (household_id = ? OR household_id IS NULL)
            ORDER BY updated_at DESC;
            """,
            [.text(householdID.uuidString)]
        )
        return rows.compactMap(Self.makeDevice)
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

    /// 用户标记 / 取消标记：先写本机并置待同步，由后续 push 走字段级 LWW。
    /// `markedAt = nil` 表示取消标记（推送编码为 JSON `null`）。
    func updateMark(id: UUID, markedAt: Date?, at date: Date) throws {
        try database.execute(
            """
            UPDATE saved_devices
            SET marked_at = ?, marked_at_patch = ?, updated_at = ?, sync_state = ?
            WHERE id = ?;
            """,
            [
                markedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(markedAt == nil ? "clear" : "set"),
                .double(date.timeIntervalSince1970),
                .text(SyncState.pending.rawValue),
                .text(id.uuidString),
            ]
        )
    }

    /// 房间详情批量标记 / 取消标记：一次 SQL 更新整批设备，避免部分成功。
    /// `markedAt = nil` 表示取消标记，仍写入 `marked_at_patch = "clear"` 等后续 push。
    func updateMark(ids: [UUID], markedAt: Date?, at date: Date) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let parameters: [SQLValue] =
            [
                markedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(markedAt == nil ? "clear" : "set"),
                .double(date.timeIntervalSince1970),
                .text(SyncState.pending.rawValue),
            ] + ids.map { .text($0.uuidString) }
        try database.execute(
            """
            UPDATE saved_devices
            SET marked_at = ?, marked_at_patch = ?, updated_at = ?, sync_state = ?
            WHERE id IN (\(placeholders));
            """,
            parameters
        )
    }

    /// 标记一批记录已同步（新增/修改/删除均适用）。
    /// 已上报成功的字段三态归零，下一次同步不会重复上报未修改的字段。
    func markSynced(ids: [UUID], at date: Date) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try database.execute(
                """
                UPDATE saved_devices
                SET sync_state = ?, alias_patch = ?, advertised_name_patch = ?, group_patch = ?, marked_at_patch = ?
                WHERE id = ?;
                """,
                [
                    .text(SyncState.synced.rawValue),
                    .text(Patch<String>.absent.persistedState),
                    .text(Patch<String>.absent.persistedState),
                    .text(Patch<String>.absent.persistedState),
                    .text(Patch<Date>.absent.persistedState),
                    .text(id.uuidString),
                ]
            )
        }
    }

    /// 换匿名账号后把本机全部活动设备重新标记为待上传，让新账号重新拿到这些记录。
    /// tombstone 不重传（新账号没有对应记录可删）。返回受影响行数。
    ///
    /// 新账号云端没有这些设备，因此别名/广播名/分组都需作为完整状态上报。
    @discardableResult
    func markAllPendingForRelogin() throws -> Int {
        let active = try database.query(
            "SELECT COUNT(*) AS total FROM saved_devices WHERE deleted_at IS NULL;"
        )
        try database.execute(
            """
            UPDATE saved_devices
            SET sync_state = ?, alias_patch = ?, advertised_name_patch = ?, group_patch = ?,
                marked_at_patch = CASE WHEN marked_at IS NULL THEN 'absent' ELSE 'set' END
            WHERE deleted_at IS NULL;
            """,
            [
                .text(SyncState.pending.rawValue),
                .text(Patch<String>.set("").persistedState),
                .text(Patch<String>.set("").persistedState),
                .text(Patch<String>.set("").persistedState),
            ]
        )
        return Int(active.first?.integer("total") ?? 0)
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
        let serverLastSeenAt = row.double("server_last_seen_at").map(Date.init(timeIntervalSince1970:))
        let deletedAt = row.double("deleted_at").map(Date.init(timeIntervalSince1970:))
        let markedAt = row.double("marked_at").map(Date.init(timeIntervalSince1970:))
        let syncState = SyncState(rawValue: row.text("sync_state") ?? "") ?? .pending
        let advertisedName = row.text("advertised_name") ?? row.text("name") ?? ""
        let remark = row.text("remark") ?? ""
        let groupName = row.text("group_name") ?? SavedDevice.defaultGroupName
        // `.set` 必须有时间值；列缺失 / 空值时按 absent 处理，不造 epoch 假值。
        let markedAtPatch: Patch<Date>
        switch row.text("marked_at_patch") ?? "absent" {
        case "clear":
            markedAtPatch = .clear
        case "set":
            markedAtPatch = markedAt.map(Patch<Date>.set) ?? .absent
        default:
            markedAtPatch = .absent
        }

        return SavedDevice(
            id: id,
            peripheralID: peripheralID,
            platform: row.text("platform") ?? SavedDevice.iosPlatform,
            externalID: row.text("external_id"),
            advertisedName: advertisedName,
            remark: remark,
            groupName: groupName,
            roomID: row.text("room_id").flatMap(UUID.init(uuidString:)),
            householdID: row.text("household_id").flatMap(UUID.init(uuidString:)),
            remoteRoomID: row.text("remote_room_id"),
            remoteHouseholdID: row.text("remote_household_id"),
            mac: row.text("mac"),
            vendor: row.text("vendor"),
            deviceType: row.text("device_type"),
            firmwareVersion: row.text("firmware_version"),
            lastSeenAt: lastSeenAt,
            serverLastSeenAt: serverLastSeenAt,
            markedAt: markedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            syncState: syncState,
            aliasPatch: Patch.restored(row.text("alias_patch"), value: remark),
            advertisedNamePatch: Patch.restored(row.text("advertised_name_patch"), value: advertisedName),
            groupPatch: Patch.restored(row.text("group_patch"), value: groupName),
            markedAtPatch: markedAtPatch
        )
    }
}
