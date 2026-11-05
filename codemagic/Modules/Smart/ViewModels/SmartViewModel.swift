import Foundation

/// 智能页视图模型：自动化规则（增删启停 + 最近触发）与场景（本机动作组合）。
final class SmartViewModel {
    private(set) var rules: [DeviceRule] = []
    private(set) var scenarios: [Scenario] = []
    private(set) var recentTriggers: [ScanLogEntry] = []
    private(set) var savedDevices: [SavedDevice] = []
    private(set) var lastError: AppError?

    var onChange: (() -> Void)?

    private let ruleStore: DeviceRuleStore
    private let savedDeviceStore: SavedDeviceStore
    private let scanLogStore: ScanLogStore
    private let scenarioStore: ScenarioStore
    private let executor: ScenarioExecutor

    init(
        ruleStore: DeviceRuleStore,
        savedDeviceStore: SavedDeviceStore,
        scanLogStore: ScanLogStore,
        scenarioStore: ScenarioStore,
        executor: ScenarioExecutor
    ) {
        self.ruleStore = ruleStore
        self.savedDeviceStore = savedDeviceStore
        self.scanLogStore = scanLogStore
        self.scenarioStore = scenarioStore
        self.executor = executor
    }

    func reload() {
        do {
            savedDevices = try savedDeviceStore.fetchAll()
            rules = try ruleStore.fetchAll()
            scenarios = try scenarioStore.fetchAll()
            recentTriggers = try scanLogStore.fetchRecent(limit: 40)
                .filter { $0.category == .rule && $0.level == .warning }
                .prefix(5)
                .map { $0 }
            lastError = nil
        } catch {
            lastError = .database("读取智能页数据失败：\(error)")
        }
        onChange?()
    }

    // MARK: - 自动化

    func deviceName(for rule: DeviceRule) -> String {
        guard let id = rule.deviceID else { return "全部设备" }
        return savedDevices.first { $0.id == id }?.displayName ?? "已删除的设备"
    }

    func triggerText(for entry: ScanLogEntry) -> String {
        Self.relativeFormatter.localizedString(for: entry.occurredAt, relativeTo: Date())
    }

    var deviceOptionsForRule: [(id: UUID?, name: String)] {
        [(nil, "全部设备")] + savedDevices.map { ($0.id, $0.displayName) }
    }

    func addRule(_ rule: DeviceRule) {
        do {
            try ruleStore.upsert(rule)
            reload()
        } catch {
            lastError = .database("保存规则失败：\(error)")
            onChange?()
        }
    }

    func toggleRule(id: UUID) {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.isEnabled.toggle()
        rule.updatedAt = Date()
        rule.syncState = .pending
        do {
            try ruleStore.upsert(rule)
            reload()
        } catch {
            lastError = .database("更新规则失败：\(error)")
            onChange?()
        }
    }

    func deleteRule(id: UUID) {
        do {
            try ruleStore.softDelete(id: id)
            reload()
        } catch {
            lastError = .database("删除规则失败：\(error)")
            onChange?()
        }
    }

    // MARK: - 场景

    func scenario(id: UUID) -> Scenario? {
        scenarios.first { $0.id == id }
    }

    func saveScenario(_ scenario: Scenario) {
        do {
            try scenarioStore.upsert(scenario)
            reload()
        } catch {
            lastError = .database("保存场景失败：\(error)")
            onChange?()
        }
    }

    func deleteScenario(id: UUID) {
        do {
            try scenarioStore.delete(id: id)
            reload()
        } catch {
            lastError = .database("删除场景失败：\(error)")
            onChange?()
        }
    }

    func actionDescription(_ action: ScenarioAction) -> String {
        action.detail { id in
            savedDevices.first { $0.id == id }?.displayName ?? "已删除的设备"
        }
    }

    func runScenario(_ scenario: Scenario, completion: @escaping (ScenarioRunResult) -> Void) {
        executor.execute(scenario, completion: completion)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()
}
