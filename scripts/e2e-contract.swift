import Foundation

/// 端到端契约联调（真实网络，不走 iOS 模拟器）。
///
/// 由 `scripts/e2e-contract.sh` 启动本地 `PJGoIoT`（`STORE=fixture`）后执行，
/// 直接通过 URLSession 访问 `http://127.0.0.1:<port>/api/v1`。
/// 覆盖：匿名登录、双平台推送、增量拉取、幂等重放、LWW 冲突不静默覆盖、
/// 无 token 401、跨用户 404。

private struct HTTPResult {
    let status: Int
    let headers: [AnyHashable: Any]
    let body: Data
    let error: Error?
}

private final class Box<T> {
    var value: T?
}

private final class E2EClient {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func request(
        _ method: String,
        _ path: String,
        token: String? = nil,
        idempotencyKey: String? = nil,
        json: Any? = nil
    ) -> HTTPResult {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }

        let box = Box<HTTPResult>()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            box.value = HTTPResult(
                status: http?.statusCode ?? -1,
                headers: http?.allHeaderFields ?? [:],
                body: data ?? Data(),
                error: error
            )
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            return HTTPResult(status: -1, headers: [:], body: Data(), error: E2EError.timeout)
        }
        return box.value ?? HTTPResult(status: -1, headers: [:], body: Data(), error: E2EError.timeout)
    }

    private func url(for path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var url = baseURL.appendingPathComponent(String(parts[0]))
        if parts.count > 1, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(parts[1])
            url = components.url ?? url
        }
        return url
    }
}

private enum E2EError: Error {
    case timeout
}

private final class Report {
    private(set) var passed = 0
    private(set) var failed = 0

    func check(_ condition: Bool, _ name: String, _ detail: String = "") {
        if condition {
            passed += 1
            print("  [PASS] \(name)")
        } else {
            failed += 1
            let suffix = detail.isEmpty ? "" : " — \(detail)"
            print("  [FAIL] \(name)\(suffix)")
        }
    }

    func section(_ title: String) {
        print("\n[\(title)]")
    }
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func list(_ value: Any?) -> [[String: Any]] {
    (value as? [[String: Any]]) ?? []
}

private func text(_ object: [String: Any], _ key: String) -> String {
    (object[key] as? String) ?? ""
}

private func errorCode(_ data: Data) -> String {
    guard let root = jsonObject(data),
          let error = root["error"] as? [String: Any] else { return "" }
    return text(error, "code")
}

private func bodyText(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? "<非 UTF-8 响应>"
}

private func rfc3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func madeDevice(
    id: String,
    platform: String,
    externalID: String,
    mac: String?,
    alias: String,
    group: String,
    updatedAt: Date,
    deleted: Bool = false
) -> [String: Any] {
    var device: [String: Any] = [
        "id": id,
        "platform": platform,
        "externalId": externalID,
        "alias": alias,
        "group": group,
        "rules": [:],
        "scanRecords": [],
        "updatedAt": rfc3339(updatedAt),
        "deleted": deleted,
    ]
    if let mac {
        device["mac"] = mac
    }
    return device
}

private func run() -> Int32 {
    let environment = ProcessInfo.processInfo.environment
    let rawBase = environment["E2E_BASE_URL"] ?? "http://127.0.0.1:8080"
    guard let rootURL = URL(string: rawBase) else {
        print("E2E_BASE_URL 非法：\(rawBase)")
        return 2
    }
    let client = E2EClient(baseURL: rootURL.appendingPathComponent("api/v1"))
    let report = Report()

    // 固定标识便于断言；每次联调都由脚本启动全新的 fixture 进程。
    let iosID = "11111111-1111-4111-8111-111111111111"
    let androidID = "22222222-2222-4222-8222-222222222222"
    let iosExternalID = iosID.uppercased()
    let androidMAC = "AA:BB:CC:DD:EE:01"
    let androidExternalID = androidMAC.uppercased()
    let sharedAlias = "Codemagic Scale"
    let sharedGroup = "e2e-same-device"
    let clientID = "ios-e2e"

    print("E2E 目标：\(client.baseURL.absoluteString)")

    // MARK: 1. 匿名登录

    report.section("1. 匿名登录")
    let authA = client.request("POST", "auth/anonymous", json: [String: Any]())
    report.check(
        authA.status == 200 || authA.status == 201,
        "匿名登录返回 2xx",
        "status=\(authA.status) body=\(bodyText(authA.body))"
    )
    let authAObject = jsonObject(authA.body) ?? [:]
    let tokenA = text(authAObject, "token")
    let userA = text(authAObject, "userId")
    report.check(!tokenA.isEmpty, "响应包含 token")
    report.check(!userA.isEmpty, "响应包含 userId")
    guard !tokenA.isEmpty else {
        print("\n匿名登录失败，后续用例无法继续。")
        return 1
    }

    // MARK: 2. 双平台推送

    report.section("2. 双平台推送（ios + android 同一台设备）")
    let deviceUpdatedAt = Date(timeIntervalSinceNow: -60)
    let iosDevice = madeDevice(
        id: iosID,
        platform: "ios",
        externalID: iosExternalID,
        mac: androidMAC,
        alias: sharedAlias,
        group: sharedGroup,
        updatedAt: deviceUpdatedAt
    )
    let androidDevice = madeDevice(
        id: androidID,
        platform: "android",
        externalID: androidExternalID,
        mac: androidMAC,
        alias: sharedAlias,
        group: sharedGroup,
        updatedAt: deviceUpdatedAt
    )
    let pushBody: [String: Any] = [
        "clientId": clientID,
        "devices": [iosDevice, androidDevice],
    ]
    let idempotencyKey = "e2e-idem-\(Int(Date().timeIntervalSince1970))"
    let pushResponse = client.request(
        "POST",
        "sync/push",
        token: tokenA,
        idempotencyKey: idempotencyKey,
        json: pushBody
    )
    let pushObject = jsonObject(pushResponse.body) ?? [:]
    let applied = list(pushObject["applied"])
    let conflicts = list(pushObject["conflicts"])
    report.check(pushResponse.status == 200, "push 返回 200", "status=\(pushResponse.status) body=\(bodyText(pushResponse.body))")
    report.check(applied.count == 2, "applied 数量为 2", "applied=\(applied.count)")
    report.check(conflicts.isEmpty, "首次 push 无冲突", "conflicts=\(conflicts.count)")

    let appliedPlatforms = Set(applied.map { text($0, "platform") })
    report.check(appliedPlatforms == Set(["ios", "android"]), "applied 包含 ios 与 android", "platforms=\(appliedPlatforms)")
    let appliedExternalIDs = Set(applied.map { text($0, "externalId") })
    report.check(appliedExternalIDs.contains(iosExternalID), "iOS externalId 为大写 UUID", "ids=\(appliedExternalIDs)")
    report.check(appliedExternalIDs.contains(androidExternalID), "Android externalId 为大写 MAC", "ids=\(appliedExternalIDs)")
    report.check(applied.allSatisfy { text($0, "status") == "applied" }, "applied 状态均为 applied")

    // MARK: 3. changes 拉回校验

    report.section("3. changes 拉回校验 platform / externalId")
    let changesResponse = client.request("GET", "sync/changes?cursor=0&limit=200", token: tokenA)
    report.check(changesResponse.status == 200, "changes 返回 200", "status=\(changesResponse.status)")
    let changesObject = jsonObject(changesResponse.body) ?? [:]
    let changes = list(changesObject["changes"])
    report.check(changes.count >= 2, "changes 至少 2 条", "count=\(changes.count)")

    let payloads = changes.compactMap { $0["payload"] as? [String: Any] }
    let iosPayload = payloads.first { text($0, "platform") == "ios" }
    let androidPayload = payloads.first { text($0, "platform") == "android" }
    report.check(iosPayload != nil, "changes 中存在 ios 设备")
    report.check(androidPayload != nil, "changes 中存在 android 设备")
    if let iosPayload {
        report.check(text(iosPayload, "externalId") == iosExternalID, "ios externalId 保持大写 UUID", "externalId=\(text(iosPayload, "externalId"))")
        report.check(text(iosPayload, "id") == iosID, "ios id 与推送一致")
        report.check(text(iosPayload, "alias") == sharedAlias, "ios alias 与推送一致")
    }
    if let androidPayload {
        report.check(text(androidPayload, "externalId") == androidExternalID, "android externalId 为大写 MAC", "externalId=\(text(androidPayload, "externalId"))")
        report.check(text(androidPayload, "mac") == androidMAC.lowercased(), "android mac 元数据规范化为小写", "mac=\(text(androidPayload, "mac"))")
        report.check(text(androidPayload, "id") == androidID, "android id 与推送一致")
        report.check(text(androidPayload, "alias") == sharedAlias, "android alias 与推送一致")
    }
    let upsertOps = changes.filter { text($0, "op") == "upsert" }
    report.check(upsertOps.count >= 2, "变更操作为 upsert", "ops=\(changes.map { text($0, "op") })")

    // MARK: 4. 幂等重放

    report.section("4. 同 Idempotency-Key 重放")
    let replayResponse = client.request(
        "POST",
        "sync/push",
        token: tokenA,
        idempotencyKey: idempotencyKey,
        json: pushBody
    )
    let replayedHeader = (replayResponse.headers["Idempotent-Replayed"] as? String)?.lowercased() ?? ""
    let replayObject = jsonObject(replayResponse.body) ?? [:]
    report.check(replayResponse.status == 200, "重放返回 200", "status=\(replayResponse.status)")
    report.check(replayedHeader == "true", "响应头 Idempotent-Replayed: true", "header=\(replayedHeader)")
    report.check(list(replayObject["applied"]).count == 2, "重放返回原始 applied 结果")
    report.check(list(replayObject["conflicts"]).isEmpty, "重放不产生冲突")

    let changesAfterReplay = client.request("GET", "sync/changes?cursor=0&limit=200", token: tokenA)
    let replayChanges = list((jsonObject(changesAfterReplay.body) ?? [:])["changes"])
    report.check(replayChanges.count == changes.count, "重放未产生重复变更", "before=\(changes.count) after=\(replayChanges.count)")

    // MARK: 5. LWW 冲突

    report.section("5. LWW 冲突：旧版本不静默覆盖新版本")
    let staleDevice = madeDevice(
        id: iosID,
        platform: "ios",
        externalID: iosExternalID,
        mac: androidMAC,
        alias: "本地旧名字",
        group: "e2e-stale",
        updatedAt: Date(timeIntervalSinceNow: -3600)
    )
    let staleBody: [String: Any] = ["clientId": clientID, "devices": [staleDevice]]
    let staleResponse = client.request(
        "POST",
        "sync/push",
        token: tokenA,
        idempotencyKey: "\(idempotencyKey)-stale",
        json: staleBody
    )
    let staleObject = jsonObject(staleResponse.body) ?? [:]
    let staleConflicts = list(staleObject["conflicts"])
    report.check(staleResponse.status == 200, "旧版本 push 返回 200", "status=\(staleResponse.status)")
    report.check(staleConflicts.count == 1, "返回 1 条冲突", "conflicts=\(staleConflicts.count) body=\(bodyText(staleResponse.body))")
    report.check(list(staleObject["applied"]).isEmpty, "冲突条目不写入 applied")
    if let conflict = staleConflicts.first {
        report.check(text(conflict, "reason") == "server_newer", "冲突原因为 server_newer", "reason=\(text(conflict, "reason"))")
        let server = conflict["server"] as? [String: Any] ?? [:]
        report.check(text(server, "alias") == sharedAlias, "冲突响应携带服务端 alias", "serverAlias=\(text(server, "alias"))")
        report.check(text(server, "externalId") == iosExternalID, "冲突响应 server.externalId 形状正确")
    }

    // 冒号在 URL 路径段中是合法字符；不要预编码，否则 Gin 不会二次解码。
    let macPath = androidMAC
    let ownDevice = client.request("GET", "my/devices/\(macPath)", token: tokenA)
    report.check(ownDevice.status == 200, "本人按 MAC 查询返回 200", "status=\(ownDevice.status)")
    let ownDeviceObject = jsonObject(ownDevice.body) ?? [:]
    report.check(text(ownDeviceObject, "alias") == sharedAlias, "服务端仍保留较新 alias，未被旧版本覆盖", "alias=\(text(ownDeviceObject, "alias"))")
    report.check(text(ownDeviceObject, "group") == sharedGroup, "服务端仍保留较新 group", "group=\(text(ownDeviceObject, "group"))")

    // MARK: 6. 鉴权与越权

    report.section("6. 无 token 401 / 跨用户 404")
    let noToken = client.request("GET", "my/devices")
    report.check(noToken.status == 401, "无 token 返回 401", "status=\(noToken.status)")
    report.check(errorCode(noToken.body) == "UNAUTHORIZED", "错误码为 UNAUTHORIZED", "code=\(errorCode(noToken.body))")

    let authB = client.request("POST", "auth/anonymous", json: [String: Any]())
    let authBObject = jsonObject(authB.body) ?? [:]
    let tokenB = text(authBObject, "token")
    report.check(authB.status == 200 || authB.status == 201, "第二个匿名用户登录成功", "status=\(authB.status)")
    report.check(tokenB != tokenA, "两个用户 token 不同")

    if !tokenB.isEmpty {
        let otherList = client.request("GET", "my/devices", token: tokenB)
        let otherItems = list((jsonObject(otherList.body) ?? [:])["items"])
        report.check(otherList.status == 200 && otherItems.isEmpty, "新用户设备列表为空", "status=\(otherList.status) items=\(otherItems.count)")

        let crossUser = client.request("GET", "my/devices/\(macPath)", token: tokenB)
        report.check(crossUser.status == 404, "跨用户查询返回 404", "status=\(crossUser.status)")
        report.check(errorCode(crossUser.body) == "NOT_FOUND", "错误码为 NOT_FOUND", "code=\(errorCode(crossUser.body))")
    }

    // MARK: 汇总

    print("\n=== E2E 合同联调结果 ===")
    print("通过：\(report.passed) 项，失败：\(report.failed) 项")
    if report.failed > 0 {
        print("结论：FAIL")
        return 1
    }
    print("结论：PASS")
    return 0
}

exit(run())
