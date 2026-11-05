import Foundation

/// 「我的」→ 家庭管理：当前家庭与角色、成员、房间、创建 / 邀请 / 加入。
/// 403 与 404 一律转成可读提示，界面不出现错误码。
final class HouseholdManagementViewModel {
    private(set) var households: [Household] = []
    private(set) var current: Household?
    private(set) var members: [HouseholdMember] = []
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
    var canManageRooms: Bool { current?.canManageRooms ?? false }
    var showsSwitcher: Bool { households.count > 1 }

    var roleText: String {
        current?.role.displayName ?? L10n.t("household.role.member")
    }

    var currentSubtitle: String {
        guard let current else { return L10n.t("household.empty") }
        let members = L10n.f("household.memberCount", String(describing: current.memberCount))
        let devices = L10n.f("household.deviceCount", String(describing: current.deviceCount))
        return "\(current.role.displayName) · \(members) · \(devices)"
    }

    func reload() {
        households = service.households()
        current = service.currentHousehold()
        rooms = service.visibleRooms()
        errorMessage = nil
        onChange?()
        fetchMembers()
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
