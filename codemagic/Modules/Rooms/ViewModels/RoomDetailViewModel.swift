import Foundation

/// 房间详情中的一台设备：名称、在线状态与最新一条真实读数。
struct RoomDetailEntry: Equatable {
    let device: SavedDevice
    /// 统一的四档联动状态：本机 BLE 连接优先，其次服务端按 `lastSeenAt` 推导的上报状态。
    let linkStatus: DeviceLinkStatus
    /// 计算相对时间用的基准时刻，页面内所有条目共用。
    let now: Date
    /// 服务端按 `lastSeenAt` 推导的上报状态（契约 0.21.0），只读。
    var presence: DevicePresence { linkStatus.presence }
    /// 本机 SQLite 中的最新读数；有则优先展示。
    let reading: DeviceReading?
    /// 云端最近读数状态；`nil` 表示未接入云端读数服务。
    let cloudReading: CloudLatestReadingState?

    var readingText: String {
        if let reading {
            // 数值与单位之间用不换行空格，避免大字号下 “24.5” 与 “℃” 被拆到两行。
            let value = reading.displayText.replacingOccurrences(of: " ", with: "\u{00A0}")
            return "\(reading.metric.displayName)\u{00A0}\(value)"
        }
        switch cloudReading {
        case .available(let cloud)?:
            let value = cloud.displayText.replacingOccurrences(of: " ", with: "\u{00A0}")
            return "\(cloud.metricTitle)\u{00A0}\(value)"
        case .failed?:
            // 拉不到 ≠ 没有读数，明确写数据来源不可用，不显示成「暂无读数」或设备离线。
            return L10n.t("room.detail.cloudUnavailable")
        case .loading?:
            return L10n.t("room.detail.readingLoading")
        case .empty?, nil:
            // 本机与云端都确认没有读数时才显示「暂无读数」。
            return L10n.t("room.detail.noReading")
        }
    }

    /// 本机可连接时用统一四档标题；跨平台设备如实说明来源边界。
    var statusText: String {
        guard device.isConnectable else {
            return device.connectUnavailableText ?? linkStatus.notConnectableText
        }
        return linkStatus.title
    }

    /// 第二行：云端是否超时 / 最近上报时间；跨平台设备与「本机不可连接」同时呈现，互不遮蔽。
    var presenceNote: String? {
        linkStatus.secondaryText(
            connectable: device.isConnectable,
            serverLastSeenAt: device.serverLastSeenAt,
            localLastSeenAt: device.lastSeenAt,
            now: now
        )
    }

    /// AX 档用的状态文案：跨平台说明在「来自 X」后显式换行，
    /// 避免最大字号下「本机不可连接」被拆成「本 / 机不可连接」。
    var statusTextForAccessibility: String {
        guard device.isConnectable else {
            return L10n.f("device.remoteOnlyAX", String(describing: device.platformDisplayName))
        }
        return linkStatus.title
    }

    /// 使用云端读数时标注上报时间，说明数据来源；本机读数不追加。
    var cloudNote: String? {
        guard reading == nil, case .available(let cloud)? = cloudReading else { return nil }
        return L10n.f("room.detail.cloudReported", RelativeTimeText.short(for: cloud.reportedAt, relativeTo: now))
    }

    /// 标记状态：已标记 / 已标记 · 待同步 / 已取消标记 · 待同步；未标记且无待上传变更时为 nil。
    var markText: String? {
        switch device.markedAtPatch {
        case .set:
            return L10n.t("device.markedPending")
        case .clear:
            return L10n.t("room.detail.unmarkPending")
        case .absent:
            return device.markedAt == nil ? nil : L10n.t("device.marked")
        }
    }
}

/// 房间详情聚合视图：设备列表来自本机 SQLite 与服务端同步落地的同一份 `saved_devices`；
/// 读数优先取本机，本机没有时查询服务端按设备读数接口。
///
/// 状态判定与首页共用 `DeviceLinkStatus`：本机 BLE 已连接为第一档，其次才是服务端
/// `presence`（按 `lastSeenAt` 与 900 秒窗口推导）。服务端 `online` 只表示
/// 「最近 15 分钟有读数上报」，界面写成「云端 15 分钟内有上报」，不包装成权威的在线绿灯；
/// `unknown`（从未上报）单独一档，不并进「上报超时」。跨平台设备的「本机不可连接」
/// 是附加说明，与云端状态同时呈现。
final class RoomDetailViewModel {

    private(set) var room: Room
    private(set) var entries: [RoomDetailEntry] = []
    private(set) var canManageRooms = true
    /// 最近一次操作结果（成功文案或失败原因）；界面以提示条展示，不清空历史数据。
    private(set) var notice: String?

    var onChange: (() -> Void)?

    private let roomStore: RoomStore
    private let deviceStore: SavedDeviceStore
    private let readingsStore: ReadingsStore
    private let bluetooth: BluetoothServicing
    private let householdService: HouseholdService?
    private let syncEngine: SyncEngine?
    private let cloudReadings: CloudLatestReadingsProviding?
    private let now: () -> Date

    private var roomDevices: [SavedDevice] = []
    private var cloudStates: [UUID: CloudLatestReadingState] = [:]

    init(
        room: Room,
        roomStore: RoomStore,
        deviceStore: SavedDeviceStore,
        readingsStore: ReadingsStore,
        bluetooth: BluetoothServicing,
        householdService: HouseholdService? = nil,
        syncEngine: SyncEngine? = nil,
        cloudReadings: CloudLatestReadingsProviding? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.room = room
        self.roomStore = roomStore
        self.deviceStore = deviceStore
        self.readingsStore = readingsStore
        self.bluetooth = bluetooth
        self.householdService = householdService
        self.syncEngine = syncEngine
        self.cloudReadings = cloudReadings
        self.now = now
    }

    var totalCount: Int { entries.count }
    /// BLE 真实连接的数量。
    var localConnectedCount: Int { entries.filter { $0.linkStatus.tier == .localConnected }.count }
    /// 服务端最近 15 分钟有读数上报的数量（只代表上报窗口，不代表设备当前连接着）。
    var cloudRecentCount: Int { entries.filter { $0.linkStatus.tier == .cloudRecent }.count }
    /// 曾上报读数但已超出上报窗口的数量。
    var cloudStaleCount: Int { entries.filter { $0.linkStatus.tier == .cloudStale }.count }
    /// 服务端从未收到过读数的数量：单独一档，不并进「上报超时」。
    var cloudUnknownCount: Int { entries.filter { $0.linkStatus.tier == .cloudUnknown }.count }
    /// 跨平台设备数量：附加的本机连接说明，不占独立档位。
    var remoteCount: Int { entries.filter { !$0.device.isConnectable }.count }
    var markedCount: Int { entries.filter { $0.device.markedAt != nil }.count }
    /// 标记 / 取消标记已写本机但尚未 push 的数量。
    var pendingMarkCount: Int { entries.filter { $0.device.markedAtPatch != .absent }.count }
    var canMark: Bool { entries.contains { $0.device.markedAt == nil } }
    var canUnmark: Bool { entries.contains { $0.device.markedAt != nil } }
    var isEmpty: Bool { entries.isEmpty }

    var summaryText: String {
        L10n.f(
            "room.detail.summary",
            String(totalCount), String(localConnectedCount), String(cloudRecentCount),
            String(cloudStaleCount), String(cloudUnknownCount),
            String(markedCount), String(remoteCount)
        )
    }

    var pendingHint: String? {
        guard pendingMarkCount > 0 else { return nil }
        return L10n.f("room.detail.pendingHint", String(pendingMarkCount))
    }

    /// 成员家庭只读：房间的新建 / 改名 / 排序 / 删除仅 owner 可用，进页即说明，避免点进去才 403。
    var readOnlyNote: String? {
        canManageRooms ? nil : L10n.t("room.detail.readonlyNote")
    }

    func reload() {
        if let latest = try? roomStore.fetch(id: room.id), !latest.isDeleted {
            room = latest
        }

        do {
            let household = householdService?.currentHousehold()
            canManageRooms = household?.canManageRooms ?? true
            roomDevices = try deviceStore.fetchAll().filter { device in
                guard device.roomID == room.id else { return false }
                guard let household else { return true }
                guard let deviceHousehold = device.householdID else { return household.isPersonal }
                return deviceHousehold == household.id
            }
            rebuildEntries()
        } catch {
            notice = L10n.f("room.detail.loadFailed", error.localizedDescription)
        }
        onChange?()
        requestCloudReadings()
    }

    private func rebuildEntries() {
        let now = self.now()
        entries = roomDevices.map { device in
            let reading = try? readingsStore.latestReading(deviceID: device.id)
            let presence = device.presence(at: now)
            let linkStatus = DeviceLinkStatus(
                isConnected: Self.isConnected(device, bluetooth: bluetooth),
                presence: presence
            )
            let cloudReading: CloudLatestReadingState?
            if cloudReadings == nil {
                cloudReading = nil
            } else if let state = cloudStates[device.id] {
                cloudReading = state
            } else if presence == .unknown || reading != nil {
                // 从未上报或本机已有读数时不会发起云端请求，也不显示「正在读取」。
                cloudReading = .empty
            } else {
                cloudReading = .loading
            }
            return RoomDetailEntry(
                device: device,
                linkStatus: linkStatus,
                now: now,
                reading: reading,
                cloudReading: cloudReading
            )
        }.sorted { lhs, rhs in
            if lhs.linkStatus.sortRank != rhs.linkStatus.sortRank {
                return lhs.linkStatus.sortRank < rhs.linkStatus.sortRank
            }
            let leftName = lhs.device.displayName
            let rightName = rhs.device.displayName
            if leftName != rightName { return leftName < rightName }
            return lhs.device.id.uuidString < rhs.device.id.uuidString
        }
    }

    /// 逐台补云端最近读数；结果在主队列回调，只重建条目，不重复发起整页刷新。
    ///
    /// `presence = unknown` 表示服务端从未接受过该设备读数，再查 `metrics + limit=1`
    /// 只是白跑两次往返；本机已有读数时界面也本机优先，同样跳过。
    private func requestCloudReadings() {
        guard let cloudReadings else { return }
        let timestamp = now()
        for device in roomDevices {
            guard device.presence(at: timestamp) != .unknown else { continue }
            guard (try? readingsStore.latestReading(deviceID: device.id)) == nil else { continue }
            cloudReadings.latestReading(platform: device.platform, externalID: device.externalID) { [weak self] state in
                guard let self, self.cloudStates[device.id] != state else { return }
                self.cloudStates[device.id] = state
                self.rebuildEntries()
                self.onChange?()
            }
        }
    }

    /// 批量标记房间内尚未标记的设备；先落本机（标记 + 待同步），再触发 push。
    func markAll() {
        apply(markedAt: now(), to: entries.filter { $0.device.markedAt == nil }.map(\.device.id))
    }

    /// 批量取消房间内已标记的设备；本地先清空并保留 `clear` 三态，push 未成功前显示待同步。
    func unmarkAll() {
        apply(markedAt: nil, to: entries.filter { $0.device.markedAt != nil }.map(\.device.id))
    }

    private func apply(markedAt: Date?, to ids: [UUID]) {
        guard !ids.isEmpty else { return }
        do {
            try deviceStore.updateMark(ids: ids, markedAt: markedAt, at: now())
            notice = markedAt == nil
                ? L10n.f("room.detail.unmarkDone", String(ids.count))
                : L10n.f("room.detail.markDone", String(ids.count))
            reload()
        } catch {
            notice = L10n.f("room.detail.markFailed", error.localizedDescription)
            onChange?()
            return
        }
        syncPending()
    }

    private func syncPending() {
        guard let syncEngine else { return }
        syncEngine.sync { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure = result {
                    self.notice = L10n.t("room.detail.syncPendingNotice")
                }
                self.reload()
            }
        }
    }

    /// 本机连接判定：只有本机可连接的 iOS 设备才查询 CoreBluetooth。
    /// 与首页共用同一口径，不再把「15 分钟内本机扫描到」额外算作在线。
    static func isConnected(_ device: SavedDevice, bluetooth: BluetoothServicing) -> Bool {
        DeviceLinkStatus.isConnected(device, bluetooth: bluetooth)
    }
}
