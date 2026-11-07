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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory else { return }
        applyHeaderTextStyles()
        updateActionsLayout()
        reload()
        tableView.reloadData()
        sizeHeaderIfNeeded()
    }

    /// 标题类文案随动态字号重算；按钮横排在大字号下改为上下堆叠，避免标题折成两行。
    private func applyHeaderTextStyles() {
        let trait = traitCollection
        summaryLabel.font = AppText.headline.font(compatibleWith: trait)
        summaryLabel.textColor = Palette.textPrimary
        pendingLabel.font = AppText.footnote.font(compatibleWith: trait)
        pendingLabel.textColor = Palette.warning
        noticeLabel.font = AppText.footnote.font(compatibleWith: trait)
        noticeLabel.textColor = Palette.textSecondary
        readOnlyLabel.font = AppText.footnote.font(compatibleWith: trait)
        readOnlyLabel.textColor = Palette.textSecondary
        for label in [summaryLabel, pendingLabel, noticeLabel, readOnlyLabel] {
            label.adjustsFontForContentSizeCategory = true
            // 避免大字号下把“设备”这类两字词拆成单字行。
            label.lineBreakStrategy = .pushOut
        }
    }

    private func updateActionsLayout() {
        actionsRow.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            ? .vertical
            : .horizontal
    }

    /// AX 档使用带显式换行点的本地化文案，避免“设备”“卡片”等词被拆成两行。
    private var usesAccessibilityText: Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Palette.canvas
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = Layout.row3
        view.addSubview(tableView)
        let fillWidth = tableView.widthAnchor.constraint(equalTo: view.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            tableView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tableView.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.contentMaxWidth),
            fillWidth,
        ])

        emptyView.isHidden = true
        tableView.backgroundView = emptyView
    }

    private func configureHeader() {
        summaryLabel.numberOfLines = 0
        pendingLabel.numberOfLines = 0
        pendingLabel.isHidden = true
        noticeLabel.numberOfLines = 0
        noticeLabel.isHidden = true
        readOnlyLabel.numberOfLines = 0
        readOnlyLabel.isHidden = true
        applyHeaderTextStyles()

        markButton.addAction(UIAction { [weak self] _ in self?.viewModel.markAll() }, for: .touchUpInside)
        markButton.accessibilityIdentifier = "roomDetailMarkAll"
        unmarkButton.addAction(UIAction { [weak self] _ in self?.viewModel.unmarkAll() }, for: .touchUpInside)
        unmarkButton.accessibilityIdentifier = "roomDetailUnmarkAll"

        actionsRow.axis = .horizontal
        actionsRow.spacing = Layout.space8
        actionsRow.distribution = .fillEqually
        actionsRow.addArrangedSubview(markButton)
        actionsRow.addArrangedSubview(unmarkButton)
        updateActionsLayout()

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
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            // AX 档每项单独一行，避免“已标记”这类词被拆到两行。
            summaryLabel.text = viewModel.summaryText.replacingOccurrences(of: " · ", with: "\n")
        } else {
            summaryLabel.text = viewModel.summaryText
        }
        summaryLabel.isHidden = viewModel.isEmpty
        pendingLabel.text = viewModel.pendingHint
        pendingLabel.isHidden = viewModel.pendingHint == nil
        noticeLabel.text = viewModel.notice
        noticeLabel.isHidden = viewModel.notice == nil
        readOnlyLabel.text = usesAccessibilityText
            ? L10n.t("room.detail.readonlyNoteAX")
            : viewModel.readOnlyNote
        readOnlyLabel.isHidden = viewModel.readOnlyNote == nil

        actionsRow.isHidden = viewModel.isEmpty
        markButton.isEnabled = viewModel.canMark
        unmarkButton.isEnabled = viewModel.canUnmark

        emptyView.isHidden = !viewModel.isEmpty
        if viewModel.isEmpty {
            emptyView.configure(
                symbolName: "square.stack.3d.up",
                title: L10n.t(usesAccessibilityText ? "room.detail.emptyTitleAX" : "room.detail.emptyTitle"),
                message: L10n.t(usesAccessibilityText ? "room.detail.emptyMessageAX" : "room.detail.emptyMessage"),
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
        let separator = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? "\n" : " · "
        return parts.joined(separator: separator)
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
        content.textProperties.font = AppText.body.font(compatibleWith: traitCollection)
        content.textProperties.color = Palette.textPrimary
        content.textProperties.numberOfLines = 0
        content.secondaryText = metaText(for: entry)
        content.secondaryTextProperties.font = AppText.caption.font(compatibleWith: traitCollection)
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
    var tableViewForTesting: UITableView { tableView }
    var actionsRowForTesting: UIStackView { actionsRow }
    var markButtonForTesting: AppButton { markButton }
    var unmarkButtonForTesting: AppButton { unmarkButton }
    var summaryLabelNumberOfLinesForTesting: Int { summaryLabel.numberOfLines }
    var readOnlyLabelNumberOfLinesForTesting: Int { readOnlyLabel.numberOfLines }
}
