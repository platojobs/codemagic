import UIKit

/// 兼容入口：旧代码通过 `AppTheme` 引用语义常量，实际取值全部来自
/// `DesignTokens.swift` 中的 `Palette` / `Layout` / `Radius` / `AppText`。
/// 新代码请直接使用令牌，避免再新增中转名。
enum AppTheme {
    // MARK: - Spacing

    enum Spacing {
        static let xSmall: CGFloat = Layout.space4
        static let small: CGFloat = Layout.space8
        static let medium: CGFloat = Layout.space12
        static let large: CGFloat = Layout.space16
        static let xLarge: CGFloat = Layout.space24
    }

    // MARK: - Metrics

    enum Metrics {
        static let estimatedRowHeight: CGFloat = Layout.row2
        static let avatarSize: CGFloat = Layout.avatar56
        static let thumbnailSize: CGFloat = Layout.row3
        static let detailImageHeight: CGFloat = 220
        static let badgeHeight: CGFloat = 22
        static let contentMargins: CGFloat = Layout.pageMargin
    }

    // MARK: - Corner Radius

    enum CornerRadius {
        static let card: CGFloat = Radius.card
        static let control: CGFloat = Radius.input
        static let badge: CGFloat = Radius.pill
    }

    // MARK: - Palette（全部映射到语义令牌）

    enum Palette {
        static let background = DesignPalette.canvas
        static let cardBackground = DesignPalette.surface
        static let primaryText = DesignPalette.textPrimary
        static let secondaryText = DesignPalette.textSecondary
        static let tertiaryText = DesignPalette.textTertiary
        static let accent = DesignPalette.primary
        static let separator = DesignPalette.divider
        static let success = DesignPalette.success
        static let highlight = DesignPalette.warning
        static let promotion = DesignPalette.danger
        static let favorite = DesignPalette.primary
        static let fill = DesignPalette.surfaceSunken
    }

    // MARK: - Typography

    enum Typography {
        /// 旧调用点使用 `UIFont.TextStyle`，这里映射到 10 级 `AppText`。
        static func font(_ style: UIFont.TextStyle) -> UIFont {
            appText(for: style).font()
        }

        static func appText(for style: UIFont.TextStyle) -> AppText {
            switch style {
            case .largeTitle: return .display
            case .title1, .title2: return .title
            case .title3, .headline: return .headline
            case .body: return .body
            case .callout, .subheadline: return .callout
            case .caption1: return .caption
            default: return .footnote
            }
        }
    }

    // MARK: - Factories

    static func makeLabel(style: UIFont.TextStyle, color: UIColor) -> UILabel {
        makeLabel(text: Typography.appText(for: style), color: color)
    }

    static func makeLabel(text: AppText, color: UIColor) -> UILabel {
        let label = UILabel()
        label.font = text.font()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    static func makePrimaryButton(title: String, symbolName: String? = nil) -> UIButton {
        AppButton(style: .primary, title: title, symbolName: symbolName)
    }

    static func makePillButton(title: String, symbolName: String) -> UIButton {
        AppButton(style: .filterChip, title: title, symbolName: symbolName)
    }

    static func makeBadgeLabel(text: String, color: UIColor) -> UILabel {
        let label = makeLabel(text: .caption, color: color)
        label.text = text
        label.textAlignment = .center
        label.backgroundColor = color.withAlphaComponent(0.12)
        label.layer.cornerRadius = Radius.sm
        label.layer.masksToBounds = true
        return label
    }

    static func styleAsCard(_ view: UIView) {
        view.styleAsCardSurface()
    }

    static func symbolImage(_ name: String, textStyle: UIFont.TextStyle = .body) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(textStyle: textStyle))
    }
}
