import UIKit

/// 场景行：名称、动作摘要、「仅本机」标记与一键执行。
final class ScenarioCell: UITableViewCell {
    static let reuseIdentifier = "ScenarioCell"

    private let container = UIView()
    private let nameLabel = UILabel()
    private let summaryLabel = UILabel()
    private let localChip = StatusChipView(text: L10n.t("smart.localOnly"), kind: .neutral)
    private let runButton = AppButton(style: .secondary, title: L10n.t("smart.run"), symbolName: "play.fill")
    private var onRun: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Palette.overlayPressed
        selected.layer.cornerRadius = Radius.card
        selectedBackgroundView = selected

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
        ])

        nameLabel.applyFont(AppText.body.font(weight: .semibold))
        nameLabel.textColor = Palette.textPrimary
        nameLabel.numberOfLines = 1

        summaryLabel.applyFont(AppText.caption.font())
        summaryLabel.textColor = Palette.textSecondary
        summaryLabel.numberOfLines = 2

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, localChip])
        titleRow.axis = .horizontal
        titleRow.spacing = Layout.space8
        titleRow.alignment = .center

        let text = UIStackView(arrangedSubviews: [titleRow, summaryLabel])
        text.axis = .vertical
        text.spacing = Layout.space8

        runButton.addTarget(self, action: #selector(handleRun), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [text, runButton])
        stack.axis = .horizontal
        stack.spacing = Layout.space12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.space16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.space16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            runButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.touchMin),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(scenario: Scenario, onRun: @escaping () -> Void) {
        nameLabel.text = scenario.name
        summaryLabel.text = scenario.summary
        self.onRun = onRun
        accessibilityLabel = L10n.f("scenario.cell.a11y.local", String(describing: scenario.name), String(describing: scenario.actions.count))
    }

    @objc private func handleRun() {
        onRun?()
    }
}

/// 服务端场景行：触发条件、状态、设备缺失标注与启停开关。
final class SceneAutomationCell: UITableViewCell {
    static let reuseIdentifier = "SceneAutomationCell"

    private let container = UIView()
    private let nameLabel = UILabel()
    private let triggerLabel = UILabel()
    private let detailLabel = UILabel()
    private let syncChip = StatusChipView(text: "", kind: .neutral)
    private let missingChip = StatusChipView(text: L10n.t("scene.deviceMissing"), kind: .danger)
    private let rejectionChip = StatusChipView(text: L10n.t("scene.sync.rejected"), kind: .danger)
    private let toggle = UISwitch()
    private let titleRow = UIStackView()
    private let chipsRow = UIStackView()
    private var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Palette.overlayPressed
        selected.layer.cornerRadius = Radius.card
        selectedBackgroundView = selected

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
        ])

        nameLabel.applyFont(AppText.body.font(weight: .semibold))
        nameLabel.textColor = Palette.textPrimary
        nameLabel.numberOfLines = 1
        // 行高受限时优先保留场景名称，避免 AX 档名称被裁成 0 高。
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        triggerLabel.applyFont(AppText.caption.font())
        triggerLabel.textColor = Palette.textSecondary
        triggerLabel.numberOfLines = 2

        detailLabel.applyFont(AppText.footnote.font())
        detailLabel.textColor = Palette.textTertiary
        detailLabel.numberOfLines = 2

        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
        toggle.accessibilityLabel = L10n.t("scene.cell.toggleA11y")
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.widthAnchor.constraint(equalToConstant: Layout.buttonH).isActive = true

        let chips = chipsRow
        chips.addArrangedSubview(missingChip)
        chips.addArrangedSubview(rejectionChip)
        chips.addArrangedSubview(syncChip)
        chips.axis = .horizontal
        chips.spacing = Layout.space4
        chips.alignment = .center

        let titleRow = self.titleRow
        titleRow.addArrangedSubview(nameLabel)
        titleRow.addArrangedSubview(chips)
        titleRow.axis = .horizontal
        titleRow.spacing = Layout.space8
        titleRow.alignment = .center

        let text = UIStackView(arrangedSubviews: [titleRow, triggerLabel, detailLabel])
        text.axis = .vertical
        text.spacing = Layout.space4

        let stack = UIStackView(arrangedSubviews: [text, toggle])
        stack.axis = .horizontal
        stack.spacing = Layout.space12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.space16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.space16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.buttonH),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        scene: Scene,
        deviceMissing: Bool,
        deviceName: String?,
        nextFire: String?,
        onToggle: @escaping (Bool) -> Void
    ) {
        // AX 档名称与徽章横排会互相挤压，改用上下排；在 configure 里切换，
        // 让 UITableView 的自适应行高按新布局重新计算。
        let isAccessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleRow.axis = isAccessibility ? .vertical : .horizontal
        titleRow.alignment = isAccessibility ? .leading : .center
        chipsRow.axis = isAccessibility ? .vertical : .horizontal
        chipsRow.alignment = isAccessibility ? .leading : .center
        nameLabel.numberOfLines = isAccessibility ? 2 : 1

        nameLabel.text = scene.name
        triggerLabel.text = scene.trigger.title
        let rejected = scene.syncState == .rejected
        var details: [String] = [scene.actionSummary]
        if let deviceName {
            details.append(L10n.f("scene.cell.device", deviceName))
        }
        if let nextFire {
            details.append(L10n.f("scene.cell.nextFire", nextFire))
        }
        if rejected {
            details.append(L10n.f("scene.cell.rejectedReason", scene.rejectionText))
        }
        detailLabel.text = details.joined(separator: L10n.t("common.semicolonSeparator"))
        missingChip.isHidden = !deviceMissing
        rejectionChip.isHidden = !rejected
        let pending = scene.syncState == .pending || scene.syncState == .pendingDelete
        syncChip.isHidden = rejected || (!pending && scene.remoteID != nil)
        syncChip.set(text: pending ? L10n.t("scene.sync.pending") : L10n.t("scene.sync.synced"), kind: pending ? .warning : .success)
        toggle.isOn = scene.enabled
        toggle.isEnabled = !deviceMissing
        self.onToggle = onToggle
        let state = rejected
            ? L10n.f("scene.cell.rejectedA11y", scene.rejectionText)
            : (deviceMissing ? L10n.t("scene.deviceMissing") : L10n.f("scene.cell.enabledState", scene.enabled ? L10n.t("common.on") : L10n.t("common.off")))
        accessibilityLabel = L10n.f("scene.cell.a11y", scene.name, scene.trigger.title, state)
    }

    @objc private func toggleChanged() {
        onToggle?(toggle.isOn)
    }
}

/// 最近触发行：规则名称、设备与相对时间。
final class TriggerCell: UITableViewCell {
    static let reuseIdentifier = "TriggerCell"

    private let messageLabel = UILabel()
    private let timeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        messageLabel.applyFont(AppText.callout.font())
        messageLabel.textColor = Palette.textPrimary
        messageLabel.numberOfLines = 2

        timeLabel.applyFont(AppText.footnote.font())
        timeLabel.textColor = Palette.textTertiary

        let stack = UIStackView(arrangedSubviews: [messageLabel, timeLabel])
        stack.axis = .vertical
        stack.spacing = Layout.space4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space8),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: String, time: String) {
        messageLabel.text = message
        timeLabel.text = time
    }
}

/// 三态占位行：空状态 / 错误重试，高度与真实内容一致。
final class StateCell: UITableViewCell {
    static let reuseIdentifier = "StateCell"
    private var stateView: UIView?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showEmpty(symbol: String, title: String, message: String, actionTitle: String?, action: (() -> Void)?) {
        replace(with: EmptyStateView())
        (stateView as? EmptyStateView)?.configure(
            symbolName: symbol,
            title: title,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
    }

    func showError(message: String, retry: @escaping () -> Void) {
        replace(with: ErrorStateView(height: 160))
        (stateView as? ErrorStateView)?.configure(
            title: L10n.t("smart.loadSmartFailed"),
            message: message,
            action: retry
        )
    }

    private func replace(with view: UIView) {
        stateView?.removeFromSuperview()
        stateView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space8),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space8),
        ])
    }
}

/// 表格分区头。
final class TableSectionHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "TableSectionHeaderView"
    private let header = SectionHeaderView(title: "")

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundColor = Palette.canvas
        contentView.backgroundColor = Palette.canvas
        contentView.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space8),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            header.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        header.subviews.forEach { $0.removeFromSuperview() }
        let label = UILabel()
        label.text = title
        label.applyFont(AppText.callout.font(weight: .semibold))
        label.textColor = Palette.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        ])
        accessibilityLabel = title
    }
}
