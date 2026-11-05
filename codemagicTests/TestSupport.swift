import Foundation
import XCTest
@testable import codemagic

/// 每个测试用例独立的临时 SQLite 库。
final class TestDatabase {
    let directory: URL
    let database: SQLiteDatabase

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemagic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: directory.appendingPathComponent("test.sqlite").path)
    }

    func makeDatabaseHandle() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: directory.appendingPathComponent("test.sqlite").path)
    }

    func cleanUp() {
        database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 可手动触发回调的蓝牙服务假实现。
final class FakeBluetoothService: BluetoothServicing {
    var state: BluetoothState
    var stateChangeHandler: ((BluetoothState) -> Void)?
    var discoveryHandler: ((ScannedDevice) -> Void)?
    var connectionHandler: ((BluetoothConnectionEvent) -> Void)?
    var readingHandler: ((BluetoothReadingSample) -> Void)?

    private(set) var authorization: BluetoothAuthorization
    private(set) var startScanningCount = 0
    private(set) var stopScanningCount = 0
    private(set) var connectedPeripheralIDs: [UUID] = []
    private(set) var disconnectedPeripheralIDs: [UUID] = []
    private(set) var readingPeripheralIDs: [UUID] = []
    private(set) var stoppedReadingPeripheralIDs: [UUID] = []
    private(set) var disconnectAllCount = 0

    init(state: BluetoothState = .poweredOn, authorization: BluetoothAuthorization = .allowed) {
        self.state = state
        self.authorization = authorization
    }

    func currentAuthorization() -> BluetoothAuthorization {
        authorization
    }

    func startScanning() {
        startScanningCount += 1
        if state != .poweredOn {
            stateChangeHandler?(state)
        }
    }

    func stopScanning() {
        stopScanningCount += 1
    }

    func connect(peripheralID: UUID) {
        connectedPeripheralIDs.append(peripheralID)
    }

    func disconnect(peripheralID: UUID) {
        disconnectedPeripheralIDs.append(peripheralID)
    }

    func startReading(peripheralID: UUID) {
        readingPeripheralIDs.append(peripheralID)
    }

    func stopReading(peripheralID: UUID) {
        stoppedReadingPeripheralIDs.append(peripheralID)
    }

    var connectedPeripheralCount: Int {
        connectedPeripheralIDs.count
    }

    func disconnectAll() {
        disconnectAllCount += 1
        for id in connectedPeripheralIDs {
            disconnectedPeripheralIDs.append(id)
        }
    }

    // MARK: - Test Helpers

    func emitState(_ newState: BluetoothState) {
        state = newState
        stateChangeHandler?(newState)
    }

    func emitDiscovery(_ device: ScannedDevice) {
        discoveryHandler?(device)
    }

    func emitConnection(_ event: BluetoothConnectionEvent) {
        connectionHandler?(event)
    }

    func emitReading(_ sample: BluetoothReadingSample) {
        readingHandler?(sample)
    }
}

/// 同步返回预设结果的网络服务假实现。
final class StubProductService: ProductServicing {
    var productsResult: Result<[ProductModel], AppError> = .success([])
    var marketResult: Result<[MarketItem], AppError> = .success([])
    var deviceInfoResult: Result<ProductModel, AppError> = .failure(.network("stub"))
    private(set) var deviceInfoRequestIDs: [UUID] = []

    func fetchProducts(completion: @escaping (Result<[ProductModel], AppError>) -> Void) {
        completion(productsResult)
    }

    func fetchMarketItems(completion: @escaping (Result<[MarketItem], AppError>) -> Void) {
        completion(marketResult)
    }

    func fetchDeviceInfo(
        peripheralID: UUID,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        deviceInfoRequestIDs.append(peripheralID)
        completion(deviceInfoResult)
    }
}

/// 记录请求 URL/头部并返回预设数据或状态码的 HTTP 客户端。
final class StubHTTPClient: HTTPClient {
    var handler: (URL) -> Result<Data, AppError>
    var statusCode: Int
    var responseHeaders: [String: String]

    private(set) var requestedURLs: [URL] = []
    private(set) var requests: [HTTPRequest] = []

    init(
        statusCode: Int = 200,
        responseHeaders: [String: String] = [:],
        handler: @escaping (URL) -> Result<Data, AppError> = { _ in .failure(.network("stub")) }
    ) {
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.handler = handler
    }

    func send(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, AppError>) -> Void) {
        requestedURLs.append(request.url)
        requests.append(request)
        switch handler(request.url) {
        case .success(let data):
            completion(.success(HTTPResponse(statusCode: statusCode, headers: responseHeaders, data: data)))
        case .failure(let error):
            completion(.failure(error))
        }
    }
}

// MARK: - Fixtures

func makeSavedDevice(
    peripheralID: UUID = UUID(),
    name: String = "测试设备",
    remark: String = "",
    groupName: String = SavedDevice.defaultGroupName,
    aliasPatch: Patch<String> = .absent,
    advertisedNamePatch: Patch<String> = .absent,
    groupPatch: Patch<String> = .absent
) -> SavedDevice {
    SavedDevice(
        peripheralID: peripheralID,
        advertisedName: name,
        remark: remark,
        groupName: groupName,
        aliasPatch: aliasPatch,
        advertisedNamePatch: advertisedNamePatch,
        groupPatch: groupPatch
    )
}

func makeProduct(
    mac: String = "AA:BB:CC:DD:EE:FF",
    vendor: String = "Acme",
    deviceType: String = "Panel",
    firmwareVersion: String = "1.2.0",
    services: [GATTService] = [GATTService(uuid: "180F", name: "Battery")],
    compatibility: [String] = ["X1"]
) -> ProductModel {
    ProductModel(
        mac: mac,
        vendor: vendor,
        deviceType: deviceType,
        firmwareVersion: firmwareVersion,
        gattServices: services,
        compatibility: compatibility
    )
}

func makeScannedDevice(
    peripheralID: UUID,
    name: String = "测试设备",
    rssi: Int = -60,
    lastSeenAt: Date
) -> ScannedDevice {
    ScannedDevice(peripheralID: peripheralID, name: name, rssi: rssi, lastSeenAt: lastSeenAt, isSaved: false)
}

/// 使用独立 UserDefaults suite，避免污染真实设置。
func makeSettingsStore() -> (store: SettingsStore, suiteName: String) {
    let suiteName = "codemagic.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (SettingsStore(defaults: defaults), suiteName)
}
