import XCTest
@testable import codemagic

/// 场景同步：首次全量上传、基线合并、字段级 LWW、离线补传、软删与 `change_log`。
final class SceneSyncTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var store: SceneStore!
    private var logStore: ScanLogStore!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        store = SceneStore(database: testDatabase.database)
        logStore = ScanLogStore(database: testDatabase.database)
    }

    override func tearDownWithError() throws {
        testDatabase.cleanUp()
    }

    // MARK: - First upload

    func testFirstUploadPostsEveryLocalSceneAndWritesBackRemoteID() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        try store.insert(makeScene(name: "回家"), now: Date(timeIntervalSince1970: 1_000))
        try store.insert(
            makeScene(
                name: "夜间静音",
                trigger: .schedule(timeOfDay: "23:00", timezone: "Asia/Shanghai", daysOfWeek: []),
                actions: [.log(message: "夜间静音", level: .info)]
            ),
            now: Date(timeIntervalSince1970: 1_001)
        )
        XCTAssertEqual(try store.pendingCount(), 2)

        let api = FakeSceneAPI(now: now)
        let service = SceneSyncService(api: api, store: store, logStore: logStore, now: { now })
        let result = push(service)

        XCTAssertTrue(result.isSuccess, "首次上传必须全部成功")
        XCTAssertEqual(api.createdInputs.count, 2)
        XCTAssertEqual(Set(api.createdInputs.map(\.name)), ["回家", "夜间静音"])
        XCTAssertEqual(api.listCallCount, 1, "首次上传前先拉基线用于幂等对账")

        let scenes = try store.fetchAll()
        XCTAssertEqual(scenes.count, 2)
        XCTAssertTrue(scenes.allSatisfy { $0.remoteID != nil })
        XCTAssertTrue(scenes.allSatisfy { $0.syncState == .synced })
        XCTAssertTrue(scenes.allSatisfy { $0.version == 1 })
        XCTAssertEqual(try store.pendingCount(), 0)
        XCTAssertEqual(Set(scenes.compactMap(\.remoteID)), ["remote-1", "remote-2"])
    }

    func testOfflineEditStaysPendingAndUploadsWhenNetworkReturns() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        try store.insert(makeScene(name: "离线新建"), now: Date(timeIntervalSince1970: 1_000))
        let api = FakeSceneAPI(now: now)
        api.isOnline = false
        let service = SceneSyncService(api: api, store: store, logStore: logStore, now: { now })

        let offline = push(service)
        XCTAssertFalse(offline.isSuccess, "断网时上传应失败并保留 pending")
        XCTAssertEqual(try store.pendingCount(), 1)
        XCTAssertNil(try store.fetchAll().first?.remoteID, "失败后不得写回假的 remoteId")

        api.isOnline = true
        let online = push(service)
        XCTAssertTrue(online.isSuccess)
        XCTAssertEqual(api.createdInputs.count, 1)
        let scene = try XCTUnwrap(store.fetchAll().first)
        XCTAssertEqual(scene.remoteID, "remote-1")
        XCTAssertEqual(scene.syncState, .synced)
        XCTAssertEqual(try store.pendingCount(), 0)
    }

    // MARK: - LWW

    func testPushSendsOnlyDirtyFieldsAndBothSidesKeepTheirEdits() throws {
        let firstRemote = makeRemoteScene(
            id: "remote-1",
            name: "服务端名",
            enabled: true,
            trigger: .rssiBelow(device: makeSceneReference(), rssiThreshold: -70),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try store.applyRemote(firstRemote, now: Date(timeIntervalSince1970: 1_000))

        let local = try XCTUnwrap(store.fetch(remoteID: "remote-1"))
        var renamed = local
        renamed.name = "本地改名"
        _ = try store.save(renamed, editedFields: [.name], now: Date(timeIntervalSince1970: 3_000))

        // 另一端只改了 enabled 与 trigger，两端改的是不同字段。
        let secondRemote = makeRemoteScene(
            id: "remote-1",
            name: "服务端名",
            enabled: false,
            trigger: .rssiBelow(device: makeSceneReference(), rssiThreshold: -60),
            version: 2,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try store.applyRemote(secondRemote, now: Date(timeIntervalSince1970: 2_000))
        let merged = try XCTUnwrap(store.fetch(remoteID: "remote-1"))
        XCTAssertEqual(merged.dirtyFields, [.name], "只有本地改过的字段待推送")

        let api = FakeSceneAPI(now: Date(timeIntervalSince1970: 4_000))
        api.addRemote(
            secondRemote,
            fieldDates: [
                .name: Date(timeIntervalSince1970: 1_000),
                .enabled: Date(timeIntervalSince1970: 2_000),
                .cooldownSeconds: Date(timeIntervalSince1970: 1_000),
                .trigger: Date(timeIntervalSince1970: 2_000),
                .actions: Date(timeIntervalSince1970: 1_000),
            ]
        )
        let service = SceneSyncService(
            api: api,
            store: store,
            logStore: logStore,
            now: { Date(timeIntervalSince1970: 4_000) }
        )
        let result = push(service)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(api.updates.count, 1)
        let patch = try XCTUnwrap(api.updates.first?.patch)
        XCTAssertEqual(patch.name?.value, "本地改名")
        XCTAssertNil(patch.enabled, "未编辑字段不得出现在 PUT 中")
        XCTAssertNil(patch.trigger, "未编辑字段不得出现在 PUT 中")
        XCTAssertNil(patch.actions)
        XCTAssertNil(patch.cooldownSeconds)

        let final = try XCTUnwrap(store.fetch(remoteID: "remote-1"))
        XCTAssertEqual(final.name, "本地改名", "本地字段保留")
        XCTAssertEqual(final.enabled, false, "远端字段保留")
        XCTAssertEqual(final.trigger, .rssiBelow(device: makeSceneReference(), rssiThreshold: -60))
        XCTAssertEqual(final.syncState, .synced)
        XCTAssertEqual(try store.pendingCount(), 0)
    }

    func testOrphanSceneIsAdoptedInsteadOfCreatedTwice() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let scene = try store.insert(makeScene(name: "响应丢失"), now: Date(timeIntervalSince1970: 1_000))
        let api = FakeSceneAPI(now: now)
        api.addRemote(
            makeRemoteScene(
                id: "remote-9",
                name: scene.name,
                enabled: scene.enabled,
                cooldownSeconds: scene.cooldownSeconds,
                trigger: scene.trigger,
                actions: scene.actions,
                updatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        let service = SceneSyncService(api: api, store: store, logStore: logStore, now: { now })

        let result = push(service)
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(api.createdInputs.isEmpty, "内容一致的孤儿场景应认领而不是重复 POST")
        let adopted = try XCTUnwrap(store.fetch(id: scene.id))
        XCTAssertEqual(adopted.remoteID, "remote-9")
        XCTAssertEqual(adopted.syncState, .synced)
        XCTAssertEqual(try store.pendingCount(), 0)
        XCTAssertTrue(api.deletedIDs.isEmpty)
    }

    // MARK: - Soft delete

    func testLocalDeleteOfSyncedSceneSendsDeleteAndKeepsTombstone() throws {
        try store.applyRemote(
            makeRemoteScene(id: "remote-7", name: "待删除", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let id = try XCTUnwrap(store.fetch(remoteID: "remote-7")?.id)
        try store.delete(id: id, now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(try store.pendingCount(), 1)

        let api = FakeSceneAPI(now: Date(timeIntervalSince1970: 5_000))
        api.addRemote(makeRemoteScene(id: "remote-7", updatedAt: Date(timeIntervalSince1970: 1_000)))
        let service = SceneSyncService(api: api, store: store, logStore: logStore)
        let result = push(service)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(api.deletedIDs, ["remote-7"])
        XCTAssertTrue(try store.fetchAll().isEmpty)
        let tombstone = try XCTUnwrap(store.fetch(id: id))
        XCTAssertNotNil(tombstone.deletedAt)
        XCTAssertEqual(tombstone.syncState, .synced)
        XCTAssertEqual(try store.pendingCount(), 0)

        let second = push(service)
        XCTAssertTrue(second.isSuccess)
        XCTAssertEqual(api.deletedIDs, ["remote-7"], "已同步的软删不得重复发送")
    }

    func testServerDeleteChangeLogSoftDeletesLocally() throws {
        try store.applyRemote(
            makeRemoteScene(id: "remote-8", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let service = SceneSyncService(api: FakeSceneAPI(), store: store, logStore: logStore)
        let change = SyncChange(
            seq: 10,
            entity: SyncEntity.scene,
            entityID: "remote-8",
            op: "delete",
            payload: RemoteDevice(id: "", externalID: "", updatedAt: Date(timeIntervalSince1970: 0)),
            sceneChange: makeRemoteScene(
                id: "remote-8",
                version: 2,
                updatedAt: Date(timeIntervalSince1970: 4_000),
                deletedAt: nil
            ),
            serverTimestamp: Date(timeIntervalSince1970: 5_000)
        )
        XCTAssertTrue(try service.apply(change))

        let tombstone = try XCTUnwrap(store.fetch(remoteID: "remote-8"))
        XCTAssertEqual(tombstone.deletedAt, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(tombstone.syncState, .synced)
        XCTAssertTrue(try store.fetchAll().isEmpty)
    }

    func testNonSceneChangeIsIgnoredWithoutTouchingStore() throws {
        try store.applyRemote(
            makeRemoteScene(id: "remote-10", name: "保留", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let service = SceneSyncService(api: FakeSceneAPI(), store: store, logStore: logStore)
        let change = SyncChange(
            seq: 11,
            entity: SyncEntity.device,
            entityID: "dev-1",
            op: "delete",
            payload: RemoteDevice(id: "dev-1", externalID: "AABB", updatedAt: Date(timeIntervalSince1970: 2_000))
        )
        XCTAssertFalse(try service.apply(change))
        XCTAssertEqual(try store.fetch(remoteID: "remote-10")?.name, "保留")
    }

    // MARK: - Baseline

    func testBaselineMarksMissingSyncedScenesDeleted() throws {
        try store.applyRemote(
            makeRemoteScene(id: "remote-a", name: "基线内", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        try store.applyRemote(
            makeRemoteScene(id: "remote-b", name: "服务端已删", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let api = FakeSceneAPI(now: Date(timeIntervalSince1970: 5_000))
        api.addRemote(makeRemoteScene(id: "remote-a", name: "基线内", updatedAt: Date(timeIntervalSince1970: 1_000)))
        let service = SceneSyncService(api: api, store: store, logStore: logStore)

        var result: Result<Void, AppError>?
        service.prepare(token: "token") { result = $0 }
        XCTAssertTrue(result?.isSuccess == true)
        XCTAssertEqual(try store.fetchAll().map(\.remoteID), ["remote-a"])
        let missing = try XCTUnwrap(store.fetch(remoteID: "remote-b"))
        XCTAssertNotNil(missing.deletedAt)
        XCTAssertEqual(missing.syncState, .synced)
    }

    func testBaselineFailureDoesNotMutateLocalData() throws {
        try store.applyRemote(
            makeRemoteScene(id: "remote-c", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let api = FakeSceneAPI(now: Date(timeIntervalSince1970: 5_000))
        api.isOnline = false
        let service = SceneSyncService(api: api, store: store, logStore: logStore)

        var result: Result<Void, AppError>?
        service.prepare(token: "token") { result = $0 }
        XCTAssertFalse(result?.isSuccess == true)
        XCTAssertEqual(try store.fetchAll().count, 1)
        XCTAssertNil(try store.fetch(remoteID: "remote-c")?.deletedAt)
    }

    // MARK: - Helpers

    private func push(_ service: SceneSyncService) -> Result<Int, AppError> {
        var captured: Result<Int, AppError>?
        service.pushPending(token: "token") { captured = $0 }
        return captured ?? .failure(.sync("missing completion"))
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Fake API

/// 内存版场景接口：实现字段级 LWW 比较，便于验证「两端改不同字段都保留」。
private final class FakeSceneAPI: SceneAPIServicing {
    var isOnline = true
    private let now: Date
    private var remoteScenes: [String: RemoteScene] = [:]
    private var fieldDates: [String: [SceneFieldKey: Date]] = [:]
    private var nextID = 1

    private(set) var listCallCount = 0
    private(set) var createdInputs: [SceneCreateInput] = []
    private(set) var updates: [(id: String, patch: ScenePatchInput)] = []
    private(set) var deletedIDs: [String] = []

    init(now: Date = Date(timeIntervalSince1970: 5_000)) {
        self.now = now
    }

    func addRemote(_ scene: RemoteScene, fieldDates dates: [SceneFieldKey: Date]? = nil) {
        remoteScenes[scene.id] = scene
        var all = dates ?? [:]
        for key in SceneFieldKey.allCases where all[key] == nil {
            all[key] = scene.updatedAt
        }
        fieldDates[scene.id] = all
    }

    func listScenes(token: String, completion: @escaping (Result<[RemoteScene], AppError>) -> Void) {
        listCallCount += 1
        guard isOnline else {
            completion(.failure(.network("offline")))
            return
        }
        completion(.success(Array(remoteScenes.values)))
    }

    func createScene(
        token: String,
        input: SceneCreateInput,
        completion: @escaping (Result<RemoteScene, AppError>) -> Void
    ) {
        guard isOnline else {
            completion(.failure(.network("offline")))
            return
        }
        createdInputs.append(input)
        let remote = RemoteScene(
            id: "remote-\(nextID)",
            name: input.name,
            enabled: input.enabled,
            cooldownSeconds: input.cooldownSeconds,
            trigger: input.trigger,
            actions: input.actions,
            version: 1,
            deviceMissing: false,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        nextID += 1
        addRemote(remote)
        completion(.success(remote))
    }

    func updateScene(
        token: String,
        id: String,
        patch: ScenePatchInput,
        completion: @escaping (Result<RemoteScene, AppError>) -> Void
    ) {
        guard isOnline else {
            completion(.failure(.network("offline")))
            return
        }
        updates.append((id, patch))
        guard var current = remoteScenes[id] else {
            completion(.failure(.server(statusCode: 404)))
            return
        }
        var dates = fieldDates[id] ?? [:]
        var newest = current.updatedAt

        func accepts(_ key: SceneFieldKey, _ raw: String) -> Bool {
            let date = SyncDateCodec.parse(raw) ?? now
            guard date >= (dates[key] ?? .distantPast) else { return false }
            dates[key] = date
            newest = max(newest, date)
            return true
        }

        if let value = patch.name, accepts(.name, value.updatedAt) { current = current.updating(name: value.value) }
        if let value = patch.enabled, accepts(.enabled, value.updatedAt) { current = current.updating(enabled: value.value) }
        if let value = patch.cooldownSeconds, accepts(.cooldownSeconds, value.updatedAt) {
            current = current.updating(cooldownSeconds: value.value)
        }
        if let value = patch.trigger, accepts(.trigger, value.updatedAt) { current = current.updating(trigger: value.value) }
        if let value = patch.actions, accepts(.actions, value.updatedAt) { current = current.updating(actions: value.value) }

        let merged = RemoteScene(
            id: current.id,
            name: current.name,
            enabled: current.enabled,
            cooldownSeconds: current.cooldownSeconds,
            trigger: current.trigger,
            actions: current.actions,
            version: current.version + 1,
            deviceMissing: current.deviceMissing,
            createdAt: current.createdAt,
            updatedAt: newest,
            deletedAt: nil
        )
        remoteScenes[id] = merged
        fieldDates[id] = dates
        completion(.success(merged))
    }

    func deleteScene(token: String, id: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        guard isOnline else {
            completion(.failure(.network("offline")))
            return
        }
        deletedIDs.append(id)
        guard remoteScenes.removeValue(forKey: id) != nil else {
            completion(.failure(.server(statusCode: 404)))
            return
        }
        fieldDates.removeValue(forKey: id)
        completion(.success(()))
    }
}

private extension RemoteScene {
    func updating(
        name: String? = nil,
        enabled: Bool? = nil,
        cooldownSeconds: Int? = nil,
        trigger: SceneTrigger? = nil,
        actions: [SceneAction]? = nil
    ) -> RemoteScene {
        RemoteScene(
            id: id,
            name: name ?? self.name,
            enabled: enabled ?? self.enabled,
            cooldownSeconds: cooldownSeconds ?? self.cooldownSeconds,
            trigger: trigger ?? self.trigger,
            actions: actions ?? self.actions,
            version: version,
            deviceMissing: deviceMissing,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}
