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
        title = "关于"
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
        contentStack.addArrangedSubview(makeTitleLabel("蓝牙设备数据面板"))
        contentStack.addArrangedSubview(makeBodyLabel("版本 \(versionText)"))
        contentStack.addArrangedSubview(makeBodyLabel("接口地址 \(baseURLText)"))

        if let startupWarning {
            contentStack.addArrangedSubview(makeWarningLabel(startupWarning))
        }

        contentStack.addArrangedSubview(makeSectionTitle("权限说明"))
        contentStack.addArrangedSubview(makeBodyLabel(
            "蓝牙用于扫描附近设备、读取信号强度并在设备详情页建立连接。iOS 13 及以上由系统弹窗询问权限，未授权时仅能看到历史本地数据。"
        ))
        contentStack.addArrangedSubview(makeBodyLabel(
            "扫描结果与规则只保存在本机，暂未同步到云端；市场页只展示配件与固件信息，不提供下单与支付。"
        ))

        contentStack.addArrangedSubview(makeSectionTitle("一致性文档"))
        contentStack.addArrangedSubview(makeBodyLabel(
            "五模块命名与顺序、字段命名、错误码、空状态与权限行为见仓库 docs/consistency.md，与 Android 端共用。"
        ))

        contentStack.addArrangedSubview(makeBodyLabel(
            "真机验证项：蓝牙扫描与 RSSI、连接后读取设备信息、系统权限弹窗。模拟器不具备真实蓝牙能力。"
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
