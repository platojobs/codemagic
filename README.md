# BLE 设备数据面板（codemagic · iOS）

纯 **Swift + UIKit（纯代码，无 Storyboard / XIB / SwiftUI）** 实现的蓝牙设备数据面板，与 Android 端 [`PKotlinApp`](https://github.com/platojobs/PKotlinApp) 共用五模块命名、数据结构与 RSSI 口径。无第三方 UI 库、无假数据、无交易 / 广告 / 支付。

- 行为口径：[docs/consistency.md](docs/consistency.md)
- 结构与分层：[docs/architecture.md](docs/architecture.md)
- 真机验收：[docs/acceptance.md](docs/acceptance.md)
- 故障排查：[docs/troubleshooting.md](docs/troubleshooting.md)
- 版本记录：[docs/releasenotes.md](docs/releasenotes.md)
- 真实 Postgres 联调：[docs/e2e-postgres.md](docs/e2e-postgres.md)

## 当前状态

| 项 | 结果 |
| --- | --- |
| 版本 | **v0.31.11**（`MARKETING_VERSION 0.31.11`，`CURRENT_PROJECT_VERSION 52`，tag `v0.31.11`） |
| 本版主题 | 设备详情在本机连接后每 2 秒 `readRSSI` 刷新信号与读数时间；断开 / 页面退出 / 进后台自动停表；刷新失败保留上次值并标记；未连接仍显示最近扫描值并标注来源 |
| 五模块 | 首页 / 智能 / 产品 / 市场 / 我的；设备管理并入首页，规则与场景集中在「智能」 |
| 核心能力 | BLE 扫描 / 连接 / 四特征读数采集、服务端类型目录、1h–30d 图表、家庭与房间、同步与推送注册、中英双语与动态字体 |
| 单元测试 | **517 个用例，0 失败**（Xcode 27.2 / iPhone 17 模拟器，`** TEST SUCCEEDED **`；v0.31.11 新增 5 个 RSSI 刷新用例） |
| e2e | **460 通过 / 0 跳过 / 0 失败**（本地 `PJGoIoT` v0.26.0，fixture）；CI pin v0.25.0 时 presence 相关 2 项显式 `[SKIP]` |
| 模拟器构建 | `** BUILD SUCCEEDED **` |
| CI | [main run 43371289145](https://github.com/platojobs/codemagic/actions/runs/43371289145) / [tag run 43371299130](https://github.com/platojobs/codemagic/actions/runs/43371299130)，均 success |
| 真机 / 签名 | **未验证**：无真机、无 Apple 开发者账号；BLE、后台任务、APNs 需真机自测 |
| 上架 | **未上架**：材料已备，无 App Store Connect 上传与审核记录 |

> **CI 覆盖边界**：`.github/workflows/ios.yml` 仍 pin `PJGoIoT` **v0.25.0**，`presence` / `lastSeenAt` 是 v0.26.0 字段。CI 的 460 项 e2e 不包含这两个字段的取值断言（显式 `[SKIP]` 并打印原因）。本地 v0.26.0 的 `e2e-contract` 与真 Postgres 的 `e2e-postgres` 已覆盖。不要把 CI 全绿误认为新字段已覆盖。

## 界面截图

模拟器 + 本机后端 + seed 数据；同名文件在 `docs/screenshots/`，iPad 在 `docs/screenshots/ipad-13/`。

| 页面 | iPhone | 大字号 / 特殊态 |
| --- | --- | --- |
| 首页 | [home.png](docs/screenshots/home.png) · [底部](docs/screenshots/home-bottom.png) · [200%](docs/screenshots/home-200.png) | [AX](docs/screenshots/home-ax.png) · [AX 底部](docs/screenshots/home-ax-bottom.png) |
| 产品 | [products.png](docs/screenshots/products.png) | [详情](docs/screenshots/product-detail.png) |
| 市场 | [market.png](docs/screenshots/market.png) | — |
| 我的 | [profile.png](docs/screenshots/profile.png) | [账号与数据](docs/screenshots/account-data.png) · [会话](docs/screenshots/sessions.png) |
| 智能 | [scenes.png](docs/screenshots/scenes.png) | [AX](docs/screenshots/scenes-ax.png) · [场景详情](docs/screenshots/scene-detail.png) |
| 房间 | [rooms.png](docs/screenshots/rooms.png) | [详情](docs/screenshots/room-detail.png) · [AX5](docs/screenshots/room-detail-ax5.png) · [iPad](docs/screenshots/room-detail-ipad.png) |
| 家庭 | [households.png](docs/screenshots/households.png) | [成员只读](docs/screenshots/households-list.png) |
| 反馈 | [列表](docs/screenshots/feedback-list.png) | [详情](docs/screenshots/feedback-detail.png) |
| 布局回归 | [空态](docs/screenshots/ui-polish-home-empty-after.png) | [AX 前](docs/screenshots/ui-polish-home-ax-before.png) / [后](docs/screenshots/ui-polish-home-ax-after.png) |

截图由 `scripts/seed-demo-data.sh` 生成同源数据后拍摄；验证细节以单测 / e2e 为准，不再逐图说明。

## 五模块能力

### 首页

- `CBCentralManager` 真实扫描，展示名称 / 标识符 / RSSI；扫描会话写本地日志。
- 已保存设备卡片：备注名、连接状态、最近读数、信号条、最后出现时间；按房间分段，房间标题可展开 / 收起，「未分配」固定最后。
- 搜索别名 / 广播名 / 型号 / 标识符；排序最近出现 / 名称 / 信号 / 添加时间，默认最近出现并持久化。
- 卡片长按「详情 / 移入房间 / 编辑 / 删除」；点卡片进详情。
- 今日告警摘要取当天真实触发条数；下方快捷场景横向卡，点击执行并提示结果。
- 空态真实：无房间、房间内无设备、搜索无结果分别给主行动。

### 智能

- 本地规则：断开、RSSI 低于阈值、指标阈值；可绑定单台设备或全部设备，启停 / 删除持久化。
- 指标阈值：指标 + 比较符 + 阈值 + 连续 N 条（1–5，默认 1），判定接在读数落库之后；恢复只在确实发过通知后补一条。
- 推荐规则只按设备真实出现过的指标生成，不列出没有的指标。
- 阈值告警通知：首次命中请求授权，1 / 5 / 30 分钟节流（默认 5），点击通知进详情。
- 场景：服务端场景（离线 / RSSI / 指标 / 定时 + 通知 / 日志 / 标记，五字段 LWW）+ 仅本机手动场景（连接 / 断开 / 采集 / 静音 / 同步）。

### 产品 / 市场

- 型号库：厂商、型号、固件、GATT 服务与特征；数据来自 `GET /catalog/device-types` + `GET /device-types/{type}/catalog`。
- 目录有缓存先渲染再异步刷新；单个 catalog 失败降级为型号信息，全部失败给错误空状态 + 重试。
- 市场按真实厂商与兼容性筛选，可叠加、可一键清除；页脚明确不提供下单 / 订单 / 支付。

### 设备详情

- 云端记录优先展示 `deviceType` / `vendor` / `firmwareVersion` / `compatibility`，`null` 显示「型号未知 / —」，绝不出 `"null"`。
- 信号行：dBm、4 格档位、读数时间。本机连接后每 2 秒 `readRSSI` 刷新（与 Android 一致），断开 / 退出页面 / 进后台停表；未连接显示最近一次扫描值并标注来源；刷新失败保留上次值并标记；非法值（非负 / 读取失败且无历史值）走未知态，不显示 dBm 与满格。
- 数据区：1h / 24h / 7d / 30d 图表、桶点选、汇总、最近记录、离线标注；CSV 导出 7 天内本地、更长走服务端分页。
- 房间归属先落本机再 `PATCH`，失败保留 pending；跨平台设备标注「来自 Android，本机不可连接」。

### 我的

- 蓝牙 / 通知权限自检与跳转系统设置；本地扫描日志。
- 同步状态、待同步条数、立即同步、匿名账号；401 显示「登录已失效」，确认后重登。
- 家庭管理：创建家庭、8 位一次性邀请码、成员移除 / 退出、房间排序；按角色裁剪入口。
- 账号与数据：迁移 / 接管、异步导出、两步删除令牌。
- 阈值告警设置、外观三态、版本与 `BASE_URL`。

## 构建与运行

要求 macOS + Xcode 16.4 或更新（本地验证 Xcode 27.2），iOS 15+。

```bash
# 模拟器构建
xcodebuild -project codemagic.xcodeproj \
  -scheme codemagic \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

# 单元测试（选择本机可用模拟器）
xcodebuild -project codemagic.xcodeproj \
  -scheme codemagic \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test

# 端到端契约联调（自动拉起本地 PJGoIoT，用完关闭）
./scripts/e2e-contract.sh
```

`BASE_URL` 由 xcconfig 注入 `Info.plist`，源码不写地址：Debug 指向 `http://127.0.0.1:8080`，Release 指向联调 mock（预计 2026-12-04 到期）。正式域名确定后只改 `Config/Release.xcconfig`。

e2e 默认端口 8080，被占用回退 18080，也可 `E2E_PORT=18080`；后端目录默认 `../PJGoIoT`，可用 `PJGOIOT_DIR` 覆盖。真实 Postgres 联调见 [docs/e2e-postgres.md](docs/e2e-postgres.md)。

## 权限

- `Info.plist` 声明 `NSBluetoothAlwaysUsageDescription` / `NSBluetoothPeripheralUsageDescription`；首次真实使用 `CBCentralManager` 时触发系统授权，不额外弹自定义框。
- 「我的」展示授权 / 开关状态与系统设置入口；拒绝 / 受限时给明确文案。
- 模拟器蓝牙为 `unsupported`，真实授权与扫描需真机。

## 已知限制与真机验收

- 真机 BLE：授权三态、扫描、12s 连接超时、断开规则、四特征 notify 帧格式、后台 / 锁屏回调。
- 真机后台：`BGAppRefreshTask` 调度、通知权限与点击跳转、APNs 注册与真实推送。
- 真机 + 真实后端：Keychain token、断网补传、410 全量重同步、503 退避、家庭 / 场景多人协作。
- Release 签名与 App Store 上架未验证（无开发者账号 / 证书）。
- 已实现 GATT 服务发现与四特征 notify 订阅；**未实现特征写入 / OTA**。

完整手工清单见 [docs/acceptance.md](docs/acceptance.md)。

## 术语

| 概念 | 统一用词 | 不使用 |
| --- | --- | --- |
| 被扫描 / 连接的硬件 | 设备 | 装置、机器、仪器 |
| 双向数据一致 | 同步 | 上传、下发 |
| 规则越界事件 | 告警 | 提示、警告、报警 |
| 系统通知渠道 | 通知 | — |
| 发现附近 BLE | 扫描 | 搜索 |
| 过滤已保存设备 | 搜索 | — |
| 设备上报的值 | 读数 | 数值、参数、数据点 |
| 用户对设备的分类 | 分组 | 分类（市场 / 产品筛选用「分类」） |
| 设备的空间归属 | 房间 | 分组、标签、家庭 |
| 自动化条件 | 规则 | 策略、场景 |
| 本地动作组合 | 场景 | 快捷指令 |
| 8 位一次性跨设备迁移码 | 接管码 | 配对码（「配对」仅指系统蓝牙配对） |

英文：Device / Reading / Sync / Scan / Group / Alert / Transfer Code。

## 上架材料

| 文件 | 内容 |
| --- | --- |
| [docs/store-listing.md](docs/store-listing.md) | 中英文短描述、长描述、关键词、4+ 分级、审核备注；不含交易 / 广告 / 账号密码登录 / 位置权限 / 分析 SDK |
| [docs/privacy-policy.md](docs/privacy-policy.md) | 收集清单、用途、服务端 90 天 / 本机 7 天保留、注销即删 |
| [docs/app-privacy.md](docs/app-privacy.md) | `PrivacyInfo.xcprivacy` 与代码位置逐项对照，含必需理由 API |
| [codemagic/Resources/PrivacyInfo.xcprivacy](codemagic/Resources/PrivacyInfo.xcprivacy) | 实际打包进 App 的隐私清单 |

当前版本 `v0.31.11`（build 52），未上传 App Store Connect、无审核记录。
