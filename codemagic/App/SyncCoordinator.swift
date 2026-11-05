import BackgroundTasks
import UIKit

/// 后台同步：注册 `BGAppRefreshTask`，并在前后台切换时触发同步。
///
/// - 前台：`sceneDidBecomeActive` 调用 `syncOnForeground()`，按 120 秒节流；
/// - 后台：`sceneDidEnterBackground` 提交后台刷新任务，系统择机执行；
/// - 任务到期或失败都会 `setTaskCompleted`，不会悬挂后台任务。
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    static let taskIdentifier = "com.platojobs.codemagic.sync"

    private var engine: SyncEngine?
    private var isRegistered = false

    private init() {}

    func configure(engine: SyncEngine) {
        self.engine = engine
        registerBackgroundTask()
    }

    func syncOnForeground() {
        engine?.syncIfNeeded()
    }

    func scheduleBackgroundSync() {
        guard engine != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // 模拟器、低电量模式或后台刷新被用户关闭时会失败；同步不因此中断。
        }
    }

    // MARK: - Private

    private func registerBackgroundTask() {
        guard !isRegistered else { return }
        isRegistered = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handle(task)
        }
    }

    private func handle(_ task: BGTask) {
        // 每次执行后必须重新提交下一次请求。
        scheduleBackgroundSync()

        guard let engine, let refreshTask = task as? BGAppRefreshTask else {
            task.setTaskCompleted(success: false)
            return
        }

        var isCompleted = false
        func complete(_ success: Bool) {
            DispatchQueue.main.async {
                guard !isCompleted else { return }
                isCompleted = true
                refreshTask.setTaskCompleted(success: success)
            }
        }

        refreshTask.expirationHandler = { complete(false) }

        DispatchQueue.main.async {
            // 后台只做受限的「推送」：不拉增量、不建匿名账号，单次最多 100 设备 / 200 读数，
            // 并以 15 分钟最小间隔与失败节流避免唤醒风暴。
            engine.pushPendingInBackground { result in
                switch result {
                case .success:
                    complete(true)
                case .failure:
                    complete(false)
                }
            }
        }
    }
}
