import Foundation

/// 设备能力分类。只由 `ReadingCharacteristic` 支持的特征推导，不维护按型号名称的第二份分类表。
enum DeviceCapabilityCategory: String, CaseIterable, Equatable {
    case health
    case environment
    case multiDevice
    case other

    var title: String {
        switch self {
        case .health: return L10n.t("market.category.health")
        case .environment: return L10n.t("market.category.environment")
        case .multiDevice: return L10n.t("market.category.multiDevice")
        case .other: return L10n.t("market.category.other")
        }
    }

    var detail: String {
        switch self {
        case .health: return L10n.t("product.type.health.detail")
        case .environment: return L10n.t("product.type.environment.detail")
        case .multiDevice: return L10n.t("product.type.multiDevice.detail")
        case .other: return L10n.t("product.type.other.detail")
        }
    }
}

/// 兼容性查询中展示的已知限制，全部来自阅读器解析器的真实约束。
enum MarketLimitation: Equatable {
    /// Nordic UART 需要设备端按 `metric=value` 逐行输出。
    case nordicUARTLineFormat
    /// 型号登记了服务，但没有可识别的订阅特征。
    case noParsableMetric
    /// 型号未登记任何 GATT 服务。
    case noGATTService
    /// 没有可展示的固件版本。
    case firmwareUnknown

    var detail: String {
        switch self {
        case .nordicUARTLineFormat: return L10n.t("market.limitation.nus")
        case .noParsableMetric: return L10n.t("market.limitation.noMetric")
        case .noGATTService: return L10n.t("market.limitation.noGatt")
        case .firmwareUnknown: return L10n.t("market.limitation.firmwareUnknown")
        }
    }
}

/// 一个型号的兼容性画像：可解析指标、所需服务与限制。
struct DeviceCompatibilityProfile: Equatable {
    let id: String
    let deviceType: String
    let vendor: String
    let firmwareVersion: String
    let services: [GATTService]
    let metrics: [ReadingCharacteristic]
    let category: DeviceCapabilityCategory
    let limitations: [MarketLimitation]
    /// 服务端目录声明的指标；nil 表示没有目录数据（仅本地推导），空数组表示目录声明为透传。
    let declaredMetrics: [CatalogMetric]?
    /// 服务端目录声明的限制；nil 表示没有目录数据。
    let declaredLimitations: [String]?

    var displayName: String {
        deviceType.isEmpty ? L10n.t("product.cell.unnamed") : deviceType
    }

    var vendorText: String {
        vendor.isEmpty ? L10n.t("product.cell.unknownVendor") : vendor
    }

    var firmwareText: String {
        firmwareVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.t("common.unknown")
            : firmwareVersion
    }

    /// 指标文案以服务端目录为准：能解析的写名称与单位，解析不了的明确标注。
    var metricsText: String {
        if let declaredMetrics {
            if declaredMetrics.isEmpty {
                return L10n.t("catalog.metricsPassthrough")
            }
            return declaredMetrics.map(\.displayText).joined(separator: L10n.t("common.listSeparator"))
        }
        return metrics.isEmpty
            ? L10n.t("market.compatibility.noMetrics")
            : metrics.map(\.title).joined(separator: L10n.t("common.listSeparator"))
    }

    /// 限制文案：目录有声明时原样展示，没有才退回本地解析器的已知约束。
    var limitationsText: String {
        if let declaredLimitations {
            return declaredLimitations.isEmpty
                ? L10n.t("market.compatibility.noLimitations")
                : declaredLimitations.joined(separator: L10n.t("common.listSeparator"))
        }
        return limitations.isEmpty
            ? L10n.t("market.compatibility.noLimitations")
            : limitations.map(\.detail).joined(separator: L10n.t("common.listSeparator"))
    }

    var servicesText: String {
        services.isEmpty
            ? L10n.t("market.compatibility.noServices")
            : services.filter { !$0.uuid.isEmpty }.map { service in
                service.name.isEmpty ? service.uuid : "\(service.name) · \(service.uuid)"
            }.joined(separator: "\n")
    }
}

/// 选购场景。每个场景只认一个真实可解析指标。
enum DeviceScenario: CaseIterable, Equatable {
    case health
    case environment
    case multiDevice

    var requiredMetric: ReadingCharacteristic {
        switch self {
        case .health: return .heartRate
        case .environment: return .temperature
        case .multiDevice: return .nordicUART
        }
    }

    var title: String {
        switch self {
        case .health: return L10n.t("market.guide.health.title")
        case .environment: return L10n.t("market.guide.environment.title")
        case .multiDevice: return L10n.t("market.guide.multiDevice.title")
        }
    }

    var advice: String {
        switch self {
        case .health: return L10n.t("market.guide.health.body")
        case .environment: return L10n.t("market.guide.environment.body")
        case .multiDevice: return L10n.t("market.guide.multiDevice.body")
        }
    }
}

struct ScenarioRecommendation: Equatable {
    let scenario: DeviceScenario
    let candidates: [DeviceCompatibilityProfile]
    let evidence: String

    var candidatesText: String {
        candidates.isEmpty
            ? L10n.t("market.guide.noCandidates")
            : candidates.map(\.displayName).joined(separator: L10n.t("common.listSeparator"))
    }
}

/// 市场兼容性与选购指南的唯一推导入口。
///
/// 数据源只有两处：`ProductModel.gattServices`（服务端型号码表）与
/// `ReadingCharacteristic`（本机阅读器 UUID 真值表）。不新增任何型号名称映射。
enum MarketInsights {
    // MARK: - Profiles

    static func profiles(from products: [ProductModel]) -> [DeviceCompatibilityProfile] {
        products
            .map(profile(from:))
            .sorted {
                if $0.displayName == $1.displayName {
                    return $0.vendorText < $1.vendorText
                }
                return $0.displayName < $1.displayName
            }
    }

    static func profile(from product: ProductModel) -> DeviceCompatibilityProfile {
        let declared = product.typeIdentifier.isEmpty ? nil : product.catalogMetrics
        let declaredLimitations = product.typeIdentifier.isEmpty ? nil : product.catalogLimitations
        let metrics = declared.map {
            locallySupportedMetrics(from: $0, services: product.gattServices)
        } ?? supportedMetrics(in: product.gattServices)
        return DeviceCompatibilityProfile(
            id: product.id,
            deviceType: product.deviceType,
            vendor: product.vendor,
            firmwareVersion: product.firmwareVersion,
            services: product.gattServices,
            metrics: metrics,
            category: category(for: metrics),
            limitations: limitations(
                metrics: metrics,
                services: product.gattServices,
                firmwareVersion: product.firmwareVersion
            ),
            declaredMetrics: declared,
            declaredLimitations: declaredLimitations
        )
    }

    /// 目录声明的指标里，本机阅读器真正能解析的那部分。
    /// 判定依据是目录的 `characteristicUuid` 是否命中本地订阅表，而不是 key 名称相似。
    static func locallySupportedMetrics(
        from declared: [CatalogMetric],
        services: [GATTService]
    ) -> [ReadingCharacteristic] {
        var supported = Set(declared.compactMap(\.localCharacteristic))
        // 目录对 Nordic UART 声明空 metrics 表示透传，此时指标由客户端逐行解析。
        if declared.isEmpty, supportedMetrics(in: services).contains(.nordicUART) {
            supported.insert(.nordicUART)
        }
        return ReadingCharacteristic.allCases.filter { supported.contains($0) }
    }

    /// 服务 UUID 或特征 UUID 命中阅读器真值表即视为支持该指标。
    static func supportedMetrics(in services: [GATTService]) -> [ReadingCharacteristic] {
        ReadingCharacteristic.allCases.filter { characteristic in
            services.contains { service in
                matches(service.uuid, characteristic.serviceUUID)
                    || service.characteristics.contains { matches($0, characteristic.rawValue) }
            }
        }
    }

    static func category(for metrics: [ReadingCharacteristic]) -> DeviceCapabilityCategory {
        if metrics.contains(.heartRate) { return .health }
        if metrics.contains(.temperature) { return .environment }
        if metrics.contains(.nordicUART) { return .multiDevice }
        return .other
    }

    static func limitations(
        metrics: [ReadingCharacteristic],
        services: [GATTService],
        firmwareVersion: String
    ) -> [MarketLimitation] {
        var result: [MarketLimitation] = []
        if services.allSatisfy({ $0.uuid.isEmpty }) {
            result.append(.noGATTService)
        } else if metrics.isEmpty {
            result.append(.noParsableMetric)
        }
        if metrics.contains(.nordicUART) {
            result.append(.nordicUARTLineFormat)
        }
        if firmwareVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.firmwareUnknown)
        }
        return result
    }

    // MARK: - Scenarios

    static func recommendations(from profiles: [DeviceCompatibilityProfile]) -> [ScenarioRecommendation] {
        DeviceScenario.allCases.map { scenario in
            let metric = scenario.requiredMetric
            let candidates = profiles.filter { $0.metrics.contains(metric) }
            let evidence = L10n.f(
                "market.guide.evidence",
                "\(metric.serviceUUID) · \(metric.rawValue)"
            )
            return ScenarioRecommendation(scenario: scenario, candidates: candidates, evidence: evidence)
        }
    }

    // MARK: - UUID

    /// 把标准 128 位蓝牙基址归一成 16 位短 UUID；非标准 128 位（如 Nordic UART）保留全串。
    static func normalizedUUID(_ raw: String) -> String {
        let compact = raw.uppercased().filter { $0 != "-" }
        guard compact.count == 32 else { return compact }
        let baseTail = "00001000800000805F9B34FB"
        if compact.hasPrefix("0000"), compact.hasSuffix(baseTail) {
            return String(compact.dropFirst(4).prefix(4))
        }
        return compact
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedUUID(lhs)
        let right = normalizedUUID(rhs)
        return !left.isEmpty && left == right
    }
}
