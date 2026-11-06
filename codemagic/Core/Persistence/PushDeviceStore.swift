import Foundation

/// 推送设备注册状态。`missingToken` 表示本机拿不到真实 APNs token（未配置证书 /
/// entitlement），此时不会向服务端注册任何占位令牌。
enum PushDeviceStatus: String, Equatable {
    case noSession
    case missingToken
    case pending
    case registered
    case rejected
    case unauthorized
    case deactivated
}

/// 本机唯一的推送注册记录（单行 `id = current`）。
struct PushDeviceRecord: Equatable {
    var token: String?
    var remoteDeviceID: String?
    var platform: String
    var status: PushDeviceStatus
    var lastError: String?
    var attempts: Int
    var nextRetryAt: Date?
    var updatedAt: Date

    static func empty(at date: Date) -> PushDeviceRecord {
        PushDeviceRecord(
            token: nil,
            remoteDeviceID: nil,
            platform: "ios",
            status: .missingToken,
            lastError: nil,
            attempts: 0,
            nextRetryAt: nil,
            updatedAt: date
        )
    }
}

/// 推送注册记录读写协议：生产用 SQLite，测试可替换为内存实现。
protocol PushDeviceStoring: AnyObject {
    func load() -> PushDeviceRecord?
    func save(_ record: PushDeviceRecord)
    func clear()
}

/// SQLite 持久化（迁移 v16）。与其它业务表共用生命周期，注销账号时一起清空。
final class PushDeviceStore: PushDeviceStoring {
    private static let rowID = "current"

    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func load() -> PushDeviceRecord? {
        guard let rows = try? database.query(
            """
            SELECT token, remote_device_id, platform, status, last_error, attempts,
                   next_retry_at, updated_at
            FROM push_devices WHERE id = ? LIMIT 1;
            """,
            [.text(Self.rowID)]
        ), let row = rows.first else {
            return nil
        }
        let status = PushDeviceStatus(rawValue: row.text("status") ?? "") ?? .missingToken
        return PushDeviceRecord(
            token: row.text("token").flatMap { $0.isEmpty ? nil : $0 },
            remoteDeviceID: row.text("remote_device_id").flatMap { $0.isEmpty ? nil : $0 },
            platform: row.text("platform") ?? "ios",
            status: status,
            lastError: row.text("last_error").flatMap { $0.isEmpty ? nil : $0 },
            attempts: Int(row.integer("attempts") ?? 0),
            nextRetryAt: row.double("next_retry_at").map(Date.init(timeIntervalSince1970:)),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
        )
    }

    func save(_ record: PushDeviceRecord) {
        let now = record.updatedAt.timeIntervalSince1970
        try? database.execute(
            """
            INSERT INTO push_devices
                (id, token, remote_device_id, platform, status, last_error,
                 attempts, next_retry_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                token = excluded.token,
                remote_device_id = excluded.remote_device_id,
                platform = excluded.platform,
                status = excluded.status,
                last_error = excluded.last_error,
                attempts = excluded.attempts,
                next_retry_at = excluded.next_retry_at,
                updated_at = excluded.updated_at;
            """,
            [
                .text(Self.rowID),
                record.token.map(SQLValue.text) ?? .null,
                record.remoteDeviceID.map(SQLValue.text) ?? .null,
                .text(record.platform),
                .text(record.status.rawValue),
                record.lastError.map(SQLValue.text) ?? .null,
                .integer(Int64(record.attempts)),
                record.nextRetryAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .double(now),
                .double(now)
            ]
        )
    }

    func clear() {
        try? database.execute("DELETE FROM push_devices WHERE id = ?;", [.text(Self.rowID)])
    }
}
