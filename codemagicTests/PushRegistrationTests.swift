import UserNotifications
import XCTest
@testable import codemagic

private final class FakePushTokenProvider: PushTokenProviding {
    var cachedToken: String?
    var onUpdate: ((Result<String, PushTokenFailure>) -> Void)?
    var requestResult: Result<String, PushTokenFailure>?
    private(set) var requestCount = 0

    func requestToken(completion: @escaping (Result<String, PushTokenFailure>) -> Void) {
        requestCount += 1
        if let requestResult {
            if case .success(let token) = requestResult {
                cachedToken = token
            }
            completion(requestResult)
        }
    }

    func deliver(_ result: Result<String, PushTokenFailure>) {
        if case .success(let token) = result {
            cachedToken = token
        }
        onUpdate?(result)
    }
}

private final class FakePushDeviceAPI: PushDeviceAPIServicing {
    var registerResults: [Result<RemotePushDevice, AppError>] = []
    var deactivateResult: Result<PushDeactivationOutcome, AppError> = .success(.deactivated)
    private(set) var payloads: [PushRegistrationPayload] = []
    private(set) var deactivatedIDs: [String] = []
    private(set) var events: [String] = []

    func register(
        payload: PushRegistrationPayload,
        authToken: String,
        completion: @escaping (Result<RemotePushDevice, AppError>) -> Void
    ) {
        payloads.append(payload)
        events.append("register:\(payload.token)")
        let result = registerResults.isEmpty
            ? .success(RemotePushDevice(id: "remote-\(payload.token)", status: "active"))
            : registerResults.removeFirst()
        completion(result)
    }

    func deactivate(
        deviceID: String,
        authToken: String,
        completion: @escaping (Result<PushDeactivationOutcome, AppError>) -> Void
    ) {
        deactivatedIDs.append(deviceID)
        events.append("deactivate:\(deviceID)")
        completion(deactivateResult)
    }
}

final class PushRegistrationTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var tokenStore: InMemoryTokenStore!
    private var api: FakePushDeviceAPI!
    private var provider: FakePushTokenProvider!
    private var service: PushRegistrationService!
    private var now: Date!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
        tokenStore = InMemoryTokenStore()
        tokenStore.session = AnonymousSession(userID: "user-1", token: "auth-token")
        api = FakePushDeviceAPI()
        provider = FakePushTokenProvider()
        now = Date(timeIntervalSince1970: 1_000_000)
    }

    override func tearDown() {
        testDatabase?.cleanUp()
    }

    private func makeService(clock: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000_000) }) {
        service = PushRegistrationService(
            api: api,
            store: PushDeviceStore(database: testDatabase.database),
            tokenStore: tokenStore,
            tokenProvider: provider,
            platform: "ios",
            now: clock,
            appVersion: { "0.26.0" },
            deviceModel: { "iPhone" }
        )
    }

    // MARK: - 注册

    func testRegistersCachedTokenWithBearerAndAppMetadata() {
        provider.cachedToken = "abc123"
        makeService()

        service.requestRegistration(force: false)

        XCTAssertEqual(api.payloads.count, 1)
        XCTAssertEqual(api.payloads.first?.platform, "ios")
        XCTAssertEqual(api.payloads.first?.token, "abc123")
        XCTAssertEqual(api.payloads.first?.appVersion, "0.26.0")
        XCTAssertEqual(api.payloads.first?.deviceModel, "iPhone")
        XCTAssertEqual(service.record?.status, .registered)
        XCTAssertEqual(service.record?.remoteDeviceID, "remote-abc123")
    }

    func testRequestTokenThenRegistersWhenSystemReturnsToken() {
        provider.requestResult = .success("from-apns")
        makeService()

        service.requestRegistration(force: false)

        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(api.payloads.first?.token, "from-apns")
        XCTAssertEqual(service.record?.status, .registered)
    }

    func testTokenChangeReRegistersAndDeactivatesOldDevice() {
        provider.cachedToken = "token-a"
        makeService()
        service.requestRegistration(force: false)
        XCTAssertEqual(service.record?.remoteDeviceID, "remote-token-a")

        // AppDelegate 收到新的 APNs token。
        provider.deliver(.success("token-b"))

        XCTAssertEqual(api.events, [
            "register:token-a",
            "deactivate:remote-token-a",
            "register:token-b"
        ])
        XCTAssertEqual(service.record?.token, "token-b")
        XCTAssertEqual(service.record?.remoteDeviceID, "remote-token-b")
        XCTAssertEqual(service.record?.status, .registered)
    }

    // MARK: - 拿不到真实 token

    func testMissingEntitlementDoesNotFabricateTokenAndShowsUnconfigured() {
        provider.requestResult = .failure(PushTokenFailure(
            message: "no valid 'aps-environment' entitlement string found for application",
            isConfigurationMissing: true
        ))
        makeService()

        service.requestRegistration(force: false)

        XCTAssertEqual(api.payloads.count, 0, "拿不到 token 时绝不能注册占位令牌")
        XCTAssertEqual(service.record?.status, .missingToken)
        XCTAssertNil(service.record?.token)
        XCTAssertNil(service.record?.remoteDeviceID)
        XCTAssertEqual(
            PushStatusPresentation.value(for: service.record, authorization: .denied),
            L10n.t("push.status.missingToken")
        )
        let guidance = PushStatusPresentation.guidance(for: service.record, authorization: .denied)
        XCTAssertFalse(guidance.contains(L10n.t("push.status.registered")))
    }

    func testAppActiveAfterMissingTokenDoesNotCallServer() {
        provider.requestResult = .failure(PushTokenFailure(message: "unavailable", isConfigurationMissing: true))
        makeService()
        service.requestRegistration(force: false)

        provider.requestResult = .failure(PushTokenFailure(message: "still unavailable", isConfigurationMissing: true))
        service.appDidBecomeActive()

        XCTAssertEqual(api.payloads.count, 0)
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertEqual(service.record?.status, .missingToken)
    }

    // MARK: - 权限与注册解耦

    func testPermissionDeniedStillRegistersButPresentationSaysPushWillNotShow() {
        provider.requestResult = .success("token-ok")
        makeService()

        // 引导页在用户拒绝通知后仍调用注册；这里直接验证注册不依赖授权结果。
        service.requestRegistration(force: true)

        XCTAssertEqual(api.payloads.first?.token, "token-ok")
        XCTAssertEqual(service.record?.status, .registered)
        XCTAssertEqual(
            PushStatusPresentation.value(for: service.record, authorization: .denied),
            L10n.t("push.status.registeredWithoutPermission")
        )
        XCTAssertTrue(
            PushStatusPresentation.guidance(for: service.record, authorization: .denied)
                .contains("推送不会展示")
        )
    }

    // MARK: - 失败路径

    func testNetworkFailureKeepsPendingAndSchedulesExponentialBackoff() {
        provider.cachedToken = "token-a"
        var clock = now!
        makeService(clock: { clock })
        api.registerResults = [.failure(.network("offline"))]

        service.requestRegistration(force: false)

        XCTAssertEqual(service.record?.status, .pending)
        XCTAssertEqual(service.record?.attempts, 1)
        XCTAssertEqual(service.record?.lastError, "offline")
        XCTAssertEqual(service.record?.nextRetryAt, now.addingTimeInterval(30))
        XCTAssertEqual(service.record?.token, "token-a", "失败后仍保留待注册 token")

        // 未到期不重试。
        service.retryIfEligible(at: now)
        XCTAssertEqual(api.payloads.count, 1)

        // 到期后重试成功。
        service.retryIfEligible(at: now.addingTimeInterval(31))
        XCTAssertEqual(api.payloads.count, 2)
        XCTAssertEqual(service.record?.status, .registered)
        XCTAssertEqual(service.record?.attempts, 0)
        XCTAssertNil(service.record?.lastError)
    }

    func testServer5xxBacksOffExponentially() {
        provider.cachedToken = "token-a"
        var clock = now!
        makeService(clock: { clock })
        api.registerResults = [.failure(.server(statusCode: 503)), .failure(.server(statusCode: 500))]

        service.requestRegistration(force: false)
        XCTAssertEqual(service.record?.attempts, 1)
        XCTAssertEqual(service.record?.nextRetryAt, now.addingTimeInterval(30))

        clock = now.addingTimeInterval(31)
        service.retryIfEligible(at: clock)
        XCTAssertEqual(service.record?.attempts, 2)
        XCTAssertEqual(service.record?.nextRetryAt, now.addingTimeInterval(31 + 60))
        XCTAssertEqual(service.record?.status, .pending)
    }

    func test400IsTerminalWithReadableReasonAndNeverRetries() {
        provider.cachedToken = "token-a"
        makeService()
        api.registerResults = [.failure(.api(
            code: "PUSH_DEVICE_INVALID",
            statusCode: 400,
            message: "platform 与 token 不能为空"
        ))]

        service.requestRegistration(force: false)

        XCTAssertEqual(service.record?.status, .rejected)
        XCTAssertTrue(service.record?.lastError?.contains("PUSH_DEVICE_INVALID") == true)
        XCTAssertNil(service.record?.nextRetryAt)

        service.retryIfEligible(at: now.addingTimeInterval(10_000))
        service.appDidBecomeActive()
        XCTAssertEqual(api.payloads.count, 1, "400 是终态，不应自动重试")
    }

    func testUnauthorizedIsTerminalUntilNextSession() {
        provider.cachedToken = "token-a"
        makeService()
        api.registerResults = [.failure(.api(code: "UNAUTHORIZED", statusCode: 401, message: "token expired"))]

        service.requestRegistration(force: false)

        XCTAssertEqual(service.record?.status, .unauthorized)
        service.appDidBecomeActive()
        XCTAssertEqual(api.payloads.count, 1)
    }

    // MARK: - 注销与本地清理

    func testDeactivateRemoteThenClearLocal() {
        provider.cachedToken = "token-a"
        makeService()
        service.requestRegistration(force: false)

        var completed = false
        service.deactivate { completed = true }

        XCTAssertTrue(completed)
        XCTAssertEqual(api.deactivatedIDs, ["remote-token-a"])
        XCTAssertNil(service.record)
        XCTAssertNil(PushDeviceStore(database: testDatabase.database).load())
    }

    func testDeactivate404ClearsLocalWithoutStoppingLogout() {
        provider.cachedToken = "token-a"
        makeService()
        service.requestRegistration(force: false)
        api.deactivateResult = .success(.alreadyAbsent)

        var completed = false
        service.deactivate { completed = true }

        XCTAssertTrue(completed)
        XCTAssertNil(service.record)
    }

    func testDeactivateWithoutRemoteIDJustClearsLocal() {
        makeService()

        var completed = false
        service.deactivate { completed = true }

        XCTAssertTrue(completed)
        XCTAssertTrue(api.deactivatedIDs.isEmpty)
        XCTAssertNil(service.record)
    }

    // MARK: - 持久化与迁移

    func testRecordPersistsAcrossDatabaseReopenAndMigrationIsRepeatable() throws {
        provider.cachedToken = "token-a"
        makeService()
        service.requestRegistration(force: false)

        let reopened = try testDatabase.makeDatabaseHandle()
        let reloaded = PushDeviceStore(database: reopened).load()

        XCTAssertEqual(reloaded?.token, "token-a")
        XCTAssertEqual(reloaded?.remoteDeviceID, "remote-token-a")
        XCTAssertEqual(reloaded?.status, .registered)

        let columns = try reopened.query("PRAGMA table_info(push_devices);", [])
        XCTAssertEqual(
            Set(columns.compactMap { $0.text("name") }),
            [
                "id", "token", "remote_device_id", "platform", "status", "last_error",
                "attempts", "next_retry_at", "created_at", "updated_at"
            ]
        )
    }

    func testPendingErrorAndRetryTimePersist() throws {
        provider.cachedToken = "token-a"
        makeService()
        api.registerResults = [.failure(.network("offline"))]
        service.requestRegistration(force: false)

        let reloaded = PushDeviceStore(database: try testDatabase.makeDatabaseHandle()).load()
        XCTAssertEqual(reloaded?.status, .pending)
        XCTAssertEqual(reloaded?.lastError, "offline")
        XCTAssertEqual(reloaded?.attempts, 1)
        XCTAssertEqual(reloaded?.nextRetryAt, now.addingTimeInterval(30))
    }

    // MARK: - 通知解析与路由

    func testParsesNestedDataAndRoutesDeviceByExternalID() {
        let handler = PushMessageHandler()
        let message = handler.message(from: [
            "aps": ["alert": ["title": "设备离线"]],
            "data": [
                "alertId": "alert-1",
                "kind": "device_offline",
                "externalId": "AA:BB:CC:DD:EE:FF",
                "platform": "ios"
            ]
        ])

        XCTAssertEqual(message?.alertID, "alert-1")
        XCTAssertEqual(message?.kind, "device_offline")
        XCTAssertEqual(
            message.map(handler.destination),
            .externalDevice(platform: "ios", externalID: "AA:BB:CC:DD:EE:FF")
        )
    }

    func testRoutesLocalDeviceUUIDToDetail() {
        let handler = PushMessageHandler()
        let uuid = UUID()
        let message = handler.message(from: [
            "kind": "device",
            "deviceID": uuid.uuidString
        ])

        XCTAssertEqual(message.map(handler.destination), .deviceDetail(uuid))
    }

    func testRoutesSceneKindToScenes() {
        let handler = PushMessageHandler()
        let message = handler.message(from: [
            "data": ["alertId": "alert-2", "kind": "scene_triggered"]
        ])

        XCTAssertEqual(message.map(handler.destination), .scenes)
    }

    func testUnknownPayloadIsIgnored() {
        let handler = PushMessageHandler()
        XCTAssertNil(handler.message(from: ["aps": ["alert": ["title": "x"]]]))
    }

    func testUnresolvableDeviceFallsBackHome() {
        let handler = PushMessageHandler()
        let message = handler.message(from: ["kind": "device_offline"])
        XCTAssertNotNil(message)
        XCTAssertEqual(message.map(handler.destination), .home)
    }
}
