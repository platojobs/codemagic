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
    let feedbackStore: FeedbackStore
    let feedbackCoordinator: FeedbackCoordinator
    let settingsStore: SettingsStore
    let notificationService: LocalNotificationServing
    let ruleAlertCoordinator: RuleAlertCoordinator
    let productService: ProductServicing
    /// 服务端设备类型目录：数据库缓存 + 条件请求；配置缺失时为 nil。
    let deviceCatalogService: DeviceCatalogServicing?
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
    let scenarioStore: ScenarioStore
    let scenarioExecutor: ScenarioExecutor
    /// 服务端场景：本地存储、同步、执行与定时调度。
    let sceneStore: SceneStore
    let sceneSyncService: SceneSyncServicing
    let sceneEngine: SceneEngine
    let sceneScheduler: SceneScheduler
    /// 房间：接入家庭后以服务端为准；离线 / 未同步时保留本机数据。
    let roomStore: RoomStore
    let householdStore: HouseholdStore
    let pendingAssignmentStore: DeviceAssignmentPendingStore
    let householdAPI: HouseholdAPIServicing
    /// 家庭 / 邀请码 / 房间 / 设备归属业务协调器。
    let householdService: HouseholdService

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
        LaunchMetrics.mark("database-ready")

        savedDeviceStore = SavedDeviceStore(database: resolved.database)
        ruleStore = DeviceRuleStore(database: resolved.database)
        scanLogStore = ScanLogStore(database: resolved.database)
        recentDeviceStore = RecentDeviceStore(database: resolved.database)
        deviceInfoCacheStore = DeviceInfoCacheStore(database: resolved.database)
        feedbackStore = FeedbackStore(database: resolved.database)
        roomStore = RoomStore(database: resolved.database)
        householdStore = HouseholdStore(database: resolved.database)
        pendingAssignmentStore = DeviceAssignmentPendingStore(database: resolved.database)
        sceneStore = SceneStore(database: resolved.database)
        self.settingsStore = settingsStore
        let notifications: LocalNotificationServing = UserNotificationService.shared
        notificationService = notifications
        ruleAlertCoordinator = RuleAlertCoordinator(
            settingsStore: settingsStore,
            notifications: notifications
        )

        if let configuration = try? APIConfiguration.fromBundle() {
            apiConfiguration = configuration
            let sessionTokenStore = KeychainTokenStore()
            tokenStore = sessionTokenStore
            feedbackCoordinator = FeedbackCoordinator(
                store: feedbackStore,
                client: FeedbackAPIClient(
                    configuration: configuration,
                    httpClient: URLSessionHTTPClient(),
                    tokenStore: sessionTokenStore
                )
            )
            let catalogService = DeviceCatalogClient(
                configuration: configuration,
                httpClient: URLSessionHTTPClient(),
                cache: DeviceCatalogStore(database: resolved.database)
            )
            deviceCatalogService = catalogService
            productService = ProductAPIClient(
                configuration: configuration,
                tokenStore: sessionTokenStore,
                catalogService: catalogService
            )
            readingsStore = ReadingsStore(database: resolved.database)
            readingsService = ReadingsAPIClient(configuration: configuration, tokenStore: sessionTokenStore)
            accountAPI = AccountAPIClient(configuration: configuration)
            let metadata = SyncMetadataStore()
            syncMetadataStore = metadata
            let householdClient = HouseholdAPIClient(configuration: configuration)
            householdAPI = householdClient
            let coordinator = HouseholdService(
                api: householdClient,
                tokenStore: sessionTokenStore,
                householdStore: householdStore,
                roomStore: roomStore,
                deviceStore: savedDeviceStore,
                pendingStore: pendingAssignmentStore,
                metadataStore: metadata,
                logStore: scanLogStore
            )
            householdService = coordinator
            let sceneSync = SceneSyncService(
                api: SceneAPIClient(configuration: configuration),
                store: sceneStore,
                logStore: scanLogStore
            )
            sceneSyncService = sceneSync
            syncEngine = SyncEngine(
                api: SyncAPIClient(configuration: configuration),
                tokenStore: sessionTokenStore,
                metadataStore: metadata,
                deviceStore: savedDeviceStore,
                readingsStore: readingsStore,
                logStore: scanLogStore,
                householdService: coordinator,
                sceneSync: sceneSync
            )
        } else {
            apiConfiguration = nil
            deviceCatalogService = nil
            feedbackCoordinator = FeedbackCoordinator(
                store: feedbackStore,
                client: UnavailableFeedbackService()
            )
            productService = UnavailableProductService()
            readingsStore = ReadingsStore(database: resolved.database)
            readingsService = UnavailableReadingsAPI()
            accountAPI = UnavailableAccountAPI()
            let metadata = SyncMetadataStore()
            syncMetadataStore = metadata
            let sessionTokenStore = KeychainTokenStore()
            tokenStore = sessionTokenStore
            let householdClient = UnavailableHouseholdAPI()
            householdAPI = householdClient
            let coordinator = HouseholdService(
                api: householdClient,
                tokenStore: sessionTokenStore,
                householdStore: householdStore,
                roomStore: roomStore,
                deviceStore: savedDeviceStore,
                pendingStore: pendingAssignmentStore,
                metadataStore: metadata,
                logStore: scanLogStore
            )
            householdService = coordinator
            let sceneSync = SceneSyncService(
                api: UnavailableSceneAPI(),
                store: sceneStore,
                logStore: scanLogStore
            )
            sceneSyncService = sceneSync
            syncEngine = SyncEngine(
                api: UnavailableSyncAPI(),
                tokenStore: sessionTokenStore,
                metadataStore: metadata,
                deviceStore: savedDeviceStore,
                readingsStore: readingsStore,
                logStore: scanLogStore,
                householdService: coordinator,
                sceneSync: sceneSync
            )
            if startupWarning == nil {
                startupWarning = L10n.f("app.env.productsUnavailable", AppError.configuration("").code)
            }
        }

        sceneEngine = SceneEngine(
            store: sceneStore,
            deviceStore: savedDeviceStore,
            logStore: scanLogStore,
            notifications: UserNotificationService.shared,
            now: { Date() }
        )
        sceneScheduler = SceneScheduler(notifications: UserNotificationService.shared)

        readingsIngestor = ReadingsIngestor(
            readingsStore: readingsStore,
            deviceStore: savedDeviceStore,
            logStore: scanLogStore,
            ruleStore: ruleStore,
            ruleEvaluator: RuleEvaluator(),
            ruleAlertCoordinator: ruleAlertCoordinator,
            sceneEngine: sceneEngine
        )
        pairingService = PairingService(
            api: accountAPI,
            tokenStore: tokenStore,
            deviceStore: savedDeviceStore,
            readingsStore: readingsStore,
            metadataStore: syncMetadataStore,
            logStore: scanLogStore
        )
        let exportService = AccountExportService(api: accountAPI, tokenStore: tokenStore)
        accountExportService = exportService
        let resolvedBluetooth = bluetooth ?? CoreBluetoothService()
        accountDeletionService = AccountDeletionService(
            api: accountAPI,
            tokenStore: tokenStore,
            database: resolved.database,
            metadataStore: syncMetadataStore,
            disconnectBluetooth: { [weak resolvedBluetooth] in
                resolvedBluetooth?.disconnectAll()
            },
            additionalCleanup: { [weak exportService] in
                // 注销后不保留任何本地导出文件。
                exportService?.removeAllExportedFiles()
            }
        )
        self.bluetooth = resolvedBluetooth
        let ingestor = readingsIngestor
        self.bluetooth.readingHandler = { sample in
            ingestor.ingest(sample)
        }

        scenarioStore = ScenarioStore(database: resolved.database)
        let engine = syncEngine
        scenarioExecutor = ScenarioExecutor(
            dependencies: ScenarioExecutor.Dependencies(
                bluetooth: self.bluetooth,
                savedDeviceStore: savedDeviceStore,
                settingsStore: settingsStore,
                alertCoordinator: ruleAlertCoordinator,
                syncAction: { completion in
                    engine.sync { result in
                        switch result {
                        case .success(let summary):
                            completion(.success(L10n.f("sync.summary.completed", String(describing: summary.pushed), String(describing: summary.pulled))))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                },
                now: { Date() }
            )
        )

        LaunchMetrics.mark("environment-init")

        sceneSyncService.onScenesChanged = { [weak self] in
            guard let self else { return }
            let scenes = (try? self.sceneStore.fetchAll()) ?? []
            self.sceneScheduler.reschedule(scenes: scenes)
        }
        // 启动时按本地场景重建定时通知；网络同步完成后会再次触发。
        let initialScenes = (try? sceneStore.fetchAll()) ?? []
        sceneScheduler.reschedule(scenes: initialScenes)

        // 7 天保留清理与首帧无关，放到后台队列，避免占用启动时的主线程。
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let store = readingsStore
        DispatchQueue.global(qos: .utility).async {
            _ = try? store.prune(olderThan: cutoff)
        }
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
                return (memory, L10n.f("app.env.databaseUnavailable", AppError.database("").code))
            } catch {
                fatalError(L10n.f("app.env.sqliteInitFailed", String(describing: error)))
            }
        }
    }
}

/// 当 BASE_URL 配置失败时使用的空实现，让页面显示配置错误而不是崩溃。
final class UnavailableFeedbackService: FeedbackServicing {
    func submit(
        draft: FeedbackDraft,
        context: FeedbackClientContext,
        diagnostics: String?,
        completion: @escaping (Result<FeedbackReceipt, FeedbackSendFailure>) -> Void
    ) {
        completion(.failure(FeedbackSendFailure(
            message: L10n.t("app.env.baseUrlMissing"),
            isRateLimited: false,
            retryAfter: nil,
            isRetryable: false,
            isConflict: false,
            apiCode: nil
        )))
    }

    func fetchMine(
        cursor: String?,
        limit: Int,
        completion: @escaping (Result<FeedbackPage, AppError>) -> Void
    ) {
        completion(.failure(.configuration(L10n.t("app.env.baseUrlMissing"))))
    }
}

/// 当 BASE_URL 配置失败时使用的空实现，让页面显示配置错误而不是崩溃。
final class UnavailableProductService: ProductServicing {
    func fetchProducts(completion: @escaping (Result<[ProductModel], AppError>) -> Void) {
        completion(.failure(.configuration(L10n.t("app.env.baseUrlMissing"))))
    }

    func fetchMarketItems(completion: @escaping (Result<[MarketItem], AppError>) -> Void) {
        completion(.failure(.configuration(L10n.t("app.env.baseUrlMissing"))))
    }

    func fetchDeviceInfo(
        peripheralID: UUID,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        completion(.failure(.configuration(L10n.t("app.env.baseUrlMissing"))))
    }
}
