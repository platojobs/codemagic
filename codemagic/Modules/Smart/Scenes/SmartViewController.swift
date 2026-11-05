import UIKit

/// 智能页：自动化（规则增删启停 + 最近触发）与场景（仅本机动作组合）。
final class SmartViewController: UIViewController {
    private enum Mode: Int {
        case automation
        case scenario
    }

    private enum Row {
        case rule(DeviceRule)
        case trigger(ScanLogEntry)
        case scenario(Scenario)
        case emptyRules
        case emptyScenarios
        case error(String)
    }

    private let segmentedControl = UISegmentedControl(items: ["自动化", "场景"])
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

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "智能"
        view.backgroundColor = Palette.canvas
        configureTable()
        configureSegmentedControl()
        configureNavigation()
        titleHost = LargeTitleHost(
            title: "智能",
            viewController: self,
            scrollView: tableView,
            adjustsContentInset: false
        )
        titleHost?.setSubtitle("自动化规则与仅本机场景")

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
        viewModel.reload()
    }

    // MARK: - Configuration

    private func configureTable() {
        tableView.backgroundColor = Palette.canvas
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.contentInset.bottom = Layout.space24
        tableView.register(RuleCell.self, forCellReuseIdentifier: RuleCell.reuseIdentifier)
        tableView.register(ScenarioCell.self, forCellReuseIdentifier: ScenarioCell.reuseIdentifier)
        tableView.register(TriggerCell.self, forCellReuseIdentifier: TriggerCell.reuseIdentifier)
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
        navigationItem.rightBarButtonItem?.accessibilityLabel = mode == .automation ? "新建规则" : "新建场景"
    }

    // MARK: - Data

    private var sections: [(title: String, rows: [Row])] {
        if let error = viewModel.lastError {
            return [("", [.error(error.localizedDescription)])]
        }
        switch mode {
        case .automation:
            var sections: [(String, [Row])] = []
            if viewModel.rules.isEmpty {
                sections.append(("自动化规则", [.emptyRules]))
            } else {
                sections.append(("自动化规则", viewModel.rules.map { .rule($0) }))
            }
            if !viewModel.recentTriggers.isEmpty {
                sections.append(("最近触发", viewModel.recentTriggers.map { .trigger($0) }))
            }
            return sections
        case .scenario:
            if viewModel.scenarios.isEmpty {
                return [("场景", [.emptyScenarios])]
            }
            return [("场景", viewModel.scenarios.map { .scenario($0) })]
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
            presentScenarioEditor(nil)
        }
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
                ToastView.show("「\(result.scenarioName)」\(result.summaryText)", kind: .success, in: self)
            } else {
                ToastView.show("「\(result.scenarioName)」\(result.failureText)", kind: .failure, in: self)
            }
            self.viewModel.reload()
        }
        overlay.present(in: view)
        viewModel.runScenario(scenario) { result in
            overlay.complete(result)
        }
    }

    private func confirmDeleteRule(_ rule: DeviceRule) {
        confirm(title: "删除规则「\(rule.name)」？") { [weak self] in
            self?.viewModel.deleteRule(id: rule.id)
        }
    }

    private func confirmDeleteScenario(_ scenario: Scenario) {
        confirm(title: "删除场景「\(scenario.name)」？") { [weak self] in
            self?.viewModel.deleteScenario(id: scenario.id)
        }
    }

    private func confirm(title: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: "删除仅影响本机数据。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in action() })
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

        case .emptyRules:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: StateCell.reuseIdentifier, for: indexPath
            ) as? StateCell else { return UITableViewCell() }
            cell.showEmpty(
                symbol: SymbolName.rule,
                title: "还没有自动化规则",
                message: "规则会记录设备断开或信号低于阈值，命中后发送本地通知。",
                actionTitle: "新建规则"
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
                title: "还没有场景",
                message: "把连接设备、后台采集、静音告警等动作组合成场景，一键执行。",
                actionTitle: "新建场景"
            ) { [weak self] in
                self?.presentScenarioEditor(nil)
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
        sections[section].title.isEmpty ? 0 : Layout.sectionHeaderH + Layout.space8
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .rule: return Layout.row2 + Layout.space8
        case .trigger: return Layout.row1 + Layout.space8
        case .scenario: return Layout.row3 + Layout.space16
        case .emptyRules, .emptyScenarios, .error: return 280
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if case .scenario(let scenario) = sections[indexPath.section].rows[indexPath.row] {
            presentScenarioEditor(scenario)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .rule(let rule):
            let action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
                self?.confirmDeleteRule(rule)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        case .scenario(let scenario):
            let action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
                self?.confirmDeleteScenario(scenario)
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
                let edit = UIAction(title: "编辑场景", image: UIImage(systemName: SymbolName.edit)) { _ in
                    self?.presentScenarioEditor(scenario)
                }
                let run = UIAction(title: "执行场景", image: UIImage(systemName: "play.fill")) { _ in
                    self?.run(scenario)
                }
                let delete = UIAction(
                    title: "删除场景",
                    image: UIImage(systemName: SymbolName.delete),
                    attributes: .destructive
                ) { _ in
                    self?.confirmDeleteScenario(scenario)
                }
                return UIMenu(children: [run, edit, delete])
            }
        default:
            return nil
        }
    }
}
