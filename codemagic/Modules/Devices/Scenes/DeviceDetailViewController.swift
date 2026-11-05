import UIKit

/// 设备详情：展示本地设备信息、云端厂商/固件/GATT/兼容性、本地读数图表与汇总。
final class DeviceDetailViewController: UIViewController {
    private enum RowKind: Equatable {
        case value
        case range
        case chart(
            buckets: [ReadingsChartBucket],
            interval: DateInterval,
            unit: String,
            rangeTitle: String,
            metricName: String
        )
        case metricPicker
        case export
        case emptyState
    }

    private struct Row {
        let title: String
        let value: String
        var kind: RowKind = .value

        init(title: String, value: String, kind: RowKind = .value) {
            self.title = title
            self.value = value
            self.kind = kind
        }
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
    private var exportProgressAlert: UIAlertController?

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 详情页可见才允许远端合并刷新；不可见时只做本地重绘。
        viewModel.setVisible(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        viewModel.setVisible(false)
        viewModel.teardown()
    }

    @objc private func handleForeground() {
        guard view.window != nil else { return }
        viewModel.setVisible(true)
    }

    /// 进入后台时停止远端刷新，避免在后台继续打接口；回到前台再补一次。
    @objc private func handleBackground() {
        viewModel.setVisible(false)
    }

    // MARK: - Configuration

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DetailCell")
        tableView.register(ReadingsChartCell.self, forCellReuseIdentifier: ReadingsChartCell.reuseIdentifier)
        tableView.register(ReadingsRangeCell.self, forCellReuseIdentifier: ReadingsRangeCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
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
        sections.append(makeDataSection())

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

    /// 「数据」区：区间切换 → 指标选择 → 时间比例折线图 → 24h 汇总 → 来源 → 最近记录。
    /// 没有读数时只保留一条真实空状态，不渲染空图表、不造数据。
    private func makeDataSection() -> SectionModel {
        let state = viewModel.readings
        guard !state.metricInfos.isEmpty else {
            return SectionModel(
                title: "数据",
                rows: [Row(title: "暂无读数", value: viewModel.readingsEmptyMessage, kind: .emptyState)]
            )
        }

        var rows: [Row] = [
            Row(title: "区间", value: state.selectedRange.title, kind: .range),
            Row(
                title: "指标",
                value: state.selectedMetric.map { viewModel.metricTitle(for: $0) } ?? "未选择",
                kind: .metricPicker
            ),
            Row(
                title: "\(state.selectedRange.title) 走势",
                value: state.hasData
                    ? "\(state.buckets.count) 个时间桶 · \(state.metricCount) 条"
                    : "暂无读数",
                kind: .chart(
                    buckets: state.buckets,
                    interval: state.interval,
                    unit: state.unit,
                    rangeTitle: state.selectedRange.title,
                    metricName: state.selectedMetric?.displayName ?? ""
                )
            ),
        ]

        if let summary = state.summary, summary.count > 0 {
            let unit = summary.unit.isEmpty ? state.unit : summary.unit
            rows.append(Row(title: "24 小时 · 最小", value: formatted(summary.minValue, unit: unit)))
            rows.append(Row(title: "24 小时 · 最大", value: formatted(summary.maxValue, unit: unit)))
            rows.append(Row(title: "24 小时 · 平均", value: formatted(summary.avg, unit: unit)))
            rows.append(Row(title: "24 小时 · 最新", value: formatted(summary.last, unit: unit)))
            rows.append(Row(title: "24 小时 · 条数", value: "\(summary.count) 条"))
        } else {
            rows.append(Row(title: "24 小时汇总", value: "暂无 24 小时内的读数"))
        }

        rows.append(Row(title: "数据来源", value: state.sourceText))

        if let metric = state.selectedMetric {
            rows.append(
                Row(
                    title: "导出 CSV",
                    value: "\(metric.displayName) · \(state.selectedRange.title) · 当前设备",
                    kind: .export
                )
            )
        }

        if state.recent.isEmpty {
            rows.append(Row(title: "最近记录", value: "暂无记录"))
        } else {
            for reading in state.recent {
                rows.append(
                    Row(
                        title: AppDateFormat.absolute(reading.recordedAt),
                        value: reading.displayText
                    )
                )
            }
        }
        return SectionModel(title: "数据", rows: rows)
    }

    private func formatted(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return unit.isEmpty ? text : "\(text) \(unit)"
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
        let row = sections[indexPath.section].rows[indexPath.row]

        switch row.kind {
        case .range:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: ReadingsRangeCell.reuseIdentifier,
                for: indexPath
            ) as? ReadingsRangeCell else {
                return UITableViewCell()
            }
            cell.configure(selected: viewModel.readings.selectedRange)
            cell.onSelect = { [weak self] range in
                self?.viewModel.selectReadingsRange(range)
            }
            return cell

        case .chart(let buckets, let interval, let unit, let rangeTitle, let metricName):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: ReadingsChartCell.reuseIdentifier,
                for: indexPath
            ) as? ReadingsChartCell else {
                return UITableViewCell()
            }
            cell.configure(
                buckets: buckets,
                interval: interval,
                unit: unit,
                rangeTitle: rangeTitle,
                metricName: metricName
            )
            return cell

        case .metricPicker:
            let cell = makeDetailCell(row: row, secondaryText: row.value)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell

        case .export:
            let cell = makeDetailCell(row: row, secondaryText: row.value)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell

        case .emptyState:
            return makeDetailCell(row: row, secondaryText: nil)

        case .value:
            let cell = makeDetailCell(row: row, secondaryText: row.value)
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
    }

    private func makeDetailCell(row: Row, secondaryText: String?) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DetailCell")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "DetailCell")
        var configuration = cell.defaultContentConfiguration()
        configuration.text = row.title
        configuration.secondaryText = secondaryText
        configuration.secondaryTextProperties.color = AppTheme.Palette.secondaryText
        configuration.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = configuration
        return cell
    }
}

// MARK: - UITableViewDelegate

extension DeviceDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        switch row.kind {
        case .metricPicker:
            presentMetricPicker()
        case .export:
            guard let metric = viewModel.readings.selectedMetric else { return }
            startExport(range: viewModel.readings.selectedRange, metric: metric)
        default:
            break
        }
    }

    // MARK: - Export

    /// 导出当前设备 + 指标 + 区间；进度显示真实已读取条数，失败可直接重试。
    private func startExport(range: ReadingsRange, metric: ReadingMetric) {
        guard exportProgressAlert == nil else { return }

        let alert = UIAlertController(
            title: "正在导出 CSV",
            message: "已读取 0 条…",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.exportProgressAlert = nil
        })
        present(alert, animated: true)
        exportProgressAlert = alert

        viewModel.exportReadings(
            range: range,
            metric: metric,
            progress: { [weak self] count in
                self?.exportProgressAlert?.message = "已读取 \(count) 条…"
            },
            completion: { [weak self] result in
                guard let self, self.exportProgressAlert != nil else { return }
                self.exportProgressAlert?.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    self.exportProgressAlert = nil
                    switch result {
                    case .success(let url):
                        self.shareCSV(at: url)
                    case .failure(let error):
                        self.presentExportError(error, range: range, metric: metric)
                    }
                }
            }
        )
    }

    private func shareCSV(at url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.viewModel.removeExportedFile(at: url)
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.bounds
        }
        present(controller, animated: true)
    }

    private func presentExportError(
        _ error: ReadingsExportError,
        range: ReadingsRange,
        metric: ReadingMetric
    ) {
        let alert = UIAlertController(
            title: "导出失败",
            message: error.errorDescription ?? "未知错误",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            self?.startExport(range: range, metric: metric)
        })
        present(alert, animated: true)
    }

    private func presentMetricPicker() {
        let metrics = viewModel.readings.metrics
        guard metrics.count > 1 else { return }
        let sheet = UIAlertController(title: "选择指标", message: nil, preferredStyle: .actionSheet)
        for metric in metrics {
            let isSelected = metric == viewModel.readings.selectedMetric
            let title = viewModel.metricTitle(for: metric)
            sheet.addAction(
                UIAlertAction(title: isSelected ? "✓ \(title)" : title, style: .default) {
                    [weak self] _ in
                    self?.viewModel.selectReadingsMetric(metric)
                }
            )
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: 0, section: 0))
        }
        present(sheet, animated: true)
    }
}
