import XCTest
@testable import codemagic

final class OnboardingTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFirstRunDefaultsAreIncompleteAtStepZero() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.onboardingCompleted)
        XCTAssertEqual(store.onboardingStep, 0)
    }

    func testStepPersistsAndClampsToValidRange() {
        let store = SettingsStore(defaults: defaults)
        store.onboardingStep = 1
        XCTAssertEqual(store.onboardingStep, 1, "中途退出后应从已到达的步骤继续")

        store.onboardingStep = 99
        XCTAssertEqual(store.onboardingStep, AppCopy.Onboarding.stepCount - 1, "越界步骤必须收敛到最后一页")

        store.onboardingStep = -3
        XCTAssertEqual(store.onboardingStep, 0, "负数步骤必须收敛到第一页")
    }

    func testCompleteOnboardingPersistsAndResetsStep() {
        let store = SettingsStore(defaults: defaults)
        store.onboardingStep = 2
        store.completeOnboarding()

        XCTAssertTrue(store.onboardingCompleted, "跳过或走完都必须持久化完成标记")
        XCTAssertEqual(store.onboardingStep, 0)

        // 重新构造读取同一 UserDefaults，模拟下次冷启动不再出现引导。
        let reopened = SettingsStore(defaults: defaults)
        XCTAssertTrue(reopened.onboardingCompleted)
    }

    func testOnboardingHasExactlyThreeSteps() {
        XCTAssertEqual(AppCopy.Onboarding.stepCount, 3)
        let copy = [
            AppCopy.Onboarding.bluetoothTitle,
            AppCopy.Onboarding.notificationTitle,
            AppCopy.Onboarding.backgroundTitle,
        ]
        XCTAssertEqual(Set(copy).count, 3, "三步标题必须各自独立")
    }

    func testHighFrequencyCopyAvoidsBannedTerminology() {
        let banned: [(String, String)] = [
            ("装置", "设备"),
            ("机器", "设备"),
            ("上传", "同步"),
            ("数值", "读数"),
            ("参数", "指标"),
            ("策略", "规则"),
            ("配对", "接管 / 系统蓝牙配对"),
            ("！", "陈述句不用感叹号"),
            ("啦", "不用口语语气词"),
            ("哦", "不用口语语气词"),
            ("亲", "不用口语语气词"),
            ("暂无数据", "必须给真实空状态文案"),
        ]
        let strings = AppCopy.highFrequencyStrings
        XCTAssertGreaterThanOrEqual(strings.count, 5, "至少覆盖 5 个高频字符串")

        for text in strings {
            for (word, replacement) in banned {
                XCTAssertFalse(
                    text.contains(word),
                    "「\(text)」含禁用词「\(word)」，应改用「\(replacement)」"
                )
            }
        }
    }
}
