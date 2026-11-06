import Foundation

/// 意见反馈本地待发队列。
///
/// 当前没有反馈接收接口，`recordAttempt` 只增加真实重试次数并把条目标记为仍未发送，
/// 不返回成功、不伪造网络结果。删除是物理删除，因为草稿不参与云端同步。
final class FeedbackStore {
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
            message: message,
            contact: contact,
            createdAt: date,
            attempts: 0,
            lastAttemptAt: nil
        )
        try database.execute(
            """
            INSERT INTO feedback_drafts
            (id, category, message, contact, created_at, attempts, last_attempt_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(draft.id),
                .text(draft.category.rawValue),
                .text(draft.message),
                .text(draft.contact),
                .double(draft.createdAt.timeIntervalSince1970),
                .integer(Int64(draft.attempts)),
                .null,
            ]
        )
        return draft
    }

    func fetchAll() throws -> [FeedbackDraft] {
        let rows = try database.query(
            "SELECT * FROM feedback_drafts ORDER BY created_at DESC;"
        )
        return rows.compactMap(Self.makeDraft)
    }

    func count() throws -> Int {
        let rows = try database.query("SELECT COUNT(*) AS total FROM feedback_drafts;")
        return Int(rows.first?.integer("total") ?? 0)
    }

    /// 重试只记录本次尝试；没有发送通道，条目保持未发送。
    @discardableResult
    func recordAttempt(id: String, at date: Date = Date()) throws -> FeedbackDraft? {
        try database.execute(
            """
            UPDATE feedback_drafts
            SET attempts = attempts + 1, last_attempt_at = ?
            WHERE id = ?;
            """,
            [.double(date.timeIntervalSince1970), .text(id)]
        )
        return try fetch(id: id)
    }

    func delete(id: String) throws {
        try database.execute("DELETE FROM feedback_drafts WHERE id = ?;", [.text(id)])
    }

    private func fetch(id: String) throws -> FeedbackDraft? {
        let rows = try database.query(
            "SELECT * FROM feedback_drafts WHERE id = ? LIMIT 1;",
            [.text(id)]
        )
        return rows.compactMap(Self.makeDraft).first
    }

    private static func makeDraft(from row: SQLRow) -> FeedbackDraft? {
        guard let id = row.text("id") else { return nil }
        let createdAt = row.double("created_at").map(Date.init(timeIntervalSince1970:)) ?? Date(timeIntervalSince1970: 0)
        return FeedbackDraft(
            id: id,
            category: FeedbackCategory(storedValue: row.text("category") ?? ""),
            message: row.text("message") ?? "",
            contact: row.text("contact") ?? "",
            createdAt: createdAt,
            attempts: Int(row.integer("attempts") ?? 0),
            lastAttemptAt: row.double("last_attempt_at").map(Date.init(timeIntervalSince1970:))
        )
    }
}
