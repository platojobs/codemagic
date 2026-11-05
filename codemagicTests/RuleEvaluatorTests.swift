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

    // MARK: - 指标阈值（读数规则）

    private func temperature(_ value: Double, index: Int = 0) -> DeviceReading {
        DeviceReading(
            deviceID: device.id,
            metric: .temperature,
            value: value,
            unit: "℃",
            recordedAt: baseDate.addingTimeInterval(Double(index))
        )
    }

    private let device = makeSavedDevice(name: "温湿度计")

    func testReadingRuleNeedsConsecutiveSamples() {
        let evaluator = RuleEvaluator()
        let rule = DeviceRule(
            name: "高温",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterOrEqual,
            readingThreshold: 30,
            consecutive: 3
        )

        // 前两条满足也不触发（防抖）。
        XCTAssertTrue(evaluator.evaluateReadings(
            rules: [rule], device: device, readings: [temperature(31, index: 0)]
        ).isEmpty)
        XCTAssertTrue(evaluator.evaluateReadings(
            rules: [rule], device: device, readings: [temperature(32, index: 1)]
        ).isEmpty)

        let events = evaluator.evaluateReadings(
            rules: [rule], device: device, readings: [temperature(32.5, index: 2)]
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .triggered)
        XCTAssertEqual(events[0].value, 32.5)
        XCTAssertEqual(events[0].threshold, 30)
        XCTAssertEqual(events[0].unit, "℃")
        XCTAssertEqual(events[0].deviceID, device.id)
        XCTAssertEqual(events[0].deviceName, "温湿度计")
        XCTAssertTrue(events[0].message.contains("32.5 ℃"), "命中日志必须带触发值与单位")
        XCTAssertTrue(events[0].message.contains("30 ℃"), "命中日志必须带阈值与单位")
        XCTAssertTrue(events[0].message.contains("连续 3 条"), "命中日志要说明防抖条数")
    }

    func testReadingRuleComparisonBoundaries() {
        let cases: [(RuleComparison, Double, Bool)] = [
            (.greaterThan, 30, false),
            (.greaterThan, 30.1, true),
            (.greaterOrEqual, 30, true),
            (.lessOrEqual, 30, true),
            (.lessOrEqual, 30.1, false),
            (.lessThan, 29.9, true),
        ]
        for (comparison, value, expected) in cases {
            let evaluator = RuleEvaluator()
            let rule = DeviceRule(
                name: "边界",
                trigger: .readingThreshold,
                metric: .temperature,
                comparison: comparison,
                readingThreshold: 30
            )
            let events = evaluator.evaluateReadings(
                rules: [rule], device: device, readings: [temperature(value)]
            )
            XCTAssertEqual(events.isEmpty, !expected, "\(comparison.symbol) \(value)")
        }
    }

    func testReadingRuleStreakResetsWhenSampleFails() {
        let evaluator = RuleEvaluator()
        let rule = DeviceRule(
            name: "高温",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterThan,
            readingThreshold: 30,
            consecutive: 3
        )

        _ = evaluator.evaluateReadings(rules: [rule], device: device, readings: [temperature(31, index: 0)])
        _ = evaluator.evaluateReadings(rules: [rule], device: device, readings: [temperature(31, index: 1)])
        // 第三条不满足 → 连续计数清零。
        XCTAssertEqual(
            evaluator.evaluateReadings(rules: [rule], device: device, readings: [temperature(20, index: 2)]).count,
            0
        )
        // 清零后即使再满足两条也不触发。
        XCTAssertTrue(evaluator.evaluateReadings(
            rules: [rule], device: device, readings: [temperature(31, index: 3)]
        ).isEmpty)
        XCTAssertTrue(evaluator.evaluateReadings(
            rules: [rule], device: device, readings: [temperature(31, index: 4)]
        ).isEmpty)
        XCTAssertEqual(
            evaluator.evaluateReadings(rules: [rule], device: device, readings: [temperature(31, index: 5)]).count,
            1
        )
    }

    func testReadingRuleRecoversOnceAfterAlert() {
        let evaluator = RuleEvaluator()
        let rule = DeviceRule(
            name: "高温",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterOrEqual,
            readingThreshold: 30
        )

        XCTAssertEqual(
            evaluator.evaluateReadings(rules: [rule], device: device, readings: [temperature(31, index: 0)]).count,
            1
        )
        // 持续满足不重复告警。
        XCTAssertTrue(evaluator.evaluateReadings(
            rules: [rule], device: device, readings: [temperature(32, index: 1)]
        ).isEmpty)

        let recovered = evaluator.evaluateReadings(
            rules: [rule], device: device, readings: [temperature(28, index: 2)]
        )
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].kind, .recovered)
        XCTAssertTrue(recovered[0].message.contains("已恢复"))
        XCTAssertTrue(recovered[0].message.contains("28 ℃"))

        // 已经恢复后继续正常读数不产生事件。
        XCTAssertTrue(evaluator.evaluateReadings(
            rules: [rule], device: device, readings: [temperature(27, index: 3)]
        ).isEmpty)
        // 重新满足后再次告警一次。
        XCTAssertEqual(
            evaluator.evaluateReadings(rules: [rule], device: device, readings: [temperature(31, index: 4)]).count,
            1
        )
    }

    func testReadingRuleSkipsOtherMetricsDisabledAndOtherDevices() {
        let evaluator = RuleEvaluator()
        let otherDevice = makeSavedDevice(name: "别的设备")
        let temperatureRule = DeviceRule(
            name: "高温",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterOrEqual,
            readingThreshold: 30,
            deviceID: device.id
        )
        let disabled = DeviceRule(
            name: "停用",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterOrEqual,
            readingThreshold: 30,
            isEnabled: false
        )
        let rssiRule = DeviceRule(name: "信号", trigger: .rssiBelowThreshold, threshold: -80)

        let humidity = DeviceReading(
            deviceID: device.id,
            metric: .humidity,
            value: 90,
            unit: "%",
            recordedAt: baseDate
        )
        XCTAssertTrue(evaluator.evaluateReadings(
            rules: [temperatureRule, disabled, rssiRule], device: device, readings: [humidity]
        ).isEmpty)
        XCTAssertTrue(evaluator.evaluateReadings(
            rules: [temperatureRule], device: otherDevice, readings: [temperature(35)]
        ).isEmpty, "规则限定设备时其它设备的读数不参与判定")
    }

    func testReadingRuleSupportsAllDocumentedMetricsWithUnitInMessage() {
        let samples: [(ReadingMetric, Double, String)] = [
            (.humidity, 82, "%"),
            (.battery, 12, "%"),
            (.heartRate, 128, "bpm"),
            (.co2, 1500, "ppm"),
        ]
        for (metric, value, unit) in samples {
            let evaluator = RuleEvaluator()
            let rule = DeviceRule(
                name: "指标",
                trigger: .readingThreshold,
                metric: metric,
                comparison: .greaterOrEqual,
                readingThreshold: value,
                deviceID: device.id
            )
            let reading = DeviceReading(
                deviceID: device.id,
                metric: metric,
                value: value,
                unit: unit,
                recordedAt: baseDate
            )
            let events = evaluator.evaluateReadings(rules: [rule], device: device, readings: [reading])
            XCTAssertEqual(events.count, 1, "\(metric)")
            XCTAssertTrue(events[0].message.contains(unit), "\(metric) 命中日志要带单位 \(unit)")
            XCTAssertEqual(rule.triggerDescription.contains(unit), true, "规则描述要带单位")
        }
    }

    func testReadingRuleDescriptionFormatsValuesWithUnit() {
        let single = DeviceRule(
            name: "高温",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterThan,
            readingThreshold: 30,
            consecutive: 1
        )
        XCTAssertEqual(single.triggerDescription, "温度 > 30 ℃ 时告警")

        let five = DeviceRule(
            name: "低温",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .lessThan,
            readingThreshold: 18.5,
            consecutive: 5
        )
        XCTAssertEqual(five.triggerDescription, "温度 < 18.5 ℃，连续 5 条读数时告警")
        XCTAssertEqual(DeviceRule.formatReading(30, unit: "℃"), "30 ℃")
        XCTAssertEqual(DeviceRule.formatReading(30.55, unit: "℃"), "30.6 ℃")
    }

    func testReadingRuleIgnoresScanEvaluation() {
        let evaluator = RuleEvaluator()
        let rule = DeviceRule(
            name: "高温",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterOrEqual,
            readingThreshold: 30
        )
        XCTAssertTrue(evaluator.evaluate(
            rules: [rule],
            devices: [device],
            observedRSSI: [device.peripheralID: -50],
            date: baseDate
        ).isEmpty)
    }
}
