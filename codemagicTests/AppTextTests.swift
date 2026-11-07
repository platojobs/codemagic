import XCTest
import UIKit
@testable import codemagic

/// 动态字体：字号随内容尺寸类别缩放，关键布局在 AX5 下仍能算出非零高度。
final class AppTextTests: XCTestCase {
    private var traits: [UIContentSizeCategory: UITraitCollection] {
        [
            .large: UITraitCollection(preferredContentSizeCategory: .large),
            .accessibilityExtraExtraExtraLarge: UITraitCollection(
                preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
            ),
        ]
    }

    func testEveryTextTokenScalesAtAccessibilitySize() throws {
        let defaultTrait = try XCTUnwrap(traits[.large])
        let accessibilityTrait = try XCTUnwrap(traits[.accessibilityExtraExtraExtraLarge])

        for token in AppText.allCases {
            let base = token.font(compatibleWith: defaultTrait)
            let scaled = token.font(compatibleWith: accessibilityTrait)
            XCTAssertGreaterThan(base.pointSize, 0, "\(token) 默认字号必须有效")
            XCTAssertGreaterThan(scaled.pointSize, base.pointSize, "\(token) 在 AX5 下必须放大")
        }
    }

    func testApplyFontEnablesDynamicType() {
        let label = UILabel()
        label.applyFont(AppText.body.font())
        XCTAssertTrue(label.adjustsFontForContentSizeCategory)

        let field = UITextField()
        field.applyFont(AppText.callout.font())
        XCTAssertTrue(field.adjustsFontForContentSizeCategory)
    }

    func testAccessibilityTextKeepsNonZeroIntrinsicHeight() throws {
        let trait = try XCTUnwrap(traits[.accessibilityExtraExtraExtraLarge])
        let label = UILabel()
        label.applyFont(AppText.body.font(compatibleWith: trait))
        label.numberOfLines = 0
        label.text = "Device readings and recommended rules stay readable at the largest text size."

        let size = label.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        XCTAssertGreaterThan(size.height, 0, "AX5 下文本固有高度不能为 0")
    }

    func testSavedDeviceCellAndRuleCellReportHeightAtAX5() throws {
        let category = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        let device = makeSavedDevice(name: "客厅温湿度计（带长名称用于折行验证）")
        let rule = DeviceRule(
            name: "温度超过 30℃ 时提醒",
            trigger: .readingThreshold,
            metric: .temperature,
            comparison: .greaterThan,
            readingThreshold: 30,
            consecutive: 1,
            deviceID: device.id
        )

        let deviceCell = SavedDeviceCell(style: .default, reuseIdentifier: nil)
        deviceCell.configure(device: device, isConnected: false)
        let ruleCell = RuleCell(style: .default, reuseIdentifier: nil)
        ruleCell.configure(rule: rule, targetName: device.displayName, onToggle: {})

        for cell in [deviceCell, ruleCell] {
            let host = host(cell, category: category)
            host.layoutIfNeeded()
            let height = cell.systemLayoutSizeFitting(
                CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            XCTAssertGreaterThan(height, 0, "\(type(of: cell)) 在 AX5 下固有高度不能为 0")
        }
    }

    /// 把 cell 放进带内容尺寸类别覆盖的容器，让 `adjustsFontForContentSizeCategory` 真正生效。
    private func host(_ view: UIView, category: UIContentSizeCategory) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        if #available(iOS 17.0, *) {
            container.traitOverrides.preferredContentSizeCategory = category
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        return container
    }
}
