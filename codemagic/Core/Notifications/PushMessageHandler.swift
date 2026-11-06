import Foundation

/// 一条推送消息的可解析字段。APNs 把自定义字段放在 `data` 字典里，
/// 这里同时兼容顶层与 `data` 嵌套两种形态。
struct PushMessage: Equatable {
    let alertID: String?
    let kind: String?
    let deviceID: String?
    let externalID: String?
    let platform: String
}

/// 点击通知后的跳转目标。`externalDevice` 由调用方用本地设备表解析成详情页。
enum PushDestination: Equatable {
    case deviceDetail(UUID)
    case externalDevice(platform: String, externalID: String)
    case scenes
    case home
}

/// 解析推送并决定跳转目标。无真实推送时由单测覆盖解析与路由。
struct PushMessageHandler {
    /// 从通知 `userInfo` 解析出 `alertId` / `kind` / 设备标识。
    func message(from userInfo: [AnyHashable: Any]) -> PushMessage? {
        let payload = (userInfo["data"] as? [AnyHashable: Any]) ?? userInfo
        let alertID = Self.string(payload["alertId"])
            ?? Self.string(payload["alertID"])
            ?? Self.string(payload["alert_id"])
        let kind = Self.string(payload["kind"])
        let deviceID = Self.string(payload["deviceID"])
            ?? Self.string(payload["deviceId"])
            ?? Self.string(payload["device_id"])
        let externalID = Self.string(payload["externalId"])
            ?? Self.string(payload["externalID"])
            ?? Self.string(payload["external_id"])
            ?? Self.string(payload["mac"])
        let platform = Self.string(payload["platform"])?.lowercased() ?? "ios"

        guard alertID != nil || kind != nil || deviceID != nil || externalID != nil else {
            return nil
        }
        return PushMessage(
            alertID: alertID,
            kind: kind?.lowercased(),
            deviceID: deviceID,
            externalID: externalID,
            platform: platform
        )
    }

    /// 按 `kind` 选择设备详情或场景页。设备详情优先使用本地 UUID；
    /// 只有服务端 externalId 时交给调用方解析，解析不到再回首页。
    func destination(for message: PushMessage) -> PushDestination {
        let kind = message.kind ?? ""
        let isScene = kind.contains("scene")
        let isDevice = kind.contains("device")
            || (!isScene && (message.deviceID != nil || message.externalID != nil))

        if isScene && !isDevice {
            return .scenes
        }
        if isDevice {
            if let deviceID = message.deviceID, let uuid = UUID(uuidString: deviceID) {
                return .deviceDetail(uuid)
            }
            if let externalID = message.externalID, !externalID.isEmpty {
                return .externalDevice(platform: message.platform, externalID: externalID)
            }
            return .home
        }
        // 只有 alertId 的推送没有可确定的目标，回首页而不是猜测。
        return .home
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
