import UIKit

/// 「加入家庭」：输入一次性 8 位邀请码；404 文案为「邀请码无效或已过期」，429 显示重试秒数。
final class HouseholdClaimViewController: UIViewController {
    private let viewModel: HouseholdClaimViewModel
    private let onCompleted: () -> Void
    private var timer: Timer?
    private var hasPresentedResult = false

    private let textField = UITextField()
    private let statusLabel = UILabel()
    private let claimButton = UIButton(type: .system)

    init(viewModel: HouseholdClaimViewModel, onCompleted: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onCompleted = onCompleted
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
        title = L10n.t("household.join.title")
        view.backgroundColor = AppTheme.Palette.background
        configureViews()

        viewModel.onChange = { [weak self] in self?.render() }
        startTimer()
        render()
        textField.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    private func configureViews() {
        let description = AppTheme.makeLabel(style: .subheadline, color: AppTheme.Palette.secondaryText)
        description.numberOfLines = 0
        description.text = L10n.t("household.join.note")

        textField.placeholder = L10n.t("household.join.placeholder")
        textField.applyFont(AppText.numericM.font(weight: .medium))
        textField.textColor = AppTheme.Palette.primaryText
        textField.tintColor = AppTheme.Palette.accent
        textField.borderStyle = .roundedRect
        textField.backgroundColor = AppTheme.Palette.cardBackground
        textField.autocapitalizationType = .allCharacters
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.keyboardType = .asciiCapable
        textField.returnKeyType = .go
        textField.clearButtonMode = .whileEditing
        textField.delegate = self
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        textField.accessibilityIdentifier = "household.claimInput"

        statusLabel.applyFont(.preferredFont(forTextStyle: .footnote))
        statusLabel.textColor = AppTheme.Palette.secondaryText
        statusLabel.numberOfLines = 0

        var configuration = UIButton.Configuration.filled()
        configuration.title = L10n.t("household.join")
        configuration.cornerStyle = .medium
        claimButton.configuration = configuration
        claimButton.addTarget(self, action: #selector(claimTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [description, textField, claimButton, statusLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(28, after: description)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            textField.heightAnchor.constraint(equalToConstant: 48),
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

    private func render() {
        if textField.text != viewModel.input {
            textField.text = viewModel.input
        }
        claimButton.isEnabled = viewModel.canClaim
        claimButton.configuration?.showsActivityIndicator = viewModel.isClaiming
        claimButton.configuration?.title = viewModel.isClaiming
            ? L10n.t("household.join.progress")
            : L10n.t("household.join")
        statusLabel.text = viewModel.statusText
        statusLabel.textColor = viewModel.errorMessage == nil
            ? AppTheme.Palette.secondaryText
            : AppTheme.Palette.promotion

        if let household = viewModel.claimedHousehold, !hasPresentedResult {
            hasPresentedResult = true
            presentSuccess(household)
        }
    }

    private func presentSuccess(_ household: Household) {
        let alert = UIAlertController(
            title: L10n.t("household.join"),
            message: L10n.f("household.join.success", household.name),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.ok"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.onCompleted()
            self.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    @objc private func textChanged() {
        let normalized = viewModel.updateInput(textField.text ?? "")
        if textField.text != normalized {
            textField.text = normalized
        }
    }

    @objc private func claimTapped() {
        textField.resignFirstResponder()
        viewModel.claim()
    }
}

extension HouseholdClaimViewController: UITextFieldDelegate {
    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        viewModel.updateInput("")
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if viewModel.canClaim {
            claimTapped()
        }
        return true
    }
}
