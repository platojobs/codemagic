import Foundation

/// 设备详情视图模型：连接蓝牙 → 拉取设备信息 → 网络失败降级本地缓存；同时展示本地/云端读数。
final class DeviceDetailViewModel {
    enum State: Equatable {
        case idle
        case connecting
        case loadingInfo
        case loaded(ProductModel)
        case cache(ProductModel, fetchedAt: Date, error: AppError)
        case failed(AppError)
    }

    /// 「数据」区状态：指标清单来自服务端（离线时回退本地），图表按所选区间分桶。
    struct ReadingsState: Equatable {
        var metricInfos: [ReadingMetricInfo] = []
        var selectedMetric: ReadingMetric?
        var selectedRange: ReadingsRange = .hour24
        var buckets: [ReadingsChartBucket] = []
        var interval: DateInterval = ReadingsRange.hour24.interval()
        var points: [DeviceReading] = []
        var recent: [DeviceReading] = []
        var summary: ReadingSummary?
        var unit: String = ""
        var isSummaryFromCloud = false
        var isSeriesFromCloud = false
        var isOfflineLocalData = false
        var isLoading = false

        var metrics: [ReadingMetric] { metricInfos.map(\.readingMetric) }
        var hasData: Bool { !buckets.isEmpty }
        var metricCount: Int { buckets.reduce(0) { $0 + $1.count } }

        /// 数据来源说明；30 天区间离线时明确标注本地只有 7 天。
        var sourceText: String {
            if isLoading { return "读取中…" }
            if isOfflineLocalData {
                return selectedRange == .day30 ? "离线：仅本地 7 天数据" : "离线：本地数据"
            }
            if isSeriesFromCloud { return "云端分桶序列" }
            if isSummaryFromCloud { return "云端汇总" }
            return "本地数据"
        }
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

    /// 指标选择行文案：服务端真值优先，展示「指标名 · N 条」。
    func metricTitle(for metric: ReadingMetric) -> String {
        let count = readings.metricInfos.first { $0.readingMetric == metric }?.count ?? 0
        return count > 0 ? "\(metric.displayName) · \(count) 条" : metric.displayName
    }

    private func observeNewReadings() {
        guard let readingsIngestor else { return }
        readingsIngestor.onSaved = { [weak self] deviceID in
            guard let self, deviceID == self.device.id else { return }
            self.reloadReadings()
        }
        isObservingReadings = true
    }

    /// 先本地渲染（保证离线/冷启动也有数据），再拉服务端指标清单与分桶序列。
    private func loadReadings() {
        applyLocalMetricInfos()
        reloadReadingsLocally()
        refreshMetricsFromCloud()
    }

    private func applyLocalMetricInfos() {
        let infos = (try? readingsStore.metricInfos(deviceID: device.id)) ?? []
        readings.metricInfos = infos
        let metrics = infos.map(\.readingMetric)
        if let selected = readings.selectedMetric, metrics.contains(selected) {
            return
        }
        readings.selectedMetric = metrics.first
    }

    /// 本地渲染：图表用本地分桶，汇总用本地 24 小时窗口；不伪造任何数据。
    private func reloadReadingsLocally() {
        applyLocalSeries()

        guard let metric = readings.selectedMetric else {
            readings.points = []
            readings.recent = []
            readings.summary = nil
            readings.unit = ""
            return
        }

        let recent = (try? readingsStore.fetchRecent(deviceID: device.id, metric: metric, limit: 60)) ?? []
        readings.points = recent.reversed()
        readings.recent = Array(recent.prefix(20))

        let since = Date().addingTimeInterval(-24 * 60 * 60)
        let window = (try? readingsStore.fetch(deviceID: device.id, metric: metric, from: since)) ?? []
        readings.summary = ReadingSummary.local(readings: window, metric: metric, since: since)
        if readings.unit.isEmpty {
            readings.unit = readings.summary?.unit ?? metric.defaultUnit
        }
    }

    /// 用与后端一致的 UTC 分桶规则聚合本地数据；时间轴保持所选区间，缺失天数留白。
    private func applyLocalSeries() {
        guard let metric = readings.selectedMetric else {
            readings.buckets = []
            readings.interval = readings.selectedRange.interval()
            return
        }
        let interval = readings.selectedRange.interval()
        let window = (try? readingsStore.fetch(
            deviceID: device.id,
            metric: metric,
            from: interval.start,
            to: interval.end
        )) ?? []
        let series = ReadingsSeries.local(readings: window, range: readings.selectedRange)
        readings.buckets = series.chartBuckets
        readings.interval = series.interval.duration > 0 ? series.interval : interval
        if readings.unit.isEmpty, let latest = window.last {
            readings.unit = latest.unit
        }
    }

    /// 指标清单以服务端为准（count / lastAt / unit）；服务端为空而本地有待同步读数时保留本地，避免数据看不见。
    private func refreshMetricsFromCloud() {
        readings.isLoading = true
        readingsService.fetchMetrics(
            platform: device.platform,
            externalID: device.externalID
        ) { [weak self] result in
            guard let self else { return }
            self.readings.isLoading = false
            switch result {
            case .success(let metrics):
                let remote = ReadingMetricInfo.sortedByLastAt(metrics.items)
                let local = (try? self.readingsStore.metricInfos(deviceID: self.device.id)) ?? []
                self.readings.metricInfos = remote.isEmpty ? local : remote
                let available = self.readings.metricInfos.map(\.readingMetric)
                if let selected = self.readings.selectedMetric, available.contains(selected) {
                    // 保留用户选择
                } else {
                    self.readings.selectedMetric = available.first
                }
                if let selected = self.readings.selectedMetric {
                    let info = self.readings.metricInfos.first { $0.readingMetric == selected }
                    if let unit = info?.unit, !unit.isEmpty {
                        self.readings.unit = unit
                    }
                }
                self.reloadReadingsLocally()
                self.refreshSeriesFromCloud()
                self.refreshSummaryFromCloud()

            case .failure:
                // 离线兜底：本地指标清单与本地分桶，明确标注离线。
                self.applyLocalMetricInfos()
                self.reloadReadingsLocally()
                self.readings.isSeriesFromCloud = false
                self.readings.isOfflineLocalData = true
            }
        }
    }

    /// 分桶序列：区间切换后重新查询；失败回退本地（30 天区间只覆盖本地 7 天）。
    private func refreshSeriesFromCloud() {
        guard let metric = readings.selectedMetric else {
            readings.buckets = []
            return
        }
        let range = readings.selectedRange
        let interval = range.interval()
        readingsService.fetchSeries(
            platform: device.platform,
            externalID: device.externalID,
            metric: metric,
            from: interval.start,
            to: interval.end,
            bucket: range.bucket
        ) { [weak self] result in
            guard let self,
                  self.readings.selectedMetric == metric,
                  self.readings.selectedRange == range
            else { return }
            switch result {
            case .success(let series):
                self.readings.buckets = series.chartBuckets
                self.readings.interval = series.interval.duration > 0 ? series.interval : interval
                if !series.unit.isEmpty {
                    self.readings.unit = series.unit
                } else if let info = self.currentMetricInfo(metric), !info.unit.isEmpty {
                    self.readings.unit = info.unit
                }
                self.readings.isSeriesFromCloud = true
                self.readings.isOfflineLocalData = false

            case .failure:
                self.applyLocalSeries()
                self.readings.isSeriesFromCloud = false
                self.readings.isOfflineLocalData = true
            }
        }
    }

    /// 24 小时汇总固定展示；失败时回退本地汇总，并标注「离线：本地数据」。
    private func refreshSummaryFromCloud() {
        guard let metric = readings.selectedMetric else { return }
        readingsService.fetchSummary(
            platform: device.platform,
            externalID: device.externalID,
            metric: metric,
            hours: 24
        ) { [weak self] result in
            guard let self, self.readings.selectedMetric == metric else { return }
            switch result {
            case .success(let summary):
                self.readings.summary = summary
                self.readings.isSummaryFromCloud = true
                if !summary.unit.isEmpty {
                    self.readings.unit = summary.unit
                }
            case .failure:
                self.readings.isSummaryFromCloud = false
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

    private func currentMetricInfo(_ metric: ReadingMetric) -> ReadingMetricInfo? {
        readings.metricInfos.first { $0.readingMetric == metric }
    }

    func selectReadingsMetric(_ metric: ReadingMetric) {
        guard readings.metrics.contains(metric), metric != readings.selectedMetric else { return }
        readings.selectedMetric = metric
        readings.unit = ""
        reloadReadingsLocally()
        refreshSeriesFromCloud()
        refreshSummaryFromCloud()
    }

    /// 切换区间：本地立即重绘，再按新 bucket 重新查询服务端。
    func selectReadingsRange(_ range: ReadingsRange) {
        guard range != readings.selectedRange, range.isSupportedByServer else { return }
        readings.selectedRange = range
        applyLocalSeries()
        refreshSeriesFromCloud()
    }

    /// 新读数落库后刷新本地列表、分桶与云端汇总。
    func reloadReadings() {
        loadReadings()
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
