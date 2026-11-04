import Foundation

/// 市场视图模型：配件与固件信息，只读展示，无购物车/订单/支付。
/// 筛选维度使用服务端真实字段：`vendor` 与 `compatibility` 展开后的字段值。
final class MarketViewModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded([MarketItem])
        case failed(AppError)
    }

    private(set) var state: State = .idle {
        didSet { onChange?() }
    }

    /// 服务端返回的全量条目；`state` 中的 `loaded` 是筛选后的结果。
    private(set) var allItems: [MarketItem] = []
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
        productService.fetchMarketItems { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let items):
                self.allItems = items
                self.dropInvalidFilters()
                self.applyFilters()

            case .failure(let error):
                self.allItems = []
                self.state = .failed(error)
            }
        }
    }

    // MARK: - Filters

    /// 厂商筛选取值：只包含非空 `vendor`。
    var vendors: [String] {
        uniqueSorted(allItems.map(\.vendor))
    }

    /// 兼容性筛选取值：来自 `Compatibility` 的真实字段值（平台 / 协议 / 扩展字段）。
    var compatibilityOptions: [String] {
        uniqueSorted(allItems.flatMap(\.compatibilityTags))
    }

    var hasActiveFilter: Bool {
        selectedVendor != nil || selectedCompatibility != nil
    }

    func selectVendor(_ vendor: String?) {
        selectedVendor = vendor
        applyFilters()
    }

    func selectCompatibility(_ tag: String?) {
        selectedCompatibility = tag
        applyFilters()
    }

    func resetFilters() {
        guard hasActiveFilter else { return }
        selectedVendor = nil
        selectedCompatibility = nil
        applyFilters()
    }

    var items: [MarketItem] {
        if case .loaded(let items) = state { return items }
        return []
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

    private func applyFilters() {
        let filtered = allItems.filter { item in
            if let vendor = selectedVendor, item.vendor != vendor { return false }
            if let tag = selectedCompatibility, !item.compatibilityTags.contains(tag) { return false }
            return true
        }
        state = .loaded(filtered)
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}
