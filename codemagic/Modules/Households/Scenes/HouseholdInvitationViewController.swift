import UIKit

/// 家庭邀请码：8 位明文 + 服务端 `expiresAt` 倒计时 + 复制 + 过期重生成。
/// 邀请码只在签发响应中出现一次，因此不在本地持久化。
final class HouseholdInvitationViewController: UIViewController {
    private let viewModel: HouseholdManagementViewModel
    private var invitation: HouseholdInvitation?
    private var timer: Timer?
    private var isGenerating = false

    private let codeLabel = UILabel()
    private let countdownLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let regenerateButton = UIButton(type: .system)
    private let hintLabel = UILabel()

    init(viewModel: HouseholdManagementViewModel) {
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
        title = L10n.t("household.invitation.title")
        view.backgroundColor = AppTheme.Palette.background
        configureViews()
        startTimer()
        generate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    private func configureViews() {
        codeLabel.applyFont(AppText.numericL.font(weight: .semibold))
        codeLabel.textColor = AppTheme.Palette.primaryText
        codeLabel.textAlignment = .center
        codeLabel.numberOfLines = 1
        codeLabel.accessibilityIdentifier = "household.invitation.code"

        countdownLabel.applyFont(.preferredFont(forTextStyle: .footnote))
        countdownLabel.textColor = AppTheme.Palette.secondaryText
        countdownLabel.textAlignment = .center
        countdownLabel.numberOfLines = 0

        var copyConfiguration = UIButton.Configuration.filled()
        copyConfiguration.title = L10n.t("household.invitation.copy")
        copyConfiguration.cornerStyle = .medium
        copyButton.configuration = copyConfiguration
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        var regenerateConfiguration = UIButton.Configuration.tinted()
        regenerateConfiguration.title = L10n.t("household.invitation.regenerate")
        regenerateConfiguration.cornerStyle = .medium
        regenerateButton.configuration = regenerateConfiguration
        regenerateButton.addTarget(self, action: #selector(regenerateTapped), for: .touchUpInside)

        hintLabel.applyFont(.preferredFont(forTextStyle: .footnote))
        hintLabel.textColor = AppTheme.Palette.secondaryText
        hintLabel.numberOfLines = 0
        hintLabel.text = L10n.t("household.invitation.note")

        let stack = UIStackView(arrangedSubviews: [
            codeLabel, countdownLabel, copyButton, regenerateButton, hintLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: codeLabel)
        stack.setCustomSpacing(28, after: countdownLabel)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            codeLabel.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.render()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        copyButton.isEnabled = false
        regenerateButton.isEnabled = false
        countdownLabel.text = L10n.t("household.invitation.generating")
        viewModel.createInvitation { [weak self] result in
            guard let self else { return }
            self.isGenerating = false
            switch result {
            case .success(let invitation):
                self.invitation = invitation
                self.render()
            case .failure(let error):
                self.invitation = nil
                self.countdownLabel.text = error.userMessage
            }
        }
    }

    private func render() {
        guard let invitation else {
            codeLabel.text = "--------"
            regenerateButton.isEnabled = !isGenerating
            return
        }
        let remaining = PairingCountdown.remainingSeconds(expiresAt: invitation.expiresAt, now: Date())
        codeLabel.text = PairingCodeFormatter.grouped(invitation.code)
        if remaining > 0 {
            countdownLabel.text = L10n.f(
                "household.invitation.remaining",
                PairingCountdown.text(seconds: remaining)
            )
            copyButton.isEnabled = true
            regenerateButton.isEnabled = true
        } else {
            countdownLabel.text = L10n.t("household.invitation.expired")
            copyButton.isEnabled = false
            // 过期后必须重新生成，避免展示已失效的明文码。
            regenerateButton.isEnabled = true
        }
    }

    @objc private func copyTapped() {
        guard let invitation, PairingCountdown.remainingSeconds(expiresAt: invitation.expiresAt, now: Date()) > 0 else {
            generate()
            return
        }
        UIPasteboard.general.string = invitation.code
        ToastView.show(L10n.t("household.invitation.copied"), kind: .success, in: self)
    }

    @objc private func regenerateTapped() {
        generate()
    }
}
