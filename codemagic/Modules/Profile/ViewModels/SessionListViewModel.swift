import Foundation

/// 登录会话列表：「我的」页二级页，标出当前会话，可单独吊销其他会话。
final class SessionListViewModel {
    private(set) var sessions: [RemoteSession] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var revokingID: String?

    var onChange: (() -> Void)?

    private let manager: SessionManager

    init(manager: SessionManager) {
        self.manager = manager
    }

    func activate() {
        load()
    }

    func load() {
        isLoading = true
        errorMessage = nil
        onChange?()
        manager.listSessions { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            switch result {
            case .success(let sessions):
                // 当前会话排在最前，其余按创建时间倒序。
                self.sessions = sessions.sorted { lhs, rhs in
                    if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                    return lhs.createdAt > rhs.createdAt
                }
            case .failure(let error):
                self.errorMessage = error.message
            }
            self.onChange?()
        }
    }

    func revoke(at index: Int, completion: @escaping (String?) -> Void) {
        guard sessions.indices.contains(index), revokingID == nil else { return }
        let session = sessions[index]
        guard !session.isCurrent else {
            completion(L10n.t("session.revokeCurrentHint"))
            return
        }
        revokingID = session.id
        onChange?()
        manager.revoke(sessionID: session.id) { [weak self] result in
            guard let self else { return }
            self.revokingID = nil
            switch result {
            case .success:
                self.sessions.removeAll { $0.id == session.id }
                completion(nil)
            case .failure(let error):
                completion(error.message)
            }
            self.onChange?()
        }
    }

    var emptyText: String { L10n.t("session.empty") }

    func createdAtText(for session: RemoteSession) -> String {
        AppDateFormat.absolute(session.createdAt)
    }

    func expiresAtText(for session: RemoteSession) -> String {
        AppDateFormat.day(session.expiresAt)
    }
}
