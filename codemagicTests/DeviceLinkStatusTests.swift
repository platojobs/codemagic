import XCTest
@testable import codemagic

final class DeviceLinkStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFourTiersUseLocalConnectionFirstThenServerPresence() {
        XCTAssertEqual(
            DeviceLinkStatus(isConnected: true, presence: .offline).tier,
            .localConnected,
            "本机 BLE 连接优先，不被服务端超时覆盖"
        )
        XCTAssertEqual(
            DeviceLinkStatus(isConnected: true, presence: .online).tier,
            .localConnected
        )
        XCTAssertEqual(DeviceLinkStatus(isConnected: false, presence: .online).tier, .cloudRecent)
        XCTAssertEqual(DeviceLinkStatus(isConnected: false, presence: .offline).tier, .cloudStale)
        XCTAssertEqual(
            DeviceLinkStatus(isConnected: false, presence: .unknown).tier,
            .cloudUnknown,
            "unknown 单独一档，不并进上报超时"
        )
    }

    func testStatusTextsDoNotClaimAuthoritativeOnlineAndKeepWindows() {
        let local = DeviceLinkStatus(isConnected: true, presence: .online)
        let recent = DeviceLinkStatus(isConnected: false, presence: .online)
        let stale = DeviceLinkStatus(isConnected: false, presence: .offline)
        let unknown = DeviceLinkStatus(isConnected: false, presence: .unknown)

        XCTAssertEqual(local.title, L10n.t("device.link.localConnected"))
        XCTAssertEqual(recent.title, L10n.t("device.link.cloudRecent"))
        XCTAssertEqual(stale.title, L10n.t("device.link.cloudStale"))
        XCTAssertEqual(unknown.title, L10n.t("device.link.cloudUnknown"))
        for status in [local, recent, stale, unknown] {
            XCTAssertFalse(status.title.contains("在线"), "不得把推导结果包装成在线")
        }
    }

    func testTimestampUsesServerLastSeenBeforeLocalScan() {
        let status = DeviceLinkStatus(isConnected: true, presence: .offline)
        let server = now.addingTimeInterval(-180)
        let local = now.addingTimeInterval(-60)

        XCTAssertEqual(
            status.timestampText(serverLastSeenAt: server, localLastSeenAt: local, now: now),
            L10n.f("device.link.serverLastReported", RelativeTimeText.short(for: server, relativeTo: now)),
            "服务端最近上报优先于本机扫描时间"
        )
        XCTAssertEqual(
            status.timestampText(serverLastSeenAt: nil, localLastSeenAt: local, now: now),
            L10n.f("device.link.localLastSeen", RelativeTimeText.short(for: local, relativeTo: now))
        )
        XCTAssertNil(status.timestampText(serverLastSeenAt: nil, localLastSeenAt: nil, now: now))
    }

    func testCrossPlatformShowsBothLocalBoundaryAndCloudStatus() {
        let status = DeviceLinkStatus(isConnected: false, presence: .offline)
        let server = now.addingTimeInterval(-3 * 60 * 60)

        let singleLine = status.statusText(
            connectable: false,
            serverLastSeenAt: server,
            localLastSeenAt: nil,
            now: now
        )
        XCTAssertTrue(singleLine.contains(L10n.t("device.link.notConnectable")))
        XCTAssertTrue(singleLine.contains(L10n.t("device.link.cloudStale")))
        XCTAssertTrue(singleLine.contains(L10n.f(
            "device.link.serverLastReported",
            RelativeTimeText.short(for: server, relativeTo: now)
        )), "本机不可连接不能遮住云端最近上报时间")

        XCTAssertEqual(
            DeviceLinkStatus(isConnected: false, presence: .unknown).secondaryText(
                connectable: false,
                serverLastSeenAt: nil,
                localLastSeenAt: nil,
                now: now
            ),
            L10n.t("device.link.cloudUnknown")
        )
    }

    func testLocalConnectedWithStaleCloudStillExplainsTimeout() {
        let status = DeviceLinkStatus(isConnected: true, presence: .offline)
        let server = now.addingTimeInterval(-3 * 60 * 60)
        let secondary = status.secondaryText(
            connectable: true,
            serverLastSeenAt: server,
            localLastSeenAt: nil,
            now: now
        )
        XCTAssertEqual(
            secondary,
            "\(L10n.t("device.link.cloudStale")) · "
                + L10n.f("device.link.serverLastReported", RelativeTimeText.short(for: server, relativeTo: now))
        )
    }

    func testWindowBoundaryUsesNineHundredSeconds() {
        let atBoundary = SavedDevice(
            peripheralID: UUID(),
            platform: SavedDevice.iosPlatform,
            advertisedName: "边界",
            serverLastSeenAt: now.addingTimeInterval(-900)
        )
        let overBoundary = SavedDevice(
            peripheralID: UUID(),
            platform: SavedDevice.iosPlatform,
            advertisedName: "超窗",
            serverLastSeenAt: now.addingTimeInterval(-901)
        )

        XCTAssertEqual(atBoundary.presence(at: now), .online)
        XCTAssertEqual(overBoundary.presence(at: now), .offline)
    }
}
