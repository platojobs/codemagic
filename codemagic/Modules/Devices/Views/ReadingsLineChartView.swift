import UIKit

/// 纯几何计算，独立于视图，便于单测覆盖 0 / 1 / 60 点。
enum ReadingsChartGeometry {
    /// 把数值映射为绘图区坐标。`values` 为空返回空数组。
    ///
    /// - 单点或所有值相同（min == max）时纵向居中，避免除零；
    /// - y 轴向上为增大，坐标原点按 UIKit 规则在左上。
    static func points(values: [Double], in rect: CGRect) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        guard rect.width > 0, rect.height > 0 else { return [] }

        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let span = maxValue - minValue
        let paddedSpan = span == 0 ? max(abs(maxValue) * 0.2, 1) : span
        let lower = span == 0 ? minValue - paddedSpan / 2 : minValue

        if values.count == 1 {
            return [CGPoint(x: rect.midX, y: rect.midY)]
        }

        let step = rect.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let ratio = (value - lower) / paddedSpan
            let x = rect.minX + step * CGFloat(index)
            let y = rect.maxY - rect.height * CGFloat(ratio)
            return CGPoint(x: x, y: y)
        }
    }
}

/// 自绘折线图：坐标轴、网格、折线、数据点全部由 `draw(_:)` 绘制，不依赖第三方图表库。
///
/// 支持 0 点（空态文案 + 网格）、1 点（居中单点）、最多 60 点（完整折线）。
final class ReadingsLineChartView: UIView {
    private var values: [Double] = []
    private var unit: String = ""

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

    /// 传入按时间升序的数值（最多 60 个）。
    func configure(values: [Double], unit: String) {
        self.values = Array(values.suffix(60))
        self.unit = unit
        accessibilityLabel = self.values.isEmpty
            ? "暂无读数"
            : "最近 \(self.values.count) 个\(unit.isEmpty ? "" : unit)读数"
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let plotRect = CGRect(
            x: rect.minX + 44,
            y: rect.minY + 12,
            width: max(rect.width - 60, 1),
            height: max(rect.height - 36, 1)
        )
        drawGrid(in: plotRect, context: context)

        guard !values.isEmpty else {
            drawEmptyText(in: plotRect)
            return
        }

        let points = ReadingsChartGeometry.points(values: values, in: plotRect)
        guard !points.isEmpty else { return }

        drawYAxisLabels(in: plotRect)
        drawPolyline(points: points, context: context)
        drawDots(points: points, context: context)
    }

    // MARK: - Drawing

    private func drawGrid(in plotRect: CGRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(AppTheme.Palette.separator.cgColor)
        context.setLineWidth(0.5)
        for index in 0...4 {
            let y = plotRect.minY + plotRect.height * CGFloat(index) / 4
            context.move(to: CGPoint(x: plotRect.minX, y: y))
            context.addLine(to: CGPoint(x: plotRect.maxX, y: y))
        }
        context.strokePath()

        // 坐标轴：左侧纵轴 + 底部横轴
        context.setStrokeColor(AppTheme.Palette.tertiaryText.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: plotRect.minX, y: plotRect.minY))
        context.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
        context.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        context.strokePath()
        context.restoreGState()
    }

    private func drawPolyline(points: [CGPoint], context: CGContext) {
        guard points.count > 1 else { return }
        context.saveGState()
        context.setStrokeColor(AppTheme.Palette.accent.cgColor)
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.move(to: points[0])
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawDots(points: [CGPoint], context: CGContext) {
        context.saveGState()
        context.setFillColor(AppTheme.Palette.accent.cgColor)
        // 60 点时缩小点半径，避免糊成一条线。
        let radius: CGFloat = points.count > 30 ? 2 : 3
        for point in points {
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

    private func drawYAxisLabels(in plotRect: CGRect) {
        guard let minValue = values.min(), let maxValue = values.max() else { return }
        let labels: [(text: String, y: CGFloat)] = [
            (format(maxValue), plotRect.minY),
            (format(minValue), plotRect.maxY),
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

    private func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}
