import UIKit

/// 自绘大标题：展开 96（标题 34/40 + 副标题 15），折叠 56（内联标题 22/28）。
/// 滚动阈值 12pt，200ms 标准曲线插值，两个标题交叉淡入，不出现双标题。
final class LargeTitleHeaderView: UIView {
    private let expandedLabel = UILabel()
    private let inlineLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let divider = UIView()
    private(set) var heightConstraint: NSLayoutConstraint!

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = Palette.canvas

        expandedLabel.text = title
        expandedLabel.apply(.display, color: Palette.textPrimary, alignment: .natural)

        inlineLabel.text = title
        inlineLabel.apply(.headline, color: Palette.textPrimary, alignment: .center)
        inlineLabel.applyFont(AppText.headline.font(weight: .semibold))
        inlineLabel.alpha = 0

        subtitleLabel.apply(.callout, color: Palette.textSecondary)

        divider.backgroundColor = Palette.divider
        divider.alpha = 0

        [expandedLabel, inlineLabel, subtitleLabel, divider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: Layout.headerExpanded)

        NSLayoutConstraint.activate([
            expandedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.pageMargin),
            expandedLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.pageMargin),
            expandedLabel.topAnchor.constraint(equalTo: topAnchor, constant: Layout.space8),

            inlineLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            inlineLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            inlineLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Layout.space48),
            inlineLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.space48),

            subtitleLabel.leadingAnchor.constraint(equalTo: expandedLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: expandedLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: expandedLabel.bottomAnchor, constant: Layout.space4),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: Stroke.one),

            heightConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSubtitle(_ text: String) {
        subtitleLabel.text = text
        subtitleLabel.isHidden = text.isEmpty
    }

    /// 0 = 展开，1 = 折叠。
    func apply(progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        heightConstraint.constant = Layout.headerExpanded
            - (Layout.headerExpanded - Layout.navBarH) * clamped
        expandedLabel.alpha = 1 - clamped
        subtitleLabel.alpha = 1 - clamped
        inlineLabel.alpha = clamped
        divider.alpha = clamped
        expandedLabel.transform = CGAffineTransform(translationX: 0, y: -8 * clamped)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        backgroundColor = Palette.canvas
        divider.backgroundColor = Palette.divider
    }
}

/// 把大标题挂到页面顶部，并用 contentInset 让内容从标题下方开始。
final class LargeTitleHost {
    let header: LargeTitleHeaderView
    private weak var scrollView: UIScrollView?
    private var observation: NSKeyValueObservation?
    private var lastProgress: CGFloat = -1
    private let threshold: CGFloat = 12
    private let adjustsContentInset: Bool

    init(
        title: String,
        viewController: UIViewController,
        scrollView: UIScrollView,
        adjustsContentInset: Bool = true
    ) {
        self.header = LargeTitleHeaderView(title: title)
        self.scrollView = scrollView
        self.adjustsContentInset = adjustsContentInset
        header.translatesAutoresizingMaskIntoConstraints = false
        viewController.view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
        ])
        header.heightConstraint.isActive = true
        header.heightConstraint.constant = Layout.headerExpanded

        if adjustsContentInset {
            scrollView.contentInset.top = Layout.headerExpanded
            scrollView.verticalScrollIndicatorInsets.top = Layout.headerExpanded
        }

        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            self?.update(with: scrollView)
        }
        // 导航栏只保留右侧动作，标题由自绘 Header 承担。
        viewController.navigationItem.title = nil
        viewController.navigationItem.largeTitleDisplayMode = .never
    }

    deinit {
        observation?.invalidate()
    }

    func setSubtitle(_ text: String) {
        header.setSubtitle(text)
    }

    private func update(with scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let progress = min(max(offset / threshold, 0), 1)
        guard abs(progress - lastProgress) > 0.01 else { return }
        lastProgress = progress

        UIView.animate(withDuration: Motion.d200, delay: 0, options: Motion.standardCurve) {
            self.header.apply(progress: progress)
            if self.adjustsContentInset {
                self.scrollView?.verticalScrollIndicatorInsets.top = self.header.heightConstraint.constant
            }
            self.header.layoutIfNeeded()
        }
    }
}
