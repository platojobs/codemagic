import Foundation

/// 场景同步服务：首次全量上传、`GET /scenes` 基线、`change_log` 应用、离线补传与软删。
protocol SceneSyncServicing: AnyObject {
    /// 场景数据发生变化（同步成功或离线编辑后），用于刷新通知调度与界面。
    var onScenesChanged: (() -> Void)? { get set }

    func prepare(token: String, completion: @escaping (Result<Void, AppError>) -> Void)
    func apply(_ change: SyncChange) throws -> Bool
    func pushPending(token: String, completion: @escaping (Result<Int, AppError>) -> Void)
    func pendingCount() -> Int
}

final class SceneSyncService: SceneSyncServicing {
    var onScenesChanged: (() -> Void)?

    private let api: SceneAPIServicing
    private let store: SceneStore
    private let logStore: ScanLogStore
    private let now: () -> Date

    init(
        api: SceneAPIServicing,
        store: SceneStore,
        logStore: ScanLogStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.store = store
        self.logStore = logStore
        self.now = now
    }

    // MARK: - Baseline

    /// `GET /scenes` 作为基线：先合并服务端全量快照，再对本地已同步但基线缺失的场景做软删。
    func prepare(token: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        api.listScenes(token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let remotes):
                do {
                    for remote in remotes {
                        try self.store.applyRemote(remote, now: self.now())
                    }
                    let remoteIDs = Set(remotes.map(\.id))
                    let locals = try self.store.fetchAll()
                    for local in locals where local.remoteID != nil {
                        if !remoteIDs.contains(local.remoteID ?? "") {
                            try self.store.markRemoteMissing(remoteID: local.remoteID ?? "", now: self.now())
                        }
                    }
                    self.notifyChanged()
                    completion(.success(()))
                } catch {
                    completion(.failure(.database(L10n.f("scene.sync.applyFailed", String(describing: error)))))
                }
            }
        }
    }

    // MARK: - change_log

    /// `scene` 实体：upsert 走字段级合并，delete 走软删；未知实体不在这里处理。
    @discardableResult
    func apply(_ change: SyncChange) throws -> Bool {
        guard change.entity == SyncEntity.scene, let remote = change.sceneChange else { return false }
        let snapshot: RemoteScene
        if change.op == "delete", remote.deletedAt == nil {
            snapshot = RemoteScene(
                id: remote.id,
                name: remote.name,
                enabled: remote.enabled,
                cooldownSeconds: remote.cooldownSeconds,
                trigger: remote.trigger,
                actions: remote.actions,
                version: remote.version,
                deviceMissing: remote.deviceMissing,
                createdAt: remote.createdAt,
                updatedAt: remote.updatedAt,
                deletedAt: change.serverTimestamp ?? now()
            )
        } else {
            snapshot = remote
        }
        let applied = try store.applyRemote(snapshot, now: now())
        if applied { notifyChanged() }
        return true
    }

    // MARK: - Push

    func pushPending(token: String, completion: @escaping (Result<Int, AppError>) -> Void) {
        let pending: [Scene]
        do {
            pending = try store.fetchPending()
        } catch {
            completion(.failure(.database(L10n.f("scene.sync.fetchFailed", String(describing: error)))))
            return
        }
        guard !pending.isEmpty else {
            completion(.success(0))
            return
        }

        // 服务端没有幂等键：先拉一次远端列表，用内容签名认领「POST 响应丢失」留下的孤儿场景，
        // 避免重试时重复创建；之后每个场景再按本地 remoteId 决定 POST 还是 PUT。
        if pending.contains(where: { $0.remoteID == nil }) {
            api.listScenes(token: token) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let remotes):
                    do {
                        let adopted = try self.reconcileOrphans(pending, remotes: remotes)
                        let remaining = try self.store.fetchPending()
                        self.upload(remaining, adoptedCount: adopted, index: 0, token: token, completion: completion)
                    } catch {
                        completion(.failure(.database(L10n.f("scene.sync.reconcileFailed", String(describing: error)))))
                    }
                }
            }
            return
        }

        upload(pending, adoptedCount: 0, index: 0, token: token, completion: completion)
    }

    func pendingCount() -> Int {
        (try? store.pendingCount()) ?? 0
    }

    // MARK: - Private

    /// 为没有 remoteId 的本地场景匹配内容完全一致且未被其他本地行认领的远端场景。
    /// 只会认领唯一候选，多个同名同内容场景保持 pending，交给 POST 处理。
    private func reconcileOrphans(_ pending: [Scene], remotes: [RemoteScene]) throws -> Int {
        var usedRemoteIDs = Set<String>()
        for local in try store.fetchAll(includeDeleted: true) {
            if let remoteID = local.remoteID { usedRemoteIDs.insert(remoteID) }
        }
        var adopted = 0
        for local in pending where local.remoteID == nil && local.deletedAt == nil {
            let candidates = remotes.filter {
                $0.deletedAt == nil
                    && !usedRemoteIDs.contains($0.id)
                    && $0.contentSignature == local.contentSignature
            }
            guard candidates.count == 1, let remote = candidates.first else { continue }
            try store.markCreated(localID: local.id, remote: remote, now: now())
            usedRemoteIDs.insert(remote.id)
            adopted += 1
        }
        if adopted > 0 {
            recordLog(L10n.f("scene.sync.reconciled", String(adopted)))
            notifyChanged()
        }
        return adopted
    }

    private func upload(
        _ pending: [Scene],
        adoptedCount: Int,
        index: Int,
        token: String,
        completion: @escaping (Result<Int, AppError>) -> Void
    ) {
        guard index < pending.count else {
            completion(.success(adoptedCount))
            return
        }
        let scene = pending[index]
        uploadOne(scene, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.upload(
                    pending,
                    adoptedCount: adoptedCount + 1,
                    index: index + 1,
                    token: token,
                    completion: completion
                )
            }
        }
    }

    private func uploadOne(_ scene: Scene, token: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        if scene.syncState == .pendingDelete, let remoteID = scene.remoteID {
            api.deleteScene(token: token, id: remoteID) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    do {
                        try self.store.markDeleteSynced(id: scene.id, now: self.now())
                        self.notifyChanged()
                        completion(.success(()))
                    } catch {
                        completion(.failure(.database(L10n.f("scene.sync.markFailed", String(describing: error)))))
                    }
                case .failure(let error):
                    if error.statusCode == 404 {
                        try? self.store.markDeleteSynced(id: scene.id, now: self.now())
                        self.notifyChanged()
                        completion(.success(()))
                    } else {
                        completion(.failure(error))
                    }
                }
            }
            return
        }

        guard let remoteID = scene.remoteID else {
            let input = SceneCreateInput(
                name: scene.name,
                enabled: scene.enabled,
                cooldownSeconds: scene.cooldownSeconds,
                trigger: scene.trigger,
                actions: scene.actions
            )
            api.createScene(token: token, input: input) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let remote):
                    do {
                        try self.store.markCreated(localID: scene.id, remote: remote, now: self.now())
                        self.notifyChanged()
                        completion(.success(()))
                    } catch {
                        completion(.failure(.database(L10n.f("scene.sync.markFailed", String(describing: error)))))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            return
        }

        let patch = ScenePatchInput(scene: scene)
        if patch.isEmpty {
            do {
                try store.markSynced(id: scene.id, now: now())
                notifyChanged()
                completion(.success(()))
            } catch {
                completion(.failure(.database(L10n.f("scene.sync.markFailed", String(describing: error)))))
            }
            return
        }
        api.updateScene(token: token, id: remoteID, patch: patch) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let remote):
                do {
                    try self.store.applyServerResponse(remote, now: self.now())
                    self.notifyChanged()
                    completion(.success(()))
                } catch {
                    completion(.failure(.database(L10n.f("scene.sync.markFailed", String(describing: error)))))
                }
            case .failure(let error):
                if error.statusCode == 404 {
                    // 远端已删除：本地 tombstone 直接落定，不重试。
                    try? self.store.markDeleteSynced(id: scene.id, now: self.now())
                    self.notifyChanged()
                    completion(.success(()))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    private func recordLog(_ message: String, level: ScanLogLevel = .info) {
        try? logStore.append(ScanLogEntry(category: .sync, level: level, message: message))
    }

    private func notifyChanged() {
        onScenesChanged?()
    }
}

private extension RemoteScene {
    var contentSignature: String? {
        guard let trigger else { return nil }
        return Scene.signature(
            name: name,
            enabled: enabled,
            cooldownSeconds: cooldownSeconds,
            trigger: trigger,
            actions: actions
        )
    }
}

private extension AppError {
    var statusCode: Int? {
        if case .api(_, let statusCode, _) = self { return statusCode }
        if case .server(let statusCode) = self { return statusCode }
        return nil
    }
}
