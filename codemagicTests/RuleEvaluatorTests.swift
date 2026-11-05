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

        // 重新出现时发「已恢复」，再次消失才再次触发。
        let recovered = evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -50],
            date: baseDate.addingTimeInterval(3)
        )
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].kind, .recovered)
        XCTAssertTrue(recovered[0].message.contains("已重新出现"))
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

        // 信号恢复后发「已恢复」并重新武装。
        let recovered = evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -60],
            date: baseDate.addingTimeInterval(2)
        )
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].kind, .recovered)
        XCTAssertEqual(recovered[0].deviceID, device.id, "恢复事件带设备 ID，供通知点击跳转")
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
