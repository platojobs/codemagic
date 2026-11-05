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
        var isPendingLocalData = false
        var isLoading = false

        var metrics: [ReadingMetric] { metricInfos.map(\.readingMetric) }
        var hasData: Bool { !buckets.isEmpty }
        var metricCount: Int { buckets.reduce(0) { $0 + $1.count } }

        /// 数据来源说明；30 天区间离线时明确标注本地只有 7 天。
        var sourceText: String {
            if isLoading { return L10n.t("device.detail.loading") }
            if isPendingLocalData { return L10n.t("device.detail.sourcePending") }
            if isOfflineLocalData {
                return selectedRange == .day30 ? L10n.t("device.detail.sourceOffline7d") : L10n.t("device.detail.sourceOffline")
            }
            if isSeriesFromCloud { return L10n.t("device.detail.sourceCloudBuckets") }
            if isSummaryFromCloud { return L10n.t("device.detail.sourceCloudSummary") }
            return L10n.t("device.detail.sourceLocal")
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
    private let exportService: ReadingsExportService
    private let roomStore: RoomStore?
    private var refreshPolicy: ReadingsRefreshPolicy
    private var remoteRefreshWorkItem: DispatchWorkItem?
    /// 详情页是否可见；不可见时不发任何远端读数请求。
    private var isVisibleForReadings = false
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
        readingsIngestor: ReadingsIngestor? = nil,
        exportService: ReadingsExportService? = nil,
        roomStore: RoomStore? = nil,
        refreshPolicy: ReadingsRefreshPolicy = ReadingsRefreshPolicy()
    ) {
        self.device = device
        self.bluetooth = bluetooth
        self.productService = productService
        self.cacheStore = cacheStore
        self.savedDeviceStore = savedDeviceStore
        self.readingsStore = readingsStore
        self.readingsService = readingsService
        self.readingsIngestor = readingsIngestor
        self.exportService = exportService ?? ReadingsExportService(
            readingsStore: readingsStore,
            readingsService: readingsService
        )
        self.roomStore = roomStore
        self.refreshPolicy = refreshPolicy
    }

    deinit {
        remoteRefreshWorkItem?.cancel()
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
            notice = L10n.f("device.detail.bluetoothUnavailable", String(describing: bluetooth.state.title))
            fetchInfo()
            return
        }

        state = .connecting
        bluetooth.connect(peripheralID: device.peripheralID)
    }

    func teardown() {
        remoteRefreshWorkItem?.cancel()
        remoteRefreshWorkItem = nil
        isVisibleForReadings = false
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
            notice = L10n.f("device.detail.bluetoothUnavailable", String(describing: bluetooth.state.title))
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
            notice = L10n.t("device.detail.bluetoothReading")
            bluetooth.startReading(peripheralID: device.peripheralID)
            fetchInfo()

        case .failed(let peripheralID, let message) where peripheralID == device.peripheralID:
            notice = L10n.f("device.detail.bluetoothConnectFailed", String(describing: message))
            fetchInfo()

        case .disconnected(let peripheralID, let message) where peripheralID == device.peripheralID:
            if state == .connecting || state == .loadingInfo {
                notice = L10n.f("device.detail.bluetoothDisconnected", message ?? L10n.t("common.unknownReason"))
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

    // MARK: - Rooms

    var canChangeRoom: Bool { roomStore != nil }

    var roomName: String {
        guard let roomID = device.roomID, let room = availableRooms().first(where: { $0.id == roomID }) else {
            return L10n.t("room.unassigned")
        }
        return room.name
    }

    func availableRooms() -> [Room] {
        (try? roomStore?.fetchAll()) ?? []
    }

    /// 移入 / 移出房间：仅改本机 `room_id`，不置同步状态。
    func updateRoom(_ roomID: UUID?) {
        guard let roomStore else { return }
        do {
            try savedDeviceStore.setRoom(id: device.id, roomID: roomID)
            device.roomID = roomID
            onChange?()
        } catch {
            notice = L10n.f("room.moveFailed", String(describing: error))
        }
    }

    // MARK: - Readings

    /// 无读数时的真实空状态文案；蓝牙未授权时指向系统设置。
    var readingsEmptyMessage: String {
        switch bluetooth.currentAuthorization() {
        case .denied, .restricted:
            return L10n.t("device.detail.bluetoothUnauthorized")
        case .notDetermined:
            return L10n.t("device.detail.connectToCollect")
        case .allowed, .unknown:
            return L10n.t("device.detail.connectToCollectShort")
        }
    }

    var canConnectForReadings: Bool { device.isConnectable }

    /// 指标选择行文案：服务端真值优先，展示「指标名 · N 条」。
    func metricTitle(for metric: ReadingMetric) -> String {
        let count = readings.metricInfos.first { $0.readingMetric == metric }?.count ?? 0
        return count > 0 ? L10n.f("device.detail.metricCount", String(describing: metric.displayName), String(describing: count)) : metric.displayName
    }

    private func observeNewReadings() {
        guard let readingsIngestor else { return }
        readingsIngestor.onSaved = { [weak self] deviceID in
            guard let self, deviceID == self.device.id else { return }
            self.reloadReadings()
        }
        isObservingReadings = true
    }

    /// 详情页可见性：不可见时取消排队中的远端刷新、不发请求；回到前台/页面再刷新一次。
    func setVisible(_ visible: Bool) {
        let wasVisible = isVisibleForReadings
        isVisibleForReadings = visible
        guard visible else {
            remoteRefreshWorkItem?.cancel()
            remoteRefreshWorkItem = nil
            return
        }
        if wasVisible {
            // 已在可见状态（回到前台）合并成一次刷新，避免前后台切换时请求风暴。
            scheduleRemoteRefresh(delay: 0)
        } else {
            performRemoteRefresh()
        }
    }

    /// 读数入库不直接联网：只做本地增量重绘，远端查询按 800ms 去抖动合并。
    private func loadReadings() {
        applyLocalMetricInfos()
        reloadReadingsLocally()
        scheduleRemoteRefresh()
    }

    private func scheduleRemoteRefresh(delay: TimeInterval? = nil) {
        guard isVisibleForReadings else { return }
        remoteRefreshWorkItem?.cancel()
        let wait = delay ?? refreshPolicy.nextDelay
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isVisibleForReadings else { return }
            self.performRemoteRefresh()
        }
        remoteRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    /// 一次合并刷新：metrics、series、summary 并发发出，且共享同一次区间计算（同一 from/to）。
    private func performRemoteRefresh() {
        let anchor = Date()
        let interval = readings.selectedRange.interval(now: anchor)
        // 先发序列 / 汇总（已有默认指标时各一次），最后刷清单；
        // 清单为空时由它的完成回调补发一次序列 / 汇总，避免重复请求。
        refreshSeriesFromCloud(interval: interval)
        refreshSummaryFromCloud(anchor: anchor)
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
                self.refreshPolicy.recordSuccess()
                let remote = ReadingMetricInfo.sortedByLastAt(metrics.items)
                let local = (try? self.readingsStore.metricInfos(deviceID: self.device.id)) ?? []
                let pending = (try? self.readingsStore.pendingCount(deviceID: self.device.id)) ?? 0

                // 服务端还没有这些读数（本地待同步）时，清单与序列都走本地，不能让图表空着。
                if remote.isEmpty && (!local.isEmpty || pending > 0) {
                    self.readings.metricInfos = local
                    self.selectAvailableMetricIfNeeded()
                    self.readings.isPendingLocalData = true
                    self.readings.isOfflineLocalData = false
                    self.reloadReadingsLocally()
                    return
                }

                self.readings.isPendingLocalData = false
                let previousSelection = self.readings.selectedMetric
                self.readings.metricInfos = remote.isEmpty ? local : remote
                self.selectAvailableMetricIfNeeded()
                if let selected = self.readings.selectedMetric {
                    let info = self.readings.metricInfos.first { $0.readingMetric == selected }
                    if let unit = info?.unit, !unit.isEmpty {
                        self.readings.unit = unit
                    }
                }
                self.reloadReadingsLocally()
                // 只有默认指标刚确定时才补发序列/汇总；否则本轮已由 performRemoteRefresh 并发发出。
                if previousSelection != self.readings.selectedMetric {
                    self.refreshSeriesFromCloud()
                    self.refreshSummaryFromCloud()
                }

            case .failure:
                // 离线兜底：本地指标清单与本地分桶，明确标注离线，并按指数退避重试。
                self.refreshPolicy.recordFailure()
                self.applyLocalMetricInfos()
                self.reloadReadingsLocally()
                self.readings.isSeriesFromCloud = false
                self.readings.isOfflineLocalData = true
                self.scheduleRemoteRefresh()
            }
        }
    }

    private func selectAvailableMetricIfNeeded() {
        let available = readings.metricInfos.map(\.readingMetric)
        if let selected = readings.selectedMetric, available.contains(selected) {
            return
        }
        readings.selectedMetric = available.first
    }

    /// 分桶序列：区间切换后重新查询；失败回退本地（30 天区间只覆盖本地 7 天）。
    private func refreshSeriesFromCloud(interval requestedInterval: DateInterval? = nil) {
        guard isVisibleForReadings else { return }
        guard let metric = readings.selectedMetric else {
            readings.buckets = []
            return
        }
        let range = readings.selectedRange
        let interval = requestedInterval ?? range.interval()
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
                  self.readings.selectedRange == range,
                  !self.readings.isPendingLocalData
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
                self.refreshPolicy.recordFailure()
                self.applyLocalSeries()
                self.readings.isSeriesFromCloud = false
                self.readings.isOfflineLocalData = true
                self.scheduleRemoteRefresh()
            }
        }
    }

    /// 24 小时汇总固定展示；失败时回退本地汇总，并标注「离线：本地数据」。
    private func refreshSummaryFromCloud(anchor: Date? = nil) {
        guard isVisibleForReadings else { return }
        guard let metric = readings.selectedMetric else { return }
        readingsService.fetchSummary(
            platform: device.platform,
            externalID: device.externalID,
            metric: metric,
            hours: 24
        ) { [weak self] result in
            guard let self, self.readings.selectedMetric == metric, !self.readings.isPendingLocalData else { return }
            switch result {
            case .success(let summary):
                self.readings.summary = summary
                self.readings.isSummaryFromCloud = true
                if !summary.unit.isEmpty {
                    self.readings.unit = summary.unit
                }
            case .failure:
                self.refreshPolicy.recordFailure()
                self.readings.isSummaryFromCloud = false
                let since = (anchor ?? Date()).addingTimeInterval(-24 * 60 * 60)
                let window = (try? self.readingsStore.fetch(
                    deviceID: self.device.id,
                    metric: metric,
                    from: since
                )) ?? []
                self.readings.summary = ReadingSummary.local(readings: window, metric: metric, since: since)
                self.scheduleRemoteRefresh()
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

    /// 新读数落库后只做本地增量重绘，远端查询交给去抖动调度器。
    func reloadReadings() {
        applyLocalMetricInfos()
        reloadReadingsLocally()
        scheduleRemoteRefresh()
    }

    // MARK: - Export

    /// 导出当前设备 + 指标 + 区间的读数 CSV；进度回调始终在主线程。
    func exportReadings(
        range: ReadingsRange,
        metric: ReadingMetric,
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, ReadingsExportError>) -> Void
    ) {
        exportService.export(
            device: device,
            metric: metric,
            range: range,
            progress: progress,
            completion: completion
        )
    }

    /// 分享结束后删除临时 CSV，避免长期留存。
    func removeExportedFile(at url: URL) {
        exportService.removeExportedFile(at: url)
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
        case .idle: return L10n.t("device.detail.notRead")
        case .connecting: return L10n.t("device.detail.connecting")
        case .loadingInfo: return L10n.t("device.detail.readingInfoProgress")
        case .loaded: return L10n.t("device.detail.infoUpdated")
        case .cache(_, let fetchedAt, let error):
            return L10n.f("device.detail.infoNetworkFallback", String(describing: error.code), String(describing: AppDateFormat.absolute(fetchedAt)))
        case .failed(let error):
            return error.localizedDescriptionText
        }
    }

    var isLoading: Bool {
        state == .connecting || state == .loadingInfo
    }
}
