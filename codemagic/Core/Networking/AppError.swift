import Foundation

/// 统一错误类型。`code` 与 `docs/consistency.md` 中的错误码表一致，Android 端同名同码。
enum AppError: Error, Equatable {
    /// 请求失败：无网络、超时、连接被拒等。
    case network(String)
    /// 服务端返回非 2xx。
    case server(statusCode: Int)
    /// 服务端返回了结构化错误体 `{"error":{"code","message"}}`。
    case api(code: String, statusCode: Int, message: String)
    /// 同步流程本身的前置条件不满足（如上一次同步尚未结束）。
    case sync(String)
    /// 响应无法解析为约定结构。
    case decoding(String)
    /// BASE_URL 缺失或非法。
    case configuration(String)
    /// 本地数据库打开/写入失败。
    case database(String)
    /// 蓝牙前置条件不满足（不支持 / 未授权 / 已关闭 / 连接失败）。
    case bluetooth(String)

    var code: String {
        switch self {
        case .network: return "NET-001"
        case .server: return "NET-002"
        case .api: return "NET-002"
        case .decoding: return "NET-003"
        case .configuration: return "NET-004"
        case .database: return "DB-001"
        case .bluetooth: return "BT-004"
        case .sync: return "SYNC-001"
        }
    }

    var message: String {
        switch self {
        case .network:
            return L10n.t("error.network")
        case .server(let statusCode):
            return Self.serverMessage(statusCode: statusCode)
        case .api(let code, let statusCode, _):
            let entry = APIErrorCatalog.entry(for: code)
            return L10n.f("error.httpDetail", entry.message, String(statusCode), code)
        case .sync(let detail):
            return detail
        case .decoding:
            return L10n.t("error.decoding")
        case .configuration:
            return L10n.t("error.config")
        case .database:
            return L10n.t("error.database")
        case .bluetooth(let detail):
            return detail
        }
    }

    var localizedDescriptionText: String {
        "\(code) \(message)"
    }

    /// 服务端结构化错误码；非 `.api` 为 nil。
    var apiCode: String? {
        if case .api(let code, _, _) = self { return code }
        return nil
    }

    /// 410 `RESYNC_REQUIRED`：游标早于最老保留行，必须全量重同步。
    /// 无结构化错误体的 410 也按同一语义处理（不静默当成空页）。
    var isResyncRequired: Bool {
        switch self {
        case .api(let code, _, _):
            return code == "RESYNC_REQUIRED" || code == "GONE"
        case .server(let statusCode):
            return statusCode == 410
        default:
            return false
        }
    }

    /// `TIMEOUT`（HTTP 503）或裸 503：服务端繁忙，走退避，绝不能按 410 处理。
    var isServerBusy: Bool {
        switch self {
        case .api(let code, let statusCode, _):
            return code == "TIMEOUT" || code == "UNAVAILABLE" || statusCode == 503
        case .server(let statusCode):
            return statusCode == 503
        default:
            return false
        }
    }

    /// 匿名 token 失效（HTTP 401）。此时必须由用户确认重新登录，不得静默新建匿名账号。
    var isUnauthorized: Bool {
        switch self {
        case .api(_, statusCode: 401, _), .server(statusCode: 401):
            return true
        default:
            return false
        }
    }

    /// 是否值得自动重试（网络抖动、5xx、限流）。410 属终态分支，不在此列。
    var isRetryable: Bool {
        switch self {
        case .network:
            return true
        case .server(let statusCode):
            return statusCode >= 500 && statusCode != 501
        case .api(let code, let statusCode, _):
            if statusCode == 410 { return false }
            return APIErrorCatalog.entry(for: code).handling == .retryWithBackoff
        default:
            return false
        }
    }

    private static func serverMessage(statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return L10n.t("error.unauthorized")
        case 410:
            return L10n.t("error.resyncRequired")
        case 503:
            return L10n.t("error.timeout")
        default:
            return L10n.f("error.httpStatus", String(describing: statusCode))
        }
    }
}
