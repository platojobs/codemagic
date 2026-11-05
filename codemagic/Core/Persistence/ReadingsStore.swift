import Foundation

/// 读数持久化：7 天本地保留、按设备/指标倒序查询、待上传增量。
final class ReadingsStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: - Write

    /// 单条写入；`id` 冲突时保留原记录（同一条读数不重复落库）。
    func insert(_ reading: DeviceReading) throws {
        try database.execute(
            """
            INSERT OR IGNORE INTO readings
            (id, device_id, metric, value, unit, recorded_at, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(reading.id.uuidString),
                .text(reading.deviceID.uuidString),
                .text(reading.metric.rawValue),
                .double(reading.value),
                .text(reading.unit),
                .double(reading.recordedAt.timeIntervalSince1970),
                .text(reading.syncState.rawValue),
            ]
        )
    }

    // MARK: - Read

    /// 最近 N 条，按时间倒序（最新在前）。
    func fetchRecent(deviceID: UUID, metric: ReadingMetric, limit: Int = 60) throws -> [DeviceReading] {
        let rows = try database.query(
            """
            SELECT * FROM readings
            WHERE device_id = ? AND metric = ?
            ORDER BY recorded_at DESC
            LIMIT ?;
            """,
            [
                .text(deviceID.uuidString),
                .text(metric.rawValue),
                .integer(Int64(limit)),
            ]
        )
        return rows.compactMap(Self.makeReading)
    }

    /// 指定窗口内的读数，按时间升序（绘图用）。
    func fetch(deviceID: UUID, metric: ReadingMetric, from: Date, to: Date = Date()) throws -> [DeviceReading] {
        let rows = try database.query(
            """
            SELECT * FROM readings
            WHERE device_id = ? AND metric = ? AND recorded_at >= ? AND recorded_at <= ?
            ORDER BY recorded_at ASC;
            """,
            [
                .text(deviceID.uuidString),
                .text(metric.rawValue),
                .double(from.timeIntervalSince1970),
                .double(to.timeIntervalSince1970),
            ]
        )
        return rows.compactMap(Self.makeReading)
    }

    /// 本地指标清单（离线兜底）：条数、首末时间与最近一条读数的单位，按 `lastAt` 倒序。
    /// 与 `GET .../readings/metrics` 形状一致，未知指标同样归一为 `other`。
    func metricInfos(deviceID: UUID) throws -> [ReadingMetricInfo] {
        let rows = try database.query(
            """
            SELECT metric, COUNT(*) AS total, MIN(recorded_at) AS first_at, MAX(recorded_at) AS last_at
            FROM readings
            WHERE device_id = ?
            GROUP BY metric;
            """,
            [.text(deviceID.uuidString)]
        )
        var merged: [ReadingMetric: (count: Int, first: Date?, last: Date?, unit: String)] = [:]
        for row in rows {
            guard let raw = row.text("metric"),
                  let total = row.integer("total")
            else { continue }
            let metric = ReadingMetric.normalized(raw)
            let first = row.double("first_at").map { Date(timeIntervalSince1970: $0) }
            let last = row.double("last_at").map { Date(timeIntervalSince1970: $0) }
            let unit = (try? latestUnit(deviceID: deviceID, rawMetric: raw)) ?? ""

            let existing = merged[metric]
            let laterExists = (existing?.last ?? .distantPast) >= (last ?? .distantPast)
            merged[metric] = (
                count: (existing?.count ?? 0) + Int(total),
                first: earlier(existing?.first, first),
                last: later(existing?.last, last),
                unit: laterExists ? (existing?.unit ?? "") : unit
            )
        }

        let infos = merged.map { metric, aggregate in
            ReadingMetricInfo(
                metric: metric.rawValue,
                unit: aggregate.unit,
                count: aggregate.count,
                firstAt: aggregate.first,
                lastAt: aggregate.last
            )
        }
        return ReadingMetricInfo.sortedByLastAt(infos)
    }

    /// 该设备真实已有指标，按白名单顺序返回；没有读数返回空数组。
    func availableMetrics(deviceID: UUID) throws -> [ReadingMetric] {
        let rows = try database.query(
            "SELECT DISTINCT metric FROM readings WHERE device_id = ?;",
            [.text(deviceID.uuidString)]
        )
        let present = Set(rows.compactMap { $0.text("metric") }.map(ReadingMetric.normalized))
        return ReadingMetric.whitelist.filter { present.contains($0) }
    }

    /// 该设备全部读数条数。
    func count(deviceID: UUID) throws -> Int {
        let rows = try database.query(
            "SELECT COUNT(*) AS total FROM readings WHERE device_id = ?;",
            [.text(deviceID.uuidString)]
        )
        return Int(rows.first?.integer("total") ?? 0)
    }

    /// 该设备尚未同步（pending / failed）的读数条数；用于判断服务端清单为空是否只是还没上传。
    func pendingCount(deviceID: UUID) throws -> Int {
        let total = try database.query(
            "SELECT COUNT(*) AS total FROM readings WHERE device_id = ? AND sync_state != ?;",
            [.text(deviceID.uuidString), .text(SyncState.synced.rawValue)]
        ).first?.integer("total") ?? 0
        return Int(total)
    }

    /// 待上传读数，按记录时间升序；`limit` 为 nil 时取全部，由同步引擎分批。
    func fetchPending(limit: Int? = nil) throws -> [DeviceReading] {
        let sql = limit == nil
            ? """
              SELECT * FROM readings WHERE sync_state != ?
              ORDER BY recorded_at ASC;
              """
            : """
              SELECT * FROM readings WHERE sync_state != ?
              ORDER BY recorded_at ASC LIMIT ?;
              """
        var parameters: [SQLValue] = [.text(SyncState.synced.rawValue)]
        if let limit {
            parameters.append(.integer(Int64(limit)))
        }
        let rows = try database.query(sql, parameters)
        return rows.compactMap(Self.makeReading)
    }

    func pendingCount() throws -> Int {
        let rows = try database.query(
            "SELECT COUNT(*) AS total FROM readings WHERE sync_state != ?;",
            [.text(SyncState.synced.rawValue)]
        )
        return Int(rows.first?.integer("total") ?? 0)
    }

    // MARK: - Sync

    func markSynced(ids: [UUID], at date: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try database.execute(
                "UPDATE readings SET sync_state = ? WHERE id = ?;",
                [.text(SyncState.synced.rawValue), .text(id.uuidString)]
            )
        }
    }

    /// 7 天保留清理。
    ///
    /// 只删除「已同步」且超过保留期的读数：未上传读数必须先补传，避免离线期间静默丢数据；
    /// 同步成功后它们会变为已同步并在同一次清理中删除。
    @discardableResult
    func prune(olderThan cutoff: Date) throws -> Int {
        let rows = try database.query(
            "SELECT COUNT(*) AS total FROM readings WHERE recorded_at < ? AND sync_state = ?;",
            [.double(cutoff.timeIntervalSince1970), .text(SyncState.synced.rawValue)]
        )
        let total = Int(rows.first?.integer("total") ?? 0)
        try database.execute(
            "DELETE FROM readings WHERE recorded_at < ? AND sync_state = ?;",
            [.double(cutoff.timeIntervalSince1970), .text(SyncState.synced.rawValue)]
        )
        return total
    }

    /// 设备被删除时清理其读数，避免孤儿数据占用空间。
    func deleteAll(deviceID: UUID) throws {
        try database.execute(
            "DELETE FROM readings WHERE device_id = ?;",
            [.text(deviceID.uuidString)]
        )
    }

    // MARK: - Mapping

    private func latestUnit(deviceID: UUID, rawMetric: String) throws -> String {
        try database.query(
            """
            SELECT unit FROM readings
            WHERE device_id = ? AND metric = ?
            ORDER BY recorded_at DESC
            LIMIT 1;
            """,
            [.text(deviceID.uuidString), .text(rawMetric)]
        ).first?.text("unit") ?? ""
    }

    private func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return min(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }

    private func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }

    private static func makeReading(from row: SQLRow) -> DeviceReading? {
        guard let idText = row.text("id"),
              let id = UUID(uuidString: idText),
              let deviceText = row.text("device_id"),
              let deviceID = UUID(uuidString: deviceText),
              let recordedAt = row.double("recorded_at")
        else { return nil }
        return DeviceReading(
            id: id,
            deviceID: deviceID,
            metric: ReadingMetric.normalized(row.text("metric") ?? ""),
            value: row.double("value") ?? 0,
            unit: row.text("unit") ?? "",
            recordedAt: Date(timeIntervalSince1970: recordedAt),
            syncState: SyncState(rawValue: row.text("sync_state") ?? "") ?? .pending
        )
    }
}
