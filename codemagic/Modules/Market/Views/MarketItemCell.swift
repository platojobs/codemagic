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

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
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

        nameLabel.text = item.name.isEmpty ? "未命名条目" : item.name

        var metaParts: [String] = []
        if !item.vendor.isEmpty { metaParts.append(item.vendor) }
        if !item.version.isEmpty { metaParts.append("版本 \(item.version)") }
        metaLabel.text = metaParts.isEmpty ? "厂商与版本信息未提供" : metaParts.joined(separator: " · ")

        compatibilityLabel.text = "兼容：\(item.compatibility.isEmpty ? "暂无说明" : item.compatibility)"
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
        contentView.addSubview(textStack)

        kindLabel.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: AppTheme.Metrics.contentMargins
            ),
            textStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -AppTheme.Metrics.contentMargins
            ),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: AppTheme.Spacing.medium),
            textStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -AppTheme.Spacing.medium
            ),
        ])
    }
}
