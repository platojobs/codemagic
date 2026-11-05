# BLE 设备数据面板（codemagic · iOS）

纯 **Swift + UIKit（纯代码，无 Storyboard/XIB）** 实现的蓝牙设备数据面板，与 Android 端 [`PKotlinApp`](https://github.com/platojobs/PKotlinApp) 保持五模块命名、数据结构与行为口径一致。

**不包含** SwiftUI 主界面、第三方 UI 库、假数据、假购物车 / 订单 / 支付。

> 行为口径（模块顺序、字段、错误码、空状态、权限）见 **[docs/consistency.md](docs/consistency.md)**。结构与分层见 **[docs/architecture.md](docs/architecture.md)**；真机验收见 **[docs/acceptance.md](docs/acceptance.md)**，故障排查见 **[docs/troubleshooting.md](docs/troubleshooting.md)**，版本变更见 **[docs/releasenotes.md](docs/releasenotes.md)**。

---

## 1. 当前状态

| 项 | 结果 |
| --- | --- |
| 版本 | **v0.15.0**（`MARKETING_VERSION 0.15.0`，`CURRENT_PROJECT_VERSION 23`，tag `v0.15.0`：家庭管理补齐成员移除 / 退出 / 邀请码列表与撤销 / 房间整段排序 / 真实计数，契约对齐 `PJGoIoT` v0.13.0 / openapi 0.9.0） |
| 五模块（首页 / 智能 / 产品 / 市场 / 我的） | 已实现，纯代码 UIKit，真实数据路径；设备管理并入首页，规则与场景集中在「智能」 |
| CoreBluetooth 扫描 + 连接 | 已实现（`CBCentralManager`，真实 RSSI） |
| BLE 读数采集 | 已实现：连接后订阅心率 `0x2A37`、电量 `0x2A19`、温度 `0x2A6E`、Nordic UART TX `6E400003-…`；各特征独立解析器，失败静默丢弃并写本地日志 |
| 长周期读数图表 | 已实现：1 小时 / 24 小时 / 7 天 / 30 天区间切换（映射 `1m` / `1h` / `1h` / `1d`），X 轴按桶 `start` 真实时间比例定位，缺口断线，`avg` 折线 + `min`–`max` 区间带，Y 轴自适应并带单位；**v0.11.0 支持点选 / 长按桶查看 start–end、min/max/avg/last 与条数（本地时区），点空白取消，Y 轴不变，并给出无障碍摘要** |
| 本地持久化 | 已实现（SQLite3，含同步字段；迁移 **v10** 为 `households` 增加 `room_count`（服务端真实房间数，不本地计数）；v9 新增 `households`（`id` / `remote_id` / `name` / `is_personal` / `role` / `member_count` / `device_count`）与 `device_assignment_pending`（设备归属上报队列），为 `rooms` 启用 `remote_id` 并增加 `household_id` / `sync_state` / `deleted`，为 `saved_devices` 增加 `household_id` / `remote_room_id` / `remote_household_id`；v8 新增 `rooms` 表与可空 `room_id`，v7 为 `rules` 加指标阈值字段，v6 新增仅本机的 `scenarios` 表；v5 新增 `readings` 表，本地保留 7 天；v4 区分 `advertised_name` 与用户别名并记录三态 patch） |
| 家庭（v0.15.0） | **已接入后端**：`GET /households` 的 `memberCount` / `deviceCount` / `roomCount` 全部使用服务端真实数字；「我的 → 家庭管理」按角色裁剪入口：owner 可签发 / 撤销邀请码、移除成员、改家庭名、退出家庭，member 只能查看与退出。成员支持左滑 / 点击移除（二次确认并说明对方设备回其个人家庭）；owner 还有其他成员时退出前置提示「请先转让所有权或移除其他成员」，服务端 409 同一文案。邀请码列表只展示哈希前缀 / 状态 / 过期时间并可撤销，绝无明文。房间支持拖拽与上下移动排序，整段提交 `PUT /rooms/order`；409（`ROOM_SET_MISMATCH` 或 v0.13.0 的 `CONFLICT`）自动重新 GET 并提示「房间列表已变化，已刷新」。设备归属仍走独立 `PATCH /my/devices/{platform}/{externalId}`；退出 / 被移除后本地设备回落个人家庭、房间脱钩保留并标注未同步 |
| 本地化（v0.12.0） | **已实现**：全部界面文案走 `L10n.t` / `L10n.f`，资源为 `Resources/zh-Hans.lproj/Localizable.strings` 与 `en.lproj/Localizable.strings`；工程 `knownRegions` 含 `zh-Hans`，`CFBundleLocalizations = [en, zh-Hans]`，设置跟随系统语言；术语双语见第 11 节；单测强制扫描 View / ViewModel 源码不得硬编码中文，并校验两语言 key 集合与占位符一致 |
| 动态字体（v0.12.0） | **已实现**：字号统一走 `AppText`（`UIFontMetrics` 缩放）+ `applyFont(_:)`（`adjustsFontForContentSizeCategory = true`）；表格行高自适应；图表 Y 轴左侧留白随字号测量增长，超大字号缩为 3 个刻度且不与绘图区重叠 |
| 设计系统（v0.8.0） | **已落地**：`Palette` 36 个语义色（浅/深 `UIColor(dynamicProvider:)`）、`Layout` 4pt 阶梯 / 16 页边距 / 56·72·88 行高 / 12 圆角 / 1dp 描边、`AppText` 10 级字号与等宽数字；代码内无硬编码色值与字号（单测强制扫描） |
| 网络层 | 已实现（URLSession + Codable；家庭 / 邀请码 / 房间 / 设备归属对齐 `PJGoIoT` v0.13.0 openapi 0.9.0；设备/型号/同步/账号对齐 openapi 0.7.0 起的既有契约；读数查询 / summary / series / metrics 对齐 v0.5.1 起；详情页远端刷新 800ms 去抖动 + 失败指数退避 ≤5 分钟，不可见/后台不请求；分页上限 changes 500 / readings 500 / export 5000 客户端先收敛） |
| 同步 | **已实现**：匿名登录、增量拉取、批量推送（设备 ≤100/批 + 读数 ≤200/批、幂等键含读数）、冲突提示、tombstone、Keychain token、前后台 / BGTask 触发、断网累积补传；后台唤醒仅做受限推送（不拉增量、不建号、≥15 分钟间隔）；**410 `RESYNC_REQUIRED` 自动全量重同步（pending 不丢）**，503 `TIMEOUT` 指数退避 |
| 自绘 RSSI + 自绘折线图 + 代码组装空状态 | 已实现（读数图表纯 `draw(_:)`，无第三方图表库） |
| 首启引导 | **已实现**：3 步（蓝牙 / 通知 / 后台采集），仅首次或未走完时出现，可跳过；步骤与完成标记持久化到 `UserDefaults` |
| 单元测试 | **303 个用例，0 失败**（`** TEST SUCCEEDED **`，2026-11-05，Xcode 27.2 / iPhone 18 Pro · iOS 27.2 模拟器；含家庭成员移除后的本地清理、退出后设备回落、邀请码列表 / 撤销、整段重排缺项与 409 刷新、owner / member 入口可见性；以及家庭首次接入房间合并、同名认领、已删家庭房间脱钩、设备归属 403 终态与网络失败 pending 重试、未分配空串清除、切换家庭、离线建房、`RemoteDevice` 编解码；房间迁移 v7→v8、增删改、设备移入移出、按房间分区与搜索隐藏空房间、推荐规则模板生成与一键写入、本地化 key / 占位符一致性与硬编码中文审计、`AppText` 默认与 AX5 字号差与布局固有高度、指标阈值规则、图表点选几何、CSV 文件名与 BOM、410 全量重同步、503 TIMEOUT 退避、错误码映射、分页上限、设计令牌审计、场景动作、通知节流、接管码、注销、首启与术语审计） |
| 模拟器构建 | **通过**（`xcodebuild ... build`，`** BUILD SUCCEEDED **`） |
| CI | **GitHub Actions 已实际运行 success**：v0.10.0 tag run [41979289081](https://github.com/platojobs/codemagic/actions/runs/41979289081)（success，提交 `74f14c4`），并行 `Build & Test`（**236 单测**）与 `E2E contract`（**151 项，0 SKIP**）；同 sha 的 `main` run [41979270921](https://github.com/platojobs/codemagic/actions/runs/41979270921) 经重跑同样 success；v0.9.0 run [41973731269](https://github.com/platojobs/codemagic/actions/runs/41973731269) 为上一基线；`codemagic.yaml` 作为可选替代保留但未验证 |
| 真机 BLE / 签名 | **未验证**：本机无真机与 Apple 开发者账号；读数采集与图表需真机 / 可穿戴设备验证（见第 9 节） |
| 真实后端同步 | **契约已联调**：`scripts/e2e-contract.sh` 对本地 `PJGoIoT` **v0.13.0**（`STORE=fixture`）跑 **260 项断言，全部 PASS**（第 9 节含 v0.13.0 成员移除 → 对方 404、owner 带成员退出 409 → 移除后可退出、邀请码列表无明文 / 撤销后 claim 404、整段重排缺项 / 多项 / 重复 409、真实 `memberCount` / `deviceCount` / `roomCount`）；`scripts/e2e-postgres.sh` 在同一套契约外，另在**真实 Postgres** 直接查库确认邀请码只存 64 位哈希、移除成员后成员行删除、退出后清理，输出见 [docs/e2e-postgres.md](docs/e2e-postgres.md)；App 内同步 UI 仍需真机手动验证 |
| 上架材料 | **已补齐**：`docs/store-listing.md`、`docs/privacy-policy.md`、`docs/app-privacy.md` 与 `codemagic/Resources/PrivacyInfo.xcprivacy`（未使用能力不声明） |

---

## 2. 五模块能力

### 信息架构（v0.8.0，对齐米家）
- 五个 Tab：**首页 / 智能 / 产品 / 市场 / 我的**。原「设备」Tab 取消，设备管理（搜索 / 排序 / 房间）并入首页；规则与场景入口统一放在「智能」，不留重复入口。
- **首页**：设备卡片网格（名称、连接状态、最近一条读数、信号条），**v0.13.0 起按房间分段**（房间标题 + 该房间设备，标题可展开 / 收起，「未分配」固定最后）；顶部搜索与排序、右上角房间管理；**v0.14.0 起「我的 → 家庭管理」可创建家庭 / 邀请成员，首页多于一个家庭时右上角提供切换**；顶部一行「今日告警摘要」（真实触发条数，点击进入「智能」）；下方「快捷场景」横向卡（前 3 个场景，点击执行并提示结果）。点卡片进设备详情。
- **智能**：分段控件切换「自动化」与「场景」。自动化 = 现有规则增删启停 + 最近触发记录；场景见下节。
- **产品 / 市场 / 我的**：保留 v0.7.0 全部能力，仅做设计令牌与几何收口，不新增功能。

### 首页 Home（`Modules/Home`）
- `CBCentralManager` 真实扫描，展示名称 / 标识符 / RSSI；扫描页仍由右上角入口进入，扫描会话写本地日志。
- 已保存设备以卡片网格展示：备注名、连接状态、最近一条读数（等宽数字 + 单位）、`RSISignalView` 信号条、最后出现时间；**按房间分段**（房间标题 + 设备数，可点击展开 / 收起；「未分配」固定最后）。
- 搜索别名 / 广播名 / 型号 / 标识符（大小写不敏感）；排序最近出现 / 名称 / 信号 / 添加时间（默认最近出现并持久化）。**房间分区与搜索 / 排序的取舍**：搜索只匹配设备字段，有关键字时隐藏没有命中的房间；排序只在房间内生效，房间分区顺序固定按 `rooms.sort_order`；v0.13.0 移除首页「分组筛选」控件，原 `group_name` 仅作兼容字段保留（编辑弹窗与详情仍可修改），不再承担首页分区职责。
- 空态真实：无房间显示「还没有房间」+「新建房间」；有房间但房间内无设备时，每个房间内给出扫描引导；搜索无结果给出清除搜索的入口。
- 「今日告警摘要」读取本地扫描日志中当天 `rule` + `warning` 的真实条数，点击切到「智能」Tab。
- 空状态 / 错误状态 / 骨架屏齐全；设备卡片支持长按「详情 / 移入房间 / 编辑 / 删除」，点击进入详情。

### 智能 Smart（`Modules/Smart`）
- **自动化**：本地规则（**断开**、**RSSI 低于阈值**、**指标阈值**）新增 / 启停 / 删除，规则持久化；可绑定单台设备或全部已保存设备；列表下方展示最近 5 条真实触发记录（摘自本地扫描日志）。
- **指标阈值（v0.11.0）**：条件为「指标（温度 / 湿度 / 电量 / 心率 / CO₂）+ 比较符（`>` / `<` / `>=` / `<=`）+ 阈值 + 连续 N 条（1–5，默认 1）」，阈值与单位成对展示（`℃` / `%` / `bpm` / `ppm`）。判定接在 `ReadingsIngestor` 落库之后、复用同一 `RuleEvaluator` 与 `RuleAlertCoordinator`，不另起链路；命中写入「智能 → 最近触发」（触发值、阈值、时间、设备），恢复只在确实发过触发通知后补一条。
- **推荐规则（v0.12.0）**：「智能 → 自动化」首段新增「推荐规则」入口。模板只根据该设备**真实出现过的指标**生成（温度 > 30℃、湿度 > 70%、电量 < 20%、心率 > 120、CO₂ > 1000ppm），不列出设备没有的指标；一键添加立即写入本地并出现在规则列表，复用 v0.11.0 的 `readingThreshold` 规则结构，不新建模型。无设备显示「还没有设备」+ 连接引导；有设备但无读数显示「连接到设备并采集到读数后可创建推荐规则」。
- **阈值告警通知（v0.6.0 起）**：首次命中请求通知授权，命中发本地通知、恢复发「已恢复」；节流窗口 1 / 5 / 30 分钟（默认 5，同一设备同一规则只报一次）；点击通知进入设备详情。
- **场景（v0.8.0，仅本机）**：见「场景」小节。

### 场景（v0.8.0，仅本机）
- 场景是**真实可执行动作**的组合，只允许：连接指定设备、断开指定设备、开始后台采集、停止后台采集、静音告警 10 / 30 / 60 分钟、立即同步。
- CRUD 存于 SQLite `scenarios` 表（迁移 v6），**不参与云同步**，界面明确标注「仅本机」；编辑页说明「场景仅保存在本机，不随账号同步」。
- 一键执行按顺序逐个动作，任一动作失败**不阻断后续**，结束后汇总「成功 N / 失败 M」并逐条给出原因；执行中显示进度浮层（当前动作 + 已完成状态）。
- 动作语义：连接前校验蓝牙权限与设备存在、已连接则返回失败原因；断开要求当前已连接；后台采集重复开启 / 未开启即停止均给出明确提示；静音校验 10/30/60 且告警未被关闭、未处于静音；同步复用现有 `SyncEngine` 并返回真实推送/拉取条数。

### 家庭与房间（v0.15.0，服务端为准）
- **数据模型**：`households` 表（`id` 复用远端 UUID、`remote_id`、`name`、`is_personal`、`role`、`member_count`、`device_count`、`room_count`），`rooms` 的 `remote_id` 真正启用并增加 `household_id` / `sync_state`（`local` / `pending` / `synced`）/ `deleted`，设备增加 `household_id` / `remote_room_id` / `remote_household_id`；迁移 **v9** 建表、**v10** 条件补 `room_count`，旧库升级不丢任何房间与归属。计数一律来自 `GET /households`，不在本地重算。
- **首次接入合并策略（不静默丢弃）**：本机未归属房间认领到当前家庭，按 `sort_order` 顺序推到服务端；服务端已有同名房间时**认领本地房间**（保留本地 `id` 与设备归属），不重复创建；推送失败保留 `local / pending` 下次重试；服务端已删除的家庭，其房间脱钩为未归属并在本轮不被重新认领，离线仍可见。
- **成员管理（v0.15.0）**：owner 可左滑或点击移除非 owner 成员，二次确认说明「对方设备回其个人家庭、房间归属清空」，调用 `DELETE /households/{id}/members/{userId}`；成功后刷新服务端计数；若被移除的是当前账号，本地设备回落个人家庭、房间脱钩保留。
- **退出家庭（v0.15.0）**：member 与无其他成员的 owner 可退出（`POST /households/{id}/leave`）；owner 还有其他成员时本地直接提示「请先转让所有权或移除其他成员」，服务端 409 `CONFLICT` 同文案，不解析 message。个人家庭隐藏退出入口。
- **邀请码管理（v0.15.0）**：owner 专属分区，`GET /households/{id}/invitations` 只展示 `codeHashPrefix` / 状态 / 过期时间，界面与模型均无明文字段；左滑或点击撤销（`DELETE .../invitations/{invitationId}`，二次确认），撤销后对方 claim 404。member 看不到该分区。
- **房间整段排序（v0.15.0）**：owner 点击「排序」进入拖拽模式，或左滑「上移 / 下移」，一次性提交 `PUT /households/{id}/rooms/order` 的完整 `roomIds`；缺项 / 多项 / 重复在本地先判 409，服务端 409（`ROOM_SET_MISMATCH`，v0.13.0 为 `CONFLICT`）时自动重新 GET 房间并提示「房间列表已变化，已刷新」。本地未同步房间不参与整段排序。
- **房间以服务端为准**：登录 / 同步时拉取当前家庭房间并落库；本机新建 / 改名 / 删除先落本地 `pending` 或墓碑，联网后补报；界面标注「未同步」。房间不再参与 `sync/push`，避免与 LWW 冲突。
- **切换家庭**：首页多于一个家庭时右上角提供切换入口，单家庭不显示；切换后按该家庭展示设备与房间，当前家庭持久化到 `SyncMetadataStore`。
- **角色可见性**：owner 可见签发 / 撤销邀请码、移除成员、改家庭名、退出、房间排序；member 仅可见创建 / 加入家庭与退出，写入口禁用并提示「你没有修改该家庭 / 房间的权限」；跨家庭读取由服务端返回 404，界面统一为可读文案，不弹错误码或整页报错。

### 设备详情（`Modules/Devices`）
- 设备详情：连接蓝牙 → `GET /api/v1/my/devices/ios/{externalId}` 拉取云端设备记录，**优先展示云端 `deviceType` / `vendor` / `firmwareVersion` / `compatibility`**；云端字段为 `null` 时显示「型号未知」/「—」/「暂无兼容性说明」，绝不出 `"null"`；未注册型号仍展示别名、分组、房间与最近出现时间，并在「云端记录」区展示同步信息；网络失败才降级本地缓存并标注缓存时间，无缓存显示失败空状态与重试。
- **房间归属（v0.14.0）**：详情页「房间」行展示当前房间（未分配显示「未分配」），点击弹出当前家庭可见房间（含「未分配」）；选中先落本机，再通过 `PATCH /my/devices/{platform}/{externalId}` 上报 `roomId` / `householdId`，失败保留 `pending` 并在下次同步重试；member 或跨家庭错误降级为可读提示。
- **图表点选（v0.11.0）**：轻点 / 长按折线桶选中该桶，顶部摘要条展示 `start–end`、最小 / 最大 / 平均 / 最新与条数（本地时区）；点空白处取消；选中态不改变 Y 轴；图表 `accessibilityLabel` 在未选中时给出「指标，最近区间，最低 / 最高，共 N 个数据点」，选中后替换为当前桶摘要。
- **读数 CSV 导出（v0.6.0 起，v0.11.0 扩展文件名）**：当前设备 + 指标 + 区间；7 天内读本地、更长走服务端分页（上限 5 万条）；UTF-8 BOM / ISO8601 UTC / RFC 4180 转义；文件名含设备名、设备标识末 8 位、指标、区间起止与 UTC 时间（如 `readings-温湿度计-4A2F9C31-temperature-20261105T010000Z-20261105T020000Z-1a2b3c4d.csv`）；临时文件分享后删除，进度真实可重试。
- 跨平台设备：服务端拉回的 `platform = android` 设备标注「来自 Android，本机不可连接」，无展开箭头、禁用点击与连接，不进入详情。

### 产品 Products（`Modules/Products`）
- 型号库：厂商、型号、固件版本、GATT 服务与特征表。
- 数据来自 `GET /api/v1/device-types` 型号列表 + 逐个 `GET /api/v1/device-types/{type}/catalog`（取固件与配件）；单个 catalog 失败降级为型号信息，全部失败显示错误空状态 + 重试。
- 详情页 GATT / 特征由代码动态组装；兼容性来自 catalog 的 `compatibility` 对象（0.3.2），按「平台 / 协议 / 特性 / 最低 App / 型号」摊平展示。

### 市场 Market（`Modules/Market`）
- 配件与固件信息列表 + 兼容性说明，由各型号 `GET /api/v1/device-types/{type}/catalog` 聚合 firmware + accessories。
- **筛选**：顶部「厂商：全部/xx」与「兼容性：全部/xx」两个入口，取值直接来自服务端真实字段（`vendor`、`compatibility` 展开的平台 / 协议 / 特性 / 型号），不造假分类；可叠加、可一键清除，无结果显示「没有符合筛选条件的条目」。
- 页脚明确声明：**不提供下单、订单或支付**。

### 我的 Profile（`Modules/Profile`）
- 蓝牙授权与开关状态自检，跳转系统设置。
- 本地扫描日志列表、计数与清空。
- **同步状态**：上次同步时间、待同步条数、「立即同步」按钮、匿名账号；失败时展示错误码与降级说明，冲突时提示「另一台设备改过这条」。
- **登录失效（401）**：token 过期时显示「登录已失效」，出现「重新登录」入口；确认弹窗说明旧账号云端数据不自动合并、本机设备会重新同步，确认后才换新匿名账号（游标重置为 0）。未确认前前后台自动同步不会静默建号，见 `docs/troubleshooting.md` 第 3.1 节。
- **家庭管理（v0.14.0）**：「我的 → 家庭管理」展示当前家庭与角色、成员列表（owner / member、账号类型）、房间数量；支持创建家庭、生成 8 位一次性邀请码（服务端 `expiresAt` 倒计时、复制、过期后重新生成）、输入邀请码加入（复用 8 位输入规范化与 404 / 429 文案）；member 的写入口隐藏并给出只读说明。
- 基础设置：自动记录最近设备、启动自动扫描、**后台采集**（v0.7.0，默认开启并说明耗电；关闭后进入后台立即断开连接，状态实时显示）。
- **账号与数据（v0.7.0）**：迁移到新设备（8 位一次性接管码、真实倒计时、复制/重新生成）、从旧设备接管（自动大写/过滤易混字符、404 统一提示、429 按 `Retry-After` 冷却）、导出我的数据（分页拉全 + 临时文件分享后删除 + 真实进度）、注销账号（二次确认永久删除；成功后清 Keychain / 全部业务表 / 同步元数据，401 与网络错误分别处理）。
- **阈值告警设置（v0.6.0）**：真实开关、节流窗口（1 / 5 / 30 分钟）与通知权限状态；拒绝时提示前往系统设置。
- **外观（v0.6.0）**：跟随系统 / 浅色 / 深色三态，窗口级生效并持久化。
- 版本与关于：读取 `CFBundleShortVersionString / CFBundleVersion` 与当前 `BASE_URL`。

### 同步（`Core/Sync`）
- 首次同步自动匿名登录，token 存 **Keychain**（非 UserDefaults）。
- 增量拉取 `GET /api/v1/sync/changes`（游标持久化，`hasMore` 循环，最多 10 页）。
- 批量推送 `POST /api/v1/sync/push`（每批 ≤100，`Idempotency-Key` 由批次内容哈希派生）；`deviceType` 为可选字段，已知型号才随推送上传，未知时省略不填假值。
- 冲突按服务端 LWW：云端获胜时写回并提示，**不静默覆盖本地修改**；tombstone 删除同样上传 / 写回。
- 家庭与归属（v0.14.0）：每次同步先 `GET /households` 合并家庭、选择当前家庭、拉取房间并补报本地房间 / 设备归属，再走原有 pull → push；设备归属**不塞进 push**，用 `PATCH /my/devices/{platform}/{externalId}` 单独上报，失败进 `device_assignment_pending` 队列，下次同步重试；401 交给同步流程，403 / 404 为终态（移出队列并记可读文案）。
- 触发：回到前台（节流 120s）、进入后台（`BGAppRefreshTask`）、手动按钮。
- 后台唤醒（v0.7.0）：仅推送、不拉增量、不创建匿名账号；单次 ≤100 设备 / ≤200 读数，最小间隔 15 分钟（失败同样节流）。`bluetooth-central` 后台模式下连接设备继续接收 notify 并入库，7 天保留清理只删 `synced`，pending 受保护。
- 契约联调：`scripts/e2e-contract.sh` 直连本地 Go 服务，覆盖双平台推送、device-types/catalog（含 vendor/compatibility）、复合键详情、UserDevice 新字段与 null 降级、别名/广播名分离、group 三态、幂等重放、LWW 冲突、401/404；**v0.14.0 起新增家庭链路**（创建家庭 → 邀请码 → 第二账号领取 → 成员可见设备 → member 改房间 403 → 跨家庭 404 → 设备归属三态 → 删除家庭级联）；已纳入 GitHub Actions `e2e-contract` job（见 4.2）。

---

## 3. 目录结构

```
codemagic/
├── App/                    # AppDelegate / SceneDelegate / AppEnvironment / MainTabBarController / SyncCoordinator
├── Core/
│   ├── Models/             # ScannedDevice、SavedDevice、DeviceRule、ProductModel、MarketItem、DeviceCatalog…
│   ├── Networking/         # APIConfiguration、HTTPClient、ProductAPIClient、AppError
│   ├── Persistence/        # SQLiteDatabase + SavedDevice/DeviceRule/Readings/RecentDevice/ScanLog/Scenario/同步元数据 Store
│   ├── Sync/               # SyncEngine、SyncAPIClient、SyncModels、KeychainTokenStore、SyncMetadataStore
│   ├── Household/          # HouseholdService、HouseholdAPIClient、HouseholdStore、HouseholdModels（家庭 / 邀请码 / 房间 / 设备归属）
│   ├── Bluetooth/          # CoreBluetoothService
│   ├── Rules/              # RuleEvaluator、RuleAlertCoordinator、ScenarioExecutor
│   ├── Export/             # ReadingsCSV、ReadingsExportService
│   ├── Notifications/      # LocalNotificationServing、UserNotificationService
│   └── Formatting/         # AppDateFormat
├── DesignSystem/           # DesignTokens（Palette/Layout/AppText）、AppTheme、AppComponents、SkeletonView、ErrorStateView、ToastView、LargeTitleHeaderView、RSISignalView（自绘）、EmptyStateView
├── Modules/
│   ├── Home/               # 首页：设备卡片网格 + 快捷场景 + 告警摘要
│   ├── Smart/              # 智能：自动化 + 场景（编辑/执行）
│   ├── Devices/            # 设备详情、规则编辑、读数图表
│   ├── Products/
│   ├── Market/
│   ├── Households/         # 家庭管理、邀请码、加入家庭（v0.14.0）
│   └── Profile/
└── Resources/              # Info.plist、Assets.xcassets
Config/
├── Debug.xcconfig          # BASE_URL → http://127.0.0.1:8080（本地 Go 服务）
└── Release.xcconfig        # BASE_URL → https://quickmock.dev/m/ecHT7ex3yQPA/（与 Android 共用 mock）
scripts/
├── e2e-contract.sh         # 启动本地 fixture 服务 + 运行联调 runner（CI 的 e2e-contract job 复用）
└── e2e-contract.swift      # 独立 Swift 可执行 runner，真实 URLSession 直连 localhost
codemagicTests/             # 293 个 XCTest 用例（设计令牌审计 / 场景执行 / 迁移 v9 / 家庭与邀请码 / 黄金读数 / 图表几何 / 节流退避 / 通知 / 导出 / 接管码 / 注销 / 后台推送 / 首启持久化与术语审计）
docs/
├── architecture.md
├── consistency.md
├── acceptance.md           # 真机验收清单（首启引导 / 权限前置 / 五模块 / 首页卡片 / 智能 / 场景 / 三态 / 蓝牙 / 规则 / 降级 / 通知 / 导出 / 深色 / 接管码 / 注销 / 后台采集 / Release）
├── store-listing.md        # 中 / 英文上架文案、关键词、分级与边界声明
├── privacy-policy.md       # 逐项数据收集、保留期、注销删除与权限边界
├── app-privacy.md          # PrivacyInfo.xcprivacy 与代码位置逐项对照
├── troubleshooting.md      # Xcode / 签名 / Keychain / BGTask / BASE_URL / Go 服务 / 端口
└── releasenotes.md         # 按 tag 的真实发布说明
```

### 分层

`ViewController（Scenes）` → `ViewModel` → `Service / Store` → `SQLite / URLSession / CoreBluetooth`，模型与设计系统独立。所有依赖在 `App/AppEnvironment.swift` 组装，界面层不直接创建数据库或网络客户端。

### 如何新增一个模块

1. 在 `codemagic/Modules/<Feature>/` 新建 `Scenes/`、`ViewModels/`、`Views/`，命名沿用现有风格（如 `XxxViewController` / `XxxViewModel` / `XxxCell`）。
2. ViewModel 用构造器注入依赖，使用 `private(set)` 状态 + `onChange` 回调驱动 UI。
3. 新增表：在 `Core/Persistence/SQLiteDatabase.swift` 的 `migrate()` 提高版本并加 `CREATE TABLE`，再写对应 Store（保留 `id / updated_at / deleted_at / sync_state`；需要参与同步的表再加 `platform / external_id`）。
4. 新增网络接口：扩展 `ProductServicing` / `SyncAPIServicing` 或新建 Service，错误统一用 `AppError`。
5. 页面骨架纯代码；空状态统一用 `EmptyStateView`；信号类控件优先自绘。
6. 在 `MainTabBarController` 装配，并更新 `docs/consistency.md` 第 1 节。
7. 补 XCTest，`xcodebuild test` 必须通过。

> 工程使用 Xcode 16+ 的 file-system synchronized group：新增 `.swift` 文件放入 `codemagic/` 或 `codemagicTests/` 会自动加入 target。

---

## 4. 构建与运行

要求：macOS + Xcode 16.4 或更新（本地验证使用 Xcode 27.2），iOS 15+ 模拟器或真机。

```bash
# 列出 scheme / target
xcodebuild -project codemagic.xcodeproj -list

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
```

或直接 `open codemagic.xcodeproj`，选择 `codemagic` scheme 运行。

### BASE_URL（Debug / Release）

地址不写在 Swift 源码，通过 xcconfig 注入 `Info.plist` 的 `BASE_URL`：

| 配置 | 文件 | 值 |
| --- | --- | --- |
| Debug | `Config/Debug.xcconfig` | `http://127.0.0.1:8080`（本地 Go 服务 `PJGoIoT`） |
| Release | `Config/Release.xcconfig` | `https://quickmock.dev/m/ecHT7ex3yQPA/`（与 Android 共用的联调 mock） |

- mock 由 Quickmock.dev 提供，任意路径返回同一份组合 JSON，**预计 2026-12-04 到期**；到期后产品 / 市场会显示错误空状态与重试，不会崩溃。
- 正式域名确定后只改 `Release.xcconfig`，不需要改源码。
- 临时联调可覆盖：`xcodebuild ... BASE_URL='https://...' build`。
- 本地 Go 服务需 **0.3.3**（`git pull` 后运行），提供 `/api/v1/device-types`、`/api/v1/device-types/{type}/catalog`、`/api/v1/my/devices/{platform}/{externalId}`，并在 `UserDevice` / catalog 固件与配件上提供 `advertisedName` / `deviceType` / `vendor` / `firmwareVersion` / `compatibility`；iOS 已全部切换，不再请求 `api/products` / `api/market` / `api/device/{uuid}`；见 `docs/consistency.md` 第 3.4 节。

### 4.2 端到端契约联调（CI 并行 job + 本地手动运行）

脚本会自行构建并启动本地 `PJGoIoT`（`STORE=fixture`），跑完自动关闭服务：

```bash
cd /path/to/codemagic
./scripts/e2e-contract.sh
```

- 端口：优先 **8080**，被占用自动改用 **18080**；也可显式指定 `E2E_PORT=18080`。
- 后端目录：默认 `../PJGoIoT`，可用 `PJGOIOT_DIR=/path/to/PJGoIoT` 覆盖。
- 健康检查：轮询 `GET /api/v1/health`，必须在 30s 内返回 200，否则脚本失败。
- 联调 runner：`scripts/e2e-contract.swift` 由 `swiftc` 编译为独立 macOS 可执行文件，使用真实 `URLSession` 直连 `127.0.0.1`，**不走 iOS 模拟器**。
- 依赖本地 Go 服务与 fixture 数据；GitHub Actions `ios.yml` 的 `e2e-contract` job 会 checkout `PJGoIoT` 并执行同一脚本（`PJGOIOT_DIR` 指向 checkout 目录），不使用 `|| true`。
- CI 中 `build-test` 与 `e2e-contract` 并行，按 `github.sha` 去重（同一次提交的 main push 与 tag 只跑一轮）。
- 读数断言（第 7 节）采用**能力门控**：探针 `GET .../readings/summary` 返回 404（后端尚未发布 readings）时输出 `[SKIP]` 且不计通过；后端上线后自动执行真实断言。本地 agent 以 `RATE_LIMIT_PER_MINUTE=0` 启动 fixture 服务，避免 ~100 次请求触发 429。

本机 2026-11-05 实际运行（后端 `PJGoIoT` v0.7.0，端口 8080）：

```
[e2e] health 200
[1. 匿名登录] 3/3 PASS
[2. 双平台推送（ios + android 同一台设备）] 7/7 PASS
[3. changes 拉回校验 platform / externalId] 12/12 PASS
[3.5 device-types/catalog 与 my/devices/{platform}/{externalId}] 14/14 PASS
[3.6 UserDevice deviceType/vendor/compatibility 与 null 降级] 12/12 PASS
[3.7 advertisedName / alias 隔离与 group 三态] 16/16 PASS
[4. 同 Idempotency-Key 重放] 5/5 PASS
[5. LWW 冲突：旧版本不静默覆盖新版本] 9/9 PASS
[6. 无 token 401 / 跨用户 404] 9/9 PASS（含复合键越权）
[7. 设备读数 readings（推送 / 倒序 / summary / 重复 id / NaN / series / metrics）] 36/36 PASS
[8. 账号：接管码 / 数据导出 / 注销] 28/28 PASS

=== E2E 合同联调结果 ===
通过：151 项，跳过：0 项，失败：0 项
结论：PASS
```

> 读数一节断言：推送 3 条 → `appliedReadings=3` / `skippedReadings=0`；`GET readings` 返回 3 条且按 `recordedAt` 倒序；`summary` 的 count/min/max/avg/last/unit/window 全部正确；重复 id 再推返回 200、`appliedReadings=0`、`skippedReadings=3`；`value="NaN"` 返回 400。v0.5.0 新增：追加 2 条温度读数后 `series` 按 `1m` 返回、桶按 `start` 升序、`count` 合计 3、每桶 `min ≤ avg ≤ max`；空区间返回 `buckets: []`；非法 `bucket=5m` 返回 400 `BAD_REQUEST`；`metrics` 按 `lastAt` 倒序、温度在首位、心率 `count=3`/`unit=bpm`。3.5 / 3.6 / 3.7 断言含义同前（固件 vendor/compatibility、未注册型号 null 降级、别名与广播名隔离、group 三态）。

服务端日志写入 `.build/e2e/pjgoiot-server.log`；脚本退出时通过 `trap` 关闭后端进程。

---

## 5. 权限（iOS）

`Info.plist` 已声明：

- `NSBluetoothAlwaysUsageDescription`：扫描附近设备、显示信号强度、连接设备读取厂商与固件信息。
- `NSBluetoothPeripheralUsageDescription`：兼容旧系统声明。
- `NSAppTransportSecurity / NSAllowsLocalNetworking = true`：仅允许本地 HTTP（Debug 的 `127.0.0.1`）。

授权流程（v0.9.0 起为「先说明后申请」）：冷启动不再创建 `CBCentralManager`，因此不会在启动时弹授权框。首启引导第 1 步说明「为什么需要蓝牙」，用户点「继续」才调用 `BluetoothServicing.activate()` 触发系统授权；被拒绝 / 受限时原地展示「仅本机可用」能力边界与「去系统设置」，可继续走完引导。首页无设备时主行动为「开始扫描」；若权限已拒绝，空态与右上角扫描统一改为「去系统设置」，不出现点了没反应的死路。

### 5.1 首次使用（首启引导）

- 触发条件：`settings.onboardingCompleted == false`（仅首次安装或引导未走完）。
- 三步内容：① 蓝牙用于扫描 / 连接 / 读取读数；② 通知用于阈值告警，仅本机生成、不用于营销；③ 后台采集受 iOS `bluetooth-central` 限制，只在设备保持连接时继续，断连即停。
- 跳过与持久化：右上角「跳过」直接写入完成标记；中途退出按 `settings.onboardingStep` 从原步骤继续；走完最后一步「开始使用」同样写入完成标记，后续冷启动不再出现。
- 与首页衔接：引导结束后首页空态只有一套文案——标题「还没有设备」、说明「扫描附近的设备，添加后可查看读数、历史曲线与规则」、主按钮「开始扫描」。

### 5.2 启动耗时（实测，Debug · iPhone 17 模拟器）

打点方式：`App/LaunchMetrics.swift` 在 `didFinishLaunching` 第一行记起点，在根窗口首次布局提交后的主线程回合记终点；同时发 `os_signpost`（subsystem `com.platojobs.codemagic`，category `launch`，interval `AppLaunch`）并输出 `[LaunchMetrics] ...` 控制台日志。工程没有 UI Test target，因此未使用 `XCTApplicationLaunchMetric`；改用 `os_signpost` + 控制台采集，**不是估算**。

| 场景 | 改动前（v0.8.0） | 改动后（v0.9.0） | 说明 |
| --- | --- | --- | --- |
| 首次安装后首次启动到首帧 | **1718.3 ms**（1 次） | **479.3 ms**（1 次） | 改动前在 `AppEnvironment` 装配时同步创建 `CBCentralManager`，首启还要等系统授权框；改动后授权由用户点「继续」触发 |
| 稳态冷启动到首帧（杀进程后） | **302.5 ms**（5 次中位数：280.3 / 286.5 / 302.5 / 311.0 / 552.6） | **288.5 ms**（4 次中位数：278.4 / 286.0 / 291.0 / 309.7） | 稳态 −14.0 ms（约 −4.6%） |
| `environment-ready`（装配 + 打开 SQLite + 迁移 + 注册同步） | **15.9 ms**（中位数） | **13.5 ms**（中位数） | SQLite 打开与迁移自身仅 **1.8 ms**（`database-ready`），未阻塞首帧 |
| 阶段占比（改动后） | — | window-visible ≈147 ms，home-data-ready ≈201 ms，first-frame ≈289 ms | 主要成本是 Tab / 首页搭建与首次数据渲染，不在装配与迁移 |

做了哪些改动：

1. **蓝牙管理器延迟创建**：`CBCentralManager` 从 `AppEnvironment` 构造时移到 `activatedManager()`，由首启引导「继续」或真实扫描 / 连接触发；冷启动不再触发系统授权框，也不把蓝牙初始化放在主线程启动路径。
2. **7 天清理移到后台**：`AppEnvironment` 中的 `readingsStore.prune` 改为 `DispatchQueue.global(qos: .utility)`，不再占用启动主线程。
3. **保留同步协调器注册在主线程**：`BGTaskScheduler.register` 必须在 `didFinishLaunching` 返回前完成，未延后；其耗时包含在 `environment-init` 的 13 ms 内。
4. **未做**：未把 SQLite 打开 / 迁移异步化，也未把首页数据加载改为后台加载；两者目前均未阻塞首帧到不可接受的程度，强行异步会引入空窗与骨架态复杂度，本版本不做。

> 以上为模拟器 Debug 构建的真实采集值，不代表真机 Release 性能；真机尚未验证（无设备 / 签名账号）。README 不声称「已优化到某目标」，只记录实测前后对比。

> iOS 不向 App 暴露蓝牙 MAC，因此设备唯一键使用 `platform="ios"` + `externalId=CBPeripheral.identifier`（大写），`mac` 允许为空；型号元数据走 `GET /api/v1/device-types/{type}`，不依赖 MAC。

---

## 6. 持久化选择

使用 **SQLite3**（系统库，`-lsqlite3`）而不是 Core Data，原因：

1. 同步字段（`id / updatedAt / deletedAt / syncState`）需要逐列精确控制，SQL 更直观。
2. schema 以 SQL 明示，便于与 Android Room 表逐列对照，评审与排查成本低。
3. 不依赖 `.xcdatamodeld` 编辑器，CI 与代码合并不会产生模型文件冲突。
4. 软删除、WAL、迁移版本（`PRAGMA user_version`）都可直接控制。

数据库位置：`Application Support/com.platojobs.codemagic/codemagic.sqlite`。磁盘库失败时回退内存库，并在「我的」页提示。

迁移：`PRAGMA user_version` 线性递增。v1 建五张表；**v2（v0.2.0）** 为 `saved_devices` 增加 `platform`（默认 `ios`）与 `external_id`，由 `peripheral_id` 大写回填，并建立 `(platform, external_id) WHERE deleted_at IS NULL` 唯一索引；**v3（v0.3.3）** 增加 `device_type TEXT`（可空，旧库升级后为 `NULL`，由云端详情回填）；**v4（v0.3.6）** 增加 `advertised_name TEXT`（由历史 `name` 回填广播名）与 `alias_patch` / `advertised_name_patch` / `group_patch`（`absent` / `clear` / `set` 三态）；**v5（v0.4.0）** 新增 `readings` 表（`id` 主键、`device_id`、`metric`、`value`、`unit`、`recorded_at`、`sync_state`），并按 `(device_id, metric, recorded_at DESC)` 建索引，支撑最近 60 点查询与 7 天清理；**v6（v0.8.0）** 新增本地 `scenarios` 表（`id` / `name` / `actions` JSON / `created_at` / `updated_at`），**不含 `sync_state` / `deleted_at` / `platform` / `external_id`，不参与同步**；**v8（v0.13.0）** 新增本地 `rooms` 表（`id` / `name` / `sort_order` / `remote_id` / `created_at` / `updated_at`）并为 `saved_devices` 增加可空 `room_id`（NULL = 未分配），原 `group_name` 保留为兼容字段；**v9（v0.14.0）** 新增 `households`（`id` / `remote_id` / `name` / `is_personal` / `role`）与 `device_assignment_pending`，`rooms` 启用 `remote_id` 并增加 `household_id` / `sync_state` / `deleted`（离线墓碑），`saved_devices` 增加 `household_id` / `remote_room_id` / `remote_household_id`；全部条件 ALTER，旧库升级后无需重装或清数据，房间与归属不丢。

---

## 7. 网络契约

### 7.1 同步 / 鉴权（v0.2.0 起，与 `PJGoIoT/api/openapi.yaml` 对齐）

| 接口 | 方法 | 说明 |
| --- | --- | --- |
| `/api/v1/auth/anonymous` | `POST` | 返回 `{userId, token}`；token 存 Keychain |
| `/api/v1/sync/changes?cursor=&limit=` | `GET` | 返回 `{changes[], nextCursor, hasMore}`，需 `Authorization: Bearer <token>` |
| `/api/v1/sync/push` | `POST` | Body `{clientId, devices[], readings[]}`；`readings` 可选，≤500/批（客户端 ≤200）；Header `Idempotency-Key`；返回 `{applied[], conflicts[], nextCursor, appliedReadings, skippedReadings}` |
| `/api/v1/device-types` | `GET` | 型号列表（`{items}`，兼容裸数组） |
| `/api/v1/device-types/{type}` | `GET` | 型号元数据（不依赖 MAC） |
| `/api/v1/device-types/{type}/catalog` | `GET` | 一次返回型号元数据 + `firmwares` + `accessories` |
| `/api/v1/my/devices/ios/{externalId}` | `GET` | iOS 单台设备详情，需 Bearer token；跨用户 404 |
| `/api/v1/my/devices/{platform}/{externalId}/readings` | `GET` | 读数列表，`metric` / `from` / `to` / `limit` / `cursor`；返回 `{items[], nextCursor, hasMore}`，倒序 |
| `/api/v1/my/devices/{platform}/{externalId}/readings/summary` | `GET` | 24h 汇总，`metric` / `hours`；返回 `{metric, unit, count, min, max, avg, last, windowStart, windowEnd}` |
| `/api/v1/my/devices/{platform}/{externalId}/readings/series` | `GET` | 分桶序列，`metric` / `from` / `to` / `bucket`（`1m` / `1h` / `1d`）；返回 `{metric, unit, bucket, from, to, buckets[{start, end, count, min, max, avg, last}]}`，按 `start` 升序，仅含有数据的桶 |
| `/api/v1/my/devices/{platform}/{externalId}/readings/metrics` | `GET` | 指标清单；返回 `{items:[{metric, unit, count, firstAt, lastAt}]}`，按 `lastAt` 倒序 |

错误体 `{"error":{"code","message"}}` 解析为 `AppError.api`（客户端码 `NET-002`，保留服务端 code）。字段解码容忍未知字段与缺失字段。

### 7.2 产品 / 市场 / 设备详情（0.3.1 起新端点，0.3.2/0.3.3 扩字段）

- 产品：`GET /api/v1/device-types` → `{items:[DeviceType]}`，再逐个 `GET /api/v1/device-types/{type}/catalog`
- 市场：同一批 catalog 聚合 `firmwares` + `accessories`，厂商与兼容性直接取条目的 `vendor` / `compatibility`
- 设备详情：`GET /api/v1/my/devices/ios/{externalId}`（大写 UUID，Bearer token），云端优先、失败降级本地缓存

字段（0.3.2/0.3.3）：`DeviceType` 为 `type, name, vendor, description, gattServices[{uuid,name,characteristics?}]`；`DeviceCatalog` 为 `deviceType, firmwares[{id,version,releaseNotes,releasedAt,vendor,compatibility}], accessories[{id,name,sku,description,vendor,compatibility}]`；`UserDevice` 为 `id, clientId, platform, externalId, mac, alias, advertisedName, group, deviceType, vendor, firmwareVersion, compatibility, updatedAt, deletedAt, serverSeq`。`deviceType` / `vendor` / `firmwareVersion` / `compatibility` 可为 `null`，客户端归一为 `nil`，展示层用「型号未知 / — / 暂无兼容性说明」，不渲染 `"null"`。`PushDevice` 的 `deviceType` 可选，未知时整体省略；`alias` / `advertisedName` / `group` 为三态（缺省省略 / `""` 显式清除 / 具体值），未上报字段不参与 LWW 与幂等哈希。错误码见 `docs/consistency.md` 第 4 节。

### 7.3 设备读数（v0.5.0，契约对齐 PJGoIoT v0.5.1）

- 推送：`readings` 与设备并入同一 `POST /api/v1/sync/push`，客户端每批 ≤200；条目为 `{id(uuid), platform, externalId, metric, value, unit, recordedAt(RFC3339)}`。按 `id` 幂等，重复 id 返回 `skippedReadings` 而非报错；`readings` 为空时整个字段省略，兼容 0.3.3 后端。
- 查询：`GET /api/v1/my/devices/{platform}/{externalId}/readings?metric=&from=&to=&limit=100&cursor=` → `{items[], nextCursor, hasMore}`，按 `recordedAt` 倒序。
- 汇总：`GET .../readings/summary?metric=&hours=24` → `{metric, unit, count, min, max, avg, last, windowStart, windowEnd}`。
- 分桶序列（v0.5.0）：`GET .../readings/series?metric=&from=&to=&bucket=`，`from` / `to` 为 UTC RFC3339，`bucket` ∈ `1m` / `1h` / `1d`；仅返回有数据的桶，按 `start` 升序。
- 指标清单（v0.5.0）：`GET .../readings/metrics` → `{items:[{metric, unit, count, firstAt, lastAt}]}`，按 `lastAt` 倒序；详情页展示「指标名 · N 条」，单位取该指标最近一条读数。
- 客户端刷新口径（v0.6.0）：读数入库只本地重绘；可见时远端合并刷新去抖 **800ms**，`series` 与 `summary` 共用同一时间锚点；不可见 / 后台不请求；失败指数退避至 **5 分钟**。服务端清单为空但本地有 pending 读数时，指标与序列均用本地 UTC 网格并标注「待同步：本地数据」。通知、CSV 导出与深色模式均为客户端行为，详见 `docs/consistency.md` 3.10。
- 后台采集（v0.7.0）：`bluetooth-central` + `BGAppRefreshTask`；连接状态下后台继续 notify 入库（同一 ingestor），后台唤醒只做受限推送（≤100 设备 / ≤200 读数、≥15 分钟间隔、不拉增量不建号）；详见 `docs/consistency.md` 3.11。
- 区间映射：1 小时 → `1m`（60 桶）、24 小时 → `1h`（24 桶）、7 天 → `1h`（168 桶）、30 天 → `1d`（30 桶），均在 500 桶上限内；默认 24 小时。
- 图表定位：X 轴按桶 `start` 的真实时间比例定位（不等距）；相邻桶间隔 >1s 视为缺口，折线**断开且不跨缺口连线**（区间带同样断开）；`avg` 连线 + `min`–`max` 区间带；Y 轴按区间 min/max 自适应并带单位；几何计算在 `ReadingsChartGeometry`，有缺口/30 天 24 桶/异常值过滤单测。
- 离线降级：series 失败时按同一 UTC 网格聚合本地 7 天数据；30 天区间标注「离线：仅本地 7 天数据」，时间轴仍按 30 天绘制、缺数据处留白。
- 保留：服务端 90 天；客户端本地 7 天（启动与同步成功后清理已同步数据，未上传读数保留至补传）。
- 采集：CoreBluetooth notify 订阅心率 `0x2A37`、电量 `0x2A19`、温度 `0x2A6E`、Nordic UART TX `6E400003-…`；解析规则见 `docs/consistency.md` 3.7。解析失败静默丢弃并写本地日志（分类「读数」），不崩溃、不写脏数据。
- 黄金用例：两端共用 `docs/consistency.md` 3.8 的「读数解析黄金用例」表（输入 hex → 唯一期望）；iOS 固化在 `codemagicTests/ReadingsGoldenTests.swift`（18 个用例，含空字节与多行部分失败）。

### 7.4 账号（v0.7.0，契约对齐 PJGoIoT v0.9.0 / openapi 0.7.0）

| 接口 | 方法 | 说明 |
| --- | --- | --- |
| `/api/v1/auth/anonymous` | `POST` | 返回 `{userId, token, expiresAt}`；token 默认 180 天 TTL |
| `/api/v1/auth/pairing-code` | `POST` | Bearer；返回 `{code, expiresAt}`；8 位、10 分钟、一次性；重新生成使旧码失效 |
| `/api/v1/auth/pairing-code/claim` | `POST` | Body `{code}`，无需旧 token；返回 `{userId, token, expiresAt}`；404 统一「码无效或已过期」；429 带 `Retry-After` |
| `/api/v1/me/export?limit=&cursor=` | `GET` | Bearer；返回 `{user, devices, readings, exportedAt, hasMore, nextCursor}`；`limit` 上限 **5000**；`cursor` 不透明 |
| `/api/v1/me` | `DELETE` | Bearer；204；删除账号、设备、读数并使全部 token 失效 |

接管成功后客户端替换 Keychain token，保留本机设备 / 读数并全部重新标记 pending，游标清零；注销成功后按 Keychain → SQLite 业务表 → 同步元数据顺序清理。细节与错误口径见 `docs/consistency.md` 3.11 / 3.13。

### 7.5 游标失效与全量重同步（v0.10.0）

服务端保留 `change_log` 90 天。若本机游标早于该用户最老保留行（例如离线超过 90 天），`GET /sync/changes` 返回：

```json
HTTP/1.1 410 Gone
{"error":{"code":"RESYNC_REQUIRED","message":"游标已过期，请全量重新同步"}}
```

`cursor=0` **永不** 410。客户端（`SyncEngine.handleResyncRequired`）收到后：

1. 清空本地同步游标与 `lastSyncAt`（`SyncMetadataStore.resetCursor()`）；
2. **不清理** pending 设备 / 读数，全量拉取后仍由 `pushPending` 重新上传；
3. 立即以 `cursor=0` 全量重拉，合并规则与首次拉取完全一致；
4. 410 属终态分支：**不进指数退避**，只处理一次（二次仍 410 则失败，不死循环）；
5. 「我的」同步状态区明确提示「**云端变更记录已过期，已重新全量同步**；同步完成：拉取 N 条…」，不静默。

与 503 的边界：`503 TIMEOUT` 是查询超时，映射「服务端繁忙，稍后重试」并进退避（30s 起、上限 5 分钟），**不得按 410 处理**。

测试：`SyncEngineTests` 中 410 游标归零 / pending 保留 / 二次从 0 / 文案断言 / HTTP fake transport 全量拉取成功；`NetworkingTests` 锁定 `TIMEOUT` 与 `RESYNC_REQUIRED` 的映射；真实 Postgres 分支由 `scripts/e2e-postgres.sh` 触发，输出见 [docs/e2e-postgres.md](docs/e2e-postgres.md)。

### 7.6 家庭 / 邀请码 / 房间 / 设备归属（v0.14.0，契约对齐 PJGoIoT v0.12.0 / openapi 0.8.0）

| 接口 | 方法 | 说明 |
| --- | --- | --- |
| `/api/v1/households` | `GET` / `POST` | `GET` 返回 `{items}`（含自动创建的个人家庭）；`POST {name}` 201 返回家庭，创建者为 `owner` |
| `/api/v1/households/{id}` | `GET` / `PATCH` / `DELETE` | `PATCH {name}`；`DELETE` 204；个人家庭不可删（403 `FORBIDDEN`）；跨家庭 404 |
| `/api/v1/households/{id}/members` | `GET` | `{items}`：`userId` / `role` / `kind` / `joinedAt` |
| `/api/v1/households/{id}/invitations` | `POST` | 201 `{code, expiresAt}`：8 位、一次性、默认 24 小时；仅 owner |
| `/api/v1/households/invitations/claim` | `POST` | `{code}`（大小写不敏感）→ 200 家庭对象（`role=member`）；无效 / 已用 / 过期 404；限流 429 带 `Retry-After` |
| `/api/v1/households/{id}/rooms` | `GET` / `POST` | `{items}`；`POST {name, sortOrder}` 201；仅 owner，member 403 `FORBIDDEN` |
| `/api/v1/households/{id}/rooms/{roomId}` | `PATCH` / `DELETE` | 改名 / 排序 / 删除；仅 owner；跨家庭 404 |
| `/api/v1/my/devices/{platform}/{externalId}` | `PATCH` | `alias` / `roomId` / `householdId` **三态**：字段缺失 = 不变、空串 = 清除（`null`）、非空 = 覆盖；非本人设备 404 |

客户端口径：设备归属与 `sync/push` 解耦（避免 LWW 覆盖），失败进 `device_assignment_pending`；403 / 404 为终态并转为可读文案；删除家庭后服务端把设备回落到个人家庭并清空 `roomId`，客户端按下一轮拉取对齐。契约由 `scripts/e2e-contract.sh` 第 9 节覆盖。

---

## 8. 持续集成

### 8.1 GitHub Actions（已实际运行，当前主用）

[`.github/workflows/ios.yml`](.github/workflows/ios.yml)：`runs-on: macos-15`，两个并行 job；只做构建、单元测试与契约联调，不做签名 / Archive。

- 触发：**仅 push 到 `main` 与 `v*` tag**（另保留 `workflow_dispatch` 手动触发）；**PR 不跑**。
- **去重**：`concurrency: group: ios-${{ github.sha }}` + `cancel-in-progress: true`。同一提交既推 `main` 又打 tag 时只保留后到的一次运行，先到的自动取消，避免重复消耗 macOS 分钟。
- Job `build-test`：`actions/checkout@v7` → 选择 Xcode（优先 `Xcode_16.4`）并打印 `xcodebuild -version` / 可用模拟器 → `xcodebuild build`（`generic/platform=iOS Simulator`）→ `xcodebuild test`（从 `xcrun simctl list devices available` 动态取首个 iPhone 模拟器 UDID）→ `actions/upload-artifact@v7` 上传 `*.xcresult`（`if: always()`）。
- Job `e2e-contract`（与 build 并行）：`actions/checkout@v7` 拉本仓库 + `platojobs/PJGoIoT`（`repository` + `path: PJGoIoT`）→ `actions/setup-go@v7`（`go-version-file: PJGoIoT/go.mod`）→ `PJGOIOT_DIR=${{ github.workspace }}/PJGoIoT bash scripts/e2e-contract.sh`；失败时 `actions/upload-artifact@v7` 上传 `.build/e2e/` 日志。失败即红，无 `|| true`。
- 两个 job 均使用 `CODE_SIGNING_ALLOWED=NO`，不需要证书与描述文件。
- 当前真实运行：[run 42060000856](https://github.com/platojobs/codemagic/actions/runs/42060000856)（`v0.15.0` 提交 `e4f3dc8`，tag push），**success**（Xcode 16.4）：
  - `Build & Test (iOS Simulator)` **success**（4m49s），`** BUILD SUCCEEDED **` / `Executed 303 tests, with 0 failures` / `** TEST SUCCEEDED **`；
  - `E2E contract (PJGoIoT fixture)` **success**（1m12s），`通过：260 项，跳过：0 项，失败：0 项` / `结论：PASS`（含家庭 v0.13.0 链路：成员移除 / 退出 409 / 邀请码无明文与撤销 / 整段重排 409）；
  - 同 sha 的 `main` 运行 [run 42059975519](https://github.com/platojobs/codemagic/actions/runs/42059975519) 被 tag 运行按 `concurrency: ios-${sha}` 取消（结论 `cancelled`）；tag 运行两个 job 均绿。
  - 真实 Postgres e2e（`scripts/e2e-postgres.sh`）**不进 CI**：GitHub Actions 的 macOS runner 无 Docker；本机运行 PASS，输出见 `docs/e2e-postgres.md`。
  - 全部 action 已升到 `checkout@v7` / `upload-artifact@v7` / `setup-go@v7`，**Node 20 弃用告警已消除**（仅剩 macOS arm64 队列容量提示）。
- 上一轮记录：[run 42047411803](https://github.com/platojobs/codemagic/actions/runs/42047411803)（`v0.14.0`，293 单测 / 224 项 E2E，success）；更早：[run 42012100360](https://github.com/platojobs/codemagic/actions/runs/42012100360)（`v0.11.0`，260 单测 / 151 项 E2E，success）、[run 42006790396](https://github.com/platojobs/codemagic/actions/runs/42006790396)（`v0.10.0`，236 单测 / 151 项 E2E，success）、[run 41973731269](https://github.com/platojobs/codemagic/actions/runs/41973731269)（`v0.9.0` 提交 `08f88d6`，226 单测 / 151 项 E2E，success）。
- locale 修复记录：v0.6.0 首次 run 41955082837 在英文 CI locale 下因测试用中文别名参与 `localizedCaseInsensitiveCompare` 产生乱序；v0.7.0 新增的倒计时 / 排序断言全部显式 `Locale(identifier: "en_US_POSIX")` 或 ASCII 别名，run 41961761756 一次通过。
- 失败与修复：首次 workflow 因 `run: |` 块内嵌的多行 Python 未随块缩进，YAML 解析失败（run 无任何 job 直接 failure）；改为单行 `simctl + grep/sed` 提取模拟器 UDID 后通过。v0.4.0 新增读数断言后，本地 e2e 因 ~100 次请求触发服务端限流（429），改为 fixture 启动时 `RATE_LIMIT_PER_MINUTE=0` 后稳定通过。
- **计费**：macOS runner 按分钟计费且显著高于 Linux，因此该 workflow 只在 `main` 与 tag 触发、不跑 PR，并用 `concurrency` 按 sha 去重；单个提交一次运行约消耗 5–6 个 macOS 分钟。

### 8.2 Codemagic（可选替代，未验证）

仓库根目录 `codemagic.yaml`（Codemagic）：

- 运行环境：Codemagic `mac_mini_m2`（macOS），指定 **Xcode 16.4**。
- 步骤：`xcodebuild -version` → `xcodebuild -list` → 模拟器 `build` → 模拟器 `test` → 打包 `codemagic.app`。
- 产物（artifact）：`codemagic-simulator-app.zip`（Debug-iphonesimulator）与 `build/ios/Logs/Test/*.xcresult`。
- 使用 `CODE_SIGNING_ALLOWED=NO`，不依赖签名证书。
- **该配置尚未在 Codemagic 上实际运行**，仅作为可选替代方案保留；当前以 GitHub Actions 为真实 CI 证据。
- 历史说明：本仓库 OAuth token 缺少 `workflow` scope，`.github/workflows/*` 无法用 HTTPS 推送；本次改用 SSH over 443（`ssh://git@ssh.github.com:443/platojobs/codemagic.git`）推送，未修改全局 git config。

---

## 9. 已知限制与需真机验证

已知问题汇总见 **[KNOWN_ISSUES.md](KNOWN_ISSUES.md)**。以下内容只完成编译、单元测试与静态验证，**必须在真实 iPhone 上自测**：

- [ ] 首次蓝牙授权弹窗、允许 / 拒绝 / 受限三种状态的实际表现与跳系统设置。
- [ ] 真实 BLE 扫描能否发现设备、名称 / 标识符 / RSSI 是否随距离变化。
- [ ] 连接设备后的状态流转、断开事件，以及 12s 连接超时。
- [ ] 断开规则在设备离开范围后是否按预期触发（10s 未出现判定）。
- [ ] 读数采集：真实可穿戴设备的 notify 频率、心率 / 电量 / 温度 / NUS 实际帧格式是否与解析器假设一致。
- [ ] 设备详情「数据」区在真机上的区间切换、长区间图表渲染性能、缺口断线与离线标注。
- [ ] RSSI 阈值规则的触发 / 恢复重新武装。
- [ ] 后台 / 锁屏后的扫描与回调行为（当前未申请后台蓝牙模式）。
- [ ] 真实后端域名下的产品 / 市场 / 设备详情 UI（服务端契约已由 E2E 覆盖，Release mock 尚未验证 0.3.3 端点与新字段）。
- [ ] App 内同步在真机 + 真实后端的完整闭环（E2E 已覆盖服务端契约，但未覆盖 App 的 Keychain、BGTask 与 UI 提示）。
- [ ] `BGAppRefreshTask` 在真机上的实际调度（模拟器不执行后台刷新）。
- [ ] 真机上确认「来自 Android，本机不可连接」设备的列表样式与点击无响应。

其他限制：

- 模拟器无真实蓝牙，状态为 `unsupported`；产品 / 市场 / 详情依赖网络，需运行包含 readings 链路的本地 Go 服务或已更新的 mock。
- 已实现 GATT 服务发现与四个读数特征的 notify 订阅；**未实现特征写入 / OTA**，GATT 元数据仍来自 catalog。
- 契约已用本地 fixture 服务端到端验证（260 项断言 PASS，后端 `PJGoIoT` v0.13.0 / openapi 0.9.0，含家庭 v0.12.0 与 v0.13.0 链路）；同一套件在本地真实 Postgres 栈重跑同样 260 项 PASS，并直接 `psql` 校验邀请码只存哈希、成员行清理；410 / series / metrics / export / 注销亦由 `scripts/e2e-postgres.sh` 跑通（不进 CI）。App 内的 Keychain token、BGTask 调度、后台 BLE 采集与真实网络环境仍需真机验证。
- 后端 `PJGoIoT` 已打 tag **v0.13.0**（成员移除 / 退出 / 邀请码列表与撤销 / 房间整段排序，openapi 0.9.0；v0.12.0 起家庭 / 邀请码 / 房间 / 设备归属 PATCH）；iOS 按该契约实现。CI 直接 checkout 后端 `main`（本次对应 tag `v0.15.0`，向后兼容；`ROOM_SET_MISMATCH` 在新版返回，v0.13.0 为 `CONFLICT`，客户端两者都识别），260 项 E2E 全 PASS；若 checkout 到旧后端，e2e 相关分支会明确 SKIP。
- [ ] 真机 + 两个真实账号：创建家庭 / 邀请码领取 / 成员共享 / member 403 / 跨家庭 404 的界面表现（服务端契约已由 E2E 覆盖，App 端需实际走查）。
- [ ] 真机：家庭切换后的首页 / 房间管理刷新、邀请码倒计时与复制、离线房间「未同步」标注。
- [ ] 真机 + 真实后端：断网 90 天以上游标（改库 + cleanup 构造 410）后的自动全量重同步、pending 保留与 UI 提示。
- [ ] 真机 + 真实后端：503 `TIMEOUT` 的「服务端繁忙，稍后重试」与退避闸门（手动同步可立即重试）。
- [ ] 真机：token 过期后的「登录已失效」与「会话到期日」展示、接管 / 注销后的更新与清除。
- Release 签名与 App Store 上架未验证（无 Apple 开发者账号 / 证书）。

---

## 10. 版本记录

- `v0.15.0`：家庭管理补齐 —— 成员移除 / 退出 / 邀请码管理 / 房间整段排序与真实计数（`MARKETING_VERSION 0.15.0` / build 23，tag `v0.15.0`）。SQLite 迁移 **v10** 为 `households` 条件补 `room_count`，`memberCount` / `deviceCount` / `roomCount` 全部来自 `GET /households`，不再本地计数。新增后端 v0.13.0（openapi 0.9.0）接口：`DELETE /households/{id}/members/{userId}`（owner 移除成员 204，对方访问家庭 404、设备回个人家庭、房间清空）；`POST /households/{id}/leave`（204，owner 还有其他成员时 409，界面与服务端统一为「请先转让所有权或移除其他成员」，**机读判断只看状态与端点，不解析 message**）；`GET /households/{id}/invitations`（只含 `codeHashPrefix` / `status` / `attempts` / `expiresAt`，模型无 `code` 字段，绝不显示明文）与 `DELETE .../invitations/{invitationId}`（撤销后 claim 404）；`PUT /households/{id}/rooms/order`（整段提交，缺项 / 多项 / 重复 409，客户端自动重新 GET 并提示「房间列表已变化，已刷新」；v0.13.0 返回 `CONFLICT`、后续版本 `ROOM_SET_MISMATCH`，两者都识别）。家庭管理 UI 增加成员左滑 / 点击移除（二次确认说明设备回落）、退出家庭、邀请码列表 + 撤销、owner 改名；owner / member 入口按角色裁剪（member 看不到签发 / 撤销邀请码、移除成员、改家庭名）。房间管理新增「排序」拖拽模式与左滑上移 / 下移，本地未同步房间不参与整段提交。退出 / 被移除后本地设备回落个人家庭、房间脱钩保留并标「未同步」。新增单测 10 个（共 **303** 个，0 失败），E2E **260** 项全 PASS（fixture，后端 v0.13.0）；真 Postgres 同契约 + 直接查库（邀请码只存 64 位哈希、移除后成员行删除、退出清理）。
- `v0.14.0`：家庭接入后端 —— 家庭归属、成员共享与房间服务端化（`MARKETING_VERSION 0.14.0` / build 22，tag `v0.14.0`）。SQLite 迁移 **v9** 新增 `households`（`id` 复用远端 UUID / `remote_id` / `name` / `is_personal` / `role`）与 `device_assignment_pending`；`rooms.remote_id` 真正启用并增加 `household_id` / `sync_state` / `deleted`；`saved_devices` 增加 `household_id` / `remote_room_id` / `remote_household_id`，条件 ALTER，旧库不丢房间与归属。登录后 `GET /households` 落库并持久化当前家庭，切换家庭按该家庭拉设备与房间；首次接入把本机未归属房间按 `sort_order` 推服务端，服务端同名房间**认领**本地房间而非重复创建，失败保留 `pending` 重试，**不静默丢弃**；服务端已删除家庭的房间脱钩保留、不自动搬入其他家庭。设备归属独立走 `PATCH /my/devices/{platform}/{externalId}` 三态（缺失 / 空串 / 非空），不塞进 push，失败进 pending 队列。新增「我的 → 家庭管理」（当前家庭与角色、成员列表、创建家庭、8 位一次性邀请码 + 服务端倒计时 / 复制 / 过期重生成、输入码加入）、首页多家庭切换、member 只读与 403 可读降级、跨家庭 404、离线「未同步」标注。新增单测 9 个（共 **293** 个，0 失败），E2E **224** 项全 PASS（新增家庭链路）。后端 `PJGoIoT` v0.12.0（openapi 0.8.0）。
- `v0.13.0`：房间归属 + 首页按房间分区（`MARKETING_VERSION 0.13.0` / build 21，tag `v0.13.0`）。SQLite 迁移 **v8** 新增 `rooms` 表（`id` / `name` / `sort_order` / `remote_id` / `created_at` / `updated_at`）与 `saved_devices.room_id`（可空，NULL = 未分配），旧数据与原 `group_name` 原样保留；首页从扁平分组改为**按房间分区**，房间标题可展开 / 收起、「未分配」固定最后，无房间显示「还没有房间」+「新建房间」、房间空显示扫描引导；右上角房间管理支持新建 / 重命名 / 删除（二次确认后设备回到未分配），设备可在详情页或首页长按移入 / 移出；房间与归属仅本机、不参与 push / changes，`Room.remoteID` 为远端家庭 / 房间接口预留映射。交互取舍：搜索只匹配设备并隐藏空房间、排序只在房间内生效、分区顺序固定，首页原「分组筛选」移除，`group_name` 仅兼容保留。新增单测 7 个（共 284 个），E2E 151 项无契约变更。
- `v0.12.0`：推荐规则 + 中英双语 + 动态字体（`MARKETING_VERSION 0.12.0` / build 20，tag `v0.12.0`）。推荐规则只按设备真实出现过的指标生成（温度 > 30℃、湿度 > 70%、电量 < 20%、心率 > 120、CO₂ > 1000ppm），一键写入现有 `readingThreshold` 规则并立即出现在列表，不新建模型、不改数据库；无设备 / 无读数分别给真实空态。全部界面文案抽到 `zh-Hans` / `en` 两份 `Localizable.strings`（685 key，key 集合与 `%@` 占位符一致由单测强制），`InfoPlist.strings` 双语权限文案，工程 `knownRegions` 含 `zh-Hans`、`CFBundleLocalizations = [en, zh-Hans]`，设置跟随系统语言；术语 Device / Reading / Sync / Scan / Group / Alert / Transfer Code。字号统一 `AppText` + `UIFontMetrics` + `adjustsFontForContentSizeCategory`，表格行高自适应，图表 Y 轴左侧留白按字号测量、超大字号下 3 个刻度且不压绘图区；数字与日期显式 `Locale.current`（CSV 仍 POSIX + UTC）。新增单测 17 个（共 277 个），E2E 151 项无契约变更。
- `v0.11.0`：指标阈值规则 + 图表点选 + CSV 区间文件名（`MARKETING_VERSION 0.11.0` / build 19，tag `v0.11.0`）。规则条件扩为「指标 + 比较符 + 阈值 + 连续 N 条（1–5，默认 1）」，判定接在 `ReadingsIngestor` → `RuleEvaluator` 同一链路，命中日志带触发值 / 阈值 / 时间 / 设备并进「智能 → 最近触发」，恢复只在确实发过触发通知后补一条；SQLite v7 为 `rules` 增加 `metric` / `comparison` / `reading_threshold` / `consecutive` 并回填旧规则（仍按 RSSI / 断开生效）。图表支持点选 / 长按桶查看 `start–end`、min/max/avg/last 与条数（本地时区），点空白取消、Y 轴不变、无障碍摘要随选中更新；几何命中（最近桶 / 24pt 近邻阈值 / 空白不命中）为纯函数。CSV 文件名含设备名、设备标识末 8 位、指标与 UTC 区间起止。新增单测 24 个（共 260 个）。规则仅本机，不改变网络契约。
- `v0.10.0`：跟进后端新契约与真 Postgres E2E（build 18，tag `v0.10.0`）。410 `RESYNC_REQUIRED` 清游标并以 `cursor=0` 全量重拉，pending 设备 / 读数保留并重新上传，终态只处理一次、不进指数退避，界面明确提示；503 `TIMEOUT` 映射「服务端繁忙，稍后重试」并退避；401 文案「登录已失效」；`expiresAt` 在「我的」只读展示；`readings 500 / export 5000 / changes 500` 上限提前分片。新增 `scripts/e2e-postgres.sh`（本地真 Postgres，macOS runner 无 Docker 故不进 CI）。单测 236 个，E2E 151 项。
- `v0.9.0`：首启引导 + 权限前置 + 启动打点 + 上架材料（`MARKETING_VERSION 0.9.0` / build 17，tag `v0.9.0`）。新增 3 步首启引导（蓝牙 / 通知 / `bluetooth-central` 后台限制），仅首次或未走完时出现，可跳过，`settings.onboardingCompleted` / `settings.onboardingStep` 持久化；蓝牙改为「先说明后申请」：`CBCentralManager` 延迟到用户点「继续」或真实扫描时创建，冷启动不再弹授权框；拒绝 / 受限时展示「仅本机可用」与「去系统设置」，首页空态主行动统一为「开始扫描」，权限被拒时改为「去系统设置」。新增 `App/LaunchMetrics.swift`（`os_signpost` + 控制台打点）与阶段日志：稳态冷启动 302.5 ms → 288.5 ms（4 次中位数，Debug 模拟器），首装首启 1718.3 ms → 479.3 ms；7 天读数清理移到后台队列，SQLite 打开 / 迁移仍同步（1.8 ms）。新增 `docs/store-listing.md`、`docs/privacy-policy.md`、`docs/app-privacy.md` 与 `PrivacyInfo.xcprivacy`（UserDefaults `CA92.1`、文件时间戳 `C617.1`、系统启动时间 `35F9.1`；无位置 / 广告 / 分析 / 账号密码）。术语统一：设备（不用装置）、同步（不用上传）、告警（事件）/ 通知（系统渠道）、接管码（不用配对码）；新增 `OnboardingTests` 5 个用例（含 13 条高频文案禁用词审计）。单测 **226** 个，E2E 151 项（无契约变更）。后端 `PJGoIoT` v0.7.0（契约 0.6.0）。
- `v0.8.0`：设计令牌落地 + 米家信息架构 + 本地场景（`MARKETING_VERSION 0.8.0` / build 16，tag `v0.8.0`）。新增 `DesignSystem/DesignTokens.swift`：`Palette` 36 个语义色（浅/深各一套，`UIColor(dynamicProvider:)`）、`Layout` 4pt 阶梯 / 16 页边距 / 56·72·88 行高 / 12 圆角 / 1dp 描边、`AppText` 10 级字号与等宽数字、`Motion` / `Elevation`；窗口与导航栏跟随语义色，统一按压态（浅 6% / 深 8% 遮罩，卡片 0.98）与列表卡片 1dp 描边零阴影；自绘大标题 96→56 收缩（12pt 阈值、200ms 插值）。五 Tab 改为**首页 / 智能 / 产品 / 市场 / 我的**，原「设备」Tab 取消：首页为设备卡片网格（名称 / 连接状态 / 最近读数 / 信号条、分组分段、搜索排序、今日告警摘要、快捷场景），「智能」集中自动化规则与场景。新增 SQLite `scenarios` 表（迁移 **v6**，仅本机不同步）与场景执行器：连接 / 断开设备、开始 / 停止后台采集、静音告警 10/30/60 分钟、立即同步；逐动作执行、失败不阻断、汇总成功/失败与原因并显示进度。三态（骨架 300ms 延迟、空状态真实文案 + 主行动、错误可重试）覆盖五 Tab。单测 **221** 个（新增 14 个：令牌审计 / 场景执行 / 迁移 v6），E2E 151 项（无契约变更）。后端 `PJGoIoT` v0.7.0（契约 0.6.0）。
- `v0.7.0`：配对码跨设备接管、账号数据导出与注销、后台采集（`MARKETING_VERSION 0.7.0` / build 15，tag `v0.7.0`）。「我的」新增 8 位一次性配对码（真实 `expiresAt` 倒计时、复制、重新生成使旧码失效）、从旧设备接管（token 替换 + 本机设备/读数全部重新标记 pending + 游标清零）、账号导出（`hasMore`/`nextCursor` 循环拉全、临时文件分享后删除、真实进度）、注销（二次确认永久删除，成功清 Keychain/SQLite 业务表/同步元数据，401 与网络错误分别处理）。声明 `bluetooth-central`，新增持久化后台采集开关（默认开启、说明耗电、关闭即断开）；后台唤醒仅受限推送（≤100 设备/≤200 读数、≥15 分钟间隔、不拉增量不建号）。单测 207 个（新增 19 个），E2E 151 项（新增 28 项）。后端 `PJGoIoT` v0.7.0（契约 0.6.0）。
- `v0.6.0`：请求节流、本地降级与四项产品功能（`MARKETING_VERSION 0.6.0` / build 14，tag `v0.6.0`）。详情页读数 notify 只本地重绘，远端刷新 800ms 去抖合并，不可见/后台不请求，失败指数退避 ≤5 分钟；服务端指标为空且本地有待同步读数时用本地指标与 UTC 网格并标注「待同步：本地数据」。新增阈值告警本地通知（首次使用授权、1/5/30 分钟节流、恢复通知、点击进详情、「我的」真实开关与权限引导）、CSV 导出（7 天内本地 / 更长服务端分页 ≤5 万条、UTF-8 BOM、ISO8601 UTC、RFC 4180 转义、临时文件分享后删除、真实进度与重试）、设备列表搜索/持久化排序/分组筛选/双空状态、外观三态与动态语义色（AccentColor 增 dark 变体）。单测 188 个（新增 31 个），E2E 123 项（无契约变更）。后端 `PJGoIoT` v0.5.1。
- `v0.5.0`：设备详情「数据」区升级为长周期可切换图表（`MARKETING_VERSION 0.5.0` / build 13，tag `v0.5.0`）。新增 `ReadingsRange`（1 小时 / 24 小时 / 7 天 / 30 天，默认 24 小时）映射 `1m` / `1h` / `1h` / `1d`，切换即时重绘并重新查询 `readings/series`（`from` / `to` 为 UTC RFC3339）；X 轴按桶 `start` 真实时间比例定位，缺口处折线断开（不跨缺口连线），`avg` 折线叠加 `min`–`max` 区间带，Y 轴按区间 min/max 自适应并带单位；几何独立在 `ReadingsChartGeometry`。指标清单改用 `readings/metrics`（`count` / `lastAt` / `unit`），展示「指标名 · N 条」，单位随指标同步；离线按同一 UTC 网格聚合本地数据，30 天区间标注「离线：仅本地 7 天数据」。单测 157 个（新增 16 个），E2E 123 项（新增 17 项：series/metrics/空区间/非法 bucket）。后端 `PJGoIoT` v0.5.1。
- `v0.4.1`：读数解析黄金用例两端对齐（`MARKETING_VERSION 0.4.1` / build 12，tag `v0.4.1`）。新增 `codemagicTests/ReadingsGoldenTests.swift` 18 个用例（心率 / 电池 / 温度 / NUS / 空字节）；`docs/consistency.md` 新增 3.8「读数解析黄金用例」章节，声明两端共用同一张表；复核 7 天清理只删已同步记录，补「30 天前 pending 清理后仍在」用例；单测 141 个。核对发现表中 `00 4A → 20.0` 与 IEEE-754 binary16 不符（`0x4A00` = 12.0，20.0 对应 `0x4D00`），实现按真实半精度解码、未硬编码，两条位型均有用例并在文档脚注标注。实现行为无变更。
- `v0.4.0`：接入设备读数链路（`MARKETING_VERSION 0.4.0` / build 11，tag `v0.4.0`）。连接后订阅心率 `0x2A37` / 电量 `0x2A19` / 温度 `0x2A6E` / Nordic UART TX，四个独立解析器（失败静默丢弃 + 本地「读数」日志）；SQLite 迁移 **v5** 新增 `readings` 表并做 7 天保留清理；读数并入 `/sync/push`（≤200/批，按 `id` 幂等，幂等键含读数）；设备详情新增「数据」区（真实指标选择 + 最近 60 点自绘折线图 + 24h 汇总 + 最近记录 + 离线标注 + 三种真实空状态）；单测 122 个，E2E 106 项（新增 19 项读数断言）。后端 `PJGoIoT` 使用当前 main（尚未打 v0.4.0 tag）。
- `v0.3.6`：对齐 `openapi.yaml` **0.3.3**（`MARKETING_VERSION 0.3.6` / build 10，tag `v0.3.6`）。`UserDevice` 新增 `advertisedName`，本地迁移 **v4** 区分用户别名与广播名；`alias` / `advertisedName` / `group` 采用 `Patch` 三态（未修改省略、`""` 显式清除、具体值上报），清空分组上报 `"group": ""` 且再次同步不复活；缺省字段不参与 LWW 与幂等哈希；冲突响应缺省字段按 absent 解析；单测 81 个，E2E 87 项（新增 3.7 的 16 项断言）。
- `v0.3.5`：CI 与 Android 对齐（`MARKETING_VERSION 0.3.5` / build 9，tag `v0.3.5`）。`actions/checkout` / `upload-artifact` / `setup-go` 全部升到 **v7**，消除 Node 20 弃用告警；新增并行 `e2e-contract` job（checkout `PJGoIoT` + `setup-go` 读 go.mod + 运行 `scripts/e2e-contract.sh`，失败上传日志）；`concurrency` 改为按 `github.sha` 分组去重；真实 run 41906015761 两个 job 均 success（74 单测 + 71 项 E2E）。
- `v0.3.4`：CI 落地（`MARKETING_VERSION 0.3.4` / build 8，tag `v0.3.4`）。新增 `.github/workflows/ios.yml`（macos-15 + Xcode 16.4，build + 74 单测 + xcresult artifact，仅 main/tag 触发）；GitHub Actions 首次真实运行 success（run 41902292283）；`codemagic.yaml` 保留为可选替代但未验证。
- `v0.3.3`：对齐 `openapi.yaml` **0.3.2**（`MARKETING_VERSION 0.3.3` / build 7，tag `v0.3.3`）。接入 `UserDevice.deviceType` / `vendor` / `firmwareVersion` / `compatibility`（可空，详情页云端优先，null 显示「型号未知 / — / 暂无兼容性说明」，未注册型号仍展示别名 / 分组 / 最近出现）；catalog `firmwares` / `accessories` 接入 `vendor` / `compatibility`；市场新增按厂商与兼容性筛选（真实字段）；`PushDevice.deviceType` 可选，已知型号才上传；SQLite 迁移 v3（`saved_devices.device_type`）；单测 74 个，E2E 71 项（新增 catalog vendor/compatibility 与 UserDevice 新字段、null 降级断言）。
- `v0.3.2`：文档补齐（`docs/acceptance.md` 真机验收清单、`docs/troubleshooting.md`、`docs/releasenotes.md`）；401 登录失效交互：「我的」页展示「登录已失效」+「重新登录」确认流程，确认后才换匿名账号，游标重置并重推本地活动设备；`sync.reloginRequired` 持久化，前后台自动同步不再静默建号；单测增至 68 个；`MARKETING_VERSION 0.3.2` / build 6，tag `v0.3.2`。
- `v0.3.1`：对齐 `openapi.yaml` 0.3.1（`MARKETING_VERSION 0.3.1` / build 5，tag `v0.3.1`）；产品改为 `device-types` + `{type}/catalog`，市场由 catalog 聚合 firmware + accessories，iOS 设备详情改用复合键 `my/devices/ios/{externalId}`；移除产品 / 市场 / 设备详情的全部历史端点；E2E 扩至 55 项断言（含 catalog 与复合键 200/404）；单测 64 个。
- `v0.3.0`：版本号对齐（`MARKETING_VERSION 0.3.0` / build 4，tag `v0.3.0`，保留 `v0.2.0`）；新增 `scripts/e2e-contract.sh` + 独立 Swift runner，对本地 `PJGoIoT`（`STORE=fixture`）完成 43 项契约联调（匿名登录、双平台推送、changes 形状、幂等重放、LWW 冲突、401/404）；跨平台 Android 设备在列表标注「来自 Android，本机不可连接」并禁用连接；按 `openapi.yaml` 修正 `docs/consistency.md` 的错误码与对齐状态；单测增至 63 个。
- `v0.2.0`：落地同步层（匿名登录 / Keychain token / 增量拉取 / 批量推送幂等 / 冲突提示 / tombstone）、SQLite 迁移 v2（`platform` + `external_id`）、`BGAppRefreshTask` 与前后台触发、「我的」同步状态与手动同步、版本号对齐；新增同步相关单元测试并更新 `docs/consistency.md`。
- `v0.1.0`：五模块（首页 / 设备 / 产品 / 市场 / 我的）、CoreBluetooth 扫描与连接、SQLite 持久化、URLSession + Codable 网络层、本地规则、设备详情缓存降级、自绘 RSSI、代码空状态、44 个单元测试、Codemagic CI。

---

## 11. 术语表（易混词）

| 概念 | 统一用词 | 不使用 | 口径 |
| --- | --- | --- | --- |
| 被扫描 / 连接的硬件 | **设备** | 装置、机器、仪器 | 代码与 UI 统一 `SavedDevice` / 「设备」 |
| 双向数据一致 | **同步** | 上传、下发 | 「待同步」「同步完成」「立即同步」；`upload` 仅存在于内部 API 命名 |
| 规则越界事件 | **告警** | 提示、警告、报警 | 首页「今日告警摘要」、阈值告警；`Alert` 仅用于系统弹窗 |
| 系统通知渠道 | **通知** | — | 「通知权限」「通知开关」；本地通知由 `UNUserNotificationCenter` 发出 |
| 发现附近 BLE | **扫描** | 搜索 | 「开始扫描」「扫描附近设备」 |
| 过滤已保存设备 | **搜索** | — | 首页搜索框仅过滤本机设备，不触发扫描 |
| 设备上报的值 | **读数** | 数值、参数、数据点 | 心率 / 电量 / 温度均为读数；阈值是规则条件 |
| 用户对设备的分类 | **分组** | 分类（用于市场 / 产品筛选时保留「分类」） | v0.13.0 起仅作兼容字段，首页分区改用「房间」 |
| 设备的空间归属 | **房间** | 分组、标签、家庭 | 首页房间分区 / 房间管理；房间仅本机，不参与同步 |
| 自动化条件 | **规则** | 策略、场景 | 「智能 → 自动化」 |
| 本地动作组合 | **场景** | 快捷指令、自动化（与规则区分） | 「智能 → 场景」，仅本机 |
| 8 位一次性跨设备迁移码 | **接管码** | 配对码（「配对」仅指系统蓝牙配对） | 「迁移到新设备 / 从旧设备接管」；接口与文档保留 `pairing code` 旧名 |

测试：`codemagicTests/OnboardingTests.swift::testHighFrequencyCopyAvoidsBannedTerminology` 覆盖 13 条高频文案（≥5 条），禁用词含装置、机器、上传、数值、参数、策略、配对、感叹号与口语语气词、`暂无数据`。

英文术语（v0.12.0）：设备 **Device**、读数 **Reading**、同步 **Sync**、扫描 **Scan**、分组 **Group**、告警 **Alert**、接管码 **Transfer Code**（不使用 `pairing code`；`pairing code` 仅保留在旧接口 / 文档字段名中）。

---

## 12. 上架材料

| 文件 | 内容 |
| --- | --- |
| [`docs/store-listing.md`](docs/store-listing.md) | 中 / 英文短描述（中文 ≤80 字、英文 ≤30 词）、长描述（仅已实现功能）、关键词、4+ 分级、明确「不含交易 / 广告 / 账号密码登录 / 位置权限 / 分析 SDK」、审核备注 |
| [`docs/privacy-policy.md`](docs/privacy-policy.md) | 逐项收集清单（BLE 标识、广播名 / 别名、读数与时间戳、匿名账号 ID 与 Keychain token）、用途、服务端 90 天 / 本机 7 天保留、注销即删、无广告 / 分析 SDK、不上传位置 |
| [`docs/app-privacy.md`](docs/app-privacy.md) | `PrivacyInfo.xcprivacy` 与代码位置逐项对照，含必需理由 API（UserDefaults `CA92.1`、文件时间戳 `C617.1`、系统启动时间 `35F9.1`） |
| [`codemagic/Resources/PrivacyInfo.xcprivacy`](codemagic/Resources/PrivacyInfo.xcprivacy) | 实际打包进 App 的隐私清单：非追踪、5 类收集数据（Device ID / User ID / Other User Content / Health / Other Usage Data）、3 类必需理由 API |

> 上架文案与版本说明一致：当前为 `v0.15.0`（build 23），详见 [`docs/releasenotes.md`](docs/releasenotes.md)。
