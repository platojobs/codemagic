import UIKit
import XCTest
@testable import codemagic

/// RSSI 分档规范（`PKotlinApp/docs/rssi-signal-tiers.md`）的 iOS 回归：
/// 边界值、全区间扫描、未知与极弱的区分、非法读数与设备卡显示条件。
final class RSISignalTests: XCTestCase {
    // MARK: - Boundaries

    /// 八个边界值逐值锁定：每档含下限，-55 起四格，-86 起零格。
    func testBoundaryValuesMatchSpec() {
        let cases: [(rssi: Int, bars: Int)] = [
            (-55, 4),
            (-56, 3),
            (-66, 3),
            (-67, 2),
            (-75, 2),
            (-76, 1),
            (-85, 1),
            (-86, 0),
        ]
        for item in cases {
            XCTAssertEqual(
                RSISignalView.tier(for: item.rssi).barCount,
                item.bars,
                "\(item.rssi) dBm 应为 \(item.bars) 格"
            )
        }
    }

    /// 全区间扫描：档位随 dBm 增大单调不降，相邻值档差只能是 0 或 1（无空隙、无跳档）。
    func testFullRangeIsMonotonicAndGapFree() {
        let range = -200...(-1)
        var previous = RSISignalView.tier(for: range.lowerBound).barCount

        for rssi in range {
            let bars = RSISignalView.tier(for: rssi).barCount
            XCTAssertTrue((0...4).contains(bars), "\(rssi) dBm 未落到任何档")
            XCTAssertGreaterThanOrEqual(bars, previous, "\(rssi) dBm 档位出现回退")
            XCTAssertLessThanOrEqual(bars - previous, 1, "\(rssi) dBm 与上一个值之间跳档")
            previous = bars
        }

        // 五个有效档全部覆盖，说明区间没有被漏掉。
        let levels = Set(range.map { RSISignalView.tier(for: $0).barCount })
        XCTAssertEqual(levels, [0, 1, 2, 3, 4])
        XCTAssertEqual(RSISignalView.tier(for: range.lowerBound).barCount, 0, "越界负数归极弱")
    }

    /// 每个档位切换点必须恰好出现在规范边界上，不多不少。
    func testTierTransitionsOccurOnlyAtSpecifiedBoundaries() {
        var transitions: [(rssi: Int, from: Int, to: Int)] = []
        var previous = RSISignalView.tier(for: -200).barCount
        for rssi in -199...(-1) {
            let current = RSISignalView.tier(for: rssi).barCount
            if current != previous {
                transitions.append((rssi, previous, current))
            }
            previous = current
        }
        XCTAssertEqual(transitions.map(\.rssi), [-85, -75, -66, -55])
        XCTAssertEqual(transitions.map(\.from), [0, 1, 2, 3])
        XCTAssertEqual(transitions.map(\.to), [1, 2, 3, 4])
    }

    // MARK: - Unknown

    /// 未知（nil）与极弱（≤ -86）格数相同但档位与文案必须区分。
    func testUnknownIsDistinctFromVeryWeak() {
        XCTAssertEqual(RSISignalView.tier(for: nil), .unknown)
        XCTAssertEqual(RSISignalView.tier(for: -86), .veryWeak)
        XCTAssertEqual(RSISignalView.tier(for: nil).barCount, 0)
        XCTAssertEqual(RSISignalView.tier(for: -86).barCount, 0)

        let unknownView = RSISignalView()
        unknownView.rssi = nil
        let unknownLabel = unknownView.accessibilityLabel ?? ""

        let veryWeakView = RSISignalView()
        veryWeakView.rssi = -86
        let veryWeakLabel = veryWeakView.accessibilityLabel ?? ""

        XCTAssertEqual(unknownLabel, L10n.t("signal.unknown"))
        XCTAssertNotEqual(unknownLabel, veryWeakLabel)
        XCTAssertTrue(veryWeakLabel.contains(L10n.t("signal.tier.veryWeak")))
        XCTAssertFalse(unknownLabel.contains(L10n.t("signal.tier.veryWeak")))
        XCTAssertFalse(unknownLabel.contains("-86"), "未知不得显示 dBm 数值")
    }

    // MARK: - Invalid Values

    /// 合法 dBm 恒为负数：0 / 127 之类占位值按未知处理，不能显示成满格。
    func testNonNegativeValuesAreTreatedAsUnknown() {
        for value in [0, 1, 64, 127, 255] {
            XCTAssertFalse(RSISignalView.isValid(value), "\(value) 不应是合法 RSSI")
            XCTAssertEqual(RSISignalView.tier(for: value), .unknown, "\(value) 应按未知处理")
        }
        XCTAssertFalse(RSISignalView.isValid(nil))

        let view = RSISignalView()
        view.rssi = 0
        XCTAssertEqual(view.signalLevel, 0)
        XCTAssertEqual(view.accessibilityLabel, L10n.t("signal.unknown"))
    }

    func testNegativeValuesIncludingOutOfRangeAreValid() {
        XCTAssertTrue(RSISignalView.isValid(-1))
        XCTAssertTrue(RSISignalView.isValid(-100))
        XCTAssertTrue(RSISignalView.isValid(-200))
        XCTAssertEqual(RSISignalView.tier(for: -100), .veryWeak)
        XCTAssertEqual(RSISignalView.tier(for: -200), .veryWeak)
    }

    /// `Int.min` 是跨端「未知」哨兵值，不能当成合法 dBm 或极弱信号。
    func testIntMinSentinelIsUnknown() {
        XCTAssertFalse(RSISignalView.isValid(Int.min))
        XCTAssertEqual(RSISignalView.tier(for: Int.min), .unknown)
        XCTAssertEqual(RSISignalView.tier(for: Int.min).barCount, 0)

        let view = RSISignalView()
        view.rssi = Int.min
        XCTAssertEqual(view.signalLevel, 0)
        XCTAssertEqual(view.accessibilityLabel, L10n.t("signal.unknown"))
        XCTAssertFalse((view.accessibilityLabel ?? "").contains("dBm"), "未知不得显示 dBm 数值")
    }

    // MARK: - Presentation

    /// 设备卡只在「本机已连接且读数合法」时显示信号条，未连接不保留上次扫描的缓存值。
    func testDeviceCardShowsSignalOnlyWhenLocallyConnectedWithValidReading() {
        let device = makeSavedDevice()
        let cell = DeviceCardCell(frame: CGRect(x: 0, y: 0, width: 180, height: 164))
        func configure(isConnected: Bool, rssi: Int?) {
            cell.configure(
                device: device,
                isConnected: isConnected,
                presence: .unknown,
                readingText: "",
                rssi: rssi,
                onTap: {}
            )
        }

        configure(isConnected: false, rssi: -60)
        XCTAssertTrue(signalView(in: cell).isHidden, "未连接时不得显示缓存的信号格")

        configure(isConnected: true, rssi: -60)
        XCTAssertFalse(signalView(in: cell).isHidden)

        configure(isConnected: true, rssi: 0)
        XCTAssertTrue(signalView(in: cell).isHidden, "非法读数按未知处理，不显示满格")
    }

    /// 详情信号行的未知态不出现 dBm 文本。
    func testSignalCellHidesdBmWhenReadingIsUnknown() {
        let cell = DeviceSignalCell(style: .default, reuseIdentifier: nil)

        cell.configure(reading: .init(rssi: -72, readAt: Date(timeIntervalSince1970: 1_700_000_000), status: .live))
        XCTAssertTrue(allLabelTexts(in: cell).contains { $0.contains("-72 dBm") })
        XCTAssertTrue(allLabelTexts(in: cell).contains { $0.contains("/4 格") })
        XCTAssertTrue(allLabelTexts(in: cell).contains { $0.contains("实时读数") })

        cell.configure(reading: .unknown)
        XCTAssertFalse(allLabelTexts(in: cell).contains { $0.contains("dBm") })
        XCTAssertTrue(allLabelTexts(in: cell).contains(L10n.t("signal.tier.unknown")))
    }

    /// 详情读数来自最近一次扫描记录，时间与 dBm 一起展示；占位值不当作真实读数。
    func testDetailViewModelReadsLatestScanTimeAndSanitizesPlaceholder() throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanUp() }

        let store = RecentDeviceStore(database: testDatabase.database)
        let device = makeSavedDevice()
        let readAt = Date(timeIntervalSince1970: 1_700_000_000)

        let emptyViewModel = makeDetailViewModel(device: device, database: testDatabase, store: store)
        XCTAssertEqual(emptyViewModel.signalReading, .unknown, "没有扫描记录时是未知")

        try store.upsert(peripheralID: device.peripheralID, name: device.displayName, rssi: -72, lastSeenAt: readAt)
        let scannedViewModel = makeDetailViewModel(device: device, database: testDatabase, store: store)
        XCTAssertEqual(
            scannedViewModel.signalReading,
            .init(rssi: -72, readAt: readAt, status: .lastScan)
        )

        try store.upsert(peripheralID: device.peripheralID, name: device.displayName, rssi: 0, lastSeenAt: readAt)
        let placeholderViewModel = makeDetailViewModel(device: device, database: testDatabase, store: store)
        XCTAssertNil(placeholderViewModel.signalReading.rssi, "占位值 0 按未知处理")
        XCTAssertNil(placeholderViewModel.signalReading.readAt, "未知时不展示读数时间")
        XCTAssertEqual(placeholderViewModel.signalReading.status, .unknown)
    }

    // MARK: - Connected Refresh

    /// 连接后 2 秒轮询成功：dBm 与读数时间都切到实时值。
    func testConnectedRefreshUpdatesValueAndTime() throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanUp() }
        let store = RecentDeviceStore(database: testDatabase.database)
        let device = makeSavedDevice()
        let scanAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsert(peripheralID: device.peripheralID, name: device.displayName, rssi: -80, lastSeenAt: scanAt)

        let bluetooth = FakeBluetoothService()
        bluetooth.markConnected(device.peripheralID)
        bluetooth.rssiResult = .success(-61)
        let liveAt = Date(timeIntervalSince1970: 1_700_000_120)
        let viewModel = makeDetailViewModel(
            device: device,
            database: testDatabase,
            bluetooth: bluetooth,
            store: store,
            now: { liveAt }
        )

        XCTAssertEqual(viewModel.signalReading.status, .lastScan)
        viewModel.setVisible(true)
        XCTAssertTrue(viewModel.isSignalPolling)
        XCTAssertEqual(viewModel.signalReading, .init(rssi: -61, readAt: liveAt, status: .live))
        XCTAssertEqual(bluetooth.rssiReadRequests, [device.peripheralID])
        viewModel.teardown()
    }

    /// 刷新失败保留上一次成功值，只把状态标成 refreshFailed。
    func testRefreshFailureKeepsPreviousValueAndMarksStatus() throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanUp() }
        let device = makeSavedDevice()
        let bluetooth = FakeBluetoothService()
        bluetooth.markConnected(device.peripheralID)
        bluetooth.rssiResult = .success(-61)
        let liveAt = Date(timeIntervalSince1970: 1_700_000_120)
        let viewModel = makeDetailViewModel(
            device: device,
            database: testDatabase,
            bluetooth: bluetooth,
            now: { liveAt }
        )

        viewModel.setVisible(true)
        let first = viewModel.signalReading
        XCTAssertEqual(first.status, .live)

        bluetooth.rssiResult = .failure(FakeRSSIError())
        viewModel.pollSignal()

        XCTAssertEqual(viewModel.signalReading.rssi, first.rssi)
        XCTAssertEqual(viewModel.signalReading.readAt, first.readAt)
        XCTAssertEqual(viewModel.signalReading.status, .refreshFailed)
        viewModel.teardown()
    }

    /// 非负值不是真实 dBm：直接进入未知态，不显示 0 dBm / 满格。
    func testInvalidConnectedValueFallsBackToUnknown() throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanUp() }
        let device = makeSavedDevice()
        let bluetooth = FakeBluetoothService()
        bluetooth.markConnected(device.peripheralID)
        bluetooth.rssiResult = .success(0)
        let viewModel = makeDetailViewModel(device: device, database: testDatabase, bluetooth: bluetooth)

        viewModel.setVisible(true)
        XCTAssertNil(viewModel.signalReading.rssi)
        XCTAssertNil(viewModel.signalReading.readAt)
        XCTAssertEqual(viewModel.signalReading.status, .unknown)
        viewModel.teardown()
    }

    /// 断开连接后停止轮询，且不再发起新的 RSSI 请求；读数回退到最近扫描值。
    func testDisconnectStopsPollingAndFallsBackToLastScan() throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanUp() }
        let store = RecentDeviceStore(database: testDatabase.database)
        let device = makeSavedDevice()
        let scanAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsert(peripheralID: device.peripheralID, name: device.displayName, rssi: -79, lastSeenAt: scanAt)

        let bluetooth = FakeBluetoothService()
        bluetooth.markConnected(device.peripheralID)
        bluetooth.rssiResult = .success(-60)
        let viewModel = makeDetailViewModel(device: device, database: testDatabase, bluetooth: bluetooth, store: store)

        viewModel.setVisible(true)
        XCTAssertEqual(bluetooth.rssiReadRequests.count, 1)

        bluetooth.disconnect(peripheralID: device.peripheralID)
        viewModel.pollSignal()

        XCTAssertFalse(viewModel.isSignalPolling)
        XCTAssertEqual(bluetooth.rssiReadRequests.count, 1, "断开后不得继续发起读取")
        XCTAssertEqual(
            viewModel.signalReading,
            .init(rssi: -79, readAt: scanAt, status: .lastScan)
        )
        viewModel.teardown()
    }

    /// 页面退出 / 进后台（setVisible(false)）同样停表，不留下空转定时器。
    func testHidingPageStopsPolling() throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanUp() }
        let device = makeSavedDevice()
        let bluetooth = FakeBluetoothService()
        bluetooth.markConnected(device.peripheralID)
        bluetooth.rssiResult = .success(-60)
        let viewModel = makeDetailViewModel(device: device, database: testDatabase, bluetooth: bluetooth)

        viewModel.setVisible(true)
        XCTAssertEqual(bluetooth.rssiReadRequests.count, 1)

        viewModel.setVisible(false)
        XCTAssertFalse(viewModel.isSignalPolling)
        viewModel.pollSignal()
        XCTAssertEqual(bluetooth.rssiReadRequests.count, 1, "页面不可见时不得继续读取")
        viewModel.teardown()
    }

    /// 停表后迟到的在途回调必须丢弃，不能把已回退的扫描值改成实时值 / 刷新失败。
    func testLateCallbackAfterStoppingDoesNotOverwriteRolledBackValue() throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanUp() }
        let store = RecentDeviceStore(database: testDatabase.database)
        let device = makeSavedDevice()
        let scanAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsert(peripheralID: device.peripheralID, name: device.displayName, rssi: -80, lastSeenAt: scanAt)

        let bluetooth = FakeBluetoothService()
        bluetooth.markConnected(device.peripheralID)
        bluetooth.rssiResult = .success(-61)
        bluetooth.defersRSSIReads = true
        let viewModel = makeDetailViewModel(
            device: device,
            database: testDatabase,
            bluetooth: bluetooth,
            store: store
        )

        viewModel.setVisible(true)
        XCTAssertEqual(viewModel.signalReading, .init(rssi: -80, readAt: scanAt, status: .lastScan), "首读尚未返回")

        viewModel.setVisible(false)
        XCTAssertEqual(viewModel.signalReading, .init(rssi: -80, readAt: scanAt, status: .lastScan))

        bluetooth.completePendingRSSIReads()
        XCTAssertEqual(
            viewModel.signalReading,
            .init(rssi: -80, readAt: scanAt, status: .lastScan),
            "停表后的迟到回调不得改动已回退的值"
        )
        viewModel.teardown()
    }

    // MARK: - Helpers

    private func makeDetailViewModel(
        device: SavedDevice,
        database: TestDatabase,
        bluetooth: BluetoothServicing = FakeBluetoothService(),
        store: RecentDeviceStore? = nil,
        now: @escaping () -> Date = Date.init
    ) -> DeviceDetailViewModel {
        DeviceDetailViewModel(
            device: device,
            bluetooth: bluetooth,
            productService: StubProductService(),
            cacheStore: DeviceInfoCacheStore(database: database.database),
            savedDeviceStore: SavedDeviceStore(database: database.database),
            readingsStore: ReadingsStore(database: database.database),
            recentDeviceStore: store,
            now: now
        )
    }

    private func signalView(in view: UIView) -> RSISignalView {
        if let signal = view as? RSISignalView { return signal }
        for subview in view.subviews {
            if let found = subviews(of: subview, matching: RSISignalView.self).first {
                return found
            }
        }
        XCTFail("未找到 RSISignalView")
        return RSISignalView()
    }

    private func subviews<T: UIView>(of view: UIView, matching type: T.Type) -> [T] {
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for subview in view.subviews {
            result.append(contentsOf: subviews(of: subview, matching: type))
        }
        return result
    }

    private func allLabelTexts(in view: UIView) -> [String] {
        subviews(of: view, matching: UILabel.self).compactMap(\.text)
    }
}

private struct FakeRSSIError: Error {}
