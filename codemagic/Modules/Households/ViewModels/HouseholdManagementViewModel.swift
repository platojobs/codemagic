import Foundation

/// 「我的」→ 家庭管理：当前家庭与角色、成员、房间、创建 / 邀请 / 加入。
/// 403 与 404 一律转成可读提示，界面不出现错误码。
final class HouseholdManagementViewModel {
    private(set) var households: [Household] = []
    private(set) var current: Household?
    private(set) var members: [HouseholdMember] = []
    private(set) var invitations: [HouseholdInvitationInfo] = []
    private(set) var rooms: [Room] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var notice: String?

    var onChange: (() -> Void)?

    private let service: HouseholdService

    init(service: HouseholdService) {
        self.service = service
    }

    var hasHousehold: Bool { current != nil }
    /// 能力矩阵统一来自 `HouseholdCapabilities`，界面只消费结果。
    var capabilities: HouseholdCapabilities {
        current?.capabilities(supportsOwnershipTransfer: service.supportsOwnershipTransfer)
            ?? HouseholdCapabilities.make(
                role: .member,
                isPersonal: true,
                memberCount: 1,
                supportsOwnershipTransfer: false
            )
    }
    var canManageRooms: Bool { capabilities.canManageRooms }
    var canManageHousehold: Bool { capabilities.canManageHousehold }
    var canLeaveHousehold: Bool { capabilities.canLeave && !capabilities.mustBlockOwnerLeave }
    /// 邀请码列表 / 签发 / 撤销入口只对 owner 可见。
    var showsInvitations: Bool { capabilities.canInviteMembers }
    var showsSwitcher: Bool { households.count > 1 }

    var roleText: String {
        current?.role.displayName ?? L10n.t("household.role.member")
    }

    var currentSubtitle: String {
        guard let current else { return L10n.t("household.empty") }
        let members = L10n.f("household.memberCount", String(describing: current.memberCount))
        let devices = L10n.f("household.deviceCount", String(describing: current.deviceCount))
        let rooms = L10n.f("household.roomCount", String(describing: current.roomCount))
        return "\(current.role.displayName) · \(members) · \(devices) · \(rooms)"
    }

    /// 成员行上的「移除成员」：owner 对非本人成员；`isSelf` 为真时一律不出现。
    func canRemove(member: HouseholdMember) -> Bool {
        capabilities.canAct(on: member) && member.role != .owner
    }

    /// 成员行上的「转让所有权」：与「移除成员」并列互斥，同样排除本人行。
    func canTransfer(member: HouseholdMember) -> Bool {
        capabilities.canTransfer(member)
    }

    /// 转让后的后果说明（二次确认正文）。
    var transferConsequence: String {
        L10n.t("household.transfer.consequence")
    }

    func reload() {
        households = service.households()
        current = service.currentHousehold()
        rooms = service.visibleRooms()
        errorMessage = nil
        onChange?()
        fetchMembers()
        fetchInvitations()
    }

    /// 下拉刷新：先拉服务端家庭快照（真实计数），再刷新本地视图。
    func refresh() {
        isRefreshing = true
        service.refreshHouseholds { [weak self] _ in
            guard let self else { return }
            self.isRefreshing = false
            self.reload()
        }
    }

    private func fetchMembers() {
        guard let current else {
            members = []
            onChange?()
            return
        }
        isRefreshing = true
        service.members(householdID: current.id) { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false
            switch result {
            case .success(let members):
                self.members = members
                self.errorMessage = nil
            case .failure(let error):
                // 成员拉取失败不清空旧列表，只给出可读原因。
                self.errorMessage = error.userMessage
            }
            self.onChange?()
        }
    }

    private func fetchInvitations() {
        guard showsInvitations, let current else {
            invitations = []
            return
        }
        service.invitations(householdID: current.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let items):
                // 接口层只返回哈希前缀，界面不可能出现明文。
                self.invitations = items.sorted { $0.expiresAt > $1.expiresAt }
            case .failure(let error):
                self.invitations = []
                if error == .forbidden {
                    // member 误触时静默降级，不打断页面。
                    self.errorMessage = nil
                } else {
                    self.errorMessage = error.userMessage
                }
            }
            self.onChange?()
        }
    }

    func switchHousehold(localID: UUID) {
        service.switchHousehold(localID: localID)
        reload()
    }

    func createHousehold(name: String, completion: @escaping (Bool) -> Void) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(false)
            return
        }
        service.createHousehold(name: trimmed) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.errorMessage = nil
                self.reload()
                completion(true)
            case .failure(let error):
                self.errorMessage = error.userMessage
                self.onChange?()
                completion(false)
            }
        }
    }

    func renameHousehold(name: String, completion: @escaping (Bool) -> Void) {
        guard let current else {
            completion(false)
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(false); return }
        service.renameHousehold(id: current.id, name: trimmed) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.errorMessage = nil
                self.reload()
                completion(true)
            case .failure(let error):
                self.errorMessage = error.userMessage
                self.onChange?()
                completion(false)
            }
        }
    }

    func removeMember(_ member: HouseholdMember, completion: @escaping (Bool) -> Void) {
        guard let current, canRemove(member: member) else {
            completion(false)
            return
        }
        service.removeMember(householdID: current.id, userID: member.userID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.errorMessage = nil
                self.reload()
                completion(true)
            case .failure(let error):
                self.errorMessage = error.userMessage
                self.onChange?()
                completion(false)
            }
        }
    }

    /// 转让所有权。成功后立即刷新成员与能力矩阵，入口随角色消失。
    /// 老后端（405）视为不支持，静默隐藏入口；403 / 404 / 409 给可读提示并刷新家庭详情。
    func transferOwnership(to member: HouseholdMember, completion: @escaping (Bool) -> Void) {
        guard let current, canTransfer(member: member) else {
            completion(false)
            return
        }
        service.transferOwnership(householdID: current.id, to: member.userID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.errorMessage = nil
                self.notice = L10n.t("household.transfer.success")
                self.reload()
                completion(true)
            case .failure(.unsupported):
                // 服务端不支持：不弹错误，重新拉取成员后入口按能力自动隐藏。
                self.errorMessage = nil
                self.reload()
                completion(false)
            case .failure(let error):
                self.reload()
                self.errorMessage = error.userMessage
                self.onChange?()
                completion(false)
            }
        }
    }

    /// 退出家庭。owner 且还有其他成员时，界面先本地拦截并给出可读提示；
    /// 服务端 409 与本地拦截使用同一文案。
    func leaveHousehold(completion: @escaping (Bool) -> Void) {
        guard let current else {
            completion(false)
            return
        }
        if capabilities.mustBlockOwnerLeave {
            errorMessage = L10n.t("household.leave.ownerConflict")
            onChange?()
            completion(false)
            return
        }
        service.leaveHousehold(householdID: current.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.errorMessage = nil
                self.reload()
                completion(true)
            case .failure(let error):
                self.errorMessage = error.userMessage
                self.onChange?()
                completion(false)
            }
        }
    }

    func revokeInvitation(id: String, completion: @escaping (Bool) -> Void) {
        guard let current else {
            completion(false)
            return
        }
        service.revokeInvitation(householdID: current.id, invitationID: id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.errorMessage = nil
                self.fetchInvitations()
                completion(true)
            case .failure(let error):
                self.errorMessage = error.userMessage
                self.onChange?()
                completion(false)
            }
        }
    }

    func createInvitation(completion: @escaping (Result<HouseholdInvitation, HouseholdAPIError>) -> Void) {
        guard let current else {
            completion(.failure(.notFound))
            return
        }
        service.createInvitation(householdID: current.id, completion: completion)
    }

    /// 房间行副标题：仅未同步房间提示，已同步保持干净。
    func roomSubtitle(for room: Room) -> String? {
        room.syncState == .synced ? nil : L10n.t("household.room.unsynced")
    }
}
