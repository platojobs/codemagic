import UIKit

/// 新增本地规则的表单：名称、触发条件、阈值与生效设备，纯代码构建。
final class RuleEditorViewController: UIViewController {
    // MARK: - Input

    private let deviceOptions: [(id: UUID?, name: String)]
    private let onSave: (DeviceRule) -> Void

    private var selectedDeviceIndex = 0
    private var selectedTrigger: RuleTrigger = .disconnect

    // MARK: - Subviews

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let nameField = UITextField()
    private let triggerControl = UISegmentedControl(items: ["设备断开", "信号低于阈值"])
    private let thresholdLabel = AppTheme.makeLabel(style: .subheadline, color: AppTheme.Palette.primaryText)
    private let thresholdSlider = UISlider()
    private let thresholdContainer = UIStackView()
    private let targetButton = UIButton(type: .system)
    private let noteLabel = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.secondaryText)

    // MARK: - Init

    init(deviceOptions: [(id: UUID?, name: String)], onSave: @escaping (DeviceRule) -> Void) {
        self.deviceOptions = deviceOptions
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "新增规则"
        view.backgroundColor = AppTheme.Palette.background
        configureNavigationItems()
        configureLayout()
        configureThresholdSection()
        updateThresholdVisibility()
    }

    // MARK: - Layout

    private func configureNavigationItems() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(handleCancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存",
            style: .done,
            target: self,
            action: #selector(handleSave)
        )
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = AppTheme.Spacing.large
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: AppTheme.Metrics.contentMargins
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -AppTheme.Metrics.contentMargins
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -24
            ),
            contentStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -2 * AppTheme.Metrics.contentMargins
            ),
        ])

        contentStack.addArrangedSubview(makeFieldGroup(
            title: "规则名称",
            content: makeTextInput()
        ))
        contentStack.addArrangedSubview(makeFieldGroup(
            title: "触发条件",
            content: makeTriggerControl()
        ))
        contentStack.addArrangedSubview(thresholdContainer)
        contentStack.addArrangedSubview(makeFieldGroup(
            title: "生效设备",
            content: makeTargetButton()
        ))

        noteLabel.text = "规则只在本地运行：扫描时按条件记录日志并在首页提示，不会向设备下发任何指令。"
        contentStack.addArrangedSubview(noteLabel)
    }

    private func makeTextInput() -> UIView {
        nameField.placeholder = "例如：设备断开提醒"
        nameField.borderStyle = .roundedRect
        nameField.clearButtonMode = .whileEditing
        nameField.autocapitalizationType = .none
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return nameField
    }

    private func makeTriggerControl() -> UIView {
        triggerControl.selectedSegmentIndex = 0
        triggerControl.addTarget(self, action: #selector(handleTriggerChange), for: .valueChanged)
        return triggerControl
    }

    private func makeTargetButton() -> UIView {
        var configuration = UIButton.Configuration.plain()
        configuration.title = deviceOptions.first?.name ?? "全部已保存设备"
        configuration.image = UIImage(systemName: SymbolName.disclosure)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = AppTheme.Spacing.small
        configuration.contentInsets = .zero
        targetButton.configuration = configuration
        targetButton.contentHorizontalAlignment = .leading
        targetButton.addTarget(self, action: #selector(handleTargetSelection), for: .touchUpInside)
        return targetButton
    }

    private func makeFieldGroup(title: String, content: UIView) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = AppTheme.Spacing.small
        let label = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.secondaryText)
        label.text = title
        container.addArrangedSubview(label)
        container.addArrangedSubview(content)
        return container
    }

    private func configureThresholdSection() {
        thresholdContainer.axis = .vertical
        thresholdContainer.spacing = AppTheme.Spacing.small

        let titleLabel = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.secondaryText)
        titleLabel.text = "RSSI 阈值（dBm）"

        thresholdSlider.minimumValue = -100
        thresholdSlider.maximumValue = -30
        thresholdSlider.value = -80
        thresholdSlider.addTarget(self, action: #selector(handleThresholdChange), for: .valueChanged)
        updateThresholdLabel()

        thresholdContainer.addArrangedSubview(titleLabel)
        thresholdContainer.addArrangedSubview(thresholdLabel)
        thresholdContainer.addArrangedSubview(thresholdSlider)
    }

    // MARK: - State

    private func updateThresholdLabel() {
        let value = Int(thresholdSlider.value.rounded())
        thresholdLabel.text = "\(value) dBm"
    }

    private func updateThresholdVisibility() {
        thresholdContainer.isHidden = selectedTrigger == .disconnect
    }

    // MARK: - Actions

    @objc private func handleTriggerChange() {
        selectedTrigger = triggerControl.selectedSegmentIndex == 1 ? .rssiBelowThreshold : .disconnect
        updateThresholdVisibility()
    }

    @objc private func handleThresholdChange() {
        updateThresholdLabel()
    }

    @objc private func handleTargetSelection() {
        let sheet = UIAlertController(title: "选择生效设备", message: nil, preferredStyle: .actionSheet)
        for (index, option) in deviceOptions.enumerated() {
            sheet.addAction(
                UIAlertAction(title: option.name, style: .default) { [weak self] _ in
                    self?.selectedDeviceIndex = index
                    self?.updateTargetButtonTitle()
                }
            )
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = targetButton
            popover.sourceRect = targetButton.bounds
        }
        present(sheet, animated: true)
    }

    private func updateTargetButtonTitle() {
        var configuration = targetButton.configuration
        configuration?.title = deviceOptions[selectedDeviceIndex].name
        targetButton.configuration = configuration
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    @objc private func handleSave() {
        let trimmedName = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName: String
        if trimmedName.isEmpty {
            resolvedName = selectedTrigger == .disconnect ? "设备断开提醒" : "信号强度提醒"
        } else {
            resolvedName = trimmedName
        }

        let rule = DeviceRule(
            name: resolvedName,
            trigger: selectedTrigger,
            threshold: Int(thresholdSlider.value.rounded()),
            deviceID: deviceOptions[selectedDeviceIndex].id,
            isEnabled: true
        )
        onSave(rule)
        dismiss(animated: true)
    }
}
