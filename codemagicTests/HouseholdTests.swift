import XCTest
@testable import codemagic

/// 家庭链路数据层：首次接入房间合并、设备归属上报、pending 重试、切换家庭与 403 降级。
final class HouseholdTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var database: SQLiteDatabase!
    private var householdStore: HouseholdStore!
    private var roomStore: RoomStore!
    private var deviceStore: SavedDeviceStore!
    private var pendingStore: DeviceAssignmentPendingStore!
    private var metadata: SyncMetadataStore!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var api: FakeHouseholdAPI!
    private var service: HouseholdService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        database = testDatabase.database
        householdStore = HouseholdStore(database: database)
        roomStore = RoomStore(database: database)
        deviceStore = SavedDeviceStore(database: database)
        pendingStore = DeviceAssignmentPendingStore(database: database)
        let suiteName = "household-tests-\(UUID().uuidString)"
        defaultsSuiteName = suiteName
        defaults = UserDefaults(suiteName: suiteName)
        metadata = SyncMetadataStore(defaults: defaults)
        api = FakeHouseholdAPI()
        service = HouseholdService(
            api: api,
            tokenStore: StubTokenStore(token: "token-a"),
            householdStore: householdStore,
            roomStore: roomStore,
            deviceStore: deviceStore,
            pendingStore: pendingStore,
            metadataStore: metadata,
            logStore: ScanLogStore(database: database),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        testDatabase?.cleanUp()
        testDatabase = nil
        super.tearDown()
    }

    // MARK: - 迁移与合并策略

    func testFirstSyncClaimsLocalRoomsAndPushesThemInOrder() throws {
        let living = try roomStore.create(name: "客厅")
        _ = try roomStore.create(name: "卧室")
        let device = makeDevice(roomID: living.id)
        try deviceStore.upsert(device)

        let personal = makeHousehold(name: "我的家", personal: true, role: .owner)
        api.households = [personal]
        api.nextRoomIDs = ["remote-living", "remote-bed"]

        service.prepareForSync(token: "token-a") { _ in }

        XCTAssertEqual(api.createdRoomNames, ["客厅", "卧室"], "按本地顺序推送到服务端")
        XCTAssertEqual(metadata.seededHouseholdRemoteID, personal.remoteID, "首次接入后记录种子家庭")

        let rooms = try roomStore.fetchAll(householdID: personal.id)
        XCTAssertEqual(rooms.map(\.name), ["客厅", "卧室"])
        XCTAssertEqual(rooms.map(\.remoteID), ["remote-living", "remote-bed"])
        XCTAssertTrue(rooms.allSatisfy { $0.syncState == .synced })
        XCTAssertTrue(rooms.allSatisfy { $0.householdID == personal.id })

        // 房间获得远端 id 后，房内设备归属补进队列并上报成功。
        XCTAssertEqual(api.patches.count, 1)
        XCTAssertEqual(api.patches.first?.roomRemoteID, "remote-living")
        XCTAssertEqual(api.patches.first?.householdRemoteID, personal.remoteID)
        let reloaded = try deviceStore.fetch(id: device.id)
        XCTAssertEqual(reloaded?.roomID, living.id, "本机归属保留")
        XCTAssertEqual(reloaded?.remoteRoomID, "remote-living")
        XCTAssertTrue(try pendingStore.fetchAll().isEmpty)
    }

    func testLocalRoomWithSameNameReusesRemoteRoomInsteadOfDuplicating() throws {
        let local = try roomStore.create(name: "客厅")
        let device = makeDevice(roomID: local.id)
        try deviceStore.upsert(device)

        let personal = makeHousehold(name: "我的家", personal: true, role: .owner)
        api.households = [personal]
        api.roomsByHousehold[personal.remoteID] = [
            RemoteHouseholdRoom(
                id: "remote-existing",
                householdID: personal.remoteID,
                name: "客厅",
                sortOrder: 1
            )
        ]

        service.prepareForSync(token: "token-a") { _ in }

        XCTAssertTrue(api.createdRoomNames.isEmpty, "同名房间应认领而不是重复创建")
        let rooms = try roomStore.fetchAll(householdID: personal.id)
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms.first?.id, local.id, "保留本地房间 id 与设备归属")
        XCTAssertEqual(rooms.first?.remoteID, "remote-existing")
        XCTAssertEqual(try deviceStore.fetch(id: device.id)?.remoteRoomID, "remote-existing")
    }

    func testPreparePrunesMissingHouseholdButKeepsItsRoomsLocal() throws {
        let stale = makeHousehold(name: "旧家庭", personal: false, role: .member)
        try householdStore.upsert(stale)
        let room = Room(name: "书房", sortOrder: 1, householdID: stale.id, syncState: .synced)
        try roomStore.upsert(room)

        let personal = makeHousehold(name: "我的家", personal: true, role: .owner)
        api.households = [personal]

        service.prepareForSync(token: "token-a") { _ in }

        XCTAssertNil(try householdStore.fetch(localID: stale.id), "服务端已删除的家庭从本地移除")
        let kept = try roomStore.fetch(id: room.id)
        XCTAssertNotNil(kept, "房间不得静默丢弃")
        XCTAssertNil(kept?.householdID, "房间脱钩为未归属，离线仍可见")
    }

    // MARK: - 设备归属

    func testForbiddenAssignmentIsTerminalAndReadable() throws {
        let personal = makeHousehold(name: "我的家", personal: true, role: .member)
        try householdStore.upsert(personal)
        metadata.currentHouseholdRemoteID = personal.remoteID
        let room = Room(
            name: "客厅",
            sortOrder: 1,
            remoteID: "remote-living",
            householdID: personal.id,
            syncState: .synced
        )
        try roomStore.upsert(room)
        let device = makeDevice(roomID: nil, householdID: personal.id)
        try deviceStore.upsert(device)

        api.patchError = .forbidden
        var result: AssignmentResult?
        service.assignDevice(device, room: room) { result = $0 }

        XCTAssertEqual(result?.reported, false)
        XCTAssertEqual(result?.errorMessage, L10n.t("household.forbidden"), "403 降级为可读提示")
        XCTAssertTrue(try pendingStore.fetchAll().isEmpty, "终态错误不无限重试")
        XCTAssertEqual(metadata.lastAssignmentError, L10n.t("household.forbidden"))
        XCTAssertEqual(try deviceStore.fetch(id: device.id)?.roomID, room.id, "本机归属仍保留")
    }

    func testRetryableAssignmentFailureKeepsPendingAndRetriesLater() throws {
        let personal = makeHousehold(name: "我的家", personal: true, role: .member)
        try householdStore.upsert(personal)
        metadata.currentHouseholdRemoteID = personal.remoteID
        let room = Room(
            name: "客厅",
            sortOrder: 1,
            remoteID: "remote-living",
            householdID: personal.id,
            syncState: .synced
        )
        try roomStore.upsert(room)
        let device = makeDevice(roomID: nil, householdID: personal.id)
        try deviceStore.upsert(device)

        api.patchError = .failure(.network("offline"))
        var firstResult: AssignmentResult?
        service.assignDevice(device, room: room) { firstResult = $0 }
        XCTAssertEqual(firstResult?.reported, false)
        XCTAssertEqual(try pendingStore.fetchAll().count, 1, "网络失败保留 pending")

        api.patchError = nil
        var flushed = false
        service.flushPendingAssignments(token: "token-a") { flushed = true }
        XCTAssertTrue(flushed)
        XCTAssertTrue(try pendingStore.fetchAll().isEmpty, "重试成功后出队")
        XCTAssertEqual(try deviceStore.fetch(id: device.id)?.remoteRoomID, "remote-living")
    }

    func testMoveToUnassignedSendsEmptyRoomID() throws {
        let personal = makeHousehold(name: "我的家", personal: true, role: .member)
        try householdStore.upsert(personal)
        metadata.currentHouseholdRemoteID = personal.remoteID
        let device = makeDevice(roomID: nil, householdID: personal.id)
        try deviceStore.upsert(device)

        var result: AssignmentResult?
        service.assignDevice(device, room: nil) { result = $0 }
        XCTAssertEqual(result?.reported, true)
        XCTAssertEqual(api.patches.last?.roomRemoteID, "", "空串 = 清除房间归属")
    }

    // MARK: - 家庭切换

    func testSwitchHouseholdLimitsVisibleRooms() throws {
        let personal = makeHousehold(name: "我的家", personal: true, role: .owner)
        let shared = makeHousehold(name: "共享家", personal: false, role: .member)
        try householdStore.upsert(personal)
        try householdStore.upsert(shared)
        try roomStore.upsert(Room(name: "客厅", sortOrder: 1, householdID: personal.id, syncState: .synced))
        try roomStore.upsert(Room(name: "书房", sortOrder: 1, householdID: shared.id, syncState: .synced))
        try roomStore.upsert(Room(name: "本机房间", sortOrder: 2, syncState: .local))

        metadata.currentHouseholdRemoteID = personal.remoteID
        XCTAssertEqual(service.visibleRooms().map(\.name), ["客厅", "本机房间"])

        service.switchHousehold(localID: shared.id)
        XCTAssertEqual(service.visibleRooms().map(\.name), ["书房", "本机房间"])
        XCTAssertEqual(metadata.currentHouseholdRemoteID, shared.remoteID)
    }

    // MARK: - 离线房间

    func testOfflineRoomCreateKeepsLocalPendingAndNoRemoteID() throws {
        let personal = makeHousehold(name: "我的家", personal: true, role: .owner)
        try householdStore.upsert(personal)
        metadata.currentHouseholdRemoteID = personal.remoteID
        api.createRoomError = .failure(.network("offline"))

        var result: Result<RoomMutationResult, HouseholdAPIError>?
        service.createRoom(name: "阳台") { result = $0 }

        guard case .success(let mutation) = result else {
            return XCTFail("离线新建应成功落本机")
        }
        XCTAssertFalse(mutation.synced)
        XCTAssertNil(mutation.room?.remoteID)
        XCTAssertEqual(mutation.room?.syncState, .pending)
        XCTAssertEqual(mutation.room?.householdID, personal.id)
    }

    // MARK: - 远端设备解码

    func testRemoteDeviceDecodesHouseholdAndRoomAssignment() throws {
        let json = """
        {"id":"d1","clientId":"c1","platform":"ble","externalId":"ext-1","mac":"",
         "alias":"灯","advertisedName":"","group":"","householdId":"hh-1","roomId":"room-1",
         "updatedAt":"2026-11-05T10:00:00Z","deletedAt":null,"serverSeq":3}
        """
        let device = try JSONDecoder().decode(RemoteDevice.self, from: Data(json.utf8))
        XCTAssertEqual(device.householdID, "hh-1")
        XCTAssertEqual(device.roomID, "room-1")
        XCTAssertTrue(device.hasRoomField)

        let legacyJSON = """
        {"id":"d2","platform":"ble","externalId":"ext-2","alias":"灯","group":"",
         "updatedAt":"2026-11-05T10:00:00Z"}
        """
        let legacy = try JSONDecoder().decode(RemoteDevice.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.householdID)
        XCTAssertFalse(legacy.hasRoomField, "旧后端缺省时不覆盖本机归属")
    }

    // MARK: - Helpers

    private func makeHousehold(name: String, personal: Bool, role: HouseholdRole) -> Household {
        Household(
            id: UUID(),
            remoteID: UUID().uuidString.lowercased(),
            name: name,
            isPersonal: personal,
            role: role,
            memberCount: personal ? 1 : 2,
            deviceCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
    }

    private func makeDevice(roomID: UUID?, householdID: UUID? = nil) -> SavedDevice {
        SavedDevice(
            id: UUID(),
            peripheralID: UUID(),
            platform: "ble",
            externalID: "ext-\(UUID().uuidString.prefix(6))",
            advertisedName: "测试设备",
            roomID: roomID,
            householdID: householdID,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000),
            syncState: .synced
        )
    }
}

/// 家庭接口替身：记录调用并按预设返回，便于验证顺序与重试。
final class FakeHouseholdAPI: HouseholdAPIServicing {
    var households: [Household] = []
    var roomsByHousehold: [String: [RemoteHouseholdRoom]] = [:]
    var members: [HouseholdMember] = []
    var nextRoomIDs: [String] = []
    var createdRoomNames: [String] = []
    var createRoomError: HouseholdAPIError?
    var patchError: HouseholdAPIError?
    var invitation: HouseholdInvitation?
    var claimError: HouseholdAPIError?

    struct PatchCall: Equatable {
        let platform: String
        let externalID: String
        let roomRemoteID: String?
        let householdRemoteID: String?
    }

    private(set) var patches: [PatchCall] = []

    func listHouseholds(token: String, completion: @escaping (Result<[Household], HouseholdAPIError>) -> Void) {
        completion(.success(households))
    }

    func createHousehold(name: String, token: String, completion: @escaping (Result<Household, HouseholdAPIError>) -> Void) {
        let household = Household(
            id: UUID(),
            remoteID: UUID().uuidString.lowercased(),
            name: name,
            isPersonal: false,
            role: .owner,
            memberCount: 1,
            deviceCount: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        households.append(household)
        completion(.success(household))
    }

    func members(
        householdID: String,
        token: String,
        completion: @escaping (Result<[HouseholdMember], HouseholdAPIError>) -> Void
    ) {
        completion(.success(members))
    }

    func createInvitation(
        householdID: String,
        token: String,
        completion: @escaping (Result<HouseholdInvitation, HouseholdAPIError>) -> Void
    ) {
        completion(.success(invitation ?? HouseholdInvitation(
            code: "ABCD1234",
            expiresAt: Date().addingTimeInterval(600)
        )))
    }

    func claimInvitation(
        code: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        if let claimError {
            completion(.failure(claimError))
            return
        }
        let household = Household(
            id: UUID(),
            remoteID: UUID().uuidString.lowercased(),
            name: "共享家",
            isPersonal: false,
            role: .member,
            memberCount: 2,
            deviceCount: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        completion(.success(household))
    }

    func rooms(
        householdID: String,
        token: String,
        completion: @escaping (Result<[RemoteHouseholdRoom], HouseholdAPIError>) -> Void
    ) {
        completion(.success(roomsByHousehold[householdID] ?? []))
    }

    func createRoom(
        householdID: String,
        name: String,
        sortOrder: Int,
        token: String,
        completion: @escaping (Result<RemoteHouseholdRoom, HouseholdAPIError>) -> Void
    ) {
        if let createRoomError {
            completion(.failure(createRoomError))
            return
        }
        createdRoomNames.append(name)
        let remoteID = nextRoomIDs.isEmpty ? "remote-\(name)" : nextRoomIDs.removeFirst()
        let room = RemoteHouseholdRoom(
            id: remoteID,
            householdID: householdID,
            name: name,
            sortOrder: sortOrder,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        roomsByHousehold[householdID, default: []].append(room)
        completion(.success(room))
    }

    func updateRoom(
        householdID: String,
        roomID: String,
        name: String?,
        sortOrder: Int?,
        token: String,
        completion: @escaping (Result<RemoteHouseholdRoom, HouseholdAPIError>) -> Void
    ) {
        if let createRoomError {
            completion(.failure(createRoomError))
            return
        }
        let existing = (roomsByHousehold[householdID] ?? []).first { $0.id == roomID }
        completion(.success(RemoteHouseholdRoom(
            id: roomID,
            householdID: householdID,
            name: name ?? existing?.name ?? "",
            sortOrder: sortOrder ?? existing?.sortOrder ?? 0,
            createdAt: existing?.createdAt
        )))
    }

    func deleteRoom(
        householdID: String,
        roomID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        roomsByHousehold[householdID]?.removeAll { $0.id == roomID }
        completion(.success(()))
    }

    func patchDeviceAssignment(
        platform: String,
        externalID: String,
        roomID: String?,
        householdID: String?,
        token: String,
        completion: @escaping (Result<RemoteDevice, HouseholdAPIError>) -> Void
    ) {
        patches.append(PatchCall(
            platform: platform,
            externalID: externalID,
            roomRemoteID: roomID,
            householdRemoteID: householdID
        ))
        if let patchError {
            completion(.failure(patchError))
            return
        }
        let device = RemoteDevice(
            id: "d1",
            clientID: "c1",
            platform: platform,
            externalID: externalID,
            mac: nil,
            alias: nil,
            advertisedName: nil,
            group: nil,
            householdID: householdID,
            roomID: roomID,
            hasRoomField: true,
            updatedAt: Date(),
            deletedAt: nil,
            serverSeq: 1
        )
        completion(.success(device))
    }
}

/// 内存 token 存储，避免测试触碰 Keychain。
struct StubTokenStore: TokenStoring {
    let token: String

    func load() -> AnonymousSession? {
        AnonymousSession(userID: "user-test", token: token)
    }

    func save(_ session: AnonymousSession) throws { }

    func clear() { }
}
