import UIKit

/// 设备页：已保存设备管理（备注名、分组、最后出现时间）与本地规则增删启停。
final class DevicesViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case devices
        case rules
    }

    // MARK: - Subviews

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let addRuleButton = UIBarButtonItem()
    private let filterBar = UIStackView()
    private let sortButton = AppTheme.makePillButton(title: L10n.t("devices.sort"), symbolName: "arrow.up.arrow.down")
    private let groupButton = AppTheme.makePillButton(title: L10n.t("device.detail.group"), symbolName: "line.3.horizontal.decrease.circle")
    private let searchController = UISearchController(searchResultsController: nil)
    private var filterHeaderHeight: CGFloat = 0

    // MARK: - Dependencies

    private let viewModel: DevicesViewModel
    private let environment: AppEnvironment

    // MARK: - Init

    init(viewModel: DevicesViewModel, environment: AppEnvironment) {
        self.viewModel = viewModel
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("devices.title")
        view.backgroundColor = AppTheme.Palette.background
        configureTableView()
        configureSearchAndFilter()

        addRuleButton.target = self
        addRuleButton.action = #selector(handleAddRule)
        addRuleButton.title = L10n.t("common.add")
        navigationItem.rightBarButtonItem = addRuleButton

        viewModel.onChange = { [weak self] in
            self?.refreshFilterBar()
            self?.tableView.reloadData()
        }
        viewModel.reload()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateFilterHeaderHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.reload()
    }

    // MARK: - Configuration

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(SavedDeviceCell.self, forCellReuseIdentifier: SavedDeviceCell.reuseIdentifier)
        tableView.register(RuleCell.self, forCellReuseIdentifier: RuleCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "PlaceholderCell")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppTheme.Metrics.estimatedRowHeight
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureSearchAndFilter() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = L10n.t("devices.searchPlaceholder")
        searchController.searchBar.autocapitalizationType = .none
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        filterBar.axis = .horizontal
        filterBar.spacing = AppTheme.Spacing.small
        filterBar.alignment = .center
        filterBar.distribution = .fill
        filterBar.isLayoutMarginsRelativeArrangement = true
        filterBar.layoutMargins = UIEdgeInsets(
            top: AppTheme.Spacing.small,
            left: AppTheme.Spacing.large,
            bottom: AppTheme.Spacing.small,
            right: AppTheme.Spacing.large
        )
        sortButton.addTarget(self, action: #selector(handleSort), for: .touchUpInside)
        groupButton.addTarget(self, action: #selector(handleGroup), for: .touchUpInside)
        filterBar.addArrangedSubview(sortButton)
        filterBar.addArrangedSubview(groupButton)
        filterBar.addArrangedSubview(UIView())

        let wrapper = UIView()
        wrapper.addSubview(filterBar)
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: wrapper.topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            filterBar.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        wrapper.frame = CGRect(x: 0, y: 0, width: 1, height: 44)
        tableView.tableHeaderView = wrapper
        refreshFilterBar()
    }

    private func refreshFilterBar() {
        sortButton.configuration?.title = L10n.f("devices.sortSummary", String(describing: viewModel.sort.title))
        groupButton.configuration?.title = viewModel.groupFilter.map { L10n.f("devices.groupSummary", $0) } ?? L10n.t("devices.groupSummaryAll")
        groupButton.isHidden = viewModel.availableGroups.isEmpty
        updateFilterHeaderHeight()
    }

    private func updateFilterHeaderHeight() {
        guard let header = tableView.tableHeaderView else { return }
        let width = max(tableView.bounds.width, view.bounds.width, 1)
        header.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let size = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = max(size.height, 44)
        header.frame.size.height = height
        guard abs(height - filterHeaderHeight) > 0.5 else { return }
        filterHeaderHeight = height
        tableView.tableHeaderView = header
    }

    @objc private func handleSort() {
        let sheet = UIAlertController(title: L10n.t("devices.sortOrder"), message: nil, preferredStyle: .actionSheet)
        for option in DeviceSort.allCases {
            let selected = option == viewModel.sort
            sheet.addAction(UIAlertAction(
                title: selected ? "✓ \(option.title)" : option.title,
                style: .default
            ) { [weak self] _ in
                self?.viewModel.updateSort(option)
            })
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        presentSheet(sheet, source: sortButton)
    }

    @objc private func handleGroup() {
        let sheet = UIAlertController(title: L10n.t("devices.filterByGroup"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(
            title: viewModel.groupFilter == nil ? L10n.t("devices.groupAllChecked") : L10n.t("common.all"),
            style: .default
        ) { [weak self] _ in
            self?.viewModel.updateGroupFilter(nil)
        })
        for group in viewModel.availableGroups {
            let selected = group == viewModel.groupFilter
            sheet.addAction(UIAlertAction(
                title: selected ? "✓ \(group)" : group,
                style: .default
            ) { [weak self] _ in
                self?.viewModel.updateGroupFilter(group)
            })
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        presentSheet(sheet, source: groupButton)
    }

    private func presentSheet(_ sheet: UIAlertController, source: UIView) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
        }
        present(sheet, animated: true)
    }

    // MARK: - Actions

    @objc private func handleAddRule() {
        let editor = RuleEditorViewController(deviceOptions: viewModel.ruleDeviceOptions) { [weak self] rule in
            self?.viewModel.saveRule(rule)
        }
        let navigationController = UINavigationController(rootViewController: editor)
        present(navigationController, animated: true)
    }

    private func presentEditAlert(for device: SavedDevice) {
        let alert = UIAlertController(
            title: L10n.t("devices.edit"),
            message: L10n.t("devices.editNote"),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = device.remark
            field.placeholder = L10n.t("devices.alias")
        }
        alert.addTextField { field in
            field.text = device.groupName
            field.placeholder = L10n.t("device.detail.group")
        }
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("common.save"), style: .default) { [weak self, weak alert] _ in
            let remark = alert?.textFields?.first?.text ?? ""
            let group = alert?.textFields?.last?.text ?? ""
            self?.viewModel.updateDevice(id: device.id, remark: remark, groupName: group)
        })
        present(alert, animated: true)
    }

    private func confirmDeleteDevice(_ device: SavedDevice) {
        let alert = UIAlertController(
            title: L10n.t("devices.deleteTitle"),
            message: L10n.t("devices.deleteMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("common.delete"), style: .destructive) { [weak self] _ in
            self?.viewModel.deleteDevice(id: device.id)
        })
        present(alert, animated: true)
    }

    /// 通知点击入口：按设备 ID 打开详情；不存在时静默返回列表。
    func openDetail(deviceID: UUID) {
        viewModel.reload()
        let device = viewModel.device(id: deviceID)
            ?? (try? environment.savedDeviceStore.fetchAll())?.first { $0.id == deviceID }
        guard let device else { return }
        openDetail(for: device)
    }

    private func openDetail(for device: SavedDevice) {
        let detailViewModel = DeviceDetailViewModel(
            device: device,
            bluetooth: environment.bluetooth,
            productService: environment.productService,
            cacheStore: environment.deviceInfoCacheStore,
            savedDeviceStore: environment.savedDeviceStore,
            readingsStore: environment.readingsStore,
            readingsService: environment.readingsService,
            readingsIngestor: environment.readingsIngestor,
            roomStore: environment.roomStore
        )
        let detail = DeviceDetailViewController(viewModel: detailViewModel)
        navigationController?.pushViewController(detail, animated: true)
    }
}

// MARK: - UITableViewDataSource

extension DevicesViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .devices:
            return max(viewModel.filteredDevices.count, 1)
        case .rules:
            return max(viewModel.rules.count, 1)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .devices:
            if viewModel.hasActiveFilter {
                return L10n.f("devices.savedCount", String(describing: viewModel.filteredDevices.count), String(describing: viewModel.devices.count))
            }
            return L10n.f("devices.savedCountSingle", String(describing: viewModel.devices.count))
        case .rules:
            return L10n.f("devices.rulesCount", String(describing: viewModel.rules.count))
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else { return UITableViewCell() }

        switch section {
        case .devices:
            let devices = viewModel.filteredDevices
            guard !devices.isEmpty else {
                return makePlaceholderCell(
                    text: viewModel.emptyStateText,
                    symbol: viewModel.emptyStateSymbol
                )
            }
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SavedDeviceCell.reuseIdentifier,
                for: indexPath
            ) as? SavedDeviceCell else {
                return UITableViewCell()
            }
            cell.configure(device: devices[indexPath.row])
            return cell

        case .rules:
            guard !viewModel.rules.isEmpty else {
                return makePlaceholderCell(
                    text: L10n.t("devices.noRules"),
                    symbol: SymbolName.rule
                )
            }
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: RuleCell.reuseIdentifier,
                for: indexPath
            ) as? RuleCell else {
                return UITableViewCell()
            }
            let rule = viewModel.rules[indexPath.row]
            cell.configure(rule: rule, targetName: viewModel.deviceName(for: rule.deviceID)) { [weak self] in
                self?.viewModel.toggleRule(id: rule.id)
            }
            return cell
        }
    }

    private func makePlaceholderCell(text: String, symbol: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "PlaceholderCell")
            ?? UITableViewCell(style: .default, reuseIdentifier: "PlaceholderCell")
        var configuration = cell.defaultContentConfiguration()
        configuration.text = text
        configuration.textProperties.color = AppTheme.Palette.secondaryText
        configuration.image = UIImage(systemName: symbol)
        configuration.imageProperties.tintColor = AppTheme.Palette.tertiaryText
        cell.contentConfiguration = configuration
        cell.selectionStyle = .none
        return cell
    }
}

// MARK: - UISearchResultsUpdating

extension DevicesViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        viewModel.updateSearch(searchController.searchBar.text ?? "")
    }
}

// MARK: - UITableViewDelegate

extension DevicesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let devices = viewModel.filteredDevices
        guard indexPath.section == Section.devices.rawValue,
              devices.indices.contains(indexPath.row) else { return }
        let device = devices[indexPath.row]
        // 跨平台拉回的设备没有本机 CoreBluetooth 标识，禁用连接入口。
        guard device.isConnectable else { return }
        openDetail(for: device)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let section = Section(rawValue: indexPath.section) else { return nil }

        let devices = viewModel.filteredDevices
        let deleteAction = UIContextualAction(style: .destructive, title: L10n.t("common.delete")) { [weak self] _, _, completion in
            guard let self else { return }
            switch section {
            case .devices where devices.indices.contains(indexPath.row):
                self.confirmDeleteDevice(devices[indexPath.row])
            case .rules where !self.viewModel.rules.isEmpty:
                self.viewModel.deleteRule(id: self.viewModel.rules[indexPath.row].id)
            default:
                break
            }
            completion(true)
        }

        let editAction = UIContextualAction(style: .normal, title: L10n.t("common.edit")) { [weak self] _, _, completion in
            guard let self, section == .devices, devices.indices.contains(indexPath.row) else {
                completion(false)
                return
            }
            self.presentEditAlert(for: devices[indexPath.row])
            completion(true)
        }

        switch section {
        case .devices where !devices.isEmpty:
            return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
        case .rules where !viewModel.rules.isEmpty:
            return UISwipeActionsConfiguration(actions: [deleteAction])
        default:
            return nil
        }
    }
}
