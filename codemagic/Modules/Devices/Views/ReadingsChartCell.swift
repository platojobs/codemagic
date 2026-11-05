import UIKit

/// 设备详情「数据」区的折线图单元格。
final class ReadingsChartCell: UITableViewCell {
    static let reuseIdentifier = "ReadingsChartCell"

    private let chartView = ReadingsLineChartView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = AppTheme.Palette.cardBackground
        chartView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(chartView)
        NSLayoutConstraint.activate([
            chartView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            chartView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            chartView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            chartView.heightAnchor.constraint(equalToConstant: 180),
            chartView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `points` 按时间升序传入，最多取最近 60 个。
    func configure(points: [DeviceReading], unit: String) {
        chartView.configure(values: points.map(\.value), unit: unit)
    }
}
