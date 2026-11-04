import Foundation

/// 市场视图模型：配件与固件信息，只读展示，无购物车/订单/支付。
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
                self.state = .loaded(items)
            case .failure(let error):
                self.state = .failed(error)
            }
        }
    }

    var items: [MarketItem] {
        if case .loaded(let items) = state { return items }
        return []
    }
}
