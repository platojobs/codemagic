import Foundation

/// 首页设备行，既可以是本次扫描结果，也可以是本地最近设备。
struct HomeDeviceRow: Equatable {
    let peripheralID: UUID
    let name: String
    let rssi: Int?
    let lastSeenAt: Date
    let isSaved: Bool
}

/// 首页视图模型：驱动 CoreBluetooth 扫描、最近设备列表与规则提示。
final class HomeViewModel {
    enum ScanStatus: Equatable {
        case idle
        case scanning
        case unavailable(BluetoothState)
        case failed(String)
    }

    // MARK: - Observable State

    private(set) var status: ScanStatus = .idle {
        didSet { if oldValue != status { onChange?() } }
    }
    private(set) var rows: [HomeDeviceRow] = [] {
        didSet { if oldValue != rows { onChange?() } }
    }
    private(set) var lastRuleEvent: RuleTriggerEvent? {
        didSet { onChange?() }
    }
    private(set) var lastError: AppError?

    var onChange: (() -> Void)?

    // MARK: - Dependencies

    private let bluetooth: BluetoothServicing
    private let savedDeviceStore: SavedDeviceStore
    private let recentDeviceStore: RecentDeviceStore
    private let scanLogStore: ScanLogStore
    private let ruleStore: DeviceRuleStore
    private let settingsStore: SettingsStore
    private let ruleEvaluator: RuleEvaluator
    private let ruleAlertCoordinator: RuleAlertCoordinator?
    /// 超过该时长未再次出现的设备视为已离开扫描范围，用于触发「断开」规则。
    private let staleInterval: TimeInterval

    private var savedDevices: [SavedDevice] = []
    private var rules: [DeviceRule] = []
    private var liveDevices: [UUID: ScannedDevice] = [:]
    private var recentDevices: [RecentDevice] = []
    private var isActive = false
    private var isScanRequested = false

    // MARK: - Init

    init(
        bluetooth: BluetoothServicing,
        savedDeviceStore: SavedDeviceStore,
        recentDeviceStore: RecentDeviceStore,
        scanLogStore: ScanLogStore,
        ruleStore: DeviceRuleStore,
        settingsStore: SettingsStore,
        ruleEvaluator: RuleEvaluator,
        ruleAlertCoordinator: RuleAlertCoordinator? = nil,
        staleInterval: TimeInterval = 10
    ) {
        self.bluetooth = bluetooth
        self.savedDeviceStore = savedDeviceStore
        self.recentDeviceStore = recentDeviceStore
        self.scanLogStore = scanLogStore
        self.ruleStore = ruleStore
        self.settingsStore = settingsStore
        self.ruleEvaluator = ruleEvaluator
        self.ruleAlertCoordinator = ruleAlertCoordinator
        self.staleInterval = staleInterval
    }

    // MARK: - Lifecycle

    /// 首页可见时绑定蓝牙回调并刷新本地数据。
    func activate() {
        guard !isActive else { return }
        isActive = true

        bluetooth.stateChangeHandler = { [weak self] state in
            self?.handleBluetoothState(state)
        }
        bluetooth.discoveryHandler = { [weak self] device in
            self?.handleDiscovery(device)
        }

        reloadLocalData()
        status = scanStatus(for: bluetooth.state)

        if settingsStore.autoScanOnLaunch, bluetooth.state == .poweredOn, status == .idle {
            startScan()
        }
    }

    /// 离开首页时停止扫描并解绑回调，避免与其它页面的回调相互覆盖。
    func deactivate() {
        guard isActive else { return }
        isActive = false
        if status == .scanning {
            stopScan()
        }
        bluetooth.discoveryHandler = nil
        bluetooth.stateChangeHandler = nil
    }

    // MARK: - Actions

    func toggleScan() {
        switch status {
        case .scanning:
            stopScan()
        default:
            startScan()
        }
    }

    func startScan() {
        guard bluetooth.state == .poweredOn else {
            status = scanStatus(for: bluetooth.state)
            recordLog(
                category: .session,
                level: .warning,
                message: L10n.f("home.scanUnavailable", String(describing: bluetooth.state.title))
            )
            return
        }

        liveDevices.removeAll()
        ruleEvaluator.reset()
        lastRuleEvent = nil
        isScanRequested = true
        status = .scanning
        recordLog(category: .session, message: L10n.t("home.scanStarted"))
        bluetooth.startScanning()
        rebuildRows()
    }

    func stopScan() {
        isScanRequested = false
        bluetooth.stopScanning()
        let discovered = liveDevices.count
        status = .idle
        recordLog(category: .session, message: L10n.f("home.scanFinished", String(describing: discovered)))
        rebuildRows()
    }

    /// 保存扫描设备到「设备」模块。
    func saveDevice(_ row: HomeDeviceRow) {
        guard !row.isSaved else { return }
        let now = Date()
        let device = SavedDevice(
            peripheralID: row.peripheralID,
            advertisedName: row.name,
            groupName: SavedDevice.defaultGroupName,
            lastSeenAt: row.lastSeenAt,
            createdAt: now,
            updatedAt: now,
            advertisedNamePatch: .set(row.name)
        )
        do {
            try savedDeviceStore.upsert(device)
            savedDevices = try savedDeviceStore.fetchAll()
            if var live = liveDevices[row.peripheralID] {
                live.isSaved = true
                liveDevices[row.peripheralID] = live
            }
            recordLog(category: .device, message: L10n.f("home.saveDevice", String(describing: device.displayName)))
            rebuildRows()
        } catch {
            lastError = .database(L10n.f("devices.saveFailed", String(describing: error)))
        }
    }

    var scanActionTitle: String {
        status == .scanning ? L10n.t("home.stop") : L10n.t("home.scan")
    }

    var statusText: String {
        switch status {
        case .idle:
            return recentDevices.isEmpty ? L10n.t("home.notScanned") : L10n.t("home.recentScan")
        case .scanning:
            return L10n.f("home.scanning", String(describing: liveDevices.count))
        case .unavailable(let state):
            return state.title
        case .failed(let message):
            return message
        }
    }

    var emptyState: (symbol: String, title: String, message: String, actionTitle: String?) {
        switch status {
        case .scanning:
            return (SymbolName.bluetooth, L10n.t("home.scanningTitle"), L10n.t("home.scanningHint"), nil)
        case .unavailable(.unsupported):
            return (SymbolName.bluetoothPoweredOff, L10n.t("home.unsupportedTitle"), L10n.t("home.unsupportedMessage"), nil)
        case .unavailable(.unauthorized):
            return (SymbolName.bluetoothPoweredOff, L10n.t("bluetooth.state.unauthorized"), L10n.t("home.unauthorizedMessage"), nil)
        case .unavailable(.poweredOff):
            return (SymbolName.bluetoothPoweredOff, L10n.t("bluetooth.state.poweredOff"), L10n.t("home.bluetoothOffMessage"), L10n.t("home.empty.action"))
        case .unavailable, .failed:
            return (SymbolName.bluetoothPoweredOff, L10n.t("home.bluetoothUnavailableTitle"), L10n.t("home.bluetoothUnavailableMessage"), L10n.t("home.empty.action"))
        case .idle:
            return (SymbolName.bluetooth, L10n.t("home.noScanTitle"), L10n.t("home.noScanMessage"), L10n.t("home.empty.action"))
        }
    }

    // MARK: - Bluetooth

    private func handleBluetoothState(_ state: BluetoothState) {
        switch state {
        case .poweredOn:
            status = isScanRequested ? .scanning : .idle
        default:
            status = .unavailable(state)
            if state == .unauthorized {
                recordLog(category: .session, level: .warning, message: L10n.t("home.bluetoothDeniedTitle"))
            }
        }
    }

    private func scanStatus(for state: BluetoothState) -> ScanStatus {
        switch state {
        case .poweredOn: return .idle
        case .unknown, .resetting: return .idle
        default: return .unavailable(state)
        }
    }

    private func handleDiscovery(_ device: ScannedDevice) {
        var device = device
        pruneStaleDevices(referenceDate: device.lastSeenAt)

        device.isSaved = savedDevices.contains { $0.peripheralID == device.peripheralID }
        liveDevices[device.peripheralID] = device

        if settingsStore.autoSaveRecentDevices {
            try? recentDeviceStore.upsert(
                peripheralID: device.peripheralID,
                name: device.name,
                rssi: device.rssi,
                lastSeenAt: device.lastSeenAt
            )
            upsertRecentInMemory(device)
        }

        touchSavedDeviceLastSeen(device)
        evaluateRules(referenceDate: device.lastSeenAt)
        rebuildRows()
    }

    /// 移除超时未出现的设备，让「断开」规则能感知到设备离开。
    private func pruneStaleDevices(referenceDate: Date) {
        let threshold = referenceDate.addingTimeInterval(-staleInterval)
        liveDevices = liveDevices.filter { $0.value.lastSeenAt >= threshold }
    }

    private func touchSavedDeviceLastSeen(_ scanned: ScannedDevice) {
        guard let index = savedDevices.firstIndex(where: { $0.peripheralID == scanned.peripheralID }) else {
            return
        }
        var device = savedDevices[index]
        device.lastSeenAt = scanned.lastSeenAt
        // 扫描只更新广播名，绝不触碰用户别名 / 分组；三态保持已有的待上报状态。
        let name = scanned.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != device.advertisedName {
            device.advertisedName = name
            device.advertisedNamePatch = .set(name)
        }
        device.updatedAt = scanned.lastSeenAt
        device.syncState = .pending
        savedDevices[index] = device
        try? savedDeviceStore.upsert(device)
    }

    private func evaluateRules(referenceDate: Date) {
        let observed = liveDevices.mapValues { $0.rssi }
        let events = ruleEvaluator.evaluate(
            rules: rules,
            devices: savedDevices,
            observedRSSI: observed,
            date: referenceDate
        )
        guard let event = events.first else { return }
        lastRuleEvent = event
        for event in events {
            recordLog(category: .rule, level: .warning, message: event.message)
        }
        // 扫描日志之外再发本地通知；通知开关 / 节流 / 授权都由协调器统一处理。
        ruleAlertCoordinator?.handle(events)
    }

    // MARK: - Local Data

    private func reloadLocalData() {
        savedDevices = (try? savedDeviceStore.fetchAll()) ?? []
        rules = (try? ruleStore.fetchAll()) ?? []
        recentDevices = (try? recentDeviceStore.fetchAll()) ?? []
        rebuildRows()
    }

    private func upsertRecentInMemory(_ scanned: ScannedDevice) {
        let recent = RecentDevice(
            peripheralID: scanned.peripheralID,
            name: scanned.name,
            rssi: scanned.rssi,
            lastSeenAt: scanned.lastSeenAt,
            updatedAt: scanned.lastSeenAt,
            deletedAt: nil,
            syncState: .pending
        )
        recentDevices.removeAll { $0.peripheralID == scanned.peripheralID }
        recentDevices.insert(recent, at: 0)
    }

    private func rebuildRows() {
        let useLive = !liveDevices.isEmpty || status == .scanning
        if useLive {
            rows = liveDevices.values
                .map {
                    HomeDeviceRow(
                        peripheralID: $0.peripheralID,
                        name: $0.name,
                        rssi: $0.rssi,
                        lastSeenAt: $0.lastSeenAt,
                        isSaved: $0.isSaved
                    )
                }
                .sorted { lhs, rhs in
                    (lhs.rssi ?? Int.min) > (rhs.rssi ?? Int.min)
                }
        } else {
            let savedIDs = Set(savedDevices.map { $0.peripheralID })
            rows = recentDevices.map {
                HomeDeviceRow(
                    peripheralID: $0.peripheralID,
                    name: $0.name,
                    rssi: nil,
                    lastSeenAt: $0.lastSeenAt,
                    isSaved: savedIDs.contains($0.peripheralID)
                )
            }
        }
    }

    private func recordLog(category: ScanLogCategory, level: ScanLogLevel = .info, message: String) {
        let entry = ScanLogEntry(category: category, level: level, message: message)
        try? scanLogStore.append(entry)
    }
}
