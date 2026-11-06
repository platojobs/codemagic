import UIKit

/// 兼容性 / 指南用的信息卡：标题 + 多行正文。
final class MarketInfoCell: UITableViewCell {
    static let reuseIdentifier = "MarketInfoCell"

    private let container = UIView()
    private let titleLabel = AppTheme.makeLabel(text: .callout, color: Palette.textPrimary)
    private let bodyLabel = AppTheme.makeLabel(text: .caption, color: Palette.textSecondary)
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String?, body: String, bodyColor: UIColor = Palette.textSecondary) {
        titleLabel.text = title
        titleLabel.isHidden = title == nil
        bodyLabel.text = body
        bodyLabel.textColor = bodyColor
        isAccessibilityElement = true
        accessibilityLabel = title ?? body
        accessibilityValue = title == nil ? nil : body
    }

    private func configureHierarchy() {
        stack.axis = .vertical
        stack.spacing = Layout.space8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(bodyLabel)

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}

/// 选购指南卡：场景标题、建议、可选型号与依据。
final class MarketScenarioCell: UITableViewCell {
    static let reuseIdentifier = "MarketScenarioCell"

    private let container = UIView()
    private let titleLabel = AppTheme.makeLabel(text: .headline, color: Palette.textPrimary)
    private let adviceLabel = AppTheme.makeLabel(text: .body, color: Palette.textSecondary)
    private let candidatesLabel = AppTheme.makeLabel(text: .caption, color: Palette.primaryText)
    private let evidenceLabel = AppTheme.makeLabel(text: .footnote, color: Palette.textTertiary)
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(recommendation: ScenarioRecommendation) {
        titleLabel.text = recommendation.scenario.title
        adviceLabel.text = recommendation.scenario.advice
        candidatesLabel.text = L10n.f("market.guide.recommended", recommendation.candidatesText)
        evidenceLabel.text = recommendation.evidence
        isAccessibilityElement = true
        accessibilityLabel = recommendation.scenario.title
        accessibilityValue = [
            recommendation.scenario.advice,
            recommendation.candidatesText,
            recommendation.evidence,
        ].joined(separator: L10n.t("common.a11ySeparator"))
    }

    private func configureHierarchy() {
        stack.axis = .vertical
        stack.spacing = Layout.space8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(adviceLabel)
        stack.addArrangedSubview(candidatesLabel)
        stack.addArrangedSubview(evidenceLabel)

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}

/// 服务入口行：图标 + 标题/说明 + 右侧箭头。
final class MarketLinkCell: UITableViewCell {
    static let reuseIdentifier = "MarketLinkCell"

    private let container = UIView()
    private let iconView = UIImageView()
    private let titleLabel = AppTheme.makeLabel(text: .body, color: Palette.textPrimary)
    private let subtitleLabel = AppTheme.makeLabel(text: .caption, color: Palette.textSecondary)
    private let chevronView = UIImageView()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .default
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(symbolName: String, title: String, subtitle: String) {
        iconView.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon20, weight: .medium)
        )
        titleLabel.text = title
        subtitleLabel.text = subtitle
        isAccessibilityElement = true
        accessibilityLabel = [title, subtitle].joined(separator: L10n.t("common.a11ySeparator"))
    }

    private func configureHierarchy() {
        iconView.tintColor = Palette.primaryText
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.image = UIImage(
            systemName: SymbolName.disclosure,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon16, weight: .medium)
        )
        chevronView.tintColor = Palette.textTertiary
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = Layout.space4

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Layout.space12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(textStack)
        stack.addArrangedSubview(chevronView)

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.row2),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            iconView.widthAnchor.constraint(equalToConstant: Layout.icon24),
            iconView.heightAnchor.constraint(equalToConstant: Layout.icon24),
            chevronView.widthAnchor.constraint(equalToConstant: Layout.icon16),
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}
