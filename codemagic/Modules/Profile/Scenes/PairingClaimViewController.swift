import UIKit

/// 「从旧设备接管」：输入 8 位码 → 换 token → 保留本机设备与读数并重新标记待上传。
final class PairingClaimViewController: UIViewController {
    private let viewModel: PairingClaimViewModel
    private let onCompleted: () -> Void
    private var timer: Timer?
    private var hasPresentedResult = false

    private let textField = UITextField()
    private let statusLabel = UILabel()
    private let claimButton = UIButton(type: .system)

    init(viewModel: PairingClaimViewModel, onCompleted: @escaping () -> Void) {
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
        title = "从旧设备接管"
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

    // MARK: - Layout

    private func configureViews() {
        let description = AppTheme.makeLabel(style: .subheadline, color: AppTheme.Palette.secondaryText)
        description.numberOfLines = 0
        description.text = "输入旧设备「迁移到新设备」页展示的 8 位接管码。接管后本机设备与读数会重新同步到旧设备账号。"

        textField.placeholder = "8 位接管码，如 K7M2QX9P"
        textField.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
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
        textField.accessibilityIdentifier = "pairing.claimInput"

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = AppTheme.Palette.secondaryText
        statusLabel.numberOfLines = 0

        var configuration = UIButton.Configuration.filled()
        configuration.title = "接管账号"
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

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.viewModel.clearCooldownIfNeeded()
            self?.render()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Render

    private func render() {
        if textField.text != viewModel.input {
            textField.text = viewModel.input
        }
        claimButton.isEnabled = viewModel.canClaim
        claimButton.configuration?.showsActivityIndicator = viewModel.isClaiming
        claimButton.configuration?.title = viewModel.isClaiming ? "正在接管…" : "接管账号"
        statusLabel.text = viewModel.statusText
        statusLabel.textColor = viewModel.errorMessage == nil
            ? AppTheme.Palette.secondaryText
            : AppTheme.Palette.promotion

        if let result = viewModel.result, !hasPresentedResult {
            hasPresentedResult = true
            presentSuccess(result)
        }
    }

    private func presentSuccess(_ result: PairingClaimResult) {
        let alert = UIAlertController(
            title: "接管成功",
            message: "已切换到账号 \(result.userID)。本机 \(result.deviceCount) 台设备、\(result.readingCount) 条读数已标记待同步，正在同步…",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            guard let self else { return }
            self.onCompleted()
            self.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    // MARK: - Actions

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

// MARK: - UITextFieldDelegate

extension PairingClaimViewController: UITextFieldDelegate {
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        // 直接交给 editingChanged 统一规范化，避免在这里重复实现过滤规则。
        true
    }

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
