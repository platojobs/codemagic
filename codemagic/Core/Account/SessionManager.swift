import Foundation

/// 会话生命周期业务层：会话列表、吊销其他会话、退出当前会话。
///
/// 「退出当前会话」只吊销服务端 token 并清空本机凭据，**不删除任何本地设备 / 读数**；
/// 用户之后可用配对码重新关联回原账号。与「删除账号」（会清空数据）严格区分。
final class SessionManager {
    private let api: AuthServicing
    private let tokenStore: TokenStoring
    private let metadataStore: SyncMetadataStore
    private let logStore: ScanLogStore
    /// 退出前先注销推送设备，避免服务端保留已失效 token。
    private let pushRegistration: PushRegistrationServicing?

    var onChange: (() -> Void)?

    init(
        api: AuthServicing,
        tokenStore: TokenStoring,
        metadataStore: SyncMetadataStore,
        logStore: ScanLogStore,
        pushRegistration: PushRegistrationServicing? = nil
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.metadataStore = metadataStore
        self.logStore = logStore
        self.pushRegistration = pushRegistration
    }

    /// 当前是否持有可用会话 token（不代表服务端一定接受，401 仍可能发生）。
    var hasSession: Bool {
        guard let session = tokenStore.load() else { return false }
        return !session.token.isEmpty
    }

    var needsRelogin: Bool { metadataStore.reloginRequired }

    var currentUserID: String? { metadataStore.userID }

    func listSessions(completion: @escaping (Result<[RemoteSession], AppError>) -> Void) {
        guard let session = tokenStore.load(), !session.token.isEmpty else {
            completion(.failure(.sync(L10n.t("sync.reloginRequired"))))
            return
        }
        api.listSessions(token: session.token, completion: completion)
    }

    func revoke(sessionID: String, completion: @escaping (Result<Void, AppError>) -> Void) {
        guard let session = tokenStore.load(), !session.token.isEmpty else {
            completion(.failure(.sync(L10n.t("sync.reloginRequired"))))
            return
        }
        api.revokeSession(id: sessionID, token: session.token) { [weak self] result in
            if case .success = result {
                self?.record(L10n.t("session.revokedLog"))
            }
            completion(result)
        }
    }

    /// 退出当前会话。网络失败也会在本地登出，避免用户「点了退出却还带 token 发请求」。
    /// 有推送设备时先 `DELETE /push/devices/{deviceId}`，成功 / 404 / 失败后都继续退出。
    func logoutCurrent(completion: @escaping (Result<Void, AppError>) -> Void) {
        guard let session = tokenStore.load(), !session.token.isEmpty else {
            // 已经没有 token：直接进入待重新登录态即可。
            enterLoggedOutState()
            completion(.success(()))
            return
        }
        let performLogout = { [weak self] in
            guard let self else { return }
            self.performLogout(token: session.token, completion: completion)
        }
        if let pushRegistration {
            pushRegistration.deactivate(completion: performLogout)
        } else {
            performLogout()
        }
    }

    private func performLogout(
        token: String,
        completion: @escaping (Result<Void, AppError>) -> Void
    ) {
        api.logout(token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.enterLoggedOutState()
                self.record(L10n.t("session.logoutLog"))
                completion(.success(()))
            case .failure(let error):
                if error.isUnauthorized {
                    // token 已失效，等同退出成功。
                    self.enterLoggedOutState()
                    self.record(L10n.t("session.logoutLog"))
                    completion(.success(()))
                    return
                }
                // 网络错误：仍本地登出，但把真实原因交给界面提示。
                self.enterLoggedOutState()
                self.record(L10n.f("session.logoutLocalOnlyLog", error.message))
                completion(.failure(error))
            }
        }
    }

    // MARK: - Private

    private func enterLoggedOutState() {
        tokenStore.clear()
        // 保留 userID / 本地数据；只标记「需要重新登录」，防止自动同步静默建新匿名账号。
        metadataStore.sessionExpiresAt = nil
        metadataStore.reloginRequired = true
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }

    private func record(_ message: String) {
        try? logStore.append(ScanLogEntry(category: .session, level: .info, message: message))
    }
}
