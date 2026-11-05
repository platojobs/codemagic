import Foundation

/// 设备详情视图模型：连接蓝牙 → 拉取设备信息 → 网络失败降级本地缓存；同时展示本地读数。
final class DeviceDetailViewModel {
    enum State: Equatable {
        case idle
        case connecting
        case loadingInfo
        case loaded(ProductModel)
        case cache(ProductModel, fetchedAt: Date, error: AppError)
        case failed(AppError)
    }

    /// 「数据」区状态：指标来自该设备真实已有读数，不预置任何假数据。
    struct ReadingsState: Equatable {
        var metrics: [ReadingMetric] = []
        var selectedMetric: ReadingMetric?
        var points: [DeviceReading] = []
        var recent: [DeviceReading] = []
        var summary: ReadingSummary?
        var isSummaryFromCloud = false
        var isOfflineLocalData = false
        var isLoading = false

        var hasData: Bool { !points.isEmpty }
        var unit: String { points.last?.unit ?? selectedMetric?.defaultUnit ?? "" }
    }

    private(set) var state: State = .idle {
        didSet { onChange?() }
    }
    private(set) var notice: String? {
        didSet { onChange?() }
    }
    private(set) var readings = ReadingsState() {
        didSet { onChange?() }
    }
    private(set) var device: SavedDevice

    var onChange: (() -> Void)?

    private let bluetooth: BluetoothServicing
    private let productService: ProductServicing
    private let cacheStore: DeviceInfoCacheStore
    private let savedDeviceStore: SavedDeviceStore
    private let readingsStore: ReadingsStore
    private let readingsService: ReadingsAPIServicing
    private let readingsIngestor: ReadingsIngestor?
    private var hasStarted = false
    private var isObservingReadings = false

    init(
        device: SavedDevice,
        bluetooth: BluetoothServicing,
        productService: ProductServicing,
        cacheStore: DeviceInfoCacheStore,
        savedDeviceStore: SavedDeviceStore,
        readingsStore: ReadingsStore,
        readingsService: ReadingsAPIServicing = UnavailableReadingsAPI(),
        readingsIngestor: ReadingsIngestor? = nil
    ) {
        self.device = device
        self.bluetooth = bluetooth
        self.productService = productService
        self.cacheStore = cacheStore
        self.savedDeviceStore = savedDeviceStore
        self.readingsStore = readingsStore
        self.readingsService = readingsService
        self.readingsIngestor = readingsIngestor
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        loadReadings()
        refreshSummaryFromCloud()
        observeNewReadings()

        guard device.isConnectable else {
            notice = device.connectUnavailableText
            return
        }

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
        if isObservingReadings {
            readingsIngestor?.onSaved = nil
            isObservingReadings = false
        }
        if bluetooth.state == .poweredOn {
            bluetooth.stopReading(peripheralID: device.peripheralID)
            bluetooth.disconnect(peripheralID: device.peripheralID)
        }
    }

    func retry() {
        notice = nil
        guard device.isConnectable else {
            notice = device.connectUnavailableText
            return
        }
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
            bluetooth.startReading(peripheralID: device.peripheralID)
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

    /// 把设备信息回写本地设备表，便于列表直接展示厂商与固件版本，
    /// 并在后续推送时带上 `deviceType`（云端未返回型号时保留原值，不写空）。
    private func persist(product: ProductModel) {
        device.mac = product.mac.isEmpty ? nil : product.mac
        device.vendor = product.vendor.isEmpty ? nil : product.vendor
        if !product.deviceType.isEmpty {
            device.deviceType = product.deviceType
        }
        device.firmwareVersion = product.firmwareVersion.isEmpty ? nil : product.firmwareVersion
        device.updatedAt = Date()
        device.syncState = .pending
        try? savedDeviceStore.upsert(device)
    }

    // MARK: - Readings

    /// 无读数时的真实空状态文案；蓝牙未授权时指向系统设置。
    var readingsEmptyMessage: String {
        switch bluetooth.currentAuthorization() {
        case .denied, .restricted:
            return "蓝牙未授权：请到系统设置允许本应用使用蓝牙"
        case .notDetermined:
            return "连接设备后开始采集（首次连接会请求蓝牙权限）"
        case .allowed, .unknown:
            return "连接设备后开始采集"
        }
    }

    var canConnectForReadings: Bool { device.isConnectable }

    private func observeNewReadings() {
        guard let readingsIngestor else { return }
        readingsIngestor.onSaved = { [weak self] deviceID in
            guard let self, deviceID == self.device.id else { return }
            self.reloadReadings()
        }
        isObservingReadings = true
    }

    private func loadReadings() {
        do {
            let metrics = try readingsStore.availableMetrics(deviceID: device.id)
            readings.metrics = metrics
            if readings.selectedMetric == nil || !metrics.contains(readings.selectedMetric!) {
                readings.selectedMetric = metrics.first
            }
            reloadReadingsLocally()
        } catch {
            // 本地库读取失败时保持空状态；宁可不展示，也不造假数据。
            readings.metrics = []
            readings.selectedMetric = nil
            readings.points = []
            readings.recent = []
            readings.summary = nil
        }
    }

    private func reloadReadingsLocally() {
        guard let metric = readings.selectedMetric else {
            readings.points = []
            readings.recent = []
            readings.summary = nil
            return
        }
        let recent = (try? readingsStore.fetchRecent(deviceID: device.id, metric: metric, limit: 60)) ?? []
        readings.points = recent.reversed()
        readings.recent = Array(recent.prefix(20))

        let since = Date().addingTimeInterval(-24 * 60 * 60)
        let window = (try? readingsStore.fetch(deviceID: device.id, metric: metric, from: since)) ?? []
        readings.summary = ReadingSummary.local(readings: window, metric: metric, since: since)
    }

    /// 优先展示云端 24h 汇总；失败时回退本地汇总，并标注「离线：本地数据」。
    private func refreshSummaryFromCloud() {
        guard let metric = readings.selectedMetric else { return }
        readings.isLoading = true
        readingsService.fetchSummary(
            platform: device.platform,
            externalID: device.externalID,
            metric: metric,
            hours: 24
        ) { [weak self] result in
            guard let self, self.readings.selectedMetric == metric else { return }
            self.readings.isLoading = false
            switch result {
            case .success(let summary):
                self.readings.summary = summary
                self.readings.isSummaryFromCloud = true
                self.readings.isOfflineLocalData = false
            case .failure:
                self.readings.isSummaryFromCloud = false
                self.readings.isOfflineLocalData = !self.readings.points.isEmpty
                let since = Date().addingTimeInterval(-24 * 60 * 60)
                let window = (try? self.readingsStore.fetch(
                    deviceID: self.device.id,
                    metric: metric,
                    from: since
                )) ?? []
                self.readings.summary = ReadingSummary.local(readings: window, metric: metric, since: since)
            }
        }
    }

    func selectReadingsMetric(_ metric: ReadingMetric) {
        guard readings.metrics.contains(metric), metric != readings.selectedMetric else { return }
        readings.selectedMetric = metric
        reloadReadingsLocally()
        refreshSummaryFromCloud()
    }

    /// 新读数落库后刷新本地列表与汇总。
    func reloadReadings() {
        loadReadings()
        refreshSummaryFromCloud()
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
