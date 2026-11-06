import UIKit

/// 意见反馈：类型 + 描述 + 可选联系方式。
///
/// 当前没有反馈接收接口，提交只写入本机 SQLite 待发队列，界面如实标注「未发送」；
/// 支持重试（只记录尝试次数）与删除，绝不伪造发送成功。
final class FeedbackViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case form
        case submit
        case queue
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let store: FeedbackStore

    private var drafts: [FeedbackDraft] = []
    private var loadError: Error?
    private var category: FeedbackCategory = .bug
    private var messageText = ""
    private var contactText = ""

    init(store: FeedbackStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("feedback.title")
        view.backgroundColor = Palette.canvas
        configureTableView()
        loadDrafts()
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Palette.canvas
        tableView.separatorStyle = .none
        tableView.register(FeedbackTextCell.self, forCellReuseIdentifier: FeedbackTextCell.reuseIdentifier)
        tableView.register(FeedbackFieldCell.self, forCellReuseIdentifier: FeedbackFieldCell.reuseIdentifier)
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

    private func loadDrafts() {
        do {
            drafts = try store.fetchAll()
            loadError = nil
        } catch {
            loadError = error
            drafts = []
        }
        tableView.reloadData()
    }

    private func submit() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            ToastView.show(L10n.t("feedback.messageRequired"), kind: .failure, in: self)
            return
        }
        do {
            _ = try store.insert(
                category: category,
                message: trimmed,
                contact: contactText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            messageText = ""
            contactText = ""
            loadDrafts()
            ToastView.show(L10n.t("feedback.savedUnsent"), kind: .info, in: self)
        } catch {
            ToastView.show(
                L10n.f("feedback.saveFailed", String(describing: error.localizedDescription)),
                kind: .failure,
                in: self
            )
        }
    }

    private func retry(_ draft: FeedbackDraft) {
        do {
            _ = try store.recordAttempt(id: draft.id)
            loadDrafts()
            ToastView.show(L10n.t("feedback.retryUnavailable"), kind: .info, in: self)
        } catch {
            ToastView.show(
                L10n.f("feedback.retryFailed", String(describing: error.localizedDescription)),
                kind: .failure,
                in: self
            )
        }
    }

    private func delete(_ draft: FeedbackDraft) {
        do {
            try store.delete(id: draft.id)
            loadDrafts()
            ToastView.show(L10n.t("feedback.deleted"), kind: .info, in: self)
        } catch {
            ToastView.show(
                L10n.f("feedback.deleteFailed", String(describing: error.localizedDescription)),
                kind: .failure,
                in: self
            )
        }
    }

    private func presentCategoryPicker(sourceView: UIView) {
        let sheet = UIAlertController(title: L10n.t("feedback.category"), message: nil, preferredStyle: .actionSheet)
        for category in FeedbackCategory.allCases {
            let title = category == self.category ? "✓ \(category.title)" : category.title
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.category = category
                self?.tableView.reloadRows(
                    at: [IndexPath(row: 0, section: Section.form.rawValue)],
                    with: .automatic
                )
            })
        }
        sheet.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView
        sheet.popoverPresentationController?.sourceRect = sourceView.bounds
        present(sheet, animated: true)
    }

    private func presentDraftDetail(_ draft: FeedbackDraft) {
        let alert = UIAlertController(
            title: L10n.t("feedback.detailTitle"),
            message: draft.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.t("feedback.retry"), style: .default) { [weak self] _ in
            self?.retry(draft)
        })
        alert.addAction(UIAlertAction(title: L10n.t("feedback.delete"), style: .destructive) { [weak self] _ in
            self?.delete(draft)
        })
        alert.addAction(UIAlertAction(title: L10n.t("common.cancel"), style: .cancel))
        present(alert, animated: true)
    }
}

extension FeedbackViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let sectionKind = Section(rawValue: section) else { return 0 }
        switch sectionKind {
        case .form: return 3
        case .submit: return 1
        case .queue: return max(1, drafts.count)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionKind = Section(rawValue: section) else { return nil }
        switch sectionKind {
        case .form: return L10n.t("feedback.section.form")
        case .submit: return nil
        case .queue:
            return drafts.isEmpty
                ? L10n.t("feedback.section.queue")
                : L10n.f("feedback.section.queueCount", String(describing: drafts.count))
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionKind = Section(rawValue: section) else { return nil }
        switch sectionKind {
        case .submit: return L10n.t("feedback.note")
        case .queue where loadError != nil: return L10n.t("feedback.loadFailed")
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let sectionKind = Section(rawValue: indexPath.section) else { return UITableViewCell() }
        switch sectionKind {
        case .form:
            switch indexPath.row {
            case 0:
                return makeCategoryCell()
            case 1:
                return makeMessageCell()
            default:
                return makeContactCell()
            }

        case .submit:
            let cell = UITableViewCell()
            var configuration = UIListContentConfiguration.cell()
            configuration.text = L10n.t("feedback.submit")
            configuration.textProperties.font = AppText.callout.font(weight: .medium)
            configuration.textProperties.color = Palette.primaryText
            configuration.textProperties.alignment = .center
            cell.contentConfiguration = configuration
            cell.backgroundColor = Palette.surface
            cell.accessibilityTraits = .button
            cell.accessibilityLabel = L10n.t("feedback.submit")
            return cell

        case .queue:
            guard !drafts.isEmpty else {
                let cell = UITableViewCell()
                var configuration = UIListContentConfiguration.cell()
                configuration.text = loadError == nil
                    ? L10n.t("feedback.queue.empty")
                    : L10n.t("feedback.loadFailed")
                configuration.textProperties.font = AppText.caption.font()
                configuration.textProperties.color = Palette.textSecondary
                cell.contentConfiguration = configuration
                cell.selectionStyle = .none
                cell.backgroundColor = .clear
                return cell
            }
            return makeQueueCell(draft: drafts[indexPath.row])
        }
    }

    private func makeCategoryCell() -> UITableViewCell {
        let cell = UITableViewCell()
        var configuration = UIListContentConfiguration.valueCell()
        configuration.text = L10n.t("feedback.category")
        configuration.textProperties.font = AppText.body.font()
        configuration.textProperties.color = Palette.textPrimary
        configuration.secondaryText = category.title
        configuration.secondaryTextProperties.font = AppText.body.font()
        configuration.secondaryTextProperties.color = Palette.textSecondary
        cell.contentConfiguration = configuration
        cell.accessoryType = .disclosureIndicator
        cell.backgroundColor = Palette.surface
        cell.accessibilityLabel = L10n.f("feedback.categoryValue", category.title)
        return cell
    }

    private func makeMessageCell() -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: FeedbackTextCell.reuseIdentifier
        ) as? FeedbackTextCell else {
            return UITableViewCell()
        }
        cell.configure(
            title: L10n.t("feedback.description"),
            placeholder: L10n.t("feedback.descriptionPlaceholder"),
            text: messageText
        ) { [weak self] text in
            self?.messageText = text
        }
        return cell
    }

    private func makeContactCell() -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: FeedbackFieldCell.reuseIdentifier
        ) as? FeedbackFieldCell else {
            return UITableViewCell()
        }
        cell.configure(
            title: L10n.t("feedback.contact"),
            placeholder: L10n.t("feedback.contactPlaceholder"),
            text: contactText
        ) { [weak self] text in
            self?.contactText = text
        }
        return cell
    }

    private func makeQueueCell(draft: FeedbackDraft) -> UITableViewCell {
        let cell = UITableViewCell()
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = draft.message
        configuration.textProperties.font = AppText.callout.font()
        configuration.textProperties.color = Palette.textPrimary
        configuration.textProperties.numberOfLines = 2
        let attempts = draft.attempts > 0
            ? L10n.f("feedback.statusWithAttempts", draft.statusText, String(describing: draft.attempts))
            : draft.statusText
        configuration.secondaryText = attempts
        configuration.secondaryTextProperties.font = AppText.caption.font()
        configuration.secondaryTextProperties.color = Palette.warning
        cell.contentConfiguration = configuration
        cell.backgroundColor = Palette.surface
        cell.accessibilityLabel = [draft.message, attempts].joined(separator: L10n.t("common.a11ySeparator"))
        return cell
    }
}

extension FeedbackViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let sectionKind = Section(rawValue: indexPath.section) else { return }
        switch sectionKind {
        case .form where indexPath.row == 0:
            guard let cell = tableView.cellForRow(at: indexPath) else { return }
            presentCategoryPicker(sourceView: cell)
        case .submit:
            submit()
        case .queue:
            guard drafts.indices.contains(indexPath.row) else { return }
            presentDraftDetail(drafts[indexPath.row])
        default:
            break
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .queue,
              drafts.indices.contains(indexPath.row)
        else { return nil }
        let draft = drafts[indexPath.row]

        let delete = UIContextualAction(style: .destructive, title: L10n.t("feedback.delete")) {
            [weak self] _, _, completion in
            self?.delete(draft)
            completion(true)
        }
        let retry = UIContextualAction(style: .normal, title: L10n.t("feedback.retry")) {
            [weak self] _, _, completion in
            self?.retry(draft)
            completion(true)
        }
        retry.backgroundColor = Palette.primary
        return UISwipeActionsConfiguration(actions: [delete, retry])
    }
}

/// 描述输入：标题 + 多行 UITextView（关闭内部滚动，随文本增高）。
final class FeedbackTextCell: UITableViewCell {
    static let reuseIdentifier = "FeedbackTextCell"

    private let container = UIView()
    private let titleLabel = AppTheme.makeLabel(text: .callout, color: Palette.textPrimary)
    private let textView = UITextView()
    private let placeholderLabel = AppTheme.makeLabel(text: .body, color: Palette.textDisabled)
    private var onTextChange: ((String) -> Void)?

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

    func configure(title: String, placeholder: String, text: String, onTextChange: @escaping (String) -> Void) {
        titleLabel.text = title
        placeholderLabel.text = placeholder
        textView.text = text
        placeholderLabel.isHidden = !text.isEmpty
        self.onTextChange = onTextChange
        textView.accessibilityLabel = title
    }

    private func configureHierarchy() {
        textView.font = AppText.body.font()
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = Palette.textPrimary
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(
            top: Layout.space8,
            left: 0,
            bottom: Layout.space8,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self

        placeholderLabel.numberOfLines = 0

        let textContainer = UIView()
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.addSubview(textView)
        textContainer.addSubview(placeholderLabel)
        textView.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [titleLabel, textContainer])
        stack.axis = .vertical
        stack.spacing = Layout.space8
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            textContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.row3),
            textView.topAnchor.constraint(equalTo: textContainer.topAnchor),
            textView.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textContainer.topAnchor, constant: Layout.space8),
            placeholderLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
        ])
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}

extension FeedbackTextCell: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        onTextChange?(textView.text)
    }
}

/// 联系方式输入：标题 + 单行 UITextField。
final class FeedbackFieldCell: UITableViewCell {
    static let reuseIdentifier = "FeedbackFieldCell"

    private let container = UIView()
    private let titleLabel = AppTheme.makeLabel(text: .callout, color: Palette.textPrimary)
    private let textField = UITextField()
    private var onTextChange: ((String) -> Void)?

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

    func configure(title: String, placeholder: String, text: String, onTextChange: @escaping (String) -> Void) {
        titleLabel.text = title
        textField.placeholder = placeholder
        textField.text = text
        self.onTextChange = onTextChange
        textField.accessibilityLabel = title
    }

    private func configureHierarchy() {
        textField.font = AppText.body.font()
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = Palette.textPrimary
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.keyboardType = .emailAddress
        textField.addTarget(self, action: #selector(handleChange), for: .editingChanged)

        let stack = UIStackView(arrangedSubviews: [titleLabel, textField])
        stack.axis = .vertical
        stack.spacing = Layout.space8
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.styleAsCardSurface()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.space4),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.pageMargin),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.pageMargin),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.space4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.cardPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.cardPadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.space12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Layout.space12),
            textField.heightAnchor.constraint(equalToConstant: Layout.space48),
        ])
    }

    @objc private func handleChange() {
        onTextChange?(textField.text ?? "")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        container.refreshDynamicLayerColors()
    }
}
