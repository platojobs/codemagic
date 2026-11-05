import UIKit

/// 关于页：版本、接口配置、权限说明与一致性文档入口。纯代码组装。
final class AboutViewController: UIViewController {
    private let versionText: String
    private let baseURLText: String
    private let startupWarning: String?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    init(versionText: String, baseURLText: String, startupWarning: String?) {
        self.versionText = versionText
        self.baseURLText = baseURLText
        self.startupWarning = startupWarning
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("profile.about")
        view.backgroundColor = AppTheme.Palette.background
        configureLayout()
        buildContent()
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = AppTheme.Spacing.medium
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: AppTheme.Metrics.contentMargins
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -AppTheme.Metrics.contentMargins
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -24
            ),
            contentStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -2 * AppTheme.Metrics.contentMargins
            ),
        ])
    }

    private func buildContent() {
        contentStack.addArrangedSubview(makeTitleLabel(L10n.t("about.appName")))
        contentStack.addArrangedSubview(makeBodyLabel(L10n.f("about.version", String(describing: versionText))))
        contentStack.addArrangedSubview(makeBodyLabel(L10n.f("about.baseURL", String(describing: baseURLText))))

        if let startupWarning {
            contentStack.addArrangedSubview(makeWarningLabel(startupWarning))
        }

        contentStack.addArrangedSubview(makeSectionTitle(L10n.t("about.permissionTitle")))
        contentStack.addArrangedSubview(makeBodyLabel(
            L10n.t("about.permissionBluetooth")
        ))
        contentStack.addArrangedSubview(makeBodyLabel(
            L10n.t("about.dataPolicy")
        ))

        contentStack.addArrangedSubview(makeSectionTitle(L10n.t("about.consistency")))
        contentStack.addArrangedSubview(makeBodyLabel(
            L10n.t("about.consistencyBody")
        ))

        contentStack.addArrangedSubview(makeBodyLabel(
            L10n.t("about.deviceCheck")
        ))
    }

    private func makeTitleLabel(_ text: String) -> UILabel {
        let label = AppTheme.makeLabel(style: .title2, color: AppTheme.Palette.primaryText)
        label.text = text
        return label
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = AppTheme.makeLabel(style: .headline, color: AppTheme.Palette.primaryText)
        label.text = text
        return label
    }

    private func makeBodyLabel(_ text: String) -> UILabel {
        let label = AppTheme.makeLabel(style: .body, color: AppTheme.Palette.secondaryText)
        label.text = text
        return label
    }

    private func makeWarningLabel(_ text: String) -> UILabel {
        let label = AppTheme.makeLabel(style: .footnote, color: AppTheme.Palette.highlight)
        label.text = text
        return label
    }
}
