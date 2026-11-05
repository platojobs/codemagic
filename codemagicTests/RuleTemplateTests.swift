import XCTest
@testable import codemagic

/// 推荐规则：只按设备真实出现过的指标生成模板，一键写入复用现有 readingThreshold 规则。
final class RuleTemplateTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var database: SQLiteDatabase!
    private var savedDeviceStore: SavedDeviceStore!
    private var readingsStore: ReadingsStore!
    private var ruleStore: DeviceRuleStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        database = testDatabase.database
        savedDeviceStore = SavedDeviceStore(database: database)
        readingsStore = ReadingsStore(database: database)
        ruleStore = DeviceRuleStore(database: database)
    }

    override func tearDown() {
        testDatabase?.cleanUp()
        testDatabase = nil
        super.tearDown()
    }

    func testTemplatesOnlyUseMetricsActuallyPresent() {
        let templates = RuleTemplateCatalog.templates(for: [.temperature, .battery])

        XCTAssertEqual(templates.map(\.metric), [.temperature, .battery])
        XCTAssertEqual(templates.map(\.threshold), [30, 20])
        XCTAssertEqual(templates.map(\.comparison), [.greaterThan, .lessThan])
        // 湿度 / 心率 / CO₂ 没有出现过，不得凭空列出。
        XCTAssertFalse(templates.contains { $0.metric == .humidity })
        XCTAssertFalse(templates.contains { $0.metric == .heartRate })
        XCTAssertFalse(templates.contains { $0.metric == .co2 })
    }

    func testUnsupportedMetricsProduceNoTemplate() {
        XCTAssertTrue(RuleTemplateCatalog.templates(for: [.pressure, .other]).isEmpty)
        XCTAssertNil(RuleTemplateCatalog.preset(for: .pressure))
        XCTAssertNil(RuleTemplateCatalog.preset(for: .other))
    }

    func testPresetThresholdsMatchAndroidDefaults() {
        XCTAssertEqual(RuleTemplateCatalog.preset(for: .temperature)?.threshold, 30)
        XCTAssertEqual(RuleTemplateCatalog.preset(for: .humidity)?.threshold, 70)
        XCTAssertEqual(RuleTemplateCatalog.preset(for: .battery)?.threshold, 20)
        XCTAssertEqual(RuleTemplateCatalog.preset(for: .heartRate)?.threshold, 120)
        XCTAssertEqual(RuleTemplateCatalog.preset(for: .co2)?.threshold, 1000)
    }

    func testTemplateTitleAndDetailCarryMetricNameAndUnit() {
        let template = RuleTemplate(metric: .temperature, comparison: .greaterThan, threshold: 30, consecutive: 1)

        XCTAssertTrue(template.title.contains("30"), template.title)
        XCTAssertTrue(template.title.contains("℃"), template.title)
        XCTAssertTrue(template.detail.contains("1"), template.detail)
        XCTAssertEqual(template.makeRule(deviceID: UUID()).trigger, .readingThreshold)
        XCTAssertEqual(template.makeRule(deviceID: UUID()).consecutive, 1)
    }

    func testEmptyStateWithoutAnyDevice() {
        let viewModel = makeViewModel()
        viewModel.reload()

        XCTAssertFalse(viewModel.hasDevices)
        XCTAssertTrue(viewModel.showsEmptyState)
        XCTAssertEqual(viewModel.emptyTitle, L10n.t("smart.recommended.noDevices"))
    }

    func testEmptyStateWithDeviceButNoReadings() throws {
        try savedDeviceStore.upsert(makeSavedDevice())
        let viewModel = makeViewModel()
        viewModel.reload()

        XCTAssertTrue(viewModel.hasDevices)
        XCTAssertTrue(viewModel.templates.isEmpty)
        XCTAssertTrue(viewModel.showsEmptyState)
        XCTAssertEqual(viewModel.emptyTitle, L10n.t("smart.recommended.emptyTitle"))
        XCTAssertEqual(viewModel.emptyMessage, L10n.t("smart.recommended.empty"))
    }

    func testTemplatesFollowRealReadingsAndOneTapAddsRule() throws {
        let device = makeSavedDevice()
        try savedDeviceStore.upsert(device)
        try readingsStore.insert(DeviceReading(
            deviceID: device.id,
            metric: .temperature,
            value: 26.5,
            unit: "℃"
        ))
        try readingsStore.insert(DeviceReading(
            deviceID: device.id,
            metric: .heartRate,
            value: 88,
            unit: "bpm"
        ))

        let viewModel = makeViewModel()
        viewModel.reload()

        XCTAssertEqual(viewModel.templates.map(\.metric), [.temperature, .heartRate])

        let template = try XCTUnwrap(viewModel.templates.first)
        let rule = try XCTUnwrap(viewModel.addTemplate(template))
        let stored = try ruleStore.fetchAll()

        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, rule.id)
        XCTAssertEqual(stored.first?.trigger, .readingThreshold)
        XCTAssertEqual(stored.first?.metric, .temperature)
        XCTAssertEqual(stored.first?.readingThreshold, 30)
        XCTAssertEqual(stored.first?.consecutive, 1)
        XCTAssertEqual(stored.first?.deviceID, device.id)
    }

    func testSwitchDeviceRegeneratesTemplates() throws {
        let temperatureDevice = makeSavedDevice(name: "温湿度计")
        let batteryDevice = makeSavedDevice(name: "电量面板")
        try savedDeviceStore.upsert(temperatureDevice)
        try savedDeviceStore.upsert(batteryDevice)
        try readingsStore.insert(DeviceReading(deviceID: temperatureDevice.id, metric: .temperature, value: 24, unit: "℃"))
        try readingsStore.insert(DeviceReading(deviceID: batteryDevice.id, metric: .battery, value: 80, unit: "%"))

        let viewModel = makeViewModel()
        viewModel.reload()
        viewModel.selectDevice(temperatureDevice.id)
        XCTAssertEqual(viewModel.templates.map(\.metric), [.temperature])

        viewModel.selectDevice(batteryDevice.id)
        XCTAssertEqual(viewModel.templates.map(\.metric), [.battery])
    }

    private func makeViewModel() -> RecommendedRulesViewModel {
        RecommendedRulesViewModel(
            readingsStore: readingsStore,
            savedDeviceStore: savedDeviceStore,
            ruleStore: ruleStore
        )
    }
}
