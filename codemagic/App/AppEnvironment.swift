import Foundation

/// 组合根：统一创建数据库、存储、网络与蓝牙服务，界面层只拿到依赖。
final class AppEnvironment {
    static let shared = AppEnvironment()

    // MARK: - Dependencies

    let database: SQLiteDatabase
    let savedDeviceStore: SavedDeviceStore
    let ruleStore: DeviceRuleStore
    let scanLogStore: ScanLogStore
    let recentDeviceStore: RecentDeviceStore
    let deviceInfoCacheStore: DeviceInfoCacheStore
    let settingsStore: SettingsStore
    let productService: ProductServicing
    let apiConfiguration: APIConfiguration?
    let bluetooth: BluetoothServicing

    /// 启动期降级说明，非空时在「我的」页展示。
    private(set) var startupWarning: String?

    // MARK: - Init

    init(
        database: SQLiteDatabase? = nil,
        bluetooth: BluetoothServicing? = nil,
        settingsStore: SettingsStore = SettingsStore()
    ) {
        let resolved: (database: SQLiteDatabase, warning: String?)
        if let database {
            resolved = (database, nil)
        } else {
            resolved = Self.makeDatabase()
        }
        self.database = resolved.database
        self.startupWarning = resolved.warning

        savedDeviceStore = SavedDeviceStore(database: resolved.database)
        ruleStore = DeviceRuleStore(database: resolved.database)
        scanLogStore = ScanLogStore(database: resolved.database)
        recentDeviceStore = RecentDeviceStore(database: resolved.database)
        deviceInfoCacheStore = DeviceInfoCacheStore(database: resolved.database)
        self.settingsStore = settingsStore

        if let configuration = try? APIConfiguration.fromBundle() {
            apiConfiguration = configuration
            productService = ProductAPIClient(configuration: configuration)
        } else {
            apiConfiguration = nil
            productService = UnavailableProductService()
            if startupWarning == nil {
                startupWarning = "\(AppError.configuration("").code) BASE_URL 未正确配置，产品与市场数据不可用"
            }
        }

        self.bluetooth = bluetooth ?? CoreBluetoothService()
    }

    // MARK: - Database

    private static func makeDatabase() -> (database: SQLiteDatabase, warning: String?) {
        do {
            let url = try AppStorageLocation.databaseURL()
            return (try SQLiteDatabase(path: url.path), nil)
        } catch {
            // 磁盘数据库不可用时退回内存库，保证应用仍可打开，但数据不跨启动保留。
            do {
                let memory = try SQLiteDatabase(path: ":memory:")
                return (memory, "\(AppError.database("").code) 本地数据库不可用，本次运行数据不会保存")
            } catch {
                fatalError("SQLite 无法初始化：\(error)")
            }
        }
    }
}

/// 当 BASE_URL 配置失败时使用的空实现，让页面显示配置错误而不是崩溃。
final class UnavailableProductService: ProductServicing {
    func fetchProducts(completion: @escaping (Result<[ProductModel], AppError>) -> Void) {
        completion(.failure(.configuration("BASE_URL 未正确配置")))
    }

    func fetchMarketItems(completion: @escaping (Result<[MarketItem], AppError>) -> Void) {
        completion(.failure(.configuration("BASE_URL 未正确配置")))
    }

    func fetchDeviceInfo(
        peripheralID: UUID,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        completion(.failure(.configuration("BASE_URL 未正确配置")))
    }
}
