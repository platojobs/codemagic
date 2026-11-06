import UIKit
import UserNotifications

/// 场景入口：不依赖 Storyboard/XIB，纯代码构建 UIWindow 与五模块 Tab 主干。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let environment = AppEnvironment.shared
    private weak var tabBarController: MainTabBarController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let tabBarController = MainTabBarController(environment: environment)
        self.tabBarController = tabBarController

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = tabBarController
        window.backgroundColor = Palette.canvas
        // 外观偏好（跟随系统 / 浅色 / 深色）在窗口级别生效，语义色随 trait 自动切换；
        // 导航栏 / 状态栏均跟随窗口的 userInterfaceStyle，不写死颜色。
        AppAppearance.apply(environment.settingsStore.appearance, to: window)
        window.makeKeyAndVisible()
        self.window = window
        LaunchMetrics.mark("window-visible")

        // 首帧布局提交发生在本次主线程回合结束时，下一回合记录终点。
        // 首启引导在首帧之后再呈现，不把引导搭建计入冷启动耗时。
        DispatchQueue.main.async { [weak self] in
            LaunchMetrics.markFirstFrame()
            self?.presentOnboardingIfNeeded()
        }

        UNUserNotificationCenter.current().delegate = self
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // 回到前台时补一次增量同步（120 秒内不重复）。
        SyncCoordinator.shared.syncOnForeground()
        // 反馈队列按有界指数退避补发到期草稿；幂等键保证不会产生重复记录。
        environment.feedbackCoordinator.retryEligible()
    }

    /// 首启引导：仅首次或未走完时出现；走完 / 跳过由引导页持久化。
    private func presentOnboardingIfNeeded() {
        guard !environment.settingsStore.onboardingCompleted,
              let tabBarController,
              tabBarController.presentedViewController == nil
        else { return }
        let onboarding = FirstRunOnboardingViewController(environment: environment)
        tabBarController.present(onboarding, animated: false)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // 后台采集关闭时立即断开所有 BLE 链路，避免系统继续为无用的连接唤醒进程。
        if !environment.settingsStore.backgroundCollectionEnabled {
            environment.bluetooth.disconnectAll()
        }
        SyncCoordinator.shared.scheduleBackgroundSync()
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension SceneDelegate: UNUserNotificationCenterDelegate {
    /// 前台也展示告警横幅，避免用户停留在应用内时漏掉通知。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// 点击通知进入对应设备详情；设备已被删除时只回到设备列表。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let deviceIDText = response.notification.request.content.userInfo[UserNotificationService.deviceIDKey] as? String
        if let deviceIDText, let deviceID = UUID(uuidString: deviceIDText) {
            tabBarController?.openDeviceDetail(deviceID: deviceID)
        }
        completionHandler()
    }
}
