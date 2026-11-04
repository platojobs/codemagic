import Foundation

/// 本地扫描日志的数据访问层。
final class ScanLogStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    /// 按时间倒序返回最近日志。
    func fetchRecent(limit: Int = 100) throws -> [ScanLogEntry] {
        let rows = try database.query(
            """
            SELECT * FROM scan_logs WHERE deleted_at IS NULL
            ORDER BY occurred_at DESC LIMIT ?;
            """,
            [.integer(Int64(limit))]
        )
        return rows.compactMap(Self.makeEntry)
    }

    func count() throws -> Int {
        let rows = try database.query(
            "SELECT COUNT(*) AS total FROM scan_logs WHERE deleted_at IS NULL;"
        )
        return Int(rows.first?.integer("total") ?? 0)
    }

    func append(_ entry: ScanLogEntry) throws {
        try database.execute(
            """
            INSERT INTO scan_logs
            (id, occurred_at, category, level, message, updated_at, deleted_at, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(entry.id.uuidString),
                .double(entry.occurredAt.timeIntervalSince1970),
                .text(entry.category.rawValue),
                .text(entry.level.rawValue),
                .text(entry.message),
                .double(entry.updatedAt.timeIntervalSince1970),
                entry.deletedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(entry.syncState.rawValue),
            ]
        )
    }

    /// 清空日志：软删除全部可见记录，等待同步删除。
    func softDeleteAll(at date: Date = Date()) throws {
        try database.execute(
            """
            UPDATE scan_logs
            SET deleted_at = ?, updated_at = ?, sync_state = ?
            WHERE deleted_at IS NULL;
            """,
            [
                .double(date.timeIntervalSince1970),
                .double(date.timeIntervalSince1970),
                .text(SyncState.pendingDelete.rawValue),
            ]
        )
    }

    private static func makeEntry(from row: SQLRow) -> ScanLogEntry? {
        guard let idText = row.text("id"), let id = UUID(uuidString: idText) else { return nil }
        let occurredAt = Date(timeIntervalSince1970: row.double("occurred_at") ?? 0)
        let updatedAt = Date(timeIntervalSince1970: row.double("updated_at") ?? 0)

        return ScanLogEntry(
            id: id,
            occurredAt: occurredAt,
            category: ScanLogCategory(rawValue: row.text("category") ?? "") ?? .session,
            level: ScanLogLevel(rawValue: row.text("level") ?? "") ?? .info,
            message: row.text("message") ?? "",
            updatedAt: updatedAt,
            deletedAt: row.double("deleted_at").map(Date.init(timeIntervalSince1970:)),
            syncState: SyncState(rawValue: row.text("sync_state") ?? "") ?? .pending
        )
    }
}
