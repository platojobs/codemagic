import UIKit

/// 推荐规则模板行：标题、说明与一键添加标记。
final class RuleTemplateCell: UITableViewCell {
    static let reuseIdentifier = "RuleTemplateCell"

    private let container = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let addImageView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Palette.overlayPressed
        selected.layer.cornerRadius = Radius.card
        selectedBackgroundView = selected

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
        ])

        titleLabel.applyFont(AppText.body.font(weight: .semibold))
        titleLabel.textColor = Palette.textPrimary
        titleLabel.numberOfLines = 0

        detailLabel.applyFont(AppText.caption.font())
        detailLabel.textColor = Palette.textSecondary
        detailLabel.numberOfLines = 0

        addImageView.image = UIImage(systemName: "plus.circle.fill")
        addImageView.tintColor = Palette.primary
        addImageView.contentMode = .scaleAspectFit
        addImageView.setContentHuggingPriority(.required, for: .horizontal)
        addImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = Layout.space4
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [text, addImageView])
        stack.axis = .horizontal
        stack.spacing = Layout.space12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            addImageView.widthAnchor.constraint(equalToConstant: Layout.icon24),
            addImageView.heightAnchor.constraint(equalToConstant: Layout.icon24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(template: RuleTemplate) {
        titleLabel.text = template.title
        detailLabel.text = template.detail
        accessibilityLabel = L10n.f("smart.recommended.a11y", template.title, template.detail)
        accessibilityTraits = .button
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}

/// 智能页入口行：告诉用户推荐规则来自真实读数。
final class RecommendedEntryCell: UITableViewCell {
    static let reuseIdentifier = "RecommendedEntryCell"

    private let container = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevron = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Palette.overlayPressed
        selected.layer.cornerRadius = Radius.card
        selectedBackgroundView = selected

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
        ])

        titleLabel.applyFont(AppText.body.font(weight: .semibold))
        titleLabel.textColor = Palette.textPrimary
        titleLabel.numberOfLines = 0
        titleLabel.text = L10n.t("smart.section.recommended")

        subtitleLabel.applyFont(AppText.caption.font())
        subtitleLabel.textColor = Palette.textSecondary
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = L10n.t("smart.recommended.entrySubtitle")

        chevron.image = UIImage(systemName: "chevron.right")
        chevron.tintColor = Palette.textTertiary
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = Layout.space4

        let stack = UIStackView(arrangedSubviews: [text, chevron])
        stack.axis = .horizontal
        stack.spacing = Layout.space12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}

/// 推荐规则页：设备选择 + 只按真实指标生成的模板列表。
final class RecommendedRulesViewController: UIViewController {
    private enum Row {
        case template(RuleTemplate)
        case empty
        case error(String)
    }

    private let viewModel: RecommendedRulesViewModel
    private let onAdded: (DeviceRule) -> Void
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let deviceButton = UIButton(type: .system)
    private let subtitleLabel = UILabel()

    init(viewModel: RecommendedRulesViewModel, onAdded: @escaping (DeviceRule) -> Void) {
        self.viewModel = viewModel
        self.onAdded = onAdded
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("smart.recommended.title")
        view.backgroundColor = Palette.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.t("common.cancel"),
            style: .plain,
            target: self,
            action: #selector(close)
        )
        configureHeader()
        configureTable()
        viewModel.onChange = { [weak self] in self?.reload() }
        viewModel.reload()
    }

    private func configureHeader() {
        subtitleLabel.applyFont(AppText.callout.font())
        subtitleLabel.textColor = Palette.textSecondary
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = L10n.t("smart.recommended.subtitle")

        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .medium
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = AppText.callout.font(weight: .medium)
            return outgoing
        }
        deviceButton.configuration = configuration
        deviceButton.showsMenuAsPrimaryAction = true
        deviceButton.contentHorizontalAlignment = .leading
        deviceButton.titleLabel?.adjustsFontForContentSizeCategory = true
        deviceButton.translatesAutoresizingMaskIntoConstraints = false

        let header = UIStackView(arrangedSubviews: [subtitleLabel, deviceButton])
        header.axis = .vertical
        header.spacing = Layout.space12
        header.translatesAutoresizingMaskIntoConstraints = false
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(
            top: Layout.space8,
            left: Layout.pageMargin,
            bottom: Layout.space8,
            right: Layout.pageMargin
        )
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Layout.space8
            ),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Layout.space8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureTable() {
        tableView.backgroundColor = Palette.canvas
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.contentInset.bottom = Layout.space24
        tableView.register(RuleTemplateCell.self, forCellReuseIdentifier: RuleTemplateCell.reuseIdentifier)
        tableView.register(StateCell.self, forCellReuseIdentifier: StateCell.reuseIdentifier)
    }

    private var rows: [Row] {
        if let error = viewModel.lastError {
            return [.error(error.localizedDescription)]
        }
        if viewModel.showsEmptyState {
            return [.empty]
        }
        return viewModel.templates.map { .template($0) }
    }

    private func reload() {
        updateDeviceMenu()
        tableView.reloadData()
    }

    private func updateDeviceMenu() {
        let current = viewModel.selectedDevice?.displayName ?? L10n.t("smart.recommended.noDevices")
        deviceButton.configuration?.title = L10n.f("smart.recommended.deviceSelector", current)
        deviceButton.menu = UIMenu(children: viewModel.devices.map { device in
            UIAction(
                title: device.displayName,
                state: device.id == viewModel.selectedDeviceID ? .on : .off
            ) { [weak self] _ in
                self?.viewModel.selectDevice(device.id)
            }
        })
        deviceButton.isEnabled = viewModel.hasDevices
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

extension RecommendedRulesViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .template(let template):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: RuleTemplateCell.reuseIdentifier, for: indexPath
            ) as? RuleTemplateCell else { return UITableViewCell() }
            cell.configure(template: template)
            return cell
        case .empty:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: StateCell.reuseIdentifier, for: indexPath
            ) as? StateCell else { return UITableViewCell() }
            cell.showEmpty(
                symbol: SymbolName.rule,
                title: viewModel.emptyTitle,
                message: viewModel.emptyMessage,
                actionTitle: nil,
                action: nil
            )
            return cell
        case .error(let message):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: StateCell.reuseIdentifier, for: indexPath
            ) as? StateCell else { return UITableViewCell() }
            cell.showError(message: message) { [weak self] in
                self?.viewModel.reload()
            }
            return cell
        }
    }
}

extension RecommendedRulesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .template(let template) = rows[indexPath.row],
              let rule = viewModel.addTemplate(template)
        else { return }
        onAdded(rule)
        dismiss(animated: true)
    }
}
