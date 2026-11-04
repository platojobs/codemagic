import UIKit

/// 设备页：已保存设备管理（备注名、分组、最后出现时间）与本地规则增删启停。
final class DevicesViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case devices
        case rules
    }

    // MARK: - Subviews

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let addRuleButton = UIBarButtonItem()

    // MARK: - Dependencies

    private let viewModel: DevicesViewModel
    private let environment: AppEnvironment

    // MARK: - Init

    init(viewModel: DevicesViewModel, environment: AppEnvironment) {
        self.viewModel = viewModel
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设备"
        view.backgroundColor = AppTheme.Palette.background
        configureTableView()

        addRuleButton.target = self
        addRuleButton.action = #selector(handleAddRule)
        addRuleButton.title = "新增"
        navigationItem.rightBarButtonItem = addRuleButton

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

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(SavedDeviceCell.self, forCellReuseIdentifier: SavedDeviceCell.reuseIdentifier)
        tableView.register(RuleCell.self, forCellReuseIdentifier: RuleCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "PlaceholderCell")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppTheme.Metrics.estimatedRowHeight
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func handleAddRule() {
        let editor = RuleEditorViewController(deviceOptions: viewModel.ruleDeviceOptions) { [weak self] rule in
            self?.viewModel.saveRule(rule)
        }
        let navigationController = UINavigationController(rootViewController: editor)
        present(navigationController, animated: true)
    }

    private func presentEditAlert(for device: SavedDevice) {
        let alert = UIAlertController(
            title: "编辑设备",
            message: "备注名用于列表展示，分组用于本地归类。",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = device.remark
            field.placeholder = "备注名"
        }
        alert.addTextField { field in
            field.text = device.groupName
            field.placeholder = "分组"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            let remark = alert?.textFields?.first?.text ?? ""
            let group = alert?.textFields?.last?.text ?? ""
            self?.viewModel.updateDevice(id: device.id, remark: remark, groupName: group)
        })
        present(alert, animated: true)
    }

    private func confirmDeleteDevice(_ device: SavedDevice) {
        let alert = UIAlertController(
            title: "删除设备？",
            message: "将同时删除该设备关联的本地规则，数据采用软删除以便后续同步。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.viewModel.deleteDevice(id: device.id)
        })
        present(alert, animated: true)
    }

    private func openDetail(for device: SavedDevice) {
        let detailViewModel = DeviceDetailViewModel(
            device: device,
            bluetooth: environment.bluetooth,
            productService: environment.productService,
            cacheStore: environment.deviceInfoCacheStore,
            savedDeviceStore: environment.savedDeviceStore
        )
        let detail = DeviceDetailViewController(viewModel: detailViewModel)
        navigationController?.pushViewController(detail, animated: true)
    }
}

// MARK: - UITableViewDataSource

extension DevicesViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .devices:
            return max(viewModel.devices.count, 1)
        case .rules:
            return max(viewModel.rules.count, 1)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .devices:
            return "已保存设备（\(viewModel.devices.count)）"
        case .rules:
            return "本地规则（\(viewModel.rules.count)）"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else { return UITableViewCell() }

        switch section {
        case .devices:
            guard !viewModel.devices.isEmpty else {
                return makePlaceholderCell(
                    text: "还没有保存的设备，可在首页扫描后保存。",
                    symbol: SymbolName.device
                )
            }
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SavedDeviceCell.reuseIdentifier,
                for: indexPath
            ) as? SavedDeviceCell else {
                return UITableViewCell()
            }
            cell.configure(device: viewModel.devices[indexPath.row])
            return cell

        case .rules:
            guard !viewModel.rules.isEmpty else {
                return makePlaceholderCell(
                    text: "暂无规则，点击右上角「新增」创建断开或信号阈值规则。",
                    symbol: SymbolName.rule
                )
            }
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: RuleCell.reuseIdentifier,
                for: indexPath
            ) as? RuleCell else {
                return UITableViewCell()
            }
            let rule = viewModel.rules[indexPath.row]
            cell.configure(rule: rule, targetName: viewModel.deviceName(for: rule.deviceID)) { [weak self] in
                self?.viewModel.toggleRule(id: rule.id)
            }
            return cell
        }
    }

    private func makePlaceholderCell(text: String, symbol: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "PlaceholderCell")
            ?? UITableViewCell(style: .default, reuseIdentifier: "PlaceholderCell")
        var configuration = cell.defaultContentConfiguration()
        configuration.text = text
        configuration.textProperties.color = AppTheme.Palette.secondaryText
        configuration.image = UIImage(systemName: symbol)
        configuration.imageProperties.tintColor = AppTheme.Palette.tertiaryText
        cell.contentConfiguration = configuration
        cell.selectionStyle = .none
        return cell
    }
}

// MARK: - UITableViewDelegate

extension DevicesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == Section.devices.rawValue,
              !viewModel.devices.isEmpty else { return }
        let device = viewModel.devices[indexPath.row]
        // 跨平台拉回的设备没有本机 CoreBluetooth 标识，禁用连接入口。
        guard device.isConnectable else { return }
        openDetail(for: device)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let section = Section(rawValue: indexPath.section) else { return nil }

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            guard let self else { return }
            switch section {
            case .devices where !self.viewModel.devices.isEmpty:
                self.confirmDeleteDevice(self.viewModel.devices[indexPath.row])
            case .rules where !self.viewModel.rules.isEmpty:
                self.viewModel.deleteRule(id: self.viewModel.rules[indexPath.row].id)
            default:
                break
            }
            completion(true)
        }

        let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            guard let self, section == .devices, !self.viewModel.devices.isEmpty else {
                completion(false)
                return
            }
            self.presentEditAlert(for: self.viewModel.devices[indexPath.row])
            completion(true)
        }

        switch section {
        case .devices where !viewModel.devices.isEmpty:
            return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
        case .rules where !viewModel.rules.isEmpty:
            return UISwipeActionsConfiguration(actions: [deleteAction])
        default:
            return nil
        }
    }
}
