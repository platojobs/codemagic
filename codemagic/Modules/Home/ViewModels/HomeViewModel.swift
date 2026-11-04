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
        staleInterval: TimeInterval = 10
    ) {
        self.bluetooth = bluetooth
        self.savedDeviceStore = savedDeviceStore
        self.recentDeviceStore = recentDeviceStore
        self.scanLogStore = scanLogStore
        self.ruleStore = ruleStore
        self.settingsStore = settingsStore
        self.ruleEvaluator = ruleEvaluator
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
                message: "无法开始扫描：\(bluetooth.state.title)"
            )
            return
        }

        liveDevices.removeAll()
        ruleEvaluator.reset()
        lastRuleEvent = nil
        isScanRequested = true
        status = .scanning
        recordLog(category: .session, message: "开始扫描附近的蓝牙设备")
        bluetooth.startScanning()
        rebuildRows()
    }

    func stopScan() {
        isScanRequested = false
        bluetooth.stopScanning()
        let discovered = liveDevices.count
        status = .idle
        recordLog(category: .session, message: "结束扫描，本次共发现 \(discovered) 台设备")
        rebuildRows()
    }

    /// 保存扫描设备到「设备」模块。
    func saveDevice(_ row: HomeDeviceRow) {
        guard !row.isSaved else { return }
        let now = Date()
        let device = SavedDevice(
            peripheralID: row.peripheralID,
            name: row.name,
            groupName: SavedDevice.defaultGroupName,
            lastSeenAt: row.lastSeenAt,
            createdAt: now,
            updatedAt: now
        )
        do {
            try savedDeviceStore.upsert(device)
            savedDevices = try savedDeviceStore.fetchAll()
            if var live = liveDevices[row.peripheralID] {
                live.isSaved = true
                liveDevices[row.peripheralID] = live
            }
            recordLog(category: .device, message: "保存设备「\(device.name)」")
            rebuildRows()
        } catch {
            lastError = .database("保存设备失败：\(error)")
        }
    }

    var scanActionTitle: String {
        status == .scanning ? "停止" : "扫描"
    }

    var statusText: String {
        switch status {
        case .idle:
            return recentDevices.isEmpty ? "尚未扫描，点右上角开始" : "显示最近扫描到的设备"
        case .scanning:
            return "正在扫描附近设备… 已发现 \(liveDevices.count) 台"
        case .unavailable(let state):
            return state.title
        case .failed(let message):
            return message
        }
    }

    var emptyState: (symbol: String, title: String, message: String, actionTitle: String?) {
        switch status {
        case .scanning:
            return (SymbolName.bluetooth, "正在扫描", "请让蓝牙设备进入广播状态，扫描结果会自动出现在这里。", nil)
        case .unavailable(.unsupported):
            return (SymbolName.bluetoothPoweredOff, "当前环境不支持蓝牙", "模拟器不提供真实的蓝牙能力，请使用真机验证扫描。", nil)
        case .unavailable(.unauthorized):
            return (SymbolName.bluetoothPoweredOff, "未获得蓝牙权限", "请到「我的」页跳转系统设置，开启蓝牙权限后重试。", nil)
        case .unavailable(.poweredOff):
            return (SymbolName.bluetoothPoweredOff, "蓝牙已关闭", "请在系统设置中开启蓝牙后重试。", "开始扫描")
        case .unavailable, .failed:
            return (SymbolName.bluetoothPoweredOff, "蓝牙暂不可用", "请检查蓝牙状态后重试。", "开始扫描")
        case .idle:
            return (SymbolName.bluetooth, "还没有扫描记录", "点击开始扫描，附近设备会显示在这里，并保留最近一次结果。", "开始扫描")
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
                recordLog(category: .session, level: .warning, message: "蓝牙权限未开启")
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
