import XCTest
@testable import codemagic

/// 房间详情：聚合总数 / 在线 / 离线 / 已标记、最新真实读数、批量标记与待同步、成员只读。
final class RoomDetailTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var database: SQLiteDatabase!
    private var deviceStore: SavedDeviceStore!
    private var roomStore: RoomStore!
    private var readingsStore: ReadingsStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        database = testDatabase.database
        deviceStore = SavedDeviceStore(database: database)
        roomStore = RoomStore(database: database)
        readingsStore = ReadingsStore(database: database)
    }

    override func tearDown() {
        testDatabase?.cleanUp()
        testDatabase = nil
        super.tearDown()
    }

    // MARK: - 聚合

    func testSummaryReadsSameLocalDeviceDataWithRealLatestReading() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let otherRoom = try roomStore.create(name: "卧室", at: now)
        let markedAt = now.addingTimeInterval(-3_600)
        let marked = makeDevice(
            name: "温度计",
            roomID: room.id,
            markedAt: markedAt,
            lastSeenAt: now.addingTimeInterval(-16 * 60)
        )
        let online = makeDevice(
            name: "面板",
            roomID: room.id,
            lastSeenAt: now.addingTimeInterval(-60)
        )
        let outside = makeDevice(name: "卧室设备", roomID: otherRoom.id)
        for device in [marked, online, outside] {
            try deviceStore.upsert(device)
        }
        try readingsStore.insert(DeviceReading(
            deviceID: marked.id,
            metric: .temperature,
            value: 24.5,
            unit: "℃",
            recordedAt: now.addingTimeInterval(-120),
            syncState: .synced
        ))

        let viewModel = makeViewModel(room: room)
        viewModel.reload()

        XCTAssertEqual(viewModel.totalCount, 2, "只聚合本房间设备")
        XCTAssertEqual(viewModel.onlineCount, 1)
        XCTAssertEqual(viewModel.offlineCount, 1)
        XCTAssertEqual(viewModel.markedCount, 1)
        XCTAssertEqual(
            viewModel.summaryText,
            L10n.f("room.detail.summary", "2", "1", "1", "1")
        )
        XCTAssertEqual(viewModel.entries.map(\.device.displayName), ["面板", "温度计"], "在线优先，其次按名称")
        XCTAssertEqual(viewModel.entries[0].readingText, L10n.t("room.detail.noReading"), "无读数不补造")
        XCTAssertTrue(viewModel.entries[1].readingText.contains("24.5"))
        XCTAssertEqual(viewModel.entries[1].markText, L10n.t("device.marked"))
        XCTAssertNil(viewModel.entries[0].markText)
    }

    func testOnlineUsesConnectedOrRecentlySeenAndCrossPlatformStaysOffline() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let bluetooth = FakeBluetoothService()
        let connected = makeDevice(name: "已连接", roomID: room.id)
        bluetooth.markConnected(connected.peripheralID)
        let recent = makeDevice(name: "刚出现", roomID: room.id, lastSeenAt: now.addingTimeInterval(-60))
        let stale = makeDevice(name: "很久没出现", roomID: room.id, lastSeenAt: now.addingTimeInterval(-16 * 60))
        let crossPlatform = makeDevice(name: "安卓设备", roomID: room.id, platform: "android")
        for device in [connected, recent, stale, crossPlatform] {
            try deviceStore.upsert(device)
        }

        let viewModel = makeViewModel(room: room, bluetooth: bluetooth)
        viewModel.reload()

        XCTAssertEqual(viewModel.onlineCount, 2)
        XCTAssertEqual(viewModel.offlineCount, 2)
        XCTAssertEqual(
            viewModel.entries.first { $0.device.displayName == "安卓设备" }?.isOnline,
            false,
            "跨平台设备本机不可连接，按离线计数"
        )
    }

    // MARK: - 批量标记

    func testMarkAllWritesPendingThenSyncClearsIt() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let first = makeDevice(name: "A", roomID: room.id, lastSeenAt: now)
        let second = makeDevice(name: "B", roomID: room.id, lastSeenAt: now)
        for device in [first, second] {
            try deviceStore.upsert(device)
        }

        let viewModel = makeViewModel(room: room)
        viewModel.reload()
        XCTAssertTrue(viewModel.canMark)
        XCTAssertFalse(viewModel.canUnmark)

        viewModel.markAll()
        XCTAssertEqual(viewModel.markedCount, 2)
        XCTAssertEqual(viewModel.pendingMarkCount, 2)
        XCTAssertEqual(viewModel.notice, L10n.f("room.detail.markDone", "2"))
        XCTAssertNotNil(viewModel.pendingHint, "未同步必须显示待同步")
        XCTAssertEqual(viewModel.entries.first?.markText, L10n.t("device.markedPending"))
        XCTAssertEqual(viewModel.entries.first?.device.markedAt?.timeIntervalSince1970, now.timeIntervalSince1970)
        XCTAssertEqual(viewModel.entries.first?.device.syncState, .pending)

        try deviceStore.markSynced(ids: [first.id, second.id], at: now)
        viewModel.reload()
        XCTAssertEqual(viewModel.pendingMarkCount, 0)
        XCTAssertNil(viewModel.pendingHint)
        XCTAssertEqual(viewModel.entries.first?.markText, L10n.t("device.marked"))
        XCTAssertFalse(viewModel.canMark)
        XCTAssertTrue(viewModel.canUnmark)
    }

    func testUnmarkAllKeepsClearPatchVisibleUntilSynced() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let device = makeDevice(
            name: "A",
            roomID: room.id,
            markedAt: now.addingTimeInterval(-600),
            lastSeenAt: now
        )
        try deviceStore.upsert(device)

        let viewModel = makeViewModel(room: room)
        viewModel.reload()
        XCTAssertEqual(viewModel.markedCount, 1)
        XCTAssertFalse(viewModel.canMark)

        viewModel.unmarkAll()
        XCTAssertEqual(viewModel.markedCount, 0)
        XCTAssertEqual(viewModel.pendingMarkCount, 1)
        XCTAssertEqual(viewModel.notice, L10n.f("room.detail.unmarkDone", "1"))
        XCTAssertEqual(viewModel.entries.first?.device.markedAtPatch, .clear)
        XCTAssertEqual(viewModel.entries.first?.device.markedAt, nil)
        XCTAssertEqual(viewModel.entries.first?.markText, L10n.t("room.detail.unmarkPending"))
        XCTAssertFalse(viewModel.canUnmark)
        XCTAssertTrue(viewModel.canMark)

        try deviceStore.markSynced(ids: [device.id], at: now)
        viewModel.reload()
        XCTAssertEqual(viewModel.pendingMarkCount, 0)
        XCTAssertNil(viewModel.entries.first?.markText, "同步后不再显示待同步")
    }

    func testBatchUpdateMarkIsNoOpForEmptyIDs() throws {
        let device = makeDevice(name: "A", roomID: nil, markedAt: now)
        try deviceStore.upsert(device)
        try deviceStore.updateMark(ids: [], markedAt: nil, at: now)
        let reloaded = try XCTUnwrap(try deviceStore.fetch(id: device.id))
        XCTAssertEqual(reloaded.markedAt, now)
        XCTAssertEqual(reloaded.markedAtPatch, .absent)
    }

    // MARK: - 权限与空态

    func testMemberHouseholdShowsOwnerOnlyReadOnlyNote() throws {
        let household = makeHousehold(role: .member)
        let service = try makeHouseholdService(household: household)
        let room = try roomStore.create(name: "客厅", at: now, householdID: household.id)

        let viewModel = makeViewModel(room: room, householdService: service)
        viewModel.reload()
        XCTAssertFalse(viewModel.canManageRooms)
        XCTAssertEqual(viewModel.readOnlyNote, L10n.t("room.detail.readonlyNote"))
    }

    func testOwnerHouseholdHasNoReadOnlyNote() throws {
        let household = makeHousehold(role: .owner)
        let service = try makeHouseholdService(household: household)
        let room = try roomStore.create(name: "客厅", at: now, householdID: household.id)

        let viewModel = makeViewModel(room: room, householdService: service)
        viewModel.reload()
        XCTAssertTrue(viewModel.canManageRooms)
        XCTAssertNil(viewModel.readOnlyNote)
    }

    func testEmptyRoomReportsZeroAndRealEmptyState() throws {
        let room = try roomStore.create(name: "空房间", at: now)
        let viewModel = makeViewModel(room: room)
        viewModel.reload()

        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertEqual(viewModel.totalCount, 0)
        XCTAssertEqual(
            viewModel.summaryText,
            L10n.f("room.detail.summary", "0", "0", "0", "0")
        )
        XCTAssertFalse(L10n.t("room.detail.emptyTitle").isEmpty)
        XCTAssertFalse(L10n.t("room.detail.emptyMessage").isEmpty)
    }

    func testDevicesOfAnotherHouseholdAreNotAggregated() throws {
        let household = makeHousehold(role: .owner)
        let service = try makeHouseholdService(household: household)
        let room = try roomStore.create(name: "客厅", at: now, householdID: household.id)
        let visible = makeDevice(name: "本家庭", roomID: room.id, householdID: household.id)
        let hidden = makeDevice(name: "别的家庭", roomID: room.id, householdID: UUID())
        try deviceStore.upsert(visible)
        try deviceStore.upsert(hidden)

        let viewModel = makeViewModel(room: room, householdService: service)
        viewModel.reload()
        XCTAssertEqual(viewModel.entries.map(\.device.displayName), ["本家庭"])
    }

    // MARK: - 大字号 / iPad 布局

    func testRoomDetailLayoutAtAX5StacksActionsAndKeepsTextUntruncated() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let online = makeDevice(name: "客厅温湿度计（较长的设备名称用于折行）", roomID: room.id, lastSeenAt: now)
        let offline = makeDevice(name: "客厅心率带", roomID: room.id, lastSeenAt: now.addingTimeInterval(-3_600))
        for device in [online, offline] {
            try deviceStore.upsert(device)
        }

        let controller = makeViewController(room: room)
        let window = host(
            controller,
            size: CGSize(width: 430, height: 900),
            category: .accessibilityExtraExtraExtraLarge
        )
        _ = window

        XCTAssertEqual(controller.actionsRowForTesting.axis, .vertical, "AX 档批量按钮改为上下堆叠")
        XCTAssertEqual(controller.summaryLabelNumberOfLinesForTesting, 0)
        XCTAssertEqual(controller.readOnlyLabelNumberOfLinesForTesting, 0)

        let button = controller.markButtonForTesting
        let lineHeight = try XCTUnwrap(button.titleLabel?.font.lineHeight)
        XCTAssertGreaterThan(button.bounds.height, lineHeight, "按钮高度必须容纳放大后的标题，不能被 48pt 固定高度裁掉")
        XCTAssertGreaterThan(button.titleLabel?.font.pointSize ?? 0, AppText.body.size, "按钮标题跟随 Dynamic Type")

        let cell = controller.tableView(controller.tableViewForTesting, cellForRowAt: IndexPath(row: 0, section: 0))
        let content = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(content.textProperties.numberOfLines, 0, "设备名称在 AX 档必须允许折行")
        XCTAssertEqual(content.secondaryTextProperties.numberOfLines, 0)
        XCTAssertGreaterThan(cell.systemLayoutSizeFitting(
            CGSize(width: controller.tableViewForTesting.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height, Layout.buttonH, "AX 档设备行高度随两行元信息增长")
    }

    func testRoomDetailOnIPadWidthStaysCenteredAndButtonsDoNotOverflow() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        try deviceStore.upsert(makeDevice(name: "客厅温湿度计", roomID: room.id, lastSeenAt: now))

        let controller = makeViewController(room: room)
        let window = host(
            controller,
            size: CGSize(width: 1024, height: 1366),
            category: .large
        )
        _ = window

        let table = controller.tableViewForTesting
        XCTAssertEqual(table.bounds.width, Layout.contentMaxWidth, "iPad 宽度下内容限制在 760pt")
        XCTAssertEqual(table.frame.midX, controller.view.bounds.midX, accuracy: 0.5, "内容水平居中，不挤在左侧")
        XCTAssertEqual(controller.actionsRowForTesting.axis, .horizontal)

        let button = controller.markButtonForTesting
        XCTAssertGreaterThan(button.bounds.width, 0)
        XCTAssertLessThanOrEqual(button.bounds.maxX, table.bounds.width, "按钮不超出内容宽度")
        XCTAssertEqual(button.bounds.height, Layout.buttonH, accuracy: 0.5, "常规字号仍保持 48pt 高度")
    }

    // MARK: - Helpers

    private func makeViewController(room: Room) -> RoomDetailViewController {
        let viewModel = makeViewModel(room: room)
        return RoomDetailViewController(viewModel: viewModel, onSelectDevice: { _ in })
    }

    /// 放进带内容尺寸覆盖的窗口，让 Dynamic Type 真正传播到 VC 及其子视图。
    private func host(
        _ controller: RoomDetailViewController,
        size: CGSize,
        category: UIContentSizeCategory
    ) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if #available(iOS 17.0, *) {
            window.traitOverrides.preferredContentSizeCategory = category
            controller.traitOverrides.preferredContentSizeCategory = category
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.tableViewForTesting.tableHeaderView?.layoutIfNeeded()
        return window
    }

    private func makeViewModel(
        room: Room,
        bluetooth: FakeBluetoothService = FakeBluetoothService(),
        householdService: HouseholdService? = nil
    ) -> RoomDetailViewModel {
        RoomDetailViewModel(
            room: room,
            roomStore: roomStore,
            deviceStore: deviceStore,
            readingsStore: readingsStore,
            bluetooth: bluetooth,
            householdService: householdService,
            syncEngine: nil,
            now: { [now] in now }
        )
    }

    private func makeDevice(
        name: String,
        roomID: UUID?,
        householdID: UUID? = nil,
        platform: String = SavedDevice.iosPlatform,
        markedAt: Date? = nil,
        markedAtPatch: Patch<Date> = .absent,
        lastSeenAt: Date? = nil
    ) -> SavedDevice {
        SavedDevice(
            peripheralID: UUID(),
            platform: platform,
            advertisedName: name,
            roomID: roomID,
            householdID: householdID,
            lastSeenAt: lastSeenAt,
            markedAt: markedAt,
            syncState: .synced,
            markedAtPatch: markedAtPatch
        )
    }

    private func makeHousehold(role: HouseholdRole) -> Household {
        Household(
            id: UUID(),
            remoteID: UUID().uuidString,
            name: "测试家庭",
            isPersonal: false,
            role: role,
            memberCount: 2,
            deviceCount: 0,
            roomCount: 1,
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeHouseholdService(household: Household) throws -> HouseholdService {
        let householdStore = HouseholdStore(database: database)
        try householdStore.upsert(household)
        return HouseholdService(
            api: UnavailableHouseholdAPI(),
            tokenStore: StubTokenStore(token: "test-token"),
            householdStore: householdStore,
            roomStore: roomStore,
            deviceStore: deviceStore,
            pendingStore: DeviceAssignmentPendingStore(database: database),
            metadataStore: SyncMetadataStore(),
            logStore: ScanLogStore(database: database),
            now: { [now] in now }
        )
    }
}
