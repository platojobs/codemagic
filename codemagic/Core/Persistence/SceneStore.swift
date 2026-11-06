import Foundation

/// 服务端场景的本地存储。
///
/// 与 `ScenarioStore` 共用 `scenarios` 表：这里只处理 `kind = 'automation'` 的行，
/// 旧的手动场景（`kind = 'manual'`）完全不受影响。
/// 同步语义与设备元数据一致：5 个字段各自带时间戳，本地脏字段在拉取时保留、推送时按字段比较。
final class SceneStore {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: - Read

    func fetchAll(includeDeleted: Bool = false) throws -> [Scene] {
        let sql = includeDeleted
            ? "SELECT * FROM scenarios WHERE kind = 'automation' ORDER BY created_at ASC;"
            : "SELECT * FROM scenarios WHERE kind = 'automation' AND deleted_at IS NULL ORDER BY created_at ASC;"
        return try database.query(sql).compactMap(Self.makeScene)
    }

    func fetch(id: UUID) throws -> Scene? {
        try database.query(
            "SELECT * FROM scenarios WHERE id = ? AND kind = 'automation';",
            [.text(id.uuidString)]
        ).first.flatMap(Self.makeScene)
    }

    func fetch(remoteID: String) throws -> Scene? {
        try database.query(
            "SELECT * FROM scenarios WHERE remote_id = ? AND kind = 'automation';",
            [.text(remoteID)]
        ).first.flatMap(Self.makeScene)
    }

    /// 待上传 / 待删除的场景，按最后修改时间升序，保证先发生的编辑先同步。
    /// `nextRetryAt` 尚未到的行（429 退避）会被跳过，退避时间落库后跨进程生效。
    func fetchPending(now: Date = Date()) throws -> [Scene] {
        try database.query(
            """
            SELECT * FROM scenarios
            WHERE kind = 'automation' AND sync_state IN ('pending', 'pendingDelete')
              AND (next_retry_at IS NULL OR next_retry_at <= ?)
            ORDER BY updated_at ASC;
            """,
            [.double(now.timeIntervalSince1970)]
        ).compactMap(Self.makeScene)
    }

    func pendingCount() throws -> Int {
        let rows = try database.query(
            """
            SELECT COUNT(*) AS total FROM scenarios
            WHERE kind = 'automation' AND sync_state IN ('pending', 'pendingDelete');
            """
        )
        return Int(rows.first?.integer("total") ?? 0)
    }

    // MARK: - Write

    /// 新建本机场景（尚未上传）。5 个字段的初始时间戳都记为 `now`。
    @discardableResult
    func insert(_ scene: Scene, now: Date = Date()) throws -> Scene {
        var normalized = scene
        normalized.syncState = .pending
        normalized.version = 0
        normalized.remoteID = nil
        normalized.deletedAt = nil
        normalized.deviceMissing = false
        normalized.lastSyncedAt = nil
        normalized.rejectionCode = nil
        normalized.rejectionReason = nil
        normalized.rejectedAt = nil
        normalized.nextRetryAt = nil
        normalized.fieldUpdatedAt = Dictionary(
            uniqueKeysWithValues: SceneFieldKey.allCases.map { ($0, now) }
        )
        try persist(normalized, createdAt: scene.createdAt)
        return normalized
    }

    /// 保存本地编辑：只把 `editedFields` 的时间戳推进到 `now`，其余字段时间戳保持不动。
    @discardableResult
    func save(_ scene: Scene, editedFields: Set<SceneFieldKey>, now: Date = Date()) throws -> Scene {
        var updated = scene
        for field in editedFields {
            updated.fieldUpdatedAt[field] = now
        }
        updated.updatedAt = now
        let wasRejected = updated.syncState == .rejected
        if updated.deletedAt == nil {
            updated.syncState = .pending
        }
        // 拒绝是终态；只有用户实际编辑字段才解除，并清掉拒绝信息与 429 退避。
        if wasRejected && !editedFields.isEmpty {
            updated.syncState = .pending
            updated.rejectionCode = nil
            updated.rejectionReason = nil
            updated.rejectedAt = nil
            updated.nextRetryAt = nil
        }
        if updated.remoteID == nil {
            // 本地新建的字段时间戳应在插入时已补齐；这里兜底，避免缺字段被判为「不脏」。
            for field in SceneFieldKey.allCases where updated.fieldUpdatedAt[field] == nil {
                updated.fieldUpdatedAt[field] = now
            }
        }
        try persist(updated, createdAt: scene.createdAt)
        return updated
    }

    /// 本地删除：已上传的走软删 + `pendingDelete`，从未上传的直接物理删除。
    func delete(id: UUID, now: Date = Date()) throws {
        guard var scene = try fetch(id: id) else { return }
        if scene.remoteID == nil {
            try database.execute(
                "DELETE FROM scenarios WHERE id = ? AND kind = 'automation';",
                [.text(id.uuidString)]
            )
            return
        }
        scene.deletedAt = now
        scene.updatedAt = now
        scene.syncState = .pendingDelete
        try persist(scene, createdAt: scene.createdAt)
    }

    /// 应用服务端快照（`GET /scenes` 基线或 `change_log` 的 `scene` 实体）。
    ///
    /// - 本地不存在：直接插入为 `synced`。
    /// - 本地已同步：整体采用服务端值。
    /// - 本地有未推送的字段：这些字段保留本地值，其余字段采用服务端值，
    ///   随后由 `PUT` 的字段级 LWW 决定最终结果（两端改不同字段时都能保留）。
    /// - 服务端已软删：本地标记删除并置 `synced`。
    ///
    /// 返回是否成功应用（未知触发条件等无法解析的 payload 会被跳过，调用方仍应推进游标）。
    @discardableResult
    func applyRemote(_ remote: RemoteScene, now: Date = Date()) throws -> Bool {
        guard let trigger = remote.trigger, !remote.id.isEmpty else { return false }

        guard var local = try fetch(remoteID: remote.id) else {
            guard remote.deletedAt == nil else { return true }
            let id = UUID(uuidString: remote.id) ?? SyncHashing.stableUUID(seed: "scene:\(remote.id)")
            let scene = Scene(
                id: id,
                remoteID: remote.id,
                name: remote.name,
                enabled: remote.enabled,
                cooldownSeconds: remote.cooldownSeconds,
                trigger: trigger,
                actions: remote.actions,
                version: remote.version,
                deviceMissing: remote.deviceMissing,
                createdAt: remote.createdAt ?? remote.updatedAt,
                updatedAt: remote.updatedAt,
                deletedAt: nil,
                syncState: .synced,
                fieldUpdatedAt: Dictionary(
                    uniqueKeysWithValues: SceneFieldKey.allCases.map { ($0, remote.updatedAt) }
                ),
                lastSyncedAt: max(now, remote.updatedAt)
            )
            try persist(scene, createdAt: scene.createdAt)
            return true
        }

        if remote.deletedAt != nil {
            local.deletedAt = remote.deletedAt
            local.version = remote.version
            local.updatedAt = remote.updatedAt
            local.syncState = .synced
            local.lastSyncedAt = now
            try persist(local, createdAt: local.createdAt)
            return true
        }

        if local.syncState == .pendingDelete {
            // 本地已删除，远端仍是旧快照：保持本地删除意图，等待推送删除。
            local.version = remote.version
            try persist(local, createdAt: local.createdAt)
            return true
        }

        if local.syncState != .pending {
            local.name = remote.name
            local.enabled = remote.enabled
            local.cooldownSeconds = remote.cooldownSeconds
            local.trigger = trigger
            local.actions = remote.actions
            local.version = remote.version
            local.deviceMissing = remote.deviceMissing
            local.updatedAt = remote.updatedAt
            local.deletedAt = nil
            local.syncState = .synced
            local.lastSyncedAt = max(now, remote.updatedAt)
            local.fieldUpdatedAt = Dictionary(
                uniqueKeysWithValues: SceneFieldKey.allCases.map { ($0, remote.updatedAt) }
            )
            try persist(local, createdAt: local.createdAt)
            return true
        }

        var keptDirty = false
        // 非脏字段采用远端值后，字段时间戳回落到旧的同步基线：
        // 既保证它们不会因为服务端时间超前被误判为脏字段，也不影响真正待推送的字段。
        let baseline = local.lastSyncedAt ?? remote.updatedAt
        for field in SceneFieldKey.allCases {
            if local.isFieldDirty(field) {
                keptDirty = true
                continue
            }
            switch field {
            case .name: local.name = remote.name
            case .enabled: local.enabled = remote.enabled
            case .cooldownSeconds: local.cooldownSeconds = remote.cooldownSeconds
            case .trigger: local.trigger = trigger
            case .actions: local.actions = remote.actions
            }
            local.fieldUpdatedAt[field] = baseline
        }
        local.version = remote.version
        local.deviceMissing = remote.deviceMissing
        local.deletedAt = nil
        local.updatedAt = keptDirty ? local.updatedAt : remote.updatedAt
        local.syncState = keptDirty ? .pending : .synced
        if !keptDirty {
            local.lastSyncedAt = now
        }
        try persist(local, createdAt: local.createdAt)
        return true
    }

    /// `GET /scenes` 基线里缺失的已同步场景：视为服务端已软删。
    /// 本地仍有未推送修改的场景保留 pending，避免基线把离线编辑覆盖掉。
    @discardableResult
    func markRemoteMissing(remoteID: String, now: Date = Date()) throws -> Bool {
        guard var local = try fetch(remoteID: remoteID) else { return false }
        guard local.syncState == .synced, local.deletedAt == nil else { return false }
        local.deletedAt = now
        local.updatedAt = now
        local.syncState = .synced
        local.lastSyncedAt = now
        try persist(local, createdAt: local.createdAt)
        return true
    }

    /// 本地没有脏字段但状态仍是 pending（例如字段时间戳已追上服务端）时，直接回到已同步。
    func markSynced(id: UUID, now: Date = Date()) throws {
        guard var scene = try fetch(id: id) else { return }
        scene.syncState = .synced
        scene.lastSyncedAt = now
        scene.rejectionCode = nil
        scene.rejectionReason = nil
        scene.rejectedAt = nil
        scene.nextRetryAt = nil
        if scene.deletedAt != nil {
            // 已软删的行保持 tombstone，但同步状态不再排队。
            scene.syncState = .synced
        }
        try persist(scene, createdAt: scene.createdAt)
    }

    /// 服务端 `SCENE_*` 拒绝：落终态与可读原因，之后不再自动重试。
    func markRejected(id: UUID, code: String, reason: String?, now: Date = Date()) throws {
        guard var scene = try fetch(id: id) else { return }
        scene.syncState = .rejected
        scene.rejectionCode = code
        scene.rejectionReason = reason
        scene.rejectedAt = now
        scene.nextRetryAt = nil
        try persist(scene, createdAt: scene.createdAt)
    }

    /// 429：把 `Retry-After` 落库为 `nextRetryAt`，重启后继续遵守退避。
    func markRateLimited(id: UUID, retryAfterSeconds: Int?, now: Date = Date()) throws {
        guard var scene = try fetch(id: id) else { return }
        let seconds = max(retryAfterSeconds ?? 60, 1)
        scene.nextRetryAt = now.addingTimeInterval(TimeInterval(seconds))
        try persist(scene, createdAt: scene.createdAt)
    }

    /// 上传 / 更新成功后写回服务端快照。
    func applyServerResponse(_ remote: RemoteScene, now: Date = Date()) throws {
        guard let trigger = remote.trigger, var local = try fetch(remoteID: remote.id) else { return }
        local.name = remote.name
        local.enabled = remote.enabled
        local.cooldownSeconds = remote.cooldownSeconds
        local.trigger = trigger
        local.actions = remote.actions
        local.version = remote.version
        local.deviceMissing = remote.deviceMissing
        local.updatedAt = remote.updatedAt
        local.deletedAt = remote.deletedAt
        local.syncState = .synced
        local.lastSyncedAt = max(now, remote.updatedAt)
        local.rejectionCode = nil
        local.rejectionReason = nil
        local.rejectedAt = nil
        local.nextRetryAt = nil
        local.fieldUpdatedAt = Dictionary(
            uniqueKeysWithValues: SceneFieldKey.allCases.map { ($0, remote.updatedAt) }
        )
        try persist(local, createdAt: local.createdAt)
    }

    /// 首次上传成功：按本地 id 精确写回，避免并发场景下错配。
    func markCreated(localID: UUID, remote: RemoteScene, now: Date = Date()) throws {
        guard let trigger = remote.trigger, var local = try fetch(id: localID) else { return }
        local.remoteID = remote.id
        local.name = remote.name
        local.enabled = remote.enabled
        local.cooldownSeconds = remote.cooldownSeconds
        local.trigger = trigger
        local.actions = remote.actions
        local.version = remote.version
        local.deviceMissing = remote.deviceMissing
        local.updatedAt = remote.updatedAt
        local.deletedAt = nil
        local.syncState = .synced
        local.lastSyncedAt = max(now, remote.updatedAt)
        local.rejectionCode = nil
        local.rejectionReason = nil
        local.rejectedAt = nil
        local.nextRetryAt = nil
        // 服务端没有暴露字段时间戳；用服务端 updatedAt 作为基线，
        // 之后本地编辑只要晚于它即可被 PUT 的字段级 LWW 接受。
        local.fieldUpdatedAt = Dictionary(
            uniqueKeysWithValues: SceneFieldKey.allCases.map { ($0, remote.updatedAt) }
        )
        try persist(local, createdAt: local.createdAt)
    }

    /// 软删同步完成（204 / 404 都视为服务端已删）。
    func markDeleteSynced(id: UUID, now: Date = Date()) throws {
        guard var scene = try fetch(id: id) else { return }
        if scene.deletedAt == nil { scene.deletedAt = now }
        scene.syncState = .synced
        scene.lastSyncedAt = now
        scene.rejectionCode = nil
        scene.rejectionReason = nil
        scene.rejectedAt = nil
        scene.nextRetryAt = nil
        try persist(scene, createdAt: scene.createdAt)
    }

    /// 记录最后一次执行时间，用于 `cooldownSeconds`。
    func markRun(id: UUID, at date: Date = Date()) throws {
        guard var scene = try fetch(id: id) else { return }
        scene.lastRunAt = date
        try persist(scene, createdAt: scene.createdAt)
    }

    /// 设备删除后刷新「设备已移除」标记；不级联删除场景。
    func updateDeviceMissing(id: UUID, missing: Bool) throws {
        guard var scene = try fetch(id: id), scene.deviceMissing != missing else { return }
        scene.deviceMissing = missing
        try persist(scene, createdAt: scene.createdAt)
    }

    // MARK: - Persistence

    private func persist(_ scene: Scene, createdAt: Date) throws {
        let encoder = JSONEncoder()
        let actionsJSON = (try? encoder.encode(scene.actions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let triggerJSON = (try? encoder.encode(scene.trigger))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        func timestamp(_ field: SceneFieldKey, fallback: Date) -> Double {
            (scene.fieldUpdatedAt[field] ?? fallback).timeIntervalSince1970
        }

        let parameters: [SQLValue] = [
            scene.remoteID.map { .text($0) } ?? .null,
            .text(scene.name),
            .text(actionsJSON),
            .text(triggerJSON),
            .integer(scene.version),
            .integer(scene.enabled ? 1 : 0),
            .integer(Int64(scene.cooldownSeconds)),
            .text(scene.syncState.rawValue),
            scene.deletedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .integer(scene.deviceMissing ? 1 : 0),
            scene.lastSyncedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            scene.lastRunAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .double(scene.updatedAt.timeIntervalSince1970),
            .double(timestamp(.name, fallback: scene.updatedAt)),
            .double(timestamp(.enabled, fallback: scene.updatedAt)),
            .double(timestamp(.cooldownSeconds, fallback: scene.updatedAt)),
            .double(timestamp(.trigger, fallback: scene.updatedAt)),
            .double(timestamp(.actions, fallback: scene.updatedAt)),
            scene.rejectionCode.map { .text($0) } ?? .null,
            scene.rejectionReason.map { .text($0) } ?? .null,
            scene.rejectedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            scene.nextRetryAt.map { .double($0.timeIntervalSince1970) } ?? .null,
        ]

        let assignments: [String] = [
            "remote_id = ?",
            "name = ?",
            "actions = ?",
            "trigger = ?",
            "version = ?",
            "enabled = ?",
            "cooldown_seconds = ?",
            "sync_state = ?",
            "deleted_at = ?",
            "device_missing = ?",
            "last_synced_at = ?",
            "last_run_at = ?",
            "updated_at = ?",
            "name_updated_at = ?",
            "enabled_updated_at = ?",
            "cooldown_updated_at = ?",
            "trigger_updated_at = ?",
            "actions_updated_at = ?",
            "rejection_code = ?",
            "rejection_reason = ?",
            "rejected_at = ?",
            "next_retry_at = ?",
        ]
        var updateParameters = parameters
        updateParameters.append(.text(scene.id.uuidString))

        try database.execute(
            "UPDATE scenarios SET \(assignments.joined(separator: ", ")) WHERE id = ? AND kind = 'automation';",
            updateParameters
        )
        // INSERT 的列顺序里 `created_at` 排在 5 个字段时间戳之前，参数必须按同样位置插入，
        // 不能把 createdAt 直接追加到末尾，否则会整体错位（created_at 变成 name 的时间戳）。
        let insertParameters =
            [.text(scene.id.uuidString)] + parameters[0..<13]
            + [.double(createdAt.timeIntervalSince1970)] + parameters[13...]
        try database.execute(
            """
            INSERT OR IGNORE INTO scenarios
            (id, kind, remote_id, name, actions, trigger, version, enabled, cooldown_seconds,
             sync_state, deleted_at, device_missing, last_synced_at, last_run_at, updated_at,
             created_at, name_updated_at, enabled_updated_at, cooldown_updated_at,
             trigger_updated_at, actions_updated_at, rejection_code, rejection_reason,
             rejected_at, next_retry_at)
            VALUES (?, 'automation', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            insertParameters
        )
    }

    // MARK: - Row mapping

    private static func makeScene(from row: SQLRow) -> Scene? {
        guard let idText = row.text("id"), let id = UUID(uuidString: idText) else { return nil }
        guard let triggerJSON = row.text("trigger"),
              let triggerData = triggerJSON.data(using: .utf8),
              let trigger = try? JSONDecoder().decode(SceneTrigger.self, from: triggerData) else {
            return nil
        }
        let actions: [SceneAction]
        if let json = row.text("actions"),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SceneAction].self, from: data) {
            actions = decoded
        } else {
            actions = []
        }
        let updatedAt = Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
        func fieldDate(_ column: String) -> Date {
            Date(timeIntervalSince1970: row.double(column) ?? updatedAt.timeIntervalSince1970)
        }
        let remoteID = row.text("remote_id")
        return Scene(
            id: id,
            remoteID: remoteID?.isEmpty == true ? nil : remoteID,
            name: row.text("name") ?? "",
            enabled: row.bool("enabled"),
            cooldownSeconds: Int(row.integer("cooldown_seconds") ?? 300),
            trigger: trigger,
            actions: actions,
            version: row.integer("version") ?? 0,
            deviceMissing: row.bool("device_missing"),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: updatedAt,
            deletedAt: row.double("deleted_at").map { Date(timeIntervalSince1970: $0) },
            syncState: SyncState(rawValue: row.text("sync_state") ?? "") ?? .pending,
            fieldUpdatedAt: [
                .name: fieldDate("name_updated_at"),
                .enabled: fieldDate("enabled_updated_at"),
                .cooldownSeconds: fieldDate("cooldown_updated_at"),
                .trigger: fieldDate("trigger_updated_at"),
                .actions: fieldDate("actions_updated_at"),
            ],
            lastSyncedAt: row.double("last_synced_at").map { Date(timeIntervalSince1970: $0) },
            lastRunAt: row.double("last_run_at").map { Date(timeIntervalSince1970: $0) },
            rejectionCode: row.text("rejection_code"),
            rejectionReason: row.text("rejection_reason"),
            rejectedAt: row.double("rejected_at").map { Date(timeIntervalSince1970: $0) },
            nextRetryAt: row.double("next_retry_at").map { Date(timeIntervalSince1970: $0) }
        )
    }
}
