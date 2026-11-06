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
    private let householdService: HouseholdService?
    private let sessionManager: SessionManager?

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
        notifications: LocalNotificationServing = UserNotificationService.shared,
        householdService: HouseholdService? = nil,
        sessionManager: SessionManager? = nil
    ) {
        self.bluetooth = bluetooth
        self.scanLogStore = scanLogStore
        self.settingsStore = settingsStore
        self.syncEngine = syncEngine
        self.pairingService = pairingService
        self.accountExportService = accountExportService
        self.accountDeletionService = accountDeletionService
        self.notifications = notifications
        self.householdService = householdService
        self.sessionManager = sessionManager
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
        guard let lastSyncAt = syncStatus.lastSyncAt else { return L10n.t("sync.notSyncedYet") }
        return AppDateFormat.absolute(lastSyncAt)
    }

    var pendingUploadText: String {
        syncStatus.pendingCount == 0 ? L10n.t("sync.noPending") : L10n.f("sync.pendingCount", String(describing: syncStatus.pendingCount))
    }

    var accountText: String {
        if syncStatus.needsRelogin {
            return L10n.t("sync.sessionExpired")
        }
        guard let userID = syncStatus.userID, !userID.isEmpty else { return L10n.t("sync.noAnonymousAccount") }
        return userID
    }

    /// 会话到期日：只读展示，来自 `/auth/anonymous` 或 claim 返回的 `expiresAt`。
    /// 不用于鉴权判断（是否失效以 401 为准）；旧后端未返回时明确显示"未返回"。
    var sessionExpiryText: String {
        if syncStatus.needsRelogin { return L10n.t("sync.sessionExpired") }
        guard let expiresAt = syncStatus.sessionExpiresAt else { return L10n.t("common.notProvided") }
        return AppDateFormat.day(expiresAt)
    }

    /// 同步区状态：登录失效 / 进行中 / 上次结果 / 失败原因 / 从未同步。
    var syncStatusText: String {
        if syncStatus.isSyncing { return L10n.t("sync.syncing") }
        if syncStatus.needsRelogin {
            return L10n.t("sync.sessionExpiredMessage")
        }
        if let lastOutcome = syncStatus.lastOutcomeMessage { return lastOutcome }
        if let error = syncStatus.lastError { return "\(error.code) \(error.message)" }
        return L10n.t("sync.notSyncedMessage")
    }

    /// 降级说明：网络/后端不可用时本地功能不受影响；登录失效时说明换号后果。
    var syncDegradationText: String {
        var lines: [String] = []
        if syncStatus.needsRelogin {
            lines.append(L10n.t("sync.reloginNote"))
        }
        lines.append(L10n.t("sync.offlineNote"))
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
            return L10n.t("profile.backgroundOnNote")
        }
        return L10n.t("profile.backgroundOffNote")
    }

    // MARK: - Account

    /// 异步导出：创建任务 → 轮询 → 下载 → 返回临时文件，由界面分享后删除。
    func exportAccountData(
        progress: @escaping (AccountExportPhase) -> Void,
        completion: @escaping (Result<AccountExportResult, AccountExportError>) -> Void
    ) {
        accountExportService.export(progress: progress, completion: completion)
    }

    func cancelExport() {
        accountExportService.cancel()
    }

    func removeExportedFile(at url: URL) {
        accountExportService.removeExportedFile(at: url)
    }

    /// 注销第一步：申请 10 分钟有效的删除令牌，供二次确认时提交。
    func requestDeletionToken(
        completion: @escaping (Result<DeletionChallenge, AccountDeletionError>) -> Void
    ) {
        accountDeletionService.requestDeletionToken(completion: completion)
    }

    /// 注销第二步：提交令牌。成功或 404（已删除）后服务会清空本地并刷新登录态。
    func confirmDeletion(
        _ challenge: DeletionChallenge,
        completion: @escaping (Result<AccountDeletionOutcome, AccountDeletionError>) -> Void
    ) {
        accountDeletionService.confirmDeletion(challenge) { [weak self] result in
            self?.syncEngine.refreshStatus()
            self?.refresh()
            completion(result)
        }
    }

    var accountDeletionConfirmationText: String {
        L10n.t("profile.deleteDataNote")
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

    // MARK: - Sessions

    /// 「我的」页会话区是否可用：已持有 token 才谈得上管理会话。
    var canManageSessions: Bool {
        guard let sessionManager else { return false }
        return sessionManager.hasSession
    }

    var sessionSummaryText: String {
        canManageSessions ? L10n.t("session.manageSummary") : L10n.t("session.none")
    }

    func makeSessionListViewModel() -> SessionListViewModel? {
        guard let sessionManager, sessionManager.hasSession else { return nil }
        return SessionListViewModel(manager: sessionManager)
    }

    /// 退出当前会话：只清本机凭据，不删除本地设备 / 读数。
    func logoutCurrent(completion: @escaping (Result<Void, AppError>) -> Void) {
        guard let sessionManager else {
            completion(.failure(.configuration(L10n.t("session.unavailable"))))
            return
        }
        sessionManager.onChange = { [weak self] in
            self?.syncEngine.refreshStatus()
            self?.refresh()
        }
        sessionManager.logoutCurrent { [weak self] result in
            self?.syncEngine.refreshStatus()
            self?.refresh()
            completion(result)
        }
    }

    // MARK: - Household

    /// 「家庭管理」行副标题：当前家庭 + 角色；未接入时给出明确说明。
    var householdText: String {
        guard let current = householdService?.currentHousehold() else {
            return L10n.t("household.empty")
        }
        return "\(current.name) · \(current.role.displayName)"
    }

    var hasHouseholdService: Bool { householdService != nil }

    func makeHouseholdViewModel() -> HouseholdManagementViewModel? {
        guard let householdService else { return nil }
        return HouseholdManagementViewModel(service: householdService)
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

    var ruleAlertThrottleText: String { L10n.f("profile.minutes", String(describing: ruleAlertThrottleMinutes)) }

    var notificationAuthorizationText: String {
        switch notificationAuthorization {
        case .authorized: return L10n.t("permission.status.granted")
        case .denied: return L10n.t("permission.status.denied")
        case .provisional: return L10n.t("permission.status.ephemeral")
        case .ephemeral: return L10n.t("permission.status.provisional")
        case .notDetermined: return L10n.t("permission.status.notAsked")
        @unknown default: return L10n.t("common.unknown")
        }
    }

    /// 拒绝后给出系统设置入口提示；未询问时说明首次命中才会弹窗。
    var notificationGuidance: String {
        if !ruleAlertsEnabled { return L10n.t("profile.notificationsOffNote") }
        switch notificationAuthorization {
        case .denied:
            return L10n.t("profile.notificationsDeniedNote")
        case .notDetermined:
            return L10n.t("profile.notificationsPromptNote")
        default:
            return L10n.t("profile.notificationsBehavior")
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
        return L10n.f("profile.buildFormat", short, build)
    }

    /// 未授权/受限时给出明确的操作引导。
    var permissionGuidance: String {
        switch authorization {
        case .allowed:
            return L10n.t("profile.bluetoothGrantedNote")
        case .notDetermined:
            return L10n.t("profile.bluetoothNotAskedNote")
        case .denied, .restricted:
            return L10n.t("profile.bluetoothDeniedNote")
        case .unknown:
            return L10n.t("profile.bluetoothUnknownNote")
        }
    }
}
