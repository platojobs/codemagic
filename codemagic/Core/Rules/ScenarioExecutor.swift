import Foundation

/// 场景执行器：按顺序执行真实动作。单个动作失败只记录原因，不阻断后续动作，
/// 全部执行完后返回汇总，由 UI 决定 toast / 详情展示。
final class ScenarioExecutor {
    struct Dependencies {
        let bluetooth: BluetoothServicing
        let savedDeviceStore: SavedDeviceStore
        let settingsStore: SettingsStore
        let alertCoordinator: RuleAlertCoordinator
        /// 注入同步动作，便于测试断言「立即同步」确实被调用。
        let syncAction: (@escaping (Result<String, AppError>) -> Void) -> Void
        let now: () -> Date
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func execute(_ scenario: Scenario, completion: @escaping (ScenarioRunResult) -> Void) {
        run(scenario, index: 0, results: [], completion: completion)
    }

    // MARK: - Private

    private func run(
        _ scenario: Scenario,
        index: Int,
        results: [ScenarioActionResult],
        completion: @escaping (ScenarioRunResult) -> Void
    ) {
        guard index < scenario.actions.count else {
            let result = ScenarioRunResult(
                scenarioID: scenario.id,
                scenarioName: scenario.name,
                actionResults: results
            )
            completion(result)
            return
        }

        perform(scenario.actions[index]) { [weak self] result in
            guard let self else { return }
            var next = results
            next.append(result)
            self.run(scenario, index: index + 1, results: next, completion: completion)
        }
    }

    private func perform(
        _ action: ScenarioAction,
        completion: @escaping (ScenarioActionResult) -> Void
    ) {
        switch action {
        case .connectDevice(let id):
            connect(id, completion: completion)

        case .disconnectDevice(let id):
            disconnect(id, completion: completion)

        case .startBackgroundCollection:
            if dependencies.settingsStore.backgroundCollectionEnabled {
                finish(action, success: false, message: "后台采集已在运行，无需重复开启", completion: completion)
            } else {
                dependencies.settingsStore.backgroundCollectionEnabled = true
                finish(action, success: true, message: "后台采集已开启", completion: completion)
            }

        case .stopBackgroundCollection:
            if !dependencies.settingsStore.backgroundCollectionEnabled {
                finish(action, success: false, message: "后台采集未开启", completion: completion)
            } else {
                dependencies.settingsStore.backgroundCollectionEnabled = false
                dependencies.bluetooth.disconnectAll()
                finish(action, success: true, message: "后台采集已关闭，并断开全部连接", completion: completion)
            }

        case .muteAlerts(let minutes):
            mute(minutes: minutes, completion: completion)

        case .syncNow:
            dependencies.syncAction { result in
                switch result {
                case .success(let message):
                    self.finish(action, success: true, message: message, completion: completion)
                case .failure(let error):
                    self.finish(action, success: false, message: error.localizedDescription, completion: completion)
                }
            }
        }
    }

    private func connect(
        _ id: UUID,
        completion: @escaping (ScenarioActionResult) -> Void
    ) {
        let action = ScenarioAction.connectDevice(id)
        guard let device = device(id) else {
            return finish(action, success: false, message: "设备不存在或已删除", completion: completion)
        }
        switch dependencies.bluetooth.currentAuthorization() {
        case .denied, .restricted:
            return finish(action, success: false, message: "蓝牙权限未授权，请到系统设置开启", completion: completion)
        default:
            break
        }
        guard dependencies.bluetooth.state == .poweredOn else {
            return finish(
                action,
                success: false,
                message: "蓝牙不可用：\(dependencies.bluetooth.state.title)",
                completion: completion
            )
        }
        guard !dependencies.bluetooth.isConnected(peripheralID: device.peripheralID) else {
            return finish(action, success: false, message: "设备已连接，无需重复连接", completion: completion)
        }
        dependencies.bluetooth.connect(peripheralID: device.peripheralID)
        finish(action, success: true, message: "已向「\(device.displayName)」发起连接", completion: completion)
    }

    private func disconnect(
        _ id: UUID,
        completion: @escaping (ScenarioActionResult) -> Void
    ) {
        let action = ScenarioAction.disconnectDevice(id)
        guard let device = device(id) else {
            return finish(action, success: false, message: "设备不存在或已删除", completion: completion)
        }
        guard dependencies.bluetooth.isConnected(peripheralID: device.peripheralID) else {
            return finish(action, success: false, message: "设备当前未连接", completion: completion)
        }
        dependencies.bluetooth.disconnect(peripheralID: device.peripheralID)
        finish(action, success: true, message: "已断开「\(device.displayName)」", completion: completion)
    }

    private func mute(
        minutes: Int,
        completion: @escaping (ScenarioActionResult) -> Void
    ) {
        let action = ScenarioAction.muteAlerts(minutes: minutes)
        guard ScenarioAction.muteOptions.contains(minutes) else {
            return finish(action, success: false, message: "静音时长只支持 10 / 30 / 60 分钟", completion: completion)
        }
        guard dependencies.settingsStore.ruleAlertsEnabled else {
            return finish(action, success: false, message: "告警通知已关闭，无需静音", completion: completion)
        }
        let now = dependencies.now()
        guard !dependencies.settingsStore.isRuleAlertsMuted(at: now) else {
            let remaining = dependencies.settingsStore.remainingMuteMinutes(at: now)
            return finish(action, success: false, message: "告警已在静音中，剩余 \(remaining) 分钟", completion: completion)
        }
        let until = dependencies.alertCoordinator.mute(minutes: minutes, now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        finish(action, success: true, message: "已静音至 \(formatter.string(from: until))", completion: completion)
    }

    private func device(_ id: UUID) -> SavedDevice? {
        try? dependencies.savedDeviceStore.fetch(id: id)
    }

    private func finish(
        _ action: ScenarioAction,
        success: Bool,
        message: String,
        completion: @escaping (ScenarioActionResult) -> Void
    ) {
        let result = ScenarioActionResult(action: action, succeeded: success, message: message)
        completion(result)
    }
}
