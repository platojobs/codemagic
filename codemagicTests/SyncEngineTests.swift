import XCTest
@testable import codemagic

// MARK: - Fakes

final class FakeSyncAPI: SyncAPIServicing {
    var authResult: Result<AnonymousSession, AppError> = .success(
        AnonymousSession(userID: "user-1", token: "token-1")
    )
    var changesPages: [Result<SyncChangesPage, AppError>] = [.success(SyncChangesPage())]
    var pushResults: [Result<PushResult, AppError>] = [.success(PushResult())]
    var deviceTypeResult: Result<DeviceTypeInfo, AppError> = .failure(.network("stub"))

    private(set) var authCount = 0
    private(set) var changesRequests: [(cursor: Int64, limit: Int, token: String)] = []
    private(set) var pushRequests: [(clientID: String, token: String, key: String, devices: [PushDevice], readings: [PushReading])] = []

    func createAnonymousSession(completion: @escaping (Result<AnonymousSession, AppError>) -> Void) {
        authCount += 1
        completion(authResult)
    }

    func fetchChanges(
        cursor: Int64,
        limit: Int,
        token: String,
        completion: @escaping (Result<SyncChangesPage, AppError>) -> Void
    ) {
        changesRequests.append((cursor, limit, token))
        if changesPages.isEmpty {
            completion(.success(SyncChangesPage(nextCursor: cursor, hasMore: false)))
        } else {
            completion(changesPages.removeFirst())
        }
    }

    func push(
        clientID: String,
        token: String,
        idempotencyKey: String,
        devices: [PushDevice],
        readings: [PushReading],
        completion: @escaping (Result<PushResult, AppError>) -> Void
    ) {
        pushRequests.append((clientID, token, idempotencyKey, devices, readings))
        if pushResults.isEmpty {
            completion(.success(PushResult()))
        } else {
            completion(pushResults.removeFirst())
        }
    }

    func fetchDeviceType(
        _ type: String,
        completion: @escaping (Result<DeviceTypeInfo, AppError>) -> Void
    ) {
        completion(deviceTypeResult)
    }
}

/// 按顺序返回不同状态码的 HTTP 桩，用于验证 410 → 全量拉取的完整链路。
final class SequencedHTTPClient: HTTPClient {
    struct Stub {
        let statusCode: Int
        let data: Data
    }

    private(set) var requests: [HTTPRequest] = []
    private var stubs: [Stub]

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func send(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, AppError>) -> Void) {
        requests.append(request)
        guard !stubs.isEmpty else {
            completion(.failure(.network("没有更多桩响应")))
            return
        }
        let stub = stubs.removeFirst()
        completion(.success(HTTPResponse(statusCode: stub.statusCode, headers: [:], data: stub.data)))
    }
}

final class InMemoryTokenStore: TokenStoring {
    var session: AnonymousSession?

    func load() -> AnonymousSession? { session }
    func save(_ session: AnonymousSession) throws { self.session = session }
    func clear() { session = nil }
}

// MARK: - Tests

final class SyncEngineTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var suiteName: String!
    private var savedDeviceStore: SavedDeviceStore!
    private var readingsStore: ReadingsStore!
    private var logStore: ScanLogStore!
    private var metadata: SyncMetadataStore!
    private var tokenStore: InMemoryTokenStore!
    private var api: FakeSyncAPI!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        suiteName = "codemagic.sync.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        metadata = SyncMetadataStore(defaults: defaults)
        savedDeviceStore = SavedDeviceStore(database: testDatabase.database)
        readingsStore = ReadingsStore(database: testDatabase.database)
        logStore = ScanLogStore(database: testDatabase.database)
        tokenStore = InMemoryTokenStore()
        api = FakeSyncAPI()
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    /// 假接口同步回调，便于断言结果。
    @discardableResult
    private func runSync(_ engine: SyncEngine) -> Result<SyncEngine.Summary, AppError>? {
        var captured: Result<SyncEngine.Summary, AppError>?
        engine.sync { captured = $0 }
        return captured
    }

    /// 假接口重新登录回调，便于断言结果。
    @discardableResult
    private func runRelogin(_ engine: SyncEngine) -> Result<SyncEngine.Summary, AppError>? {
        var captured: Result<SyncEngine.Summary, AppError>?
        engine.relogin { captured = $0 }
        return captured
    }

    private func makeEngine(now: @escaping () -> Date = Date.init) -> SyncEngine {
        SyncEngine(
            api: api,
            tokenStore: tokenStore,
            metadataStore: metadata,
            deviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            logStore: logStore,
            now: now
        )
    }

    private func makeRemote(
        id: String,
        externalID: String,
        alias: String?,
        advertisedName: String? = "PJ-Sensor",
        group: String? = "默认分组",
        updatedAt: Date,
        platform: String = SavedDevice.iosPlatform,
        deletedAt: Date? = nil
    ) -> RemoteDevice {
        RemoteDevice(
            id: id,
            platform: platform,
            externalID: externalID,
            alias: alias,
            advertisedName: advertisedName,
            group: group,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    // MARK: - Auth

    func testAnonymousLoginIsStoredAndReused() throws {
        let engine = makeEngine()
        _ = runSync(engine)
        XCTAssertEqual(api.authCount, 1)
        XCTAssertEqual(tokenStore.session?.token, "token-1")
        XCTAssertEqual(metadata.userID, "user-1")

        _ = runSync(engine)
        XCTAssertEqual(api.authCount, 1, "已有 token 时不应重复匿名登录")
        XCTAssertEqual(api.changesRequests.last?.token, "token-1")
    }

    func testAnonymousLoginPersistsSessionExpiryForProfile() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        api.authResult = .success(
            AnonymousSession(userID: "user-1", token: "token-1", expiresAt: expiry)
        )

        let engine = makeEngine()
        _ = runSync(engine)

        XCTAssertEqual(metadata.sessionExpiresAt, expiry)
        XCTAssertEqual(engine.status.sessionExpiresAt, expiry)
    }

    // MARK: - 410 全量重同步

    func testResyncRequiredClearsCursorKeepsPendingAndPullsFromZero() throws {
        let device = makeSavedDevice(name: "离线 90 天的待上传设备")
        try savedDeviceStore.upsert(device)
        metadata.cursor = 9
        metadata.lastSyncAt = Date(timeIntervalSince1970: 1_700_000_000)
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")

        api.changesPages = [
            .failure(.api(code: "RESYNC_REQUIRED", statusCode: 410, message: "cursor too old")),
            .success(SyncChangesPage(changes: [], nextCursor: 3, hasMore: false)),
        ]
        api.pushResults = [.success(PushResult())]

        let engine = makeEngine()
        guard case .success = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("410 后应自动全量重拉并成功")
        }

        XCTAssertEqual(
            api.changesRequests.map(\.cursor),
            [9, 0],
            "410 只处理一次：先按旧游标失败，再从 cursor=0 全量拉取"
        )
        XCTAssertEqual(metadata.cursor, 3, "全量拉取完成后写入新游标")
        XCTAssertNotNil(metadata.lastSyncAt)
        XCTAssertEqual(api.pushRequests.count, 1, "pending 设备不得丢弃，必须重新上传")
        XCTAssertEqual(engine.status.pendingCount, 0)
        XCTAssertFalse(engine.status.needsRelogin, "410 不是登录失效，不得引导重新登录")
        let message = try XCTUnwrap(engine.status.lastOutcomeMessage)
        XCTAssertTrue(
            message.contains("云端变更记录已过期，已重新全量同步"),
            "必须明确提示，不得静默：\(message)"
        )

        // 后续同步从新游标继续，而不是再次从 0 开始。
        _ = runSync(engine)
        XCTAssertEqual(api.changesRequests.last?.cursor, 3)
    }

    func testResyncRequiredOnlyHandledOnceWhenFullPullAlsoFails() throws {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        metadata.cursor = 9
        api.changesPages = [
            .failure(.api(code: "RESYNC_REQUIRED", statusCode: 410, message: "too old")),
            .failure(.api(code: "RESYNC_REQUIRED", statusCode: 410, message: "too old")),
        ]

        let engine = makeEngine()
        guard case .failure = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("全量拉取仍 410 时应失败，避免死循环")
        }
        XCTAssertEqual(api.changesRequests.map(\.cursor), [9, 0], "410 属于终态，只处理一次")
        XCTAssertEqual(metadata.cursor, 0)
        XCTAssertFalse(engine.status.needsRelogin)
        XCTAssertTrue(
            engine.status.lastOutcomeMessage?.contains("重新全量同步失败") == true,
            "失败也要明确说明：\(String(describing: engine.status.lastOutcomeMessage))"
        )
    }

    func testResyncRequiredEndToEndThroughHTTPTransport() throws {
        let device = makeSavedDevice(name: "待上传")
        try savedDeviceStore.upsert(device)
        metadata.cursor = 9
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")

        let gone = Data(#"{"error":{"code":"RESYNC_REQUIRED","message":"cursor too old"}}"#.utf8)
        let fullPage = Data(#"{"changes":[],"nextCursor":3,"hasMore":false}"#.utf8)
        let transport = SequencedHTTPClient(stubs: [
            .init(statusCode: 410, data: gone),
            .init(statusCode: 200, data: fullPage),
            .init(statusCode: 200, data: Data("{}".utf8)),
        ])
        let configuration = APIConfiguration(baseURL: URL(string: "http://127.0.0.1:18080")!)
        let engine = SyncEngine(
            api: SyncAPIClient(configuration: configuration, httpClient: transport),
            tokenStore: tokenStore,
            metadataStore: metadata,
            deviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            logStore: logStore
        )

        let expectation = expectation(description: "410 后全量拉取成功")
        var captured: Result<SyncEngine.Summary, AppError>?
        engine.sync {
            captured = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        guard case .success = try XCTUnwrap(captured) else {
            return XCTFail("410 后应全量拉取成功")
        }
        let cursors = transport.requests.compactMap { request -> String? in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
        }
        XCTAssertEqual(cursors, ["9", "0"], "HTTP 层也必须以 cursor=0 重拉")
        XCTAssertEqual(transport.requests.last?.url.path, "/api/v1/sync/push")
        XCTAssertEqual(metadata.cursor, 3)
        XCTAssertEqual(engine.status.pendingCount, 0)
        XCTAssertTrue(engine.status.lastOutcomeMessage?.contains("已重新全量同步") == true)
    }

    // MARK: - 503 TIMEOUT 退避

    func testTimeoutMapsToBusyAndEntersBackoffInsteadOfResync() throws {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        metadata.cursor = 4
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        api.changesPages = [
            .failure(.api(code: "TIMEOUT", statusCode: 503, message: "query timeout")),
        ]

        let engine = makeEngine(now: { fixedNow })
        guard case .failure(let error) = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("503 应失败")
        }
        XCTAssertFalse(error.isResyncRequired, "503 不得按 410 处理")
        XCTAssertTrue(error.isServerBusy)
        XCTAssertTrue(error.isRetryable)
        XCTAssertEqual(metadata.cursor, 4, "503 不应改动游标")
        XCTAssertFalse(engine.status.needsRelogin)
        let message = try XCTUnwrap(engine.status.lastOutcomeMessage)
        XCTAssertTrue(message.contains("服务端繁忙，稍后重试"), "映射文案：\(message)")
        XCTAssertTrue(message.contains("30 秒后自动重试"), "应进退避：\(message)")

        // 退避窗口内自动同步被闸门跳过，不再连续打点。
        _ = engine.syncIfNeeded(minimumInterval: 0)
        XCTAssertEqual(api.changesRequests.count, 1, "退避期间不应再次请求")
    }

    func testUnauthorizedMessageSaysLoginExpired() {
        let error = AppError.api(code: "UNAUTHORIZED", statusCode: 401, message: "token expired")
        XCTAssertTrue(error.isUnauthorized)
        XCTAssertFalse(error.isRetryable)
        XCTAssertTrue(error.message.contains("登录已失效"), "401 文案：\(error.message)")
    }

    // MARK: - Push 幂等

    func testRetryAfterNetworkFailureReusesIdempotencyKeyAndClearsPending() throws {
        let device = makeSavedDevice(name: "待上传设备")
        try savedDeviceStore.upsert(device)
        api.pushResults = [
            .failure(.network("offline")),
            .success(PushResult()),
        ]

        let engine = makeEngine()
        guard case .failure = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("首次同步应失败")
        }
        XCTAssertEqual(engine.status.pendingCount, 1, "失败后必须保留待上传")
        XCTAssertEqual(api.pushRequests.count, 1)
        XCTAssertNil(metadata.lastSyncAt)

        guard case .success = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("第二次同步应成功")
        }
        XCTAssertEqual(api.pushRequests.count, 2)
        XCTAssertEqual(
            api.pushRequests[0].key,
            api.pushRequests[1].key,
            "相同批次重试必须复用同一 Idempotency-Key"
        )
        XCTAssertEqual(engine.status.pendingCount, 0)
        XCTAssertNotNil(metadata.lastSyncAt)

        // 没有待上传时不应再调用 push。
        _ = runSync(engine)
        XCTAssertEqual(api.pushRequests.count, 2, "已同步记录不应重复上传")
    }

    func testChangedBatchProducesDifferentIdempotencyKey() {
        let first = PushDevice(
            device: makeSavedDevice(name: "A")
        )
        let second = PushDevice(
            device: makeSavedDevice(name: "B")
        )
        XCTAssertNotEqual(
            SyncHashing.idempotencyKey(for: [first]),
            SyncHashing.idempotencyKey(for: [second])
        )
        XCTAssertEqual(
            SyncHashing.idempotencyKey(for: [first]),
            SyncHashing.idempotencyKey(for: [first]),
            "同一内容必须得到稳定键"
        )
    }

    // MARK: - 冲突

    func testPushConflictAppliesServerVersionAndSurfacesNotice() throws {
        let peripheralID = UUID()
        let local = SavedDevice(
            peripheralID: peripheralID,
            advertisedName: "本地改名",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncState: .pending
        )
        try savedDeviceStore.upsert(local)

        let serverUpdated = Date(timeIntervalSince1970: 1_700_000_100)
        let server = makeRemote(
            id: local.id.uuidString,
            externalID: peripheralID.uuidString.uppercased(),
            alias: "另一台设备的新名字",
            updatedAt: serverUpdated
        )
        let conflict = SyncConflict(
            id: local.id.uuidString,
            externalID: peripheralID.uuidString,
            reason: "server_newer",
            server: server
        )
        api.pushResults = [.success(PushResult(conflicts: [conflict]))]

        let engine = makeEngine()
        guard case .success = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("冲突不应导致整个同步失败")
        }

        let stored = try XCTUnwrap(savedDeviceStore.fetch(id: local.id))
        XCTAssertEqual(stored.remark, "另一台设备的新名字", "服务端 LWW 获胜，别名回落为 remark")
        XCTAssertEqual(stored.syncState, .synced)
        XCTAssertEqual(engine.status.pendingCount, 0)

        let notice = try XCTUnwrap(engine.status.lastConflictMessages.first)
        XCTAssertTrue(notice.contains("另一台设备改过这条"), "落败时必须明确提示：\(notice)")
        XCTAssertTrue(engine.status.lastOutcomeMessage?.contains("冲突") == true)

        let logs = try logStore.fetchRecent()
        XCTAssertTrue(logs.contains { $0.category == .sync && $0.level == .warning })
    }

    func testPullNewerServerVersionOverwritesPendingLocalWithNotice() throws {
        let peripheralID = UUID()
        let local = SavedDevice(
            peripheralID: peripheralID,
            advertisedName: "本地旧名",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncState: .pending
        )
        try savedDeviceStore.upsert(local)

        let serverUpdated = Date(timeIntervalSince1970: 1_700_000_050)
        let change = makeUpsertChange(
            id: local.id.uuidString,
            externalID: peripheralID.uuidString.uppercased(),
            alias: "云端新名",
            updatedAt: serverUpdated
        )
        api.changesPages = [.success(SyncChangesPage(changes: [change], nextCursor: 1, hasMore: false))]

        let engine = makeEngine()
        _ = runSync(engine)

        let stored = try XCTUnwrap(savedDeviceStore.fetch(id: local.id))
        XCTAssertEqual(stored.remark, "云端新名")
        XCTAssertEqual(stored.syncState, .synced)
        XCTAssertTrue(engine.status.lastConflictMessages.first?.contains("另一台设备改过这条") == true)
    }

    func testPullOlderServerVersionKeepsNewerLocalEdit() throws {
        let peripheralID = UUID()
        let localUpdated = Date(timeIntervalSince1970: 1_700_000_100)
        let local = SavedDevice(
            peripheralID: peripheralID,
            advertisedName: "本地新名",
            updatedAt: localUpdated,
            syncState: .pending
        )
        try savedDeviceStore.upsert(local)

        let change = makeUpsertChange(
            id: local.id.uuidString,
            externalID: peripheralID.uuidString.uppercased(),
            alias: "云端旧名",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        api.changesPages = [.success(SyncChangesPage(changes: [change], nextCursor: 1, hasMore: false))]

        let engine = makeEngine()
        _ = runSync(engine)

        let stored = try XCTUnwrap(savedDeviceStore.fetch(id: local.id))
        XCTAssertEqual(stored.displayName, "本地新名", "本地 LWW 获胜时不能被拉取静默覆盖")
        XCTAssertEqual(api.pushRequests.count, 1, "本地较新时应继续上传")
    }

    // MARK: - Tombstone

    func testPushTombstoneMarksSyncedAndHidesRecord() throws {
        let device = makeSavedDevice(name: "待删除设备")
        try savedDeviceStore.upsert(device)
        try savedDeviceStore.softDelete(id: device.id)

        let engine = makeEngine()
        _ = runSync(engine)

        XCTAssertEqual(api.pushRequests.count, 1)
        XCTAssertEqual(api.pushRequests.first?.devices.first?.deleted, true)
        XCTAssertTrue(try savedDeviceStore.fetchAll().isEmpty, "删除后不应出现在列表")
        XCTAssertEqual(engine.status.pendingCount, 0)
        let tombstone = try XCTUnwrap(savedDeviceStore.fetch(id: device.id))
        XCTAssertNotNil(tombstone.deletedAt)
        XCTAssertEqual(tombstone.syncState, .synced)
    }

    func testPullTombstoneDeletesLocalRecord() throws {
        let peripheralID = UUID()
        let local = SavedDevice(
            peripheralID: peripheralID,
            advertisedName: "将被云端删除",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncState: .synced
        )
        try savedDeviceStore.upsert(local)

        let deletedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let change = makeDeleteChange(
            id: local.id.uuidString,
            externalID: peripheralID.uuidString.uppercased(),
            deletedAt: deletedAt
        )
        api.changesPages = [.success(SyncChangesPage(changes: [change], nextCursor: 1, hasMore: false))]

        let engine = makeEngine()
        _ = runSync(engine)

        XCTAssertTrue(try savedDeviceStore.fetchAll().isEmpty)
        XCTAssertEqual(engine.status.pendingCount, 0)
        let stored = try XCTUnwrap(savedDeviceStore.fetch(id: local.id))
        XCTAssertEqual(stored.deletedAt, deletedAt)
        XCTAssertEqual(stored.syncState, .synced)
    }

    // MARK: - 失败降级

    func testPullFailureRecordsErrorAndKeepsPending() throws {
        try savedDeviceStore.upsert(makeSavedDevice(name: "离线设备"))
        api.changesPages = [.failure(.network("offline"))]

        let engine = makeEngine()
        guard case .failure(let error) = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("应失败")
        }
        XCTAssertEqual(error.code, "NET-001")
        XCTAssertEqual(engine.status.pendingCount, 1)
        XCTAssertNotNil(engine.status.lastError)
        XCTAssertTrue(engine.status.lastOutcomeMessage?.contains("本地数据仍可用") == true)
        XCTAssertEqual(api.pushRequests.count, 0, "拉取失败时不应继续推送")
    }

    // MARK: - 401 与重新登录

    func testUnauthorizedMarksReloginRequiredWithoutCreatingNewAccount() throws {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        api.changesPages = [.failure(.api(code: "UNAUTHORIZED", statusCode: 401, message: "token expired"))]

        let engine = makeEngine()
        guard case .failure(let error) = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("401 应导致同步失败")
        }
        XCTAssertTrue(error.isUnauthorized)
        XCTAssertTrue(engine.status.needsRelogin)
        XCTAssertTrue(metadata.reloginRequired)
        XCTAssertEqual(api.authCount, 0, "401 时不得静默新建匿名账号")
        XCTAssertEqual(tokenStore.session?.token, "token-1", "未确认前保留旧 token 等待用户操作")

        // 后续自动同步（前台 / 后台）也必须停在待重新登录，不得建号。
        api.changesPages = [.failure(.api(code: "UNAUTHORIZED", statusCode: 401, message: "token expired"))]
        _ = runSync(engine)
        XCTAssertEqual(api.authCount, 0)
        XCTAssertTrue(engine.status.needsRelogin)
    }

    func testMissingTokenWithReloginRequiredDoesNotAutoCreateAccount() throws {
        metadata.reloginRequired = true

        let engine = makeEngine()
        guard case .failure(let error) = try XCTUnwrap(runSync(engine)) else {
            return XCTFail("缺少会话应失败")
        }
        XCTAssertEqual(error.code, "SYNC-001")
        XCTAssertEqual(api.authCount, 0, "等待用户确认时不得静默建号")
        XCTAssertTrue(engine.status.needsRelogin)
    }

    func testReloginClearsTokenResetsCursorAndReuploadsLocalDevices() throws {
        let device = SavedDevice(
            peripheralID: UUID(),
            advertisedName: "本机设备",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncState: .synced
        )
        try savedDeviceStore.upsert(device)
        metadata.cursor = 42
        metadata.userID = "user-1"
        metadata.lastSyncAt = Date(timeIntervalSince1970: 1_700_000_000)
        tokenStore.session = AnonymousSession(userID: "user-1", token: "old-token")
        api.authResult = .success(AnonymousSession(userID: "user-2", token: "token-2"))

        let engine = makeEngine()
        guard case .success = try XCTUnwrap(runRelogin(engine)) else {
            return XCTFail("重新登录应成功")
        }

        XCTAssertEqual(api.authCount, 1, "重新登录只创建一次新匿名账号")
        XCTAssertEqual(tokenStore.session?.token, "token-2")
        XCTAssertEqual(metadata.userID, "user-2")
        XCTAssertEqual(api.changesRequests.last?.cursor, 0, "换号后必须从游标 0 重新拉取")
        XCTAssertEqual(api.pushRequests.count, 1, "本机设备需重新上传到新账号")
        XCTAssertEqual(api.pushRequests.first?.devices.first?.id, device.id.uuidString)
        XCTAssertEqual(engine.status.pendingCount, 0)
        XCTAssertFalse(engine.status.needsRelogin)
        XCTAssertFalse(metadata.reloginRequired)
        XCTAssertNotNil(metadata.lastSyncAt)
    }

    func testReloginFailureKeepsReloginRequiredAndDoesNotFallBackToAutoLogin() throws {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "old-token")
        api.authResult = .failure(.network("offline"))

        let engine = makeEngine()
        guard case .failure = try XCTUnwrap(runRelogin(engine)) else {
            return XCTFail("重新登录失败应返回错误")
        }
        XCTAssertNil(tokenStore.session, "已确认换号，旧 token 不恢复")
        XCTAssertTrue(metadata.reloginRequired)
        XCTAssertTrue(engine.status.needsRelogin)

        _ = runSync(engine)
        XCTAssertEqual(api.authCount, 1, "失败后自动同步不得悄悄建新号")
    }

    // MARK: - 0.3.3 三态 / 别名隔离

    /// absent 必须完全省略字段；clear 必须编码为空串。两者不能混为一谈。
    func testPatchEncodesAbsentAsOmittedAndClearAsEmptyString() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = PushDevice(
            id: "d-1",
            platform: "ios",
            externalID: "EXT-1",
            mac: nil,
            alias: .absent,
            advertisedName: .set("PJ-Sensor"),
            group: .clear,
            updatedAt: date,
            deleted: false
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertEqual(object["group"] as? String, "", "显式清除分组编码为空串")
        XCTAssertEqual(object["advertisedName"] as? String, "PJ-Sensor")
        XCTAssertNil(object["alias"], "未上报的别名字段必须省略")

        let allAbsent = PushDevice(
            id: "d-2",
            platform: "ios",
            externalID: "EXT-2",
            mac: nil,
            updatedAt: date,
            deleted: false
        )
        let absentObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(allAbsent)) as? [String: Any]
        )
        XCTAssertNil(absentObject["alias"])
        XCTAssertNil(absentObject["advertisedName"])
        XCTAssertNil(absentObject["group"], "未修改时不得把分组编码成空串")
    }

    /// 扫描只写广播名，用户编辑只写别名，互不覆盖。
    func testAliasAndAdvertisedNameAreIsolated() {
        let scanned = makeSavedDevice(name: "PJ-Sensor", advertisedNamePatch: .set("PJ-Sensor"))
        let scanPayload = PushDevice(device: scanned)
        XCTAssertEqual(scanPayload.advertisedName, .set("PJ-Sensor"))
        XCTAssertEqual(scanPayload.alias, .absent, "扫描不得上报别名")
        XCTAssertEqual(scanPayload.group, .absent, "扫描不得上报分组")

        var edited = scanned
        edited.remark = "客厅面板"
        edited.aliasPatch = .set("客厅面板")
        edited.advertisedNamePatch = .absent

        let editPayload = PushDevice(device: edited)
        XCTAssertEqual(editPayload.alias, .set("客厅面板"))
        XCTAssertEqual(editPayload.advertisedName, .absent, "用户编辑不得上报广播名")
        XCTAssertEqual(edited.advertisedName, "PJ-Sensor", "编辑别名不覆盖广播名")
        XCTAssertEqual(edited.displayName, "客厅面板", "展示顺序：别名 → 广播名 → 型号")
    }

    /// 幂等键只取上报字段：未上报字段的值不计入哈希，清除与未上报必须区分。
    func testIdempotencyKeyExcludesUnreportedFields() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func make(_ alias: Patch<String> = .absent, group: Patch<String> = .absent) -> PushDevice {
            PushDevice(
                id: "d-1",
                platform: "ios",
                externalID: "EXT-1",
                mac: nil,
                alias: alias,
                group: group,
                updatedAt: date,
                deleted: false
            )
        }
        let base = SyncHashing.idempotencyKey(for: [make()])
        XCTAssertEqual(base, SyncHashing.idempotencyKey(for: [make()]), "同内容重试必须稳定")
        XCTAssertEqual(
            base,
            SyncHashing.idempotencyKey(for: [make(.absent, group: .absent)]),
            "未上报字段不得因为空值进入哈希"
        )
        XCTAssertNotEqual(base, SyncHashing.idempotencyKey(for: [make(.set("别名"))]))
        XCTAssertNotEqual(base, SyncHashing.idempotencyKey(for: [make(group: .clear)]), "清除与未上报必须区分")
    }

    /// 清空分组后必须显式上报空串；再次同步不得复活旧分组。
    func testClearedGroupIsReportedAsEmptyAndDoesNotResurrect() throws {
        let peripheralID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let synced = SavedDevice(
            peripheralID: peripheralID,
            advertisedName: "PJ-Sensor",
            groupName: "客厅",
            updatedAt: base,
            syncState: .synced
        )
        try savedDeviceStore.upsert(synced)

        var cleared = synced
        cleared.groupName = SavedDevice.defaultGroupName
        cleared.groupPatch = .clear
        cleared.updatedAt = base.addingTimeInterval(10)
        cleared.syncState = .pending
        try savedDeviceStore.upsert(cleared)

        let engine = makeEngine()
        _ = runSync(engine)

        let pushed = try XCTUnwrap(api.pushRequests.last?.devices.first)
        XCTAssertEqual(pushed.id, synced.id.uuidString)
        XCTAssertEqual(pushed.group, .clear, "删除分组必须上报 \"group\": \"\"")
        XCTAssertEqual(pushed.alias, .absent, "未修改的别名不得上报")
        XCTAssertEqual(pushed.advertisedName, .absent, "未修改的广播名不得上报")

        // 服务端返回清除后的 group 空串，第二次同步不得把「客厅」拉回来。
        let server = makeRemote(
            id: synced.id.uuidString,
            externalID: peripheralID.uuidString.uppercased(),
            alias: nil,
            group: "",
            updatedAt: base.addingTimeInterval(20)
        )
        api.changesPages = [
            .success(SyncChangesPage(changes: [makeChange(payload: server, op: "upsert")], nextCursor: 1, hasMore: false))
        ]
        _ = runSync(engine)

        let stored = try XCTUnwrap(savedDeviceStore.fetch(id: synced.id))
        XCTAssertEqual(stored.groupName, SavedDevice.defaultGroupName, "已清除的分组不得复活")
        XCTAssertEqual(stored.groupPatch, .absent)
        XCTAssertEqual(stored.advertisedName, "PJ-Sensor", "广播名不得被缺省字段清空")
    }

    /// 冲突响应省略可选字段时必须按 absent 解析并保留本地值。
    func testConflictResponseWithOmittedFieldsKeepsLocalValues() throws {
        let peripheralID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let local = SavedDevice(
            peripheralID: peripheralID,
            advertisedName: "PJ-Sensor",
            remark: "本地别名",
            groupName: "客厅",
            updatedAt: base,
            syncState: .pending
        )
        try savedDeviceStore.upsert(local)

        let json = """
        {"id":"\(local.id.uuidString)","platform":"ios",
         "externalId":"\(peripheralID.uuidString.uppercased())",
         "updatedAt":"\(SyncDateCodec.string(from: base.addingTimeInterval(100)))",
         "serverSeq":9}
        """
        let server = try JSONDecoder().decode(RemoteDevice.self, from: Data(json.utf8))
        XCTAssertNil(server.alias, "缺省别名按 absent 解析")
        XCTAssertNil(server.group, "缺省分组按 absent 解析")
        XCTAssertNil(server.advertisedName, "缺省广播名按 absent 解析")

        let conflict = SyncConflict(
            id: local.id.uuidString,
            externalID: peripheralID.uuidString.uppercased(),
            reason: "server_newer",
            server: server
        )
        api.pushResults = [.success(PushResult(conflicts: [conflict]))]
        _ = runSync(makeEngine())

        let stored = try XCTUnwrap(savedDeviceStore.fetch(id: local.id))
        XCTAssertEqual(stored.remark, "本地别名")
        XCTAssertEqual(stored.advertisedName, "PJ-Sensor")
        XCTAssertEqual(stored.groupName, "客厅")
        XCTAssertEqual(stored.syncState, .synced)
    }

    // MARK: - Helpers

    private func makeUpsertChange(id: String, externalID: String, alias: String, updatedAt: Date) -> SyncChange {
        let payload = makeRemote(id: id, externalID: externalID, alias: alias, updatedAt: updatedAt)
        return makeChange(payload: payload, op: "upsert")
    }

    private func makeDeleteChange(id: String, externalID: String, deletedAt: Date) -> SyncChange {
        let payload = makeRemote(
            id: id,
            externalID: externalID,
            alias: "",
            updatedAt: deletedAt,
            deletedAt: deletedAt
        )
        return makeChange(payload: payload, op: "delete")
    }

    private func makeChange(payload: RemoteDevice, op: String) -> SyncChange {
        var payloadObject: [String: Any] = [
            "id": payload.id,
            "clientId": "android-client",
            "platform": payload.platform,
            "externalId": payload.externalID,
            "alias": payload.alias ?? "",
            "group": payload.group ?? "",
            "updatedAt": SyncDateCodec.string(from: payload.updatedAt),
        ]
        if let deletedAt = payload.deletedAt {
            payloadObject["deletedAt"] = SyncDateCodec.string(from: deletedAt)
        }
        let json: [String: Any] = [
            "seq": 1,
            "entity": "device",
            "entityId": payload.id,
            "op": op,
            "payload": payloadObject,
            "serverTs": SyncDateCodec.string(from: payload.updatedAt),
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SyncChange.self, from: data)
    }

    // MARK: - v0.16.0：结构变更进增量同步

    /// 硬约束：未知实体必须被跳过，且游标照常推进（否则未来加实体会让老版本永久卡住）。
    func testUnknownEntityIsSkippedAndCursorStillAdvances() throws {
        let json = """
        {
          "changes": [
            {"seq": 1, "entity": "future_entity", "entityId": "u-1", "op": "upsert", "payload": {"id": "u-1", "whatever": 42}},
            {"seq": 2, "entity": "user_device", "entityId": "d-1", "op": "upsert", "payload": {
              "id": "00000000-0000-0000-0000-000000000001",
              "platform": "ios",
              "externalId": "EXT-1",
              "alias": "灯",
              "updatedAt": "2026-11-05T02:00:00Z"
            }}
          ],
          "nextCursor": 2,
          "hasMore": false
        }
        """
        let page = try JSONDecoder().decode(SyncChangesPage.self, from: Data(json.utf8))
        api.changesPages = [.success(page)]

        let engine = makeEngine()
        let result = runSync(engine)

        guard case .success(let summary) = result else {
            return XCTFail("未知实体不应导致同步失败")
        }
        XCTAssertEqual(metadata.cursor, 2, "游标必须前进")
        XCTAssertEqual(summary.pulled, 1, "只写入已知的设备实体")
        let device = try savedDeviceStore.fetch(platform: SavedDevice.iosPlatform, externalID: "EXT-1")
        XCTAssertNotNil(device, "未知实体被跳过后仍继续处理后续设备")
    }

    /// 本地没有该家庭时，增量 upsert 必须触发一次 GET /households 全量基线。
    func testUnknownHouseholdUpsertTriggersBaselinePull() throws {
        let householdStore = HouseholdStore(database: testDatabase.database)
        let roomStore = RoomStore(database: testDatabase.database)
        let pendingStore = DeviceAssignmentPendingStore(database: testDatabase.database)
        let householdAPI = FakeHouseholdAPI()
        let remoteHousehold = Household(
            id: UUID(),
            remoteID: "h-1",
            name: "刚加入的家",
            isPersonal: false,
            role: .member,
            memberCount: 2,
            deviceCount: 0,
            roomCount: 1,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        householdAPI.households = [remoteHousehold]
        let householdService = HouseholdService(
            api: householdAPI,
            tokenStore: tokenStore,
            householdStore: householdStore,
            roomStore: roomStore,
            deviceStore: savedDeviceStore,
            pendingStore: pendingStore,
            metadataStore: metadata,
            logStore: logStore
        )
        let engine = SyncEngine(
            api: api,
            tokenStore: tokenStore,
            metadataStore: metadata,
            deviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            logStore: logStore,
            householdService: householdService
        )

        let json = """
        {"changes":[{"seq":7,"entity":"household","entityId":"h-1","op":"upsert","payload":{
          "id":"h-1","name":"刚加入的家","ownerUserId":"owner","role":"member","memberCount":2,"deleted":false
        }}],"nextCursor":7,"hasMore":false}
        """
        let page = try JSONDecoder().decode(SyncChangesPage.self, from: Data(json.utf8))
        api.changesPages = [.success(page)]

        _ = runSync(engine)

        XCTAssertEqual(metadata.cursor, 7)
        XCTAssertNotNil(try householdStore.fetch(remoteID: "h-1"), "基线拉取后本地出现该家庭")
        XCTAssertEqual(metadata.currentHouseholdRemoteID, "h-1")
    }
}

// MARK: - API Client

final class SyncAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8080")!

    private func waitForResult<T>(
        _ call: (@escaping (Result<T, AppError>) -> Void) -> Void,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result<T, AppError> {
        var captured: Result<T, AppError>?
        let expectation = expectation(description: "completion")
        call { result in
            captured = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
        guard let captured else {
            XCTFail("回调未返回", file: file, line: line)
            return .failure(.network("no callback"))
        }
        return captured
    }

    func testAnonymousAuthUsesPostAndDecodesSession() throws {
        let json = #"{"userId":"u-123","token":"tk-abc"}"#
        let client = StubHTTPClient(statusCode: 201) { _ in .success(Data(json.utf8)) }
        let api = SyncAPIClient(configuration: APIConfiguration(baseURL: baseURL), httpClient: client)

        let result = waitForResult { api.createAnonymousSession(completion: $0) }
        let session = try XCTUnwrap(try? result.get())

        XCTAssertEqual(session.userID, "u-123")
        XCTAssertEqual(session.token, "tk-abc")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(request.url.absoluteString.contains("/api/v1/auth/anonymous"))
    }

    func testChangesRequestCarriesCursorLimitAndBearerToken() throws {
        let json = """
        {"changes":[],"nextCursor":42,"hasMore":false}
        """
        let client = StubHTTPClient { _ in .success(Data(json.utf8)) }
        let api = SyncAPIClient(configuration: APIConfiguration(baseURL: baseURL), httpClient: client)

        let result = waitForResult { api.fetchChanges(cursor: 7, limit: 200, token: "tk", completion: $0) }
        let page = try XCTUnwrap(try? result.get())

        XCTAssertEqual(page.nextCursor, 42)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer tk")
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertTrue(components.path.contains("/api/v1/sync/changes"))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "cursor" })?.value, "7")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "200")
    }

    func testPushSendsIdempotencyKeyAndDetectsReplay() throws {
        let json = """
        {"applied":[{"id":"d-1","platform":"ios","externalId":"ABC","status":"applied","serverSeq":5}],
         "conflicts":[],"nextCursor":5}
        """
        let client = StubHTTPClient(responseHeaders: ["Idempotent-Replayed": "true"]) { _ in
            .success(Data(json.utf8))
        }
        let api = SyncAPIClient(configuration: APIConfiguration(baseURL: baseURL), httpClient: client)

        let device = PushDevice(
            id: "d-1",
            platform: "ios",
            externalID: "abc",
            mac: nil,
            alias: .set("设备"),
            group: .set("默认分组"),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deleted: false
        )
        let result = waitForResult {
            api.push(clientID: "ios-client", token: "tk", idempotencyKey: "KEY-1", devices: [device], readings: [], completion: $0)
        }
        let response = try XCTUnwrap(try? result.get())

        XCTAssertTrue(response.isIdempotentReplay)
        XCTAssertEqual(response.applied.count, 1)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.headers["Idempotency-Key"], "KEY-1")
        XCTAssertTrue(request.url.absoluteString.contains("/api/v1/sync/push"))

        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["clientId"] as? String, "ios-client")
        let devices = try XCTUnwrap(object["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.first?["externalId"] as? String, "abc")
    }

    func testServerErrorEnvelopeMapsToAPICode() throws {
        let json = #"{"error":{"code":"RATE_LIMITED","message":"too many requests","retryAfter":30}}"#
        let client = StubHTTPClient(statusCode: 429) { _ in .success(Data(json.utf8)) }
        let api = SyncAPIClient(configuration: APIConfiguration(baseURL: baseURL), httpClient: client)

        let result = waitForResult { api.fetchChanges(cursor: 0, limit: 200, token: "tk", completion: $0) }
        guard case .failure(let error) = result else {
            return XCTFail("应失败")
        }
        guard case .rateLimited(let retryAfter) = error else {
            return XCTFail("429 应映射为 rateLimited，而不是通用 api 错误")
        }
        XCTAssertEqual(retryAfter, 30)
        XCTAssertTrue(error.isRetryable)
        XCTAssertEqual(error.code, "NET-002")
    }

    func testDeviceTypeRequestUsesTypePath() throws {
        let json = """
        {"type":"panel","name":"面板","vendor":"Acme","description":"演示",
         "gattServices":[{"uuid":"180F","name":"Battery","extra":"ignored"}]}
        """
        let client = StubHTTPClient { _ in .success(Data(json.utf8)) }
        let api = SyncAPIClient(configuration: APIConfiguration(baseURL: baseURL), httpClient: client)

        let result = waitForResult { api.fetchDeviceType("panel", completion: $0) }
        let info = try XCTUnwrap(try? result.get())

        XCTAssertEqual(info.vendor, "Acme")
        XCTAssertEqual(info.gattServices.first?.uuid, "180F")
        XCTAssertTrue(client.requests.first?.url.absoluteString.contains("/api/v1/device-types/panel") == true)
    }
}

// MARK: - 解码容错

final class SyncDecodingTests: XCTestCase {
    func testChangesPageIgnoresUnknownFieldsEverywhere() throws {
        let json = """
        {
          "changes": [{
            "seq": 3,
            "entity": "device",
            "entityId": "e-1",
            "op": "upsert",
            "serverTs": "2026-11-05T02:00:00Z",
            "unknownChangeField": "ignored",
            "payload": {
              "id": "11111111-1111-1111-1111-111111111111",
              "clientId": "client-1",
              "platform": "android",
              "externalId": "aa:bb:cc:dd:ee:ff",
              "mac": null,
              "alias": "安卓设备",
              "group": "默认分组",
              "rules": {"lowRssi": -80},
              "scanRecords": [],
              "serverSeq": 3,
              "updatedAt": "2026-11-05T01:59:59.123Z",
              "unknownPayloadField": 123,
              "nestedUnknown": {"a": 1}
            }
          }],
          "nextCursor": 3,
          "hasMore": true,
          "unknownEnvelopeField": true
        }
        """
        let page = try JSONDecoder().decode(SyncChangesPage.self, from: Data(json.utf8))

        XCTAssertEqual(page.changes.count, 1)
        XCTAssertEqual(page.nextCursor, 3)
        XCTAssertTrue(page.hasMore)
        let change = try XCTUnwrap(page.changes.first)
        XCTAssertEqual(change.entityID, "e-1")
        XCTAssertEqual(change.payload.platform, "android")
        XCTAssertEqual(change.payload.externalID, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(change.payload.serverSeq, 3)
    }

    func testPayloadWithMissingOptionalFieldsStillDecodes() throws {
        let json = #"{"changes":[{"payload":{"externalId":"abc","updatedAt":"2026-11-05T02:00:00Z"}}]}"#
        let page = try JSONDecoder().decode(SyncChangesPage.self, from: Data(json.utf8))
        let payload = try XCTUnwrap(page.changes.first?.payload)
        XCTAssertEqual(payload.externalID, "ABC")
        XCTAssertEqual(payload.platform, SavedDevice.iosPlatform, "platform 缺失时按 iOS 兜底")
        XCTAssertNil(payload.mac)
        XCTAssertNil(payload.alias, "缺省别名按 absent 解析，而不是空串")
        XCTAssertNil(payload.advertisedName, "缺省广播名按 absent 解析")
        XCTAssertNil(payload.group, "缺省分组按 absent 解析")
        XCTAssertEqual(page.nextCursor, 0)
        XCTAssertFalse(page.hasMore)
    }
}
