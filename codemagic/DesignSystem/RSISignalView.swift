import UIKit

/// 自绘 RSSI 信号强度视图：4 根柱状条按 dBm 分档绘制，不使用图片或系统 symbol 组合。
/// 分档阈值与文案以 `PKotlinApp/docs/rssi-signal-tiers.md` 为唯一真源，本文件不自行定义数字。
final class RSISignalView: UIView {
    /// 信号档位。未知与极弱都画 0 格，但必须用不同文案区分。
    enum Tier: CaseIterable, Equatable {
        case unknown
        case strong
        case good
        case fair
        case weak
        case veryWeak

        /// 4 格制下点亮的根数。
        var barCount: Int {
            switch self {
            case .unknown, .veryWeak: return 0
            case .weak: return 1
            case .fair: return 2
            case .good: return 3
            case .strong: return 4
            }
        }

        var localizationKey: String {
            switch self {
            case .unknown: return "signal.tier.unknown"
            case .strong: return "signal.tier.strong"
            case .good: return "signal.tier.good"
            case .fair: return "signal.tier.fair"
            case .weak: return "signal.tier.weak"
            case .veryWeak: return "signal.tier.veryWeak"
            }
        }
    }

    // MARK: - State

    /// 最近一次真实读数；`nil` 表示没有信号数据。
    /// 合法 dBm 恒为负数：`0` / `127` 之类占位值按未知处理，不能渲染成满格。
    var rssi: Int? {
        didSet {
            guard oldValue != rssi else { return }
            setNeedsDisplay()
            updateAccessibility()
        }
    }

    // MARK: - Level

    /// 只有负数才是真实 RSSI；`Int.min` 是「未知」哨兵值，不能当极弱信号排序或展示。
    static func isValid(_ rssi: Int?) -> Bool {
        guard let rssi else { return false }
        return rssi < 0 && rssi != Int.min
    }

    /// 由最近扫描记录构建「设备 → 合法 dBm」映射，展示与排序统一走这一处判定。
    static func validRSSIMap(from devices: [RecentDevice]) -> [UUID: Int] {
        Dictionary(
            devices.compactMap { device -> (UUID, Int)? in
                isValid(device.rssi) ? (device.peripheralID, device.rssi) : nil
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 按规范降序判定：每个整数 dBm 恰好命中一档。
    static func tier(for rssi: Int?) -> Tier {
        guard let rssi, isValid(rssi) else { return .unknown }
        if rssi >= -55 { return .strong }
        if rssi >= -66 { return .good }
        if rssi >= -75 { return .fair }
        if rssi >= -85 { return .weak }
        return .veryWeak
    }

    var tier: Tier { Self.tier(for: rssi) }
    var signalLevel: Int { tier.barCount }

    private let barCount = 4

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Layout.space32, height: Layout.icon24)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let level = signalLevel
        let barWidth: CGFloat = 6
        let gap: CGFloat = 3
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX = rect.midX - totalWidth / 2
        let maxHeight = rect.height
        let heights: [CGFloat] = [0.35, 0.55, 0.75, 1.0]

        for index in 0..<barCount {
            let height = maxHeight * heights[index]
            let barRect = CGRect(
                x: startX + CGFloat(index) * (barWidth + gap),
                y: rect.maxY - height,
                width: barWidth,
                height: height
            )
            let path = UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2)
            let active = index < level
            let color = active ? activeColor(for: level) : Palette.border
            color.setFill()
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }

    /// 颜色按档位着色属于展示选择，不影响档位语义。
    private func activeColor(for level: Int) -> UIColor {
        switch level {
        case 4, 3: return Palette.success
        case 2: return Palette.warning
        case 1: return Palette.danger
        default: return Palette.border
        }
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        guard let rssi, Self.isValid(rssi) else {
            accessibilityLabel = L10n.t("signal.unknown")
            return
        }
        let tierText = L10n.t(tier.localizationKey)
        accessibilityLabel = L10n.f("signal.a11y.known", tierText, String(describing: rssi))
    }
}
