import UIKit

/// 设备详情信号行：dBm 数值、对应档位格数与读数时间；未知时只写「无信号数据」。
final class DeviceSignalCell: UITableViewCell {
    static let reuseIdentifier = "DeviceSignalCell"

    private let titleLabel = AppTheme.makeLabel(style: .body, color: AppTheme.Palette.primaryText)
    private let valueLabel = AppTheme.makeLabel(style: .body, color: AppTheme.Palette.secondaryText)
    private let detailLabel = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.tertiaryText)
    private let signalView = RSISignalView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.text = L10n.t("device.detail.signal")
        signalView.translatesAutoresizingMaskIntoConstraints = false

        let top = UIStackView(arrangedSubviews: [titleLabel, UIView(), signalView])
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = Layout.space8

        let stack = UIStackView(arrangedSubviews: [top, valueLabel, detailLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Layout.space4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: Layout.space8),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -Layout.space8),
            signalView.widthAnchor.constraint(equalToConstant: Layout.space32),
            signalView.heightAnchor.constraint(equalToConstant: Layout.icon20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(reading: DeviceDetailViewModel.SignalReading) {
        guard let rssi = reading.rssi, let readAt = reading.readAt, RSISignalView.isValid(rssi) else {
            signalView.rssi = nil
            valueLabel.text = L10n.t("signal.tier.unknown")
            detailLabel.text = nil
            detailLabel.isHidden = true
            return
        }

        let tier = RSISignalView.tier(for: rssi)
        signalView.rssi = rssi
        valueLabel.text = L10n.f("device.detail.signalValue", String(describing: rssi), String(describing: tier.barCount))
        let detailKey: String
        switch reading.status {
        case .live:
            detailKey = "device.detail.signalDetailLive"
        case .refreshFailed:
            detailKey = "device.detail.signalDetailFailed"
        case .lastScan, .unknown:
            detailKey = "device.detail.signalDetailScan"
        }
        detailLabel.text = L10n.f(
            detailKey,
            L10n.t(tier.localizationKey),
            AppDateFormat.absolute(readAt)
        )
        detailLabel.isHidden = false
    }
}
