import Foundation

/// 设备页视图模型：已保存设备与本地规则的增删改查。
final class DevicesViewModel {
    private(set) var devices: [SavedDevice] = []
    private(set) var rules: [DeviceRule] = []
    private(set) var lastError: AppError?

    var onChange: (() -> Void)?

    private let savedDeviceStore: SavedDeviceStore
    private let ruleStore: DeviceRuleStore

    init(savedDeviceStore: SavedDeviceStore, ruleStore: DeviceRuleStore) {
        self.savedDeviceStore = savedDeviceStore
        self.ruleStore = ruleStore
    }

    func reload() {
        do {
            devices = try savedDeviceStore.fetchAll()
            rules = try ruleStore.fetchAll()
        } catch {
            lastError = .database("读取本地设备失败：\(error)")
        }
        onChange?()
    }

    // MARK: - Devices

    func updateDevice(
        id: UUID,
        remark: String,
        groupName: String
    ) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var device = devices[index]
        device.remark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        device.groupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SavedDevice.defaultGroupName
            : groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        device.updatedAt = Date()
        device.syncState = .pending
        devices[index] = device
        persist(device)
    }

    func deleteDevice(id: UUID) {
        do {
            try savedDeviceStore.softDelete(id: id)
            // 目标为该设备的规则同步删除，避免留下悬空规则。
            for rule in rules where rule.deviceID == id {
                try ruleStore.softDelete(id: rule.id)
            }
            reload()
        } catch {
            lastError = .database("删除设备失败：\(error)")
            onChange?()
        }
    }

    // MARK: - Rules

    func toggleRule(id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        var rule = rules[index]
        rule.isEnabled.toggle()
        rule.updatedAt = Date()
        rule.syncState = .pending
        rules[index] = rule
        persist(rule)
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

    func saveRule(_ rule: DeviceRule) {
        persist(rule)
    }

    var ruleDeviceOptions: [(id: UUID?, name: String)] {
        [(nil, "全部已保存设备")] + devices.map { ($0.id, $0.displayName) }
    }

    func deviceName(for id: UUID?) -> String {
        guard let id else { return "全部已保存设备" }
        return devices.first(where: { $0.id == id })?.displayName ?? "已删除设备"
    }

    // MARK: - Private

    private func persist(_ device: SavedDevice) {
        do {
            try savedDeviceStore.upsert(device)
            reload()
        } catch {
            lastError = .database("保存设备失败：\(error)")
            onChange?()
        }
    }

    private func persist(_ rule: DeviceRule) {
        do {
            try ruleStore.upsert(rule)
            reload()
        } catch {
            lastError = .database("保存规则失败：\(error)")
            onChange?()
        }
    }
}
