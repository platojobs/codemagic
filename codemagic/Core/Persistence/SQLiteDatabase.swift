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

    /// 注销账号：清空全部业务表，保留表结构与 schema 版本。非业务设置仍由 UserDefaults 持有。
    func resetBusinessData() throws {
        try queue.sync {
            let tables = [
                "readings",
                "saved_devices",
                "rules",
                "scan_logs",
                "recent_devices",
                "device_info_cache",
                "scenarios",
                "rooms",
                "households",
                "device_assignment_pending",
                "feedback_drafts"
            ]
            try performExecute("BEGIN IMMEDIATE;", [])
            do {
                for table in tables {
                    try performExecute("DELETE FROM \(table);", [])
                }
                try performExecute("COMMIT;", [])
            } catch {
                try? performExecute("ROLLBACK;", [])
                throw error
            }
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
        if version < 6 {
            try migrateToVersion6()
        }
        if version < 7 {
            try migrateToVersion7()
        }
        if version < 8 {
            try migrateToVersion8()
        }
        if version < 9 {
            try migrateToVersion9()
        }
        if version < 10 {
            try migrateToVersion10()
        }
        if version < 11 {
            try migrateToVersion11()
        }
        if version < 12 {
            try migrateToVersion12()
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

    /// v6：场景表。仅本机数据，刻意不建 `sync_state / updated_at` 之外的同步字段，
    /// 也不参与 `SyncEngine` 的推拉，避免误把本机动作组合同步到云端。
    private func migrateToVersion6() throws {
        try executeScript("""
        CREATE TABLE IF NOT EXISTS scenarios (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            actions TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        PRAGMA user_version = 6;
        """)
    }

    /// v7：规则从「只看信号」扩到「看读数」。
    ///
    /// 新增列都带默认值，旧规则升级后仍是原来的 RSSI / 断开规则：
    /// `metric` 保持 NULL、`comparison` 回填 `lte`、`consecutive` 回填 1，
    /// 旧规则照常按 `threshold` 判定，不丢任何一条。
    private func migrateToVersion7() throws {
        // 极端旧库可能从未建过 rules 表（例如只跑过部分迁移的夹具），直接按 v7 结构建表。
        let columns = try performQuery("PRAGMA table_info(rules);", [])
        guard !columns.isEmpty else {
            try executeScript("""
            CREATE TABLE IF NOT EXISTS rules (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                trigger TEXT NOT NULL,
                threshold INTEGER NOT NULL,
                metric TEXT,
                comparison TEXT NOT NULL DEFAULT 'lte',
                reading_threshold REAL NOT NULL DEFAULT 0,
                consecutive INTEGER NOT NULL DEFAULT 1,
                device_id TEXT,
                is_enabled INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                deleted_at REAL,
                sync_state TEXT NOT NULL
            );
            PRAGMA user_version = 7;
            """)
            return
        }

        // 逐列判断后再加：夹具数据库可能已经包含部分新列（例如把当前库回落到旧版本号）。
        let existing = Set(columns.compactMap { $0.text("name") })
        var script = ""
        if !existing.contains("metric") {
            script += "ALTER TABLE rules ADD COLUMN metric TEXT;\n"
        }
        if !existing.contains("comparison") {
            script += "ALTER TABLE rules ADD COLUMN comparison TEXT NOT NULL DEFAULT 'lte';\n"
        }
        if !existing.contains("reading_threshold") {
            script += "ALTER TABLE rules ADD COLUMN reading_threshold REAL NOT NULL DEFAULT 0;\n"
        }
        if !existing.contains("consecutive") {
            script += "ALTER TABLE rules ADD COLUMN consecutive INTEGER NOT NULL DEFAULT 1;\n"
        }
        script += """
        UPDATE rules SET comparison = 'lte' WHERE comparison IS NULL OR comparison = '';
        UPDATE rules SET consecutive = 1 WHERE consecutive < 1 OR consecutive > 5;
        PRAGMA user_version = 7;
        """
        try executeScript(script)
    }

    /// v8：房间归属。房间仅本机（不参与 push / changes），`saved_devices.room_id` 可空，NULL 表示未分配。
    /// 旧数据原样保留，原 `group_name` 作为兼容字段继续存在，但不再承担首页主要分区职责。
    private func migrateToVersion8() throws {
        let columns = try performQuery("PRAGMA table_info(saved_devices);", [])
        let existing = Set(columns.compactMap { $0.text("name") })
        var script = """
        CREATE TABLE IF NOT EXISTS rooms (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            remote_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        if !existing.isEmpty && !existing.contains("room_id") {
            script += "ALTER TABLE saved_devices ADD COLUMN room_id TEXT;\n"
        }
        script += """
        CREATE INDEX IF NOT EXISTS idx_rooms_sort ON rooms(sort_order);
        PRAGMA user_version = 8;
        """
        try executeScript(script)
    }

    /// v9：家庭接入。
    ///
    /// - `households` 保存服务端家庭快照；`remote_id` 唯一，`is_personal` / `role` 用于
    ///   判断「个人家庭不可删」与成员权限；本地 `id` 与远端 id 之间不做重映射，直接复用同一个 UUID。
    /// - `rooms` 启用 `remote_id` 与 `household_id`，并以 `sync_state` 记录 `local / pending / synced`；
    ///   `deleted` 作为离线删除墓碑，联网重试成功后物理删除。旧房间 `household_id` 保持 NULL，
    ///   首次接入家庭时由 `HouseholdService` 认领并推送到服务端，绝不静默丢弃。
    /// - `saved_devices` 增加本地 `household_id` 与服务端真值 `remote_room_id / remote_household_id`，
    ///   以便离线时按本机房间展示、联网后核对。
    /// - `device_assignment_pending` 记录待上报的设备归属（`roomId` 三态：空串 = 清除），
    ///   与 `saved_devices.sync_state` 解耦，避免把归属塞进 push 触发 LWW 冲突。
    private func migrateToVersion9() throws {
        let deviceColumns = Set(try performQuery("PRAGMA table_info(saved_devices);", [])
            .compactMap { $0.text("name") })
        let roomColumns = Set(try performQuery("PRAGMA table_info(rooms);", [])
            .compactMap { $0.text("name") })
        var script = """
        CREATE TABLE IF NOT EXISTS households (
            id TEXT PRIMARY KEY NOT NULL,
            remote_id TEXT NOT NULL DEFAULT '',
            name TEXT NOT NULL,
            is_personal INTEGER NOT NULL DEFAULT 0,
            role TEXT NOT NULL DEFAULT 'member',
            member_count INTEGER NOT NULL DEFAULT 0,
            device_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_households_remote ON households(remote_id);

        CREATE TABLE IF NOT EXISTS device_assignment_pending (
            device_id TEXT PRIMARY KEY NOT NULL,
            platform TEXT NOT NULL,
            external_id TEXT NOT NULL,
            room_remote_id TEXT NOT NULL DEFAULT '',
            household_remote_id TEXT NOT NULL DEFAULT '',
            attempts INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        if !deviceColumns.isEmpty {
            for column in ["household_id", "remote_room_id", "remote_household_id"]
            where !deviceColumns.contains(column) {
                script += "ALTER TABLE saved_devices ADD COLUMN \(column) TEXT;\n"
            }
        }
        if !roomColumns.isEmpty {
            if !roomColumns.contains("household_id") {
                script += "ALTER TABLE rooms ADD COLUMN household_id TEXT;\n"
            }
            if !roomColumns.contains("sync_state") {
                script += "ALTER TABLE rooms ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'local';\n"
            }
            if !roomColumns.contains("deleted") {
                script += "ALTER TABLE rooms ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;\n"
            }
        }
        script += """
        CREATE INDEX IF NOT EXISTS idx_rooms_household ON rooms(household_id, sort_order);
        PRAGMA user_version = 9;
        """
        try executeScript(script)
    }

    /// v10：家庭快照补充 `room_count`（服务端真实房间数，不本地计数）。
    private func migrateToVersion10() throws {
        let householdColumns = Set(try performQuery("PRAGMA table_info(households);", [])
            .compactMap { $0.text("name") })
        var script = ""
        if !householdColumns.isEmpty && !householdColumns.contains("room_count") {
            script += "ALTER TABLE households ADD COLUMN room_count INTEGER NOT NULL DEFAULT 0;\n"
        }
        script += "PRAGMA user_version = 10;"
        try executeScript(script)
    }

    /// v11：意见反馈本地待发队列。
    ///
    /// 当前没有反馈接收接口，条目只落本机；`attempts / last_attempt_at` 记录真实重试次数，
    /// 界面据此展示「未发送」，绝不伪造发送成功。
    /// 可重复执行：先 `PRAGMA table_info` 判列，缺列才 `ALTER`，半迁移或夹具库也能补齐。
    private func migrateToVersion11() throws {
        let columns = Set(try performQuery("PRAGMA table_info(feedback_drafts);", [])
            .compactMap { $0.text("name") })
        var script = """
        CREATE TABLE IF NOT EXISTS feedback_drafts (
            id TEXT PRIMARY KEY NOT NULL,
            category TEXT NOT NULL DEFAULT 'other',
            message TEXT NOT NULL DEFAULT '',
            contact TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_attempt_at REAL
        );
        """
        if !columns.isEmpty {
            if !columns.contains("category") {
                script += "ALTER TABLE feedback_drafts ADD COLUMN category TEXT NOT NULL DEFAULT 'other';\n"
            }
            if !columns.contains("message") {
                script += "ALTER TABLE feedback_drafts ADD COLUMN message TEXT NOT NULL DEFAULT '';\n"
            }
            if !columns.contains("contact") {
                script += "ALTER TABLE feedback_drafts ADD COLUMN contact TEXT NOT NULL DEFAULT '';\n"
            }
            if !columns.contains("created_at") {
                script += "ALTER TABLE feedback_drafts ADD COLUMN created_at REAL NOT NULL DEFAULT 0;\n"
            }
            if !columns.contains("attempts") {
                script += "ALTER TABLE feedback_drafts ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;\n"
            }
            if !columns.contains("last_attempt_at") {
                script += "ALTER TABLE feedback_drafts ADD COLUMN last_attempt_at REAL;\n"
            }
        }
        script += "PRAGMA user_version = 11;"
        try executeScript(script)
    }

    private func currentUserVersion() throws -> Int {
        let rows = try performQuery("PRAGMA user_version;", [])
        return Int(rows.first?.integer("user_version") ?? 0)
    }

    /// v12：反馈草稿接入真实发送链路，增加状态 / 上次错误 / 远端 ID / 下次重试时间。
    /// 旧行默认 `pending`，已有内容与创建时间保留。
    /// 可重复执行：先 `PRAGMA table_info` 判列，缺列才 `ALTER`。
    private func migrateToVersion12() throws {
        let columns = Set(try performQuery("PRAGMA table_info(feedback_drafts);", [])
            .compactMap { $0.text("name") })
        var script = ""
        if !columns.contains("status") {
            script += "ALTER TABLE feedback_drafts ADD COLUMN status TEXT NOT NULL DEFAULT 'pending';\n"
        }
        if !columns.contains("last_error") {
            script += "ALTER TABLE feedback_drafts ADD COLUMN last_error TEXT;\n"
        }
        if !columns.contains("remote_id") {
            script += "ALTER TABLE feedback_drafts ADD COLUMN remote_id TEXT;\n"
        }
        if !columns.contains("next_retry_at") {
            script += "ALTER TABLE feedback_drafts ADD COLUMN next_retry_at REAL;\n"
        }
        script += "PRAGMA user_version = 12;"
        try executeScript(script)
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
