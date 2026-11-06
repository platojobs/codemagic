import UIKit

/// 服务端场景编辑器：名称、触发条件（离线 / RSSI / 指标阈值 / 定时）、冷却与 1–4 个动作。
/// 纯代码布局，所有尺寸取 `DesignTokens`；文案中英双语由 `L10n` 提供。
final class SceneEditorViewController: UIViewController {
    private let editingScene: Scene?
    private let devices: [SavedDevice]
    private let onSave: (Scene) -> Void

    private var selectedTriggerKind = 0
    private var selectedDevice: SavedDevice?
    private var selectedMetric: ReadingMetric = .temperature
    private var selectedComparator: SceneComparator = .gte
    private var selectedWeekdays: Set<Int> = []

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let nameField = UITextField()
    private let enabledSwitch = UISwitch()
    private let triggerControl = UISegmentedControl(items: [
        L10n.t("scene.editor.offline"),
        L10n.t("scene.editor.rssi"),
        L10n.t("scene.editor.metric"),
        L10n.t("scene.editor.schedule"),
    ])
    private let deviceButton = UIButton(type: .system)
    private let offlineField = UITextField()
    private let rssiField = UITextField()
    private let deviceTypeField = UITextField()
    private let metricButton = UIButton(type: .system)
    private let comparatorControl = UISegmentedControl(items: SceneComparator.allCases.map(\.symbol))
    private let thresholdField = UITextField()
    private let consecutiveField = UITextField()
    private let timePicker = UIDatePicker()
    private let timezoneField = UITextField()
    private let weekdayStack = UIStackView()
    private let cooldownField = UITextField()

    private let notifySwitch = UISwitch()
    private let notifyTitleField = UITextField()
    private let notifyBodyField = UITextField()
    private let logSwitch = UISwitch()
    private let logMessageField = UITextField()
    private let logLevelControl = UISegmentedControl(items: [L10n.t("scene.editor.info"), L10n.t("scene.editor.warn")])
    private let markSwitch = UISwitch()
    private let markField = UITextField()

    private let deviceSection = UIStackView()
    private let offlineSection = UIStackView()
    private let rssiSection = UIStackView()
    private let metricSection = UIStackView()
    private let scheduleSection = UIStackView()

    init(scene: Scene?, devices: [SavedDevice], onSave: @escaping (Scene) -> Void) {
        self.editingScene = scene
        self.devices = devices
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = editingScene == nil ? L10n.t("scene.editor.titleNew") : L10n.t("scene.editor.titleEdit")
        view.backgroundColor = Palette.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.t("common.cancel"),
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.t("scene.editor.save"),
            style: .done,
            target: self,
            action: #selector(saveTapped)
        )
        buildLayout()
        populate()
        updateVisibility()
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = Layout.space16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Layout.space24),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Layout.pageMargin),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Layout.pageMargin),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Layout.space24),
        ])

        nameField.accessibilityLabel = L10n.t("scene.editor.name")
        nameField.placeholder = L10n.t("scene.editor.namePlaceholder")
        nameField.applyFormFieldStyle()
        stack.addArrangedSubview(labelled(L10n.t("scene.editor.name"), nameField))

        enabledSwitch.accessibilityLabel = L10n.t("scene.editor.enabled")
        stack.addArrangedSubview(labelledControl(L10n.t("scene.editor.enabled"), enabledSwitch))

        triggerControl.selectedSegmentIndex = 0
        triggerControl.addTarget(self, action: #selector(triggerChanged), for: .valueChanged)
        stack.addArrangedSubview(labelled(L10n.t("scene.editor.triggerType"), triggerControl))

        deviceButton.applyMenuStyle()
        deviceButton.addTarget(self, action: #selector(deviceTapped), for: .touchUpInside)
        deviceSection.addArrangedSubview(labelled(L10n.t("scene.editor.device"), deviceButton))
        stack.addArrangedSubview(deviceSection)

        offlineField.keyboardType = .numberPad
        offlineField.applyFormFieldStyle()
        offlineSection.addArrangedSubview(labelled(L10n.t("scene.editor.offlineSeconds"), offlineField))
        stack.addArrangedSubview(offlineSection)

        rssiField.keyboardType = .numbersAndPunctuation
        rssiField.applyFormFieldStyle()
        rssiSection.addArrangedSubview(labelled(L10n.t("scene.editor.rssiThreshold"), rssiField))
        stack.addArrangedSubview(rssiSection)

        deviceTypeField.applyFormFieldStyle()
        deviceTypeField.placeholder = "thermometer"
        metricButton.applyMenuStyle()
        metricButton.addTarget(self, action: #selector(metricTapped), for: .touchUpInside)
        comparatorControl.selectedSegmentIndex = 0
        thresholdField.keyboardType = .decimalPad
        thresholdField.applyFormFieldStyle()
        consecutiveField.keyboardType = .numberPad
        consecutiveField.applyFormFieldStyle()
        metricSection.addArrangedSubview(labelled(L10n.t("scene.editor.deviceType"), deviceTypeField))
        metricSection.addArrangedSubview(labelled(L10n.t("scene.editor.metricName"), metricButton))
        metricSection.addArrangedSubview(labelled(L10n.t("scene.editor.comparator"), comparatorControl))
        metricSection.addArrangedSubview(labelled(L10n.t("scene.editor.threshold"), thresholdField))
        metricSection.addArrangedSubview(labelled(L10n.t("scene.editor.consecutive"), consecutiveField))
        stack.addArrangedSubview(metricSection)

        timePicker.datePickerMode = .time
        timePicker.preferredDatePickerStyle = .compact
        timePicker.accessibilityLabel = L10n.t("scene.editor.time")
        timezoneField.applyFormFieldStyle()
        timezoneField.text = TimeZone.current.identifier
        timezoneField.accessibilityLabel = L10n.t("scene.editor.timezone")
        weekdayStack.axis = .horizontal
        weekdayStack.spacing = Layout.space4
        weekdayStack.distribution = .fillEqually
        for iso in 1...7 {
            let button = UIButton(type: .system)
            button.tag = iso
            button.setTitle(weekdayShort(iso), for: .normal)
            button.titleLabel?.applyFont(AppText.caption.font(weight: .medium))
            button.layer.cornerRadius = Radius.sm
            button.heightAnchor.constraint(equalToConstant: Layout.buttonH).isActive = true
            button.addTarget(self, action: #selector(weekdayTapped(_:)), for: .touchUpInside)
            button.accessibilityLabel = weekdayShort(iso)
            weekdayStack.addArrangedSubview(button)
        }
        scheduleSection.addArrangedSubview(labelled(L10n.t("scene.editor.time"), timePicker))
        scheduleSection.addArrangedSubview(labelled(L10n.t("scene.editor.timezone"), timezoneField))
        scheduleSection.addArrangedSubview(labelled(L10n.t("scene.editor.weekdays"), weekdayStack))
        scheduleSection.addArrangedSubview(caption(L10n.t("scene.editor.allDays")))
        stack.addArrangedSubview(scheduleSection)

        cooldownField.keyboardType = .numberPad
        cooldownField.applyFormFieldStyle()
        stack.addArrangedSubview(labelled(L10n.t("scene.editor.cooldown"), cooldownField))

        stack.addArrangedSubview(sectionTitle(L10n.t("scene.editor.actions")))
        notifySwitch.accessibilityLabel = L10n.t("scene.editor.notify")
        logSwitch.accessibilityLabel = L10n.t("scene.editor.log")
        markSwitch.accessibilityLabel = L10n.t("scene.editor.mark")
        notifyTitleField.placeholder = L10n.t("scene.editor.notifyTitle")
        notifyTitleField.applyFormFieldStyle()
        notifyBodyField.placeholder = L10n.t("scene.editor.notifyBody")
        notifyBodyField.applyFormFieldStyle()
        logMessageField.placeholder = L10n.t("scene.editor.logMessage")
        logMessageField.applyFormFieldStyle()
        logLevelControl.selectedSegmentIndex = 0
        markField.placeholder = L10n.t("scene.editor.markName")
        markField.applyFormFieldStyle()

        stack.addArrangedSubview(labelledControl(L10n.t("scene.editor.notify"), notifySwitch))
        stack.addArrangedSubview(labelled(L10n.t("scene.editor.notifyTitle"), notifyTitleField))
        stack.addArrangedSubview(labelled(L10n.t("scene.editor.notifyBody"), notifyBodyField))
        stack.addArrangedSubview(caption(L10n.t("scene.editor.placeholderHint")))

        stack.addArrangedSubview(labelledControl(L10n.t("scene.editor.log"), logSwitch))
        stack.addArrangedSubview(labelled(L10n.t("scene.editor.logMessage"), logMessageField))
        stack.addArrangedSubview(labelled(L10n.t("scene.editor.logLevel"), logLevelControl))

        stack.addArrangedSubview(labelledControl(L10n.t("scene.editor.mark"), markSwitch))
        stack.addArrangedSubview(labelled(L10n.t("scene.editor.markName"), markField))

        notifySwitch.addTarget(self, action: #selector(actionToggled), for: .valueChanged)
        logSwitch.addTarget(self, action: #selector(actionToggled), for: .valueChanged)
        markSwitch.addTarget(self, action: #selector(actionToggled), for: .valueChanged)
    }

    private func populate() {
        guard let scene = editingScene else {
            selectedDevice = devices.first
            updateDeviceButton()
            offlineField.text = "300"
            rssiField.text = "-80"
            thresholdField.text = "30"
            consecutiveField.text = "3"
            cooldownField.text = "300"
            updateWeekdayButtons()
            return
        }
        nameField.text = scene.name
        enabledSwitch.isOn = scene.enabled
        cooldownField.text = String(scene.cooldownSeconds)
        switch scene.trigger {
        case .deviceOffline(let reference, let seconds):
            selectedTriggerKind = 0
            selectedDevice = device(for: reference)
            offlineField.text = String(seconds)
        case .rssiBelow(let reference, let threshold):
            selectedTriggerKind = 1
            selectedDevice = device(for: reference)
            rssiField.text = String(threshold)
        case .metricThreshold(let reference, let deviceType, let metric, let comparator, let threshold, let consecutive):
            selectedTriggerKind = 2
            selectedDevice = device(for: reference)
            deviceTypeField.text = deviceType
            selectedMetric = ReadingMetric(rawValue: metric) ?? .other
            updateMetricButton()
            comparatorControl.selectedSegmentIndex = SceneComparator.allCases.firstIndex(of: comparator) ?? 3
            thresholdField.text = SceneNumber.text(threshold)
            consecutiveField.text = String(consecutive)
        case .schedule(let timeOfDay, let timezone, let days):
            selectedTriggerKind = 3
            timezoneField.text = timezone
            selectedWeekdays = Set(days)
            let parts = timeOfDay.split(separator: ":")
            var components = DateComponents()
            components.hour = parts.count == 2 ? Int(parts[0]) : 9
            components.minute = parts.count == 2 ? Int(parts[1]) : 0
            timePicker.date = Calendar.current.date(from: components) ?? Date()
        }
        triggerControl.selectedSegmentIndex = selectedTriggerKind
        updateDeviceButton()
        updateWeekdayButtons()
        for action in scene.actions {
            switch action {
            case .notify(let title, let body):
                notifySwitch.isOn = true
                notifyTitleField.text = title
                notifyBodyField.text = body
            case .log(let message, let level):
                logSwitch.isOn = true
                logMessageField.text = message
                logLevelControl.selectedSegmentIndex = level == .warn ? 1 : 0
            case .markDevice(let mark):
                markSwitch.isOn = true
                markField.text = mark
            }
        }
    }

    // MARK: - Actions

    @objc private func triggerChanged() {
        selectedTriggerKind = triggerControl.selectedSegmentIndex
        updateVisibility()
    }

    @objc private func actionToggled() {
        updateActionVisibility()
    }

    @objc private func deviceTapped() {
        let sheet = UIAlertController(title: L10n.t("scene.editor.selectDevice"), message: nil, preferredStyle: .actionSheet)
        for saved in devices where saved.deletedAt == nil {
            sheet.addAction(UIAlertAction(title: saved.displayName, style: .default) { [weak self] _ in
                self?.selectedDevice = saved
                self?.updateDeviceButton()
            })
        }
        if devices.isEmpty {
            sheet.addAction(UIAlertAction(title: L10n.t("scene.editor.noDevice"), style: .cancel))
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = deviceButton
        }
        present(sheet, animated: true)
    }

    @objc private func metricTapped() {
        let sheet = UIAlertController(title: L10n.t("scene.editor.metricName"), message: nil, preferredStyle: .actionSheet)
        for metric in ReadingMetric.whitelist {
            sheet.addAction(UIAlertAction(title: metric.displayName, style: .default) { [weak self] _ in
                self?.selectedMetric = metric
                self?.updateMetricButton()
            })
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = metricButton
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        present(sheet, animated: true)
    }

    @objc private func weekdayTapped(_ sender: UIButton) {
        let iso = sender.tag
        if selectedWeekdays.contains(iso) {
            selectedWeekdays.remove(iso)
        } else {
            selectedWeekdays.insert(iso)
        }
        updateWeekdayButtons()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        guard let scene = buildScene() else { return }
        onSave(scene)
        dismiss(animated: true)
    }

    // MARK: - Build

    private func buildScene() -> Scene? {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return alert(L10n.t("scene.editor.nameRequired")) }

        let trigger: SceneTrigger
        switch selectedTriggerKind {
        case 0:
            guard let device = selectedDevice else { return alert(L10n.t("scene.editor.deviceRequired")) }
            guard let seconds = Int(offlineField.text ?? ""), (60...86400).contains(seconds) else {
                return alert(L10n.t("scene.editor.validation"))
            }
            trigger = .deviceOffline(device: reference(device), offlineSeconds: seconds)
        case 1:
            guard let device = selectedDevice else { return alert(L10n.t("scene.editor.deviceRequired")) }
            guard let threshold = Int(rssiField.text ?? ""), (-100...0).contains(threshold) else {
                return alert(L10n.t("scene.editor.validation"))
            }
            trigger = .rssiBelow(device: reference(device), rssiThreshold: threshold)
        case 2:
            guard let device = selectedDevice else { return alert(L10n.t("scene.editor.deviceRequired")) }
            guard !selectedMetric.displayName.isEmpty,
                  let threshold = Double(thresholdField.text ?? ""),
                  let consecutive = Int(consecutiveField.text ?? ""), (1...30).contains(consecutive),
                  !(deviceTypeField.text ?? "").isEmpty else {
                return alert(L10n.t("scene.editor.validation"))
            }
            trigger = .metricThreshold(
                device: reference(device),
                deviceType: deviceTypeField.text ?? "",
                metric: selectedMetric.rawValue,
                comparator: SceneComparator.allCases[comparatorControl.selectedSegmentIndex],
                threshold: threshold,
                consecutive: consecutive
            )
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
            let timeOfDay = formatter.string(from: timePicker.date)
            let timezone = (timezoneField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard TimeZone(identifier: timezone) != nil else { return alert(L10n.t("scene.editor.validation")) }
            trigger = .schedule(timeOfDay: timeOfDay, timezone: timezone, daysOfWeek: selectedWeekdays.sorted())
        }

        var actions: [SceneAction] = []
        if notifySwitch.isOn {
            let title = (notifyTitleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return alert(L10n.t("scene.editor.validation")) }
            actions.append(.notify(title: title, body: (notifyBodyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if logSwitch.isOn {
            let message = (logMessageField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return alert(L10n.t("scene.editor.validation")) }
            actions.append(.log(message: message, level: logLevelControl.selectedSegmentIndex == 1 ? .warn : .info))
        }
        if markSwitch.isOn {
            let mark = (markField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mark.isEmpty else { return alert(L10n.t("scene.editor.validation")) }
            actions.append(.markDevice(mark: mark))
        }
        guard !actions.isEmpty else { return alert(L10n.t("scene.editor.actionRequired")) }
        let cooldown = Int(cooldownField.text ?? "") ?? 300
        guard (0...86400).contains(cooldown) else { return alert(L10n.t("scene.editor.validation")) }

        return Scene(
            id: editingScene?.id ?? UUID(),
            remoteID: editingScene?.remoteID,
            name: name,
            enabled: enabledSwitch.isOn,
            cooldownSeconds: cooldown,
            trigger: trigger,
            actions: actions,
            version: editingScene?.version ?? 0,
            createdAt: editingScene?.createdAt ?? Date(),
            updatedAt: Date(),
            syncState: .pending
        )
    }

    @discardableResult
    private func alert(_ message: String) -> Scene? {
        let controller = UIAlertController(title: L10n.t("scene.editor.validation"), message: message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: L10n.t("common.ok"), style: .default))
        present(controller, animated: true)
        return nil
    }

    // MARK: - Helpers

    private func updateVisibility() {
        deviceSection.isHidden = selectedTriggerKind == 3
        offlineSection.isHidden = selectedTriggerKind != 0
        rssiSection.isHidden = selectedTriggerKind != 1
        metricSection.isHidden = selectedTriggerKind != 2
        scheduleSection.isHidden = selectedTriggerKind != 3
        updateActionVisibility()
    }

    private func updateActionVisibility() {
        notifyTitleField.isHidden = !notifySwitch.isOn
        notifyBodyField.isHidden = !notifySwitch.isOn
        logMessageField.isHidden = !logSwitch.isOn
        logLevelControl.isHidden = !logSwitch.isOn
        markField.isHidden = !markSwitch.isOn
    }

    private func updateDeviceButton() {
        let title = selectedDevice?.displayName ?? L10n.t("scene.editor.selectDevice")
        deviceButton.setTitle(title, for: .normal)
        deviceButton.accessibilityLabel = L10n.f("scene.editor.device", title)
    }

    private func updateMetricButton() {
        metricButton.setTitle(selectedMetric.displayName, for: .normal)
        metricButton.accessibilityLabel = selectedMetric.displayName
    }

    private func updateWeekdayButtons() {
        for view in weekdayStack.arrangedSubviews {
            guard let button = view as? UIButton else { continue }
            let selected = selectedWeekdays.contains(button.tag)
            button.backgroundColor = selected ? Palette.primary.withAlphaComponent(0.15) : Palette.surfaceSunken
            button.setTitleColor(selected ? Palette.primary : Palette.textSecondary, for: .normal)
            button.accessibilityValue = selected ? L10n.t("common.on") : L10n.t("common.off")
        }
    }

    private func device(for reference: SceneDeviceReference) -> SavedDevice? {
        devices.first {
            $0.platform.caseInsensitiveCompare(reference.platform) == .orderedSame
                && $0.externalID.caseInsensitiveCompare(reference.externalID) == .orderedSame
        }
    }

    private func reference(_ device: SavedDevice) -> SceneDeviceReference {
        SceneDeviceReference(platform: device.platform, externalID: device.externalID)
    }

    private func weekdayShort(_ iso: Int) -> String {
        ["weekday.mon", "weekday.tue", "weekday.wed", "weekday.thu", "weekday.fri", "weekday.sat", "weekday.sun"]
            .map { L10n.t($0) }[min(max(iso - 1, 0), 6)]
    }

    private func labelled(_ title: String, _ control: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.applyFont(AppText.caption.font(weight: .medium))
        label.textColor = Palette.textSecondary
        label.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = Layout.space4
        stack.isAccessibilityElement = false
        return stack
    }

    private func labelledControl(_ title: String, _ control: UIView) -> UIView {
        let row = labelled(title, control)
        if let stack = row as? UIStackView {
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = Layout.space12
        }
        return row
    }

    private func sectionTitle(_ title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.applyFont(AppText.headline.font())
        label.textColor = Palette.textPrimary
        label.numberOfLines = 0
        return label
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.applyFont(AppText.footnote.font())
        label.textColor = Palette.textTertiary
        label.numberOfLines = 0
        return label
    }
}

private extension UITextField {
    func applyFormFieldStyle() {
        applyFont(AppText.body.font())
        textColor = Palette.textPrimary
        backgroundColor = Palette.surface
        layer.cornerRadius = Radius.sm
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = Palette.border.cgColor
        heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.buttonH).isActive = true
        let padding = UIView(frame: CGRect(x: 0, y: 0, width: Layout.space12, height: 1))
        leftView = padding
        leftViewMode = .always
    }
}

private extension UIButton {
    func applyMenuStyle() {
        setTitleColor(Palette.textPrimary, for: .normal)
        titleLabel?.applyFont(AppText.body.font())
        contentHorizontalAlignment = .leading
        backgroundColor = Palette.surface
        layer.cornerRadius = Radius.sm
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = Palette.border.cgColor
        heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.buttonH).isActive = true
    }
}
