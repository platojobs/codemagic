import Foundation

/// 401 刷新协调器：单飞刷新 + 原子替换 token。
///
/// 规则（与 `docs/consistency.md` 一致）：
/// - 收到 401 时先比对请求携带的 token 与本地当前 token。若已不同，说明刷新刚完成，
///   直接重放，不再触发第二次刷新。
/// - token 相同才发起刷新；并发 401 全部挂在同一次刷新上（单飞），不会形成刷新风暴。
/// - 刷新成功：新 token 先写入 Keychain，再唤醒等待方，保证并发请求读到的是新值。
/// - 刷新返回 401（服务端已吊销）：进入「需要重新登录」态，**保留本地设备与读数**，只清空失效 token。
/// - 刷新遇到网络 / 5xx：保留 token 与会话，调用方按可重试处理，不把用户登出。
protocol SessionRefreshing: AnyObject {
    /// 用 401 请求上携带的 `staleToken` 换取新会话。
    func recover(staleToken: String, completion: @escaping (Result<AnonymousSession, AppError>) -> Void)
}

final class TokenRefreshCoordinator: SessionRefreshing {
    private let api: AuthServicing
    private let tokenStore: TokenStoring
    private let metadataStore: SyncMetadataStore
    private let queue = DispatchQueue(label: "com.platojobs.codemagic.token-refresh")
    private var isRefreshing = false
    private var waiters: [(Result<AnonymousSession, AppError>) -> Void] = []

    /// 刷新因 401 失败、进入重新登录态时回调（切主线程）；用于刷新「我的」页状态。
    var onReloginRequired: (() -> Void)?

    init(api: AuthServicing, tokenStore: TokenStoring, metadataStore: SyncMetadataStore) {
        self.api = api
        self.tokenStore = tokenStore
        self.metadataStore = metadataStore
    }

    func recover(staleToken: String, completion: @escaping (Result<AnonymousSession, AppError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            // 已经处于「需要重新登录」：不再尝试刷新，避免对同一失效 token 反复打点。
            if self.metadataStore.reloginRequired {
                completion(.failure(Self.unauthorizedError))
                return
            }
            guard let current = self.tokenStore.load(), !current.token.isEmpty else {
                self.enterReloginState()
                completion(.failure(Self.unauthorizedError))
                return
            }
            // 刷新已在别处完成：直接用新 token 重放，不再发起第二次刷新。
            if current.token != staleToken {
                completion(.success(current))
                return
            }

            self.waiters.append(completion)
            guard !self.isRefreshing else { return }
            self.isRefreshing = true
            let token = current.token
            self.api.refresh(token: token) { [weak self] result in
                self?.finish(result)
            }
        }
    }

    // MARK: - Private

    private func finish(_ result: Result<AnonymousSession, AppError>) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRefreshing = false
            let waiters = self.waiters
            self.waiters.removeAll()

            switch result {
            case .success(let session):
                do {
                    try self.tokenStore.save(session)
                } catch {
                    // 无法持久化新 token：不能让并发请求拿到「只存在一次」的 token。
                    let failure = AppError.sync(L10n.f("sync.keychain.failed", String(describing: error)))
                    waiters.forEach { $0(.failure(failure)) }
                    return
                }
                self.metadataStore.userID = session.userID
                self.metadataStore.sessionExpiresAt = session.expiresAt
                self.metadataStore.reloginRequired = false
                waiters.forEach { $0(.success(session)) }

            case .failure(let error):
                if error.isUnauthorized || error.apiCode == "UNAUTHORIZED" {
                    self.enterReloginState()
                }
                // 网络 / 5xx 不清会话：交给调用方按可重试处理。
                waiters.forEach { $0(.failure(error)) }
            }
        }
    }

    private func enterReloginState() {
        metadataStore.reloginRequired = true
        // 仅清掉已吊销的 token；本地设备、读数、家庭、场景全部保留。
        tokenStore.clear()
        DispatchQueue.main.async { [weak self] in
            self?.onReloginRequired?()
        }
    }

    private static let unauthorizedError = AppError.api(
        code: "UNAUTHORIZED",
        statusCode: 401,
        message: L10n.t("error.unauthorized")
    )
}

/// 给所有带 Bearer 的请求加一层 401 → 刷新 → 重放的装饰器。
///
/// 只对「响应确实是 401」且「请求本身带 Bearer」且「不是鉴权端点」的请求生效，
/// 每个请求最多重放一次，避免刷新失败后形成递归。
final class AuthenticatedHTTPClient: HTTPClient {
    private let base: HTTPClient
    private let refreshCoordinator: SessionRefreshing

    init(base: HTTPClient, refreshCoordinator: SessionRefreshing) {
        self.base = base
        self.refreshCoordinator = refreshCoordinator
    }

    func send(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, AppError>) -> Void) {
        send(request, allowRefresh: true, completion: completion)
    }

    private func send(
        _ request: HTTPRequest,
        allowRefresh: Bool,
        completion: @escaping (Result<HTTPResponse, AppError>) -> Void
    ) {
        base.send(request) { [weak self] result in
            guard let self,
                  allowRefresh,
                  case .success(let response) = result,
                  response.statusCode == 401,
                  !Self.isAuthEndpoint(request.url),
                  let bearer = Self.bearerToken(in: request)
            else {
                completion(result)
                return
            }
            self.refreshCoordinator.recover(staleToken: bearer) { recovery in
                switch recovery {
                case .success(let session):
                    var retried = request
                    retried.headers["Authorization"] = "Bearer \(session.token)"
                    self.send(retried, allowRefresh: false, completion: completion)
                case .failure:
                    // 刷新失败：把原始 401 交给调用方，由错误目录映射为「需要重新登录」。
                    completion(result)
                }
            }
        }
    }

    private static func bearerToken(in request: HTTPRequest) -> String? {
        let header = request.headers.first {
            $0.key.caseInsensitiveCompare("Authorization") == .orderedSame
        }?.value
        guard let header else { return nil }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return nil }
        let token = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// 刷新 / 退出 / 匿名登录自身返回 401 时不能再触发刷新。
    private static func isAuthEndpoint(_ url: URL) -> Bool {
        url.path.contains("/auth/refresh")
            || url.path.contains("/auth/logout")
            || url.path.contains("/auth/anonymous")
    }
}
