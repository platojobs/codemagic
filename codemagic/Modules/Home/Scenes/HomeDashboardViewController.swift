import UIKit

/// 首页：设备卡片按房间分段 + 今日告警摘要 + 快捷场景。
final class HomeDashboardViewController: UIViewController {
    // MARK: - Sections

    private enum Section: Equatable {
        case alert
        case scenarios
        case scenarioEmpty
        case roomsEmpty
        case room(room: Room?, items: [SavedDevice], totalCount: Int)
        case roomEmpty(room: Room)
        case devicesEmpty
        case error(message: String)
    }

    // MARK: - Subviews

    private let collectionView: UICollectionView
    private let searchBar = UISearchBar()
    private let sortButton = AppButton(style: .filterChip, title: L10n.t("devices.sort"), symbolName: "arrow.up.arrow.down")
    private let roomButton = AppButton(style: .filterChip, title: L10n.t("room.manage"), symbolName: "square.grid.2x2")
    /// 仅在用户拥有多于一个家庭时显示；单家庭不出现切换控件。
    private let householdButton = AppButton(
        style: .filterChip,
        title: L10n.t("household.switch"),
        symbolName: "person.2"
    )
    private let controlsView = UIStackView()
    private let chipsStack = UIStackView()
    private let chipsScroll = UIScrollView()
    private var titleHost: LargeTitleHost?
    /// 设备卡高度测量用：隐藏、不参与交互，但挂在视图树里，AX 字号会真实放大后再测量。
    private let sizingCard = DeviceCardCell(frame: .zero)
    private var sizingCardWidth: NSLayoutConstraint?

    /// 收起状态只保存在当前会话：房间分区标题可点击展开 / 收起，未分配分区固定排最后。
    private var collapsedRoomIDs: Set<UUID> = []
    private var isUnassignedCollapsed = false

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyBottomOcclusionInset(to: collectionView)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Tab 在首次布局之后才挂上时，safe area 会再变一次，这里重算底部留白，避免沿用初始值。
        applyBottomOcclusionInset(to: collectionView)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory else { return }
        applyChipsArrangement()
        // 设备卡高度按字号测量，字号切档后必须重新计算分区高度。
        collectionView.collectionViewLayout.invalidateLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("tab.home")
        view.backgroundColor = Palette.canvas
        configureSizingCard()
        configureCollectionView()
        configureControls()
        configureNavigation()

        titleHost = LargeTitleHost(
            title: L10n.t("tab.home"),
            viewController: self,
            scrollView: collectionView,
            adjustsContentInset: false
        )
        titleHost?.setSubtitle(L10n.t("home.subtitle"))

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
        LaunchMetrics.mark("home-data-ready")
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
        navigationItem.rightBarButtonItem?.accessibilityLabel = L10n.t("home.scan.action")
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
        searchBar.placeholder = L10n.t("devices.searchPlaceholder")
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.backgroundImage = UIImage()
        searchBar.searchTextField.backgroundColor = Palette.surface
        searchBar.searchTextField.textColor = Palette.textPrimary
        searchBar.searchTextField.applyFont(AppText.callout.font())
        searchBar.searchTextField.layer.cornerRadius = Radius.input
        searchBar.searchTextField.layer.cornerCurve = .continuous
        searchBar.searchTextField.layer.borderWidth = Stroke.one
        searchBar.searchTextField.layer.borderColor = Palette.divider.resolvedColor(with: traitCollection).cgColor
        searchBar.searchTextField.heightAnchor.constraint(equalToConstant: Layout.inputH).isActive = true

        sortButton.addTarget(self, action: #selector(handleSort), for: .touchUpInside)
        roomButton.addTarget(self, action: #selector(handleRooms), for: .touchUpInside)
        householdButton.addTarget(self, action: #selector(handleHouseholdSwitch), for: .touchUpInside)

        let chips = chipsStack
        chips.addArrangedSubview(sortButton)
        chips.addArrangedSubview(roomButton)
        chips.addArrangedSubview(householdButton)
        chips.spacing = Layout.space8
        chips.setContentHuggingPriority(.required, for: .horizontal)
        chips.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 按内容固有宽度排布；常规字号放不下时横向滚动，AX 档改为竖排，保证三个 chip 文字完整。
        chipsScroll.showsHorizontalScrollIndicator = false
        chipsScroll.showsVerticalScrollIndicator = false
        chipsScroll.translatesAutoresizingMaskIntoConstraints = false
        chipsScroll.addSubview(chips)
        chips.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chips.topAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.bottomAnchor),
            chips.leadingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.trailingAnchor),
            chipsScroll.heightAnchor.constraint(equalTo: chips.heightAnchor),
        ])
        applyChipsArrangement()

        controlsView.axis = .vertical
        controlsView.spacing = Layout.space8
        controlsView.addArrangedSubview(searchBar)
        controlsView.addArrangedSubview(chipsScroll)
        refreshControls()
    }

    /// 常规字号横排、放不下时横向滚动；AX 档竖排，避免边缘 chip 只露出半个。
    private func applyChipsArrangement() {
        let isAccessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        chipsStack.axis = isAccessibility ? .vertical : .horizontal
        chipsStack.alignment = isAccessibility ? .leading : .center
        chipsStack.spacing = Layout.space8
        chipsScroll.alwaysBounceHorizontal = !isAccessibility
        chipsScroll.alwaysBounceVertical = false
    }

    /// 隐藏的测量卡：只有宽度约束，高度由内容决定；挂在视图树里才能拿到放大后的 AX 字体。
    private func configureSizingCard() {
        sizingCard.isHidden = true
        sizingCard.isUserInteractionEnabled = false
        sizingCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sizingCard)
        let width = sizingCard.widthAnchor.constraint(equalToConstant: 0)
        sizingCardWidth = width
        NSLayoutConstraint.activate([
            width,
            sizingCard.topAnchor.constraint(equalTo: view.topAnchor),
        ])
    }

    /// AX 档在紧凑横向（iPhone）改为单列：两列时卡片只有约 180pt 宽，放不下放大后的
    /// 「72 bpm」等读数；iPad 常规横向每列约 500pt，保持两列仍可完整显示。
    private func usesSingleColumnCards() -> Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            && traitCollection.horizontalSizeClass == .compact
    }

    /// 是否处于无障碍大字号档位（与横向尺寸无关，用于文案重排与卡片自适配高）。
    private func isAccessibilityText() -> Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    /// 设备卡宽度：与分区实际可用宽度一致（常规 / iPad 两列，iPhone AX 单列）。
    private func deviceCardWidth() -> CGFloat {
        let container = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let content = container - Layout.pageMargin * 2
        return max(1, usesSingleColumnCards() ? content : (content - Layout.cardGap) / 2)
    }

    /// 取本段所有设备实测高度的最大值；常规字号下不低于 164pt，保持既有版式。
    private func deviceCardHeight(for items: [SavedDevice]) -> CGFloat {
        let width = deviceCardWidth()
        sizingCardWidth?.constant = width
        var height: CGFloat = 164
        for device in items {
            sizingCard.configure(
                device: device,
                isConnected: viewModel.isConnected(device),
                readingText: viewModel.readingText(for: device),
                rssi: viewModel.rssi(for: device),
                cloudReportedAt: viewModel.cloudReportedAt(for: device),
                isUnsynced: viewModel.isUnsynced(device)
            ) {}
            sizingCard.setNeedsLayout()
            sizingCard.layoutIfNeeded()
            let target = sizingCard.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            height = max(height, ceil(target.height))
        }
        return height
    }

    private func refreshControls() {
        sortButton.configuration?.title = L10n.f("devices.sortSummary", String(describing: viewModel.sort.title))
        roomButton.configuration?.title = viewModel.hasRooms
            ? L10n.f("room.manageWithCount", String(describing: viewModel.rooms.count))
            : L10n.t("room.manage")
        // 单家庭不出现切换控件。
        householdButton.isHidden = !viewModel.showsHouseholdSwitcher
        if let current = viewModel.currentHousehold {
            householdButton.configuration?.title = current.name
        } else {
            householdButton.configuration?.title = L10n.t("household.switch")
        }
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
            // 常规字号保持 96pt；AX 档改为自适配高，标题与说明不被固定高度裁切。
            let height: NSCollectionLayoutDimension = isAccessibilityText() ? .estimated(96) : .absolute(96)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: height)
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: height),
                subitems: [item]
            )
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: Layout.space8, leading: Layout.pageMargin, bottom: 0, trailing: Layout.pageMargin
            )
            return layoutSection

        case .scenarios, .scenarioEmpty:
            let base: CGFloat = section == .scenarios ? 124 : 200
            // 快捷场景卡与空态卡在 AX 档同样按内容自适配高，名称与说明不被固定高度裁切。
            let height: NSCollectionLayoutDimension = isAccessibilityText()
                ? .estimated(base)
                : .absolute(base)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: section == .scenarios ? .absolute(210) : .fractionalWidth(1),
                    heightDimension: height
                )
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: section == .scenarios ? .absolute(210) : .fractionalWidth(1),
                    heightDimension: height
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

        case .room(_, let items, _):
            if items.isEmpty {
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(1))
                )
                let group = NSCollectionLayoutGroup.vertical(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(1)),
                    subitems: [item]
                )
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(
                    top: 0, leading: Layout.pageMargin, bottom: 0, trailing: Layout.pageMargin
                )
                layoutSection.boundarySupplementaryItems = [makeHeader()]
                return layoutSection
            }
            // 每段卡片统一高度，按本段最长的名称 / 状态 / 读数 / 时间实测；
            // 常规字号下最小 164pt，AX 字号放大后随内容增高，不裁切、不缩字号。
            let height = deviceCardHeight(for: items)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height))
            )
            let group: NSCollectionLayoutGroup
            if usesSingleColumnCards() {
                // AX 档单列：放大后的读数有完整横向空间，不在数值与单位之间断行。
                group = NSCollectionLayoutGroup.vertical(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                    subitems: [item]
                )
            } else {
                group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                    subitem: item,
                    count: 2
                )
            }
            group.interItemSpacing = .fixed(Layout.cardGap)
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.interGroupSpacing = Layout.cardGap
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: Layout.pageMargin, bottom: Layout.space8, trailing: Layout.pageMargin
            )
            layoutSection.boundarySupplementaryItems = [makeHeader()]
            return layoutSection

        case .roomEmpty:
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(220))
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(220)),
                subitems: [item]
            )
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: Layout.pageMargin, bottom: Layout.space8, trailing: Layout.pageMargin
            )
            layoutSection.boundarySupplementaryItems = [makeHeader()]
            return layoutSection

        case .roomsEmpty:
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(220))
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(220)),
                subitems: [item]
            )
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: Layout.space8, leading: Layout.pageMargin, bottom: Layout.space8, trailing: Layout.pageMargin
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

        // 无房间：给出「还没有房间」+ 新建房间；有房间但无设备：逐房间引导扫描。
        if !viewModel.hasRooms {
            result.append(.roomsEmpty)
        }
        if viewModel.devices.isEmpty {
            if viewModel.hasRooms {
                result.append(contentsOf: viewModel.rooms.map { .roomEmpty(room: $0) })
            }
            return result
        }
        if viewModel.filteredDevices.isEmpty {
            result.append(.devicesEmpty)
            return result
        }

        for roomSection in viewModel.roomSections {
            let totalCount = roomSection.devices.count
            if let room = roomSection.room {
                if collapsedRoomIDs.contains(room.id) {
                    result.append(.room(room: room, items: [], totalCount: totalCount))
                } else if roomSection.devices.isEmpty {
                    result.append(.roomEmpty(room: room))
                } else {
                    result.append(.room(room: room, items: roomSection.devices, totalCount: totalCount))
                }
            } else if isUnassignedCollapsed {
                result.append(.room(room: nil, items: [], totalCount: totalCount))
            } else {
                result.append(.room(room: nil, items: roomSection.devices, totalCount: totalCount))
            }
        }
        return result
    }

    // MARK: - Actions

    private func presentBluetoothSettingsAlert() {
        let alert = UIAlertController(
            title: AppCopy.Permission.localOnlyTitle,
            message: AppCopy.Permission.localOnlyMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: AppCopy.Permission.openSettings, style: .default) { [weak self] _ in
            self?.openSystemSettings()
        })
        present(alert, animated: true)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func presentScanner() {
        if viewModel.isBluetoothPermissionBlocked {
            presentBluetoothSettingsAlert()
            return
        }
        let scanViewModel = HomeViewModel(
            bluetooth: environment.bluetooth,
            savedDeviceStore: environment.savedDeviceStore,
            recentDeviceStore: environment.recentDeviceStore,
            scanLogStore: environment.scanLogStore,
            ruleStore: environment.ruleStore,
            settingsStore: environment.settingsStore,
            ruleEvaluator: RuleEvaluator(),
            ruleAlertCoordinator: environment.ruleAlertCoordinator,
            sceneEngine: environment.sceneEngine
        )
        let scanner = HomeViewController(viewModel: scanViewModel)
        scanner.title = L10n.t("home.scan.action")
        let navigation = UINavigationController(rootViewController: scanner)
        present(navigation, animated: true)
    }

    /// 市场页「配对向导」入口：切到首页后直接打开扫描页。
    func startPairingWizard() {
        presentScanner()
    }

    @objc private func handleSort() {
        let sheet = UIAlertController(title: L10n.t("devices.sortOrder"), message: nil, preferredStyle: .actionSheet)
        for option in DeviceSort.allCases {
            sheet.addAction(UIAlertAction(title: option == viewModel.sort ? "✓ \(option.title)" : option.title, style: .default) { [weak self] _ in
                self?.viewModel.updateSort(option)
            })
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        presentSheet(sheet, source: sortButton)
    }

    @objc private func handleHouseholdSwitch() {
        let sheet = UIAlertController(title: L10n.t("household.switch.title"), message: nil, preferredStyle: .actionSheet)
        for household in viewModel.households {
            let isCurrent = household.id == viewModel.currentHousehold?.id
            let title = isCurrent
                ? "✓ \(household.name) · \(household.role.displayName)"
                : "\(household.name) · \(household.role.displayName)"
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.viewModel.switchHousehold(localID: household.id) { [weak self] in
                    self?.environment.syncEngine.sync { _ in }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        presentSheet(sheet, source: householdButton)
    }

    @objc private func handleRooms() {
        let viewModel = RoomManagementViewModel(
            roomStore: environment.roomStore,
            deviceStore: environment.savedDeviceStore,
            householdService: environment.householdService
        )
        let controller = RoomManagementViewController(viewModel: viewModel) { [weak self] in
            self?.viewModel.reload()
        }
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    private func toggleRoom(_ room: Room) {
        if collapsedRoomIDs.contains(room.id) {
            collapsedRoomIDs.remove(room.id)
        } else {
            collapsedRoomIDs.insert(room.id)
        }
        collectionView.reloadData()
    }

    /// 点房间分区标题进入详情：聚合本机与同步落地的同一份设备数据。
    private func openRoomDetail(_ room: Room) {
        let detailViewModel = RoomDetailViewModel(
            room: room,
            roomStore: environment.roomStore,
            deviceStore: environment.savedDeviceStore,
            readingsStore: environment.readingsStore,
            bluetooth: environment.bluetooth,
            householdService: environment.householdService,
            syncEngine: environment.syncEngine,
            cloudReadings: environment.cloudLatestReadings
        )
        let controller = RoomDetailViewController(
            viewModel: detailViewModel,
            onSelectDevice: { [weak self] device in self?.openDetail(for: device) },
            onScan: { [weak self] in self?.presentScanner() }
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    private func toggleUnassigned() {
        isUnassignedCollapsed.toggle()
        collectionView.reloadData()
    }

    private func presentMoveSheet(for device: SavedDevice) {
        let sheet = UIAlertController(title: L10n.t("room.moveTitle"), message: nil, preferredStyle: .actionSheet)
        let current = device.roomID
        for room in viewModel.rooms {
            sheet.addAction(UIAlertAction(
                title: room.id == current ? "✓ \(room.name)" : room.name,
                style: .default
            ) { [weak self] _ in
                self?.viewModel.moveDevice(id: device.id, to: room.id)
            })
        }
        sheet.addAction(UIAlertAction(
            title: current == nil ? "✓ \(L10n.t("room.unassigned"))" : L10n.t("room.unassigned"),
            style: .default
        ) { [weak self] _ in
            self?.viewModel.moveDevice(id: device.id, to: nil)
        })
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        presentSheet(sheet, source: view)
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
            ToastView.show(L10n.t("home.deviceGone"), kind: .failure, in: self)
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
            readingsIngestor: environment.readingsIngestor,
            roomStore: environment.roomStore
        )
        navigationController?.pushViewController(DeviceDetailViewController(viewModel: detailViewModel), animated: true)
    }

    private func runScenario(_ scenario: Scenario) {
        let overlay = ScenarioProgressOverlay(scenario: scenario)
        overlay.onFinish = { [weak self] result in
            guard let self else { return }
            if result.isFullySuccessful {
                ToastView.show(L10n.f("scenario.result.quoted", result.scenarioName, result.summaryText), kind: .success, in: self)
            } else {
                ToastView.show(L10n.f("scenario.result.quoted", result.scenarioName, result.failureText), kind: .failure, in: self)
            }
            self.viewModel.reload()
        }
        overlay.present(in: view)
        viewModel.runScenario(scenario) { result in
            overlay.complete(result)
        }
    }

    private func presentEditAlert(for device: SavedDevice) {
        let alert = UIAlertController(title: L10n.t("devices.edit"), message: L10n.t("home.editNote"), preferredStyle: .alert)
        alert.addTextField { field in
            field.text = device.remark.isEmpty ? device.advertisedName : device.remark
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

    private func confirmDelete(_ device: SavedDevice) {
        let alert = UIAlertController(
            title: L10n.t("devices.deleteTitle"),
            message: L10n.t("home.deleteNote"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("common.delete"), style: .destructive) { [weak self] _ in
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
        case .alert, .scenarioEmpty, .roomsEmpty, .roomEmpty, .devicesEmpty, .error:
            return 1
        case .scenarios:
            return viewModel.quickScenarios.count
        case .room(_, let items, _):
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
                title: L10n.t("home.noScenarios"),
                message: L10n.t("home.noScenariosMessage"),
                actionTitle: L10n.t("home.createInSmart")
            ) { [weak self] in
                self?.openSmart()
            }
            return cell

        case .roomsEmpty:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HomeEmptyCell.reuseIdentifier,
                for: indexPath
            ) as? HomeEmptyCell else { return UICollectionViewCell() }
            cell.configure(
                symbol: "house",
                title: L10n.t("room.emptyTitle"),
                message: L10n.t("room.emptyMessage"),
                actionTitle: L10n.t("room.create")
            ) { [weak self] in
                self?.handleRooms()
            }
            return cell

        case .roomEmpty:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HomeEmptyCell.reuseIdentifier,
                for: indexPath
            ) as? HomeEmptyCell else { return UICollectionViewCell() }
            cell.configure(
                symbol: SymbolName.device,
                title: L10n.t("room.roomEmptyTitle"),
                message: L10n.t("room.roomEmptyMessage"),
                actionTitle: L10n.t("home.scan.action")
            ) { [weak self] in
                self?.presentScanner()
            }
            return cell

        case .room(_, let items, _):
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: DeviceCardCell.reuseIdentifier,
                for: indexPath
            ) as? DeviceCardCell else { return UICollectionViewCell() }
            let device = items[indexPath.item]
            cell.configure(
                device: device,
                isConnected: viewModel.isConnected(device),
                readingText: viewModel.readingText(for: device),
                rssi: viewModel.rssi(for: device),
                cloudReportedAt: viewModel.cloudReportedAt(for: device),
                isUnsynced: viewModel.isUnsynced(device)
            ) { [weak self] in
                self?.openDetail(for: device)
            }
            return cell

        case .devicesEmpty:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HomeEmptyCell.reuseIdentifier,
                for: indexPath
            ) as? HomeEmptyCell else { return UICollectionViewCell() }
            let permissionBlocked = viewModel.isBluetoothPermissionBlocked
            cell.configure(
                symbol: permissionBlocked
                    ? "lock.shield"
                    : (viewModel.devices.isEmpty ? SymbolName.device : "line.3.horizontal.decrease.circle"),
                title: permissionBlocked
                    ? AppCopy.Permission.localOnlyTitle
                    : (viewModel.devices.isEmpty ? AppCopy.Home.emptyTitle : AppCopy.Home.filteredTitle),
                message: permissionBlocked ? AppCopy.Permission.localOnlyMessage : viewModel.emptyStateText,
                actionTitle: permissionBlocked ? AppCopy.Permission.openSettings : viewModel.emptyActionTitle
            ) { [weak self] in
                guard let self else { return }
                if permissionBlocked {
                    self.openSystemSettings()
                } else if self.viewModel.devices.isEmpty {
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
            header.configure(title: L10n.t("home.quickScenarios"))
        case .room(let room, _, let totalCount):
            let baseTitle = "\(room?.name ?? L10n.t("room.unassigned")) · \(totalCount)"
            // 本机 / 离线房间明确标注「未同步」，与服务端房间区分。
            let title = room.map { $0.syncState == .synced ? baseTitle : "\(baseTitle) · \(L10n.t("household.room.unsynced"))" }
                ?? baseTitle
            if let room {
                let collapsed = collapsedRoomIDs.contains(room.id)
                header.configure(
                    title: title,
                    collapsed: collapsed,
                    onToggle: { [weak self] in self?.toggleRoom(room) },
                    onDetail: { [weak self] in self?.openRoomDetail(room) }
                )
            } else {
                header.configure(title: title, collapsed: isUnassignedCollapsed) { [weak self] in
                    self?.toggleUnassigned()
                }
            }
        case .roomsEmpty, .roomEmpty:
            header.configure(title: L10n.t("room.manage"))
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
        guard case .room(_, let items, _) = sections[indexPath.section], items.indices.contains(indexPath.item) else {
            return nil
        }
        let device = items[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let edit = UIAction(title: L10n.t("home.editAliasGroup"), image: UIImage(systemName: SymbolName.edit)) { _ in
                self.presentEditAlert(for: device)
            }
            let delete = UIAction(title: L10n.t("home.deleteDevice"), image: UIImage(systemName: SymbolName.delete), attributes: .destructive) { _ in
                self.confirmDelete(device)
            }
            let detail = UIAction(title: L10n.t("home.viewDetail"), image: UIImage(systemName: SymbolName.disclosure)) { _ in
                self.openDetail(for: device)
            }
            let move = UIAction(title: L10n.t("room.moveTitle"), image: UIImage(systemName: "square.grid.2x2")) { _ in
                self.presentMoveSheet(for: device)
            }
            return UIMenu(children: [detail, move, edit, delete])
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
