import Foundation

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
        productService.fetchProducts { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let products):
                self.state = .loaded(products)
            case .failure(let error):
                self.state = .failed(error)
            }
        }
    }

    var products: [ProductModel] {
        if case .loaded(let products) = state { return products }
        return []
    }
}
