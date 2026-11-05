import Foundation

/// 场景动作：只允许真实可执行的操作，不产生「仅记录」的假动作。
enum ScenarioAction: Equatable, Hashable {
    case connectDevice(UUID)
    case disconnectDevice(UUID)
    case startBackgroundCollection
    case stopBackgroundCollection
    case muteAlerts(minutes: Int)
    case syncNow

    static let muteOptions = [10, 30, 60]

    var title: String {
        switch self {
        case .connectDevice: return L10n.t("scenario.action.connect")
        case .disconnectDevice: return L10n.t("scenario.action.disconnect")
        case .startBackgroundCollection: return L10n.t("scenario.action.startBackground")
        case .stopBackgroundCollection: return L10n.t("scenario.action.stopBackground")
        case .muteAlerts: return L10n.t("scenario.action.muteAlerts")
        case .syncNow: return L10n.t("scenario.action.syncNow")
        }
    }

    var symbolName: String {
        switch self {
        case .connectDevice: return "link"
        case .disconnectDevice: return "link.badge.minus"
        case .startBackgroundCollection: return "arrow.triangle.2.circlepath"
        case .stopBackgroundCollection: return "pause.circle"
        case .muteAlerts: return "bell.slash"
        case .syncNow: return "arrow.clockwise"
        }
    }

    func detail(deviceName: (UUID) -> String) -> String {
        switch self {
        case .connectDevice(let id): return L10n.f("scenario.action.connectDevice", String(describing: deviceName(id)))
        case .disconnectDevice(let id): return L10n.f("scenario.action.disconnectDevice", String(describing: deviceName(id)))
        case .startBackgroundCollection: return L10n.t("scenario.action.startBackgroundDetail")
        case .stopBackgroundCollection: return L10n.t("scenario.action.stopBackgroundDetail")
        case .muteAlerts(let minutes): return L10n.f("scenario.action.muteMinutes", String(describing: minutes))
        case .syncNow: return L10n.t("scenario.action.syncOnce")
        }
    }
}

/// 场景：本机动作组合，仅存储在本机，不参与云端同步。
struct Scenario: Identifiable, Equatable {
    let id: UUID
    var name: String
    var actions: [ScenarioAction]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        actions: [ScenarioAction],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.actions = actions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var summary: String {
        actions.map(\.title).joined(separator: " → ")
    }
}

/// 单个动作的执行结果。
struct ScenarioActionResult: Equatable {
    let action: ScenarioAction
    let succeeded: Bool
    let message: String
}

/// 一次场景执行汇总：任一失败不阻断后续动作，最终统一提示。
struct ScenarioRunResult: Equatable {
    let scenarioID: UUID
    let scenarioName: String
    let actionResults: [ScenarioActionResult]

    var succeededCount: Int { actionResults.filter(\.succeeded).count }
    var failedCount: Int { actionResults.count - succeededCount }
    var isFullySuccessful: Bool { failedCount == 0 }

    var summaryText: String {
        if actionResults.isEmpty { return L10n.t("scenario.summary.empty") }
        if isFullySuccessful { return L10n.f("scenario.summary.completed", String(describing: succeededCount)) }
        return L10n.f("scenario.summary.partial", String(describing: succeededCount), String(describing: failedCount))
    }

    var failureText: String {
        actionResults.filter { !$0.succeeded }
            .map { L10n.f("scenario.result.line", $0.action.title, $0.message) }
            .joined(separator: L10n.t("common.semicolonSeparator"))
    }
}
