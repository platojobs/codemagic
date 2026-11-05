import Foundation

/// 家庭 / 邀请码 / 房间 / 设备归属接口（`PJGoIoT` openapi 0.11.0，后端 v0.15.0）。
protocol HouseholdAPIServicing {
    func listHouseholds(token: String, completion: @escaping (Result<[Household], HouseholdAPIError>) -> Void)
    func createHousehold(name: String, token: String, completion: @escaping (Result<Household, HouseholdAPIError>) -> Void)
    func updateHousehold(
        householdID: String,
        name: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    )
    func members(
        householdID: String,
        token: String,
        completion: @escaping (Result<[HouseholdMember], HouseholdAPIError>) -> Void
    )
    func removeMember(
        householdID: String,
        userID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    )
    func leaveHousehold(
        householdID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    )
    /// 所有权转让（后端 v0.14.0 起）。老后端返回 405 时映射为 `.unsupported`。
    func transferOwnership(
        householdID: String,
        userID: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    )
    func createInvitation(
        householdID: String,
        token: String,
        completion: @escaping (Result<HouseholdInvitation, HouseholdAPIError>) -> Void
    )
    func invitations(
        householdID: String,
        token: String,
        completion: @escaping (Result<[HouseholdInvitationInfo], HouseholdAPIError>) -> Void
    )
    func revokeInvitation(
        householdID: String,
        invitationID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
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
    /// 整段重排：`roomIDs` 必须恰好覆盖家庭全部房间；409 时返回 `.roomSetMismatch`。
    func reorderRooms(
        householdID: String,
        roomIDs: [String],
        token: String,
        completion: @escaping (Result<[RemoteHouseholdRoom], HouseholdAPIError>) -> Void
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

    func updateHousehold(
        householdID: String,
        name: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        let body = (try? JSONEncoder().encode(HouseholdNameBody(name: name))) ?? Data()
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)"),
                method: "PATCH",
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
                            joinedAt: SyncDateCodec.parse(item.joinedAt) ?? Date(timeIntervalSince1970: 0),
                            isSelf: item.isSelf
                        )
                    }
                    self.deliver(.success(members), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func removeMember(
        householdID: String,
        userID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/members/\(userID)"),
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

    func leaveHousehold(
        householdID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/leave"),
                method: "POST",
                headers: jsonAuthHeaders(token: token),
                body: Data("{}".utf8)
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

    func transferOwnership(
        householdID: String,
        userID: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        let body = (try? JSONEncoder().encode(OwnershipTransferBody(userId: userID))) ?? Data()
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/transfer-ownership"),
                method: "POST",
                headers: jsonAuthHeaders(token: token),
                body: body
            ),
            bareNotFoundIsUnsupported: true
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

    func invitations(
        householdID: String,
        token: String,
        completion: @escaping (Result<[HouseholdInvitationInfo], HouseholdAPIError>) -> Void
    ) {
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/invitations"),
                headers: authHeaders(token: token)
            )
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(error), completion)
            case .success(let response):
                do {
                    let payload = try self.decoder.decode(InvitationListPayload.self, from: response.data)
                    let items = payload.items.map { item in
                        HouseholdInvitationInfo(
                            id: item.id,
                            codeHashPrefix: item.codeHashPrefix,
                            status: HouseholdInvitationStatus(rawValue: item.status) ?? .expired,
                            attempts: item.attempts,
                            expiresAt: SyncDateCodec.parse(item.expiresAt) ?? Date(timeIntervalSince1970: 0),
                            createdAt: SyncDateCodec.parse(item.createdAt) ?? Date(timeIntervalSince1970: 0)
                        )
                    }
                    self.deliver(.success(items), completion)
                } catch {
                    self.deliver(.failure(.decoding(error.localizedDescription)), completion)
                }
            }
        }
    }

    func revokeInvitation(
        householdID: String,
        invitationID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/invitations/\(invitationID)"),
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

    func reorderRooms(
        householdID: String,
        roomIDs: [String],
        token: String,
        completion: @escaping (Result<[RemoteHouseholdRoom], HouseholdAPIError>) -> Void
    ) {
        let body = (try? JSONEncoder().encode(RoomOrderBody(roomIds: roomIDs))) ?? Data()
        send(
            HTTPRequest(
                url: endpoint("households/\(householdID)/rooms/order"),
                method: "PUT",
                headers: jsonAuthHeaders(token: token),
                body: body
            ),
            conflict: .roomSetMismatch
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
        conflict: HouseholdAPIError = .conflict,
        bareNotFoundIsUnsupported: Bool = false,
        completion: @escaping (Result<HTTPResponse, HouseholdAPIError>) -> Void
    ) {
        httpClient.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.failure(error)), completion)
            case .success(let response):
                guard response.isSuccess else {
                    self.deliver(
                        .failure(
                            self.apiError(
                                response,
                                conflict: conflict,
                                bareNotFoundIsUnsupported: bareNotFoundIsUnsupported
                            )
                        ),
                        completion
                    )
                    return
                }
                self.deliver(.success(response), completion)
            }
        }
    }

    private func apiError(
        _ response: HTTPResponse,
        conflict conflictKind: HouseholdAPIError,
        bareNotFoundIsUnsupported: Bool
    ) -> HouseholdAPIError {
        let envelope = try? decoder.decode(APIErrorEnvelope.self, from: response.data)
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 404:
            // 老后端没有该路由时返回裸 404（无 JSON envelope）；新后端的 404 一定带错误体。
            if bareNotFoundIsUnsupported, envelope == nil { return .unsupported }
            return .notFound
        case 405:
            return .unsupported
        case 409:
            // 机读判断：`ROOM_SET_MISMATCH` 为重排集合不一致，其余 409 按调用端点语义降级。
            if envelope?.error.code == "ROOM_SET_MISMATCH" {
                return .roomSetMismatch
            }
            return conflictKind
        case 429:
            return .rateLimited(retryAfterSeconds: Self.retryAfterSeconds(response))
        default:
            if let envelope {
                if envelope.error.code == "FORBIDDEN" { return .forbidden }
                if envelope.error.code == "ROOM_SET_MISMATCH" { return .roomSetMismatch }
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
            roomCount: payload.roomCount,
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
        let roomCount: Int
        let createdAt: String
    }

    private struct MemberListPayload: Decodable {
        let items: [MemberPayload]

        struct MemberPayload: Decodable {
            let userId: String
            let role: String
            let kind: String
            let joinedAt: String
            /// 老后端不返回该字段。
            let isSelf: Bool?
        }
    }

    private struct InvitationPayload: Decodable {
        let code: String
        let expiresAt: String
    }

    private struct InvitationListPayload: Decodable {
        let items: [InvitationInfoPayload]
    }

    private struct InvitationInfoPayload: Decodable {
        let id: String
        let codeHashPrefix: String
        let status: String
        let attempts: Int
        let expiresAt: String
        let createdAt: String
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

    private struct OwnershipTransferBody: Encodable {
        let userId: String
    }

    private struct RoomCreateBody: Encodable {
        let name: String
        let sortOrder: Int
    }

    private struct RoomOrderBody: Encodable {
        let roomIds: [String]
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

    func updateHousehold(
        householdID: String,
        name: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func members(
        householdID: String,
        token: String,
        completion: @escaping (Result<[HouseholdMember], HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func removeMember(
        householdID: String,
        userID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func leaveHousehold(
        householdID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func transferOwnership(
        householdID: String,
        userID: String,
        token: String,
        completion: @escaping (Result<Household, HouseholdAPIError>) -> Void
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

    func invitations(
        householdID: String,
        token: String,
        completion: @escaping (Result<[HouseholdInvitationInfo], HouseholdAPIError>) -> Void
    ) {
        completion(.failure(error))
    }

    func revokeInvitation(
        householdID: String,
        invitationID: String,
        token: String,
        completion: @escaping (Result<Void, HouseholdAPIError>) -> Void
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

    func reorderRooms(
        householdID: String,
        roomIDs: [String],
        token: String,
        completion: @escaping (Result<[RemoteHouseholdRoom], HouseholdAPIError>) -> Void
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
