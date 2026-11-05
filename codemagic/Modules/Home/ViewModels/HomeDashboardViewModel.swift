import Foundation

/// 首页视图模型：设备卡片按房间分段、今日告警摘要、快捷场景。
final class HomeDashboardViewModel {
    private(set) var devices: [SavedDevice] = []
    private(set) var rooms: [Room] = []
    private(set) var scenarios: [Scenario] = []
    private(set) var todayAlertCount: Int = 0
    private(set) var searchText: String = ""
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
    private let roomStore: RoomStore
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
        roomStore: RoomStore,
        executor: ScenarioExecutor
    ) {
        self.bluetooth = bluetooth
        self.savedDeviceStore = savedDeviceStore
        self.recentDeviceStore = recentDeviceStore
        self.settingsStore = settingsStore
        self.scanLogStore = scanLogStore
        self.readingsStore = readingsStore
        self.scenarioStore = scenarioStore
        self.roomStore = roomStore
        self.executor = executor
        self.sort = settingsStore.deviceSort
    }

    func reload() {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try savedDeviceStore.fetchAll()
            rooms = try roomStore.fetchAll()
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
        } catch {
            lastError = .database(L10n.f("home.loadFailed", String(describing: error)))
        }
        onChange?()
    }

    // MARK: - 告警摘要

    var alertSummaryText: String {
        todayAlertCount > 0 ? L10n.f("home.alertsToday", String(describing: todayAlertCount)) : L10n.t("home.alertsNoneToday")
    }

    var alertSummaryDetail: String {
        todayAlertCount > 0 ? L10n.t("home.rulesTriggered") : L10n.t("home.rulesNormal")
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

    // MARK: - 过滤与房间分段

    /// 房间分区：房间按 `sort_order` 升序，「未分配」固定最后。
    /// 搜索只匹配设备字段；有关键字时隐藏没有命中的房间，无关键字时保留空房间并展示扫描引导。
    var roomSections: [HomeRoomSection] {
        let filtered = filteredDevices
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let knownRoomIDs = Set(rooms.map(\.id))
        let grouped = Dictionary(grouping: filtered) { device -> UUID? in
            guard let roomID = device.roomID, knownRoomIDs.contains(roomID) else { return nil }
            return roomID
        }

        var sections = rooms.map { room in
            HomeRoomSection(room: room, title: room.name, devices: grouped[room.id] ?? [])
        }
        if isSearching {
            sections = sections.filter { !$0.devices.isEmpty }
        }
        let unassigned = grouped[nil] ?? []
        if !unassigned.isEmpty {
            sections.append(HomeRoomSection(room: nil, title: L10n.t("room.unassigned"), devices: unassigned))
        }
        return sections
    }

    var hasRooms: Bool { !rooms.isEmpty }

    var hasActiveFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredDevices: [SavedDevice] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = devices.filter { device in
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

    func roomName(for device: SavedDevice) -> String {
        guard let roomID = device.roomID, let room = rooms.first(where: { $0.id == roomID }) else {
            return L10n.t("room.unassigned")
        }
        return room.name
    }

    func rssi(for device: SavedDevice) -> Int? {
        recentRSSI[device.peripheralID]
    }

    /// 最近一条读数：按记录时间取所有指标里最新的一条，没有则返回 nil。
    func latestReading(for device: SavedDevice) -> DeviceReading? {
        latestReadings[device.id]
    }

    func readingText(for device: SavedDevice) -> String {
        guard let reading = latestReadings[device.id] else { return L10n.t("device.detail.noReadings") }
        return "\(reading.metric.displayName) \(reading.displayText)"
    }

    /// 真实连接状态：仅本机可连接设备才查询 CoreBluetooth。
    func isConnected(_ device: SavedDevice) -> Bool {
        device.isConnectable && bluetooth.isConnected(peripheralID: device.peripheralID)
    }

    var emptyStateText: String {
        devices.isEmpty ? AppCopy.Home.emptyMessage : AppCopy.Home.filteredMessage
    }

    var emptyActionTitle: String? {
        devices.isEmpty ? AppCopy.Home.emptyAction : AppCopy.Home.filteredAction
    }

    /// 蓝牙被拒绝或受限：首页主行动改为「去系统设置」，并说明仅本机可用的能力边界。
    var isBluetoothPermissionBlocked: Bool {
        let authorization = bluetooth.currentAuthorization()
        return authorization == .denied || authorization == .restricted
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

    func resetFilters() {
        guard hasActiveFilter else { return }
        searchText = ""
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
            lastError = .database(L10n.f("devices.saveFailed", String(describing: error)))
            onChange?()
        }
    }

    func deleteDevice(id: UUID) {
        do {
            try savedDeviceStore.softDelete(id: id)
            reload()
        } catch {
            lastError = .database(L10n.f("devices.deleteFailed", String(describing: error)))
            onChange?()
        }
    }

    // MARK: - 房间（仅本机）

    @discardableResult
    func createRoom(name: String) -> Room? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let room = try roomStore.create(name: trimmed)
            reload()
            return room
        } catch {
            lastError = .database(L10n.f("room.saveFailed", String(describing: error)))
            onChange?()
            return nil
        }
    }

    func renameRoom(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try roomStore.rename(id: id, name: trimmed)
            reload()
        } catch {
            lastError = .database(L10n.f("room.saveFailed", String(describing: error)))
            onChange?()
        }
    }

    func deleteRoom(id: UUID) {
        do {
            try roomStore.delete(id: id, deviceStore: savedDeviceStore)
            reload()
        } catch {
            lastError = .database(L10n.f("room.deleteFailed", String(describing: error)))
            onChange?()
        }
    }

    /// 移入 / 移出房间：只改本机 `room_id`，不置同步状态、不参与 push / changes。
    func moveDevice(id: UUID, to roomID: UUID?) {
        do {
            try savedDeviceStore.setRoom(id: id, roomID: roomID)
            reload()
        } catch {
            lastError = .database(L10n.f("room.moveFailed", String(describing: error)))
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

/// 首页房间分区：`room == nil` 表示「未分配」，固定排在最后。
struct HomeRoomSection: Equatable {
    let room: Room?
    let title: String
    let devices: [SavedDevice]

    var isUnassigned: Bool { room == nil }
}
