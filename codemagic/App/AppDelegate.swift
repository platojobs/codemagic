import UIKit

/// 应用入口：采用 UIKit 生命周期，窗口与根视图控制器由 SceneDelegate 纯代码创建。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 后台任务必须在 didFinishLaunching 返回前注册。
        SyncCoordinator.shared.configure(engine: AppEnvironment.shared.syncEngine)
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        SyncCoordinator.shared.scheduleBackgroundSync()
    }
}
