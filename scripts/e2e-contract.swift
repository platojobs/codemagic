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
        headers: [String: String] = [:],
        json: Any? = nil,
        rawJSON: String? = nil
    ) -> HTTPResult {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        // 条件请求必须绕过 URLCache，否则本地缓存会直接返回 200，掩盖服务端 304 行为。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let rawJSON {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(rawJSON.utf8)
        } else if let json {
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
    private(set) var skipped = 0

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

    /// 能力未上线时明确跳过（不计为通过，也不假装成功）。
    func skip(_ name: String, _ detail: String) {
        skipped += 1
        print("  [SKIP] \(name) — \(detail)")
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

private func stringList(_ value: Any?) -> [String] {
    (value as? [String]) ?? []
}

/// 服务端目录使用完整 128 位 UUID；比较时归一化为 16 位短 UUID。
private func shortUUID(_ value: String) -> String {
    let lower = value.lowercased()
    guard lower.count > 8,
          lower.hasPrefix("0000"),
          lower.contains("-0000-1000-8000-00805f9b34fb") else {
        return lower
    }
    return String(lower.dropFirst(4).prefix(4)).uppercased()
}

private func text(_ object: [String: Any], _ key: String) -> String {
    (object[key] as? String) ?? ""
}

private func errorCode(_ data: Data) -> String {
    guard let root = jsonObject(data),
          let error = root["error"] as? [String: Any] else { return "" }
    return text(error, "code")
}

private func errorMessage(_ data: Data) -> String {
    guard let root = jsonObject(data),
          let error = root["error"] as? [String: Any] else { return "" }
    return text(error, "message")
}

private func bodyText(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? "<非 UTF-8 响应>"
}

/// HTTP 头大小写不敏感；`allHeaderFields` 的键不保证统一大小写。
private func header(_ result: HTTPResult, _ name: String) -> String {
    for (key, value) in result.headers {
        guard let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame else {
            continue
        }
        return (value as? String) ?? ""
    }
    return ""
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
    alias: String? = nil,
    group: String? = nil,
    advertisedName: String? = nil,
    updatedAt: Date,
    deleted: Bool = false,
    deviceType: String? = nil,
    markedAt: Any? = nil
) -> [String: Any] {
    var device: [String: Any] = [
        "id": id,
        "platform": platform,
        "externalId": externalID,
        "rules": [:],
        "scanRecords": [],
        "updatedAt": rfc3339(updatedAt),
        "deleted": deleted,
    ]
    // nil 表示未上报（字段省略），"" 表示显式清除；两者语义不同。
    if let alias { device["alias"] = alias }
    if let group { device["group"] = group }
    if let advertisedName { device["advertisedName"] = advertisedName }
    if let mac {
        device["mac"] = mac
    }
    if let deviceType {
        device["deviceType"] = deviceType
    }
    // nil=字段省略（保持原值）；NSNull()=显式 null（取消标记）；字符串=RFC3339 标记。
    if let markedAt {
        device["markedAt"] = markedAt
    }
    return device
}

private func madeReading(
    id: String,
    platform: String,
    externalID: String,
    metric: String,
    value: Double,
    unit: String,
    recordedAt: Date
) -> [String: Any] {
    [
        "id": id,
        "platform": platform,
        "externalId": externalID,
        "metric": metric,
        "value": value,
        "unit": unit,
        "recordedAt": rfc3339(recordedAt),
    ]
}

private func number(_ object: [String: Any], _ key: String) -> Double? {
    (object[key] as? NSNumber)?.doubleValue
}

private func parsedDate(_ object: [String: Any], _ key: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text(object, key)) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text(object, key))
}

private func compatibilityPlatforms(_ object: [String: Any]) -> [String] {
    guard let compatibility = object["compatibility"] as? [String: Any] else { return [] }
    return (compatibility["platforms"] as? [String]) ?? []
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

    // MARK: 3.4 设备类型目录（公开只读 + 条件请求）

    report.section("3.4 设备类型目录 /catalog/device-types（公开只读 + ETag/304）")
    let catalogResponse = client.request("GET", "catalog/device-types")
    report.check(
        catalogResponse.status == 200,
        "目录匿名可读且返回 200",
        "status=\(catalogResponse.status) body=\(bodyText(catalogResponse.body))"
    )
    let catalogObject = jsonObject(catalogResponse.body) ?? [:]
    let catalogItems = list(catalogObject["items"])
    let catalogVersion = (catalogObject["version"] as? NSNumber)?.intValue ?? 0
    report.check(catalogVersion > 0, "目录包含递增版本号", "version=\(catalogVersion)")
    report.check(!text(catalogObject, "generatedAt").isEmpty, "目录包含 generatedAt")
    report.check(catalogItems.count >= 5, "目录至少 5 个设备类型", "count=\(catalogItems.count)")

    let requiredTypes = Set([
        "cycling_speed_cadence", "environmental_sensor", "heart_rate_monitor",
        "nordic_uart", "smart_scale",
    ])
    let actualTypes = Set(catalogItems.map { text($0, "type") })
    report.check(
        requiredTypes.isSubset(of: actualTypes),
        "目录覆盖固定类型集合",
        "missing=\(requiredTypes.subtracting(actualTypes))"
    )

    let catalogByType = Dictionary(uniqueKeysWithValues: catalogItems.map { (text($0, "type"), $0) })
    if let env = catalogByType["environmental_sensor"] {
        report.check(!text(env, "displayName").isEmpty, "环境传感器有 displayName")
        report.check(!text(env, "description").isEmpty, "环境传感器有 description")
        report.check(list(env["gattServices"]).count >= 2, "环境传感器声明 GATT 服务")
        let envMetrics = list(env["metrics"])
        report.check(envMetrics.count == 3, "环境传感器声明 3 个指标", "count=\(envMetrics.count)")
        let temperature = envMetrics.first { text($0, "key") == "temperature_celsius" }
        report.check(temperature != nil, "环境传感器包含 temperature_celsius")
        report.check(
            shortUUID(text(temperature ?? [:], "characteristicUuid")) == "2A6E",
            "温度来源特征为 2A6E"
        )
        report.check(stringList(env["limitations"]).count >= 2, "环境传感器有目录限制说明")
        let compatibility = env["compatibility"] as? [String: Any] ?? [:]
        report.check(
            (compatibility["platforms"] as? [String] ?? []).contains("ios"),
            "环境传感器兼容性包含 ios"
        )
        report.check(!text(env, "updatedAt").isEmpty, "目录项包含 updatedAt")
    } else {
        report.check(false, "目录缺少 environmental_sensor")
    }

    if let heart = catalogByType["heart_rate_monitor"] {
        let heartMetrics = list(heart["metrics"])
        report.check(
            heartMetrics.contains {
                text($0, "key") == "heart_rate" && shortUUID(text($0, "characteristicUuid")) == "2A37"
            },
            "心率目录项指向 2A37"
        )
    }
    if let scale = catalogByType["smart_scale"] {
        let scaleMetrics = list(scale["metrics"])
        report.check(
            scaleMetrics.contains {
                text($0, "key") == "weight_kg" && shortUUID(text($0, "characteristicUuid")) == "2A9D"
            },
            "体脂秤目录项指向 2A9D"
        )
    }
    if let uart = catalogByType["nordic_uart"] {
        report.check(list(uart["metrics"]).isEmpty, "NUS 透传设备不声明指标")
    }

    let catalogETag = header(catalogResponse, "ETag")
    let catalogLastModified = header(catalogResponse, "Last-Modified")
    report.check(!catalogETag.isEmpty, "目录响应包含 ETag", "etag=\(catalogETag)")
    report.check(!catalogLastModified.isEmpty, "目录响应包含 Last-Modified")
    report.check(
        !header(catalogResponse, "Cache-Control").isEmpty,
        "目录响应包含 Cache-Control"
    )

    if !catalogETag.isEmpty {
        let notModified = client.request(
            "GET",
            "catalog/device-types",
            headers: ["If-None-Match": catalogETag]
        )
        report.check(
            notModified.status == 304,
            "If-None-Match 命中返回 304",
            "status=\(notModified.status) body=\(bodyText(notModified.body))"
        )
        report.check(
            header(notModified, "ETag") == catalogETag,
            "304 响应的 ETag 与首次一致"
        )
    }
    if !catalogLastModified.isEmpty {
        let notModified = client.request(
            "GET",
            "catalog/device-types",
            headers: ["If-Modified-Since": catalogLastModified]
        )
        report.check(
            notModified.status == 304,
            "If-Modified-Since 命中返回 304",
            "status=\(notModified.status)"
        )
    }

    // MARK: 3.5 型号 catalog 与复合键详情

    report.section("3.5 device-types/catalog 与 my/devices/{platform}/{externalId}")
    let typesResponse = client.request("GET", "device-types")
    let typesObject = jsonObject(typesResponse.body) ?? [:]
    let deviceTypes = list(typesObject["items"])
    report.check(typesResponse.status == 200, "device-types 返回 200", "status=\(typesResponse.status)")
    report.check(!deviceTypes.isEmpty, "device-types 列表非空", "count=\(deviceTypes.count)")

    var catalogOK = 0
    var totalFirmwares = 0
    var totalAccessories = 0
    var firmwaresWithVendor = 0
    var firmwaresWithCompatibility = 0
    var accessoriesWithVendor = 0
    var accessoriesWithCompatibility = 0
    var firstTypeKey = ""
    for deviceType in deviceTypes.prefix(10) {
        let typeKey = text(deviceType, "type")
        if firstTypeKey.isEmpty { firstTypeKey = typeKey }
        let catalogResponse = client.request("GET", "device-types/\(typeKey)/catalog")
        let catalogObject = jsonObject(catalogResponse.body) ?? [:]
        let catalogType = catalogObject["deviceType"] as? [String: Any] ?? [:]
        let catalogFirmwares = list(catalogObject["firmwares"])
        let catalogAccessories = list(catalogObject["accessories"])
        if catalogResponse.status == 200, text(catalogType, "type") == typeKey {
            catalogOK += 1
            totalFirmwares += catalogFirmwares.count
            totalAccessories += catalogAccessories.count
            firmwaresWithVendor += catalogFirmwares.filter { !text($0, "vendor").isEmpty }.count
            firmwaresWithCompatibility += catalogFirmwares.filter {
                compatibilityPlatforms($0).isEmpty == false
            }.count
            accessoriesWithVendor += catalogAccessories.filter { !text($0, "vendor").isEmpty }.count
            accessoriesWithCompatibility += catalogAccessories.filter {
                ($0["compatibility"] as? [String: Any]) != nil
            }.count
        }
    }
    report.check(catalogOK == deviceTypes.prefix(10).count, "所有 catalog 返回 200 且 type 一致", "ok=\(catalogOK)/\(deviceTypes.prefix(10).count)")
    report.check(totalFirmwares > 0, "catalog 聚合含固件", "firmwares=\(totalFirmwares)")
    report.check(totalAccessories > 0, "catalog 聚合含配件", "accessories=\(totalAccessories)")
    report.check(
        firmwaresWithVendor > 0 && firmwaresWithVendor == totalFirmwares,
        "固件均带非空 vendor",
        "withVendor=\(firmwaresWithVendor)/\(totalFirmwares)"
    )
    report.check(
        firmwaresWithCompatibility == totalFirmwares,
        "固件均带 compatibility.platforms",
        "withCompatibility=\(firmwaresWithCompatibility)/\(totalFirmwares)"
    )
    report.check(
        accessoriesWithCompatibility == totalAccessories,
        "配件均带 compatibility 对象",
        "withCompatibility=\(accessoriesWithCompatibility)/\(totalAccessories)"
    )
    report.check(
        accessoriesWithVendor > 0,
        "配件含真实 vendor（允许未核实为空）",
        "withVendor=\(accessoriesWithVendor)/\(totalAccessories)"
    )
    report.check(
        catalogOK > 0,
        "catalog 示例型号可解析",
        "firstType=\(firstTypeKey)"
    )

    let compositeDevice = client.request("GET", "my/devices/ios/\(iosExternalID)", token: tokenA)
    let compositeObject = jsonObject(compositeDevice.body) ?? [:]
    report.check(compositeDevice.status == 200, "iOS 复合键详情返回 200", "status=\(compositeDevice.status)")
    report.check(text(compositeObject, "platform") == "ios", "复合键详情 platform=ios")
    report.check(text(compositeObject, "externalId") == iosExternalID, "复合键详情 externalId 为大写 UUID")
    report.check(text(compositeObject, "id") == iosID, "复合键详情 id 与推送一致")

    // MARK: 3.6 UserDevice 元数据补全与 null 降级

    report.section("3.6 UserDevice deviceType/vendor/compatibility 与 null 降级")
    let knownMetaID = "33333333-3333-4333-8333-333333333333"
    let unknownMetaID = "44444444-4444-4444-8444-444444444444"
    let metadataUpdatedAt = Date(timeIntervalSinceNow: -30)
    let knownMetaDevice = madeDevice(
        id: knownMetaID,
        platform: "ios",
        externalID: knownMetaID.uppercased(),
        mac: nil,
        alias: "元数据设备",
        group: "e2e-metadata",
        updatedAt: metadataUpdatedAt,
        deviceType: "nordic_uart"
    )
    let unknownMetaDevice = madeDevice(
        id: unknownMetaID,
        platform: "ios",
        externalID: unknownMetaID.uppercased(),
        mac: nil,
        alias: "未注册型号设备",
        group: "e2e-metadata",
        updatedAt: metadataUpdatedAt
    )
    let metadataPush = client.request(
        "POST",
        "sync/push",
        token: tokenA,
        idempotencyKey: "\(idempotencyKey)-meta",
        json: ["clientId": clientID, "devices": [knownMetaDevice, unknownMetaDevice]]
    )
    let metadataApplied = list((jsonObject(metadataPush.body) ?? [:])["applied"])
    report.check(metadataPush.status == 200, "元数据设备 push 返回 200", "status=\(metadataPush.status)")
    report.check(metadataApplied.count == 2, "元数据设备 applied 数量为 2", "applied=\(metadataApplied.count)")

    let knownDetail = client.request(
        "GET",
        "my/devices/ios/\(knownMetaID.uppercased())",
        token: tokenA
    )
    let knownObject = jsonObject(knownDetail.body) ?? [:]
    report.check(knownDetail.status == 200, "已知型号详情返回 200", "status=\(knownDetail.status)")
    report.check(
        text(knownObject, "deviceType") == "nordic_uart",
        "UserDevice 带 deviceType",
        "deviceType=\(text(knownObject, "deviceType"))"
    )
    report.check(
        text(knownObject, "vendor") == "Nordic Semiconductor",
        "UserDevice 带 vendor（按型号补全）",
        "vendor=\(text(knownObject, "vendor"))"
    )
    report.check(
        compatibilityPlatforms(knownObject).contains("ios"),
        "UserDevice 带 compatibility.platforms",
        "body=\(bodyText(knownDetail.body))"
    )

    let unknownDetail = client.request(
        "GET",
        "my/devices/ios/\(unknownMetaID.uppercased())",
        token: tokenA
    )
    let unknownObject = jsonObject(unknownDetail.body) ?? [:]
    report.check(unknownDetail.status == 200, "未注册型号详情返回 200", "status=\(unknownDetail.status)")
    report.check(
        unknownObject["deviceType"] is NSNull,
        "未注册型号 deviceType 为 null（客户端降级为「型号未知」）",
        "deviceType=\(String(describing: unknownObject["deviceType"]))"
    )
    report.check(
        unknownObject["vendor"] is NSNull,
        "未注册型号 vendor 为 null，不编造",
        "vendor=\(String(describing: unknownObject["vendor"]))"
    )
    report.check(
        unknownObject["compatibility"] is NSNull,
        "未注册型号 compatibility 为 null",
        "compatibility=\(String(describing: unknownObject["compatibility"]))"
    )
    report.check(
        text(unknownObject, "alias") == "未注册型号设备",
        "未注册型号仍返回 alias（详情页可展示）",
        "alias=\(text(unknownObject, "alias"))"
    )
    report.check(
        text(unknownObject, "group") == "e2e-metadata",
        "未注册型号仍返回 group",
        "group=\(text(unknownObject, "group"))"
    )

    // MARK: 3.7 别名 / 广播名分离与分组三态 (openapi 0.3.3)

    report.section("3.7 advertisedName / alias 隔离与 group 三态")
    let separationID = "55555555-5555-4555-8555-555555555555"
    let separationExternalID = separationID.uppercased()
    let separationMAC = "AA:BB:CC:DD:EE:03"
    let separationStart = Date(timeIntervalSinceNow: -40)
    func separationDetail() -> [String: Any] {
        let response = client.request(
            "GET",
            "my/devices/ios/\(separationExternalID)",
            token: tokenA
        )
        return jsonObject(response.body) ?? [:]
    }
    func pushSeparation(_ device: [String: Any], key: String) -> HTTPResult {
        client.request(
            "POST",
            "sync/push",
            token: tokenA,
            idempotencyKey: "\(idempotencyKey)-\(key)",
            json: ["clientId": clientID, "devices": [device]]
        )
    }

    // 1) 扫描只上报 advertisedName，不带 alias / group。
    let scanPush = pushSeparation(
        madeDevice(
            id: separationID,
            platform: "ios",
            externalID: separationExternalID,
            mac: separationMAC,
            advertisedName: "PJ-Sensor",
            updatedAt: separationStart
        ),
        key: "scan"
    )
    report.check(scanPush.status == 200, "扫描上报返回 200", "status=\(scanPush.status)")
    report.check(
        list((jsonObject(scanPush.body) ?? [:])["conflicts"]).isEmpty,
        "扫描上报无冲突"
    )
    let afterScan = separationDetail()
    report.check(
        text(afterScan, "advertisedName") == "PJ-Sensor",
        "服务端保存广播名",
        "advertisedName=\(text(afterScan, "advertisedName"))"
    )
    report.check(
        text(afterScan, "alias") == "",
        "扫描未上报时 alias 保持空串（不编造别名）",
        "alias=\(text(afterScan, "alias"))"
    )

    // 2) 用户编辑只上报 alias，广播名必须保留。
    let aliasPush = pushSeparation(
        madeDevice(
            id: separationID,
            platform: "ios",
            externalID: separationExternalID,
            mac: separationMAC,
            alias: "客厅传感器",
            updatedAt: separationStart.addingTimeInterval(10)
        ),
        key: "alias"
    )
    report.check(aliasPush.status == 200, "别名上报返回 200", "status=\(aliasPush.status)")
    let afterAlias = separationDetail()
    report.check(
        text(afterAlias, "alias") == "客厅传感器",
        "服务端保存别名",
        "alias=\(text(afterAlias, "alias"))"
    )
    report.check(
        text(afterAlias, "advertisedName") == "PJ-Sensor",
        "编辑别名不覆盖广播名",
        "advertisedName=\(text(afterAlias, "advertisedName"))"
    )

    // 3) 设置分组，同时标记设备：markedAt 必须保留微秒精度。
    let markedAtMicros = "2026-11-05T08:09:10.123456Z"
    let groupSetPush = pushSeparation(
        madeDevice(
            id: separationID,
            platform: "ios",
            externalID: separationExternalID,
            mac: separationMAC,
            group: "e2e-separation",
            updatedAt: separationStart.addingTimeInterval(20),
            markedAt: markedAtMicros
        ),
        key: "group-set"
    )
    report.check(groupSetPush.status == 200, "设置分组返回 200", "status=\(groupSetPush.status)")
    let afterGroupSet = separationDetail()
    report.check(
        text(afterGroupSet, "group") == "e2e-separation" && text(afterGroupSet, "markedAt") == markedAtMicros,
        "服务端保存分组与 markedAt（/my/devices 回读微秒一致）",
        "group=\(text(afterGroupSet, "group")) markedAt=\(text(afterGroupSet, "markedAt"))"
    )

    // 4) 未上报分组（字段省略）必须保持原值。
    let omitGroupPush = pushSeparation(
        madeDevice(
            id: separationID,
            platform: "ios",
            externalID: separationExternalID,
            mac: separationMAC,
            updatedAt: separationStart.addingTimeInterval(25)
        ),
        key: "group-absent"
    )
    report.check(omitGroupPush.status == 200, "缺省分组上报返回 200", "status=\(omitGroupPush.status)")
    report.check(
        text(separationDetail(), "group") == "e2e-separation",
        "缺省 group 字段不参与 LWW，不覆盖已有分组",
        "group=\(text(separationDetail(), "group"))"
    )

    // 5) 显式清除分组：必须上报 "group": ""；同时用 null 取消标记。
    let clearPush = pushSeparation(
        madeDevice(
            id: separationID,
            platform: "ios",
            externalID: separationExternalID,
            mac: separationMAC,
            group: "",
            updatedAt: separationStart.addingTimeInterval(30),
            markedAt: NSNull()
        ),
        key: "group-clear"
    )
    report.check(clearPush.status == 200, "清空分组返回 200", "status=\(clearPush.status)")
    let afterClear = separationDetail()
    report.check(
        text(afterClear, "group") == "" && afterClear["markedAt"] is NSNull,
        "显式空串清除云端分组，null 取消标记且回读为 null",
        "group=\(text(afterClear, "group")) markedAt=\(String(describing: afterClear["markedAt"]))"
    )
    report.check(
        text(afterClear, "advertisedName") == "PJ-Sensor" && text(afterClear, "alias") == "客厅传感器",
        "清除分组不影响别名与广播名"
    )

    // 6) 同内容重试（含缺省字段）必须幂等：同键重放返回 applied，换键也不能 409。
    let replayClear = client.request(
        "POST",
        "sync/push",
        token: tokenA,
        idempotencyKey: "\(idempotencyKey)-group-clear",
        json: ["clientId": clientID, "devices": [
            madeDevice(
                id: separationID,
                platform: "ios",
                externalID: separationExternalID,
                mac: separationMAC,
                group: "",
                updatedAt: separationStart.addingTimeInterval(30),
                markedAt: NSNull()
            ),
        ]]
    )
    report.check(replayClear.status == 200, "同内容同键重放返回 200", "status=\(replayClear.status)")
    report.check(
        client.request(
            "POST",
            "sync/push",
            token: tokenA,
            idempotencyKey: "\(idempotencyKey)-group-clear-alt",
            json: ["clientId": clientID, "devices": [
                madeDevice(
                    id: separationID,
                    platform: "ios",
                    externalID: separationExternalID,
                    mac: separationMAC,
                    group: "",
                    updatedAt: separationStart.addingTimeInterval(30),
                    markedAt: NSNull()
                ),
            ]]
        ).status == 200,
        "同内容换幂等键不触发 409",
        "group 空串与 markedAt null 同样参与内容比较"
    )

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

    let changesBeforeReplay = client.request("GET", "sync/changes?cursor=0&limit=200", token: tokenA)
    let beforeReplayCount = list((jsonObject(changesBeforeReplay.body) ?? [:])["changes"]).count
    let changesAfterReplay = client.request("GET", "sync/changes?cursor=0&limit=200", token: tokenA)
    let replayChanges = list((jsonObject(changesAfterReplay.body) ?? [:])["changes"])
    // change_log 的 user_device payload 必须带 markedAt；取该设备最后一条（已用 null 取消）。
    let separationChange = replayChanges.last { change in(
        text(change, "entity") == "user_device"
            && text(change["payload"] as? [String: Any] ?? [:], "externalId") == separationExternalID)
    }
    let separationPayload = separationChange?["payload"] as? [String: Any]
    report.check(
        replayChanges.count == beforeReplayCount
            && separationChange != nil
            && separationPayload?.keys.contains("markedAt") == true
            && separationPayload?["markedAt"] is NSNull,
        "重放未产生重复变更，user_device change_log payload 含 markedAt=null",
        "before=\(beforeReplayCount) after=\(replayChanges.count) markedAt=\(String(describing: separationPayload?["markedAt"]))"
    )

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
        report.check(crossUser.status == 404, "跨用户按 MAC 查询返回 404", "status=\(crossUser.status)")
        report.check(errorCode(crossUser.body) == "NOT_FOUND", "错误码为 NOT_FOUND", "code=\(errorCode(crossUser.body))")

        let crossUserComposite = client.request("GET", "my/devices/ios/\(iosExternalID)", token: tokenB)
        report.check(crossUserComposite.status == 404, "跨用户按复合键查询返回 404", "status=\(crossUserComposite.status)")
        report.check(errorCode(crossUserComposite.body) == "NOT_FOUND", "复合键错误码为 NOT_FOUND")
    }

    // MARK: 7. 设备读数（readings）

    report.section("7. 设备读数 readings（推送 / 倒序 / summary / 重复 id / NaN）")
    let readingsPath = "my/devices/ios/\(iosExternalID)/readings"
    let readingsSummaryPath = "\(readingsPath)/summary?metric=heart_rate&hours=24"
    let probe = client.request("GET", readingsSummaryPath, token: tokenA)
    if probe.status == 404 {
        // 后端 readings 尚未发布（当前 PJGoIoT main 仍为 v0.3.3）：
        // 明确跳过，不用 || true 或伪造 PASS；后端上线后本节自动执行真实断言。
        report.skip(
            "readings 契约",
            "GET \(readingsSummaryPath) 返回 404（后端尚未实现 readings，能力门控跳过）"
        )
    } else {
        let now = Date()
        let readingIDs = [
            "33333333-3333-4333-8333-333333333331",
            "33333333-3333-4333-8333-333333333332",
            "33333333-3333-4333-8333-333333333333",
        ]
        let readingValues: [Double] = [61, 72, 65]
        let readingTimes = [
            now.addingTimeInterval(-180),
            now.addingTimeInterval(-120),
            now.addingTimeInterval(-60),
        ]
        let readings = zip(readingIDs.indices, readingIDs).map { index, id in
            madeReading(
                id: id,
                platform: "ios",
                externalID: iosExternalID,
                metric: "heart_rate",
                value: readingValues[index],
                unit: "bpm",
                recordedAt: readingTimes[index]
            )
        }

        let readingsPush = client.request(
            "POST",
            "sync/push",
            token: tokenA,
            idempotencyKey: "\(idempotencyKey)-readings",
            json: ["clientId": clientID, "devices": [], "readings": readings]
        )
        let readingsPushObject = jsonObject(readingsPush.body) ?? [:]
        report.check(
            readingsPush.status == 200,
            "推送读数返回 200",
            "status=\(readingsPush.status) body=\(bodyText(readingsPush.body))"
        )
        report.check(
            (readingsPushObject["appliedReadings"] as? NSNumber)?.intValue == 3,
            "appliedReadings 为 3",
            "appliedReadings=\(readingsPushObject["appliedReadings"] ?? "nil")"
        )
        report.check(
            (readingsPushObject["skippedReadings"] as? NSNumber)?.intValue == 0,
            "首次推送 skippedReadings 为 0",
            "skippedReadings=\(readingsPushObject["skippedReadings"] ?? "nil")"
        )

        let listResponse = client.request(
            "GET",
            "\(readingsPath)?metric=heart_rate&limit=100",
            token: tokenA
        )
        let listObject = jsonObject(listResponse.body) ?? [:]
        let items = list(listObject["items"])
        report.check(listResponse.status == 200, "查询读数返回 200", "status=\(listResponse.status)")
        report.check(items.count == 3, "返回 3 条读数", "items=\(items.count)")
        let dates = items.compactMap { parsedDate($0, "recordedAt") }
        report.check(
            dates.count == 3 && zip(dates, dates.dropFirst()).allSatisfy { $0 > $1 },
            "读数按 recordedAt 倒序",
            "dates=\(dates)"
        )
        report.check(
            items.first.map { number($0, "value") == readingValues[2] } ?? false,
            "首条为最新读数 65 bpm",
            "first=\(items.first.map { "\(number($0, "value") ?? -1)" } ?? "nil")"
        )

        let summaryResponse = client.request("GET", readingsSummaryPath, token: tokenA)
        let summaryObject = jsonObject(summaryResponse.body) ?? [:]
        report.check(summaryResponse.status == 200, "summary 返回 200", "status=\(summaryResponse.status)")
        report.check(
            (summaryObject["count"] as? NSNumber)?.intValue == 3,
            "summary count 为 3",
            "body=\(bodyText(summaryResponse.body))"
        )
        report.check(number(summaryObject, "min") == 61, "summary min 为 61")
        report.check(number(summaryObject, "max") == 72, "summary max 为 72")
        report.check(number(summaryObject, "last") == 65, "summary last 为 65")
        report.check(number(summaryObject, "avg") == 66, "summary avg 为 66")
        report.check(text(summaryObject, "unit") == "bpm", "summary unit 为 bpm")
        report.check(
            !text(summaryObject, "windowStart").isEmpty && !text(summaryObject, "windowEnd").isEmpty,
            "summary 包含 windowStart / windowEnd"
        )

        let duplicatePush = client.request(
            "POST",
            "sync/push",
            token: tokenA,
            idempotencyKey: "\(idempotencyKey)-readings-dup",
            json: ["clientId": clientID, "devices": [], "readings": readings]
        )
        let duplicateObject = jsonObject(duplicatePush.body) ?? [:]
        report.check(
            duplicatePush.status == 200,
            "重复 id 推送返回 200（幂等，不报错）",
            "status=\(duplicatePush.status)"
        )
        report.check(
            (duplicateObject["appliedReadings"] as? NSNumber)?.intValue == 0,
            "重复 id appliedReadings 为 0",
            "body=\(bodyText(duplicatePush.body))"
        )
        report.check(
            (duplicateObject["skippedReadings"] as? NSNumber)?.intValue == 3,
            "重复 id skippedReadings 为 3",
            "body=\(bodyText(duplicatePush.body))"
        )

        let nanBody = """
        {"clientId":"\(clientID)","devices":[],"readings":[{"id":"33333333-3333-4333-8333-333333333334","platform":"ios","externalId":"\(iosExternalID)","metric":"heart_rate","value":"NaN","unit":"bpm","recordedAt":"\(rfc3339(now))"}]}
        """
        let nanResponse = client.request(
            "POST",
            "sync/push",
            token: tokenA,
            idempotencyKey: "\(idempotencyKey)-readings-nan",
            rawJSON: nanBody
        )
        report.check(
            nanResponse.status == 400,
            "非法 NaN 值返回 400",
            "status=\(nanResponse.status) body=\(bodyText(nanResponse.body))"
        )

        // MARK: 7.1 series / metrics（后端 v0.5.0 起）

        // 追加两条温度读数（比心率更新），用于验证指标清单按 lastAt 倒序。
        let extraReadings = [
            madeReading(
                id: "33333333-3333-4333-8333-333333333335",
                platform: "ios",
                externalID: iosExternalID,
                metric: "temperature",
                value: 22.5,
                unit: "℃",
                recordedAt: now.addingTimeInterval(-30)
            ),
            madeReading(
                id: "33333333-3333-4333-8333-333333333336",
                platform: "ios",
                externalID: iosExternalID,
                metric: "temperature",
                value: 23.5,
                unit: "℃",
                recordedAt: now.addingTimeInterval(-10)
            ),
        ]
        let extraPush = client.request(
            "POST",
            "sync/push",
            token: tokenA,
            idempotencyKey: "\(idempotencyKey)-readings-extra",
            json: ["clientId": clientID, "devices": [], "readings": extraReadings]
        )
        let extraObject = jsonObject(extraPush.body) ?? [:]
        report.check(
            extraPush.status == 200 && (extraObject["appliedReadings"] as? NSNumber)?.intValue == 2,
            "追加 2 条温度读数",
            "status=\(extraPush.status) body=\(bodyText(extraPush.body))"
        )

        let seriesFrom = now.addingTimeInterval(-3_600)
        let seriesTo = now.addingTimeInterval(60)
        let seriesPath = "\(readingsPath)/series?metric=heart_rate&from=\(rfc3339(seriesFrom))&to=\(rfc3339(seriesTo))&bucket=1m"
        let seriesResponse = client.request("GET", seriesPath, token: tokenA)
        let seriesObject = jsonObject(seriesResponse.body) ?? [:]
        let buckets = list(seriesObject["buckets"])
        report.check(seriesResponse.status == 200, "series 返回 200", "status=\(seriesResponse.status) body=\(bodyText(seriesResponse.body))")
        report.check(text(seriesObject, "metric") == "heart_rate", "series metric 为 heart_rate")
        report.check(text(seriesObject, "unit") == "bpm", "series unit 为 bpm")
        report.check(text(seriesObject, "bucket") == "1m", "series bucket 回显 1m")
        let bucketDates = buckets.compactMap { parsedDate($0, "start") }
        report.check(
            bucketDates.count == buckets.count && zip(bucketDates, bucketDates.dropFirst()).allSatisfy { $0 < $1 },
            "桶按 start 升序",
            "starts=\(bucketDates)"
        )
        report.check(
            buckets.reduce(0) { $0 + Int((($1["count"] as? NSNumber)?.intValue) ?? 0) } == 3,
            "桶内 count 合计为 3",
            "buckets=\(buckets.count)"
        )
        report.check(
            buckets.allSatisfy { bucket in
                guard let min = number(bucket, "min"), let max = number(bucket, "max"),
                      let avg = number(bucket, "avg") else { return false }
                return min <= avg && avg <= max
            },
            "每个桶满足 min ≤ avg ≤ max"
        )

        let emptyFrom = now.addingTimeInterval(-60 * 86_400)
        let emptyTo = now.addingTimeInterval(-59 * 86_400)
        let emptyPath = "\(readingsPath)/series?metric=heart_rate&from=\(rfc3339(emptyFrom))&to=\(rfc3339(emptyTo))&bucket=1d"
        let emptyResponse = client.request("GET", emptyPath, token: tokenA)
        let emptyObject = jsonObject(emptyResponse.body) ?? [:]
        report.check(emptyResponse.status == 200, "空区间 series 返回 200", "status=\(emptyResponse.status)")
        report.check(
            (emptyObject["buckets"] as? [Any])?.isEmpty ?? false,
            "空区间返回 buckets: []",
            "body=\(bodyText(emptyResponse.body))"
        )

        let badBucket = client.request(
            "GET",
            "\(readingsPath)/series?metric=heart_rate&from=\(rfc3339(seriesFrom))&to=\(rfc3339(seriesTo))&bucket=5m",
            token: tokenA
        )
        report.check(badBucket.status == 400, "非法 bucket 返回 400", "status=\(badBucket.status)")
        report.check(errorCode(badBucket.body) == "BAD_REQUEST", "非法 bucket 错误码为 BAD_REQUEST", "code=\(errorCode(badBucket.body))")

        let metricsResponse = client.request("GET", "\(readingsPath)/metrics", token: tokenA)
        let metricsObject = jsonObject(metricsResponse.body) ?? [:]
        let metricItems = list(metricsObject["items"])
        report.check(metricsResponse.status == 200, "metrics 返回 200", "status=\(metricsResponse.status)")
        report.check(metricItems.count == 2, "指标清单包含 2 个指标", "items=\(metricItems.count)")
        let metricDates = metricItems.compactMap { parsedDate($0, "lastAt") }
        report.check(
            metricDates.count == metricItems.count
                && zip(metricDates, metricDates.dropFirst()).allSatisfy { $0 > $1 },
            "指标清单按 lastAt 倒序",
            "lastAt=\(metricDates)"
        )
        report.check(
            metricItems.first.map { text($0, "metric") == "temperature" } ?? false,
            "最新的温度指标排在首位",
            "first=\(metricItems.first.map { text($0, "metric") } ?? "nil")"
        )
        report.check(
            metricItems.contains { item in
                text(item, "metric") == "heart_rate"
                    && (item["count"] as? NSNumber)?.intValue == 3
                    && text(item, "unit") == "bpm"
            },
            "心率指标 count 为 3、unit 为 bpm"
        )
    }

    // MARK: 8. 账号（配对码 / 导出 / 注销）

    report.section("8. 账号：配对码接管 / 异步导出 / 删除令牌注销")
    let codeResponse = client.request("POST", "auth/pairing-code", token: tokenA, json: [String: Any]())
    let codeObject = jsonObject(codeResponse.body) ?? [:]
    let firstCode = text(codeObject, "code")
    let firstExpiry = parsedDate(codeObject, "expiresAt")
    report.check(
        codeResponse.status == 200 || codeResponse.status == 201,
        "生成配对码返回 2xx",
        "status=\(codeResponse.status) body=\(bodyText(codeResponse.body))"
    )
    report.check(
        firstCode.count == 8 && firstCode.allSatisfy { $0.isUppercase || $0.isNumber },
        "配对码为 8 位大写字母/数字",
        "code=\(firstCode)"
    )
    report.check(
        firstExpiry.map { $0 > Date() } ?? false,
        "expiresAt 为真实未来时间",
        "expiresAt=\(text(codeObject, "expiresAt"))"
    )

    let regenerated = client.request("POST", "auth/pairing-code", token: tokenA, json: [String: Any]())
    let regeneratedObject = jsonObject(regenerated.body) ?? [:]
    let secondCode = text(regeneratedObject, "code")
    report.check(
        regenerated.status == 200 || regenerated.status == 201,
        "重新生成配对码返回 2xx",
        "status=\(regenerated.status)"
    )
    report.check(!secondCode.isEmpty && secondCode != firstCode, "重新生成后配对码不同")

    let staleClaim = client.request("POST", "auth/pairing-code/claim", json: ["code": firstCode])
    report.check(staleClaim.status == 404, "旧配对码重新生成后失效（404）", "status=\(staleClaim.status)")
    report.check(errorCode(staleClaim.body) == "NOT_FOUND", "旧码错误码为 NOT_FOUND", "code=\(errorCode(staleClaim.body))")

    let invalidClaim = client.request("POST", "auth/pairing-code/claim", json: ["code": "ZZZZZZZZ"])
    report.check(invalidClaim.status == 404, "不存在的配对码返回 404", "status=\(invalidClaim.status)")

    let claimResponse = client.request("POST", "auth/pairing-code/claim", json: ["code": secondCode])
    let claimObject = jsonObject(claimResponse.body) ?? [:]
    let claimedToken = text(claimObject, "token")
    report.check(
        claimResponse.status == 200 || claimResponse.status == 201,
        "接管配对码返回 2xx",
        "status=\(claimResponse.status) body=\(bodyText(claimResponse.body))"
    )
    report.check(text(claimObject, "userId") == userA, "接管后 userId 与旧设备一致", "userId=\(text(claimObject, "userId"))")
    report.check(!claimedToken.isEmpty && claimedToken != tokenA, "接管返回新 token")

    let reusedClaim = client.request("POST", "auth/pairing-code/claim", json: ["code": secondCode])
    report.check(reusedClaim.status == 404, "配对码只能使用一次（404）", "status=\(reusedClaim.status)")

    let exportCreateNoToken = client.request("POST", "me/export", json: [String: Any]())
    report.check(exportCreateNoToken.status == 401, "创建导出无 token 返回 401", "status=\(exportCreateNoToken.status)")

    // 删除令牌：Bearer 申请 → 401 无凭据 → 10 分钟有效 → 再次申请作废旧令牌
    let deletionRequestNoToken = client.request("POST", "me/deletion-request", json: [String: Any]())
    report.check(deletionRequestNoToken.status == 401, "申请删除令牌无 token 返回 401", "status=\(deletionRequestNoToken.status)")

    let firstDeletion = client.request("POST", "me/deletion-request", token: claimedToken, json: [String: Any]())
    let firstDeletionObject = jsonObject(firstDeletion.body) ?? [:]
    let firstDeletionToken = text(firstDeletionObject, "token")
    report.check(
        firstDeletion.status == 201,
        "申请删除令牌返回 201",
        "status=\(firstDeletion.status) body=\(bodyText(firstDeletion.body))"
    )
    report.check(!firstDeletionToken.isEmpty, "删除令牌非空")
    report.check(
        parsedDate(firstDeletionObject, "expiresAt").map { $0 > Date() } ?? false,
        "删除令牌 expiresAt 为未来时间",
        "expiresAt=\(text(firstDeletionObject, "expiresAt"))"
    )

    let secondDeletion = client.request("POST", "me/deletion-request", token: claimedToken, json: [String: Any]())
    let secondDeletionObject = jsonObject(secondDeletion.body) ?? [:]
    let deletionToken = text(secondDeletionObject, "token")
    report.check(secondDeletion.status == 201, "再次申请删除令牌返回 201", "status=\(secondDeletion.status)")
    report.check(!deletionToken.isEmpty && deletionToken != firstDeletionToken, "再次申请签发新令牌并作废旧令牌")

    let staleDelete = client.request("DELETE", "me", headers: ["X-Deletion-Token": firstDeletionToken])
    report.check(staleDelete.status == 403, "被作废的旧删除令牌返回 403", "status=\(staleDelete.status) body=\(bodyText(staleDelete.body))")
    report.check(
        errorCode(staleDelete.body) == "DELETION_TOKEN_INVALID",
        "旧令牌错误码为 DELETION_TOKEN_INVALID",
        "code=\(errorCode(staleDelete.body))"
    )

    let missingTokenDelete = client.request("DELETE", "me")
    report.check(missingTokenDelete.status == 400, "缺少删除令牌返回 400", "status=\(missingTokenDelete.status)")
    report.check(
        errorCode(missingTokenDelete.body) == "DELETION_TOKEN_REQUIRED",
        "缺少令牌错误码为 DELETION_TOKEN_REQUIRED",
        "code=\(errorCode(missingTokenDelete.body))"
    )

    let invalidDelete = client.request("DELETE", "me", headers: ["X-Deletion-Token": "not-a-token"])
    report.check(invalidDelete.status == 403, "错误删除令牌返回 403", "status=\(invalidDelete.status)")
    report.check(
        errorCode(invalidDelete.body) == "DELETION_TOKEN_INVALID",
        "错误令牌错误码为 DELETION_TOKEN_INVALID",
        "code=\(errorCode(invalidDelete.body))"
    )

    // 异步导出：创建 202 → 轮询 pending/ready → ready 签发一次性下载链接
    let exportCreate = client.request("POST", "me/export", token: claimedToken, json: [String: Any]())
    let exportCreateObject = jsonObject(exportCreate.body) ?? [:]
    let exportID = text(exportCreateObject, "id")
    report.check(
        exportCreate.status == 202,
        "创建导出任务返回 202",
        "status=\(exportCreate.status) body=\(bodyText(exportCreate.body))"
    )
    report.check(!exportID.isEmpty, "导出任务 id 非空")
    report.check(
        ["pending", "ready", "failed"].contains(text(exportCreateObject, "status")),
        "创建响应状态合法",
        "status=\(text(exportCreateObject, "status"))"
    )

    /// 服务端返回的是 `/api/v1/...` 相对地址；E2E 客户端 baseURL 已含 `/api/v1`，这里剥掉前缀。
    func exportRelativePath(_ raw: String) -> String? {
        guard raw.contains("/me/export/") else { return nil }
        if let range = raw.range(of: "/api/v1/") {
            return String(raw[range.upperBound...])
        }
        return raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    }

    var latestExportURL = ""
    var exportReady = false
    var exportPollCount = 0
    // 轮询次数取决于服务端何时把任务标为 ready，断言必须放到循环外，
    // 否则本机（1 次轮询）与 CI（2 次轮询）会产出不同数量的 [PASS]，项数永远对不齐。
    var pollsAllOK = true
    var pollStatusesAllValid = true
    while exportPollCount < 20 {
        exportPollCount += 1
        let poll = client.request("GET", "me/export/\(exportID)", token: claimedToken)
        let pollObject = jsonObject(poll.body) ?? [:]
        let status = text(pollObject, "status")
        if poll.status != 200 { pollsAllOK = false }
        if !["pending", "ready", "failed"].contains(status) { pollStatusesAllValid = false }
        if status == "ready" {
            exportReady = true
            latestExportURL = text(pollObject, "downloadUrl")
            report.check(!latestExportURL.isEmpty, "ready 响应含 downloadUrl")
            report.check(
                parsedDate(pollObject, "downloadExpiresAt").map { $0 > Date() } ?? false,
                "downloadExpiresAt 为未来时间",
                "downloadExpiresAt=\(text(pollObject, "downloadExpiresAt"))"
            )
            break
        }
        if status == "failed" {
            report.check(false, "导出任务不应失败", "status=\(status)")
            break
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    report.check(pollsAllOK, "每次轮询导出任务均返回 200", "polls=\(exportPollCount)")
    report.check(pollStatusesAllValid, "每次轮询状态合法", "polls=\(exportPollCount)")
    report.check(exportReady, "导出任务在限定次数内就绪", "polls=\(exportPollCount)")

    if exportReady, let exportPath = exportRelativePath(latestExportURL) {
        let download = client.request("GET", exportPath)
        let downloadedObject = jsonObject(download.body) ?? [:]
        let downloadedUser = downloadedObject["user"] as? [String: Any] ?? [:]
        report.check(download.status == 200, "一次性链接下载返回 200", "status=\(download.status)")
        report.check(
            text(downloadedUser, "id") == userA,
            "下载内容 user.id 与当前账号一致",
            "user=\(text(downloadedUser, "id"))"
        )
        report.check(!list(downloadedObject["devices"]).isEmpty, "下载内容包含本机设备")
        report.check(!list(downloadedObject["readings"]).isEmpty, "下载内容包含读数聚合")

        let replayDownload = client.request("GET", exportPath)
        report.check(replayDownload.status == 410, "同一下载链接重放返回 410", "status=\(replayDownload.status)")
        report.check(
            errorCode(replayDownload.body) == "EXPORT_DOWNLOAD_EXPIRED",
            "重放错误码为 EXPORT_DOWNLOAD_EXPIRED",
            "code=\(errorCode(replayDownload.body))"
        )

        let wrongTokenDownload = client.request("GET", "me/export/\(exportID)/download?token=wrong-token")
        report.check(wrongTokenDownload.status == 403, "错误下载令牌返回 403", "status=\(wrongTokenDownload.status)")
        report.check(
            errorCode(wrongTokenDownload.body) == "EXPORT_DOWNLOAD_INVALID",
            "错误令牌错误码为 EXPORT_DOWNLOAD_INVALID",
            "code=\(errorCode(wrongTokenDownload.body))"
        )

        // ready 时每次查询都覆盖旧链接；新链接仍可下载一次。
        let refreshedPoll = client.request("GET", "me/export/\(exportID)", token: claimedToken)
        let refreshedObject = jsonObject(refreshedPoll.body) ?? [:]
        let refreshedURL = text(refreshedObject, "downloadUrl")
        report.check(
            text(refreshedObject, "status") == "ready",
            "重新查询任务仍为 ready",
            "status=\(text(refreshedObject, "status"))"
        )
        report.check(
            !refreshedURL.isEmpty && refreshedURL != latestExportURL,
            "重新查询签发新的下载链接",
            "old=\(latestExportURL) new=\(refreshedURL)"
        )
        if let refreshedPath = exportRelativePath(refreshedURL) {
            let freshDownload = client.request("GET", refreshedPath)
            report.check(freshDownload.status == 200, "新下载链接可再次下载（200）", "status=\(freshDownload.status)")
        }
    }

    let deleteResponse = client.request("DELETE", "me", headers: ["X-Deletion-Token": deletionToken])
    report.check(
        deleteResponse.status == 204,
        "注销账号返回 204",
        "status=\(deleteResponse.status) body=\(bodyText(deleteResponse.body))"
    )
    let bearerAfterDelete = client.request("POST", "me/export", token: claimedToken, json: [String: Any]())
    report.check(bearerAfterDelete.status == 401, "注销后旧访问令牌立即失效（401）", "status=\(bearerAfterDelete.status)")
    let oldBearerAfterDelete = client.request("POST", "me/export", token: tokenA, json: [String: Any]())
    report.check(oldBearerAfterDelete.status == 401, "注销后最早 token 也失效（401）", "status=\(oldBearerAfterDelete.status)")
    let replayDelete = client.request("DELETE", "me", headers: ["X-Deletion-Token": deletionToken])
    report.check(replayDelete.status == 404, "同一删除令牌重放返回 404", "status=\(replayDelete.status) body=\(bodyText(replayDelete.body))")

    // MARK: 9. 家庭链路（创建 / 邀请码 / 成员可见 / 权限降级）

    report.section("9. 家庭：创建 / 邀请码 / 成员可见设备 / 403 与跨家庭 404")

    func anonymousAccount(_ label: String) -> (token: String, userID: String)? {
        let response = client.request("POST", "auth/anonymous", json: [String: Any]())
        let object = jsonObject(response.body) ?? [:]
        let token = text(object, "token")
        let userID = text(object, "userId")
        report.check(
            (response.status == 200 || response.status == 201) && !token.isEmpty && !userID.isEmpty,
            "匿名登录（\(label)）",
            "status=\(response.status) body=\(bodyText(response.body))"
        )
        guard !token.isEmpty else { return nil }
        return (token, userID)
    }

    guard let ownerAccount = anonymousAccount("owner"),
          let memberAccount = anonymousAccount("member"),
          let outsiderAccount = anonymousAccount("outsider")
    else {
        print("\n家庭链路所需账号创建失败。")
        return 1
    }

    // 9.1 个人家庭自动创建且不可删除
    let ownerHouseholds = client.request("GET", "households", token: ownerAccount.token)
    let ownerHouseholdItems = list((jsonObject(ownerHouseholds.body) ?? [:])["items"])
    let ownerPersonal = ownerHouseholdItems.first { ($0["personal"] as? Bool) == true } ?? [:]
    report.check(ownerHouseholds.status == 200, "owner 家庭列表返回 200", "status=\(ownerHouseholds.status)")
    report.check(ownerPersonal.isEmpty == false, "账号自动拥有个人家庭", "items=\(ownerHouseholdItems.count)")
    report.check(text(ownerPersonal, "role") == "owner", "个人家庭角色为 owner")
    let ownerPersonalID = text(ownerPersonal, "id")
    let deletePersonal = client.request("DELETE", "households/\(ownerPersonalID)", token: ownerAccount.token)
    report.check(deletePersonal.status == 403, "个人家庭不可删除（403）", "status=\(deletePersonal.status)")
    report.check(errorCode(deletePersonal.body) == "FORBIDDEN", "个人家庭删除错误码为 FORBIDDEN", "code=\(errorCode(deletePersonal.body))")

    // 9.2 创建家庭
    let createdHousehold = client.request(
        "POST", "households", token: ownerAccount.token, json: ["name": "e2e-家庭"]
    )
    let householdObject = jsonObject(createdHousehold.body) ?? [:]
    let householdID = text(householdObject, "id")
    report.check(createdHousehold.status == 201, "创建家庭返回 201", "status=\(createdHousehold.status) body=\(bodyText(createdHousehold.body))")
    report.check(!householdID.isEmpty, "创建家庭返回 id")
    report.check(text(householdObject, "role") == "owner", "创建者为 owner", "role=\(text(householdObject, "role"))")
    report.check((householdObject["personal"] as? Bool) == false, "新建家庭不是个人家庭")
    report.check((householdObject["memberCount"] as? NSNumber)?.intValue == 1, "新建家庭成员数为 1")

    // 9.3 邀请码：8 位、未来到期、一次性
    let invitation = client.request("POST", "households/\(householdID)/invitations", token: ownerAccount.token, json: [String: Any]())
    let invitationObject = jsonObject(invitation.body) ?? [:]
    let invitationCode = text(invitationObject, "code")
    let invitationExpiry = parsedDate(invitationObject, "expiresAt")
    report.check(invitation.status == 201, "签发邀请码返回 201", "status=\(invitation.status) body=\(bodyText(invitation.body))")
    report.check(
        invitationCode.count == 8 && invitationCode.allSatisfy { $0.isUppercase || $0.isNumber },
        "邀请码为 8 位大写字母/数字",
        "code=\(invitationCode)"
    )
    report.check(
        invitationExpiry.map { $0 > Date() } ?? false,
        "邀请码 expiresAt 为未来时间",
        "expiresAt=\(text(invitationObject, "expiresAt"))"
    )

    // 9.4 第二个账号用邀请码加入（小写码应被规范化）
    let joinResponse = client.request(
        "POST", "households/invitations/claim", token: memberAccount.token,
        json: ["code": invitationCode.lowercased()]
    )
    let joinedObject = jsonObject(joinResponse.body) ?? [:]
    report.check(joinResponse.status == 200, "成员领取邀请码返回 200", "status=\(joinResponse.status) body=\(bodyText(joinResponse.body))")
    report.check(text(joinedObject, "id") == householdID, "领取后返回同一家庭", "id=\(text(joinedObject, "id"))")
    report.check(text(joinedObject, "role") == "member", "领取者角色为 member", "role=\(text(joinedObject, "role"))")
    report.check((joinedObject["memberCount"] as? NSNumber)?.intValue == 2, "加入后成员数为 2")

    let memberHouseholds = client.request("GET", "households", token: memberAccount.token)
    let memberItems = list((jsonObject(memberHouseholds.body) ?? [:])["items"])
    let memberShared = memberItems.first { text($0, "id") == householdID } ?? [:]
    report.check(memberHouseholds.status == 200, "成员家庭列表返回 200", "status=\(memberHouseholds.status)")
    report.check(memberItems.count == 2, "成员可见共享家庭与个人家庭", "items=\(memberItems.count)")
    report.check(text(memberShared, "role") == "member", "成员在共享家庭中角色为 member")
    let memberPersonal = memberItems.first { ($0["personal"] as? Bool) == true } ?? [:]
    let memberPersonalID = text(memberPersonal, "id")

    let membersResponse = client.request("GET", "households/\(householdID)/members", token: memberAccount.token)
    let memberList = list((jsonObject(membersResponse.body) ?? [:])["items"])
    report.check(membersResponse.status == 200, "成员列表返回 200", "status=\(membersResponse.status)")
    report.check(memberList.count == 2, "成员列表包含 owner 与 member", "items=\(memberList.count)")
    report.check(
        memberList.contains { text($0, "userId") == ownerAccount.userID && text($0, "role") == "owner" }
            && memberList.contains { text($0, "userId") == memberAccount.userID && text($0, "role") == "member" },
        "成员角色与账号对应"
    )
    let selfRows = memberList.filter { ($0["isSelf"] as? Bool) == true }
    report.check(selfRows.count == 1, "成员列表恰有一行 isSelf=true", "count=\(selfRows.count)")
    report.check(
        selfRows.first.map { text($0, "userId") == memberAccount.userID } ?? false,
        "isSelf=true 的行就是调用者本人",
        "userId=\(selfRows.first.map { text($0, "userId") } ?? "")"
    )

    // 9.5 房间归属设备，成员可见
    let roomResponse = client.request(
        "POST", "households/\(householdID)/rooms", token: ownerAccount.token,
        json: ["name": "客厅", "sortOrder": 1]
    )
    let roomObject = jsonObject(roomResponse.body) ?? [:]
    let roomID = text(roomObject, "id")
    report.check(roomResponse.status == 201, "创建房间返回 201", "status=\(roomResponse.status) body=\(bodyText(roomResponse.body))")
    report.check(text(roomObject, "householdId") == householdID, "房间归属该家庭")
    report.check((roomObject["sortOrder"] as? NSNumber)?.intValue == 1, "房间排序写入")

    let householdDeviceID = "55555555-5555-4555-8555-555555555555"
    let householdExternalID = householdDeviceID.uppercased()
    let householdPush = client.request(
        "POST", "sync/push", token: ownerAccount.token,
        idempotencyKey: "e2e-household-\(Int(Date().timeIntervalSince1970))",
        json: [
            "clientId": clientID,
            "devices": [madeDevice(
                id: householdDeviceID,
                platform: "ios",
                externalID: householdExternalID,
                mac: nil,
                alias: "家庭设备",
                updatedAt: Date(timeIntervalSinceNow: -5)
            )],
        ]
    )
    report.check(householdPush.status == 200, "家庭设备 push 返回 200", "status=\(householdPush.status) body=\(bodyText(householdPush.body))")

    let assignResponse = client.request(
        "PATCH", "my/devices/ios/\(householdExternalID)", token: ownerAccount.token,
        json: ["householdId": householdID, "roomId": roomID]
    )
    let assignedObject = jsonObject(assignResponse.body) ?? [:]
    report.check(assignResponse.status == 200, "PATCH 设备归属返回 200", "status=\(assignResponse.status) body=\(bodyText(assignResponse.body))")
    report.check(text(assignedObject, "householdId") == householdID, "设备 householdId 已覆盖", "householdId=\(text(assignedObject, "householdId"))")
    report.check(text(assignedObject, "roomId") == roomID, "设备 roomId 已覆盖", "roomId=\(text(assignedObject, "roomId"))")

    let memberDevices = client.request("GET", "my/devices", token: memberAccount.token)
    let memberDeviceItems = list((jsonObject(memberDevices.body) ?? [:])["items"])
    let visibleDevice = memberDeviceItems.first { text($0, "id") == householdDeviceID }
    report.check(memberDevices.status == 200, "成员设备列表返回 200", "status=\(memberDevices.status)")
    report.check(visibleDevice != nil, "成员可见家庭内他人设备", "items=\(memberDeviceItems.count)")
    if let visibleDevice {
        report.check(text(visibleDevice, "householdId") == householdID, "成员看到的设备归属该家庭")
        report.check(text(visibleDevice, "roomId") == roomID, "成员看到的设备在房间内")
    }

    let outsiderDevices = client.request("GET", "my/devices", token: outsiderAccount.token)
    report.check(
        list((jsonObject(outsiderDevices.body) ?? [:])["items"]).contains { text($0, "id") == householdDeviceID } == false,
        "非成员看不到该设备",
        "items=\(list((jsonObject(outsiderDevices.body) ?? [:])["items"]).count)"
    )

    // 9.6 member 写操作 403 FORBIDDEN（可读降级）
    let memberRoomPatch = client.request(
        "PATCH", "households/\(householdID)/rooms/\(roomID)", token: memberAccount.token,
        json: ["name": "成员改房"]
    )
    report.check(memberRoomPatch.status == 403, "member 改房间返回 403", "status=\(memberRoomPatch.status) body=\(bodyText(memberRoomPatch.body))")
    report.check(errorCode(memberRoomPatch.body) == "FORBIDDEN", "member 改房间错误码为 FORBIDDEN", "code=\(errorCode(memberRoomPatch.body))")

    let memberRoomCreate = client.request(
        "POST", "households/\(householdID)/rooms", token: memberAccount.token,
        json: ["name": "成员建房"]
    )
    report.check(memberRoomCreate.status == 403, "member 建房返回 403", "status=\(memberRoomCreate.status)")

    let memberInvitation = client.request(
        "POST", "households/\(householdID)/invitations", token: memberAccount.token, json: [String: Any]()
    )
    report.check(memberInvitation.status == 403, "member 签发邀请码返回 403", "status=\(memberInvitation.status)")

    let memberHouseholdPatch = client.request(
        "PATCH", "households/\(householdID)", token: memberAccount.token, json: ["name": "成员改名"]
    )
    report.check(memberHouseholdPatch.status == 403, "member 改家庭名返回 403", "status=\(memberHouseholdPatch.status)")

    let memberDevicePatch = client.request(
        "PATCH", "my/devices/ios/\(householdExternalID)", token: memberAccount.token,
        json: ["alias": "成员改别名"]
    )
    report.check(memberDevicePatch.status == 404, "member 改他人设备返回 404（不泄露存在性）", "status=\(memberDevicePatch.status)")

    // 9.7 跨家庭 / 一次性邀请码 / 非成员一律 404
    let secondHousehold = client.request(
        "POST", "households", token: ownerAccount.token, json: ["name": "e2e-第二家庭"]
    )
    let secondHouseholdID = text(jsonObject(secondHousehold.body) ?? [:], "id")
    report.check(secondHousehold.status == 201 && !secondHouseholdID.isEmpty, "owner 创建第二个家庭", "status=\(secondHousehold.status)")

    // 用例名不嵌入随机家庭 id，否则每次运行的两份 PASS 清单都无法直接 diff；
    // 真实 id 放 detail，失败时仍可定位。
    for (label, path) in [
        ("家庭信息", "households/\(secondHouseholdID)"),
        ("成员列表", "households/\(secondHouseholdID)/members"),
        ("房间列表", "households/\(secondHouseholdID)/rooms"),
    ] {
        let crossResponse = client.request("GET", path, token: memberAccount.token)
        report.check(crossResponse.status == 404, "跨家庭读取\(label)返回 404", "path=\(path) status=\(crossResponse.status)")
        report.check(errorCode(crossResponse.body) == "NOT_FOUND", "跨家庭读取\(label)错误码为 NOT_FOUND", "path=\(path) code=\(errorCode(crossResponse.body))")
    }
    let outsiderGet = client.request("GET", "households/\(householdID)", token: outsiderAccount.token)
    report.check(outsiderGet.status == 404, "非成员读取家庭返回 404", "status=\(outsiderGet.status)")
    let outsiderRoomPatch = client.request(
        "PATCH", "households/\(householdID)/rooms/\(roomID)", token: outsiderAccount.token,
        json: ["name": "外人改房"]
    )
    report.check(outsiderRoomPatch.status == 404, "非成员改房间返回 404", "status=\(outsiderRoomPatch.status)")

    let reusedInvitation = client.request(
        "POST", "households/invitations/claim", token: outsiderAccount.token,
        json: ["code": invitationCode]
    )
    report.check(reusedInvitation.status == 404, "邀请码一次性（重复领取 404）", "status=\(reusedInvitation.status)")
    report.check(errorCode(reusedInvitation.body) == "NOT_FOUND", "重复邀请码错误码为 NOT_FOUND", "code=\(errorCode(reusedInvitation.body))")
    let invalidInvitation = client.request(
        "POST", "households/invitations/claim", token: outsiderAccount.token,
        json: ["code": "ZZZZZZZZ"]
    )
    report.check(invalidInvitation.status == 404, "不存在邀请码返回 404", "status=\(invalidInvitation.status)")

    // 9.8 设备归属三态：缺失=不变 / 空串=清除 / 非空=覆盖
    let aliasOnly = client.request(
        "PATCH", "my/devices/ios/\(householdExternalID)", token: ownerAccount.token,
        json: ["alias": "家庭设备·改名"]
    )
    let aliasOnlyObject = jsonObject(aliasOnly.body) ?? [:]
    report.check(aliasOnly.status == 200, "仅改 alias 返回 200", "status=\(aliasOnly.status)")
    report.check(text(aliasOnlyObject, "alias") == "家庭设备·改名", "alias 已覆盖")
    report.check(text(aliasOnlyObject, "roomId") == roomID, "缺失 roomId 时归属不变", "roomId=\(text(aliasOnlyObject, "roomId"))")
    report.check(text(aliasOnlyObject, "householdId") == householdID, "缺失 householdId 时归属不变")

    let clearRoom = client.request(
        "PATCH", "my/devices/ios/\(householdExternalID)", token: ownerAccount.token,
        json: ["roomId": ""]
    )
    let clearRoomObject = jsonObject(clearRoom.body) ?? [:]
    report.check(clearRoom.status == 200, "空串清房间返回 200", "status=\(clearRoom.status)")
    report.check(clearRoomObject["roomId"] is NSNull, "空串清除 roomId", "body=\(bodyText(clearRoom.body))")
    report.check(text(clearRoomObject, "householdId") == householdID, "清房间不影响 householdId")

    let setRoomAgain = client.request(
        "PATCH", "my/devices/ios/\(householdExternalID)", token: ownerAccount.token,
        json: ["roomId": roomID]
    )
    report.check(setRoomAgain.status == 200 && text(jsonObject(setRoomAgain.body) ?? [:], "roomId") == roomID, "非空值覆盖 roomId")

    let clearHousehold = client.request(
        "PATCH", "my/devices/ios/\(householdExternalID)", token: ownerAccount.token,
        json: ["householdId": ""]
    )
    let clearHouseholdObject = jsonObject(clearHousehold.body) ?? [:]
    report.check(clearHousehold.status == 200, "空串清家庭返回 200", "status=\(clearHousehold.status)")
    report.check(text(clearHouseholdObject, "householdId") == ownerPersonalID, "空串 householdId 回到个人家庭", "householdId=\(text(clearHouseholdObject, "householdId"))")
    report.check(clearHouseholdObject["roomId"] is NSNull, "回到个人家庭后 roomId 为 null")

    // 9.9 删除共享家庭：房间与成员级联清理，设备回到个人家庭
    let backToHousehold = client.request(
        "PATCH", "my/devices/ios/\(householdExternalID)", token: ownerAccount.token,
        json: ["householdId": householdID, "roomId": roomID]
    )
    report.check(backToHousehold.status == 200, "设备重新归属共享家庭", "status=\(backToHousehold.status)")

    let deleteShared = client.request("DELETE", "households/\(householdID)", token: ownerAccount.token)
    report.check(deleteShared.status == 204, "owner 删除共享家庭返回 204", "status=\(deleteShared.status) body=\(bodyText(deleteShared.body))")

    let afterDeleteDetail = client.request("GET", "households/\(householdID)", token: ownerAccount.token)
    report.check(afterDeleteDetail.status == 404, "删除后家庭 404", "status=\(afterDeleteDetail.status)")
    let memberAfterDelete = client.request("GET", "households", token: memberAccount.token)
    let memberAfterDeleteItems = list((jsonObject(memberAfterDelete.body) ?? [:])["items"])
    report.check(
        memberAfterDeleteItems.contains { text($0, "id") == householdID } == false,
        "成员列表不再包含已删家庭",
        "items=\(memberAfterDeleteItems.count)"
    )
    let deviceAfterDelete = client.request("GET", "my/devices/ios/\(householdExternalID)", token: ownerAccount.token)
    let deviceAfterDeleteObject = jsonObject(deviceAfterDelete.body) ?? [:]
    report.check(deviceAfterDelete.status == 200, "设备本身未被删除", "status=\(deviceAfterDelete.status)")
    report.check(
        text(deviceAfterDeleteObject, "householdId") == ownerPersonalID && deviceAfterDeleteObject["roomId"] is NSNull,
        "删除家庭后设备回到个人家庭且房间清空",
        "body=\(bodyText(deviceAfterDelete.body))"
    )

    // 9.10 成员移除 / 退出 / 邀请码管理 / 整段重排（后端 v0.13.0）
    let managementHousehold = client.request(
        "POST", "households", token: ownerAccount.token, json: ["name": "e2e-成员管理"]
    )
    let managementID = text(jsonObject(managementHousehold.body) ?? [:], "id")
    report.check(
        managementHousehold.status == 201 && !managementID.isEmpty,
        "创建成员管理家庭",
        "status=\(managementHousehold.status)"
    )

    let managementInvite = client.request(
        "POST", "households/\(managementID)/invitations", token: ownerAccount.token, json: [String: Any]()
    )
    let managementCode = text(jsonObject(managementInvite.body) ?? [:], "code")
    let memberClaim = client.request(
        "POST", "households/invitations/claim", token: memberAccount.token, json: ["code": managementCode]
    )
    report.check(memberClaim.status == 200, "成员领取新家庭邀请码", "status=\(memberClaim.status)")

    // 邀请码列表：只返回哈希前缀与状态，绝不出现明文
    let secondInvite = client.request(
        "POST", "households/\(managementID)/invitations", token: ownerAccount.token, json: [String: Any]()
    )
    let managementSecondCode = text(jsonObject(secondInvite.body) ?? [:], "code")
    let invitationList = client.request("GET", "households/\(managementID)/invitations", token: ownerAccount.token)
    let invitationItems = list((jsonObject(invitationList.body) ?? [:])["items"])
    report.check(invitationList.status == 200, "owner 拉取邀请码列表返回 200", "status=\(invitationList.status)")
    report.check(invitationItems.count >= 1, "邀请码列表包含未使用邀请码", "items=\(invitationItems.count)")
    let listedInvitation = invitationItems.first ?? [:]
    report.check(!text(listedInvitation, "codeHashPrefix").isEmpty, "邀请码列表返回哈希前缀")
    report.check(listedInvitation["code"] == nil, "邀请码列表不含明文字段")
    report.check(
        !bodyText(invitationList.body).uppercased().contains(managementSecondCode.uppercased()),
        "邀请码列表响应不含明文码"
    )
    report.check(text(listedInvitation, "status") == "active", "邀请码状态为 active", "status=\(text(listedInvitation, "status"))")
    let listedInvitationID = text(listedInvitation, "id")

    let revokeResponse = client.request(
        "DELETE", "households/\(managementID)/invitations/\(listedInvitationID)", token: ownerAccount.token
    )
    report.check(revokeResponse.status == 204, "撤销邀请码返回 204", "status=\(revokeResponse.status)")
    let claimRevoked = client.request(
        "POST", "households/invitations/claim", token: outsiderAccount.token, json: ["code": managementSecondCode]
    )
    report.check(claimRevoked.status == 404, "撤销后领取返回 404", "status=\(claimRevoked.status)")

    // 整段重排：完整集合成功，缺项 / 多项 / 重复一律 409 ROOM_SET_MISMATCH
    var orderRoomIDs: [String] = []
    for (index, name) in ["客厅", "卧室", "书房"].enumerated() {
        let response = client.request(
            "POST", "households/\(managementID)/rooms", token: ownerAccount.token,
            json: ["name": name, "sortOrder": index + 1]
        )
        report.check(response.status == 201, "创建排序房间 \(name)", "status=\(response.status)")
        orderRoomIDs.append(text(jsonObject(response.body) ?? [:], "id"))
    }
    let fullOrder = client.request(
        "PUT", "households/\(managementID)/rooms/order", token: ownerAccount.token,
        json: ["roomIds": [orderRoomIDs[2], orderRoomIDs[0], orderRoomIDs[1]]]
    )
    let fullOrderItems = list((jsonObject(fullOrder.body) ?? [:])["items"])
    report.check(fullOrder.status == 200, "完整整段重排返回 200", "status=\(fullOrder.status) body=\(bodyText(fullOrder.body))")
    report.check(text(fullOrderItems.first ?? [:], "id") == orderRoomIDs[2], "整段重排生效（书房置首）")
    report.check(
        fullOrderItems.enumerated().allSatisfy { (($0.element["sortOrder"] as? NSNumber)?.intValue ?? -1) == $0.offset },
        "整段重排 sortOrder 按 0..n-1 连续"
    )

    let missingOrder = client.request(
        "PUT", "households/\(managementID)/rooms/order", token: ownerAccount.token,
        json: ["roomIds": [orderRoomIDs[0], orderRoomIDs[1]]]
    )
    report.check(missingOrder.status == 409, "重排缺项返回 409", "status=\(missingOrder.status)")
    let missingCode = errorCode(missingOrder.body)
    report.check(
        missingCode == "ROOM_SET_MISMATCH" || missingCode == "CONFLICT",
        "重排缺项返回 409 且错误码可机读（v0.13.0=CONFLICT，后续版本=ROOM_SET_MISMATCH）",
        "code=\(missingCode)"
    )
    let extraOrder = client.request(
        "PUT", "households/\(managementID)/rooms/order", token: ownerAccount.token,
        json: ["roomIds": orderRoomIDs + ["00000000-0000-4000-8000-000000000000"]]
    )
    report.check(extraOrder.status == 409, "重排多项返回 409", "status=\(extraOrder.status)")
    let duplicateOrder = client.request(
        "PUT", "households/\(managementID)/rooms/order", token: ownerAccount.token,
        json: ["roomIds": [orderRoomIDs[0], orderRoomIDs[0], orderRoomIDs[1]]]
    )
    report.check(duplicateOrder.status == 409, "重排重复返回 409", "status=\(duplicateOrder.status)")

    // 家庭列表计数为服务端真实数字
    let managementList = client.request("GET", "households", token: ownerAccount.token)
    let managementItems = list((jsonObject(managementList.body) ?? [:])["items"])
    let managementObject = managementItems.first { text($0, "id") == managementID } ?? [:]
    report.check(managementList.status == 200, "owner 家庭列表返回 200", "status=\(managementList.status)")
    report.check(
        (managementObject["memberCount"] as? NSNumber)?.intValue == 2,
        "memberCount 为服务端真实值 2",
        "memberCount=\(managementObject["memberCount"] ?? "nil")"
    )
    report.check(
        (managementObject["roomCount"] as? NSNumber)?.intValue == 3,
        "roomCount 为服务端真实值 3",
        "roomCount=\(managementObject["roomCount"] ?? "nil")"
    )
    report.check(
        (managementObject["deviceCount"] as? NSNumber)?.intValue == 0,
        "deviceCount 为服务端真实值 0",
        "deviceCount=\(managementObject["deviceCount"] ?? "nil")"
    )

    // 成员设备加入家庭，移除后回个人家庭
    let memberDeviceID = "66666666-6666-4666-8666-666666666666"
    let memberExternalID = memberDeviceID.uppercased()
    let memberPush = client.request(
        "POST", "sync/push", token: memberAccount.token,
        idempotencyKey: "e2e-member-device-\(Int(Date().timeIntervalSince1970))",
        json: [
            "clientId": clientID,
            "devices": [madeDevice(
                id: memberDeviceID,
                platform: "ios",
                externalID: memberExternalID,
                mac: nil,
                alias: "成员设备",
                updatedAt: Date(timeIntervalSinceNow: -5)
            )],
        ]
    )
    report.check(memberPush.status == 200, "成员设备 push 返回 200", "status=\(memberPush.status)")
    let memberAssign = client.request(
        "PATCH", "my/devices/ios/\(memberExternalID)", token: memberAccount.token,
        json: ["householdId": managementID, "roomId": orderRoomIDs[0]]
    )
    report.check(memberAssign.status == 200, "成员设备归属家庭", "status=\(memberAssign.status)")

    // owner 还有其他成员时不能退出
    let ownerLeaveConflict = client.request("POST", "households/\(managementID)/leave", token: ownerAccount.token)
    report.check(ownerLeaveConflict.status == 409, "owner 带成员退出返回 409", "status=\(ownerLeaveConflict.status)")
    report.check(
        errorCode(ownerLeaveConflict.body) == "CONFLICT",
        "退出冲突错误码为 CONFLICT",
        "code=\(errorCode(ownerLeaveConflict.body))"
    )
    report.check(
        errorMessage(ownerLeaveConflict.body).isEmpty == false,
        "退出冲突带可读 message",
        "body=\(bodyText(ownerLeaveConflict.body))"
    )

    // 移除成员 → 对方 404，设备回其个人家庭且房间清空
    let removeMember = client.request(
        "DELETE", "households/\(managementID)/members/\(memberAccount.userID)", token: ownerAccount.token
    )
    report.check(removeMember.status == 204, "owner 移除成员返回 204", "status=\(removeMember.status)")
    let removedMemberGet = client.request("GET", "households/\(managementID)", token: memberAccount.token)
    report.check(removedMemberGet.status == 404, "被移除成员访问家庭返回 404", "status=\(removedMemberGet.status)")
    let memberDeviceAfter = client.request("GET", "my/devices/ios/\(memberExternalID)", token: memberAccount.token)
    let memberDeviceAfterObject = jsonObject(memberDeviceAfter.body) ?? [:]
    report.check(memberDeviceAfter.status == 200, "成员设备仍存在", "status=\(memberDeviceAfter.status)")
    report.check(
        text(memberDeviceAfterObject, "householdId") == memberPersonalID,
        "移除后设备回到成员个人家庭",
        "householdId=\(text(memberDeviceAfterObject, "householdId"))"
    )
    report.check(memberDeviceAfterObject["roomId"] is NSNull, "移除后设备房间清空")

    // 移除后 owner 可退出，家庭被删除
    let ownerLeave = client.request("POST", "households/\(managementID)/leave", token: ownerAccount.token)
    report.check(ownerLeave.status == 204, "移除成员后 owner 退出返回 204", "status=\(ownerLeave.status)")
    let managementAfterLeave = client.request("GET", "households/\(managementID)", token: ownerAccount.token)
    report.check(managementAfterLeave.status == 404, "退出后家庭 404", "status=\(managementAfterLeave.status)")

    // 9.12 所有权转让（后端 v0.14.0）与结构变更进 change_log（后端 v0.15.0）
    let transferHousehold = client.request(
        "POST", "households", token: ownerAccount.token, json: ["name": "e2e-转让"]
    )
    let transferID = text(jsonObject(transferHousehold.body) ?? [:], "id")
    report.check(
        transferHousehold.status == 201 && !transferID.isEmpty,
        "创建转让家庭",
        "status=\(transferHousehold.status)"
    )
    let transferInvite = client.request(
        "POST", "households/\(transferID)/invitations", token: ownerAccount.token, json: [String: Any]()
    )
    let transferCode = text(jsonObject(transferInvite.body) ?? [:], "code")
    let transferClaim = client.request(
        "POST", "households/invitations/claim", token: memberAccount.token, json: ["code": transferCode]
    )
    report.check(transferClaim.status == 200, "成员加入转让家庭", "status=\(transferClaim.status)")

    func payloadObject(_ change: [String: Any]) -> [String: Any] {
        change["payload"] as? [String: Any] ?? [:]
    }

    func syncChanges(token: String) -> [[String: Any]] {
        let response = client.request("GET", "sync/changes?cursor=0&limit=500", token: token)
        return list((jsonObject(response.body) ?? [:])["changes"])
    }

    let ownerMemberRows = list((jsonObject(client.request(
        "GET", "households/\(transferID)/members", token: ownerAccount.token
    ).body) ?? [:])["items"])
    let ownerSelfRow = ownerMemberRows.first { ($0["isSelf"] as? Bool) == true } ?? [:]
    report.check(
        text(ownerSelfRow, "userId") == ownerAccount.userID && text(ownerSelfRow, "role") == "owner",
        "owner 视角 isSelf 指向本人且为 owner",
        "userId=\(text(ownerSelfRow, "userId"))"
    )

    // 非成员转让目标 404；member 无权转让 403；本人 → 400
    let transferToOutsider = client.request(
        "POST", "households/\(transferID)/transfer-ownership", token: ownerAccount.token,
        json: ["userId": outsiderAccount.userID]
    )
    report.check(transferToOutsider.status == 404, "转让给非成员返回 404", "status=\(transferToOutsider.status)")
    report.check(
        errorCode(transferToOutsider.body) == "NOT_FOUND" && !errorMessage(transferToOutsider.body).isEmpty,
        "转让 404 带可读 message",
        "body=\(bodyText(transferToOutsider.body))"
    )
    let memberTransfer = client.request(
        "POST", "households/\(transferID)/transfer-ownership", token: memberAccount.token,
        json: ["userId": ownerAccount.userID]
    )
    report.check(memberTransfer.status == 403, "member 转让返回 403", "status=\(memberTransfer.status)")
    report.check(errorCode(memberTransfer.body) == "FORBIDDEN", "member 转让错误码为 FORBIDDEN")
    let selfTransfer = client.request(
        "POST", "households/\(transferID)/transfer-ownership", token: ownerAccount.token,
        json: ["userId": ownerAccount.userID]
    )
    report.check(selfTransfer.status == 400, "转让给自己返回 400", "status=\(selfTransfer.status)")

    // 转让成功：调用者降为 member，接收者成为 owner
    let transferSuccess = client.request(
        "POST", "households/\(transferID)/transfer-ownership", token: ownerAccount.token,
        json: ["userId": memberAccount.userID]
    )
    let transferObject = jsonObject(transferSuccess.body) ?? [:]
    report.check(transferSuccess.status == 200, "转让所有权返回 200", "status=\(transferSuccess.status) body=\(bodyText(transferSuccess.body))")
    report.check(text(transferObject, "role") == "member", "转让后原 owner 角色为 member", "role=\(text(transferObject, "role"))")
    report.check(text(transferObject, "ownerUserId") == memberAccount.userID, "家庭 ownerUserId 指向新 owner")

    let afterTransferRows = list((jsonObject(client.request(
        "GET", "households/\(transferID)/members", token: ownerAccount.token
    ).body) ?? [:])["items"])
    let formerOwnerRow = afterTransferRows.first { text($0, "userId") == ownerAccount.userID } ?? [:]
    let newOwnerRow = afterTransferRows.first { text($0, "userId") == memberAccount.userID } ?? [:]
    report.check(text(formerOwnerRow, "role") == "member", "原 owner 在成员列表降为 member")
    report.check(text(newOwnerRow, "role") == "owner", "新 owner 在成员列表为 owner")
    report.check(
        afterTransferRows.first { ($0["isSelf"] as? Bool) == true }.map { text($0, "userId") == ownerAccount.userID } ?? false,
        "原 owner 视角 isSelf 仍指向本人"
    )

    // 权限随角色翻转：原 owner 改名 / 邀请 403，新 owner 可改名
    let formerRename = client.request(
        "PATCH", "households/\(transferID)", token: ownerAccount.token, json: ["name": "原 owner 改名"]
    )
    report.check(formerRename.status == 403, "原 owner 改名返回 403", "status=\(formerRename.status)")
    let formerInvite = client.request(
        "POST", "households/\(transferID)/invitations", token: ownerAccount.token, json: [String: Any]()
    )
    report.check(formerInvite.status == 403, "原 owner 签发邀请码返回 403", "status=\(formerInvite.status)")
    let newRename = client.request(
        "PATCH", "households/\(transferID)", token: memberAccount.token, json: ["name": "e2e-转让-改名"]
    )
    report.check(newRename.status == 200, "新 owner 改名返回 200", "status=\(newRename.status)")
    report.check(text(jsonObject(newRename.body) ?? [:], "name") == "e2e-转让-改名", "家庭名已更新")

    // 结构变更进入双方 change_log：household upsert 的角色按接收者计算
    let ownerChangesAfterTransfer = syncChanges(token: ownerAccount.token)
    let ownerHouseholdChanges = ownerChangesAfterTransfer.filter {
        text($0, "entity") == "household" && text($0, "entityId") == transferID
    }
    let ownerLatestHousehold = ownerHouseholdChanges.last.map(payloadObject) ?? [:]
    report.check(
        !ownerHouseholdChanges.isEmpty && text(ownerLatestHousehold, "role") == "member",
        "原 owner 收到 household upsert 且 role=member",
        "payload=\(ownerLatestHousehold)"
    )
    let memberChangesAfterTransfer = syncChanges(token: memberAccount.token)
    let memberHouseholdChanges = memberChangesAfterTransfer.filter {
        text($0, "entity") == "household" && text($0, "entityId") == transferID
    }
    let memberLatestHousehold = memberHouseholdChanges.last.map(payloadObject) ?? [:]
    report.check(
        text(memberLatestHousehold, "role") == "owner" && text(memberLatestHousehold, "name") == "e2e-转让-改名",
        "新 owner 收到 household upsert（role=owner 且名字已更新）",
        "payload=\(memberLatestHousehold)"
    )
    report.check(
        (memberLatestHousehold["memberCount"] as? NSNumber)?.intValue == 2,
        "household payload 带服务端 memberCount",
        "payload=\(memberLatestHousehold)"
    )

    // 房间结构：新增 / 改名 / 删除都进 change_log
    let structRoom = client.request(
        "POST", "households/\(transferID)/rooms", token: memberAccount.token,
        json: ["name": "结构-客厅", "sortOrder": 1]
    )
    let structRoomID = text(jsonObject(structRoom.body) ?? [:], "id")
    report.check(structRoom.status == 201 && !structRoomID.isEmpty, "新 owner 建房", "status=\(structRoom.status)")
    let roomRename = client.request(
        "PATCH", "households/\(transferID)/rooms/\(structRoomID)", token: memberAccount.token,
        json: ["name": "结构-起居室"]
    )
    report.check(roomRename.status == 200, "新 owner 改名房间", "status=\(roomRename.status)")
    let roomDelete = client.request("DELETE", "households/\(transferID)/rooms/\(structRoomID)", token: memberAccount.token)
    report.check(roomDelete.status == 204, "新 owner 删房", "status=\(roomDelete.status)")

    for (label, token) in [("原 owner", ownerAccount.token), ("新 owner", memberAccount.token)] {
        let roomChanges = syncChanges(token: token).filter {
            text($0, "entity") == "room" && text($0, "entityId") == structRoomID
        }
        let renamed = roomChanges.map(payloadObject).first { text($0, "name") == "结构-起居室" }
        report.check(
            renamed != nil && text(renamed ?? [:], "householdId") == transferID,
            "\(label) 收到 room upsert（改名 + householdId）",
            "count=\(roomChanges.count)"
        )
        let deleted = roomChanges.map(payloadObject).last
        report.check(
            (deleted?["deleted"] as? Bool) == true,
            "\(label) 收到 room delete（deleted=true）",
            "payload=\(deleted ?? [:])"
        )
        report.check(
            (deleted?["sortOrder"] as? NSNumber)?.intValue == 1,
            "room delete payload 保留 sortOrder",
            "payload=\(deleted ?? [:])"
        )
    }

    // 移除成员后的可见性：被移除者不再收到后续结构变更，历史行仍可读
    let removedBeforeChanges = syncChanges(token: ownerAccount.token)
    let removedHistoricalHousehold = removedBeforeChanges.filter {
        text($0, "entity") == "household" && text($0, "entityId") == transferID
    }
    report.check(!removedHistoricalHousehold.isEmpty, "被移除前的历史 household 变更仍可读")
    let removeFormerOwner = client.request(
        "DELETE", "households/\(transferID)/members/\(ownerAccount.userID)", token: memberAccount.token
    )
    report.check(removeFormerOwner.status == 204, "新 owner 移除原 owner 返回 204", "status=\(removeFormerOwner.status)")
    let formerOwnerAfterRemoval = client.request("GET", "households/\(transferID)", token: ownerAccount.token)
    report.check(formerOwnerAfterRemoval.status == 404, "被移除成员访问家庭返回 404", "status=\(formerOwnerAfterRemoval.status)")

    // 接收方计数更新
    let newOwnerHouseholdChanges = syncChanges(token: memberAccount.token).filter {
        text($0, "entity") == "household" && text($0, "entityId") == transferID
    }
    let latestAfterRemoval = newOwnerHouseholdChanges.last.map(payloadObject) ?? [:]
    report.check(
        (latestAfterRemoval["memberCount"] as? NSNumber)?.intValue == 1,
        "移除成员后新 owner 收到 memberCount=1 的 household upsert",
        "payload=\(latestAfterRemoval)"
    )
    // 被移除者：移除之后不应再出现该家庭的新 household 行
    let removedAfter = syncChanges(token: ownerAccount.token).filter {
        text($0, "entity") == "household" && text($0, "entityId") == transferID
    }
    report.check(
        removedAfter.count == removedHistoricalHousehold.count,
        "被移除成员不再收到该家庭的新结构变更",
        "before=\(removedHistoricalHousehold.count) after=\(removedAfter.count)"
    )

    // 解散家庭：剩余 owner 收到 household delete
    let deleteTransferHousehold = client.request("DELETE", "households/\(transferID)", token: memberAccount.token)
    report.check(deleteTransferHousehold.status == 204, "新 owner 解散家庭返回 204", "status=\(deleteTransferHousehold.status)")
    let deleteHouseholdChanges = syncChanges(token: memberAccount.token).filter {
        text($0, "entity") == "household" && text($0, "entityId") == transferID
    }
    let deletePayload = deleteHouseholdChanges.last.map(payloadObject) ?? [:]
    report.check(
        (deletePayload["deleted"] as? Bool) == true,
        "家庭解散推送 household delete（deleted=true）",
        "payload=\(deletePayload)"
    )

    // 9.13 账号删除阻塞：owner 家庭仍有成员 → 409；转让所有权后同一未消耗令牌仍可用
    let blockedHousehold = client.request(
        "POST", "households", token: ownerAccount.token, json: ["name": "e2e-注销阻塞"]
    )
    let blockedHouseholdID = text(jsonObject(blockedHousehold.body) ?? [:], "id")
    report.check(
        blockedHousehold.status == 201 && !blockedHouseholdID.isEmpty,
        "创建注销测试家庭",
        "status=\(blockedHousehold.status)"
    )
    let blockedInvite = client.request(
        "POST", "households/\(blockedHouseholdID)/invitations", token: ownerAccount.token, json: [String: Any]()
    )
    let blockedCode = text(jsonObject(blockedInvite.body) ?? [:], "code")
    let blockedClaim = client.request(
        "POST", "households/invitations/claim", token: memberAccount.token, json: ["code": blockedCode]
    )
    report.check(blockedClaim.status == 200, "成员加入注销测试家庭", "status=\(blockedClaim.status)")

    let blockedDeletionRequest = client.request(
        "POST", "me/deletion-request", token: ownerAccount.token, json: [String: Any]()
    )
    let blockedDeletionObject = jsonObject(blockedDeletionRequest.body) ?? [:]
    let blockedDeletionToken = text(blockedDeletionObject, "token")
    report.check(
        blockedDeletionRequest.status == 201 && !blockedDeletionToken.isEmpty,
        "家庭阻塞前申请删除令牌成功",
        "status=\(blockedDeletionRequest.status)"
    )
    let blockedDelete = client.request("DELETE", "me", headers: ["X-Deletion-Token": blockedDeletionToken])
    report.check(
        blockedDelete.status == 409,
        "owner 家庭仍有成员时注销返回 409",
        "status=\(blockedDelete.status) body=\(bodyText(blockedDelete.body))"
    )
    report.check(
        errorCode(blockedDelete.body) == "ACCOUNT_DELETION_BLOCKED",
        "409 错误码为 ACCOUNT_DELETION_BLOCKED",
        "code=\(errorCode(blockedDelete.body))"
    )
    let stillAlive = client.request("GET", "households", token: ownerAccount.token)
    report.check(stillAlive.status == 200, "409 后账号数据仍保留", "status=\(stillAlive.status)")

    let transferForDeletion = client.request(
        "POST", "households/\(blockedHouseholdID)/transfer-ownership", token: ownerAccount.token,
        json: ["userId": memberAccount.userID]
    )
    report.check(
        transferForDeletion.status == 200,
        "注销前转让所有权成功",
        "status=\(transferForDeletion.status) body=\(bodyText(transferForDeletion.body))"
    )

    let deleteAfterTransfer = client.request("DELETE", "me", headers: ["X-Deletion-Token": blockedDeletionToken])
    report.check(
        deleteAfterTransfer.status == 204,
        "转让后同一未消耗令牌可注销（204）",
        "status=\(deleteAfterTransfer.status) body=\(bodyText(deleteAfterTransfer.body))"
    )
    let ownerBearerAfterDelete = client.request("POST", "me/export", token: ownerAccount.token, json: [String: Any]())
    report.check(ownerBearerAfterDelete.status == 401, "注销后 owner 的访问令牌立即失效（401）", "status=\(ownerBearerAfterDelete.status)")
    let ownerReplayDelete = client.request("DELETE", "me", headers: ["X-Deletion-Token": blockedDeletionToken])
    report.check(ownerReplayDelete.status == 404, "注销删除令牌重放返回 404", "status=\(ownerReplayDelete.status)")

    // MARK: 反馈提交与读回

    report.section("10. 反馈：提交 / 幂等重放 / 冲突 / 我的列表")
    let feedbackAuthA = jsonObject(client.request("POST", "auth/anonymous", json: [String: Any]()).body) ?? [:]
    let feedbackTokenA = text(feedbackAuthA, "token")
    let feedbackAuthB = jsonObject(client.request("POST", "auth/anonymous", json: [String: Any]()).body) ?? [:]
    let feedbackTokenB = text(feedbackAuthB, "token")
    let feedbackKey = "e2e-feedback-\(UUID().uuidString.lowercased())"
    let feedbackBody: [String: Any] = [
        "kind": "bug",
        "body": "e2e 反馈内容",
        "contact": "e2e@example.com",
        "diagnostics": "e2e diagnostics",
        "context": [
            "platform": "ios",
            "appVersion": "0.22.0",
            "buildType": "debug",
            "osVersion": "15.5",
            "deviceModel": "iPhone15,3",
        ],
    ]
    let firstFeedback = client.request(
        "POST", "feedback", token: feedbackTokenA, idempotencyKey: feedbackKey, json: feedbackBody
    )
    let firstObject = jsonObject(firstFeedback.body) ?? [:]
    let feedbackID = text(firstObject, "feedbackId")
    report.check(firstFeedback.status == 201, "POST /feedback 返回 201", "status=\(firstFeedback.status) body=\(firstObject)")
    report.check(!feedbackID.isEmpty, "POST /feedback 返回 feedbackId", "body=\(firstObject)")
    report.check(!text(firstObject, "createdAt").isEmpty, "POST /feedback 返回 createdAt", "body=\(firstObject)")

    let replayFeedback = client.request(
        "POST", "feedback", token: feedbackTokenA, idempotencyKey: feedbackKey, json: feedbackBody
    )
    let feedbackReplayObject = jsonObject(replayFeedback.body) ?? [:]
    let feedbackReplayHeader = (replayFeedback.headers["Idempotent-Replayed"] as? String)?.lowercased() ?? ""
    report.check(
        replayFeedback.status == 200,
        "同 key 同内容重放返回 200",
        "status=\(replayFeedback.status) body=\(feedbackReplayObject)"
    )
    report.check(feedbackReplayHeader == "true", "重放带 Idempotent-Replayed: true", "header=\(feedbackReplayHeader)")
    report.check(text(feedbackReplayObject, "feedbackId") == feedbackID, "重放返回同一 feedbackId", "body=\(feedbackReplayObject)")

    var conflictingFeedbackBody = feedbackBody
    conflictingFeedbackBody["body"] = "内容已变化"
    let conflictFeedback = client.request(
        "POST", "feedback", token: feedbackTokenA, idempotencyKey: feedbackKey, json: conflictingFeedbackBody
    )
    let conflictObject = jsonObject(conflictFeedback.body) ?? [:]
    let conflictCode = text(conflictObject["error"] as? [String: Any] ?? [:], "code")
    report.check(conflictFeedback.status == 409, "同 key 不同内容返回 409", "status=\(conflictFeedback.status) body=\(conflictObject)")
    report.check(conflictCode == "IDEMPOTENCY_CONFLICT", "409 错误码为 IDEMPOTENCY_CONFLICT", "code=\(conflictCode)")

    let mine = client.request("GET", "feedback/mine?limit=20", token: feedbackTokenA)
    let mineObject = jsonObject(mine.body) ?? [:]
    let mineItems = mineObject["items"] as? [[String: Any]] ?? []
    let submittedItem = mineItems.first { text($0, "feedbackId") == feedbackID }
    report.check(mine.status == 200, "GET /feedback/mine 返回 200", "status=\(mine.status)")
    report.check(submittedItem != nil, "我的反馈包含刚提交的记录", "items=\(mineItems.count)")
    report.check(
        text(submittedItem ?? [:], "status") == "submitted",
        "新反馈状态为 submitted",
        "item=\(submittedItem ?? [:])"
    )
    report.check(
        submittedItem?["contact"] == nil && submittedItem?["diagnostics"] == nil,
        "我的反馈列表不返回 contact / diagnostics",
        "item=\(submittedItem ?? [:])"
    )
    report.check(mineObject["hasMore"] is Bool, "列表返回 hasMore 布尔值", "body=\(mineObject)")
    if mineObject["nextCursor"] != nil {
        report.check(mineObject["nextCursor"] is String || mineObject["nextCursor"] is NSNull, "nextCursor 为字符串或 null")
    }

    let otherMine = client.request("GET", "feedback/mine?limit=20", token: feedbackTokenB)
    let otherItems = (jsonObject(otherMine.body) ?? [:])["items"] as? [[String: Any]] ?? []
    report.check(
        !otherItems.contains { text($0, "feedbackId") == feedbackID },
        "其他账号看不到该反馈",
        "items=\(otherItems.count)"
    )

    // MARK: 11. 场景（CRUD / 字段级 LWW / deviceMissing / 软删）

    report.section("11. 场景：CRUD / 字段级 LWW / deviceMissing / 软删与 change_log")
    guard let sceneAccountA = anonymousAccount("scene-a"),
          let sceneAccountB = anonymousAccount("scene-b")
    else {
        print("\n场景链路所需账号创建失败。")
        return 1
    }
    let sceneTokenA = sceneAccountA.token
    let sceneTokenB = sceneAccountB.token

    // 场景创建要求引用的设备真实存在；先推一台设备，稍后删除以验证 deviceMissing。
    let sceneDeviceID = UUID().uuidString.lowercased()
    let sceneDeviceExternalID = sceneDeviceID.uppercased()
    let sceneDevice = madeDevice(
        id: sceneDeviceID,
        platform: "ios",
        externalID: sceneDeviceExternalID,
        mac: nil,
        advertisedName: "场景测试设备",
        updatedAt: Date(timeIntervalSinceNow: -120)
    )
    let sceneDevicePush = client.request(
        "POST",
        "sync/push",
        token: sceneTokenA,
        idempotencyKey: "e2e-scene-device-\(UUID().uuidString.lowercased())",
        json: ["clientId": "ios-e2e-scene", "devices": [sceneDevice]]
    )
    report.check(
        sceneDevicePush.status == 200,
        "场景前置：推送设备成功",
        "status=\(sceneDevicePush.status) body=\(bodyText(sceneDevicePush.body))"
    )

    let sceneBody: [String: Any] = [
        "name": "e2e 离线场景",
        "enabled": true,
        "cooldownSeconds": 120,
        "trigger": [
            "kind": "device_offline",
            "device": ["platform": "ios", "externalId": sceneDeviceExternalID],
            "offlineSeconds": 120,
        ],
        "actions": [
            ["kind": "notify", "title": "设备离线", "body": "{device} 已离线"],
            ["kind": "log", "message": "记录 {device}", "level": "warn"],
        ],
    ]
    let createSceneResponse = client.request("POST", "scenes", token: sceneTokenA, json: sceneBody)
    let createdScene = jsonObject(createSceneResponse.body) ?? [:]
    let sceneID = text(createdScene, "id")
    report.check(createSceneResponse.status == 201, "POST /scenes 返回 201", "status=\(createSceneResponse.status) body=\(createdScene)")
    report.check(!sceneID.isEmpty, "POST /scenes 返回场景 id")
    report.check(createdScene["version"] as? NSNumber == 1, "新场景版本为 1", "version=\(text(createdScene, "version"))")
    report.check(createdScene["enabled"] as? Bool == true, "enabled 回显 true")
    report.check((createdScene["cooldownSeconds"] as? NSNumber)?.intValue == 120, "cooldownSeconds 回显 120")
    report.check(createdScene["deviceMissing"] as? Bool == false, "设备存在时 deviceMissing=false")

    let scheduleBody: [String: Any] = [
        "name": "e2e 定时场景",
        "trigger": [
            "kind": "schedule",
            "timeOfDay": "08:30",
            "timezone": "Asia/Shanghai",
            "daysOfWeek": [1, 3],
        ],
        "actions": [["kind": "mark_device", "mark": "已检查"]],
    ]
    let createSchedule = client.request("POST", "scenes", token: sceneTokenA, json: scheduleBody)
    let scheduleScene = jsonObject(createSchedule.body) ?? [:]
    let scheduleID = text(scheduleScene, "id")
    report.check(createSchedule.status == 201, "POST /scenes 定时场景返回 201", "status=\(createSchedule.status) body=\(scheduleScene)")
    report.check(scheduleScene["deviceMissing"] as? Bool == false, "无设备触发条件 deviceMissing=false")

    let listScenes = client.request("GET", "scenes", token: sceneTokenA)
    let sceneItems = list((jsonObject(listScenes.body) ?? [:])["items"])
    report.check(listScenes.status == 200, "GET /scenes 返回 200", "status=\(listScenes.status)")
    report.check(sceneItems.count == 2, "列表返回本人 2 个场景（无分页）", "count=\(sceneItems.count)")
    report.check(sceneItems.contains { text($0, "id") == sceneID }, "列表包含刚创建场景")
    report.check(sceneItems.contains { text($0, "id") == scheduleID }, "列表包含定时场景")

    // 删除设备后，场景保留但读取时 deviceMissing=true。
    let deletedDevice = madeDevice(
        id: sceneDeviceID,
        platform: "ios",
        externalID: sceneDeviceExternalID,
        mac: nil,
        advertisedName: "场景测试设备",
        updatedAt: Date(),
        deleted: true
    )
    let deleteDevicePush = client.request(
        "POST",
        "sync/push",
        token: sceneTokenA,
        idempotencyKey: "e2e-scene-device-delete-\(UUID().uuidString.lowercased())",
        json: ["clientId": "ios-e2e-scene", "devices": [deletedDevice]]
    )
    report.check(deleteDevicePush.status == 200, "场景前置：删除设备成功", "status=\(deleteDevicePush.status)")

    let sceneAfterDeviceDelete = client.request("GET", "scenes/\(sceneID)", token: sceneTokenA)
    let missingScene = jsonObject(sceneAfterDeviceDelete.body) ?? [:]
    report.check(sceneAfterDeviceDelete.status == 200, "设备删除后场景仍可读取（200）", "status=\(sceneAfterDeviceDelete.status)")
    report.check(missingScene["deviceMissing"] as? Bool == true, "设备删除后 deviceMissing=true", "body=\(missingScene)")
    report.check(text(missingScene, "name") == "e2e 离线场景", "设备删除不级联删场景")

    // 字段级 LWW：新名字生效，旧 enabled 被忽略；随后旧补丁不改变版本。
    // 服务端时间戳含纳秒，而 rfc3339 只有秒级精度；额外留出余量，避免同秒写入被判为不新。
    let newerTime = Date().addingTimeInterval(60)
    let olderTime = newerTime.addingTimeInterval(-3600)
    let lwwPatch: [String: Any] = [
        "name": ["value": "e2e 改名", "updatedAt": rfc3339(newerTime)],
        "enabled": ["value": false, "updatedAt": rfc3339(olderTime)],
    ]
    let lwwResponse = client.request("PUT", "scenes/\(sceneID)", token: sceneTokenA, json: lwwPatch)
    let lwwScene = jsonObject(lwwResponse.body) ?? [:]
    report.check(lwwResponse.status == 200, "PUT /scenes 返回 200", "status=\(lwwResponse.status)")
    report.check(text(lwwScene, "name") == "e2e 改名", "较新的 name 被应用", "name=\(text(lwwScene, "name"))")
    report.check(lwwScene["enabled"] as? Bool == true, "较旧的 enabled 被字段级 LWW 忽略")
    report.check((lwwScene["version"] as? NSNumber)?.intValue == 2, "至少一个字段应用后 version+1", "version=\(text(lwwScene, "version"))")
    report.check(lwwScene["deviceMissing"] as? Bool == true, "PUT 后仍返回实时 deviceMissing")

    let stalePatch: [String: Any] = [
        "name": ["value": "e2e 过期改名", "updatedAt": rfc3339(olderTime)],
    ]
    let staleSceneResponse = client.request("PUT", "scenes/\(sceneID)", token: sceneTokenA, json: stalePatch)
    let staleScene = jsonObject(staleSceneResponse.body) ?? [:]
    report.check(staleSceneResponse.status == 200, "过期补丁仍返回 200（静默不应用）", "status=\(staleSceneResponse.status)")
    report.check(text(staleScene, "name") == "e2e 改名", "过期 name 不覆盖新值")
    report.check((staleScene["version"] as? NSNumber)?.intValue == 2, "无字段应用时 version 不变", "version=\(text(staleScene, "version"))")

    let newerEnabledPatch: [String: Any] = [
        "enabled": ["value": false, "updatedAt": rfc3339(newerTime.addingTimeInterval(1))],
    ]
    let enabledResponse = client.request("PUT", "scenes/\(sceneID)", token: sceneTokenA, json: newerEnabledPatch)
    let enabledScene = jsonObject(enabledResponse.body) ?? [:]
    report.check(enabledResponse.status == 200, "PUT enabled 返回 200", "status=\(enabledResponse.status)")
    report.check(enabledScene["enabled"] as? Bool == false, "较新的 enabled 被应用")
    report.check((enabledScene["version"] as? NSNumber)?.intValue == 3, "第二个字段应用后 version=3", "version=\(text(enabledScene, "version"))")
    report.check(text(enabledScene, "name") == "e2e 改名", "其他字段未被覆盖")

    // 跨用户统一 404。
    let crossGet = client.request("GET", "scenes/\(sceneID)", token: sceneTokenB)
    report.check(crossGet.status == 404, "跨用户 GET 返回 404", "status=\(crossGet.status)")
    let crossPut = client.request("PUT", "scenes/\(sceneID)", token: sceneTokenB, json: newerEnabledPatch)
    report.check(crossPut.status == 404, "跨用户 PUT 返回 404", "status=\(crossPut.status)")
    let crossDelete = client.request("DELETE", "scenes/\(sceneID)", token: sceneTokenB)
    report.check(crossDelete.status == 404, "跨用户 DELETE 返回 404", "status=\(crossDelete.status)")

    // 非法触发条件 / 动作种类重复。
    let badTriggerBody = sceneBody.merging(["trigger": ["kind": "rssi_below", "device": ["platform": "ios", "externalId": sceneDeviceExternalID]]]) { _, new in new }
    let badTrigger = client.request("POST", "scenes", token: sceneTokenA, json: badTriggerBody)
    report.check(badTrigger.status == 400, "rssi_below 缺 rssiThreshold 返回 400", "status=\(badTrigger.status)")
    report.check(errorCode(badTrigger.body) == "SCENE_TRIGGER_INVALID", "错误码 SCENE_TRIGGER_INVALID", "code=\(errorCode(badTrigger.body))")

    var duplicateActionBody = scheduleBody
    duplicateActionBody["actions"] = [
        ["kind": "notify", "title": "重复一", "body": "内容"],
        ["kind": "notify", "title": "重复二", "body": "内容"],
    ]
    let duplicateAction = client.request("POST", "scenes", token: sceneTokenA, json: duplicateActionBody)
    report.check(duplicateAction.status == 400, "动作种类重复返回 400", "status=\(duplicateAction.status)")
    report.check(errorCode(duplicateAction.body) == "SCENE_ACTION_INVALID", "错误码 SCENE_ACTION_INVALID", "code=\(errorCode(duplicateAction.body))")

    // 软删：DELETE 204，随后 GET/PUT 都是 404，列表不再返回。
    let deleteScene = client.request("DELETE", "scenes/\(sceneID)", token: sceneTokenA)
    report.check(deleteScene.status == 204, "DELETE /scenes 返回 204", "status=\(deleteScene.status)")
    let getDeleted = client.request("GET", "scenes/\(sceneID)", token: sceneTokenA)
    report.check(getDeleted.status == 404, "已软删场景 GET 返回 404", "status=\(getDeleted.status)")
    let putDeleted = client.request("PUT", "scenes/\(sceneID)", token: sceneTokenA, json: stalePatch)
    report.check(putDeleted.status == 404, "已软删场景 PUT 返回 404", "status=\(putDeleted.status)")
    let listAfterDelete = client.request("GET", "scenes", token: sceneTokenA)
    let remainingScenes = list((jsonObject(listAfterDelete.body) ?? [:])["items"])
    report.check(!remainingScenes.contains { text($0, "id") == sceneID }, "列表不再返回已软删场景")
    report.check(remainingScenes.contains { text($0, "id") == scheduleID }, "未删除的定时场景仍在列表")

    // change_log：scene 实体的 upsert 与 delete（tombstone 带 deletedAt）。
    let sceneChanges = list((jsonObject(client.request(
        "GET", "sync/changes?cursor=0&limit=500", token: sceneTokenA
    ).body) ?? [:])["changes"]).filter { text($0, "entity") == "scene" }
    report.check(sceneChanges.count >= 3, "change_log 包含场景变更", "count=\(sceneChanges.count)")
    report.check(
        sceneChanges.contains {
            text($0, "op") == "upsert" && text($0["payload"] as? [String: Any] ?? [:], "id") == sceneID
        },
        "change_log 包含场景 upsert"
    )
    let sceneDeleteChange = sceneChanges.first {
        text($0, "op") == "delete" && text($0["payload"] as? [String: Any] ?? [:], "id") == sceneID
    }
    report.check(sceneDeleteChange != nil, "change_log 包含场景 delete tombstone")
    report.check(
        !text(sceneDeleteChange?["payload"] as? [String: Any] ?? [:], "deletedAt").isEmpty,
        "场景 tombstone 携带 deletedAt"
    )

    // MARK: 会话生命周期（v0.22.0 / 契约 0.17.0）

    if let sessionAccount = anonymousAccount("session-lifecycle") {
        let sessionsResponse = client.request("GET", "sessions", token: sessionAccount.token)
        let sessionItems = list(jsonObject(sessionsResponse.body)?["sessions"])
        report.check(sessionsResponse.status == 200, "GET /sessions 返回 200", "status=\(sessionsResponse.status)")
        report.check(
            sessionItems.contains { ($0["current"] as? Bool) == true },
            "GET /sessions 标出当前会话"
        )

        let refresh = client.request("POST", "auth/refresh", token: sessionAccount.token)
        let refreshedObject = jsonObject(refresh.body) ?? [:]
        let refreshedToken = text(refreshedObject, "token")
        report.check(refresh.status == 200, "POST /auth/refresh 返回 200", "status=\(refresh.status)")
        report.check(!refreshedToken.isEmpty, "刷新返回新 token")
        report.check(
            refreshedToken != sessionAccount.token,
            "滚动刷新后 token 已更换"
        )

        let stale = client.request("GET", "sessions", token: sessionAccount.token)
        report.check(stale.status == 401, "旧 token 立刻失效", "status=\(stale.status)")

        let current = client.request("GET", "sessions", token: refreshedToken)
        report.check(current.status == 200, "新 token 可访问 /sessions", "status=\(current.status)")

        let missing = client.request("DELETE", "sessions/00000000-0000-0000-0000-000000000000", token: refreshedToken)
        report.check(missing.status == 404, "吊销不存在会话返回 404", "status=\(missing.status)")

        let logout = client.request("POST", "auth/logout", token: refreshedToken)
        report.check(logout.status == 204, "POST /auth/logout 返回 204", "status=\(logout.status)")
        let afterLogout = client.request("GET", "sessions", token: refreshedToken)
        report.check(afterLogout.status == 401, "退出后 token 失效", "status=\(afterLogout.status)")
    }

    // MARK: 反馈详情与关闭（v0.22.0）

    if !feedbackID.isEmpty {
        let detail = client.request("GET", "feedback/\(feedbackID)", token: feedbackTokenA)
        let detailObject = jsonObject(detail.body) ?? [:]
        report.check(detail.status == 200, "GET /feedback/{id} 返回 200", "status=\(detail.status)")
        report.check(
            !text(detailObject, "statusMessage").isEmpty,
            "反馈详情包含 statusMessage"
        )

        let close = client.request(
            "PATCH",
            "feedback/\(feedbackID)",
            token: feedbackTokenA,
            json: ["status": "closed"]
        )
        let closeObject = jsonObject(close.body) ?? [:]
        report.check(close.status == 200, "PATCH /feedback/{id} 关闭返回 200", "status=\(close.status)")
        report.check(text(closeObject, "status") == "closed", "关闭后状态为 closed")

        let closeAgain = client.request(
            "PATCH",
            "feedback/\(feedbackID)",
            token: feedbackTokenA,
            json: ["status": "closed"]
        )
        report.check(closeAgain.status == 409, "已关闭再改返回 409", "status=\(closeAgain.status)")
    }

    // MARK: 12. 推送设备注册 / 注销 与 /scenes 可选分页（v0.23.0）

    report.section("12. 推送设备注册 / 注销 / 场景分页（v0.23.0）")

    if let pushAccount = anonymousAccount("push") {
        let pushToken = "e2e-push-token"
        let pushBody: [String: Any] = [
            "platform": "ios",
            "token": pushToken,
            "appVersion": "0.26.0",
            "deviceModel": "iPhone",
        ]

        let noAuth = client.request("POST", "push/devices", json: pushBody)
        report.check(noAuth.status == 401, "未带 token 注册推送设备返回 401", "status=\(noAuth.status)")

        let registered = client.request("POST", "push/devices", token: pushAccount.token, json: pushBody)
        let registeredObject = jsonObject(registered.body) ?? [:]
        let pushDeviceID = text(registeredObject, "id")
        report.check(registered.status == 200, "POST /push/devices 返回 200", "status=\(registered.status) body=\(bodyText(registered.body))")
        report.check(
            text(registeredObject, "status") == "active" && text(registeredObject, "platform") == "ios",
            "注册响应 status=active、platform=ios"
        )
        report.check(!pushDeviceID.isEmpty, "注册响应包含远端 deviceId")

        let repeated = client.request(
            "POST",
            "push/devices",
            token: pushAccount.token,
            json: ["platform": "ios", "token": pushToken, "appVersion": "2.0.0"]
        )
        let repeatedObject = jsonObject(repeated.body) ?? [:]
        report.check(repeated.status == 200, "同一 token 重复注册返回 200", "status=\(repeated.status)")
        report.check(text(repeatedObject, "id") == pushDeviceID, "同一 (user, token) 幂等复用同一 deviceId")
        report.check(text(repeatedObject, "appVersion") == "2.0.0", "重复注册更新 appVersion")

        let invalidPlatform = client.request(
            "POST",
            "push/devices",
            token: pushAccount.token,
            json: ["platform": "web", "token": "e2e-invalid"]
        )
        report.check(invalidPlatform.status == 400, "非法 platform 返回 400", "status=\(invalidPlatform.status)")
        report.check(
            errorCode(invalidPlatform.body) == "PUSH_DEVICE_INVALID",
            "非法 platform 返回 PUSH_DEVICE_INVALID",
            "code=\(errorCode(invalidPlatform.body))"
        )

        let emptyToken = client.request(
            "POST",
            "push/devices",
            token: pushAccount.token,
            json: ["platform": "ios", "token": ""]
        )
        report.check(emptyToken.status == 400, "空 token 返回 400", "status=\(emptyToken.status)")
        report.check(
            errorCode(emptyToken.body) == "PUSH_DEVICE_INVALID",
            "空 token 返回 PUSH_DEVICE_INVALID",
            "code=\(errorCode(emptyToken.body))"
        )

        if let otherPushAccount = anonymousAccount("push-other") {
            let crossUser = client.request(
                "DELETE",
                "push/devices/\(pushDeviceID)",
                token: otherPushAccount.token
            )
            report.check(crossUser.status == 404, "跨用户注销推送设备返回 404", "status=\(crossUser.status)")
        }

        let deactivated = client.request("DELETE", "push/devices/\(pushDeviceID)", token: pushAccount.token)
        report.check(deactivated.status == 204, "本人注销推送设备返回 204", "status=\(deactivated.status)")
        let deactivatedAgain = client.request("DELETE", "push/devices/\(pushDeviceID)", token: pushAccount.token)
        report.check(deactivatedAgain.status == 204, "已停用再次注销仍幂等 204", "status=\(deactivatedAgain.status)")

        // /scenes 可选分页：不传参数维持全量；limit/cursor 能翻页；非法参数 400。
        var createdSceneIDs: [String] = []
        for index in 0..<3 {
            let body: [String: Any] = [
                "name": "分页场景 \(index)",
                "trigger": ["kind": "schedule", "timeOfDay": "08:0\(index)"],
                "actions": [["kind": "log", "message": "m\(index)"]],
            ]
            let created = client.request("POST", "scenes", token: pushAccount.token, json: body)
            if let id = jsonObject(created.body).map({ text($0, "id") }), !id.isEmpty {
                createdSceneIDs.append(id)
            }
            report.check(created.status == 201, "分页前置：创建场景 \(index)", "status=\(created.status) body=\(bodyText(created.body))")
        }

        let full = client.request("GET", "scenes", token: pushAccount.token)
        let fullObject = jsonObject(full.body) ?? [:]
        let fullItems = list(fullObject["items"])
        report.check(full.status == 200, "GET /scenes 不传分页参数返回 200", "status=\(full.status)")
        report.check(fullItems.count == createdSceneIDs.count, "不传 limit 保持全量返回", "items=\(fullItems.count)")
        report.check(
            fullObject["nextCursor"] == nil && fullObject["hasMore"] == nil,
            "不传 limit 不出现分页字段"
        )

        let firstPage = client.request("GET", "scenes?limit=2", token: pushAccount.token)
        let firstPageObject = jsonObject(firstPage.body) ?? [:]
        let firstItems = list(firstPageObject["items"])
        let firstCursor = text(firstPageObject, "nextCursor")
        report.check(firstPage.status == 200, "GET /scenes?limit=2 返回 200", "status=\(firstPage.status)")
        report.check(firstItems.count == 2, "limit=2 每页 2 条", "items=\(firstItems.count)")
        report.check(firstPageObject["hasMore"] as? Bool == true, "第一页 hasMore=true")
        report.check(!firstCursor.isEmpty, "hasMore=true 时返回 nextCursor")

        let secondPage = client.request("GET", "scenes?limit=2&cursor=\(firstCursor)", token: pushAccount.token)
        let secondPageObject = jsonObject(secondPage.body) ?? [:]
        let secondItems = list(secondPageObject["items"])
        report.check(secondPage.status == 200, "游标翻页返回 200", "status=\(secondPage.status)")
        report.check(secondItems.count == 1, "第二页返回剩余 1 条", "items=\(secondItems.count)")
        report.check(secondPageObject["hasMore"] as? Bool == false, "第二页 hasMore=false")

        let invalidLimit = client.request("GET", "scenes?limit=0", token: pushAccount.token)
        report.check(invalidLimit.status == 400, "非法 limit=0 返回 400", "status=\(invalidLimit.status)")
    }

    // MARK: 汇总

    print("\n=== E2E 合同联调结果 ===")
    print("通过：\(report.passed) 项，跳过：\(report.skipped) 项，失败：\(report.failed) 项")
    if report.failed > 0 {
        print("结论：FAIL")
        return 1
    }
    print("结论：PASS")
    return 0
}

exit(run())
