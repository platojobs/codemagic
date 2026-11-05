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
        case .connectDevice: return "连接设备"
        case .disconnectDevice: return "断开设备"
        case .startBackgroundCollection: return "开始后台采集"
        case .stopBackgroundCollection: return "停止后台采集"
        case .muteAlerts: return "静音告警"
        case .syncNow: return "立即同步"
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
        case .connectDevice(let id): return "连接「\(deviceName(id))」"
        case .disconnectDevice(let id): return "断开「\(deviceName(id))」"
        case .startBackgroundCollection: return "开启后台采集"
        case .stopBackgroundCollection: return "关闭后台采集并断开连接"
        case .muteAlerts(let minutes): return "静音 \(minutes) 分钟"
        case .syncNow: return "立即同步一次"
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
        if actionResults.isEmpty { return "场景没有动作" }
        if isFullySuccessful { return "已完成 \(succeededCount) 个动作" }
        return "\(succeededCount) 个成功，\(failedCount) 个失败"
    }

    var failureText: String {
        actionResults.filter { !$0.succeeded }
            .map { "\($0.action.title)：\($0.message)" }
            .joined(separator: "；")
    }
}
