import XCTest
@testable import codemagic

/// 服务端场景的本地存储：字段级 LWW、软删与迁移隔离。
final class SceneStoreTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var store: SceneStore!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        store = SceneStore(database: testDatabase.database)
    }

    override func tearDownWithError() throws {
        testDatabase.cleanUp()
    }

    // MARK: - Round trip

    func testInsertAndFetchPreservesFields() throws {
        let trigger = SceneTrigger.metricThreshold(
            device: makeSceneReference(externalID: "DEV-1"),
            deviceType: "panel",
            metric: "temperature",
            comparator: .gte,
            threshold: 30,
            consecutive: 3
        )
        let actions: [SceneAction] = [
            .notify(title: "温度过高", body: "{device} 当前 {value}"),
            .log(message: "记录 {device}", level: .warn),
        ]
        let inserted = try store.insert(
            makeScene(name: "高温", trigger: trigger, actions: actions),
            now: Date(timeIntervalSince1970: 1_000)
        )

        let loaded = try XCTUnwrap(store.fetch(id: inserted.id))
        XCTAssertEqual(loaded.remoteID, nil)
        XCTAssertEqual(loaded.name, "高温")
        XCTAssertEqual(loaded.trigger, trigger)
        XCTAssertEqual(loaded.actions, actions)
        XCTAssertEqual(loaded.syncState, .pending)
        XCTAssertEqual(loaded.version, 0)
        XCTAssertEqual(loaded.fieldUpdatedAt[.name], Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(try store.pendingCount(), 1)
    }

    func testSceneStoreIgnoresManualScenarios() throws {
        let manual = Scenario(name: "手动", actions: [.syncNow])
        try ScenarioStore(database: testDatabase.database).upsert(manual)
        try store.insert(makeScene(name: "服务端场景"), now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(try store.fetchAll().map(\.name), ["服务端场景"])
        XCTAssertEqual(try ScenarioStore(database: testDatabase.database).fetchAll().map(\.id), [manual.id])
    }

    func testSaveOnlyAdvancesEditedFieldTimestamp() throws {
        let baseline = Date(timeIntervalSince1970: 1_000)
        try store.applyRemote(
            makeRemoteScene(id: "remote-x", name: "原名", updatedAt: baseline),
            now: baseline
        )
        let inserted = try XCTUnwrap(store.fetch(remoteID: "remote-x"))
        let editTime = Date(timeIntervalSince1970: 2_000)
        var scene = inserted
        scene.name = "新名"
        let saved = try store.save(scene, editedFields: [.name], now: editTime)

        XCTAssertEqual(saved.fieldUpdatedAt[.name], editTime)
        XCTAssertEqual(saved.fieldUpdatedAt[.enabled], baseline, "未编辑字段保持原时间戳")
        XCTAssertEqual(saved.dirtyFields, [.name], "只有编辑过的字段是脏字段")
    }

    // MARK: - LWW merge

    func testRemoteMergeKeepsLocalDirtyFieldAndAdoptsRemoteOthers() throws {
        let firstRemote = makeRemoteScene(
            id: "remote-1",
            name: "远端名",
            enabled: true,
            trigger: .rssiBelow(device: makeSceneReference(), rssiThreshold: -70),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try store.applyRemote(firstRemote, now: Date(timeIntervalSince1970: 1_000))

        let local = try XCTUnwrap(store.fetch(remoteID: "remote-1"))
        let renameTime = Date(timeIntervalSince1970: 3_000)
        var edited = local
        edited.name = "本地改名"
        _ = try store.save(edited, editedFields: [.name], now: renameTime)

        let secondRemote = makeRemoteScene(
            id: "remote-1",
            name: "远端名",
            enabled: false,
            trigger: .rssiBelow(device: makeSceneReference(), rssiThreshold: -60),
            version: 2,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try store.applyRemote(secondRemote, now: Date(timeIntervalSince1970: 4_000))

        let merged = try XCTUnwrap(store.fetch(remoteID: "remote-1"))
        XCTAssertEqual(merged.name, "本地改名")
        XCTAssertEqual(merged.enabled, false, "未编辑字段采用远端新值")
        XCTAssertEqual(merged.trigger, .rssiBelow(device: makeSceneReference(), rssiThreshold: -60))
        XCTAssertEqual(merged.dirtyFields, [.name])
        XCTAssertEqual(merged.syncState, .pending)
        XCTAssertEqual(merged.version, 2)
        XCTAssertEqual(merged.fieldUpdatedAt[.name], renameTime)
        XCTAssertEqual(merged.fieldUpdatedAt[.enabled], Date(timeIntervalSince1970: 1_000), "采用远端值的字段回落到旧同步基线，不应误判为脏字段")
    }

    func testSyncedSceneAdoptsWholeRemoteSnapshot() throws {
        try store.applyRemote(
            makeRemoteScene(id: "remote-2", name: "第一版", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let remote = makeRemoteScene(
            id: "remote-2",
            name: "服务端第二版",
            enabled: false,
            version: 2,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try store.applyRemote(remote, now: Date(timeIntervalSince1970: 3_000))

        let loaded = try XCTUnwrap(store.fetch(remoteID: "remote-2"))
        XCTAssertEqual(loaded.name, "服务端第二版")
        XCTAssertEqual(loaded.enabled, false)
        XCTAssertEqual(loaded.syncState, .synced)
        XCTAssertEqual(loaded.dirtyFields, [])
        XCTAssertEqual(loaded.lastSyncedAt, Date(timeIntervalSince1970: 3_000))
    }

    // MARK: - Deletion

    func testDeleteUnsyncedSceneRemovesRowPhysically() throws {
        let inserted = try store.insert(makeScene(name: "未上传"), now: Date(timeIntervalSince1970: 1_000))
        try store.delete(id: inserted.id, now: Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(try store.fetchAll().isEmpty)
        XCTAssertTrue(try store.fetchAll(includeDeleted: true).isEmpty)
        XCTAssertNil(try store.fetch(id: inserted.id))
    }

    func testDeleteSyncedSceneKeepsTombstoneForSync() throws {
        try store.applyRemote(
            makeRemoteScene(id: "remote-3", name: "已同步", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let localID = try XCTUnwrap(store.fetch(remoteID: "remote-3")?.id)
        try store.delete(id: localID, now: Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(try store.fetchAll().isEmpty)
        let tombstone = try XCTUnwrap(store.fetch(id: localID))
        XCTAssertEqual(tombstone.syncState, .pendingDelete)
        XCTAssertEqual(tombstone.deletedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(try store.pendingCount(), 1)
    }

    func testBaselineMissingMarksSyncedSceneDeletedButKeepsPendingEdits() throws {
        try store.applyRemote(
            makeRemoteScene(id: "remote-4", name: "基线内", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let local = try XCTUnwrap(store.fetch(remoteID: "remote-4"))
        var edited = local
        edited.name = "本地改名"
        _ = try store.save(edited, editedFields: [.name], now: Date(timeIntervalSince1970: 3_000))
        XCTAssertFalse(try store.markRemoteMissing(remoteID: "remote-4", now: Date(timeIntervalSince1970: 4_000)))
        XCTAssertNil(try store.fetch(id: local.id)?.deletedAt, "本地还有未推送编辑时不能被基线判死")

        try store.applyRemote(
            makeRemoteScene(id: "remote-5", updatedAt: Date(timeIntervalSince1970: 1_000)),
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(try store.markRemoteMissing(remoteID: "remote-5", now: Date(timeIntervalSince1970: 4_000)))
        let tombstone = try XCTUnwrap(store.fetch(remoteID: "remote-5"))
        XCTAssertNotNil(tombstone.deletedAt)
        XCTAssertEqual(tombstone.syncState, .synced)
    }
}
