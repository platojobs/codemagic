import Foundation

/// 房间：仅本机数据，不参与 `push` / `changes`。`remoteID` 预留给后端家庭 / 房间接口，
/// 本地 id 与远端 id 的映射通过该字段完成，后续接入时无需变更表结构。
struct Room: Identifiable, Equatable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var remoteID: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int,
        remoteID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.remoteID = remoteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 房间存储：CRUD 与排序；删除房间时把房内设备回到「未分配」。
final class RoomStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func fetchAll() throws -> [Room] {
        try database.query(
            "SELECT * FROM rooms ORDER BY sort_order ASC, created_at ASC;"
        ).compactMap(Self.makeRoom)
    }

    /// 新建房间，排序追加到末尾。
    @discardableResult
    func create(name: String, at date: Date = Date()) throws -> Room {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxOrder = try database.query("SELECT MAX(sort_order) AS max_order FROM rooms;", [])
            .first?.integer("max_order") ?? 0
        let room = Room(name: trimmed, sortOrder: Int(maxOrder) + 1, createdAt: date, updatedAt: date)
        try upsert(room)
        return room
    }

    func upsert(_ room: Room) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO rooms
            (id, name, sort_order, remote_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [
                .text(room.id.uuidString),
                .text(room.name),
                .integer(Int64(room.sortOrder)),
                room.remoteID.map(SQLValue.text) ?? .null,
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

    /// 删除房间并把房内设备置回未分配（`room_id = NULL`），不删除设备本身。
    func delete(id: UUID, deviceStore: SavedDeviceStore) throws {
        let devices = try deviceStore.fetchAll().filter { $0.roomID == id }
        for device in devices {
            try deviceStore.setRoom(id: device.id, roomID: nil)
        }
        try database.execute("DELETE FROM rooms WHERE id = ?;", [.text(id.uuidString)])
    }

    func deviceCounts() throws -> [UUID: Int] {
        let rows = try database.query(
            """
            SELECT room_id, COUNT(*) AS total FROM saved_devices
            WHERE room_id IS NOT NULL AND deleted_at IS NULL
            GROUP BY room_id;
            """
        )
        var counts: [UUID: Int] = [:]
        for row in rows {
            guard let text = row.text("room_id"), let id = UUID(uuidString: text) else { continue }
            counts[id] = Int(row.integer("total") ?? 0)
        }
        return counts
    }

    private static func makeRoom(from row: SQLRow) -> Room? {
        guard let idText = row.text("id"), let id = UUID(uuidString: idText) else { return nil }
        return Room(
            id: id,
            name: row.text("name") ?? "",
            sortOrder: Int(row.integer("sort_order") ?? 0),
            remoteID: row.text("remote_id"),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
        )
    }
}
