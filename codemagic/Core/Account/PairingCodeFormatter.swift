import Foundation

/// 配对码输入的规范化：自动大写、过滤易混字符（0/O/1/I）与空白，限制 8 位。
enum PairingCodeFormatter {
    static let codeLength = 8
    /// 与服务端字符集一致：去掉易混的 `0/O/1/I`。
    static let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    private static let allowed = Set(alphabet)

    /// 过滤规则：大写后只保留字符集内字符，再截断到 8 位。
    static func normalize(_ raw: String) -> String {
        let upper = raw.uppercased()
        let filtered = upper.filter { allowed.contains($0) }
        return String(filtered.prefix(codeLength))
    }

    static func isComplete(_ normalized: String) -> Bool {
        normalized.count == codeLength && normalized.allSatisfy { allowed.contains($0) }
    }

    /// 展示时每 4 位分组，便于在另一台设备上抄写；复制时仍用原始码。
    static func grouped(_ code: String) -> String {
        guard code.count > 4 else { return code }
        let head = code.prefix(4)
        let tail = code.dropFirst(4)
        return "\(head) \(tail)"
    }
}

/// 倒计时文案。显式使用 POSIX locale，避免英文/中文环境下数字格式差异。
enum PairingCountdown {
    static func remainingSeconds(expiresAt: Date, now: Date) -> Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(now))))
    }

    static func text(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(
            format: "%02d:%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            clamped / 60,
            clamped % 60
        )
    }
}
