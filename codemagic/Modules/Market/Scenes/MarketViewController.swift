import UIKit

/// 市场模块：配件与固件信息 + 兼容性说明。仅信息展示，不做购物车/订单/支付。
final class MarketViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyStateView = EmptyStateView()
    private let errorStateView = ErrorStateView(height: 240)
    private lazy var skeletonController = SkeletonController(host: view)
    private let filterBar = UIStackView()
    private let vendorButton = UIButton(type: .system)
    private let compatibilityButton = UIButton(type: .system)
    private let resetFilterButton = UIButton(type: .system)

    private let viewModel: MarketViewModel

    init(viewModel: MarketViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "市场"
        view.backgroundColor = AppTheme.Palette.background
        configureFilterBar()
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

    private func configureFilterBar() {
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.axis = .horizontal
        filterBar.spacing = 8
        filterBar.alignment = .center
        filterBar.isLayoutMarginsRelativeArrangement = true
        filterBar.layoutMargins = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)

        var vendorConfig = UIButton.Configuration.gray()
        vendorConfig.cornerStyle = .capsule
        vendorConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        vendorButton.configuration = vendorConfig
        vendorButton.titleLabel?.font = AppText.callout.font()
        vendorButton.addTarget(self, action: #selector(handleVendorFilter), for: .touchUpInside)

        var compatibilityConfig = UIButton.Configuration.gray()
        compatibilityConfig.cornerStyle = .capsule
        compatibilityConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        compatibilityButton.configuration = compatibilityConfig
        compatibilityButton.titleLabel?.font = AppText.callout.font()
        compatibilityButton.addTarget(
            self,
            action: #selector(handleCompatibilityFilter),
            for: .touchUpInside
        )

        resetFilterButton.setTitle("清除", for: .normal)
        resetFilterButton.titleLabel?.font = AppText.callout.font()
        resetFilterButton.addTarget(self, action: #selector(handleResetFilters), for: .touchUpInside)

        filterBar.addArrangedSubview(vendorButton)
        filterBar.addArrangedSubview(compatibilityButton)
        filterBar.addArrangedSubview(resetFilterButton)
        filterBar.addArrangedSubview(UIView())
        view.addSubview(filterBar)

        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Palette.canvas
        tableView.separatorStyle = .none
        tableView.register(MarketItemCell.self, forCellReuseIdentifier: MarketItemCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        tableView.tableFooterView = makeFootnoteView()
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// 页脚说明：明确本页不提供交易能力，避免误以为是商城。
    private func makeFootnoteView() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 64))
        let label = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.tertiaryText)
        label.text = "以上仅展示配件与固件信息及兼容性，不提供下单、订单或支付功能。"
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    private func reloadContent() {
        navigationItem.rightBarButtonItem?.isEnabled = viewModel.state != .loading
        updateFilterBar()

        switch viewModel.state {
        case .idle, .loading:
            tableView.backgroundView = nil
            skeletonController.begin {
                SkeletonView.list(rows: 5, rowHeight: 100)
            }

        case .failed(let error):
            skeletonController.end()
            errorStateView.configure(
                title: "市场数据加载失败",
                message: "\(error.localizedDescriptionText)。请检查网络或 BASE_URL 配置。"
            ) { [weak self] in
                self?.viewModel.reload()
            }
            tableView.backgroundView = errorStateView

        case .loaded(_) where viewModel.items.isEmpty && viewModel.hasActiveFilter:
            skeletonController.end()
            emptyStateView.configure(
                symbolName: SymbolName.marketTab,
                title: "没有符合筛选条件的条目",
                message: "当前筛选：\(filterSummary)。调整厂商或兼容性筛选，或清除筛选。",
                actionTitle: "清除筛选",
                action: { [weak self] in self?.viewModel.resetFilters() }
            )
            tableView.backgroundView = emptyStateView

        case .loaded(_) where viewModel.items.isEmpty:
            skeletonController.end()
            emptyStateView.configure(
                symbolName: SymbolName.marketTab,
                title: "暂无市场信息",
                message: "服务端返回了空列表，新增配件或固件后会显示在这里。",
                actionTitle: "刷新",
                action: { [weak self] in self?.viewModel.reload() }
            )
            tableView.backgroundView = emptyStateView

        case .loaded:
            skeletonController.end()
            tableView.backgroundView = nil
        }

        tableView.reloadData()
    }

    private func updateFilterBar() {
        let hasData = !viewModel.allItems.isEmpty
        vendorButton.isEnabled = hasData
        compatibilityButton.isEnabled = hasData
        resetFilterButton.isHidden = !viewModel.hasActiveFilter

        vendorButton.configuration?.title = viewModel.selectedVendor.map { "厂商：\($0)" } ?? "厂商：全部"
        compatibilityButton.configuration?.title = viewModel.selectedCompatibility.map {
            "兼容性：\($0)"
        } ?? "兼容性：全部"
    }

    private var filterSummary: String {
        [
            viewModel.selectedVendor.map { "厂商 \($0)" },
            viewModel.selectedCompatibility.map { "兼容性 \($0)" },
        ].compactMap { $0 }.joined(separator: "，")
    }

    // MARK: - Actions

    @objc private func handleVendorFilter() {
        presentFilterSheet(
            title: "按厂商筛选",
            options: viewModel.vendors,
            selected: viewModel.selectedVendor,
            sourceView: vendorButton
        ) { [weak self] value in
            self?.viewModel.selectVendor(value)
        }
    }

    @objc private func handleCompatibilityFilter() {
        presentFilterSheet(
            title: "按兼容性筛选",
            options: viewModel.compatibilityOptions,
            selected: viewModel.selectedCompatibility,
            sourceView: compatibilityButton
        ) { [weak self] value in
            self?.viewModel.selectCompatibility(value)
        }
    }

    @objc private func handleResetFilters() {
        viewModel.resetFilters()
    }

    /// 选项来自服务端真实字段值；`nil` 表示「全部」。
    private func presentFilterSheet(
        title: String,
        options: [String],
        selected: String?,
        sourceView: UIView,
        onSelect: @escaping (String?) -> Void
    ) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "全部", style: .default) { _ in onSelect(nil) })
        for option in options {
            let actionTitle = option == selected ? "✓ \(option)" : option
            sheet.addAction(UIAlertAction(title: actionTitle, style: .default) { _ in onSelect(option) })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView
        sheet.popoverPresentationController?.sourceRect = sourceView.bounds
        present(sheet, animated: true)
    }

    @objc private func handleRefresh() {
        viewModel.reload()
    }
}

extension MarketViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: MarketItemCell.reuseIdentifier,
            for: indexPath
        ) as? MarketItemCell else {
            return UITableViewCell()
        }
        cell.configure(item: viewModel.items[indexPath.row])
        return cell
    }
}
