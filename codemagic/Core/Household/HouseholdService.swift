import Foundation

/// 房间写操作结果：`synced` 为 false 表示只落到本机，等待下次同步补报。
struct RoomMutationResult: Equatable {
    let room: Room?
    let synced: Bool
}

/// 设备归属结果：`reported` 为 false 表示已本地保存、待下次同步上报。
struct AssignmentResult: Equatable {
    let reported: Bool
    let errorMessage: String?
}

/// 家庭业务层：拉取家庭 / 房间、首次接入合并本机房间、设备归属上报、邀请码与成员。
///
/// 设计要点：
/// - 房间以服务端为准；本机离线新增 / 改名 / 删除保留为 `local / pending`，绝不静默丢弃；
/// - 设备归属不进 `push`，用 `PATCH /my/devices/...` 单独上报，失败进 `pending` 队列重试；
/// - 403 / 404 一律转成可读文案，不向界面抛错误码。
final class HouseholdService {
    private let api: HouseholdAPIServicing
    private let tokenStore: TokenStoring
    private let householdStore: HouseholdStore
    private let roomStore: RoomStore
    private let deviceStore: SavedDeviceStore
    private let pendingStore: DeviceAssignmentPendingStore
    private let metadataStore: SyncMetadataStore
    private let logStore: ScanLogStore
    private let now: () -> Date

    init(
        api: HouseholdAPIServicing,
        tokenStore: TokenStoring,
        householdStore: HouseholdStore,
        roomStore: RoomStore,
        deviceStore: SavedDeviceStore,
        pendingStore: DeviceAssignmentPendingStore,
        metadataStore: SyncMetadataStore,
        logStore: ScanLogStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.householdStore = householdStore
        self.roomStore = roomStore
        self.deviceStore = deviceStore
        self.pendingStore = pendingStore
        self.metadataStore = metadataStore
        self.logStore = logStore
        self.now = now
    }

    // MARK: - 读取

    func households() -> [Household] {
        (try? householdStore.fetchAll()) ?? []
    }

    /// 当前家庭：优先持久化的远端 id，其次个人家庭，最后列表首个。
    func currentHousehold() -> Household? {
        let all = households()
        guard !all.isEmpty else { return nil }
        if let remoteID = metadataStore.currentHouseholdRemoteID,
           let match = all.first(where: { $0.remoteID == remoteID }) {
            return match
        }
        return all.first(where: \.isPersonal) ?? all.first
    }

    func switchHousehold(localID: UUID) {
        guard let household = try? householdStore.fetch(localID: localID) else { return }
        metadataStore.currentHouseholdRemoteID = household.remoteID
    }

    /// 首页 / 房间管理的可见房间：当前家庭 + 未归属的本机房间（标注未同步）。
    func visibleRooms() -> [Room] {
        guard let current = currentHousehold() else {
            return (try? roomStore.unclaimedRooms()) ?? []
        }
        let owned = (try? roomStore.fetchAll(householdID: current.id)) ?? []
        let unclaimed = (try? roomStore.unclaimedRooms()) ?? []
        return owned + unclaimed
    }

    func members(
        householdID: UUID,
        completion: @escaping (Result<[HouseholdMember], HouseholdAPIError>) -> Void
    ) {
        guard let token = token else {
            completion(.failure(.unauthorized))
            return
        }
        guard let household = try? householdStore.fetch(localID: householdID) else {
            completion(.failure(.notFound))
            return
        }
        api.members(householdID: household.remoteID, token: token, completion: completion)
    }

    // MARK: - 家庭

    func createHousehold(
        name: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(.failure(.api(code: "BAD_REQUEST", statusCode: 400, message: ""))))
            return
        }
        guard let token else {
            completion(.failure(.unauthorized))
            return
        }
        api.createHousehold(name: trimmed, token: token) { [weak self] result in
            guard let self else { return }
            if case .success(let household) = result {
                try? self.householdStore.upsert(household)
                self.metadataStore.currentHouseholdRemoteID = household.remoteID
                self.recordLog(L10n.f("household.log.created", household.name))
            }
            completion(result)
        }
    }

    /// 重命名家庭：仅 owner 可见入口，member 直接本地拒绝（不依赖服务端 403）。
    func renameHousehold(
        id: UUID,
        name: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(.failure(.api(code: "BAD_REQUEST", statusCode: 400, message: ""))))
            return
        }
        guard let token else {
            completion(.failure(.unauthorized))
            return
        }
        guard let household = try? householdStore.fetch(localID: id) else {
            completion(.failure(.notFound))
            return
        }
        guard household.canManageHousehold else {
            completion(.failure(.forbidden))
            return
        }
        api.updateHousehold(householdID: household.remoteID, name: trimmed, token: token) { [weak self] result in
            guard let self else { return }
            if case .success(let updated) = result {
                try? self.householdStore.upsert(updated)
                self.recordLog(L10n.f("household.log.renamed", updated.name))
            }
            completion(result)
        }
    }

    /// 拉取家庭列表并落库（`memberCount` / `deviceCount` / `roomCount` 均以服务端为准）。
    func refreshHouseholds(completion: ((Result<[Household], HouseholdAPIError>) -> Void)? = nil) {
        guard let token else {
            completion?(.failure(.unauthorized))
            return
        }
        api.listHouseholds(token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion?(.failure(error))
            case .success(let households):
                try? self.householdStore.merge(households)
                let stale = (try? self.householdStore.prune(keepingRemoteIDs: Set(households.map(\.remoteID)))) ?? []
                for household in stale {
                    try? self.roomStore.clearHousehold(householdID: household.id)
                }
                self.pickCurrentHousehold(from: households)
                completion?(.success(households))
            }
        }
    }

    func createInvitation(
        householdID: UUID,
        completion: @escaping (Result<HouseholdInvitation, HouseholdAPIError>) -> Void
    ) {
        guard let token else {
            completion(.failure(.unauthorized))
            return
        }
        guard let household = try? householdStore.fetch(localID: householdID) else {
            completion(.failure(.notFound))
            return
        }
        api.createInvitation(householdID: household.remoteID, token: token, completion: completion)
    }

    func claimInvitation(
        rawCode: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        let code = PairingCodeFormatter.normalize(rawCode)
        guard PairingCodeFormatter.isComplete(code) else {
            completion(.failure(.failure(.api(code: "BAD_REQUEST", statusCode: 400, message: ""))))
            return
        }
        guard let token else {
            completion(.failure(.unauthorized))
            return
        }
        api.claimInvitation(code: code, token: token) { [weak self] result in
            guard let self else { return }
            if case .success(let household) = result {
                try? self.householdStore.upsert(household)
                self.metadataStore.currentHouseholdRemoteID = household.remoteID
                self.recordLog(L10n.f("household.log.joined", household.name))
            }
            completion(result)
        }
    }

    // MARK: - 成员 / 退出 / 邀请码管理

    func invitations(
        householdID: UUID,
        completion: @escaping (Result<[HouseholdInvitationInfo], HouseholdAPIError>) -> Void
    ) {
        guard let token else {
            completion(.failure(.unauthorized))
            return
        }
        guard let household = try? householdStore.fetch(localID: householdID) else {
            completion(.failure(.notFound))
            return
        }
        guard household.canManageHousehold else {
            completion(.failure(.forbidden))
            return
        }
        api.invitations(householdID: household.remoteID, token: token, completion: completion)
    }

    func revokeInvitation(
        householdID: UUID,
        invitationID: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        guard let token else {
            completion(.failure(.unauthorized))
            return
        }
        guard let household = try? householdStore.fetch(localID: householdID) else {
            completion(.failure(.notFound))
            return
        }
        guard household.canManageHousehold else {
            completion(.failure(.forbidden))
            return
        }
        api.revokeInvitation(
            householdID: household.remoteID,
            invitationID: invitationID,
            token: token
        ) { [weak self] result in
            guard let self else { return }
            if case .success = result {
                self.recordLog(L10n.t("household.log.invitationRevoked"))
            }
            completion(result)
        }
    }

    /// owner 移除成员。成功后会清掉该成员在本地留下的归属痕迹并刷新服务端计数。
    func removeMember(
        householdID: UUID,
        userID: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        guard let token else {
            completion(.failure(.unauthorized))
            return
        }
        guard let household = try? householdStore.fetch(localID: householdID) else {
            completion(.failure(.notFound))
            return
        }
        guard household.canManageHousehold else {
            completion(.failure(.forbidden))
            return
        }
        api.removeMember(householdID: household.remoteID, userID: userID, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.recordLog(L10n.t("household.log.memberRemoved"))
                // 被移除的是当前用户：本地按「退出家庭」同样回落，避免继续显示已无权限的数据。
                if userID == self.tokenStore.load()?.userID {
                    self.applyLocalDeparture(household: household)
                }
                self.refreshHouseholds { _ in completion(.success(())) }
            }
        }
    }

    /// 退出家庭。owner 还有其他成员时服务端 409，统一转成可读提示。
    func leaveHousehold(
        householdID: UUID,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        guard let token else {
            completion(.failure(.unauthorized))
            return
        }
        guard let household = try? householdStore.fetch(localID: householdID) else {
            completion(.failure(.notFound))
            return
        }
        guard household.canLeave else {
            // 个人家庭不可退出。
            completion(.failure(.conflict))
            return
        }
        api.leaveHousehold(householdID: household.remoteID, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.recordLog(L10n.f("household.log.left", household.name))
                self.applyLocalDeparture(household: household)
                self.refreshHouseholds { _ in completion(.success(())) }
            }
        }
    }

    /// 本地回落：设备改挂个人家庭并清空房间；房间脱钩保留（不静默丢弃）；切回个人家庭。
    private func applyLocalDeparture(household: Household) {
        let personal = households().first(where: \.isPersonal)
        let devices = (try? deviceStore.devices(householdID: household.id)) ?? []
        for device in devices {
            try? pendingStore.remove(deviceID: device.id)
            try? deviceStore.setAssignment(
                id: device.id,
                householdID: personal?.id,
                roomID: nil,
                remoteRoomID: nil,
                remoteHouseholdID: personal?.remoteID
            )
        }
        try? roomStore.clearHousehold(householdID: household.id)
        try? householdStore.delete(localID: household.id)
        metadataStore.currentHouseholdRemoteID = personal?.remoteID
    }

    /// 整段重排：`orderedRoomIDs` 必须覆盖当前家庭全部已同步房间。409 时不改本地顺序。
    func reorderRooms(
        householdID: UUID,
        orderedRoomIDs: [UUID],
        completion: @escaping (Result<[Room], HouseholdAPIError>) -> Void
    ) {
        guard let household = try? householdStore.fetch(localID: householdID) else {
            completion(.failure(.notFound))
            return
        }
        guard household.canManageRooms else {
            completion(.failure(.forbidden))
            return
        }
        let currentRooms = ((try? roomStore.fetchAll(householdID: household.id)) ?? [])
            .filter { !$0.isDeleted }
        let remoteRooms = currentRooms.filter { $0.remoteID != nil }
        let orderedRemoteIDs = orderedRoomIDs.compactMap { id in
            remoteRooms.first(where: { $0.id == id })?.remoteID
        }
        guard let token, !household.remoteID.isEmpty else {
            // 未登录 / 离线：只落本机顺序。
            try? roomStore.applySortOrders(orderedRoomIDs, at: now())
            completion(.success((try? roomStore.fetchAll(householdID: household.id)) ?? []))
            return
        }
        guard orderedRemoteIDs.count == remoteRooms.count, Set(orderedRemoteIDs).count == remoteRooms.count else {
            completion(.failure(.roomSetMismatch))
            return
        }
        api.reorderRooms(householdID: household.remoteID, roomIDs: orderedRemoteIDs, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // 网络失败不落本地顺序，避免与服务端真值分叉；409 由界面重新拉取后整段重提。
                completion(.failure(error))
            case .success(let remotes):
                for remote in remotes {
                    _ = self.upsertRemoteRoom(remote, household: household)
                }
                let ids = remotes.compactMap { self.localRoomID(remoteID: $0.id) }
                try? self.roomStore.applySortOrders(ids, at: self.now())
                completion(.success(self.visibleRooms()))
            }
        }
    }

    /// 409 后重新拉取当前家庭房间（保留本地未同步房间）。
    func refreshRooms(
        householdID: UUID,
        completion: @escaping (Result<[Room], HouseholdAPIError>) -> Void
    ) {
        guard let household = try? householdStore.fetch(localID: householdID) else {
            completion(.failure(.notFound))
            return
        }
        guard let token else {
            completion(.success(visibleRooms()))
            return
        }
        fetchRooms(token: token, household: household) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(error == .unauthorized ? .failure(error) : .success(self.visibleRooms()))
            case .success:
                completion(.success(self.visibleRooms()))
            }
        }
    }

    // MARK: - 房间

    func createRoom(
        name: String,
        completion: @escaping (Result<RoomMutationResult, HouseholdAPIError>) -> Void
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(.failure(.api(code: "BAD_REQUEST", statusCode: 400, message: ""))))
            return
        }
        let current = currentHousehold()
        guard let current, let token else {
            let room = (try? roomStore.create(name: trimmed)) ?? Room(name: trimmed, sortOrder: 1)
            completion(.success(RoomMutationResult(room: room, synced: false)))
            return
        }
        guard current.canManageRooms else {
            completion(.failure(.forbidden))
            return
        }
        let localSortOrder = (try? roomStore.fetchAll(householdID: current.id).count) ?? 0
        api.createRoom(
            householdID: current.remoteID,
            name: trimmed,
            sortOrder: localSortOrder + 1,
            token: token
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if error.isRetryable {
                    // 离线：先落本机 pending，下次同步补创建。
                    let room = self.makePendingRoom(name: trimmed, household: current)
                    completion(.success(RoomMutationResult(room: room, synced: false)))
                } else {
                    completion(.failure(error))
                }
            case .success(let remote):
                let room = self.upsertRemoteRoom(remote, household: current)
                completion(.success(RoomMutationResult(room: room, synced: true)))
            }
        }
    }

    func renameRoom(
        id: UUID,
        name: String,
        completion: @escaping (Result<RoomMutationResult, HouseholdAPIError>) -> Void
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(.failure(.api(code: "BAD_REQUEST", statusCode: 400, message: ""))))
            return
        }
        guard let room = try? roomStore.fetch(id: id) else {
            completion(.failure(.notFound))
            return
        }
        let current = currentHousehold()
        guard let remoteRoomID = room.remoteID, let current, current.householdMatches(room), let token else {
            try? roomStore.rename(id: id, name: trimmed, at: now())
            try? roomStore.setSyncState(id: id, syncState: room.remoteID == nil ? .local : .pending, at: now())
            let updated = try? roomStore.fetch(id: id)
            completion(.success(RoomMutationResult(room: updated, synced: false)))
            return
        }
        guard current.canManageRooms else {
            completion(.failure(.forbidden))
            return
        }
        api.updateRoom(
            householdID: current.remoteID,
            roomID: remoteRoomID,
            name: trimmed,
            sortOrder: nil,
            token: token
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if error.isRetryable {
                    try? self.roomStore.rename(id: id, name: trimmed, at: self.now())
                    try? self.roomStore.setSyncState(id: id, syncState: .pending, at: self.now())
                    completion(.success(RoomMutationResult(room: try? self.roomStore.fetch(id: id), synced: false)))
                } else {
                    completion(.failure(error))
                }
            case .success(let remote):
                self.upsertRemoteRoom(remote, household: current)
                completion(.success(RoomMutationResult(room: try? self.roomStore.fetch(id: id), synced: true)))
            }
        }
    }

    func deleteRoom(
        id: UUID,
        completion: @escaping (Result<RoomMutationResult, HouseholdAPIError>) -> Void
    ) {
        guard let room = try? roomStore.fetch(id: id) else {
            completion(.failure(.notFound))
            return
        }
        let current = currentHousehold()
        guard let remoteRoomID = room.remoteID, let current, current.householdMatches(room), let token else {
            try? performLocalDelete(roomID: id)
            completion(.success(RoomMutationResult(room: nil, synced: room.remoteID == nil)))
            return
        }
        guard current.canManageRooms else {
            completion(.failure(.forbidden))
            return
        }
        api.deleteRoom(householdID: current.remoteID, roomID: remoteRoomID, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if error.isRetryable {
                    // 离线：先打墓碑并让房内设备回到未分配，联网后重试删除。
                    try? self.roomStore.markDeleted(id: id, at: self.now())
                    try? self.moveDevicesOut(of: id, household: current)
                    completion(.success(RoomMutationResult(room: nil, synced: false)))
                } else if error == .notFound {
                    // 服务端已不存在：本地直接清理。
                    try? self.performLocalDelete(roomID: id)
                    completion(.success(RoomMutationResult(room: nil, synced: true)))
                } else {
                    completion(.failure(error))
                }
            case .success:
                try? self.performLocalDelete(roomID: id)
                completion(.success(RoomMutationResult(room: nil, synced: true)))
            }
        }
    }

    // MARK: - 设备归属

    /// 设备移入 / 移出房间。先落本机，再尝试 PATCH；可重试错误保留 pending 等下次同步。
    func assignDevice(
        _ device: SavedDevice,
        room: Room?,
        completion: @escaping (AssignmentResult) -> Void
    ) {
        let current = currentHousehold()
        let householdID = current?.id ?? device.householdID
        let householdRemoteID = current?.remoteID ?? device.remoteHouseholdID
        let roomRemoteID = room?.remoteID
        let roomHouseholdMatches = room.map { $0.householdID == nil || $0.householdID == householdID } ?? true

        do {
            try deviceStore.setAssignment(
                id: device.id,
                householdID: householdID,
                roomID: room?.id,
                remoteRoomID: roomRemoteID,
                remoteHouseholdID: householdRemoteID
            )
        } catch {
            completion(AssignmentResult(reported: false, errorMessage: L10n.t("household.genericError")))
            return
        }

        guard roomHouseholdMatches, let householdRemoteID, let token else {
            completion(AssignmentResult(reported: false, errorMessage: nil))
            return
        }
        guard room == nil || roomRemoteID != nil else {
            // 目标房间尚未同步到服务端：归属保留在本机，等房间同步后由 prepareForSync 补报。
            completion(AssignmentResult(reported: false, errorMessage: nil))
            return
        }
        // 未分配使用空串显式清除（openapi 三态：缺失 = 不变、空串 = 清除）。
        let reportedRoomID = roomRemoteID ?? ""

        let entry = PendingDeviceAssignment(
            deviceID: device.id,
            platform: device.platform,
            externalID: device.externalID,
            roomRemoteID: reportedRoomID,
            householdRemoteID: householdRemoteID,
            attempts: 0,
            createdAt: now(),
            updatedAt: now()
        )
        try? pendingStore.upsert(entry)

        api.patchDeviceAssignment(
            platform: device.platform,
            externalID: device.externalID,
            roomID: reportedRoomID,
            householdID: householdRemoteID,
            token: token
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let remote):
                try? self.pendingStore.remove(deviceID: device.id)
                try? self.deviceStore.applyRemoteAssignment(
                    id: device.id,
                    householdID: householdID,
                    roomID: room?.id,
                    remoteRoomID: remote.roomID,
                    remoteHouseholdID: remote.householdID
                )
                self.metadataStore.lastAssignmentError = nil
                completion(AssignmentResult(reported: true, errorMessage: nil))
            case .failure(let error):
                if error.isRetryable {
                    completion(AssignmentResult(
                        reported: false,
                        errorMessage: L10n.t("household.assignment.pending")
                    ))
                } else {
                    // 403 / 404 属终态：移除队列并给出可读提示，避免无限重试。
                    try? self.pendingStore.remove(deviceID: device.id)
                    self.metadataStore.lastAssignmentError = error.userMessage
                    completion(AssignmentResult(reported: false, errorMessage: error.userMessage))
                }
            }
        }
    }

    // MARK: - 同步

    /// 登录 / 同步前置：拉家庭、确定当前家庭、合并房间、补报归属。
    func prepareForSync(
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        api.listHouseholds(token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // 家庭接口不可用时不妨碍设备同步；401 交给同步流程处理。
                completion(error == .unauthorized ? .failure(error) : .success(()))
            case .success(let households):
                try? self.householdStore.merge(households)
                // 服务端已不存在的家庭（被删除 / 换号）从本地移除，房间脱钩保留，不丢用户数据。
                let stale = (try? self.householdStore.prune(keepingRemoteIDs: Set(households.map(\.remoteID)))) ?? []
                var detachedRoomIDs: Set<UUID> = []
                for household in stale {
                    let rooms = (try? self.roomStore.fetchAll(householdID: household.id)) ?? []
                    detachedRoomIDs.formUnion(rooms.map(\.id))
                    try? self.roomStore.clearHousehold(householdID: household.id)
                }
                self.pickCurrentHousehold(from: households)
                // 刚脱钩的房间不在本轮重新认领，避免把已删家庭的房间静默搬进当前家庭。
                self.prepareRooms(token: token, excluding: detachedRoomIDs, completion: completion)
            }
        }
    }

    /// 重试设备归属队列；单条失败不影响其余条目。
    func flushPendingAssignments(
        token: String? = nil,
        completion: @escaping () -> Void
    ) {
        guard let token = token ?? self.token else {
            completion()
            return
        }
        let entries = (try? pendingStore.fetchAll()) ?? []
        guard !entries.isEmpty else {
            completion()
            return
        }
        var index = 0
        func step() {
            guard index < entries.count else {
                completion()
                return
            }
            let entry = entries[index]
            index += 1
            api.patchDeviceAssignment(
                platform: entry.platform,
                externalID: entry.externalID,
                roomID: entry.roomRemoteID,
                householdID: entry.householdRemoteID,
                token: token
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let remote):
                    try? self.pendingStore.remove(deviceID: entry.deviceID)
                    if let local = try? self.deviceStore.fetch(id: entry.deviceID) {
                        try? self.deviceStore.applyRemoteAssignment(
                            id: local.id,
                            householdID: local.householdID,
                            roomID: local.roomID,
                            remoteRoomID: remote.roomID,
                            remoteHouseholdID: remote.householdID
                        )
                    }
                case .failure(let error):
                    if error.isRetryable {
                        var retried = entry
                        retried.attempts += 1
                        retried.updatedAt = self.now()
                        try? self.pendingStore.upsert(retried)
                    } else {
                        try? self.pendingStore.remove(deviceID: entry.deviceID)
                        self.metadataStore.lastAssignmentError = error.userMessage
                        self.recordLog(L10n.f("household.log.assignmentFailed", error.userMessage))
                    }
                }
                step()
            }
        }
        step()
    }

    // MARK: - 远端映射（供 SyncEngine 使用）

    func localize(remoteHouseholdID: String?, remoteRoomID: String?) -> (householdID: UUID?, roomID: UUID?) {
        let householdID = householdStore.localID(forRemoteID: remoteHouseholdID)
        if let remoteRoomID, !remoteRoomID.isEmpty {
            let room = try? roomStore.fetch(remoteID: remoteRoomID)
            return (householdID, room?.id)
        }
        return (householdID, nil)
    }

    func localRoomID(remoteID: String?) -> UUID? {
        guard let remoteID, !remoteID.isEmpty else { return nil }
        return (try? roomStore.fetch(remoteID: remoteID))?.id
    }

    /// 本地归属是否待上报；用于拉取时避免服务端旧值覆盖用户刚做的移动。
    func hasPendingAssignment(deviceID: UUID) -> Bool {
        ((try? pendingStore.fetchAll()) ?? []).contains { $0.deviceID == deviceID }
    }

    // MARK: - Private

    private var token: String? {
        guard let token = tokenStore.load()?.token, !token.isEmpty else { return nil }
        return token
    }

    private func pickCurrentHousehold(from households: [Household]) {
        guard !households.isEmpty else { return }
        if let remoteID = metadataStore.currentHouseholdRemoteID,
           households.contains(where: { $0.remoteID == remoteID }) {
            return
        }
        let chosen = households.first(where: \.isPersonal) ?? households[0]
        metadataStore.currentHouseholdRemoteID = chosen.remoteID
    }

    private func prepareRooms(
        token: String,
        excluding excludedRoomIDs: Set<UUID>,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        guard let current = currentHousehold() else {
            completion(.success(()))
            return
        }
        // 首次接入：把本机未归属房间认领到当前（owner）家庭，随后由 pushLocalRooms 推到服务端。
        let alreadySeeded = metadataStore.seededHouseholdRemoteID
        let unclaimed = ((try? roomStore.unclaimedRooms()) ?? []).filter { !excludedRoomIDs.contains($0.id) }
        if unclaimed.isEmpty || alreadySeeded != nil {
            // 无需种子；继续补报该家庭内的本地房间与设备归属。
            syncHouseholdRooms(token: token, household: current) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(error == .unauthorized ? .failure(error) : .success(()))
                case .success:
                    self.syncOtherHouseholds(token: token, excluding: current) {
                        self.flushPendingAssignments(token: token) {
                            completion(.success(()))
                        }
                    }
                }
            }
            return
        }
        guard current.canManageRooms else {
            // 成员无法创建房间：本机房间保持未归属并标注未同步。
            syncHouseholdRooms(token: token, household: current) { [weak self] _ in
                self?.flushPendingAssignments(token: token) { completion(.success(())) }
            }
            return
        }
        for room in unclaimed {
            try? roomStore.claim(id: room.id, householdID: current.id)
        }
        // 标记先写：房间推失败时仍会由 pushLocalRooms 重试，但不再重复走认领流程。
        metadataStore.seededHouseholdRemoteID = current.remoteID
        syncHouseholdRooms(token: token, household: current) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result, error == .unauthorized {
                completion(.failure(error))
                return
            }
            self.syncOtherHouseholds(token: token, excluding: current) {
                self.flushPendingAssignments(token: token) {
                    completion(.success(()))
                }
            }
        }
    }

    /// 同步当前家庭：先补报 pending 改名 / 删除，再拉取远端房间，最后把本地房间推上去。
    private func syncHouseholdRooms(
        token: String,
        household: Household,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        flushRoomTombstones(token: token, household: household) { [weak self] in
            guard let self else { return }
            self.flushRoomRenames(token: token, household: household) { [weak self] in
                guard let self else { return }
                self.fetchRooms(token: token, household: household) { [weak self] fetchResult in
                    guard let self else { return }
                    switch fetchResult {
                    case .failure(let error):
                        completion(error == .unauthorized ? .failure(error) : .success(()))
                    case .success:
                        self.pushLocalRooms(token: token, household: household) { [weak self] in
                            guard let self else { return }
                            self.enqueueAssignmentsForLocalRooms(household: household)
                            completion(.success(()))
                        }
                    }
                }
            }
        }
    }

    private func flushRoomTombstones(
        token: String,
        household: Household,
        completion: @escaping () -> Void
    ) {
        let deleted = (try? roomStore.fetchDeleted(householdID: household.id)) ?? []
        guard !deleted.isEmpty else {
            completion()
            return
        }
        var index = 0
        func step() {
            guard index < deleted.count else {
                completion()
                return
            }
            let room = deleted[index]
            index += 1
            guard let remoteID = room.remoteID else {
                // 从未上报成功：无需远端删除，直接清理墓碑。
                try? roomStore.purge(id: room.id)
                step()
                return
            }
            api.deleteRoom(householdID: household.remoteID, roomID: remoteID, token: token) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success, .failure(.notFound):
                    try? self.roomStore.purge(id: room.id)
                case .failure(let error):
                    if !error.isRetryable {
                        self.recordLog(L10n.f("household.log.roomSyncFailed", room.name, error.userMessage))
                    }
                }
                step()
            }
        }
        step()
    }

    private func flushRoomRenames(
        token: String,
        household: Household,
        completion: @escaping () -> Void
    ) {
        let pending = ((try? roomStore.pendingRooms(householdID: household.id)) ?? [])
            .filter { !$0.isDeleted && $0.remoteID != nil }
        guard !pending.isEmpty else {
            completion()
            return
        }
        var index = 0
        func step() {
            guard index < pending.count else {
                completion()
                return
            }
            let room = pending[index]
            index += 1
            guard let remoteID = room.remoteID else {
                step()
                return
            }
            api.updateRoom(
                householdID: household.remoteID,
                roomID: remoteID,
                name: room.name,
                sortOrder: room.sortOrder,
                token: token
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let remote):
                    self.upsertRemoteRoom(remote, household: household)
                case .failure(let error):
                    if !error.isRetryable {
                        // 权限或不存在：停止重试，房间保留本机并标注未同步。
                        self.recordLog(L10n.f("household.log.roomSyncFailed", room.name, error.userMessage))
                    }
                }
                step()
            }
        }
        step()
    }

    private func fetchRooms(
        token: String,
        household: Household,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        api.rooms(householdID: household.remoteID, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let remotes):
                for remote in remotes {
                    if let existing = try? self.roomStore.fetch(remoteID: remote.id) {
                        // 本地权限内改名仍在 pending 时不覆盖用户修改。
                        if existing.syncState != .pending {
                            try? self.roomStore.applyRemote(
                                id: existing.id,
                                remoteID: remote.id,
                                name: remote.name,
                                sortOrder: remote.sortOrder,
                                at: self.now()
                            )
                        }
                    } else {
                        // 服务端房间与本机未上报房间同名：认领本机房间，避免重复建房间并保留设备归属。
                        let locals = (try? self.roomStore.localRooms(householdID: household.id)) ?? []
                        if let local = locals.first(where: {
                            Self.normalizedName($0.name) == Self.normalizedName(remote.name)
                        }) {
                            try? self.roomStore.applyRemote(
                                id: local.id,
                                remoteID: remote.id,
                                name: remote.name,
                                sortOrder: remote.sortOrder,
                                at: self.now()
                            )
                            continue
                        }
                        let room = Room(
                            name: remote.name,
                            sortOrder: remote.sortOrder,
                            remoteID: remote.id,
                            householdID: household.id,
                            syncState: .synced,
                            createdAt: remote.createdAt ?? self.now(),
                            updatedAt: self.now()
                        )
                        try? self.roomStore.upsert(room)
                    }
                }
                completion(.success(()))
            }
        }
    }

    private func pushLocalRooms(
        token: String,
        household: Household,
        completion: @escaping () -> Void
    ) {
        guard household.canManageRooms else {
            completion()
            return
        }
        let locals = (try? roomStore.localRooms(householdID: household.id)) ?? []
        guard !locals.isEmpty, let room = locals.first else {
            completion()
            return
        }
        let remotes = (try? roomStore.fetchAll(householdID: household.id)) ?? []
        if let match = remotes.first(where: {
            $0.remoteID != nil && Self.normalizedName($0.name) == Self.normalizedName(room.name)
        }), let remoteID = match.remoteID {
            // 服务端已有同名房间：认领而不是重复创建，保留本地设备归属。
            try? roomStore.applyRemote(
                id: room.id,
                remoteID: remoteID,
                name: match.name,
                sortOrder: match.sortOrder,
                at: now()
            )
            pushLocalRooms(token: token, household: household, completion: completion)
            return
        }
        api.createRoom(
            householdID: household.remoteID,
            name: room.name,
            sortOrder: room.sortOrder,
            token: token
        ) { [weak self] result in
            guard let self else { return }
            if case .success(let remote) = result {
                try? self.roomStore.applyRemote(
                    id: room.id,
                    remoteID: remote.id,
                    name: remote.name,
                    sortOrder: remote.sortOrder,
                    at: self.now()
                )
            } else {
                self.recordLog(L10n.f("household.log.roomSyncFailed", room.name, ""))
            }
            self.pushLocalRooms(token: token, household: household, completion: completion)
        }
    }

    /// 本机房间获得远端 id 后，把房内设备归属补进上报队列。
    /// 首次种子家庭的未归属设备（`householdID == nil`）一并认领，保证旧数据归属不丢。
    private func enqueueAssignmentsForLocalRooms(household: Household) {
        guard let devices = try? deviceStore.fetchAll() else { return }
        let isSeedingHousehold = metadataStore.seededHouseholdRemoteID == household.remoteID
        for device in devices where device.deletedAt == nil {
            let belongsToHousehold = device.householdID == household.id
                || (device.householdID == nil && isSeedingHousehold)
            guard belongsToHousehold else { continue }
            guard let roomID = device.roomID, let room = try? roomStore.fetch(id: roomID) else { continue }
            guard let remoteRoomID = room.remoteID else { continue }
            if device.householdID == nil {
                try? deviceStore.setAssignment(
                    id: device.id,
                    householdID: household.id,
                    roomID: roomID,
                    remoteRoomID: device.remoteRoomID,
                    remoteHouseholdID: device.remoteHouseholdID
                )
            }
            guard device.remoteRoomID != remoteRoomID || device.remoteHouseholdID != household.remoteID else { continue }
            let entry = PendingDeviceAssignment(
                deviceID: device.id,
                platform: device.platform,
                externalID: device.externalID,
                roomRemoteID: remoteRoomID,
                householdRemoteID: household.remoteID,
                attempts: 0,
                createdAt: now(),
                updatedAt: now()
            )
            try? pendingStore.upsert(entry)
        }
    }

    private func syncOtherHouseholds(
        token: String,
        excluding current: Household,
        completion: @escaping () -> Void
    ) {
        let others = households().filter { $0.id != current.id }
        guard !others.isEmpty else {
            completion()
            return
        }
        var index = 0
        func step() {
            guard index < others.count else {
                completion()
                return
            }
            var household = others[index]
            index += 1
            api.rooms(householdID: household.remoteID, token: token) { [weak self] result in
                guard let self else { return }
                if case .success(let remotes) = result {
                    for remote in remotes {
                        if let existing = try? self.roomStore.fetch(remoteID: remote.id) {
                            if existing.syncState != .pending {
                                try? self.roomStore.applyRemote(
                                    id: existing.id,
                                    remoteID: remote.id,
                                    name: remote.name,
                                    sortOrder: remote.sortOrder,
                                    at: self.now()
                                )
                            }
                        } else {
                            let room = Room(
                                name: remote.name,
                                sortOrder: remote.sortOrder,
                                remoteID: remote.id,
                                householdID: household.id,
                                syncState: .synced,
                                createdAt: remote.createdAt ?? self.now(),
                                updatedAt: self.now()
                            )
                            try? self.roomStore.upsert(room)
                        }
                    }
                }
                step()
            }
        }
        step()
    }

    private func upsertRemoteRoom(_ remote: RemoteHouseholdRoom, household: Household) -> Room {
        if let existing = try? roomStore.fetch(remoteID: remote.id) {
            try? roomStore.applyRemote(
                id: existing.id,
                remoteID: remote.id,
                name: remote.name,
                sortOrder: remote.sortOrder,
                at: now()
            )
            return (try? roomStore.fetch(id: existing.id)) ?? existing
        }
        let room = Room(
            name: remote.name,
            sortOrder: remote.sortOrder,
            remoteID: remote.id,
            householdID: household.id,
            syncState: .synced,
            createdAt: remote.createdAt ?? now(),
            updatedAt: now()
        )
        try? roomStore.upsert(room)
        return room
    }

    private func makePendingRoom(name: String, household: Household) -> Room {
        let order = ((try? roomStore.fetchAll(householdID: household.id).count) ?? 0) + 1
        if let room = try? roomStore.create(name: name, householdID: household.id, syncState: .pending) {
            return room
        }
        return Room(name: name, sortOrder: order, householdID: household.id, syncState: .pending)
    }

    private func performLocalDelete(roomID: UUID) throws {
        let devices = try deviceStore.fetchAll().filter { $0.roomID == roomID }
        for device in devices {
            try deviceStore.setRoom(id: device.id, roomID: nil)
        }
        try roomStore.purge(id: roomID)
    }

    private func moveDevicesOut(of roomID: UUID, household: Household) throws {
        let devices = try deviceStore.fetchAll().filter { $0.roomID == roomID }
        for device in devices {
            try deviceStore.setRoom(id: device.id, roomID: nil)
            let entry = PendingDeviceAssignment(
                deviceID: device.id,
                platform: device.platform,
                externalID: device.externalID,
                roomRemoteID: "",
                householdRemoteID: household.remoteID,
                attempts: 0,
                createdAt: now(),
                updatedAt: now()
            )
            try? pendingStore.upsert(entry)
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func recordLog(_ message: String) {
        try? logStore.append(ScanLogEntry(category: .sync, level: .info, message: message))
    }
}

private extension Household {
    func householdMatches(_ room: Room) -> Bool {
        room.householdID == nil || room.householdID == id
    }
}
