import UIKit

/// 设置开关行。
final class SwitchCell: UITableViewCell {
    static let reuseIdentifier = "SwitchCell"

    private let toggle = UISwitch()
    private var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        accessoryView = toggle
        toggle.addTarget(self, action: #selector(handleToggle), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        var configuration = defaultContentConfiguration()
        configuration.text = title
        contentConfiguration = configuration
        toggle.isOn = isOn
        toggle.accessibilityLabel = title
    }

    @objc private func handleToggle() {
        onToggle?(toggle.isOn)
    }
}
