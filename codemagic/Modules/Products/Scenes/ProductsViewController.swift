import UIKit

/// 产品模块：型号库（厂商、固件版本、GATT 服务与特征），数据来自网络层。
/// 可按设备类型浏览；类型由 GATT 能力推导，不硬编码型号名单。
final class ProductsViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyStateView = EmptyStateView()
    private let errorStateView = ErrorStateView(height: 240)
    private lazy var skeletonController = SkeletonController(host: view)
    private let categoryBar = ProductCategoryBar()
    private let categoryBarContainer = UIView()
    private let statusFooterView = UIView()
    private let statusLabel = AppTheme.makeLabel(style: .caption1, color: Palette.textTertiary)

    private let viewModel: ProductsViewModel
    private let savedDeviceStore: SavedDeviceStore?

    init(viewModel: ProductsViewModel, savedDeviceStore: SavedDeviceStore? = nil) {
        self.viewModel = viewModel
        self.savedDeviceStore = savedDeviceStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("tab.products")
        view.backgroundColor = AppTheme.Palette.background
        configureCategoryBar()
        configureTableView()
        configureStatusFooter()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.t("market.refresh"),
            style: .plain,
            target: self,
            action: #selector(handleRefresh)
        )

        viewModel.onChange = { [weak self] in
            self?.reloadContent()
        }
        viewModel.loadIfNeeded()
    }

    private func configureCategoryBar() {
        categoryBarContainer.translatesAutoresizingMaskIntoConstraints = false
        categoryBar.translatesAutoresizingMaskIntoConstraints = false
        categoryBarContainer.addSubview(categoryBar)
        view.addSubview(categoryBarContainer)
        NSLayoutConstraint.activate([
            categoryBarContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            categoryBarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            categoryBarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            categoryBarContainer.heightAnchor.constraint(equalToConstant: Layout.space48 + Layout.space12),
            categoryBar.topAnchor.constraint(equalTo: categoryBarContainer.topAnchor),
            categoryBar.leadingAnchor.constraint(equalTo: categoryBarContainer.leadingAnchor),
            categoryBar.trailingAnchor.constraint(equalTo: categoryBarContainer.trailingAnchor),
            categoryBar.bottomAnchor.constraint(equalTo: categoryBarContainer.bottomAnchor),
        ])
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Palette.canvas
        tableView.separatorStyle = .none
        tableView.register(ProductCell.self, forCellReuseIdentifier: ProductCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppTheme.Metrics.estimatedRowHeight
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: categoryBarContainer.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureStatusFooter() {
        statusFooterView.backgroundColor = .clear
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusFooterView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: statusFooterView.topAnchor, constant: Layout.space8),
            statusLabel.leadingAnchor.constraint(equalTo: statusFooterView.leadingAnchor, constant: Layout.pageMargin),
            statusLabel.trailingAnchor.constraint(equalTo: statusFooterView.trailingAnchor, constant: -Layout.pageMargin),
            statusLabel.bottomAnchor.constraint(equalTo: statusFooterView.bottomAnchor, constant: -Layout.space16),
        ])
    }

    private func reloadContent() {
        navigationItem.rightBarButtonItem?.isEnabled = viewModel.state != .loading

        switch viewModel.state {
        case .idle, .loading:
            tableView.backgroundView = nil
            categoryBarContainer.isHidden = true
            // 300ms 后才出现骨架，行高与真实产品行一致（72）。
            skeletonController.begin {
                SkeletonView.list(rows: 6, rowHeight: Layout.row2)
            }

        case .failed(let error):
            skeletonController.end()
            categoryBarContainer.isHidden = true
            errorStateView.configure(
                title: L10n.t("products.loadFailed"),
                message: L10n.f("market.loadFailedDetail", String(describing: error.localizedDescriptionText))
            ) { [weak self] in
                self?.viewModel.reload()
            }
            tableView.backgroundView = errorStateView

        case .loaded(let all) where all.isEmpty:
            skeletonController.end()
            categoryBarContainer.isHidden = true
            emptyStateView.configure(
                symbolName: SymbolName.product,
                title: L10n.t("products.emptyTitle"),
                message: L10n.t("products.emptyMessage"),
                actionTitle: L10n.t("market.refresh"),
                action: { [weak self] in self?.viewModel.reload() }
            )
            tableView.backgroundView = emptyStateView

        case .loaded where viewModel.products.isEmpty:
            skeletonController.end()
            showCategoryBar()
            emptyStateView.configure(
                symbolName: SymbolName.product,
                title: L10n.t("products.filtered.emptyTitle"),
                message: L10n.t("products.filtered.emptyMessage"),
                actionTitle: L10n.t("products.filter.all"),
                action: { [weak self] in
                    self?.viewModel.selectCategory(.all)
                }
            )
            tableView.backgroundView = emptyStateView

        case .loaded:
            skeletonController.end()
            showCategoryBar()
            tableView.backgroundView = nil
        }

        tableView.separatorStyle = viewModel.products.isEmpty ? .none : .singleLine
        tableView.reloadData()
        updateStatusFooter()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyBottomOcclusionInset(to: tableView)
        updateStatusFooter()
    }

    /// 目录更新时间标注放在列表尾部；断网兜底时同一行追加「离线缓存」。
    private func updateStatusFooter() {
        guard let info = viewModel.catalogInfo, !viewModel.products.isEmpty else {
            if tableView.tableFooterView != nil {
                tableView.tableFooterView = nil
            }
            return
        }
        statusLabel.text = info.statusText
        statusLabel.accessibilityLabel = info.statusText
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let size = statusFooterView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        statusFooterView.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        if tableView.tableFooterView !== statusFooterView {
            tableView.tableFooterView = statusFooterView
        }
    }

    private func showCategoryBar() {
        categoryBarContainer.isHidden = viewModel.categories.isEmpty
        categoryBar.configure(
            categories: viewModel.categories,
            selected: viewModel.selectedCategory
        ) { [weak self] filter in
            self?.viewModel.selectCategory(filter)
        }
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
        let product = viewModel.products[indexPath.row]
        cell.configure(product: product, category: ProductsViewModel.category(of: product))
        return cell
    }
}

extension ProductsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let product = viewModel.products[indexPath.row]
        let detail = ProductDetailViewController(
            product: product,
            savedDeviceStore: savedDeviceStore
        )
        navigationController?.pushViewController(detail, animated: true)
    }
}
