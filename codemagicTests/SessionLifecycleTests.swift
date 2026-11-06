import XCTest
@testable import codemagic

/// v0.22.0：会话生命周期、场景错误码、导出失败原因、反馈详情、单设备详情。
final class SessionLifecycleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tokenStore: MutableTokenStore!
    private var metadata: SyncMetadataStore!

    override func setUp() {
        super.setUp()
        suiteName = "SessionLifecycleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        tokenStore = MutableTokenStore()
        metadata = SyncMetadataStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - P1: 401 → 单飞刷新 → 重放

    func test401RefreshesThenReplaysOriginalRequest() {
        try? tokenStore.save(AnonymousSession(userID: "u1", token: "old", expiresAt: nil))
        let auth = ScriptedAuthAPI()
        auth.refreshResult = .success(AnonymousSession(userID: "u1", token: "new", expiresAt: nil))
        let base = ScriptedHTTPClient { request in
            request.headers["Authorization"] == "Bearer new"
                ? HTTPResponse(statusCode: 200, headers: [:], data: Data("ok".utf8))
                : HTTPResponse(statusCode: 401, headers: [:], data: Self.unauthorizedBody)
        }
        let coordinator = TokenRefreshCoordinator(api: auth, tokenStore: tokenStore, metadataStore: metadata)
        let client = AuthenticatedHTTPClient(base: base, refreshCoordinator: coordinator)

        let expectation = expectation(description: "replayed")
        var statusCode: Int?
        client.send(HTTPRequest(url: URL(string: "https://example.com/api/v1/scenes")!, headers: ["Authorization": "Bearer old"])) { result in
            if case .success(let response) = result { statusCode = response.statusCode }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(statusCode, 200)
        XCTAssertEqual(auth.refreshCalls, 1)
        XCTAssertEqual(tokenStore.load()?.token, "new")
        XCTAssertEqual(base.requests.last?.headers["Authorization"], "Bearer new")
    }

    func testRefreshFailureEntersReloginAndKeepsLocalData() throws {
        let database = try TestDatabase()
        defer { database.cleanUp() }
        let deviceStore = SavedDeviceStore(database: database.database)
        let readingsStore = ReadingsStore(database: database.database)
        try deviceStore.upsert(makeSavedDevice())
        let deviceID = try XCTUnwrap(deviceStore.fetchAll().first?.id)
        try readingsStore.insert(DeviceReading(
            deviceID: deviceID,
            metric: .temperature,
            value: 21,
            unit: "C",
            recordedAt: Date()
        ))
        let deviceCountBefore = try deviceStore.fetchAll().count
        let readingCountBefore = try readingsStore.fetchPending().count

        try? tokenStore.save(AnonymousSession(userID: "u1", token: "dead", expiresAt: nil))
        let auth = ScriptedAuthAPI()
        auth.refreshResult = .failure(.api(code: "UNAUTHORIZED", statusCode: 401, message: "unauthorized"))
        let base = ScriptedHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], data: Self.unauthorizedBody)
        }
        let coordinator = TokenRefreshCoordinator(api: auth, tokenStore: tokenStore, metadataStore: metadata)
        let client = AuthenticatedHTTPClient(base: base, refreshCoordinator: coordinator)

        let expectation = expectation(description: "relogin")
        client.send(HTTPRequest(url: URL(string: "https://example.com/api/v1/scenes")!, headers: ["Authorization": "Bearer dead"])) { _ in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertTrue(metadata.reloginRequired)
        XCTAssertNil(tokenStore.load())
        XCTAssertEqual(try deviceStore.fetchAll().count, deviceCountBefore)
        XCTAssertEqual(try readingsStore.fetchPending().count, readingCountBefore)
    }

    func testFiveConcurrent401sTriggerExactlyOneRefresh() {
        try? tokenStore.save(AnonymousSession(userID: "u1", token: "old", expiresAt: nil))
        let auth = ScriptedAuthAPI()
        auth.manualRefresh = true
        let base = ScriptedHTTPClient { request in
            request.headers["Authorization"] == "Bearer new"
                ? HTTPResponse(statusCode: 200, headers: [:], data: Data("ok".utf8))
                : HTTPResponse(statusCode: 401, headers: [:], data: Self.unauthorizedBody)
        }
        let coordinator = TokenRefreshCoordinator(api: auth, tokenStore: tokenStore, metadataStore: metadata)
        let client = AuthenticatedHTTPClient(base: base, refreshCoordinator: coordinator)

        let allReplayed = expectation(description: "all replayed")
        allReplayed.expectedFulfillmentCount = 5
        var statuses: [Int] = []
        let lock = NSLock()
        for index in 0..<5 {
            client.send(HTTPRequest(
                url: URL(string: "https://example.com/api/v1/scenes/\(index)")!,
                headers: ["Authorization": "Bearer old"]
            )) { result in
                if case .success(let response) = result {
                    lock.lock(); statuses.append(response.statusCode); lock.unlock()
                }
                allReplayed.fulfill()
            }
        }

        // 等 5 个 401 都挂到同一次刷新上，再放行刷新结果。
        let refreshStarted = expectation(description: "refresh started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(auth.refreshCalls, 1)
            refreshStarted.fulfill()
            auth.completeRefresh(.success(AnonymousSession(userID: "u1", token: "new", expiresAt: nil)))
        }
        wait(for: [refreshStarted, allReplayed], timeout: 3)

        XCTAssertEqual(auth.refreshCalls, 1)
        XCTAssertEqual(statuses, Array(repeating: 200, count: 5))
        XCTAssertEqual(tokenStore.load()?.token, "new")
    }

    func testNetworkFailureDuringRefreshKeepsSession() {
        try? tokenStore.save(AnonymousSession(userID: "u1", token: "old", expiresAt: nil))
        let auth = ScriptedAuthAPI()
        auth.refreshResult = .failure(.network("offline"))
        let base = ScriptedHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], data: Self.unauthorizedBody)
        }
        let coordinator = TokenRefreshCoordinator(api: auth, tokenStore: tokenStore, metadataStore: metadata)
        let client = AuthenticatedHTTPClient(base: base, refreshCoordinator: coordinator)

        let expectation = expectation(description: "no relogin")
        client.send(HTTPRequest(url: URL(string: "https://example.com/api/v1/scenes")!, headers: ["Authorization": "Bearer old"])) { _ in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertFalse(metadata.reloginRequired)
        XCTAssertEqual(tokenStore.load()?.token, "old")
    }

    func testRequestAlreadyCarryingNewTokenIsReplayedWithoutRefresh() {
        try? tokenStore.save(AnonymousSession(userID: "u1", token: "new", expiresAt: nil))
        let auth = ScriptedAuthAPI()
        let base = ScriptedHTTPClient { request in
            request.headers["Authorization"] == "Bearer new"
                ? HTTPResponse(statusCode: 200, headers: [:], data: Data("ok".utf8))
                : HTTPResponse(statusCode: 401, headers: [:], data: Self.unauthorizedBody)
        }
        let coordinator = TokenRefreshCoordinator(api: auth, tokenStore: tokenStore, metadataStore: metadata)
        let client = AuthenticatedHTTPClient(base: base, refreshCoordinator: coordinator)

        let expectation = expectation(description: "replayed")
        client.send(HTTPRequest(url: URL(string: "https://example.com/x")!, headers: ["Authorization": "Bearer stale"])) { result in
            if case .success(let response) = result { XCTAssertEqual(response.statusCode, 200) }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(auth.refreshCalls, 0)
    }

    // MARK: - 退出当前会话

    func testLogoutClearsTokenAndKeepsLocalData() throws {
        let database = try TestDatabase()
        defer { database.cleanUp() }
        let deviceStore = SavedDeviceStore(database: database.database)
        try deviceStore.upsert(makeSavedDevice())
        try? tokenStore.save(AnonymousSession(userID: "u1", token: "live", expiresAt: Date().addingTimeInterval(3600)))
        metadata.userID = "u1"

        let auth = ScriptedAuthAPI()
        let manager = SessionManager(api: auth, tokenStore: tokenStore, metadataStore: metadata, logStore: ScanLogStore(database: database.database))

        let expectation = expectation(description: "logout")
        manager.logoutCurrent { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(auth.logoutCalls, 1)
        XCTAssertNil(tokenStore.load())
        XCTAssertTrue(metadata.reloginRequired)
        XCTAssertFalse(manager.hasSession)
        XCTAssertEqual(try deviceStore.fetchAll().count, 1)
    }

    // MARK: - 场景错误码与重试分类

    func testSceneErrorCodesMapToReadableMessages() {
        let codes = [
            "SCENE_NAME_INVALID",
            "SCENE_TRIGGER_INVALID",
            "SCENE_COOLDOWN_OUT_OF_RANGE",
            "SCENE_ACTION_INVALID",
            "SCENE_DEVICE_NOT_FOUND",
            "SCENE_METRIC_NOT_SUPPORTED",
        ]
        let seen = Set(codes.map { APIErrorCatalog.entry(for: $0).message })
        XCTAssertEqual(seen.count, 6, "每个场景错误码都要有独立文案，不能落到通用提示")
        for code in codes {
            let entry = APIErrorCatalog.entry(for: code)
            XCTAssertEqual(entry.handling, .terminal)
            let error = AppError.api(code: code, statusCode: 400, message: "x")
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testRetryClassification() {
        XCTAssertTrue(AppError.network("x").isRetryable)
        XCTAssertTrue(AppError.server(statusCode: 500).isRetryable)
        XCTAssertTrue(AppError.server(statusCode: 503).isRetryable)
        XCTAssertFalse(AppError.server(statusCode: 501).isRetryable)
        XCTAssertFalse(AppError.api(code: "BAD_REQUEST", statusCode: 400, message: "x").isRetryable)
        XCTAssertFalse(AppError.api(code: "NOT_FOUND", statusCode: 404, message: "x").isRetryable)
        XCTAssertFalse(AppError.api(code: "CONFLICT", statusCode: 409, message: "x").isRetryable)
        XCTAssertFalse(AppError.api(code: "SCENE_TRIGGER_INVALID", statusCode: 422, message: "x").isRetryable)
        XCTAssertTrue(AppError.api(code: "UNAVAILABLE", statusCode: 503, message: "x").isRetryable)

        let limited = AppError.rateLimited(retryAfterSeconds: 7)
        XCTAssertTrue(limited.isRetryable)
        XCTAssertEqual(limited.retryAfterSeconds, 7)
    }

    // MARK: - 契约形状

    func testSceneListDecodesItemsEnvelope() {
        let http = StubHTTPClient(
            statusCode: 200,
            handler: { _ in .success(Data(#"{"items":[]}"#.utf8)) }
        )
        let client = SceneAPIClient(configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!), httpClient: http)
        let expectation = expectation(description: "list")
        client.listScenes(token: "t") { result in
            switch result {
            case .success(let scenes): XCTAssertTrue(scenes.isEmpty)
            case .failure(let error): XCTFail("契约是 {\"items\":[...]}，解码失败：\(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - 导出失败原因

    func testExportFailureReasonIsSurfaced() {
        let service = AccountExportService(
            api: FailedExportAPI(reason: "导出任务因服务重启中断，请重新发起导出"),
            tokenStore: tokenStore
        )
        try? tokenStore.save(AnonymousSession(userID: "u1", token: "t", expiresAt: nil))
        let expectation = expectation(description: "export")
        service.export(progress: { _ in }) { result in
            guard case .failure(let error) = result else {
                XCTFail("应当失败")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(error.errorDescription, "导出任务因服务重启中断，请重新发起导出")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    // MARK: - 反馈详情与关闭

    func testFeedbackDetailParsesStatusMessage() {
        try? tokenStore.save(AnonymousSession(userID: "u1", token: "t", expiresAt: nil))
        let body = Data(#"""
        {"feedbackId":"f1","kind":"bug","body":"崩溃","status":"received",
        "statusMessage":"已收到，正在处理","createdAt":"2026-01-01T10:00:00Z","updatedAt":"2026-01-02T10:00:00Z"}
        """#.utf8)
        let http = StubHTTPClient(statusCode: 200, handler: { _ in .success(body) })
        let client = FeedbackAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http,
            tokenStore: tokenStore
        )
        let expectation = expectation(description: "detail")
        client.fetchDetail(id: "f1") { result in
            guard case .success(let detail) = result else {
                XCTFail("详情解码失败")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(detail.status, .received)
            XCTAssertEqual(detail.statusMessage, "已收到，正在处理")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testFeedbackCloseConflictHasExplicitMessage() {
        try? tokenStore.save(AnonymousSession(userID: "u1", token: "t", expiresAt: nil))
        let body = Data(#"{"error":{"code":"FEEDBACK_INVALID_TRANSITION","message":"already closed"}}"#.utf8)
        let http = StubHTTPClient(statusCode: 409, handler: { _ in .success(body) })
        let client = FeedbackAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http,
            tokenStore: tokenStore
        )
        let expectation = expectation(description: "close")
        client.close(id: "f1") { result in
            guard case .failure(let failure) = result else {
                XCTFail("应当 409")
                expectation.fulfill()
                return
            }
            XCTAssertTrue(failure.isConflict)
            XCTAssertEqual(failure.message, L10n.t("feedback.close.alreadyClosed"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - 单设备详情

    func testAndroidDeviceUsesMacEndpoint() {
        try? tokenStore.save(AnonymousSession(userID: "u1", token: "t", expiresAt: nil))
        let http = StubHTTPClient(statusCode: 200, handler: { _ in .success(Data(#"{"mac":"AA:BB:CC:DD:EE:FF"}"#.utf8)) })
        let client = ProductAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http,
            tokenStore: tokenStore
        )
        let device = SavedDevice(
            peripheralID: UUID(),
            platform: "android",
            externalID: "AA:BB:CC:DD:EE:FF",
            advertisedName: "Android 设备"
        )
        let expectation = expectation(description: "device")
        client.fetchDeviceInfo(device: device) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(http.requestedURLs.last?.path, "/api/v1/my/devices/AA:BB:CC:DD:EE:FF")
    }

    // MARK: - Helpers

    private static let unauthorizedBody = Data(#"{"error":{"code":"UNAUTHORIZED","message":"unauthorized"}}"#.utf8)
}

// MARK: - Doubles

private final class MutableTokenStore: TokenStoring {
    private let lock = NSLock()
    private var value: AnonymousSession?

    func load() -> AnonymousSession? {
        lock.lock(); defer { lock.unlock() }; return value
    }

    func save(_ session: AnonymousSession) throws {
        lock.lock(); value = session; lock.unlock()
    }

    func clear() {
        lock.lock(); value = nil; lock.unlock()
    }
}

private final class ScriptedHTTPClient: HTTPClient {
    private let responder: (HTTPRequest) -> HTTPResponse
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []

    init(responder: @escaping (HTTPRequest) -> HTTPResponse) {
        self.responder = responder
    }

    func send(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, AppError>) -> Void) {
        lock.lock(); requests.append(request); lock.unlock()
        completion(.success(responder(request)))
    }
}

private final class ScriptedAuthAPI: AuthServicing {
    var refreshResult: Result<AnonymousSession, AppError> = .failure(.network("stub"))
    var manualRefresh = false
    private var pendingRefresh: ((Result<AnonymousSession, AppError>) -> Void)?
    private(set) var refreshCalls = 0
    private(set) var logoutCalls = 0

    func completeRefresh(_ result: Result<AnonymousSession, AppError>) {
        pendingRefresh?(result)
        pendingRefresh = nil
    }

    func refresh(token: String, completion: @escaping (Result<AnonymousSession, AppError>) -> Void) {
        refreshCalls += 1
        if manualRefresh {
            pendingRefresh = completion
            return
        }
        DispatchQueue.main.async { completion(self.refreshResult) }
    }

    func logout(token: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        logoutCalls += 1
        DispatchQueue.main.async { completion(.success(())) }
    }

    func listSessions(token: String, completion: @escaping (Result<[RemoteSession], AppError>) -> Void) {
        DispatchQueue.main.async { completion(.success([])) }
    }

    func revokeSession(id: String, token: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        DispatchQueue.main.async { completion(.success(())) }
    }
}

private final class FailedExportAPI: AccountAPIServicing {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func createExport(token: String, completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void) {
        let task = AccountExportTask(
            id: "e1",
            status: .failed,
            createdAt: Date(),
            completedAt: Date(),
            downloadURL: nil,
            downloadExpiresAt: nil,
            expiresAt: Date().addingTimeInterval(3600),
            failureReason: reason
        )
        DispatchQueue.main.async { completion(.success(task)) }
    }

    func fetchExport(id: String, token: String, completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void) {
        completion(.failure(.exportNotFound))
    }

    func downloadExport(url: URL, completion: @escaping (Result<Data, AccountAPIError>) -> Void) {
        completion(.failure(.downloadInvalid))
    }

    func createPairingCode(token: String, completion: @escaping (Result<PairingCode, AccountAPIError>) -> Void) {
        completion(.failure(.invalidCode))
    }

    func claimPairingCode(_ code: String, completion: @escaping (Result<AnonymousSession, AccountAPIError>) -> Void) {
        completion(.failure(.invalidCode))
    }

    func createDeletionRequest(token: String, completion: @escaping (Result<DeletionChallenge, AccountAPIError>) -> Void) {
        completion(.failure(.invalidCode))
    }

    func deleteAccount(deletionToken: String, completion: @escaping (Result<Void, AccountAPIError>) -> Void) {
        completion(.failure(.invalidCode))
    }
}
