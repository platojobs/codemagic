import Foundation
import UserNotifications

/// 「我的」视图模型：蓝牙权限自检、本地扫描日志、基础设置、通知授权与同步状态。
final class ProfileViewModel {
    private(set) var authorization: BluetoothAuthorization = .unknown
    private(set) var bluetoothState: BluetoothState = .unknown
    private(set) var logCount: Int = 0
    private(set) var syncStatus = SyncEngine.Status()
    private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    let startupWarning: String?
    let baseURLText: String

    var onChange: (() -> Void)?

    private let bluetooth: BluetoothServicing
    private let scanLogStore: ScanLogStore
    private let settingsStore: SettingsStore
    private let syncEngine: SyncEngine
    private let notifications: LocalNotificationServing
    private let pairingService: PairingServicing
    private let accountExportService: AccountExportService
    private let accountDeletionService: AccountDeletionService

    init(
        bluetooth: BluetoothServicing,
        scanLogStore: ScanLogStore,
        settingsStore: SettingsStore,
        syncEngine: SyncEngine,
        pairingService: PairingServicing,
        accountExportService: AccountExportService,
        accountDeletionService: AccountDeletionService,
        baseURLText: String,
        startupWarning: String?,
        notifications: LocalNotificationServing = UserNotificationService.shared
    ) {
        self.bluetooth = bluetooth
        self.scanLogStore = scanLogStore
        self.settingsStore = settingsStore
        self.syncEngine = syncEngine
        self.pairingService = pairingService
        self.accountExportService = accountExportService
        self.accountDeletionService = accountDeletionService
        self.notifications = notifications
        self.baseURLText = baseURLText
        self.startupWarning = startupWarning
    }

    // MARK: - Lifecycle

    func activate() {
        bluetooth.stateChangeHandler = { [weak self] state in
            self?.bluetoothState = state
            self?.onChange?()
        }
        syncEngine.onChange = { [weak self] in
            guard let self else { return }
            self.syncStatus = self.syncEngine.status
            self.onChange?()
        }
        refresh()
    }

    func deactivate() {
        bluetooth.stateChangeHandler = nil
        syncEngine.onChange = nil
    }

    func refresh() {
        authorization = bluetooth.currentAuthorization()
        bluetoothState = bluetooth.state
        logCount = (try? scanLogStore.count()) ?? 0
        syncStatus = syncEngine.status
        notifications.authorizationStatus { [weak self] status in
            guard let self else { return }
            self.notificationAuthorization = status
            self.onChange?()
        }
        onChange?()
    }

    // MARK: - Sync

    /// 手动同步：不受前后台节流限制，失败时状态区会给出错误码与降级说明。
    func manualSync() {
        guard !syncStatus.isSyncing else { return }
        syncEngine.sync { [weak self] _ in
            self?.refresh()
        }
    }

    /// 用户确认后：换新的匿名账号、重置游标、把本机设备重新上传。
    func relogin() {
        guard !syncStatus.isSyncing else { return }
        syncEngine.relogin { [weak self] _ in
            self?.refresh()
        }
    }

    var isSyncing: Bool { syncStatus.isSyncing }

    /// 匿名 token 已失效，需要用户在「我的」页确认重新登录。
    var needsRelogin: Bool { syncStatus.needsRelogin }

    var lastSyncText: String {
        guard let lastSyncAt = syncStatus.lastSyncAt else { return "尚未同步" }
        return AppDateFormat.absolute(lastSyncAt)
    }

    var pendingUploadText: String {
        syncStatus.pendingCount == 0 ? "无待上传" : "\(syncStatus.pendingCount) 条"
    }

    var accountText: String {
        if syncStatus.needsRelogin {
            return "登录已失效"
        }
        guard let userID = syncStatus.userID, !userID.isEmpty else { return "匿名账号尚未创建" }
        return userID
    }

    /// 同步区状态：登录失效 / 进行中 / 上次结果 / 失败原因 / 从未同步。
    var syncStatusText: String {
        if syncStatus.isSyncing { return "正在同步…" }
        if syncStatus.needsRelogin {
            return "登录已失效：匿名会话 token 已过期，云端同步已暂停。"
        }
        if let lastOutcome = syncStatus.lastOutcomeMessage { return lastOutcome }
        if let error = syncStatus.lastError { return "\(error.code) \(error.message)" }
        return "尚未同步。点击「立即同步」或回到前台后自动同步。"
    }

    /// 降级说明：网络/后端不可用时本地功能不受影响；登录失效时说明换号后果。
    var syncDegradationText: String {
        var lines: [String] = []
        if syncStatus.needsRelogin {
            lines.append("重新登录会创建新的匿名账号，旧账号的云端数据不会自动合并；本机已有设备会重新上传到新账号。")
        }
        lines.append("断网或后端不可用时同步会自动失败并保留待上传记录；恢复后前后台切换或后台任务会重试，本地功能不受影响。")
        if let conflict = syncStatus.lastConflictMessages.first {
            lines.append(conflict)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Settings

    var autoSaveRecentDevices: Bool {
        get { settingsStore.autoSaveRecentDevices }
        set {
            settingsStore.autoSaveRecentDevices = newValue
            onChange?()
        }
    }

    var autoScanOnLaunch: Bool {
        get { settingsStore.autoScanOnLaunch }
        set {
            settingsStore.autoScanOnLaunch = newValue
            onChange?()
        }
    }

    // MARK: - Background Collection

    var backgroundCollectionEnabled: Bool {
        get { settingsStore.backgroundCollectionEnabled }
        set {
            settingsStore.backgroundCollectionEnabled = newValue
            if !newValue {
                // 关闭后立即断开当前连接，不再后台保持链路。
                bluetooth.disconnectAll()
            }
            onChange?()
        }
    }

    var backgroundCollectionStatusText: String {
        settingsStore.backgroundCollectionStatusText(connectedCount: bluetooth.connectedPeripheralCount)
    }

    var backgroundCollectionGuidance: String {
        if backgroundCollectionEnabled {
            return "开启后连接状态下锁屏/切后台仍会接收 notify 并入库；持续 BLE 连接与后台唤醒会增加耗电，系统低电量模式可能延后唤醒。"
        }
        return "关闭后进入后台会主动断开蓝牙连接，后台不再接收读数；回到前台后需重新连接设备。"
    }

    // MARK: - Account

    /// 导出账号数据：进度为已读取的真实读数条数；完成后返回临时文件，由界面分享后删除。
    func exportAccountData(
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, AccountExportError>) -> Void
    ) {
        accountExportService.export(progress: progress, completion: completion)
    }

    func removeExportedFile(at url: URL) {
        accountExportService.removeExportedFile(at: url)
    }

    /// 注销账号。服务端失败时本地数据完全保留；成功则由服务按 token → 业务表 → 元数据顺序清理。
    func deleteAccount(completion: @escaping (Result<Void, AccountDeletionError>) -> Void) {
        accountDeletionService.deleteAccount { [weak self] result in
            self?.refresh()
            completion(result)
        }
    }

    var accountDeletionConfirmationText: String {
        "设备与读数将永久删除且不可恢复，云端与本机数据都会被清空。注销后将回到全新的匿名状态。"
    }

    /// 接管后触发一次前台同步，让新账号尽快拿到本机重新标记的数据。
    func syncAfterTakeover() {
        syncEngine.sync { [weak self] _ in
            self?.refresh()
        }
    }

    func makePairingCodeViewModel() -> PairingCodeViewModel {
        PairingCodeViewModel(service: pairingService)
    }

    func makePairingClaimViewModel() -> PairingClaimViewModel {
        PairingClaimViewModel(service: pairingService)
    }

    // MARK: - Alerts

    /// 真实开关：关闭后规则命中只写扫描日志，不再请求授权或发通知。
    var ruleAlertsEnabled: Bool {
        get { settingsStore.ruleAlertsEnabled }
        set {
            settingsStore.ruleAlertsEnabled = newValue
            if newValue {
                notifications.requestAuthorizationIfNeeded { [weak self] granted in
                    guard let self else { return }
                    self.notifications.authorizationStatus { status in
                        self.notificationAuthorization = status
                        self.onChange?()
                    }
                    if !granted {
                        self.notificationAuthorization = .denied
                        self.onChange?()
                    }
                }
            }
            onChange?()
        }
    }

    var ruleAlertThrottleOptions: [Int] { SettingsStore.ruleAlertThrottleOptions }

    var ruleAlertThrottleMinutes: Int {
        get { settingsStore.ruleAlertThrottleMinutes }
        set {
            settingsStore.ruleAlertThrottleMinutes = newValue
            onChange?()
        }
    }

    var ruleAlertThrottleText: String { "\(ruleAlertThrottleMinutes) 分钟" }

    var notificationAuthorizationText: String {
        switch notificationAuthorization {
        case .authorized: return "已允许"
        case .denied: return "已拒绝"
        case .provisional: return "临时允许"
        case .ephemeral: return "临时授权"
        case .notDetermined: return "尚未询问"
        @unknown default: return "未知"
        }
    }

    /// 拒绝后给出系统设置入口提示；未询问时说明首次命中才会弹窗。
    var notificationGuidance: String {
        if !ruleAlertsEnabled { return "阈值告警通知已关闭，规则命中仍会写入本地扫描日志。" }
        switch notificationAuthorization {
        case .denied:
            return "通知权限被拒绝，阈值告警不会弹出。请前往系统设置开启通知后返回本页。"
        case .notDetermined:
            return "首次触发规则命中时会请求通知权限。"
        default:
            return "规则命中时发送本地通知；同一设备同一规则在节流窗口内只提醒一次，恢复时发送「已恢复」。"
        }
    }

    var needsNotificationSettings: Bool {
        ruleAlertsEnabled && notificationAuthorization == .denied
    }

    // MARK: - Appearance

    var appearance: AppAppearance {
        get { settingsStore.appearance }
        set {
            settingsStore.appearance = newValue
            onChange?()
        }
    }

    var appearanceText: String { settingsStore.appearance.title }

    // MARK: - Logs

    func clearLogs() {
        do {
            try scanLogStore.softDeleteAll()
            logCount = 0
        } catch {
            logCount = (try? scanLogStore.count()) ?? 0
        }
        onChange?()
    }

    // MARK: - Display

    var authorizationText: String {
        authorization.title
    }

    var bluetoothStateText: String {
        bluetoothState.title
    }

    var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short)（build \(build)）"
    }

    /// 未授权/受限时给出明确的操作引导。
    var permissionGuidance: String {
        switch authorization {
        case .allowed:
            return "已获得蓝牙权限。首次扫描由系统弹窗询问，之后可在系统设置中修改。"
        case .notDetermined:
            return "尚未询问蓝牙权限，开始扫描时会触发系统授权弹窗。"
        case .denied, .restricted:
            return "蓝牙权限被拒绝或受限，扫描与连接不可用。请前往系统设置开启。"
        case .unknown:
            return "无法获取蓝牙授权状态，请稍后重试。"
        }
    }
}
