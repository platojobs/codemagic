import UIKit

/// 规则行：名称、触发条件描述与启停开关。
final class RuleCell: UITableViewCell {
    static let reuseIdentifier = "RuleCell"

    private let nameLabel = AppTheme.makeLabel(style: .body, color: AppTheme.Palette.primaryText)
    private let descriptionLabel = AppTheme.makeLabel(style: .caption1, color: AppTheme.Palette.secondaryText)
    private let textStack = UIStackView()
    private let container = UIView()
    private let toggle = UISwitch()

    private var onToggle: (() -> Void)?

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

    func configure(rule: DeviceRule, targetName: String, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        nameLabel.text = rule.name
        descriptionLabel.text = "\(rule.triggerDescription) · \(targetName)"
        toggle.isOn = rule.isEnabled
        toggle.accessibilityLabel = L10n.f("rule.cell.toggle", String(describing: rule.name))
    }

    @objc private func handleToggle() {
        onToggle?()
    }

    private func configureHierarchy() {
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(descriptionLabel)

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(handleToggle), for: .valueChanged)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 名称与说明在 AX 档都要完整换行：横向用栈把宽度定死，
        // 早先用 trailing 「<=」约束时宽度在自适应行高测量阶段不收敛，
        // 单元格高度按单行算出，规则名被截成「设备断开…」。
        let row = UIStackView(arrangedSubviews: [textStack, toggle])
        row.axis = .horizontal
        row.spacing = Layout.space12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(row)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            toggle.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.touchMin),
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}
