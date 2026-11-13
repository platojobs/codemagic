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

        cell.configure(reading: .init(rssi: -72, readAt: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertTrue(allLabelTexts(in: cell).contains { $0.contains("-72 dBm") })
        XCTAssertTrue(allLabelTexts(in: cell).contains { $0.contains("/4 格") })

        cell.configure(reading: .init(rssi: nil, readAt: nil))
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
        let viewModel = DeviceDetailViewModel(
            device: device,
            bluetooth: FakeBluetoothService(),
            productService: StubProductService(),
            cacheStore: DeviceInfoCacheStore(database: testDatabase.database),
            savedDeviceStore: SavedDeviceStore(database: testDatabase.database),
            readingsStore: ReadingsStore(database: testDatabase.database),
            recentDeviceStore: store
        )

        XCTAssertNil(viewModel.signalReading.rssi, "没有扫描记录时是未知")

        try store.upsert(peripheralID: device.peripheralID, name: device.displayName, rssi: -72, lastSeenAt: readAt)
        XCTAssertEqual(viewModel.signalReading, .init(rssi: -72, readAt: readAt))

        try store.upsert(peripheralID: device.peripheralID, name: device.displayName, rssi: 0, lastSeenAt: readAt)
        XCTAssertNil(viewModel.signalReading.rssi, "占位值 0 按未知处理")
        XCTAssertNil(viewModel.signalReading.readAt, "未知时不展示读数时间")
    }

    // MARK: - Helpers

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
