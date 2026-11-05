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

    /// `buckets` 按时间升序传入；`interval` 决定 X 轴的时间比例。
    func configure(
        buckets: [ReadingsChartBucket],
        interval: DateInterval,
        unit: String,
        rangeTitle: String
    ) {
        chartView.configure(buckets: buckets, interval: interval, unit: unit, rangeTitle: rangeTitle)
    }
}

/// 「数据」区顶部的区间切换：1 小时 / 24 小时 / 7 天 / 30 天。
final class ReadingsRangeCell: UITableViewCell {
    static let reuseIdentifier = "ReadingsRangeCell"

    private let segmentedControl = UISegmentedControl(
        items: ReadingsRange.allCases.map(\.title)
    )

    var onSelect: ((ReadingsRange) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.addTarget(self, action: #selector(handleChange), for: .valueChanged)
        contentView.addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(selected: ReadingsRange) {
        if let index = ReadingsRange.allCases.firstIndex(of: selected) {
            segmentedControl.selectedSegmentIndex = index
        }
    }

    @objc private func handleChange() {
        let index = segmentedControl.selectedSegmentIndex
        guard ReadingsRange.allCases.indices.contains(index) else { return }
        onSelect?(ReadingsRange.allCases[index])
    }
}
