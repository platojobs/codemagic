import CoreBluetooth
import Foundation

/// 蓝牙服务抽象，UI 与视图模型只依赖该协议，测试可注入假实现。
protocol BluetoothServicing: AnyObject {
    var state: BluetoothState { get }
    var stateChangeHandler: ((BluetoothState) -> Void)? { get set }
    var discoveryHandler: ((ScannedDevice) -> Void)? { get set }
    var connectionHandler: ((BluetoothConnectionEvent) -> Void)? { get set }
    /// notify 特征原始数据回调；解析与存储由上层完成。
    var readingHandler: ((BluetoothReadingSample) -> Void)? { get set }

    func currentAuthorization() -> BluetoothAuthorization
    func startScanning()
    func stopScanning()
    func connect(peripheralID: UUID)
    func disconnect(peripheralID: UUID)
    /// 连接后订阅心率 / 电池 / 温度 / Nordic UART TX（0x2A37 / 0x2A19 / 0x2A6E / 6E400003…）。
    func startReading(peripheralID: UUID)
    func stopReading(peripheralID: UUID)
    /// 当前已连接外设数量，用于「我的」页展示后台采集状态。
    var connectedPeripheralCount: Int { get }
    /// 指定外设是否已连接；场景执行前用于判断「重复连接 / 未连接」。
    func isConnected(peripheralID: UUID) -> Bool
    /// 关闭后台采集或进入后台时断开全部连接，不再保持 BLE 链路。
    func disconnectAll()
}

/// CoreBluetooth 实现：真实扫描、连接与 RSSI 回调，回调统一在主线程投递。
final class CoreBluetoothService: NSObject, BluetoothServicing {
    // MARK: - Callbacks

    var stateChangeHandler: ((BluetoothState) -> Void)?
    var discoveryHandler: ((ScannedDevice) -> Void)?
    var connectionHandler: ((BluetoothConnectionEvent) -> Void)?
    var readingHandler: ((BluetoothReadingSample) -> Void)?

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
    /// 需要订阅读数的外设；连接成功或已连接时开始服务发现。
    private var readingPeripheralID: UUID?
    private var notifiedCharacteristics: [CBUUID: CBCharacteristic] = [:]

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

    var connectedPeripheralCount: Int {
        var count = 0
        for peripheral in discoveredPeripherals.values where peripheral.state == .connected {
            count += 1
        }
        return count
    }

    func isConnected(peripheralID: UUID) -> Bool {
        peripheral(for: peripheralID)?.state == .connected
    }

    /// 后台采集关闭/进入后台：断开所有已知连接并停止读取。
    /// 使用 `retrieveConnectedPeripherals` 兜底覆盖本次进程未在扫描表中、但系统仍保持链路的外设。
    func disconnectAll() {
        readingPeripheralID = nil
        var targets: [UUID: CBPeripheral] = discoveredPeripherals
        if state == .poweredOn {
            for peripheral in centralManager.retrieveConnectedPeripherals(withServices: []) {
                targets[peripheral.identifier] = peripheral
            }
        }
        for (_, peripheral) in targets where peripheral.state == .connected || peripheral.state == .connecting {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    func startReading(peripheralID: UUID) {
        readingPeripheralID = peripheralID
        guard let peripheral = peripheral(for: peripheralID), peripheral.state == .connected else {
            // 尚未连接：didConnect 后统一开始服务发现。
            return
        }
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func stopReading(peripheralID: UUID) {
        if readingPeripheralID == peripheralID {
            readingPeripheralID = nil
        }
        let target = peripheral(for: peripheralID)
        for (_, characteristic) in notifiedCharacteristics {
            if characteristic.service?.peripheral === target {
                target?.setNotifyValue(false, for: characteristic)
            }
        }
        notifiedCharacteristics.removeAll()
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
        peripheral.delegate = self
        if readingPeripheralID == peripheral.identifier {
            // 只订阅已知读数特征；服务发现失败由 CoreBluetooth 回调，不影响连接事件。
            peripheral.discoverServices(nil)
        }
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

extension CoreBluetoothService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard readingPeripheralID == peripheral.identifier else { return }
        guard error == nil else { return }
        for service in peripheral.services ?? [] {
            // 不限定服务 UUID：部分设备把 Nordic UART 放在自定义服务下，
            // 只有特征 UUID 是可靠的。
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard readingPeripheralID == peripheral.identifier else { return }
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            guard ReadingCharacteristic.from(uuid: characteristic.uuid) != nil else { continue }
            guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                continue
            }
            notifiedCharacteristics[characteristic.uuid] = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              let data = characteristic.value,
              let kind = ReadingCharacteristic.from(uuid: characteristic.uuid)
        else { return }
        let sample = BluetoothReadingSample(
            peripheralID: peripheral.identifier,
            characteristic: kind,
            data: data,
            receivedAt: Date()
        )
        readingHandler?(sample)
    }
}
