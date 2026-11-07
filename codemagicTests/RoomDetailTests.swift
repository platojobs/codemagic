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
            serverLastSeenAt: now.addingTimeInterval(-16 * 60)
        )
        let recent = makeDevice(
            name: "面板",
            roomID: room.id,
            serverLastSeenAt: now.addingTimeInterval(-60)
        )
        let outside = makeDevice(name: "卧室设备", roomID: otherRoom.id)
        for device in [marked, recent, outside] {
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
        XCTAssertEqual(viewModel.localConnectedCount, 0)
        XCTAssertEqual(viewModel.cloudRecentCount, 1)
        XCTAssertEqual(viewModel.cloudStaleCount, 1)
        XCTAssertEqual(viewModel.cloudUnknownCount, 0)
        XCTAssertEqual(viewModel.remoteCount, 0)
        XCTAssertEqual(viewModel.markedCount, 1)
        XCTAssertEqual(
            viewModel.summaryText,
            L10n.f("room.detail.summary", "2", "0", "1", "1", "0", "1", "0")
        )
        XCTAssertEqual(viewModel.entries.map(\.device.displayName), ["面板", "温度计"], "云端最近上报优先，其次按名称")
        XCTAssertEqual(viewModel.entries[0].readingText, L10n.t("room.detail.noReading"), "无读数不补造")
        XCTAssertTrue(viewModel.entries[1].readingText.contains("24.5"))
        XCTAssertEqual(viewModel.entries[1].markText, L10n.t("device.marked"))
        XCTAssertNil(viewModel.entries[0].markText)
    }

    func testOnlyBLEConnectionCountsAsLocalAndRecentScanDoesNot() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let bluetooth = FakeBluetoothService()
        let connected = makeDevice(name: "已连接", roomID: room.id)
        bluetooth.markConnected(connected.peripheralID)
        let recentScan = makeDevice(name: "刚扫描到", roomID: room.id, lastSeenAt: now.addingTimeInterval(-60))
        let staleScan = makeDevice(name: "很久没扫描到", roomID: room.id, lastSeenAt: now.addingTimeInterval(-16 * 60))
        let crossPlatform = makeDevice(name: "安卓设备", roomID: room.id, platform: "android")
        for device in [connected, recentScan, staleScan, crossPlatform] {
            try deviceStore.upsert(device)
        }

        let viewModel = makeViewModel(room: room, bluetooth: bluetooth)
        viewModel.reload()

        XCTAssertEqual(viewModel.localConnectedCount, 1, "只有 BLE 已连接才算本机已连接")
        XCTAssertEqual(viewModel.cloudRecentCount, 0)
        XCTAssertEqual(viewModel.cloudStaleCount, 0)
        XCTAssertEqual(
            viewModel.cloudUnknownCount, 3,
            "15 分钟内本机扫描到不再算在线；从未上报读数的设备单独一档"
        )
        XCTAssertEqual(viewModel.remoteCount, 1, "跨平台设备是附加说明，不占独立档位")
        let recentEntry = viewModel.entries.first { $0.device.displayName == "刚扫描到" }
        XCTAssertEqual(recentEntry?.linkStatus.tier, .cloudUnknown, "本机扫描不能替代服务端上报窗口")
        XCTAssertEqual(recentEntry?.statusText, L10n.t("device.link.cloudUnknown"))
        let crossPlatformEntry = viewModel.entries.first { $0.device.displayName == "安卓设备" }
        XCTAssertEqual(crossPlatformEntry?.linkStatus.tier, .cloudUnknown)
        XCTAssertEqual(
            crossPlatformEntry?.statusText,
            crossPlatformEntry?.device.connectUnavailableText,
            "本机不可连接时如实说明来源边界，不宣称离线"
        )
        XCTAssertEqual(
            crossPlatformEntry?.presenceNote,
            L10n.t("device.link.cloudUnknown"),
            "本机不可连接与云端状态同时呈现，不互相遮蔽"
        )
    }

    func testPresenceThreeStatesUseServerLastSeenAndNeverClaimOnline() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let reported = makeDevice(
            name: "刚上报",
            roomID: room.id,
            serverLastSeenAt: now.addingTimeInterval(-120)
        )
        let stale = makeDevice(
            name: "久未上报",
            roomID: room.id,
            serverLastSeenAt: now.addingTimeInterval(-2 * 60 * 60)
        )
        let never = makeDevice(name: "从未上报", roomID: room.id)
        for device in [reported, stale, never] {
            try deviceStore.upsert(device)
        }

        let viewModel = makeViewModel(room: room)
        viewModel.reload()

        XCTAssertEqual(viewModel.localConnectedCount, 0)
        XCTAssertEqual(viewModel.cloudRecentCount, 1)
        XCTAssertEqual(viewModel.cloudStaleCount, 1)
        XCTAssertEqual(viewModel.cloudUnknownCount, 1, "unknown 不并进上报超时")
        XCTAssertEqual(viewModel.entries.map(\.device.displayName), ["刚上报", "久未上报", "从未上报"])

        let reportedEntry = viewModel.entries[0]
        XCTAssertEqual(reportedEntry.presence, .online)
        XCTAssertEqual(reportedEntry.statusText, L10n.t("device.link.cloudRecent"))
        XCTAssertEqual(
            reportedEntry.presenceNote,
            L10n.f(
                "device.link.serverLastReported",
                RelativeTimeText.short(for: now.addingTimeInterval(-120), relativeTo: now)
            )
        )
        XCTAssertFalse(reportedEntry.statusText.contains("在线"), "不得把服务端推导写成在线")

        let staleEntry = viewModel.entries[1]
        XCTAssertEqual(staleEntry.presence, .offline)
        XCTAssertEqual(staleEntry.statusText, L10n.t("device.link.cloudStale"))
        XCTAssertEqual(
            staleEntry.presenceNote,
            L10n.f(
                "device.link.serverLastReported",
                RelativeTimeText.short(for: now.addingTimeInterval(-2 * 60 * 60), relativeTo: now)
            ),
            "上报超时也要给出具体最近上报时间，不写成「已离线」"
        )

        let neverEntry = viewModel.entries[2]
        XCTAssertEqual(neverEntry.presence, .unknown)
        XCTAssertEqual(neverEntry.statusText, L10n.t("device.link.cloudUnknown"))
        XCTAssertNil(neverEntry.presenceNote, "从未上报且本机无扫描记录时不再编造时间")
    }

    func testPresenceWindowBoundaryAtNineHundredSeconds() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let boundary = makeDevice(
            name: "边界",
            roomID: room.id,
            serverLastSeenAt: now.addingTimeInterval(-DevicePresence.window)
        )
        let justOver = makeDevice(
            name: "超窗",
            roomID: room.id,
            serverLastSeenAt: now.addingTimeInterval(-(DevicePresence.window + 1))
        )
        for device in [boundary, justOver] {
            try deviceStore.upsert(device)
        }

        let viewModel = makeViewModel(room: room)
        viewModel.reload()

        XCTAssertEqual(viewModel.entries.first { $0.device.displayName == "边界" }?.presence, .online)
        XCTAssertEqual(viewModel.entries.first { $0.device.displayName == "超窗" }?.presence, .offline)
        XCTAssertEqual(viewModel.cloudRecentCount, 1)
        XCTAssertEqual(viewModel.cloudStaleCount, 1, "900 秒内为云端最近上报，超过即上报超时")
    }

    func testLocalConnectionTakesPriorityOverStaleServerPresence() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let bluetooth = FakeBluetoothService()
        let connected = makeDevice(
            name: "本机已连接",
            roomID: room.id,
            serverLastSeenAt: now.addingTimeInterval(-3 * 60 * 60)
        )
        bluetooth.markConnected(connected.peripheralID)
        try deviceStore.upsert(connected)

        let viewModel = makeViewModel(room: room, bluetooth: bluetooth)
        viewModel.reload()

        XCTAssertEqual(viewModel.localConnectedCount, 1, "本机 BLE 连接优先，服务端超时不被说成本机在线")
        XCTAssertEqual(viewModel.cloudStaleCount, 0, "本机已连接时不占云端档位")
        XCTAssertEqual(viewModel.entries[0].statusText, L10n.t("device.link.localConnected"))
        XCTAssertEqual(
            viewModel.entries[0].presenceNote,
            "\(L10n.t("device.link.cloudStale")) · "
                + L10n.f(
                    "device.link.serverLastReported",
                    RelativeTimeText.short(for: now.addingTimeInterval(-3 * 60 * 60), relativeTo: now)
                ),
            "本机连接与云端超时同时呈现，不互相遮蔽"
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
            L10n.f("room.detail.summary", "0", "0", "0", "0", "0", "0", "0")
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

    // MARK: - 云端读数

    func testCloudReadingFillsMissingLocalReadingAndKeepsSourceBoundary() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let device = makeDevice(
            name: "客厅温湿度计",
            roomID: room.id,
            platform: "android",
            serverLastSeenAt: now.addingTimeInterval(-60)
        )
        try deviceStore.upsert(device)
        let cloud = FakeCloudReadings()
        cloud.states[cloudKey(for: device)] = .available(CloudLatestReading(
            metric: .temperature,
            rawMetric: "temperature_celsius",
            value: 24.5,
            unit: "celsius",
            reportedAt: now.addingTimeInterval(-600)
        ))

        let viewModel = makeViewModel(room: room, cloudReadings: cloud)
        viewModel.reload()

        let entry = try XCTUnwrap(viewModel.entries.first)
        XCTAssertTrue(entry.readingText.contains("温度"), "服务端指标名映射为本地化标题")
        XCTAssertTrue(entry.readingText.contains("24.5"))
        XCTAssertEqual(entry.readingText, "温度\u{00A0}24.5\u{00A0}℃")
        XCTAssertNotNil(entry.cloudNote, "使用云端数据时标注上报时间")
        XCTAssertEqual(entry.statusText, device.connectUnavailableText, "跨平台设备不宣称离线")
    }

    func testLocalReadingTakesPrecedenceOverCloudAndSkipsRequest() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let device = makeDevice(
            name: "面板",
            roomID: room.id,
            serverLastSeenAt: now.addingTimeInterval(-60)
        )
        try deviceStore.upsert(device)
        try readingsStore.insert(DeviceReading(
            deviceID: device.id,
            metric: .temperature,
            value: 21.2,
            unit: "℃",
            recordedAt: now.addingTimeInterval(-120),
            syncState: .synced
        ))
        let cloud = FakeCloudReadings()
        cloud.states[cloudKey(for: device)] = .available(CloudLatestReading(
            metric: .humidity,
            rawMetric: "relative_humidity",
            value: 52,
            unit: "%",
            reportedAt: now.addingTimeInterval(-60)
        ))

        let viewModel = makeViewModel(room: room, cloudReadings: cloud)
        viewModel.reload()

        let entry = try XCTUnwrap(viewModel.entries.first)
        XCTAssertTrue(entry.readingText.contains("21.2"), "本机读数优先")
        XCTAssertNil(entry.cloudNote, "未使用云端数据时不标注云端来源")
        XCTAssertTrue(cloud.requested.isEmpty, "本机已有读数时不再为云端读数白跑往返")
    }

    func testCloudFailureShowsUnavailableRatherThanNoReading() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let device = makeDevice(
            name: "客厅温湿度计",
            roomID: room.id,
            platform: "android",
            serverLastSeenAt: now.addingTimeInterval(-60)
        )
        try deviceStore.upsert(device)
        let cloud = FakeCloudReadings()
        cloud.states[cloudKey(for: device)] = .failed

        let viewModel = makeViewModel(room: room, cloudReadings: cloud)
        viewModel.reload()

        let entry = try XCTUnwrap(viewModel.entries.first)
        XCTAssertEqual(entry.readingText, L10n.t("room.detail.cloudUnavailable"), "拉不到不等于没有读数")
        XCTAssertEqual(entry.statusText, device.connectUnavailableText, "查询失败不能显示成设备离线")
    }

    func testCloudEmptyAndNoLocalReadingStaysNoReading() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let device = makeDevice(
            name: "客厅温湿度计",
            roomID: room.id,
            platform: "android",
            serverLastSeenAt: now.addingTimeInterval(-60)
        )
        try deviceStore.upsert(device)
        let cloud = FakeCloudReadings()
        cloud.states[cloudKey(for: device)] = .empty

        let viewModel = makeViewModel(room: room, cloudReadings: cloud)
        viewModel.reload()

        let entry = try XCTUnwrap(viewModel.entries.first)
        XCTAssertEqual(entry.readingText, L10n.t("room.detail.noReading"))
        XCTAssertNil(entry.cloudNote)
    }

    func testUnknownPresenceSkipsCloudReadingsRequest() throws {
        let room = try roomStore.create(name: "客厅", at: now)
        let device = makeDevice(name: "从未上报", roomID: room.id)
        try deviceStore.upsert(device)
        let cloud = FakeCloudReadings()

        let viewModel = makeViewModel(room: room, cloudReadings: cloud)
        viewModel.reload()

        XCTAssertTrue(cloud.requested.isEmpty, "presence=unknown 时服务端从未接受过读数，不应再请求 metrics + limit=1")
        let entry = try XCTUnwrap(viewModel.entries.first)
        XCTAssertEqual(entry.readingText, L10n.t("room.detail.noReading"), "跳过请求不能显示成「正在读取」")
        XCTAssertEqual(entry.cloudReading, .empty)
    }

    // MARK: - Helpers

    private func cloudKey(for device: SavedDevice) -> String {
        "\(device.platform):\(device.externalID)"
    }

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
        householdService: HouseholdService? = nil,
        cloudReadings: CloudLatestReadingsProviding? = nil
    ) -> RoomDetailViewModel {
        RoomDetailViewModel(
            room: room,
            roomStore: roomStore,
            deviceStore: deviceStore,
            readingsStore: readingsStore,
            bluetooth: bluetooth,
            householdService: householdService,
            syncEngine: nil,
            cloudReadings: cloudReadings,
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
        lastSeenAt: Date? = nil,
        serverLastSeenAt: Date? = nil
    ) -> SavedDevice {
        SavedDevice(
            peripheralID: UUID(),
            platform: platform,
            advertisedName: name,
            roomID: roomID,
            householdID: householdID,
            lastSeenAt: lastSeenAt,
            serverLastSeenAt: serverLastSeenAt,
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

/// 同步返回的云端读数替身：按 `platform:externalID` 预设状态。
final class FakeCloudReadings: CloudLatestReadingsProviding {
    var states: [String: CloudLatestReadingState] = [:]
    private(set) var requested: [String] = []

    func latestReading(
        platform: String,
        externalID: String,
        completion: @escaping (CloudLatestReadingState) -> Void
    ) {
        let key = "\(platform):\(externalID)"
        requested.append(key)
        completion(states[key] ?? .empty)
    }
}
