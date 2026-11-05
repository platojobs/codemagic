import UIKit

/// 首页：设备卡片网格（按分组分段）+ 今日告警摘要 + 快捷场景。
final class HomeDashboardViewController: UIViewController {
    // MARK: - Sections

    private enum Section: Equatable {
        case alert
        case scenarios
        case scenarioEmpty
        case devices(group: String, items: [SavedDevice])
        case devicesEmpty
        case error(message: String)
    }

    // MARK: - Subviews

    private let collectionView: UICollectionView
    private let searchBar = UISearchBar()
    private let sortButton = AppButton(style: .filterChip, title: "排序", symbolName: "arrow.up.arrow.down")
    private let groupButton = AppButton(style: .filterChip, title: "分组", symbolName: "line.3.horizontal.decrease.circle")
    private let controlsView = UIStackView()
    private var titleHost: LargeTitleHost?

    // MARK: - Dependencies

    private let viewModel: HomeDashboardViewModel
    private let environment: AppEnvironment

    // MARK: - Init

    init(viewModel: HomeDashboardViewModel, environment: AppEnvironment) {
        self.viewModel = viewModel
        self.environment = environment
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "首页"
        view.backgroundColor = Palette.canvas
        configureCollectionView()
        configureControls()
        configureNavigation()

        titleHost = LargeTitleHost(
            title: "首页",
            viewController: self,
            scrollView: collectionView,
            adjustsContentInset: false
        )
        titleHost?.setSubtitle("设备、场景与今日告警")

        controlsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsView)
        NSLayoutConstraint.activate([
            controlsView.topAnchor.constraint(equalTo: titleHost!.header.bottomAnchor, constant: Layout.space8),
            controlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.pageMargin),
            controlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.pageMargin),
            collectionView.topAnchor.constraint(equalTo: controlsView.bottomAnchor, constant: Layout.space8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        viewModel.onChange = { [weak self] in
            self?.refreshControls()
            self?.collectionView.reloadData()
        }
        viewModel.reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.reload()
    }

    // MARK: - Configuration

    private func configureNavigation() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: SymbolName.bluetooth),
            style: .plain,
            target: self,
            action: #selector(presentScanner)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = "扫描附近设备"
    }

    private func configureCollectionView() {
        collectionView.backgroundColor = Palette.canvas
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(DeviceCardCell.self, forCellWithReuseIdentifier: DeviceCardCell.reuseIdentifier)
        collectionView.register(QuickScenarioCell.self, forCellWithReuseIdentifier: QuickScenarioCell.reuseIdentifier)
        collectionView.register(HomeAlertCell.self, forCellWithReuseIdentifier: HomeAlertCell.reuseIdentifier)
        collectionView.register(HomeEmptyCell.self, forCellWithReuseIdentifier: HomeEmptyCell.reuseIdentifier)
        collectionView.register(HomeErrorCell.self, forCellWithReuseIdentifier: HomeErrorCell.reuseIdentifier)
        collectionView.register(
            HomeSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: HomeSectionHeaderView.reuseIdentifier
        )
        collectionView.contentInset.bottom = Layout.space24
        collectionView.collectionViewLayout = makeLayout()
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
    }

    private func configureControls() {
        searchBar.delegate = self
        searchBar.placeholder = "搜索别名、广播名、型号或标识符"
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.backgroundImage = UIImage()
        searchBar.searchTextField.backgroundColor = Palette.surface
        searchBar.searchTextField.textColor = Palette.textPrimary
        searchBar.searchTextField.font = AppText.callout.font()
        searchBar.searchTextField.layer.cornerRadius = Radius.input
        searchBar.searchTextField.layer.cornerCurve = .continuous
        searchBar.searchTextField.layer.borderWidth = Stroke.one
        searchBar.searchTextField.layer.borderColor = Palette.divider.resolvedColor(with: traitCollection).cgColor
        searchBar.searchTextField.heightAnchor.constraint(equalToConstant: Layout.inputH).isActive = true

        sortButton.addTarget(self, action: #selector(handleSort), for: .touchUpInside)
        groupButton.addTarget(self, action: #selector(handleGroup), for: .touchUpInside)

        let chips = UIStackView(arrangedSubviews: [sortButton, groupButton, UIView()])
        chips.axis = .horizontal
        chips.spacing = Layout.space8
        chips.alignment = .center

        controlsView.axis = .vertical
        controlsView.spacing = Layout.space8
        controlsView.addArrangedSubview(searchBar)
        controlsView.addArrangedSubview(chips)
        refreshControls()
    }

    private func refreshControls() {
        sortButton.configuration?.title = "排序：\(viewModel.sort.title)"
        groupButton.configuration?.title = "分组：\(viewModel.groupFilter ?? "全部")"
        groupButton.isHidden = viewModel.availableGroups.isEmpty
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self, self.sections.indices.contains(index) else { return nil }
            return self.layoutSection(for: self.sections[index])
        }
    }

    private func layoutSection(for section: Section) -> NSCollectionLayoutSection? {
        switch section {
        case .alert:
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(96))
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(96)),
                subitems: [item]
            )
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: Layout.space8, leading: Layout.pageMargin, bottom: 0, trailing: Layout.pageMargin
            )
            return layoutSection

        case .scenarios, .scenarioEmpty:
            let height: CGFloat = section == .scenarios ? 124 : 200
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: section == .scenarios ? .absolute(210) : .fractionalWidth(1),
                    heightDimension: .absolute(height)
                )
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: section == .scenarios ? .absolute(210) : .fractionalWidth(1),
                    heightDimension: .absolute(height)
                ),
                subitems: [item]
            )
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.orthogonalScrollingBehavior = section == .scenarios ? .continuous : .none
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: Layout.pageMargin, bottom: 0, trailing: Layout.pageMargin
            )
            layoutSection.boundarySupplementaryItems = [makeHeader()]
            return layoutSection

        case .devices:
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(140))
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(140)),
                subitem: item,
                count: 2
            )
            group.interItemSpacing = .fixed(Layout.cardGap)
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.interGroupSpacing = Layout.cardGap
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: Layout.pageMargin, bottom: Layout.space8, trailing: Layout.pageMargin
            )
            layoutSection.boundarySupplementaryItems = [makeHeader()]
            return layoutSection

        case .devicesEmpty:
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(280))
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(280)),
                subitems: [item]
            )
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: Layout.space8, leading: Layout.pageMargin, bottom: 0, trailing: Layout.pageMargin
            )
            return layoutSection

        case .error:
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(160))
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(160)),
                subitems: [item]
            )
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: Layout.space8, leading: Layout.pageMargin, bottom: 0, trailing: Layout.pageMargin
            )
            return layoutSection
        }
    }

    private func makeHeader() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(Layout.sectionHeaderH)),
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )
    }

    private var sections: [Section] {
        if let error = viewModel.lastError {
            return [.error(message: error.localizedDescription)]
        }
        var result: [Section] = [.alert]
        if viewModel.scenarios.isEmpty {
            result.append(.scenarioEmpty)
        } else {
            result.append(.scenarios)
        }
        if viewModel.devices.isEmpty || viewModel.filteredDevices.isEmpty {
            result.append(.devicesEmpty)
        } else {
            for group in viewModel.groupedDevices {
                result.append(.devices(group: group.group, items: group.devices))
            }
        }
        return result
    }

    // MARK: - Actions

    @objc private func presentScanner() {
        let scanViewModel = HomeViewModel(
            bluetooth: environment.bluetooth,
            savedDeviceStore: environment.savedDeviceStore,
            recentDeviceStore: environment.recentDeviceStore,
            scanLogStore: environment.scanLogStore,
            ruleStore: environment.ruleStore,
            settingsStore: environment.settingsStore,
            ruleEvaluator: RuleEvaluator(),
            ruleAlertCoordinator: environment.ruleAlertCoordinator
        )
        let scanner = HomeViewController(viewModel: scanViewModel)
        scanner.title = "扫描附近设备"
        let navigation = UINavigationController(rootViewController: scanner)
        present(navigation, animated: true)
    }

    @objc private func handleSort() {
        let sheet = UIAlertController(title: "排序方式", message: nil, preferredStyle: .actionSheet)
        for option in DeviceSort.allCases {
            sheet.addAction(UIAlertAction(title: option == viewModel.sort ? "✓ \(option.title)" : option.title, style: .default) { [weak self] _ in
                self?.viewModel.updateSort(option)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentSheet(sheet, source: sortButton)
    }

    @objc private func handleGroup() {
        let sheet = UIAlertController(title: "按分组筛选", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: viewModel.groupFilter == nil ? "✓ 全部" : "全部", style: .default) { [weak self] _ in
            self?.viewModel.updateGroupFilter(nil)
        })
        for group in viewModel.availableGroups {
            sheet.addAction(UIAlertAction(title: group == viewModel.groupFilter ? "✓ \(group)" : group, style: .default) { [weak self] _ in
                self?.viewModel.updateGroupFilter(group)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentSheet(sheet, source: groupButton)
    }

    private func presentSheet(_ sheet: UIAlertController, source: UIView) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
        }
        present(sheet, animated: true)
    }

    private func openSmart() {
        tabBarController?.selectedIndex = 1
    }

    /// 通知深链：刷新后打开指定设备详情。
    func openDeviceDetail(deviceID: UUID) {
        viewModel.reload()
        guard let device = viewModel.device(id: deviceID) else {
            ToastView.show("设备已删除或不在本机", kind: .failure, in: self)
            return
        }
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
            readingsIngestor: environment.readingsIngestor
        )
        navigationController?.pushViewController(DeviceDetailViewController(viewModel: detailViewModel), animated: true)
    }

    private func runScenario(_ scenario: Scenario) {
        let overlay = ScenarioProgressOverlay(scenario: scenario)
        overlay.onFinish = { [weak self] result in
            guard let self else { return }
            if result.isFullySuccessful {
                ToastView.show("「\(result.scenarioName)」\(result.summaryText)", kind: .success, in: self)
            } else {
                ToastView.show("「\(result.scenarioName)」\(result.failureText)", kind: .failure, in: self)
            }
            self.viewModel.reload()
        }
        overlay.present(in: view)
        viewModel.runScenario(scenario) { result in
            overlay.complete(result)
        }
    }

    private func presentEditAlert(for device: SavedDevice) {
        let alert = UIAlertController(title: "编辑设备", message: "备注名用于展示，分组用于首页分段。", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = device.remark.isEmpty ? device.advertisedName : device.remark
            field.placeholder = "备注名"
        }
        alert.addTextField { field in
            field.text = device.groupName
            field.placeholder = "分组"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            let remark = alert?.textFields?.first?.text ?? ""
            let group = alert?.textFields?.last?.text ?? ""
            self?.viewModel.updateDevice(id: device.id, remark: remark, groupName: group)
        })
        present(alert, animated: true)
    }

    private func confirmDelete(_ device: SavedDevice) {
        let alert = UIAlertController(
            title: "删除设备？",
            message: "将同时删除该设备关联的本地规则。删除会先软删除，便于后续同步。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.viewModel.deleteDevice(id: device.id)
        })
        present(alert, animated: true)
    }
}

// MARK: - UICollectionViewDataSource

extension HomeDashboardViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        switch sections[section] {
        case .alert, .scenarioEmpty, .devicesEmpty, .error:
            return 1
        case .scenarios:
            return viewModel.quickScenarios.count
        case .devices(_, let items):
            return items.count
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch sections[indexPath.section] {
        case .alert:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HomeAlertCell.reuseIdentifier,
                for: indexPath
            ) as? HomeAlertCell else { return UICollectionViewCell() }
            cell.configure(
                count: viewModel.todayAlertCount,
                summary: viewModel.alertSummaryText,
                detail: viewModel.alertSummaryDetail,
                kind: viewModel.alertSummaryKind
            ) { [weak self] in
                self?.openSmart()
            }
            return cell

        case .scenarios:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: QuickScenarioCell.reuseIdentifier,
                for: indexPath
            ) as? QuickScenarioCell else { return UICollectionViewCell() }
            let scenario = viewModel.quickScenarios[indexPath.item]
            cell.configure(scenario: scenario) { [weak self] in
                self?.runScenario(scenario)
            }
            return cell

        case .scenarioEmpty:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HomeEmptyCell.reuseIdentifier,
                for: indexPath
            ) as? HomeEmptyCell else { return UICollectionViewCell() }
            cell.configure(
                symbol: SymbolName.rule,
                title: "还没有场景",
                message: "把常用动作组合成场景，例如连接设备后立即同步。",
                actionTitle: "去智能页创建"
            ) { [weak self] in
                self?.openSmart()
            }
            return cell

        case .devices(_, let items):
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: DeviceCardCell.reuseIdentifier,
                for: indexPath
            ) as? DeviceCardCell else { return UICollectionViewCell() }
            let device = items[indexPath.item]
            cell.configure(
                device: device,
                isConnected: viewModel.isConnected(device),
                readingText: viewModel.readingText(for: device),
                rssi: viewModel.rssi(for: device)
            ) { [weak self] in
                self?.openDetail(for: device)
            }
            return cell

        case .devicesEmpty:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HomeEmptyCell.reuseIdentifier,
                for: indexPath
            ) as? HomeEmptyCell else { return UICollectionViewCell() }
            cell.configure(
                symbol: viewModel.devices.isEmpty ? SymbolName.device : "line.3.horizontal.decrease.circle",
                title: viewModel.devices.isEmpty ? "还没有设备" : "没有匹配的设备",
                message: viewModel.emptyStateText,
                actionTitle: viewModel.emptyActionTitle
            ) { [weak self] in
                guard let self else { return }
                if self.viewModel.devices.isEmpty {
                    self.presentScanner()
                } else {
                    self.viewModel.resetFilters()
                }
            }
            return cell

        case .error(let message):
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HomeErrorCell.reuseIdentifier,
                for: indexPath
            ) as? HomeErrorCell else { return UICollectionViewCell() }
            cell.configure(message: message) { [weak self] in
                self?.viewModel.reload()
            }
            return cell
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: HomeSectionHeaderView.reuseIdentifier,
                for: indexPath
              ) as? HomeSectionHeaderView
        else { return UICollectionReusableView() }

        switch sections[indexPath.section] {
        case .scenarios, .scenarioEmpty:
            header.configure(title: "快捷场景")
        case .devices(let group, let items):
            header.configure(title: "\(group) · \(items.count)")
        default:
            header.configure(title: "")
        }
        return header
    }
}

// MARK: - UICollectionViewDelegate

extension HomeDashboardViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .devices(_, let items) = sections[indexPath.section], items.indices.contains(indexPath.item) else {
            return nil
        }
        let device = items[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let edit = UIAction(title: "编辑备注与分组", image: UIImage(systemName: SymbolName.edit)) { _ in
                self.presentEditAlert(for: device)
            }
            let delete = UIAction(title: "删除设备", image: UIImage(systemName: SymbolName.delete), attributes: .destructive) { _ in
                self.confirmDelete(device)
            }
            let detail = UIAction(title: "查看详情", image: UIImage(systemName: SymbolName.disclosure)) { _ in
                self.openDetail(for: device)
            }
            return UIMenu(children: [detail, edit, delete])
        }
    }
}

// MARK: - UISearchBarDelegate

extension HomeDashboardViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        viewModel.updateSearch(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
