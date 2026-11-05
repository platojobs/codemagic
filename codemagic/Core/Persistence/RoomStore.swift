import Foundation

/// 房间同步状态：`local` 仅本机（从未上报）、`pending` 有待重试的服务端写入、`synced` 与服务端一致。
enum RoomSyncState: String {
    case local
    case pending
    case synced

    var isSynced: Bool { self == .synced }
}

/// 房间：已接入家庭后以服务端为准；`remoteID` 与 `householdID` 建立本地 / 远端映射。
/// 未接入家庭或离线时保持 `local / pending`，本机数据不丢。
struct Room: Identifiable, Equatable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var remoteID: String?
    var householdID: UUID?
    var syncState: RoomSyncState
    var isDeleted: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int,
        remoteID: String? = nil,
        householdID: UUID? = nil,
        syncState: RoomSyncState = .local,
        isDeleted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.remoteID = remoteID
        self.householdID = householdID
        self.syncState = syncState
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 房间存储：CRUD 与排序；删除房间时把房内设备回到「未分配」。
/// 家居接入后 `syncState` 由 `HouseholdService` 维护，本层只负责持久化。
final class RoomStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    /// 默认只返回未删除房间；传 `householdID` 时按家庭过滤（`nil` 保留全部）。
    func fetchAll(householdID: UUID? = nil) throws -> [Room] {
        let rows: [SQLRow]
        if let householdID {
            rows = try database.query(
                """
                SELECT * FROM rooms WHERE deleted = 0 AND household_id = ?
                ORDER BY sort_order ASC, created_at ASC;
                """,
                [.text(householdID.uuidString)]
            )
        } else {
            rows = try database.query(
                "SELECT * FROM rooms WHERE deleted = 0 ORDER BY sort_order ASC, created_at ASC;"
            )
        }
        return rows.compactMap(Self.makeRoom)
    }

    func fetch(id: UUID) throws -> Room? {
        try database.query("SELECT * FROM rooms WHERE id = ?;", [.text(id.uuidString)]
        ).compactMap(Self.makeRoom).first
    }

    func fetch(remoteID: String) throws -> Room? {
        try database.query("SELECT * FROM rooms WHERE remote_id = ?;", [.text(remoteID)]
        ).compactMap(Self.makeRoom).first
    }

    /// 尚未获知远端 id 的本地房间（含离线新建 / 待重试）。
    func localRooms(householdID: UUID) throws -> [Room] {
        try database.query(
            """
            SELECT * FROM rooms WHERE deleted = 0 AND household_id = ?
              AND (remote_id IS NULL OR remote_id = '') AND sync_state != 'synced'
            ORDER BY sort_order ASC, created_at ASC;
            """,
            [.text(householdID.uuidString)]
        ).compactMap(Self.makeRoom)
    }

    /// 尚未归属任何家庭的本机房间（用于首次接入家庭时认领）。
    func unclaimedRooms() throws -> [Room] {
        try database.query(
            "SELECT * FROM rooms WHERE deleted = 0 AND household_id IS NULL ORDER BY sort_order ASC, created_at ASC;"
        ).compactMap(Self.makeRoom)
    }

    func pendingRooms(householdID: UUID) throws -> [Room] {
        try database.query(
            """
            SELECT * FROM rooms WHERE household_id = ? AND sync_state = 'pending' AND deleted = 0
            ORDER BY sort_order ASC, created_at ASC;
            """,
            [.text(householdID.uuidString)]
        ).compactMap(Self.makeRoom)
    }

    /// 离线删除的墓碑房间（`deleted = 1`），联网后重试删除。
    func fetchDeleted(householdID: UUID) throws -> [Room] {
        try database.query(
            "SELECT * FROM rooms WHERE household_id = ? AND deleted = 1;",
            [.text(householdID.uuidString)]
        ).compactMap(Self.makeRoom)
    }

    /// 家庭已不存在（被删除 / 换号）：房间脱钩为未归属，保留本机数据。
    func clearHousehold(householdID: UUID) throws {
        try database.execute(
            "UPDATE rooms SET household_id = NULL, sync_state = 'local' WHERE household_id = ?;",
            [.text(householdID.uuidString)]
        )
    }

    /// 新建房间，排序追加到当前家庭末尾。
    @discardableResult
    func create(
        name: String,
        at date: Date = Date(),
        householdID: UUID? = nil,
        syncState: RoomSyncState = .local
    ) throws -> Room {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxOrder: Int64
        if let householdID {
            maxOrder = try database.query(
                "SELECT MAX(sort_order) AS max_order FROM rooms WHERE household_id = ?;",
                [.text(householdID.uuidString)]
            ).first?.integer("max_order") ?? 0
        } else {
            maxOrder = try database.query("SELECT MAX(sort_order) AS max_order FROM rooms;", [])
                .first?.integer("max_order") ?? 0
        }
        let room = Room(
            name: trimmed,
            sortOrder: Int(maxOrder) + 1,
            householdID: householdID,
            syncState: syncState,
            createdAt: date,
            updatedAt: date
        )
        try upsert(room)
        return room
    }

    func upsert(_ room: Room) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO rooms
            (id, name, sort_order, remote_id, household_id, sync_state, deleted, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(room.id.uuidString),
                .text(room.name),
                .integer(Int64(room.sortOrder)),
                room.remoteID.map(SQLValue.text) ?? .null,
                room.householdID.map { .text($0.uuidString) } ?? .null,
                .text(room.syncState.rawValue),
                .integer(room.isDeleted ? 1 : 0),
                .double(room.createdAt.timeIntervalSince1970),
                .double(room.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    func rename(id: UUID, name: String, at date: Date = Date()) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.execute(
            "UPDATE rooms SET name = ?, updated_at = ? WHERE id = ?;",
            [.text(trimmed), .double(date.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    /// 服务端改名成功后的本地落库，不改变 `sync_state`。
    func applyRemote(id: UUID, remoteID: String, name: String, sortOrder: Int, at date: Date = Date()) throws {
        try database.execute(
            """
            UPDATE rooms SET name = ?, sort_order = ?, remote_id = ?, sync_state = 'synced', deleted = 0, updated_at = ?
            WHERE id = ?;
            """,
            [
                .text(name),
                .integer(Int64(sortOrder)),
                .text(remoteID),
                .double(date.timeIntervalSince1970),
                .text(id.uuidString),
            ]
        )
    }

    func setSyncState(id: UUID, syncState: RoomSyncState, at date: Date = Date()) throws {
        try database.execute(
            "UPDATE rooms SET sync_state = ?, updated_at = ? WHERE id = ?;",
            [.text(syncState.rawValue), .double(date.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    func claim(id: UUID, householdID: UUID) throws {
        try database.execute(
            "UPDATE rooms SET household_id = ? WHERE id = ? AND household_id IS NULL;",
            [.text(householdID.uuidString), .text(id.uuidString)]
        )
    }

    /// 删除房间并把房内设备置回未分配（`room_id = NULL`），不删除设备本身。
    func delete(id: UUID, deviceStore: SavedDeviceStore) throws {
        let devices = try deviceStore.fetchAll().filter { $0.roomID == id }
        for device in devices {
            try deviceStore.setRoom(id: device.id, roomID: nil)
        }
        try database.execute("DELETE FROM rooms WHERE id = ?;", [.text(id.uuidString)])
    }

    /// 离线删除：先打墓碑，等下次同步成功后物理删除。
    func markDeleted(id: UUID, at date: Date = Date()) throws {
        try database.execute(
            "UPDATE rooms SET deleted = 1, sync_state = 'pending', updated_at = ? WHERE id = ?;",
            [.double(date.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    func purge(id: UUID) throws {
        try database.execute("DELETE FROM rooms WHERE id = ?;", [.text(id.uuidString)])
    }

    func deviceCounts(householdID: UUID? = nil) throws -> [UUID: Int] {
        let rows: [SQLRow]
        if let householdID {
            rows = try database.query(
                """
                SELECT room_id, COUNT(*) AS total FROM saved_devices
                WHERE room_id IS NOT NULL AND deleted_at IS NULL AND household_id = ?
                GROUP BY room_id;
                """,
                [.text(householdID.uuidString)]
            )
        } else {
            rows = try database.query(
                """
                SELECT room_id, COUNT(*) AS total FROM saved_devices
                WHERE room_id IS NOT NULL AND deleted_at IS NULL
                GROUP BY room_id;
                """
            )
        }
        var counts: [UUID: Int] = [:]
        for row in rows {
            guard let text = row.text("room_id"), let id = UUID(uuidString: text) else { continue }
            counts[id] = Int(row.integer("total") ?? 0)
        }
        return counts
    }

    private static func makeRoom(from row: SQLRow) -> Room? {
        guard let idText = row.text("id"), let id = UUID(uuidString: idText) else { return nil }
        let householdID = row.text("household_id").flatMap(UUID.init(uuidString:))
        return Room(
            id: id,
            name: row.text("name") ?? "",
            sortOrder: Int(row.integer("sort_order") ?? 0),
            remoteID: row.text("remote_id"),
            householdID: householdID,
            syncState: RoomSyncState(rawValue: row.text("sync_state") ?? "local") ?? .local,
            isDeleted: row.bool("deleted"),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
        )
    }
}
