import UIKit

/// 家庭管理：当前家庭与角色、成员列表、房间、创建 / 邀请 / 加入。
/// 只读成员隐藏写入口；服务端 403 只展示可读提示。
final class HouseholdManagementViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case current
        case members
        case rooms
        case actions
    }

    private let viewModel: HouseholdManagementViewModel
    private let roomStore: RoomStore
    private let savedDeviceStore: SavedDeviceStore
    private let householdService: HouseholdService
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(
        viewModel: HouseholdManagementViewModel,
        roomStore: RoomStore,
        savedDeviceStore: SavedDeviceStore,
        householdService: HouseholdService
    ) {
        self.viewModel = viewModel
        self.roomStore = roomStore
        self.savedDeviceStore = savedDeviceStore
        self.householdService = householdService
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("household.title")
        view.backgroundColor = AppTheme.Palette.background
        configureTableView()
        viewModel.onChange = { [weak self] in
            self?.tableView.reloadData()
            self?.tableView.refreshControl?.endRefreshing()
            self?.presentErrorIfNeeded()
        }
        viewModel.reload()
    }

    private func configureTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(refresh), for: .valueChanged)
        tableView.refreshControl = control
    }

    @objc private func refresh() {
        viewModel.reload()
    }

    // MARK: - Actions

    private func presentCreateHousehold() {
        let alert = UIAlertController(
            title: L10n.t("household.create.title"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = L10n.t("household.create.placeholder")
            field.autocapitalizationType = .sentences
            field.accessibilityIdentifier = "household.createName"
        }
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("household.create.action"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = alert?.textFields?.first?.text ?? ""
            self.viewModel.createHousehold(name: name) { [weak self] succeeded in
                guard let self, !succeeded else { return }
                self.presentErrorIfNeeded()
            }
        })
        present(alert, animated: true)
    }

    private func presentInvitation() {
        guard viewModel.hasHousehold else {
            ToastView.show(L10n.t("household.empty"), kind: .info, in: self)
            return
        }
        navigationController?.pushViewController(
            HouseholdInvitationViewController(viewModel: viewModel),
            animated: true
        )
    }

    private func presentJoin() {
        let claimViewModel = HouseholdClaimViewModel(service: householdService)
        let controller = HouseholdClaimViewController(viewModel: claimViewModel) { [weak self] in
            self?.viewModel.reload()
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func presentSwitch() {
        let sheet = UIAlertController(title: L10n.t("household.switch.title"), message: nil, preferredStyle: .actionSheet)
        for household in viewModel.households {
            let title = household.id == viewModel.current?.id
                ? "✓ \(household.name) · \(household.role.displayName)"
                : "\(household.name) · \(household.role.displayName)"
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.viewModel.switchHousehold(localID: household.id)
            })
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        presentSheet(sheet, source: nil)
    }

    private func presentRoomManagement() {
        let roomViewModel = RoomManagementViewModel(
            roomStore: roomStore,
            deviceStore: savedDeviceStore,
            householdService: householdService
        )
        let roomController = RoomManagementViewController(viewModel: roomViewModel) { [weak self] in
            self?.viewModel.reload()
        }
        let navigation = UINavigationController(rootViewController: roomController)
        present(navigation, animated: true) { [weak self] in
            self?.viewModel.reload()
        }
    }

    private func presentErrorIfNeeded() {
        guard let message = viewModel.errorMessage else { return }
        ToastView.show(message, kind: .failure, in: self)
    }
}

// MARK: - UITableViewDataSource

extension HouseholdManagementViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .current:
            return viewModel.showsSwitcher ? 2 : 1
        case .members:
            return max(viewModel.members.count, 1)
        case .rooms:
            return max(viewModel.rooms.count, 0) + 1
        case .actions:
            return viewModel.canManageRooms ? 2 : 1
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .current: return L10n.t("household.current")
        case .members: return L10n.t("household.members")
        case .rooms: return L10n.t("household.rooms")
        case .actions: return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .current:
            return viewModel.hasHousehold ? nil : L10n.t("household.empty")
        case .rooms:
            return viewModel.canManageRooms
                ? L10n.t("household.rooms.serverNote")
                : L10n.t("household.permission.memberNote")
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var configuration = cell.defaultContentConfiguration()
        configuration.textProperties.font = AppText.body.font()
        configuration.secondaryTextProperties.font = AppText.caption.font()
        cell.accessoryType = .none
        cell.selectionStyle = .none

        guard let section = Section(rawValue: indexPath.section) else { return cell }
        switch section {
        case .current:
            if indexPath.row == 0 {
                configuration.text = viewModel.current?.name ?? L10n.t("household.empty")
                configuration.secondaryText = viewModel.currentSubtitle
            } else {
                configuration.text = L10n.t("household.switch")
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }
        case .members:
            if viewModel.members.isEmpty {
                configuration.text = viewModel.isRefreshing
                    ? L10n.t("common.loading")
                    : L10n.t("household.members.empty")
                configuration.textProperties.color = AppTheme.Palette.secondaryText
            } else {
                let member = viewModel.members[indexPath.row]
                configuration.text = "\(member.shortID) · \(member.role.displayName)"
                configuration.secondaryText = "\(member.kindDisplayName) · \(Self.dateFormatter.string(from: member.joinedAt))"
            }
        case .rooms:
            if indexPath.row == 0 {
                configuration.text = L10n.t("room.manage")
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            } else {
                let room = viewModel.rooms[indexPath.row - 1]
                configuration.text = room.name
                configuration.secondaryText = viewModel.roomSubtitle(for: room)
            }
        case .actions:
            let actions = actionTitles()
            configuration.text = actions[indexPath.row]
            configuration.textProperties.color = AppTheme.Palette.accent
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = configuration
        return cell
    }

    private func actionTitles() -> [String] {
        var titles = [L10n.t("household.create"), L10n.t("household.join")]
        if viewModel.canManageRooms {
            titles.insert(L10n.t("household.invitation.create"), at: 1)
        }
        return titles
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - UITableViewDelegate

extension HouseholdManagementViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }
        switch section {
        case .current:
            if indexPath.row == 1 { presentSwitch() }
        case .rooms:
            if indexPath.row == 0 { presentRoomManagement() }
        case .actions:
            let title = actionTitles()[indexPath.row]
            if title == L10n.t("household.create") {
                presentCreateHousehold()
            } else if title == L10n.t("household.invitation.create") {
                presentInvitation()
            } else {
                presentJoin()
            }
        case .members:
            break
        }
    }
}

// MARK: - Sheet helper

private extension UIViewController {
    /// iPad / 常规宽度下 action sheet 需要 sourceView，避免崩溃。
    func presentSheet(_ sheet: UIAlertController, source: UIView?) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source ?? view
            popover.sourceRect = source?.bounds ?? CGRect(
                x: view.bounds.midX,
                y: view.bounds.maxY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }
}
