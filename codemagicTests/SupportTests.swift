import XCTest
@testable import codemagic

/// 帮助中心目录与本地反馈队列。
final class SupportTests: XCTestCase {
    private var testDatabase: TestDatabase!

    override func setUpWithError() throws {
        testDatabase = try TestDatabase()
    }

    override func tearDownWithError() throws {
        testDatabase?.cleanUp()
    }

    // MARK: - Help Center

    func testHelpEntriesCoverAllRequiredTopics() {
        XCTAssertEqual(HelpCenterCatalog.entries.count, 5)
        XCTAssertEqual(
            Set(HelpCenterCatalog.entries.map(\.topic)),
            [.pairing, .connection, .readings, .sync, .household]
        )
        XCTAssertEqual(HelpCenterCatalog.entries(for: .all), HelpCenterCatalog.entries)
        XCTAssertEqual(HelpCenterCatalog.entries(for: .pairing).map(\.id), ["pairing"])
    }

    func testHelpCopyResolvesToNonEmptyLocalizedText() {
        for entry in HelpCenterCatalog.entries {
            XCTAssertFalse(L10n.t(entry.questionKey).isEmpty, "缺少问题文案：\(entry.questionKey)")
            XCTAssertFalse(L10n.t(entry.answerKey).isEmpty, "缺少答案文案：\(entry.answerKey)")
            XCTAssertNotEqual(
                L10n.t(entry.questionKey),
                entry.questionKey,
                "问题文案未命中本地化表：\(entry.questionKey)"
            )
            XCTAssertNotEqual(
                L10n.t(entry.answerKey),
                entry.answerKey,
                "答案文案未命中本地化表：\(entry.answerKey)"
            )
        }
    }

    // MARK: - Feedback Queue

    func testFeedbackRoundTripStartsPendingAndCanRetry() throws {
        let store = FeedbackStore(database: testDatabase.database)
        let draft = try store.insert(
            category: .feature,
            message: "希望支持更多设备类型",
            contact: "user@example.com",
            at: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(try store.count(), 1)
        let fetched = try XCTUnwrap(store.fetchAll().first)
        XCTAssertEqual(fetched.id, draft.id)
        XCTAssertEqual(fetched.category, .feature)
        XCTAssertEqual(fetched.message, "希望支持更多设备类型")
        XCTAssertEqual(fetched.contact, "user@example.com")
        XCTAssertEqual(fetched.status, .pending)
        XCTAssertEqual(fetched.attempts, 0)
        XCTAssertNil(fetched.remoteID)
        XCTAssertFalse(fetched.isSent)
        XCTAssertTrue(fetched.canRetry)
        XCTAssertEqual(try store.pendingCount(), 1)

        let retried = try XCTUnwrap(store.recordAttempt(id: draft.id, at: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(retried.attempts, 1)
        XCTAssertEqual(retried.lastAttemptAt, Date(timeIntervalSince1970: 200))
        XCTAssertFalse(retried.isSent, "重试不伪造发送成功")

        try store.delete(id: draft.id)
        XCTAssertEqual(try store.count(), 0)
    }

    func testFeedbackOrderedByCreatedAtDescending() throws {
        let store = FeedbackStore(database: testDatabase.database)
        try store.insert(category: .other, message: "旧", contact: "", at: Date(timeIntervalSince1970: 100))
        try store.insert(category: .bug, message: "新", contact: "", at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(try store.fetchAll().map(\.message), ["新", "旧"])
    }

    func testFeedbackStatusTransitionsOnlySentWithRemoteID() throws {
        let store = FeedbackStore(database: testDatabase.database)
        let draft = try store.insert(category: .bug, message: "崩溃", contact: "", at: Date(timeIntervalSince1970: 100))

        let sending = try XCTUnwrap(store.markSending(id: draft.id, at: Date(timeIntervalSince1970: 110)))
        XCTAssertEqual(sending.status, .sending)
        XCTAssertEqual(sending.attempts, 1)

        let sent = try XCTUnwrap(store.markSent(
            id: draft.id,
            remoteID: "f4d0c7ba-0000-4000-8000-000000000001",
            at: Date(timeIntervalSince1970: 120)
        ))
        XCTAssertTrue(sent.isSent)
        XCTAssertEqual(sent.status, .sent)
        XCTAssertEqual(sent.remoteID, "f4d0c7ba-0000-4000-8000-000000000001")
        XCTAssertFalse(sent.canRetry)
        XCTAssertEqual(try store.pendingCount(), 0)

        let emptyRemote = try XCTUnwrap(store.markSent(id: draft.id, remoteID: "  ", at: Date()))
        XCTAssertTrue(emptyRemote.isSent, "已成功过的记录不应被空 ID 回退")
    }

    func testFeedbackFailureKeepsDraftAndRecordsReadableError() throws {
        let store = FeedbackStore(database: testDatabase.database)
        let draft = try store.insert(category: .experience, message: "闪退", contact: "", at: Date())
        _ = try store.markSending(id: draft.id, at: Date())

        let failed = try XCTUnwrap(store.markFailed(
            id: draft.id,
            error: "反馈提交过于频繁，请稍后再试",
            nextRetryAt: Date(timeIntervalSince1970: 500),
            at: Date(timeIntervalSince1970: 200)
        ))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastError, "反馈提交过于频繁，请稍后再试")
        XCTAssertEqual(failed.failureText, "反馈提交过于频繁，请稍后再试")
        XCTAssertEqual(failed.nextRetryAt, Date(timeIntervalSince1970: 500))
        XCTAssertFalse(failed.isSent)
        XCTAssertTrue(failed.canRetry)
        XCTAssertEqual(try store.count(), 1, "失败草稿必须保留")
    }

    func testRecoverInterruptedSending() throws {
        let store = FeedbackStore(database: testDatabase.database)
        let draft = try store.insert(category: .bug, message: "卡住", contact: "", at: Date())
        _ = try store.markSending(id: draft.id, at: Date())

        try store.recoverInterruptedSends()
        let recovered = try XCTUnwrap(store.fetch(id: draft.id))
        XCTAssertEqual(recovered.status, .pending)
        XCTAssertEqual(recovered.attempts, 1, "中断不吞掉已发生的尝试次数")
    }

    // MARK: - Migration

    func testVersion12MigrationKeepsExistingDrafts() throws {
        let database = testDatabase.database
        try database.execute("DROP TABLE IF EXISTS feedback_drafts;")
        try database.execute(
            """
            CREATE TABLE feedback_drafts (
                id TEXT PRIMARY KEY, category TEXT, message TEXT, contact TEXT,
                created_at REAL, attempts INTEGER, last_attempt_at REAL
            );
            """
        )
        try database.execute(
            """
            INSERT INTO feedback_drafts (id, category, message, contact, created_at, attempts, last_attempt_at)
            VALUES ('legacy-id', 'connection', '旧数据', '', 100, 3, NULL);
            """
        )
        try database.execute("PRAGMA user_version = 11;")
        let path = testDatabase.directory.appendingPathComponent("test.sqlite").path
        database.close()

        let migrated = try SQLiteDatabase(path: path)
        let columns = Set(try migrated.query("PRAGMA table_info(feedback_drafts);").compactMap { $0.text("name") })
        XCTAssertEqual(
            columns,
            [
                "id", "category", "message", "contact", "created_at", "attempts", "last_attempt_at",
                "status", "last_error", "remote_id", "next_retry_at",
            ]
        )
        XCTAssertEqual(
            try migrated.query("PRAGMA user_version;").first?.integer("user_version"),
             17
        )
        let store = FeedbackStore(database: migrated)
        let legacy = try XCTUnwrap(store.fetch(id: "legacy-id"))
        XCTAssertEqual(legacy.message, "旧数据", "旧数据必须保留")
        XCTAssertEqual(legacy.attempts, 3)
        XCTAssertEqual(legacy.status, .pending, "旧行默认待发送")
        XCTAssertEqual(legacy.category, .other, "旧连接类目兼容为其他")
        migrated.close()

        // 再次打开迁移可重复执行，不重复报错。
        let reopened = try SQLiteDatabase(path: path)
        defer { reopened.close() }
        XCTAssertEqual(
            try reopened.query("PRAGMA user_version;").first?.integer("user_version"),
            17
        )
        XCTAssertEqual(try FeedbackStore(database: reopened).count(), 1)
    }
}
