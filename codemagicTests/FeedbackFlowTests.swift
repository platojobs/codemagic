import XCTest
@testable import codemagic

/// 反馈发送状态机、幂等键与接口 DTO 契约。
final class FeedbackFlowTests: XCTestCase {
    private var testDatabase: TestDatabase!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
    }

    // MARK: - Coordinator

    func testSuccessfulSendOnlyMarksSentWithRemoteID() throws {
        let service = StubFeedbackService()
        service.submitResults = [.success(FeedbackReceipt(
            feedbackID: "remote-1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            replayed: false
        ))]
        var now = Date(timeIntervalSince1970: 100)
        let coordinator = FeedbackCoordinator(
            store: FeedbackStore(database: testDatabase.database),
            client: service,
            now: { now }
        )

        var outcome: Result<FeedbackDraft, FeedbackSendFailure>?
        coordinator.enqueue(category: .bug, message: "  闪退  ", contact: " a@b.com ") { outcome = $0 }

        let draft = try XCTUnwrap(coordinator.store.fetchAll().first)
        XCTAssertEqual(draft.message, "闪退")
        XCTAssertEqual(draft.contact, "a@b.com")
        XCTAssertEqual(draft.status, .sent)
        XCTAssertEqual(draft.remoteID, "remote-1")
        XCTAssertEqual(draft.attempts, 1)
        XCTAssertTrue(draft.isSent)
        XCTAssertEqual(try XCTUnwrap(outcome).successValue?.isSent, true)
        XCTAssertEqual(service.submissions.count, 1)
        XCTAssertEqual(service.submissions.first?.draft.id, draft.id, "幂等键使用草稿本地 ID")

        // 已发送的草稿再次重试不会重复提交。
        coordinator.send(id: draft.id)
        XCTAssertEqual(service.submissions.count, 1)
        XCTAssertEqual(now, Date(timeIntervalSince1970: 100))
    }

    func testRetryableFailureKeepsDraftAndBacksOff() throws {
        let service = StubFeedbackService()
        service.submitResults = [.failure(FeedbackSendFailure(
            message: "网络不可用",
            isRateLimited: false,
            retryAfter: nil,
            isRetryable: true,
            isConflict: false,
            apiCode: nil
        ))]
        var now = Date(timeIntervalSince1970: 100)
        let coordinator = FeedbackCoordinator(
            store: FeedbackStore(database: testDatabase.database),
            client: service,
            now: { now }
        )

        var outcome: Result<FeedbackDraft, FeedbackSendFailure>?
        coordinator.enqueue(category: .other, message: "离线提交", contact: "") { outcome = $0 }

        let draft = try XCTUnwrap(coordinator.store.fetchAll().first)
        XCTAssertEqual(draft.status, .failed)
        XCTAssertEqual(draft.lastError, "网络不可用")
        XCTAssertEqual(draft.failureText, "网络不可用")
        XCTAssertEqual(draft.attempts, 1)
        XCTAssertEqual(draft.nextRetryAt, now.addingTimeInterval(FeedbackRetryPolicy.baseDelay))
        XCTAssertFalse(draft.isSent)
        XCTAssertTrue(draft.canRetry)
        XCTAssertNotNil(outcome?.failureValue)

        // 未到退避时间不自动重试；手动重试复用同一个幂等键。
        now = now.addingTimeInterval(10)
        coordinator.retryEligible()
        XCTAssertEqual(service.submissions.count, 1)

        service.submitResults = [.success(FeedbackReceipt(feedbackID: "remote-2", createdAt: nil, replayed: true))]
        coordinator.send(id: draft.id)
        XCTAssertEqual(service.submissions.count, 2)
        XCTAssertEqual(service.submissions[0].draft.id, service.submissions[1].draft.id)
        XCTAssertEqual(service.submissions[1].draft.attempts, 2)
    }

    func testRateLimitSchedulesRetryAfterAndDoesNotAutoFlood() throws {
        let service = StubFeedbackService()
        service.submitResults = [.failure(FeedbackSendFailure(
            message: "反馈提交过于频繁，请稍后再试",
            isRateLimited: true,
            retryAfter: 12,
            isRetryable: true,
            isConflict: false,
            apiCode: "FEEDBACK_RATE_LIMITED"
        ))]
        var now = Date(timeIntervalSince1970: 100)
        let coordinator = FeedbackCoordinator(
            store: FeedbackStore(database: testDatabase.database),
            client: service,
            now: { now }
        )
        coordinator.enqueue(category: .bug, message: "限流", contact: "")

        let draft = try XCTUnwrap(coordinator.store.fetchAll().first)
        XCTAssertEqual(draft.status, .failed)
        XCTAssertEqual(draft.nextRetryAt, now.addingTimeInterval(12))
        XCTAssertEqual(service.submissions.count, 1)

        coordinator.retryEligible()
        XCTAssertEqual(service.submissions.count, 1, "429 到期前不得自动重试")

        now = now.addingTimeInterval(13)
        service.submitResults = [.success(FeedbackReceipt(feedbackID: "remote-3", createdAt: nil, replayed: false))]
        coordinator.retryEligible()
        XCTAssertEqual(service.submissions.count, 2, "退避到期后允许一次自动补发")
    }

    func testTerminalConflictStopsAutoRetryButKeepsDraft() throws {
        let service = StubFeedbackService()
        service.submitResults = [.failure(FeedbackSendFailure(
            message: "幂等键冲突",
            isRateLimited: false,
            retryAfter: nil,
            isRetryable: false,
            isConflict: true,
            apiCode: "IDEMPOTENCY_CONFLICT"
        ))]
        let coordinator = FeedbackCoordinator(
            store: FeedbackStore(database: testDatabase.database),
            client: service,
            now: { Date(timeIntervalSince1970: 100) }
        )
        coordinator.enqueue(category: .bug, message: "冲突", contact: "")

        let draft = try XCTUnwrap(coordinator.store.fetchAll().first)
        XCTAssertEqual(draft.status, .failed)
        XCTAssertNil(draft.nextRetryAt, "终态失败不再自动重试")
        XCTAssertEqual(try coordinator.store.count(), 1, "失败草稿永久保留")
        XCTAssertTrue(draft.canRetry, "仍可手动重试")
    }

    func testAutoRetryStopsAtBoundButKeepsDraft() throws {
        let service = StubFeedbackService()
        var now = Date(timeIntervalSince1970: 100)
        let coordinator = FeedbackCoordinator(
            store: FeedbackStore(database: testDatabase.database),
            client: service,
            now: { now }
        )
        let store = coordinator.store
        let draft = try store.insert(category: .bug, message: "持续失败", contact: "", at: now)

        for attempt in 1...(FeedbackStore.maxAutoAttempts + 2) {
            service.submitResults = [.failure(FeedbackSendFailure(
                message: "失败 \(attempt)",
                isRateLimited: false,
                retryAfter: nil,
                isRetryable: true,
                isConflict: false,
                apiCode: nil
            ))]
            coordinator.retryEligible()
            now = now.addingTimeInterval(FeedbackRetryPolicy.maxDelay + 1)
        }

        XCTAssertEqual(service.submissions.count, FeedbackStore.maxAutoAttempts,
                         "达到上限后不再自动补发")
        let stored = try XCTUnwrap(store.fetch(id: draft.id))
        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.attempts, FeedbackStore.maxAutoAttempts)
        XCTAssertNil(stored.nextRetryAt)
        XCTAssertEqual(try store.count(), 1, "失败草稿不得被静默删除")
    }

    func testRetryPolicyIsBoundedExponential() {
        XCTAssertEqual(FeedbackRetryPolicy.delay(afterAttempts: 0), 0)
        XCTAssertEqual(FeedbackRetryPolicy.delay(afterAttempts: 1), 30)
        XCTAssertEqual(FeedbackRetryPolicy.delay(afterAttempts: 2), 60)
        XCTAssertEqual(FeedbackRetryPolicy.delay(afterAttempts: 3), 120)
        XCTAssertEqual(FeedbackRetryPolicy.delay(afterAttempts: 20), FeedbackRetryPolicy.maxDelay)
    }

    // MARK: - API DTO

    func testSubmitDTOMatchesContractAndUsesIdempotencyKey() throws {
        let http = MockHTTPClient()
        http.response = HTTPResponse(
            statusCode: 201,
            headers: [:],
            data: Data(#"{"feedbackId":"fb-1","createdAt":"2026-11-06T10:00:00Z"}"#.utf8)
        )
        let client = makeClient(http: http)
        let draft = makeDraft(id: "draft-uuid")
        let context = FeedbackClientContext(
            platform: "ios",
            appVersion: "0.18.0",
            buildType: "debug",
            osVersion: "15.5",
            deviceModel: "iPhone15,3"
        )

        var receipt: FeedbackReceipt?
        client.submit(draft: draft, context: context, diagnostics: "log") { result in
            receipt = try? result.get()
        }
        waitForMainQueue()

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/api/v1/feedback")
        XCTAssertEqual(request.headers["Idempotency-Key"], "draft-uuid")
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["kind", "body", "diagnostics", "context"])
        XCTAssertEqual(json["kind"] as? String, "bug")
        XCTAssertEqual(json["body"] as? String, "描述")
        XCTAssertEqual(json["diagnostics"] as? String, "log")
        let contextJSON = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(Set(contextJSON.keys), ["platform", "appVersion", "buildType", "osVersion", "deviceModel"])
        XCTAssertEqual(contextJSON["platform"] as? String, "ios")
        XCTAssertEqual(contextJSON["appVersion"] as? String, "0.18.0")
        XCTAssertEqual(contextJSON["buildType"] as? String, "debug")
        XCTAssertEqual(contextJSON["osVersion"] as? String, "15.5")
        XCTAssertEqual(contextJSON["deviceModel"] as? String, "iPhone15,3")
        XCTAssertEqual(receipt?.feedbackID, "fb-1")
        XCTAssertEqual(receipt?.replayed, false)
    }

    func testSubmitOmitsEmptyOptionalFieldsAndDetectsReplay() throws {
        let http = MockHTTPClient()
        http.response = HTTPResponse(
            statusCode: 200,
            headers: ["Idempotent-Replayed": "true"],
            data: Data(#"{"feedbackId":"fb-1","createdAt":"2026-11-06T10:00:00Z"}"#.utf8)
        )
        let client = makeClient(http: http)
        var receipt: FeedbackReceipt?
        client.submit(draft: makeDraft(id: "draft-2"), context: makeContext(), diagnostics: nil) { result in
            receipt = try? result.get()
        }
        waitForMainQueue()

        let body = try XCTUnwrap(http.requests.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["contact"])
        XCTAssertNil(json["diagnostics"])
        XCTAssertEqual(receipt?.replayed, true)
    }

    func testSubmitMapsRateLimitWithRetryAfter() {
        let http = MockHTTPClient()
        http.response = HTTPResponse(
            statusCode: 429,
            headers: ["Retry-After": "9"],
            data: Data(#"{"error":{"code":"FEEDBACK_RATE_LIMITED","message":"too many"}}"#.utf8)
        )
        let client = makeClient(http: http)
        var failure: FeedbackSendFailure?
        client.submit(draft: makeDraft(id: "draft-3"), context: makeContext(), diagnostics: nil) { result in
            failure = try? XCTUnwrap(result.failureValue)
        }
        waitForMainQueue()

        XCTAssertEqual(failure?.isRateLimited, true)
        XCTAssertEqual(failure?.retryAfter, 9)
        XCTAssertEqual(failure?.apiCode, "FEEDBACK_RATE_LIMITED")
        XCTAssertEqual(failure?.isRetryable, true)
    }

    func testSubmitMapsIdempotencyConflict() {
        let http = MockHTTPClient()
        http.response = HTTPResponse(
            statusCode: 409,
            headers: [:],
            data: Data(#"{"error":{"code":"IDEMPOTENCY_CONFLICT","message":"conflict"}}"#.utf8)
        )
        let client = makeClient(http: http)
        var failure: FeedbackSendFailure?
        client.submit(draft: makeDraft(id: "draft-4"), context: makeContext(), diagnostics: nil) { result in
            failure = try? XCTUnwrap(result.failureValue)
        }
        waitForMainQueue()

        XCTAssertEqual(failure?.isConflict, true)
        XCTAssertEqual(failure?.isRetryable, false)
        XCTAssertEqual(failure?.apiCode, "IDEMPOTENCY_CONFLICT")
    }

    func testSubmitWithoutFeedbackIDIsFailure() {
        let http = MockHTTPClient()
        http.response = HTTPResponse(
            statusCode: 201,
            headers: [:],
            data: Data(#"{"feedbackId":"","createdAt":"2026-11-06T10:00:00Z"}"#.utf8)
        )
        let client = makeClient(http: http)
        var failure: FeedbackSendFailure?
        client.submit(draft: makeDraft(id: "draft-5"), context: makeContext(), diagnostics: nil) { result in
            failure = try? XCTUnwrap(result.failureValue)
        }
        waitForMainQueue()
        XCTAssertEqual(failure?.isRetryable, true)
    }

    func testMineDTOExcludesSensitiveFieldsAndPaginates() throws {
        let http = MockHTTPClient()
        http.response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            data: Data(#"""
            {
              "items": [{
                "feedbackId": "fb-1", "kind": "experience", "body": "有点卡",
                "platform": "ios", "appVersion": "0.18.0", "buildType": "release",
                "osVersion": "15.5", "deviceModel": "iPhone15,3",
                "status": "received", "createdAt": "2026-11-06T10:00:00Z"
              }],
              "nextCursor": "cursor-2", "hasMore": true
            }
            """#.utf8)
        )
        let client = makeClient(http: http)
        var page: FeedbackPage?
        client.fetchMine(cursor: nil, limit: 500) { result in
            page = try? result.get()
        }
        waitForMainQueue()

        let request = try XCTUnwrap(http.requests.first)
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/v1/feedback/mine")
        XCTAssertEqual(components.queryItems?.first { $0.name == "limit" }?.value, "50")
        XCTAssertNil(components.queryItems?.first { $0.name == "cursor" })

        let item = try XCTUnwrap(page?.items.first)
        XCTAssertEqual(item.feedbackID, "fb-1")
        XCTAssertEqual(item.kind, .experience)
        XCTAssertEqual(item.status, .received)
        XCTAssertNotNil(item.createdAt)
        XCTAssertEqual(page?.nextCursor, "cursor-2")
        XCTAssertEqual(page?.hasMore, true)
    }

    func testMineStatusDecodingAndCursorForwarding() {
        let http = MockHTTPClient()
        http.response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            data: Data(#"{"items":[],"nextCursor":null,"hasMore":false}"#.utf8)
        )
        let client = makeClient(http: http)
        client.fetchMine(cursor: "abc", limit: 20) { _ in }
        waitForMainQueue()

        let components = try? URLComponents(url: http.requests.first!.url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "cursor" }?.value, "abc")

        XCTAssertEqual(FeedbackRemoteStatus(rawValue: "submitted"), .submitted)
        XCTAssertEqual(FeedbackRemoteStatus(rawValue: "closed"), .closed)
        XCTAssertEqual(FeedbackRemoteStatus(rawValue: "unexpected"), .unknown("unexpected"))
    }

    // MARK: - Helpers

    private func makeClient(http: MockHTTPClient) -> FeedbackAPIClient {
        FeedbackAPIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.test")!),
            httpClient: http,
            tokenStore: FeedbackTokenStoreStub()
        )
    }

    private func makeDraft(id: String) -> FeedbackDraft {
        FeedbackDraft(
            id: id,
            category: .bug,
            message: "描述",
            contact: "",
            createdAt: Date(timeIntervalSince1970: 100),
            status: .pending,
            attempts: 0,
            lastAttemptAt: nil,
            lastError: nil,
            remoteID: nil,
            nextRetryAt: nil
        )
    }

    private func makeContext() -> FeedbackClientContext {
        FeedbackClientContext(
            platform: "ios",
            appVersion: "0.18.0",
            buildType: "debug",
            osVersion: "15.5",
            deviceModel: "iPhone15,3"
        )
    }

    private func waitForMainQueue() {
        let expectation = expectation(description: "main queue delivery")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
    }
}

// MARK: - Stubs

private final class StubFeedbackService: FeedbackServicing {
    var submissions: [(draft: FeedbackDraft, context: FeedbackClientContext, diagnostics: String?)] = []
    var submitResults: [Result<FeedbackReceipt, FeedbackSendFailure>] = []
    var fetchResults: [Result<FeedbackPage, AppError>] = []

    func submit(
        draft: FeedbackDraft,
        context: FeedbackClientContext,
        diagnostics: String?,
        completion: @escaping (Result<FeedbackReceipt, FeedbackSendFailure>) -> Void
    ) {
        submissions.append((draft, context, diagnostics))
        let result = submitResults.isEmpty
            ? .success(FeedbackReceipt(feedbackID: "default", createdAt: nil, replayed: false))
            : submitResults.removeFirst()
        completion(result)
    }

    func fetchMine(
        cursor: String?,
        limit: Int,
        completion: @escaping (Result<FeedbackPage, AppError>) -> Void
    ) {
        completion(fetchResults.isEmpty
            ? .success(FeedbackPage(items: [], nextCursor: nil, hasMore: false))
            : fetchResults.removeFirst())
    }
}

private final class MockHTTPClient: HTTPClient {
    var requests: [HTTPRequest] = []
    var response = HTTPResponse(
        statusCode: 200,
        headers: [:],
        data: Data()
    )

    func send(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, AppError>) -> Void) {
        requests.append(request)
        completion(.success(response))
    }
}

private final class FeedbackTokenStoreStub: TokenStoring {
    func load() -> AnonymousSession? {
        AnonymousSession(userID: "u1", token: "token")
    }

    func save(_ session: AnonymousSession) throws {}

    func clear() {}
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }

    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
