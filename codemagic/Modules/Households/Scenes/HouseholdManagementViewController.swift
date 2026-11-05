import UIKit

/// 家庭管理：当前家庭与角色、成员、邀请码、房间、创建 / 邀请 / 加入 / 改名 / 退出。
/// owner 与 member 的入口按角色裁剪；服务端 403 / 409 只展示可读提示。
final class HouseholdManagementViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case current
        case members
        case invitations
        case rooms
        case actions
    }

    private enum RowAction {
        case create
        case join
        case invitation
        case rename
        case leave
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
        viewModel.refresh()
    }

    /// 角色裁剪：member 不显示邀请码分区。
    private var sections: [Section] {
        viewModel.showsInvitations ? Section.allCases : Section.allCases.filter { $0 != .invitations }
    }

    private func sectionType(at index: Int) -> Section? {
        guard index >= 0, index < sections.count else { return nil }
        return sections[index]
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

    private func presentRename() {
        guard viewModel.canManageHousehold, let current = viewModel.current else {
            ToastView.show(L10n.t("household.forbidden"), kind: .failure, in: self)
            return
        }
        let alert = UIAlertController(
            title: L10n.t("household.rename.title"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = current.name
            field.placeholder = L10n.t("household.create.placeholder")
            field.accessibilityIdentifier = "household.renameName"
        }
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("common.save"), style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            self?.viewModel.renameHousehold(name: name) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    ToastView.show(L10n.t("household.rename.done"), kind: .success, in: self)
                } else {
                    self.presentErrorIfNeeded()
                }
            }
        })
        present(alert, animated: true)
    }

    private func presentLeave() {
        guard viewModel.capabilities.canLeave else {
            ToastView.show(L10n.t("household.leave.personal"), kind: .info, in: self)
            return
        }
        // owner 且还有其他成员：本地直接给出可读提示，避免只展示服务端 message。
        if viewModel.capabilities.mustBlockOwnerLeave {
            ToastView.show(L10n.t("household.leave.ownerConflict"), kind: .failure, in: self)
            return
        }
        let isOwner = viewModel.capabilities.isOwner
        let alert = UIAlertController(
            title: L10n.t("household.leave.title"),
            message: isOwner ? L10n.t("household.leave.ownerMessage") : L10n.t("household.leave.memberMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("household.leave.action"), style: .destructive) { [weak self] _ in
            self?.viewModel.leaveHousehold { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    ToastView.show(L10n.t("household.leave.done"), kind: .success, in: self)
                } else {
                    self.presentErrorIfNeeded()
                }
            }
        })
        present(alert, animated: true)
    }

    /// 成员行操作：转让所有权与移除成员并列互斥；本人行不出现任何操作。
    private func presentMemberActions(_ member: HouseholdMember) {
        let canTransfer = viewModel.canTransfer(member: member)
        let canRemove = viewModel.canRemove(member: member)
        guard canTransfer || canRemove else { return }
        let sheet = UIAlertController(
            title: L10n.f("household.member.actions.title", member.shortID),
            message: nil,
            preferredStyle: .actionSheet
        )
        if canTransfer {
            sheet.addAction(UIAlertAction(
                title: L10n.t("household.transfer.action"),
                style: .default
            ) { [weak self] _ in
                self?.confirmTransferOwnership(member)
            })
        }
        if canRemove {
            sheet.addAction(UIAlertAction(
                title: L10n.t("household.member.remove.action"),
                style: .destructive
            ) { [weak self] _ in
                self?.confirmRemoveMember(member)
            })
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        presentSheet(sheet, source: nil)
    }

    private func confirmTransferOwnership(_ member: HouseholdMember) {
        let alert = UIAlertController(
            title: L10n.t("household.transfer.title"),
            message: L10n.f("household.transfer.message", member.shortID) + "\n\n" + viewModel.transferConsequence,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("household.transfer.action"), style: .destructive) {
            [weak self] _ in
            self?.viewModel.transferOwnership(to: member) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    ToastView.show(L10n.t("household.transfer.success"), kind: .success, in: self)
                } else {
                    self.presentErrorIfNeeded()
                }
            }
        })
        present(alert, animated: true)
    }

    private func confirmRemoveMember(_ member: HouseholdMember) {
        let alert = UIAlertController(
            title: L10n.t("household.member.remove.title"),
            message: L10n.f("household.member.remove.message", member.shortID),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("household.member.remove.action"), style: .destructive) {
            [weak self] _ in
            self?.viewModel.removeMember(member) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    ToastView.show(L10n.t("household.member.remove.done"), kind: .success, in: self)
                } else {
                    self.presentErrorIfNeeded()
                }
            }
        })
        present(alert, animated: true)
    }

    private func confirmRevoke(_ invitation: HouseholdInvitationInfo) {
        let alert = UIAlertController(
            title: L10n.t("household.invitation.revoke.title"),
            message: L10n.f("household.invitation.revoke.message", invitation.codeHashPrefix),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("household.invitation.revoke.action"), style: .destructive) {
            [weak self] _ in
            self?.viewModel.revokeInvitation(id: invitation.id) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    ToastView.show(L10n.t("household.invitation.revoke.done"), kind: .success, in: self)
                } else {
                    self.presentErrorIfNeeded()
                }
            }
        })
        present(alert, animated: true)
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
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = sectionType(at: section) else { return 0 }
        switch section {
        case .current:
            return viewModel.showsSwitcher ? 2 : 1
        case .members:
            return max(viewModel.members.count, 1)
        case .invitations:
            return viewModel.invitations.isEmpty ? 1 : viewModel.invitations.count
        case .rooms:
            return viewModel.rooms.count + 1
        case .actions:
            return actionRows.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = sectionType(at: section) else { return nil }
        switch section {
        case .current: return L10n.t("household.current")
        case .members: return L10n.t("household.members")
        case .invitations: return L10n.t("household.invitations")
        case .rooms: return L10n.t("household.rooms")
        case .actions: return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = sectionType(at: section) else { return nil }
        switch section {
        case .current:
            return viewModel.hasHousehold ? nil : L10n.t("household.empty")
        case .invitations:
            return L10n.t("household.invitations.note")
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

        guard let section = sectionType(at: indexPath.section) else { return cell }
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
                configuration.text = member.isCurrentUser
                    ? "\(member.shortID) · \(member.role.displayName) · \(L10n.t("household.member.me"))"
                    : "\(member.shortID) · \(member.role.displayName)"
                configuration.secondaryText = "\(member.kindDisplayName) · \(Self.dateFormatter.string(from: member.joinedAt))"
                cell.selectionStyle = .default
                cell.accessibilityLabel = configuration.text
            }
        case .invitations:
            if viewModel.invitations.isEmpty {
                configuration.text = L10n.t("household.invitations.empty")
                configuration.textProperties.color = AppTheme.Palette.secondaryText
            } else {
                let invitation = viewModel.invitations[indexPath.row]
                // 只展示哈希前缀与状态，界面不可能出现明文。
                configuration.text = "\(L10n.f("household.invitation.prefix", invitation.codeHashPrefix)) · \(invitation.status.displayName)"
                configuration.secondaryText = L10n.f(
                    "household.invitation.expires",
                    Self.dateTimeFormatter.string(from: invitation.expiresAt)
                )
                cell.selectionStyle = .default
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
            let action = actionRows[indexPath.row]
            configuration.text = action.title
            configuration.textProperties.color = AppTheme.Palette.accent
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = configuration
        return cell
    }

    /// 入口可见性：member 只看创建 / 加入；owner 额外有签发邀请码、改名、退出。
    private var actionRows: [(action: RowAction, title: String)] {
        var rows: [(RowAction, String)] = [
            (.create, L10n.t("household.create")),
            (.join, L10n.t("household.join")),
        ]
        if viewModel.canManageHousehold {
            rows.insert((.invitation, L10n.t("household.invitation.create")), at: 1)
            rows.append((.rename, L10n.t("household.rename")))
        }
        if viewModel.current?.canLeave == true {
            rows.append((.leave, L10n.t("household.leave")))
        }
        return rows
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - UITableViewDelegate

extension HouseholdManagementViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = sectionType(at: indexPath.section) else { return }
        switch section {
        case .current:
            if indexPath.row == 1 { presentSwitch() }
        case .members:
            guard !viewModel.members.isEmpty else { return }
            presentMemberActions(viewModel.members[indexPath.row])
        case .invitations:
            guard !viewModel.invitations.isEmpty else { return }
            confirmRevoke(viewModel.invitations[indexPath.row])
        case .rooms:
            if indexPath.row == 0 { presentRoomManagement() }
        case .actions:
            switch actionRows[indexPath.row].action {
            case .create: presentCreateHousehold()
            case .join: presentJoin()
            case .invitation: presentInvitation()
            case .rename: presentRename()
            case .leave: presentLeave()
            }
        }
    }

    /// 成员支持左滑转让 / 移除（均二次确认）；本人行不出现任何操作。
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let section = sectionType(at: indexPath.section), section == .members,
              !viewModel.members.isEmpty
        else { return nil }
        let member = viewModel.members[indexPath.row]
        var actions: [UIContextualAction] = []
        if viewModel.canTransfer(member: member) {
            let transfer = UIContextualAction(
                style: .normal,
                title: L10n.t("household.transfer.action")
            ) { [weak self] _, _, completion in
                self?.confirmTransferOwnership(member)
                completion(true)
            }
            transfer.backgroundColor = AppTheme.Palette.accent
            actions.append(transfer)
        }
        if viewModel.canRemove(member: member) {
            let remove = UIContextualAction(
                style: .destructive,
                title: L10n.t("household.member.remove.action")
            ) { [weak self] _, _, completion in
                self?.confirmRemoveMember(member)
                completion(true)
            }
            actions.append(remove)
        }
        guard !actions.isEmpty else { return nil }
        return UISwipeActionsConfiguration(actions: actions)
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
