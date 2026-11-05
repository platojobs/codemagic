import UIKit

/// 错误块：图标 + 标题 + 说明 + 可重试按钮；模块级 240 高，卡内 120 高。
final class ErrorStateView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = AppButton(style: .secondary, title: L10n.t("common.retry"), symbolName: SymbolName.refresh)
    private var retryAction: (() -> Void)?

    init(height: CGFloat = 240) {
        super.init(frame: .zero)
        configureSubviews()
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, message: String, retryTitle: String = L10n.t("common.retry"), action: (() -> Void)?) {
        titleLabel.text = title
        titleLabel.apply(.callout, color: Palette.textPrimary)
        messageLabel.text = message
        messageLabel.apply(.caption, color: Palette.textSecondary)
        retryButton.isHidden = action == nil
        retryAction = action
        if let action {
            retryButton.removeTarget(nil, action: nil, for: .touchUpInside)
            retryButton.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
    }

    private func configureSubviews() {
        iconView.image = UIImage(
            systemName: SymbolName.warning,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon20, weight: .medium)
        )
        iconView.tintColor = Palette.danger
        iconView.contentMode = .scaleAspectFit

        titleLabel.numberOfLines = 0
        messageLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        textStack.axis = .vertical
        textStack.spacing = Layout.space4

        let header = UIStackView(arrangedSubviews: [iconView, textStack])
        header.axis = .horizontal
        header.spacing = Layout.space8
        header.alignment = .top

        let content = UIStackView(arrangedSubviews: [header, retryButton])
        content.axis = .vertical
        content.spacing = Layout.space16
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.cardPadding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.cardPadding),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Layout.cardPadding),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.cardPadding),
            iconView.widthAnchor.constraint(equalToConstant: Layout.icon24),
            iconView.heightAnchor.constraint(equalToConstant: Layout.icon24),
        ])
    }
}
