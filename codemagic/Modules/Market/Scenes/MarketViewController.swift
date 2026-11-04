import UIKit

/// 市场模块：配件与固件信息 + 兼容性说明。仅信息展示，不做购物车/订单/支付。
final class MarketViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyStateView = EmptyStateView()
    private let loadingView = LoadingStateView()

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
        tableView.register(MarketItemCell.self, forCellReuseIdentifier: MarketItemCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        tableView.tableFooterView = makeFootnoteView()
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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

        switch viewModel.state {
        case .idle, .loading:
            loadingView.configure(message: "正在拉取配件与固件信息…")
            tableView.backgroundView = loadingView

        case .failed(let error):
            emptyStateView.configure(
                symbolName: SymbolName.warning,
                title: "市场数据加载失败",
                message: "\(error.localizedDescriptionText)。请检查网络或 BASE_URL 配置。",
                actionTitle: "重试",
                action: { [weak self] in self?.viewModel.reload() }
            )
            tableView.backgroundView = emptyStateView

        case .loaded(let items) where items.isEmpty:
            emptyStateView.configure(
                symbolName: SymbolName.marketTab,
                title: "暂无市场信息",
                message: "服务端返回了空列表，新增配件或固件后会显示在这里。",
                actionTitle: "刷新",
                action: { [weak self] in self?.viewModel.reload() }
            )
            tableView.backgroundView = emptyStateView

        case .loaded:
            tableView.backgroundView = nil
        }

        tableView.reloadData()
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
