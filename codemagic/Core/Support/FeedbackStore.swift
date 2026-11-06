import Foundation

/// 反馈草稿的数据访问层。草稿失败后永久保留，只能由用户显式删除。
final class FeedbackStore {
    static let maxAutoAttempts = 5

    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    @discardableResult
    func insert(
        category: FeedbackCategory,
        message: String,
        contact: String,
        at date: Date = Date()
    ) throws -> FeedbackDraft {
        let draft = FeedbackDraft(
            id: UUID().uuidString.lowercased(),
            category: category,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            contact: contact.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: date,
            status: .pending,
            attempts: 0,
            lastAttemptAt: nil,
            lastError: nil,
            remoteID: nil,
            nextRetryAt: nil
        )
        try database.execute(
            """
            INSERT INTO feedback_drafts
            (id, category, message, contact, created_at, attempts, last_attempt_at,
             status, last_error, remote_id, next_retry_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            parameters(for: draft)
        )
        return draft
    }

    func fetchAll() throws -> [FeedbackDraft] {
        let rows = try database.query(
            "SELECT * FROM feedback_drafts ORDER BY created_at DESC;"
        )
        return rows.compactMap(Self.makeDraft)
    }

    func fetch(id: String) throws -> FeedbackDraft? {
        let rows = try database.query(
            "SELECT * FROM feedback_drafts WHERE id = ? LIMIT 1;",
            [.text(id)]
        )
        return rows.compactMap(Self.makeDraft).first
    }

    func count() throws -> Int {
        let rows = try database.query("SELECT COUNT(*) AS total FROM feedback_drafts;")
        return Int(rows.first?.integer("total") ?? 0)
    }

    /// 尚未成功发送的数量（含发送中与失败），用于「我的」角标。
    func pendingCount() throws -> Int {
        let rows = try database.query(
            "SELECT COUNT(*) AS total FROM feedback_drafts WHERE status != ?;",
            [.text(FeedbackSendStatus.sent.rawValue)]
        )
        return Int(rows.first?.integer("total") ?? 0)
    }

    /// 仅记录一次尝试，不改发送状态；用于界面手动重试的计数展示。
    @discardableResult
    func recordAttempt(id: String, at date: Date) throws -> FeedbackDraft? {
        try database.execute(
            "UPDATE feedback_drafts SET attempts = attempts + 1, last_attempt_at = ? WHERE id = ?;",
            [.double(date.timeIntervalSince1970), .text(id)]
        )
        return try fetch(id: id)
    }

    /// 进入发送中，记录一次尝试。`Idempotency-Key` 保持为草稿 ID。
    @discardableResult
    func markSending(id: String, at date: Date) throws -> FeedbackDraft? {
        try database.execute(
            """
            UPDATE feedback_drafts
            SET status = ?, attempts = attempts + 1, last_attempt_at = ?, next_retry_at = NULL
            WHERE id = ? AND status != ?;
            """,
            [
                .text(FeedbackSendStatus.sending.rawValue),
                .double(date.timeIntervalSince1970),
                .text(id),
                .text(FeedbackSendStatus.sent.rawValue),
            ]
        )
        return try fetch(id: id)
    }

    /// 只有收到 2xx 且拿到远端 ID 才落库为已发送。
    @discardableResult
    func markSent(id: String, remoteID: String, at date: Date) throws -> FeedbackDraft? {
        let trimmed = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try fetch(id: id) }
        try database.execute(
            """
            UPDATE feedback_drafts
            SET status = ?, remote_id = ?, last_error = NULL, next_retry_at = NULL
            WHERE id = ?;
            """,
            [
                .text(FeedbackSendStatus.sent.rawValue),
                .text(trimmed),
                .text(id),
            ]
        )
        return try fetch(id: id)
    }

    @discardableResult
    func markFailed(
        id: String,
        error: String,
        nextRetryAt: Date?,
        at date: Date
    ) throws -> FeedbackDraft? {
        try database.execute(
            """
            UPDATE feedback_drafts
            SET status = ?, last_error = ?, next_retry_at = ?
            WHERE id = ?;
            """,
            [
                .text(FeedbackSendStatus.failed.rawValue),
                .text(error),
                nextRetryAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(id),
            ]
        )
        return try fetch(id: id)
    }

    /// 应用被杀导致 `sending` 悬挂：下次启动回收到 `pending`，幂等键保证重放不重复。
    func recoverInterruptedSends() throws {
        try database.execute(
            "UPDATE feedback_drafts SET status = ? WHERE status = ?;",
            [
                .text(FeedbackSendStatus.pending.rawValue),
                .text(FeedbackSendStatus.sending.rawValue),
            ]
        )
    }

    /// 有界指数退避候选：到期的待发 / 失败草稿，自动尝试次数未达上限。
    /// 达到上限后不再自动重试，但草稿永久保留，仍可手动重试。
    func fetchAutoRetryCandidates(limit: Int, at date: Date) throws -> [FeedbackDraft] {
        let rows = try database.query(
            """
            SELECT * FROM feedback_drafts
            WHERE status IN (?, ?)
              AND attempts < ?
              AND (next_retry_at IS NULL OR next_retry_at <= ?)
            ORDER BY created_at ASC
            LIMIT ?;
            """,
            [
                .text(FeedbackSendStatus.pending.rawValue),
                .text(FeedbackSendStatus.failed.rawValue),
                .integer(Int64(FeedbackStore.maxAutoAttempts)),
                .double(date.timeIntervalSince1970),
                .integer(Int64(limit)),
            ]
        )
        return rows.compactMap(Self.makeDraft)
    }

    func delete(id: String) throws {
        try database.execute(
            "DELETE FROM feedback_drafts WHERE id = ?;",
            [.text(id)]
        )
    }

    // MARK: - Mapping

    private func parameters(for draft: FeedbackDraft) -> [SQLValue] {
        [
            .text(draft.id),
            .text(draft.category.rawValue),
            .text(draft.message),
            .text(draft.contact),
            .double(draft.createdAt.timeIntervalSince1970),
            .integer(Int64(draft.attempts)),
            draft.lastAttemptAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .text(draft.status.rawValue),
            draft.lastError.map(SQLValue.text) ?? .null,
            draft.remoteID.map(SQLValue.text) ?? .null,
            draft.nextRetryAt.map { .double($0.timeIntervalSince1970) } ?? .null,
        ]
    }

    private static func makeDraft(from row: SQLRow) -> FeedbackDraft? {
        guard let id = row.text("id") else { return nil }
        let createdAt = Date(timeIntervalSince1970: row.double("created_at") ?? 0)
        let lastAttemptAt = row.double("last_attempt_at").map { Date(timeIntervalSince1970: $0) }
        let nextRetryAt = row.double("next_retry_at").map { Date(timeIntervalSince1970: $0) }
        return FeedbackDraft(
            id: id,
            category: FeedbackCategory(storedValue: row.text("category")),
            message: row.text("message") ?? "",
            contact: row.text("contact") ?? "",
            createdAt: createdAt,
            status: FeedbackSendStatus(storedValue: row.text("status")),
            attempts: Int(row.integer("attempts") ?? 0),
            lastAttemptAt: lastAttemptAt,
            lastError: row.text("last_error"),
            remoteID: row.text("remote_id"),
            nextRetryAt: nextRetryAt
        )
    }
}
