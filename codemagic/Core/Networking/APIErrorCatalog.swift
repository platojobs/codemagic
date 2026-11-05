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
        "RESYNC_REQUIRED": Entry(handling: .resyncRequired, message: "云端变更记录已过期，需要全量重新同步"),
        "TIMEOUT": Entry(handling: .retryWithBackoff, message: "服务端繁忙，稍后重试"),
        "UNAUTHORIZED": Entry(handling: .reloginRequired, message: "登录已失效，请在「我的」页重新登录"),
        "IDEMPOTENCY_CONFLICT": Entry(handling: .terminal, message: "同步请求与已有幂等键冲突，请稍后重试"),
        "RATE_LIMITED": Entry(handling: .retryWithBackoff, message: "请求过于频繁，稍后重试"),
        "UNAVAILABLE": Entry(handling: .retryWithBackoff, message: "服务暂时不可用，稍后重试"),
        "INTERNAL": Entry(handling: .retryWithBackoff, message: "服务端内部错误，稍后重试"),
        "BAD_REQUEST": Entry(handling: .terminal, message: "请求参数不符合约定"),
        "INVALID_MAC": Entry(handling: .terminal, message: "设备地址格式不合法"),
        "INVALID_JSON": Entry(handling: .terminal, message: "请求 JSON 不合法"),
        "NOT_FOUND": Entry(handling: .terminal, message: "资源不存在或无权访问"),
        "METHOD_NOT_ALLOWED": Entry(handling: .terminal, message: "接口不支持该请求方法"),
        "CONFLICT": Entry(handling: .terminal, message: "数据版本冲突"),
        "PAYLOAD_TOO_LARGE": Entry(handling: .terminal, message: "请求体超过服务端上限"),
        "NOT_IMPLEMENTED": Entry(handling: .terminal, message: "服务端未实现该能力"),
    ]

    static func entry(for code: String) -> Entry {
        entries[code] ?? Entry(handling: .terminal, message: "服务端返回错误")
    }
}

/// 服务端分页上限。客户端在发请求前自行收敛，避免越界被 400。
enum APILimits {
    static let readings = 500
    static let export = 5000
    static let changes = 500

    static func clamp(_ value: Int, to upperBound: Int) -> Int {
        min(max(value, 1), upperBound)
    }
}
