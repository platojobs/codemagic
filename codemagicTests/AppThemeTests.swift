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

    /// 几何 / 配色类不得出现硬编码黑白或十六进制颜色。
    func testChartAndThemeSourcesContainNoHardcodedColors() throws {
        let directories = [
            "codemagic/DesignSystem",
            "codemagic/Modules/Devices/Views",
        ]
        let forbidden = [
            ".white",
            ".black",
            "UIColor(white:",
            "UIColor(red:",
            "UIColor(displayP3Red:",
            "#colorLiteral",
            "0x",
        ]
        for directory in directories {
            let directoryURL = repoRoot.appendingPathComponent(directory)
            let files = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" }

            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    XCTAssertFalse(
                        source.contains(token),
                        "\(file.lastPathComponent) 出现硬编码颜色 \(token)"
                    )
                }
            }
        }
    }
}
