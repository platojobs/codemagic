import UIKit

/// 应用入口：采用 UIKit 生命周期，窗口与根视图控制器由 SceneDelegate 纯代码创建。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        LaunchMetrics.markLaunchStart()
        // 后台任务必须在 didFinishLaunching 返回前注册。
        SyncCoordinator.shared.configure(engine: AppEnvironment.shared.syncEngine)
        LaunchMetrics.mark("environment-ready")
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        if !AppEnvironment.shared.settingsStore.backgroundCollectionEnabled {
            AppEnvironment.shared.bluetooth.disconnectAll()
        }
        SyncCoordinator.shared.scheduleBackgroundSync()
    }

    // MARK: - Remote notifications

    /// 系统拿到 APNs token 后交给 `APNSTokenProvider`；注册请求本身由
    /// `PushRegistrationService` 在会话就绪 / token 变化时发起。
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        APNSTokenProvider.shared.handleDeviceToken(deviceToken)
    }

    /// 没有推送证书 / entitlement 时系统会走到这里；如实记录失败，
    /// 不伪造 token，界面保持「未配置推送 / 无法获取令牌」。
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        APNSTokenProvider.shared.handleRegistrationFailure(error)
    }
}
