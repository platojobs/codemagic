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
    let notificationService: LocalNotificationServing
    let ruleAlertCoordinator: RuleAlertCoordinator
    let productService: ProductServicing
    let apiConfiguration: APIConfiguration?
    let bluetooth: BluetoothServicing
    let readingsStore: ReadingsStore
    let readingsService: ReadingsAPIServicing
    let readingsIngestor: ReadingsIngestor
    let syncMetadataStore: SyncMetadataStore
    let tokenStore: TokenStoring
    let syncEngine: SyncEngine
    let accountAPI: AccountAPIServicing
    let pairingService: PairingServicing
    let accountExportService: AccountExportService
    let accountDeletionService: AccountDeletionService

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
        let notifications: LocalNotificationServing = UserNotificationService.shared
        notificationService = notifications
        ruleAlertCoordinator = RuleAlertCoordinator(
            settingsStore: settingsStore,
            notifications: notifications
        )

        if let configuration = try? APIConfiguration.fromBundle() {
            apiConfiguration = configuration
            tokenStore = KeychainTokenStore()
            productService = ProductAPIClient(configuration: configuration, tokenStore: tokenStore)
            readingsStore = ReadingsStore(database: resolved.database)
            readingsService = ReadingsAPIClient(configuration: configuration, tokenStore: tokenStore)
            accountAPI = AccountAPIClient(configuration: configuration)
            syncMetadataStore = SyncMetadataStore()
            syncEngine = SyncEngine(
                api: SyncAPIClient(configuration: configuration),
                tokenStore: tokenStore,
                metadataStore: syncMetadataStore,
                deviceStore: savedDeviceStore,
                readingsStore: readingsStore,
                logStore: scanLogStore
            )
        } else {
            apiConfiguration = nil
            productService = UnavailableProductService()
            readingsStore = ReadingsStore(database: resolved.database)
            readingsService = UnavailableReadingsAPI()
            accountAPI = UnavailableAccountAPI()
            syncMetadataStore = SyncMetadataStore()
            tokenStore = KeychainTokenStore()
            syncEngine = SyncEngine(
                api: UnavailableSyncAPI(),
                tokenStore: tokenStore,
                metadataStore: syncMetadataStore,
                deviceStore: savedDeviceStore,
                readingsStore: readingsStore,
                logStore: scanLogStore
            )
            if startupWarning == nil {
                startupWarning = "\(AppError.configuration("").code) BASE_URL 未正确配置，产品与市场数据不可用"
            }
        }

        readingsIngestor = ReadingsIngestor(
            readingsStore: readingsStore,
            deviceStore: savedDeviceStore,
            logStore: scanLogStore
        )
        pairingService = PairingService(
            api: accountAPI,
            tokenStore: tokenStore,
            deviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            metadataStore: syncMetadataStore,
            logStore: scanLogStore
        )
        accountExportService = AccountExportService(api: accountAPI, tokenStore: tokenStore)
        accountDeletionService = AccountDeletionService(
            api: accountAPI,
            tokenStore: tokenStore,
            database: resolved.database,
            metadataStore: syncMetadataStore
        )
        self.bluetooth = bluetooth ?? CoreBluetoothService()
        let ingestor = readingsIngestor
        self.bluetooth.readingHandler = { sample in
            ingestor.ingest(sample)
        }

        // 启动即执行 7 天保留清理；同步成功后引擎会再次清理。
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        try? readingsStore.prune(olderThan: cutoff)
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
