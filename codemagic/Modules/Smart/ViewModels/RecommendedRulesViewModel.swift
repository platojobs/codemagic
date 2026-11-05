import Foundation

/// 推荐规则页视图模型：选设备 → 读取该设备真实指标 → 生成模板 → 一键写入本地规则。
final class RecommendedRulesViewModel {
    private(set) var devices: [SavedDevice] = []
    private(set) var selectedDeviceID: UUID?
    private(set) var templates: [RuleTemplate] = []
    private(set) var lastError: AppError?

    var onChange: (() -> Void)?

    private let readingsStore: ReadingsStore
    private let savedDeviceStore: SavedDeviceStore
    private let ruleStore: DeviceRuleStore

    init(readingsStore: ReadingsStore, savedDeviceStore: SavedDeviceStore, ruleStore: DeviceRuleStore) {
        self.readingsStore = readingsStore
        self.savedDeviceStore = savedDeviceStore
        self.ruleStore = ruleStore
    }

    var selectedDevice: SavedDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    var hasDevices: Bool { !devices.isEmpty }

    /// 空态文案：没有设备与「有设备但没读数」分开表达。
    var emptyMessage: String {
        hasDevices ? L10n.t("smart.recommended.empty") : L10n.t("smart.recommended.noDevicesMessage")
    }

    var emptyTitle: String {
        hasDevices ? L10n.t("smart.recommended.emptyTitle") : L10n.t("smart.recommended.noDevices")
    }

    var showsEmptyState: Bool { !hasDevices || templates.isEmpty }

    func reload() {
        do {
            devices = try savedDeviceStore.fetchAll()
            if let selectedDeviceID, devices.contains(where: { $0.id == selectedDeviceID }) {
                // 保持当前选择
            } else {
                selectedDeviceID = devices.first?.id
            }
            refreshTemplates()
            lastError = nil
        } catch {
            devices = []
            templates = []
            lastError = .database(L10n.f("smart.recommended.loadFailed", String(describing: error)))
        }
        onChange?()
    }

    func selectDevice(_ id: UUID?) {
        selectedDeviceID = id
        refreshTemplates()
        onChange?()
    }

    /// 一键添加：立即写入本地规则库；失败时保留错误供界面提示。
    @discardableResult
    func addTemplate(_ template: RuleTemplate) -> DeviceRule? {
        guard let selectedDeviceID else { return nil }
        let rule = template.makeRule(deviceID: selectedDeviceID)
        do {
            try ruleStore.upsert(rule)
            lastError = nil
            return rule
        } catch {
            lastError = .database(L10n.f("devices.saveRuleFailed", String(describing: error)))
            onChange?()
            return nil
        }
    }

    private func refreshTemplates() {
        guard let selectedDeviceID else {
            templates = []
            return
        }
        do {
            templates = RuleTemplateCatalog.templates(for: try readingsStore.availableMetrics(deviceID: selectedDeviceID))
        } catch {
            templates = []
            lastError = .database(L10n.f("smart.recommended.loadFailed", String(describing: error)))
        }
    }
}
