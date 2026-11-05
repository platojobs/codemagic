import XCTest
import UserNotifications
@testable import codemagic

/// 阈值告警通知：开关、授权、节流窗口与恢复通知。
final class RuleAlertCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var notifications: FakeNotificationService!
    private var coordinator: RuleAlertCoordinator!
    private var ruleID: UUID!
    private var deviceID: UUID!

    override func setUp() {
        super.setUp()
        suiteName = "rule-alert-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = SettingsStore(defaults: defaults)
        notifications = FakeNotificationService()
        coordinator = RuleAlertCoordinator(settingsStore: settings, notifications: notifications)
        ruleID = UUID()
        deviceID = UUID()
    }

    override func tearDown() {
        if let defaults, let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        super.tearDown()
    }

    func testTriggeredSchedulesNotificationOncePerWindow() {
        let start = Date()
        coordinator.handle([event(.triggered, at: start)], now: start)
        coordinator.handle([event(.triggered, at: start.addingTimeInterval(120))], now: start.addingTimeInterval(120))
        XCTAssertEqual(notifications.scheduled.count, 1, "5 分钟窗口内同一设备同一规则只报一次")

        coordinator.handle([event(.triggered, at: start.addingTimeInterval(301))], now: start.addingTimeInterval(301))
        XCTAssertEqual(notifications.scheduled.count, 2, "窗口结束后可再次提醒")
    }

    func testThrottleWindowIsConfigurable() {
        settings.ruleAlertThrottleMinutes = 1
        let start = Date()
        coordinator.handle([event(.triggered, at: start)], now: start)
        coordinator.handle([event(.triggered, at: start.addingTimeInterval(30))], now: start.addingTimeInterval(30))
        XCTAssertEqual(notifications.scheduled.count, 1, "1 分钟窗口内不重复")

        coordinator.handle([event(.triggered, at: start.addingTimeInterval(61))], now: start.addingTimeInterval(61))
        XCTAssertEqual(notifications.scheduled.count, 2)
    }

    func testDifferentDevicesAreThrottledIndependently() {
        let start = Date()
        coordinator.handle([event(.triggered, deviceID: UUID(), at: start)], now: start)
        coordinator.handle([event(.triggered, deviceID: UUID(), at: start)], now: start)
        XCTAssertEqual(notifications.scheduled.count, 2)
    }

    func testRecoveredOnlyAfterDeliveredAlert() {
        let start = Date()
        coordinator.handle([event(.recovered, at: start)], now: start)
        XCTAssertEqual(notifications.scheduled.count, 0, "没有告警过就不发恢复通知")

        coordinator.handle([event(.triggered, at: start)], now: start)
        coordinator.handle([event(.recovered, at: start.addingTimeInterval(60))], now: start.addingTimeInterval(60))
        XCTAssertEqual(notifications.scheduled.count, 2)
        XCTAssertEqual(notifications.scheduled.last?.kind, .recovered)
    }

    func testDisabledSwitchSendsNothingAndDoesNotRequestAuthorization() {
        settings.ruleAlertsEnabled = false
        coordinator.handle([event(.triggered, at: Date())])
        XCTAssertEqual(notifications.authorizationRequests, 0)
        XCTAssertTrue(notifications.scheduled.isEmpty)
    }

    func testDeniedAuthorizationDoesNotScheduleAndIsReported() {
        notifications.status = .denied
        notifications.granted = false
        coordinator.handle([event(.triggered, at: Date())])
        XCTAssertEqual(notifications.authorizationRequests, 1)
        XCTAssertTrue(notifications.scheduled.isEmpty)
    }

    // MARK: - Helpers

    private func event(
        _ kind: RuleEventKind,
        deviceID: UUID? = nil,
        at date: Date
    ) -> RuleTriggerEvent {
        RuleTriggerEvent(
            ruleID: ruleID,
            ruleName: "信号过低",
            deviceID: deviceID ?? self.deviceID,
            deviceName: "温湿度计",
            kind: kind,
            message: kind == .triggered ? "信号低于阈值（-88 dBm）" : "设备已恢复",
            occurredAt: date
        )
    }
}

private final class FakeNotificationService: LocalNotificationServing {
    var status: UNAuthorizationStatus = .authorized
    var granted = true
    private(set) var authorizationRequests = 0
    private(set) var scheduled: [RuleTriggerEvent] = []

    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        completion(status)
    }

    func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        authorizationRequests += 1
        completion(granted)
    }

    func schedule(event: RuleTriggerEvent, completion: ((Error?) -> Void)? = nil) {
        scheduled.append(event)
        completion?(nil)
    }
}
