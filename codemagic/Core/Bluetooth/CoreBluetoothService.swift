import CoreBluetooth
import Foundation

/// 蓝牙服务抽象，UI 与视图模型只依赖该协议，测试可注入假实现。
protocol BluetoothServicing: AnyObject {
    var state: BluetoothState { get }
    var stateChangeHandler: ((BluetoothState) -> Void)? { get set }
    var discoveryHandler: ((ScannedDevice) -> Void)? { get set }
    var connectionHandler: ((BluetoothConnectionEvent) -> Void)? { get set }

    func currentAuthorization() -> BluetoothAuthorization
    func startScanning()
    func stopScanning()
    func connect(peripheralID: UUID)
    func disconnect(peripheralID: UUID)
}

/// CoreBluetooth 实现：真实扫描、连接与 RSSI 回调，回调统一在主线程投递。
final class CoreBluetoothService: NSObject, BluetoothServicing {
    // MARK: - Callbacks

    var stateChangeHandler: ((BluetoothState) -> Void)?
    var discoveryHandler: ((ScannedDevice) -> Void)?
    var connectionHandler: ((BluetoothConnectionEvent) -> Void)?

    // MARK: - State

    private(set) var state: BluetoothState = .unknown {
        didSet {
            guard oldValue != state else { return }
            stateChangeHandler?(state)
        }
    }

    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var lastEmit: [UUID: (rssi: Int, date: Date)] = [:]
    private var wantsScanning = false
    private var connectTimeoutWorkItem: DispatchWorkItem?

    // MARK: - Init

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    // MARK: - BluetoothServicing

    func currentAuthorization() -> BluetoothAuthorization {
        switch CBManager.authorization {
        case .allowedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    func startScanning() {
        wantsScanning = true
        guard state == .poweredOn else {
            stateChangeHandler?(state)
            return
        }
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScanning() {
        wantsScanning = false
        if state == .poweredOn {
            centralManager.stopScan()
        }
    }

    func connect(peripheralID: UUID) {
        guard state == .poweredOn else {
            connectionHandler?(
                .failed(peripheralID: peripheralID, errorMessage: state.title)
            )
            return
        }
        guard let peripheral = peripheral(for: peripheralID) else {
            connectionHandler?(
                .failed(peripheralID: peripheralID, errorMessage: "未找到该蓝牙设备")
            )
            return
        }

        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)

        connectTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, peripheral.state != .connected else { return }
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.connectionHandler?(
                .failed(peripheralID: peripheralID, errorMessage: "连接超时")
            )
        }
        connectTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: workItem)
    }

    func disconnect(peripheralID: UUID) {
        guard let peripheral = peripheral(for: peripheralID) else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Private

    private func peripheral(for peripheralID: UUID) -> CBPeripheral? {
        if let discovered = discoveredPeripherals[peripheralID] {
            return discovered
        }
        // 应用重启后扫描缓存为空，用已知标识符向系统取回外设。
        let retrieved = centralManager.retrievePeripherals(withIdentifiers: [peripheralID])
        if let first = retrieved.first {
            discoveredPeripherals[peripheralID] = first
            return first
        }
        return nil
    }

    private func shouldEmit(rssi: Int, for peripheralID: UUID, now: Date) -> Bool {
        guard let last = lastEmit[peripheralID] else {
            lastEmit[peripheralID] = (rssi, now)
            return true
        }
        let significantChange = abs(last.rssi - rssi) >= 2
        let elapsed = now.timeIntervalSince(last.date) >= 3
        if significantChange || elapsed {
            lastEmit[peripheralID] = (rssi, now)
            return true
        }
        return false
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = .poweredOn
            if wantsScanning {
                startScanning()
            }
        case .poweredOff:
            state = .poweredOff
        case .unauthorized:
            state = .unauthorized
        case .unsupported:
            state = .unsupported
        case .resetting:
            state = .resetting
        case .unknown:
            state = .unknown
        @unknown default:
            state = .unknown
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let peripheralID = peripheral.identifier
        discoveredPeripherals[peripheralID] = peripheral

        let now = Date()
        guard shouldEmit(rssi: RSSI.intValue, for: peripheralID, now: now) else { return }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "未命名设备"
        discoveryHandler?(
            ScannedDevice(
                peripheralID: peripheralID,
                name: name,
                rssi: RSSI.intValue,
                lastSeenAt: now,
                isSaved: false
            )
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        connectionHandler?(.connected(peripheralID: peripheral.identifier))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        connectionHandler?(
            .failed(
                peripheralID: peripheral.identifier,
                errorMessage: error?.localizedDescription ?? "连接失败"
            )
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        connectionHandler?(
            .disconnected(
                peripheralID: peripheral.identifier,
                errorMessage: error?.localizedDescription
            )
        )
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothService: CBPeripheralDelegate {}
