import UIKit
import UserNotifications

/// 首启引导：三步说明（蓝牙 / 通知 / 后台采集），可跳过，进度持久化。
/// 蓝牙与通知都是「先说明后申请」：只有点「继续」才会触发系统授权框。
final class FirstRunOnboardingViewController: UIViewController {
    // MARK: - Steps

    private struct Step {
        let symbol: String
        let title: String
        let message: String
        let footnote: String
    }

    private let steps: [Step] = [
        Step(
            symbol: "dot.radiowaves.left.and.right",
            title: AppCopy.Onboarding.bluetoothTitle,
            message: AppCopy.Onboarding.bluetoothMessage,
            footnote: AppCopy.Onboarding.bluetoothFootnote
        ),
        Step(
            symbol: "bell.badge",
            title: AppCopy.Onboarding.notificationTitle,
            message: AppCopy.Onboarding.notificationMessage,
            footnote: AppCopy.Onboarding.notificationFootnote
        ),
        Step(
            symbol: "arrow.triangle.2.circlepath",
            title: AppCopy.Onboarding.backgroundTitle,
            message: AppCopy.Onboarding.backgroundMessage,
            footnote: AppCopy.Onboarding.backgroundFootnote
        ),
    ]

    // MARK: - Dependencies

    private let environment: AppEnvironment
    private var currentStep = 0
    private var isRequestingAuthorization = false
    var onFinish: (() -> Void)?

    // MARK: - Subviews

    private let skipButton = UIButton(type: .system)
    private let progressStack = UIStackView()
    private var progressBars: [UIView] = []
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let footnoteLabel = UILabel()
    private let permissionCard = UIView()
    private let permissionTitleLabel = UILabel()
    private let permissionMessageLabel = UILabel()
    private let settingsButton = AppButton(style: .secondary, title: AppCopy.Permission.openSettings)
    private let primaryButton = AppButton(style: .primary, title: AppCopy.Onboarding.next)

    // MARK: - Init

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.canvas
        configureSubviews()
        configureHierarchy()
        currentStep = environment.settingsStore.onboardingStep
        render(step: currentStep)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshPermissionState()
    }

    // MARK: - Configuration

    private func configureSubviews() {
        skipButton.setTitle(AppCopy.Onboarding.skip, for: .normal)
        skipButton.setTitleColor(Palette.textSecondary, for: .normal)
        skipButton.titleLabel?.font = AppText.callout.font()
        skipButton.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        skipButton.accessibilityLabel = "跳过首次使用引导"

        progressStack.axis = .horizontal
        progressStack.spacing = Layout.space4
        progressStack.distribution = .fillEqually
        for _ in steps {
            let bar = UIView()
            bar.layer.cornerRadius = 1
            bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
            progressStack.addArrangedSubview(bar)
            progressBars.append(bar)
        }

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = Palette.primary
        iconView.isAccessibilityElement = false
        iconView.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.numberOfLines = 0
        messageLabel.numberOfLines = 0
        footnoteLabel.numberOfLines = 0

        permissionCard.styleAsCardSurface()
        permissionCard.isHidden = true
        permissionTitleLabel.apply(.callout, color: Palette.warning)
        permissionMessageLabel.apply(.caption, color: Palette.textSecondary)
        permissionMessageLabel.numberOfLines = 0
        settingsButton.addAction(UIAction { [weak self] _ in self?.openSystemSettings() }, for: .touchUpInside)

        primaryButton.addAction(UIAction { [weak self] _ in self?.handlePrimaryAction() }, for: .touchUpInside)
    }

    private func configureHierarchy() {
        contentStack.axis = .vertical
        contentStack.spacing = Layout.space12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(progressStack)
        contentStack.setCustomSpacing(Layout.space32, after: progressStack)
        contentStack.addArrangedSubview(iconView)
        contentStack.setCustomSpacing(Layout.space20, after: iconView)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(messageLabel)
        contentStack.setCustomSpacing(Layout.space8, after: messageLabel)
        contentStack.addArrangedSubview(footnoteLabel)
        contentStack.setCustomSpacing(Layout.space24, after: footnoteLabel)
        contentStack.addArrangedSubview(permissionCard)
        contentStack.addArrangedSubview(primaryButton)

        let permissionStack = UIStackView(arrangedSubviews: [
            permissionTitleLabel,
            permissionMessageLabel,
            settingsButton,
        ])
        permissionStack.axis = .vertical
        permissionStack.spacing = Layout.space8
        permissionStack.translatesAutoresizingMaskIntoConstraints = false
        permissionCard.addSubview(permissionStack)
        NSLayoutConstraint.activate([
            permissionStack.topAnchor.constraint(equalTo: permissionCard.topAnchor, constant: Layout.space16),
            permissionStack.leadingAnchor.constraint(equalTo: permissionCard.leadingAnchor, constant: Layout.space16),
            permissionStack.trailingAnchor.constraint(equalTo: permissionCard.trailingAnchor, constant: -Layout.space16),
            permissionStack.bottomAnchor.constraint(equalTo: permissionCard.bottomAnchor, constant: -Layout.space16),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(contentStack)
        view.addSubview(skipButton)
        view.addSubview(scrollView)
        skipButton.translatesAutoresizingMaskIntoConstraints = false

        iconView.heightAnchor.constraint(equalToConstant: Layout.icon64).isActive = true
        iconView.widthAnchor.constraint(equalToConstant: Layout.icon64).isActive = true

        NSLayoutConstraint.activate([
            skipButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Layout.space8),
            skipButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.pageMargin),
            skipButton.heightAnchor.constraint(equalToConstant: Layout.iconButtonBox),

            scrollView.topAnchor.constraint(equalTo: skipButton.bottomAnchor, constant: Layout.space8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Layout.space16),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Layout.space24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Layout.space24),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: Layout.pageMargin),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -Layout.pageMargin),
        ])
    }

    // MARK: - Rendering

    private func render(step index: Int) {
        guard steps.indices.contains(index) else { return }
        currentStep = index
        environment.settingsStore.onboardingStep = index

        let step = steps[index]
        iconView.image = UIImage(
            systemName: step.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon48, weight: .regular)
        )
        titleLabel.apply(.title, color: Palette.textPrimary)
        titleLabel.text = step.title
        messageLabel.apply(.body, color: Palette.textSecondary)
        messageLabel.text = step.message
        footnoteLabel.apply(.footnote, color: Palette.textTertiary)
        footnoteLabel.text = step.footnote

        for (barIndex, bar) in progressBars.enumerated() {
            bar.backgroundColor = barIndex <= index ? Palette.primary : Palette.divider
        }

        setPrimaryTitle(index == steps.count - 1 ? AppCopy.Onboarding.finish : AppCopy.Onboarding.next)
        skipButton.isHidden = index == steps.count - 1
        refreshPermissionState()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    private func advance() {
        guard !isRequestingAuthorization else { return }
        if currentStep >= steps.count - 1 {
            finish()
        } else {
            render(step: currentStep + 1)
        }
    }

    private func finish() {
        environment.settingsStore.completeOnboarding()
        onFinish?()
        dismiss(animated: true)
    }

    // MARK: - Permission

    private func handlePrimaryAction() {
        switch currentStep {
        case 0:
            let authorization = environment.bluetooth.currentAuthorization()
            if authorization == .notDetermined || authorization == .unknown {
                requestBluetoothAuthorization()
            } else {
                advance()
            }
        case 1:
            environment.notificationService.authorizationStatus { [weak self] status in
                guard let self else { return }
                if status == .notDetermined {
                    self.requestNotificationAuthorization()
                } else {
                    self.advance()
                }
            }
        default:
            finish()
        }
    }

    private func requestBluetoothAuthorization() {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        primaryButton.isEnabled = false
        setPrimaryTitle("等待系统授权…")
        environment.bluetooth.activate()
        pollBluetoothAuthorization(attempt: 0)
    }

    private func pollBluetoothAuthorization(attempt: Int) {
        let authorization = environment.bluetooth.currentAuthorization()
        guard authorization == .notDetermined || authorization == .unknown else {
            isRequestingAuthorization = false
            primaryButton.isEnabled = true
            refreshPermissionState()
            if authorization == .allowed {
                advance()
            } else {
                setPrimaryTitle(AppCopy.Onboarding.next)
            }
            return
        }
        guard attempt < 40 else {
            // 系统授权框未返回时不阻塞流程，保留说明与设置入口。
            isRequestingAuthorization = false
            primaryButton.isEnabled = true
            setPrimaryTitle(AppCopy.Onboarding.next)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pollBluetoothAuthorization(attempt: attempt + 1)
        }
    }

    private func requestNotificationAuthorization() {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        primaryButton.isEnabled = false
        setPrimaryTitle("等待系统授权…")
        environment.notificationService.requestAuthorizationIfNeeded { [weak self] granted in
            guard let self else { return }
            self.isRequestingAuthorization = false
            self.primaryButton.isEnabled = true
            self.refreshPermissionState()
            if granted {
                self.advance()
            } else {
                self.setPrimaryTitle(AppCopy.Onboarding.next)
            }
        }
    }

    /// 根据当前步骤刷新权限说明与系统设置入口；拒绝/受限时展示「仅本机可用」，不出现死路。
    private func refreshPermissionState() {
        switch currentStep {
        case 0:
            let authorization = environment.bluetooth.currentAuthorization()
            let blocked = authorization == .denied || authorization == .restricted
            permissionTitleLabel.text = AppCopy.Permission.localOnlyTitle
            permissionMessageLabel.text = AppCopy.Permission.localOnlyMessage
            permissionCard.isHidden = !blocked
        case 1:
            environment.notificationService.authorizationStatus { [weak self] status in
                guard let self, self.currentStep == 1 else { return }
                let blocked = status == .denied
                self.permissionTitleLabel.text = "通知未开启"
                self.permissionMessageLabel.text = AppCopy.Permission.notificationOffMessage
                self.permissionCard.isHidden = !blocked
            }
        default:
            permissionCard.isHidden = true
        }
    }

    private func setPrimaryTitle(_ title: String) {
        var configuration = primaryButton.configuration
        configuration?.title = title
        primaryButton.configuration = configuration
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
