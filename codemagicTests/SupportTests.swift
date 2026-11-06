import XCTest
@testable import codemagic

/// 帮助中心目录与本地待发反馈队列。
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

    func testFeedbackRoundTripAndAttemptsStayUnsent() throws {
        let store = FeedbackStore(database: testDatabase.database)
        let draft = try store.insert(
            category: .connection,
            message: "设备一直连不上",
            contact: "user@example.com",
            at: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(try store.count(), 1)
        let fetched = try XCTUnwrap(store.fetchAll().first)
        XCTAssertEqual(fetched.id, draft.id)
        XCTAssertEqual(fetched.category, .connection)
        XCTAssertEqual(fetched.message, "设备一直连不上")
        XCTAssertEqual(fetched.contact, "user@example.com")
        XCTAssertEqual(fetched.attempts, 0)
        XCTAssertNil(fetched.lastAttemptAt)
        XCTAssertFalse(fetched.isSent, "没有发送通道，任何草稿都只能是未发送")

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

    func testVersion11MigrationIsRepeatable() throws {
        // 先退回到 v10 且没有 feedback_drafts 的状态，模拟旧库升级。
        try testDatabase.database.execute("DROP TABLE IF EXISTS feedback_drafts;")
        try testDatabase.database.execute("PRAGMA user_version = 10;")
        let path = testDatabase.directory.appendingPathComponent("test.sqlite").path
        testDatabase.database.close()

        let migrated = try SQLiteDatabase(path: path)
        XCTAssertEqual(
            try migrated.query("PRAGMA user_version;").first?.integer("user_version"),
            11
        )
        let columns = try migrated.query("PRAGMA table_info(feedback_drafts);")
        XCTAssertEqual(
            Set(columns.compactMap { $0.text("name") }),
            ["id", "category", "message", "contact", "created_at", "attempts", "last_attempt_at"]
        )
        migrated.close()

        // 再次打开不应重复报错，且已有数据保留。
        let reopened = try SQLiteDatabase(path: path)
        defer { reopened.close() }
        XCTAssertEqual(
            try reopened.query("PRAGMA user_version;").first?.integer("user_version"),
            11
        )
        let store = FeedbackStore(database: reopened)
        XCTAssertEqual(try store.count(), 0)
        try store.insert(category: .sync, message: "冲突", contact: "", at: Date())
        XCTAssertEqual(try store.count(), 1)
    }
}
