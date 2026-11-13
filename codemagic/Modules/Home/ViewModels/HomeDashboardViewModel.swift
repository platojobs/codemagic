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
    private(set) var lastNotice: String?
    private(set) var isLoading = false
    private(set) var households: [Household] = []
    private(set) var currentHousehold: Household?

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
    private let householdService: HouseholdService?
    private let cloudReadings: CloudLatestReadingsProviding?
    private let now: () -> Date
    private var recentRSSI: [UUID: Int] = [:]
    private var latestReadings: [UUID: DeviceReading] = [:]
    private var cloudStates: [UUID: CloudLatestReadingState] = [:]

    init(
        bluetooth: BluetoothServicing,
        savedDeviceStore: SavedDeviceStore,
        recentDeviceStore: RecentDeviceStore,
        settingsStore: SettingsStore,
        scanLogStore: ScanLogStore,
        readingsStore: ReadingsStore,
        scenarioStore: ScenarioStore,
        roomStore: RoomStore,
        executor: ScenarioExecutor,
        householdService: HouseholdService? = nil,
        cloudReadings: CloudLatestReadingsProviding? = nil,
        now: @escaping () -> Date = Date.init
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
        self.householdService = householdService
        self.cloudReadings = cloudReadings
        self.now = now
        self.sort = settingsStore.deviceSort
    }

    func reload() {
        isLoading = true
        defer { isLoading = false }
        do {
            let current = householdService?.currentHousehold()
            currentHousehold = current
            households = householdService?.households() ?? []
            let all = try savedDeviceStore.fetchAll()
            devices = all.filter { isVisible($0, in: current) }
            if let householdService {
                rooms = householdService.visibleRooms()
            } else {
                rooms = try roomStore.fetchAll()
            }
            scenarios = try scenarioStore.fetchAll()
            let recent = (try? recentDeviceStore.fetchAll(limit: 100)) ?? []
            // 非负 RSSI 是占位 / 非法读数，统一按未知处理，不参与展示与排序。
            recentRSSI = Dictionary(
                recent.compactMap { device -> (UUID, Int)? in
                    RSISignalView.isValid(device.rssi) ? (device.peripheralID, device.rssi) : nil
                },
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
        requestCloudReadings()
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

    // MARK: - 家庭

    /// 多于一个家庭时才显示切换控件；单家庭保持首页简洁。
    var showsHouseholdSwitcher: Bool { households.count > 1 }

    func switchHousehold(localID: UUID, completion: @escaping () -> Void) {
        householdService?.switchHousehold(localID: localID)
        reload()
        completion()
    }

    /// 设备卡片是否「未同步」：从未接入家庭，或本机仍有待上报修改。
    func isUnsynced(_ device: SavedDevice) -> Bool {
        device.householdID == nil || device.syncState != .synced
    }

    private func isVisible(_ device: SavedDevice, in current: Household?) -> Bool {
        guard householdService != nil, let current else { return true }
        guard let householdID = device.householdID else {
            // 老数据 / 离线新增：个人家庭下展示并标注未同步，其他家庭不混入。
            return current.isPersonal
        }
        return householdID == current.id
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
        if let reading = latestReadings[device.id] {
            // 数值与单位用不换行空格绑定：AX 字号下不能把「72」和「bpm」拆到两行。
            let value = reading.displayText.replacingOccurrences(of: " ", with: "\u{00A0}")
            return "\(reading.metric.displayName) \(value)"
        }
        switch cloudStates[device.id] {
        case .available(let cloud)?:
            let value = cloud.displayText.replacingOccurrences(of: " ", with: "\u{00A0}")
            return "\(cloud.metricTitle) \(value)"
        case .failed?:
            // 云端查询失败不等于设备没有读数，也不据此判定设备离线。
            return L10n.t("home.reading.unavailable")
        default:
            return L10n.t("device.detail.noReadings")
        }
    }

    /// 云端最近上报时间；仅在本机没有读数时用于卡片时间行。
    func cloudReportedAt(for device: SavedDevice) -> Date? {
        guard latestReadings[device.id] == nil, case .available(let cloud)? = cloudStates[device.id]
        else { return nil }
        return cloud.reportedAt
    }

    /// 真实连接状态：仅本机可连接设备才查询 CoreBluetooth。
    func isConnected(_ device: SavedDevice) -> Bool {
        DeviceLinkStatus.isConnected(device, bluetooth: bluetooth)
    }

    /// 服务端上报状态：按 `lastSeenAt` 与 900 秒窗口推导；`unknown` 不等同于离线。
    func presence(for device: SavedDevice) -> DevicePresence {
        device.presence(at: now())
    }

    /// 与房间详情共用的四档联动状态：本机 BLE 连接优先，其次服务端上报状态。
    func linkStatus(for device: SavedDevice) -> DeviceLinkStatus {
        DeviceLinkStatus(isConnected: isConnected(device), presence: presence(for: device))
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

    // MARK: - 房间 / 设备归属

    /// 房间增删改统一走 `HouseholdService`：联网写服务端，离线落本机并标注未同步。
    func createRoom(name: String, completion: (() -> Void)? = nil) {
        guard let householdService else {
            _ = try? roomStore.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            reload()
            completion?()
            return
        }
        householdService.createRoom(name: name) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let mutation):
                if !mutation.synced {
                    self.lastNotice = L10n.t("household.assignment.pending")
                }
                self.lastError = nil
            case .failure(let error):
                self.lastError = .api(
                    code: "HOUSEHOLD",
                    statusCode: 400,
                    message: error.userMessage
                )
            }
            self.reload()
            completion?()
        }
    }

    func renameRoom(id: UUID, name: String) {
        guard let householdService else {
            try? roomStore.rename(id: id, name: name)
            reload()
            return
        }
        householdService.renameRoom(id: id, name: name) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.lastError = .api(code: "HOUSEHOLD", statusCode: 400, message: error.userMessage)
            }
            self.reload()
        }
    }

    func deleteRoom(id: UUID) {
        guard let householdService else {
            try? roomStore.delete(id: id, deviceStore: savedDeviceStore)
            reload()
            return
        }
        householdService.deleteRoom(id: id) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.lastError = .api(code: "HOUSEHOLD", statusCode: 400, message: error.userMessage)
            }
            self.reload()
        }
    }

    /// 移入 / 移出房间：先落本机，再由 `HouseholdService` 用 PATCH 上报；
    /// 归属不走 push，可重试失败保留 pending，下次同步自动补报。
    func moveDevice(id: UUID, to roomID: UUID?) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        let targetRoom = roomID.flatMap { target in rooms.first(where: { $0.id == target }) }
        guard let householdService else {
            do {
                try savedDeviceStore.setRoom(id: id, roomID: roomID)
                reload()
            } catch {
                lastError = .database(L10n.f("room.moveFailed", String(describing: error)))
                onChange?()
            }
            return
        }
        householdService.assignDevice(device, room: targetRoom) { [weak self] result in
            guard let self else { return }
            if let message = result.errorMessage {
                self.lastNotice = message
            }
            self.reload()
        }
        reload()
    }

    // MARK: - Private

    /// 本机没有读数的设备补查云端最近读数；失败只记录状态，不当作离线。
    ///
    /// `presence = unknown` 表示服务端从未接受过该设备读数，再查 `metrics + limit=1`
    /// 只是白跑两次往返；本机已有读数时界面本机优先，同样跳过。
    private func requestCloudReadings() {
        guard let cloudReadings else { return }
        for device in devices {
            guard presence(for: device) != .unknown else { continue }
            guard latestReadings[device.id] == nil else { continue }
            cloudReadings.latestReading(platform: device.platform, externalID: device.externalID) { [weak self] state in
                guard let self, self.cloudStates[device.id] != state else { return }
                self.cloudStates[device.id] = state
                self.onChange?()
            }
        }
    }

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
