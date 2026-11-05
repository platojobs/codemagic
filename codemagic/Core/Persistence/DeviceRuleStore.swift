import Foundation

/// 本地规则的数据访问层。
final class DeviceRuleStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func fetchAll() throws -> [DeviceRule] {
        let rows = try database.query(
            "SELECT * FROM rules WHERE deleted_at IS NULL ORDER BY created_at ASC;"
        )
        return rows.compactMap(Self.makeRule)
    }

    func upsert(_ rule: DeviceRule) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO rules
            (id, name, trigger, threshold, metric, comparison, reading_threshold, consecutive,
             device_id, is_enabled, created_at, updated_at, deleted_at, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(rule.id.uuidString),
                .text(rule.name),
                .text(rule.trigger.rawValue),
                .integer(Int64(rule.threshold)),
                rule.metric.map { .text($0.rawValue) } ?? .null,
                .text(rule.comparison.rawValue),
                .double(rule.readingThreshold),
                .integer(Int64(rule.consecutive)),
                rule.deviceID.map { .text($0.uuidString) } ?? .null,
                .integer(rule.isEnabled ? 1 : 0),
                .double(rule.createdAt.timeIntervalSince1970),
                .double(rule.updatedAt.timeIntervalSince1970),
                rule.deletedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(rule.syncState.rawValue),
            ]
        )
    }

    func softDelete(id: UUID, at date: Date = Date()) throws {
        try database.execute(
            """
            UPDATE rules SET deleted_at = ?, updated_at = ?, sync_state = ? WHERE id = ?;
            """,
            [
                .double(date.timeIntervalSince1970),
                .double(date.timeIntervalSince1970),
                .text(SyncState.pendingDelete.rawValue),
                .text(id.uuidString),
            ]
        )
    }

    private static func makeRule(from row: SQLRow) -> DeviceRule? {
        guard let idText = row.text("id"), let id = UUID(uuidString: idText) else { return nil }

        let createdAt = Date(timeIntervalSince1970: row.double("created_at") ?? 0)
        let updatedAt = Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
        let deletedAt = row.double("deleted_at").map(Date.init(timeIntervalSince1970:))

        return DeviceRule(
            id: id,
            name: row.text("name") ?? "",
            trigger: RuleTrigger(rawValue: row.text("trigger") ?? "") ?? .disconnect,
            threshold: Int(row.integer("threshold") ?? -80),
            metric: row.text("metric").flatMap(ReadingMetric.init(rawValue:)),
            comparison: RuleComparison(rawValue: row.text("comparison") ?? "") ?? .lessOrEqual,
            readingThreshold: row.double("reading_threshold") ?? 0,
            consecutive: Int(row.integer("consecutive") ?? 1),
            deviceID: row.text("device_id").flatMap(UUID.init(uuidString:)),
            isEnabled: row.bool("is_enabled"),
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            syncState: SyncState(rawValue: row.text("sync_state") ?? "") ?? .pending
        )
    }
}
