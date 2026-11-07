import Foundation

/// 统一的设备联动状态：本机 BLE 连接优先，其次才是服务端按 `lastSeenAt` 推导的上报状态。
///
/// 四个档位（本机已连接 / 云端最近上报 / 云端上报已超时 / 云端从未收到上报）
/// 在首页、房间详情、设备列表与设备详情共用同一份判定与文案，避免同一台设备在不同页面给出不同答案。
/// 「本机不可连接」不是第五档，而是附加的本机连接说明，与云端状态并列呈现。
struct DeviceLinkStatus: Equatable {
    enum Tier: Equatable {
        case localConnected
        case cloudRecent
        case cloudStale
        case cloudUnknown
    }

    let tier: Tier
    let presence: DevicePresence

    init(isConnected: Bool, presence: DevicePresence) {
        self.presence = presence
        if isConnected {
            tier = .localConnected
        } else {
            switch presence {
            case .online: tier = .cloudRecent
            case .offline: tier = .cloudStale
            case .unknown: tier = .cloudUnknown
            }
        }
    }

    var isLocalConnected: Bool { tier == .localConnected }

    /// 排序：本机已连接 > 云端最近上报 > 云端上报已超时 > 云端从未收到上报。
    var sortRank: Int {
        switch tier {
        case .localConnected: return 0
        case .cloudRecent: return 1
        case .cloudStale: return 2
        case .cloudUnknown: return 3
        }
    }

    /// 主状态文案：只描述判定依据，不把服务端推导写成「在线」。
    var title: String {
        switch tier {
        case .localConnected: return L10n.t("device.link.localConnected")
        case .cloudRecent: return L10n.t("device.link.cloudRecent")
        case .cloudStale: return L10n.t("device.link.cloudStale")
        case .cloudUnknown: return L10n.t("device.link.cloudUnknown")
        }
    }

    /// 云端状态：即使本机已连接也单独可得，便于「本机连接 + 云端上报」两件事同时呈现。
    var cloudStatusText: String {
        switch presence {
        case .online: return L10n.t("device.link.cloudRecent")
        case .offline: return L10n.t("device.link.cloudStale")
        case .unknown: return L10n.t("device.link.cloudUnknown")
        }
    }

    /// 本机不可连接是附加说明，不是独立档位。
    var notConnectableText: String { L10n.t("device.link.notConnectable") }

    /// 相对时间行：优先云端最近上报时间，其次本机最近扫描时间。
    func timestampText(
        serverLastSeenAt: Date?,
        localLastSeenAt: Date?,
        now: Date = Date()
    ) -> String? {
        if let serverLastSeenAt {
            return L10n.f(
                "device.link.serverLastReported",
                RelativeTimeText.short(for: serverLastSeenAt, relativeTo: now)
            )
        }
        if let localLastSeenAt {
            return L10n.f(
                "device.link.localLastSeen",
                RelativeTimeText.short(for: localLastSeenAt, relativeTo: now)
            )
        }
        return nil
    }

    /// 单行合并文案：主状态 + 时间；跨平台设备前置「本机不可连接」，云端状态与时间仍完整保留。
    func statusText(
        connectable: Bool,
        serverLastSeenAt: Date?,
        localLastSeenAt: Date?,
        now: Date = Date()
    ) -> String {
        let time = timestampText(
            serverLastSeenAt: serverLastSeenAt,
            localLastSeenAt: localLastSeenAt,
            now: now
        )
        if !connectable {
            return [notConnectableText, cloudStatusText, time]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        return [title, time]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// 时间行：跨平台设备补云端状态；本机已连接但云端超时时也说明超时，不隐藏服务端读数。
    /// 云端状态与时间各自成行：窄卡片里不会出现行末悬挂的分隔符，也符合「本机不可连接 + 云端状态」双行呈现。
    func secondaryText(
        connectable: Bool,
        serverLastSeenAt: Date?,
        localLastSeenAt: Date?,
        now: Date = Date()
    ) -> String? {
        let time = timestampText(
            serverLastSeenAt: serverLastSeenAt,
            localLastSeenAt: localLastSeenAt,
            now: now
        )
        if !connectable {
            return [cloudStatusText, time]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
        switch tier {
        case .localConnected:
            // 本机连接时若云端已超时，仍要说明云端状态，不能只报「本机已连接」。
            return presence == .online ? time : [cloudStatusText, time]
                .compactMap { $0 }
                .joined(separator: "\n")
        case .cloudRecent, .cloudStale, .cloudUnknown:
            return time
        }
    }
}
