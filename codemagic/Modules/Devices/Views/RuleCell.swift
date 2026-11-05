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

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(textStack)
        container.addSubview(toggle)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: toggle.leadingAnchor,
                constant: -Layout.space12
            ),
            toggle.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Layout.cardPadding
            ),
            toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}
