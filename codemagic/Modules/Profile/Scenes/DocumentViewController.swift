import UIKit

/// 本地文档查看器：从 App bundle 读取仓库内的 Markdown / LICENSE 文本。
/// 不打开外部 URL，确保离线与真机都能打开。
final class DocumentViewController: UIViewController {
    private let resourceName: String
    private let fileExtension: String?
    private let textView = UITextView()

    init(titleText: String, resourceName: String, fileExtension: String?) {
        self.resourceName = resourceName
        self.fileExtension = fileExtension
        super.init(nibName: nil, bundle: nil)
        title = titleText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.canvas
        configureTextView()
        loadDocument()
    }

    private func configureTextView() {
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = Palette.surface
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(
            top: Layout.space16,
            left: Layout.pageMargin,
            bottom: Layout.space24,
            right: Layout.pageMargin
        )
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func loadDocument() {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            showMissingDocument()
            return
        }
        textView.attributedText = Self.makeAttributed(text: text, baseURL: url.deletingLastPathComponent())
    }

    private func showMissingDocument() {
        let empty = EmptyStateView()
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.configure(
            symbolName: SymbolName.warning,
            title: L10n.t("about.documentMissingTitle"),
            message: L10n.f("about.documentMissing", resourceName)
        )
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.pageMargin),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.pageMargin),
        ])
        textView.isHidden = true
    }

    private static func makeAttributed(text: String, baseURL: URL?) -> NSAttributedString {
        let parsed: NSAttributedString
        if let markdown = try? NSAttributedString(
            markdown: text,
            options: .init(),
            baseURL: baseURL
        ) {
            parsed = markdown
        } else {
            parsed = NSAttributedString(string: text)
        }

        let mutable = NSMutableAttributedString(attributedString: parsed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: Palette.textPrimary, range: fullRange)
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard let font = value as? UIFont else { return }
            let scaled = UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
            mutable.addAttribute(.font, value: scaled, range: range)
        }
        return mutable
    }
}
