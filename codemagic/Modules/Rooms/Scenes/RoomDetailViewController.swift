import UIKit

/// 房间详情：聚合本机 / 同步落地的同一份设备数据，展示总数、在线 / 离线、已标记，
/// 支持批量标记 / 取消标记（先写本机 pending，再走 push），并保留真实空态。
final class RoomDetailViewController: UIViewController {
    private let viewModel: RoomDetailViewModel
    private let onSelectDevice: (SavedDevice) -> Void
    private let onScan: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyView = EmptyStateView()
    private let headerView = UIView()
    private let headerStack = UIStackView()
    private let summaryLabel = UILabel()
    private let pendingLabel = UILabel()
    private let noticeLabel = UILabel()
    private let readOnlyLabel = UILabel()
    private let markButton = AppButton(style: .secondary, title: L10n.t("room.detail.mark"))
    private let unmarkButton = AppButton(style: .secondary, title: L10n.t("room.detail.unmark"))
    private let actionsRow = UIStackView()

    init(
        viewModel: RoomDetailViewModel,
        onSelectDevice: @escaping (SavedDevice) -> Void,
        onScan: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onSelectDevice = onSelectDevice
        self.onScan = onScan
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = viewModel.room.name
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Palette.canvas

        configureTable()
        configureHeader()

        viewModel.onChange = { [weak self] in self?.reload() }
        viewModel.reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyBottomOcclusionInset(to: tableView)
        sizeHeaderIfNeeded()
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Palette.canvas
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        emptyView.isHidden = true
        tableView.backgroundView = emptyView
    }

    private func configureHeader() {
        summaryLabel.apply(.headline, color: Palette.textPrimary)
        summaryLabel.numberOfLines = 0

        pendingLabel.apply(.footnote, color: Palette.warning)
        pendingLabel.numberOfLines = 0
        pendingLabel.isHidden = true

        noticeLabel.apply(.footnote, color: Palette.textSecondary)
        noticeLabel.numberOfLines = 0
        noticeLabel.isHidden = true

        readOnlyLabel.apply(.footnote, color: Palette.textSecondary)
        readOnlyLabel.numberOfLines = 0
        readOnlyLabel.isHidden = true

        markButton.addAction(UIAction { [weak self] _ in self?.viewModel.markAll() }, for: .touchUpInside)
        markButton.accessibilityIdentifier = "roomDetailMarkAll"
        unmarkButton.addAction(UIAction { [weak self] _ in self?.viewModel.unmarkAll() }, for: .touchUpInside)
        unmarkButton.accessibilityIdentifier = "roomDetailUnmarkAll"

        actionsRow.axis = .horizontal
        actionsRow.spacing = Layout.space8
        actionsRow.distribution = .fillEqually
        actionsRow.addArrangedSubview(markButton)
        actionsRow.addArrangedSubview(unmarkButton)

        headerStack.axis = .vertical
        headerStack.spacing = Layout.space8
        headerStack.addArrangedSubview(summaryLabel)
        headerStack.addArrangedSubview(pendingLabel)
        headerStack.addArrangedSubview(noticeLabel)
        headerStack.addArrangedSubview(readOnlyLabel)
        headerStack.addArrangedSubview(actionsRow)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor, constant: Layout.space8),
            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: Layout.pageMargin),
            headerStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -Layout.pageMargin),
            headerStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -Layout.space8),
        ])
        tableView.tableHeaderView = headerView
    }

    private func reload() {
        title = viewModel.room.name
        summaryLabel.text = viewModel.summaryText
        pendingLabel.text = viewModel.pendingHint
        pendingLabel.isHidden = viewModel.pendingHint == nil
        noticeLabel.text = viewModel.notice
        noticeLabel.isHidden = viewModel.notice == nil
        readOnlyLabel.text = viewModel.readOnlyNote
        readOnlyLabel.isHidden = viewModel.readOnlyNote == nil

        actionsRow.isHidden = viewModel.isEmpty
        markButton.isEnabled = viewModel.canMark
        unmarkButton.isEnabled = viewModel.canUnmark

        emptyView.isHidden = !viewModel.isEmpty
        if viewModel.isEmpty {
            emptyView.configure(
                symbolName: "square.stack.3d.up",
                title: L10n.t("room.detail.emptyTitle"),
                message: L10n.t("room.detail.emptyMessage"),
                actionTitle: onScan == nil ? nil : L10n.t("room.detail.scan")
            ) { [weak self] in
                self?.onScan?()
            }
        }

        tableView.reloadData()
        sizeHeaderIfNeeded()
    }

    private func sizeHeaderIfNeeded() {
        guard let header = tableView.tableHeaderView else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let target = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if abs(header.frame.height - target.height) > 0.5 {
            header.frame.size.height = target.height
            tableView.tableHeaderView = header
        }
    }

    private func metaText(for entry: RoomDetailEntry) -> String {
        var parts = [entry.isOnline ? L10n.t("room.detail.online") : L10n.t("room.detail.offline")]
        if let remoteOnly = entry.device.connectUnavailableText {
            parts.append(remoteOnly)
        }
        parts.append(entry.readingText)
        if let markText = entry.markText {
            parts.append(markText)
        }
        return parts.joined(separator: " · ")
    }
}

extension RoomDetailViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.entries.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !viewModel.isEmpty else { return nil }
        return L10n.f("room.detail.devices", String(viewModel.totalCount))
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RoomDeviceCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "RoomDeviceCell")
        let entry = viewModel.entries[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.device.displayName
        content.textProperties.font = AppText.body.font()
        content.textProperties.color = Palette.textPrimary
        content.secondaryText = metaText(for: entry)
        content.secondaryTextProperties.font = AppText.caption.font()
        content.secondaryTextProperties.color = entry.isOnline ? Palette.success : Palette.textSecondary
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.backgroundColor = Palette.surface
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelectDevice(viewModel.entries[indexPath.row].device)
    }
}

// MARK: - 测试访问

extension RoomDetailViewController {
    /// 测试与截图核对入口：暴露批量按钮的实际可用状态，避免「点了没反应」。
    var markButtonIsEnabled: Bool { markButton.isEnabled }
    var unmarkButtonIsEnabled: Bool { unmarkButton.isEnabled }
    var summaryTextForTesting: String { summaryLabel.text ?? "" }
    var pendingTextForTesting: String? { pendingLabel.isHidden ? nil : pendingLabel.text }
    var readOnlyTextForTesting: String? { readOnlyLabel.isHidden ? nil : readOnlyLabel.text }
}
