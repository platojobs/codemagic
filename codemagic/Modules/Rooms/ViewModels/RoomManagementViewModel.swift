import Foundation

/// 房间管理视图模型：接入家庭后写服务端，离线落本机并标注未同步；
/// member 不展示新建 / 改名 / 删除入口，服务端 403 也降级为可读提示。
final class RoomManagementViewModel {
    private(set) var rooms: [Room] = []
    private(set) var counts: [UUID: Int] = [:]
    private(set) var lastError: String?
    private(set) var lastNotice: String?

    var onChange: (() -> Void)?

    private let roomStore: RoomStore
    private let deviceStore: SavedDeviceStore
    private let householdService: HouseholdService?

    init(roomStore: RoomStore, deviceStore: SavedDeviceStore, householdService: HouseholdService? = nil) {
        self.roomStore = roomStore
        self.deviceStore = deviceStore
        self.householdService = householdService
    }

    var canManageRooms: Bool {
        householdService?.currentHousehold()?.canManageRooms ?? true
    }

    var footnoteText: String {
        canManageRooms ? L10n.t("room.localOnlyNote") : L10n.t("household.permission.memberNote")
    }

    func reload() {
        do {
            if let householdService {
                rooms = householdService.visibleRooms()
            } else {
                rooms = try roomStore.fetchAll()
            }
            counts = try roomStore.deviceCounts()
            lastError = nil
        } catch {
            lastError = L10n.f("room.loadFailed", String(describing: error))
        }
        onChange?()
    }

    func deviceCount(for room: Room) -> Int {
        counts[room.id] ?? 0
    }

    func create(name: String, completion: ((Bool) -> Void)? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(false)
            return
        }
        guard let householdService else {
            do {
                try roomStore.create(name: trimmed)
                reload()
                completion?(true)
            } catch {
                lastError = L10n.f("room.saveFailed", String(describing: error))
                onChange?()
                completion?(false)
            }
            return
        }
        householdService.createRoom(name: trimmed) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let mutation):
                if !mutation.synced {
                    self.lastNotice = L10n.t("household.assignment.pending")
                }
                self.lastError = nil
                self.reload()
                completion?(true)
            case .failure(let error):
                self.lastError = error.userMessage
                self.onChange?()
                completion?(false)
            }
        }
    }

    func rename(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let householdService else {
            do {
                try roomStore.rename(id: id, name: trimmed)
                reload()
            } catch {
                lastError = L10n.f("room.saveFailed", String(describing: error))
                onChange?()
            }
            return
        }
        householdService.renameRoom(id: id, name: trimmed) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let mutation):
                if !mutation.synced {
                    self.lastNotice = L10n.t("household.assignment.pending")
                }
                self.lastError = nil
            case .failure(let error):
                self.lastError = error.userMessage
            }
            self.reload()
        }
    }

    /// 删除房间：房内设备回到「未分配」，设备本身不删除；离线删除先打墓碑。
    func delete(id: UUID, completion: ((Bool) -> Void)? = nil) {
        guard let householdService else {
            do {
                try roomStore.delete(id: id, deviceStore: deviceStore)
                reload()
                completion?(true)
            } catch {
                lastError = L10n.f("room.deleteFailed", String(describing: error))
                onChange?()
                completion?(false)
            }
            return
        }
        householdService.deleteRoom(id: id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let mutation):
                if !mutation.synced {
                    self.lastNotice = L10n.t("household.assignment.pending")
                }
                self.lastError = nil
                self.reload()
                completion?(true)
            case .failure(let error):
                self.lastError = error.userMessage
                self.onChange?()
                completion?(false)
            }
        }
    }
}
