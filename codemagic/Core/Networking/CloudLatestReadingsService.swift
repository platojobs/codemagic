import Foundation

/// 单台设备的云端最近读数。
///
/// 后端只提供「按设备查询读数」，没有服务端在线 / lastSeen 字段，
/// 因此这里只表达「服务端最近一条读数」，不推断设备在线状态。
struct CloudLatestReading: Equatable {
    let metric: ReadingMetric
    /// 服务端原始指标名（如 `temperature_celsius`），仅用于展示映射。
    let rawMetric: String
    let value: Double
    let unit: String
    let reportedAt: Date

    var metricTitle: String {
        ReadingMetricPresentation.title(rawMetric: rawMetric, fallback: metric)
    }

    var displayUnit: String {
        ReadingMetricPresentation.unit(rawUnit: unit)
    }

    /// 与本地读数一致的数值格式：整数不带小数，其余保留 1 位。
    var displayText: String {
        let rounded = (value * 10).rounded() / 10
        let valueText: String
        if rounded == rounded.rounded(), abs(rounded) < 1_000_000 {
            valueText = String(Int(rounded))
        } else {
            valueText = String(format: "%.1f", locale: Locale.current, rounded)
        }
        return displayUnit.isEmpty ? valueText : "\(valueText) \(displayUnit)"
    }
}

/// 云端最近读数的加载状态。
///
/// `.failed` 表示这次查询没拿到结果（无网 / 鉴权 / 服务错误），
/// **不能据此判定设备离线，也不能显示成「暂无读数」**；只有 `.empty`
/// 才是服务端确认「该设备从未上报读数」。
enum CloudLatestReadingState: Equatable {
    case loading
    case available(CloudLatestReading)
    case empty
    case failed

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

protocol CloudLatestReadingsProviding: AnyObject {
    func latestReading(
        platform: String,
        externalID: String,
        completion: @escaping (CloudLatestReadingState) -> Void
    )
}

/// 服务端指标名到界面标题的展示映射。
///
/// 后端指标是设备自定义的小写 snake_case（`temperature_celsius` 等），
/// iOS 的 `ReadingMetric` 枚举只覆盖本机 BLE 常用指标，未知指标会落到 `.other`。
/// 这里只做展示翻译，不改变读数本身，也不把未知指标伪装成已知指标。
enum ReadingMetricPresentation {
    static func title(rawMetric: String, fallback: ReadingMetric) -> String {
        switch rawMetric.lowercased() {
        case "temperature", "temperature_celsius", "temperature_fahrenheit":
            return L10n.t("metric.temperature")
        case "humidity", "relative_humidity":
            return L10n.t("metric.humidity")
        case "battery", "battery_level", "battery_percent":
            return L10n.t("metric.battery")
        case "heart_rate":
            return L10n.t("metric.heartRate")
        case "co2", "carbon_dioxide":
            return "CO₂"
        case "pressure", "pressure_hpa":
            return L10n.t("metric.pressure")
        case "cadence_rpm":
            return L10n.t("metric.cadence")
        case "speed", "wheel_speed_kmh":
            return L10n.t("metric.speed")
        case "weight", "weight_kg":
            return L10n.t("metric.weight")
        case "body_fat_percent":
            return L10n.t("metric.bodyFat")
        default:
            return fallback.displayName
        }
    }

    static func unit(rawUnit: String) -> String {
        switch rawUnit.lowercased() {
        case "celsius", "°c":
            return "℃"
        case "fahrenheit", "°f":
            return "℉"
        default:
            return rawUnit
        }
    }
}

/// 相对时间文案；统一用短格式，避免各模块各建 formatter 导致口径漂移。
enum RelativeTimeText {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.current
        formatter.unitsStyle = .short
        return formatter
    }()

    static func short(for date: Date, relativeTo now: Date = Date()) -> String {
        formatter.localizedString(for: date, relativeTo: now)
    }
}

/// 云端最近读数加载器。
///
/// - 每台设备两次请求：`/readings/metrics` 找 `lastAt` 最新的指标，
///   再 `/readings?metric=&limit=1` 取该指标最新一条读数；
/// - 结果按设备缓存，失败缓存更短，避免频繁重试；
/// - 同一设备并发请求合并为一次，整页刷新不会打爆服务端；
/// - 最多 `maxConcurrent` 台设备并行；
/// - 成功 / 空 / 失败都在主队列回调。
final class CloudLatestReadingsService: CloudLatestReadingsProviding {
    private struct CacheEntry {
        let state: CloudLatestReadingState
        let fetchedAt: Date
    }

    private struct Job {
        let key: String
        let platform: String
        let externalID: String
        var completions: [(CloudLatestReadingState) -> Void]
    }

    private let api: ReadingsAPIServicing
    private let now: () -> Date
    private let maxConcurrent: Int
    private let cacheLifetime: TimeInterval
    private let failureCacheLifetime: TimeInterval
    private let queue = DispatchQueue(label: "app.cloud.latest.readings")

    private var cache: [String: CacheEntry] = [:]
    private var jobs: [String: Job] = [:]
    private var waiting: [String] = []
    private var running = 0

    init(
        api: ReadingsAPIServicing,
        now: @escaping () -> Date = Date.init,
        maxConcurrent: Int = 3,
        cacheLifetime: TimeInterval = 60,
        failureCacheLifetime: TimeInterval = 20
    ) {
        self.api = api
        self.now = now
        self.maxConcurrent = max(1, maxConcurrent)
        self.cacheLifetime = cacheLifetime
        self.failureCacheLifetime = failureCacheLifetime
    }

    func latestReading(
        platform: String,
        externalID: String,
        completion: @escaping (CloudLatestReadingState) -> Void
    ) {
        let key = Self.key(platform: platform, externalID: externalID)
        queue.async { [weak self] in
            guard let self else { return }
            if let cached = self.cache[key] {
                let lifetime = cached.state.isFailure ? self.failureCacheLifetime : self.cacheLifetime
                if self.now().timeIntervalSince(cached.fetchedAt) < lifetime {
                    self.deliver(cached.state, to: [completion])
                    return
                }
            }
            if var job = self.jobs[key] {
                job.completions.append(completion)
                self.jobs[key] = job
                return
            }
            self.jobs[key] = Job(
                key: key,
                platform: platform,
                externalID: externalID,
                completions: [completion]
            )
            self.waiting.append(key)
            self.pump()
        }
    }

    // MARK: - Private

    private static func key(platform: String, externalID: String) -> String {
        "\(platform):\(externalID)"
    }

    private func pump() {
        while running < maxConcurrent, let key = waiting.first {
            waiting.removeFirst()
            guard let job = jobs[key] else { continue }
            running += 1
            start(job)
        }
    }

    private func start(_ job: Job) {
        api.fetchMetrics(platform: job.platform, externalID: job.externalID) { [weak self] result in
            guard let self else { return }
            self.queue.async { self.handleMetrics(job, result) }
        }
    }

    private func handleMetrics(_ job: Job, _ result: Result<ReadingMetrics, AppError>) {
        switch result {
        case .failure(let error):
            // 404 表示服务端没有这台设备的注册记录：不是「查询失败」，而是确认无云端数据。
            finish(job.key, state: Self.isNotFound(error) ? .empty : .failed)
        case .success(let metrics):
            guard let newest = ReadingMetricInfo.sortedByLastAt(metrics.items)
                .first(where: { $0.count > 0 && $0.lastAt != nil })
            else {
                finish(job.key, state: .empty)
                return
            }
            api.fetchReadings(
                platform: job.platform,
                externalID: job.externalID,
                metricName: newest.metric,
                from: nil,
                to: nil,
                limit: 1,
                cursor: nil
            ) { [weak self] result in
                guard let self else { return }
                self.queue.async { self.handleReadings(job, metric: newest, result) }
            }
        }
    }

    private func handleReadings(
        _ job: Job,
        metric: ReadingMetricInfo,
        _ result: Result<ReadingsPage, AppError>
    ) {
        switch result {
        case .failure(let error):
            finish(job.key, state: Self.isNotFound(error) ? .empty : .failed)
        case .success(let page):
            guard let item = page.items.first else {
                finish(job.key, state: .empty)
                return
            }
            let reportedAt = item.recordedAt.timeIntervalSince1970 > 0
                ? item.recordedAt
                : (metric.lastAt ?? now())
            finish(job.key, state: .available(CloudLatestReading(
                metric: metric.readingMetric,
                rawMetric: metric.metric,
                value: item.value,
                unit: item.unit.isEmpty ? metric.unit : item.unit,
                reportedAt: reportedAt
            )))
        }
    }

    private func finish(_ key: String, state: CloudLatestReadingState) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        waiting.removeAll { $0 == key }
        running = max(0, running - 1)
        cache[key] = CacheEntry(state: state, fetchedAt: now())
        deliver(state, to: job.completions)
        pump()
    }

    private func deliver(
        _ state: CloudLatestReadingState,
        to completions: [(CloudLatestReadingState) -> Void]
    ) {
        guard !completions.isEmpty else { return }
        DispatchQueue.main.async {
            completions.forEach { $0(state) }
        }
    }

    private static func isNotFound(_ error: AppError) -> Bool {
        switch error {
        case .api(_, let statusCode, _), .server(let statusCode):
            return statusCode == 404
        default:
            return false
        }
    }
}
