import UIKit

/// 反馈详情：展示服务端状态与状态说明，允许本人关闭。
/// 关闭后按钮置灰；已关闭再关闭会收到 409，由服务端文案明确提示。
final class FeedbackDetailViewController: UIViewController {
    private let coordinator: FeedbackCoordinator
    private let feedbackID: String

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let card = UIView()
    private let cardStack = UIStackView()
    private let statusLabel = UILabel()
    private let statusMessageLabel = UILabel()
    private let bodyLabel = UILabel()
    private let timeLabel = UILabel()
    private let noticeLabel = UILabel()
    private let closeButton: UIButton
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var detail: FeedbackDetailItem?
    private var isClosing = false

    init(coordinator: FeedbackCoordinator, feedbackID: String) {
        self.coordinator = coordinator
        self.feedbackID = feedbackID
        self.closeButton = AppTheme.makePrimaryButton(title: L10n.t("feedback.detail.close"))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.t("feedback.detail.title")
        view.backgroundColor = Palette.canvas
        configureViews()
        loadDetail()
    }

    private func configureViews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        contentStack.axis = .vertical
        contentStack.spacing = Layout.sectionGap
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Layout.pageMargin),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Layout.pageMargin),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: Layout.pageMargin),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -Layout.pageMargin),
        ])

        AppTheme.styleAsCard(card)
        cardStack.axis = .vertical
        cardStack.spacing = Layout.cardGap
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: Layout.cardPadding),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Layout.cardPadding),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Layout.cardPadding),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Layout.cardPadding),
        ])

        statusLabel.font = AppText.title.font()
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = Palette.primaryText
        statusLabel.numberOfLines = 0

        [statusMessageLabel, bodyLabel, timeLabel].forEach {
            $0.font = AppText.callout.font()
            $0.adjustsFontForContentSizeCategory = true
            $0.numberOfLines = 0
        }
        statusMessageLabel.textColor = Palette.textSecondary
        bodyLabel.textColor = Palette.textPrimary
        timeLabel.textColor = Palette.textTertiary

        [statusLabel, statusMessageLabel, bodyLabel, timeLabel].forEach { cardStack.addArrangedSubview($0) }
        cardStack.setCustomSpacing(Layout.space20, after: bodyLabel)

        noticeLabel.font = AppText.footnote.font()
        noticeLabel.adjustsFontForContentSizeCategory = true
        noticeLabel.textColor = Palette.danger
        noticeLabel.numberOfLines = 0
        noticeLabel.isHidden = true

        closeButton.heightAnchor.constraint(equalToConstant: Layout.buttonH).isActive = true
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        closeButton.accessibilityLabel = L10n.t("feedback.detail.close")

        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(card)
        contentStack.addArrangedSubview(noticeLabel)
        contentStack.addArrangedSubview(closeButton)
        contentStack.addArrangedSubview(activityIndicator)
        activityIndicator.centerXAnchor.constraint(equalTo: contentStack.centerXAnchor).isActive = true

        statusLabel.text = L10n.t("common.loading")
        statusMessageLabel.text = nil
        bodyLabel.text = nil
        timeLabel.text = nil
        closeButton.isEnabled = false
    }

    private func loadDetail() {
        activityIndicator.startAnimating()
        noticeLabel.isHidden = true
        coordinator.fetchDetail(id: feedbackID) { [weak self] result in
            guard let self else { return }
            self.activityIndicator.stopAnimating()
            switch result {
            case .success(let detail):
                self.apply(detail)
            case .failure(let error):
                self.statusLabel.text = L10n.t("feedback.detail.loadFailed")
                self.statusMessageLabel.text = error.localizedDescriptionText
                self.closeButton.isEnabled = false
                self.noticeLabel.isHidden = false
                self.noticeLabel.text = L10n.t("feedback.detail.retryHint")
            }
        }
    }

    private func apply(_ detail: FeedbackDetailItem) {
        self.detail = detail
        statusLabel.text = detail.status.title
        statusMessageLabel.text = detail.statusMessage
        bodyLabel.text = detail.body
        let formatter = Self.dateFormatter
        let created = detail.createdAt.map(formatter.string(from:)) ?? L10n.t("common.unknown")
        let updated = detail.updatedAt.map(formatter.string(from:)) ?? created
        timeLabel.text = L10n.f("feedback.detail.time", created, updated)
        let isClosed = detail.status == .closed
        closeButton.isEnabled = !isClosed
        if isClosed {
            closeButton.setTitle(L10n.t("feedback.detail.closed"), for: .normal)
        }
        updateAccessibility()
    }

    private func updateAccessibility() {
        let parts: [String?] = [
            statusLabel.text,
            statusMessageLabel.text,
            bodyLabel.text,
            timeLabel.text,
        ]
        view.accessibilityLabel = parts.compactMap { $0 }.joined(separator: L10n.t("common.a11ySeparator"))
    }

    @objc private func handleClose() {
        guard !isClosing, detail?.status != .closed else { return }
        isClosing = true
        noticeLabel.isHidden = true
        closeButton.isEnabled = false
        activityIndicator.startAnimating()
        coordinator.close(id: feedbackID) { [weak self] result in
            guard let self else { return }
            self.isClosing = false
            self.activityIndicator.stopAnimating()
            switch result {
            case .success(let detail):
                self.apply(detail)
            case .failure(let failure):
                self.closeButton.isEnabled = true
                self.noticeLabel.isHidden = false
                self.noticeLabel.text = failure.message
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
