import XCTest
@testable import codemagic

/// 详情页远端刷新策略：800ms 去抖动 + 指数退避（上限 5 分钟）。
final class ReadingsRefreshPolicyTests: XCTestCase {
    func testDefaultDelayIsDebounceWindow() {
        var policy = ReadingsRefreshPolicy()
        XCTAssertEqual(policy.nextDelay, 0.8)
        policy.recordSuccess()
        XCTAssertEqual(policy.nextDelay, 0.8)
    }

    func testFailuresBackOffExponentiallyAndCapAtFiveMinutes() {
        var policy = ReadingsRefreshPolicy()
        policy.recordFailure()
        XCTAssertEqual(policy.nextDelay, 1, accuracy: 0.001)
        policy.recordFailure()
        XCTAssertEqual(policy.nextDelay, 2, accuracy: 0.001)
        policy.recordFailure()
        XCTAssertEqual(policy.nextDelay, 4, accuracy: 0.001)

        for _ in 0..<20 { policy.recordFailure() }
        XCTAssertEqual(policy.nextDelay, 300, accuracy: 0.001, "退避上限 5 分钟")
    }

    func testSuccessResetsBackoff() {
        var policy = ReadingsRefreshPolicy()
        policy.recordFailure()
        policy.recordFailure()
        XCTAssertGreaterThan(policy.nextDelay, 0.8)
        policy.recordSuccess()
        XCTAssertEqual(policy.nextDelay, 0.8)
    }

    func testCustomDebounceIsRespected() {
        var policy = ReadingsRefreshPolicy(debounce: 0.2, maxBackoff: 60)
        XCTAssertEqual(policy.nextDelay, 0.2)
        policy.recordFailure()
        XCTAssertEqual(policy.nextDelay, 1, "首次失败从 2^0 秒开始，但不会低于 debounce")
    }
}
