import Foundation
import os

/// 冷启动打点：`markLaunchStart()` 在 `didFinishLaunching` 第一行调用，
/// `markFirstFrame()` 在根窗口完成首次布局提交后的下一个主线程回合调用。
///
/// 同时使用 `os_signpost`（Instruments 的 App Launch / Points of Interest 可直接查看）
/// 与控制台输出（`[LaunchMetrics] ...`，便于 CI / 模拟器脚本采集数字）。
enum LaunchMetrics {
    private static let signposter = OSSignposter(
        subsystem: "com.platojobs.codemagic",
        category: "launch"
    )
    private static var startUptimeNanoseconds: UInt64?
    private static var intervalState: OSSignpostIntervalState?

    /// 记录启动起点。重复调用只保留第一次，避免场景重建污染基线。
    static func markLaunchStart() {
        guard startUptimeNanoseconds == nil else { return }
        startUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        intervalState = signposter.beginInterval("AppLaunch")
        print("[LaunchMetrics] didFinishLaunching")
    }

    /// 记录阶段耗时，输出相对启动起点的毫秒数。
    static func mark(_ name: String) {
        guard let elapsed = elapsedMilliseconds() else { return }
        print("[LaunchMetrics] \(name) ms=\(format(elapsed))")
    }

    /// 首帧到达：结束 signpost 区间并输出总耗时。
    static func markFirstFrame() {
        guard let elapsed = elapsedMilliseconds() else { return }
        if let intervalState {
            signposter.endInterval("AppLaunch", intervalState)
        }
        self.intervalState = nil
        print("[LaunchMetrics] first-frame ms=\(format(elapsed))")
    }

    private static func elapsedMilliseconds() -> Double? {
        guard let start = startUptimeNanoseconds else { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
