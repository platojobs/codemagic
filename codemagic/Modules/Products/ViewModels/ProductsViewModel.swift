import Foundation

/// 产品目录的类型筛选。分类由 GATT 能力推导，不按型号名称硬编码。
enum ProductCategoryFilter: Equatable {
    case all
    case category(DeviceCapabilityCategory)
}

/// 产品库视图模型：数据只来自网络层，不内置任何本地假数据。
final class ProductsViewModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded([ProductModel])
        case failed(AppError)
    }

    private(set) var state: State = .idle {
        didSet { onChange?() }
    }
    private(set) var selectedCategory: ProductCategoryFilter = .all
    /// 目录来源与更新时间，用于「目录更新时间 / 离线缓存」标注。
    private(set) var catalogInfo: DeviceCatalogSnapshot?
    /// 已有缓存内容时刷新失败不切空白页，只记录错误供界面提示。
    private(set) var refreshError: AppError?

    var onChange: (() -> Void)?

    private let productService: ProductServicing
    private var hasLoaded = false

    init(productService: ProductServicing) {
        self.productService = productService
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        // 先渲染本地缓存，网络刷新在后台进行，不阻塞首屏。
        if let cached = productService.cachedCatalogSnapshot() {
            apply(cached)
        }
        reload()
    }

    func reload() {
        if allProducts.isEmpty {
            state = .loading
        }
        productService.fetchCatalogSnapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.refreshError = nil
                self.apply(snapshot)
            case .failure(let error):
                if self.allProducts.isEmpty {
                    self.catalogInfo = nil
                    self.state = .failed(error)
                } else {
                    self.refreshError = error
                    self.onChange?()
                }
            }
        }
    }

    private func apply(_ snapshot: ProductCatalogSnapshot) {
        catalogInfo = snapshot.catalogInfo
        state = .loaded(snapshot.products)
    }

    func selectCategory(_ filter: ProductCategoryFilter) {
        guard selectedCategory != filter else { return }
        selectedCategory = filter
        onChange?()
    }

    /// 目录中实际出现的类型，按固定顺序展示；只包含有型号的类型。
    var categories: [DeviceCapabilityCategory] {
        let present = Set(allProducts.map(Self.category(of:)))
        return DeviceCapabilityCategory.allCases.filter { present.contains($0) }
    }

    var hasActiveCategory: Bool {
        if case .all = selectedCategory { return false }
        return true
    }

    /// 已按当前类型筛选的产品。
    var products: [ProductModel] {
        switch selectedCategory {
        case .all:
            return allProducts
        case .category(let category):
            return allProducts.filter { Self.category(of: $0) == category }
        }
    }

    var allProducts: [ProductModel] {
        if case .loaded(let products) = state { return products }
        return []
    }

    static func category(of product: ProductModel) -> DeviceCapabilityCategory {
        MarketInsights.profile(from: product).category
    }
}

