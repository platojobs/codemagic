import UIKit

// MARK: - 按钮

/// 自绘按钮：主 / 次 / 文字 / 危险 / 筛选 Chip。
/// 只变填充色不缩放，按下态为 `primaryPressed` 或叠 `overlayPressed`。
final class AppButton: UIButton {
    enum Style {
        case primary
        case secondary
        case text
        case danger
        case filterChip
    }

    private let style: Style
    private var baseBackground: UIColor = .clear
    private var pressedBackground: UIColor = .clear

    init(style: Style, title: String, symbolName: String? = nil) {
        self.style = style
        super.init(frame: .zero)
        configure(title: title, symbolName: symbolName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isEnabled else { return }
            backgroundColor = isHighlighted ? pressedBackground : baseBackground
        }
    }

    override var isEnabled: Bool {
        didSet { applyEnabledColors() }
    }

    private func configure(title: String, symbolName: String?) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: Layout.space12,
            leading: Layout.space20,
            bottom: Layout.space12,
            trailing: Layout.space20
        )
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = AppText.body.font(weight: .medium)
            outgoing.foregroundColor = nil
            return outgoing
        }
        if let symbolName {
            configuration.image = UIImage(
                systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon16, weight: .medium)
            )
            configuration.imagePadding = Layout.space8
        }
        self.configuration = configuration
        titleLabel?.adjustsFontForContentSizeCategory = true
        layer.cornerRadius = style == .filterChip ? Radius.pill : Radius.card
        layer.cornerCurve = .continuous
        clipsToBounds = true
        heightAnchor.constraint(equalToConstant: style == .filterChip ? Layout.chipH : Layout.buttonH)
            .isActive = true

        switch style {
        case .primary:
            baseBackground = Palette.primary
            pressedBackground = Palette.primaryPressed
            tintColor = Palette.onPrimary
            configuration.baseForegroundColor = Palette.onPrimary
        case .secondary:
            baseBackground = Palette.surface
            pressedBackground = Palette.overlayPressed
            tintColor = Palette.primaryText
            configuration.baseForegroundColor = Palette.primaryText
            layer.borderWidth = Stroke.one
            layer.borderColor = Palette.borderStrong.resolvedColor(with: traitCollection).cgColor
        case .text:
            baseBackground = .clear
            pressedBackground = Palette.overlayPressed
            tintColor = Palette.primaryText
            configuration.baseForegroundColor = Palette.primaryText
        case .danger:
            baseBackground = Palette.dangerFill
            pressedBackground = Palette.dangerPressed
            tintColor = Palette.onPrimary
            configuration.baseForegroundColor = Palette.onPrimary
        case .filterChip:
            baseBackground = Palette.surface
            pressedBackground = Palette.overlayPressed
            tintColor = Palette.textSecondary
            configuration.baseForegroundColor = Palette.textSecondary
            layer.borderWidth = Stroke.one
            layer.borderColor = Palette.border.resolvedColor(with: traitCollection).cgColor
        }
        backgroundColor = baseBackground
        applyEnabledColors()
    }

    private func applyEnabledColors() {
        alpha = 1
        if !isEnabled {
            backgroundColor = style == .danger || style == .primary ? Palette.actionDisabledBg : .clear
            configuration?.baseForegroundColor = Palette.textDisabled
            tintColor = Palette.textDisabled
            layer.borderColor = Palette.divider.resolvedColor(with: traitCollection).cgColor
        } else {
            backgroundColor = isHighlighted ? pressedBackground : baseBackground
            configuration?.baseForegroundColor = defaultForegroundColor
            tintColor = defaultForegroundColor
        }
    }

    private var defaultForegroundColor: UIColor {
        switch style {
        case .primary, .danger: return Palette.onPrimary
        case .secondary, .text: return Palette.primaryText
        case .filterChip: return Palette.textSecondary
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshDynamicLayerColors()
    }

    func setSelectedChip(_ selected: Bool) {
        guard style == .filterChip else { return }
        if selected {
            baseBackground = Palette.chartBand
            configuration?.baseForegroundColor = Palette.primaryText
            layer.borderColor = Palette.primary.resolvedColor(with: traitCollection).cgColor
        } else {
            baseBackground = Palette.surface
            configuration?.baseForegroundColor = Palette.textSecondary
            layer.borderColor = Palette.border.resolvedColor(with: traitCollection).cgColor
        }
        backgroundColor = baseBackground
    }
}

// MARK: - 分区标题

final class SectionHeaderView: UIView {
    private let titleLabel = UILabel()

    init(title: String, trailing: UIView? = nil) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.applyFont(AppText.callout.font(weight: .semibold))
        titleLabel.textColor = Palette.textPrimary

        let stack = UIStackView(arrangedSubviews: [titleLabel])
        if let trailing {
            stack.addArrangedSubview(UIView())
            stack.addArrangedSubview(trailing)
        }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Layout.space8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Layout.sectionHeaderH),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - 状态 Chip

final class StatusChipView: UIView {
    enum Kind {
        case success, warning, danger, neutral
    }

    private let label = UILabel()

    init(text: String, kind: Kind) {
        super.init(frame: .zero)
        label.text = text
        label.applyFont(AppText.caption.font(weight: .medium))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        layer.cornerRadius = Radius.sm
        switch kind {
        case .success:
            backgroundColor = Palette.successBg
            label.textColor = Palette.success
        case .warning:
            backgroundColor = Palette.warningBg
            label.textColor = Palette.warning
        case .danger:
            backgroundColor = Palette.dangerBg
            label.textColor = Palette.danger
        case .neutral:
            backgroundColor = Palette.surfaceSunken
            label.textColor = Palette.textSecondary
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.space8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.space8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Layout.space4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.space4),
            heightAnchor.constraint(equalToConstant: Layout.chipH),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 复用 Chip（例如同步状态在待上传 / 已同步之间切换）。
    func set(text: String, kind: Kind) {
        label.text = text
        switch kind {
        case .success:
            backgroundColor = Palette.successBg
            label.textColor = Palette.success
        case .warning:
            backgroundColor = Palette.warningBg
            label.textColor = Palette.warning
        case .danger:
            backgroundColor = Palette.dangerBg
            label.textColor = Palette.danger
        case .neutral:
            backgroundColor = Palette.surfaceSunken
            label.textColor = Palette.textSecondary
        }
    }
}

// MARK: - 可点卡片

/// 卡片容器：1dp 描边 + 12 圆角 + 零阴影；按下叠 6%/8% 遮罩并缩放 0.98。
final class AppCardControl: UIControl {
    let contentView = UIView()
    private let pressedOverlay = UIView()
    private(set) var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        styleAsCardSurface()
        addSubview(contentView)
        contentView.isUserInteractionEnabled = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: Layout.cardPadding),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.cardPadding),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.cardPadding),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.cardPadding),
        ])

        pressedOverlay.backgroundColor = Palette.overlayPressed
        pressedOverlay.layer.cornerRadius = Radius.card
        pressedOverlay.isUserInteractionEnabled = false
        pressedOverlay.alpha = 0
        addSubview(pressedOverlay)
        pressedOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pressedOverlay.topAnchor.constraint(equalTo: topAnchor),
            pressedOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            pressedOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            pressedOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func onTap(_ action: @escaping () -> Void) {
        onTap = action
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: Motion.d100, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.pressedOverlay.alpha = self.isHighlighted ? 1 : 0
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshDynamicLayerColors()
    }

    @objc private func handleTap() {
        onTap?()
    }
}

// MARK: - 数值

enum NumericText {
    /// 读数 / 阈值 / 计数统一走等宽数字，右对齐。
    static func makeLabel(_ text: AppText = .numericM, color: UIColor = Palette.textPrimary) -> UILabel {
        let label = UILabel()
        label.font = text.font()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.textAlignment = .right
        return label
    }

    static func string(_ value: Double, unit: String, fractionDigits: Int = 1) -> String {
        let formatter = MeasurementNumberFormatter.shared
        formatter.maximumFractionDigits = fractionDigits
        formatter.minimumFractionDigits = fractionDigits
        return "\(formatter.string(from: NSNumber(value: value)) ?? "—") \(unit)"
    }
}

/// 数字格式化跟随系统地区（Locale.current），小数点等符号与用户设置一致。
final class MeasurementNumberFormatter: NumberFormatter, @unchecked Sendable {
    static let shared = MeasurementNumberFormatter()

    private override init() {
        super.init()
        locale = Locale.current
        numberStyle = .decimal
        usesGroupingSeparator = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension AppText {
    /// 同一字号阶梯的加粗变体，避免在业务代码里出现字号字面量。
    func font(weight: UIFont.Weight) -> UIFont {
        let base: UIFont = isNumeric
            ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
    }
}
