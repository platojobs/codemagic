import UIKit

/// 空内容占位视图：SF Symbol 插画 + 标题 + 说明 + 引导按钮，纯代码 Auto Layout。
///
/// 未使用 iOS 16+ 的 `ContentUnavailableView`，因此在 iOS 15 上同样可用。
final class EmptyStateView: UIView {
    // MARK: - Subviews

    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let stackView = UIStackView()

    // MARK: - State

    private var action: (() -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    func configure(
        symbolName: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.action = action

        // 尺寸交给 preferredSymbolConfiguration 由 Dynamic Type 决定，不写死像素。
        imageView.image = UIImage(systemName: symbolName)
        titleLabel.text = title
        messageLabel.text = message
        actionButton.setTitle(actionTitle, for: .normal)
        actionButton.isHidden = actionTitle == nil
    }

    // MARK: - Private

    private func configureSubviews() {
        imageView.tintColor = AppTheme.Palette.secondaryText
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle)
        imageView.adjustsImageSizeForAccessibilityContentSizeCategory = true
        imageView.isAccessibilityElement = false

        titleLabel.font = AppTheme.Typography.font(.title3)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = AppTheme.Palette.primaryText
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = AppTheme.Typography.font(.body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = AppTheme.Palette.secondaryText
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        actionButton.titleLabel?.font = AppTheme.Typography.font(.headline)
        actionButton.titleLabel?.adjustsFontForContentSizeCategory = true
        actionButton.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
    }

    private func configureHierarchy() {
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = AppTheme.Spacing.small
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(actionButton)
        stackView.setCustomSpacing(AppTheme.Spacing.xLarge, after: messageLabel)

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
        ])
    }
}
