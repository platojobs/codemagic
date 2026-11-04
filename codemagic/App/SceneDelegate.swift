import UIKit

/// 场景入口：不依赖 Storyboard/XIB，纯代码构建 UIWindow 与五模块 Tab 主干。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let environment = AppEnvironment.shared

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let tabBarController = MainTabBarController(environment: environment)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = tabBarController
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // 回到前台时补一次增量同步（120 秒内不重复）。
        SyncCoordinator.shared.syncOnForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        SyncCoordinator.shared.scheduleBackgroundSync()
    }
}
