import Foundation

/// 家庭角色。`owner` 可修改家庭 / 房间、管理成员与邀请码；`member` 只读，写操作由服务端返回 403。
enum HouseholdRole: String, Equatable {
    case owner
    case member

    var displayName: String {
        self == .owner ? L10n.t("household.role.owner") : L10n.t("household.role.member")
    }

    var canManageRooms: Bool { self == .owner }
    var canManageHousehold: Bool { self == .owner }
}

/// 家庭快照，与服务端 `Household` 一致。本地 id 直接复用远端 UUID，便于与房间 / 设备映射。
/// `memberCount` / `deviceCount` / `roomCount` 均为服务端返回的真实数字，不在本地重新计数。
struct Household: Identifiable, Equatable {
    let id: UUID
    var remoteID: String
    var name: String
    var isPersonal: Bool
    var role: HouseholdRole
    var memberCount: Int
    var deviceCount: Int
    var roomCount: Int
    var createdAt: Date
    var updatedAt: Date

    var canManageRooms: Bool { role.canManageRooms }
    var canManageHousehold: Bool { role.canManageHousehold }
    /// 个人家庭不可退出（服务端 400），也不可删除。
    var canLeave: Bool { !isPersonal }
}

/// 家庭成员。服务端不返回昵称，展示时对用户 id 做脱敏缩写。
struct HouseholdMember: Identifiable, Equatable {
    var id: String { userID }
    let userID: String
    let role: HouseholdRole
    let kind: String
    let joinedAt: Date

    /// 成员列表展示名：前 8 位，避免整屏 UUID。
    var shortID: String {
        String(userID.prefix(8)).uppercased()
    }

    var kindDisplayName: String {
        kind == "account" ? L10n.t("household.member.account") : L10n.t("household.member.anonymous")
    }
}

/// 一次性邀请码：明文只在签发响应中出现一次，`expiresAt` 为服务端倒计时依据。
struct HouseholdInvitation: Equatable {
    let code: String
    let expiresAt: Date
}

/// 邀请码管理状态。领取成功或撤销后服务端立即删除记录，列表只包含未使用的码。
enum HouseholdInvitationStatus: String, Equatable {
    case active
    case expired
    case locked

    var displayName: String {
        switch self {
        case .active: return L10n.t("household.invitation.status.active")
        case .expired: return L10n.t("household.invitation.status.expired")
        case .locked: return L10n.t("household.invitation.status.locked")
        }
    }
}

/// 邀请码管理视图：只含 SHA-256 哈希前 8 位，**绝不包含明文**。
struct HouseholdInvitationInfo: Identifiable, Equatable {
    let id: String
    let codeHashPrefix: String
    let status: HouseholdInvitationStatus
    let attempts: Int
    let expiresAt: Date
    let createdAt: Date
}

/// 服务端房间。`createdAt` 缺省时由客户端按拉取时间补齐，不臆造服务端时间。
struct RemoteHouseholdRoom: Decodable, Equatable {
    let id: String
    let householdID: String
    let name: String
    let sortOrder: Int
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case householdId
        case name
        case sortOrder
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        householdID = (try? container.decodeIfPresent(String.self, forKey: .householdId)) ?? ""
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        sortOrder = (try? container.decodeIfPresent(Int.self, forKey: .sortOrder)) ?? 0
        createdAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        )
    }

    init(id: String, householdID: String, name: String, sortOrder: Int, createdAt: Date? = nil) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// 待上报的设备归属。与设备 `sync_state` 解耦：归属不塞进 `push`，避免与 LWW 冲突。
struct PendingDeviceAssignment: Equatable {
    let deviceID: UUID
    let platform: String
    let externalID: String
    /// 目标房间服务端 id；空串表示「清除房间（回到未分配）」。
    let roomRemoteID: String
    /// 目标家庭服务端 id；空串表示「回到 owner 的个人家庭」。
    let householdRemoteID: String
    var attempts: Int
    let createdAt: Date
    var updatedAt: Date
}

/// 家庭接口错误。403 / 404 / 409 都转换为可读提示，界面不展示错误码。
enum HouseholdAPIError: Error, Equatable {
    case unauthorized
    case forbidden
    case notFound
    /// 409：owner 还有其他成员时不能退出等状态冲突。
    case conflict
    case rateLimited(retryAfterSeconds: Int?)
    /// 409：整段重排时房间集合已变化（服务端 `ROOM_SET_MISMATCH` 或重排端点 `CONFLICT`）。
    case roomSetMismatch
    case failure(AppError)
    case decoding(String)

    var userMessage: String {
        switch self {
        case .unauthorized:
            return L10n.t("account.auth.expired")
        case .forbidden:
            return L10n.t("household.forbidden")
        case .notFound:
            return L10n.t("household.notFound")
        case .conflict:
            return L10n.t("household.leave.ownerConflict")
        case .rateLimited(let seconds):
            if let seconds {
                return L10n.f("household.rateLimitedSeconds", String(describing: seconds))
            }
            return L10n.t("household.rateLimited")
        case .roomSetMismatch:
            return L10n.t("household.room.orderChanged")
        case .failure(let error):
            return error.isRetryable ? error.message : L10n.t("household.genericError")
        case .decoding:
            return L10n.t("household.responseMismatch")
        }
    }

    /// 网络抖动、5xx 与限流可重试；401 / 403 / 404 / 409 不重试（409 由调用方重新拉取后整段重提）。
    var isRetryable: Bool {
        switch self {
        case .failure(.network), .failure(.server), .rateLimited:
            return true
        default:
            return false
        }
    }

    /// 邀请码领取：404 一律解释为「邀请码无效或已过期」。
    var claimUserMessage: String {
        self == .notFound ? L10n.t("household.invitation.invalid") : userMessage
    }
}
