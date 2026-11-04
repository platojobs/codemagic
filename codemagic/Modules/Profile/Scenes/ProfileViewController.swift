import UIKit

/// 「我的」页：蓝牙权限自检、本地扫描日志入口、基础设置与关于。
final class ProfileViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case bluetooth
        case localData
        case settings
        case about
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let viewModel: ProfileViewModel
    private let scanLogStore: ScanLogStore

    init(viewModel: ProfileViewModel, scanLogStore: ScanLogStore) {
        self.viewModel = viewModel
        self.scanLogStore = scanLogStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "我的"
        view.backgroundColor = AppTheme.Palette.background
        configureTableView()
        viewModel.onChange = { [weak self] in
            self?.tableView.reloadData()
        }
        viewModel.refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.activate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        viewModel.deactivate()
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ValueCell")
        tableView.register(SwitchCell.self, forCellReuseIdentifier: SwitchCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func makeValueCell(title: String, value: String, showsDisclosure: Bool = false) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ValueCell")
            ?? UITableViewCell(style: .default, reuseIdentifier: "ValueCell")
        var configuration = UIListContentConfiguration.valueCell()
        configuration.text = title
        configuration.secondaryText = value
        configuration.secondaryTextProperties.color = AppTheme.Palette.secondaryText
        cell.contentConfiguration = configuration
        cell.accessoryType = showsDisclosure ? .disclosureIndicator : .none
        cell.selectionStyle = showsDisclosure ? .default : .none
        return cell
    }

    private func makeActionCell(title: String, color: UIColor) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ValueCell")
            ?? UITableViewCell(style: .default, reuseIdentifier: "ValueCell")
        var configuration = UIListContentConfiguration.cell()
        configuration.text = title
        configuration.textProperties.color = color
        cell.contentConfiguration = configuration
        cell.selectionStyle = .default
        return cell
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func confirmClearLogs() {
        let alert = UIAlertController(
            title: "清空扫描日志？",
            message: "日志采用软删除，记录会在本地保留 deletedAt 与待同步状态。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            self?.viewModel.clearLogs()
        })
        present(alert, animated: true)
    }

    private func openLogs() {
        let logs = ScanLogViewController(scanLogStore: scanLogStore)
        navigationController?.pushViewController(logs, animated: true)
    }

    private func openAbout() {
        let about = AboutViewController(
            versionText: viewModel.appVersionText,
            baseURLText: viewModel.baseURLText,
            startupWarning: viewModel.startupWarning
        )
        navigationController?.pushViewController(about, animated: true)
    }
}

// MARK: - UITableViewDataSource

extension ProfileViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .bluetooth: return 3
        case .localData: return 2
        case .settings: return 2
        case .about: return 3
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .bluetooth: return "蓝牙权限"
        case .localData: return "本地数据"
        case .settings: return "设置"
        case .about: return "关于"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .bluetooth:
            return viewModel.permissionGuidance
        case .about:
            return viewModel.startupWarning ?? "行为口径与 Android 端共用 docs/consistency.md。"
        case .localData, .settings:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else { return UITableViewCell() }

        switch section {
        case .bluetooth:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: "授权状态", value: viewModel.authorizationText)
            case 1:
                return makeValueCell(title: "运行状态", value: viewModel.bluetoothStateText)
            default:
                return makeActionCell(
                    title: "前往系统设置",
                    color: AppTheme.Palette.accent
                )
            }

        case .localData:
            if indexPath.row == 0 {
                return makeValueCell(
                    title: "本地扫描日志",
                    value: "\(viewModel.logCount) 条",
                    showsDisclosure: true
                )
            }
            return makeActionCell(title: "清空扫描日志", color: AppTheme.Palette.promotion)

        case .settings:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SwitchCell.reuseIdentifier,
                for: indexPath
            ) as? SwitchCell else {
                return UITableViewCell()
            }
            if indexPath.row == 0 {
                cell.configure(
                    title: "自动保存最近扫描设备",
                    isOn: viewModel.autoSaveRecentDevices
                ) { [weak self] isOn in
                    self?.viewModel.autoSaveRecentDevices = isOn
                }
            } else {
                cell.configure(
                    title: "进入首页自动开始扫描",
                    isOn: viewModel.autoScanOnLaunch
                ) { [weak self] isOn in
                    self?.viewModel.autoScanOnLaunch = isOn
                }
            }
            return cell

        case .about:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: "应用版本", value: viewModel.appVersionText)
            case 1:
                return makeValueCell(title: "接口地址（BASE_URL）", value: viewModel.baseURLText)
            default:
                return makeValueCell(title: "关于与权限说明", value: "", showsDisclosure: true)
            }
        }
    }
}

// MARK: - UITableViewDelegate

extension ProfileViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }

        switch section {
        case .bluetooth where indexPath.row == 2:
            openSystemSettings()
        case .localData where indexPath.row == 0:
            openLogs()
        case .localData where indexPath.row == 1:
            confirmClearLogs()
        case .about where indexPath.row == 2:
            openAbout()
        default:
            break
        }
    }
}
