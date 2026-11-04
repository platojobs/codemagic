import Foundation

/// 统一错误类型。`code` 与 `docs/consistency.md` 中的错误码表一致，Android 端同名同码。
enum AppError: Error, Equatable {
    /// 请求失败：无网络、超时、连接被拒等。
    case network(String)
    /// 服务端返回非 2xx。
    case server(statusCode: Int)
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
        case .decoding: return "NET-003"
        case .configuration: return "NET-004"
        case .database: return "DB-001"
        case .bluetooth: return "BT-004"
        }
    }

    var message: String {
        switch self {
        case .network:
            return "网络请求失败，请检查网络或本地服务是否启动"
        case .server(let statusCode):
            return "服务端返回异常状态（HTTP \(statusCode)）"
        case .decoding:
            return "响应数据结构与约定不符"
        case .configuration:
            return "BASE_URL 未配置或格式非法"
        case .database:
            return "本地数据读写失败"
        case .bluetooth(let detail):
            return detail
        }
    }

    var localizedDescriptionText: String {
        "\(code) \(message)"
    }
}
