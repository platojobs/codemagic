import UIKit

/// 产品型号行：厂商、型号、固件版本与 MAC。
final class ProductCell: UITableViewCell {
    static let reuseIdentifier = "ProductCell"

    private let titleLabel = AppTheme.makeLabel(style: .headline, color: AppTheme.Palette.primaryText)
    private let metaLabel = AppTheme.makeLabel(style: .caption1, color: AppTheme.Palette.secondaryText)
    private let footnoteLabel = AppTheme.makeLabel(style: .caption2, color: AppTheme.Palette.tertiaryText)
    private let textStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
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
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: AppTheme.Metrics.contentMargins
            ),
            textStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -AppTheme.Spacing.small
            ),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: AppTheme.Spacing.medium),
            textStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -AppTheme.Spacing.medium
            ),
        ])
    }
}
