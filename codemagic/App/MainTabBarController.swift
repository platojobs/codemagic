import UIKit

/// 五模块入口：首页 / 设备 / 产品 / 市场 / 我的。
/// 命名与顺序与 Android 端 `PKotlinApp` 保持一致。
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
            root: HomeViewController(
                viewModel: HomeViewModel(
                    bluetooth: environment.bluetooth,
                    savedDeviceStore: environment.savedDeviceStore,
                    recentDeviceStore: environment.recentDeviceStore,
                    scanLogStore: environment.scanLogStore,
                    ruleStore: environment.ruleStore,
                    settingsStore: environment.settingsStore,
                    ruleEvaluator: RuleEvaluator()
                )
            ),
            title: "首页",
            imageName: SymbolName.homeTab,
            selectedImageName: SymbolName.homeTabSelected
        )

        let devices = makeNavigationController(
            root: DevicesViewController(
                viewModel: DevicesViewModel(
                    savedDeviceStore: environment.savedDeviceStore,
                    ruleStore: environment.ruleStore
                ),
                environment: environment
            ),
            title: "设备",
            imageName: SymbolName.devicesTab,
            selectedImageName: SymbolName.devicesTab
        )

        let products = makeNavigationController(
            root: ProductsViewController(
                viewModel: ProductsViewModel(productService: environment.productService)
            ),
            title: "产品",
            imageName: SymbolName.productsTab,
            selectedImageName: SymbolName.productsTabSelected
        )

        let market = makeNavigationController(
            root: MarketViewController(
                viewModel: MarketViewModel(productService: environment.productService)
            ),
            title: "市场",
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
                    baseURLText: environment.apiConfiguration?.displayString ?? "未配置",
                    startupWarning: environment.startupWarning
                ),
                scanLogStore: environment.scanLogStore
            ),
            title: "我的",
            imageName: SymbolName.profileTab,
            selectedImageName: SymbolName.profileTabSelected
        )

        viewControllers = [home, devices, products, market, profile]
    }

    private func makeNavigationController(
        root: UIViewController,
        title: String,
        imageName: String,
        selectedImageName: String
    ) -> UINavigationController {
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.navigationBar.prefersLargeTitles = true
        navigationController.tabBarItem = UITabBarItem(
            title: title,
            image: UIImage(systemName: imageName),
            selectedImage: UIImage(systemName: selectedImageName)
        )
        return navigationController
    }
}
