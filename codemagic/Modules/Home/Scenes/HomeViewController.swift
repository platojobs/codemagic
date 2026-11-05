import UIKit

/// 首页：真实蓝牙扫描入口、最近设备列表与规则提醒。
final class HomeViewController: UIViewController {
    // MARK: - Subviews

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyStateView = EmptyStateView()
    private let headerView = UIView()
    private let statusLabel = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.secondaryText)
    private let noticeLabel = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.highlight)
    private let scanButton = UIBarButtonItem()

    // MARK: - Dependencies

    private let viewModel: HomeViewModel

    // MARK: - Init

    init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("tab.home")
        view.backgroundColor = AppTheme.Palette.background
        configureTableView()
        configureHeader()
        configureNavigationItems()

        viewModel.onChange = { [weak self] in
            self?.reloadContent()
        }

        reloadContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.activate()
        reloadContent()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        viewModel.deactivate()
    }

    // MARK: - Configuration

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(ScannedDeviceCell.self, forCellReuseIdentifier: ScannedDeviceCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppTheme.Metrics.estimatedRowHeight
        tableView.backgroundColor = AppTheme.Palette.background
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: AppTheme.Metrics.contentMargins,
            bottom: 0,
            right: 0
        )
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureHeader() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.numberOfLines = 0
        headerView.addSubview(statusLabel)
        headerView.addSubview(noticeLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: AppTheme.Spacing.medium),
            statusLabel.leadingAnchor.constraint(
                equalTo: headerView.leadingAnchor,
                constant: AppTheme.Metrics.contentMargins
            ),
            statusLabel.trailingAnchor.constraint(
                equalTo: headerView.trailingAnchor,
                constant: -AppTheme.Metrics.contentMargins
            ),

            noticeLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: AppTheme.Spacing.small),
            noticeLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            noticeLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            noticeLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -AppTheme.Spacing.small),
        ])
        tableView.tableHeaderView = headerView
    }

    private func configureNavigationItems() {
        scanButton.target = self
        scanButton.action = #selector(handleScanButton)
        navigationItem.rightBarButtonItem = scanButton
    }

    // MARK: - Content

    private func reloadContent() {
        scanButton.title = viewModel.scanActionTitle
        statusLabel.text = viewModel.statusText
        noticeLabel.text = viewModel.lastRuleEvent?.message
        noticeLabel.isHidden = viewModel.lastRuleEvent == nil
        updateHeaderHeight()
        updateEmptyState()
        tableView.reloadData()
    }

    private func updateHeaderHeight() {
        let width = max(tableView.bounds.width, view.bounds.width)
        guard width > 0 else { return }
        headerView.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let size = headerView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        headerView.frame.size.height = size.height
        tableView.tableHeaderView = headerView
    }

    private func updateEmptyState() {
        guard viewModel.rows.isEmpty else {
            tableView.backgroundView = nil
            tableView.separatorStyle = .singleLine
            return
        }

        let state = viewModel.emptyState
        let allowsAction = state.actionTitle != nil
        emptyStateView.configure(
            symbolName: state.symbol,
            title: state.title,
            message: state.message,
            actionTitle: state.actionTitle,
            action: allowsAction ? { [weak self] in self?.viewModel.startScan() } : nil
        )
        tableView.backgroundView = emptyStateView
        tableView.separatorStyle = .none
    }

    // MARK: - Actions

    @objc private func handleScanButton() {
        viewModel.toggleScan()
    }
}

// MARK: - UITableViewDataSource

extension HomeViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ScannedDeviceCell.reuseIdentifier,
            for: indexPath
        ) as? ScannedDeviceCell else {
            return UITableViewCell()
        }
        let row = viewModel.rows[indexPath.row]
        cell.configure(row: row) { [weak self] in
            self?.viewModel.saveDevice(row)
        }
        return cell
    }
}

// MARK: - UITableViewDelegate

extension HomeViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = viewModel.rows[indexPath.row]
        if row.isSaved {
            presentAlert(title: L10n.t("home.savedTitle"), message: L10n.t("home.savedMessage"))
        } else {
            viewModel.saveDevice(row)
            presentAlert(title: L10n.t("common.saved"), message: L10n.t("home.savedMessage2"))
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.t("common.gotIt"), style: .default))
        present(alert, animated: true)
    }
}
