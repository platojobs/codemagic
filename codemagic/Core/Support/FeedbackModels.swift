import Foundation

/// 反馈类型。与服务端接口无关，仅用于本地待发队列分类。
enum FeedbackCategory: String, CaseIterable, Equatable {
    case bug
    case connection
    case sync
    case other

    var title: String {
        switch self {
        case .bug: return L10n.t("feedback.category.bug")
        case .connection: return L10n.t("feedback.category.connection")
        case .sync: return L10n.t("feedback.category.sync")
        case .other: return L10n.t("feedback.category.other")
        }
    }

    init(storedValue: String) {
        self = FeedbackCategory(rawValue: storedValue) ?? .other
    }
}

/// 一条保存在本机、尚未发送的意见反馈。
///
/// 当前没有反馈接收接口，因此 `isSent` 恒为 false；UI 必须如实展示「未发送」。
struct FeedbackDraft: Identifiable, Equatable {
    let id: String
    let category: FeedbackCategory
    let message: String
    let contact: String
    let createdAt: Date
    let attempts: Int
    let lastAttemptAt: Date?

    /// 没有发送通道，任何草稿都不可能是「已发送」。
    var isSent: Bool { false }

    var statusText: String {
        L10n.t("feedback.state.unsent")
    }
}
