import UIKit

/// 市场 Tab：设备与服务市场。四块内容全部由真实数据/能力推导驱动：
/// 1. 兼容性查询：选设备类型 → 可解析指标 / 所需 GATT 服务 / 已知限制。
///    唯一真值是 `ReadingCharacteristic` UUID 表与型号 GATT 服务，不新增型号能力表。
/// 2. 选购指南：按场景说明该选什么类型，依据是能力而不是营销话术。
/// 3. 服务入口：配对向导 / 连接排障 / 采集省电建议，直达真实页面或帮助条目。
/// 4. 示例条目：默认隐藏；开启后明确标注「示例数据，不代表真实在售」，不展示价格与库存。
final class MarketViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case typePicker
        case compatibility
        case guide
        case services
        case sample
    }

    private enum ServiceEntry: Int, CaseIterable {
        case pairing
        case troubleshooting
        case powerSaving

        var title: String {
            switch self {
            case .pairing: return L10n.t("market.service.pairing")
            case .troubleshooting: return L10n.t("market.service.troubleshooting")
            case .powerSaving: return L10n.t("market.service.powerSaving")
            }
        }

        var subtitle: String {
            switch self {
            case .pairing: return L10n.t("market.service.pairingDetail")
            case .troubleshooting: return L10n.t("market.service.troubleshootingDetail")
            case .powerSaving: return L10n.t("market.service.powerSavingDetail")
            }
        }

        var symbolName: String {
            switch self {
            case .pairing: return SymbolName.bluetooth
            case .troubleshooting: return SymbolName.warning
            case .powerSaving: return SymbolName.rule
            }
        }
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyStateView = EmptyStateView()
    private let errorStateView = ErrorStateView(height: 240)
    private lazy var skeletonController = SkeletonController(host: view)

    private let viewModel: MarketViewModel

    init(viewModel: MarketViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyBottomOcclusionInset(to: tableView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("tab.market")
        view.backgroundColor = Palette.canvas
        configureTableView()
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

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Palette.canvas
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.register(MarketTypeCell.self, forCellReuseIdentifier: MarketTypeCell.reuseIdentifier)
        tableView.register(MarketInfoCell.self, forCellReuseIdentifier: MarketInfoCell.reuseIdentifier)
        tableView.register(MarketScenarioCell.self, forCellReuseIdentifier: MarketScenarioCell.reuseIdentifier)
        tableView.register(MarketLinkCell.self, forCellReuseIdentifier: MarketLinkCell.reuseIdentifier)
        tableView.register(MarketFilterCell.self, forCellReuseIdentifier: MarketFilterCell.reuseIdentifier)
        tableView.register(MarketItemCell.self, forCellReuseIdentifier: MarketItemCell.reuseIdentifier)
        tableView.register(SwitchCell.self, forCellReuseIdentifier: SwitchCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = Layout.row2
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
            tableView.backgroundView = nil
            skeletonController.begin {
                SkeletonView.list(rows: 5, rowHeight: Layout.row2)
            }

        case .failed(let error):
            skeletonController.end()
            errorStateView.configure(
                title: L10n.t("market.loadFailed"),
                message: L10n.f("market.loadFailedDetail", String(describing: error.localizedDescriptionText))
            ) { [weak self] in
                self?.viewModel.reload()
            }
            tableView.backgroundView = errorStateView

        case .loaded where !viewModel.hasContent:
            skeletonController.end()
            emptyStateView.configure(
                symbolName: SymbolName.marketTab,
                title: L10n.t("market.emptyTitle"),
                message: L10n.t("market.emptyMessage"),
                actionTitle: L10n.t("market.refresh"),
                action: { [weak self] in self?.viewModel.reload() }
            )
            tableView.backgroundView = emptyStateView

        case .loaded:
            skeletonController.end()
            tableView.backgroundView = nil
        }

        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func handleRefresh() {
        viewModel.reload()
    }
}

// MARK: - UITableViewDataSource

extension MarketViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        guard case .loaded = viewModel.state, viewModel.hasContent else { return 0 }
        return Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let sectionKind = Section(rawValue: section) else { return 0 }
        switch sectionKind {
        case .typePicker:
            return viewModel.profiles.isEmpty ? 0 : 1
        case .compatibility:
            return viewModel.selectedProfile == nil ? 0 : 1
        case .guide:
            return viewModel.recommendations.count
        case .services:
            return ServiceEntry.allCases.count
        case .sample:
            return sampleRowCount
        }
    }

    private var sampleRowCount: Int {
        var rows = 1
        guard viewModel.showSampleItems else { return rows }
        if !viewModel.sampleItems.isEmpty {
            rows += 1
        }
        rows += max(1, viewModel.items.count)
        return rows
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionKind = Section(rawValue: section) else { return nil }
        switch sectionKind {
        case .typePicker:
            return L10n.t("market.section.compatibility")
        case .guide:
            return L10n.t("market.section.guide")
        case .services:
            return L10n.t("market.section.services")
        case .sample:
            return L10n.t("market.section.sample")
        case .compatibility:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionKind = Section(rawValue: section) else { return nil }
        switch sectionKind {
        case .typePicker where !viewModel.profiles.isEmpty:
            var parts = [L10n.t("market.compatibility.hint")]
            if let info = viewModel.catalogInfo {
                parts.append(info.statusText)
            }
            if let error = viewModel.refreshError {
                parts.append(L10n.f("catalog.refreshFailed", error.message))
            }
            return parts.joined(separator: "\n")
        case .sample:
            if let error = viewModel.marketItemsError {
                return L10n.f(
                    "market.sample.loadFailedDetail",
                    String(describing: error.localizedDescriptionText)
                )
            }
            return L10n.t("market.sample.disclaimer")
        case .services:
            return L10n.t("market.services.footer")
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let sectionKind = Section(rawValue: indexPath.section) else { return UITableViewCell() }
        switch sectionKind {
        case .typePicker:
            return makeTypeCell()

        case .compatibility:
            guard let profile = viewModel.selectedProfile else { return UITableViewCell() }
            return makeCompatibilityCell(for: profile)

        case .guide:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: MarketScenarioCell.reuseIdentifier,
                for: indexPath
            ) as? MarketScenarioCell else {
                return UITableViewCell()
            }
            cell.configure(recommendation: viewModel.recommendations[indexPath.row])
            return cell

        case .services:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: MarketLinkCell.reuseIdentifier,
                for: indexPath
            ) as? MarketLinkCell else {
                return UITableViewCell()
            }
            let entry = ServiceEntry.allCases[indexPath.row]
            cell.configure(symbolName: entry.symbolName, title: entry.title, subtitle: entry.subtitle)
            return cell

        case .sample:
            return makeSampleCell(at: indexPath)
        }
    }

    private func makeTypeCell() -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: MarketTypeCell.reuseIdentifier
        ) as? MarketTypeCell else {
            return UITableViewCell()
        }
        cell.configure(
            profiles: viewModel.profiles,
            selectedID: viewModel.selectedProfile?.id,
            onChange: { [weak self] id in
                self?.viewModel.selectType(id)
            }
        )
        return cell
    }

    private func makeCompatibilityCell(for profile: DeviceCompatibilityProfile) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: MarketInfoCell.reuseIdentifier
        ) as? MarketInfoCell else {
            return UITableViewCell()
        }
        var parts: [String] = []
        parts.append(L10n.f("market.compatibility.vendorLine", profile.vendorText, profile.category.title))
        parts.append(L10n.f("market.compatibility.metrics", profile.metricsText))
        parts.append(L10n.f("market.compatibility.services", profile.servicesText))
        parts.append(L10n.f("market.compatibility.firmware", profile.firmwareText))
        parts.append(
            L10n.f(
                "market.compatibility.limitations",
                profile.declaredLimitations == nil && profile.limitations.isEmpty
                    ? L10n.t("common.none")
                    : profile.limitationsText
            )
        )
        cell.configure(title: profile.displayName, body: parts.joined(separator: "\n"))
        return cell
    }

    private func makeSampleCell(at indexPath: IndexPath) -> UITableViewCell {
        let row = indexPath.row
        if row == 0 {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SwitchCell.reuseIdentifier,
                for: indexPath
            ) as? SwitchCell else {
                return UITableViewCell()
            }
            cell.configure(
                title: L10n.t("market.sample.toggle"),
                isOn: viewModel.showSampleItems
            ) { [weak self] isOn in
                self?.viewModel.setShowSampleItems(isOn)
            }
            return cell
        }

        guard viewModel.showSampleItems else { return UITableViewCell() }

        let hasFilters = !viewModel.sampleItems.isEmpty
        if hasFilters && row == 1 {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: MarketFilterCell.reuseIdentifier,
                for: indexPath
            ) as? MarketFilterCell else {
                return UITableViewCell()
            }
            cell.configure(
                vendorTitle: viewModel.selectedVendor.map {
                    L10n.f("market.filter.vendor", $0)
                } ?? L10n.t("market.filter.vendorAll"),
                compatibilityTitle: viewModel.selectedCompatibility.map {
                    L10n.f("market.filter.compatibility", $0)
                } ?? L10n.t("market.filter.compatibilityAll"),
                showsReset: viewModel.hasActiveFilter
            )
            cell.onVendor = { [weak self, weak cell] in
                guard let self, let cell else { return }
                self.presentFilterSheet(
                    title: L10n.t("market.filterByVendor"),
                    options: self.viewModel.vendors,
                    selected: self.viewModel.selectedVendor,
                    sourceView: cell
                ) { [weak self] value in
                    self?.viewModel.selectVendor(value)
                }
            }
            cell.onCompatibility = { [weak self, weak cell] in
                guard let self, let cell else { return }
                self.presentFilterSheet(
                    title: L10n.t("market.filterByCompatibility"),
                    options: self.viewModel.compatibilityOptions,
                    selected: self.viewModel.selectedCompatibility,
                    sourceView: cell
                ) { [weak self] value in
                    self?.viewModel.selectCompatibility(value)
                }
            }
            cell.onReset = { [weak self] in
                self?.viewModel.resetFilters()
            }
            return cell
        }

        let itemIndex = row - (hasFilters ? 2 : 1)
        guard itemIndex >= 0, itemIndex < viewModel.items.count else {
            return makeInlineEmptyCell()
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: MarketItemCell.reuseIdentifier,
            for: indexPath
        ) as? MarketItemCell else {
            return UITableViewCell()
        }
        cell.configure(item: viewModel.items[itemIndex])
        return cell
    }

    private func makeInlineEmptyCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.applyFont(AppText.caption.font())
        cell.textLabel?.textColor = Palette.textSecondary
        cell.textLabel?.text = viewModel.hasActiveFilter
            ? L10n.t("market.sample.noMatches")
            : (viewModel.marketItemsError == nil
                ? L10n.t("market.sample.empty")
                : L10n.t("market.sample.loadFailed"))
        return cell
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
        sheet.addAction(UIAlertAction(title: L10n.t("common.all"), style: .default) { _ in onSelect(nil) })
        for option in options {
            let actionTitle = option == selected ? "✓ \(option)" : option
            sheet.addAction(UIAlertAction(title: actionTitle, style: .default) { _ in onSelect(option) })
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView
        sheet.popoverPresentationController?.sourceRect = sourceView.bounds
        present(sheet, animated: true)
    }
}

// MARK: - UITableViewDelegate

extension MarketViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let sectionKind = Section(rawValue: indexPath.section), sectionKind == .services else {
            return
        }
        navigate(to: ServiceEntry.allCases[indexPath.row])
    }

    private func navigate(to entry: ServiceEntry) {
        switch entry {
        case .pairing:
            (tabBarController as? MainTabBarController)?.openHomeScanner()
        case .troubleshooting:
            navigationController?.pushViewController(
                HelpCenterViewController(topic: .connection),
                animated: true
            )
        case .powerSaving:
            (tabBarController as? MainTabBarController)?.openProfileBackgroundSettings()
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = self.tableView(tableView, titleForHeaderInSection: section) else { return nil }
        let container = UIView()
        container.backgroundColor = .clear
        let header = SectionHeaderView(title: title)
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.pageMargin),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.pageMargin),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        self.tableView(tableView, titleForHeaderInSection: section) == nil ? 0 : Layout.sectionHeaderH
    }
}
