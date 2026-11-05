import UIKit

/// 五模块入口：首页 / 智能 / 产品 / 市场 / 我的。
/// 首页承接原「设备」页的设备管理；规则入口只保留在「智能」页。
final class MainTabBarController: UITabBarController {
    private let environment: AppEnvironment

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
                    executor: environment.scenarioExecutor
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
                    executor: environment.scenarioExecutor
                ),
                environment: environment
            ),
            title: L10n.t("tab.smart"),
            imageName: SymbolName.smartTab,
            selectedImageName: SymbolName.smartTab
        )

        let products = makeNavigationController(
            root: ProductsViewController(
                viewModel: ProductsViewModel(productService: environment.productService)
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
                    notifications: environment.notificationService
                ),
                scanLogStore: environment.scanLogStore
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
