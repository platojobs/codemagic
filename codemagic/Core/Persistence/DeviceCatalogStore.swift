import Foundation

/// 本地缓存的目录快照。`payload` 保留原始响应，避免在缓存层重新序列化模型。
struct CachedDeviceCatalog: Equatable {
    let catalog: DeviceTypeCatalog
    let etag: String?
    let lastModified: String?
    let fetchedAt: Date
    let lastUsedAt: Date
}

/// 目录缓存读写协议：生产用 SQLite，测试可用内存实现。
protocol DeviceCatalogCaching {
    func load() -> CachedDeviceCatalog?
    func save(
        catalog: DeviceTypeCatalog,
        rawPayload: Data,
        etag: String?,
        lastModified: String?,
        fetchedAt: Date
    )
    func touchLastUsed(at date: Date)
}

/// 为什么用 SQLite：项目已有 `user_version` + `PRAGMA table_info` 迁移链路，
/// 目录缓存与其它业务数据共享生命周期（注销时一起清空），且条件请求头与
/// 「最近使用时间」可以原子更新，不需要额外管理缓存文件或格式版本。
final class DeviceCatalogStore: DeviceCatalogCaching {
    private static let rowID = "device_types"

    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func load() -> CachedDeviceCatalog? {
        guard let rows = try? database.query(
            """
            SELECT version, generated_at, etag, last_modified, payload, fetched_at, last_used_at
            FROM device_catalog_cache WHERE id = ? LIMIT 1;
            """,
            [.text(Self.rowID)]
        ), let row = rows.first else {
            return nil
        }
        guard let payload = row.text("payload"), !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let catalog = try? JSONDecoder().decode(DeviceTypeCatalog.self, from: data) else {
            // 缓存损坏时当作无缓存，让上层走网络或给出可读错误，不伪装成有效目录。
            return nil
        }
        return CachedDeviceCatalog(
            catalog: catalog,
            etag: row.text("etag"),
            lastModified: row.text("last_modified"),
            fetchedAt: Date(timeIntervalSince1970: row.double("fetched_at") ?? 0),
            lastUsedAt: Date(timeIntervalSince1970: row.double("last_used_at") ?? 0)
        )
    }

    func save(
        catalog: DeviceTypeCatalog,
        rawPayload: Data,
        etag: String?,
        lastModified: String?,
        fetchedAt: Date
    ) {
        guard let payload = String(data: rawPayload, encoding: .utf8), !payload.isEmpty else {
            return
        }
        try? database.execute(
            """
            INSERT INTO device_catalog_cache
                (id, version, generated_at, etag, last_modified, payload, fetched_at, last_used_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                version = excluded.version,
                generated_at = excluded.generated_at,
                etag = excluded.etag,
                last_modified = excluded.last_modified,
                payload = excluded.payload,
                fetched_at = excluded.fetched_at,
                last_used_at = excluded.last_used_at;
            """,
            [
                .text(Self.rowID),
                .integer(catalog.version),
                .double(catalog.generatedAt.timeIntervalSince1970),
                etag.map(SQLValue.text) ?? .null,
                lastModified.map(SQLValue.text) ?? .null,
                .text(payload),
                .double(fetchedAt.timeIntervalSince1970),
                .double(fetchedAt.timeIntervalSince1970)
            ]
        )
    }

    func touchLastUsed(at date: Date) {
        try? database.execute(
            "UPDATE device_catalog_cache SET last_used_at = ? WHERE id = ?;",
            [.double(date.timeIntervalSince1970), .text(Self.rowID)]
        )
    }
}

/// 测试 / 无数据库环境的内存缓存，行为与 SQLite 实现一致。
final class InMemoryDeviceCatalogCache: DeviceCatalogCaching {
    private var entry: CachedDeviceCatalog?

    init(entry: CachedDeviceCatalog? = nil) {
        self.entry = entry
    }

    func load() -> CachedDeviceCatalog? { entry }

    func save(
        catalog: DeviceTypeCatalog,
        rawPayload: Data,
        etag: String?,
        lastModified: String?,
        fetchedAt: Date
    ) {
        entry = CachedDeviceCatalog(
            catalog: catalog,
            etag: etag,
            lastModified: lastModified,
            fetchedAt: fetchedAt,
            lastUsedAt: fetchedAt
        )
    }

    func touchLastUsed(at date: Date) {
        guard let entry else { return }
        self.entry = CachedDeviceCatalog(
            catalog: entry.catalog,
            etag: entry.etag,
            lastModified: entry.lastModified,
            fetchedAt: entry.fetchedAt,
            lastUsedAt: date
        )
    }
}
