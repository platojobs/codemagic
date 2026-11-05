import Foundation

/// 「从旧设备接管」：8 位码输入规范化、提交、429 冷却倒计时与错误文案。
final class PairingClaimViewModel {
    private(set) var input = ""
    private(set) var isClaiming = false
    private(set) var errorMessage: String?
    private(set) var result: PairingClaimResult?
    private(set) var cooldownUntil: Date?

    var onChange: (() -> Void)?

    private let service: PairingServicing
    private let now: () -> Date

    init(service: PairingServicing, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    /// 输入框代理调用：自动大写、过滤易混字符与空白、截断 8 位。返回应回填的文本。
    @discardableResult
    func updateInput(_ raw: String) -> String {
        let normalized = PairingCodeFormatter.normalize(raw)
        if normalized != input {
            input = normalized
            errorMessage = nil
            onChange?()
        }
        return normalized
    }

    var isComplete: Bool { PairingCodeFormatter.isComplete(input) }

    var canClaim: Bool {
        isComplete && !isClaiming && result == nil && cooldownSeconds() == 0
    }

    func cooldownSeconds(at date: Date? = nil) -> Int {
        guard let cooldownUntil else { return 0 }
        return max(0, Int(ceil(cooldownUntil.timeIntervalSince(date ?? now()))))
    }

    var cooldownText: String? {
        let remaining = cooldownSeconds()
        guard remaining > 0 else { return nil }
        return "请求过于频繁，请 \(remaining) 秒后再试"
    }

    var statusText: String {
        if isClaiming { return "正在校验配对码…" }
        if let errorMessage { return errorMessage }
        if let cooldownText { return cooldownText }
        if input.isEmpty { return "请输入旧设备展示的 8 位配对码" }
        if !isComplete { return "还需 \(PairingCodeFormatter.codeLength - input.count) 位" }
        return "配对码仅可使用一次；接管后本机设备与读数会重新上传到旧设备账号。"
    }

    func claim() {
        guard canClaim else { return }
        isClaiming = true
        errorMessage = nil
        onChange?()

        service.claim(code: input) { [weak self] result in
            guard let self else { return }
            self.isClaiming = false
            switch result {
            case .success(let claimResult):
                self.result = claimResult
                self.errorMessage = nil
            case .failure(let error):
                self.errorMessage = error.userMessage
                if case .api(.rateLimited(let seconds)) = error {
                    let delay = TimeInterval(seconds ?? 30)
                    self.cooldownUntil = self.now().addingTimeInterval(delay)
                }
            }
            self.onChange?()
        }
    }

    func clearCooldownIfNeeded() {
        if let cooldownUntil, cooldownUntil <= now() {
            self.cooldownUntil = nil
            onChange?()
        }
    }
}
