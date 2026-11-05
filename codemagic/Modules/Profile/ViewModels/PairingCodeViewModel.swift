import Foundation

/// 「迁移到新设备」：展示一次性配对码与基于服务端 `expiresAt` 的真实倒计时。
final class PairingCodeViewModel {
    private(set) var code: PairingCode?
    private(set) var isGenerating = false
    private(set) var errorMessage: String?

    var onChange: (() -> Void)?

    private let service: PairingServicing
    private let now: () -> Date

    init(service: PairingServicing, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        onChange?()

        service.createCode { [weak self] result in
            guard let self else { return }
            self.isGenerating = false
            switch result {
            case .success(let code):
                self.code = code
                self.errorMessage = nil
            case .failure(let error):
                // 重新生成失败时保留旧码，用户仍可在其过期前使用。
                self.errorMessage = error.userMessage
            }
            self.onChange?()
        }
    }

    var codeDisplayText: String {
        guard let code else { return "———— ————" }
        return PairingCodeFormatter.grouped(code.code)
    }

    var rawCode: String? {
        guard let code, !isExpired else { return nil }
        return code.code
    }

    func remainingSeconds(at date: Date? = nil) -> Int {
        guard let code else { return 0 }
        return PairingCountdown.remainingSeconds(expiresAt: code.expiresAt, now: date ?? now())
    }

    var isExpired: Bool {
        guard let code else { return false }
        return remainingSeconds() <= 0
    }

    var countdownText: String {
        guard let code else { return "生成后可复制到旧设备" }
        if isExpired { return "已过期，请重新生成" }
        return "剩余 \(PairingCountdown.text(seconds: remainingSeconds()))"
    }

    var statusText: String {
        if isGenerating { return "正在生成接管码…" }
        if let errorMessage { return errorMessage }
        if code == nil { return "点击下方按钮生成一次性接管码" }
        if isExpired { return "旧接管码已失效，请重新生成。" }
        return "接管码 10 分钟内有效，仅可使用一次；重新生成后旧码立即失效。"
    }

    var canCopy: Bool {
        rawCode != nil && !isGenerating
    }

    /// 过期时间展示，显式固定 UTC 时区与 locale，避免不同设备显示偏差。
    var expiryText: String? {
        guard let code else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "UTC \(formatter.string(from: code.expiresAt))"
    }
}
