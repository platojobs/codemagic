import Foundation

/// 远端读数查询的去抖动与退避策略。
///
/// - 读数入库不直接触发网络：调用方在 800ms 窗口内多次请求只合并为一次；
/// - 失败后按 1s → 2s → 4s … 指数退避，上限 5 分钟，与 notify 频率解耦；
/// - 成功后清零，回到下一次窗口。
struct ReadingsRefreshPolicy: Equatable {
    var debounce: TimeInterval
    var maxBackoff: TimeInterval
    private(set) var consecutiveFailures: Int

    init(debounce: TimeInterval = 0.8, maxBackoff: TimeInterval = 300) {
        self.debounce = debounce
        self.maxBackoff = maxBackoff
        self.consecutiveFailures = 0
    }

    /// 下一次远端刷新需要等待的时长。
    var nextDelay: TimeInterval {
        guard consecutiveFailures > 0 else { return debounce }
        let exponent = Double(min(consecutiveFailures - 1, 20))
        let backoff = pow(2, exponent)
        return min(max(debounce, backoff), maxBackoff)
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    mutating func recordFailure() {
        consecutiveFailures += 1
    }
}
