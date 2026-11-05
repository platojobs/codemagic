import UIKit

/// 场景执行进度浮层：执行中逐条展示动作，完成后显示成功 / 失败与原因。
final class ScenarioProgressOverlay: UIView {
    private let scrim = UIView()
    private let card = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let rowsStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var rowViews: [ScenarioAction: (icon: UIImageView, label: UILabel)] = [:]
    private var didFinish = false

    var onFinish: ((ScenarioRunResult) -> Void)?

    init(scenario: Scenario) {
        super.init(frame: .zero)
        backgroundColor = .clear
        scrim.backgroundColor = Palette.scrim
        addSubview(scrim)
        scrim.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        card.backgroundColor = Palette.surfaceRaised
        card.layer.cornerRadius = Radius.sheet
        card.layer.cornerCurve = .continuous
        card.applyElevation(.overlay)
        addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.pageMargin),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.pageMargin),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        titleLabel.text = L10n.f("scenario.progress.running", String(describing: scenario.name))
        titleLabel.applyFont(AppText.headline.font(weight: .semibold))
        titleLabel.textColor = Palette.textPrimary
        titleLabel.numberOfLines = 2

        subtitleLabel.text = L10n.t("scenario.progress.note")
        subtitleLabel.applyFont(AppText.caption.font())
        subtitleLabel.textColor = Palette.textSecondary
        subtitleLabel.numberOfLines = 0

        spinner.startAnimating()

        rowsStack.axis = .vertical
        rowsStack.spacing = Layout.space12

        for action in scenario.actions {
            let icon = UIImageView()
            icon.image = UIImage(
                systemName: "circle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon16, weight: .regular)
            )
            icon.tintColor = Palette.textTertiary
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: Layout.icon20).isActive = true

            let label = UILabel()
            label.text = action.title
            label.applyFont(AppText.callout.font())
            label.textColor = Palette.textSecondary
            label.numberOfLines = 2

            let row = UIStackView(arrangedSubviews: [icon, label])
            row.axis = .horizontal
            row.spacing = Layout.space8
            row.alignment = .center
            rowsStack.addArrangedSubview(row)
            rowViews[action] = (icon, label)
        }

        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        header.axis = .vertical
        header.spacing = Layout.space4

        let top = UIStackView(arrangedSubviews: [header, spinner])
        top.axis = .horizontal
        top.spacing = Layout.space12
        top.alignment = .center

        let content = UIStackView(arrangedSubviews: [top, rowsStack])
        content.axis = .vertical
        content.spacing = Layout.space16
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: Layout.space20),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Layout.space20),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Layout.space20),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Layout.space20),
        ])

        isAccessibilityElement = false
        accessibilityViewIsModal = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(in host: UIView) {
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        alpha = 0
        host.addSubview(self)
        UIView.animate(withDuration: Motion.d200, delay: 0, options: Motion.standardCurve) {
            self.alpha = 1
        }
    }

    func complete(_ result: ScenarioRunResult) {
        guard !didFinish else { return }
        didFinish = true
        spinner.stopAnimating()
        titleLabel.text = result.isFullySuccessful
            ? L10n.f("scenario.progress.completed", String(describing: result.scenarioName))
            : L10n.f("scenario.progress.partial", String(describing: result.scenarioName))

        for actionResult in result.actionResults {
            guard let row = rowViews[actionResult.action] else { continue }
            row.icon.image = UIImage(
                systemName: actionResult.succeeded ? SymbolName.checkmark : SymbolName.warning,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon16, weight: .semibold)
            )
            row.icon.tintColor = actionResult.succeeded ? Palette.success : Palette.danger
            row.label.text = L10n.f("scenario.result.line", actionResult.action.title, actionResult.message)
            row.label.textColor = actionResult.succeeded ? Palette.textSecondary : Palette.danger
        }

        UIView.animate(withDuration: Motion.d200, delay: 0.8, options: Motion.standardCurve, animations: {
            self.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
            self.onFinish?(result)
        })
    }
}
