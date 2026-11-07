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
        // 名称单独占行、不限制行数；卡片高度由首页按内容测量，AX 字号放大后不会截断。
        nameLabel.numberOfLines = 0
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.lineBreakStrategy = .pushOut

        statusLabel.applyFont(AppText.caption.font(weight: .medium))
        statusLabel.textAlignment = .natural
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.lineBreakStrategy = .pushOut
        // 状态（未连接 / 已连接 / 跨平台）必须完整可读，排在名称下一行且不被挤压。
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        readingLabel.applyFont(AppText.numericM.font())
        readingLabel.textColor = Palette.textPrimary
        readingLabel.adjustsFontForContentSizeCategory = true
        readingLabel.numberOfLines = 0
        readingLabel.lineBreakMode = .byWordWrapping
        readingLabel.lineBreakStrategy = .pushOut

        timeLabel.applyFont(AppText.footnote.font())
        timeLabel.textColor = Palette.textTertiary
        timeLabel.numberOfLines = 0
        timeLabel.lineBreakMode = .byWordWrapping
        timeLabel.lineBreakStrategy = .pushOut

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
        presence: DevicePresence,
        readingText: String,
        rssi: Int?,
        cloudReportedAt: Date? = nil,
        isUnsynced: Bool = false,
        onTap: @escaping () -> Void
    ) {
        nameLabel.text = device.displayName
        // 与房间详情共用同一份四档判定：本机 BLE 连接优先，其次服务端上报状态。
        let linkStatus = DeviceLinkStatus(isConnected: isConnected, presence: presence)
        if device.isConnectable {
            statusLabel.text = linkStatus.title
            statusLabel.textColor = linkStatus.isLocalConnected ? Palette.success : Palette.textSecondary
        } else {
            // 「本机不可连接」只是本机连接说明，云端状态仍在下面的时间行同时呈现。
            statusLabel.text = linkStatus.notConnectableText
            statusLabel.textColor = Palette.textTertiary
        }
        readingLabel.text = readingText
        signalView.isSignalUnavailable = rssi == nil
        signalView.rssi = rssi ?? -100
        let timeText: String?
        if !device.isConnectable {
            timeText = linkStatus.secondaryText(
                connectable: false,
                serverLastSeenAt: device.serverLastSeenAt,
                localLastSeenAt: device.lastSeenAt
            )
        } else if let secondary = linkStatus.secondaryText(
            connectable: true,
            serverLastSeenAt: device.serverLastSeenAt,
            localLastSeenAt: device.lastSeenAt
        ) {
            timeText = secondary
        } else if let cloudReportedAt {
            // 本机没扫描过这台设备，用云端最近上报时间说明读数来源，不写成「尚未连接」。
            timeText = L10n.f("home.cloudReported", RelativeTimeText.short(for: cloudReportedAt))
        } else {
            timeText = nil
        }
        // 离线 / 未接入家庭的设备保留展示，但明确标注「未同步」，不假装已同步。
        // 已标记时用标记状态表达（含「待同步」），避免重复追加「未同步」。
        var timeParts: [String] = []
        if let timeText {
            timeParts.append(timeText)
        }
        if let mark = device.markStatusText {
            timeParts.append(mark)
        } else if isUnsynced {
            timeParts.append(L10n.t("device.sync.unsynced"))
        }
        // 卡片宽度有限，第二段（已标记 / 待同步 / 未同步）始终独占一行，
        // 避免默认字号下「已标记」被拆成「已 / 标记」；AX 档同样适用。
        timeLabel.text = timeParts.joined(separator: "\n")
        card.onTap(onTap)
        accessibilityLabel = L10n.f("home.a11y.card", device.displayName, statusLabel.text ?? "", readingText)
    }
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
        nameLabel.numberOfLines = 0
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.lineBreakStrategy = .pushOut

        detailLabel.applyFont(AppText.caption.font())
        detailLabel.textColor = Palette.textSecondary
        detailLabel.numberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.lineBreakStrategy = .pushOut

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
    private let spacer = UIView()
    private let contentStack = UIStackView()

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
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.lineBreakStrategy = .pushOut

        detailLabel.applyFont(AppText.caption.font())
        detailLabel.textColor = Palette.textSecondary
        detailLabel.numberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.lineBreakStrategy = .pushOut

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

        let stack = contentStack
        [text, spacer, rightStack, chevron].forEach(stack.addArrangedSubview)
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
        applyArrangement()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory else { return }
        applyArrangement()
    }

    /// 常规字号横排；AX 档改为竖排，避免标题被右侧计数 / 状态胶囊挤成「今日告警…」。
    private func applyArrangement() {
        let isAccessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        contentStack.axis = isAccessibility ? .vertical : .horizontal
        contentStack.alignment = isAccessibility ? .leading : .center
        spacer.isHidden = isAccessibility
        chevron.isHidden = isAccessibility
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

/// 分区头（UICollectionReusableView 包装 `SectionHeaderView`）。
/// 房间分区支持点击展开 / 收起；提供 `onDetail` 时改为点击标题进入房间详情，
/// 展开 / 收起由右侧 chevron 按钮承担。
final class HomeSectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "HomeSectionHeaderView"
    /// 当前展示的头视图；复用时会替换，不能只移除初始那一个，否则旧标题会叠在下面。
    private var header: SectionHeaderView?
    private var onToggle: (() -> Void)?
    private var onDetail: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // 不吞掉 chevron / 详情按钮的触摸，按钮自身的 action 才能触发。
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        onToggle = nil
        onDetail = nil
        rebuild(title: title, trailing: nil)
    }

    func configure(title: String, collapsed: Bool, onToggle: @escaping () -> Void) {
        configure(title: title, collapsed: collapsed, onToggle: onToggle, onDetail: nil)
    }

    func configure(
        title: String,
        collapsed: Bool,
        onToggle: @escaping () -> Void,
        onDetail: (() -> Void)?
    ) {
        self.onToggle = onToggle
        self.onDetail = onDetail
        if onDetail != nil {
            let chevron = UIButton(type: .system)
            chevron.setImage(
                UIImage(
                    systemName: collapsed ? "chevron.down" : "chevron.up",
                    withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1)
                ),
                for: .normal
            )
            chevron.tintColor = AppTheme.Palette.secondaryText
            chevron.accessibilityIdentifier = "roomSectionChevron"
            chevron.accessibilityLabel = collapsed
                ? L10n.t("room.detail.expand")
                : L10n.t("room.detail.collapse")
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
            rebuild(title: title, trailing: chevron)
        } else {
            let chevron = UIImageView(image: UIImage(systemName: collapsed ? "chevron.down" : "chevron.up"))
            chevron.tintColor = AppTheme.Palette.secondaryText
            chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
            chevron.contentMode = .scaleAspectFit
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.accessibilityIdentifier = "roomSectionChevron"
            rebuild(title: title, trailing: chevron)
        }
        accessibilityLabel = title
        accessibilityHint = onDetail == nil
            ? (collapsed ? L10n.t("room.expand") : L10n.t("room.collapse"))
            : L10n.t("room.detail.openHint")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if let hit = hitTest(point, with: nil), hit is UIControl { return }
        if let onDetail {
            onDetail()
        } else {
            onToggle?()
        }
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
