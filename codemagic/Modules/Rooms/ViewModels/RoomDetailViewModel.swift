import Foundation

/// 房间详情中的一台设备：名称、在线状态与最新一条真实读数。
struct RoomDetailEntry: Equatable {
    let device: SavedDevice
    /// 本机依据：CoreBluetooth 已连接，或本机最近 15 分钟内扫描到过。
    let isOnline: Bool
    /// 服务端按 `lastSeenAt` 推导的上报状态（契约 0.21.0），只读。
    let presence: DevicePresence
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

    /// 本机有依据时用本机状态；否则用服务端上报状态，且不把推导结果说成「在线」。
    var statusText: String {
        if isOnline { return L10n.t("room.detail.online") }
        if !device.isConnectable { return device.connectUnavailableText ?? L10n.t("room.detail.remoteOnlyShort") }
        switch presence {
        case .online:
            guard let serverLastSeenAt = device.serverLastSeenAt else {
                return L10n.t("device.presence.reported")
            }
            return L10n.f("room.detail.lastReported", RelativeTimeText.short(for: serverLastSeenAt))
        case .offline:
            guard let serverLastSeenAt = device.serverLastSeenAt else {
                return L10n.t("device.presence.offline")
            }
            return L10n.f("room.detail.offlineWithTime", RelativeTimeText.short(for: serverLastSeenAt))
        case .unknown:
            return L10n.t("device.presence.unknown")
        }
    }

    /// 跨平台设备的状态行只说「本机不可连接」，再用一条附带说明给出最近上报 / 从未上报。
    var presenceNote: String? {
        guard !isOnline, !device.isConnectable else { return nil }
        guard let serverLastSeenAt = device.serverLastSeenAt else {
            return L10n.t("device.presence.unknown")
        }
        if presence == .offline {
            return L10n.f("room.detail.offlineWithTime", RelativeTimeText.short(for: serverLastSeenAt))
        }
        return L10n.f("room.detail.lastReported", RelativeTimeText.short(for: serverLastSeenAt))
    }

    /// AX 档用的状态文案：跨平台说明在「来自 X」后显式换行，
    /// 避免最大字号下「本机不可连接」被拆成「本 / 机不可连接」。
    var statusTextForAccessibility: String {
        if isOnline { return L10n.t("room.detail.online") }
        if device.isConnectable { return statusText }
        return L10n.f("device.remoteOnlyAX", String(describing: device.platformDisplayName))
    }

    /// 使用云端读数时标注上报时间，说明数据来源；本机读数不追加。
    var cloudNote: String? {
        guard reading == nil, case .available(let cloud)? = cloudReading else { return nil }
        return L10n.f("room.detail.cloudReported", RelativeTimeText.short(for: cloud.reportedAt))
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
/// 在线判定：本机 BLE 优先（已连接，或最近 15 分钟内扫描到），其次才是服务端
/// `presence`（按 `lastSeenAt` 与 900 秒窗口推导）。服务端 `online` 只表示
/// 「最近 15 分钟有读数上报」，界面写成「最近上报」，不包装成权威的在线绿灯；
/// `unknown`（从未上报）单独一档，不并进离线。
final class RoomDetailViewModel {
    private static let onlineWindow: TimeInterval = 15 * 60

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
    /// 本机有真实连接 / 最近扫描依据的在线数。
    var onlineCount: Int { entries.filter(\.isOnline).count }
    /// 本机没有依据、但服务端 `presence = online` 的数量（只代表最近 15 分钟有读数上报）。
    var reportedCount: Int { entries.filter { !$0.isOnline && $0.presence == .online }.count }
    /// 本机没有依据、且服务端显示已超出上报窗口的数量；不含 `unknown`。
    var presenceOfflineCount: Int { entries.filter { !$0.isOnline && $0.presence == .offline }.count }
    /// 服务端从未收到过读数的数量：单独一档，不并进离线。
    var neverReportedCount: Int { entries.filter { !$0.isOnline && $0.presence == .unknown }.count }
    /// 跨平台设备数量：本机没有在线判定依据，单独计数，不计入「离线」。
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
            String(totalCount), String(onlineCount), String(reportedCount),
            String(presenceOfflineCount), String(neverReportedCount),
            String(remoteCount), String(markedCount)
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
        let onlineSince = now.addingTimeInterval(-Self.onlineWindow)
        entries = roomDevices.map { device in
            RoomDetailEntry(
                device: device,
                isOnline: Self.isOnline(device, bluetooth: bluetooth, onlineSince: onlineSince),
                presence: device.presence(at: now),
                reading: try? readingsStore.latestReading(deviceID: device.id),
                cloudReading: cloudReadings == nil ? nil : (cloudStates[device.id] ?? .loading)
            )
        }.sorted { lhs, rhs in
            if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
            if lhs.presence != rhs.presence { return Self.presenceRank(lhs.presence) < Self.presenceRank(rhs.presence) }
            let leftName = lhs.device.displayName
            let rightName = rhs.device.displayName
            if leftName != rightName { return leftName < rightName }
            return lhs.device.id.uuidString < rhs.device.id.uuidString
        }
    }

    /// 本机在线优先；服务端状态里最近上报 > 已离线 > 从未上报。
    private static func presenceRank(_ presence: DevicePresence) -> Int {
        switch presence {
        case .online: return 0
        case .offline: return 1
        case .unknown: return 2
        }
    }

    /// 逐台补云端最近读数；结果在主队列回调，只重建条目，不重复发起整页刷新。
    private func requestCloudReadings() {
        guard let cloudReadings else { return }
        for device in roomDevices {
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

    /// 在线判定与首页一致：已连接优先，其次最近 15 分钟内出现过。
    static func isOnline(
        _ device: SavedDevice,
        bluetooth: BluetoothServicing,
        onlineSince: Date
    ) -> Bool {
        if device.isConnectable, bluetooth.isConnected(peripheralID: device.peripheralID) {
            return true
        }
        guard let lastSeenAt = device.lastSeenAt else { return false }
        return lastSeenAt >= onlineSince
    }
}
