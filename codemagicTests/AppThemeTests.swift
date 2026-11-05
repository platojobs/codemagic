import XCTest
import UIKit
@testable import codemagic

/// 深色模式：三态外观、语义色动态解析与源码颜色常量扫描。
final class AppThemeTests: XCTestCase {
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testAppearanceHasThreeStatesWithStableRawValues() {
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppAppearance.system.rawValue, "system")
        XCTAssertEqual(AppAppearance.light.rawValue, "light")
        XCTAssertEqual(AppAppearance.dark.rawValue, "dark")
        XCTAssertEqual(AppAppearance.dark.userInterfaceStyle, .dark)
        XCTAssertEqual(AppAppearance.light.userInterfaceStyle, .light)
        XCTAssertEqual(AppAppearance.system.userInterfaceStyle, .unspecified)
    }

    func testAppearancePreferencePersists() {
        let suiteName = "appearance-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.appearance, .system, "默认跟随系统")

        settings.appearance = .dark
        XCTAssertEqual(settings.appearance, .dark)
        settings.appearance = .light
        XCTAssertEqual(settings.appearance, .light)
    }

    func testSemanticPaletteResolvesDifferentlyInLightAndDark() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        let background = AppTheme.Palette.background.resolvedColor(with: light)
        let darkBackground = AppTheme.Palette.background.resolvedColor(with: dark)
        XCTAssertNotEqual(background, darkBackground, "分组背景必须随深浅色变化")

        let card = AppTheme.Palette.cardBackground.resolvedColor(with: light)
        let darkCard = AppTheme.Palette.cardBackground.resolvedColor(with: dark)
        XCTAssertNotEqual(card, darkCard, "卡片背景必须随深浅色变化")

        let label = AppTheme.Palette.primaryText.resolvedColor(with: light)
        let darkLabel = AppTheme.Palette.primaryText.resolvedColor(with: dark)
        XCTAssertNotEqual(label, darkLabel, "主文本颜色必须随深浅色变化")
    }

    func testAccentColorAssetHasDarkVariant() throws {
        let contentsURL = repoRoot
            .appendingPathComponent("codemagic/Resources/Assets.xcassets/AccentColor.colorset/Contents.json")
        let data = try Data(contentsOf: contentsURL)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        let hasDark = colors.contains { entry in
            guard let appearances = entry["appearances"] as? [[String: Any]] else { return false }
            return appearances.contains {
                ($0["appearance"] as? String) == "luminosity" && ($0["value"] as? String) == "dark"
            }
        }
        XCTAssertTrue(hasDark, "AccentColor 需要 dark 变体")
        XCTAssertGreaterThanOrEqual(colors.count, 2)
    }

    func testPaletteExposes36SemanticColorsWithDarkVariants() {
        XCTAssertEqual(Palette.all.count, 36, "语义色必须是 36 个")
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        var identical: [String] = []
        for (name, color) in Palette.all {
            let l = color.resolvedColor(with: light)
            let d = color.resolvedColor(with: dark)
            if l == d { identical.append(name) }
        }
        // onPrimary 是唯一在深浅色下都为纯白的语义色。
        XCTAssertEqual(identical, ["onPrimary"], "除 onPrimary 外的语义色都必须有深色变体")
    }

    func testLayoutAndTypographyTokens() {
        XCTAssertEqual(Layout.space4, 4)
        XCTAssertEqual(Layout.pageMargin, 16)
        XCTAssertEqual(Layout.row1, 56)
        XCTAssertEqual(Layout.row2, 72)
        XCTAssertEqual(Layout.row3, 88)
        XCTAssertEqual(Radius.card, 12)
        XCTAssertEqual(Stroke.one, 1)
        XCTAssertEqual(Layout.headerExpanded, 96)
        XCTAssertEqual(Layout.navBarH, 56)
        XCTAssertEqual(AppText.allCases.count, 10, "字号阶梯必须为 10 级")
        XCTAssertEqual(AppText.display.size, 34)
        XCTAssertEqual(AppText.numericXL.size, 40)
        XCTAssertTrue(AppText.numericM.isNumeric, "数值文本必须使用等宽数字令牌")
        XCTAssertTrue(AppText.numericXL.isNumeric)
        XCTAssertTrue(AppText.numericL.isNumeric)
        XCTAssertEqual(Motion.d200, 0.2)
    }

    /// 全量源码不得出现硬编码颜色与字号；令牌文件本身除外。
    func testChartAndThemeSourcesContainNoHardcodedColorsOrFontSizes() throws {
        let rootURL = repoRoot.appendingPathComponent("codemagic")
        let excluded: Set<String> = ["DesignTokens.swift"]
        let forbiddenColorTokens = [
            "UIColor(white:",
            "UIColor(red:",
            "UIColor(displayP3Red:",
            "#colorLiteral",
        ]
        let forbiddenColorPatterns = [
            #"\.white\b"#,
            #"\.black\b"#,
            #"UIColor\.system[A-Z]"#,
            #"\.systemGray[0-9]?"#,
        ]
        let fontLiteralPatterns = [
            #"systemFont\(ofSize:\s*[0-9]"#,
            #"monospacedDigitSystemFont\(ofSize:\s*[0-9]"#,
            #"\.font\s*=\s*UIFont\."#,
            #"UIFont\.boldSystemFont"#,
        ]

        let files = try FileManager.default.subpathsOfDirectory(atPath: rootURL.path)
            .filter { $0.hasSuffix(".swift") }
            .map { rootURL.appendingPathComponent($0) }

        for file in files where !excluded.contains(file.lastPathComponent) {
            // 只审计表现层；Core 中 `0x` 是 GATT/协议常量，不是颜色。
            guard ["DesignSystem", "Modules", "App"].contains(where: {
                file.path.contains("/codemagic/\($0)/")
            }) else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbiddenColorTokens {
                XCTAssertFalse(
                    source.contains(token),
                    "\(file.lastPathComponent) 出现硬编码颜色 \(token)"
                )
            }
            for pattern in forbiddenColorPatterns + fontLiteralPatterns {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(source.startIndex..., in: source)
                XCTAssertNil(
                    regex.firstMatch(in: source, range: range),
                    "\(file.lastPathComponent) 出现硬编码颜色/字号（\(pattern)）"
                )
            }
        }
    }
}
