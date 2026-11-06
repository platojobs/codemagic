import Foundation

/// 智能页视图模型：自动化规则（增删启停 + 最近触发）、本机手动场景与服务端场景。
final class SmartViewModel {
    private(set) var rules: [DeviceRule] = []
    private(set) var scenarios: [Scenario] = []
    private(set) var scenes: [Scene] = []
    private(set) var recentTriggers: [ScanLogEntry] = []
    private(set) var savedDevices: [SavedDevice] = []
    private(set) var lastError: AppError?

    var onChange: (() -> Void)?

    private let ruleStore: DeviceRuleStore
    private let savedDeviceStore: SavedDeviceStore
    private let scanLogStore: ScanLogStore
    private let scenarioStore: ScenarioStore
    private let sceneStore: SceneStore
    private let sceneScheduler: SceneScheduler?
    private let executor: ScenarioExecutor
    private let requestSync: () -> Void

    init(
        ruleStore: DeviceRuleStore,
        savedDeviceStore: SavedDeviceStore,
        scanLogStore: ScanLogStore,
        scenarioStore: ScenarioStore,
        sceneStore: SceneStore,
        sceneScheduler: SceneScheduler? = nil,
        executor: ScenarioExecutor,
        requestSync: @escaping () -> Void = {}
    ) {
        self.ruleStore = ruleStore
        self.savedDeviceStore = savedDeviceStore
        self.scanLogStore = scanLogStore
        self.scenarioStore = scenarioStore
        self.sceneStore = sceneStore
        self.sceneScheduler = sceneScheduler
        self.executor = executor
        self.requestSync = requestSync
    }

    func reload() {
        do {
            savedDevices = try savedDeviceStore.fetchAll()
            rules = try ruleStore.fetchAll()
            scenarios = try scenarioStore.fetchAll()
            scenes = try sceneStore.fetchAll()
            recentTriggers = try scanLogStore.fetchRecent(limit: 40)
                .filter { $0.category == .rule && $0.level == .warning }
                .prefix(5)
                .map { $0 }
            lastError = nil
        } catch {
            lastError = .database(L10n.f("smart.loadFailed", String(describing: error)))
        }
        onChange?()
    }

    // MARK: - 自动化

    func deviceName(for rule: DeviceRule) -> String {
        guard let id = rule.deviceID else { return L10n.t("smart.allDevices") }
        return savedDevices.first { $0.id == id }?.displayName ?? L10n.t("common.deviceDeleted")
    }

    func triggerText(for entry: ScanLogEntry) -> String {
        Self.relativeFormatter.localizedString(for: entry.occurredAt, relativeTo: Date())
    }

    var deviceOptionsForRule: [(id: UUID?, name: String)] {
        [(nil, L10n.t("smart.allDevices"))] + savedDevices.map { ($0.id, $0.displayName) }
    }

    func addRule(_ rule: DeviceRule) {
        do {
            try ruleStore.upsert(rule)
            reload()
        } catch {
            lastError = .database(L10n.f("devices.saveRuleFailed", String(describing: error)))
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
            lastError = .database(L10n.f("smart.updateRuleFailed", String(describing: error)))
            onChange?()
        }
    }

    func deleteRule(id: UUID) {
        do {
            try ruleStore.softDelete(id: id)
            reload()
        } catch {
            lastError = .database(L10n.f("devices.deleteRuleFailed", String(describing: error)))
            onChange?()
        }
    }

    // MARK: - 服务端场景

    func scene(id: UUID) -> Scene? {
        scenes.first { $0.id == id }
    }

    /// 场景引用的设备是否仍在本地（服务端 `deviceMissing` 只作展示补充）。
    func isDeviceMissing(_ scene: Scene) -> Bool {
        guard let reference = scene.trigger.device else { return false }
        return savedDevices.first {
            $0.platform.caseInsensitiveCompare(reference.platform) == .orderedSame
                && $0.externalID.caseInsensitiveCompare(reference.externalID) == .orderedSame
                && $0.deletedAt == nil
        } == nil
    }

    func sceneDeviceName(_ scene: Scene) -> String? {
        guard let reference = scene.trigger.device else { return nil }
        return savedDevices.first {
            $0.platform.caseInsensitiveCompare(reference.platform) == .orderedSame
                && $0.externalID.caseInsensitiveCompare(reference.externalID) == .orderedSame
        }?.displayName
    }

    func nextFireText(for scene: Scene) -> String? {
        guard let scheduler = sceneScheduler,
              case .schedule = scene.trigger,
              let date = scheduler.nextFire(for: scene) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        if case .schedule(_, let timezone, _) = scene.trigger,
           let zone = TimeZone(identifier: timezone) {
            formatter.timeZone = zone
        }
        return formatter.string(from: date)
    }

    /// 新场景插入；已有场景只推进实际编辑过的字段。
    func saveScene(_ scene: Scene, editedFields: Set<SceneFieldKey>) {
        do {
            if let existing = try sceneStore.fetch(id: scene.id) {
                var updated = scene
                updated.remoteID = existing.remoteID
                updated.syncState = existing.syncState
                updated.lastSyncedAt = existing.lastSyncedAt
                updated.fieldUpdatedAt = existing.fieldUpdatedAt
                try sceneStore.save(updated, editedFields: editedFields, now: Date())
            } else {
                try sceneStore.insert(scene, now: Date())
            }
            reload()
            requestSync()
        } catch {
            lastError = .database(L10n.f("smart.saveSceneFailed", String(describing: error)))
            onChange?()
        }
    }

    func toggleScene(id: UUID) {
        guard var scene = try? sceneStore.fetch(id: id) else { return }
        scene.enabled.toggle()
        saveScene(scene, editedFields: [.enabled])
    }

    func deleteScene(id: UUID) {
        do {
            try sceneStore.delete(id: id, now: Date())
            reload()
            requestSync()
        } catch {
            lastError = .database(L10n.f("smart.deleteSceneFailed", String(describing: error)))
            onChange?()
        }
    }

    // MARK: - 本机手动场景

    func scenario(id: UUID) -> Scenario? {
        scenarios.first { $0.id == id }
    }

    func saveScenario(_ scenario: Scenario) {
        do {
            try scenarioStore.upsert(scenario)
            reload()
        } catch {
            lastError = .database(L10n.f("smart.saveScenarioFailed", String(describing: error)))
            onChange?()
        }
    }

    func deleteScenario(id: UUID) {
        do {
            try scenarioStore.delete(id: id)
            reload()
        } catch {
            lastError = .database(L10n.f("smart.deleteScenarioFailed", String(describing: error)))
            onChange?()
        }
    }

    func actionDescription(_ action: ScenarioAction) -> String {
        action.detail { id in
            savedDevices.first { $0.id == id }?.displayName ?? L10n.t("common.deviceDeleted")
        }
    }

    func runScenario(_ scenario: Scenario, completion: @escaping (ScenarioRunResult) -> Void) {
        executor.execute(scenario, completion: completion)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.current
        formatter.unitsStyle = .short
        return formatter
    }()
}
