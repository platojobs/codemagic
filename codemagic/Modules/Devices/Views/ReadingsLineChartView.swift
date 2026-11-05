import UIKit

/// 自绘折线图：坐标轴、网格、折线、数据点与 min–max 区间带全部由 `draw(_:)` 绘制，不依赖第三方图表库。
///
/// 折线按桶 `start` 的真实时间比例定位；服务端只返回有数据的桶，桶间缺口处折线断开。
final class ReadingsLineChartView: UIView {
    private var buckets: [ReadingsChartBucket] = []
    private var interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 0)
    private var unit: String = ""
    private var rangeTitle: String = ""

    private let leftInset: CGFloat = 56
    private let rightInset: CGFloat = 14
    private let topInset: CGFloat = 14
    private let bottomInset: CGFloat = 30

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 传入按时间升序的有数据的桶，以及查询区间（决定 X 轴比例）。
    func configure(buckets: [ReadingsChartBucket], interval: DateInterval, unit: String, rangeTitle: String) {
        self.buckets = buckets.sorted { $0.start < $1.start }
        self.interval = interval
        self.unit = unit
        self.rangeTitle = rangeTitle
        accessibilityLabel = self.buckets.isEmpty
            ? "暂无读数"
            : "\(rangeTitle)走势，共 \(self.buckets.count) 个时间桶"
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let plotRect = CGRect(
            x: rect.minX + leftInset,
            y: rect.minY + topInset,
            width: max(rect.width - leftInset - rightInset, 1),
            height: max(rect.height - topInset - bottomInset, 1)
        )
        drawGrid(in: plotRect, context: context)

        let layout = ReadingsChartGeometry.layout(buckets: buckets, interval: interval, in: plotRect)
        guard !layout.isEmpty else {
            drawEmptyText(in: plotRect)
            return
        }

        drawYAxisLabels(layout: layout, in: plotRect)
        drawXAxisLabels(in: plotRect)
        drawBands(layout: layout, context: context)
        drawPolylines(layout: layout, context: context)
        drawDots(layout: layout, context: context)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 是静态快照，外观切换后必须重绘才能换成深色解析值。
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            setNeedsDisplay()
        }
    }

    // MARK: - Drawing

    /// 自绘 CGColor 必须显式按当前 trait 解析，否则深色模式下会沿用上一次浅色解析结果。
    private func cgColor(_ color: UIColor) -> CGColor {
        color.resolvedColor(with: traitCollection).cgColor
    }

    private func drawGrid(in plotRect: CGRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(cgColor(AppTheme.Palette.separator))
        context.setLineWidth(0.5)
        for index in 0...4 {
            let y = plotRect.minY + plotRect.height * CGFloat(index) / 4
            context.move(to: CGPoint(x: plotRect.minX, y: y))
            context.addLine(to: CGPoint(x: plotRect.maxX, y: y))
        }
        context.strokePath()

        // 坐标轴：左侧纵轴 + 底部横轴
        context.setStrokeColor(cgColor(AppTheme.Palette.tertiaryText))
        context.setLineWidth(1)
        context.move(to: CGPoint(x: plotRect.minX, y: plotRect.minY))
        context.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
        context.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        context.strokePath()
        context.restoreGState()
    }

    /// min–max 浅色区间带，让每桶的波动幅度可见。
    private func drawBands(layout: ReadingsChartLayout, context: CGContext) {
        guard !layout.bandPolygons.isEmpty else { return }
        context.saveGState()
        context.setFillColor(cgColor(AppTheme.Palette.accent.withAlphaComponent(0.16)))
        for polygon in layout.bandPolygons where polygon.count > 2 {
            context.beginPath()
            context.move(to: polygon[0])
            for point in polygon.dropFirst() {
                context.addLine(to: point)
            }
            context.closePath()
            context.fillPath()
        }
        context.restoreGState()
    }

    /// 每段单独描边：缺口处不跨空缺连线。
    private func drawPolylines(layout: ReadingsChartLayout, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(cgColor(AppTheme.Palette.accent))
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for segment in layout.segments where segment.count > 1 {
            context.move(to: segment[0])
            for point in segment.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawDots(layout: ReadingsChartLayout, context: CGContext) {
        guard !layout.points.isEmpty else { return }
        context.saveGState()
        context.setFillColor(cgColor(AppTheme.Palette.accent))
        // 点数多时缩小半径，避免糊成一条线。
        let radius: CGFloat = layout.points.count > 30 ? 2 : 3
        for point in layout.points {
            context.fillEllipse(
                in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        }
        context.restoreGState()
    }

    private func drawYAxisLabels(layout: ReadingsChartLayout, in plotRect: CGRect) {
        let labels: [(text: String, y: CGFloat)] = [
            (format(layout.yMax), plotRect.minY),
            (format((layout.yMin + layout.yMax) / 2), plotRect.midY),
            (format(layout.yMin), plotRect.maxY),
        ]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .caption2),
            .foregroundColor: AppTheme.Palette.secondaryText,
        ]
        for label in labels {
            let size = (label.text as NSString).size(withAttributes: attributes)
            let origin = CGPoint(
                x: plotRect.minX - size.width - 6,
                y: label.y - size.height / 2
            )
            (label.text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    private func drawXAxisLabels(in plotRect: CGRect) {
        guard interval.duration > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .caption2),
            .foregroundColor: AppTheme.Palette.secondaryText,
        ]
        let positions: [(date: Date, alignment: NSTextAlignment)] = [
            (interval.start, .left),
            (interval.start.addingTimeInterval(interval.duration / 2), .center),
            (interval.end, .right),
        ]
        for position in positions {
            let text = timeText(for: position.date) as NSString
            let size = text.size(withAttributes: attributes)
            let x: CGFloat
            switch position.alignment {
            case .left: x = plotRect.minX
            case .right: x = plotRect.maxX - size.width
            default: x = plotRect.midX - size.width / 2
            }
            text.draw(at: CGPoint(x: x, y: plotRect.maxY + 6), withAttributes: attributes)
        }
    }

    private func drawEmptyText(in plotRect: CGRect) {
        let text = "暂无读数"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: AppTheme.Palette.secondaryText,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(x: plotRect.midX - size.width / 2, y: plotRect.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func timeText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        // 2 天以内按时刻，长区间按日期；两者都足以表达时间位置。
        formatter.dateFormat = interval.duration <= 2 * 86_400 ? "HH:mm" : "MM-dd"
        return formatter.string(from: date)
    }

    private func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }
}
