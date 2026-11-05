import Foundation

/// 首页视图模型：设备卡片网格（按分组分段）、今日告警摘要、快捷场景。
final class HomeDashboardViewModel {
    private(set) var devices: [SavedDevice] = []
    private(set) var scenarios: [Scenario] = []
    private(set) var todayAlertCount: Int = 0
    private(set) var searchText: String = ""
    private(set) var groupFilter: String?
    private(set) var sort: DeviceSort
    private(set) var lastError: AppError?
    private(set) var isLoading = false

    var onChange: (() -> Void)?

    private let bluetooth: BluetoothServicing
    private let savedDeviceStore: SavedDeviceStore
    private let recentDeviceStore: RecentDeviceStore
    private let settingsStore: SettingsStore
    private let scanLogStore: ScanLogStore
    private let readingsStore: ReadingsStore
    private let scenarioStore: ScenarioStore
    private let executor: ScenarioExecutor
    private var recentRSSI: [UUID: Int] = [:]
    private var latestReadings: [UUID: DeviceReading] = [:]

    init(
        bluetooth: BluetoothServicing,
        savedDeviceStore: SavedDeviceStore,
        recentDeviceStore: RecentDeviceStore,
        settingsStore: SettingsStore,
        scanLogStore: ScanLogStore,
        readingsStore: ReadingsStore,
        scenarioStore: ScenarioStore,
        executor: ScenarioExecutor
    ) {
        self.bluetooth = bluetooth
        self.savedDeviceStore = savedDeviceStore
        self.recentDeviceStore = recentDeviceStore
        self.settingsStore = settingsStore
        self.scanLogStore = scanLogStore
        self.readingsStore = readingsStore
        self.scenarioStore = scenarioStore
        self.executor = executor
        self.sort = settingsStore.deviceSort
    }

    func reload() {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try savedDeviceStore.fetchAll()
            scenarios = try scenarioStore.fetchAll()
            let recent = (try? recentDeviceStore.fetchAll(limit: 100)) ?? []
            recentRSSI = Dictionary(
                recent.map { ($0.peripheralID, $0.rssi) },
                uniquingKeysWith: { first, _ in first }
            )
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: Date())
            todayAlertCount = (try? scanLogStore.countRuleAlerts(since: startOfDay)) ?? 0
            latestReadings = [:]
            for device in devices {
                latestReadings[device.id] = latestReading(deviceID: device.id)
            }
            if let groupFilter, !availableGroups.contains(groupFilter) {
                self.groupFilter = nil
            }
        } catch {
            lastError = .database("读取本地数据失败：\(error)")
        }
        onChange?()
    }

    // MARK: - 告警摘要

    var alertSummaryText: String {
        todayAlertCount > 0 ? "今日 \(todayAlertCount) 条告警" : "今日无告警"
    }

    var alertSummaryDetail: String {
        todayAlertCount > 0 ? "规则已触发，点击查看智能页" : "所有规则运行正常"
    }

    var alertSummaryKind: StatusChipView.Kind {
        todayAlertCount > 0 ? .warning : .success
    }

    // MARK: - 场景

    /// 首页只展示前 3 个场景，完整的增删改在「智能」页。
    var quickScenarios: [Scenario] {
        Array(scenarios.prefix(3))
    }

    func runScenario(_ scenario: Scenario, completion: @escaping (ScenarioRunResult) -> Void) {
        executor.execute(scenario) { result in
            completion(result)
        }
    }

    // MARK: - 过滤与分组

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

    /// 按分组分段，段内保持当前排序。
    var groupedDevices: [(group: String, devices: [SavedDevice])] {
        let filtered = filteredDevices
        let groups = Dictionary(grouping: filtered, by: \.groupName)
        return groups.keys.sorted { lhs, rhs in
            if lhs == SavedDevice.defaultGroupName { return false }
            if rhs == SavedDevice.defaultGroupName { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }.map { ($0, groups[$0] ?? []) }
    }

    func rssi(for device: SavedDevice) -> Int? {
        recentRSSI[device.peripheralID]
    }

    /// 最近一条读数：按记录时间取所有指标里最新的一条，没有则返回 nil。
    func latestReading(for device: SavedDevice) -> DeviceReading? {
        latestReadings[device.id]
    }

    func readingText(for device: SavedDevice) -> String {
        guard let reading = latestReadings[device.id] else { return "暂无读数" }
        return "\(reading.metric.displayName) \(reading.displayText)"
    }

    /// 真实连接状态：仅本机可连接设备才查询 CoreBluetooth。
    func isConnected(_ device: SavedDevice) -> Bool {
        device.isConnectable && bluetooth.isConnected(peripheralID: device.peripheralID)
    }

    var emptyStateText: String {
        devices.isEmpty
            ? "还没有设备。点击右上角扫描，把身边的设备添加进来。"
            : "没有匹配的设备，试试修改搜索词或切换分组。"
    }

    var emptyActionTitle: String? {
        devices.isEmpty ? "扫描附近设备" : "清除筛选"
    }

    // MARK: - Mutations

    func updateSearch(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        onChange?()
    }

    func updateSort(_ newSort: DeviceSort) {
        guard newSort != sort else { return }
        sort = newSort
        settingsStore.deviceSort = newSort
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

    func device(id: UUID) -> SavedDevice? {
        devices.first { $0.id == id }
    }

    func updateDevice(id: UUID, remark: String, groupName: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var device = devices[index]
        let newRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGroup = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newGroup = trimmedGroup.isEmpty ? SavedDevice.defaultGroupName : trimmedGroup
        var changed = false
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
        do {
            try savedDeviceStore.upsert(device)
            reload()
        } catch {
            lastError = .database("保存设备失败：\(error)")
            onChange?()
        }
    }

    func deleteDevice(id: UUID) {
        do {
            try savedDeviceStore.softDelete(id: id)
            reload()
        } catch {
            lastError = .database("删除设备失败：\(error)")
            onChange?()
        }
    }

    // MARK: - Private

    private func latestReading(deviceID: UUID) -> DeviceReading? {
        var newest: DeviceReading?
        for metric in ReadingMetric.whitelist {
            guard let reading = try? readingsStore.fetchRecent(deviceID: deviceID, metric: metric, limit: 1).first
            else { continue }
            if newest == nil || reading.recordedAt > newest!.recordedAt {
                newest = reading
            }
        }
        return newest
    }

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
}
