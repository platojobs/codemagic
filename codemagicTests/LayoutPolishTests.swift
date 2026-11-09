import UIKit
import XCTest
@testable import codemagic

/// v0.31.9 UI 打磨的布局回归：空态卡片与分区头随内容 / 字号增长，不再被固定高度裁切。
final class LayoutPolishTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        super.tearDown()
    }

    /// 每个字号档位都新建窗口：标签字体在创建时按当前 trait 选定，复用窗口无法回退到常规字号。
    private func makeHost(category: UIContentSizeCategory) throws -> (UIWindow, UIViewController) {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("iOS 16 及以下无 traitOverrides，无法在单测内模拟 AX 字号")
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIViewController()
        window.rootViewController = host
        window.traitOverrides.preferredContentSizeCategory = category
        window.makeKeyAndVisible()
        windows.append(window)
        return (window, host)
    }

    /// 找出 cell 里所有标签，逐个校验「实际 frame 高度 >= 文本所需高度」，即没有被压掉行。
    private func assertNoVerticalClipping(
        in view: UIView,
        width: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for label in allLabels(in: view) where !(label.text ?? "").isEmpty {
            let needed = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            XCTAssertGreaterThanOrEqual(
                label.frame.height + 0.5,
                needed,
                "「\(label.text ?? "")」frame \(label.frame.height)pt < 需要 \(needed)pt",
                file: file,
                line: line
            )
        }
    }

    /// 场景空态：常规字号下内容需要 228pt，旧分区高度 200pt 会把说明压掉一行；AX5 下需要 403pt。
    func testScenarioEmptyCardSelfSizesAtRegularAndAccessibilitySizes() throws {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let (_, host) = try makeHost(category: category)
            let cell = HomeEmptyCell(frame: .zero)
            cell.configure(
                symbol: "rules",
                title: L10n.t("home.noScenarios"),
                message: L10n.t("home.noScenariosMessage"),
                actionTitle: L10n.t("home.createInSmart"),
                action: {}
            )
            host.view.addSubview(cell)
            let width: CGFloat = 361
            let fitting = cell.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            cell.frame = CGRect(x: 0, y: 0, width: width, height: fitting.height)
            cell.layoutIfNeeded()

            assertNoVerticalClipping(in: cell, width: width)
            // 常规字号就应超过旧的 220pt 固定高度，说明自适配真的生效。
            XCTAssertGreaterThanOrEqual(fitting.height, 220, "\(category.rawValue) 空态卡未按内容撑开")
        }
    }

    /// 分区头：常规字号 40pt；AX5 下 callout 行高约 51pt，旧实现固定 40pt 会切掉上下各 5.7pt。
    func testSectionHeaderGrowsInsteadOfClippingAtAccessibilitySizes() throws {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let (_, host) = try makeHost(category: category)
            let header = SectionHeaderView(title: "Living Room · 3")
            host.view.addSubview(header)
            header.layoutIfNeeded()

            let fitting = header.systemLayoutSizeFitting(
                CGSize(width: 361, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            header.frame = CGRect(x: 0, y: 0, width: 361, height: fitting.height)
            header.layoutIfNeeded()

            assertNoVerticalClipping(in: header, width: 361)
            if category == .accessibilityExtraExtraExtraLarge {
                XCTAssertEqual(fitting.height, 51.33, accuracy: 1, "AX5 分区头应随行高长到约 51pt")
            } else {
                XCTAssertEqual(fitting.height, 40, accuracy: 0.5, "常规字号保持 40pt 视觉高度")
            }
        }
    }

    /// 首页分区头用 `.estimated(40)` 的 boundary supplementary：验证高度确实来自视图自适配而非回落 40pt。
    func testEstimatedSectionHeaderUsesSelfSizingHeight() throws {
        let (_, host) = try makeHost(category: .accessibilityExtraExtraExtraLarge)

        let layout = UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(80))
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(80)),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.boundarySupplementaryItems = [
                NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .estimated(Layout.sectionHeaderH)
                    ),
                    elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top
                ),
            ]
            return section
        }
        let collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 361, height: 480), collectionViewLayout: layout)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "Cell")
        collectionView.register(
            HomeSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "Header"
        )
        collectionView.dataSource = self
        host.view.addSubview(collectionView)
        collectionView.layoutIfNeeded()

        let attributes = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: 0)
        )
        XCTAssertEqual(attributes?.frame.height ?? 0, 51.33, accuracy: 2, "AX5 分区头高度应随字高增长")
    }

    /// 智能页规则卡：AX5 下规则名与说明曾被压成单行（「设备断开…」）。
    /// 横向改为水平栈后宽度确定，自适应行高必须按换行后的内容撑开。
    func testRuleCellWrapsInsteadOfTruncatingAtAccessibilitySizes() throws {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let (_, host) = try makeHost(category: category)
            let cell = RuleCell(style: .default, reuseIdentifier: RuleCell.reuseIdentifier)
            host.view.addSubview(cell)
            // 先让窗口的 trait 传导到 cell，再按该字号配置并测量，等价于表格里 dequeue 后 configure。
            host.view.layoutIfNeeded()
            let rule = DeviceRule(name: "设备断开记录", trigger: .disconnect)
            cell.configure(rule: rule, targetName: "客厅温湿度计") {}
            let width: CGFloat = 393
            let fitting = cell.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            cell.frame = CGRect(x: 0, y: 0, width: width, height: fitting.height)
            cell.layoutIfNeeded()

            for label in allLabels(in: cell) where !(label.text ?? "").isEmpty {
                let needed = label.sizeThatFits(
                    CGSize(width: label.frame.width, height: .greatestFiniteMagnitude)
                ).height
                XCTAssertGreaterThanOrEqual(
                    label.frame.height + 0.5,
                    needed,
                    "\(category.rawValue)「\(label.text ?? "")」被截断"
                )
            }
        }
    }

    /// 市场页的表格分区头：视图已改为 `>= 40`，表格侧必须用 automaticDimension 才能拿到 51pt。
    func testTableSectionHeaderSelfSizesAtAccessibilitySizes() throws {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let (window, host) = try makeHost(category: category)
            let table = UITableView(frame: CGRect(x: 0, y: 0, width: 393, height: 600), style: .plain)
            table.dataSource = self
            table.delegate = self
            table.register(UITableViewCell.self, forCellReuseIdentifier: "PlainCell")
            table.sectionHeaderHeight = UITableView.automaticDimension
            table.estimatedSectionHeaderHeight = Layout.sectionHeaderH
            host.view.addSubview(table)
            window.layoutIfNeeded()
            table.reloadData()
            table.layoutIfNeeded()
            table.layoutIfNeeded()

            let height = table.rectForHeader(inSection: 0).height
            if category == .accessibilityExtraExtraExtraLarge {
                XCTAssertEqual(height, 51.33, accuracy: 1, "AX5 表格分区头应随行高长到约 51pt")
            } else {
                XCTAssertEqual(height, 40, accuracy: 0.5, "常规字号保持 40pt 视觉高度")
            }
        }
    }

    private func allLabels(in view: UIView) -> [UILabel] {
        var result: [UILabel] = []
        if let label = view as? UILabel { result.append(label) }
        for subview in view.subviews {
            result.append(contentsOf: allLabels(in: subview))
        }
        return result
    }
}

extension LayoutPolishTests: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: "PlainCell", for: indexPath)
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        // 与 MarketViewController 相同的容器写法：分区头铺满容器，容器交给表格自适应。
        let container = UIView()
        let header = SectionHeaderView(title: "设备类型")
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.pageMargin),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.pageMargin),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        UITableView.automaticDimension
    }
}

extension LayoutPolishTests: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 1 }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "Cell", for: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: "Header",
            for: indexPath
        )
        (view as? HomeSectionHeaderView)?.configure(title: "Living Room · 3")
        return view
    }
}
