import UIKit

/// 设备详情：展示本地设备信息、云端厂商/固件/GATT/兼容性，网络失败时展示缓存。
final class DeviceDetailViewController: UIViewController {
    private struct Row {
        let title: String
        let value: String
    }

    private struct SectionModel {
        let title: String?
        let rows: [Row]
    }

    // MARK: - Subviews

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyStateView = EmptyStateView()
    private let headerView = UIView()
    private let statusLabel = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.secondaryText)
    private let noticeLabel = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.highlight)
    private var sections: [SectionModel] = []

    // MARK: - Dependencies

    private let viewModel: DeviceDetailViewModel

    // MARK: - Init

    init(viewModel: DeviceDetailViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = viewModel.device.displayName
        view.backgroundColor = AppTheme.Palette.background
        configureTableView()
        configureHeader()
        configureNavigationItems()

        viewModel.onChange = { [weak self] in
            self?.reloadContent()
        }
        reloadContent()
        viewModel.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        viewModel.teardown()
    }

    // MARK: - Configuration

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DetailCell")
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureHeader() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.numberOfLines = 0
        headerView.addSubview(statusLabel)
        headerView.addSubview(noticeLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),

            noticeLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            noticeLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            noticeLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            noticeLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -8),
        ])
        tableView.tableHeaderView = headerView
    }

    private func configureNavigationItems() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "重试",
            style: .plain,
            target: self,
            action: #selector(handleRetry)
        )
    }

    // MARK: - Content

    private func reloadContent() {
        sections = buildSections()
        statusLabel.text = viewModel.statusText
        noticeLabel.text = viewModel.notice
        noticeLabel.isHidden = viewModel.notice == nil

        navigationItem.rightBarButtonItem?.isEnabled = !viewModel.isLoading
        updateHeaderHeight()
        updateEmptyState()
        tableView.reloadData()
    }

    private func buildSections() -> [SectionModel] {
        let device = viewModel.device
        var sections: [SectionModel] = []

        var localRows: [Row] = [
            // 展示顺序：用户别名 → 广播名 → 型号名/型号键，见 SavedDevice.displayName。
            Row(title: "显示名称", value: device.displayName),
            Row(title: "用户别名", value: device.remark.isEmpty ? "—" : device.remark),
            Row(title: "广播名", value: device.advertisedName.isEmpty ? "—" : device.advertisedName),
            Row(title: "分组", value: device.groupName),
            Row(title: "标识符", value: device.peripheralID.uuidString),
            Row(
                title: "最近出现",
                value: device.lastSeenAt.map { AppDateFormat.absolute($0) } ?? "尚无扫描记录"
            ),
        ]

        if let product = viewModel.product {
            localRows.append(Row(title: "厂商", value: product.vendor.isEmpty ? "—" : product.vendor))
            // 未注册型号时 deviceType 为 null：显示「型号未知」，不影响别名 / 分组 / 最近出现。
            localRows.append(
                Row(title: "型号", value: product.deviceType.isEmpty ? "型号未知" : product.deviceType)
            )
            localRows.append(
                Row(title: "固件版本", value: product.firmwareVersion.isEmpty ? "—" : product.firmwareVersion)
            )
            localRows.append(Row(title: "MAC", value: product.mac.isEmpty ? "—" : product.mac))
        }
        sections.append(SectionModel(title: "设备信息", rows: localRows))

        if let product = viewModel.product {
            if !product.gattServices.isEmpty {
                let serviceRows = product.gattServices.map {
                    Row(title: $0.name.isEmpty ? "未命名服务" : $0.name, value: $0.uuid)
                }
                sections.append(SectionModel(title: "GATT 服务与特征", rows: serviceRows))
            }

            let compatibilityValue = product.compatibility.isEmpty
                ? "暂无兼容性说明"
                : product.compatibility.joined(separator: "；")
            sections.append(
                SectionModel(
                    title: "兼容性",
                    rows: [Row(title: "兼容设备 / 固件", value: compatibilityValue)]
                )
            )

            if !product.note.isEmpty {
                sections.append(
                    SectionModel(title: "云端记录", rows: [Row(title: "同步信息", value: product.note)])
                )
            }
        }

        return sections
    }

    private func updateHeaderHeight() {
        let width = max(tableView.bounds.width, view.bounds.width)
        guard width > 0 else { return }
        headerView.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let size = headerView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        headerView.frame.size.height = size.height
        tableView.tableHeaderView = headerView
    }

    private func updateEmptyState() {
        if viewModel.product != nil {
            tableView.backgroundView = nil
            return
        }

        let message: String
        let title: String
        switch viewModel.state {
        case .failed(let error):
            title = "设备信息读取失败"
            message = "\(error.localizedDescriptionText)。请确认本地 Go 服务或线上接口可用。"
        case .connecting, .loadingInfo:
            title = "正在读取设备信息"
            message = "连接蓝牙后将从服务端拉取厂商与固件版本，失败时会回退到本地缓存。"
        case .idle:
            title = "尚未读取"
            message = "点击右上角重试。"
        case .loaded, .cache:
            title = ""
            message = ""
        }

        emptyStateView.configure(
            symbolName: SymbolName.device,
            title: title,
            message: message,
            actionTitle: "重试",
            action: { [weak self] in self?.viewModel.retry() }
        )
        tableView.backgroundView = emptyStateView
    }

    // MARK: - Actions

    @objc private func handleRetry() {
        viewModel.retry()
    }
}

// MARK: - UITableViewDataSource

extension DeviceDetailViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DetailCell", for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]

        var configuration = cell.defaultContentConfiguration()
        configuration.text = row.title
        configuration.secondaryText = row.value
        configuration.secondaryTextProperties.color = AppTheme.Palette.secondaryText
        configuration.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = configuration
        cell.selectionStyle = .none
        return cell
    }
}
