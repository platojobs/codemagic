import Foundation

/// 家庭 / 邀请码 / 房间 / 设备归属接口（`PJGoIoT` openapi 0.8.0）。
protocol HouseholdAPIServicing {
    func listHouseholds(token: String, completion: @escaping (Result<[Household], HouseholdAPIError>) -> Void)
    func createHousehold(name: String, token: String, completion: @escaping (Result<Household, HouseholdAPIError>) -> Void)
    func members(
        householdID: String,
        token: String,
        completion: @escaping (Result<[HouseholdMember], HouseholdAPIError>) -> Void
    )
    func createInvitation(
        householdID: String,
        token: String,
        completion: @escaping (Result<HouseholdInvitation, HouseholdAPIError>) -> Void
    )
    func claimInvitation(
        code: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    )
    func rooms(
        householdID: String,
        token: String,
        completion: @escaping (Result<[RemoteHouseholdRoom], HouseholdAPIError>) -> Void
    )
    func createRoom(
        householdID: String,
        name: String,
        sortOrder: Int,
        token: String,
        completion: @escaping (Result<RemoteHouseholdRoom, HouseholdAPIError>) -> Void
    )
    func updateRoom(
        householdID: String,
        roomID: String,
        name: String?,
        sortOrder: Int?,
        token: String,
        completion: @escaping (Result<RemoteHouseholdRoom, HouseholdAPIError>) -> Void
    )
    func deleteRoom(
        householdID: String,
        roomID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    )
    /// 设备归属三态：传入 `nil` 表示缺失（保持不变），空串表示清除，非空表示覆盖。
    func patchDeviceAssignment(
        platform: String,
        externalID: String,
        roomID: String?,
        householdID: String?,
        token: String,
        completion: @escaping (Result<RemoteDevice, HouseholdAPIError>) -> Void
    )
}

final class HouseholdAPIClient: HouseholdAPIServicing {
    private let configuration: APIConfiguration
    private let httpClient: HTTPClient
    private let decoder = JSONDecoder()

    init(configuration: APIConfiguration, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    // MARK: - Households

    func listHouseholds(
        token: String,
        completion: @escaping (Result<[Household], HouseholdAPIError>) -> Void
    ) {
        send(
            HTTPRequest(url: endpoint("households"), headers: authHeaders(token: token))
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(HouseholdListPayload.self, from: response.data)
                    self.deliver(.success(payload.items.compactMap(Self.makeHousehold)), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func createHousehold(
        name: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        let body = (try? JSONEncoder().encode(HouseholdNameBody(name: name))) ?? Data()
        send(
            HTTPRequest(
                url: endpoint("households"),
                method: "POST",
                headers: jsonAuthHeaders(token: token),
                body: body
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(HouseholdPayload.self, from: response.data)
                    guard let household = Self.makeHousehold(payload) else {
                        self.deliver(.failure(.decoding(L10n.t("household.responseMismatch"))), completion)
                        return
                    }
                    self.deliver(.success(household), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func members(
        householdID: String,
        token: String,
        completion: @escaping (Result<[HouseholdMember], HouseholdAPIError>) -> Void
    ) {
        send(
            HTTPRequest(url: endpoint("households/\(householdID)/members"), headers: authHeaders(token: token))
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(MemberListPayload.self, from: response.data)
                    let members = payload.items.map { item in
                        HouseholdMember(
                            userID: item.userId,
                            role: HouseholdRole(rawValue: item.role) ?? .member,
                            kind: item.kind,
                            joinedAt: SyncDateCodec.parse(item.joinedAt) ?? Date(timeIntervalSince1970: 0)
                        )
                    }
                    self.deliver(.success(members), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    // MARK: - Invitations

    func createInvitation(
        householdID: String,
        token: String,
        completion: @escaping (Result<HouseholdInvitation, HouseholdAPIError>) -> Void
    ) {
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/invitations"),
                method: "POST",
                headers: jsonAuthHeaders(token: token),
                body: Data("{}".utf8)
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(InvitationPayload.self, from: response.data)
                    guard payload.code.count == PairingCodeFormatter.codeLength,
                          let expiresAt = SyncDateCodec.parse(payload.expiresAt)
                    else {
                        self.deliver(.failure(.decoding(L10n.t("household.invitation.missingCode"))), completion)
                        return
                    }
                    self.deliver(
                        .success(HouseholdInvitation(code: payload.code.uppercased(), expiresAt: expiresAt)),
                        completion
                    )
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func claimInvitation(
        code: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        let body = (try? JSONEncoder().encode(ClaimBody(code: code))) ?? Data()
        send(
            HTTPRequest(
                url: endpoint("households/invitations/claim"),
                method: "POST",
                headers: jsonAuthHeaders(token: token),
                body: body
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(HouseholdPayload.self, from: response.data)
                    guard let household = Self.makeHousehold(payload) else {
                        self.deliver(.failure(.decoding(L10n.t("household.responseMismatch"))), completion)
                        return
                    }
                    self.deliver(.success(household), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    // MARK: - Rooms

    func rooms(
        householdID: String,
        token: String,
        completion: @escaping (Result<[RemoteHouseholdRoom], HouseholdAPIError>) -> Void
    ) {
        send(
            HTTPRequest(url: endpoint("households/\(householdID)/rooms"), headers: authHeaders(token: token))
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(RoomListPayload.self, from: response.data)
                    self.deliver(.success(payload.items), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func createRoom(
        householdID: String,
        name: String,
        sortOrder: Int,
        token: String,
        completion: @escaping (Result<RemoteHouseholdRoom, HouseholdAPIError>) -> Void
    ) {
        let body = (try? JSONEncoder().encode(RoomCreateBody(name: name, sortOrder: sortOrder))) ?? Data()
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/rooms"),
                method: "POST",
                headers: jsonAuthHeaders(token: token),
                body: body
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(RemoteHouseholdRoom.self, from: response.data)
                    self.deliver(.success(payload), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func updateRoom(
        householdID: String,
        roomID: String,
        name: String?,
        sortOrder: Int?,
        token: String,
        completion: @escaping (Result<RemoteHouseholdRoom, HouseholdAPIError>) -> Void
    ) {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let sortOrder { body["sortOrder"] = sortOrder }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/rooms/\(roomID)"),
                method: "PATCH",
                headers: jsonAuthHeaders(token: token),
                body: data
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(RemoteHouseholdRoom.self, from: response.data)
                    self.deliver(.success(payload), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func deleteRoom(
        householdID: String,
        roomID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/rooms/\(roomID)"),
                method: "DELETE",
                headers: authHeaders(token: token)
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success:
                self.deliver(.success(()), completion)
            }
        }
    }

    // MARK: - Device assignment

    func patchDeviceAssignment(
        platform: String,
        externalID: String,
        roomID: String?,
        householdID: String?,
        token: String,
        completion: @escaping (Result<RemoteDevice, HouseholdAPIError>) -> Void
    ) {
        var body: [String: String] = [:]
        if let roomID { body["roomId"] = roomID }
        if let householdID { body["householdId"] = householdID }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        send(
            HTTPRequest(
                url: endpoint("my/devices/\(platform)/\(externalID)"),
                method: "PATCH",
                headers: jsonAuthHeaders(token: token),
                body: data
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(RemoteDevice.self, from: response.data)
                    self.deliver(.success(payload), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    // MARK: - Private

    private func send(
        _ request: HTTPRequest,
        completion: @escaping (Result<HTTPResponse, HouseholdAPIError>) -> Void
    ) {
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.failure(error)), completion)
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(.failure(self.apiError(response)), completion)
                    return
                }
                self.deliver(.success(response), completion)
            }
        }
    }

    private func apiError(_ response: HTTPResponse) -> HouseholdAPIError {
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 429:
            return .rateLimited(retryAfterSeconds: Self.retryAfterSeconds(response))
        default:
            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: response.data) {
                if envelope.error.code == "FORBIDDEN" { return .forbidden }
                return .failure(.api(
                    code: envelope.error.code,
                    statusCode: response.statusCode,
                    message: envelope.error.message
                ))
            }
            return .failure(.server(statusCode: response.statusCode))
        }
    }

    private func deliver<T>(
        _ result: Result<T, HouseholdAPIError>,
        _ completion: @escaping (Result<T, HouseholdAPIError>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private static func retryAfterSeconds(_ response: HTTPResponse) -> Int? {
        guard let raw = response.header("Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Int(raw)
        else { return nil }
        return max(0, seconds)
    }

    private func authHeaders(token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    private func jsonAuthHeaders(token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
    }

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent("api/v1/\(path)")
    }

    private static func makeHousehold(_ payload: HouseholdPayload) -> Household? {
        guard let id = UUID(uuidString: payload.id) else { return nil }
        return Household(
            id: id,
            remoteID: payload.id,
            name: payload.name,
            isPersonal: payload.personal,
            role: HouseholdRole(rawValue: payload.role) ?? .member,
            memberCount: payload.memberCount,
            deviceCount: payload.deviceCount,
            createdAt: SyncDateCodec.parse(payload.createdAt) ?? Date(timeIntervalSince1970: 0),
            updatedAt: Date()
        )
    }

    private struct HouseholdListPayload: Decodable {
        let items: [HouseholdPayload]
    }

    private struct HouseholdPayload: Decodable {
        let id: String
        let name: String
        let role: String
        let personal: Bool
        let memberCount: Int
        let deviceCount: Int
        let createdAt: String
    }

    private struct MemberListPayload: Decodable {
        let items: [MemberPayload]

        struct MemberPayload: Decodable {
            let userId: String
            let role: String
            let kind: String
            let joinedAt: String
        }
    }

    private struct InvitationPayload: Decodable {
        let code: String
        let expiresAt: String
    }

    private struct RoomListPayload: Decodable {
        let items: [RemoteHouseholdRoom]
    }

    private struct HouseholdNameBody: Encodable {
        let name: String
    }

    private struct ClaimBody: Encodable {
        let code: String
    }

    private struct RoomCreateBody: Encodable {
        let name: String
        let sortOrder: Int
    }

    private struct APIErrorEnvelope: Decodable {
        let error: Body

        struct Body: Decodable {
            let code: String
            let message: String
        }
    }
}

/// BASE_URL 未配置时的降级实现。
final class UnavailableHouseholdAPI: HouseholdAPIServicing {
    private var error: HouseholdAPIError {
        .failure(.configuration(L10n.t("account.baseUrlMissing")))
    }

    func listHouseholds(token: String, completion: @escaping (Result<[Household], HouseholdAPIError>) -> Void) {
        completion(.failure(error))
    }

    func createHousehold(name: String, token: String, completion: @escaping (Result<Household, HouseholdAPIError>) -> Void) {
        completion(.failure(error))
    }

    func members(
        householdID: String,
        token: String,
        completion: @escaping (Result<[HouseholdMember], HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func createInvitation(
        householdID: String,
        token: String,
        completion: @escaping (Result<HouseholdInvitation, HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func claimInvitation(
        code: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func rooms(
        householdID: String,
        token: String,
        completion: @escaping (Result<[RemoteHouseholdRoom], HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func createRoom(
        householdID: String,
        name: String,
        sortOrder: Int,
        token: String,
        completion: @escaping (Result<RemoteHouseholdRoom, HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func updateRoom(
        householdID: String,
        roomID: String,
        name: String?,
        sortOrder: Int?,
        token: String,
        completion: @escaping (Result<RemoteHouseholdRoom, HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func deleteRoom(
        householdID: String,
        roomID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func patchDeviceAssignment(
        platform: String,
        externalID: String,
        roomID: String?,
        householdID: String?,
        token: String,
        completion: @escaping (Result<RemoteDevice, HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }
}
