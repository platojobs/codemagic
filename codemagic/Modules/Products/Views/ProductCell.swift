import UIKit

/// 产品型号行：厂商、型号、固件版本与 MAC。
final class ProductCell: UITableViewCell {
    static let reuseIdentifier = "ProductCell"

    private let titleLabel = AppTheme.makeLabel(style: .headline, color: AppTheme.Palette.primaryText)
    private let metaLabel = AppTheme.makeLabel(style: .caption1, color: AppTheme.Palette.secondaryText)
    private let footnoteLabel = AppTheme.makeLabel(style: .caption2, color: AppTheme.Palette.tertiaryText)
    private let textStack = UIStackView()
    private let container = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        backgroundColor = .clear
        selectionStyle = .default
        let selected = UIView()
        selected.backgroundColor = Palette.overlayPressed
        selected.layer.cornerRadius = Radius.card
        selectedBackgroundView = selected
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(product: ProductModel) {
        titleLabel.text = product.deviceType.isEmpty ? "未命名型号" : product.deviceType
        metaLabel.text = "\(product.vendor.isEmpty ? "未知厂商" : product.vendor) · 固件 \(product.firmwareVersion.isEmpty ? "未知" : product.firmwareVersion)"
        footnoteLabel.text = "MAC \(product.mac.isEmpty ? "—" : product.mac) · GATT \(product.gattServices.count) 项"
    }

    private func configureHierarchy() {
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(metaLabel)
        textStack.addArrangedSubview(footnoteLabel)
        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(textStack)

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
