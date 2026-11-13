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

    /// 详情页展示的信号读数：连接后来自定时 `readRSSI`，未连接时回退最近一次扫描。
    struct SignalReading: Equatable {
        enum Status: Equatable {
            /// 本机连接中，成功读到实时值。
            case live
            /// 未连接，展示最近一次扫描值。
            case lastScan
            /// 本机连接中但本次读取失败（含成功回调返回非法值），保留上一次值。
            case refreshFailed
            /// 本机连接中读取失败且从未成功过，无可用读数。
            case readFailed
            /// 无可用读数（未连接且无扫描记录）。
            case unknown
        }

        let rssi: Int?
        let readAt: Date?
        let status: Status

        static let unknown = SignalReading(rssi: nil, readAt: nil, status: .unknown)
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

    /// 详情页使用的联动状态：连接态来自真实 BLE 服务，与首页 / 房间详情 / 设备列表同源。
    var linkStatus: DeviceLinkStatus {
        DeviceLinkStatus.make(device: device, bluetooth: bluetooth)
    }

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
    private let householdService: HouseholdService?
    /// 最近一次扫描记录：详情页据此展示 dBm 与读数时间。
    private let recentDeviceStore: RecentDeviceStore?
    private let now: () -> Date
    private var currentSignalReading: SignalReading = .unknown
    private var signalTimer: Timer?
    /// 本机连接期间每 2 秒读取一次 RSSI，与 Android `readRemoteRssi()` 周期一致。
    static let signalRefreshInterval: TimeInterval = 2
    private(set) var isSignalPolling = false
    private var isSignalReadInFlight = false
    /// 每次停表递增，用于丢弃停表后才返回的在途 RSSI 回调，防止覆盖已回退的值。
    private var signalGeneration = 0
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
        householdService: HouseholdService? = nil,
        recentDeviceStore: RecentDeviceStore? = nil,
        now: @escaping () -> Date = Date.init,
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
        self.householdService = householdService
        self.recentDeviceStore = recentDeviceStore
        self.now = now
        self.refreshPolicy = refreshPolicy
        self.currentSignalReading = Self.makeLastScanReading(
            store: recentDeviceStore,
            peripheralID: device.peripheralID
        )
    }

    deinit {
        remoteRefreshWorkItem?.cancel()
        signalTimer?.invalidate()
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        loadReadings()
        observeNewReadings()

        guard device.isConnectable else {
            notice = device.connectUnavailableText
            // Android 等不可直连设备仍要展示服务端单设备详情，避免只看到本地缓存。
            fetchInfo()
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
        stopSignalPolling(resetToLastScan: true)
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
            // Android 等不可直连设备仍要展示服务端单设备详情，避免只看到本地缓存。
            fetchInfo()
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
            startSignalPolling()
            fetchInfo()

        case .failed(let peripheralID, let message) where peripheralID == device.peripheralID:
            notice = L10n.f("device.detail.bluetoothConnectFailed", String(describing: message))
            stopSignalPolling(resetToLastScan: true)
            fetchInfo()

        case .disconnected(let peripheralID, let message) where peripheralID == device.peripheralID:
            stopSignalPolling(resetToLastScan: true)
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
        productService.fetchDeviceInfo(device: device) { [weak self] result in
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

    // MARK: - Mark

    /// 详情行展示值：已标记时间 + 未同步时明确标注「待同步」，未标记显示「未标记」。
    var markValueText: String {
        guard let markedAt = device.markedAt else {
            return L10n.t("device.detail.notMarked")
        }
        let base = L10n.f("device.detail.markedAt", AppDateFormat.absolute(markedAt))
        return device.syncState == .synced ? base : "\(base) · \(L10n.t("sync.state.pending"))"
    }

    /// 标记 / 取消标记：先写本机并置待同步，由下一次 `POST /sync/push` 走字段级 LWW。
    /// 未登录或离线时不会假装已同步，界面继续显示「待同步」。
    func toggleMark() {
        let markedAt: Date? = device.markedAt == nil ? Date() : nil
        do {
            try savedDeviceStore.updateMark(id: device.id, markedAt: markedAt, at: Date())
            device.markedAt = markedAt
            device.markedAtPatch = markedAt == nil ? .clear : .set(markedAt ?? Date())
            device.updatedAt = Date()
            device.syncState = .pending
            onChange?()
        } catch {
            notice = L10n.f("device.detail.markFailed", String(describing: error))
        }
    }

    // MARK: - Rooms

    var canChangeRoom: Bool { roomStore != nil || householdService != nil }

    var roomName: String {
        guard let roomID = device.roomID, let room = availableRooms().first(where: { $0.id == roomID }) else {
            return L10n.t("room.unassigned")
        }
        return room.name
    }

    func availableRooms() -> [Room] {
        if let householdService {
            return householdService.visibleRooms()
        }
        return (try? roomStore?.fetchAll()) ?? []
    }

    /// 移入 / 移出房间：先落本机，再由 `HouseholdService` 用 PATCH 上报；
    /// 失败进入 pending，下次同步重试，403 / 404 转成可读提示。
    func updateRoom(_ roomID: UUID?) {
        let room = roomID.flatMap { target in availableRooms().first(where: { $0.id == target }) }
        guard let householdService else {
            guard let roomStore else { return }
            do {
                try savedDeviceStore.setRoom(id: device.id, roomID: roomID)
                device.roomID = roomID
                onChange?()
            } catch {
                notice = L10n.f("room.moveFailed", String(describing: error))
            }
            return
        }
        householdService.assignDevice(device, room: room) { [weak self] result in
            guard let self else { return }
            self.device.roomID = roomID
            if let message = result.errorMessage {
                self.notice = message
            }
            self.onChange?()
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
            // 页面退出 / 进后台时停表，避免定时器空转耗电；读数回退到最近扫描值。
            stopSignalPolling(resetToLastScan: true)
            return
        }
        if wasVisible {
            // 已在可见状态（回到前台）合并成一次刷新，避免前后台切换时请求风暴。
            scheduleRemoteRefresh(delay: 0)
        } else {
            performRemoteRefresh()
        }
        updateSignalPolling()
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

    // MARK: - Signal

    /// 详情页信号读数：连接中为实时值，未连接为最近扫描值。
    var signalReading: SignalReading { currentSignalReading }

    private static func makeLastScanReading(store: RecentDeviceStore?, peripheralID: UUID) -> SignalReading {
        guard let store,
              let recent = try? store.fetch(peripheralID: peripheralID),
              RSISignalView.isValid(recent.rssi)
        else {
            return .unknown
        }
        return SignalReading(rssi: recent.rssi, readAt: recent.lastSeenAt, status: .lastScan)
    }

    private func loadLastScanReading() -> SignalReading {
        Self.makeLastScanReading(store: recentDeviceStore, peripheralID: device.peripheralID)
    }

    /// 页面可见且本机已连接时启动 2 秒轮询；否则保持停止。
    private func updateSignalPolling() {
        guard isVisibleForReadings, DeviceLinkStatus.isConnected(device, bluetooth: bluetooth) else {
            stopSignalPolling()
            return
        }
        startSignalPolling()
    }

    func startSignalPolling() {
        guard isVisibleForReadings, DeviceLinkStatus.isConnected(device, bluetooth: bluetooth) else {
            stopSignalPolling()
            return
        }
        guard signalTimer == nil else {
            pollSignal()
            return
        }
        isSignalPolling = true
        // 立即读一次，避免连接后等满一个周期才从扫描值切到实时值。
        pollSignal()
        let timer = Timer(timeInterval: Self.signalRefreshInterval, repeats: true) { [weak self] _ in
            self?.pollSignal()
        }
        RunLoop.main.add(timer, forMode: .common)
        signalTimer = timer
    }

    func stopSignalPolling(resetToLastScan: Bool = false) {
        signalGeneration &+= 1
        signalTimer?.invalidate()
        signalTimer = nil
        isSignalPolling = false
        isSignalReadInFlight = false
        if resetToLastScan {
            let lastScan = loadLastScanReading()
            if lastScan != currentSignalReading {
                currentSignalReading = lastScan
                onChange?()
            }
        }
    }

    /// 读取一次 RSSI；断开时先停表，不再发起新请求。
    func pollSignal() {
        guard isSignalPolling, isVisibleForReadings else { return }
        guard DeviceLinkStatus.isConnected(device, bluetooth: bluetooth) else {
            stopSignalPolling(resetToLastScan: true)
            return
        }
        guard !isSignalReadInFlight else { return }
        isSignalReadInFlight = true
        let generation = signalGeneration
        bluetooth.readRSSI(peripheralID: device.peripheralID) { [weak self] result in
            guard let self, self.signalGeneration == generation else { return }
            self.isSignalReadInFlight = false
            self.handleSignalResult(result)
        }
    }

    private func handleSignalResult(_ result: Result<Int, Error>) {
        switch result {
        case .success(let rssi) where RSISignalView.isValid(rssi):
            currentSignalReading = SignalReading(rssi: rssi, readAt: now(), status: .live)

        case .success, .failure:
            // 成功回调返回非法值（0 / 127 / Int.min）与读取失败同口径：本质是坏数据，
            // 保留上一次成功读到的值并标记刷新失败；从未成功读过才显示读取失败且无读数。
            // 扫描值不算「成功读取」，不能冒充连接后的上次读数。
            if let rssi = currentSignalReading.rssi,
               let readAt = currentSignalReading.readAt,
               currentSignalReading.status == .live || currentSignalReading.status == .refreshFailed {
                currentSignalReading = SignalReading(rssi: rssi, readAt: readAt, status: .refreshFailed)
            } else {
                currentSignalReading = SignalReading(rssi: nil, readAt: nil, status: .readFailed)
            }
        }
        onChange?()
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
