import Foundation

/// 同步引擎：匿名登录 → 增量拉取 → 批量推送 → 冲突处理。
///
/// 冲突策略与后端 openapi 一致（字段级 LWW，服务端获胜）：
/// 落败的本地修改**不会静默覆盖**，而是把云端版本写回本地，同时在本地日志与「我的」页
/// 明确提示「另一台设备改过这条」。
final class SyncEngine {
    /// 一次同步的统计。
    struct Summary: Equatable {
        var pulled: Int = 0
        var pushed: Int = 0
        var conflicts: Int = 0
        var idempotentReplays: Int = 0
    }

    /// 「我的」页展示的同步状态。
    struct Status: Equatable {
        var userID: String?
        var lastSyncAt: Date?
        var pendingCount: Int = 0
        var isSyncing: Bool = false
        var lastError: AppError?
        var lastConflictMessages: [String] = []
        var lastOutcomeMessage: String?
        /// 匿名 token 已失效，等待用户确认重新登录。
        var needsRelogin: Bool = false
    }

    private(set) var status = Status()
    var onChange: (() -> Void)?

    private let api: SyncAPIServicing
    private let tokenStore: TokenStoring
    private let metadataStore: SyncMetadataStore
    private let deviceStore: SavedDeviceStore
    private let logStore: ScanLogStore
    private let now: () -> Date
    private let pageLimit: Int
    private let maxPages: Int

    private var isSyncing = false
    private var sessionConflictMessages: [String] = []

    init(
        api: SyncAPIServicing,
        tokenStore: TokenStoring,
        metadataStore: SyncMetadataStore,
        deviceStore: SavedDeviceStore,
        logStore: ScanLogStore,
        pageLimit: Int = 200,
        maxPages: Int = 10,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.metadataStore = metadataStore
        self.deviceStore = deviceStore
        self.logStore = logStore
        self.pageLimit = pageLimit
        self.maxPages = maxPages
        self.now = now
        refreshStatus()
    }

    // MARK: - Public

    func refreshStatus() {
        let pending = (try? deviceStore.pendingCount()) ?? 0
        status.userID = metadataStore.userID ?? tokenStore.load()?.userID
        status.lastSyncAt = metadataStore.lastSyncAt
        status.pendingCount = pending
        status.isSyncing = isSyncing
        status.needsRelogin = metadataStore.reloginRequired
    }

    /// 前后台切换触发：距上次同步不足 `minimumInterval` 时直接跳过。
    func syncIfNeeded(minimumInterval: TimeInterval = 120, completion: ((Result<Summary, AppError>) -> Void)? = nil) {
        if isSyncing { return }
        if let lastSyncAt = metadataStore.lastSyncAt,
           now().timeIntervalSince(lastSyncAt) < minimumInterval {
            completion?(.success(Summary()))
            return
        }
        sync(completion: completion)
    }

    func sync(completion: ((Result<Summary, AppError>) -> Void)? = nil) {
        guard !isSyncing else {
            completion?(.failure(.sync("上一次同步尚未结束")))
            return
        }
        isSyncing = true
        sessionConflictMessages = []
        status.isSyncing = true
        status.lastError = nil
        notify()

        ensureSession { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(error), completion: completion)

            case .success(let session):
                self.runSync(session: session, summary: Summary(), completion: completion)
            }
        }
    }

    /// 用户确认重新登录：换新的匿名账号，重置游标，并把本机设备全部重新上传。
    ///
    /// 旧账号数据不会自动合并；本机数据保留，只更换云端归属。重复点击由 `isSyncing` 拦截。
    func relogin(completion: ((Result<Summary, AppError>) -> Void)? = nil) {
        guard !isSyncing else {
            completion?(.failure(.sync("上一次同步尚未结束")))
            return
        }
        isSyncing = true
        sessionConflictMessages = []
        status.isSyncing = true
        status.lastError = nil
        notify()

        // 丢弃旧会话与游标，账号标识清空；本地设备数据保留。
        // reloginRequired 保持 true 直到新会话创建成功，避免中途杀进程后自动建号。
        tokenStore.clear()
        metadataStore.resetCursor()
        metadataStore.userID = nil
        metadataStore.reloginRequired = true

        do {
            let requeued = try deviceStore.markAllPendingForRelogin()
            recordLog("重新登录：本地 \(requeued) 条设备将上传到新匿名账号")
        } catch {
            finish(.failure(.database("重新登录前重置同步状态失败：\(error)")), completion: completion)
            return
        }

        api.createAnonymousSession { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // 不恢复旧 token；保持待重新登录，避免下次自动同步静默建号。
                self.metadataStore.reloginRequired = true
                self.status.needsRelogin = true
                self.finish(.failure(error), completion: completion)

            case .success(let session):
                do {
                    try self.tokenStore.save(session)
                } catch {
                    self.recordLog("重新登录成功，但 token 写入 Keychain 失败：\(error)")
                }
                self.metadataStore.userID = session.userID
                self.metadataStore.reloginRequired = false
                self.status.needsRelogin = false
                self.runSync(session: session, summary: Summary(), completion: completion)
            }
        }
    }

    // MARK: - Session

    private func ensureSession(completion: @escaping (Result<AnonymousSession, AppError>) -> Void) {
        if let session = tokenStore.load(), !session.token.isEmpty {
            completion(.success(session))
            return
        }
        // token 已失效且用户尚未确认重新登录：禁止静默新建匿名账号，避免设备归属漂移。
        guard !metadataStore.reloginRequired else {
            completion(.failure(.sync("匿名登录已失效，请在「我的」页重新登录")))
            return
        }
        api.createAnonymousSession { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let session):
                do {
                    try self.tokenStore.save(session)
                } catch {
                    // Keychain 偶发失败不应阻断本次同步，但下次启动需重新匿名登录。
                    self.recordLog("匿名登录成功，但 token 写入 Keychain 失败：\(error)")
                }
                self.metadataStore.userID = session.userID
                completion(.success(session))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 使用给定会话执行「拉取 → 推送」，首次同步与重新登录共用。
    private func runSync(
        session: AnonymousSession,
        summary: Summary,
        completion: ((Result<Summary, AppError>) -> Void)?
    ) {
        metadataStore.userID = session.userID
        pull(
            cursor: metadataStore.cursor,
            token: session.token,
            page: 0,
            summary: summary
        ) { [weak self] pullResult in
            guard let self else { return }
            switch pullResult {
            case .failure(let error):
                self.finish(.failure(error), completion: completion)
            case .success(let summary):
                self.pushPending(
                    token: session.token,
                    summary: summary
                ) { [weak self] pushResult in
                    guard let self else { return }
                    switch pushResult {
                    case .failure(let error):
                        self.finish(.failure(error), completion: completion)
                    case .success(let finalSummary):
                        self.metadataStore.lastSyncAt = self.now()
                        self.finish(.success(finalSummary), completion: completion)
                    }
                }
            }
        }
    }

    // MARK: - Pull

    private func pull(
        cursor: Int64,
        token: String,
        page: Int,
        summary: Summary,
        completion: @escaping (Result<Summary, AppError>) -> Void
    ) {
        api.fetchChanges(cursor: cursor, limit: pageLimit, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))

            case .success(let pageResult):
                var summary = summary
                do {
                    let applied = try self.apply(pageResult.changes)
                    summary.pulled += applied.pulled
                    summary.conflicts += applied.conflicts.count
                    self.sessionConflictMessages.append(contentsOf: applied.conflicts)
                } catch {
                    completion(.failure(.database("应用增量变更失败：\(error)")))
                    return
                }
                self.metadataStore.cursor = pageResult.nextCursor

                if pageResult.hasMore, page + 1 < self.maxPages {
                    self.pull(
                        cursor: pageResult.nextCursor,
                        token: token,
                        page: page + 1,
                        summary: summary,
                        completion: completion
                    )
                } else {
                    completion(.success(summary))
                }
            }
        }
    }

    /// 应用一页变更，返回「实际写入条数」与冲突提示。
    private func apply(_ changes: [SyncChange]) throws -> (pulled: Int, conflicts: [String]) {
        var pulled = 0
        var conflicts: [String] = []

        for change in changes {
            let remote = change.payload
            guard !remote.externalID.isEmpty else { continue }

            let remoteID = UUID(uuidString: remote.id)
            let existing = try deviceStore.fetch(platform: remote.platform, externalID: remote.externalID)
                ?? remoteID.flatMap { try? deviceStore.fetch(id: $0) }

            if change.isDeletion {
                guard let existing else { continue }
                let deletedAt = remote.deletedAt ?? remote.updatedAt
                if existing.syncState != .synced, existing.updatedAt > deletedAt {
                    let message = self.conflictMessage(
                        name: existing.displayName,
                        reason: "本地修改较新，云端删除未生效"
                    )
                    conflicts.append(message)
                    recordLog(message, level: .warning)
                    continue
                }
                try deviceStore.applyRemoteDelete(id: existing.id, at: deletedAt)
                pulled += 1
                continue
            }

            guard let existing else {
                try deviceStore.upsert(remote.makeLocalDevice())
                pulled += 1
                continue
            }

            if existing.syncState == .synced {
                // 缺省字段（nil）表示服务端未上报，不参与比较也不得覆盖本地。
                let aliasChanged = remote.alias.map { $0 != existing.remark } ?? false
                let groupChanged = remote.group.map {
                    ($0.isEmpty ? SavedDevice.defaultGroupName : $0) != existing.groupName
                } ?? false
                let advertisedChanged = remote.advertisedName.map {
                    !$0.isEmpty && $0 != existing.advertisedName
                } ?? false
                if remote.updatedAt > existing.updatedAt || aliasChanged || groupChanged || advertisedChanged {
                    try deviceStore.upsert(merge(remote, into: existing))
                    pulled += 1
                }
            } else if remote.updatedAt > existing.updatedAt {
                // 本地有未上传修改，但云端版本更新：服务端获胜，必须提示而非静默覆盖。
                let message = conflictMessage(
                    name: existing.displayName,
                    reason: "同一台设备在另一台设备上被改过"
                )
                conflicts.append(message)
                recordLog(message, level: .warning)
                try deviceStore.upsert(merge(remote, into: existing))
                pulled += 1
            }
            // 本地更新则保留 pending，后续推送由服务端做最终裁决。
        }

        return (pulled, conflicts)
    }

    // MARK: - Push

    private func pushPending(
        token: String,
        summary: Summary,
        completion: @escaping (Result<Summary, AppError>) -> Void
    ) {
        let pending: [SavedDevice]
        do {
            pending = try deviceStore.fetchPending()
        } catch {
            completion(.failure(.database("读取待上传设备失败：\(error)")))
            return
        }

        guard !pending.isEmpty else {
            completion(.success(summary))
            return
        }

        let chunks = stride(from: 0, to: pending.count, by: 100).map {
            Array(pending[$0..<min($0 + 100, pending.count)])
        }
        push(chunks: chunks, index: 0, token: token, summary: summary, completion: completion)
    }

    private func push(
        chunks: [[SavedDevice]],
        index: Int,
        token: String,
        summary: Summary,
        completion: @escaping (Result<Summary, AppError>) -> Void
    ) {
        guard index < chunks.count else {
            completion(.success(summary))
            return
        }

        let chunk = chunks[index]
        // 排序保证同一批内容得到相同的幂等键；网络失败重试时服务端可命中缓存。
        let devices = chunk.map(PushDevice.init(device:)).sorted { $0.id < $1.id }
        let idempotencyKey = SyncHashing.idempotencyKey(for: devices)

        api.push(
            clientID: metadataStore.clientID,
            token: token,
            idempotencyKey: idempotencyKey,
            devices: devices
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // 保留本地 sync_state 为 pending，下次同步用相同幂等键重试。
                completion(.failure(error))

            case .success(let pushResult):
                var summary = summary
                summary.pushed += pushResult.applied.count
                if pushResult.isIdempotentReplay { summary.idempotentReplays += 1 }

                let ids = chunk.map(\.id)
                do {
                    try self.deviceStore.markSynced(ids: ids, at: self.now())
                    for conflict in pushResult.conflicts {
                        let message = self.applyPushConflict(conflict)
                        summary.conflicts += 1
                        self.sessionConflictMessages.append(message)
                    }
                } catch {
                    completion(.failure(.database("写回同步状态失败：\(error)")))
                    return
                }

                self.push(
                    chunks: chunks,
                    index: index + 1,
                    token: token,
                    summary: summary,
                    completion: completion
                )
            }
        }
    }

    /// 服务端拒绝本地版本时：写回云端版本并返回提示文案，绝不静默丢弃本地修改。
    private func applyPushConflict(_ conflict: SyncConflict) -> String {
        let server = conflict.server
        let serverName = server.displayName.isEmpty ? "设备 \(conflict.externalID)" : server.displayName
        let message = conflictMessage(name: serverName, reason: conflict.reasonText)
        do {
            let remoteID = UUID(uuidString: server.id) ?? UUID(uuidString: conflict.id)
            let existing = try remoteID.flatMap { try deviceStore.fetch(id: $0) }
                ?? deviceStore.fetch(platform: server.platform, externalID: server.externalID)

            if let existing {
                if server.deletedAt != nil {
                    try deviceStore.applyRemoteDelete(id: existing.id, at: server.deletedAt ?? server.updatedAt)
                } else {
                    try deviceStore.upsert(merge(server, into: existing))
                }
            } else if !server.externalID.isEmpty {
                try deviceStore.upsert(server.makeLocalDevice())
            }
            recordLog(message, level: .warning)
        } catch {
            recordLog("冲突写回失败：\(error)", level: .warning)
        }
        return message
    }

    // MARK: - Merge

    /// 把云端字段合并到本地行，保留本地主键 / CoreBluetooth 标识符。
    ///
    /// 缺省字段（nil）表示服务端未上报，保留本地原值；空串表示服务端已显式清除。
    private func merge(_ remote: RemoteDevice, into local: SavedDevice) -> SavedDevice {
        var merged = local
        if let alias = remote.alias, !alias.isEmpty {
            merged.remark = alias
        }
        if let group = remote.group {
            merged.groupName = group.isEmpty ? SavedDevice.defaultGroupName : group
        }
        // 广播名只在服务端有值时回填，避免从未上报过的空串清掉本机扫描结果。
        if let advertised = remote.advertisedName, !advertised.isEmpty {
            merged.advertisedName = advertised
        }
        merged.mac = remote.mac?.isEmpty == false ? remote.mac : local.mac
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        merged.deletedAt = remote.deletedAt
        // 服务端版本已落库，本地待上报的三态全部归零。
        merged.aliasPatch = .absent
        merged.advertisedNamePatch = .absent
        merged.groupPatch = .absent
        merged.syncState = .synced
        return merged
    }

    // MARK: - Finish

    private func finish(
        _ result: Result<Summary, AppError>,
        completion: ((Result<Summary, AppError>) -> Void)?
    ) {
        isSyncing = false
        switch result {
        case .success(let summary):
            status.lastError = nil
            metadataStore.reloginRequired = false
            status.needsRelogin = false
            let base = "同步完成：拉取 \(summary.pulled) 条，上传 \(summary.pushed) 条"
            status.lastOutcomeMessage = summary.conflicts > 0
                ? "\(base)，冲突 \(summary.conflicts) 条（已采用云端版本）"
                : base
            status.lastConflictMessages = sessionConflictMessages

        case .failure(let error):
            status.lastError = error
            status.lastConflictMessages = sessionConflictMessages
            if error.isUnauthorized {
                // 401：token 已失效。保留本地数据与 token，等待用户在「我的」页确认重新登录。
                metadataStore.reloginRequired = true
                status.needsRelogin = true
                status.lastOutcomeMessage = "登录已失效：匿名 token 已过期，请点「重新登录」；本地数据仍可用"
                recordLog("登录已失效（HTTP 401）：等待用户重新登录", level: .warning)
            } else {
                status.lastOutcomeMessage = "同步失败：\(error.code) \(error.message)；本地数据仍可用，稍后自动重试"
                recordLog("同步失败：\(error.code) \(error.message)", level: .warning)
            }
        }

        refreshStatus()
        isSyncing = false
        status.isSyncing = false
        notify()
        completion?(result)
    }

    // MARK: - Helpers

    private func conflictMessage(name: String, reason: String) -> String {
        "另一台设备改过这条：「\(name)」（\(reason)），已采用云端版本"
    }

    private func recordLog(_ message: String, level: ScanLogLevel = .info) {
        let entry = ScanLogEntry(category: .sync, level: level, message: message)
        try? logStore.append(entry)
    }

    private func notify() {
        onChange?()
    }
}
