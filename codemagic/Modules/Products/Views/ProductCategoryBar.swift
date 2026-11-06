import UIKit

/// 产品目录的类型筛选条：横向胶囊，48pt 触达，选中态用设计令牌。
final class ProductCategoryBar: UIView {
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var onSelect: ((ProductCategoryFilter) -> Void)?
    private var categories: [DeviceCapabilityCategory] = []
    private var selected: ProductCategoryFilter = .all

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        categories: [DeviceCapabilityCategory],
        selected: ProductCategoryFilter,
        onSelect: @escaping (ProductCategoryFilter) -> Void
    ) {
        self.categories = categories
        self.selected = selected
        self.onSelect = onSelect
        rebuild()
    }

    private func configureHierarchy() {
        backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = Layout.space8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Layout.space48 + Layout.space12),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: Layout.pageMargin),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -Layout.pageMargin),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: Layout.space4),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -Layout.space4),
        ])
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items: [(ProductCategoryFilter, String)] = [(.all, L10n.t("products.filter.all"))]
            + categories.map { (.category($0), $0.title) }
        for (filter, title) in items {
            let selectedChip: Bool
            switch (filter, selected) {
            case (.all, .all):
                selectedChip = true
            case let (.category(lhs), .category(rhs)):
                selectedChip = lhs == rhs
            default:
                selectedChip = false
            }
            let button = makeChip(title: title, selected: selectedChip)
            button.accessibilityLabel = title
            button.addAction(UIAction { [weak self] _ in
                self?.onSelect?(filter)
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
            return outgoing
        }
        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.layer.cornerRadius = Radius.pill
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = Stroke.one
        button.clipsToBounds = true
        button.heightAnchor.constraint(equalToConstant: Layout.space48).isActive = true
        button.configuration?.baseForegroundColor = selected ? Palette.primaryText : Palette.textSecondary
        button.backgroundColor = selected ? Palette.chartBand : Palette.surface
        button.layer.borderColor = (selected ? Palette.primary : Palette.border)
            .resolvedColor(with: traitCollection).cgColor
        return button
    }
}
