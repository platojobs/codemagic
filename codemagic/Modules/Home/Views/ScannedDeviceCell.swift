import UIKit

/// 首页设备行：名称、标识符、RSSI（自绘信号条）与保存按钮，全部纯代码布局。
final class ScannedDeviceCell: UITableViewCell {
    static let reuseIdentifier = "ScannedDeviceCell"

    // MARK: - Subviews

    private let nameLabel = AppTheme.makeLabel(style: .headline, color: AppTheme.Palette.primaryText)
    private let identifierLabel = AppTheme.makeLabel(style: .caption1, color: AppTheme.Palette.secondaryText)
    private let rssiLabel = AppTheme.makeLabel(style: .caption1, color: AppTheme.Palette.secondaryText)
    private let signalView = RSISignalView()
    private let saveButton = UIButton(type: .system)
    private let textStack = UIStackView()

    private var onSave: (() -> Void)?

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureSubviews()
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    func configure(row: HomeDeviceRow, onSave: @escaping () -> Void) {
        self.onSave = onSave
        nameLabel.text = row.name
        identifierLabel.text = L10n.f("scanned.identifier", String(describing: row.peripheralID.uuidString.prefix(8)))

        let validRSSI = RSISignalView.isValid(row.rssi)
        signalView.rssi = validRSSI ? row.rssi : nil
        if let rssi = row.rssi, validRSSI {
            rssiLabel.text = "\(AppDateFormat.rssi(rssi)) · \(AppDateFormat.relative(row.lastSeenAt))"
        } else {
            rssiLabel.text = L10n.f("scanned.lastSeen", String(describing: AppDateFormat.relative(row.lastSeenAt)))
        }

        var configuration = UIButton.Configuration.tinted()
        configuration.title = row.isSaved ? L10n.t("common.saved") : L10n.t("common.save")
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: AppTheme.Spacing.xSmall,
            leading: AppTheme.Spacing.medium,
            bottom: AppTheme.Spacing.xSmall,
            trailing: AppTheme.Spacing.medium
        )
        saveButton.configuration = configuration
        saveButton.isEnabled = !row.isSaved
        saveButton.accessibilityLabel = row.isSaved ? L10n.t("scanned.saved") : L10n.f("scanned.saveDeviceA11y", String(describing: row.name))
    }

    // MARK: - Actions

    @objc private func handleSave() {
        onSave?()
    }

    // MARK: - Layout

    private func configureSubviews() {
        selectionStyle = .none
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(identifierLabel)
        textStack.addArrangedSubview(rssiLabel)

        signalView.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureHierarchy() {
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)
        contentView.addSubview(signalView)
        contentView.addSubview(saveButton)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: AppTheme.Metrics.contentMargins
            ),
            textStack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: AppTheme.Spacing.medium
            ),
            textStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -AppTheme.Spacing.medium
            ),
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: signalView.leadingAnchor,
                constant: -AppTheme.Spacing.small
            ),

            signalView.trailingAnchor.constraint(
                equalTo: saveButton.leadingAnchor,
                constant: -AppTheme.Spacing.small
            ),
            signalView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            signalView.widthAnchor.constraint(equalToConstant: 34),
            signalView.heightAnchor.constraint(equalToConstant: 24),

            saveButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -AppTheme.Metrics.contentMargins
            ),
            saveButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
}
