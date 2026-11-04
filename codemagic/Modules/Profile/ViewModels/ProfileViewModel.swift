import Foundation

/// 「我的」视图模型：蓝牙权限自检、本地扫描日志、基础设置与同步状态。
final class ProfileViewModel {
    private(set) var authorization: BluetoothAuthorization = .unknown
    private(set) var bluetoothState: BluetoothState = .unknown
    private(set) var logCount: Int = 0
    private(set) var syncStatus = SyncEngine.Status()

    let startupWarning: String?
    let baseURLText: String

    var onChange: (() -> Void)?

    private let bluetooth: BluetoothServicing
    private let scanLogStore: ScanLogStore
    private let settingsStore: SettingsStore
    private let syncEngine: SyncEngine

    init(
        bluetooth: BluetoothServicing,
        scanLogStore: ScanLogStore,
        settingsStore: SettingsStore,
        syncEngine: SyncEngine,
        baseURLText: String,
        startupWarning: String?
    ) {
        self.bluetooth = bluetooth
        self.scanLogStore = scanLogStore
        self.settingsStore = settingsStore
        self.syncEngine = syncEngine
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
