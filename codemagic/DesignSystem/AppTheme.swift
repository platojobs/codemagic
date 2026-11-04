import UIKit

/// 设计系统：颜色、间距、圆角、字体与常用控件的统一入口。
///
/// 业务代码只引用这里的语义常量，不写十六进制颜色、不写魔法数字，
/// 从而同时适配深色模式与 Dynamic Type。
enum AppTheme {
    // MARK: - Spacing

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
    }

    // MARK: - Metrics

    enum Metrics {
        static let estimatedRowHeight: CGFloat = 64
        static let avatarSize: CGFloat = 56
        static let thumbnailSize: CGFloat = 88
        static let detailImageHeight: CGFloat = 220
        static let badgeHeight: CGFloat = 22
        static let contentMargins: CGFloat = 20
    }

    // MARK: - Corner Radius

    enum CornerRadius {
        static let card: CGFloat = 16
        static let control: CGFloat = 10
        static let badge: CGFloat = 11
    }

    // MARK: - Palette（全部为语义色）

    enum Palette {
        static let background = UIColor.systemGroupedBackground
        static let cardBackground = UIColor.secondarySystemGroupedBackground
        static let primaryText = UIColor.label
        static let secondaryText = UIColor.secondaryLabel
        static let tertiaryText = UIColor.tertiaryLabel
        static let accent = UIColor.tintColor
        static let separator = UIColor.separator
        static let success = UIColor.systemGreen
        static let highlight = UIColor.systemOrange
        static let promotion = UIColor.systemRed
        static let favorite = UIColor.systemPink
        static let fill = UIColor.tertiarySystemFill
    }

    // MARK: - Typography

    enum Typography {
        static func font(_ style: UIFont.TextStyle) -> UIFont {
            .preferredFont(forTextStyle: style)
        }
    }

    // MARK: - Factories

    static func makeLabel(style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.font = Typography.font(style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    static func makePrimaryButton(title: String, symbolName: String? = nil) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = Palette.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.medium,
            leading: Spacing.large,
            bottom: Spacing.medium,
            trailing: Spacing.large
        )
        if let symbolName {
            configuration.image = UIImage(
                systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)
            )
            configuration.imagePadding = Spacing.small
        }
        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }

    static func makePillButton(title: String, symbolName: String) -> UIButton {
        let image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1)
        )
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = image
        configuration.imagePadding = Spacing.xSmall
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.small,
            leading: Spacing.medium,
            bottom: Spacing.small,
            trailing: Spacing.medium
        )
        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }

    static func makeBadgeLabel(text: String, color: UIColor) -> UILabel {
        let label = makeLabel(style: .caption2, color: color)
        label.text = text
        label.textAlignment = .center
        label.backgroundColor = color.withAlphaComponent(0.15)
        label.layer.cornerRadius = CornerRadius.badge
        label.layer.masksToBounds = true
        return label
    }

    static func styleAsCard(_ view: UIView) {
        view.backgroundColor = Palette.cardBackground
        view.layer.cornerRadius = CornerRadius.card
        view.layer.cornerCurve = .continuous
    }

    static func symbolImage(_ name: String, textStyle: UIFont.TextStyle = .body) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(textStyle: textStyle))
    }
}
