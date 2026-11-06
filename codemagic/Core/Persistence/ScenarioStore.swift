import Foundation

/// 场景存储：仅本机 SQLite 表，无 sync_state，不参与云端同步。
/// v14 之后同表还存放服务端场景（`kind = automation`），这里只读 `manual` 行。
final class ScenarioStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func fetchAll() throws -> [Scenario] {
        let rows = try database.query(
            "SELECT * FROM scenarios WHERE kind = 'manual' AND deleted_at IS NULL ORDER BY created_at ASC;"
        )
        return rows.compactMap(Self.makeScenario)
    }

    func upsert(_ scenario: Scenario) throws {
        let payload = try JSONEncoder().encode(scenario.actions)
        let json = String(data: payload, encoding: .utf8) ?? "[]"
        // 用 UPDATE 再 INSERT，避免 INSERT OR REPLACE 把 v14 新增的同步列重置为默认值。
        try database.execute(
            """
            UPDATE scenarios SET name = ?, actions = ?, updated_at = ?
            WHERE id = ? AND kind = 'manual';
            """,
            [
                .text(scenario.name),
                .text(json),
                .double(scenario.updatedAt.timeIntervalSince1970),
                .text(scenario.id.uuidString),
            ]
        )
        try database.execute(
            """
            INSERT OR IGNORE INTO scenarios
            (id, kind, name, actions, created_at, updated_at, enabled, cooldown_seconds, sync_state)
            VALUES (?, 'manual', ?, ?, ?, ?, 1, 0, 'localOnly');
            """,
            [
                .text(scenario.id.uuidString),
                .text(scenario.name),
                .text(json),
                .double(scenario.createdAt.timeIntervalSince1970),
                .double(scenario.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    func delete(id: UUID) throws {
        try database.execute(
            "DELETE FROM scenarios WHERE id = ? AND kind = 'manual';",
            [.text(id.uuidString)]
        )
    }

    private static func makeScenario(from row: SQLRow) -> Scenario? {
        guard let idText = row.text("id"), let id = UUID(uuidString: idText) else { return nil }
        let actions: [ScenarioAction]
        if let json = row.text("actions"),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ScenarioAction].self, from: data) {
            actions = decoded
        } else {
            actions = []
        }
        return Scenario(
            id: id,
            name: row.text("name") ?? "",
            actions: actions,
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
        )
    }
}

// MARK: - Codable

extension ScenarioAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, deviceID, minutes
    }

    private enum Kind: String, Codable {
        case connectDevice, disconnectDevice, startBackgroundCollection
        case stopBackgroundCollection, muteAlerts, syncNow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .connectDevice:
            self = .connectDevice(try container.decode(UUID.self, forKey: .deviceID))
        case .disconnectDevice:
            self = .disconnectDevice(try container.decode(UUID.self, forKey: .deviceID))
        case .startBackgroundCollection:
            self = .startBackgroundCollection
        case .stopBackgroundCollection:
            self = .stopBackgroundCollection
        case .muteAlerts:
            self = .muteAlerts(minutes: try container.decode(Int.self, forKey: .minutes))
        case .syncNow:
            self = .syncNow
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connectDevice(let id):
            try container.encode(Kind.connectDevice, forKey: .kind)
            try container.encode(id, forKey: .deviceID)
        case .disconnectDevice(let id):
            try container.encode(Kind.disconnectDevice, forKey: .kind)
            try container.encode(id, forKey: .deviceID)
        case .startBackgroundCollection:
            try container.encode(Kind.startBackgroundCollection, forKey: .kind)
        case .stopBackgroundCollection:
            try container.encode(Kind.stopBackgroundCollection, forKey: .kind)
        case .muteAlerts(let minutes):
            try container.encode(Kind.muteAlerts, forKey: .kind)
            try container.encode(minutes, forKey: .minutes)
        case .syncNow:
            try container.encode(Kind.syncNow, forKey: .kind)
        }
    }
}
