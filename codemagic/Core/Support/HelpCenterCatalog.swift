import Foundation

/// 帮助中心主题。文案与真实行为保持一致，不写「请联系客服」这类无落点的承诺。
enum HelpTopic: Equatable {
    case all
    case pairing
    case connection
    case readings
    case sync
    case household

    var title: String {
        switch self {
        case .all: return L10n.t("help.title")
        case .pairing: return L10n.t("help.topic.pairing")
        case .connection: return L10n.t("help.topic.connection")
        case .readings: return L10n.t("help.topic.readings")
        case .sync: return L10n.t("help.topic.sync")
        case .household: return L10n.t("help.topic.household")
        }
    }
}

/// 一条 FAQ：问题与答案文案都在 Localizable.strings 中维护，便于中英对齐。
struct HelpCenterEntry: Equatable {
    let id: String
    let topic: HelpTopic
    let questionKey: String
    let answerKey: String
}

enum HelpCenterCatalog {
    static let entries: [HelpCenterEntry] = [
        HelpCenterEntry(
            id: "pairing",
            topic: .pairing,
            questionKey: "help.question.pairing",
            answerKey: "help.answer.pairing"
        ),
        HelpCenterEntry(
            id: "connection",
            topic: .connection,
            questionKey: "help.question.connection",
            answerKey: "help.answer.connection"
        ),
        HelpCenterEntry(
            id: "readings",
            topic: .readings,
            questionKey: "help.question.readings",
            answerKey: "help.answer.readings"
        ),
        HelpCenterEntry(
            id: "sync",
            topic: .sync,
            questionKey: "help.question.sync",
            answerKey: "help.answer.sync"
        ),
        HelpCenterEntry(
            id: "household",
            topic: .household,
            questionKey: "help.question.household",
            answerKey: "help.answer.household"
        ),
    ]

    static func entries(for topic: HelpTopic) -> [HelpCenterEntry] {
        guard topic != .all else { return entries }
        return entries.filter { $0.topic == topic }
    }
}
