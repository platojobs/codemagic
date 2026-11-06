import XCTest
@testable import codemagic

/// 定时场景：按 IANA 时区与 ISO 星期计算下一次触发，覆盖 DST；以及系统通知注册。
final class SceneScheduleTests: XCTestCase {
    func testDailyNextFireRespectsTimezone() throws {
        let now = try date("2026-10-31T12:00:00Z")
        let next = try XCTUnwrap(
            SceneScheduleCalculator.nextFire(
                after: now,
                timeOfDay: "08:00",
                timezoneID: "Asia/Shanghai",
                daysOfWeek: []
            )
        )
        // 上海 UTC+8，2026-11-01 08:00 = 00:00Z（now 之后第一个 08:00）。
        XCTAssertEqual(next, try date("2026-11-01T00:00:00Z"))
    }

    func testSpringForwardNonexistentTimeMovesToNextValidTime() throws {
        let now = try date("2026-03-07T12:00:00Z")
        let next = try XCTUnwrap(
            SceneScheduleCalculator.nextFire(
                after: now,
                timeOfDay: "02:30",
                timezoneID: "America/New_York",
                daysOfWeek: []
            )
        )
        // 2026-03-08 02:00 -> 03:00 跳过 02:30，顺延到 03:00 EDT = 07:00Z。
        XCTAssertEqual(next, try date("2026-03-08T07:00:00Z"))
    }

    func testFallBackRepeatedTimeUsesFirstOccurrence() throws {
        let now = try date("2026-10-31T12:00:00Z")
        let next = try XCTUnwrap(
            SceneScheduleCalculator.nextFire(
                after: now,
                timeOfDay: "01:30",
                timezoneID: "America/New_York",
                daysOfWeek: []
            )
        )
        // 2026-11-01 01:30 出现两次：第一次是 EDT（05:30Z），第二次是 EST（06:30Z）。
        XCTAssertEqual(next, try date("2026-11-01T05:30:00Z"))
    }

    func testDailyCrossesLondonDstBoundary() throws {
        let now = try date("2026-03-28T12:00:00Z")
        let next = try XCTUnwrap(
            SceneScheduleCalculator.nextFire(
                after: now,
                timeOfDay: "09:00",
                timezoneID: "Europe/London",
                daysOfWeek: []
            )
        )
        // 2026-03-29 英国进入 BST，09:00 本地时间 = 08:00Z。
        XCTAssertEqual(next, try date("2026-03-29T08:00:00Z"))
    }

    func testWeeklyUsesISOWeekdayMapping() throws {
        let now = try date("2026-10-31T12:00:00Z") // 周六
        let monday = try XCTUnwrap(
            SceneScheduleCalculator.nextFire(
                after: now,
                timeOfDay: "08:00",
                timezoneID: "America/New_York",
                daysOfWeek: [1]
            )
        )
        XCTAssertEqual(monday, try date("2026-11-02T13:00:00Z"), "ISO 1=周一，08:00 EST = 13:00Z")

        let sunday = try XCTUnwrap(
            SceneScheduleCalculator.nextFire(
                after: now,
                timeOfDay: "08:00",
                timezoneID: "America/New_York",
                daysOfWeek: [7]
            )
        )
        XCTAssertEqual(sunday, try date("2026-11-01T13:00:00Z"), "ISO 7=周日，08:00 EST = 13:00Z")
    }

    func testWeeklyPicksEarliestOfMultipleDays() throws {
        let now = try date("2026-10-31T12:00:00Z")
        let next = try XCTUnwrap(
            SceneScheduleCalculator.nextFire(
                after: now,
                timeOfDay: "08:00",
                timezoneID: "America/New_York",
                daysOfWeek: [1, 7]
            )
        )
        XCTAssertEqual(next, try date("2026-11-01T13:00:00Z"), "周日比周一更早")
    }

    func testInvalidTimeOrTimezoneFallsBackWithoutCrashing() throws {
        XCTAssertNil(
            SceneScheduleCalculator.nextFire(
                after: Date(),
                timeOfDay: "24:00",
                timezoneID: "UTC",
                daysOfWeek: []
            )
        )
        XCTAssertNil(
            SceneScheduleCalculator.nextFire(
                after: Date(),
                timeOfDay: "oops",
                timezoneID: "UTC",
                daysOfWeek: []
            )
        )
        let now = try date("2026-10-31T12:00:00Z")
        let next = try XCTUnwrap(
            SceneScheduleCalculator.nextFire(
                after: now,
                timeOfDay: "09:00",
                timezoneID: "Not/AZone",
                daysOfWeek: []
            )
        )
        XCTAssertEqual(next, try date("2026-11-01T09:00:00Z"), "未知时区按 UTC 处理")
    }

    func testScheduleTriggerAccessorUsesSameCalculator() throws {
        let scene = makeScene(
            trigger: .schedule(timeOfDay: "06:00", timezone: "UTC", daysOfWeek: [2]),
            actions: [.notify(title: "早安", body: "{device}")]
        )
        let next = try XCTUnwrap(SceneScheduleCalculator.nextFire(after: try date("2026-11-02T00:00:00Z"), trigger: scene.trigger))
        XCTAssertEqual(next, try date("2026-11-03T06:00:00Z"))
    }

    // MARK: - Notification registration

    func testNotificationRequestsUseCalendarComponentsWithTimezone() throws {
        let scene = makeScene(
            trigger: .schedule(timeOfDay: "08:00", timezone: "America/New_York", daysOfWeek: [1, 3]),
            actions: [.notify(title: "出门提醒", body: "记得带伞")]
        )
        let requests = SceneScheduler.notificationRequests(for: scene, now: Date())

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.repeatComponents?.weekday }, [2, 4], "ISO 1/3 -> Calendar 周一/周三")
        XCTAssertEqual(requests.first?.repeatComponents?.hour, 8)
        XCTAssertEqual(requests.first?.repeatComponents?.minute, 0)
        XCTAssertEqual(requests.first?.repeatComponents?.timeZone?.identifier, "America/New_York")
        XCTAssertEqual(requests[0].identifier, "scene-\(scene.id.uuidString)-2")
        XCTAssertEqual(requests[1].identifier, "scene-\(scene.id.uuidString)-4")
        XCTAssertEqual(requests[0].userInfo[SceneNotificationKeys.sceneID], scene.id.uuidString)
        XCTAssertNil(requests[0].fireDate)
    }

    func testDailyNotificationRequestHasNoWeekday() throws {
        let scene = makeScene(
            trigger: .schedule(timeOfDay: "07:30", timezone: "Asia/Shanghai", daysOfWeek: []),
            actions: [.notify(title: "起床", body: "早安")]
        )
        let requests = SceneScheduler.notificationRequests(for: scene, now: Date())
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests[0].repeatComponents?.weekday)
        XCTAssertEqual(requests[0].identifier, "scene-\(scene.id.uuidString)-daily")
    }

    func testNonNotifyOrNonScheduleSceneRegistersNoNotification() throws {
        let noNotify = makeScene(
            trigger: .schedule(timeOfDay: "08:00", timezone: "UTC", daysOfWeek: []),
            actions: [.log(message: "仅记录", level: .info)]
        )
        XCTAssertTrue(SceneScheduler.notificationRequests(for: noNotify, now: Date()).isEmpty)

        let noSchedule = makeScene(
            trigger: .deviceOffline(device: makeSceneReference(), offlineSeconds: 300),
            actions: [.notify(title: "离线", body: "{device}")]
        )
        XCTAssertTrue(SceneScheduler.notificationRequests(for: noSchedule, now: Date()).isEmpty)
    }

    func testRescheduleCancelsOldNotificationsAndOnlySchedulesEnabledScenes() throws {
        let fake = FakeSceneNotificationService()
        let scheduler = SceneScheduler(notifications: fake, now: { Date() })
        let weekly = makeScene(
            trigger: .schedule(timeOfDay: "08:00", timezone: "UTC", daysOfWeek: [1, 3]),
            actions: [.notify(title: "提醒", body: "内容")]
        )
        let disabled = makeScene(
            enabled: false,
            trigger: .schedule(timeOfDay: "09:00", timezone: "UTC", daysOfWeek: []),
            actions: [.notify(title: "停用", body: "内容")]
        )
        let deleted = makeScene(
            trigger: .schedule(timeOfDay: "10:00", timezone: "UTC", daysOfWeek: []),
            actions: [.notify(title: "已删除", body: "内容")],
            deletedAt: Date(timeIntervalSince1970: 1_000),
            syncState: .synced
        )

        var didComplete = false
        scheduler.reschedule(scenes: [weekly, disabled, deleted]) { didComplete = true }

        XCTAssertTrue(didComplete)
        XCTAssertEqual(fake.cancelCount, 1)
        XCTAssertEqual(fake.scheduled.count, 2)
        XCTAssertEqual(fake.scheduled.map { $0.identifier }, [
            "scene-\(weekly.id.uuidString)-2",
            "scene-\(weekly.id.uuidString)-4",
        ])
    }

    // MARK: - Helpers

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }
}

private final class FakeSceneNotificationService: SceneNotificationServing {
    private(set) var scheduled: [SceneNotificationRequest] = []
    private(set) var cancelCount = 0

    func scheduleScene(_ request: SceneNotificationRequest, completion: ((Error?) -> Void)?) {
        scheduled.append(request)
        completion?(nil)
    }

    func cancelSceneNotifications(completion: (() -> Void)?) {
        cancelCount += 1
        scheduled.removeAll()
        completion?()
    }
}
