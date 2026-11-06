import UIKit

/// 帮助中心行：问题常显，答案按需展开。
final class HelpFAQCell: UITableViewCell {
    static let reuseIdentifier = "HelpFAQCell"

    private let container = UIView()
    private let questionLabel = AppTheme.makeLabel(text: .callout, color: Palette.textPrimary)
    private let answerLabel = AppTheme.makeLabel(text: .caption, color: Palette.textSecondary)
    private let chevronView = UIImageView()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .clear
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(question: String, answer: String, expanded: Bool) {
        questionLabel.text = question
        answerLabel.text = answer
        answerLabel.isHidden = !expanded
        chevronView.transform = expanded
            ? CGAffineTransform(rotationAngle: .pi / 2)
            : .identity
        isAccessibilityElement = true
        accessibilityLabel = question
        accessibilityValue = expanded ? answer : nil
        accessibilityHint = expanded ? L10n.t("help.collapse") : L10n.t("help.expand")
        accessibilityTraits = expanded ? [.button, .selected] : .button
    }

    private func configureHierarchy() {
        questionLabel.numberOfLines = 0
        answerLabel.numberOfLines = 0

        chevronView.image = UIImage(
            systemName: SymbolName.disclosure,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Layout.icon16, weight: .medium)
        )
        chevronView.tintColor = Palette.textTertiary
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentHuggingPriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [questionLabel, chevronView])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Layout.space12

        stack.axis = .vertical
        stack.spacing = Layout.space8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(answerLabel)

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.space48),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            chevronView.widthAnchor.constraint(equalToConstant: Layout.icon16),
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}

/// 帮助中心：结构化 FAQ，可展开。文案在 Localizable.strings 中与真实行为逐条对齐。
final class HelpCenterViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let topic: HelpTopic
    private let entries: [HelpCenterEntry]
    private var expandedIDs: Set<String> = []

    init(topic: HelpTopic = .all) {
        self.topic = topic
        self.entries = HelpCenterCatalog.entries(for: topic)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = topic == .all ? L10n.t("help.title") : topic.title
        view.backgroundColor = Palette.canvas
        configureTableView()
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Palette.canvas
        tableView.separatorStyle = .none
        tableView.register(HelpFAQCell.self, forCellReuseIdentifier: HelpFAQCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = Layout.row2
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension HelpCenterViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        entries.isEmpty ? 0 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        topic == .all ? L10n.t("help.section.all") : topic.title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        L10n.t("help.footer")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: HelpFAQCell.reuseIdentifier,
            for: indexPath
        ) as? HelpFAQCell else {
            return UITableViewCell()
        }
        let entry = entries[indexPath.row]
        cell.configure(
            question: L10n.t(entry.questionKey),
            answer: L10n.t(entry.answerKey),
            expanded: expandedIDs.contains(entry.id)
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entries[indexPath.row]
        if expandedIDs.contains(entry.id) {
            expandedIDs.remove(entry.id)
        } else {
            expandedIDs.insert(entry.id)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}
