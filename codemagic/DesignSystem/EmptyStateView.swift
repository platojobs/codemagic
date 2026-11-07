import UIKit

/// 空内容占位视图：SF Symbol 插画 + 标题 + 说明 + 主行动。
/// 文案与主行动由调用方传入规范里的真实文案，不显示「暂无数据」。
final class EmptyStateView: UIView {
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = AppButton(style: .secondary, title: L10n.t("common.retry"))
    private let stackView = UIStackView()
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        symbolName: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.action = action
        imageView.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon48, weight: .regular)
        )
        titleLabel.text = title
        titleLabel.apply(.headline, color: Palette.textPrimary, alignment: .center, compatibleWith: traitCollection)
        messageLabel.text = message
        messageLabel.apply(messageStyle(), color: Palette.textSecondary, alignment: .center, compatibleWith: traitCollection)
        var configuration = actionButton.configuration
        configuration?.title = actionTitle
        actionButton.configuration = configuration
        actionButton.isHidden = actionTitle == nil
    }

    private func configureSubviews() {
        imageView.tintColor = Palette.textTertiary
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle)
        imageView.adjustsImageSizeForAccessibilityContentSizeCategory = true
        imageView.isAccessibilityElement = false

        titleLabel.numberOfLines = 0
        messageLabel.numberOfLines = 0

        actionButton.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
    }

    private func configureHierarchy() {
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = Layout.space8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(actionButton)
        stackView.setCustomSpacing(Layout.space24, after: messageLabel)

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.pageMargin),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.pageMargin),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            imageView.heightAnchor.constraint(equalToConstant: Layout.icon64),
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        imageView.tintColor = Palette.textTertiary
        // attributedText 不会自动跟随 Dynamic Type，内容尺寸变化时按当前档位重排。
        if let title = titleLabel.text, !title.isEmpty {
            titleLabel.apply(.headline, color: Palette.textPrimary, alignment: .center, compatibleWith: traitCollection)
        }
        if let message = messageLabel.text, !message.isEmpty {
            messageLabel.apply(messageStyle(), color: Palette.textSecondary, alignment: .center, compatibleWith: traitCollection)
        }
        setNeedsLayout()
    }

    /// AX 档说明文字降为 footnote，避免大字号下长句被拆成过多行。
    private func messageStyle() -> AppText {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .footnote : .body
    }
}
