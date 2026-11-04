import Foundation

/// 设备详情视图模型：连接蓝牙 → 拉取设备信息 → 网络失败降级本地缓存。
final class DeviceDetailViewModel {
    enum State: Equatable {
        case idle
        case connecting
        case loadingInfo
        case loaded(ProductModel)
        case cache(ProductModel, fetchedAt: Date, error: AppError)
        case failed(AppError)
    }

    private(set) var state: State = .idle {
        didSet { onChange?() }
    }
    private(set) var notice: String? {
        didSet { onChange?() }
    }
    private(set) var device: SavedDevice

    var onChange: (() -> Void)?

    private let bluetooth: BluetoothServicing
    private let productService: ProductServicing
    private let cacheStore: DeviceInfoCacheStore
    private let savedDeviceStore: SavedDeviceStore
    private var hasStarted = false

    init(
        device: SavedDevice,
        bluetooth: BluetoothServicing,
        productService: ProductServicing,
        cacheStore: DeviceInfoCacheStore,
        savedDeviceStore: SavedDeviceStore
    ) {
        self.device = device
        self.bluetooth = bluetooth
        self.productService = productService
        self.cacheStore = cacheStore
        self.savedDeviceStore = savedDeviceStore
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        bluetooth.connectionHandler = { [weak self] event in
            self?.handle(event)
        }

        guard bluetooth.state == .poweredOn else {
            notice = "蓝牙不可用（\(bluetooth.state.title)），已直接读取设备信息"
            fetchInfo()
            return
        }

        state = .connecting
        bluetooth.connect(peripheralID: device.peripheralID)
    }

    func teardown() {
        bluetooth.connectionHandler = nil
        if bluetooth.state == .poweredOn {
            bluetooth.disconnect(peripheralID: device.peripheralID)
        }
    }

    func retry() {
        notice = nil
        guard bluetooth.state == .poweredOn else {
            notice = "蓝牙不可用（\(bluetooth.state.title)），已直接读取设备信息"
            fetchInfo()
            return
        }
        state = .connecting
        bluetooth.connect(peripheralID: device.peripheralID)
    }

    // MARK: - Connection

    private func handle(_ event: BluetoothConnectionEvent) {
        switch event {
        case .connected(let peripheralID) where peripheralID == device.peripheralID:
            notice = "蓝牙已连接，正在读取设备信息"
            fetchInfo()

        case .failed(let peripheralID, let message) where peripheralID == device.peripheralID:
            notice = "蓝牙连接失败：\(message)，已尝试读取设备信息"
            fetchInfo()

        case .disconnected(let peripheralID, let message) where peripheralID == device.peripheralID:
            if state == .connecting || state == .loadingInfo {
                notice = "蓝牙连接已断开：\(message ?? "未知原因")"
            }

        default:
            break
        }
    }

    // MARK: - Network

    private func fetchInfo() {
        state = .loadingInfo
        productService.fetchDeviceInfo(peripheralID: device.peripheralID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let product):
                try? self.cacheStore.save(product: product, peripheralID: self.device.peripheralID)
                self.persist(product: product)
                self.state = .loaded(product)

            case .failure(let error):
                if let cache = try? self.cacheStore.fetch(peripheralID: self.device.peripheralID) {
                    self.state = .cache(cache.product, fetchedAt: cache.fetchedAt, error: error)
                } else {
                    self.state = .failed(error)
                }
            }
        }
    }

    /// 把设备信息回写本地设备表，便于列表直接展示厂商与固件版本。
    private func persist(product: ProductModel) {
        device.mac = product.mac.isEmpty ? nil : product.mac
        device.vendor = product.vendor.isEmpty ? nil : product.vendor
        device.firmwareVersion = product.firmwareVersion.isEmpty ? nil : product.firmwareVersion
        device.updatedAt = Date()
        device.syncState = .pending
        try? savedDeviceStore.upsert(device)
    }

    // MARK: - Display

    var product: ProductModel? {
        switch state {
        case .loaded(let product): return product
        case .cache(let product, _, _): return product
        default: return nil
        }
    }

    var statusText: String {
        switch state {
        case .idle: return "尚未读取设备信息"
        case .connecting: return "正在连接蓝牙设备…"
        case .loadingInfo: return "正在读取设备信息…"
        case .loaded: return "设备信息已更新"
        case .cache(_, let fetchedAt, let error):
            return "\(error.code) 网络读取失败，显示 \(AppDateFormat.absolute(fetchedAt)) 的本地缓存"
        case .failed(let error):
            return error.localizedDescriptionText
        }
    }

    var isLoading: Bool {
        state == .connecting || state == .loadingInfo
    }
}
