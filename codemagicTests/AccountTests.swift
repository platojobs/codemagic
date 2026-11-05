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
    var exportPages: [Result<Data, AccountAPIError>] = []
    var deleteResult: Result<Void, AccountAPIError> = .success(())

    private(set) var createCount = 0
    private(set) var claimCount = 0
    private(set) var claimedCodes: [String] = []
    private(set) var exportRequests: [(cursor: String?, limit: Int, token: String)] = []
    private(set) var deleteTokens: [String] = []

    func createPairingCode(token: String, completion: @escaping (Result<PairingCode, AccountAPIError>) -> Void) {
        createCount += 1
        completion(createResult)
    }

    func claimPairingCode(_ code: String, completion: @escaping (Result<AnonymousSession, AccountAPIError>) -> Void) {
        claimCount += 1
        claimedCodes.append(code)
        completion(claimResult)
    }

    func fetchExportPage(
        cursor: String?,
        limit: Int,
        token: String,
        completion: @escaping (Result<Data, AccountAPIError>) -> Void
    ) {
        exportRequests.append((cursor, limit, token))
        if exportPages.isEmpty {
            completion(.failure(.decoding("stub 未配置导出页")))
        } else {
            completion(exportPages.removeFirst())
        }
    }

    func deleteAccount(token: String, completion: @escaping (Result<Void, AccountAPIError>) -> Void) {
        deleteTokens.append(token)
        completion(deleteResult)
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

    // MARK: - API mapping

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

    func testAccountAPIClient_exportPageCarriesOpaqueCursorAndLimit() {
        let http = StubHTTPClient(statusCode: 200) { _ in .success(Data("{}".utf8)) }
        let client = AccountAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.com")!),
            httpClient: http
        )
        let expectation = expectation(description: "export page")
        client.fetchExportPage(cursor: "opaque-secret", limit: 5000, token: "token") { result in
            if case .failure(let error) = result {
                XCTFail("不应失败：\(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        let url = http.requestedURLs.first
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        XCTAssertEqual(items?.first { $0.name == "limit" }?.value, "5000")
        XCTAssertEqual(items?.first { $0.name == "cursor" }?.value, "opaque-secret")
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer token")
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

    func testAccountExportService_pagesThroughOpaqueCursorsAndWritesFile() throws {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        api.exportPages = [
            .success(makeExportPage(userID: "user-1", readings: 2, hasMore: true, cursor: "opaque-1")),
            .success(makeExportPage(userID: "user-1", readings: 3, hasMore: true, cursor: "opaque-2")),
            .success(makeExportPage(userID: "user-1", readings: 1, hasMore: false, cursor: nil)),
        ]
        let directory = testDatabase.directory.appendingPathComponent("export", isDirectory: true)
        let service = AccountExportService(api: api, tokenStore: tokenStore, directoryURL: directory)

        let expectation = expectation(description: "export")
        var progressValues: [Int] = []
        var fileURL: URL?
        service.export(progress: { progressValues.append($0) }) { result in
            if case .success(let url) = result { fileURL = url }
            if case .failure(let error) = result { XCTFail("导出失败：\(error)") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(progressValues, [2, 5, 6])
        XCTAssertEqual(api.exportRequests.map(\.cursor), [nil, "opaque-1", "opaque-2"])
        XCTAssertEqual(api.exportRequests.map(\.limit), [AccountExportService.pageLimit, AccountExportService.pageLimit, AccountExportService.pageLimit])

        let url = try XCTUnwrap(fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let readings = try XCTUnwrap(object["readings"] as? [[String: Any]])
        XCTAssertEqual(readings.count, 6)
        let user = object["user"] as? [String: Any]
        XCTAssertEqual(user?["id"] as? String, "user-1")

        service.removeExportedFile(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAccountExportService_rejectsRepeatedCursorAndEmptyExport() {
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        api.exportPages = [
            .success(makeExportPage(userID: "user-1", readings: 1, hasMore: true, cursor: "same")),
            .success(makeExportPage(userID: "user-1", readings: 1, hasMore: true, cursor: "same")),
        ]
        let service = AccountExportService(api: api, tokenStore: tokenStore, directoryURL: testDatabase.directory)
        let repeatedExpectation = XCTestExpectation(description: "repeated cursor")
        var captured: AccountExportError?
        service.export(progress: { _ in }) { result in
            if case .failure(let error) = result { captured = error }
            repeatedExpectation.fulfill()
        }
        wait(for: [repeatedExpectation], timeout: 2)
        XCTAssertEqual(captured, .invalidCursor)

        api.exportPages = [.success(makeExportPage(
            userID: "user-1",
            readings: 0,
            hasMore: false,
            cursor: nil,
            devices: 0
        ))]
        let emptyExpectation = expectation(description: "empty export")
        var emptyError: AccountExportError?
        service.export(progress: { _ in }) { result in
            if case .failure(let error) = result { emptyError = error }
            emptyExpectation.fulfill()
        }
        wait(for: [emptyExpectation], timeout: 2)
        XCTAssertEqual(emptyError, .noData)
    }

    func testAccountExportService_requiresSession() {
        let service = AccountExportService(api: api, tokenStore: tokenStore)
        let expectation = expectation(description: "unauthorized")
        service.export(progress: { _ in }) { result in
            XCTAssertEqual(result, .failure(.unauthorized))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(api.exportRequests.isEmpty)
    }

    // MARK: - Deletion

    func testAccountDeletionService_clearsTokenTablesAndMetadataInOrder() throws {
        try seedAllBusinessTables()
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        metadata.userID = "user-1"
        metadata.cursor = 10
        metadata.lastSyncAt = Date()
        metadata.reloginRequired = true
        metadata.lastBackgroundPushAt = Date()
        let clientID = metadata.clientID

        api.deleteResult = .success(())
        let service = AccountDeletionService(
            api: api,
            tokenStore: tokenStore,
            database: testDatabase.database,
            metadataStore: metadata
        )
        let expectation = expectation(description: "delete")
        var captured: Result<Void, AccountDeletionError>?
        service.deleteAccount { result in
            captured = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(api.deleteTokens, ["token-1"])
        guard case .success = captured else {
            XCTFail("注销应成功：\(String(describing: captured))")
            return
        }
        XCTAssertNil(tokenStore.session)
        for table in ["readings", "saved_devices", "rules", "scan_logs", "recent_devices", "device_info_cache"] {
            let rows = try testDatabase.database.query("SELECT COUNT(*) AS total FROM \(table);")
            XCTAssertEqual(rows.first?.integer("total"), 0, "\(table) 应被清空")
        }
        XCTAssertNil(metadata.userID)
        XCTAssertEqual(metadata.cursor, 0)
        XCTAssertNil(metadata.lastSyncAt)
        XCTAssertFalse(metadata.reloginRequired)
        XCTAssertNil(metadata.lastBackgroundPushAt)
        XCTAssertEqual(metadata.clientID, clientID)
    }

    func testAccountDeletionService_unauthorizedAndNetworkKeepLocalData() throws {
        try seedAllBusinessTables()
        tokenStore.session = AnonymousSession(userID: "user-1", token: "token-1")
        let service = AccountDeletionService(
            api: api,
            tokenStore: tokenStore,
            database: testDatabase.database,
            metadataStore: metadata
        )

        api.deleteResult = .failure(.unauthorized)
        let unauthorized = expectation(description: "401")
        service.deleteAccount { result in
            if case .failure(.unauthorized) = result {
                // 预期：401 与网络错误分别处理。
            } else {
                XCTFail("应为未授权：\(result)")
            }
            unauthorized.fulfill()
        }
        wait(for: [unauthorized], timeout: 1)
        XCTAssertEqual(try deviceStore.fetchAll().count, 1)
        XCTAssertEqual(tokenStore.session?.token, "token-1")

        api.deleteResult = .failure(.failure(.network("断网")))
        let network = expectation(description: "network")
        service.deleteAccount { result in
            if case .failure(.network) = result {
                // 预期：网络错误单独处理且保留本地数据。
            } else {
                XCTFail("应为网络错误：\(result)")
            }
            network.fulfill()
        }
        wait(for: [network], timeout: 1)
        XCTAssertEqual(try readingsStore.fetchPending().count, 1)
        XCTAssertEqual(tokenStore.session?.token, "token-1")
    }

    // MARK: - Helpers

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

    private func makeExportPage(
        userID: String,
        readings: Int,
        hasMore: Bool,
        cursor: String?,
        devices: Int = 1
    ) -> Data {
        var object: [String: Any] = [
            "user": ["id": userID],
            "devices": (0..<devices).map { ["id": "device-\($0)", "externalId": "ext-\($0)"] },
            "readings": (0..<readings).map { ["id": "reading-\($0)", "value": $0] },
            "exportedAt": "2026-11-05T00:00:00Z",
            "hasMore": hasMore,
        ]
        if let cursor { object["nextCursor"] = cursor }
        return try! JSONSerialization.data(withJSONObject: object)
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
        try DeviceInfoCacheStore(database: testDatabase.database).save(
            product: makeProduct(),
            peripheralID: device.peripheralID,
            fetchedAt: Date()
        )
    }
}
