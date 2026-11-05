import Foundation

/// 房间管理视图模型：房间仅本机保存，增删改后立即通知宿主刷新。
final class RoomManagementViewModel {
    private(set) var rooms: [Room] = []
    private(set) var counts: [UUID: Int] = [:]
    private(set) var lastError: AppError?

    var onChange: (() -> Void)?

    private let roomStore: RoomStore
    private let deviceStore: SavedDeviceStore

    init(roomStore: RoomStore, deviceStore: SavedDeviceStore) {
        self.roomStore = roomStore
        self.deviceStore = deviceStore
    }

    func reload() {
        do {
            rooms = try roomStore.fetchAll()
            counts = try roomStore.deviceCounts()
            lastError = nil
        } catch {
            lastError = .database(L10n.f("room.loadFailed", String(describing: error)))
        }
        onChange?()
    }

    func deviceCount(for room: Room) -> Int {
        counts[room.id] ?? 0
    }

    @discardableResult
    func create(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try roomStore.create(name: trimmed)
            reload()
            return true
        } catch {
            lastError = .database(L10n.f("room.saveFailed", String(describing: error)))
            onChange?()
            return false
        }
    }

    func rename(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try roomStore.rename(id: id, name: trimmed)
            reload()
        } catch {
            lastError = .database(L10n.f("room.saveFailed", String(describing: error)))
            onChange?()
        }
    }

    /// 删除房间：房内设备回到「未分配」，设备本身不删除。
    func delete(id: UUID) {
        do {
            try roomStore.delete(id: id, deviceStore: deviceStore)
            reload()
        } catch {
            lastError = .database(L10n.f("room.deleteFailed", String(describing: error)))
            onChange?()
        }
    }
}
