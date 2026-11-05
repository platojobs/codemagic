import UIKit

/// 底部轻提示：自建浮层，高 48、圆角 12、toastSurface 底；同一时刻最多一个。
final class ToastView: UIView {
    private let iconView = UIImageView()
    private let label = UILabel()

    private init(message: String, kind: Kind) {
        super.init(frame: .zero)
        backgroundColor = Palette.toastSurface
        layer.cornerRadius = Radius.card
        layer.cornerCurve = .continuous
        applyElevation(.floating)

        label.text = message
        label.applyFont(AppText.callout.font(weight: .medium))
        label.textColor = Palette.toastText
        label.numberOfLines = 2

        iconView.image = UIImage(
            systemName: kind.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon16, weight: .medium)
        )
        iconView.tintColor = kind.tintColor
        iconView.contentMode = .scaleAspectFit

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .horizontal
        stack.spacing = Layout.space8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.space16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.space16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.buttonH),
            iconView.widthAnchor.constraint(equalToConstant: Layout.icon20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    enum Kind {
        case success, failure, info

        var symbolName: String {
            switch self {
            case .success: return SymbolName.checkmark
            case .failure: return SymbolName.warning
            case .info: return SymbolName.info
            }
        }

        var tintColor: UIColor {
            switch self {
            case .success: return Palette.success
            case .failure: return Palette.danger
            case .info: return Palette.toastText
            }
        }
    }

    /// 挂到当前 key window，距 Tab 栏上方 16；3 秒后自动消失。
    static func show(_ message: String, kind: Kind = .info, in viewController: UIViewController? = nil) {
        let window = viewController?.view.window ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return }
        window.viewWithTag(toastTag)?.removeFromSuperview()

        let toast = ToastView(message: message, kind: kind)
        toast.tag = toastTag
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.leadingAnchor.constraint(equalTo: window.leadingAnchor, constant: Layout.pageMargin),
            toast.trailingAnchor.constraint(equalTo: window.trailingAnchor, constant: -Layout.pageMargin),
            toast.bottomAnchor.constraint(
                equalTo: window.safeAreaLayoutGuide.bottomAnchor,
                constant: -Layout.space16 - Layout.tabBarH
            ),
        ])

        UIView.animate(withDuration: Motion.d200, delay: 0, options: Motion.standardCurve) {
            toast.alpha = 1
        }
        UIView.animate(withDuration: Motion.d150, delay: 3.0, options: Motion.standardCurve) {
            toast.alpha = 0
        } completion: { _ in
            toast.removeFromSuperview()
        }
    }

    private static let toastTag = 9_001
}

private extension SymbolName {
    static let info = "info.circle.fill"
}
