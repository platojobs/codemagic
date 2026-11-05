import Foundation

/// 读数指标白名单，与后端 `reading.metric` 枚举一致。
/// 未知指标一律记为 `other`，不猜测、不丢弃原始数值。
enum ReadingMetric: String, Codable, CaseIterable, Equatable {
    case temperature
    case humidity
    case battery
    case heartRate = "heart_rate"
    case co2
    case pressure
    case other

    /// 白名单顺序即界面指标选择的默认顺序。
    static var whitelist: [ReadingMetric] { allCases }

    static func normalized(_ raw: String) -> ReadingMetric {
        ReadingMetric(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .other
    }

    var displayName: String {
        switch self {
        case .temperature: return "温度"
        case .humidity: return "湿度"
        case .battery: return "电量"
        case .heartRate: return "心率"
        case .co2: return "CO₂"
        case .pressure: return "气压"
        case .other: return "其他"
        }
    }

    /// 由特征或文本推导出的默认单位；未知指标没有单位，留空而不编造。
    var defaultUnit: String {
        switch self {
        case .temperature: return "℃"
        case .humidity: return "%"
        case .battery: return "%"
        case .heartRate: return "bpm"
        case .co2: return "ppm"
        case .pressure: return "hPa"
        case .other: return ""
        }
    }

    var rawValueForAPI: String { rawValue }
}

/// 一条本地读数。`id` 由客户端生成，推送时作为幂等主键。
struct DeviceReading: Identifiable, Equatable {
    let id: UUID
    let deviceID: UUID
    let metric: ReadingMetric
    let value: Double
    let unit: String
    let recordedAt: Date
    var syncState: SyncState

    init(
        id: UUID = UUID(),
        deviceID: UUID,
        metric: ReadingMetric,
        value: Double,
        unit: String,
        recordedAt: Date = Date(),
        syncState: SyncState = .pending
    ) {
        self.id = id
        self.deviceID = deviceID
        self.metric = metric
        self.value = value
        self.unit = unit
        self.recordedAt = recordedAt
        self.syncState = syncState
    }

    /// 展示用数值：整数不带小数，其余保留 1 位。
    var displayValue: String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded(), abs(rounded) < 1_000_000 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    var displayText: String {
        unit.isEmpty ? displayValue : "\(displayValue) \(unit)"
    }
}

/// 24 小时汇总，形状与 `GET .../readings/summary` 一致；也用于本地降级计算。
struct ReadingSummary: Decodable, Equatable {
    let metric: String
    let unit: String
    let count: Int
    let minValue: Double?
    let maxValue: Double?
    let avg: Double?
    let last: Double?
    let windowStart: Date?
    let windowEnd: Date?

    private enum CodingKeys: String, CodingKey {
        case metric
        case unit
        case count
        case min
        case max
        case avg
        case last
        case windowStart
        case windowEnd
    }

    init(
        metric: String,
        unit: String,
        count: Int,
        minValue: Double?,
        maxValue: Double?,
        avg: Double?,
        last: Double?,
        windowStart: Date? = nil,
        windowEnd: Date? = nil
    ) {
        self.metric = metric
        self.unit = unit
        self.count = count
        self.minValue = minValue
        self.maxValue = maxValue
        self.avg = avg
        self.last = last
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metric = (try? container.decodeIfPresent(String.self, forKey: .metric)) ?? ""
        unit = (try? container.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? 0
        minValue = try? container.decodeIfPresent(Double.self, forKey: .min)
        maxValue = try? container.decodeIfPresent(Double.self, forKey: .max)
        avg = try? container.decodeIfPresent(Double.self, forKey: .avg)
        last = try? container.decodeIfPresent(Double.self, forKey: .last)
        windowStart = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .windowStart)) ?? ""
        )
        windowEnd = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .windowEnd)) ?? ""
        )
    }

    /// 断网 / 后端不可用时的本地汇总；窗口内没有读数返回 nil，不造 0 值。
    static func local(
        readings: [DeviceReading],
        metric: ReadingMetric,
        since: Date,
        until: Date = Date()
    ) -> ReadingSummary? {
        let window = readings
            .filter { $0.metric == metric && $0.recordedAt >= since && $0.recordedAt <= until }
            .sorted { $0.recordedAt < $1.recordedAt }
        guard let newest = window.last else { return nil }
        let values = window.map(\.value)
        return ReadingSummary(
            metric: metric.rawValue,
            unit: newest.unit,
            count: window.count,
            minValue: values.min(),
            maxValue: values.max(),
            avg: values.reduce(0, +) / Double(values.count),
            last: newest.value,
            windowStart: since,
            windowEnd: until
        )
    }
}

/// `GET .../readings` 的条目。
struct ReadingItem: Decodable, Equatable {
    let id: String
    let metric: String
    let value: Double
    let unit: String
    let recordedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case metric
        case value
        case unit
        case recordedAt
    }

    init(id: String, metric: String, value: Double, unit: String, recordedAt: Date) {
        self.id = id
        self.metric = metric
        self.value = value
        self.unit = unit
        self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        metric = (try? container.decodeIfPresent(String.self, forKey: .metric)) ?? ""
        value = (try? container.decodeIfPresent(Double.self, forKey: .value)) ?? 0
        unit = (try? container.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        recordedAt = SyncDateCodec.parse(
            (try? container.decodeIfPresent(String.self, forKey: .recordedAt)) ?? ""
        ) ?? Date(timeIntervalSince1970: 0)
    }
}

struct ReadingsPage: Decodable, Equatable {
    let items: [ReadingItem]
    let nextCursor: String?
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case items
        case nextCursor
        case hasMore
    }

    init(items: [ReadingItem] = [], nextCursor: String? = nil, hasMore: Bool = false) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decodeIfPresent([ReadingItem].self, forKey: .items)) ?? []
        nextCursor = try? container.decodeIfPresent(String.self, forKey: .nextCursor)
        hasMore = (try? container.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
    }
}
