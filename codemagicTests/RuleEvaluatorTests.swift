import XCTest
@testable import codemagic

final class RuleEvaluatorTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1000)

    func testDisconnectTriggersOnTransitionAndOnlyOnce() {
        let evaluator = RuleEvaluator()
        let device = makeSavedDevice(name: "面板")
        let rule = DeviceRule(name: "断开", trigger: .disconnect, deviceID: device.id)

        XCTAssertTrue(evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -50],
            date: baseDate
        ).isEmpty)

        let firstGone = evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [:],
            date: baseDate.addingTimeInterval(1)
        )
        XCTAssertEqual(firstGone.count, 1)
        XCTAssertTrue(firstGone[0].message.contains("已从扫描结果中消失"))

        XCTAssertTrue(evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [:],
            date: baseDate.addingTimeInterval(2)
        ).isEmpty)

        // 重新出现后再次消失，应再次触发。
        _ = evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -50],
            date: baseDate.addingTimeInterval(3)
        )
        let secondGone = evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [:],
            date: baseDate.addingTimeInterval(4)
        )
        XCTAssertEqual(secondGone.count, 1)
    }

    func testRSSIThresholdTriggersOnceAndRearms() {
        let evaluator = RuleEvaluator()
        let device = makeSavedDevice(name: "传感器")
        let rule = DeviceRule(name: "弱信号", trigger: .rssiBelowThreshold, threshold: -80)

        let low = evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -85],
            date: baseDate
        )
        XCTAssertEqual(low.count, 1)
        XCTAssertTrue(low[0].message.contains("-85 dBm"))

        XCTAssertTrue(evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -85],
            date: baseDate.addingTimeInterval(1)
        ).isEmpty)

        // 信号恢复后重新武装。
        _ = evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -60],
            date: baseDate.addingTimeInterval(2)
        )
        let againLow = evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -90],
            date: baseDate.addingTimeInterval(3)
        )
        XCTAssertEqual(againLow.count, 1)
    }

    func testDisabledRuleDoesNotTrigger() {
        let evaluator = RuleEvaluator()
        let device = makeSavedDevice()
        let rule = DeviceRule(
            name: "停用",
            trigger: .rssiBelowThreshold,
            threshold: -70,
            isEnabled: false
        )

        XCTAssertTrue(evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -95],
            date: baseDate
        ).isEmpty)
    }

    func testRuleOnlyTargetsConfiguredDevice() {
        let evaluator = RuleEvaluator()
        let target = makeSavedDevice(name: "目标设备")
        let other = makeSavedDevice(name: "其它设备")
        let rule = DeviceRule(
            name: "目标弱信号",
            trigger: .rssiBelowThreshold,
            threshold: -70,
            deviceID: target.id
        )

        let events = evaluator.evaluate(
            rules: [rule],
            devices: [target, other],
            observedRSSI: [other.peripheralID: -95],
            date: baseDate
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testResetClearsPreviousSession() {
        let evaluator = RuleEvaluator()
        let device = makeSavedDevice()
        let rule = DeviceRule(name: "断开", trigger: .disconnect)

        _ = evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -50],
            date: baseDate
        )
        evaluator.reset()

        XCTAssertTrue(evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [:],
            date: baseDate.addingTimeInterval(1)
        ).isEmpty)
    }
}
