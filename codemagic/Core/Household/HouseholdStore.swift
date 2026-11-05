import Foundation

/// 家庭快照存储。家庭只来自服务端，本地不新建；离线时保留上次快照供界面展示。
final class HouseholdStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func fetchAll() throws -> [Household] {
        try database.query(
            "SELECT * FROM households ORDER BY is_personal DESC, created_at ASC;"
        ).compactMap(Self.makeHousehold)
    }

    func fetch(localID: UUID) throws -> Household? {
        try database.query("SELECT * FROM households WHERE id = ? LIMIT 1;", [.text(localID.uuidString)]
        ).compactMap(Self.makeHousehold).first
    }

    func fetch(remoteID: String) throws -> Household? {
        try database.query("SELECT * FROM households WHERE remote_id = ? LIMIT 1;", [.text(remoteID)]
        ).compactMap(Self.makeHousehold).first
    }

    func localID(forRemoteID remoteID: String?) -> UUID? {
        guard let remoteID, !remoteID.isEmpty else { return nil }
        return (try? fetch(remoteID: remoteID))?.id
    }

    func upsert(_ household: Household) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO households
            (id, remote_id, name, is_personal, role, member_count, device_count, room_count, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(household.id.uuidString),
                .text(household.remoteID),
                .text(household.name),
                .integer(household.isPersonal ? 1 : 0),
                .text(household.role.rawValue),
                .integer(Int64(household.memberCount)),
                .integer(Int64(household.deviceCount)),
                .integer(Int64(household.roomCount)),
                .double(household.createdAt.timeIntervalSince1970),
                .double(household.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    /// 服务端列表落库：更新或插入，但不删除本地已有家庭，避免离线时界面清空。
    func merge(_ households: [Household]) throws {
        for household in households {
            try upsert(household)
        }
    }

    func delete(localID: UUID) throws {
        try database.execute("DELETE FROM households WHERE id = ?;", [.text(localID.uuidString)])
    }

    /// 服务端列表已不含家庭：删除本地快照并返回被移除的家庭，由调用方把其房间脱钩保留。
    func prune(keepingRemoteIDs remoteIDs: Set<String>) throws -> [Household] {
        let stale = try fetchAll().filter { !remoteIDs.contains($0.remoteID) }
        for household in stale {
            try delete(localID: household.id)
        }
        return stale
    }

    private static func makeHousehold(from row: SQLRow) -> Household? {
        guard let idText = row.text("id"),
              let id = UUID(uuidString: idText),
              let remoteID = row.text("remote_id"), !remoteID.isEmpty
        else { return nil }
        return Household(
            id: id,
            remoteID: remoteID,
            name: row.text("name") ?? "",
            isPersonal: row.bool("is_personal"),
            role: HouseholdRole(rawValue: row.text("role") ?? "member") ?? .member,
            memberCount: Int(row.integer("member_count") ?? 0),
            deviceCount: Int(row.integer("device_count") ?? 0),
            roomCount: Int(row.integer("room_count") ?? 0),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
        )
    }
}

/// 待上报的设备归属队列。`roomRemoteID` / `householdRemoteID` 为空串时表示显式清除。
final class DeviceAssignmentPendingStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func fetchAll() throws -> [PendingDeviceAssignment] {
        try database.query(
            "SELECT * FROM device_assignment_pending ORDER BY updated_at ASC;"
        ).compactMap(Self.makeEntry)
    }

    func upsert(_ entry: PendingDeviceAssignment) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO device_assignment_pending
            (device_id, platform, external_id, room_remote_id, household_remote_id, attempts, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(entry.deviceID.uuidString),
                .text(entry.platform),
                .text(entry.externalID),
                .text(entry.roomRemoteID),
                .text(entry.householdRemoteID),
                .integer(Int64(entry.attempts)),
                .double(entry.createdAt.timeIntervalSince1970),
                .double(entry.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    func remove(deviceID: UUID) throws {
        try database.execute(
            "DELETE FROM device_assignment_pending WHERE device_id = ?;",
            [.text(deviceID.uuidString)]
        )
    }

    func removeAll() throws {
        try database.execute("DELETE FROM device_assignment_pending;", [])
    }

    func pendingCount() throws -> Int {
        let rows = try database.query("SELECT COUNT(*) AS total FROM device_assignment_pending;", [])
        return Int(rows.first?.integer("total") ?? 0)
    }

    private static func makeEntry(from row: SQLRow) -> PendingDeviceAssignment? {
        guard let idText = row.text("device_id"), let deviceID = UUID(uuidString: idText),
              let platform = row.text("platform"), let externalID = row.text("external_id")
        else { return nil }
        return PendingDeviceAssignment(
            deviceID: deviceID,
            platform: platform,
            externalID: externalID,
            roomRemoteID: row.text("room_remote_id") ?? "",
            householdRemoteID: row.text("household_remote_id") ?? "",
            attempts: Int(row.integer("attempts") ?? 0),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
        )
    }
}
