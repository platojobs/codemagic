import UIKit

/// 设备类型选择：横向可滚动胶囊，高度保证 48pt 触达。
final class MarketTypeCell: UITableViewCell {
    static let reuseIdentifier = "MarketTypeCell"

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var onChange: ((String) -> Void)?
    private var profiles: [DeviceCompatibilityProfile] = []
    private var selectedID: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        profiles: [DeviceCompatibilityProfile],
        selectedID: String?,
        onChange: @escaping (String) -> Void
    ) {
        self.profiles = profiles
        self.selectedID = selectedID
        self.onChange = onChange
        rebuildChips()
    }

    private func configureHierarchy() {
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = Layout.space8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Layout.space48 + Layout.space12),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: Layout.pageMargin),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -Layout.pageMargin),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: Layout.space4),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -Layout.space4),
        ])
    }

    private func rebuildChips() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for profile in profiles {
            let button = makeChip(title: profile.displayName, selected: profile.id == selectedID)
            button.accessibilityLabel = profile.displayName
            button.addAction(UIAction { [weak self] _ in
                self?.onChange?(profile.id)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }

    private func makeChip(title: String, selected: Bool) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: Layout.space12,
            leading: Layout.space16,
            bottom: Layout.space12,
            trailing: Layout.space16
        )
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = AppText.callout.font(weight: .medium)
            outgoing.foregroundColor = nil
            return outgoing
        }
        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.layer.cornerRadius = Radius.pill
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = Stroke.one
        button.clipsToBounds = true
        button.heightAnchor.constraint(equalToConstant: Layout.space48).isActive = true
        applyChipStyle(button, selected: selected)
        return button
    }

    private func applyChipStyle(_ button: UIButton, selected: Bool) {
        if selected {
            button.backgroundColor = Palette.chartBand
            button.configuration?.baseForegroundColor = Palette.primaryText
            button.layer.borderColor = Palette.primary.resolvedColor(with: traitCollection).cgColor
        } else {
            button.backgroundColor = Palette.surface
            button.configuration?.baseForegroundColor = Palette.textSecondary
            button.layer.borderColor = Palette.border.resolvedColor(with: traitCollection).cgColor
        }
    }
}

/// 示例条目的筛选行：厂商 / 兼容性 / 清除。选项全部来自服务端真实字段。
final class MarketFilterCell: UITableViewCell {
    static let reuseIdentifier = "MarketFilterCell"

    private let vendorButton = UIButton(type: .system)
    private let compatibilityButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let stack = UIStackView()

    var onVendor: (() -> Void)?
    var onCompatibility: (() -> Void)?
    var onReset: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(vendorTitle: String, compatibilityTitle: String, showsReset: Bool) {
        vendorButton.configuration?.title = vendorTitle
        compatibilityButton.configuration?.title = compatibilityTitle
        resetButton.isHidden = !showsReset
    }

    private func configureHierarchy() {
        [vendorButton, compatibilityButton, resetButton].forEach { button in
            var configuration = UIButton.Configuration.gray()
            configuration.cornerStyle = .capsule
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: Layout.space8,
                leading: Layout.space12,
                bottom: Layout.space8,
                trailing: Layout.space12
            )
            button.configuration = configuration
            button.titleLabel?.applyFont(AppText.callout.font())
            button.heightAnchor.constraint(equalToConstant: Layout.space48).isActive = true
        }
        vendorButton.addAction(UIAction { [weak self] _ in self?.onVendor?() }, for: .touchUpInside)
        compatibilityButton.addAction(UIAction { [weak self] _ in self?.onCompatibility?() }, for: .touchUpInside)
        resetButton.addAction(UIAction { [weak self] _ in self?.onReset?() }, for: .touchUpInside)

        resetButton.setTitle(L10n.t("market.clear"), for: .normal)
        resetButton.titleLabel?.applyFont(AppText.callout.font())

        stack.axis = .horizontal
        stack.spacing = Layout.space8
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(
            top: Layout.space4,
            left: Layout.pageMargin,
            bottom: Layout.space4,
            right: Layout.pageMargin
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(vendorButton)
        stack.addArrangedSubview(compatibilityButton)
        stack.addArrangedSubview(resetButton)
        stack.addArrangedSubview(UIView())
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
}
