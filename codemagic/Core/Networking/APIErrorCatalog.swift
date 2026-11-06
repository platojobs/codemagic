import Foundation

/// 服务端错误码 → 客户端处理方式与展示文案的**唯一映射表**。
///
/// 新增后端错误码时只改这里，`AppError` 与同步流程都从同一张表读取，
/// 避免 503 `TIMEOUT` 被误当成 410、或 401 只显示原始 message。
enum APIErrorCatalog {
    /// 客户端应如何处理该错误。
    enum Handling: Equatable {
        /// 410：游标已失效，清空游标并以 0 全量重拉；不进指数退避。
        case resyncRequired
        /// 401：token 失效，必须由用户确认重新登录，不静默建号。
        case reloginRequired
        /// 503 / 429 / 网络类：服务端繁忙，稍后按指数退避重试。
        case retryWithBackoff
        /// 请求本身有问题（400 / 404 / 409 等），重试无意义。
        case terminal
    }

    struct Entry: Equatable {
        let handling: Handling
        let message: String
    }

    static let entries: [String: Entry] = [
        "RESYNC_REQUIRED": Entry(handling: .resyncRequired, message: L10n.t("error.resyncRequired")),
        "TIMEOUT": Entry(handling: .retryWithBackoff, message: L10n.t("error.timeout")),
        "UNAUTHORIZED": Entry(handling: .reloginRequired, message: L10n.t("error.unauthorized")),
        "IDEMPOTENCY_CONFLICT": Entry(handling: .terminal, message: L10n.t("error.idempotencyConflict")),
        "FEEDBACK_RATE_LIMITED": Entry(handling: .retryWithBackoff, message: L10n.t("error.feedbackRateLimited")),
        "RATE_LIMITED": Entry(handling: .retryWithBackoff, message: L10n.t("error.rateLimited")),
        "UNAVAILABLE": Entry(handling: .retryWithBackoff, message: L10n.t("error.serviceUnavailable")),
        "INTERNAL": Entry(handling: .retryWithBackoff, message: L10n.t("error.serverError")),
        "BAD_REQUEST": Entry(handling: .terminal, message: L10n.t("error.badRequest")),
        "INVALID_MAC": Entry(handling: .terminal, message: L10n.t("error.invalidAddress")),
        "INVALID_JSON": Entry(handling: .terminal, message: L10n.t("error.invalidJSON")),
        "NOT_FOUND": Entry(handling: .terminal, message: L10n.t("error.notFound")),
        "METHOD_NOT_ALLOWED": Entry(handling: .terminal, message: L10n.t("error.methodNotAllowed")),
        "CONFLICT": Entry(handling: .terminal, message: L10n.t("error.conflict")),
        "PAYLOAD_TOO_LARGE": Entry(handling: .terminal, message: L10n.t("error.payloadTooLarge")),
        "NOT_IMPLEMENTED": Entry(handling: .terminal, message: L10n.t("error.notImplemented")),
        // 客户端内部状态：收到 304 却没有本地缓存，属于异常而非服务端错误。
        "CATALOG_CACHE_MISSING": Entry(handling: .terminal, message: L10n.t("catalog.cacheMissing")),
        // 账号删除（v0.20.0，契约 0.15.0）：阻塞需先处理家庭，令牌问题需重新申请。
        "ACCOUNT_DELETION_BLOCKED": Entry(handling: .terminal, message: L10n.t("account.delete.blocked")),
        "DELETION_TOKEN_REQUIRED": Entry(handling: .terminal, message: L10n.t("account.delete.tokenInvalid")),
        "DELETION_TOKEN_INVALID": Entry(handling: .terminal, message: L10n.t("account.delete.tokenInvalid")),
        "DELETION_TOKEN_EXPIRED": Entry(handling: .terminal, message: L10n.t("account.delete.tokenExpired")),
        // 异步导出：未就绪可重试；下载令牌无效 / 过期需重新获取链接。
        "EXPORT_NOT_READY": Entry(handling: .retryWithBackoff, message: L10n.t("account.export.notReady")),
        "EXPORT_DOWNLOAD_INVALID": Entry(handling: .terminal, message: L10n.t("account.export.downloadInvalid")),
        "EXPORT_DOWNLOAD_EXPIRED": Entry(handling: .terminal, message: L10n.t("account.export.downloadExpired")),
    ]

    static func entry(for code: String) -> Entry {
        entries[code] ?? Entry(handling: .terminal, message: L10n.t("error.serverGeneric"))
    }
}

/// 服务端分页上限。客户端在发请求前自行收敛，避免越界被 400。
enum APILimits {
    static let readings = 500
    static let export = 5000
    static let changes = 500
    static let feedback = 50

    static func clamp(_ value: Int, to upperBound: Int) -> Int {
        min(max(value, 1), upperBound)
    }
}
