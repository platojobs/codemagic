import UIKit

/// 「迁移到新设备」：展示一次性配对码、真实倒计时、复制与重新生成。
final class PairingCodeViewController: UIViewController {
    private let viewModel: PairingCodeViewModel
    private var timer: Timer?

    private let codeLabel = UILabel()
    private let countdownLabel = UILabel()
    private let statusLabel = UILabel()
    private let feedbackLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let regenerateButton = UIButton(type: .system)

    init(viewModel: PairingCodeViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("transfer.code.title")
        view.backgroundColor = AppTheme.Palette.background
        configureViews()

        viewModel.onChange = { [weak self] in self?.render() }
        viewModel.generate()
        startTimer()
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Layout

    private func configureViews() {
        let description = AppTheme.makeLabel(style: .subheadline, color: AppTheme.Palette.secondaryText)
        description.numberOfLines = 0
        description.text = L10n.t("transfer.code.message")

        codeLabel.applyFont(AppText.numericXL.font())
        codeLabel.textColor = AppTheme.Palette.primaryText
        codeLabel.textAlignment = .center
        codeLabel.adjustsFontSizeToFitWidth = true
        codeLabel.minimumScaleFactor = 0.5
        codeLabel.accessibilityIdentifier = "pairing.code"

        countdownLabel.applyFont(.preferredFont(forTextStyle: .headline))
        countdownLabel.textColor = AppTheme.Palette.accent
        countdownLabel.textAlignment = .center

        statusLabel.applyFont(.preferredFont(forTextStyle: .footnote))
        statusLabel.textColor = AppTheme.Palette.secondaryText
        statusLabel.numberOfLines = 0

        feedbackLabel.applyFont(.preferredFont(forTextStyle: .footnote))
        feedbackLabel.textColor = AppTheme.Palette.success
        feedbackLabel.numberOfLines = 0

        var copyConfiguration = UIButton.Configuration.filled()
        copyConfiguration.title = L10n.t("transfer.code.copy")
        copyConfiguration.cornerStyle = .medium
        copyButton.configuration = copyConfiguration
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        var regenerateConfiguration = UIButton.Configuration.tinted()
        regenerateConfiguration.title = L10n.t("transfer.code.regenerate")
        regenerateConfiguration.cornerStyle = .medium
        regenerateButton.configuration = regenerateConfiguration
        regenerateButton.addTarget(self, action: #selector(regenerateTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            description,
            codeLabel,
            countdownLabel,
            copyButton,
            regenerateButton,
            statusLabel,
            feedbackLabel
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(28, after: description)
        stack.setCustomSpacing(28, after: countdownLabel)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.render()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func render() {
        codeLabel.text = viewModel.codeDisplayText
        countdownLabel.text = viewModel.countdownText
        countdownLabel.textColor = viewModel.isExpired
            ? AppTheme.Palette.promotion
            : AppTheme.Palette.accent
        statusLabel.text = [viewModel.statusText, viewModel.expiryText]
            .compactMap { $0 }
            .joined(separator: "\n")
        copyButton.isEnabled = viewModel.canCopy
        regenerateButton.isEnabled = !viewModel.isGenerating
    }

    // MARK: - Actions

    @objc private func copyTapped() {
        guard let code = viewModel.rawCode else { return }
        UIPasteboard.general.string = code
        feedbackLabel.text = L10n.t("transfer.code.copied")
    }

    @objc private func regenerateTapped() {
        let alert = UIAlertController(
            title: L10n.t("transfer.code.regenerateTitle"),
            message: L10n.t("transfer.code.regenerateMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("transfer.code.regenerate"), style: .destructive) { [weak self] _ in
            self?.feedbackLabel.text = nil
            self?.viewModel.generate()
        })
        present(alert, animated: true)
    }
}
