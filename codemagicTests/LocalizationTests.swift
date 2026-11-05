import XCTest
@testable import codemagic

/// 本地化约束：界面源码不得硬编码中文、zh-Hans / en 的 key 与占位符必须一致。
final class LocalizationTests: XCTestCase {
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var sourceRoot: URL { repoRoot.appendingPathComponent("codemagic") }

    func testNoHardcodedChineseLiteralsInViewAndViewModelSources() throws {
        let cjk = try NSRegularExpression(pattern: "[\u{4e00}-\u{9fff}\u{3000}-\u{303f}\u{ff00}-\u{ffef}]")
        let literal = try NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")
        let logCall = try NSRegularExpression(
            pattern: "print\\(|NSLog|debugPrint|Logger|AppLog|\\.debug\\(|os_log|assertionFailure"
        )

        var offenders: [String] = []
        for file in try viewAndViewModelFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).split(
                separator: "\n", omittingEmptySubsequences: false
            )
            var debugOnly = false
            for (index, line) in lines.enumerated() {
                let text = String(line)
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if DEBUG") { debugOnly = true }
                if trimmed.hasPrefix("#endif") { debugOnly = false }
                if debugOnly || trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    continue
                }
                if logCall.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    continue
                }
                for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    let value = String(text[range])
                    if cjk.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                        offenders.append("\(file.lastPathComponent):\(index + 1) → \"\(value)\"")
                    }
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, "界面文案必须走 L10n，不得硬编码中文：\n" + offenders.joined(separator: "\n"))
    }

    func testChineseAndEnglishKeySetsAreIdentical() throws {
        let zh = try strings(named: "zh-Hans")
        let en = try strings(named: "en")

        XCTAssertFalse(zh.isEmpty)
        XCTAssertEqual(zh.count, Set(zh.keys).count, "zh-Hans 存在重复 key")
        XCTAssertEqual(en.count, Set(en.keys).count, "en 存在重复 key")
        XCTAssertEqual(Set(zh.keys), Set(en.keys), "zh-Hans 与 en 的 key 集合必须一致")
        XCTAssertTrue(zh.values.allSatisfy { !$0.isEmpty }, "zh-Hans 存在空文案")
        XCTAssertTrue(en.values.allSatisfy { !$0.isEmpty }, "en 存在空文案")
    }

    func testPlaceholderCountsMatchAcrossLanguages() throws {
        let zh = try strings(named: "zh-Hans")
        let en = try strings(named: "en")

        var mismatched: [String] = []
        for (key, value) in zh {
            let expected = occurrences(of: "%@", in: value)
            let actual = occurrences(of: "%@", in: en[key] ?? "")
            if expected != actual {
                mismatched.append("\(key)：zh \(expected) 个 %@，en \(actual) 个")
            }
        }
        XCTAssertTrue(mismatched.isEmpty, mismatched.joined(separator: "\n"))
    }

    func testEveryCodeKeyExistsInBothStringsFiles() throws {
        let zh = try strings(named: "zh-Hans")
        let en = try strings(named: "en")
        let used = try codeKeys()

        XCTAssertFalse(used.isEmpty)
        let missing = used.subtracting(zh.keys).union(used.subtracting(en.keys))
        XCTAssertTrue(missing.isEmpty, "代码引用了不存在的 key：\n" + missing.sorted().joined(separator: "\n"))
    }

    func testLocalizationDeclaresEnglishAndSimplifiedChinese() throws {
        let info = try propertyList(named: "Info.plist")
        let localizations = info["CFBundleLocalizations"] as? [String]
        XCTAssertEqual(localizations, ["en", "zh-Hans"])

        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("codemagic.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("\"zh-Hans\""), "工程 knownRegions 必须包含 zh-Hans")
    }

    // MARK: - Helpers

    private func viewAndViewModelFiles() throws -> [URL] {
        let roots = ["Modules", "DesignSystem"].map { sourceRoot.appendingPathComponent($0) }
        var result: [URL] = []
        for root in roots {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let name = url.lastPathComponent
                let isViewLayer = name.hasSuffix("ViewController.swift")
                    || name.hasSuffix("ViewModel.swift")
                    || url.path.contains("/Views/")
                if isViewLayer { result.append(url) }
            }
        }
        return result
    }

    private func strings(named language: String) throws -> [String: String] {
        let url = sourceRoot.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    private func propertyList(named name: String) throws -> [String: Any] {
        let url = sourceRoot.appendingPathComponent("Resources/\(name)")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func codeKeys() throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: "L10n\\.(?:t|f)\\(\\s*\"([^\"]+)\"")
        var keys = Set<String>()
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
                keys.insert(String(text[keyRange]))
            }
        }
        return keys
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
