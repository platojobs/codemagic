import UIKit

// MARK: - 颜色令牌
//
// 与 `design-spec.md` / `token-mapping.md` 一一对应：
// 浅色 / 深色各一套，语义键相同，禁止在业务代码里写十六进制或系统色。

extension UIColor {
    /// `#AARRGGBB`，同时兼容不透明 `#RRGGBB`（调用方补 `0xFF` 前缀）。
    convenience init(argb: UInt32) {
        let a = CGFloat((argb & 0xFF00_0000) >> 24) / 255.0
        let r = CGFloat((argb & 0x00FF_0000) >> 16) / 255.0
        let g = CGFloat((argb & 0x0000_FF00) >> 8) / 255.0
        let b = CGFloat(argb & 0x0000_00FF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(argb: dark) : UIColor(argb: light)
        }
    }
}

enum Palette {
    // 基础（7）
    static let canvas = UIColor.dynamic(light: 0xFFF4F6F9, dark: 0xFF0B0D12)
    static let surface = UIColor.dynamic(light: 0xFFFFFFFF, dark: 0xFF14171E)
    static let surfaceRaised = UIColor.dynamic(light: 0xFFFFFFFF, dark: 0xFF1B1F27)
    static let surfaceSunken = UIColor.dynamic(light: 0xFFEEF1F5, dark: 0xFF101319)
    static let divider = UIColor.dynamic(light: 0xFFE4E7EC, dark: 0xFF262B35)
    static let border = UIColor.dynamic(light: 0xFFD0D5DD, dark: 0xFF343A46)
    static let borderStrong = UIColor.dynamic(light: 0xFF8A93A2, dark: 0xFF646C7C)

    // 文字（5）
    static let textPrimary = UIColor.dynamic(light: 0xFF101828, dark: 0xFFE7E9EE)
    static let textSecondary = UIColor.dynamic(light: 0xFF475467, dark: 0xFFA8B0BE)
    static let textTertiary = UIColor.dynamic(light: 0xFF667085, dark: 0xFF8A93A2)
    static let textDisabled = UIColor.dynamic(light: 0xFF98A2B3, dark: 0xFF5F6775)
    static let textInverse = UIColor.dynamic(light: 0xFFFFFFFF, dark: 0xFF0B0D12)

    // 动作（7）
    static let primary = UIColor.dynamic(light: 0xFF175CD3, dark: 0xFF2563EB)
    static let primaryPressed = UIColor.dynamic(light: 0xFF1249A8, dark: 0xFF1D4ED8)
    static let primaryText = UIColor.dynamic(light: 0xFF175CD3, dark: 0xFF6AA0FF)
    static let onPrimary = UIColor.dynamic(light: 0xFFFFFFFF, dark: 0xFFFFFFFF)
    static let dangerFill = UIColor.dynamic(light: 0xFFB42318, dark: 0xFFC0392B)
    static let dangerPressed = UIColor.dynamic(light: 0xFF912018, dark: 0xFFA32E22)
    static let actionDisabledBg = UIColor.dynamic(light: 0xFFE4E7EC, dark: 0xFF232832)

    // 状态（6）
    static let success = UIColor.dynamic(light: 0xFF067647, dark: 0xFF3DD68C)
    static let successBg = UIColor.dynamic(light: 0xFFECFDF3, dark: 0xFF10261B)
    static let warning = UIColor.dynamic(light: 0xFFB54708, dark: 0xFFF5A524)
    static let warningBg = UIColor.dynamic(light: 0xFFFFFAEB, dark: 0xFF2A2113)
    static let danger = UIColor.dynamic(light: 0xFFB42318, dark: 0xFFFF6B6B)
    static let dangerBg = UIColor.dynamic(light: 0xFFFEF3F2, dark: 0xFF2A1416)

    // 图表（5）
    static let chartLine = UIColor.dynamic(light: 0xFF175CD3, dark: 0xFF6AA0FF)
    static let chartLine2 = UIColor.dynamic(light: 0xFF7A5AF8, dark: 0xFFB79CFF)
    static let chartBand = UIColor.dynamic(light: 0xFFE8EFFB, dark: 0xFF1A2740)
    static let chartGrid = UIColor.dynamic(light: 0xFFEAECF0, dark: 0xFF262B35)
    static let chartAxis = UIColor.dynamic(light: 0xFF667085, dark: 0xFF8A93A2)

    // 反馈（6）
    static let overlayPressed = UIColor.dynamic(light: 0x0F101828, dark: 0x14FFFFFF)
    static let skeletonBase = UIColor.dynamic(light: 0xFFE9ECF1, dark: 0xFF1B1F27)
    static let skeletonHighlight = UIColor.dynamic(light: 0xFFF6F8FA, dark: 0xFF232832)
    static let toastSurface = UIColor.dynamic(light: 0xFF1D2939, dark: 0xFF2A2F3A)
    static let toastText = UIColor.dynamic(light: 0xFFFFFFFF, dark: 0xFFE7E9EE)
    static let scrim = UIColor.dynamic(light: 0x73101828, dark: 0x99000000)

    /// 36 个语义色，供审计测试逐项校验深浅色解析。
    static let all: [(String, UIColor)] = [
        ("canvas", canvas), ("surface", surface), ("surfaceRaised", surfaceRaised),
        ("surfaceSunken", surfaceSunken), ("divider", divider), ("border", border),
        ("borderStrong", borderStrong), ("textPrimary", textPrimary), ("textSecondary", textSecondary),
        ("textTertiary", textTertiary), ("textDisabled", textDisabled), ("textInverse", textInverse),
        ("primary", primary), ("primaryPressed", primaryPressed), ("primaryText", primaryText),
        ("onPrimary", onPrimary), ("dangerFill", dangerFill), ("dangerPressed", dangerPressed),
        ("actionDisabledBg", actionDisabledBg), ("success", success), ("successBg", successBg),
        ("warning", warning), ("warningBg", warningBg), ("danger", danger),
        ("dangerBg", dangerBg), ("chartLine", chartLine), ("chartLine2", chartLine2),
        ("chartBand", chartBand), ("chartGrid", chartGrid), ("chartAxis", chartAxis),
        ("overlayPressed", overlayPressed), ("skeletonBase", skeletonBase),
        ("skeletonHighlight", skeletonHighlight), ("toastSurface", toastSurface),
        ("toastText", toastText), ("scrim", scrim),
    ]
}

/// 供 `AppTheme` 等旧命名空间引用，避免嵌套 `Palette` 名称覆盖。
typealias DesignPalette = Palette

// MARK: - 尺寸令牌

enum Layout {
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32
    static let space40: CGFloat = 40
    static let space48: CGFloat = 48

    static let pageMargin: CGFloat = 16
    static let pageMarginWide: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let cardGap: CGFloat = 12
    static let sectionGap: CGFloat = 24
    static let sectionHeaderH: CGFloat = 40
    /// iPad 等宽屏上的内容最大宽度：列表与按钮保持居中、不横跨整屏。
    static let contentMaxWidth: CGFloat = 760

    static let row1: CGFloat = 56
    static let row2: CGFloat = 72
    static let row3: CGFloat = 88
    static let navBarH: CGFloat = 56
    static let headerExpanded: CGFloat = 96
    static let tabBarH: CGFloat = 56

    static let buttonH: CGFloat = 48
    static let inputH: CGFloat = 52
    static let chipH: CGFloat = 32
    static let switchSize = CGSize(width: 52, height: 32)
    static let chartH: CGFloat = 240
    static let touchMin: CGFloat = 44
    static let iconButtonBox: CGFloat = 48

    static let icon16: CGFloat = 16
    static let icon20: CGFloat = 20
    static let icon24: CGFloat = 24
    static let icon32: CGFloat = 32
    static let icon40: CGFloat = 40
    static let icon48: CGFloat = 48
    static let icon64: CGFloat = 64
    static let avatar40: CGFloat = 40
    static let avatar56: CGFloat = 56
}

enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let input: CGFloat = 10
    static let card: CGFloat = 12
    static let sheet: CGFloat = 20
    static let pill: CGFloat = 999
}

enum Stroke {
    static let one: CGFloat = 1
    static let two: CGFloat = 2
    static let three: CGFloat = 3
}

// MARK: - 动效令牌

enum Motion {
    static let d100: TimeInterval = 0.10
    static let d150: TimeInterval = 0.15
    static let d200: TimeInterval = 0.20
    static let d300: TimeInterval = 0.30

    static let standard = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
    static let enter = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
    static let exit = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
    static let linear = CAMediaTimingFunction(name: .linear)

    /// 标准曲线的 UIView 动画参数（UIView 只支持系统曲线，语义以 200ms/easeOut 近似）。
    static var standardCurve: UIView.AnimationOptions { .curveEaseOut }
}

enum Elevation {
    case card, floating, overlay

    var opacity: Float {
        switch self {
        case .card: return 0.06
        case .floating: return 0.10
        case .overlay: return 0.14
        }
    }

    var radius: CGFloat {
        switch self {
        case .card: return 8
        case .floating: return 16
        case .overlay: return 24
        }
    }

    var offset: CGSize {
        switch self {
        case .card: return CGSize(width: 0, height: 2)
        case .floating: return CGSize(width: 0, height: 6)
        case .overlay: return CGSize(width: 0, height: 10)
        }
    }
}

// MARK: - 字体令牌

enum AppText: CaseIterable {
    case display, title, headline, body, callout, caption, footnote
    case numericXL, numericL, numericM

    var size: CGFloat {
        switch self {
        case .display: return 34
        case .title: return 28
        case .headline: return 22
        case .body: return 17
        case .callout: return 15
        case .caption: return 13
        case .footnote: return 11
        case .numericXL: return 40
        case .numericL: return 28
        case .numericM: return 20
        }
    }

    var lineHeight: CGFloat {
        switch self {
        case .display: return 40
        case .title: return 36
        case .headline: return 28
        case .body: return 24
        case .callout: return 21
        case .caption: return 18
        case .footnote: return 16
        case .numericXL: return 44
        case .numericL: return 34
        case .numericM: return 26
        }
    }

    var weight: UIFont.Weight {
        switch self {
        case .display, .title: return .bold
        case .headline, .numericXL, .numericL: return .semibold
        case .callout, .numericM: return .medium
        case .body, .caption, .footnote: return .regular
        }
    }

    var kern: CGFloat {
        switch self {
        case .display: return -0.4
        case .title: return -0.2
        case .numericXL: return -0.2
        default: return 0
        }
    }

    var isNumeric: Bool {
        switch self {
        case .numericXL, .numericL, .numericM: return true
        default: return false
        }
    }

    var textStyle: UIFont.TextStyle {
        switch self {
        case .display: return .largeTitle
        case .title: return .title1
        case .headline: return .headline
        case .body, .numericM: return .body
        case .callout: return .callout
        case .caption: return .caption1
        case .footnote: return .footnote
        case .numericXL, .numericL: return .title1
        }
    }

    func font(compatibleWith trait: UITraitCollection? = nil) -> UIFont {
        let base: UIFont = isNumeric
            ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base, compatibleWith: trait)
    }

    func attributes(
        color: UIColor,
        alignment: NSTextAlignment = .natural,
        trait: UITraitCollection? = nil
    ) -> [NSAttributedString.Key: Any] {
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        let scaledLineHeight = metrics.scaledValue(for: lineHeight, compatibleWith: trait)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.minimumLineHeight = scaledLineHeight
        paragraph.maximumLineHeight = scaledLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font(compatibleWith: trait),
            .foregroundColor: color,
            .kern: kern,
            .paragraphStyle: paragraph,
        ]
    }
}

extension UIFont {
    static var appDisplay: UIFont { AppText.display.font() }
    static var appTitle: UIFont { AppText.title.font() }
    static var appHeadline: UIFont { AppText.headline.font() }
    static var appBody: UIFont { AppText.body.font() }
    static var appCallout: UIFont { AppText.callout.font() }
    static var appCaption: UIFont { AppText.caption.font() }
    static var appFootnote: UIFont { AppText.footnote.font() }
    static var appNumericXL: UIFont { AppText.numericXL.font() }
    static var appNumericL: UIFont { AppText.numericL.font() }
    static var appNumericM: UIFont { AppText.numericM.font() }
}

// MARK: - 视图扩展

extension UIView {
    /// 卡片：surface + 1dp 描边 + 12 圆角，列表内零阴影。
    func styleAsCardSurface() {
        backgroundColor = Palette.surface
        layer.cornerRadius = Radius.card
        layer.cornerCurve = .continuous
        layer.borderWidth = Stroke.one
        layer.borderColor = Palette.divider.resolvedColor(with: traitCollection).cgColor
    }

    /// 仅浮层使用阴影；深色模式关闭阴影，靠表面色阶与描边表达层级。
    func applyElevation(_ level: Elevation) {
        guard traitCollection.userInterfaceStyle == .light else {
            layer.shadowOpacity = 0
            layer.shadowRadius = 0
            layer.shadowOffset = .zero
            return
        }
        layer.shadowColor = UIColor(red: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0, alpha: 1).cgColor
        layer.shadowOpacity = level.opacity
        layer.shadowRadius = level.radius
        layer.shadowOffset = level.offset
        layer.masksToBounds = false
    }

    /// CALayer 不随动态色自动更新；外观切换时重设描边。
    func refreshDynamicLayerColors() {
        layer.borderColor = Palette.divider.resolvedColor(with: traitCollection).cgColor
        if traitCollection.userInterfaceStyle == .dark {
            layer.shadowOpacity = 0
        }
    }
}

/// 悬浮 Tab 的底部留白计算：独立成纯函数，避免各页面各自算错或漏算。
enum BottomOcclusion {
    /// - Parameters:
    ///   - overlap: 悬浮 Tab 与滚动视图可见区域的重叠高度。
    ///   - automaticInset: 滚动视图已自动获得的 safe-area 底部补偿。
    ///   - spacing: Tab 之上额外保留的最小留白。
    static func inset(overlap: CGFloat, automaticInset: CGFloat, spacing: CGFloat) -> CGFloat {
        max(0, overlap - max(0, automaticInset)) + max(0, spacing)
    }
}

/// 底部条带：从悬浮 Tab 顶边一直遮挡到屏幕底边（含底部安全区）。
/// iOS 26 的悬浮胶囊只覆盖自身，胶囊下方与两侧仍会透出滚动内容，因此需要在最上层铺一条
/// 与画布同色的不透明条带；纯函数便于单测覆盖高度计算。
enum BottomBand {
    static func frame(containerSize: CGSize, barTop: CGFloat) -> CGRect {
        let top = min(max(0, barTop), max(0, containerSize.height))
        return CGRect(x: 0, y: top, width: containerSize.width, height: max(0, containerSize.height - top))
    }
}

extension UIViewController {
    /// 底部滚动留白：把最后一项抬到 Tab 之上，并额外留 `spacing`。
    /// iOS 26+ 的悬浮 Tab 不一定计入 `safeAreaInsets`，因此用视图坐标算实际遮挡量，
    /// 并扣除滚动视图已自动获得的 safe-area inset，避免重复留白。
    func applyBottomOcclusionInset(to scrollView: UIScrollView, spacing: CGFloat = Layout.space24) {
        guard let tabBar = tabBarController?.tabBar, !tabBar.isHidden, tabBar.alpha > 0 else {
            if abs(scrollView.contentInset.bottom - spacing) > 0.5 {
                scrollView.contentInset.bottom = spacing
            }
            return
        }
        let tabFrame = view.convert(tabBar.bounds, from: tabBar)
        let overlap = scrollView.frame.maxY - tabFrame.minY
        let automatic = scrollView.adjustedContentInset.bottom - scrollView.contentInset.bottom
        let bottom = BottomOcclusion.inset(overlap: overlap, automaticInset: automatic, spacing: spacing)
        if abs(scrollView.contentInset.bottom - bottom) > 0.5 {
            scrollView.contentInset.bottom = bottom
            scrollView.scrollIndicatorInsets.bottom = bottom
        }
    }
}

extension UILabel {
    func apply(
        _ text: AppText,
        color: UIColor,
        alignment: NSTextAlignment = .natural,
        compatibleWith trait: UITraitCollection? = nil
    ) {
        self.attributedText = NSAttributedString(
            string: self.text ?? "",
            attributes: text.attributes(color: color, alignment: alignment, trait: trait)
        )
    }

    /// 等宽数字：读数、阈值、计数使用，避免数字跳动。
    func applyNumeric(_ text: AppText, color: UIColor, alignment: NSTextAlignment = .right) {
        apply(text, color: color, alignment: alignment)
    }
}
