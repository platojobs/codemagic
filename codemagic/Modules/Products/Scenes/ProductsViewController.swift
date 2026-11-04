import UIKit

/// 产品模块：型号库（厂商、固件版本、GATT 服务与特征），数据来自网络层。
final class ProductsViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyStateView = EmptyStateView()
    private let loadingView = LoadingStateView()

    private let viewModel: ProductsViewModel

    init(viewModel: ProductsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "产品"
        view.backgroundColor = AppTheme.Palette.background
        configureTableView()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "刷新",
            style: .plain,
            target: self,
            action: #selector(handleRefresh)
        )

        viewModel.onChange = { [weak self] in
            self?.reloadContent()
        }
        viewModel.loadIfNeeded()
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(ProductCell.self, forCellReuseIdentifier: ProductCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppTheme.Metrics.estimatedRowHeight
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func reloadContent() {
        navigationItem.rightBarButtonItem?.isEnabled = viewModel.state != .loading

        switch viewModel.state {
        case .idle, .loading:
            loadingView.configure(message: "正在拉取产品型号…")
            tableView.backgroundView = loadingView

        case .failed(let error):
            emptyStateView.configure(
                symbolName: SymbolName.warning,
                title: "产品数据加载失败",
                message: "\(error.localizedDescriptionText)。Debug 请先启动本地 Go 服务，或检查 BASE_URL 配置。",
                actionTitle: "重试",
                action: { [weak self] in self?.viewModel.reload() }
            )
            tableView.backgroundView = emptyStateView

        case .loaded(let products) where products.isEmpty:
            emptyStateView.configure(
                symbolName: SymbolName.product,
                title: "暂无产品型号",
                message: "服务端返回了空列表，新增型号后会显示在这里。",
                actionTitle: "刷新",
                action: { [weak self] in self?.viewModel.reload() }
            )
            tableView.backgroundView = emptyStateView

        case .loaded:
            tableView.backgroundView = nil
        }

        tableView.separatorStyle = viewModel.products.isEmpty ? .none : .singleLine
        tableView.reloadData()
    }

    @objc private func handleRefresh() {
        viewModel.reload()
    }
}

extension ProductsViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.products.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ProductCell.reuseIdentifier,
            for: indexPath
        ) as? ProductCell else {
            return UITableViewCell()
        }
        cell.configure(product: viewModel.products[indexPath.row])
        return cell
    }
}

extension ProductsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let product = viewModel.products[indexPath.row]
        let detail = ProductDetailViewController(product: product)
        navigationController?.pushViewController(detail, animated: true)
    }
}
