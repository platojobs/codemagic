import XCTest

/// 隐私申报一致性：清单键集合必须恰好等于商店文档声明的 8 类，且属性固定。
final class PrivacyManifestTests: XCTestCase {
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private let expectedTypes: Set<String> = [
        "NSPrivacyCollectedDataTypeDeviceID",
        "NSPrivacyCollectedDataTypeUserID",
        "NSPrivacyCollectedDataTypeHealth",
        "NSPrivacyCollectedDataTypeOtherDataTypes",
        "NSPrivacyCollectedDataTypeOtherUsageData",
        "NSPrivacyCollectedDataTypeOtherUserContent",
        "NSPrivacyCollectedDataTypeOtherUserContactInfo",
        "NSPrivacyCollectedDataTypeOtherDiagnosticData"
    ]

    func testManifestDeclaresExactlyEightCollectedTypes() throws {
        let url = repoRoot.appendingPathComponent("codemagic/Resources/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)

        let entries = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 8)

        let keys = Set(entries.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(keys, expectedTypes)

        for entry in entries {
            let key = entry["NSPrivacyCollectedDataType"] as? String ?? "?"
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true,
                "\(key) 应与匿名账号关联"
            )
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false,
                "\(key) 不得用于追踪"
            )
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
                "\(key) 用途应仅为 App Functionality"
            )
        }
    }

    func testStoreListingDeclaresTheSameEightTypes() throws {
        let url = repoRoot.appendingPathComponent("docs/store-listing.md")
        let doc = try String(contentsOf: url, encoding: .utf8)

        let regex = try NSRegularExpression(pattern: "NSPrivacyCollectedDataType[A-Za-z]+")
        let range = NSRange(doc.startIndex..., in: doc)
        let keys = Set(regex.matches(in: doc, range: range).compactMap { match in
            Range(match.range, in: doc).map { String(doc[$0]) }
        }).subtracting(["NSPrivacyCollectedDataTypes"])

        XCTAssertEqual(keys, expectedTypes, "商店文档必须逐项列出同样的 8 类，且不得出现第 9 类")
        XCTAssertTrue(doc.contains("当前构建不产生、不上报"), "必须写明 APNs 令牌当前不采集")
        XCTAssertTrue(doc.contains("APNs 推送令牌"), "APNs 令牌须归入 DeviceID 并注明触发条件")
    }
}