# 版本发布说明（iOS · codemagic）

按 tag 记录真实变更。版本号与 `PJGoIoT` / `PKotlinApp` 保持同一序列；同一 tag 的 iOS 构建号见下表。

| Tag | MARKETING_VERSION | Build | 日期 | 对齐后端 |
| --- | --- | --- | --- | --- |
| `v0.10.0` | 0.10.0 | 18 | 2026-11-05 | PJGoIoT v0.9.0（openapi 0.7.0；410 / 503 TIMEOUT / expiresAt / 分页上限） |
| `v0.9.0` | 0.9.0 | 17 | 2026-11-05 | PJGoIoT v0.7.0（契约 0.6.0；无后端变更） |
| `v0.8.0` | 0.8.0 | 16 | 2026-11-05 | PJGoIoT v0.7.0（契约 0.6.0；无后端变更） |
| `v0.7.0` | 0.7.0 | 15 | 2026-11-05 | PJGoIoT v0.7.0（契约 0.6.0） |
| `v0.6.0` | 0.6.0 | 14 | 2026-11-05 | PJGoIoT v0.5.1 |
| `v0.5.0` | 0.5.0 | 13 | 2026-11-05 | PJGoIoT v0.5.1 |
| `v0.4.1` | 0.4.1 | 12 | 2026-11-05 | PJGoIoT v0.4.0（tag `7acab36`） |
| `v0.4.0` | 0.4.0 | 11 | 2026-11-05 | PJGoIoT main `7acab36`（当时未打 tag） |
| `v0.3.6` | 0.3.6 | 10 | 2026-11-05 | 0.3.3 |
| `v0.3.5` | 0.3.5 | 9 | 2026-11-05 | 0.3.2 |
| `v0.3.4` | 0.3.4 | 8 | 2026-11-05 | 0.3.2 |
| `v0.3.3` | 0.3.3 | 7 | 2026-11-05 | 0.3.2 |
| `v0.3.2` | 0.3.2 | 6 | 2026-11-05 | 0.3.1 |
| `v0.3.1` | 0.3.1 | 5 | 2026-11-05 | 0.3.1 |
| `v0.3.0` | 0.3.0 | 4 | 2026-11-05 | 0.3.0 |
| `v0.2.0` | 0.2.0 | 3 | 2026-11-05 | 0.2.0 |
| `v0.1.0` | — | 1 | 2026-11-05 | — |

---

## v0.10.0（build 18）

**主题：跟进后端新契约（410 / 503 / expiresAt / 分页上限）与真 Postgres E2E**

### 410 `RESYNC_REQUIRED` 全量重同步
- 收到 `410 {"error":{"code":"RESYNC_REQUIRED"}}`：`SyncMetadataStore.resetCursor()` 清空游标与 `lastSyncAt`，立即以 `cursor=0` 全量重拉；合并规则复用首次拉取，本地 pending 设备 / 读数不清理，拉取后仍重新上传。
- 410 属终态分支：不进指数退避、只处理一次；二次仍 410 直接失败，不死循环。
- 「我的」同步状态区明确展示「云端变更记录已过期，已重新全量同步；…」，不静默。
- 单测覆盖：游标归零、pending 保留并重新推送、二次同步从新游标、UI 文案、fake transport 410 → 全量 200 → push；另加「二次仍 410 不死循环」。

### 其它契约
- `503 TIMEOUT` 映射「服务端繁忙，稍后重试」，按指数退避（30s 起、上限 5 分钟）设自动同步闸门；绝不按 410 处理。
- `401`（含 token 180 天 TTL 过期）沿用既有重登流程，文案统一「登录已失效」。
- `/auth/anonymous` 与 `claim` 解析 `expiresAt` 并存 `sync.sessionExpiresAt`；「我的」新增只读行「会话到期日」，注销 / 重新登录 / 接管时更新或清除。
- 错误码集中到 `APIErrorCatalog` 一张映射表（补 `RESYNC_REQUIRED` / `TIMEOUT` / `IDEMPOTENCY_CONFLICT` 等）。
- 分页上限自查：changes 500、readings 500、export 5000，`APILimits` 在发请求前收敛，避免越界 400。

### 真 Postgres E2E
- 新增 `scripts/e2e-postgres.sh`：起 `PJGoIoT/scripts/stack-for-e2e.sh`（Postgres + API）→ 复用真实栈跑 151 项契约 → 用 SQL 改最老 `server_ts` + `cleanup(90)` 触发真实 410 → `cursor=0` 全量 → series / metrics / export / 注销 → 停栈回收；状态全部落在 `mktemp` 目录。
- 真实运行 PASS，输出见 `docs/e2e-postgres.md`。GitHub Actions macOS runner 无法跑 Docker，本项**不进 CI**，只本地执行。

### 测试与文档
- 单元测试 **236 个，0 失败**；`xcodebuild build` / `test` 全绿；`scripts/e2e-contract.sh` 151 项 PASS。
- `docs/consistency.md` 新增 3.13（410 / 503 / 401+expiresAt / 分页上限）与错误码映射表；README 新增「游标失效与全量重同步」；`docs/acceptance.md` 新增 S-01–S-08 真机走查。

---

## v0.9.0（build 17）

**主题：首次使用路径、启动耗时测量、上架材料与术语统一**

### 首启与权限前置（A）
- 新增 3 步首启引导：① 为什么需要蓝牙（扫描 / 连接 / 取数）；② 为什么需要通知（阈值告警、本地生成、不营销）；③ 为什么后台采集只在已连接时继续（`bluetooth-central` 限制、系统可能延后唤醒、断连即停）。
- 仅首次安装或引导未走完时出现；右上角「跳过」持久化完成标记；中途退出按 `settings.onboardingStep` 从原步骤继续。
- 蓝牙授权改为「先说明后申请」：`CBCentralManager` 延迟到用户点「继续」或真实扫描 / 连接时创建，冷启动不再弹授权框。
- 拒绝 / 受限：引导内与首页空态展示「仅本机可用」能力边界 +「去系统设置」；右上角扫描弹出同一说明，不出现死路。
- 首页空态收敛为单一文案与「开始扫描」主行动，删除重复的「还没有设备」副文案。

### 启动耗时（B，实测）
- 新增 `App/LaunchMetrics.swift`：`didFinishLaunching` 首行记起点，根窗口首帧后记终点；`os_signpost` interval `AppLaunch` + 控制台 `[LaunchMetrics]` 阶段日志。
- 工程无 UI Test target，未使用 `XCTApplicationLaunchMetric`，改用上述打点真实采集。
- `AppEnvironment` 装配 15.9 ms → 13.5 ms；SQLite 打开 + 迁移 1.8 ms；同步协调器注册保留在主线程（BGTaskScheduler 要求）。
- 7 天读数清理移到后台 `utility` 队列；蓝牙管理器延迟创建。
- 稳态冷启动到首帧 **302.5 ms → 288.5 ms**（4 次中位数，Debug / iPhone 17 模拟器）；首装首启 **1718.3 ms → 479.3 ms**（授权框不再进入启动路径）。未把 SQLite 与首页数据加载异步化，README 如实标注未做项。

### 上架材料（C）
- `docs/store-listing.md`：中 / 英文短描述、长描述（仅已实现功能）、关键词、4+ 分级、明确不含交易 / 广告 / 账号密码登录 / 位置 / 分析 SDK。
- `docs/privacy-policy.md`：逐项收集（BLE 标识、广播名 / 别名、读数与时间戳、匿名账号 ID 与 Keychain token）、用途、服务端 90 天 / 本机 7 天、注销即删、无广告 / 分析 SDK、不上传位置。
- `docs/app-privacy.md` + `PrivacyInfo.xcprivacy`：5 类收集声明与 3 类必需理由 API（UserDefaults `CA92.1`、文件时间戳 `C617.1`、系统启动时间 `35F9.1`），逐项对应代码位置。

### 术语（D）
- UI 统一：设备（不用装置 / 机器）、同步（不用上传）、告警（事件）/ 通知（系统渠道）、扫描（发现设备）/ 搜索（过滤已保存设备）、接管码（不用配对码）。
- README 新增术语表；新增 `OnboardingTests`（首启持久化、3 步、13 条高频文案禁用词）。

### 质量（E）
- 单测 **226** 个（新增 5 个），0 失败；E2E 151 项对 `PJGoIoT` v0.7.0 全部 PASS（无契约变更）。
- `docs/acceptance.md` 新增 O-01 ~ O-08 首启与权限前置走查项。

---

## v0.8.0（build 16）

**主题：设计令牌落地、米家信息架构重组、本地场景**

### 设计令牌（A）
- 新增 `DesignSystem/DesignTokens.swift`：`Palette` 36 个语义色（浅 / 深各一套，`UIColor(dynamicProvider:)`）、`Layout`（4pt 阶梯、16 页边距、56 / 72 / 88 行高、12 圆角、1dp 描边）、`AppText` / `UIFont`（10 级字号，含 `display34` / `title28` / `headline22` / `body17` / `callout15` / `caption13` / `footnote11` / `numericXL40` / `numericL28` / `numericM20`）、`Motion` / `Elevation`。
- 删除硬编码色值与字号；`window.backgroundColor`、导航栏与状态栏样式跟随语义色；浅 / 深色按语义色自动切换。
- 统一按压态：浅色 6% / 深色 8% 遮罩，不使用整体 alpha；按钮只变色不缩放，卡片按下 0.98。
- 列表卡片 1dp 描边、零阴影；仅浮层使用 2 / 4 / 8dp 阴影；深色用表面色阶 + 描边。
- 读数、阈值、计数使用等宽数字（`monospacedDigitSystemFont`）。
- 自绘大标题滚动收缩 96 → 56（阈值 12pt，200ms 插值，KVO `contentOffset`）。
- 视觉审计单测扩展：除硬编码颜色外，禁止 `systemFont(ofSize:)` 字面量、`monospacedDigitSystemFont` 字面量与裸 `font = UIFont.` 赋值。

### 信息架构（B，对齐米家）
- 五 Tab：**首页 / 智能 / 产品 / 市场 / 我的**。原「设备」Tab 取消，规则入口迁至「智能」，不留重复入口；设备详情仍由 `Modules/Devices` 提供。
- **首页**：设备卡片网格（名称、连接状态、最近一条读数、信号条），按分组分段；顶部保留搜索与排序 / 分组筛选；顶部一行「今日告警摘要」（真实触发条数，点击进「智能」）；下方「快捷场景」横向卡（前 3 个）；点卡片进详情。
- **智能**：分段「自动化 / 场景」。自动化保留规则增删启停与最近 5 条真实触发；场景为本地动作组合。
- **产品 / 市场 / 我的**：保留现有能力，仅视觉与几何收口。

### 场景（C，仅本机）
- 动作集合：连接指定设备、断开指定设备、开始后台采集、停止后台采集、静音告警 10 / 30 / 60 分钟、立即同步。
- SQLite 新表 `scenarios`（迁移 **v6**），仅本机、不参与同步；列表与编辑页均标注「仅本机」。
- 一键执行按顺序逐个动作，失败不阻断后续，汇总成功 / 失败与逐条原因；执行中进度浮层展示当前与已完成动作。
- 首页快捷场景展示前 3 个并提示执行结果（Toast）。

### 质量（D）
- 三态覆盖五个 Tab：骨架延迟 300ms 且与真实内容同高；空状态使用规范真实文案 + 主行动；错误块可重试。
- 新增 14 个单测（总 **221**）：36 语义色与深色变体、Layout / AppText 令牌、硬编码色值与字号扫描、场景存储与迁移 v5→v6、连接 / 断开 / 权限 / 重复执行、静音持久化与非法时长、失败汇总不阻断、同步动作真实调用。
- E2E 151 项（无后端契约变更，后端 `PJGoIoT` v0.7.0）。

---

## v0.7.0（build 15）

**主题：跨设备接管、账号导出与注销、后台采集**

### 功能 1：配对码跨设备接管
- 「我的 → 账号与数据 → 迁移到新设备」调用 `POST /api/v1/auth/pairing-code`，展示 8 位码（每 4 位分组）、依据服务端 `expiresAt` 的每秒倒计时、UTC 过期时间；支持复制原始码。
- 「重新生成」二次确认并明确提示旧码立即失效；失败保留旧码直到过期。
- 「从旧设备接管」输入 8 位码（自动大写、过滤空白与易混字符 `0/O/1/I`、截断 8 位），`POST /auth/pairing-code/claim` 换取 `{userId, token}`。
- 404 统一提示「码无效或已过期」；429 按 `Retry-After` 显示冷却秒数并禁用提交；网络错误可重试；401 提示登录失效。
- 成功后替换 Keychain token，保留本机设备与读数并全部重新标记 pending（设备含别名/分组/广播名三态），游标清零、`reloginRequired` 清除，并自动触发一次同步上传本机数据。

### 功能 2：账号数据导出与注销
- 「导出我的数据」：`GET /api/v1/me/export` 按 `hasMore` / `nextCursor` 循环拉全（游标不透明、不解析），合并读数后写临时 JSON，`UIActivityViewController` 分享，分享结束删除；进度为真实已读取条数，401 / 网络 / 游标异常分别提示，可重试。
- 「注销账号」二次确认写明「设备与读数将永久删除且不可恢复」；`DELETE /api/v1/me` 成功后按 **Keychain → SQLite 全部业务表（单事务）→ 同步元数据** 顺序清理，回到全新匿名状态；401 与网络失败不清理本地数据，分别提示且网络错误可重试。

### 功能 3：后台采集
- `Info.plist` 增加 `bluetooth-central`；连接状态下后台继续接收 notify，走同一入库与 7 天保留逻辑，pending 数据受保护。
- 「我的」新增持久化开关（默认开启）、当前状态与耗电说明；关闭后进入后台立即断开全部连接。
- 后台唤醒只做受限推送：不拉增量、不建匿名账号，单次 ≤100 设备 / ≤200 读数，最小间隔 15 分钟；前台 800ms 去抖与指数退避 ≤300s 不变。

### 质量
- 新增 19 个单测（总 **207**）：配对码规范化与倒计时、404/429 映射与 `Retry-After`、token 替换与 pending 重置、导出分页 / 重复游标 / 空导出 / 文件删除、注销清理与 401/网络保留、后台限流推送与保留清理。
- 所有日期 / 数字格式化显式 `Locale(identifier: "en_US_POSIX")`，避免英文 CI 下中文别名排序随机失败。
- E2E 新增 28 项（总 **151**）：配对码生成/重新生成/旧码失效、claim 一致性/一次性、导出分页循环、无 token 401、注销后新旧 token 失效。

---

## v0.6.0（build 14）

**主题：修掉详情页请求风暴与空图降级，同时补齐告警通知、CSV 导出、设备列表可用性与深色模式**

### 修复 1：请求节流（保留真实行为）
- 读数入库触发 `notify` 时只做本地增量重绘（指标清单 / 最近读数 / 本地 UTC 网格），**不再每次 notify 都打 metrics + series + summary 三次请求**。
- 远端刷新改为合并 + 800ms 去抖动（`ReadingsRefreshPolicy`）：详情页可见时窗口内只发一次刷新，series 与 summary 共享同一次 `from/to` 计算（metrics 无区间参数）；再次触发会取消上一个待执行任务。
- 详情页不可见 / App 进入后台时不发任何远端请求；回到前台或重新可见时补刷一次。
- 远端失败进入指数退避：1s → 2s → 4s …，上限 **5 分钟**，与 notify 频率解耦；任一请求成功即复位。
- 新增 `ReadingsRefreshPolicyTests` 覆盖去抖、退避、封顶与复位；`ReadingsSeriesTests` 覆盖「不可见不发请求 / 可见只刷一次 / 回前台再刷」。

### 修复 2：本地降级补齐
- `ReadingsStore.pendingCount(deviceID:)` 判断「服务端指标为空」是否只是本地读数还没上传。
- 服务端清单为空但本地有 pending / failed 读数时：指标 Chip 用本地聚合、序列用本地 UTC 网格聚合，**图表不再空白**，数据来源显示「待同步：本地数据」。
- 新增单测 `testEmptyServerMetricsFallsBackToPendingLocalData`，断言指标、选中项、图表数据与来源文案。

### 功能 1：阈值告警本地通知
- `RuleEvaluator` 扩展 `RuleTriggerEvent`（`triggered` / `recovered` + `deviceID`），规则恢复时发「已恢复」；恢复只针对实际发出过告警的设备。
- 新增 `UserNotificationService`（`UNUserNotificationCenter`）与 `RuleAlertCoordinator`：首次真正需要通知时才请求授权；开关、节流（1 / 5 / 30 分钟，默认 5，按「规则 + 设备」）集中管理。
- 通知 `userInfo` 携带 `deviceID`；SceneDelegate 实现通知代理，前台展示横幅，点击直接进入对应设备详情。
- 「我的」新增真实开关「阈值告警通知」、节流窗口选择与通知权限状态；被拒绝时提示前往系统设置。
- 新增 `RuleAlertCoordinatorTests` 6 个用例；`RuleEvaluatorTests` 补恢复事件断言。

### 功能 2：读数 CSV 导出
- 详情页「数据」区新增「导出 CSV」行，导出当前设备 + 当前指标 + 当前区间。
- 7 天内读本地 SQLite；更长区间走服务端 cursor 分页，单次上限 **50,000 条**，超限返回「请缩短导出区间」。
- CSV：UTF-8 **BOM**、表头 `recordedAt,metric,value,unit`、ISO8601 **UTC**、含逗号 / 引号 / 换行字段按 RFC 4180 转义、行按时间升序。
- 生成文件写入临时目录（1 天后自动清理），用 `UIActivityViewController` 分享，分享结束删除文件；导出中显示真实已读取条数，失败弹窗可直接重试。
- 新增 `ReadingsCSVTests` 与 `ReadingsExportServiceTests`（本地 / 分页 / 超限 / 空数据 / 进度）。

### 功能 3：设备列表可用性
- 搜索：别名（remark）、广播名、型号、externalID 与 peripheralID，大小写不敏感。
- 排序：最近出现 / 名称 / 信号强度 / 添加时间；默认最近出现并持久化到 `SettingsStore`；信号取 `RecentDeviceStore` 的最新 RSSI，未知信号排最后。
- 分组筛选：取真实 `groupName`（含「未分组」），与搜索可叠加。
- 两种空状态：真的没有设备 vs 筛选无结果；筛选态表头显示「已保存设备（命中 / 总数）」。
- 新增 `DevicesViewModelTests` 7 个用例。

### 功能 4：深色模式
- 新增 `AppAppearance`（跟随系统 / 浅色 / 深色），持久化并在启动与切换时应用到窗口；「我的 → 外观」可切换。
- 图表折线、min–max 区间带、网格、Chip 与卡片统一使用 `AppTheme.Palette` 语义色（系统动态色），无硬编码 `.white` / `.black`；`AccentColor` 增加 dark 变体。
- 新增 `AppThemeTests`：三态枚举、偏好持久化、浅/深语义色解析差异、AccentColor dark 变体、源码扫描禁止硬编码颜色常量。

### 测试与验收
- 单测 **188 个**，0 失败；`xcodebuild build` / `test` 全绿。
- 本地 e2e 仍 **123 项全部 PASS**（本轮无 HTTP 契约变更，后端 `PJGoIoT` v0.5.1 / `STORE=fixture`）。
- `docs/acceptance.md` 新增通知权限与告警、CSV 导出、深色模式、设备搜索排序筛选、请求节流真机验收项。

---

## v0.5.0（build 13）

**主题：设备详情「数据」区升级为长周期分桶图表 + 服务端指标清单**

### 区间切换
- 「数据」区顶部新增代码生成的 `UISegmentedControl`：**1 小时 / 24 小时 / 7 天 / 30 天**，默认 24 小时；切换立即用本地数据重绘，并按新区间重新查询服务端。
- 映射：`1h→1m`、`24h→1h`、`7d→1h`、`30d→1d`；桶数分别 60 / 24 / 168 / 30，均在服务端 500 桶上限内。
- 请求 `GET .../readings/series?metric=&from=&to=&bucket=`，`from` / `to` 使用 UTC RFC3339；网络失败回退本地，30 天区间标注「离线：仅本地 7 天数据」。

### 图表必须按时间定位
- 服务端只返回有数据的桶：X 轴按桶 `start` 在区间内的**真实时间比例**定位，不按数组下标等距；30 天只有 24 桶时首尾留白如实反映缺数据天数。
- 相邻桶间隔 > 1 秒视为缺口，折线**断开且不跨缺口连线**（`min`–`max` 区间带同样断开）。原因：服务端不返回空桶，跨缺口连线会把「设备断采」画成「数值缓慢变化」，属于伪造趋势。
- 每桶用 `avg` 连线，叠加 `min`–`max` 浅色区间带；Y 轴按区间真实 min/max 自适应（全相等时留白），刻度标签带真实单位；NaN / Inf 桶丢弃。
- 几何计算独立在 `ReadingsChartGeometry`（`layout(buckets:interval:in:)`），与视图解耦，便于单测。

### 指标清单
- 改为 `GET .../readings/metrics`（`metric` / `unit` / `count` / `firstAt` / `lastAt`），按 `lastAt` 倒序；展示「指标名 · N 条」。
- 单位以响应中该指标最近一条读数为准，切换指标同步更新 Y 轴与 24h 汇总行单位。
- 服务端为空而本地有待同步读数时用本地清单兜底；完全没有指标展示「连接设备后开始采集」。

### UTC 网格
- 桶起点按绝对秒数对齐 UTC：1970-01-01T00:00:00Z 同时是 1m / 1h / 1d 的整数倍，等价于后端 2000-01-01Z 原点，不受本地时区与夏令时影响；本地兜底与云端桶边界一致。

### 测试
- 单测 **157 个**（新增 16 个：区间与 bucket 映射、UTC 对齐、序列解码与空桶过滤、本地分桶、空/单桶/等距/缺口/30 天 24 桶/异常值几何、Y 轴自适应、指标排序、服务端指标接入与离线降级）。
- 本地 e2e：`通过：123 项，跳过：0 项，失败：0 项` / `结论：PASS`（`PJGoIoT` v0.5.1，`STORE=fixture`），新增 series/metrics/空区间/非法 bucket 17 项。
- `xcodebuild build` 与 `xcodebuild test` 全绿。

### 文档
- `docs/consistency.md` 新增 3.9「长周期分桶序列与指标清单」，写明 UTC 网格与「缺口不连线」原因；头部后端版本引用修正为 **v0.5.1**（含该版本 4 处契约修正说明，对客户端逻辑无影响）。
- README 第 1 / 4.2 / 7.1 / 7.3 / 9 / 10 节同步；`releasenotes.md` 新增本版本记录。

---

## v0.4.1（build 12）

**主题：读数解析黄金用例两端对齐（实现核对，无行为变更）**

### 新增
- `codemagicTests/ReadingsGoldenTests.swift`：18 个黄金用例，覆盖心率（uint8 72 / 0 丢弃 / uint16 300 / 301 丢弃）、电池（100 % / 0 % / 101 丢弃）、温度（sint16 20.90 ℃ / −4.00 ℃ / binary16 / float32 1.5 ℃ / `FF FF` → −0.01 ℃）、NUS（`metric=value` / 纯数字 → `other` / 非数字丢弃 / 多行只丢坏行 / 空字节不崩溃）。
- 文档新增 `docs/consistency.md` 3.8「读数解析黄金用例」章节，声明两端共用同一张表，新增特征时先补表再写用例。

### 核对结论
- 现实现与黄金表口径一致：NUS `\n` 分行、单行失败只丢该行、≤256 字节 / 单行 ≤64 字符；温度先 sint16 × 0.01 再回退 binary16、4 字节 float32、最终越界或 NaN/Inf 丢弃；心率 uint16 小端、范围 1…300；电池 0 % 与 100 % 均合法。
- 唯一差异为表中 `00 4A → 20.0`：按 IEEE-754 binary16，`0x4A00` = 1.5 × 2³ = **12.0**，20.0 对应 `0x4D00`（字节 `00 4D`）。实现未做硬编码，两种位型均固化为用例；已在文档脚注标注，供 Android 侧修正期望值。

### 测试
- 单测 **141 个**（新增 18 个黄金用例 + 1 个「30 天前 pending 清理后仍在」用例），`xcodebuild build` / `xcodebuild test` 全绿。
- 本地 e2e：`通过：106 项，跳过：0 项，失败：0 项` / `结论：PASS`（`PJGoIoT` v0.4.0 `7acab36`，`STORE=fixture`）。
- CI：run [41945052635](https://github.com/platojobs/codemagic/actions/runs/41945052635)（tag 提交 `81d8578`）`build-test` 140 单测、`e2e-contract` 106 项均 PASS；后续追加 pending 保留用例提交由 CI 再验证（141 单测）。

### 复核
- 本地 7 天清理只删 `sync_state = synced` 的过期读数；离线超过 7 天（含 30 天）的 `pending` 保留至补传，已用单测固化。

---

## v0.4.0（build 11）

**主题：设备读数采集、存储、同步与展示**

### 新增
- CoreBluetooth 连接后订阅读数特征：心率 `0x2A37`、电量 `0x2A19`、温度 `0x2A6E`、Nordic UART TX `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`。
- 四个独立解析器：心率按 flags 取 uint8 / uint16；电量百分比；温度支持 0.01℃ sint16、IEEE-754 半精度与 float32；NUS 支持 `metric=value` 与纯数字文本行。解析失败静默丢弃并写本地「读数」日志，不崩溃、不写脏数据。
- SQLite 迁移 **v5** 新增 `readings` 表（`id` 主键、`device_id`、`metric`、`value`、`unit`、`recorded_at`、`sync_state`），本地保留 7 天，启动与同步成功后清理已同步过期数据。
- 读数并入 `POST /api/v1/sync/push`：每批 ≤200，按 `id` 幂等，失败重试复用同一幂等体；`readings` 为空时字段省略，兼容旧后端；响应解析 `appliedReadings` / `skippedReadings`。
- 读数查询客户端：`GET .../readings`（倒序、cursor）与 `GET .../readings/summary`（24h min/max/avg/last）。
- 设备详情新增「数据」区：指标选择（仅该设备真实已有指标）→ 最近 60 点自绘折线图（`draw(_:)` 手绘坐标轴/网格/折线/点，无第三方库）→ 24h 汇总 → 最近记录。
- 三种真实空状态：无读数「连接设备后开始采集」、蓝牙未授权指向系统设置、无数据不造假数据；云端汇总失败时展示本地数据并标注「离线：本地数据」。

### 测试
- 单测 **122 个**：解析器合法 / 非法 / 超长 / 非数字、幂等键含读数、7 天清理、v4→v5 迁移、折线图 0/1/60 点、同步批次与 skipped、详情指标切换与空状态。
- E2E **106 项**：新增第 7 节 19 项——推送读数、倒序、summary、重复 id skipped、非法 NaN 400；后端未发布 readings 时能力门控 `[SKIP]`，不伪造 PASS。
- `xcodebuild build` 与 `xcodebuild test` 全绿。

---

## v0.3.6（build 10）

**主题：接入 openapi 0.3.3 —— 别名与广播名分离 + 缺省字段三态**

### 新增
- `UserDevice.advertisedName`：服务端设备广播名，与用户别名分离。
- 本地迁移 **v4**：`saved_devices` 增加 `advertised_name TEXT`（由历史 `name` 回填）与 `alias_patch` / `advertised_name_patch` / `group_patch` 三态列。
- `Patch<String>` 三态（`absent` / `clear` / `set`）+ `PushDevice` 自定义 `encode`：未上报字段完全省略，显式清除编码 `""`。

### 变更
- 扫描只写 `advertisedName`，用户编辑只写 `alias`，互不覆盖；列表/详情展示顺序：用户别名 → 广播名 → 型号名/型号键。
- 删除分组上报 `"group": ""`；未修改分组时省略字段，不编码空串。清空后再次同步不会复活旧分组。
- 幂等键改为按上报字段的规范化 JSON 计算，absent 字段不参与哈希；同内容重试/换键均不触发 409。
- 冲突响应中缺省的可选字段按 `absent` 解析，合并时保留本地值（`RemoteDevice.alias` / `advertisedName` / `group` 改为可选）。
- `MARKETING_VERSION 0.3.6` / build 10。

### 验证
- `xcodebuild test`：**81 个用例，0 失败**（新增三态编码、别名/广播名隔离、清空分组不复活、幂等键稳定、v4 迁移与 patch 持久化）。
- `scripts/e2e-contract.sh`（后端 0.3.3，fixture）：**87 项断言全部 PASS**，新增 3.7 的 16 项（扫描只写广播名、编辑别名不覆盖、缺省 group 保留、`""` 清除、重放不 409）。

---

## v0.3.5（build 9）

**主题：CI 与 Android 对齐（e2e 入 CI + action 升级）**

### 新增
- `.github/workflows/ios.yml` 新增并行 job `e2e-contract`：checkout 本仓库 + `platojobs/PJGoIoT`（`path: PJGoIoT`）→ `actions/setup-go@v7`（`go-version-file: PJGoIoT/go.mod`）→ `PJGOIOT_DIR=${{ github.workspace }}/PJGoIoT bash scripts/e2e-contract.sh`；失败时上传 `.build/e2e/` 日志。

### 变更
- `actions/checkout@v4 → v7`、`actions/upload-artifact@v4 → v7`、`actions/setup-go@v5 → v7`，Node 20 弃用告警消除。
- `concurrency` 由按 ref 改为按 `github.sha` 分组：同一提交既推 main 又打 tag 时只跑一次，后到运行取消先到运行。
- `MARKETING_VERSION 0.3.5` / build 9。

### 验证
- CI run [41906015761](https://github.com/platojobs/codemagic/actions/runs/41906015761)：**success**
  - `build-test` 4m44s：`** BUILD SUCCEEDED **`、`Executed 74 tests, with 0 failures`、`** TEST SUCCEEDED **`，xcresult artifact 已上传；
  - `e2e-contract` 约 1m16s：`通过：71 项，失败：0 项`、`结论：PASS`。
- 本地 `PJGOIOT_DIR=... bash scripts/e2e-contract.sh`：71 项全部 PASS。

---

## v0.3.4（build 8）

**主题：GitHub Actions CI 首次真实运行**

### 新增
- `.github/workflows/ios.yml`：`runs-on: macos-15`，checkout → 选择 Xcode 16.4 并打印版本/模拟器 → `xcodebuild build`（generic iOS Simulator）→ `xcodebuild test`（动态选首个可用 iPhone 模拟器）→ 上传 `*.xcresult`。
- 触发仅 `push` 到 `main` 与 `v*` tag（另有手动 `workflow_dispatch`），PR 不跑；macOS runner 计费高于 Linux，用 `concurrency` 取消同 ref 重复运行。

### 修复
- 首次 workflow 因 `run: |` 内多行 Python 未随块缩进导致 YAML 解析失败（无任何 job，run 直接 failure）；改为单行 `simctl + grep/sed` 提取模拟器 UDID 后通过。

### 验证
- GitHub Actions run [41902292283](https://github.com/platojobs/codemagic/actions/runs/41902292283)：**success**，Xcode 16.4，`** BUILD SUCCEEDED **`、`Executed 74 tests, with 0 failures`、`** TEST SUCCEEDED **`，xcresult 已作为 artifact 上传。
- `codemagic.yaml` 保留为可选替代方案，仍未在 Codemagic 上运行。
- `MARKETING_VERSION 0.3.4` / build 8。

---

## v0.3.3（build 7）

**主题：接入 openapi 0.3.2 新字段**

### 新增
- **设备详情**：展示云端 `deviceType` / `vendor` / `firmwareVersion` / `compatibility`；`compatibility` 按「平台 / 协议 / 特性 / 最低 App / 型号」摊平，并以「；」连接。云端优先，本地缓存仅断网降级。
- **null 语义**：`deviceType` 为 `null` 显示「型号未知」，厂商 / 固件显示「—」，兼容性显示「暂无兼容性说明」；不渲染 `"null"` 或空串。未注册型号仍展示别名、分组与最近出现时间，并新增「云端记录」区展示同步信息。
- **市场筛选**：顶部「厂商：全部/xx」「兼容性：全部/xx」，取值来自服务端真实 `vendor` 与 `compatibility` 展开字段，可叠加、可清除；刷新后自动清除失效筛选；无结果显示「没有符合筛选条件的条目」。
- **catalog**：`firmwares[]` / `accessories[]` 解析 `vendor` 与 `compatibility`（配件 `deviceTypes` 映射为「型号」）；产品 / 市场详情展示真实厂商与兼容性。

### 变更
- `PushDevice` 增加可选 `deviceType`：设备详情拿到云端型号后写回本地，下次推送带上；无法推导时整体省略，不填假值。
- SQLite 迁移 **v3**：`saved_devices` 增加 `device_type TEXT`（可空），旧库升级后为 `NULL`。
- `MARKETING_VERSION 0.3.3` / build 7。

### 修复
- 固件 / 配件不再用所属型号厂商兜底，避免展示未经核实的厂商。

### 验证
- `xcodebuild build`：`** BUILD SUCCEEDED **`
- `xcodebuild test`：**74 个用例，0 失败**
- `scripts/e2e-contract.sh`（后端 0.3.2，fixture）：**71 项断言全部 PASS**，新增 catalog `vendor` / `compatibility` 与 `UserDevice` 新字段、null 降级断言

---

## v0.3.2（build 6）

**主题：文档补齐 + 登录失效交互**

### 新增
- `docs/acceptance.md`：真机验收清单，覆盖五模块逐页走查、蓝牙授权三态、真实扫描与 RSSI、连接与断开规则、12s 超时、Android 设备不可连接、断网与同步降级、`BGAppRefreshTask`、Release 域名切换；每项含步骤 / 预期 / 失败判定。
- `docs/troubleshooting.md`：Xcode 与模拟器、签名证书、Keychain 异常、BGTask 未调度、BASE_URL 与 mock 到期、Go 服务未启动、端口占用等排查路径。
- `docs/releasenotes.md`：本文件。

### 变更
- **401 交互**：「我的」页在 token 失效时明确展示「登录已失效」，并提供「重新登录」入口；点击后弹出确认框，说明「旧账号云端数据不会自动合并，本机设备会重新上传到新账号」，用户确认后才创建新匿名账号。
- 重新登录时重置同步游标（从 0 拉取），并把本机全部活动设备重新标记为待上传，避免换号后云端缺数据。
- 登录失效状态持久化（UserDefaults `sync.reloginRequired`）：后台 / 前台自动同步不会静默新建匿名账号；重登失败同样保持待重新登录。
- `AppError` 增加 `isUnauthorized`，401 在状态区显示专门的降级文案并写入同步日志。

### 修复
- 重新登录失败（断网）后不再回退到自动匿名登录，避免设备归属漂移。

### 验证
- `xcodebuild build`：`** BUILD SUCCEEDED **`
- `xcodebuild test`：**68 个用例，0 失败**
- `scripts/e2e-contract.sh`（后端 0.3.1，fixture）：55 项断言全部 PASS

---

## v0.3.1（build 5）

**主题：对齐 openapi 0.3.1**

### 变更
- 产品：`GET /api/v1/device-types`（兼容 `{items}` 与裸数组）+ 逐个 `GET /api/v1/device-types/{type}/catalog`。
- 市场：由同一批 catalog 聚合 `firmwares` + `accessories`，不再请求 `api/market`。
- iOS 设备详情：改用 `GET /api/v1/my/devices/ios/{externalId}` 复合键（大写 UUID + Bearer token），不再请求 `api/device/{peripheralUUID}`。
- 新增 `Core/Models/DeviceCatalog.swift`（`FirmwareInfo` / `AccessoryInfo` / `DeviceCatalog` / `UserDeviceInfo`），catalog 解析容忍缺失与未知字段。
- 单个 catalog 失败只降级该型号；全部失败才整页报错。
- 无 token 时设备详情返回 `SYNC-001`，不发起请求、不创建匿名账号。

### 文档
- `docs/consistency.md`：版本行改为 0.3.1；接口表补 `device-types` / `catalog` / 复合键 / 按 MAC 查询；401 语义明确「需用户重新登录，不得静默建号」；删除全部「仍为历史端点」条目，仅保留「`/api/v1/devices/{mac}` 仍可用但仅 Android 使用」。
- `KNOWN_ISSUES.md`：记录 catalog 无 compatibility、无 vendor，`UserDevice` 无 `deviceType` 等结构差异。

### 验证
- 单元测试 64 个，0 失败；E2E 扩至 55 项（含 catalog 与复合键 200/404）。

---

## v0.3.0（build 4）

**主题：版本对齐 + 端到端契约联调**

### 新增
- `scripts/e2e-contract.sh`：从 `../PJGoIoT` 以 `STORE=fixture` 构建并启动 Go 服务（8080 → 18080 回退），健康检查后运行独立 Swift runner，结束自动清理。
- `scripts/e2e-contract.swift`：真实 `URLSession` 直连本地服务的联调 runner，覆盖匿名登录、双平台推送、changes 形状、幂等重放、LWW 冲突、401/404。

### 变更
- `MARKETING_VERSION 0.3.0` / build 4；保留 `v0.2.0` tag 不重打。
- Android 设备在「设备」列表标注「来自 Android，本机不可连接」，无展开箭头、禁用点击与连接入口；详情页增加守卫。
- `docs/consistency.md` 按 `openapi.yaml` 修正错误码、`platform` / `externalId` 与同步触发说明。

### 验证
- 单元测试 63 个；E2E 43 项断言 PASS（随后 docs 修正分组计数）。

---

## v0.2.0（build 3）

**主题：同步层落地**

### 新增
- 匿名登录 `POST /api/v1/auth/anonymous`，token 存 Keychain（`KeychainTokenStore`）。
- 增量拉取 `GET /api/v1/sync/changes`（游标持久化、`hasMore` 最多 10 页）。
- 批量推送 `POST /api/v1/sync/push`（每批 ≤100、`Idempotency-Key` 由批次内容哈希派生、重试复用）。
- 冲突处理：服务端 LWW 获胜时写回云端版本并提示「另一台设备改过这条」，不静默覆盖本地修改；tombstone 上传 / 写回。
- `BGAppRefreshTask`（`com.platojobs.codemagic.sync`）与前后台触发（前台 120s 节流）。
- 「我的」同步区：上次同步时间、待上传、立即同步、匿名账号、错误码与降级说明。

### 迁移
- SQLite 迁移 v2：`saved_devices` 增加 `platform` / `external_id`，由 `peripheral_id` 大写回填，并建立 `(platform, external_id) WHERE deleted_at IS NULL` 唯一索引；旧库升级无需重装。

---

## v0.1.0（build 1）

**首个可用版本**

- 五模块：首页 / 设备 / 产品 / 市场 / 我的，纯 Swift + UIKit（无 Storyboard / XIB）。
- CoreBluetooth 真实扫描（名称 / 标识符 / RSSI）、连接（12s 超时）、断开回调。
- SQLite3 持久化：`saved_devices` / `rules` / `scan_logs` / `recent_devices` / `device_info_cache`；软删除与 `sync_state`。
- 网络层：URLSession + Codable，`BASE_URL` 由 xcconfig 注入 `Info.plist`；产品 / 市场 / 设备详情（当时为历史端点）。
- 本地规则：断开、RSSI 低于阈值；触发写扫描日志并在首页提示。
- 自绘 `RSISignalView`、代码组装 `EmptyStateView`；设备详情网络失败降级本地缓存。
- 44 个单元测试；Codemagic CI 配置（构建 + 测试 + artifact）。

---

## 发布流程（维护者）

1. 改代码与文档 → `xcodebuild build` + `xcodebuild test` 通过。
2. 跑 `./scripts/e2e-contract.sh`（后端同步到对应版本）并记录输出。
3. 更新本文件、`README.md` 第 10 节、`docs/consistency.md` 版本行。
4. 提升 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`（`codemagic.xcodeproj/project.pbxproj` 的 app Debug + Release 两处）。
5. 提交推送 `main`，创建 **annotated** tag 并推送；**不重打或强推已有 tag**。
