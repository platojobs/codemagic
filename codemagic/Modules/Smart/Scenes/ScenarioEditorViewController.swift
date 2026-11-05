import UIKit

/// 场景编辑器：名称 + 真实可执行动作集合。
/// 场景仅保存在本机，页面内明确标注，不提示同步。
final class ScenarioEditorViewController: UIViewController {
    private let existing: Scenario?
    private let deviceOptions: [(id: UUID, name: String)]
    private let onSave: (Scenario) -> Void

    private var actions: [ScenarioAction]
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let nameField = UITextField()
    private let actionsStack = UIStackView()

    init(
        scenario: Scenario?,
        deviceOptions: [(id: UUID, name: String)],
        onSave: @escaping (Scenario) -> Void
    ) {
        self.existing = scenario
        self.deviceOptions = deviceOptions
        self.onSave = onSave
        self.actions = scenario?.actions ?? []
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = existing == nil ? "新增场景" : "编辑场景"
        view.backgroundColor = Palette.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消", style: .plain, target: self, action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存", style: .done, target: self, action: #selector(save)
        )
        configureLayout()
        renderActions()
    }

    // MARK: - Layout

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        contentStack.axis = .vertical
        contentStack.spacing = Layout.space16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Layout.space16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Layout.pageMargin),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Layout.pageMargin),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Layout.space24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -Layout.pageMargin * 2),
        ])

        let nameLabel = UILabel()
        nameLabel.text = "场景名称"
        nameLabel.font = AppText.callout.font(weight: .medium)
        nameLabel.textColor = Palette.textSecondary

        nameField.text = existing?.name
        nameField.placeholder = "例如：回家后连接设备并同步"
        nameField.font = AppText.body.font()
        nameField.textColor = Palette.textPrimary
        nameField.backgroundColor = Palette.surface
        nameField.layer.cornerRadius = Radius.input
        nameField.layer.cornerCurve = .continuous
        nameField.layer.borderWidth = Stroke.one
        nameField.layer.borderColor = Palette.divider.resolvedColor(with: traitCollection).cgColor
        nameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: Layout.space12, height: Layout.inputH))
        nameField.leftViewMode = .always
        nameField.heightAnchor.constraint(equalToConstant: Layout.inputH).isActive = true

        let actionsTitle = UILabel()
        actionsTitle.text = "动作（按顺序执行）"
        actionsTitle.font = AppText.callout.font(weight: .medium)
        actionsTitle.textColor = Palette.textSecondary

        actionsStack.axis = .vertical
        actionsStack.spacing = Layout.space8

        let addButton = AppButton(style: .secondary, title: "添加动作", symbolName: "plus")
        addButton.addTarget(self, action: #selector(addAction), for: .touchUpInside)

        let note = UILabel()
        note.text = "场景仅保存在本机，不参与账号同步。动作失败不会阻断后续动作，执行结束会汇总结果。"
        note.font = AppText.caption.font()
        note.textColor = Palette.textTertiary
        note.numberOfLines = 0

        contentStack.addArrangedSubview(nameLabel)
        contentStack.addArrangedSubview(nameField)
        contentStack.addArrangedSubview(actionsTitle)
        contentStack.addArrangedSubview(actionsStack)
        contentStack.addArrangedSubview(addButton)
        contentStack.addArrangedSubview(note)
    }

    private func renderActions() {
        actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !actions.isEmpty else {
            let placeholder = UILabel()
            placeholder.text = "还没有动作，点击下方按钮添加。"
            placeholder.font = AppText.callout.font()
            placeholder.textColor = Palette.textSecondary
            placeholder.numberOfLines = 0
            actionsStack.addArrangedSubview(placeholder)
            return
        }
        for (index, action) in actions.enumerated() {
            actionsStack.addArrangedSubview(makeActionRow(index: index, action: action))
        }
    }

    private func makeActionRow(index: Int, action: ScenarioAction) -> UIView {
        let container = UIView()
        container.styleAsCardSurface()
        container.backgroundColor = Palette.surface

        let icon = UIImageView(image: UIImage(systemName: action.symbolName))
        icon.tintColor = Palette.primaryText
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: Layout.icon20).isActive = true

        let label = UILabel()
        label.text = "\(index + 1). \(actionDetail(action))"
        label.font = AppText.callout.font()
        label.textColor = Palette.textPrimary
        label.numberOfLines = 2

        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: SymbolName.delete), for: .normal)
        remove.tintColor = Palette.danger
        remove.accessibilityLabel = "删除动作"
        remove.addAction(UIAction { [weak self] _ in
            self?.actions.remove(at: index)
            self?.renderActions()
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, label, remove])
        stack.axis = .horizontal
        stack.spacing = Layout.space8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.space12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.space12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.row1),
        ])
        return container
    }

    // MARK: - Actions

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func save() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            presentAlert(title: "请填写场景名称", message: "名称为空时无法保存。")
            return
        }
        guard !actions.isEmpty else {
            presentAlert(title: "请至少添加一个动作", message: "场景必须包含可执行动作。")
            return
        }
        let now = Date()
        let scenario = Scenario(
            id: existing?.id ?? UUID(),
            name: name,
            actions: actions,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        onSave(scenario)
        dismiss(animated: true)
    }

    @objc private func addAction() {
        let sheet = UIAlertController(title: "添加动作", message: "只列出真实可执行的动作。", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "连接指定设备", style: .default) { [weak self] _ in
            self?.pickDevice(forConnect: true)
        })
        sheet.addAction(UIAlertAction(title: "断开指定设备", style: .default) { [weak self] _ in
            self?.pickDevice(forConnect: false)
        })
        sheet.addAction(UIAlertAction(title: "开始后台采集", style: .default) { [weak self] _ in
            self?.actions.append(.startBackgroundCollection)
            self?.renderActions()
        })
        sheet.addAction(UIAlertAction(title: "停止后台采集", style: .default) { [weak self] _ in
            self?.actions.append(.stopBackgroundCollection)
            self?.renderActions()
        })
        sheet.addAction(UIAlertAction(title: "静音告警", style: .default) { [weak self] _ in
            self?.pickMuteMinutes()
        })
        sheet.addAction(UIAlertAction(title: "立即同步", style: .default) { [weak self] _ in
            self?.actions.append(.syncNow)
            self?.renderActions()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func pickDevice(forConnect: Bool) {
        guard !deviceOptions.isEmpty else {
            presentAlert(title: "还没有可用设备", message: "请先在首页扫描并保存设备。")
            return
        }
        let sheet = UIAlertController(title: "选择设备", message: nil, preferredStyle: .actionSheet)
        for option in deviceOptions {
            sheet.addAction(UIAlertAction(title: option.name, style: .default) { [weak self] _ in
                guard let self else { return }
                self.actions.append(
                    forConnect ? .connectDevice(option.id) : .disconnectDevice(option.id)
                )
                self.renderActions()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func pickMuteMinutes() {
        let sheet = UIAlertController(title: "静音时长", message: "静音期间规则仍会记录，但不再发送通知。", preferredStyle: .actionSheet)
        for minutes in ScenarioAction.muteOptions {
            sheet.addAction(UIAlertAction(title: "\(minutes) 分钟", style: .default) { [weak self] _ in
                self?.actions.append(.muteAlerts(minutes: minutes))
                self?.renderActions()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func actionDetail(_ action: ScenarioAction) -> String {
        action.detail { id in
            deviceOptions.first { $0.id == id }?.name ?? "已删除的设备"
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}
