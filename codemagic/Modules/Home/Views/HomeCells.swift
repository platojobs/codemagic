import UIKit

/// 首页设备卡片：名称、连接状态、最近一条读数、信号条。
final class DeviceCardCell: UICollectionViewCell {
    static let reuseIdentifier = "DeviceCardCell"

    private let card = AppCardControl()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let readingLabel = UILabel()
    private let timeLabel = UILabel()
    private let signalView = RSISignalView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        nameLabel.applyFont(AppText.body.font(weight: .semibold))
        nameLabel.textColor = Palette.textPrimary
        // 名称单独占行，最多两行；过长的名称才省略，不再和状态抢同一行的宽度。
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail

        statusLabel.applyFont(AppText.caption.font(weight: .medium))
        statusLabel.textAlignment = .natural
        statusLabel.numberOfLines = 1
        // 状态（未连接 / 已连接 / 离线）必须完整可读，排在名称下一行且不被挤压。
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        readingLabel.applyFont(AppText.numericM.font())
        readingLabel.textColor = Palette.textPrimary
        readingLabel.adjustsFontForContentSizeCategory = true

        timeLabel.applyFont(AppText.footnote.font())
        timeLabel.textColor = Palette.textTertiary

        signalView.translatesAutoresizingMaskIntoConstraints = false

        let top = UIStackView(arrangedSubviews: [nameLabel, statusLabel])
        top.axis = .vertical
        top.spacing = Layout.space4
        top.alignment = .fill

        let bottom = UIStackView(arrangedSubviews: [signalView, timeLabel])
        bottom.axis = .horizontal
        bottom.spacing = Layout.space8
        bottom.alignment = .center

        let stack = UIStackView(arrangedSubviews: [top, readingLabel, UIView(), bottom])
        stack.axis = .vertical
        stack.spacing = Layout.space8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            signalView.widthAnchor.constraint(equalToConstant: Layout.space32),
            signalView.heightAnchor.constraint(equalToConstant: Layout.icon20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        card.refreshDynamicLayerColors()
    }

    func configure(
        device: SavedDevice,
        isConnected: Bool,
        readingText: String,
        rssi: Int?,
        isUnsynced: Bool = false,
        onTap: @escaping () -> Void
    ) {
        nameLabel.text = device.displayName
        if !device.isConnectable {
            statusLabel.text = L10n.t("home.status.crossPlatform")
            statusLabel.textColor = Palette.textTertiary
        } else if isConnected {
            statusLabel.text = L10n.t("home.status.connected")
            statusLabel.textColor = Palette.success
        } else {
            statusLabel.text = L10n.t("home.status.disconnected")
            statusLabel.textColor = Palette.textSecondary
        }
        readingLabel.text = readingText
        signalView.isSignalUnavailable = rssi == nil
        signalView.rssi = rssi ?? -100
        let timeText: String
        if let lastSeenAt = device.lastSeenAt {
            timeText = Self.relativeFormatter.localizedString(for: lastSeenAt, relativeTo: Date())
        } else {
            timeText = L10n.t("home.status.notConnectedYet")
        }
        // 离线 / 未接入家庭的设备保留展示，但明确标注「未同步」，不假装已同步。
        // 已标记时用标记状态表达（含「待同步」），避免重复追加「未同步」。
        var timeParts = [timeText]
        if let mark = device.markStatusText {
            timeParts.append(mark)
        } else if isUnsynced {
            timeParts.append(L10n.t("device.sync.unsynced"))
        }
        timeLabel.text = timeParts.joined(separator: " · ")
        card.onTap(onTap)
        accessibilityLabel = L10n.f("home.a11y.card", device.displayName, statusLabel.text ?? "", readingText)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.current
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// 快捷场景卡：图标、名称、动作数量与「仅本机」标记。
final class QuickScenarioCell: UICollectionViewCell {
    static let reuseIdentifier = "QuickScenarioCell"

    private let card = AppCardControl()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        iconView.tintColor = Palette.primaryText
        iconView.contentMode = .scaleAspectFit
        iconView.image = UIImage(
            systemName: SymbolName.rule,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon24, weight: .medium)
        )

        nameLabel.applyFont(AppText.body.font(weight: .semibold))
        nameLabel.textColor = Palette.textPrimary
        nameLabel.numberOfLines = 1

        detailLabel.applyFont(AppText.caption.font())
        detailLabel.textColor = Palette.textSecondary
        detailLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [iconView, nameLabel, detailLabel, UIView()])
        stack.axis = .vertical
        stack.spacing = Layout.space8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Layout.icon32),
            iconView.heightAnchor.constraint(equalToConstant: Layout.icon32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(scenario: Scenario, onTap: @escaping () -> Void) {
        nameLabel.text = scenario.name
        detailLabel.text = L10n.f("scenario.cell.actionsLocal", String(describing: scenario.actions.count))
        card.onTap(onTap)
        accessibilityLabel = L10n.f("scenario.cell.a11y", String(describing: scenario.name), String(describing: scenario.actions.count))
    }
}

/// 今日告警摘要：真实触发条数，点击进入智能页。
final class HomeAlertCell: UICollectionViewCell {
    static let reuseIdentifier = "HomeAlertCell"

    private let card = AppCardControl()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let countLabel = UILabel()
    private let rightStack = UIStackView()
    private var statusChip: StatusChipView?
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        titleLabel.applyFont(AppText.callout.font(weight: .semibold))
        titleLabel.text = L10n.t("home.alertSummary")
        titleLabel.textColor = Palette.textPrimary

        detailLabel.applyFont(AppText.caption.font())
        detailLabel.textColor = Palette.textSecondary

        countLabel.applyFont(AppText.numericM.font())
        countLabel.textColor = Palette.textPrimary
        countLabel.textAlignment = .right

        chevron.image = UIImage(
            systemName: SymbolName.disclosure,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon16, weight: .semibold)
        )
        chevron.tintColor = Palette.textTertiary

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = Layout.space4

        rightStack.axis = .horizontal
        rightStack.spacing = Layout.space8
        rightStack.alignment = .center
        rightStack.addArrangedSubview(countLabel)

        let stack = UIStackView(arrangedSubviews: [text, UIView(), rightStack, chevron])
        stack.axis = .horizontal
        stack.spacing = Layout.space12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            chevron.widthAnchor.constraint(equalToConstant: Layout.icon16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(count: Int, summary: String, detail: String, kind: StatusChipView.Kind, onTap: @escaping () -> Void) {
        countLabel.text = "\(count)"
        statusChip?.removeFromSuperview()
        let chip = StatusChipView(text: count > 0 ? L10n.t("home.alertSummary.needsAttention") : L10n.t("home.alertSummary.normal"), kind: kind)
        statusChip = chip
        rightStack.addArrangedSubview(chip)
        detailLabel.text = "\(summary) · \(detail)"
        card.onTap(onTap)
    }
}

/// 首页空状态：真实文案 + 主行动。
final class HomeEmptyCell: UICollectionViewCell {
    static let reuseIdentifier = "HomeEmptyCell"
    private let emptyView = EmptyStateView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(emptyView)
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: contentView.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(symbol: String, title: String, message: String, actionTitle: String?, action: (() -> Void)?) {
        emptyView.configure(
            symbolName: symbol,
            title: title,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
    }
}

/// 首页错误块：可重试。
final class HomeErrorCell: UICollectionViewCell {
    static let reuseIdentifier = "HomeErrorCell"
    private let errorView = ErrorStateView(height: 120)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(errorView)
        errorView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: contentView.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: String, retry: @escaping () -> Void) {
        errorView.configure(title: L10n.t("home.loadLocalFailed"), message: message, action: retry)
    }
}

/// 分区头（UICollectionReusableView 包装 `SectionHeaderView`），房间分区支持点击展开 / 收起。
final class HomeSectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "HomeSectionHeaderView"
    /// 当前展示的头视图；复用时会替换，不能只移除初始那一个，否则旧标题会叠在下面。
    private var header: SectionHeaderView?
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        onToggle = nil
        rebuild(title: title, trailing: nil)
    }

    func configure(title: String, collapsed: Bool, onToggle: @escaping () -> Void) {
        let chevron = UIImageView(image: UIImage(systemName: collapsed ? "chevron.down" : "chevron.up"))
        chevron.tintColor = AppTheme.Palette.secondaryText
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.accessibilityIdentifier = "roomSectionChevron"
        rebuild(title: title, trailing: chevron)
        self.onToggle = onToggle
        accessibilityLabel = title
        accessibilityHint = collapsed ? L10n.t("room.expand") : L10n.t("room.collapse")
    }

    @objc private func handleTap() {
        onToggle?()
    }

    private func rebuild(title: String, trailing: UIView?) {
        header?.removeFromSuperview()
        let replacement = SectionHeaderView(title: title, trailing: trailing)
        replacement.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replacement)
        NSLayoutConstraint.activate([
            replacement.topAnchor.constraint(equalTo: topAnchor),
            replacement.leadingAnchor.constraint(equalTo: leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: trailingAnchor),
            replacement.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        header = replacement
    }
}
