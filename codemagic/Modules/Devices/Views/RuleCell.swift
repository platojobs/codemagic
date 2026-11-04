import UIKit

/// 规则行：名称、触发条件描述与启停开关。
final class RuleCell: UITableViewCell {
    static let reuseIdentifier = "RuleCell"

    private let nameLabel = AppTheme.makeLabel(style: .body, color: AppTheme.Palette.primaryText)
    private let descriptionLabel = AppTheme.makeLabel(style: .caption1, color: AppTheme.Palette.secondaryText)
    private let textStack = UIStackView()
    private let toggle = UISwitch()

    private var onToggle: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
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
        toggle.accessibilityLabel = "启用规则 \(rule.name)"
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

        contentView.addSubview(textStack)
        contentView.addSubview(toggle)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: AppTheme.Metrics.contentMargins
            ),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: AppTheme.Spacing.medium),
            textStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -AppTheme.Spacing.medium
            ),
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: toggle.leadingAnchor,
                constant: -AppTheme.Spacing.small
            ),

            toggle.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -AppTheme.Metrics.contentMargins
            ),
            toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
}
