import UIKit

/// 房间管理：新建 / 重命名 / 删除房间。房间仅本机，删除前二次确认，房内设备回到未分配。
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

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("room.manage")
        view.backgroundColor = Palette.canvas

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.presentCreateAlert() }
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = L10n.t("room.create")
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
        emptyView.isHidden = !viewModel.rooms.isEmpty
        emptyView.configure(
            symbolName: "house",
            title: L10n.t("room.emptyTitle"),
            message: L10n.t("room.emptyMessage"),
            actionTitle: L10n.t("room.create")
        ) { [weak self] in
            self?.presentCreateAlert()
        }
        onChanged()
    }

    private func presentCreateAlert() {
        presentNameAlert(title: L10n.t("room.createTitle"), initial: "") { [weak self] name in
            guard let self else { return }
            if !self.viewModel.create(name: name) {
                self.presentError()
            }
        }
    }

    private func presentRenameAlert(for room: Room) {
        presentNameAlert(title: L10n.t("room.renameTitle"), initial: room.name) { [weak self] name in
            self?.viewModel.rename(id: room.id, name: name)
        }
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
            self?.viewModel.delete(id: room.id)
        })
        present(alert, animated: true)
    }

    private func presentError() {
        let alert = UIAlertController(
            title: L10n.t("room.saveFailedTitle"),
            message: viewModel.lastError?.localizedDescription,
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
        configuration.secondaryText = L10n.f("room.deviceCount", String(describing: viewModel.deviceCount(for: room)))
        configuration.textProperties.font = AppText.body.font()
        configuration.secondaryTextProperties.font = AppText.caption.font()
        cell.contentConfiguration = configuration
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityHint = L10n.t("room.renameHint")
        return cell
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        L10n.t("room.localOnlyNote")
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let room = viewModel.rooms[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L10n.t("common.delete")) { [weak self] _, _, completion in
            self?.confirmDelete(room)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

extension RoomManagementViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        presentRenameAlert(for: viewModel.rooms[indexPath.row])
    }
}
