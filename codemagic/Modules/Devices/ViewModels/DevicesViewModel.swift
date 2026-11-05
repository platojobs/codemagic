import Foundation

/// 设备页视图模型：已保存设备与本地规则的增删改查。
///
/// 列表支持搜索（别名 / 广播名 / 型号 / 标识符）、排序（最近出现 / 名称 / 信号 / 添加时间）
/// 与分组筛选；排序方式持久化到 `SettingsStore`，默认最近出现。
final class DevicesViewModel {
    private(set) var devices: [SavedDevice] = []
    private(set) var rules: [DeviceRule] = []
    private(set) var lastError: AppError?
    private(set) var searchText: String = ""
    private(set) var groupFilter: String?
    private(set) var sort: DeviceSort

    var onChange: (() -> Void)?

    private let savedDeviceStore: SavedDeviceStore
    private let ruleStore: DeviceRuleStore
    private let recentDeviceStore: RecentDeviceStore?
    private let settingsStore: SettingsStore?
    private var recentRSSI: [UUID: Int] = [:]

    init(
        savedDeviceStore: SavedDeviceStore,
        ruleStore: DeviceRuleStore,
        recentDeviceStore: RecentDeviceStore? = nil,
        settingsStore: SettingsStore? = nil
    ) {
        self.savedDeviceStore = savedDeviceStore
        self.ruleStore = ruleStore
        self.recentDeviceStore = recentDeviceStore
        self.settingsStore = settingsStore
        self.sort = settingsStore?.deviceSort ?? .recent
    }

    func reload() {
        do {
            devices = try savedDeviceStore.fetchAll()
            rules = try ruleStore.fetchAll()
            if let recentDeviceStore {
                let recent = (try? recentDeviceStore.fetchAll(limit: 100)) ?? []
                recentRSSI = Dictionary(
                    recent.map { ($0.peripheralID, $0.rssi) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            // 分组被清空后自动回到「全部」，避免筛选结果一直为空。
            if let groupFilter, !availableGroups.contains(groupFilter) {
                self.groupFilter = nil
            }
        } catch {
            lastError = .database("读取本地设备失败：\(error)")
        }
        onChange?()
    }

    // MARK: - Filtering & Sorting

    /// 真实分组值（含「未分组」），按名称排序。
    var availableGroups: [String] {
        Array(Set(devices.map(\.groupName))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var hasActiveFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || groupFilter != nil
    }

    var filteredDevices: [SavedDevice] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = devices.filter { device in
            if let groupFilter, device.groupName != groupFilter { return false }
            guard !keyword.isEmpty else { return true }
            return [
                device.remark,
                device.advertisedName,
                device.deviceType ?? "",
                device.externalID,
                device.peripheralID.uuidString,
            ].contains { $0.lowercased().contains(keyword) }
        }
        return sorted(filtered)
    }

    /// 两种空状态：真的没有设备，与筛选后无结果。
    var emptyStateText: String {
        devices.isEmpty
            ? "还没有保存的设备，可在首页扫描后保存。"
            : "没有匹配的设备，试试修改搜索词或切换分组。"
    }

    var emptyStateSymbol: String {
        devices.isEmpty ? SymbolName.device : "line.3.horizontal.decrease.circle"
    }

    func updateSearch(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        onChange?()
    }

    func updateSort(_ newSort: DeviceSort) {
        guard newSort != sort else { return }
        sort = newSort
        settingsStore?.deviceSort = newSort
        onChange?()
    }

    func updateGroupFilter(_ group: String?) {
        guard group != groupFilter else { return }
        groupFilter = group
        onChange?()
    }

    func resetFilters() {
        guard hasActiveFilter else { return }
        searchText = ""
        groupFilter = nil
        onChange?()
    }

    // MARK: - Devices

    func device(id: UUID) -> SavedDevice? {
        devices.first { $0.id == id }
    }

    func updateDevice(
        id: UUID,
        remark: String,
        groupName: String
    ) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var device = devices[index]
        let newRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGroup = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newGroup = trimmedGroup.isEmpty ? SavedDevice.defaultGroupName : trimmedGroup
        var changed = false

        // 用户编辑只写别名 / 分组；未改动的字段保持 absent，推送时省略以免覆盖其他端。
        if newRemark != device.remark {
            device.remark = newRemark
            device.aliasPatch = newRemark.isEmpty ? .clear : .set(newRemark)
            changed = true
        }
        if newGroup != device.groupName {
            device.groupName = newGroup
            device.groupPatch = newGroup == SavedDevice.defaultGroupName ? .clear : .set(newGroup)
            changed = true
        }
        guard changed else { return }

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
        return device(id: id)?.displayName ?? "已删除设备"
    }

    // MARK: - Private

    private func sorted(_ input: [SavedDevice]) -> [SavedDevice] {
        input.sorted { lhs, rhs in
            switch sort {
            case .recent:
                let left = lhs.lastSeenAt ?? .distantPast
                let right = rhs.lastSeenAt ?? .distantPast
                if left != right { return left > right }
            case .name:
                let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if order != .orderedSame { return order == .orderedAscending }
            case .signal:
                let left = recentRSSI[lhs.peripheralID] ?? Int.min
                let right = recentRSSI[rhs.peripheralID] ?? Int.min
                if left != right { return left > right }
            case .addedAt:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

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
