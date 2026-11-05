import UIKit

/// 加载中占位：系统菊花 + 文案，纯代码构建。
final class LoadingStateView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.secondaryText)
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.startAnimating()
        label.text = L10n.t("common.loading")
        label.textAlignment = .center

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = AppTheme.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: String) {
        label.text = message
    }
}
