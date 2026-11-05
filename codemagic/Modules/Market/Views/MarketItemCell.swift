import UIKit

/// 市场条目行：类型、名称、厂商/版本、兼容性说明与简介。
final class MarketItemCell: UITableViewCell {
    static let reuseIdentifier = "MarketItemCell"

    private let kindLabel = AppTheme.makeBadgeLabel(text: "", color: AppTheme.Palette.accent)
    private let nameLabel = AppTheme.makeLabel(style: .headline, color: AppTheme.Palette.primaryText)
    private let metaLabel = AppTheme.makeLabel(style: .caption1, color: AppTheme.Palette.secondaryText)
    private let compatibilityLabel = AppTheme.makeLabel(style: .caption1, color: AppTheme.Palette.secondaryText)
    private let summaryLabel = AppTheme.makeLabel(style: .caption2, color: AppTheme.Palette.tertiaryText)
    private let textStack = UIStackView()
    private let container = UIView()

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

    func configure(item: MarketItem) {
        kindLabel.text = item.kind.title
        kindLabel.textColor = item.kind == .firmware
            ? AppTheme.Palette.highlight
            : AppTheme.Palette.accent
        kindLabel.backgroundColor = kindLabel.textColor.withAlphaComponent(0.15)

        nameLabel.text = item.name.isEmpty ? L10n.t("market.item.unnamed") : item.name

        var metaParts: [String] = []
        if !item.vendor.isEmpty { metaParts.append(item.vendor) }
        if !item.version.isEmpty { metaParts.append(L10n.f("market.item.version", String(describing: item.version))) }
        metaLabel.text = metaParts.isEmpty ? L10n.t("market.item.noVendorVersion") : metaParts.joined(separator: " · ")

        compatibilityLabel.text = L10n.f("market.item.compatibility", item.compatibility.isEmpty ? L10n.t("market.item.noCompatibility") : item.compatibility)
        summaryLabel.text = item.summary.isEmpty ? nil : item.summary
        summaryLabel.isHidden = item.summary.isEmpty
    }

    private func configureHierarchy() {
        textStack.axis = .vertical
        textStack.spacing = AppTheme.Spacing.xSmall
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(kindLabel)
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(metaLabel)
        textStack.addArrangedSubview(compatibilityLabel)
        textStack.addArrangedSubview(summaryLabel)
        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(textStack)

        kindLabel.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            textStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}
