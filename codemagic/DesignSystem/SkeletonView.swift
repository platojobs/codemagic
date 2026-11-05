import UIKit

/// 骨架屏：延迟 300ms 出现、最短展示 300ms，尺寸与真实内容一致。
///
/// 只负责绘制，何时出现 / 消失由 `SkeletonController` 控制。
final class SkeletonView: UIView {
    private let shimmer = CAGradientLayer()
    private var blocks: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shimmer.frame = bounds
        shimmer.cornerRadius = Radius.sm
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            shimmer.removeAllAnimations()
        } else if UIAccessibility.isReduceMotionEnabled {
            shimmer.removeAllAnimations()
        } else if shimmer.animation(forKey: "shimmer") == nil {
            startShimmer()
        }
    }

    // MARK: - Factory

    /// 列表骨架：5 行 × 72，左侧 40×40，标题 56%、副标题 36%、尾部 32×12。
    static func list(rows: Int = 5, rowHeight: CGFloat = Layout.row2) -> SkeletonView {
        let skeleton = SkeletonView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Layout.space12
        stack.translatesAutoresizingMaskIntoConstraints = false
        skeleton.addSubview(stack)

        for _ in 0..<rows {
            let row = UIView()
            let icon = skeleton.block(width: Layout.icon40, height: Layout.icon40, radius: Radius.sm)
            let title = skeleton.block(width: 160, height: Layout.space16, radius: Radius.xs)
            let subtitle = skeleton.block(width: 100, height: Layout.space12, radius: Radius.xs)
            let tail = skeleton.block(width: Layout.space32, height: Layout.space12, radius: Radius.xs)

            let text = UIStackView(arrangedSubviews: [title, subtitle])
            text.axis = .vertical
            text.spacing = Layout.space8

            [icon, text, tail].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview($0)
            }
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: rowHeight),
                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Layout.space12),
                text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                tail.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                tail.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                tail.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: Layout.space12),
            ])
            stack.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: skeleton.topAnchor, constant: Layout.space16),
            stack.leadingAnchor.constraint(equalTo: skeleton.leadingAnchor, constant: Layout.pageMargin),
            stack.trailingAnchor.constraint(equalTo: skeleton.trailingAnchor, constant: -Layout.pageMargin),
        ])
        return skeleton
    }

    /// 卡片网格骨架：2 列，高度与设备卡片一致。
    static func grid(cards: Int = 4, cardHeight: CGFloat = 132) -> SkeletonView {
        let skeleton = SkeletonView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Layout.cardGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        skeleton.addSubview(stack)
        for _ in 0..<max(1, cards / 2) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = Layout.cardGap
            row.distribution = .fillEqually
            for _ in 0..<2 {
                let card = UIView()
                card.layer.cornerRadius = Radius.card
                card.layer.borderWidth = Stroke.one
                card.layer.borderColor = Palette.divider.resolvedColor(with: skeleton.traitCollection).cgColor
                [skeleton.block(width: 120, height: Layout.space16, radius: Radius.xs),
                 skeleton.block(width: 72, height: Layout.space12, radius: Radius.xs),
                 skeleton.block(width: 40, height: Layout.space12, radius: Radius.xs)].forEach {
                    card.addSubview($0)
                    $0.translatesAutoresizingMaskIntoConstraints = false
                }
                let children = card.subviews
                NSLayoutConstraint.activate([
                    card.heightAnchor.constraint(equalToConstant: cardHeight),
                    children[0].leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Layout.cardPadding),
                    children[0].topAnchor.constraint(equalTo: card.topAnchor, constant: Layout.cardPadding),
                    children[1].leadingAnchor.constraint(equalTo: children[0].leadingAnchor),
                    children[1].topAnchor.constraint(equalTo: children[0].bottomAnchor, constant: Layout.space12),
                    children[2].leadingAnchor.constraint(equalTo: children[0].leadingAnchor),
                    children[2].bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Layout.cardPadding),
                ])
                row.addArrangedSubview(card)
            }
            stack.addArrangedSubview(row)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: skeleton.topAnchor),
            stack.leadingAnchor.constraint(equalTo: skeleton.leadingAnchor, constant: Layout.pageMargin),
            stack.trailingAnchor.constraint(equalTo: skeleton.trailingAnchor, constant: -Layout.pageMargin),
        ])
        return skeleton
    }

    // MARK: - Private

    private func block(width: CGFloat, height: CGFloat, radius: CGFloat) -> UIView {
        let view = UIView()
        view.backgroundColor = Palette.skeletonBase
        view.layer.cornerRadius = radius
        blocks.append(view)
        return view
    }

    private func startShimmer() {
        shimmer.colors = [
            Palette.skeletonBase.cgColor,
            Palette.skeletonHighlight.cgColor,
            Palette.skeletonBase.cgColor,
        ]
        shimmer.locations = [0, 0.5, 1]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.frame = bounds
        layer.addSublayer(shimmer)

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1.0, -0.5, 0.0]
        animation.toValue = [1.0, 1.5, 2.0]
        animation.duration = 1.2
        animation.repeatCount = .infinity
        animation.timingFunction = Motion.linear
        shimmer.add(animation, forKey: "shimmer")
    }

    deinit {
        shimmer.removeAllAnimations()
    }
}

/// 延迟展示骨架：开始后 300ms 才出现；出现后至少保留 300ms。
final class SkeletonController {
    private weak var host: UIView?
    private var overlay: UIView?
    private var showWorkItem: DispatchWorkItem?
    private var shownAt: Date?
    private var hideWorkItem: DispatchWorkItem?

    init(host: UIView) {
        self.host = host
    }

    /// 调用方在开始加载时调用；`make` 返回与真实内容同高的骨架。
    func begin(make: @escaping () -> UIView, delay: TimeInterval = Motion.d300) {
        cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let host = self.host else { return }
            let skeleton = make()
            skeleton.frame = host.bounds
            skeleton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(skeleton)
            self.overlay = skeleton
            self.shownAt = Date()
        }
        showWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// 内容到达：若骨架出现过，至少保留 300ms 后 200ms 淡出。
    func end() {
        showWorkItem?.cancel()
        showWorkItem = nil
        guard let overlay else { return }
        let elapsed = Date().timeIntervalSince(shownAt ?? Date())
        let remaining = max(0, 0.3 - elapsed)
        let workItem = DispatchWorkItem { [weak self, weak overlay] in
            guard let overlay else { return }
            UIView.animate(withDuration: Motion.d200, animations: {
                overlay.alpha = 0
            }, completion: { _ in
                overlay.removeFromSuperview()
                self?.overlay = nil
            })
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: workItem)
    }

    func cancel() {
        showWorkItem?.cancel()
        hideWorkItem?.cancel()
        overlay?.removeFromSuperview()
        overlay = nil
        showWorkItem = nil
        hideWorkItem = nil
    }
}
