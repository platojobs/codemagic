import Foundation

/// 服务端反馈条目。DTO 故意不含 `contact` 与 `diagnostics`，与契约「列表不返回敏感字段」一致。
struct FeedbackRemoteItem: Equatable {
    let feedbackID: String
    let kind: FeedbackCategory
    let body: String
    let platform: String
    let appVersion: String
    let buildType: String
    let osVersion: String
    let deviceModel: String
    let status: FeedbackRemoteStatus
    let createdAt: Date?
}

/// 服务端反馈状态。未知值保留为 `unknown`，直接展示原始值，不猜测语义。
enum FeedbackRemoteStatus: Equatable {
    case submitted
    case received
    case closed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "submitted": self = .submitted
        case "received": self = .received
        case "closed": self = .closed
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .submitted: return "submitted"
        case .received: return "received"
        case .closed: return "closed"
        case .unknown(let raw): return raw
        }
    }

    var title: String {
        switch self {
        case .submitted: return L10n.t("feedback.remote.status.submitted")
        case .received: return L10n.t("feedback.remote.status.received")
        case .closed: return L10n.t("feedback.remote.status.closed")
        case .unknown(let raw): return raw
        }
    }
}

struct FeedbackPage: Equatable {
    let items: [FeedbackRemoteItem]
    let nextCursor: String?
    let hasMore: Bool
}

/// 单条反馈详情（`GET /feedback/{id}`）：比列表多 `statusMessage` 与 `updatedAt`。
struct FeedbackDetailItem: Equatable {
    let feedbackID: String
    let kind: FeedbackCategory
    let body: String
    let status: FeedbackRemoteStatus
    /// 服务端给用户看的中文状态说明，原样展示。
    let statusMessage: String
    let createdAt: Date?
    let updatedAt: Date?
}

struct FeedbackReceipt: Equatable {
    let feedbackID: String
    let createdAt: Date?
    let replayed: Bool
}

/// 提交失败的可读原因。只有 `2xx + feedbackId` 才判成功，其余都进这里。
struct FeedbackSendFailure: Error, Equatable {
    let message: String
    let isRateLimited: Bool
    let retryAfter: TimeInterval?
    let isRetryable: Bool
    let isConflict: Bool
    let apiCode: String?
}

protocol FeedbackServicing {
    func submit(
        draft: FeedbackDraft,
        context: FeedbackClientContext,
        diagnostics: String?,
        completion: @escaping (Result<FeedbackReceipt, FeedbackSendFailure>) -> Void
    )

    func fetchMine(
        cursor: String?,
        limit: Int,
        completion: @escaping (Result<FeedbackPage, AppError>) -> Void
    )

    /// `GET /feedback/{id}`：本人单条详情，含服务端状态说明。
    func fetchDetail(
        id: String,
        completion: @escaping (Result<FeedbackDetailItem, AppError>) -> Void
    )

    /// `PATCH /feedback/{id}`：关闭本人反馈；已关闭再改返回 409。
    func close(
        id: String,
        completion: @escaping (Result<FeedbackDetailItem, FeedbackSendFailure>) -> Void
    )
}

/// 反馈接口客户端：`POST /feedback` 与 `GET /feedback/mine`。
/// 幂等键固定使用草稿本地 ID，断网重放不会产生重复记录。
final class FeedbackAPIClient: FeedbackServicing {
    static let maxBodyLength = 4000
    static let maxContactLength = 200
    static let maxDiagnosticsLength = 8000
    static let defaultPageSize = 20

    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let tokenStore: TokenStoring?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        configuration: APIConfiguration,
        httpClient: HTTPClient,
        tokenStore: TokenStoring? = nil
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    func submit(
        draft: FeedbackDraft,
        context: FeedbackClientContext,
        diagnostics: String?,
        completion: @escaping (Result<FeedbackReceipt, FeedbackSendFailure>) -> Void
    ) {
        guard let session = tokenStore?.load(), !session.token.isEmpty else {
            deliver(.failure(FeedbackSendFailure(
                message: L10n.t("feedback.error.loginRequired"),
                isRateLimited: false,
                retryAfter: nil,
                isRetryable: false,
                isConflict: false,
                apiCode: nil
            )), completion)
            return
        }

        let body = Self.makeBody(
            draft: draft,
            context: context,
            diagnostics: diagnostics
        )
        guard let payload = try? encoder.encode(body) else {
            deliver(.failure(FeedbackSendFailure(
                message: L10n.t("error.decoding"),
                isRateLimited: false,
                retryAfter: nil,
                isRetryable: true,
                isConflict: false,
                apiCode: nil
            )), completion)
            return
        }

        let request = HTTPRequest(
            url: configuration.baseURL.appendingPathComponent("api/v1/feedback"),
            method: "POST",
            headers: [
                "Authorization": "Bearer \(session.token)",
                "Content-Type": "application/json",
                "Idempotency-Key": draft.id,
            ],
            body: payload
        )

        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(FeedbackSendFailure(
                    message: error.message,
                    isRateLimited: false,
                    retryAfter: nil,
                    isRetryable: true,
                    isConflict: false,
                    apiCode: error.apiCode
                )), completion)
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.makeFailure(response)), completion)
                    return
                }
                do {
                    let decoded = try self.decoder.decode(FeedbackCreatedPayload.self, from: response.data)
                    let remoteID = decoded.feedbackId.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remoteID.isEmpty else {
                        self.deliver(.failure(FeedbackSendFailure(
                            message: L10n.t("feedback.error.missingReceipt"),
                            isRateLimited: false,
                            retryAfter: nil,
                            isRetryable: true,
                            isConflict: false,
                            apiCode: nil
                        )), completion)
                        return
                    }
                    let replayed = response.header("Idempotent-Replayed")?.lowercased() == "true"
                    self.deliver(.success(FeedbackReceipt(
                        feedbackID: remoteID,
                        createdAt: SyncDateCodec.parse(decoded.createdAt),
                        replayed: replayed
                    )), completion)
                } catch {
                    self.deliver(.failure(FeedbackSendFailure(
                        message: L10n.t("feedback.error.missingReceipt"),
                        isRateLimited: false,
                        retryAfter: nil,
                        isRetryable: true,
                        isConflict: false,
                        apiCode: nil
                    )), completion)
                }
            }
        }
    }

    func fetchMine(
        cursor: String?,
        limit: Int,
        completion: @escaping (Result<FeedbackPage, AppError>) -> Void
    ) {
        guard let session = tokenStore?.load(), !session.token.isEmpty else {
            deliver(.failure(.sync(L10n.t("feedback.error.loginRequired"))), completion)
            return
        }
        let clampedLimit = APILimits.clamp(limit, to: APILimits.feedback)
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("api/v1/feedback/mine"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "limit", value: String(clampedLimit))]
        if let cursor, !cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            deliver(.failure(.configuration(L10n.t("feedback.error.urlFailed"))), completion)
            return
        }

        let request = HTTPRequest(url: url, headers: ["Authorization": "Bearer \(session.token)"])
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                do {
                    let decoded = try self.decoder.decode(FeedbackListPayload.self, from: response.data)
                    let items = decoded.items.map { $0.makeItem() }
                    self.deliver(.success(FeedbackPage(
                        items: items,
                        nextCursor: decoded.nextCursor,
                        hasMore: decoded.hasMore
                    )), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func fetchDetail(
        id: String,
        completion: @escaping (Result<FeedbackDetailItem, AppError>) -> Void
    ) {
        guard let session = tokenStore?.load(), !session.token.isEmpty else {
            deliver(.failure(.sync(L10n.t("feedback.error.loginRequired"))), completion)
            return
        }
        let request = HTTPRequest(
            url: configuration.baseURL.appendingPathComponent("api/v1/feedback/\(id)"),
            headers: ["Authorization": "Bearer \(session.token)"]
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.mapError(response)), completion)
                    return
                }
                do {
                    let decoded = try self.decoder.decode(FeedbackDetailPayload.self, from: response.data)
                    self.deliver(.success(decoded.makeItem()), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func close(
        id: String,
        completion: @escaping (Result<FeedbackDetailItem, FeedbackSendFailure>) -> Void
    ) {
        guard let session = tokenStore?.load(), !session.token.isEmpty else {
            deliver(.failure(FeedbackSendFailure(
                message: L10n.t("feedback.error.loginRequired"),
                isRateLimited: false,
                retryAfter: nil,
                isRetryable: false,
                isConflict: false,
                apiCode: nil
            )), completion)
            return
        }
        let body = Data(#"{"status":"closed"}"#.utf8)
        let request = HTTPRequest(
            url: configuration.baseURL.appendingPathComponent("api/v1/feedback/\(id)"),
            method: "PATCH",
            headers: [
                "Authorization": "Bearer \(session.token)",
                "Content-Type": "application/json",
            ],
            body: body
        )
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(FeedbackSendFailure(
                    message: error.message,
                    isRateLimited: false,
                    retryAfter: nil,
                    isRetryable: error.isRetryable,
                    isConflict: false,
                    apiCode: error.apiCode
                )), completion)
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.makeCloseFailure(response)), completion)
                    return
                }
                do {
                    let decoded = try self.decoder.decode(FeedbackDetailPayload.self, from: response.data)
                    self.deliver(.success(decoded.makeItem()), completion)
                } catch {
                    self.deliver(.failure(FeedbackSendFailure(
                        message: L10n.t("feedback.error.missingReceipt"),
                        isRateLimited: false,
                        retryAfter: nil,
                        isRetryable: true,
                        isConflict: false,
                        apiCode: nil
                    )), completion)
                }
            }
        }
    }

    // MARK: - Private

    private func makeCloseFailure(_ response: HTTPResponse) -> FeedbackSendFailure {
        let envelope = try? decoder.decode(APIErrorEnvelope.self, from: response.data)
        let code = envelope?.error.code
        if response.statusCode == 409 || code == "FEEDBACK_INVALID_TRANSITION" || code == "CONFLICT" {
            return FeedbackSendFailure(
                message: L10n.t("feedback.close.alreadyClosed"),
                isRateLimited: false,
                retryAfter: nil,
                isRetryable: false,
                isConflict: true,
                apiCode: code ?? "FEEDBACK_INVALID_TRANSITION"
            )
        }
        if response.statusCode == 429 {
            return FeedbackSendFailure(
                message: L10n.t("error.rateLimited"),
                isRateLimited: true,
                retryAfter: FeedbackAPIClient.parseRetryAfter(response.header("Retry-After")),
                isRetryable: true,
                isConflict: false,
                apiCode: code
            )
        }
        let error = mapError(response)
        return FeedbackSendFailure(
            message: error.apiCode.map { APIErrorCatalog.entry(for: $0).message } ?? error.message,
            isRateLimited: false,
            retryAfter: nil,
            isRetryable: error.isRetryable,
            isConflict: false,
            apiCode: error.apiCode
        )
    }

    private func makeFailure(_ response: HTTPResponse) -> FeedbackSendFailure {
        let envelope = try? decoder.decode(APIErrorEnvelope.self, from: response.data)
        let code = envelope?.error.code
        let statusCode = response.statusCode
        let retryAfter = Self.parseRetryAfter(response.header("Retry-After"))
        if statusCode == 429 || code == "FEEDBACK_RATE_LIMITED" {
            return FeedbackSendFailure(
                message: APIErrorCatalog.entry(for: "FEEDBACK_RATE_LIMITED").message,
                isRateLimited: true,
                retryAfter: retryAfter,
                isRetryable: true,
                isConflict: false,
                apiCode: code ?? "FEEDBACK_RATE_LIMITED"
            )
        }
        if statusCode == 409 || code == "IDEMPOTENCY_CONFLICT" {
            return FeedbackSendFailure(
                message: APIErrorCatalog.entry(for: code ?? "IDEMPOTENCY_CONFLICT").message,
                isRateLimited: false,
                retryAfter: nil,
                isRetryable: false,
                isConflict: true,
                apiCode: code
            )
        }
        let error = mapError(response)
        return FeedbackSendFailure(
            message: error.apiCode.map { APIErrorCatalog.entry(for: $0).message } ?? error.message,
            isRateLimited: false,
            retryAfter: retryAfter,
            isRetryable: error.isRetryable,
            isConflict: false,
            apiCode: error.apiCode
        )
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

    private func deliver<T>(
        _ result: Result<T, FeedbackSendFailure>,
        _ completion: @escaping (Result<T, FeedbackSendFailure>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private func deliver<T>(
        _ result: Result<T, AppError>,
        _ completion: @escaping (Result<T, AppError>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    static func parseRetryAfter(_ raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = TimeInterval(trimmed) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func makeBody(
        draft: FeedbackDraft,
        context: FeedbackClientContext,
        diagnostics: String?
    ) -> FeedbackCreatePayload {
        let body = String(draft.message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxBodyLength))
        let contact = String(draft.contact
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxContactLength))
        let diagnosticText = diagnostics?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxDiagnosticsLength) ?? ""
        return FeedbackCreatePayload(
            kind: draft.category.rawValue,
            body: body,
            contact: contact.isEmpty ? nil : contact,
            diagnostics: diagnosticText.isEmpty ? nil : String(diagnosticText),
            context: FeedbackCreatePayload.Context(
                platform: context.platform,
                appVersion: context.appVersion,
                buildType: context.buildType,
                osVersion: context.osVersion,
                deviceModel: context.deviceModel
            )
        )
    }

    // MARK: - DTO

    private struct FeedbackCreatePayload: Encodable {
        struct Context: Encodable {
            let platform: String
            let appVersion: String
            let buildType: String
            let osVersion: String
            let deviceModel: String
        }

        let kind: String
        let body: String
        let contact: String?
        let diagnostics: String?
        let context: Context
    }

    private struct FeedbackCreatedPayload: Decodable {
        let feedbackId: String
        let createdAt: String
    }

    private struct FeedbackListPayload: Decodable {
        struct Item: Decodable {
            let feedbackId: String
            let kind: String
            let body: String
            let platform: String
            let appVersion: String
            let buildType: String
            let osVersion: String
            let deviceModel: String
            let status: String
            let createdAt: String

            func makeItem() -> FeedbackRemoteItem {
                FeedbackRemoteItem(
                    feedbackID: feedbackId,
                    kind: FeedbackCategory(storedValue: kind),
                    body: body,
                    platform: platform,
                    appVersion: appVersion,
                    buildType: buildType,
                    osVersion: osVersion,
                    deviceModel: deviceModel,
                    status: FeedbackRemoteStatus(rawValue: status),
                    createdAt: SyncDateCodec.parse(createdAt)
                )
            }
        }

        let items: [Item]
        let nextCursor: String?
        let hasMore: Bool
    }

    private struct FeedbackDetailPayload: Decodable {
        let feedbackId: String
        let kind: String
        let body: String
        let status: String
        let statusMessage: String
        let createdAt: String
        let updatedAt: String?

        func makeItem() -> FeedbackDetailItem {
            FeedbackDetailItem(
                feedbackID: feedbackId,
                kind: FeedbackCategory(storedValue: kind),
                body: body,
                status: FeedbackRemoteStatus(rawValue: status),
                statusMessage: statusMessage,
                createdAt: SyncDateCodec.parse(createdAt),
                updatedAt: updatedAt.flatMap(SyncDateCodec.parse)
            )
        }
    }

    private struct APIErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String
        }

        let error: Body
    }
}
