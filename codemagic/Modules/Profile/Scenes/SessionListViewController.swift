import UIKit

/// 登录会话管理：列出全部会话、标出当前会话、可单独吊销其他会话。
///
/// 注意：吊销「当前会话」与「退出当前会话」等价，这里禁止从行内直接吊销当前会话，
/// 以免用户在不知情的情况下把本机登出；请回到「我的」页使用「退出当前会话」。
final class SessionListViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let viewModel: SessionListViewModel
    private let refreshControl = UIRefreshControl()

    init(viewModel: SessionListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("session.title")
        view.backgroundColor = Palette.canvas
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = Layout.buttonH
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SessionCell")
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        viewModel.onChange = { [weak self] in
            guard let self else { return }
            self.refreshControl.endRefreshing()
            self.tableView.reloadData()
        }
        viewModel.activate()
    }

    @objc private func handleRefresh() {
        viewModel.load()
    }

    private func revoke(at index: Int) {
        viewModel.revoke(at: index) { [weak self] errorMessage in
            guard let self, let errorMessage else { return }
            let alert = UIAlertController(
                title: L10n.t("session.revokeFailed"),
                message: errorMessage,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.t("common.ok"), style: .cancel))
            self.present(alert, animated: true)
        }
    }
}

extension SessionListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.sessions.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        L10n.t("session.title")
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let errorMessage = viewModel.errorMessage { return errorMessage }
        if viewModel.sessions.isEmpty {
            return viewModel.isLoading ? L10n.t("common.loading") : viewModel.emptyText
        }
        return L10n.t("session.footnote")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SessionCell", for: indexPath)
        let session = viewModel.sessions[indexPath.row]
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = session.isCurrent
            ? L10n.t("session.current")
            : L10n.f("session.other", String(session.id.prefix(8)))
        configuration.secondaryText = L10n.f(
            "session.meta",
            viewModel.createdAtText(for: session),
            viewModel.expiresAtText(for: session)
        )
        configuration.secondaryTextProperties.font = AppText.caption.font()
        configuration.secondaryTextProperties.color = Palette.textSecondary
        configuration.textProperties.font = AppText.body.font()
        configuration.textProperties.color = Palette.primaryText
        configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Layout.space16,
            leading: Layout.pageMargin,
            bottom: Layout.space16,
            trailing: Layout.pageMargin
        )
        cell.contentConfiguration = configuration
        cell.selectionStyle = .none
        cell.backgroundColor = Palette.surface
        cell.accessibilityLabel = session.isCurrent
            ? L10n.t("session.currentAccessibility")
            : L10n.f("session.otherAccessibility", String(session.id.prefix(8)))
        cell.accessibilityTraits = .staticText
        return cell
    }
}

extension SessionListViewController: UITableViewDelegate {
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let session = viewModel.sessions[indexPath.row]
        guard !session.isCurrent else { return nil }
        let action = UIContextualAction(style: .destructive, title: L10n.t("session.revoke")) { [weak self] _, _, done in
            guard let self else { return done(false) }
            self.revoke(at: indexPath.row)
            done(true)
        }
        action.accessibilityLabel = L10n.t("session.revokeAccessibility")
        return UISwipeActionsConfiguration(actions: [action])
    }
}
