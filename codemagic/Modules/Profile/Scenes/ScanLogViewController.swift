import UIKit

/// 本地扫描日志列表：扫描会话、设备保存与规则触发记录。
final class ScanLogViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyStateView = EmptyStateView()

    private let scanLogStore: ScanLogStore
    private var entries: [ScanLogEntry] = []

    init(scanLogStore: ScanLogStore) {
        self.scanLogStore = scanLogStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("profile.scanLogTitle")
        view.backgroundColor = AppTheme.Palette.background
        configureTableView()
        reload()
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ScanLogCell")
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func reload() {
        entries = (try? scanLogStore.fetchRecent(limit: 200)) ?? []

        if entries.isEmpty {
            emptyStateView.configure(
                symbolName: SymbolName.log,
                title: L10n.t("profile.scanLogEmpty"),
                message: L10n.t("profile.scanLogEmptyMessage")
            )
            tableView.backgroundView = emptyStateView
            tableView.separatorStyle = .none
        } else {
            tableView.backgroundView = nil
            tableView.separatorStyle = .singleLine
        }
        tableView.reloadData()
    }
}

extension ScanLogViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ScanLogCell", for: indexPath)
        let entry = entries[indexPath.row]

        var configuration = cell.defaultContentConfiguration()
        configuration.text = entry.message
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryText = "\(entry.category.title) · \(AppDateFormat.absolute(entry.occurredAt))"
        configuration.secondaryTextProperties.color = entry.level == .warning
            ? AppTheme.Palette.highlight
            : AppTheme.Palette.secondaryText
        cell.contentConfiguration = configuration
        cell.selectionStyle = .none
        return cell
    }
}
