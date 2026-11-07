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
        var pushedReadings: Int = 0
        var skippedReadings: Int = 0
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
        /// 会话到期时间（服务端 180 天 TTL）；仅用于「我的」页只读展示。
        var sessionExpiresAt: Date?
    }

    private(set) var status = Status()
    var onChange: (() -> Void)?
    /// 会话就绪（首次匿名登录成功 / 已有 token 可用 / 重新登录成功）时回调。
    /// 推送令牌注册依赖它，避免在还没有 Bearer 时发起请求。
    var onSessionReady: (() -> Void)?

    private let api: SyncAPIServicing
    private let tokenStore: TokenStoring
    private let metadataStore: SyncMetadataStore
    private let deviceStore: SavedDeviceStore
    private let readingsStore: ReadingsStore
    private let logStore: ScanLogStore
    /// 家庭 / 房间 / 设备归属协调器；未配置时退化为纯设备同步（老版本行为）。
    private let householdService: HouseholdService?
    /// 服务端场景同步；未配置时场景只保留本地。
    private let sceneSync: SceneSyncServicing?
    private let now: () -> Date
    private let pageLimit: Int
    private let maxPages: Int

    private var isSyncing = false
    private var sessionConflictMessages: [String] = []
    /// 本轮同步是否发生了 410 全量重同步；用于在结果文案中明确提示。
    private var didFullResync = false
    /// 可重试失败（网络 / 5xx / TIMEOUT / 限流）的连续次数，用于指数退避。
    private var retryFailureCount = 0
    /// 自动同步的退避闸门：未到点前 `syncIfNeeded` 直接跳过；手动同步不受限。
    private var nextAutomaticRetryAt: Date?
    /// 增量里出现本地未知的家庭（如刚被邀请加入）：本轮拉取结束后补一次 `GET /households` 全量基线。
    private var needsHouseholdBaseline = false

    init(
        api: SyncAPIServicing,
        tokenStore: TokenStoring,
        metadataStore: SyncMetadataStore,
        deviceStore: SavedDeviceStore,
        readingsStore: ReadingsStore,
        logStore: ScanLogStore,
        householdService: HouseholdService? = nil,
        sceneSync: SceneSyncServicing? = nil,
        pageLimit: Int = 200,
        maxPages: Int = 10,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.metadataStore = metadataStore
        self.deviceStore = deviceStore
        self.readingsStore = readingsStore
        self.logStore = logStore
        self.householdService = householdService
        self.sceneSync = sceneSync
        // 服务端 changes 上限 500，客户端自己收敛，避免越界 400。
        self.pageLimit = APILimits.clamp(pageLimit, to: APILimits.changes)
        self.maxPages = maxPages
        self.now = now
        refreshStatus()
    }

    // MARK: - Public

    func refreshStatus() {
        let pending = (try? deviceStore.pendingCount()) ?? 0
        status.userID = metadataStore.userID ?? tokenStore.load()?.userID
        status.lastSyncAt = metadataStore.lastSyncAt
        status.pendingCount = pending + (sceneSync?.pendingCount() ?? 0)
        status.isSyncing = isSyncing
        status.needsRelogin = metadataStore.reloginRequired
        status.sessionExpiresAt = metadataStore.sessionExpiresAt
    }

    /// 前后台切换触发：距上次同步不足 `minimumInterval` 时直接跳过。
    func syncIfNeeded(minimumInterval: TimeInterval = 120, completion: ((Result<Summary, AppError>) -> Void)? = nil) {
        if isSyncing { return }
        // 失败后的指数退避闸门：未到点前不再自动发起，避免对 503 连续打点。
        if let nextAutomaticRetryAt, now() < nextAutomaticRetryAt {
            completion?(.success(Summary()))
            return
        }
        if let lastSyncAt = metadataStore.lastSyncAt,
           now().timeIntervalSince(lastSyncAt) < minimumInterval {
            completion?(.success(Summary()))
            return
        }
        sync(completion: completion)
    }

    func sync(completion: ((Result<Summary, AppError>) -> Void)? = nil) {
        guard !isSyncing else {
            completion?(.failure(.sync(L10n.t("sync.busy"))))
            return
        }
        isSyncing = true
        sessionConflictMessages = []
        didFullResync = false
        needsHouseholdBaseline = false
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

    /// 后台唤醒的轻量同步：只推送、不拉取，限制单次批量，且受最小间隔节流。
    ///
    /// 后台不得发起大量网络请求：无 token 时直接跳过（不静默建号），
    /// 单次最多 100 台设备 / 200 条读数，并以 `lastBackgroundPushAt` 保证失败也不会被连续唤醒放大。
    func pushPendingInBackground(
        minimumInterval: TimeInterval = 15 * 60,
        readingLimit: Int = 200,
        deviceLimit: Int = 100,
        completion: ((Result<Summary, AppError>) -> Void)? = nil
    ) {
        guard !isSyncing else {
            completion?(.failure(.sync(L10n.t("sync.busy"))))
            return
        }
        guard let session = tokenStore.load(), !session.token.isEmpty else {
            // 后台不创建匿名账号；留给用户回到前台后的显式同步。
            completion?(.success(Summary()))
            return
        }
        if let last = metadataStore.lastBackgroundPushAt,
           now().timeIntervalSince(last) < minimumInterval {
            completion?(.success(Summary()))
            return
        }
        metadataStore.lastBackgroundPushAt = now()

        isSyncing = true
        sessionConflictMessages = []
        status.isSyncing = true
        status.lastError = nil
        notify()

        pushPending(
            token: session.token,
            summary: Summary(),
            readingsLimit: readingLimit,
            deviceLimit: deviceLimit
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let summary):
                self.metadataStore.lastSyncAt = self.now()
                self.finish(.success(summary), completion: completion)
            case .failure(let error):
                self.finish(.failure(error), completion: completion)
            }
        }
    }

    /// 用户确认重新登录：换新的匿名账号，重置游标，并把本机设备全部重新上传。
    ///
    /// 旧账号数据不会自动合并；本机数据保留，只更换云端归属。重复点击由 `isSyncing` 拦截。
    func relogin(completion: ((Result<Summary, AppError>) -> Void)? = nil) {
        guard !isSyncing else {
            completion?(.failure(.sync(L10n.t("sync.busy"))))
            return
        }
        isSyncing = true
        sessionConflictMessages = []
        needsHouseholdBaseline = false
        status.isSyncing = true
        status.lastError = nil
        notify()

        // 丢弃旧会话与游标，账号标识清空；本地设备数据保留。
        // reloginRequired 保持 true 直到新会话创建成功，避免中途杀进程后自动建号。
        tokenStore.clear()
        metadataStore.resetCursor()
        metadataStore.userID = nil
        metadataStore.sessionExpiresAt = nil
        metadataStore.reloginRequired = true

        do {
            let requeued = try deviceStore.markAllPendingForRelogin()
            recordLog(L10n.f("sync.reloginRequeue", String(describing: requeued)))
        } catch {
            finish(.failure(.database(L10n.f("sync.reloginResetFailed", String(describing: error)))), completion: completion)
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
                    self.recordLog(L10n.f("sync.reloginKeychainFailed", String(describing: error)))
                }
                self.metadataStore.userID = session.userID
                self.metadataStore.sessionExpiresAt = session.expiresAt
                self.metadataStore.reloginRequired = false
                self.status.needsRelogin = false
                self.sessionDidBecomeReady()
                self.runSync(session: session, summary: Summary(), completion: completion)
            }
        }
    }

    // MARK: - Session

    private func sessionDidBecomeReady() {
        DispatchQueue.main.async { [weak self] in
            self?.onSessionReady?()
        }
    }

    private func ensureSession(completion: @escaping (Result<AnonymousSession, AppError>) -> Void) {
        if let session = tokenStore.load(), !session.token.isEmpty {
            sessionDidBecomeReady()
            completion(.success(session))
            return
        }
        // token 已失效且用户尚未确认重新登录：禁止静默新建匿名账号，避免设备归属漂移。
        guard !metadataStore.reloginRequired else {
            completion(.failure(.sync(L10n.t("sync.reloginRequired"))))
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
                    self.recordLog(L10n.f("sync.loginKeychainFailed", String(describing: error)))
                }
                self.metadataStore.userID = session.userID
                self.metadataStore.sessionExpiresAt = session.expiresAt
                self.sessionDidBecomeReady()
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
        // 先拉家庭 / 房间并补报上次失败的归属，再做增量拉取；家庭接口失败不阻断设备同步。
        prepareHouseholds(token: session.token) { [weak self] in
            guard let self else { return }
            self.prepareScenes(token: session.token) {
                self.pull(
                    cursor: self.metadataStore.cursor,
                    token: session.token,
                    page: 0,
                    summary: summary,
                    hasResynced: false
                ) { pullResult in
                    switch pullResult {
                    case .failure(let error):
                        self.finish(.failure(error), completion: completion)
                    case .success(let summary):
                        self.pushPending(
                            token: session.token,
                            summary: summary
                        ) { pushResult in
                            switch pushResult {
                            case .failure(let error):
                                self.finish(.failure(error), completion: completion)
                            case .success(let finalSummary):
                                self.pushScenes(token: session.token, summary: finalSummary) { sceneResult in
                                    switch sceneResult {
                                    case .failure(let error):
                                        self.finish(.failure(error), completion: completion)
                                    case .success(let withScenes):
                                        self.flushAssignments(token: session.token) {
                                            self.metadataStore.lastSyncAt = self.now()
                                            self.finish(.success(withScenes), completion: completion)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `GET /scenes` 基线。失败不阻断设备同步：增量拉取仍会带回场景变更，
    /// 推送阶段也会再次尝试上传；401 由后续拉取统一处理。
    private func prepareScenes(token: String, completion: @escaping () -> Void) {
        guard let sceneSync else {
            completion()
            return
        }
        sceneSync.prepare(token: token) { [weak self] result in
            if case .failure(let error) = result {
                self?.recordLog(
                    L10n.f("scene.sync.baselineFailed", error.code, error.message),
                    level: .warning
                )
            }
            completion()
        }
    }

    /// 场景推送在设备推送之后：即使场景接口失败，设备与读数也已落库。
    private func pushScenes(
        token: String,
        summary: Summary,
        completion: @escaping (Result<Summary, AppError>) -> Void
    ) {
        guard let sceneSync else {
            completion(.success(summary))
            return
        }
        sceneSync.pushPending(token: token) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let count):
                var summary = summary
                summary.pushed += count
                completion(.success(summary))
            }
        }
    }

    /// 家庭准备阶段失败不阻断设备同步；401 由后续拉取统一处理（避免双次 finish）。
    private func prepareHouseholds(token: String, completion: @escaping () -> Void) {
        guard let householdService else {
            completion()
            return
        }
        householdService.prepareForSync(token: token) { _ in
            completion()
        }
    }

    private func flushAssignments(token: String, completion: @escaping () -> Void) {
        guard let householdService else {
            completion()
            return
        }
        householdService.flushPendingAssignments(token: token, completion: completion)
    }

    // MARK: - Pull

    /// 增量拉取。`hasResynced` 保证 410 只处理一次：第二次仍 410 直接失败，不再循环。
    private func pull(
        cursor: Int64,
        token: String,
        page: Int,
        summary: Summary,
        hasResynced: Bool,
        completion: @escaping (Result<Summary, AppError>) -> Void
    ) {
        api.fetchChanges(cursor: cursor, limit: pageLimit, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error) where error.isResyncRequired && !hasResynced:
                self.handleResyncRequired(token: token, summary: summary, completion: completion)

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
                    completion(.failure(.database(L10n.f("sync.applyChangesFailed", String(describing: error)))))
                    return
                }
                // 未知实体也在 apply 中被跳过；游标照常推进，绝不阻塞后续实体。
                self.metadataStore.cursor = pageResult.nextCursor

                if pageResult.hasMore, page + 1 < self.maxPages {
                    self.pull(
                        cursor: pageResult.nextCursor,
                        token: token,
                        page: page + 1,
                        summary: summary,
                        hasResynced: hasResynced,
                        completion: completion
                    )
                } else if self.needsHouseholdBaseline, let householdService = self.householdService {
                    // 本地缺失家庭（如刚被邀请加入）：后端不回放历史，补一次全量基线。
                    self.needsHouseholdBaseline = false
                    householdService.refreshHouseholds { _ in
                        completion(.success(summary))
                    }
                } else {
                    completion(.success(summary))
                }
            }
        }
    }

    /// 410 `RESYNC_REQUIRED`：游标早于服务端最老保留行。
    ///
    /// 处理语义与首次拉取完全一致：
    /// 1. 游标与同步元数据归零（`resetCursor()` 只清 cursor / lastSyncAt）；
    /// 2. 本地 pending 设备与读数**不清理**，全量拉取后仍会由 `pushPending` 重新上传；
    /// 3. 以 `cursor=0` 重新拉取，合并规则复用 `apply`；
    /// 4. 属终态分支，不进指数退避，且只处理一次（再次 410 直接失败）。
    private func handleResyncRequired(
        token: String,
        summary: Summary,
        completion: @escaping (Result<Summary, AppError>) -> Void
    ) {
        didFullResync = true
        metadataStore.resetCursor()
        recordLog(L10n.t("sync.cursorExpired"), level: .warning)
        pull(
            cursor: 0,
            token: token,
            page: 0,
            summary: summary,
            hasResynced: true,
            completion: completion
        )
    }

    /// 应用一页变更，返回「实际写入条数」与冲突提示。
    ///
    /// 未知 `entity` 必须在 while 循环内被忽略，但**不得影响游标推进**（游标由 `pull` 无条件写入）。
    private func apply(_ changes: [SyncChange]) throws -> (pulled: Int, conflicts: [String]) {
        var pulled = 0
        var conflicts: [String] = []

        for change in changes {
            switch change.entity {
            case SyncEntity.household:
                guard let householdService, let payload = change.householdChange else { continue }
                if householdService.applyHouseholdChange(payload) == .needsBaseline {
                    needsHouseholdBaseline = true
                }
                pulled += 1
                continue

            case SyncEntity.room:
                guard let householdService, let payload = change.roomChange else { continue }
                if householdService.applyRoomChange(payload) == .needsBaseline {
                    needsHouseholdBaseline = true
                }
                pulled += 1
                continue

            case SyncEntity.scene:
                guard let sceneSync else { continue }
                _ = try sceneSync.apply(change)
                pulled += 1
                continue

            default:
                // 未知实体：跳过，但循环继续、游标照常推进。
                guard change.isDeviceEntity else { continue }
            }

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
                        reason: L10n.t("sync.conflict.localNewer")
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
                var local = remote.makeLocalDevice()
                applyAssignment(remote, to: &local)
                try deviceStore.upsert(local)
                pulled += 1
                continue
            }

            // 契约 0.21.0：lastSeenAt 是服务端只读派生字段，键缺省时不得覆盖本地。
            let lastSeenChanged = remote.hasLastSeenAtField
                && remote.serverLastSeenAt != existing.serverLastSeenAt
            if existing.syncState == .synced {
                // 缺省字段（nil）表示服务端未上报，不参与比较也不得覆盖本地。
                let aliasChanged = remote.alias.map { $0 != existing.remark } ?? false
                let groupChanged = remote.group.map {
                    ($0.isEmpty ? SavedDevice.defaultGroupName : $0) != existing.groupName
                } ?? false
                let advertisedChanged = remote.advertisedName.map {
                    !$0.isEmpty && $0 != existing.advertisedName
                } ?? false
                // 标记同样是字段级 LWW：键缺省保持本地，null 表示取消，时间表示标记。
                let markedChanged: Bool
                switch remote.markedAt {
                case .absent: markedChanged = false
                case .clear: markedChanged = existing.markedAt != nil
                case .set(let date): markedChanged = existing.markedAt != date
                }
                let assignmentChanged = !hasPendingAssignment(existing.id) && (
                    (remote.hasRoomField && remote.roomID != existing.remoteRoomID)
                        || (remote.householdID != nil && remote.householdID != existing.remoteHouseholdID)
                )
                if remote.updatedAt > existing.updatedAt || aliasChanged || groupChanged
                    || advertisedChanged || markedChanged || assignmentChanged || lastSeenChanged {
                    try deviceStore.upsert(merge(remote, into: existing))
                    pulled += 1
                }
            } else if remote.updatedAt > existing.updatedAt {
                // 本地有未上传修改，但云端版本更新：服务端获胜，必须提示而非静默覆盖。
                let message = conflictMessage(
                    name: existing.displayName,
                    reason: L10n.t("sync.conflict.changedElsewhere")
                )
                conflicts.append(message)
                recordLog(message, level: .warning)
                try deviceStore.upsert(merge(remote, into: existing))
                pulled += 1
            } else if lastSeenChanged {
                // 本地仍有待上传修改，且云端版本没有前进：只写只读的 lastSeenAt，
                // 保持 pending 与 updatedAt 不变，避免凭空产生同步脏位或 LWW 冲突。
                try deviceStore.applyServerLastSeenAt(id: existing.id, at: remote.serverLastSeenAt)
                pulled += 1
            }
            // 本地更新则保留 pending，后续推送由服务端做最终裁决。
        }

        return (pulled, conflicts)
    }

    // MARK: - Push

    /// 一个批次内包含设备与读数：设备 ≤100、读数 ≤200；两者共用同一个幂等键与请求体。
    /// 读数与设备无关时，后续批次 devices 为空数组，仍是同一 `/sync/push` 契约。
    private struct PushBatch {
        let devices: [SavedDevice]
        let readings: [DeviceReading]
    }

    private func pushPending(
        token: String,
        summary: Summary,
        readingsLimit: Int? = nil,
        deviceLimit: Int? = nil,
        completion: @escaping (Result<Summary, AppError>) -> Void
    ) {
        let pendingDevices: [SavedDevice]
        let pendingReadings: [DeviceReading]
        do {
            pendingDevices = try deviceStore.fetchPending(limit: deviceLimit)
            pendingReadings = try readingsStore.fetchPending(limit: readingsLimit)
        } catch {
            completion(.failure(.database(L10n.f("sync.readPendingFailed", String(describing: error)))))
            return
        }

        guard !pendingDevices.isEmpty || !pendingReadings.isEmpty else {
            pruneReadings()
            completion(.success(summary))
            return
        }

        var batches: [PushBatch] = []
        var deviceIndex = 0
        var readingIndex = 0
        while deviceIndex < pendingDevices.count || readingIndex < pendingReadings.count {
            let deviceEnd = min(deviceIndex + 100, pendingDevices.count)
            let readingEnd = min(readingIndex + 200, pendingReadings.count)
            batches.append(
                PushBatch(
                    devices: Array(pendingDevices[deviceIndex..<deviceEnd]),
                    readings: Array(pendingReadings[readingIndex..<readingEnd])
                )
            )
            deviceIndex = deviceEnd
            readingIndex = readingEnd
        }
        push(batches: batches, index: 0, token: token, summary: summary, completion: completion)
    }

    private func push(
        batches: [PushBatch],
        index: Int,
        token: String,
        summary: Summary,
        completion: @escaping (Result<Summary, AppError>) -> Void
    ) {
        guard index < batches.count else {
            pruneReadings()
            completion(.success(summary))
            return
        }

        let batch = batches[index]
        let devices = batch.devices.map(PushDevice.init(device:)).sorted { $0.id < $1.id }
        let readings = makeReadingPayloads(batch.readings)

        // 排序保证同一批内容得到相同的幂等键；网络失败重试时服务端可命中缓存。
        let idempotencyKey = SyncHashing.idempotencyKey(for: devices, readings: readings)

        api.push(
            clientID: metadataStore.clientID,
            token: token,
            idempotencyKey: idempotencyKey,
            devices: devices,
            readings: readings
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // 保留本地 sync_state 为 pending，下次同步用相同幂等键重试。
                completion(.failure(error))

            case .success(let pushResult):
                var summary = summary
                summary.pushed += pushResult.applied.count
                summary.pushedReadings += pushResult.appliedReadings
                summary.skippedReadings += pushResult.skippedReadings
                if pushResult.isIdempotentReplay { summary.idempotentReplays += 1 }

                do {
                    try self.deviceStore.markSynced(ids: batch.devices.map(\.id), at: self.now())
                    // 只有真正进入请求体的读数才标记已同步；无法归属的读数保持待上传。
                    try self.readingsStore.markSynced(
                        ids: readings.compactMap { UUID(uuidString: $0.id) },
                        at: self.now()
                    )
                    for conflict in pushResult.conflicts {
                        let message = self.applyPushConflict(conflict)
                        summary.conflicts += 1
                        self.sessionConflictMessages.append(message)
                    }
                } catch {
                    completion(.failure(.database(L10n.f("sync.writeStatusFailed", String(describing: error)))))
                    return
                }

                self.push(
                    batches: batches,
                    index: index + 1,
                    token: token,
                    summary: summary,
                    completion: completion
                )
            }
        }
    }

    /// 读数需要设备的 `platform` / `externalId` 才能构造推送条目。
    /// 设备被删除后其读数没有上报意义，直接清理，避免无限累积。
    private func makeReadingPayloads(_ readings: [DeviceReading]) -> [PushReading] {
        var devices: [UUID: SavedDevice] = [:]
        var orphanDeviceIDs: Set<UUID> = []
        for reading in readings {
            if let cached = devices[reading.deviceID] {
                if cached.deletedAt != nil { orphanDeviceIDs.insert(reading.deviceID) }
                continue
            }
            guard let device = try? deviceStore.fetch(id: reading.deviceID) else { continue }
            devices[reading.deviceID] = device
            if device.deletedAt != nil { orphanDeviceIDs.insert(reading.deviceID) }
        }
        for deviceID in orphanDeviceIDs {
            try? readingsStore.deleteAll(deviceID: deviceID)
        }
        return readings
            .compactMap { reading in
                guard let device = devices[reading.deviceID], device.deletedAt == nil else { return nil }
                return PushReading(reading: reading, device: device)
            }
            .sorted { $0.id < $1.id }
    }

    /// 同步成功后执行 7 天清理；启动时的清理在 `AppEnvironment` 完成。
    private func pruneReadings() {
        let cutoff = now().addingTimeInterval(-7 * 24 * 60 * 60)
        guard let removed = try? readingsStore.prune(olderThan: cutoff), removed > 0 else { return }
        recordLog(L10n.f("sync.purgeReadings", String(describing: removed)))
    }

    /// 服务端拒绝本地版本时：写回云端版本并返回提示文案，绝不静默丢弃本地修改。
    private func applyPushConflict(_ conflict: SyncConflict) -> String {
        let server = conflict.server
        let serverName = server.displayName.isEmpty ? L10n.f("sync.conflict.device", String(describing: conflict.externalID)) : server.displayName
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
            recordLog(L10n.f("sync.writeConflictFailed", String(describing: error)), level: .warning)
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
        switch remote.markedAt {
        case .absent:
            break
        case .clear:
            merged.markedAt = nil
        case .set(let date):
            merged.markedAt = date
        }
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        if remote.hasLastSeenAtField {
            // 只接受服务端值；本地不得自行推进或把它当作可写字段。
            merged.serverLastSeenAt = remote.serverLastSeenAt
        }
        merged.deletedAt = remote.deletedAt
        // 服务端版本已落库，本地待上报的三态全部归零。
        merged.aliasPatch = .absent
        merged.advertisedNamePatch = .absent
        merged.groupPatch = .absent
        merged.markedAtPatch = .absent
        merged.syncState = .synced
        applyAssignment(remote, to: &merged)
        return merged
    }

    /// 把服务端归属映射到本机：本地有待上报的移动时不覆盖用户刚改的归属。
    private func applyAssignment(_ remote: RemoteDevice, to device: inout SavedDevice) {
        guard let householdService, remote.householdID != nil || remote.hasRoomField else { return }
        if hasPendingAssignment(device.id) { return }
        if let remoteHouseholdID = remote.householdID {
            let householdID = householdService.localize(remoteHouseholdID: remoteHouseholdID, remoteRoomID: nil).householdID
            device.householdID = householdID
            device.remoteHouseholdID = remoteHouseholdID
        }
        if remote.hasRoomField {
            device.remoteRoomID = remote.roomID
            device.roomID = householdService.localRoomID(remoteID: remote.roomID)
        }
    }

    private func hasPendingAssignment(_ deviceID: UUID) -> Bool {
        householdService?.hasPendingAssignment(deviceID: deviceID) ?? false
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
            retryFailureCount = 0
            nextAutomaticRetryAt = nil
            let base = L10n.f("sync.summary.synced", String(describing: summary.pulled), String(describing: summary.pushed))
            var message = summary.conflicts > 0
                ? L10n.f("sync.summary.conflicts", String(describing: base), String(describing: summary.conflicts))
                : base
            if summary.pushedReadings > 0 || summary.skippedReadings > 0 {
                message += L10n.f("sync.summary.readings", String(describing: summary.pushedReadings), String(describing: summary.skippedReadings))
            }
            // 410 全量重同步不得静默：结果文案必须明确告知用户。
            status.lastOutcomeMessage = didFullResync
                ? L10n.f("sync.resyncDone", String(describing: message))
                : message
            status.lastConflictMessages = sessionConflictMessages
            status.sessionExpiresAt = metadataStore.sessionExpiresAt

        case .failure(let error):
            status.lastError = error
            status.lastConflictMessages = sessionConflictMessages
            if error.isUnauthorized {
                // 401：token 已失效。保留本地数据与 token，等待用户在「我的」页确认重新登录。
                metadataStore.reloginRequired = true
                status.needsRelogin = true
                retryFailureCount = 0
                nextAutomaticRetryAt = nil
                status.lastOutcomeMessage = L10n.t("sync.sessionExpiredDetail")
                recordLog(L10n.t("sync.awaitRelogin"), level: .warning)
            } else if error.isResyncRequired {
                // 已重同步一次仍失败：终态，不进退避、不重复处理。
                nextAutomaticRetryAt = nil
                let prefix = didFullResync ? L10n.t("sync.resyncFailedPrefix") : ""
                status.lastOutcomeMessage = L10n.f("sync.failureWithLocal", String(describing: prefix), String(describing: error.code), String(describing: error.message))
                recordLog(L10n.f("sync.resyncError", String(describing: error.code), String(describing: error.message)), level: .warning)
            } else if error.isRetryable {
                // 网络 / 5xx 指数退避；429 完全按服务端 `Retry-After`，绝不按 410 处理。
                retryFailureCount += 1
                let delay = error.retryAfterSeconds.map(TimeInterval.init)
                    ?? Self.retryDelay(failureCount: retryFailureCount)
                nextAutomaticRetryAt = now().addingTimeInterval(delay)
                let prefix = didFullResync ? L10n.t("sync.resyncThenFail") : L10n.t("sync.failedPrefix")
                status.lastOutcomeMessage = L10n.f("sync.failureRetry", String(describing: prefix), String(describing: error.code), String(describing: error.message), String(describing: Int(delay)))
                recordLog(L10n.f("sync.retryAttempt", String(describing: retryFailureCount), String(describing: error.code), String(describing: error.message)), level: .warning)
            } else {
                retryFailureCount = 0
                nextAutomaticRetryAt = nil
                let prefix = didFullResync ? L10n.t("sync.resyncThenFail") : L10n.t("sync.failedPrefix")
                status.lastOutcomeMessage = L10n.f("sync.failureWithLocal", String(describing: prefix), String(describing: error.code), String(describing: error.message))
                recordLog(L10n.f("sync.failed", String(describing: error.code), String(describing: error.message)), level: .warning)
            }
        }

        refreshStatus()
        isSyncing = false
        status.isSyncing = false
        notify()
        completion?(result)
    }

    // MARK: - Helpers

    /// 30s 起步、逐次翻倍、上限 5 分钟；仅用于可重试失败。
    private static func retryDelay(failureCount: Int) -> TimeInterval {
        let exponent = max(failureCount - 1, 0)
        return min(pow(2, Double(exponent)) * 30, 300)
    }

    private func conflictMessage(name: String, reason: String) -> String {
        L10n.f("sync.conflict.message", String(describing: name), String(describing: reason))
    }

    private func recordLog(_ message: String, level: ScanLogLevel = .info) {
        let entry = ScanLogEntry(category: .sync, level: level, message: message)
        try? logStore.append(entry)
    }

    private func notify() {
        onChange?()
    }
}
