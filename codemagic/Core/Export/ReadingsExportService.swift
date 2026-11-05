import Foundation

/// 读数导出失败原因；文案直接用于界面提示与重试判断。
enum ReadingsExportError: Error, Equatable, LocalizedError {
    /// 超过服务端 / 本地一次导出的 5 万条上限，需要用户缩短区间。
    case tooManyRows(limit: Int)
    case noData
    case storeFailed(String)
    case network(AppError)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .tooManyRows(let limit):
            return "读数超过 \(limit) 条上限，请缩短导出区间后重试。"
        case .noData:
            return "所选区间内没有可导出的读数。"
        case .storeFailed(let message):
            return "读取本地读数失败：\(message)"
        case .network(let error):
            return "\(error.code) \(error.message)"
        case .writeFailed(let message):
            return "写入 CSV 文件失败：\(message)"
        }
    }
}

/// 读数导出：7 天内读本地 SQLite，更长区间走服务端 cursor 分页（上限 5 万条）。
///
/// 进度回调传递「已读取条数」，始终在主线程；生成的文件只落在临时目录，分享结束后删除。
final class ReadingsExportService {
    static let maxRows = 50_000
    static let pageSize = 200
    static let localWindow: TimeInterval = 7 * 86_400

    private let readingsStore: ReadingsStore
    private let readingsService: ReadingsAPIServicing
    private let fileManager: FileManager
    private let directoryURL: URL
    private let maxRows: Int
    private let workQueue = DispatchQueue(label: "codemagic.readings.export", qos: .userInitiated)

    init(
        readingsStore: ReadingsStore,
        readingsService: ReadingsAPIServicing,
        maxRows: Int = ReadingsExportService.maxRows,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.readingsStore = readingsStore
        self.readingsService = readingsService
        self.maxRows = maxRows
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("codemagic-readings-export", isDirectory: true)
    }

    func export(
        device: SavedDevice,
        metric: ReadingMetric,
        range: ReadingsRange,
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, ReadingsExportError>) -> Void
    ) {
        let anchor = Date()
        let interval = range.interval(now: anchor)
        cleanupStaleFiles()

        if range.duration <= Self.localWindow {
            exportLocally(
                device: device,
                metric: metric,
                interval: interval,
                progress: progress,
                completion: completion
            )
        } else {
            fetchRemotePage(
                device: device,
                metric: metric,
                interval: interval,
                items: [],
                cursor: nil,
                seenCursors: [],
                progress: progress,
                completion: completion
            )
        }
    }

    /// 分享结束后删除临时文件，避免长期占用空间。
    func removeExportedFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Local

    private func exportLocally(
        device: SavedDevice,
        metric: ReadingMetric,
        interval: DateInterval,
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, ReadingsExportError>) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let readings = try self.readingsStore.fetch(
                    deviceID: device.id,
                    metric: metric,
                    from: interval.start,
                    to: interval.end
                )
                guard !readings.isEmpty else {
                    self.deliver(.failure(.noData), completion)
                    return
                }
                guard readings.count <= self.maxRows else {
                    self.deliver(.failure(.tooManyRows(limit: self.maxRows)), completion)
                    return
                }
                self.deliverProgress(readings.count, progress)
                let data = ReadingsCSV.data(rows: readings.map(ReadingsCSV.Row.init(reading:)))
                let url = try self.write(data, device: device, metric: metric, interval: interval)
                self.deliver(.success(url), completion)
            } catch {
                self.deliver(.failure(.storeFailed(error.localizedDescription)), completion)
            }
        }
    }

    // MARK: - Remote

    private func fetchRemotePage(
        device: SavedDevice,
        metric: ReadingMetric,
        interval: DateInterval,
        items: [ReadingItem],
        cursor: String?,
        seenCursors: Set<String>,
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, ReadingsExportError>) -> Void
    ) {
        readingsService.fetchReadings(
            platform: device.platform,
            externalID: device.externalID,
            metric: metric,
            from: interval.start,
            to: interval.end,
            limit: Self.pageSize,
            cursor: cursor
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliver(.failure(.network(error)), completion)

            case .success(let page):
                let merged = items + page.items
                if merged.count > self.maxRows {
                    self.deliver(.failure(.tooManyRows(limit: self.maxRows)), completion)
                    return
                }
                self.deliverProgress(merged.count, progress)

                var nextSeen = seenCursors
                let next = page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if page.hasMore, !next.isEmpty, !nextSeen.contains(next) {
                    nextSeen.insert(next)
                    self.fetchRemotePage(
                        device: device,
                        metric: metric,
                        interval: interval,
                        items: merged,
                        cursor: next,
                        seenCursors: nextSeen,
                        progress: progress,
                        completion: completion
                    )
                    return
                }

                guard !merged.isEmpty else {
                    self.deliver(.failure(.noData), completion)
                    return
                }
                self.writeRows(
                    merged,
                    device: device,
                    metric: metric,
                    interval: interval,
                    completion: completion
                )
            }
        }
    }

    private func writeRows(
        _ items: [ReadingItem],
        device: SavedDevice,
        metric: ReadingMetric,
        interval: DateInterval,
        completion: @escaping (Result<URL, ReadingsExportError>) -> Void
    ) {
        let rows = items.map { item -> ReadingsCSV.Row in
            let normalized = ReadingMetric.normalized(item.metric)
            // 未知指标保留服务端原始名称，避免导出后丢失指标语义。
            let metric = normalized == .other ? item.metric : normalized.rawValue
            return ReadingsCSV.Row(
                recordedAt: item.recordedAt,
                metric: metric,
                value: item.value,
                unit: item.unit
            )
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let url = try self.write(
                    ReadingsCSV.data(rows: rows),
                    device: device,
                    metric: metric,
                    interval: interval
                )
                self.deliver(.success(url), completion)
            } catch {
                self.deliver(.failure(.writeFailed(error.localizedDescription)), completion)
            }
        }
    }

    // MARK: - File

    /// 文件名带设备名与设备标识、指标、区间起止（UTC）与随机后缀：
    /// `readings-温湿度计-4A2F9C31-temperature-20261105T013000Z-20261105T043000Z-1a2b3c4d.csv`
    private func write(
        _ data: Data,
        device: SavedDevice,
        metric: ReadingMetric,
        interval: DateInterval
    ) throws -> URL {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let filename = Self.filename(device: device, metric: metric, interval: interval)
        let url = directoryURL.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 文件名的纯函数部分，便于单测；日期一律 UTC。
    static func filename(
        device: SavedDevice,
        metric: ReadingMetric,
        interval: DateInterval,
        suffix: String = String(UUID().uuidString.prefix(8)).lowercased()
    ) -> String {
        let safeName = device.displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let identifier = String(device.externalID
            .filter { $0.isLetter || $0.isNumber }
            .suffix(8))
        let shortID = identifier.isEmpty
            ? String(device.id.uuidString.replacingOccurrences(of: "-", with: "").suffix(8))
            : identifier
        let from = utcStamp.string(from: interval.start)
        let to = utcStamp.string(from: interval.end)
        return "readings-\(safeName)-\(shortID)-\(metric.rawValue)-\(from)-\(to)-\(suffix).csv"
    }

    private static let utcStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    /// 临时目录中也只保留 1 天内的文件，避免异常退出后残留。
    private func cleanupStaleFiles() {
        let cutoff = Date().addingTimeInterval(-86_400)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    // MARK: - Delivery

    private func deliver(
        _ result: Result<URL, ReadingsExportError>,
        _ completion: @escaping (Result<URL, ReadingsExportError>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private func deliverProgress(_ count: Int, _ progress: @escaping (Int) -> Void) {
        DispatchQueue.main.async { progress(count) }
    }
}
