import Foundation

/// 扫描到的一台蓝牙设备（运行时状态，不直接持久化）。
struct ScannedDevice: Equatable {
    /// CoreBluetooth 分配的稳定标识符，同一台设备在同一台手机上保持不变。
    let peripheralID: UUID
    var name: String
    var rssi: Int
    var lastSeenAt: Date
    /// 是否已在「设备」页保存。
    var isSaved: Bool
}

/// 蓝牙可用性状态。与 Android 端的 BT-001 / BT-002 / BT-003 错误码一一对应。
enum BluetoothState: Equatable {
    case unknown
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
    case resetting

    var title: String {
        switch self {
        case .unknown: return "正在初始化蓝牙"
        case .unsupported: return "当前设备不支持蓝牙"
        case .unauthorized: return "未获得蓝牙权限"
        case .poweredOff: return "蓝牙已关闭"
        case .poweredOn: return "蓝牙已就绪"
        case .resetting: return "蓝牙正在重置"
        }
    }

    var isReady: Bool { self == .poweredOn }
}

/// 蓝牙授权状态，对应 `CBManager.authorization`。
enum BluetoothAuthorization: String, Equatable {
    case allowed
    case denied
    case restricted
    case notDetermined
    case unknown

    var title: String {
        switch self {
        case .allowed: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未询问"
        case .unknown: return "未知"
        }
    }
}

/// 连接事件。
enum BluetoothConnectionEvent: Equatable {
    case connected(peripheralID: UUID)
    case disconnected(peripheralID: UUID, errorMessage: String?)
    case failed(peripheralID: UUID, errorMessage: String)
}
