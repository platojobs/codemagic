import Foundation

/// 房间详情中的一台设备：名称、在线状态与最新一条真实读数。
struct RoomDetailEntry: Equatable {
    let device: SavedDevice
    let isOnline: Bool
    let reading: DeviceReading?

    var readingText: String {
        guard let reading else { return L10n.t("room.detail.noReading") }
        // 数值与单位之间用不换行空格，避免大字号下 “24.5” 与 “℃” 被拆到两行。
        let value = reading.displayText.replacingOccurrences(of: " ", with: "\u{00A0}")
        return "\(reading.metric.displayName)\u{00A0}\(value)"
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

/// 房间详情聚合视图：本机 SQLite 与服务端同步落地的是同一份 `saved_devices`，
/// 因此总数 / 在线 / 已标记与设备行都直接从这里读取，不另行请求服务端。
///
/// 在线沿用首页现有判定：本机可连接且 CoreBluetooth 已连接，或最近 15 分钟内出现过
/// （与 Android 首页 `ONLINE_WINDOW_MS` 同口径）。跨平台设备没有本机扫描记录，按离线展示，
/// 行内会明确标注「本机不可连接」。
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
    private let now: () -> Date

    init(
        room: Room,
        roomStore: RoomStore,
        deviceStore: SavedDeviceStore,
        readingsStore: ReadingsStore,
        bluetooth: BluetoothServicing,
        householdService: HouseholdService? = nil,
        syncEngine: SyncEngine? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.room = room
        self.roomStore = roomStore
        self.deviceStore = deviceStore
        self.readingsStore = readingsStore
        self.bluetooth = bluetooth
        self.householdService = householdService
        self.syncEngine = syncEngine
        self.now = now
    }

    var totalCount: Int { entries.count }
    var onlineCount: Int { entries.filter(\.isOnline).count }
    var offlineCount: Int { totalCount - onlineCount }
    var markedCount: Int { entries.filter { $0.device.markedAt != nil }.count }
    /// 标记 / 取消标记已写本机但尚未 push 的数量。
    var pendingMarkCount: Int { entries.filter { $0.device.markedAtPatch != .absent }.count }
    var canMark: Bool { entries.contains { $0.device.markedAt == nil } }
    var canUnmark: Bool { entries.contains { $0.device.markedAt != nil } }
    var isEmpty: Bool { entries.isEmpty }

    var summaryText: String {
        L10n.f(
            "room.detail.summary",
            String(totalCount), String(onlineCount), String(offlineCount), String(markedCount)
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
            let onlineSince = now().addingTimeInterval(-Self.onlineWindow)
            let roomDevices = try deviceStore.fetchAll().filter { device in
                guard device.roomID == room.id else { return false }
                guard let household else { return true }
                guard let deviceHousehold = device.householdID else { return household.isPersonal }
                return deviceHousehold == household.id
            }
            entries = roomDevices.map { device in
                RoomDetailEntry(
                    device: device,
                    isOnline: Self.isOnline(device, bluetooth: bluetooth, onlineSince: onlineSince),
                    reading: try? readingsStore.latestReading(deviceID: device.id)
                )
            }.sorted { lhs, rhs in
                if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
                let leftName = lhs.device.displayName
                let rightName = rhs.device.displayName
                if leftName != rightName { return leftName < rightName }
                return lhs.device.id.uuidString < rhs.device.id.uuidString
            }
        } catch {
            notice = L10n.f("room.detail.loadFailed", error.localizedDescription)
        }
        onChange?()
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
