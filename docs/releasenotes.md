# 版本发布说明（iOS · codemagic）

按 tag 记录真实变更。版本号与 `PJGoIoT` / `PKotlinApp` 保持同一序列；同一 tag 的 iOS 构建号见下表。

| Tag | MARKETING_VERSION | Build | 日期 | 对齐后端 |
| --- | --- | --- | --- | --- |
| `v0.21.0` | 0.21.0 | 29 | 2026-11-06 | PJGoIoT v0.20.0（openapi 0.16.0；服务端场景 CRUD / 字段级 LWW / `deviceMissing` / `scene` change_log） |
| `v0.20.0` | 0.20.0 | 28 | 2026-11-06 | PJGoIoT v0.19.0（openapi 0.15.0；两步删除令牌、异步导出任务与一次性下载链接） |
| `v0.19.0` | 0.19.0 | 27 | 2026-11-06 | PJGoIoT v0.18.0（openapi 0.14.0；`GET /catalog/device-types` 成为设备类型目录唯一事实源，条件请求 / 304 / 离线缓存） |
| `v0.18.0` | 0.18.0 | 26 | 2026-11-06 | PJGoIoT v0.16.0（openapi 0.12.0；`POST /feedback` / `GET /feedback/mine` 真链路、幂等与限流） |
| `v0.17.0` | 0.17.0 | 25 | 2026-11-06 | PJGoIoT v0.15.0（openapi 0.11.0；无契约变更，市场 / 产品 / 我的为纯客户端能力） |
| `v0.16.0` | 0.16.0 | 24 | 2026-11-05 | PJGoIoT v0.15.0（openapi 0.11.0；所有权转让 / `isSelf` / `household`·`room` 结构变更进 change_log） |
| `v0.15.0` | 0.15.0 | 23 | 2026-11-05 | PJGoIoT v0.13.0（openapi 0.9.0；成员移除 / 退出 / 邀请码列表与撤销 / 房间整段排序 / 真实计数） |
| `v0.14.0` | 0.14.0 | 22 | 2026-11-05 | PJGoIoT v0.12.0（openapi 0.8.0；家庭 / 邀请码 / 房间 / 设备归属 PATCH） |
| `v0.13.0` | 0.13.0 | 21 | 2026-11-05 | PJGoIoT v0.9.0（openapi 0.7.0；无契约变更，房间仅本机） |
| `v0.12.0` | 0.12.0 | 20 | 2026-11-05 | PJGoIoT v0.9.0（openapi 0.7.0；无契约变更，推荐规则仅本机） |
| `v0.11.0` | 0.11.0 | 19 | 2026-11-05 | PJGoIoT v0.9.0（openapi 0.7.0；无契约变更，规则仅本机） |
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

## v0.21.0（build 29）

**主题：场景接入服务端 —— 自动化配置跨设备同步，同时由本地引擎真实执行**

- **契约（PJGoIoT v0.20.0 / openapi 0.16.0）**：
  - `GET /scenes` 一次返回本人全部场景（`{items}`，无分页）；`POST /scenes` 201；`GET / PUT / DELETE /scenes/{id}` 200 / 200 / 204（软删）。
  - `PUT` 为字段级 LWW：body 只包含要改的字段，每个字段 `{value, updatedAt}`；粒度是 `name` / `enabled` / `cooldownSeconds` / `trigger` / `actions` 五个字段。
  - 跨用户与已软删统一 404；创建时引用的设备必须属于本人且存在（`SCENE_DEVICE_NOT_FOUND`）；读取时实时返回 `deviceMissing`，设备删除不级联删场景。
  - `change_log` 新增 `entity=scene`：upsert 携带完整场景，delete 携带 `deletedAt`；未知 entity 仍忽略并推进游标。
- **本地存储（迁移 v14）**：`scenarios` 增加 `kind`（`manual` / `automation`）、`remote_id`（唯一索引）、`version`、`enabled`、`cooldown_seconds`、`trigger`、`sync_state`（`localOnly / pending / synced / pendingDelete`）、`deleted_at`、`device_missing`、`last_synced_at`、`last_run_at` 及 5 个字段级时间戳；`PRAGMA table_info` 判列 + 条件 ALTER，缺失表的旧库直接建完整表。v0.8.0 的手动场景保留为 `kind='manual'`、`sync_state='localOnly'`，不上传、不静默丢失。
- **首次接入与离线**：本机已有 automation 场景逐条 `POST`，成功后写回 `remoteId` 与版本；首次上传前 `GET /scenes` 做基线，重试时按内容签名唯一认领之前响应丢失的孤儿场景，避免重复创建（服务端无幂等键）。断网时新建 / 改名 / 停用 / 删除先落本地 pending，联网后串行补传；已上传场景删除为 `pendingDelete` 并 `DELETE`，`PUT` 404 视为远端已删直接收敛。
- **字段级 LWW**：本地保存时只推进被编辑字段的时间戳；拉取时若本地 pending，脏字段保留本地、非脏字段采用远端值，非脏字段时间戳回落到旧同步基线，避免服务端时钟超前造成反复推送。因此「两端改不同字段」都会保留。
- **执行引擎**：服务端场景接入现有 `RuleEngine` / `ReadingsIngestor`——`device_offline`、`rssi_below`、`metric_threshold`（含 1–30 连续条数）复用现有判定与冷却；`notify` 走本地通知、`log` 写扫描日志、`mark_device` 写标记日志。`deviceMissing` 场景执行时跳过并记一条失败日志（冷却窗口内不重复），不静默失效。
- **定时与 DST**：`SceneScheduleCalculator` 用 IANA `timezone` 与 ISO `daysOfWeek`（1=周一）计算下一次触发；春季不存在的本地时间顺延、秋季重复时间取第一次；通知按星期注册带 `timeZone` 的重复日历组件，不按 86400 秒漂移。
- **占位符**：`notify` / `log` 文本支持 `{device}` / `{metric}` / `{value}`；缺失上下文替换 `—`，未知占位符原样保留（约定见 `docs/consistency.md` 3.19）。
- **UI**：「智能 → 场景」分为「服务端场景」与「仅本机场景」；场景行显示触发条件、动作 / 设备、下次触发、待同步 / 已同步状态，设备缺失标注「设备已移除」；编辑器支持 4 类触发条件、冷却与 1–4 个不重复动作。UIKit 纯代码、iOS 15、中英双语、`UIFontMetrics`、48pt 触达、`accessibilityLabel`、仅 `DesignTokens`。
- 单测 **402 个，0 失败**（新增 38 个：首次全量上传与写回 remoteId、orphan 认领、LWW 两端不同字段都保留、离线 pending 补传、软删同步与 change_log tombstone、基线缺失、deviceMissing 跳过 + 失败日志 + 标记刷新、RSSI / 指标连续条数 / 冷却、定时下一次触发含跨 DST、占位符渲染、SQLite v14 迁移与旧数据保留）。E2E fixture **414 项全 PASS**（后端 v0.20.0 干净 worktree：场景 CRUD、字段级 LWW、跨用户 404、非法触发 / 重复动作 400、设备删除后的 `deviceMissing`、软删后 GET/PUT 404、`change_log` upsert + tombstone）。
- **CI**：tag `v0.21.0` run [42190873586](https://github.com/platojobs/codemagic/actions/runs/42190873586) success（`Build & Test` 402 单测 / `E2E contract` 414 项，后端固定 v0.20.0）；同 sha 的 `main` run [42190693581](https://github.com/platojobs/codemagic/actions/runs/42190693581) 被 tag 并发规则取消；证据回填后的 `main` run 结果待补。

---

## v0.20.0（build 28）

**主题：账号删除两步令牌 + 异步数据导出 —— 更安全的删除鉴权、可轮询的导出任务与一次性下载链接**

- **契约（PJGoIoT v0.19.0 / openapi 0.15.0）**：
  - `POST /me/deletion-request`（Bearer）→ 201 `{token, expiresAt}`；令牌 10 分钟、服务端只存哈希，再次申请作废旧令牌。
  - `DELETE /me` **只用 `X-Deletion-Token`，不用 Bearer** → 204；缺令牌 400 `DELETION_TOKEN_REQUIRED`，无效 403 `DELETION_TOKEN_INVALID`，过期 410，owner 家庭仍有成员 409 `ACCOUNT_DELETION_BLOCKED`。
  - 删除后旧 Bearer 立即 401；同一令牌重放 404；令牌被清理后降级 403。
  - `POST /me/export` → 202 异步任务；`GET /me/export/{id}` 轮询 `pending|ready|failed`；`ready` 每次签发新的一次性下载令牌（10 分钟、覆盖旧链接）。
  - `GET /me/export/{id}/download?token=…` 首次 200，重放 410 `EXPORT_DOWNLOAD_EXPIRED`，错误令牌 403 `EXPORT_DOWNLOAD_INVALID`。
- **「我的」新增「账号与数据」区域**：导出我的数据、删除账号两个入口，副标题说明后果；原账号接管码区域保留在下方，标题改为「跨设备接管」。
- **删除流程**：申请令牌 → 二次确认（明确「设备、读数、场景、家庭关系、反馈都会被删除且不可恢复」）→ 提交令牌。409 如实提示「请先转让所有权或移除成员」，提供「去家庭管理」与「重试删除」，并保留同一个未消耗令牌；403 提示「重新申请」；404 视为账号已删除，仍执行本地清空并回未登录态；网络 / 5xx 保留可重试状态，不中途踢回首页。
- **删除后本地彻底清空**：断开 BLE → 清 Keychain → 单事务清 9 张业务表（`readings` / `saved_devices` / `rules` / `scan_logs` / `recent_devices` / `device_info_cache` / `feedback_drafts` / `scenarios` / `device_catalog_cache`）→ 清同步元数据 → 清 `URLCache` → 删除导出临时文件；`.accountDeleted` 通知重建五个 Tab，停在「我的」未登录态；重启后业务表仍为空，不复活设备与读数。
- **导出流程**：创建后展示「处理中」，轮询 2.5s 起、×1.4、封顶 5s；ready 后下载到临时目录并调 `UIActivityViewController`，分享关闭即删；下载 410 自动重新查询任务换新链接并提示「下载链接已刷新」，只自动重试一次；取消 / 失败保留可重试状态。
- **UI 约束**：UIKit 纯代码、iOS 15；中英双语；`UIFontMetrics` 动态字号；操作行 48pt 触达；`accessibilityLabel`；颜色 / 间距 / 字号全部来自 `DesignTokens`。
- 单测 **364 个，0 失败**（新增 8 个：删除令牌申请与 `DELETE /me` 只带 `X-Deletion-Token`、409/403/404/410 分流、异步导出 DTO / 相对 URL 解析 / 下载 410·403、轮询退避 `[2.5, 3.5, 4.9]`、410 自动刷新一次、409 → 转让后同一令牌成功、删除后业务表计数归零 + 目录缓存清空 + 重启不复活的存库验证）。E2E fixture **367 项全 PASS**（后端 v0.19.0 干净 worktree：令牌申请 / 401 / 旧令牌作废 / 400 / 403、删除 204 / 旧 Bearer 401 / 重放 404、导出 202 → pending/ready → 下载 200 → 重放 410 → 错令牌 403 → 换新链接再下载、409 → 转让后同一令牌 204）。
- **CI**：tag `v0.20.0` run [42179059627](https://github.com/platojobs/codemagic/actions/runs/42179059627) success（`Build & Test` 364 单测 / `E2E contract` 367 项）；同 sha 的 main run 被 tag 并发规则取消；证据回填后的 `main` run [42179940342](https://github.com/platojobs/codemagic/actions/runs/42179940342) success。

---

## v0.19.0（build 27）

**主题：设备类型目录改由服务端提供 —— 单一行事实源、条件请求与离线兜底**

- **契约（PJGoIoT v0.18.0 / openapi 0.14.0）**：`GET /catalog/device-types` 公开只读、匿名可读，返回 `{version, generatedAt, items[]}`；每项含 `type` / `displayName` / `description` / `gattServices` / `metrics`（`key` / `unit` / `characteristicUuid`）/ `limitations` / `compatibility` / `updatedAt`。支持 `If-None-Match` 与 `If-Modified-Since`，命中返回 `304`，并带 `ETag`（由目录版本派生）、`Last-Modified`、`Cache-Control`。
- **替换本地目录**：产品与市场的类型清单、展示名、GATT 服务、指标、限制、兼容性全部来自该接口；删除本地逐型号的 `GET /device-types` 清单调用，不再保留第二份常量表。逐型号 `GET /device-types/{type}/catalog` 仅补充固件与配件，不参与目录字段判定；厂商字段目录未提供时保持未知，不编造。
- **缓存策略（SQLite 单行）**：迁移 **v13** 新建 `device_catalog_cache`（`id` 固定 `device_types`，存原始响应 `payload`、`version` / `generated_at`、`etag` / `last_modified`、`fetched_at` / `last_used_at`），`PRAGMA table_info` 判列、可重复执行。选 SQLite 是因为已有迁移链路、注销时与业务数据一起清空、条件头与使用时间可原子更新，无需额外缓存文件格式。缓存存原始 JSON，加载时再解码，避免缓存层重新序列化造成失真。
- **条件请求**：优先 `If-None-Match`，无 `ETag` 时退化为 `If-Modified-Since`；`304` 直接复用本地缓存并刷新 `last_used_at`，`fetched_at` 保持不变；`ETag` 变化返回 `200` 时覆盖缓存。
- **离线与失败回退**：有缓存时断网仍展示缓存内容，并在列表尾部标注「目录更新时间」与「离线缓存」；无缓存且请求失败时展示可读错误与重试入口，绝不把写死的旧清单冒充服务端数据。异常 `304`（本地无缓存）给出独立错误 `CATALOG_CACHE_MISSING`。
- **首屏关系**：目录请求不在 App 启动路径上，也不阻塞首页；产品 / 市场打开时先同步读 SQLite 缓存渲染已有内容，再异步刷新，刷新完成后就地替换，不切空白页。首次安装无缓存时才显示页内加载态。
- **能力对齐**：本地解析器按目录的 `characteristicUuid` 判断能否解析（16 位与 128 位 UUID 都归一化比较），不再用 key 名称猜测。能解析的展示「指标 · 单位」；解析不了的如实标注「当前版本不支持」；目录对 NUS 声明空 `metrics` 时按透传设备处理，保留客户端逐行解析能力。限制文案优先使用目录 `limitations`。
- 单测 **356 个，0 失败**（新增 12 个：`200` 首次落库、`304` 命中缓存并刷新使用时间、`ETag` 变化触发更新、断网有缓存回退、断网无缓存错误、`304` 无缓存异常、SQLite 缓存往返、`v12→v13` 迁移（`PRAGMA table_info` 判列）、目录新增类型界面表现、指标与解析能力不一致标注、NUS 透传）。E2E fixture **337 项全 PASS**（新增目录匿名 200、字段完整性、UUID 归一化、NUS 空指标、`ETag` / `Last-Modified` / `Cache-Control` 与两种条件请求 `304`；条件请求绕过 `URLCache` 以免掩盖服务端行为）。
- **CI**：tag `v0.19.0` run [42172416077](https://github.com/platojobs/codemagic/actions/runs/42172416077) success（`Build & Test` 356 单测 + `E2E contract` 337 项，PJGoIoT 固定 v0.18.0）；同 sha 的 `main` run 被 tag 并发组取消，回填提交重新触发 `main`。

---

## v0.18.0（build 26）

**主题：意见反馈接真实后端 —— 本地队列有状态、幂等重放、限流与退避**

- **契约（PJGoIoT v0.16.0 / openapi 0.12.0）**：
  - `POST /feedback`：`kind`（`bug` / `feature` / `experience` / `other`）、`body`（去空白非空、≤4000）、可选 `contact`（≤200）、可选 `diagnostics`（≤8000）、必填 `context`（`platform=ios` / `appVersion` / `buildType` / `osVersion` / `deviceModel`）；成功 `201 {feedbackId, createdAt}`。
  - `GET /feedback/mine?cursor=&limit=`：只返回本人，倒序游标分页，`{items, nextCursor, hasMore}`，状态 `submitted` / `received` / `closed`；DTO 不含 `contact` 与 `diagnostics`。
  - 幂等：`Idempotency-Key` 固定为草稿本地 ID；同内容重放返回同一 ID 且带 `Idempotent-Replayed: true`；同 key 不同内容 `409 IDEMPOTENCY_CONFLICT`；限流 `429 FEEDBACK_RATE_LIMITED` + `Retry-After`（账号 10/min、IP 30/min）。
- **SQLite 迁移 v12**：`feedback_drafts` 条件补 `status` / `last_error` / `remote_id` / `next_retry_at`，用 `PRAGMA table_info` 判列、可重复执行；旧行默认 `pending`，不删任何草稿。
- **状态机**：`pending → sending → sent / failed`。`markSending` 记一次尝试；只有 `2xx` 且解出非空 `feedbackId` 才落到 `sent`，缺 ID 与解码失败都按失败处理，绝不伪装成功。应用被杀导致的悬挂 `sending` 在下次启动回收到 `pending`，幂等键保证重放不重复。
- **如实展示**：待发送显示「待发送（第 N 次重试）」，失败显示服务端可读原因，达到自动上限后仍保留草稿并保留手动重试入口，不静默删除。
- **自动重试**：前台回到 App 与打开反馈页时触发，30 秒起有界指数退避、封顶 1 小时，自动上限 5 次；429 按 `Retry-After` 推迟且本轮停止批量重试，409 / 401 等终态失败不再自动重试。
- **上下文自动填充**：`appVersion` 取 `CFBundleShortVersionString`，`buildType` 由 `#if DEBUG` 判定，`osVersion` 取 `UIDevice.current.systemVersion`，`deviceModel` 取 `uname` 机型标识，全部不硬编码。
- **我的反馈**：新增「我的 → 我的反馈」，调用 `GET /feedback/mine`，展示状态与时间，下拉刷新、游标加载更多，空 / 错态复用现有 `EmptyStateView` / `ErrorStateView`。
- 单测 **344 个，0 失败**（新增 16 个：状态机成功 / 失败分支、仅 2xx + ID 判成功、幂等键复用、429 `Retry-After`、终态冲突不自动重试、自动上限后草稿保留、退避策略、`POST /feedback` DTO 字段与可选字段省略、列表 DTO 不含 contact / diagnostics、`limit` clamp、游标透传、`feedback_drafts` v11→v12 迁移旧数据保留）。E2E fixture **314 项全 PASS**（新增反馈提交、同 key 同内容重放、同 key 不同内容 409、我的列表字段与跨账号隔离）。

---

## v0.17.0（build 25）

**主题：设备与服务市场不造假 + 「我的」帮助 / 反馈 / 关于补齐**

- **市场 Tab 改造为「设备与服务市场」**，不再展示虚构商品：
  - 兼容性查询：选设备类型后展示可解析指标、所需 GATT 服务、固件与已知限制。指标由 `ReadingCharacteristic` UUID 真值表匹配型号 `gattServices` 推导，不新增平行能力表；支持 16 位短 UUID 与 128 位完整 UUID。
  - 选购指南：按健康监测 / 环境采集 / 多设备组网三个场景，只推荐具备对应指标的型号，并给出 UUID 证据。
  - 服务入口：配对向导直达首页扫描，连接排障直达帮助中心连接专题，省电建议直达「我的 → 后台采集」设置，无死链。
  - 示例条目默认隐藏；开启后显式标注「示例数据，不代表真实在售」，只使用服务端返回的条目，不展示价格 / 库存 / 销量。示例接口失败只降级该区块，不拖垮兼容性查询。
- **我的 → 帮助中心**：5 条可展开 FAQ（配对失败、连不上、读数不刷新、同步冲突、退出家庭 / 转让所有权），文案对齐真实行为：owner 还有成员时退出返回 409、已同步读数保留 7 天、冲突以服务端为准。
- **我的 → 意见反馈**：类型 + 描述 + 可选联系方式，无后端时落本地 `feedback_drafts` 待发队列（SQLite 迁移 v11，`PRAGMA table_info` 判列可重复执行），界面如实标注「未发送」，支持重试与删除，绝不伪装发送成功。
- **关于**：版本号读取 `CFBundleShortVersionString` / `CFBundleVersion`，不硬编码；许可、隐私政策、数据安全、一致性文档从仓库文档打包进 bundle 并可打开；缺文档时显示空态而不是白屏。
- **产品 Tab**：按能力类型筛选浏览（健康 / 环境 / 组网 / 其他），详情补类型说明、可解析指标、GATT 服务、兼容性 / 固件与本机同类型设备。
- 单测 **328 个，0 失败**（新增 13 个：UUID 长短格式归一、指标推导、能力分类优先级、限制项、场景推荐、型号排序、产品类型筛选、帮助目录与文案、反馈队列往返 / 重试 / 删除、v11 迁移可重复）。E2E fixture **299 项全 PASS**（无后端契约变更）。

---

## v0.16.0（build 24）

**主题：所有权转让 + 家庭结构变更进增量同步**

- **契约（PJGoIoT v0.15.0 / openapi 0.11.0）**：
  - 成员 DTO 增加 `isSelf`；`isSelf` 为 true 的行不出现「转让所有权 / 移除成员」。老后端不返回该字段时解码为 `nil`，入口整体隐藏。
  - `POST /households/{id}/transfer-ownership`（body `{userId}`，200 返回调用者视角的家庭）：owner 可转让给普通成员；403 / 404 / 409 转可读文案并刷新成员与家庭详情；405 / 裸 404 视为服务端不支持，隐藏入口且不弹错误。
  - `change_log` 新增 `household` / `room` 两个 entity。未知 entity 一律跳过但**游标照常推进**（固定 JSON 用例覆盖）。
- **能力矩阵集中判定**：`HouseholdCapabilities` 是 owner / member 权限的唯一来源（改名、邀请码、移除成员、转让、退出拦截），界面与服务层只消费结果。
- **增量同步语义**：
  - `household upsert`：更新家庭名、接收者角色、`memberCount`；本地没有该家庭（如刚被邀请加入）时，本轮拉取结束补一次 `GET /households` 全量基线。
  - `household delete`：整段移除该家庭的房间、待上报归属与本地归属，设备回落个人家庭（不静默删设备），当前家庭切回个人家庭。
  - `room upsert`：按 `sortOrder` 落序、新增或改名；本机未上报的改名不丢，只应用服务端顺序。同名未上报房间认领而不是重复创建。
  - `room delete`：删本地房间并清空房内设备归属与待上报项，设备本身保留。
  - 410 `RESYNC_REQUIRED` 沿用原逻辑：清游标 → `cursor=0` 全量重拉，pending 编辑不丢。
- **房间整段重排补强**：先本地落序（离线也保留），提交前补传未同步房间，收到 409 由界面重拉并提示已刷新，不盲目重试。
- 单测 **315 个，0 失败**（新增 12 个：`isSelf` 本人行无操作、转让成功降级并隐藏入口、405 静默隐藏、403 可读提示并刷新、household upsert 更新 / 未知家庭基线、household delete 整段清理并回落个人家庭、room upsert 落序 / 新建、pending 改名保留、room delete 清归属不删设备、未知 entity 跳过且游标前进、未知 household 触发全量基线）。E2E fixture **299 项全 PASS**；真 Postgres 同套契约 + 直接查库确认转让后 `owner_user_id`、移除后成员行、删房后 `household_rooms`、`change_log` 结构实体与 `deleted`。

---

## v0.15.0（build 23）

**主题：家庭管理补齐 —— 成员移除 / 退出 / 邀请码管理 / 房间整段排序与真实计数**

- **SQLite 迁移 v10**：为 `households` 条件补 `room_count`；`memberCount` / `deviceCount` / `roomCount` 全部来自 `GET /households`，本地不再自行计数。
- **新增契约（PJGoIoT v0.13.0 / openapi 0.9.0）**：
  - `DELETE /households/{id}/members/{userId}`：owner 移除成员（204）；被移除成员访问家庭 404，其设备回个人家庭、房间清空。
  - `POST /households/{id}/leave`：成员退出（204）；owner 还有其他成员时 409 `CONFLICT`，界面与错误映射统一为「请先转让所有权或移除其他成员」，**不解析 message 文本**。
  - `GET /households/{id}/invitations`：只返回 `codeHashPrefix` / `status` / `attempts` / `expiresAt`，模型与界面均无明文字段；`DELETE .../invitations/{invitationId}` 撤销（204），撤销后 claim 404。
  - `PUT /households/{id}/rooms/order`：整段顺序提交（200 返回重排后的房间）；缺项 / 多项 / 重复返回 409，客户端按端点上下文 + HTTP 状态机读判定（后端 v0.13.0 返回 `CONFLICT`，新版本返回 `ROOM_SET_MISMATCH`，两者都识别），自动重新 GET 后提示「房间列表已变化，已刷新」。
- **家庭管理 UI**：成员左滑 / 点击移除（二次确认并说明对方设备回落）；「退出家庭」按角色可见，owner 有其他成员时前置提示；邀请码管理分区（哈希前缀 / 状态 / 过期时间 + 撤销）；owner 可改家庭名，member 看不到签发 / 撤销邀请码、移除成员、改家庭名。
- **本地回落**：退出或被移除时，当前账号的设备改挂个人家庭、清空房间与远端归属、清掉待上报归属，房间脱钩保留并标「未同步」，当前家庭切回个人家庭。
- **房间排序 UI**：owner 可进入「排序」拖拽模式或左滑上移 / 下移；本地未同步房间不参与整段提交；网络失败不落本地顺序，避免与服务端分叉。
- 单测 **303 个，0 失败**（新增 10 个：移除当前用户的本地清理、退出设备回落、owner 带成员退出可读 409、邀请码列表 / 撤销且无明文、member 禁止邀请码、重排缺项本地 409、409 刷新提示、整段重排成功、member 禁止重排、owner / member 可见性）。E2E **260 项全 PASS**（fixture，后端 v0.13.0）；**真 Postgres** 同一套契约外，直接查库确认邀请码只存 64 位哈希、移除成员后成员行删除、owner 退出 409→移除后可退出 204。

---

## v0.14.0（build 22）

**主题：家庭接入后端 —— 家庭归属、成员共享与房间以服务端为准**

- **SQLite 迁移 v9**：新增 `households`（`id` 复用远端 UUID / `remote_id` / `name` / `is_personal` / `role`）与 `device_assignment_pending`（归属上报队列）；`rooms.remote_id` 真正启用并增加 `household_id` / `sync_state`（`local` / `pending` / `synced`）/ `deleted`；`saved_devices` 增加 `household_id` / `remote_room_id` / `remote_household_id`。条件 ALTER（`PRAGMA table_info` 查缺列），旧库升级**不丢任何房间与归属**。
- **登录后家庭落库**：`GET /households` 合并到本地并持久化当前家庭；切换家庭后按该家庭拉设备与房间；服务端已不存在的家庭从本地移除，但其房间**脱钩保留**（不静默删除），本轮不被重新认领。
- **首次接入房间合并（明确策略）**：本机未归属房间认领到当前家庭 → 按 `sort_order` 顺序 `POST /households/{id}/rooms` → 服务端已有**同名**房间时认领本地房间（保留本地 `id` 与设备归属、不重复创建）→ 失败保持 `local / pending` 下次同步重试；完成后写 `seededHouseholdRemoteID`，不再重复搬迁。
- **设备归属独立上报**：`PATCH /my/devices/{platform}/{externalId}`，字段 `alias` / `roomId` / `householdId` 三态（缺失 = 不变、空串 = 清除、非空 = 覆盖）；**不塞进 `sync/push`**，避免 LWW 覆盖；失败进 `device_assignment_pending`，下次同步重试；403 / 404 为终态（移出队列并记录可读文案），未分配显式发送空串。
- **家庭管理 UI**：「我的 → 家庭管理」展示当前家庭与角色（owner / member）、成员列表、房间数量；创建家庭、生成 8 位邀请码（服务端 `expiresAt` 倒计时 + 复制 + 过期重生成）、输入邀请码加入（大写规范化、404 / 429 文案复用接管码口径）；首页多于一个家庭时显示切换入口，单家庭不显示。
- **房间以服务端为准**：本机新建 / 改名 / 删除先落 `pending` 或墓碑，联网补报并在界面标注「未同步」；member 禁用写入口并提示「你没有修改该家庭 / 房间的权限」，403 不弹错误码、不整页报错；离线保留本机房间与设备。
- 单测 **293 个，0 失败**（新增 9 个家庭用例：首次种子按序推房间并补报设备、同名认领不重复、已删家庭房间脱钩、403 终态可读、网络失败 pending 重试、未分配空串清除、切换家庭可见房间、离线建房、`RemoteDevice` 编解码）。E2E **224 项全 PASS**（新增家庭链路第 9 节：创建家庭 → 邀请码 → 第二账号领取 → 成员可见设备 → member 改房间 403 → 跨家庭 404 → 归属三态 → 删除家庭级联）。

---

## v0.13.0（build 21）

**主题：房间归属与首页按房间分区（对齐米家「家庭 / 房间」）**

- **SQLite 迁移 v8（仅本机）**：新增 `rooms` 表（`id` / `name` / `sort_order` / `remote_id`（预留远端映射）/ `created_at` / `updated_at`）与 `saved_devices.room_id`（可空，`NULL` = 未分配）；旧数据、原 `group_name` 原样保留，`group_name` 降为兼容字段；`rooms` 与 `room_id` 不参与 push / changes。
- **首页分区**：设备卡片从扁平分组改为按房间分段，房间标题 + 设备数，点击标题展开 / 收起；「未分配」固定最后。无房间显示「还没有房间」+「新建房间」；有房间但房间内无设备时，房间内给出扫描引导。
- **房间管理**：右上角入口，支持新建 / 重命名 / 删除；删除前二次确认，房间内设备逐台回到未分配（先 `UPDATE room_id = NULL` 再删房间，设备不丢）；展示每个房间的设备数，页脚标注「仅本机」。
- **移入 / 移出**：设备详情新增「房间」行（选择房间或「未分配」）；首页卡片长按菜单含「移入房间」。两处只更新 `room_id`，不触碰同步状态与 `updated_at`。
- **交互取舍**：搜索只匹配设备字段，有关键字时隐藏没有命中的房间；排序只在房间内生效，房间分区顺序固定按 `sort_order`；首页移除原「分组筛选」，`group_name` 仅保留在编辑 / 详情。
- 单测 **284 个，0 失败**（新增 7 个：v7→v8 迁移保留旧设备与新增列、创建 / 重命名 / 排序、删除房间设备落点、归属在 upsert 后仍保留、未分配固定最后与房间内排序、搜索隐藏空房间、无房间设备进入未分配）。E2E 151 项无契约变更。

---

## v0.12.0（build 20）

**主题：推荐规则、中英双语与动态字体**

- **推荐规则**：「智能 → 自动化」首段新增「推荐规则」入口，只根据该设备**真实出现过的指标**生成模板（温度 > 30℃、湿度 > 70%、电量 < 20%、心率 > 120、CO₂ > 1000ppm），不列出设备没有的指标；一键添加立即写入本地并出现在规则列表，复用 `readingThreshold` 规则结构，不新建模型、不改数据库。无设备显示「还没有设备」，有设备无读数显示「连接到设备并采集到读数后可创建推荐规则」。
- **中英双语**：全部界面文案抽到 `Resources/zh-Hans.lproj/Localizable.strings` 与 `en.lproj/Localizable.strings`（key 集合一致、`%@` 数量一致由单测强制）；`InfoPlist.strings` 双语权限文案；工程 `knownRegions` 含 `zh-Hans`，`CFBundleLocalizations = [en, zh-Hans]`，设置跟随系统语言。术语：Device / Reading / Sync / Scan / Group / Alert / Transfer Code（不使用 `pairing code`）。数字与日期显式 `Locale.current`，CSV 与文件名仍 `en_US_POSIX` + UTC。
- **动态字体**：字号统一 `AppText`（`UIFontMetrics` 缩放），`adjustsFontForContentSizeCategory = true`；表格行高自适应；图表 Y 轴左侧留白按实际标签宽度计算，超大字号下缩为 3 个刻度且标签不压绘图区。
- 单测 **277 个，0 失败**（新增 17 个：模板只按真实指标生成 / 空态 / 阈值预设 / 一键写入与设备切换、本地化 key 与占位符一致性 / 硬编码中文审计 / 声明语言、`AppText` 默认与 AX5 字号差 / 布局固有高度）。E2E 151 项无契约变更。
- 无 SQLite 迁移（v0.11.0 的 v7 结构沿用）。

---

## v0.11.0（build 19）

**主题：指标阈值规则、图表点选与 CSV 区间文件名**

- **指标阈值规则**：规则条件从「只看信号」扩到「看读数」——指标（temperature / humidity / battery / heart_rate / co2）+ 比较符（`>` / `<` / `>=` / `<=`）+ 阈值 + 连续 N 条（1–5，默认 1）。判定接在 `ReadingsIngestor` 落库之后，复用同一 `RuleEvaluator` 与 `RuleAlertCoordinator`；命中日志包含触发值、阈值、时间与设备并进入「智能 → 最近触发」；恢复只在确实发过触发通知后补一条。阈值展示一律带单位（`℃` / `%` / `bpm` / `ppm`）。
- **SQLite 迁移 v7**：`rules` 表新增 `metric` / `comparison` / `reading_threshold` / `consecutive`，旧规则保持 `metric = NULL`、`comparison = lte`、`consecutive = 1`，升级后仍按原 RSSI / 断开条件生效，一条不丢。
- **图表点选**：轻点 / 长按折线桶显示 `start–end`、最小 / 最大 / 平均 / 最新与条数（本地时区）；点空白处取消；选中态不改变 Y 轴并给出竖向参考线与放大数据点；图表无障碍标签在未选中时给出「指标，最近区间，最低 / 最高，共 N 个数据点」，选中后替换为当前桶摘要。命中判定抽成纯函数（最近桶 + 24pt 近邻阈值 + 空白不命中）。
- **CSV 导出**：文件名含设备名、设备标识末 8 位、指标、区间起止与 UTC 时间；仍为 UTF-8 BOM + 表头 `recordedAt,metric,value,unit`、RFC 4180 转义、ISO8601 UTC、上限 5 万条、系统分享后删除临时文件。
- 单测 **260 个，0 失败**（新增 24 个：指标规则比较符 / 防抖 / 恢复 / 单位 / 旧规则升级仍生效、图表点选几何与摘要、CSV 文件名与 BOM）。E2E 151 项无契约变更。
- `docs/consistency.md` 补充「规则仅本机」说明。

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
