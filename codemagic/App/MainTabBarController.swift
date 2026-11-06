import UIKit

/// 五模块入口：首页 / 智能 / 产品 / 市场 / 我的。
/// 首页承接原「设备」页的设备管理；规则入口只保留在「智能」页。
final class MainTabBarController: UITabBarController {
    private let environment: AppEnvironment
    /// iOS 26 悬浮玻璃胶囊只遮住自身，胶囊下方与两侧会透出滚动内容；
    /// 这一层铺在 Tab 顶边到屏幕底边之间，保证条带内不会出现被切断的文字或按钮。
    private let bottomBand = UIView()

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureTabs()
        configureBottomBand()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccountDeleted),
            name: .accountDeleted,
            object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutBottomBand()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 账号删除后重建五个 Tab，丢弃所有内存中的旧设备 / 读数视图模型，停在「我的」未登录态。
    @objc private func handleAccountDeleted() {
        configureTabs()
        selectedIndex = 4
        guard let navigation = viewControllers?[4] as? UINavigationController else { return }
        navigation.popToRootViewController(animated: false)
    }

    private func configureTabs() {
        let home = makeNavigationController(
            root: HomeDashboardViewController(
                viewModel: HomeDashboardViewModel(
                    bluetooth: environment.bluetooth,
                    savedDeviceStore: environment.savedDeviceStore,
                    recentDeviceStore: environment.recentDeviceStore,
                    settingsStore: environment.settingsStore,
                    scanLogStore: environment.scanLogStore,
                    readingsStore: environment.readingsStore,
                    scenarioStore: environment.scenarioStore,
                    roomStore: environment.roomStore,
                    executor: environment.scenarioExecutor,
                    householdService: environment.householdService
                ),
                environment: environment
            ),
            title: L10n.t("tab.home"),
            imageName: SymbolName.homeTab,
            selectedImageName: SymbolName.homeTabSelected
        )

        let smart = makeNavigationController(
            root: SmartViewController(
                viewModel: SmartViewModel(
                    ruleStore: environment.ruleStore,
                    savedDeviceStore: environment.savedDeviceStore,
                    scanLogStore: environment.scanLogStore,
                    scenarioStore: environment.scenarioStore,
                    sceneStore: environment.sceneStore,
                    sceneScheduler: environment.sceneScheduler,
                    executor: environment.scenarioExecutor,
                    requestSync: { [weak environment] in
                        environment?.syncEngine.sync(completion: nil)
                    }
                ),
                environment: environment
            ),
            title: L10n.t("tab.smart"),
            imageName: SymbolName.smartTab,
            selectedImageName: SymbolName.smartTab
        )

        let products = makeNavigationController(
            root: ProductsViewController(
                viewModel: ProductsViewModel(productService: environment.productService),
                savedDeviceStore: environment.savedDeviceStore
            ),
            title: L10n.t("tab.products"),
            imageName: SymbolName.productsTab,
            selectedImageName: SymbolName.productsTabSelected
        )

        let market = makeNavigationController(
            root: MarketViewController(
                viewModel: MarketViewModel(productService: environment.productService)
            ),
            title: L10n.t("tab.market"),
            imageName: SymbolName.marketTab,
            selectedImageName: SymbolName.marketTabSelected
        )

        let profile = makeNavigationController(
            root: ProfileViewController(
                viewModel: ProfileViewModel(
                    bluetooth: environment.bluetooth,
                    scanLogStore: environment.scanLogStore,
                    settingsStore: environment.settingsStore,
                    syncEngine: environment.syncEngine,
                    pairingService: environment.pairingService,
                    accountExportService: environment.accountExportService,
                    accountDeletionService: environment.accountDeletionService,
                    baseURLText: environment.apiConfiguration?.displayString ?? L10n.t("tab.unconfigured"),
                    startupWarning: environment.startupWarning,
                    notifications: environment.notificationService,
                    householdService: environment.householdService,
                    sessionManager: environment.sessionManager
                ),
                scanLogStore: environment.scanLogStore,
                roomStore: environment.roomStore,
                savedDeviceStore: environment.savedDeviceStore,
                householdService: environment.householdService,
                feedbackCoordinator: environment.feedbackCoordinator
            ),
            title: L10n.t("tab.profile"),
            imageName: SymbolName.profileTab,
            selectedImageName: SymbolName.profileTabSelected
        )

        viewControllers = [home, smart, products, market, profile]
        configureBarAppearance()
    }

    /// 通知点击路由：切到首页并打开对应设备详情。
    func openDeviceDetail(deviceID: UUID) {
        selectedIndex = 0
        guard let navigation = viewControllers?[0] as? UINavigationController,
              let home = navigation.viewControllers.first as? HomeDashboardViewController
        else { return }
        navigation.popToRootViewController(animated: false)
        home.openDeviceDetail(deviceID: deviceID)
    }

    /// 市场页「配对向导」：切到首页并打开扫描页。
    func openHomeScanner() {
        selectedIndex = 0
        guard let navigation = viewControllers?[0] as? UINavigationController,
              let home = navigation.viewControllers.first as? HomeDashboardViewController
        else { return }
        navigation.popToRootViewController(animated: false)
        home.startPairingWizard()
    }

    /// 市场页「采集省电建议」：切到「我的 → 设置」，定位到后台采集开关。
    func openProfileBackgroundSettings() {
        selectedIndex = 4
        guard let navigation = viewControllers?[4] as? UINavigationController,
              let profile = navigation.viewControllers.first as? ProfileViewController
        else { return }
        navigation.popToRootViewController(animated: false)
        profile.revealBackgroundCollectionSetting()
    }

    private func configureBottomBand() {
        // 与 Tab 的不透明外观同色，玻璃胶囊透出的仍是画布色，不与页面割裂。
        bottomBand.backgroundColor = Palette.canvas
        bottomBand.isAccessibilityElement = false
        bottomBand.accessibilityIdentifier = "main.bottomBand"
        // 条带本身拦截点按，避免被遮住的内容还能被误触。
        insertBottomBandBelowTabBar()
    }

    /// 把条带插到 Tab 的父视图里、紧贴 Tab 之下：iOS 26 的 Tab 可能包在私有容器中，
    /// 直接插到 TabBarController 的 view 上会被容器盖住（表现为 Tab 胶囊消失）。
    private func insertBottomBandBelowTabBar() {
        guard let host = tabBar.superview else { return }
        host.insertSubview(bottomBand, belowSubview: tabBar)
    }

    /// 条带跟随 Tab 顶边：胶囊以下到屏幕底（含 home indicator 安全区）全部不透明。
    /// Tab 被隐藏（如未来某页使用 `hidesBottomBarWhenPushed`）时同步隐藏，避免整条盖住内容。
    private func layoutBottomBand() {
        let barVisible = !tabBar.isHidden && tabBar.alpha > 0
        bottomBand.isHidden = !barVisible
        guard barVisible, let host = tabBar.superview else { return }
        bottomBand.frame = BottomBand.frame(containerSize: host.bounds.size, barTop: tabBar.frame.minY)
        // Tab 容器可能在布局阶段被重排或重建，每次布局都重新贴到 Tab 之下，保证层次稳定。
        insertBottomBandBelowTabBar()
    }

    private func configureBarAppearance() {
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = Palette.canvas
        tabAppearance.shadowColor = Palette.divider
        tabBar.standardAppearance = tabAppearance
        tabBar.scrollEdgeAppearance = tabAppearance
        tabBar.tintColor = Palette.primaryText
        tabBar.unselectedItemTintColor = Palette.textTertiary

        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithTransparentBackground()
        navigationAppearance.backgroundColor = Palette.canvas
        navigationAppearance.shadowColor = .clear
        navigationAppearance.titleTextAttributes = [
            .foregroundColor: Palette.textPrimary,
            .font: AppText.callout.font(weight: .semibold),
        ]
        navigationAppearance.largeTitleTextAttributes = [
            .foregroundColor: Palette.textPrimary,
            .font: AppText.display.font(),
        ]
        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
    }

    private func makeNavigationController(
        root: UIViewController,
        title: String,
        imageName: String,
        selectedImageName: String
    ) -> UINavigationController {
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.navigationBar.prefersLargeTitles = false
        navigationController.tabBarItem = UITabBarItem(
            title: title,
            image: UIImage(systemName: imageName),
            selectedImage: UIImage(systemName: selectedImageName)
        )
        return navigationController
    }
}
