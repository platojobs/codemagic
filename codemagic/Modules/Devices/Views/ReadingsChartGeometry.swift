import UIKit

/// 一次绘图的完整几何结果：时间定位后的点、缺口分段与 min–max 区间带。
struct ReadingsChartLayout: Equatable {
    let buckets: [ReadingsChartBucket]
    let yMin: Double
    let yMax: Double
    let points: [CGPoint]
    let segments: [[CGPoint]]
    let bandPolygons: [[CGPoint]]

    static let empty = ReadingsChartLayout(
        buckets: [],
        yMin: 0,
        yMax: 0,
        points: [],
        segments: [],
        bandPolygons: []
    )

    var isEmpty: Bool { buckets.isEmpty }
}

/// 纯几何计算，独立于视图，便于单测覆盖 空 / 单桶 / 等距 / 带缺口 / 30 天 24 桶 / 异常值。
enum ReadingsChartGeometry {
    /// 相邻桶仍视为连续的最大时间差：服务端保证 `end == 下一个 start`，这里留 1 秒容差。
    static let gapTolerance: TimeInterval = 1

    /// 旧版按数组下标等距的纵向映射，保留 0 / 1 / 60 点回归用例。
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

    /// X 轴按桶 `start` 在查询区间内的真实时间比例定位；区间外的点夹紧到边界。
    static func xPosition(for date: Date, interval: DateInterval, in rect: CGRect) -> CGFloat {
        guard interval.duration > 0 else { return rect.midX }
        let ratio = date.timeIntervalSince(interval.start) / interval.duration
        return rect.minX + rect.width * CGFloat(clamp(ratio))
    }

    static func yPosition(for value: Double, yMin: Double, yMax: Double, in rect: CGRect) -> CGFloat {
        guard yMax > yMin else { return rect.midY }
        let ratio = (value - yMin) / (yMax - yMin)
        return rect.maxY - rect.height * CGFloat(clamp(ratio))
    }

    /// 按真实时间切分为连续段：相邻桶之间出现空桶（时间缺口）时另起一段，避免跨缺口连线。
    static func continuousSegments(of buckets: [ReadingsChartBucket]) -> [[ReadingsChartBucket]] {
        let sorted = buckets.sorted { $0.start < $1.start }
        var result: [[ReadingsChartBucket]] = []
        var current: [ReadingsChartBucket] = []
        for bucket in sorted {
            if let previous = current.last,
               bucket.start.timeIntervalSince(previous.end) > gapTolerance {
                result.append(current)
                current = []
            }
            current.append(bucket)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Y 轴按区间内真实 min/max 自适应；全相等时上下留白，避免折线贴边或除零。
    static func yBounds(of buckets: [ReadingsChartBucket]) -> (min: Double, max: Double)? {
        guard !buckets.isEmpty else { return nil }
        var lower = buckets.map(\.minValue).min() ?? 0
        var upper = buckets.map(\.maxValue).max() ?? 0
        if upper < lower { swap(&lower, &upper) }
        if upper == lower {
            let padding = max(abs(lower) * 0.1, 0.5)
            lower -= padding
            upper += padding
        }
        return (lower, upper)
    }

    static func layout(
        buckets: [ReadingsChartBucket],
        interval: DateInterval,
        in rect: CGRect
    ) -> ReadingsChartLayout {
        // 异常值过滤：NaN / 无穷桶直接丢弃，避免整条折线被污染。
        let valid = buckets.filter {
            $0.average.isFinite && $0.minValue.isFinite && $0.maxValue.isFinite
        }
        guard !valid.isEmpty, rect.width > 0, rect.height > 0, interval.duration > 0 else {
            return .empty
        }
        guard let bounds = yBounds(of: valid) else { return .empty }

        let sorted = valid.sorted { $0.start < $1.start }
        let groups = continuousSegments(of: sorted)

        func point(for bucket: ReadingsChartBucket, value: Double) -> CGPoint {
            CGPoint(
                x: xPosition(for: bucket.start, interval: interval, in: rect),
                y: yPosition(for: value, yMin: bounds.min, yMax: bounds.max, in: rect)
            )
        }

        let points = sorted.map { point(for: $0, value: $0.average) }
        let segments = groups.map { group in
            group.map { point(for: $0, value: $0.average) }
        }
        // 区间带：同一段内沿 min 正向、再沿 max 反向，形成闭合多边形；单桶无法成带。
        let bandPolygons = groups.compactMap { group -> [CGPoint]? in
            guard group.count > 1 else { return nil }
            let lower = group.map { point(for: $0, value: $0.minValue) }
            let upper = group.reversed().map { point(for: $0, value: $0.maxValue) }
            return lower + upper
        }

        return ReadingsChartLayout(
            buckets: sorted,
            yMin: bounds.min,
            yMax: bounds.max,
            points: points,
            segments: segments,
            bandPolygons: bandPolygons
        )
    }

    /// 点选命中：返回距离触点最近的桶下标。
    ///
    /// - 只比较折线各桶的均值点，按最近距离取一个；
    /// - 最近点仍超出 `proximity`（默认 24pt）视为点在空白处，返回 nil；
    /// - 纯函数，不读取视图状态，命中与否与 Y 轴缩放无关。
    static func hitIndex(
        for point: CGPoint,
        layout: ReadingsChartLayout,
        proximity: CGFloat = 24
    ) -> Int? {
        guard !layout.points.isEmpty else { return nil }
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, candidate) in layout.points.enumerated() {
            let dx = candidate.x - point.x
            let dy = candidate.y - point.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard let bestIndex, bestDistance <= proximity else { return nil }
        return bestIndex
    }

    /// 点选摘要：`start–end · 最小 / 最大 / 平均 / 最新 · 条数`，时间用本地时区。
    ///
    /// 时间与单位均由参数注入，便于单测在不同时区与区间长度下断言。
    static func bucketSummary(
        _ bucket: ReadingsChartBucket,
        unit: String,
        timeZone: TimeZone = .current,
        locale: Locale = .current,
        showDate: Bool = false
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = showDate ? "MM-dd HH:mm" : "HH:mm"
        let start = formatter.string(from: bucket.start)
        let end = formatter.string(from: bucket.end)
        let last = bucket.lastValue.map { DeviceRule.formatReading($0, unit: unit) } ?? "—"
        return [
            "\(start)–\(end)",
            L10n.f("chart.summary.min", String(describing: DeviceRule.formatReading(bucket.minValue, unit: unit))),
            L10n.f("chart.summary.max", String(describing: DeviceRule.formatReading(bucket.maxValue, unit: unit))),
            L10n.f("chart.summary.avg", String(describing: DeviceRule.formatReading(bucket.average, unit: unit))),
            L10n.f("chart.summary.last", String(describing: last)),
            L10n.f("common.readingsCountShort", String(describing: bucket.count)),
        ].joined(separator: " · ")
    }

    private static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, 0), 1)
    }
}