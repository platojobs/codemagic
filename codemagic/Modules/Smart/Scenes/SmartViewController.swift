import UIKit

/// 智能页：自动化（规则增删启停 + 最近触发）与场景（仅本机动作组合）。
final class SmartViewController: UIViewController {
    private enum Mode: Int {
        case automation
        case scenario
    }

    private enum Row {
        case recommended
        case rule(DeviceRule)
        case trigger(ScanLogEntry)
        case scenario(Scenario)
        case scene(Scene)
        case emptyRules
        case emptyScenarios
        case error(String)
    }

    private let segmentedControl = UISegmentedControl(items: [L10n.t("smart.mode.automation"), L10n.t("smart.mode.scenarios")])
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var titleHost: LargeTitleHost?
    private var mode: Mode = .automation

    private let viewModel: SmartViewModel
    private let environment: AppEnvironment

    init(viewModel: SmartViewModel, environment: AppEnvironment) {
        self.viewModel = viewModel
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyBottomOcclusionInset(to: tableView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("smart.title")
        view.backgroundColor = Palette.canvas
        configureTable()
        configureSegmentedControl()
        configureNavigation()
        titleHost = LargeTitleHost(
            title: L10n.t("smart.title"),
            viewController: self,
            scrollView: tableView,
            adjustsContentInset: false
        )
        titleHost?.setSubtitle(L10n.t("smart.subtitle"))

        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: titleHost!.header.bottomAnchor, constant: Layout.space8),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.pageMargin),
            segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.pageMargin),
            segmentedControl.heightAnchor.constraint(equalToConstant: Layout.chipH),
            tableView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: Layout.space8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        viewModel.onChange = { [weak self] in
            self?.tableView.reloadData()
        }
        viewModel.reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        environment.sceneEngine.refreshMissingFlags()
        viewModel.reload()
    }

    // MARK: - Configuration

    private func configureTable() {
        tableView.backgroundColor = Palette.canvas
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.contentInset.bottom = Layout.space24
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = Layout.row2
        tableView.register(RuleCell.self, forCellReuseIdentifier: RuleCell.reuseIdentifier)
        tableView.register(ScenarioCell.self, forCellReuseIdentifier: ScenarioCell.reuseIdentifier)
        tableView.register(SceneAutomationCell.self, forCellReuseIdentifier: SceneAutomationCell.reuseIdentifier)
        tableView.register(TriggerCell.self, forCellReuseIdentifier: TriggerCell.reuseIdentifier)
        tableView.register(RecommendedEntryCell.self, forCellReuseIdentifier: RecommendedEntryCell.reuseIdentifier)
        tableView.register(StateCell.self, forCellReuseIdentifier: StateCell.reuseIdentifier)
        tableView.register(
            TableSectionHeaderView.self,
            forHeaderFooterViewReuseIdentifier: TableSectionHeaderView.reuseIdentifier
        )
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
    }

    private func configureSegmentedControl() {
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.selectedSegmentTintColor = Palette.surface
        segmentedControl.backgroundColor = Palette.surfaceSunken
        segmentedControl.setTitleTextAttributes(
            [.foregroundColor: Palette.textSecondary, .font: AppText.callout.font(weight: .medium)],
            for: .normal
        )
        segmentedControl.setTitleTextAttributes(
            [.foregroundColor: Palette.textPrimary, .font: AppText.callout.font(weight: .semibold)],
            for: .selected
        )
        segmentedControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
    }

    private func configureNavigation() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addTapped)
        )
        updateAddAccessibility()
    }

    private func updateAddAccessibility() {
        navigationItem.rightBarButtonItem?.accessibilityLabel =
            mode == .automation ? L10n.t("smart.newRule") : L10n.t("smart.newCloudScene")
    }

    // MARK: - Data

    private var sections: [(title: String, rows: [Row])] {
        if let error = viewModel.lastError {
            return [("", [.error(error.localizedDescription)])]
        }
        switch mode {
        case .automation:
            var sections: [(String, [Row])] = []
            sections.append(("", [.recommended]))
            if viewModel.rules.isEmpty {
                sections.append((L10n.t("smart.section.rules"), [.emptyRules]))
            } else {
                sections.append((L10n.t("smart.section.rules"), viewModel.rules.map { .rule($0) }))
            }
            if !viewModel.recentTriggers.isEmpty {
                sections.append((L10n.t("smart.section.recentTriggers"), viewModel.recentTriggers.map { .trigger($0) }))
            }
            return sections
        case .scenario:
            var sections: [(String, [Row])] = []
            if !viewModel.scenes.isEmpty {
                sections.append((L10n.t("smart.section.cloudScenes"), viewModel.scenes.map { .scene($0) }))
            }
            if !viewModel.scenarios.isEmpty {
                sections.append((L10n.t("smart.section.localScenarios"), viewModel.scenarios.map { .scenario($0) }))
            }
            if sections.isEmpty {
                return [(L10n.t("smart.mode.scenarios"), [.emptyScenarios])]
            }
            return sections
        }
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        mode = Mode(rawValue: segmentedControl.selectedSegmentIndex) ?? .automation
        updateAddAccessibility()
        tableView.reloadData()
    }

    @objc private func addTapped() {
        switch mode {
        case .automation:
            let editor = RuleEditorViewController(deviceOptions: viewModel.deviceOptionsForRule) { [weak self] rule in
                self?.viewModel.addRule(rule)
            }
            present(UINavigationController(rootViewController: editor), animated: true)
        case .scenario:
            presentSceneChooser()
        }
    }

    /// 场景模式的新增入口：推荐新建服务端场景，同时保留「仅本机」兼容旧用法。
    private func presentSceneChooser() {
        let sheet = UIAlertController(
            title: L10n.t("smart.sceneChooserTitle"),
            message: L10n.t("smart.sceneChooserMessage"),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: L10n.t("smart.newCloudScene"), style: .default) { [weak self] _ in
            self?.presentSceneEditor(nil)
        })
        sheet.addAction(UIAlertAction(title: L10n.t("smart.newLocalScenario"), style: .default) { [weak self] _ in
            self?.presentScenarioEditor(nil)
        })
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(sheet, animated: true)
    }

    private func presentSceneEditor(_ scene: Scene?) {
        let editor = SceneEditorViewController(scene: scene, devices: viewModel.savedDevices) { [weak self] updated in
            guard let self else { return }
            let fields: Set<SceneFieldKey>
            if let scene {
                fields = Self.changedFields(from: scene, to: updated)
            } else {
                fields = Set(SceneFieldKey.allCases)
            }
            self.viewModel.saveScene(updated, editedFields: fields)
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    private static func changedFields(from old: Scene, to new: Scene) -> Set<SceneFieldKey> {
        var fields: Set<SceneFieldKey> = []
        if old.name != new.name { fields.insert(.name) }
        if old.enabled != new.enabled { fields.insert(.enabled) }
        if old.cooldownSeconds != new.cooldownSeconds { fields.insert(.cooldownSeconds) }
        if old.trigger != new.trigger { fields.insert(.trigger) }
        if old.actions != new.actions { fields.insert(.actions) }
        return fields
    }

    /// 推荐规则入口：只使用设备真实出现过的指标，一键写入现有 readingThreshold 规则。
    private func presentRecommendedRules() {
        let viewModel = RecommendedRulesViewModel(
            readingsStore: environment.readingsStore,
            savedDeviceStore: environment.savedDeviceStore,
            ruleStore: environment.ruleStore
        )
        let controller = RecommendedRulesViewController(viewModel: viewModel) { [weak self] rule in
            guard let self else { return }
            self.viewModel.reload()
            ToastView.show(L10n.f("smart.recommended.added", rule.name), kind: .success, in: self)
        }
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    private func presentScenarioEditor(_ scenario: Scenario?) {
        let options = viewModel.savedDevices.map { ($0.id, $0.displayName) }
        let editor = ScenarioEditorViewController(scenario: scenario, deviceOptions: options) { [weak self] scenario in
            self?.viewModel.saveScenario(scenario)
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    private func run(_ scenario: Scenario) {
        let overlay = ScenarioProgressOverlay(scenario: scenario)
        overlay.onFinish = { [weak self] result in
            guard let self else { return }
            if result.isFullySuccessful {
                ToastView.show(L10n.f("scenario.result.quoted", result.scenarioName, result.summaryText), kind: .success, in: self)
            } else {
                ToastView.show(L10n.f("scenario.result.quoted", result.scenarioName, result.failureText), kind: .failure, in: self)
            }
            self.viewModel.reload()
        }
        overlay.present(in: view)
        viewModel.runScenario(scenario) { result in
            overlay.complete(result)
        }
    }

    private func confirmDeleteRule(_ rule: DeviceRule) {
        confirm(title: L10n.f("smart.deleteRuleTitle", String(describing: rule.name))) { [weak self] in
            self?.viewModel.deleteRule(id: rule.id)
        }
    }

    private func confirmDeleteScenario(_ scenario: Scenario) {
        confirm(title: L10n.f("smart.deleteScenarioTitle", String(describing: scenario.name))) { [weak self] in
            self?.viewModel.deleteScenario(id: scenario.id)
        }
    }

    private func confirm(title: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: L10n.t("smart.deleteNote"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("common.delete"), style: .destructive) { _ in action() })
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource

extension SmartViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        switch row {
        case .recommended:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: RecommendedEntryCell.reuseIdentifier, for: indexPath
            ) as? RecommendedEntryCell else { return UITableViewCell() }
            return cell

        case .rule(let rule):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: RuleCell.reuseIdentifier, for: indexPath
            ) as? RuleCell else { return UITableViewCell() }
            cell.configure(rule: rule, targetName: viewModel.deviceName(for: rule)) { [weak self] in
                self?.viewModel.toggleRule(id: rule.id)
            }
            return cell

        case .trigger(let entry):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: TriggerCell.reuseIdentifier, for: indexPath
            ) as? TriggerCell else { return UITableViewCell() }
            cell.configure(message: entry.message, time: viewModel.triggerText(for: entry))
            return cell

        case .scenario(let scenario):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: ScenarioCell.reuseIdentifier, for: indexPath
            ) as? ScenarioCell else { return UITableViewCell() }
            cell.configure(scenario: scenario) { [weak self] in
                self?.run(scenario)
            }
            return cell

        case .scene(let scene):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SceneAutomationCell.reuseIdentifier, for: indexPath
            ) as? SceneAutomationCell else { return UITableViewCell() }
            cell.configure(
                scene: scene,
                deviceMissing: viewModel.isDeviceMissing(scene),
                deviceName: viewModel.sceneDeviceName(scene),
                nextFire: viewModel.nextFireText(for: scene)
            ) { [weak self] isOn in
                guard isOn != scene.enabled else { return }
                self?.viewModel.toggleScene(id: scene.id)
            }
            return cell

        case .emptyRules:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: StateCell.reuseIdentifier, for: indexPath
            ) as? StateCell else { return UITableViewCell() }
            cell.showEmpty(
                symbol: SymbolName.rule,
                title: L10n.t("smart.emptyRules"),
                message: L10n.t("smart.emptyRulesMessage"),
                actionTitle: L10n.t("smart.newRule")
            ) { [weak self] in
                self?.addTapped()
            }
            return cell

        case .emptyScenarios:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: StateCell.reuseIdentifier, for: indexPath
            ) as? StateCell else { return UITableViewCell() }
            cell.showEmpty(
                symbol: "sparkles",
                title: L10n.t("home.noScenarios"),
                message: L10n.t("smart.emptyScenariosMessage"),
                actionTitle: L10n.t("smart.newCloudScene")
            ) { [weak self] in
                self?.presentSceneChooser()
            }
            return cell

        case .error(let message):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: StateCell.reuseIdentifier, for: indexPath
            ) as? StateCell else { return UITableViewCell() }
            cell.showError(message: message) { [weak self] in
                self?.viewModel.reload()
            }
            return cell
        }
    }
}

// MARK: - UITableViewDelegate

extension SmartViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: TableSectionHeaderView.reuseIdentifier
        ) as? TableSectionHeaderView else { return nil }
        header.configure(title: sections[section].title)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections[section].title.isEmpty
            ? 0
            : UIFontMetrics(forTextStyle: .headline).scaledValue(for: Layout.sectionHeaderH + Layout.space8)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .recommended:
            presentRecommendedRules()
        case .scenario(let scenario):
            presentScenarioEditor(scenario)
        case .scene(let scene):
            presentSceneEditor(scene)
        default:
            break
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .rule(let rule):
            let action = UIContextualAction(style: .destructive, title: L10n.t("common.delete")) { [weak self] _, _, completion in
                self?.confirmDeleteRule(rule)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        case .scenario(let scenario):
            let action = UIContextualAction(style: .destructive, title: L10n.t("common.delete")) { [weak self] _, _, completion in
                self?.confirmDeleteScenario(scenario)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        case .scene(let scene):
            let action = UIContextualAction(style: .destructive, title: L10n.t("common.delete")) { [weak self] _, _, completion in
                self?.confirm(title: L10n.f("smart.deleteScenarioTitle", scene.name)) { [weak self] in
                    self?.viewModel.deleteScene(id: scene.id)
                }
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        default:
            return nil
        }
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .scenario(let scenario):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                let edit = UIAction(title: L10n.t("scenario.editor.editTitle"), image: UIImage(systemName: SymbolName.edit)) { _ in
                    self?.presentScenarioEditor(scenario)
                }
                let run = UIAction(title: L10n.t("smart.runScenario"), image: UIImage(systemName: "play.fill")) { _ in
                    self?.run(scenario)
                }
                let delete = UIAction(
                    title: L10n.t("smart.deleteScenarioAction"),
                    image: UIImage(systemName: SymbolName.delete),
                    attributes: .destructive
                ) { _ in
                    self?.confirmDeleteScenario(scenario)
                }
                return UIMenu(children: [run, edit, delete])
            }
        case .scene(let scene):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                let edit = UIAction(
                    title: L10n.t("scenario.editor.editTitle"),
                    image: UIImage(systemName: SymbolName.edit)
                ) { _ in
                    self?.presentSceneEditor(scene)
                }
                let delete = UIAction(
                    title: L10n.t("smart.deleteScenarioAction"),
                    image: UIImage(systemName: SymbolName.delete),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.confirm(title: L10n.f("smart.deleteScenarioTitle", scene.name)) {
                        self?.viewModel.deleteScene(id: scene.id)
                    }
                }
                return UIMenu(children: [edit, delete])
            }
        default:
            return nil
        }
    }
}
