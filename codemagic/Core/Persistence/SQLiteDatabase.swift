import Foundation
import SQLite3

/// 一个 SQL 参数值。
enum SQLValue {
    case text(String)
    case integer(Int64)
    case double(Double)
    case null
}

/// 一条查询结果，按列名取值。
struct SQLRow {
    fileprivate let storage: [String: SQLValue]

    func text(_ column: String) -> String? {
        if case .text(let value) = storage[column] { return value }
        return nil
    }

    func double(_ column: String) -> Double? {
        switch storage[column] {
        case .double(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    func integer(_ column: String) -> Int64? {
        switch storage[column] {
        case .integer(let value): return value
        case .double(let value): return Int64(value)
        default: return nil
        }
    }

    func bool(_ column: String) -> Bool {
        (integer(column) ?? 0) != 0
    }
}

/// 轻量 SQLite 封装。
///
/// 选择 SQLite 而不是 Core Data 的理由写在 `README.md` 与 `docs/architecture.md`：
/// 同步字段（id / updatedAt / deletedAt / syncState）需要精确控制，schema 以 SQL 明示，
/// 不依赖 `.xcdatamodeld` 编辑器，便于 CI 与 Android 端字段对照。
final class SQLiteDatabase {
    // MARK: - Properties

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.platojobs.codemagic.sqlite")

    // MARK: - Init

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if handle != nil {
                sqlite3_close(handle)
                handle = nil
            }
            throw AppError.database("打开数据库失败：\(message)")
        }

        try execute("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    /// 显式关闭连接；主要用于测试在删除临时数据库文件前释放句柄。
    func close() {
        queue.sync {
            if let handle {
                sqlite3_close(handle)
                self.handle = nil
            }
        }
    }

    // MARK: - Public

    func execute(_ sql: String, _ parameters: [SQLValue] = []) throws {
        try queue.sync {
            try performExecute(sql, parameters)
        }
    }

    func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [SQLRow] {
        try queue.sync {
            try performQuery(sql, parameters)
        }
    }

    // MARK: - Migration

    private func migrate() throws {
        let version = try currentUserVersion()
        if version < 1 {
            try migrateToVersion1()
        }
        if version < 2 {
            try migrateToVersion2()
        }
        if version < 3 {
            try migrateToVersion3()
        }
        if version < 4 {
            try migrateToVersion4()
        }
        if version < 5 {
            try migrateToVersion5()
        }
    }

    /// v1：五张业务表，均含 `id / updated_at / deleted_at / sync_state`。
    private func migrateToVersion1() throws {
        try executeScript("""
        CREATE TABLE IF NOT EXISTS saved_devices (
            id TEXT PRIMARY KEY NOT NULL,
            peripheral_id TEXT NOT NULL,
            name TEXT NOT NULL,
            remark TEXT NOT NULL DEFAULT '',
            group_name TEXT NOT NULL DEFAULT '未分组',
            mac TEXT,
            vendor TEXT,
            firmware_version TEXT,
            last_seen_at REAL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            sync_state TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_saved_devices_peripheral
            ON saved_devices(peripheral_id) WHERE deleted_at IS NULL;

        CREATE TABLE IF NOT EXISTS rules (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            trigger TEXT NOT NULL,
            threshold INTEGER NOT NULL,
            device_id TEXT,
            is_enabled INTEGER NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            sync_state TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS scan_logs (
            id TEXT PRIMARY KEY NOT NULL,
            occurred_at REAL NOT NULL,
            category TEXT NOT NULL,
            level TEXT NOT NULL,
            message TEXT NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            sync_state TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_scan_logs_occurred ON scan_logs(occurred_at DESC);

        CREATE TABLE IF NOT EXISTS recent_devices (
            peripheral_id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            rssi INTEGER NOT NULL,
            last_seen_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            sync_state TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS device_info_cache (
            peripheral_id TEXT PRIMARY KEY NOT NULL,
            payload TEXT NOT NULL,
            fetched_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            sync_state TEXT NOT NULL
        );

        PRAGMA user_version = 1;
        """)
    }

    /// v2：补齐服务端设备唯一键 `(platform, externalId)`。
    /// - 新增列后立即用 `peripheral_id` 回填，保证旧数据也能参与同步；
    /// - 唯一索引限定 `deleted_at IS NULL`，tombstone 与同名新记录可以并存。
    private func migrateToVersion2() throws {
        try executeScript("""
        ALTER TABLE saved_devices ADD COLUMN platform TEXT NOT NULL DEFAULT 'ios';
        ALTER TABLE saved_devices ADD COLUMN external_id TEXT NOT NULL DEFAULT '';
        UPDATE saved_devices SET external_id = UPPER(peripheral_id) WHERE external_id = '';
        CREATE UNIQUE INDEX IF NOT EXISTS idx_saved_devices_sync_key
            ON saved_devices(platform, external_id) WHERE deleted_at IS NULL;
        PRAGMA user_version = 2;
        """)
    }

    /// v3：记录从云端详情拿到的型号，供推送 `PushDevice.deviceType` 使用。
    /// 可为空；无法从 catalog 匹配时保持 NULL，不填假值。
    private func migrateToVersion3() throws {
        try executeScript("""
        ALTER TABLE saved_devices ADD COLUMN device_type TEXT;
        PRAGMA user_version = 3;
        """)
    }

    /// v4：区分「用户别名」与「设备广播名」，并记录待上报字段的三态。
    /// - `advertised_name`：扫描得到的广播名，由 v4 之前用于展示的 `name` 列回填；
    ///   `name` 列保留并与 `advertised_name` 同值写入，避免降级版本读到空名称；
    /// - `*_patch`：`absent` / `clear` / `set`，与 openapi 0.3.3 的缺省字段语义一一对应。
    private func migrateToVersion4() throws {
        try executeScript("""
        ALTER TABLE saved_devices ADD COLUMN advertised_name TEXT NOT NULL DEFAULT '';
        UPDATE saved_devices SET advertised_name = name WHERE advertised_name = '';
        ALTER TABLE saved_devices ADD COLUMN alias_patch TEXT NOT NULL DEFAULT 'absent';
        ALTER TABLE saved_devices ADD COLUMN advertised_name_patch TEXT NOT NULL DEFAULT 'absent';
        ALTER TABLE saved_devices ADD COLUMN group_patch TEXT NOT NULL DEFAULT 'absent';
        PRAGMA user_version = 4;
        """)
    }

    /// v5：读数表。`id` 为客户端 UUID，推送时作为幂等主键；
    /// `sync_state` 复用全局同步状态，`recorded_at` 以 Unix 秒存储，索引支持
    /// 「按设备 + 指标取最近 60 点」与 7 天清理。
    private func migrateToVersion5() throws {
        try executeScript("""
        CREATE TABLE IF NOT EXISTS readings (
            id TEXT PRIMARY KEY NOT NULL,
            device_id TEXT NOT NULL,
            metric TEXT NOT NULL,
            value REAL NOT NULL,
            unit TEXT NOT NULL,
            recorded_at REAL NOT NULL,
            sync_state TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_readings_device_metric_time
            ON readings(device_id, metric, recorded_at DESC);
        CREATE INDEX IF NOT EXISTS idx_readings_sync_state
            ON readings(sync_state, recorded_at);
        PRAGMA user_version = 5;
        """)
    }

    private func currentUserVersion() throws -> Int {
        let rows = try performQuery("PRAGMA user_version;", [])
        return Int(rows.first?.integer("user_version") ?? 0)
    }

    /// 迁移脚本包含多条语句，必须用 sqlite3_exec 一次性执行；
    /// sqlite3_prepare_v2 只会预处理第一条语句。
    private func executeScript(_ script: String) throws {
        guard let handle else { throw AppError.database("数据库已关闭") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, script, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw AppError.database("迁移失败：\(message)")
        }
    }

    // MARK: - Private

    private func performExecute(_ sql: String, _ parameters: [SQLValue]) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw AppError.database("执行失败：\(errorMessage)")
        }
    }

    private func performQuery(_ sql: String, _ parameters: [SQLValue]) throws -> [SQLRow] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var rows: [SQLRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columnCount = Int(sqlite3_column_count(statement))
            var storage: [String: SQLValue] = [:]
            for index in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, Int32(index)))
                switch sqlite3_column_type(statement, Int32(index)) {
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, Int32(index)) {
                        storage[name] = .text(String(cString: text))
                    } else {
                        storage[name] = .null
                    }
                case SQLITE_INTEGER:
                    storage[name] = .integer(sqlite3_column_int64(statement, Int32(index)))
                case SQLITE_FLOAT:
                    storage[name] = .double(sqlite3_column_double(statement, Int32(index)))
                default:
                    storage[name] = .null
                }
            }
            rows.append(SQLRow(storage: storage))
        }
        return rows
    }

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer {
        guard let handle else {
            throw AppError.database("数据库已关闭")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AppError.database("SQL 预处理失败：\(errorMessage)")
        }

        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            switch parameter {
            case .text(let value):
                sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
            case .integer(let value):
                sqlite3_bind_int64(statement, position, value)
            case .double(let value):
                sqlite3_bind_double(statement, position, value)
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private var errorMessage: String {
        guard let handle else { return "数据库已关闭" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

/// SQLite 要求传入持久化析构标记，Swift 中用 -1 的位模式表达 SQLITE_TRANSIENT。
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
