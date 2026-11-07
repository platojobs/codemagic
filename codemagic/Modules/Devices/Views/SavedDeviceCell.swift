import UIKit

/// 已保存设备行：展示名、分组、最后出现时间与厂商/固件信息。
final class SavedDeviceCell: UITableViewCell {
    static let reuseIdentifier = "SavedDeviceCell"

    private let nameLabel = AppTheme.makeLabel(style: .headline, color: AppTheme.Palette.primaryText)
    private let metaLabel = AppTheme.makeLabel(style: .caption1, color: AppTheme.Palette.secondaryText)
    private let detailLabel = AppTheme.makeLabel(style: .caption2, color: AppTheme.Palette.tertiaryText)
    private let platformNoteLabel = AppTheme.makeLabel(style: .caption2, color: AppTheme.Palette.highlight)
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

    func configure(device: SavedDevice, now: Date = Date()) {
        nameLabel.text = device.displayName

        var metaParts = [device.groupName]
        if let mark = device.markStatusText {
            metaParts.append(mark)
        }
        // 云端状态与相对时间用统一四档实现；跨平台设备的「本机不可连接」在下方单独一行，
        // 两件事同时呈现，不互相遮蔽。
        let linkStatus = DeviceLinkStatus(isConnected: false, presence: device.presence(at: now))
        if let summary = linkStatus.secondaryText(
            connectable: device.isConnectable,
            serverLastSeenAt: device.serverLastSeenAt,
            localLastSeenAt: device.lastSeenAt,
            now: now
        ) {
            metaParts.append(summary)
        } else {
            metaParts.append(linkStatus.cloudStatusText)
        }
        metaLabel.text = metaParts.joined(separator: " · ")

        var detailParts: [String] = []
        if let vendor = device.vendor, !vendor.isEmpty {
            detailParts.append(vendor)
        }
        if let firmware = device.firmwareVersion, !firmware.isEmpty {
            detailParts.append(L10n.f("device.cell.firmware", String(describing: firmware)))
        }
        if detailParts.isEmpty {
            detailParts.append(L10n.t("device.cell.noVendor"))
        }
        detailLabel.text = detailParts.joined(separator: " · ")

        if let note = device.connectUnavailableText {
            platformNoteLabel.text = note
            platformNoteLabel.isHidden = false
            accessoryType = .none
            selectionStyle = .none
        } else {
            platformNoteLabel.text = nil
            platformNoteLabel.isHidden = true
            accessoryType = .disclosureIndicator
            selectionStyle = .default
        }
    }

    private func configureHierarchy() {
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(metaLabel)
        textStack.addArrangedSubview(detailLabel)
        textStack.addArrangedSubview(platformNoteLabel)
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
