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

/// 基于 URLSession + Codable 的实现。
///
/// 端点与 Android 端 `ApiService` 保持一致：
/// - `GET api/products` → `{"products":[...]}`，兼容裸数组
/// - `GET api/market` → `{"marketItems":[...]}`，兼容裸数组
/// - `GET api/device/{identifier}` → 单个设备信息对象，字段同产品契约
///
/// iOS 无法读取蓝牙 MAC（CoreBluetooth 不暴露），因此设备信息以 `CBPeripheral.identifier`
/// 的 UUID 作为路径标识；Android 使用 MAC。该差异与后端 `openapi.yaml` 的 `/devices/{mac}`
/// 尚未对齐，详见 `docs/consistency.md`。
final class ProductAPIClient: ProductServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let decoder: JSONDecoder

    init(configuration: APIConfiguration, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.decoder = JSONDecoder()
    }

    func fetchProducts(completion: @escaping (Result<[ProductModel], AppError>) -> Void) {
        let url = configuration.baseURL.appendingPathComponent("api/products")
        fetch(ProductsEnvelope.self, from: url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let envelope):
                completion(.success(envelope.products))
            case .failure(.decoding):
                // 兼容直接返回数组的后端。
                self.fetch([ProductModel].self, from: url, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func fetchMarketItems(completion: @escaping (Result<[MarketItem], AppError>) -> Void) {
        let url = configuration.baseURL.appendingPathComponent("api/market")
        fetch(MarketEnvelope.self, from: url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let envelope):
                completion(.success(envelope.marketItems))
            case .failure(.decoding):
                // 兼容直接返回数组的后端。
                self.fetch([MarketItem].self, from: url, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func fetchDeviceInfo(
        peripheralID: UUID,
        completion: @escaping (Result<ProductModel, AppError>) -> Void
    ) {
        let url = configuration.baseURL
            .appendingPathComponent("api/device")
            .appendingPathComponent(peripheralID.uuidString)
        fetch(ProductModel.self, from: url, completion: completion)
    }

    // MARK: - Private

    private func fetch<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        completion: @escaping (Result<T, AppError>) -> Void
    ) {
        httpClient.get(url) { [weak self] result in
            guard let self else { return }
            let output: Result<T, AppError>
            switch result {
            case .success(let data):
                do {
                    output = .success(try self.decoder.decode(T.self, from: data))
                } catch {
                    output = .failure(.decoding(error.localizedDescription))
                }
            case .failure(let error):
                output = .failure(error)
            }
            DispatchQueue.main.async { completion(output) }
        }
    }
}

/// `GET api/products` 的响应包裹；裸数组由调用方回退解析。
private struct ProductsEnvelope: Decodable {
    let products: [ProductModel]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        products = try container.decodeIfPresent([ProductModel].self, forKey: .products) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case products
    }
}

/// `GET api/market` 的响应包裹；裸数组由调用方回退解析。
private struct MarketEnvelope: Decodable {
    let marketItems: [MarketItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marketItems = try container.decodeIfPresent([MarketItem].self, forKey: .marketItems) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case marketItems
    }
}
