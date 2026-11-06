import Foundation

/// 一次 catalog 遍历同时得到型号与配件/固件，供市场页复用，避免重复请求。
struct ProductCatalogSnapshot: Equatable {
    let products: [ProductModel]
    let marketItems: [MarketItem]
    /// 配件/固件部分失败时不为空；型号仍可用于兼容性查询。
    let marketItemsError: AppError?
    /// 目录来源与更新时间；nil 表示使用没有目录元数据的降级实现（如测试桩）。
    let catalogInfo: DeviceCatalogSnapshot?
}

/// 产品库 / 市场 / 设备信息的数据源协议。
protocol ProductServicing {
    func fetchProducts(completion: @escaping (Result<[ProductModel], AppError>) -> Void)
    func fetchMarketItems(completion: @escaping (Result<[MarketItem], AppError>) -> Void)
    func fetchDeviceInfo(
        peripheralID: UUID,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    )
    /// 按设备平台选择单设备详情端点：Android 记录没有 iOS 外设标识，按 MAC 查询；
    /// iOS 记录走 `ios/{externalId}`。默认实现退化为按 peripheralID 查询。
    func fetchDeviceInfo(
        device: SavedDevice,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    )
    /// 一次取回型号与市场条目；真实客户端保证只遍历一遍目录。
    func fetchCatalogSnapshot(
        completion: @escaping (Result<ProductCatalogSnapshot, AppError>) -> Void
    )
    /// 首屏先渲染的本地目录缓存；没有缓存返回 nil。
    func cachedCatalogSnapshot() -> ProductCatalogSnapshot?
}

extension ProductServicing {
    func cachedCatalogSnapshot() -> ProductCatalogSnapshot? { nil }

    func fetchDeviceInfo(
        device: SavedDevice,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        fetchDeviceInfo(peripheralID: device.peripheralID, completion: completion)
    }

    /// 默认实现分两次取；真实客户端覆盖为单次遍历。
    /// 型号是兼容性查询的核心，型号失败才整体失败；配件/固件失败只降级为错误提示。
    func fetchCatalogSnapshot(
        completion: @escaping (Result<ProductCatalogSnapshot, AppError>) -> Void
    ) {
        fetchProducts { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let products):
                self.fetchMarketItems { marketResult in
                    switch marketResult {
                    case .success(let items):
                        completion(.success(ProductCatalogSnapshot(
                            products: products,
                            marketItems: items,
                            marketItemsError: nil,
                            catalogInfo: nil
                        )))
                    case .failure(let error):
                        completion(.success(ProductCatalogSnapshot(
                            products: products,
                            marketItems: [],
                            marketItemsError: error,
                            catalogInfo: nil
                        )))
                    }
                }
            }
        }
    }
}

/// 基于 URLSession + Codable 的实现，对齐 `PJGoIoT/api/openapi.yaml` v0.3.5（契约 0.14.0）：
/// - `GET /api/v1/catalog/device-types` → 设备类型目录（类型 / GATT / 指标 / 限制 / 兼容性）
/// - `GET /api/v1/device-types/{type}/catalog` → 单型号固件 + 配件
/// - `GET /api/v1/my/devices/ios/{externalId}` → 当前用户的单台 iOS 设备记录
///
/// 类型清单与能力信息只认目录接口；逐型号 catalog 仅补充固件 / 配件，不参与
/// 类型、GATT、指标、限制、兼容性的判定，避免两份互相竞争的真值。
final class ProductAPIClient: ProductServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let tokenStore: TokenStoring?
    private let catalogService: DeviceCatalogServicing
    private let decoder = JSONDecoder()

    init(
        configuration: APIConfiguration,
        httpClient: HTTPClient = URLSessionHTTPClient(),
        tokenStore: TokenStoring? = nil,
        catalogService: DeviceCatalogServicing? = nil
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.tokenStore = tokenStore
        self.catalogService = catalogService ?? DeviceCatalogClient(
            configuration: configuration,
            httpClient: httpClient
        )
    }

    // MARK: - Products / Market

    func fetchProducts(completion: @escaping (Result<[ProductModel], AppError>) -> Void) {
        loadCatalogs { result in
            switch result {
            case .success(let snapshot):
                completion(.success(self.products(from: snapshot)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func fetchMarketItems(completion: @escaping (Result<[MarketItem], AppError>) -> Void) {
        loadCatalogs { result in
            switch result {
            case .success(let snapshot):
                let items = self.marketItems(from: snapshot.pairs)
                if items.isEmpty, let error = snapshot.catalogError {
                    completion(.failure(error))
                } else {
                    completion(.success(items))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 单次 catalog 遍历同时产出型号与配件/固件，市场页不再重复请求。
    func fetchCatalogSnapshot(
        completion: @escaping (Result<ProductCatalogSnapshot, AppError>) -> Void
    ) {
        loadCatalogs { result in
            switch result {
            case .success(let snapshot):
                let items = self.marketItems(from: snapshot.pairs)
                completion(.success(ProductCatalogSnapshot(
                    products: self.products(from: snapshot),
                    marketItems: items,
                    marketItemsError: items.isEmpty ? snapshot.catalogError : nil,
                    catalogInfo: snapshot.catalogInfo
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func cachedCatalogSnapshot() -> ProductCatalogSnapshot? {
        guard let info = catalogService.cachedSnapshot() else { return nil }
        return ProductCatalogSnapshot(
            products: info.catalog.items.map { product(from: $0, catalog: nil) },
            marketItems: [],
            marketItemsError: nil,
            catalogInfo: info
        )
    }

    // MARK: - Device info

    func fetchDeviceInfo(
        peripheralID: UUID,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        fetchDeviceInfo(
            path: "api/v1/my/devices/ios/\(peripheralID.uuidString.uppercased())",
            completion: completion
        )
    }

    /// 单设备详情：Android 记录按契约用 `GET /my/devices/{mac}`（同用户同 MAC 取 updatedAt 最新一条）；
    /// iOS 记录仍走平台 + externalId，避免退化成扫描全量列表。
    func fetchDeviceInfo(
        device: SavedDevice,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        let platform = device.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if platform == "android", !device.externalID.isEmpty {
            fetchDeviceInfo(path: "api/v1/my/devices/\(device.externalID)", completion: completion)
        } else {
            fetchDeviceInfo(
                path: "api/v1/my/devices/ios/\(device.peripheralID.uuidString.uppercased())",
                completion: completion
            )
        }
    }

    private func fetchDeviceInfo(
        path: String,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        guard let session = tokenStore?.load(), !session.token.isEmpty else {
            completion(.failure(.sync(L10n.t("product.noSession"))))
            return
        }
        let request = HTTPRequest(
            url: endpoint(path),
            headers: ["Authorization": "Bearer \(session.token)"]
        )

        send(request, as: UserDeviceInfo.self) { result in
            switch result {
            case .success(let record):
                completion(.success(self.product(from: record)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Catalog loading

    private struct CatalogPair {
        let type: DeviceTypeCatalogItem
        let catalog: DeviceCatalog?
    }

    private struct CatalogLoadResult {
        let pairs: [CatalogPair]
        let catalogInfo: DeviceCatalogSnapshot
        /// 逐型号 catalog（固件 / 配件）部分失败时的最后一个错误。
        let catalogError: AppError?
    }

    /// 先取服务端目录（带条件请求与缓存兜底），再逐个取固件 / 配件。
    /// 单个逐型号 catalog 失败只降级为「无固件 / 无配件」，目录本身仍可展示。
    private func loadCatalogs(completion: @escaping (Result<CatalogLoadResult, AppError>) -> Void) {
        catalogService.refresh { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let info):
                guard !info.catalog.items.isEmpty else {
                    completion(.success(CatalogLoadResult(
                        pairs: [],
                        catalogInfo: info,
                        catalogError: nil
                    )))
                    return
                }
                self.fetchCatalogs(for: info.catalog.items) { pairs, lastError in
                    completion(.success(CatalogLoadResult(
                        pairs: pairs,
                        catalogInfo: info,
                        catalogError: lastError
                    )))
                }
            }
        }
    }

    private func fetchCatalogs(
        for types: [DeviceTypeCatalogItem],
        completion: @escaping (_ pairs: [CatalogPair], _ lastError: AppError?) -> Void
    ) {
        var pairs: [CatalogPair] = []
        var lastError: AppError?
        var index = 0

        func next() {
            guard index < types.count else {
                completion(pairs, lastError)
                return
            }
            let type = types[index]
            index += 1
            self.fetchCatalog(type.type) { result in
                switch result {
                case .success(let catalog):
                    pairs.append(CatalogPair(type: type, catalog: catalog))
                case .failure(let error):
                    lastError = error
                    pairs.append(CatalogPair(type: type, catalog: nil))
                }
                next()
            }
        }

        next()
    }

    private func fetchCatalog(
        _ type: String,
        completion: @escaping (Result<DeviceCatalog, AppError>) -> Void
    ) {
        guard !type.isEmpty else {
            completion(.failure(.decoding(L10n.t("product.modelMissingType"))))
            return
        }
        let encodedType = type.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? type
        let url = endpoint("api/v1/device-types/\(encodedType)/catalog")
        send(url, as: DeviceCatalog.self, completion: completion)
    }

    // MARK: - Mapping

    private func products(from snapshot: CatalogLoadResult) -> [ProductModel] {
        snapshot.pairs.map { product(from: $0.type, catalog: $0.catalog) }
    }

    private func product(from type: DeviceTypeCatalogItem, catalog: DeviceCatalog?) -> ProductModel {
        let firmware = catalog?.firmwares.first?.version ?? ""
        let noteParts = [
            type.descriptionText,
            catalog?.accessories.isEmpty == false ? L10n.f("product.accessoryCount", String(describing: catalog?.accessories.count ?? 0)) : "",
        ]
        return ProductModel(
            mac: "",
            // 目录不提供厂商字段；逐型号 catalog 有则展示，没有保持空串，不编造。
            vendor: catalog?.deviceType.vendor ?? "",
            deviceType: type.resolvedDisplayName,
            firmwareVersion: firmware,
            gattServices: type.gattServices,
            compatibility: type.compatibility?.displayItems ?? [],
            note: noteParts.filter { !$0.isEmpty }.joined(separator: L10n.t("common.semicolonSeparator")),
            apiIdentifier: type.type,
            typeIdentifier: type.type,
            catalogMetrics: type.metrics,
            catalogLimitations: type.limitations
        )
    }

    private func product(from record: UserDeviceInfo) -> ProductModel {
        ProductModel(
            mac: record.mac,
            vendor: record.vendor ?? "",
            deviceType: record.deviceType ?? "",
            firmwareVersion: record.firmwareVersion ?? "",
            gattServices: [],
            compatibility: record.compatibility?.displayItems ?? [],
            note: recordNote(record),
            apiIdentifier: record.id
        )
    }

    private func recordNote(_ record: UserDeviceInfo) -> String {
        var parts = [L10n.f("product.cloudRecord", String(describing: record.platform))]
        if !record.alias.isEmpty { parts.append(L10n.f("product.alias", String(describing: record.alias))) }
        if let advertised = record.advertisedName, !advertised.isEmpty {
            parts.append(L10n.f("product.advertisedName", String(describing: advertised)))
        }
        if !record.group.isEmpty { parts.append(L10n.f("product.group", String(describing: record.group))) }
        parts.append(L10n.f("product.externalID", record.externalID))
        if record.updatedAt.timeIntervalSince1970 > 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "yMMMdjm", options: 0, locale: Locale.current)
            parts.append(L10n.f("product.updatedAt", String(describing: formatter.string(from: record.updatedAt))))
        }
        return parts.joined(separator: " · ")
    }

    private func marketItems(from pairs: [CatalogPair]) -> [MarketItem] {
        pairs.flatMap { pair -> [MarketItem] in
            var items: [MarketItem] = []
            for firmware in pair.catalog?.firmwares ?? [] {
                items.append(MarketItem(
                    id: firmware.id,
                    kind: .firmware,
                    name: firmware.version.isEmpty ? L10n.t("product.firmwareUnnamed") : L10n.f("product.firmwareVersion", String(describing: firmware.version)),
                    // 未核实发布方时保留空串，不回退成型号厂商，避免编造。
                    vendor: firmware.vendor,
                    version: firmware.version,
                    compatibility: firmware.compatibility?.displayItems.joined(separator: L10n.t("common.semicolonSeparator")) ?? "",
                    compatibilityTags: firmware.compatibility?.filterTags ?? [],
                    summary: firmware.releaseNotes
                ))
            }
            for accessory in pair.catalog?.accessories ?? [] {
                items.append(MarketItem(
                    id: accessory.id,
                    kind: .accessory,
                    name: accessory.name,
                    vendor: accessory.vendor,
                    version: accessory.sku,
                    compatibility: accessory.compatibility?.displayItems.joined(separator: L10n.t("common.semicolonSeparator")) ?? "",
                    compatibilityTags: accessory.compatibility?.filterTags ?? [],
                    summary: accessory.descriptionText
                ))
            }
            return items
        }
    }

    // MARK: - HTTP

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }

    private func send<T: Decodable>(
        _ url: URL,
        as type: T.Type,
        completion: @escaping (Result<T, AppError>) -> Void
    ) {
        send(HTTPRequest(url: url), as: type, completion: completion)
    }

    private func send<T: Decodable>(
        _ request: HTTPRequest,
        as type: T.Type,
        completion: @escaping (Result<T, AppError>) -> Void
    ) {
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            let output: Result<T, AppError>
            switch result {
            case .success(let response):
                guard response.isSuccess else {
                    output = .failure(self.mapError(response))
                    DispatchQueue.main.async { completion(output) }
                    return
                }
                do {
                    output = .success(try self.decoder.decode(T.self, from: response.data))
                } catch {
                    output = .failure(.decoding(error.localizedDescription))
                }
            case .failure(let error):
                output = .failure(error)
            }
            DispatchQueue.main.async { completion(output) }
        }
    }

    private func mapError(_ response: HTTPResponse) -> AppError {
        if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: response.data) {
            return .api(
                code: envelope.error.code,
                statusCode: response.statusCode,
                message: envelope.error.message
            )
        }
        return .server(statusCode: response.statusCode)
    }

    private struct APIErrorEnvelope: Decodable {
        let error: Body

        struct Body: Decodable {
            let code: String
            let message: String
        }
    }
}
