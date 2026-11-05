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
