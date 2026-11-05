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
        guard let code else { return L10n.t("transfer.code.hint") }
        if isExpired { return L10n.t("transfer.code.expired") }
        return L10n.f("transfer.code.remaining", String(describing: PairingCountdown.text(seconds: remainingSeconds())))
    }

    var statusText: String {
        if isGenerating { return L10n.t("transfer.code.generating") }
        if let errorMessage { return errorMessage }
        if code == nil { return L10n.t("transfer.code.empty") }
        if isExpired { return L10n.t("transfer.code.invalidated") }
        return L10n.t("transfer.code.note")
    }

    var canCopy: Bool {
        rawCode != nil && !isGenerating
    }

    /// 过期时间展示跟随系统区域与时区。
    var expiryText: String? {
        guard let code else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "yMMMdHms", options: 0, locale: Locale.current)
        return L10n.f("transfer.code.expires", formatter.string(from: code.expiresAt))
    }
}
