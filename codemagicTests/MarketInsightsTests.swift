import XCTest
@testable import codemagic

/// 兼容性 / 选购指南推导：只依赖 GATT 服务表与阅读器 UUID 真值表。
final class MarketInsightsTests: XCTestCase {
    func testShortAndFullUUIDNormalization() {
        XCTAssertEqual(
            MarketInsights.normalizedUUID("0000180D-0000-1000-8000-00805F9B34FB"),
            "180D"
        )
        XCTAssertEqual(
            MarketInsights.normalizedUUID("6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
            "6E400001B5A3F393E0A9E50E24DCCA9E"
        )
        XCTAssertTrue(MarketInsights.matches("180D", "0000180d-0000-1000-8000-00805f9b34fb"))
        XCTAssertFalse(MarketInsights.matches("180D", "180F"))
        XCTAssertFalse(MarketInsights.matches("", ""), "空 UUID 不能互相命中")
    }

    func testSupportedMetricsFromServiceAndCharacteristic() {
        let services = [
            GATTService(uuid: "180D", name: "Heart Rate"),
            GATTService(uuid: "custom-service", name: "Custom", characteristics: ["2A19"]),
            GATTService(uuid: ReadingCharacteristic.nordicUART.serviceUUID, name: "NUS"),
        ]
        let metrics = MarketInsights.supportedMetrics(in: services)
        XCTAssertEqual(metrics, [.heartRate, .battery, .nordicUART])

        XCTAssertTrue(MarketInsights.supportedMetrics(in: []).isEmpty)
        XCTAssertTrue(MarketInsights.supportedMetrics(in: [GATTService(uuid: "", name: "")]).isEmpty)
    }

    func testCategoryUsesCapabilityPriority() {
        XCTAssertEqual(MarketInsights.category(for: [.heartRate]), .health)
        XCTAssertEqual(MarketInsights.category(for: [.temperature]), .environment)
        XCTAssertEqual(MarketInsights.category(for: [.nordicUART]), .multiDevice)
        XCTAssertEqual(MarketInsights.category(for: [.battery]), .other)
        XCTAssertEqual(MarketInsights.category(for: []), .other)
        XCTAssertEqual(
            MarketInsights.category(for: [.heartRate, .temperature]),
            .health,
            "同时具备多种能力时按健康 → 环境 → 组网排序取第一个"
        )
    }

    func testLimitationsReflectParserConstraints() {
        let noServices = MarketInsights.limitations(metrics: [], services: [], firmwareVersion: "")
        XCTAssertEqual(noServices, [.noGATTService, .firmwareUnknown])

        let noMetric = MarketInsights.limitations(
            metrics: [],
            services: [GATTService(uuid: "180A", name: "Device Information")],
            firmwareVersion: "1.0"
        )
        XCTAssertEqual(noMetric, [.noParsableMetric])

        let nus = MarketInsights.limitations(
            metrics: [.nordicUART],
            services: [GATTService(uuid: ReadingCharacteristic.nordicUART.serviceUUID, name: "NUS")],
            firmwareVersion: "2.1"
        )
        XCTAssertEqual(nus, [.nordicUARTLineFormat])
    }

    func testRecommendationsOnlyIncludeCapableModels() {
        let heartRate = makeCapabilityProduct(
            deviceType: "HR-1",
            services: [GATTService(uuid: "180D", name: "Heart Rate")]
        )
        let temperature = makeCapabilityProduct(
            deviceType: "TEMP-1",
            services: [GATTService(uuid: "1809", name: "Thermometer")]
        )
        let nus = makeCapabilityProduct(
            deviceType: "NUS-1",
            services: [GATTService(uuid: ReadingCharacteristic.nordicUART.serviceUUID, name: "NUS")]
        )
        let batteryOnly = makeCapabilityProduct(
            deviceType: "BAT-1",
            services: [GATTService(uuid: "180F", name: "Battery")]
        )
        let profiles = MarketInsights.profiles(from: [heartRate, temperature, nus, batteryOnly])
        let recommendations = MarketInsights.recommendations(from: profiles)

        XCTAssertEqual(recommendations.map(\.scenario), [.health, .environment, .multiDevice])
        XCTAssertEqual(recommendations[0].candidates.map(\.displayName), ["HR-1"])
        XCTAssertEqual(recommendations[1].candidates.map(\.displayName), ["TEMP-1"])
        XCTAssertEqual(recommendations[2].candidates.map(\.displayName), ["NUS-1"])
        XCTAssertTrue(recommendations[0].evidence.contains("180D"))
        XCTAssertTrue(recommendations[2].evidence.contains("6E400001"))
        XCTAssertTrue(
            recommendations.allSatisfy { $0.candidates.allSatisfy { $0.category != .other } },
            "仅有电池电量的型号不进入任何场景推荐"
        )
    }

    func testProfilesSortedByNameThenVendor() {
        let profiles = MarketInsights.profiles(from: [
            makeCapabilityProduct(deviceType: "B", vendor: "Zeta"),
            makeCapabilityProduct(deviceType: "A", vendor: "Acme"),
            makeCapabilityProduct(deviceType: "B", vendor: "Acme"),
        ])
        XCTAssertEqual(profiles.map { "\($0.displayName)/\($0.vendorText)" }, ["A/Acme", "B/Acme", "B/Zeta"])
    }

    func testProductsCategoryFilterUsesDerivedCapabilities() {
        let service = StubProductService()
        service.productsResult = .success([
            makeCapabilityProduct(deviceType: "HR", services: [GATTService(uuid: "180D", name: "Heart Rate")]),
            makeCapabilityProduct(deviceType: "TEMP", services: [GATTService(uuid: "1809", name: "Temperature")]),
            makeCapabilityProduct(deviceType: "BAT", services: [GATTService(uuid: "180F", name: "Battery")]),
        ])
        let viewModel = ProductsViewModel(productService: service)
        viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.allProducts.count, 3)
        XCTAssertEqual(viewModel.categories, [.health, .environment, .other])
        XCTAssertEqual(viewModel.selectedCategory, .all)
        XCTAssertFalse(viewModel.hasActiveCategory)

        viewModel.selectCategory(.category(.health))
        XCTAssertEqual(viewModel.products.map(\.deviceType), ["HR"])
        XCTAssertTrue(viewModel.hasActiveCategory)

        viewModel.selectCategory(.all)
        XCTAssertEqual(viewModel.products.count, 3)
        XCTAssertFalse(viewModel.hasActiveCategory)
    }
}

private extension MarketInsightsTests {
    func makeCapabilityProduct(
        deviceType: String,
        vendor: String = "Acme",
        services: [GATTService] = []
    ) -> ProductModel {
        ProductModel(
            mac: "",
            vendor: vendor,
            deviceType: deviceType,
            firmwareVersion: "1.0",
            gattServices: services,
            compatibility: []
        )
    }
}
