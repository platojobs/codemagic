import UIKit

/// 产品详情：字段与设备信息契约一致，展示类型说明、可解析指标、GATT 表、
/// 兼容性/固件，以及本机同类型设备。
final class ProductDetailViewController: UIViewController {
    private struct Row {
        let title: String
        let value: String
    }

    private struct SectionModel {
        let title: String
        let rows: [Row]
        let footer: String?
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let product: ProductModel
    private let savedDeviceStore: SavedDeviceStore?
    private var sections: [SectionModel] = []

    init(product: ProductModel, savedDeviceStore: SavedDeviceStore? = nil) {
        self.product = product
        self.savedDeviceStore = savedDeviceStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = product.deviceType.isEmpty ? L10n.t("product.detail.title") : product.deviceType
        view.backgroundColor = AppTheme.Palette.background
        sections = buildSections()

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProductDetailCell")
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

    private func buildSections() -> [SectionModel] {
        let profile = MarketInsights.profile(from: product)

        var basicRows = [
            Row(title: L10n.t("device.detail.vendor"), value: product.vendor.isEmpty ? "—" : product.vendor),
            Row(title: L10n.t("catalog.model"), value: product.deviceType.isEmpty ? "—" : product.deviceType),
            Row(title: L10n.t("device.detail.firmwareVersion"), value: profile.firmwareText),
            Row(title: "MAC", value: product.mac.isEmpty ? "—" : product.mac),
        ]
        if !product.note.isEmpty {
            basicRows.append(Row(title: L10n.t("product.detail.description"), value: product.note))
        }
        let basic = SectionModel(
            title: L10n.t("product.detail.basicInfo"),
            rows: basicRows,
            footer: nil
        )

        let capability = SectionModel(
            title: L10n.t("product.detail.capability"),
            rows: [
                Row(title: L10n.t("product.detail.type"), value: profile.category.title),
                Row(title: L10n.t("product.detail.typeDetail"), value: profile.category.detail),
                Row(title: L10n.t("product.detail.metrics"), value: profile.metricsText),
                Row(
                    title: L10n.t("product.detail.limitations"),
                    value: profile.declaredLimitations == nil && profile.limitations.isEmpty
                        ? L10n.t("common.none")
                        : profile.limitationsText
                ),
            ],
            footer: L10n.t("product.detail.capabilityFooter")
        )

        var gattRows: [Row] = []
        if product.gattServices.isEmpty {
            gattRows = [Row(title: L10n.t("product.detail.gatt"), value: L10n.t("common.noData"))]
        } else {
            for service in product.gattServices {
                gattRows.append(Row(
                    title: service.name.isEmpty ? L10n.t("device.detail.unnamedService") : service.name,
                    value: service.uuid
                ))
                for characteristic in service.characteristics {
                    gattRows.append(Row(title: L10n.t("product.detail.characteristics"), value: characteristic))
                }
            }
        }
        let gatt = SectionModel(title: L10n.t("device.detail.gatt"), rows: gattRows, footer: nil)

        let compatibility = SectionModel(
            title: L10n.t("device.detail.compatibility"),
            rows: [
                Row(
                    title: L10n.t("device.detail.compatibleDevices"),
                    value: product.compatibility.isEmpty
                        ? L10n.t("device.detail.noCompatibility")
                        : product.compatibility.joined(separator: L10n.t("common.listSeparator"))
                ),
                Row(title: L10n.t("product.detail.firmware"), value: profile.firmwareText),
            ],
            footer: nil
        )

        return [basic, capability, gatt, compatibility] + myDevicesSections(for: profile)
    }

    /// 本机已保存设备中型号名相同的设备。无数据时整段省略，不展示空占位。
    private func myDevicesSections(for profile: DeviceCompatibilityProfile) -> [SectionModel] {
        guard let savedDeviceStore, let devices = try? savedDeviceStore.fetchAll() else { return [] }
        let matched = devices.filter { device in
            let deviceType = device.deviceType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !deviceType.isEmpty && deviceType == product.deviceType
        }
        guard !matched.isEmpty else { return [] }
        let rows = matched.map { device in
            Row(
                title: device.displayName,
                value: device.isConnectable
                    ? L10n.t("product.detail.myDeviceLocal")
                    : L10n.f("product.detail.myDeviceRemote", device.platformDisplayName)
            )
        }
        return [
            SectionModel(
                title: L10n.f("product.detail.myDevices", profile.category.title),
                rows: rows,
                footer: L10n.t("product.detail.myDevicesFooter")
            )
        ]
    }
}

extension ProductDetailViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ProductDetailCell", for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]
        var configuration = cell.defaultContentConfiguration()
        configuration.text = row.title
        configuration.secondaryText = row.value
        configuration.secondaryTextProperties.color = AppTheme.Palette.secondaryText
        configuration.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = configuration
        cell.selectionStyle = .none
        cell.accessibilityLabel = [row.title, row.value].joined(separator: L10n.t("common.a11ySeparator"))
        return cell
    }
}
