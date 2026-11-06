import Foundation
import UIKit

/// 反馈类型，`rawValue` 与服务端 `kind` 枚举一致。
/// 旧版本本地草稿使用 `connection` / `sync`，读取时按 `other` 兼容，不再作为可选项展示。
enum FeedbackCategory: String, CaseIterable, Equatable {
    case bug
    case feature
    case experience
    case other

    var title: String {
        switch self {
        case .bug: return L10n.t("feedback.category.bug")
        case .feature: return L10n.t("feedback.category.feature")
        case .experience: return L10n.t("feedback.category.experience")
        case .other: return L10n.t("feedback.category.other")
        }
    }

    init(storedValue: String?) {
        switch storedValue {
        case FeedbackCategory.bug.rawValue: self = .bug
        case FeedbackCategory.feature.rawValue: self = .feature
        case FeedbackCategory.experience.rawValue: self = .experience
        default: self = .other
        }
    }
}

/// 草稿发送状态。只有 `sent` 且拿到远端 `feedbackId` 才算发送成功。
enum FeedbackSendStatus: String, CaseIterable, Equatable {
    case pending
    case sending
    case sent
    case failed

    init(storedValue: String?) {
        switch storedValue {
        case FeedbackSendStatus.sending.rawValue: self = .sending
        case FeedbackSendStatus.sent.rawValue: self = .sent
        case FeedbackSendStatus.failed.rawValue: self = .failed
        default: self = .pending
        }
    }
}

/// 本地反馈草稿。`id` 同时作为 `Idempotency-Key`，断网重放不会在服务端产生重复记录。
struct FeedbackDraft: Identifiable, Equatable {
    let id: String
    let category: FeedbackCategory
    let message: String
    let contact: String
    let createdAt: Date
    var status: FeedbackSendStatus
    var attempts: Int
    var lastAttemptAt: Date?
    var lastError: String?
    var remoteID: String?
    var nextRetryAt: Date?

    /// 成功判定必须同时满足：服务端终态成功 + 拿到远端 ID。
    var isSent: Bool {
        status == .sent && !(remoteID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRetry: Bool {
        !isSent && status != .sending
    }

    var statusText: String {
        switch status {
        case .sent:
            return L10n.t("feedback.state.sent")
        case .sending:
            return L10n.t("feedback.state.sending")
        case .pending:
            guard attempts > 0 else { return L10n.t("feedback.state.pending") }
            return L10n.f("feedback.state.pendingRetry", String(attempts))
        case .failed:
            guard attempts > 0 else { return L10n.t("feedback.state.failed") }
            return L10n.f("feedback.state.failedRetry", String(attempts))
        }
    }

    /// 失败原因直接展示服务端可读文案；没有原因时返回 nil，不编造。
    var failureText: String? {
        guard status == .failed else { return nil }
        let error = lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return error.isEmpty ? nil : error
    }
}

/// 提交反馈时自动填充的客户端上下文，字段名与服务端契约一致。
struct FeedbackClientContext: Equatable {
    let platform: String
    let appVersion: String
    let buildType: String
    let osVersion: String
    let deviceModel: String

    static func current() -> FeedbackClientContext {
        FeedbackClientContext(
            platform: "ios",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            buildType: FeedbackBuildType.current,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: DeviceModelIdentifier.current
        )
    }
}

enum FeedbackBuildType {
    /// 由编译条件判定，不读取配置或硬编码版本。
    static var current: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }
}

/// 机型标识（如 `iPhone15,3`），从 `hw.machine` 读取，不使用营销名称。
enum DeviceModelIdentifier {
    static var current: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { buffer in
                String(cString: buffer)
            }
        }
        return machine.isEmpty ? "unknown" : machine
    }
}
