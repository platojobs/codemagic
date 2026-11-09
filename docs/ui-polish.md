# v0.31.9 UI 细节与布局错位走查

本版只做布局与视觉细节收敛，不引入新功能、不引入 SwiftUI。所有结论都来自真实视图层级测量（`codemagicTests/LayoutPolishTests.swift`）与模拟器实拍，不用「已居中 / 已适配」这类无法核对的措辞。

## 1. 测量方法

- **数值来源**：在单元测试宿进程内创建真实 `UIWindow`（393×852，iPhone 18 Pro），用 `traitOverrides.preferredContentSizeCategory` 切到目标字号，调用 `systemLayoutSizeFitting` 取自适应高度，再逐个 `UILabel` 比较 `frame.height` 与 `sizeThatFits(width:)`，差值即被压掉的高度。
- **字号档位**：常规（`UICTContentSizeCategoryL`）与 AX5（`UICTContentSizeCategoryAccessibilityXXXL`）。
- **iPad**：`iPad Pro 13-inch (M5)`，2064×2752，AX5。
- **截图**：`xcrun simctl ui <udid> content_size <档位>` + Debug 构建实拍；iPhone 截图为 1206×2622，iPad 为 2064×2752。
- **复现**：`xcodebuild test -project codemagic.xcodeproj -scheme codemagic -destination 'id=<sim>' -only-testing:codemagicTests/LayoutPolishTests`。

## 2. 修复项与前后数值

### 2.0 市场页表格分区头：固定 40pt 同样裁切

`MarketViewController` 的 `heightForHeaderInSection` 原先固定返回 40pt，与 2.2 是同一类问题。AX5 下真实表格 `rectForHeader(inSection:)` 实测 **51.33pt**，固定 40pt 上下各裁 **5.7pt**。

修复：`tableView.sectionHeaderHeight = UITableView.automaticDimension` + `estimatedSectionHeaderHeight = Layout.sectionHeaderH`，`heightForHeaderInSection` 改为返回 `automaticDimension`。在真实 `UITableView` 中复测：常规 **40pt**、AX5 **51.33pt**（`testTableSectionHeaderSelfSizesAtAccessibilitySizes`）。

### 2.1 首页空态卡：固定高度装不下内容

`HomeDashboardViewController` 的空态分区此前固定 200pt（场景）/ 220pt（房间）/ 280pt（设备），而卡片实际内容在 361pt 宽下：

| 档位 | 内容需要 | 修复前高度 | 被裁掉 | 修复后 |
| --- | --- | --- | --- | --- |
| 常规 | 228pt | 200pt（场景空态） | 28pt（说明少一行、按钮完全不可见） | `.estimated`，实测 228pt |
| AX5 | 403.3pt | 200pt | 203.3pt（标题只剩「这个房间还」） | `.estimated`，实测 403.3pt |

修复：`.scenarioEmpty` / `.roomEmpty` / `.roomsEmpty` / `.devicesEmpty` 一律改为 `NSCollectionLayoutDimension.estimated(...)`；快捷场景卡仍保留 124pt 固定高（内容由卡片自身布局保证，不参与本次改动）。

| 截图 | 对应问题 |
| --- | --- |
| [ui-polish-home-empty-before.png](screenshots/ui-polish-home-empty-before.png) | 修复前常规字号：房间空态卡 220pt，说明只剩一行、底部「扫描附近设备」按钮被切掉 |
| [ui-polish-home-empty-after.png](screenshots/ui-polish-home-empty-after.png) | 修复后常规字号：说明两行完整，按钮可见，卡片按内容长到约 285pt |
| [ui-polish-home-ax-before.png](screenshots/ui-polish-home-ax-before.png) | 修复前 AX5：分区标题被压成单行「这个房间还」并在上下被裁切 |
| [ui-polish-home-ax-after.png](screenshots/ui-polish-home-ax-after.png) | 修复后 AX5：标题两行完整、说明三行 + 按钮完整 |
| [ui-polish-home-ax-bottom-after.png](screenshots/ui-polish-home-ax-bottom-after.png) | 修复后 AX5 滚到底：最后一项完整位于悬浮 Tab 条带上方 |
| [ui-polish-home-ipad-ax-after.png](screenshots/ui-polish-home-ipad-ax-after.png) | iPad 13 英寸 + AX5：空态卡同样按内容撑开，未出现裁切 |

### 2.2 分区头：40pt 固定高切掉上下各 5.7pt

`SectionHeaderView` 与首页 compositional layout 的 boundary supplementary 都固定 40pt。常规字号 callout 行高约 20pt，没问题；AX5 下 callout 行高实测 **51.33pt**，固定 40pt 会上下各裁 **5.7pt**（拉丁文下伸部直接消失）。

修复：视图侧 `heightAnchor >= Layout.sectionHeaderH`，布局侧 `heightDimension = .estimated(Layout.sectionHeaderH)`。实测布局后分区头高度 51.33pt，常规字号仍为 40pt。

### 2.3 智能页规则卡：自适应行高按单行算出

`RuleCell` 的横向约束原本是 `textStack.trailingAnchor <= toggle.leadingAnchor - 12`。`<=` 让文本宽度在自适应行高测量阶段不收敛，`UITableView.automaticDimension` 先按单行算出高度：

| 档位 | 修复前 | 内容需要 | 差异 | 修复后 |
| --- | --- | --- | --- | --- |
| 常规 | 名称 20.33pt / 说明 31.33pt，行高 86.67pt | 与左侧一致 | 无 | 保持 86.67pt，单行紧凑 |
| AX5 | 名称 57.33pt（1 行，渲染为「设备断开…」） | 114.67pt（2 行） | **隐藏 57.34pt** | 名称 114.67pt、说明 196pt，行高 345.67pt |

修复：改成与 `SceneAutomationCell` 一致的水平 `UIStackView`（`[textStack, toggle]`，`alignment = .center`），宽度由栈定死（`equal` 而非 `<=`），标签本身保持 `numberOfLines = 0`（`AppTheme.makeLabel` 的默认值）——不额外按字号切行数。

| 截图 | 对应问题 |
| --- | --- |
| [ui-polish-smart-ax-before.png](screenshots/ui-polish-smart-ax-before.png) | 修复前 AX5：规则名只显示「设备断开…」，说明被卡片底边切断 |
| [ui-polish-smart-ax-after.png](screenshots/ui-polish-smart-ax-after.png) | 修复后 AX5：名称两行「设备断开 / 提醒」完整，无省略号 |
| [ui-polish-smart-ax-bottom-after.png](screenshots/ui-polish-smart-ax-bottom-after.png) | 修复后 AX5 滚到底：最后一张规则卡名称、说明、开关完整，卡片底边在 Tab 之上 |
| [ui-polish-smart-regular-after.png](screenshots/ui-polish-smart-regular-after.png) | 修复后常规字号：两张规则卡仍单行紧凑，内边距与行高一致 |

## 3. 回归测试

`codemagicTests/LayoutPolishTests.swift` 共 5 个用例，全部在真实 `UIWindow` 中按常规 / AX5 两档运行：

1. `testScenarioEmptyCardSelfSizesAtRegularAndAccessibilitySizes`：空态卡常规 228pt、AX5 403.3pt，且不低于内容所需。
2. `testSectionHeaderGrowsInsteadOfClippingAtAccessibilitySizes`：`SectionHeaderView` 常规 40pt、AX5 51.33pt（±1）。
3. `testEstimatedSectionHeaderUsesSelfSizingHeight`：`.estimated(40)` 在真实 compositional layout 中得到 51.33pt（±2）。
4. `testRuleCellWrapsInsteadOfTruncatingAtAccessibilitySizes`：逐标签比较 `frame.height` 与 `sizeThatFits`，常规 / AX5 均无垂直裁切。
5. `testTableSectionHeaderSelfSizesAtAccessibilitySizes`：真实 `UITableView` 表头常规 40pt、AX5 51.33pt。

全量单测 **503 个，0 失败**；e2e **460 通过 / 0 跳过 / 0 失败**（后端 v0.26.0）。

## 4. 检查过但保留为设计取舍的项

- **「我的 → 帮助中心 / 关于 / 扫码日志 / 反馈详情」未加 `applyBottomOcclusionInset`**：这些页面是普通 `UIScrollView`，内容靠安全区自动 inset；实测「关于」滚到底最后一行与悬浮 Tab 仍有 57pt 间距，无遮挡。为了统一而给它们加自定义 inset 反而会多出一段空白，保留现状。
- **`DevicesViewController` / `SavedDeviceCell` 的内边距**：两者当前未被任何入口引用（设备管理已并入首页），调内边距不会出现在任何界面；按「不为改动而改动」保留，待入口恢复时再一并处理。
- **快捷场景卡 124pt 固定高**：常规与 AX 档内容均由卡片自身布局保证完整，保留固定高可以让首页分区高度稳定，不影响可读性。

## 5. 未纳入本轮的问题（如实记录）

`RSISignalView.signalLevel` 的注释写「≥ -90 显示一格」，代码实际在 -84…-90 返回 0 格。这是数据映射与注释不一致，不是布局错位；改动会影响信号格数的语义，需与 Android 端一起确认阈值，本轮不动，留待后续数据口径对齐。
