import UIKit

/// 自绘 RSSI 信号强度视图：4 根柱状条按 dBm 分档绘制，不使用图片或系统 symbol 组合。
/// 分档口径与 Android 端一致：≥ -55 四格，≥ -67 三格，≥ -78 两格，≥ -90 一格，更低为零格。
final class RSISignalView: UIView {
    // MARK: - State

    var rssi: Int = -100 {
        didSet {
            guard oldValue != rssi else { return }
            setNeedsDisplay()
            updateAccessibility()
        }
    }

    /// 是否处于「未获取到信号」状态（未扫描到该设备）。
    var isSignalUnavailable: Bool = true {
        didSet {
            guard oldValue != isSignalUnavailable else { return }
            setNeedsDisplay()
            updateAccessibility()
        }
    }

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

    // MARK: - Level

    private var signalLevel: Int {
        guard !isSignalUnavailable else { return 0 }
        switch rssi {
        case (-55)...: return 4
        case (-67)...(-56): return 3
        case (-77)...(-68): return 2
        case (-83)...(-78): return 1
        default: return 0
        }
    }

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
        if isSignalUnavailable {
            accessibilityLabel = "信号强度：未获取"
        } else {
            accessibilityLabel = "信号强度：\(rssi) dBm，4 格中的 \(signalLevel) 格"
        }
    }
}
