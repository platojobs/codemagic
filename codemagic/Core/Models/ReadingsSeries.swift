import Foundation

/// 服务端支持的分桶粒度，与 `GET .../readings/series` 的 `bucket` 枚举一致。
enum ReadingsBucket: String, Codable, CaseIterable, Equatable {
    case minute = "1m"
    case hour = "1h"
    case day = "1d"

    var duration: TimeInterval {
        switch self {
        case .minute: return 60
        case .hour: return 3_600
        case .day: return 86_400
        }
    }

    /// 把时间对齐到 UTC 网格上的桶起点。
    ///
    /// 1970-01-01T00:00:00Z 同时是 1m / 1h / 1d 的整数倍，因此直接按绝对秒数取整
    /// 就等价于后端「2000-01-01T00:00:00Z 原点」的算法，且不受本地时区与夏令时影响。
    func alignedStart(for date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / duration).rounded(.down) * duration)
    }
}

/// 「数据」区可切换的时间区间；每个区间映射到服务端支持的 bucket（桶数均不超过 500）。
enum ReadingsRange: String, CaseIterable, Equatable {
    case hour1
    case hour24
    case day7
    case day30

    var title: String {
        switch self {
        case .hour1: return L10n.t("range.hour1")
        case .hour24: return L10n.t("range.hours24")
        case .day7: return L10n.t("range.days7")
        case .day30: return L10n.t("range.days30")
        }
    }

    var bucket: ReadingsBucket {
        switch self {
        case .hour1: return .minute
        case .hour24, .day7: return .hour
        case .day30: return .day
        }
    }

    var duration: TimeInterval {
        switch self {
        case .hour1: return 3_600
        case .hour24: return 86_400
        case .day7: return 7 * 86_400
        case .day30: return 30 * 86_400
        }
    }

    /// 覆盖该区间会落到的桶数；服务端上限为 500。
    var bucketCount: Int { Int((duration / bucket.duration).rounded()) }

    var isSupportedByServer: Bool { bucketCount <= 500 }

    func interval(now: Date = Date()) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-duration), end: now)
    }
}

/// 服务端返回的单个时间桶；只包含 `count > 0` 的桶。
struct ReadingBucket: Decodable, Equatable {
    let start: Date
    let end: Date
    let count: Int
    let minValue: Double?
    let maxValue: Double?
    let avg: Double?
    let last: Double?

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case count
        case min
        case max
        case avg
        case last
    }

    init(
        start: Date,
        end: Date,
        count: Int,
        minValue: Double?,
        maxValue: Double?,
        avg: Double?,
        last: Double?
    ) {
        self.start = start
        self.end = end
        self.count = count
        self.minValue = minValue
        self.maxValue = maxValue
        self.avg = avg
        self.last = last
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startText = (try? container.decodeIfPresent(String.self, forKey: .start)) ?? ""
        start = SyncDateCodec.parse(startText) ?? Date(timeIntervalSince1970: 0)
        let endText = (try? container.decodeIfPresent(String.self, forKey: .end)) ?? ""
        end = SyncDateCodec.parse(endText) ?? start
        count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? 0
        minValue = try? container.decodeIfPresent(Double.self, forKey: .min)
        maxValue = try? container.decodeIfPresent(Double.self, forKey: .max)
        avg = try? container.decodeIfPresent(Double.self, forKey: .avg)
        last = try? container.decodeIfPresent(Double.self, forKey: .last)
    }

    /// 转为绘图输入：过滤空桶、非法时间与非有限数值；min/max 顺序颠倒时纠正。
    func chartBucket(bucketDuration: TimeInterval) -> ReadingsChartBucket? {
        guard count > 0,
              let avg, let minValue, let maxValue,
              avg.isFinite, minValue.isFinite, maxValue.isFinite,
              start.timeIntervalSince1970 > 0
        else { return nil }
        let resolvedEnd = end > start ? end : start.addingTimeInterval(max(bucketDuration, 0))
        return ReadingsChartBucket(
            start: start,
            end: resolvedEnd,
            average: avg,
            minValue: Swift.min(minValue, maxValue),
            maxValue: Swift.max(minValue, maxValue),
            count: count,
            lastValue: last
        )
    }
}

/// `GET .../readings/series` 响应；`buckets` 按 `start` 升序，无数据时为空数组。
struct ReadingsSeries: Decodable, Equatable {
    let metric: String
    let unit: String
    let bucket: ReadingsBucket?
    let from: Date
    let to: Date
    let buckets: [ReadingBucket]

    private enum CodingKeys: String, CodingKey {
        case metric
        case unit
        case bucket
        case from
        case to
        case buckets
    }

    init(
        metric: String,
        unit: String,
        bucket: ReadingsBucket?,
        from: Date,
        to: Date,
        buckets: [ReadingBucket]
    ) {
        self.metric = metric
        self.unit = unit
        self.bucket = bucket
        self.from = from
        self.to = to
        self.buckets = buckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metric = (try? container.decodeIfPresent(String.self, forKey: .metric)) ?? ""
        unit = (try? container.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        bucket = try? container.decodeIfPresent(ReadingsBucket.self, forKey: .bucket)
        let fromText = (try? container.decodeIfPresent(String.self, forKey: .from)) ?? ""
        from = SyncDateCodec.parse(fromText) ?? Date(timeIntervalSince1970: 0)
        let toText = (try? container.decodeIfPresent(String.self, forKey: .to)) ?? ""
        to = SyncDateCodec.parse(toText) ?? from
        buckets = (try? container.decodeIfPresent([ReadingBucket].self, forKey: .buckets)) ?? []
    }

    var interval: DateInterval { DateInterval(start: from, end: to) }

    var chartBuckets: [ReadingsChartBucket] {
        let duration = bucket?.duration ?? 0
        return buckets
            .compactMap { $0.chartBucket(bucketDuration: duration) }
            .sorted { $0.start < $1.start }
    }

    /// 网络不可用时的本地降级：用与后端相同的 UTC 分桶规则聚合本地 7 天读数。
    /// 时间轴仍按请求区间绘制，缺失的天数会留白，不拉伸数据。
    static func local(
        readings: [DeviceReading],
        range: ReadingsRange,
        now: Date = Date()
    ) -> ReadingsSeries {
        let interval = range.interval(now: now)
        let bucket = range.bucket
        let inWindow = readings.filter { $0.recordedAt >= interval.start && $0.recordedAt <= interval.end }

        var groups: [Date: [DeviceReading]] = [:]
        for reading in inWindow {
            let key = bucket.alignedStart(for: reading.recordedAt)
            groups[key, default: []].append(reading)
        }

        let buckets = groups.keys.sorted().compactMap { key -> ReadingBucket? in
            guard let items = groups[key], !items.isEmpty else { return nil }
            let values = items.map(\.value)
            guard let minValue = values.min(), let maxValue = values.max() else { return nil }
            let newest = items.max { $0.recordedAt < $1.recordedAt }
            return ReadingBucket(
                start: key,
                end: key.addingTimeInterval(bucket.duration),
                count: items.count,
                minValue: minValue,
                maxValue: maxValue,
                avg: values.reduce(0, +) / Double(values.count),
                last: newest?.value
            )
        }

        let unit = inWindow.max { $0.recordedAt < $1.recordedAt }?.unit ?? ""
        return ReadingsSeries(
            metric: inWindow.first?.metric.rawValue ?? readings.first?.metric.rawValue ?? "",
            unit: unit,
            bucket: bucket,
            from: interval.start,
            to: interval.end,
            buckets: buckets
        )
    }
}

/// 绘图输入：一个桶的时间位置、均值与波动区间。
struct ReadingsChartBucket: Equatable {
    let start: Date
    let end: Date
    let average: Double
    let minValue: Double
    let maxValue: Double
    let count: Int
    /// 桶内最后一条读数；服务端与本地聚合都可能缺失，缺失时点选摘要显示「—」。
    let lastValue: Double?

    init(
        start: Date,
        end: Date,
        average: Double,
        minValue: Double,
        maxValue: Double,
        count: Int,
        lastValue: Double? = nil
    ) {
        self.start = start
        self.end = end
        self.average = average
        self.minValue = minValue
        self.maxValue = maxValue
        self.count = count
        self.lastValue = lastValue
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// `GET .../readings/metrics` 的单项；`unit` 取该指标最近一条读数的单位。
struct ReadingMetricInfo: Decodable, Equatable {
    let metric: String
    let unit: String
    let count: Int
    let firstAt: Date?
    let lastAt: Date?

    private enum CodingKeys: String, CodingKey {
        case metric
        case unit
        case count
        case firstAt
        case lastAt
    }

    init(
        metric: String,
        unit: String,
        count: Int,
        firstAt: Date? = nil,
        lastAt: Date? = nil
    ) {
        self.metric = metric
        self.unit = unit
        self.count = count
        self.firstAt = firstAt
        self.lastAt = lastAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metric = (try? container.decodeIfPresent(String.self, forKey: .metric)) ?? ""
        unit = (try? container.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? 0
        let firstText = (try? container.decodeIfPresent(String.self, forKey: .firstAt)) ?? ""
        firstAt = SyncDateCodec.parse(firstText)
        let lastText = (try? container.decodeIfPresent(String.self, forKey: .lastAt)) ?? ""
        lastAt = SyncDateCodec.parse(lastText)
    }

    var readingMetric: ReadingMetric { ReadingMetric.normalized(metric) }

    /// 指标清单按 `lastAt` 倒序、同一时间按指标名升序（与后端一致，客户端再兜底排序）。
    static func sortedByLastAt(_ items: [ReadingMetricInfo]) -> [ReadingMetricInfo] {
        items.sorted { lhs, rhs in
            let left = lhs.lastAt ?? .distantPast
            let right = rhs.lastAt ?? .distantPast
            if left != right { return left > right }
            return lhs.metric < rhs.metric
        }
    }
}

struct ReadingMetrics: Decodable, Equatable {
    let items: [ReadingMetricInfo]

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(items: [ReadingMetricInfo] = []) {
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decodeIfPresent([ReadingMetricInfo].self, forKey: .items)) ?? []
    }
}
