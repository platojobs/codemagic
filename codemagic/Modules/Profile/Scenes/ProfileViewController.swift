import UIKit

/// 「我的」页：蓝牙权限自检、本地扫描日志入口、同步状态、基础设置与关于。
final class ProfileViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case bluetooth
        case localData
        case sync
        case account
        case alerts
        case appearance
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

    /// 重新登录必须由用户确认：会换新的匿名账号，旧账号云端数据不会自动合并。
    private func confirmRelogin() {
        let alert = UIAlertController(
            title: "重新登录？",
            message: "将创建新的匿名账号，旧账号的云端数据不会自动合并到新账号；本机已有设备会重新同步到新账号。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "重新登录", style: .destructive) { [weak self] _ in
            self?.viewModel.relogin()
        })
        present(alert, animated: true)
    }

    private func openLogs() {
        let logs = ScanLogViewController(scanLogStore: scanLogStore)
        navigationController?.pushViewController(logs, animated: true)
    }

    private func presentThrottlePicker() {
        let sheet = UIAlertController(title: "通知节流窗口", message: "同一设备同一规则在窗口内只提醒一次。", preferredStyle: .actionSheet)
        for minutes in viewModel.ruleAlertThrottleOptions {
            let selected = minutes == viewModel.ruleAlertThrottleMinutes
            sheet.addAction(UIAlertAction(
                title: selected ? "✓ \(minutes) 分钟" : "\(minutes) 分钟",
                style: .default
            ) { [weak self] _ in
                self?.viewModel.ruleAlertThrottleMinutes = minutes
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: 1, section: Section.alerts.rawValue))
        }
        present(sheet, animated: true)
    }

    private func presentAppearancePicker() {
        let sheet = UIAlertController(title: "外观", message: "深色模式下图表与卡片使用动态配色。", preferredStyle: .actionSheet)
        for appearance in AppAppearance.allCases {
            let selected = appearance == viewModel.appearance
            sheet.addAction(UIAlertAction(
                title: selected ? "✓ \(appearance.title)" : appearance.title,
                style: .default
            ) { [weak self] _ in
                self?.viewModel.appearance = appearance
                AppAppearance.apply(appearance)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: 0, section: Section.appearance.rawValue))
        }
        present(sheet, animated: true)
    }

    private func openAbout() {
        let about = AboutViewController(
            versionText: viewModel.appVersionText,
            baseURLText: viewModel.baseURLText,
            startupWarning: viewModel.startupWarning
        )
        navigationController?.pushViewController(about, animated: true)
    }

    // MARK: - Account

    private func openPairingCode() {
        let controller = PairingCodeViewController(viewModel: viewModel.makePairingCodeViewModel())
        navigationController?.pushViewController(controller, animated: true)
    }

    private func openPairingClaim() {
        let controller = PairingClaimViewController(
            viewModel: viewModel.makePairingClaimViewModel()
        ) { [weak self] in
            self?.viewModel.syncAfterTakeover()
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    /// 导出进度使用真实已读取读数条数；文件落临时目录，分享面板关闭后删除。
    private func exportAccountData() {
        let progress = UIAlertController(
            title: "导出我的数据",
            message: "正在读取账号数据…",
            preferredStyle: .alert
        )
        present(progress, animated: true)

        viewModel.exportAccountData(progress: { [weak progress] count in
            progress?.message = count > 0 ? "已读取 \(count) 条读数…" : "正在读取账号数据…"
        }, completion: { [weak self, weak progress] result in
            progress?.dismiss(animated: true) {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.presentShareSheet(for: url)
                case .failure(let error):
                    self.presentExportError(error)
                }
            }
        })
    }

    private func presentShareSheet(for url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
            // 分享或取消后都删除临时文件，不在沙盒长期留存账号数据。
            self?.viewModel.removeExportedFile(at: url)
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.bounds
        }
        present(activity, animated: true)
    }

    private func presentExportError(_ error: AccountExportError) {
        let alert = UIAlertController(
            title: "导出失败",
            message: error.errorDescription ?? "请稍后重试。",
            preferredStyle: .alert
        )
        if error.isRetryable {
            alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
                self?.exportAccountData()
            })
        }
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }

    private func confirmDeleteAccount() {
        let alert = UIAlertController(
            title: "注销账号？",
            message: viewModel.accountDeletionConfirmationText,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "永久删除并注销", style: .destructive) { [weak self] _ in
            self?.performDeleteAccount()
        })
        present(alert, animated: true)
    }

    private func performDeleteAccount() {
        guard !viewModel.isSyncing else {
            presentMessage(title: "无法注销", message: "正在同步，请等待同步结束后再注销账号。")
            return
        }
        let progress = UIAlertController(
            title: "注销账号",
            message: "正在删除云端账号…",
            preferredStyle: .alert
        )
        present(progress, animated: true)

        viewModel.deleteAccount { [weak self, weak progress] result in
            progress?.dismiss(animated: true) {
                guard let self else { return }
                switch result {
                case .success:
                    self.presentMessage(
                        title: "账号已注销",
                        message: "云端与本机数据已清空，回到全新的匿名状态；下一次同步会创建新的匿名账号。"
                    )
                case .failure(let error):
                    let alert = UIAlertController(
                        title: "注销失败",
                        message: error.errorDescription ?? "请稍后重试。",
                        preferredStyle: .alert
                    )
                    if error.isRetryable {
                        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
                            self?.performDeleteAccount()
                        })
                    }
                    alert.addAction(UIAlertAction(title: "好", style: .cancel))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
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
        case .sync: return 4 + (viewModel.needsRelogin ? 1 : 0)
        case .account: return 4
        case .alerts: return 3
        case .appearance: return 1
        case .settings: return 3
        case .about: return 3
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .bluetooth: return "蓝牙权限"
        case .localData: return "本地数据"
        case .sync: return "同步"
        case .account: return "账号与数据"
        case .alerts: return "阈值告警"
        case .appearance: return "外观"
        case .settings: return "设置"
        case .about: return "关于"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .bluetooth:
            return viewModel.permissionGuidance
        case .sync:
            return "\(viewModel.syncStatusText)\n\(viewModel.syncDegradationText)"
        case .account:
            return "接管码一次性有效，10 分钟内失效；导出文件在分享完成后自动删除；注销不可恢复。"
        case .alerts:
            return viewModel.notificationGuidance
        case .appearance:
            return "深色模式使用动态语义色，图表、区间带与卡片会自动适配。"
        case .settings:
            return "\(viewModel.backgroundCollectionStatusText)\n\(viewModel.backgroundCollectionGuidance)"
        case .about:
            return viewModel.startupWarning ?? "行为口径与 Android 端共用 docs/consistency.md。"
        case .localData:
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

        case .sync:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: "上次同步时间", value: viewModel.lastSyncText)
            case 1:
                return makeValueCell(title: "待同步", value: viewModel.pendingUploadText)
            case 2:
                return makeActionCell(
                    title: viewModel.isSyncing ? "同步中…" : "立即同步",
                    color: viewModel.isSyncing ? AppTheme.Palette.secondaryText : AppTheme.Palette.accent
                )
            case 3:
                return makeValueCell(title: "匿名账号", value: viewModel.accountText)
            default:
                return makeActionCell(
                    title: viewModel.isSyncing ? "登录中…" : "重新登录",
                    color: AppTheme.Palette.accent
                )
            }

        case .account:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: "迁移到新设备", value: "生成接管码", showsDisclosure: true)
            case 1:
                return makeValueCell(title: "从旧设备接管", value: "输入 8 位接管码", showsDisclosure: true)
            case 2:
                return makeActionCell(title: "导出我的数据", color: AppTheme.Palette.accent)
            default:
                return makeActionCell(title: "注销账号", color: AppTheme.Palette.promotion)
            }

        case .alerts:
            if indexPath.row == 0 {
                guard let cell = tableView.dequeueReusableCell(
                    withIdentifier: SwitchCell.reuseIdentifier,
                    for: indexPath
                ) as? SwitchCell else {
                    return UITableViewCell()
                }
                cell.configure(
                    title: "阈值告警通知",
                    isOn: viewModel.ruleAlertsEnabled
                ) { [weak self] isOn in
                    self?.viewModel.ruleAlertsEnabled = isOn
                }
                return cell
            }
            if indexPath.row == 1 {
                return makeValueCell(
                    title: "节流窗口",
                    value: viewModel.ruleAlertThrottleText,
                    showsDisclosure: true
                )
            }
            return makeValueCell(
                title: "通知权限",
                value: viewModel.notificationAuthorizationText,
                showsDisclosure: viewModel.needsNotificationSettings
            )

        case .appearance:
            return makeValueCell(
                title: "外观",
                value: viewModel.appearanceText,
                showsDisclosure: true
            )

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
            } else if indexPath.row == 1 {
                cell.configure(
                    title: "进入首页自动开始扫描",
                    isOn: viewModel.autoScanOnLaunch
                ) { [weak self] isOn in
                    self?.viewModel.autoScanOnLaunch = isOn
                }
            } else {
                cell.configure(
                    title: "后台采集",
                    isOn: viewModel.backgroundCollectionEnabled
                ) { [weak self] isOn in
                    self?.viewModel.backgroundCollectionEnabled = isOn
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
        case .sync where indexPath.row == 2:
            viewModel.manualSync()
        case .sync where indexPath.row == 4:
            confirmRelogin()
        case .account where indexPath.row == 0:
            openPairingCode()
        case .account where indexPath.row == 1:
            openPairingClaim()
        case .account where indexPath.row == 2:
            exportAccountData()
        case .account where indexPath.row == 3:
            confirmDeleteAccount()
        case .alerts where indexPath.row == 1:
            presentThrottlePicker()
        case .alerts where indexPath.row == 2 && viewModel.needsNotificationSettings:
            openSystemSettings()
        case .appearance where indexPath.row == 0:
            presentAppearancePicker()
        case .about where indexPath.row == 2:
            openAbout()
        default:
            break
        }
    }
}
