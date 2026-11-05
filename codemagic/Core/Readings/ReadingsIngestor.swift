import Foundation

/// 把 BLE notify 原始数据解析并落到 `readings` 表，然后交给本地规则引擎判定读数阈值。
///
/// 失败处理：解析失败只写本地日志（分类「读数」），不落库、不弹窗、不崩溃；
/// 未保存设备的读数直接丢弃并记一条日志，避免出现无法归属的孤儿数据。
final class ReadingsIngestor {
    private let readingsStore: ReadingsStore
    private let deviceStore: SavedDeviceStore
    private let logStore: ScanLogStore
    private let ruleStore: DeviceRuleStore?
    private let ruleEvaluator: RuleEvaluator?
    private let ruleAlertCoordinator: RuleAlertCoordinator?
    private let now: () -> Date

    /// 某个设备新增读数后回调（详情页据此刷新），在主线程调用。
    var onSaved: ((UUID) -> Void)?

    init(
        readingsStore: ReadingsStore,
        deviceStore: SavedDeviceStore,
        logStore: ScanLogStore,
        ruleStore: DeviceRuleStore? = nil,
        ruleEvaluator: RuleEvaluator? = nil,
        ruleAlertCoordinator: RuleAlertCoordinator? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.readingsStore = readingsStore
        self.deviceStore = deviceStore
        self.logStore = logStore
        self.ruleStore = ruleStore
        self.ruleEvaluator = ruleEvaluator
        self.ruleAlertCoordinator = ruleAlertCoordinator
        self.now = now
    }

    @discardableResult
    func ingest(_ sample: BluetoothReadingSample) -> [DeviceReading] {
        let parsed = ReadingParser.parse(sample)
        for failure in parsed.failures {
            appendLog(
                "\(sample.characteristic.title)解析失败：\(failure)",
                at: sample.receivedAt
            )
        }
        guard !parsed.readings.isEmpty else { return [] }

        guard let device = (try? deviceStore.fetch(peripheralID: sample.peripheralID)),
              device.deletedAt == nil
        else {
            appendLog(
                "\(sample.characteristic.title)读数未落库：设备 \(sample.peripheralID.uuidString) 不在已保存列表中",
                at: sample.receivedAt
            )
            return []
        }

        var saved: [DeviceReading] = []
        for item in parsed.readings {
            let reading = DeviceReading(
                deviceID: device.id,
                metric: item.metric,
                value: item.value,
                unit: item.unit,
                recordedAt: sample.receivedAt
            )
            do {
                try readingsStore.insert(reading)
                saved.append(reading)
            } catch {
                appendLog(
                    "\(sample.characteristic.title)读数写入失败：\(error.localizedDescription)",
                    at: now()
                )
            }
        }
        if !saved.isEmpty {
            onSaved?(device.id)
            evaluateReadingRules(device: device, readings: saved)
        }
        return saved
    }

    /// 读数规则的触发链路：落库 → 规则引擎 → 本地日志（「智能 → 最近触发」） → 本地通知。
    private func evaluateReadingRules(device: SavedDevice, readings: [DeviceReading]) {
        guard let ruleStore, let ruleEvaluator else { return }
        let rules = (try? ruleStore.fetchAll()) ?? []
        guard !rules.isEmpty else { return }

        let events = ruleEvaluator.evaluateReadings(rules: rules, device: device, readings: readings)
        guard !events.isEmpty else { return }

        for event in events {
            // 触发写 warning（进「最近触发」），恢复写 info，避免把恢复也当成命中。
            try? logStore.append(
                ScanLogEntry(
                    occurredAt: event.occurredAt,
                    category: .rule,
                    level: event.kind == .triggered ? .warning : .info,
                    message: event.message
                )
            )
        }
        ruleAlertCoordinator?.handle(events, now: now())
    }

    private func appendLog(_ message: String, at date: Date) {
        try? logStore.append(
            ScanLogEntry(
                occurredAt: date,
                category: .reading,
                level: .warning,
                message: message
            )
        )
    }
}
