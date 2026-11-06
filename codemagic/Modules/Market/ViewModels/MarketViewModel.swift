import Foundation

/// 市场视图模型：兼容性查询、选购指南、服务入口与可隐藏的示例条目。
///
/// 兼容性数据只来自 `ProductModel.gattServices` 与 `ReadingCharacteristic` 的推导结果，
/// 不维护第二份型号/能力真值；示例条目默认隐藏，避免被误认为在售商品。
final class MarketViewModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(AppError)
    }

    private(set) var state: State = .idle {
        didSet { onChange?() }
    }

    private(set) var profiles: [DeviceCompatibilityProfile] = []
    private(set) var sampleItems: [MarketItem] = []
    private(set) var marketItemsError: AppError?
    private(set) var selectedTypeID: String?
    private(set) var showSampleItems = false
    private(set) var selectedVendor: String?
    private(set) var selectedCompatibility: String?

    var onChange: (() -> Void)?

    private let productService: ProductServicing
    private var hasLoaded = false

    init(productService: ProductServicing) {
        self.productService = productService
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    func reload() {
        state = .loading
        productService.fetchCatalogSnapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.profiles = MarketInsights.profiles(from: snapshot.products)
                self.sampleItems = snapshot.marketItems
                self.marketItemsError = snapshot.marketItemsError
                if let selected = self.selectedTypeID,
                   !self.profiles.contains(where: { $0.id == selected }) {
                    self.selectedTypeID = nil
                }
                if self.selectedTypeID == nil {
                    self.selectedTypeID = self.profiles.first?.id
                }
                self.dropInvalidFilters()
                self.state = .loaded

            case .failure(let error):
                self.profiles = []
                self.sampleItems = []
                self.marketItemsError = nil
                self.selectedTypeID = nil
                self.state = .failed(error)
            }
        }
    }

    // MARK: - 兼容性查询

    var selectedProfile: DeviceCompatibilityProfile? {
        guard let selectedTypeID else { return profiles.first }
        return profiles.first { $0.id == selectedTypeID }
    }

    func selectType(_ id: String) {
        guard profiles.contains(where: { $0.id == id }), selectedTypeID != id else { return }
        selectedTypeID = id
        onChange?()
    }

    var recommendations: [ScenarioRecommendation] {
        MarketInsights.recommendations(from: profiles)
    }

    // MARK: - 示例条目

    func setShowSampleItems(_ visible: Bool) {
        guard showSampleItems != visible else { return }
        showSampleItems = visible
        onChange?()
    }

    var hasContent: Bool {
        if case .loaded = state {
            return !profiles.isEmpty || (showSampleItems && !sampleItems.isEmpty)
        }
        return false
    }

    var vendors: [String] {
        uniqueSorted(sampleItems.map(\.vendor))
    }

    var compatibilityOptions: [String] {
        uniqueSorted(sampleItems.flatMap(\.compatibilityTags))
    }

    var hasActiveFilter: Bool {
        selectedVendor != nil || selectedCompatibility != nil
    }

    func selectVendor(_ vendor: String?) {
        selectedVendor = vendor
        applyFiltersDroppingInvalid()
    }

    func selectCompatibility(_ tag: String?) {
        selectedCompatibility = tag
        applyFiltersDroppingInvalid()
    }

    func resetFilters() {
        guard hasActiveFilter else { return }
        selectedVendor = nil
        selectedCompatibility = nil
        onChange?()
    }

    /// 仅在开启「示例条目」时用于列表展示；筛选维度仍是服务端真实字段。
    var items: [MarketItem] {
        sampleItems.filter { item in
            if let vendor = selectedVendor, item.vendor != vendor { return false }
            if let tag = selectedCompatibility, !item.compatibilityTags.contains(tag) { return false }
            return true
        }
    }

    // MARK: - Private

    private func dropInvalidFilters() {
        if let vendor = selectedVendor, !vendors.contains(vendor) {
            selectedVendor = nil
        }
        if let tag = selectedCompatibility, !compatibilityOptions.contains(tag) {
            selectedCompatibility = nil
        }
    }

    private func applyFiltersDroppingInvalid() {
        dropInvalidFilters()
        onChange?()
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}
