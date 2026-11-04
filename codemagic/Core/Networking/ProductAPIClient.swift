import Foundation

/// 产品库 / 市场 / 设备信息的数据源协议。
protocol ProductServicing {
    func fetchProducts(completion: @escaping (Result<[ProductModel], AppError>) -> Void)
    func fetchMarketItems(completion: @escaping (Result<[MarketItem], AppError>) -> Void)
    func fetchDeviceInfo(
        peripheralID: UUID,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    )
}

/// 基于 URLSession + Codable 的实现，对齐 `PJGoIoT/api/openapi.yaml` v0.3.1：
/// - `GET /api/v1/device-types` → 型号列表（`{items:[...]}`）
/// - `GET /api/v1/device-types/{type}/catalog` → 型号元数据 + 固件 + 配件
/// - `GET /api/v1/my/devices/ios/{externalId}` → 当前用户的单台 iOS 设备记录
///
/// 产品 / 市场的固件与配件均来自 catalog，不再调用历史 `api/products` / `api/market`
/// 或按 MAC 拼接多个端点。iOS 详情使用复合键路径，避免依赖无法获取的蓝牙 MAC。
final class ProductAPIClient: ProductServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let tokenStore: TokenStoring?
    private let decoder = JSONDecoder()

    init(
        configuration: APIConfiguration,
        httpClient: HTTPClient = URLSessionHTTPClient(),
        tokenStore: TokenStoring? = nil
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    // MARK: - Products / Market

    func fetchProducts(completion: @escaping (Result<[ProductModel], AppError>) -> Void) {
        loadCatalogs { result in
            switch result {
            case .success(let pairs):
                completion(.success(pairs.map { self.product(from: $0.type, catalog: $0.catalog) }))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func fetchMarketItems(completion: @escaping (Result<[MarketItem], AppError>) -> Void) {
        loadCatalogs { result in
            switch result {
            case .success(let pairs):
                completion(.success(self.marketItems(from: pairs)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Device info

    func fetchDeviceInfo(
        peripheralID: UUID,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        guard let session = tokenStore?.load(), !session.token.isEmpty else {
            completion(.failure(.sync("尚未创建匿名会话，无法读取云端设备记录；请先在「我的」执行同步")))
            return
        }
        let externalID = peripheralID.uuidString.uppercased()
        let url = endpoint("api/v1/my/devices/ios/\(externalID)")
        let request = HTTPRequest(url: url, headers: ["Authorization": "Bearer \(session.token)"])

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
        let type: DeviceTypeInfo
        let catalog: DeviceCatalog?
    }

    /// 先取型号列表，再逐个取 catalog；单个 catalog 失败时降级为仅有型号元数据，
    /// 只有全部失败才整体报错，避免一个坏型号导致产品 / 市场空白。
    private func loadCatalogs(completion: @escaping (Result<[CatalogPair], AppError>) -> Void) {
        fetchDeviceTypes { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let types):
                guard !types.isEmpty else {
                    completion(.success([]))
                    return
                }
                self.fetchCatalogs(for: types, completion: completion)
            }
        }
    }

    private func fetchCatalogs(
        for types: [DeviceTypeInfo],
        completion: @escaping (Result<[CatalogPair], AppError>) -> Void
    ) {
        var pairs: [CatalogPair] = []
        var lastError: AppError?
        var index = 0

        func next() {
            guard index < types.count else {
                if pairs.isEmpty, let lastError {
                    completion(.failure(lastError))
                } else {
                    completion(.success(pairs))
                }
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

    private func fetchDeviceTypes(completion: @escaping (Result<[DeviceTypeInfo], AppError>) -> Void) {
        let url = endpoint("api/v1/device-types")
        send(url, as: DeviceTypeListEnvelope.self) { result in
            switch result {
            case .success(let envelope):
                completion(.success(envelope.items))
            case .failure(.decoding):
                // 兼容直接返回数组的后端。
                self.send(url, as: [DeviceTypeInfo].self, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func fetchCatalog(
        _ type: String,
        completion: @escaping (Result<DeviceCatalog, AppError>) -> Void
    ) {
        guard !type.isEmpty else {
            completion(.failure(.decoding("型号缺少 type 字段")))
            return
        }
        let encodedType = type.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? type
        let url = endpoint("api/v1/device-types/\(encodedType)/catalog")
        send(url, as: DeviceCatalog.self, completion: completion)
    }

    // MARK: - Mapping

    private func product(from type: DeviceTypeInfo, catalog: DeviceCatalog?) -> ProductModel {
        let firmware = catalog?.firmwares.first?.version ?? ""
        let deviceType = catalog?.deviceType.name.isEmpty == false
            ? (catalog?.deviceType.name ?? "")
            : (type.name.isEmpty ? type.type : type.name)
        let noteParts = [
            type.descriptionText,
            catalog?.accessories.isEmpty == false ? "配件 \(catalog?.accessories.count ?? 0) 件" : "",
        ]
        return ProductModel(
            mac: "",
            vendor: type.vendor,
            deviceType: deviceType,
            firmwareVersion: firmware,
            gattServices: type.gattServices,
            compatibility: [],
            note: noteParts.filter { !$0.isEmpty }.joined(separator: "；"),
            apiIdentifier: type.type
        )
    }

    private func product(from record: UserDeviceInfo) -> ProductModel {
        ProductModel(
            mac: record.mac,
            vendor: "",
            deviceType: "",
            firmwareVersion: "",
            gattServices: [],
            compatibility: [],
            note: recordNote(record),
            apiIdentifier: record.id
        )
    }

    private func recordNote(_ record: UserDeviceInfo) -> String {
        var parts = ["云同步记录（\(record.platform)）"]
        if !record.alias.isEmpty { parts.append("别名：\(record.alias)") }
        if !record.group.isEmpty { parts.append("分组：\(record.group)") }
        parts.append("externalId：\(record.externalID)")
        if record.updatedAt.timeIntervalSince1970 > 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            parts.append("更新于 \(formatter.string(from: record.updatedAt))")
        }
        return parts.joined(separator: " · ")
    }

    private func marketItems(from pairs: [CatalogPair]) -> [MarketItem] {
        pairs.flatMap { pair -> [MarketItem] in
            let vendor = pair.type.vendor
            let compatibility = pair.catalog?.deviceType.name.isEmpty == false
                ? (pair.catalog?.deviceType.name ?? "")
                : pair.type.name

            var items: [MarketItem] = []
            for firmware in pair.catalog?.firmwares ?? [] {
                items.append(MarketItem(
                    id: firmware.id,
                    kind: .firmware,
                    name: firmware.version.isEmpty ? "未命名固件" : "固件 \(firmware.version)",
                    vendor: vendor,
                    version: firmware.version,
                    compatibility: compatibility,
                    summary: firmware.releaseNotes
                ))
            }
            for accessory in pair.catalog?.accessories ?? [] {
                items.append(MarketItem(
                    id: accessory.id,
                    kind: .accessory,
                    name: accessory.name,
                    vendor: vendor,
                    version: accessory.sku,
                    compatibility: compatibility,
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

    private struct DeviceTypeListEnvelope: Decodable {
        let items: [DeviceTypeInfo]

        private enum CodingKeys: String, CodingKey {
            case items
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            items = (try? container.decodeIfPresent([DeviceTypeInfo].self, forKey: .items)) ?? []
        }
    }

    private struct APIErrorEnvelope: Decodable {
        let error: Body

        struct Body: Decodable {
            let code: String
            let message: String
        }
    }
}
