import UIKit

/// 「我的」页：蓝牙权限自检、本地扫描日志入口、家庭管理、同步状态、帮助/反馈、基础设置与关于。
final class ProfileViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case bluetooth
        case localData
        case household
        case sync
        case account
        case alerts
        case appearance
        case settings
        case support
        case about
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let viewModel: ProfileViewModel
    private let scanLogStore: ScanLogStore
    private let roomStore: RoomStore?
    private let savedDeviceStore: SavedDeviceStore?
    private let householdService: HouseholdService?
    private let feedbackCoordinator: FeedbackCoordinator?

    init(
        viewModel: ProfileViewModel,
        scanLogStore: ScanLogStore,
        roomStore: RoomStore? = nil,
        savedDeviceStore: SavedDeviceStore? = nil,
        householdService: HouseholdService? = nil,
        feedbackCoordinator: FeedbackCoordinator? = nil
    ) {
        self.viewModel = viewModel
        self.scanLogStore = scanLogStore
        self.roomStore = roomStore
        self.savedDeviceStore = savedDeviceStore
        self.householdService = householdService
        self.feedbackCoordinator = feedbackCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("tab.profile")
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
        tableView.reloadData()
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
            title: L10n.t("profile.clearLogTitle"),
            message: L10n.t("profile.clearLogMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("common.clear"), style: .destructive) { [weak self] _ in
            self?.viewModel.clearLogs()
        })
        present(alert, animated: true)
    }

    /// 重新登录必须由用户确认：会换新的匿名账号，旧账号云端数据不会自动合并。
    private func confirmRelogin() {
        let alert = UIAlertController(
            title: L10n.t("profile.reloginTitle"),
            message: L10n.t("profile.reloginMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("profile.relogin"), style: .destructive) { [weak self] _ in
            self?.viewModel.relogin()
        })
        present(alert, animated: true)
    }

    private func openLogs() {
        let logs = ScanLogViewController(scanLogStore: scanLogStore)
        navigationController?.pushViewController(logs, animated: true)
    }

    private func presentThrottlePicker() {
        let sheet = UIAlertController(title: L10n.t("profile.throttle"), message: L10n.t("profile.throttleNote"), preferredStyle: .actionSheet)
        for minutes in viewModel.ruleAlertThrottleOptions {
            let selected = minutes == viewModel.ruleAlertThrottleMinutes
            sheet.addAction(UIAlertAction(
                title: selected ? L10n.f("profile.throttleMinutesChecked", String(describing: minutes)) : L10n.f("profile.throttleMinutes", String(describing: minutes)),
                style: .default
            ) { [weak self] _ in
                self?.viewModel.ruleAlertThrottleMinutes = minutes
            })
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: 1, section: Section.alerts.rawValue))
        }
        present(sheet, animated: true)
    }

    private func presentAppearancePicker() {
        let sheet = UIAlertController(title: L10n.t("profile.appearance"), message: L10n.t("profile.appearanceNote"), preferredStyle: .actionSheet)
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
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: 0, section: Section.appearance.rawValue))
        }
        present(sheet, animated: true)
    }

    private func openHelpCenter() {
        let controller = HelpCenterViewController(topic: .all)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func openFeedback() {
        guard let feedbackCoordinator else {
            presentMessage(title: L10n.t("feedback.entry"), message: L10n.t("feedback.storeUnavailable"))
            return
        }
        let controller = FeedbackViewController(coordinator: feedbackCoordinator)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func openMyFeedback() {
        guard let feedbackCoordinator else {
            presentMessage(title: L10n.t("feedback.mine.entry"), message: L10n.t("feedback.storeUnavailable"))
            return
        }
        let controller = MyFeedbackViewController(coordinator: feedbackCoordinator)
        navigationController?.pushViewController(controller, animated: true)
    }

    /// 市场「采集省电建议」入口：定位到「我的 → 设置」的后台采集开关。
    func revealBackgroundCollectionSetting() {
        guard isViewLoaded else { return }
        view.layoutIfNeeded()
        let indexPath = IndexPath(row: 2, section: Section.settings.rawValue)
        tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
    }

    private func openAbout() {
        let about = AboutViewController(
            versionText: viewModel.appVersionText,
            baseURLText: viewModel.baseURLText,
            startupWarning: viewModel.startupWarning
        )
        navigationController?.pushViewController(about, animated: true)
    }

    // MARK: - Household

    private func openHousehold() {
        guard let viewModel = viewModel.makeHouseholdViewModel(),
              let roomStore,
              let savedDeviceStore,
              let householdService
        else {
            presentMessage(
                title: L10n.t("household.title"),
                message: L10n.t("household.empty")
            )
            return
        }
        let controller = HouseholdManagementViewController(
            viewModel: viewModel,
            roomStore: roomStore,
            savedDeviceStore: savedDeviceStore,
            householdService: householdService
        )
        navigationController?.pushViewController(controller, animated: true)
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
            title: L10n.t("profile.exportData"),
            message: L10n.t("profile.exportReading"),
            preferredStyle: .alert
        )
        present(progress, animated: true)

        viewModel.exportAccountData(progress: { [weak progress] count in
            progress?.message = count > 0 ? L10n.f("profile.exportProgress", String(describing: count)) : L10n.t("profile.exportReading")
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
            title: L10n.t("device.detail.exportFailed"),
            message: error.errorDescription ?? L10n.t("common.tryAgainLater"),
            preferredStyle: .alert
        )
        if error.isRetryable {
            alert.addAction(UIAlertAction(title: L10n.t("common.retry"), style: .default) { [weak self] _ in
                self?.exportAccountData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.t("common.ok"), style: .cancel))
        present(alert, animated: true)
    }

    private func confirmDeleteAccount() {
        let alert = UIAlertController(
            title: L10n.t("profile.deleteAccountTitle"),
            message: viewModel.accountDeletionConfirmationText,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("profile.deleteAccountAction"), style: .destructive) { [weak self] _ in
            self?.performDeleteAccount()
        })
        present(alert, animated: true)
    }

    private func performDeleteAccount() {
        guard !viewModel.isSyncing else {
            presentMessage(title: L10n.t("profile.deleteAccountBlocked"), message: L10n.t("profile.deleteAccountBlockedMessage"))
            return
        }
        let progress = UIAlertController(
            title: L10n.t("profile.deleteAccount"),
            message: L10n.t("profile.deleteAccountProgress"),
            preferredStyle: .alert
        )
        present(progress, animated: true)

        viewModel.deleteAccount { [weak self, weak progress] result in
            progress?.dismiss(animated: true) {
                guard let self else { return }
                switch result {
                case .success:
                    self.presentMessage(
                        title: L10n.t("profile.deleteAccountDone"),
                        message: L10n.t("profile.deleteAccountDoneMessage")
                    )
                case .failure(let error):
                    let alert = UIAlertController(
                        title: L10n.t("profile.deleteAccountFailed"),
                        message: error.errorDescription ?? L10n.t("common.tryAgainLater"),
                        preferredStyle: .alert
                    )
                    if error.isRetryable {
                        alert.addAction(UIAlertAction(title: L10n.t("common.retry"), style: .default) { [weak self] _ in
                            self?.performDeleteAccount()
                        })
                    }
                    alert.addAction(UIAlertAction(title: L10n.t("common.ok"), style: .cancel))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.t("common.ok"), style: .cancel))
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
        case .household: return 1
        case .sync: return 5 + (viewModel.needsRelogin ? 1 : 0)
        case .account: return 4
        case .alerts: return 3
        case .appearance: return 1
        case .settings: return 3
        case .support: return feedbackCoordinator == nil ? 1 : 3
        case .about: return 3
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .bluetooth: return L10n.t("profile.section.bluetooth")
        case .localData: return L10n.t("device.detail.sourceLocal")
        case .household: return L10n.t("profile.section.household")
        case .sync: return L10n.t("profile.section.sync")
        case .account: return L10n.t("profile.section.account")
        case .alerts: return L10n.t("profile.section.alerts")
        case .appearance: return L10n.t("profile.appearance")
        case .settings: return L10n.t("profile.section.settings")
        case .support: return L10n.t("profile.section.support")
        case .about: return L10n.t("profile.aboutShort")
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
            return L10n.t("profile.footnote.transfer")
        case .alerts:
            return viewModel.notificationGuidance
        case .appearance:
            return L10n.t("profile.footnote.appearance")
        case .settings:
            return "\(viewModel.backgroundCollectionStatusText)\n\(viewModel.backgroundCollectionGuidance)"
        case .support:
            return L10n.t("profile.footnote.support")
        case .about:
            return viewModel.startupWarning ?? L10n.t("profile.footnote.consistency")
        case .localData:
            return nil
        case .household:
            return L10n.t("household.rooms.serverNote")
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else { return UITableViewCell() }

        switch section {
        case .bluetooth:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: L10n.t("profile.bluetoothAuth"), value: viewModel.authorizationText)
            case 1:
                return makeValueCell(title: L10n.t("profile.bluetoothState"), value: viewModel.bluetoothStateText)
            default:
                return makeActionCell(
                    title: L10n.t("profile.openSettings"),
                    color: AppTheme.Palette.accent
                )
            }

        case .localData:
            if indexPath.row == 0 {
                return makeValueCell(
                    title: L10n.t("profile.scanLog"),
                    value: L10n.f("sync.pendingCount", String(describing: viewModel.logCount)),
                    showsDisclosure: true
                )
            }
            return makeActionCell(title: L10n.t("profile.clearScanLog"), color: AppTheme.Palette.promotion)

        case .household:
            return makeValueCell(
                title: L10n.t("household.manage"),
                value: viewModel.householdText,
                showsDisclosure: true
            )

        case .sync:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: L10n.t("profile.lastSync"), value: viewModel.lastSyncText)
            case 1:
                return makeValueCell(title: L10n.t("profile.pending"), value: viewModel.pendingUploadText)
            case 2:
                return makeActionCell(
                    title: viewModel.isSyncing ? L10n.t("profile.syncing") : L10n.t("profile.syncNow"),
                    color: viewModel.isSyncing ? AppTheme.Palette.secondaryText : AppTheme.Palette.accent
                )
            case 3:
                return makeValueCell(title: L10n.t("profile.anonymous"), value: viewModel.accountText)
            case 4:
                return makeValueCell(title: L10n.t("profile.sessionExpiry"), value: viewModel.sessionExpiryText)
            default:
                return makeActionCell(
                    title: viewModel.isSyncing ? L10n.t("profile.signingIn") : L10n.t("profile.relogin"),
                    color: AppTheme.Palette.accent
                )
            }

        case .account:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: L10n.t("transfer.code.title"), value: L10n.t("profile.generateTransferCode"), showsDisclosure: true)
            case 1:
                return makeValueCell(title: L10n.t("transfer.claim.title"), value: L10n.t("profile.enterTransferCode"), showsDisclosure: true)
            case 2:
                return makeActionCell(title: L10n.t("profile.exportData"), color: AppTheme.Palette.accent)
            default:
                return makeActionCell(title: L10n.t("profile.deleteAccount"), color: AppTheme.Palette.promotion)
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
                    title: L10n.t("profile.alertNotifications"),
                    isOn: viewModel.ruleAlertsEnabled
                ) { [weak self] isOn in
                    self?.viewModel.ruleAlertsEnabled = isOn
                }
                return cell
            }
            if indexPath.row == 1 {
                return makeValueCell(
                    title: L10n.t("profile.throttleWindow"),
                    value: viewModel.ruleAlertThrottleText,
                    showsDisclosure: true
                )
            }
            return makeValueCell(
                title: L10n.t("profile.notificationPermission"),
                value: viewModel.notificationAuthorizationText,
                showsDisclosure: viewModel.needsNotificationSettings
            )

        case .appearance:
            return makeValueCell(
                title: L10n.t("profile.appearance"),
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
                    title: L10n.t("profile.autoSaveScanned"),
                    isOn: viewModel.autoSaveRecentDevices
                ) { [weak self] isOn in
                    self?.viewModel.autoSaveRecentDevices = isOn
                }
            } else if indexPath.row == 1 {
                cell.configure(
                    title: L10n.t("profile.autoScanOnHome"),
                    isOn: viewModel.autoScanOnLaunch
                ) { [weak self] isOn in
                    self?.viewModel.autoScanOnLaunch = isOn
                }
            } else {
                cell.configure(
                    title: L10n.t("profile.backgroundCollection"),
                    isOn: viewModel.backgroundCollectionEnabled
                ) { [weak self] isOn in
                    self?.viewModel.backgroundCollectionEnabled = isOn
                }
            }
            return cell

        case .support:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: L10n.t("help.entry"), value: "", showsDisclosure: true)
            case 1:
                let pending = feedbackCoordinator?.pendingCount() ?? 0
                return makeValueCell(
                    title: L10n.t("feedback.entry"),
                    value: pending > 0 ? L10n.f("profile.feedbackPending", String(describing: pending)) : "",
                    showsDisclosure: true
                )
            default:
                return makeValueCell(
                    title: L10n.t("feedback.mine.entry"),
                    value: "",
                    showsDisclosure: true
                )
            }

        case .about:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: L10n.t("profile.appVersion"), value: viewModel.appVersionText)
            case 1:
                return makeValueCell(title: L10n.t("profile.baseURL"), value: viewModel.baseURLText)
            default:
                return makeValueCell(title: L10n.t("profile.about"), value: "", showsDisclosure: true)
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
        case .household:
            openHousehold()
        case .sync where indexPath.row == 2:
            viewModel.manualSync()
        case .sync where indexPath.row == 5:
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
        case .support where indexPath.row == 0:
            openHelpCenter()
        case .support where indexPath.row == 1:
            openFeedback()
        case .support where indexPath.row == 2:
            openMyFeedback()
        case .about where indexPath.row == 2:
            openAbout()
        default:
            break
        }
    }
}
