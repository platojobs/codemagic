import XCTest
@testable import codemagic

// MARK: - Fakes

final class FakeAccountAPI: AccountAPIServicing {
    var createResult: Result<PairingCode, AccountAPIError> = .success(
        PairingCode(code: "K7M2QX9P", expiresAt: Date().addingTimeInterval(600))
    )
    var claimResult: Result<AnonymousSession, AccountAPIError> = .success(
        AnonymousSession(userID: "user-new", token: "token-new")
    )
    var deletionRequestResult: Result<DeletionChallenge, AccountAPIError> = .success(
        DeletionChallenge(token: "delete-token", expiresAt: Date().addingTimeInterval(600))
    )
    /// 队列里保留最后一个结果用于后续重复调用；用于模拟 409 → 成功 等连续分支。
    var deleteResults: [Result<Void, AccountAPIError>] = [.success(())]
    var exportCreateResult: Result<AccountExportTask, AccountAPIError> = .success(
        FakeAccountAPI.makeTask(id: "export-1", status: .pending)
    )
    var exportFetchResults: [Result<AccountExportTask, AccountAPIError>] = []
    var downloadResults: [Result<Data, AccountAPIError>] = []

    private(set) var createCount = 0
    private(set) var claimCount = 0
    private(set) var claimedCodes: [String] = []
    private(set) var deletionRequestTokens: [String] = []
    private(set) var deleteTokens: [String] = []
    private(set) var exportCreateTokens: [String] = []
    private(set) var exportFetchIDs: [String] = []
    private(set) var downloadURLs: [URL] = []

    func createPairingCode(token: String, completion: @escaping (Result<PairingCode, AccountAPIError>) -> Void) {
        createCount += 1
        completion(createResult)
    }

    func claimPairingCode(_ code: String, completion: @escaping (Result<AnonymousSession, AccountAPIError>) -> Void) {
        claimCount += 1
        claimedCodes.append(code)
        completion(claimResult)
    }

    func createDeletionRequest(
        token: String,
        completion: @escaping (Result<DeletionChallenge, AccountAPIError>) -> Void
    ) {
        deletionRequestTokens.append(token)
        completion(deletionRequestResult)
    }

    func deleteAccount(
        deletionToken: String,
        completion: @escaping (Result<Void, AccountAPIError>) -> Void
    ) {
        deleteTokens.append(deletionToken)
        completion(Self.next(&deleteResults) ?? .success(()))
    }

    func createExport(
        token: String,
        completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void
    ) {
        exportCreateTokens.append(token)
        completion(exportCreateResult)
    }

    func fetchExport(
        id: String,
        token: String,
        completion: @escaping (Result<AccountExportTask, AccountAPIError>) -> Void
    ) {
        exportFetchIDs.append(id)
        completion(Self.next(&exportFetchResults) ?? .failure(.decoding("stub 未配置导出状态")))
    }

    func downloadExport(url: URL, completion: @escaping (Result<Data, AccountAPIError>) -> Void) {
        downloadURLs.append(url)
        completion(Self.next(&downloadResults) ?? .failure(.decoding("stub 未配置下载")))
    }

    static func makeTask(
        id: String,
        status: AccountExportTask.Status,
        downloadURL: URL? = nil
    ) -> AccountExportTask {
        AccountExportTask(
            id: id,
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_000),
            completedAt: status == .pending ? nil : Date(timeIntervalSince1970: 1_010),
            downloadURL: downloadURL,
            downloadExpiresAt: downloadURL == nil ? nil : Date(timeIntervalSince1970: 2_000),
            expiresAt: Date(timeIntervalSince1970: 100_000),
            failureReason: nil
        )
    }

    private static func next<T>(_ queue: inout [T]) -> T? {
        guard !queue.isEmpty else { return nil }
        if queue.count > 1 {
            return queue.removeFirst()
        }
        return queue[0]
    }
}

final class FakePairingService: PairingServicing {
    var createResult: Result<PairingCode, PairingError> = .success(
        PairingCode(code: "K7M2QX9P", expiresAt: Date().addingTimeInterval(600))
    )
    var claimResult: Result<PairingClaimResult, PairingError> = .success(
        PairingClaimResult(userID: "user-1", deviceCount: 2, readingCount: 5)
    )
    private(set) var createCount = 0
    private(set) var claimedCodes: [String] = []

    func createCode(completion: @escaping (Result<PairingCode, PairingError>) -> Void) {
        createCount += 1
        completion(createResult)
    }

    func claim(code: String, completion: @escaping (Result<PairingClaimResult, PairingError>) -> Void) {
        claimedCodes.append(code)
        completion(claimResult)
    }
}

// MARK: - Tests

final class AccountTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var deviceStore: SavedDeviceStore!
    private var readingsStore: ReadingsStore!
    private var logStore: ScanLogStore!
    private var metadata: SyncMetadataStore!
    private var tokenStore: InMemoryTokenStore!
    private var api: FakeAccountAPI!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        suiteName = "codemagic.account.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        metadata = SyncMetadataStore(defaults: defaults)
        deviceStore = SavedDeviceStore(database: testDatabase.database)
        readingsStore = ReadingsStore(database: testDatabase.database)
        logStore = ScanLogStore(database: testDatabase.database)
        tokenStore = InMemoryTokenStore()
        api = FakeAccountAPI()
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Pairing formatter

    func testPairingCodeFormatter_normalizesUppercasesAndFiltersConfusables() {
        XCTAssertEqual(PairingCodeFormatter.normalize("k7m2 qx9p"), "K7M2QX9P")
        XCTAssertEqual(PairingCodeFormatter.normalize("a0b1c-o i d!"), "ABCD")
        XCTAssertEqual(PairingCodeFormatter.normalize("ABCDEFGHJKLM"), "ABCDEFGH")
        XCTAssertTrue(PairingCodeFormatter.isComplete("K7M2QX9P"))
        XCTAssertFalse(PairingCodeFormatter.isComplete("K7M2QX9"))
        XCTAssertFalse(PairingCodeFormatter.isComplete("K7M2QX0P"))
        XCTAssertEqual(PairingCodeFormatter.grouped("ABCDEFGH"), "ABCD EFGH")
    }

    func testPairingCountdown_formatsWithPOSIXLocale() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            PairingCountdown.remainingSeconds(expiresAt: now.addingTimeInterval(0.4), now: now),
            1
        )
        XCTAssertEqual(PairingCountdown.remainingSeconds(expiresAt: now.addingTimeInterval(-10), now: now), 0)
        XCTAssertEqual(PairingCountdown.text(seconds: 90), "01:30")
        XCTAssertEqual(PairingCountdown.text(seconds: 0), "00:00")
    }

    // MARK: - API mapping & DTO contract

    func testAccountAPIClient_mapsNotFoundToInvalidCode() {
        let http = StubHTTPClient(statusCode: 404) { _ in .success(Data("{}".utf8)) }
        let client = AccountAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http
        )
        let expectation = expectation(description: "claim 404")
        client.claimPairingCode("K7MQX9P") { result in
            XCTAssertEqual(result, .failure(.invalidCode))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(http.requests.first?.url.path, "/api/v1/auth/pairing-code/claim")
        XCTAssertEqual(http.requests.first?.method, "POST")
    }

    func testAccountAPIClient_readsRetryAfterFor429() {
        let http = StubHTTPClient(
            statusCode: 429,
            responseHeaders: ["Retry-After": "42"]
        ) { _ in .success(Data("{}".utf8)) }
        let client = AccountAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http
        )
        let expectation = expectation(description: "429")
        client.claimPairingCode("K7MQX9P") { result in
            XCTAssertEqual(result, .failure(.rateLimited(retryAfterSeconds: 42)))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testAccountAPIClient_decodesPairingCodeWithRealExpiresAt() {
        let data = Data(#"{"code":"K7M2QX9P","expiresAt":"2026-11-05T10:00:00Z"}"#.utf8)
        let http = StubHTTPClient(statusCode: 201) { _ in .success(data) }
        let client = AccountAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http
        )
        let expectation = expectation(description: "create code")
        client.createPairingCode(token: "token") { result in
            guard case .success(let code) = result else {
                XCTFail("应成功：\(result)")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(code.code, "K7M2QX9P")
            XCTAssertEqual(code.expiresAt, SyncDateCodec.parse("2026-11-05T10:00:00Z"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    /// DTO 契约（契约 0.15.0）：删除请求返回 token + expiresAt，走 Bearer。
    func testAccountAPIClient_deletionRequestCarriesBearerAndDecodesToken() {
        let data = Data(#"{"token":"del-1","expiresAt":"2026-11-06T10:10:00Z"}"#.utf8)
        let http = StubHTTPClient(statusCode: 201) { _ in .success(data) }
        let client = AccountAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http
        )
        let expectation = expectation(description: "deletion request")
        client.createDeletionRequest(token: "bearer") { result in
            guard case .success(let challenge) = result else {
                XCTFail("应成功：\(result)")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(challenge.token, "del-1")
            XCTAssertEqual(challenge.expiresAt, SyncDateCodec.parse("2026-11-06T10:10:00Z"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(http.requests.first?.method, "POST")
        XCTAssertEqual(http.requests.first?.url.path, "/api/v1/me/deletion-request")
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer bearer")
    }

    /// `DELETE /me` 只用 X-Deletion-Token，不得带 Bearer。
    func testAccountAPIClient_deleteUsesDeletionTokenWithoutBearer() {
        let http = StubHTTPClient(statusCode: 204) { _ in .success(Data()) }
        let client = AccountAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http
        )
        let expectation = expectation(description: "delete")
        client.deleteAccount(deletionToken: "del-1") { result in
            if case .failure(let error) = result { XCTFail("应成功：\(error)") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(http.requests.first?.method, "DELETE")
        XCTAssertEqual(http.requests.first?.url.path, "/api/v1/me")
        XCTAssertEqual(http.requests.first?.headers["X-Deletion-Token"], "del-1")
        XCTAssertNil(http.requests.first?.headers["Authorization"])
    }

    func testAccountAPIClient_mapsDeletionStatusToDistinctErrors() {
        let cases: [(Int, String, AccountAPIError)] = [
            (409, "ACCOUNT_DELETION_BLOCKED", .deletionBlocked),
            (403, "DELETION_TOKEN_INVALID", .deletionTokenInvalid),
            (404, "NOT_FOUND", .accountDeleted),
            (410, "DELETION_TOKEN_EXPIRED", .deletionTokenExpired),
        ]
        let baseURL = URL(string: "https://example.com")!
        for (status, code, expected) in cases {
            let body = Data(#"{"error":{"code":"\#(code)","message":"detail"}}"#.utf8)
            let http = StubHTTPClient(statusCode: status) { _ in .success(body) }
            let client = AccountAPIClient(configuration: APIConfiguration(baseURL: baseURL), httpClient: http)
            let expectation = expectation(description: "delete \(status)")
            client.deleteAccount(deletionToken: "del") { result in
                guard case .failure(let error) = result else {
                    XCTFail("\(status) 应失败")
                    expectation.fulfill()
                    return
                }
                XCTAssertEqual(error, expected, "\(status) 应映射为 \(expected)")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 1)
        }
    }

    func testAccountAPIClient_decodesPendingAndReadyExportTasks() {
        let pending = Data(#"{"id":"exp-1","status":"pending","createdAt":"2026-11-06T10:00:00Z","completedAt":null,"downloadUrl":null,"downloadExpiresAt":null,"expiresAt":"2026-11-06T11:00:00Z"}"#.utf8)
        let ready = Data(#"{"id":"exp-1","status":"ready","createdAt":"2026-11-06T10:00:00Z","completedAt":"2026-11-06T10:01:00Z","downloadUrl":"/api/v1/me/export/exp-1/download?token=dl-1","downloadExpiresAt":"2026-11-06T10:11:00Z","expiresAt":"2026-11-06T11:00:00Z"}"#.utf8)

        let pendingHTTP = StubHTTPClient(statusCode: 202) { _ in .success(pending) }
        let pendingClient = AccountAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: pendingHTTP
        )
        let pendingExpectation = expectation(description: "pending task")
        pendingClient.createExport(token: "bearer") { result in
            guard case .success(let task) = result else {
                XCTFail("应成功：\(result)")
                pendingExpectation.fulfill()
                return
            }
            XCTAssertEqual(task.id, "exp-1")
            XCTAssertEqual(task.status, .pending)
            XCTAssertNil(task.downloadURL)
            XCTAssertEqual(task.createdAt, SyncDateCodec.parse("2026-11-06T10:00:00Z"))
            XCTAssertEqual(task.expiresAt, SyncDateCodec.parse("2026-11-06T11:00:00Z"))
            pendingExpectation.fulfill()
        }
        wait(for: [pendingExpectation], timeout: 1)
        XCTAssertEqual(pendingHTTP.requests.first?.method, "POST")
        XCTAssertEqual(pendingHTTP.requests.first?.url.path, "/api/v1/me/export")
        XCTAssertEqual(pendingHTTP.requests.first?.headers["Authorization"], "Bearer bearer")

        let readyHTTP = StubHTTPClient(statusCode: 200) { _ in .success(ready) }
        let readyClient = AccountAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: readyHTTP
        )
        let readyExpectation = expectation(description: "ready task")
        readyClient.fetchExport(id: "exp-1", token: "bearer") { result in
            guard case .success(let task) = result else {
                XCTFail("应成功：\(result)")
                readyExpectation.fulfill()
                return
            }
            XCTAssertEqual(task.status, .ready)
            // 相对下载地址必须按 BASE_URL 解析成绝对地址，供无 Bearer 下载使用。
            XCTAssertEqual(
                task.downloadURL?.absoluteString,
                "https://example.com/api/v1/me/export/exp-1/download?token=dl-1"
            )
            XCTAssertEqual(task.completedAt, SyncDateCodec.parse("2026-11-06T10:01:00Z"))
            readyExpectation.fulfill()
        }
        wait(for: [readyExpectation], timeout: 1)
        XCTAssertEqual(readyHTTP.requests.first?.method, "GET")
        XCTAssertEqual(readyHTTP.requests.first?.url.path, "/api/v1/me/export/exp-1")
    }

    func testAccountAPIClient_mapsDownloadExpiredAndInvalid() {
        let http = StubHTTPClient(statusCode: 410) { _ in .success(Data("{}".utf8)) }
        let client = AccountAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http
        )
        let expired = expectation(description: "410")
        client.downloadExport(url: URL(string: "https://example.com/download")!) { result in
            XCTAssertEqual(result, .failure(.downloadExpired))
            expired.fulfill()
        }
        wait(for: [expired], timeout: 1)

        http.statusCode = 403
        let invalid = expectation(description: "403")
        client.downloadExport(url: URL(string: "https://example.com/download")!) { result in
            XCTAssertEqual(result, .failure(.downloadInvalid))
            invalid.fulfill()
        }
        wait(for: [invalid], timeout: 1)
    }

    // MARK: - Pairing service

    func testPairingService_claimReplacesTokenAndMarksLocalDataPending() throws {
        let active = makeSavedDevice(name: "活跃设备")
        let deleted = makeSavedDevice(name: "已删除设备")
        try deviceStore.upsert(active)
        try deviceStore.upsert(deleted)
        try deviceStore.softDelete(id: deleted.id)
        try deviceStore.markSynced(ids: [active.id, deleted.id], at: Date())
        try readingsStore.insert(DeviceReading(deviceID: active.id, metric: .temperature, value: 21, unit: "℃"))
        try readingsStore.insert(DeviceReading(deviceID: active.id, metric: .battery, value: 80, unit: "%"))
        try readingsStore.markSynced(ids: try readingsStore.fetchPending().map(\.id))

        tokenStore.session = AnonymousSession(userID: "user-old", token: "token-old")
        metadata.userID = "user-old"
        metadata.cursor = 88
        metadata.reloginRequired = true

        api.claimResult = .success(AnonymousSession(userID: "user-new", token: "token-new"))
        let service = makePairingService()
        let expectation = expectation(description: "claim")
        var captured: Result<PairingClaimResult, PairingError>?
        service.claim(code: "k7m2 qx9p") { result in
            captured = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        guard case .success(let result) = captured else {
            XCTFail("接管应成功：\(String(describing: captured))")
            return
        }
        XCTAssertEqual(result.userID, "user-new")
        XCTAssertEqual(result.deviceCount, 1)
        XCTAssertEqual(result.readingCount, 2)
        XCTAssertEqual(api.claimedCodes, ["K7M2QX9P"])
        XCTAssertEqual(tokenStore.session?.token, "token-new")
        XCTAssertEqual(metadata.userID, "user-new")
        XCTAssertEqual(metadata.cursor, 0)
        XCTAssertNil(metadata.lastSyncAt)
        XCTAssertFalse(metadata.reloginRequired)
        XCTAssertEqual(try deviceStore.fetchPending().count, 1)
        XCTAssertEqual(try readingsStore.fetchPending().count, 2)
    }

    func testPairingService_rejectsIncompleteCodeWithoutRequest() {
        tokenStore.session = AnonymousSession(userID: "user-old", token: "token-old")
        let service = makePairingService()
        let expectation = expectation(description: "invalid format")
        service.claim(code: "K7M2QX") { result in
            XCTAssertEqual(result, .failure(.invalidFormat))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(api.claimCount, 0)
    }

    func testPairingService_createCodeRequiresToken() {
        let service = makePairingService()
        let expectation = expectation(description: "no token")
        service.createCode { result in
            XCTAssertEqual(result, .failure(.api(.unauthorized)))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(api.createCount, 0)
    }

    // MARK: - View models

    func testPairingCodeViewModel_countdownUsesRealExpiryAndRegenerate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fake = FakePairingService()
        fake.createResult = .success(PairingCode(code: "K7M2QX9P", expiresAt: now.addingTimeInterval(600)))
        let viewModel = PairingCodeViewModel(service: fake, now: { now })

        viewModel.generate()
        XCTAssertEqual(viewModel.codeDisplayText, "K7M2 QX9P")
        XCTAssertEqual(viewModel.countdownText, "剩余 10:00")
        XCTAssertTrue(viewModel.canCopy)

        let expiredViewModel = PairingCodeViewModel(service: fake, now: { now.addingTimeInterval(601) })
        expiredViewModel.generate()
        XCTAssertTrue(expiredViewModel.isExpired)
        XCTAssertFalse(expiredViewModel.canCopy)
        XCTAssertEqual(expiredViewModel.countdownText, "已过期，请重新生成")

        viewModel.generate()
        XCTAssertEqual(fake.createCount, 3)
    }

    func testPairingClaimViewModel_filtersInputAndHonorsRetryAfterCooldown() {
        var now = Date(timeIntervalSince1970: 1_000)
        let fake = FakePairingService()
        fake.claimResult = .failure(.api(.rateLimited(retryAfterSeconds: 12)))
        let viewModel = PairingClaimViewModel(service: fake, now: { now })

        XCTAssertEqual(viewModel.updateInput("k7m2-qx9p0"), "K7M2QX9P")
        XCTAssertTrue(viewModel.isComplete)
        XCTAssertTrue(viewModel.canClaim)

        viewModel.claim()
        XCTAssertEqual(viewModel.cooldownSeconds(), 12)
        XCTAssertFalse(viewModel.canClaim)
        XCTAssertTrue(viewModel.statusText.contains("12 秒"))

        now = now.addingTimeInterval(13)
        viewModel.clearCooldownIfNeeded()
        XCTAssertEqual(viewModel.cooldownSeconds(), 0)
        XCTAssertTrue(viewModel.canClaim)
    }

    // MARK: - Export

    func testAccountExportService_pollsWithBackoffThenDownloadsFile() throws {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        let finalURL = URL(string: "https://example.com/api/v1/me/export/exp-1/download?token=dl-1")!
        api.exportCreateResult = .success(FakeAccountAPI.makeTask(id: "exp-1", status: .pending))
        api.exportFetchResults = [
            .success(FakeAccountAPI.makeTask(id: "exp-1", status: .pending)),
            .success(FakeAccountAPI.makeTask(id: "exp-1", status: .pending)),
            .success(FakeAccountAPI.makeTask(id: "exp-1", status: .ready, downloadURL: finalURL)),
        ]
        api.downloadResults = [.success(Data(#"{"user":{"id":"user-1"},"readings":[]}"#.utf8))]

        var delays: [TimeInterval] = []
        let service = AccountExportService(
            api: api,
            tokenStore: tokenStore,
            directoryURL: testDatabase.directory.appendingPathComponent("export", isDirectory: true),
            scheduler: { delay, block in
                delays.append(delay)
                block()
            }
        )
        let expectation = expectation(description: "export")
        var phases: [AccountExportPhase] = []
        var output: AccountExportResult?
        service.export(progress: { phases.append($0) }) { result in
            if case .success(let value) = result { output = value }
            if case .failure(let error) = result { XCTFail("导出失败：\(error)") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)

        let fileURL = try XCTUnwrap(output?.fileURL)
        XCTAssertFalse(output?.refreshedDownloadToken ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: fileURL), Data(#"{"user":{"id":"user-1"},"readings":[]}"#.utf8))
        XCTAssertEqual(delays.count, 3)
        XCTAssertEqual(delays[0], 2.5, accuracy: 0.001)
        XCTAssertEqual(delays[1], 3.5, accuracy: 0.001)
        XCTAssertEqual(delays[2], 4.9, accuracy: 0.001)
        XCTAssertEqual(api.exportFetchIDs, ["exp-1", "exp-1", "exp-1"])
        XCTAssertEqual(api.downloadURLs, [finalURL])
        XCTAssertEqual(phases, [.creating, .pending(attempt: 1), .pending(attempt: 2), .pending(attempt: 3), .downloading])

        service.removeAllExportedFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAccountExportService_refreshesExpiredDownloadTokenOnce() throws {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        let staleURL = URL(string: "https://example.com/api/v1/me/export/exp-1/download?token=old")!
        let freshURL = URL(string: "https://example.com/api/v1/me/export/exp-1/download?token=new")!
        api.exportCreateResult = .success(FakeAccountAPI.makeTask(id: "exp-1", status: .ready, downloadURL: staleURL))
        api.exportFetchResults = [
            .success(FakeAccountAPI.makeTask(id: "exp-1", status: .ready, downloadURL: freshURL)),
        ]
        api.downloadResults = [
            .failure(.downloadExpired),
            .success(Data(#"{"user":{"id":"user-1"}}"#.utf8)),
        ]

        let service = AccountExportService(
            api: api,
            tokenStore: tokenStore,
            directoryURL: testDatabase.directory.appendingPathComponent("export", isDirectory: true),
            scheduler: { _, block in block() }
        )
        let expectation = expectation(description: "refresh token")
        var phases: [AccountExportPhase] = []
        var output: AccountExportResult?
        service.export(progress: { phases.append($0) }) { result in
            if case .success(let value) = result { output = value }
            if case .failure(let error) = result { XCTFail("应自动重试成功：\(error)") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(output?.refreshedDownloadToken, true)
        XCTAssertEqual(api.downloadURLs, [staleURL, freshURL])
        XCTAssertEqual(phases, [.creating, .downloading, .refreshingDownload])
        let fileURL = try XCTUnwrap(output?.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAccountExportService_reportsTaskFailedAndTimeout() {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        api.exportCreateResult = .success(FakeAccountAPI.makeTask(id: "exp-1", status: .failed))
        let failed = expectation(description: "failed")
        let service = AccountExportService(api: api, tokenStore: tokenStore, scheduler: { _, block in block() })
        service.export(progress: { _ in }) { result in
            XCTAssertEqual(result, .failure(.taskFailed(reason: nil)))
            failed.fulfill()
        }
        wait(for: [failed], timeout: 1)

        api.exportCreateResult = .success(FakeAccountAPI.makeTask(id: "exp-2", status: .pending))
        api.exportFetchResults = [.success(FakeAccountAPI.makeTask(id: "exp-2", status: .pending))]
        let timeoutService = AccountExportService(
            api: api,
            tokenStore: tokenStore,
            maxPollAttempts: 2,
            scheduler: { _, block in block() }
        )
        let timeout = expectation(description: "timeout")
        timeoutService.export(progress: { _ in }) { result in
            XCTAssertEqual(result, .failure(.timeout))
            timeout.fulfill()
        }
        wait(for: [timeout], timeout: 1)
    }

    func testAccountExportService_requiresSession() {
        let service = AccountExportService(api: api, tokenStore: tokenStore, scheduler: { _, block in block() })
        let expectation = expectation(description: "unauthorized")
        service.export(progress: { _ in }) { result in
            XCTAssertEqual(result, .failure(.unauthorized))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(api.exportCreateTokens.isEmpty)
    }

    // MARK: - Deletion

    func testDeletion_tokenFlowClearsEveryLocalTableAndSurvivesRestart() throws {
        try seedAllBusinessTables()
        XCTAssertNotNil(DeviceCatalogStore(database: testDatabase.database).load())
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        metadata.userID = "user-1"
        metadata.cursor = 10
        metadata.lastSyncAt = Date()
        metadata.reloginRequired = true
        metadata.lastBackgroundPushAt = Date()
        let clientID = metadata.clientID

        var urlCacheCleared = false
        var bluetoothDisconnected = false
        var exportedFilesCleared = false
        let service = AccountDeletionService(
            api: api,
            tokenStore: tokenStore,
            database: testDatabase.database,
            metadataStore: metadata,
            clearURLCache: { urlCacheCleared = true },
            disconnectBluetooth: { bluetoothDisconnected = true },
            additionalCleanup: { exportedFilesCleared = true }
        )

        let requestExpectation = expectation(description: "request token")
        var challenge: DeletionChallenge?
        service.requestDeletionToken { result in
            if case .success(let value) = result { challenge = value }
            if case .failure(let error) = result { XCTFail("申请令牌失败：\(error)") }
            requestExpectation.fulfill()
        }
        wait(for: [requestExpectation], timeout: 1)
        XCTAssertEqual(api.deletionRequestTokens, ["token-1"])
        XCTAssertEqual(try XCTUnwrap(challenge).token, "delete-token")

        api.deleteResults = [.success(())]
        let confirmExpectation = expectation(description: "confirm")
        var outcome: AccountDeletionOutcome?
        service.confirmDeletion(try XCTUnwrap(challenge)) { result in
            if case .success(let value) = result { outcome = value }
            if case .failure(let error) = result { XCTFail("删除失败：\(error)") }
            confirmExpectation.fulfill()
        }
        wait(for: [confirmExpectation], timeout: 1)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(api.deleteTokens, ["delete-token"])
        XCTAssertNil(tokenStore.session)
        XCTAssertTrue(urlCacheCleared)
        XCTAssertTrue(bluetoothDisconnected)
        XCTAssertTrue(exportedFilesCleared)
        for table in businessTables {
            XCTAssertEqual(try count(table), 0, "\(table) 应被清空")
        }
        XCTAssertNil(DeviceCatalogStore(database: testDatabase.database).load())
        XCTAssertNil(metadata.userID)
        XCTAssertEqual(metadata.cursor, 0)
        XCTAssertNil(metadata.lastSyncAt)
        XCTAssertFalse(metadata.reloginRequired)
        XCTAssertNil(metadata.lastBackgroundPushAt)
        XCTAssertEqual(metadata.clientID, clientID)

        // 重启后重新打开同一个 SQLite 文件，业务表必须仍为空，不能从缓存放回。
        let reopened = try testDatabase.makeDatabaseHandle()
        defer { reopened.close() }
        for table in businessTables {
            let rows = try reopened.query("SELECT COUNT(*) AS total FROM \(table);")
            XCTAssertEqual(rows.first?.integer("total"), 0, "重启后 \(table) 不应复活")
        }
    }

    func testDeletion_blockedThenSameTokenSucceedsAfterTransfer() throws {
        try seedAllBusinessTables()
        let deviceCountBefore = try deviceStore.fetchAll().count
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        api.deleteResults = [.failure(.deletionBlocked), .success(())]
        let service = AccountDeletionService(
            api: api,
            tokenStore: tokenStore,
            database: testDatabase.database,
            metadataStore: metadata
        )

        let requestExpectation = expectation(description: "request")
        var challenge: DeletionChallenge?
        service.requestDeletionToken { result in
            if case .success(let value) = result { challenge = value }
            requestExpectation.fulfill()
        }
        wait(for: [requestExpectation], timeout: 1)
        let token = try XCTUnwrap(challenge)

        let blockedExpectation = expectation(description: "blocked")
        service.confirmDeletion(token) { result in
            XCTAssertEqual(result, .failure(.blocked))
            blockedExpectation.fulfill()
        }
        wait(for: [blockedExpectation], timeout: 1)
        // 409 不做本地清理，令牌仍可用。
        XCTAssertEqual(try deviceStore.fetchAll().count, deviceCountBefore)
        XCTAssertNotNil(tokenStore.session)
        XCTAssertNotNil(DeviceCatalogStore(database: testDatabase.database).load())

        let successExpectation = expectation(description: "retry success")
        service.confirmDeletion(token) { result in
            XCTAssertEqual(result, .success(.deleted))
            successExpectation.fulfill()
        }
        wait(for: [successExpectation], timeout: 1)
        // 同一令牌重放：服务端成功删除，本地清空。
        XCTAssertEqual(api.deleteTokens, [token.token, token.token])
        XCTAssertNil(tokenStore.session)
        for table in businessTables {
            XCTAssertEqual(try count(table), 0, "\(table) 应被清空")
        }
    }

    func testDeletion_tokenInvalidKeepsLocalUntilReapply() throws {
        try seedAllBusinessTables()
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        api.deleteResults = [.failure(.deletionTokenInvalid)]
        let service = AccountDeletionService(
            api: api,
            tokenStore: tokenStore,
            database: testDatabase.database,
            metadataStore: metadata
        )
        let invalidExpectation = expectation(description: "403")
        service.confirmDeletion(DeletionChallenge(token: "expired", expiresAt: Date())) { result in
            XCTAssertEqual(result, .failure(.tokenInvalid))
            invalidExpectation.fulfill()
        }
        wait(for: [invalidExpectation], timeout: 1)
        XCTAssertEqual(try deviceStore.fetchAll().count, 1)
        XCTAssertNotNil(tokenStore.session)

        // 重新申请后成功删除。
        api.deleteResults = [.success(())]
        let retry = expectation(description: "reapply")
        service.confirmDeletion(DeletionChallenge(token: "fresh", expiresAt: Date())) { result in
            XCTAssertEqual(result, .success(.deleted))
            retry.fulfill()
        }
        wait(for: [retry], timeout: 1)
        XCTAssertNil(tokenStore.session)
        XCTAssertEqual(try count("saved_devices"), 0)
    }

    func testDeletion_404IsTreatedAsDeletedAndClearsLocal() throws {
        try seedAllBusinessTables()
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        api.deleteResults = [.failure(.accountDeleted)]
        let service = AccountDeletionService(
            api: api,
            tokenStore: tokenStore,
            database: testDatabase.database,
            metadataStore: metadata
        )
        let expectation = expectation(description: "404 replay")
        service.confirmDeletion(DeletionChallenge(token: "replayed", expiresAt: Date())) { result in
            XCTAssertEqual(result, .success(.alreadyDeleted))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertNil(tokenStore.session)
        for table in businessTables {
            XCTAssertEqual(try count(table), 0, "\(table) 应被清空")
        }
    }

    func testDeletion_networkFailureKeepsLocalAndRetryable() throws {
        try seedAllBusinessTables()
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        api.deleteResults = [.failure(.failure(.network("断网")))]
        let service = AccountDeletionService(
            api: api,
            tokenStore: tokenStore,
            database: testDatabase.database,
            metadataStore: metadata
        )
        let expectation = expectation(description: "offline")
        service.confirmDeletion(DeletionChallenge(token: "pending", expiresAt: Date())) { result in
            guard case .failure(.network(let error)) = result else {
                XCTFail("应为网络错误：\(result)")
                expectation.fulfill()
                return
            }
            XCTAssertTrue(error.isRetryable)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(try deviceStore.fetchAll().count, 1)
        XCTAssertEqual(try readingsStore.fetchPending().count, 1)
        XCTAssertNotNil(tokenStore.session)
    }

    func testDeletion_requestTokenRequiresSession() {
        let service = AccountDeletionService(
            api: api,
            tokenStore: tokenStore,
            database: testDatabase.database,
            metadataStore: metadata
        )
        let expectation = expectation(description: "no session")
        service.requestDeletionToken { result in
            XCTAssertEqual(result, .failure(.unauthorized))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(api.deletionRequestTokens.isEmpty)
    }

    // MARK: - Helpers

    private var businessTables: [String] {
        [
            "readings", "saved_devices", "rules", "scan_logs", "recent_devices",
            "device_info_cache", "feedback_drafts", "scenarios", "device_catalog_cache",
        ]
    }

    private func count(_ table: String) throws -> Int {
        let rows = try testDatabase.database.query("SELECT COUNT(*) AS total FROM \(table);")
        return Int(rows.first?.integer("total") ?? 0)
    }

    private func makePairingService() -> PairingService {
        PairingService(
            api: api,
            tokenStore: tokenStore,
            deviceStore: deviceStore,
            readingsStore: readingsStore,
            metadataStore: metadata,
            logStore: logStore
        )
    }

    private func makeSavedDevice(name: String) -> SavedDevice {
        SavedDevice(peripheralID: UUID(), advertisedName: name)
    }

    private func seedAllBusinessTables() throws {
        let device = makeSavedDevice(name: "设备")
        try deviceStore.upsert(device)
        try readingsStore.insert(DeviceReading(deviceID: device.id, metric: .temperature, value: 20, unit: "℃"))
        try DeviceRuleStore(database: testDatabase.database).upsert(
            DeviceRule(name: "断连告警", trigger: .disconnect)
        )
        try logStore.append(ScanLogEntry(category: .sync, message: "测试日志"))
        try RecentDeviceStore(database: testDatabase.database).upsert(
            peripheralID: device.peripheralID,
            name: device.displayName,
            rssi: -60,
            lastSeenAt: Date()
        )
        try FeedbackStore(database: testDatabase.database).insert(
            category: .other,
            message: "待发反馈",
            contact: ""
        )
        try ScenarioStore(database: testDatabase.database).upsert(
            Scenario(name: "场景", actions: [.syncNow])
        )
        let catalog = DeviceTypeCatalog(version: 1, generatedAt: Date(), items: [])
        let payload = Data(#"{"version":1,"generatedAt":"2026-11-06T10:00:00Z","items":[]}"#.utf8)
        DeviceCatalogStore(database: testDatabase.database).save(
            catalog: catalog,
            rawPayload: payload,
            etag: "\"catalog-v1\"",
            lastModified: nil,
            fetchedAt: Date()
        )
    }
}
