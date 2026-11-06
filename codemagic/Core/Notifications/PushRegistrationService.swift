import Foundation
import UserNotifications
import UIKit

/// 推送令牌注册的生命周期服务。
///
/// 触发点：
/// - 会话就绪（`SyncEngine.onSessionReady`）；
/// - App 回到前台（补注册未成功 / 到期的退避）；
/// - APNs token 变化（`PushTokenProvider.onUpdate`）；
/// - 首次引导里用户处理完通知权限（权限结果不影响注册）；
/// - 登出 / 删除账号前先 `DELETE /push/devices/{deviceId}` 再清本地。
protocol PushRegistrationServicing: AnyObject {
    var onChange: (() -> Void)? { get set }
    var record: PushDeviceRecord? { get }
    /// 发起注册；`force == false` 时已注册且 token 未变化则直接返回。
    func requestRegistration(force: Bool)
    /// 回到前台：补一次未成功的注册，并检查退避是否到期。
    func appDidBecomeActive()
    /// 退避到期才重试；测试可注入时间。
    func retryIfEligible(at date: Date?)
    /// 登出 / 删除账号：先尝试远端 DELETE（404 视为已不存在），再清本地。
    func deactivate(completion: @escaping () -> Void)
    /// 仅清本地记录（不访问网络）。
    func clearLocal()
}

final class PushRegistrationService: PushRegistrationServicing {
    var onChange: (() -> Void)?
    private(set) var record: PushDeviceRecord?

    private let api: PushDeviceAPIServicing
    private let store: PushDeviceStoring
    private let tokenStore: TokenStoring
    private let tokenProvider: PushTokenProviding
    private let logStore: ScanLogStore?
    private let now: () -> Date
    private let appVersion: () -> String
    private let deviceModel: () -> String
    private let platform: String

    private var isRegistering = false
    private var isRequestingToken = false

    init(
        api: PushDeviceAPIServicing,
        store: PushDeviceStoring,
        tokenStore: TokenStoring,
        tokenProvider: PushTokenProviding,
        logStore: ScanLogStore? = nil,
        platform: String = "ios",
        now: @escaping () -> Date = { Date() },
        appVersion: @escaping () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        },
        deviceModel: @escaping () -> String = { UIDevice.current.model }
    ) {
        self.api = api
        self.store = store
        self.tokenStore = tokenStore
        self.tokenProvider = tokenProvider
        self.logStore = logStore
        self.platform = platform
        self.now = now
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.record = store.load()

        tokenProvider.onUpdate = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let token):
                self.handleToken(token, force: true)
            case .failure(let failure):
                self.saveMissingToken(failure)
            }
        }
    }

    // MARK: - Triggers

    func requestRegistration(force: Bool) {
        guard !isRegistering else { return }
        guard let authToken = currentAuthToken() else {
            persistStatus(.noSession, error: nil)
            return
        }
        if !force, let record,
           record.status == .registered,
           record.token == tokenProvider.cachedToken,
           let remote = record.remoteDeviceID, !remote.isEmpty {
            return
        }
        if let token = tokenProvider.cachedToken {
            register(deviceToken: token, authToken: authToken, force: force)
        } else {
            requestToken(authToken: authToken)
        }
    }

    func appDidBecomeActive() {
        guard currentAuthToken() != nil else {
            if record?.status != .noSession {
                persistStatus(.noSession, error: nil)
            }
            return
        }
        if let record, record.status == .pending,
           let next = record.nextRetryAt, next > now() {
            return
        }
        switch record?.status {
        case .registered:
            return
        case .rejected, .unauthorized, .deactivated:
            return
        case .pending, .missingToken, .noSession, .none:
            if let token = tokenProvider.cachedToken {
                register(deviceToken: token, authToken: currentAuthToken() ?? "", force: false)
            } else {
                requestToken(authToken: currentAuthToken() ?? "")
            }
        }
    }

    func retryIfEligible(at date: Date? = nil) {
        guard let record, record.status == .pending, let token = record.token else { return }
        let reference = date ?? now()
        if let next = record.nextRetryAt, next > reference { return }
        guard let authToken = currentAuthToken() else {
            persistStatus(.noSession, error: nil)
            return
        }
        register(deviceToken: token, authToken: authToken, force: true)
    }

    func deactivate(completion: @escaping () -> Void) {
        let stored = record ?? store.load()
        guard let remoteID = stored?.remoteDeviceID, !remoteID.isEmpty,
              let authToken = currentAuthToken() else {
            clearLocal()
            completion()
            return
        }
        api.deactivate(deviceID: remoteID, authToken: authToken) { [weak self] result in
            guard let self else {
                completion()
                return
            }
            if case .failure(let error) = result {
                self.log("push.log.deactivateFailed", detail: error.localizedDescriptionText)
            }
            // 404 由 API 映射为 `.alreadyAbsent`，同样清理本地。
            self.clearLocal()
            completion()
        }
    }

    func clearLocal() {
        store.clear()
        record = nil
        notifyChange()
    }

    // MARK: - Token

    private func requestToken(authToken: String) {
        guard !isRequestingToken else { return }
        isRequestingToken = true
        tokenProvider.requestToken { [weak self] result in
            guard let self else { return }
            self.isRequestingToken = false
            switch result {
            case .success(let token):
                self.register(deviceToken: token, authToken: self.currentAuthToken() ?? authToken, force: true)
            case .failure(let failure):
                self.saveMissingToken(failure)
            }
        }
    }

    private func handleToken(_ token: String, force: Bool) {
        guard let authToken = currentAuthToken() else {
            persistStatus(.noSession, error: nil)
            return
        }
        register(deviceToken: token, authToken: authToken, force: force)
    }

    private func saveMissingToken(_ failure: PushTokenFailure) {
        var updated = record ?? PushDeviceRecord.empty(at: now())
        updated.token = nil
        updated.status = .missingToken
        updated.lastError = failure.message
        updated.attempts = 0
        updated.nextRetryAt = nil
        updated.updatedAt = now()
        persist(updated)
        log(
            failure.isConfigurationMissing ? "push.log.missingConfiguration" : "push.log.tokenFailed",
            detail: failure.message
        )
    }

    // MARK: - Registration

    private func register(deviceToken: String, authToken: String, force: Bool) {
        guard !deviceToken.isEmpty, !authToken.isEmpty else { return }
        guard !isRegistering else { return }
        if !force, let record,
           record.status == .registered,
           record.token == deviceToken,
           let remote = record.remoteDeviceID, !remote.isEmpty {
            return
        }

        let previous = record ?? store.load()
        let tokenChanged = previous?.token != nil && previous?.token != deviceToken
        let oldRemoteID = previous?.remoteDeviceID
        isRegistering = true

        let proceed = { [weak self] in
            self?.performRegistration(
                deviceToken: deviceToken,
                authToken: authToken,
                previous: previous,
                tokenChanged: tokenChanged
            )
        }

        // token 变化时先注销旧设备，避免服务端保留两条 active 记录；
        // 注销失败不阻塞新 token 注册。
        if tokenChanged, let oldRemoteID, !oldRemoteID.isEmpty {
            api.deactivate(deviceID: oldRemoteID, authToken: authToken) { _ in
                proceed()
            }
        } else {
            proceed()
        }
    }

    private func performRegistration(
        deviceToken: String,
        authToken: String,
        previous: PushDeviceRecord?,
        tokenChanged: Bool
    ) {
        let sameToken = previous?.token == deviceToken
        var pending = previous ?? PushDeviceRecord.empty(at: now())
        pending.token = deviceToken
        pending.platform = platform
        pending.status = .pending
        pending.lastError = nil
        pending.nextRetryAt = nil
        pending.attempts = sameToken ? (previous?.attempts ?? 0) : 0
        if tokenChanged || !sameToken {
            pending.remoteDeviceID = nil
        }
        pending.updatedAt = now()
        persist(pending)

        let payload = PushRegistrationPayload(
            platform: platform,
            token: deviceToken,
            appVersion: appVersion(),
            deviceModel: deviceModel()
        )
        api.register(payload: payload, authToken: authToken) { [weak self] result in
            guard let self else { return }
            self.isRegistering = false
            switch result {
            case .success(let remote):
                var updated = self.record ?? pending
                updated.token = deviceToken
                updated.remoteDeviceID = remote.id
                updated.status = .registered
                updated.lastError = nil
                updated.attempts = 0
                updated.nextRetryAt = nil
                updated.updatedAt = self.now()
                self.persist(updated)
                self.log("push.log.registered", detail: remote.id)
            case .failure(let error):
                self.handleFailure(
                    error,
                    deviceToken: deviceToken,
                    authToken: authToken,
                    previous: self.record ?? pending
                )
            }

            // 注册期间系统又送来了新 token：立即用最新 token 重注册。
            if self.isRegistering == false,
               let latest = self.tokenProvider.cachedToken,
               latest != deviceToken,
               let currentAuth = self.currentAuthToken() {
                self.register(deviceToken: latest, authToken: currentAuth, force: true)
            }
        }
    }

    private func handleFailure(
        _ error: AppError,
        deviceToken: String,
        authToken: String,
        previous: PushDeviceRecord
    ) {
        var updated = previous
        updated.token = deviceToken
        updated.updatedAt = now()

        if error.isUnauthorized {
            updated.status = .unauthorized
            updated.lastError = error.localizedDescriptionText
            updated.nextRetryAt = nil
            persist(updated)
            log("push.log.unauthorized", detail: error.localizedDescriptionText)
            return
        }

        if isTerminal(error) {
            updated.status = .rejected
            updated.lastError = readable(error)
            updated.nextRetryAt = nil
            persist(updated)
            log("push.log.rejected", detail: updated.lastError ?? "")
            return
        }

        let attempts = updated.attempts + 1
        let delay = retryDelay(for: error, attempts: attempts)
        updated.status = .pending
        updated.attempts = attempts
        updated.nextRetryAt = now().addingTimeInterval(delay)
        updated.lastError = readable(error)
        persist(updated)
        log("push.log.retryScheduled", detail: "\(updated.lastError ?? "") · \(Int(delay))s")
    }

    /// 4xx（401 / 429 除外）为终态，不自动重试；400 `PUSH_DEVICE_INVALID` 同属此类。
    private func isTerminal(_ error: AppError) -> Bool {
        switch error {
        case .network, .rateLimited, .server, .api:
            if error.isRetryable || error.isUnauthorized { return false }
            switch error {
            case .server(let status):
                return (400..<500).contains(status)
            case .api(_, let status, _):
                return (400..<500).contains(status)
            default:
                return false
            }
        case .decoding, .configuration, .database:
            return true
        case .sync, .bluetooth:
            return true
        }
    }

    private func retryDelay(for error: AppError, attempts: Int) -> TimeInterval {
        if case .rateLimited(let seconds) = error, let seconds {
            return TimeInterval(max(seconds, 1))
        }
        // 30s → 60s → 120s … 上限 1 小时。
        let exponential = 30 * pow(2.0, Double(max(attempts - 1, 0)))
        return min(exponential, 3600)
    }

    private func readable(_ error: AppError) -> String {
        switch error {
        case .api(let code, _, let message):
            return message.isEmpty ? code : "\(code) \(message)"
        case .network(let detail):
            return detail.isEmpty ? error.message : detail
        case .server(let statusCode):
            return "HTTP \(statusCode) \(error.message)"
        case .sync(let detail), .database(let detail), .bluetooth(let detail):
            return detail.isEmpty ? error.message : detail
        case .decoding, .configuration, .rateLimited:
            return error.message
        }
    }

    // MARK: - Persistence

    private func persistStatus(_ status: PushDeviceStatus, error: String?) {
        var updated = record ?? PushDeviceRecord.empty(at: now())
        updated.status = status
        updated.lastError = error
        updated.nextRetryAt = nil
        updated.updatedAt = now()
        persist(updated)
    }

    private func persist(_ updated: PushDeviceRecord) {
        record = updated
        store.save(updated)
        notifyChange()
    }

    private func currentAuthToken() -> String? {
        guard let token = tokenStore.load()?.token, !token.isEmpty else { return nil }
        return token
    }

    private func notifyChange() {
        if Thread.isMainThread {
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

    private func log(_ key: String, detail: String) {
        guard let logStore else { return }
        let entry = ScanLogEntry(
            category: .sync,
            level: .info,
            message: L10n.f(key, detail)
        )
        try? logStore.append(entry)
    }
}

// MARK: - Presentation

/// 「我的 → 通知与设置」里的推送状态展示。**未拿到真实 token 时绝不显示「已开启」**。
enum PushStatusPresentation {
    static func value(for record: PushDeviceRecord?, authorization: UNAuthorizationStatus) -> String {
        guard let record else { return L10n.t("push.status.missingToken") }
        switch record.status {
        case .noSession:
            return L10n.t("push.status.noSession")
        case .missingToken:
            return L10n.t("push.status.missingToken")
        case .pending:
            return record.attempts > 0
                ? L10n.t("push.status.retrying")
                : L10n.t("push.status.pending")
        case .registered:
            return authorization == .denied
                ? L10n.t("push.status.registeredWithoutPermission")
                : L10n.t("push.status.registered")
        case .rejected:
            return L10n.t("push.status.rejected")
        case .unauthorized:
            return L10n.t("push.status.unauthorized")
        case .deactivated:
            return L10n.t("push.status.deactivated")
        }
    }

    static func guidance(for record: PushDeviceRecord?, authorization: UNAuthorizationStatus) -> String {
        guard let record else { return L10n.t("push.guidance.missingToken") }
        switch record.status {
        case .noSession:
            return L10n.t("push.guidance.noSession")
        case .missingToken:
            if let error = record.lastError, !error.isEmpty {
                return L10n.f("push.guidance.missingTokenDetail", error)
            }
            return L10n.t("push.guidance.missingToken")
        case .pending:
            var text = L10n.t("push.guidance.pending")
            if let error = record.lastError, !error.isEmpty {
                text = L10n.f("push.guidance.pendingDetail", error)
            }
            if let next = record.nextRetryAt {
                return L10n.f("push.guidance.pendingRetryAt", text, Self.timeFormatter.string(from: next))
            }
            return text
        case .registered:
            return authorization == .denied
                ? L10n.t("push.guidance.registeredWithoutPermission")
                : L10n.t("push.guidance.registered")
        case .rejected:
            return L10n.f("push.guidance.rejectedDetail", record.lastError ?? L10n.t("push.status.rejected"))
        case .unauthorized:
            return L10n.t("push.guidance.unauthorized")
        case .deactivated:
            return L10n.t("push.guidance.deactivated")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
