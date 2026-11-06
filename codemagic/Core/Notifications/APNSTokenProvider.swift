import Foundation
import UIKit

/// 获取 APNs token 失败的原因。`isConfigurationMissing` 用于界面区分
/// 「未配置推送（缺证书 / entitlement）」与其它系统错误。
struct PushTokenFailure: Error, Equatable {
    let message: String
    let isConfigurationMissing: Bool
}

/// APNs token 来源抽象。生产实现调用 `registerForRemoteNotifications`，
/// 测试注入 fake；**任何实现都不得返回占位 token**。
protocol PushTokenProviding: AnyObject {
    var cachedToken: String? { get }
    /// 系统在应用生命周期内收到新 token / 失败时回调（用于 token 变化重注册）。
    var onUpdate: ((Result<String, PushTokenFailure>) -> Void)? { get set }
    func requestToken(completion: @escaping (Result<String, PushTokenFailure>) -> Void)
}

/// 基于 `UIApplication.registerForRemoteNotifications()` 的真实实现。
/// 没有推送证书与 `aps-environment` entitlement 时系统会失败，这里如实把失败
/// 传给上层；拿不到 token 时状态停在「未配置推送 / 无法获取令牌」。
final class APNSTokenProvider: PushTokenProviding {
    static let shared = APNSTokenProvider()

    private(set) var cachedToken: String?
    var onUpdate: ((Result<String, PushTokenFailure>) -> Void)?

    private var pending: [(Result<String, PushTokenFailure>) -> Void] = []
    private var isRequesting = false

    private init() {}

    func requestToken(completion: @escaping (Result<String, PushTokenFailure>) -> Void) {
        if let cachedToken {
            completion(.success(cachedToken))
            return
        }
        pending.append(completion)
        guard !isRequesting else { return }
        isRequesting = true
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
        // 系统通常立即回调成功或失败；超时兜底避免界面永久停在「注册中」。
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.isRequesting else { return }
            self.isRequesting = false
            let failure = PushTokenFailure(
                message: L10n.t("push.token.timeout"),
                isConfigurationMissing: false
            )
            self.deliver(.failure(failure))
        }
    }

    /// AppDelegate 转发 `didRegisterForRemoteNotificationsWithDeviceToken`。
    func handleDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else {
            handleRegistrationFailure(NSError(
                domain: "codemagic.push",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.t("push.token.empty")]
            ))
            return
        }
        cachedToken = token
        isRequesting = false
        onUpdate?(.success(token))
        deliver(.success(token))
    }

    /// AppDelegate 转发 `didFailToRegisterForRemoteNotificationsWithError`。
    func handleRegistrationFailure(_ error: Error) {
        let message = error.localizedDescription
        let lowercased = message.lowercased()
        let configurationMissing = lowercased.contains("aps-environment")
            || lowercased.contains("entitlement")
            || lowercased.contains("no valid")
        let failure = PushTokenFailure(
            message: message,
            isConfigurationMissing: configurationMissing
        )
        isRequesting = false
        onUpdate?(.failure(failure))
        deliver(.failure(failure))
    }

    private func deliver(_ result: Result<String, PushTokenFailure>) {
        let callbacks = pending
        pending.removeAll()
        for callback in callbacks {
            callback(result)
        }
    }
}
