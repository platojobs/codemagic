import UIKit

/// 产品详情：字段与设备信息契约一致，展示 GATT 表与兼容性说明。
final class ProductDetailViewController: UIViewController {
    private struct Row {
        let title: String
        let value: String
    }

    private struct SectionModel {
        let title: String
        let rows: [Row]
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let product: ProductModel
    private var sections: [SectionModel] = []

    init(product: ProductModel) {
        self.product = product
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = product.deviceType.isEmpty ? "产品详情" : product.deviceType
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
        var basicRows = [
            Row(title: "厂商", value: product.vendor.isEmpty ? "—" : product.vendor),
            Row(title: "型号", value: product.deviceType.isEmpty ? "—" : product.deviceType),
            Row(title: "固件版本", value: product.firmwareVersion.isEmpty ? "—" : product.firmwareVersion),
            Row(title: "MAC", value: product.mac.isEmpty ? "—" : product.mac),
        ]
        if !product.note.isEmpty {
            basicRows.append(Row(title: "说明", value: product.note))
        }
        let basic = SectionModel(title: "基本信息", rows: basicRows)

        var gattRows: [Row] = []
        if product.gattServices.isEmpty {
            gattRows = [Row(title: "GATT 服务", value: "暂无数据")]
        } else {
            for service in product.gattServices {
                gattRows.append(Row(
                    title: service.name.isEmpty ? "未命名服务" : service.name,
                    value: service.uuid
                ))
                for characteristic in service.characteristics {
                    gattRows.append(Row(title: "  特征", value: characteristic))
                }
            }
        }
        let gatt = SectionModel(title: "GATT 服务与特征", rows: gattRows)

        let compatibility = SectionModel(
            title: "兼容性",
            rows: [
                Row(
                    title: "兼容设备 / 固件",
                    value: product.compatibility.isEmpty
                        ? "暂无兼容性说明"
                        : product.compatibility.joined(separator: "、")
                )
            ]
        )
        return [basic, gatt, compatibility]
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
        return cell
    }
}
