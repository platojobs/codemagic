import UIKit

/// 我的反馈：`GET /feedback/mine` 的只读列表，支持下拉刷新与游标加载更多。
/// 响应不含联系方式与诊断信息，界面只展示状态与时间。
final class MyFeedbackViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyStateView = EmptyStateView()
    private let errorStateView = ErrorStateView(height: 240)
    private let refreshControl = UIRefreshControl()
    private let coordinator: FeedbackCoordinator

    private var items: [FeedbackRemoteItem] = []
    private var nextCursor: String?
    private var hasMore = false
    private var isLoading = false
    private var hasLoadedOnce = false
    private var loadError: AppError?

    init(coordinator: FeedbackCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("feedback.mine.title")
        view.backgroundColor = Palette.canvas
        configureTableView()
        reload(reset: true)
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Palette.canvas
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "MyFeedbackCell")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = Layout.row2
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func handleRefresh() {
        reload(reset: true)
    }

    private func reload(reset: Bool) {
        guard !isLoading else { return }
        isLoading = true
        if reset {
            nextCursor = nil
            hasMore = false
        }
        coordinator.fetchMine(
            cursor: reset ? nil : nextCursor,
            limit: FeedbackAPIClient.defaultPageSize
        ) { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            self.hasLoadedOnce = true
            self.refreshControl.endRefreshing()
            switch result {
            case .success(let page):
                if reset {
                    self.items = page.items
                } else {
                    let existing = Set(self.items.map(\.feedbackID))
                    self.items.append(contentsOf: page.items.filter { !existing.contains($0.feedbackID) })
                }
                self.nextCursor = page.nextCursor
                self.hasMore = page.hasMore && page.nextCursor != nil
                self.loadError = nil
            case .failure(let error):
                self.loadError = error
                if reset {
                    self.items = []
                }
                self.hasMore = false
            }
            self.updateBackground()
            self.tableView.reloadData()
        }
    }

    private func updateBackground() {
        if let loadError {
            errorStateView.configure(
                title: L10n.t("feedback.mine.loadFailed"),
                message: loadError.localizedDescriptionText
            ) { [weak self] in
                self?.reload(reset: true)
            }
            tableView.backgroundView = errorStateView
            tableView.separatorStyle = .none
            return
        }
        if items.isEmpty, hasLoadedOnce {
            emptyStateView.configure(
                symbolName: SymbolName.help,
                title: L10n.t("feedback.mine.emptyTitle"),
                message: L10n.t("feedback.mine.emptyMessage"),
                actionTitle: L10n.t("market.refresh"),
                action: { [weak self] in self?.reload(reset: true) }
            )
            tableView.backgroundView = emptyStateView
            tableView.separatorStyle = .none
            return
        }
        tableView.backgroundView = nil
        tableView.separatorStyle = .singleLine
    }
}

extension MyFeedbackViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MyFeedbackCell", for: indexPath)
        guard items.indices.contains(indexPath.row) else { return cell }
        let item = items[indexPath.row]
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = item.body
        configuration.textProperties.font = AppText.callout.font()
        configuration.textProperties.color = Palette.textPrimary
        configuration.textProperties.numberOfLines = 3

        let timeText = item.createdAt.map(Self.dateFormatter.string(from:)) ?? L10n.t("common.unknown")
        configuration.secondaryText = "\(item.status.title) · \(timeText)"
        configuration.secondaryTextProperties.font = AppText.caption.font()
        configuration.secondaryTextProperties.color = Palette.textSecondary
        cell.contentConfiguration = configuration
        cell.selectionStyle = .default
        cell.backgroundColor = Palette.surface
        cell.accessibilityLabel = [
            item.body,
            item.status.title,
            timeText,
        ].joined(separator: L10n.t("common.a11ySeparator"))
        return cell
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

extension MyFeedbackViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard items.indices.contains(indexPath.row) else { return }
        let detail = FeedbackDetailViewController(
            coordinator: coordinator,
            feedbackID: items[indexPath.row].feedbackID
        )
        navigationController?.pushViewController(detail, animated: true)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard hasMore, !isLoading, indexPath.row >= items.count - 2 else { return }
        reload(reset: false)
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if isLoading {
            return L10n.t("feedback.mine.loadingMore")
        }
        return nil
    }
}
