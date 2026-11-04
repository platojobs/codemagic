import Foundation

/// 「我的」视图模型：蓝牙权限自检、本地扫描日志与基础设置。
final class ProfileViewModel {
    private(set) var authorization: BluetoothAuthorization = .unknown
    private(set) var bluetoothState: BluetoothState = .unknown
    private(set) var logCount: Int = 0

    let startupWarning: String?
    let baseURLText: String

    var onChange: (() -> Void)?

    private let bluetooth: BluetoothServicing
    private let scanLogStore: ScanLogStore
    private let settingsStore: SettingsStore

    init(
        bluetooth: BluetoothServicing,
        scanLogStore: ScanLogStore,
        settingsStore: SettingsStore,
        baseURLText: String,
        startupWarning: String?
    ) {
        self.bluetooth = bluetooth
        self.scanLogStore = scanLogStore
        self.settingsStore = settingsStore
        self.baseURLText = baseURLText
        self.startupWarning = startupWarning
    }

    // MARK: - Lifecycle

    func activate() {
        bluetooth.stateChangeHandler = { [weak self] state in
            self?.bluetoothState = state
            self?.onChange?()
        }
        refresh()
    }

    func deactivate() {
        bluetooth.stateChangeHandler = nil
    }

    func refresh() {
        authorization = bluetooth.currentAuthorization()
        bluetoothState = bluetooth.state
        logCount = (try? scanLogStore.count()) ?? 0
        onChange?()
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
