import UIKit

/// 房间管理：新建 / 重命名 / 删除房间。接入家庭后写服务端，离线落本机并标注未同步；
/// member 只读，服务端 403 降级为可读提示。
final class RoomManagementViewController: UIViewController {
    private let viewModel: RoomManagementViewModel
    private let onChanged: () -> Void
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyView = EmptyStateView()

    init(viewModel: RoomManagementViewModel, onChanged: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onChanged = onChanged
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
        title = L10n.t("room.manage")
        view.backgroundColor = Palette.canvas

        let createItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.presentCreateAlert() }
        )
        createItem.accessibilityLabel = L10n.t("room.create")
        createItem.isEnabled = viewModel.canManageRooms
        let sortItem = UIBarButtonItem(
            title: L10n.t("household.room.sort"),
            primaryAction: UIAction { [weak self] _ in self?.toggleSorting() }
        )
        sortItem.accessibilityIdentifier = "room.sortToggle"
        navigationItem.rightBarButtonItems = [createItem, sortItem]
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.t("common.done"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "RoomCell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        emptyView.isHidden = true
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        viewModel.onChange = { [weak self] in self?.reload() }
        viewModel.reload()
    }

    private func reload() {
        tableView.reloadData()
        navigationItem.rightBarButtonItems?.first?.isEnabled = viewModel.canManageRooms
        navigationItem.rightBarButtonItems?.last?.isEnabled = viewModel.canReorder
        if !viewModel.canReorder {
            setSorting(false)
        }
        emptyView.isHidden = !viewModel.rooms.isEmpty
        emptyView.configure(
            symbolName: "house",
            title: L10n.t("room.emptyTitle"),
            message: viewModel.footnoteText,
            actionTitle: viewModel.canManageRooms ? L10n.t("room.create") : nil
        ) { [weak self] in
            self?.presentCreateAlert()
        }
        presentNoticeIfNeeded()
        onChanged()
    }

    /// 上下移动 / 拖拽排序入口：进入编辑态后行可拖动，再次点击结束。
    private func toggleSorting() {
        guard viewModel.canReorder else {
            ToastView.show(L10n.t("household.permission.memberNote"), kind: .info, in: self)
            return
        }
        setSorting(!tableView.isEditing)
    }

    private func setSorting(_ editing: Bool) {
        tableView.setEditing(editing, animated: true)
        navigationItem.rightBarButtonItems?.last?.title = editing
            ? L10n.t("household.room.sortDone")
            : L10n.t("household.room.sort")
    }

    /// 409 重排冲突：服务层已重新拉取，这里只提示结果。
    private func presentNoticeIfNeeded() {
        guard let notice = viewModel.lastNotice else { return }
        ToastView.show(notice, kind: .info, in: self)
        viewModel.clearNotice()
    }

    private func presentCreateAlert() {
        guard viewModel.canManageRooms else {
            presentPermissionNotice()
            return
        }
        presentNameAlert(title: L10n.t("room.createTitle"), initial: "") { [weak self] name in
            guard let self else { return }
            self.viewModel.create(name: name) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    self.presentPendingNoticeIfNeeded()
                } else {
                    self.presentError()
                }
            }
        }
    }

    private func presentRenameAlert(for room: Room) {
        guard viewModel.canManageRooms else {
            presentPermissionNotice()
            return
        }
        presentNameAlert(title: L10n.t("room.renameTitle"), initial: room.name) { [weak self] name in
            guard let self else { return }
            self.viewModel.rename(id: room.id, name: name)
            if let error = self.viewModel.lastError {
                let alert = UIAlertController(title: L10n.t("room.saveFailedTitle"), message: error, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.t("common.ok"), style: .default))
                self.present(alert, animated: true)
            } else {
                self.presentPendingNoticeIfNeeded()
            }
        }
    }

    /// 403 降级为可读提示，不弹错误码、不整页报错。
    private func presentPermissionNotice() {
        let alert = UIAlertController(
            title: L10n.t("household.notOwner"),
            message: L10n.t("household.forbidden"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.ok"), style: .default))
        present(alert, animated: true)
    }

    private func presentPendingNoticeIfNeeded() {
        guard viewModel.lastNotice != nil else { return }
        ToastView.show(L10n.t("household.assignment.pending"), kind: .info, in: self)
    }

    private func presentNameAlert(title: String, initial: String, onSave: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initial
            field.placeholder = L10n.t("room.namePlaceholder")
        }
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("common.save"), style: .default) { [weak alert] _ in
            onSave(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    private func confirmDelete(_ room: Room) {
        let alert = UIAlertController(
            title: L10n.f("room.deleteTitle", room.name),
            message: L10n.t("room.deleteMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.t("common.delete"), style: .destructive) { [weak self] _ in
            self?.viewModel.delete(id: room.id) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    self.presentPendingNoticeIfNeeded()
                } else {
                    self.presentError()
                }
            }
        })
        present(alert, animated: true)
    }

    private func presentError() {
        let alert = UIAlertController(
            title: L10n.t("room.saveFailedTitle"),
            message: viewModel.lastError,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("common.ok"), style: .default))
        present(alert, animated: true)
    }
}

extension RoomManagementViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.rooms.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RoomCell", for: indexPath)
        let room = viewModel.rooms[indexPath.row]
        var configuration = cell.defaultContentConfiguration()
        configuration.text = room.name
        let countText = L10n.f("room.deviceCount", String(describing: viewModel.deviceCount(for: room)))
        configuration.secondaryText = room.syncState == .synced
            ? countText
            : "\(countText) · \(L10n.t("household.room.unsynced"))"
        configuration.textProperties.font = AppText.body.font()
        configuration.secondaryTextProperties.font = AppText.caption.font()
        cell.contentConfiguration = configuration
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityHint = L10n.t("room.renameHint")
        return cell
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        viewModel.footnoteText
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard viewModel.canManageRooms, !tableView.isEditing else { return nil }
        let room = viewModel.rooms[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L10n.t("common.delete")) { [weak self] _, _, completion in
            self?.confirmDelete(room)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    /// 非拖拽场景的上下移动入口（owner 可见）。
    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard viewModel.canReorder, !tableView.isEditing else { return nil }
        var actions: [UIContextualAction] = []
        if indexPath.row > 0 {
            let up = UIContextualAction(style: .normal, title: L10n.t("household.room.moveUp")) {
                [weak self] _, _, completion in
                self?.viewModel.moveUp(index: indexPath.row)
                completion(true)
            }
            up.backgroundColor = AppTheme.Palette.accent
            actions.append(up)
        }
        if indexPath.row < viewModel.rooms.count - 1 {
            let down = UIContextualAction(style: .normal, title: L10n.t("household.room.moveDown")) {
                [weak self] _, _, completion in
                self?.viewModel.moveDown(index: indexPath.row)
                completion(true)
            }
            down.backgroundColor = AppTheme.Palette.secondaryText
            actions.append(down)
        }
        return actions.isEmpty ? nil : UISwipeActionsConfiguration(actions: actions)
    }
}

extension RoomManagementViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !tableView.isEditing else { return }
        presentRenameAlert(for: viewModel.rooms[indexPath.row])
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        viewModel.canReorder && viewModel.rooms[indexPath.row].remoteID != nil
    }

    /// 拖拽落位后整段提交；失败 / 409 由服务层与 reload 统一处理。
    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        viewModel.moveRoom(from: sourceIndexPath.row, to: destinationIndexPath.row)
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }
}
