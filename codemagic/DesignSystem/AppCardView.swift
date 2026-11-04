import UIKit

/// 统一卡片容器：语义背景、圆角与内边距均由设计系统决定。
final class AppCardView: UIView {
    // MARK: - Subviews

    let contentView = UIView()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        AppTheme.styleAsCard(self)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: AppTheme.Spacing.large),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppTheme.Spacing.large),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -AppTheme.Spacing.large),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -AppTheme.Spacing.large),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
