# BLE 设备数据面板（codemagic · iOS）

纯 **Swift + UIKit（纯代码，无 Storyboard/XIB）** 实现的蓝牙设备数据面板，与 Android 端 [`PKotlinApp`](https://github.com/platojobs/PKotlinApp) 保持五模块命名、数据结构与行为口径一致。

**不包含** SwiftUI 主界面、第三方 UI 库、假数据、假购物车 / 订单 / 支付。

> 行为口径（模块顺序、字段、错误码、空状态、权限）见 **[docs/consistency.md](docs/consistency.md)**。结构与分层见 **[docs/architecture.md](docs/architecture.md)**；真机验收见 **[docs/acceptance.md](docs/acceptance.md)**，故障排查见 **[docs/troubleshooting.md](docs/troubleshooting.md)**，版本变更见 **[docs/releasenotes.md](docs/releasenotes.md)**。

---

## 1. 当前状态

| 项 | 结果 |
| --- | --- |
| 版本 | **v0.31.6**（`MARKETING_VERSION 0.31.6`，`CURRENT_PROJECT_VERSION 46`，tag `v0.31.6`：按三端 presence 对账报告收敛 iOS 四处偏差。① 在线判定统一为 `DeviceLinkStatus` 四档（本机 BLE 已连接 / 云端最近上报 / 云端上报已超时 / 云端从未收到上报），首页、房间详情、设备列表与设备详情共用同一份实现，房间详情不再把「15 分钟内本机扫描到」额外算作在线；② 整组文案去除上帝视角：本机写「本机已连接」，云端 `online` 写「云端 15 分钟内有上报」，`offline` 写「云端上报已超时 · 云端最近上报 X 前」，`unknown` 写「云端从未收到上报」，房间汇总四行同步更新；③ 跨平台设备的「本机不可连接」只作附加说明，与云端状态 / 最近上报时间同时呈现，AX 档也不再丢失「已标记」；④ `presence=unknown` 或本机已有读数时跳过云端读数请求，避免 `metrics + limit=1` 白跑两次往返。新增/更新 15 个单测合计 **495**，e2e 仍 **460** 项全绿；本地 `e2e-contract` 对 v0.26.0 的 presence 断言做过反向验证（临时断言错误值 → 459 通过 / 1 失败 / 退出码 1），`e2e-postgres` 在真 Postgres 上验证 online 与回拨 `last_seen_at` 后的 offline。**CI 仍 pin 后端 v0.25.0，新字段不在 CI 断言范围内**，见第 1 节 CI 覆盖边界）。上一版 **v0.31.5**（`MARKETING_VERSION 0.31.5`，`CURRENT_PROJECT_VERSION 45`，tag `v0.31.5`：接入后端 **presence**（后端 `PJGoIoT` v0.26.0 / 契约 0.21.0）。`UserDevice` 新增 `lastSeenAt`（`date-time | null`，UTC 微秒截断）与 `presence`（`unknown / online / offline`，由服务端按 `/sync/push` 被接受读数的**接收时间** 900 秒窗口实时推导、不落库、只读且不参与 LWW），`/my/devices`、单设备读与 `/sync/changes` 均返回。客户端新增 `DevicePresence` 与 `serverLastSeenAt`，原 `lastSeenAt` 继续只作本机 BLE 扫描时间，两者不混用；迁移 **v18** 增加 `saved_devices.server_last_seen_at`，增量与本地 pending 设备都只更新该列，**不置 pending、不推进 `updatedAt`**。在线判定改为 本机 BLE 连接 > `presence`，`unknown` 单独一档不并进离线；文案一律「最近上报 X 前 / 已离线 · 最近上报 X 前 / 从未上报读数」，房间汇总四行（共 N 台 / 本机在线 N · 最近上报 N / 已离线 N · 从未上报 N / 本机不可连接 N · 已标记 N），首页状态「本机在线」「本机不可连接」；卡片时间行与「已标记 / 待同步」第二段固定换行，默认字号下不再把「已标记」拆成「已 / 标记」。`lastSeenAt` 归「使用数据 → 其他使用数据」，隐私清单仍 8 类，`store-listing.md` / `privacy-policy.md` / `app-privacy.md` 已同步。单测 **487**（0 失败），e2e 仍 **460**；首页 6 张、房间详情 24 张与 iPad 首页 / 房间详情用真实后端 + seed 重拍，presence 与库内 `last_seen_at` 对得上）。上一版 **v0.31.4**（`MARKETING_VERSION 0.31.4`，`CURRENT_PROJECT_VERSION 44`，tag `v0.31.4`：修掉首页无障碍大字号下的**设备卡裁切**。iPhone 紧凑横向 + AX 字号时设备卡由两列改**单列全宽**，卡片高度按本段设备（名称 / 状态 / 读数 / 时间）实测取最大值，常规字号仍为两列且最小 164pt；名称、状态、读数、时间均多行自适应，数值与单位用不换行空格绑定（`72 bpm` 不再拆成两行），时间行在 AX 档按语义换行；顶部告警摘要卡与快捷场景卡（含空态）在 AX 档改为按内容自适配高。列表行高随卡片变化，AX5 滚到底最后一张卡完整位于悬浮 Tab 条带之上。重拍首页 AX5 与 200%（1320×2868）及 iPad AX 截图，卡片内容与 seed 一致（客厅 3 台：心率 72 bpm / 湿度 52 % / 踏频 78 rpm，骑行台已标记）；单测仍 **480**（0 失败），e2e 仍 **460**；未提前推演服务端在线状态，本机在线 / 本机离线 / 本机不可连接口径不变）。上一版 **v0.31.3**（`MARKETING_VERSION 0.31.3`，`CURRENT_PROJECT_VERSION 43`，tag `v0.31.3`：接入**服务端最近读数**（后端 v0.25.1 / 契约 0.20.0，无契约变更）。新增 `CloudLatestReadingsService`：`GET /readings/metrics` 找 `lastAt` 最新的指标，再按**服务端原始指标名** `GET /readings?limit=1` 取最近一条；成功缓存 60s、失败 20s、同设备请求合并、最多 3 台并发。房间详情与首页卡片**本机读数优先**，本机没有时显示云端读数并标注「云端 X 前上报」；查询失败（无网 / 401 / 5xx）显示「云端读数暂不可用」，**不判定设备离线、也不显示「暂无读数」**；本机与云端都确认无数据才显示「暂无读数」。在线判定仍只用本机依据（BLE 已连接，或 15 分钟内 `lastSeenAt`），跨平台设备改标「来自 Android，本机不可连接」并从「离线」计数拆出，汇总为「共 N 台 · 本机在线 N · 本机离线 N · 本机不可连接 N · 已标记 N」。顺带修复 `appendingPathComponent` 对 MAC 二次编码（`:` → `%3A`，服务端判 `INVALID_MAC`）的根因，该问题同时影响既有读数页。新增 12 个单测合计 **480**，e2e 仍 **460**；房间详情 24 张与首页 6 张用 seed 数据重拍。**契约没有服务端 `lastSeen` / `online` 字段**，需要后端补（见 [docs/consistency.md](docs/consistency.md) 3.26），本轮不伪造、不用夹具充数）。上一版 **v0.31.2**（`MARKETING_VERSION 0.31.2`，`CURRENT_PROJECT_VERSION 42`，tag `v0.31.2`：补齐截图可复现性。新增 `scripts/seed-demo-data.sh`，一键重建与商城截图同源的演示数据（3 个演示家庭 / 6 个房间 / 12 台在用设备 + 1 台已移除 / 7 天读数 / 4 个场景 / 3 条反馈，另建 1 个只读成员账号），重复执行形状不变；补全前置条件（后端 v0.25.x、迁移 19、`STORE=postgres`、配对码接管账号）。用 seed 重拍房间详情 24 张（默认 / AX5 / 200% / iPad 各含首页、底部、待同步、待同步底部、空态、成员只读），画面与脚本数据一致：共 3 台 · 在线 0 · 离线 3 · 已标记 1，行内「离线 · 来自 Android，本机不可连接 · 暂无读数」。排查确认 `household_rooms = 0` 非 e2e 清库（fixture e2e 走内存、pg e2e 固定独立库 `pjgoiot_e2e`），e2e 脚本新增库名断言。单测 468、e2e 460，无后端契约变更）。上一版 **v0.31.1**（`MARKETING_VERSION 0.31.1`，`CURRENT_PROJECT_VERSION 41`，tag `v0.31.1`：房间详情无障碍大字号与 iPad 宽度走查修复。AX5 / AX2（≈200%）下汇总逐项成行、设备行多行自适应、批量按钮全宽竖排且高度随字号增长、空态与成员只读改用带显式换行的 AX 本地化文案、读数数值与单位不换行、列表锚定安全区底部不被 Tab 条带遮挡；iPad 13 英寸下内容居中限宽 760pt，按钮横排不溢出。新增 2 个布局单测，合计 **468**；e2e 仍 460。补 18 张 AX5 / 200% / iPad 截图，仍使用本机 SQLite 夹具）。上一版 **v0.31.0**（`MARKETING_VERSION 0.31.0`，`CURRENT_PROJECT_VERSION 40`，tag `v0.31.0`：补齐 Android v0.32.4 已有的**房间详情**。点首页房间分区标题进入详情（右侧箭头仍展开 / 收起）；聚合本机 SQLite 与服务端同步落地的同一份设备数据，展示**总数 / 在线 / 离线 / 已标记**，在线沿用现有判定（本机可连接且 CoreBluetooth 已连接，或最近 15 分钟内出现，与 Android 首页同口径），跨平台设备行内标注「本机不可连接」；每台设备显示名称、在线状态与**最新一条真实读数**，没有读数显示「暂无读数」而不补造；批量「标记」/「取消标记」一次更新整批 `saved_devices`，走既有 `markedAt` 三态与 push，未同步时显示「待同步」并禁用无目标的按钮，本地写入失败不静默；成员家庭进页即说明「房间管理仅 owner」，空房间显示真实空态与扫描入口。新增 9 个单测覆盖聚合 / 在线 / 批量标记与取消 / 待同步 / 成员只读 / 空态 / 跨家庭隔离，合计 **466**）。上一版 **v0.30.0**（`MARKETING_VERSION 0.30.0`，`CURRENT_PROJECT_VERSION 39`，tag `v0.30.0`：① RFC3339 编解码改为**保留微秒**（手动拆分小数，服务端返回的 `...123456Z` 可完整往返，不再被截成毫秒，避免 Android 微秒写入时 iOS 回传被字段级 LWW 判为不同值而多写 `change_log`），新增 1 个往返精度单测；② `markedAt` 纳入既有 e2e 断言（不新增条目，仍 **460 项**）：push 带微秒 `markedAt` 后 `/my/devices` 回读一致、`null` 取消后回读为 `null`、`entity=user_device` 的 `change_log` payload 含 `markedAt`、幂等键内容比较覆盖该字段，fixture 与真 Postgres 均 PASS；单测合计 **457**）。上一版 **v0.29.0**（`MARKETING_VERSION 0.29.0`，`CURRENT_PROJECT_VERSION 38`，tag `v0.29.0`：接入后端 `PJGoIoT` v0.25.0 的「设备标记」（契约 0.20.0）。`saved_devices` 迁移 **v17** 增加 `marked_at` / `marked_at_patch`（`PRAGMA table_info` 判列、可重复执行，旧行保留）；`PushDevice` 新增 `markedAt` 三态 —— 字段缺省保持原值、`null` / `""` 取消标记、RFC3339 时间标记，与 `alias` / `group` / `deviceType` 共用设备级 `updatedAt` 字段级 LWW，旧 `updatedAt` 走已有 `conflict(server_newer)` 路径以服务端为准；增量 `entity=user_device` 的 `markedAt` 落地本机（未标记为 `null`）；设备列表 / 首页卡片显示「已标记」，本机先写待同步时显示「已标记 · 待同步」而不是已同步，详情新增「标记」行可标记 / 取消；新增 7 个单测覆盖三态解码、null 取消、旧 `updatedAt` 冲突、增量落地与换号隔离，合计 **456**）。上一版 **v0.28.0**（`MARKETING_VERSION 0.28.0`，`CURRENT_PROJECT_VERSION 37`，tag `v0.28.0`：① 按 App Store 6.9 英寸规格在 **iPhone 18 Pro Max · iOS 27.2** 模拟器重导整组 **18 张 1320×2868** 截图（同名替换 `docs/screenshots`）；工程 `TARGETED_DEVICE_FAMILY = "1,2"`、iPad 四方向、无 `UIRequiresFullScreen`，因此同时补 **iPad Pro 13-inch (M5)** 同名 18 张 **2064×2752**（`docs/screenshots/ipad-13`），逐张核对内容与标题；② APNs 令牌申报与二进制对齐 —— 当前无 `aps-environment` entitlement，**不采集令牌**，DeviceID 实际只含 BLE 外设 UUID；`store-listing.md` / `app-privacy.md` / `privacy-policy.md` 明确「当前不采集、启用推送后需改 6 处」，新增 `PrivacyManifestTests` 断言清单恰为 8 类且与商店文档逐项一致；③ 首页底部截图改用慢速多次上滑，6.9 英寸下滚到次卧最后两张卡完整在 Tab 之上）。上一版 **v0.27.0**（`MARKETING_VERSION 0.27.0`，`CURRENT_PROJECT_VERSION 36`，tag `v0.27.0`：① 重截「我的」`profile.png`，滚到「阈值告警」分区，完整显示「推送注册 = 未配置推送」与三行说明（证书缺失、不注册占位令牌），顶部无半行、底部未被悬浮 Tab 条带切断；② 用后端 `PJGoIoT` v0.23.0 干净 worktree 重跑 `scripts/e2e-postgres.sh`，在真实 Postgres 上直接查库确认 `push_devices` 表、同 token 注册幂等（1 行 / 同 `deviceId`）、停用不硬删、`inactive` 重置 `active`、跨用户隔离且互不可停用、注册前后 `change_log` 条目数不变且无 push 实体，契约仍为 460 项 0 失败；③ 补齐 App Store 上架材料 `docs/store-listing.md`（中英文名称 / 副标题 / 促销文本 / 完整描述 / 关键词逐项标字数、隐私营养标签 8 类、审核备注、未上传 / 无账号 / 无审核声明），同步 `docs/app-privacy.md`、`docs/privacy-policy.md` 与 `PrivacyInfo.xcprivacy`（新增 `OtherDataTypes` / `OtherUserContactInfo` / `OtherDiagnosticData`，`plutil -lint` 通过））。上一版 **v0.26.0**（`MARKETING_VERSION 0.26.0`，`CURRENT_PROJECT_VERSION 35`，tag `v0.26.0`：接入推送令牌注册（后端 `PJGoIoT` v0.23.0 / openapi 0.18.0）。`PushRegistrationService` 在会话就绪、回到前台、APNs token 变化时注册；登出与删除账号前先 `DELETE /push/devices/{deviceId}` 再清本地；通知权限与注册解耦，拒绝通知仍完成注册但如实提示「推送不会展示」。拿不到推送证书 / entitlement 时状态停在「未配置推送 · 无法获取令牌」，**不注册占位 token，界面不显示「已开启」**。本地迁移 v16 新增 `push_devices`（deviceId / token / status / 最后错误 / 退避时间）；网络与 5xx 指数退避，400 `PUSH_DEVICE_INVALID` 终态。新增 `PushMessageHandler` 按 `kind` 解析并跳转设备详情或场景页；e2e 升级到后端 v0.23.0，补 push 与 `/scenes` 可选分页断言，项数本机 / CI 一致 460）。上一版 **v0.25.1**（`MARKETING_VERSION 0.25.1`，`CURRENT_PROJECT_VERSION 34`，tag `v0.25.1`：iOS 26 悬浮 Tab 的玻璃胶囊只遮住自身，胶囊下方到屏幕底会露出滚动内容；本版在最上层铺一条与画布同色的不透明条带（`BottomBand`），任意页面、任意滚动位置，Tab 条带区域内都不再出现被切断的文字或按钮，胶囊本身保留玻璃效果）。上一版 **v0.25.0**（`MARKETING_VERSION 0.25.0`，`CURRENT_PROJECT_VERSION 33`，tag `v0.25.0`：① 家庭管理「家庭房间」分区不再把「房间」导航入口当成一行房间 —— 入口移到分区头右侧「管理」，分区行数只等于真实房间数，与房间管理页一致；② 首页底部留白抽成 `BottomOcclusion` 纯函数并补测，`viewSafeAreaInsetsDidChange` 重算，滚到底时最后一项完整位于悬浮 Tab 之上；③ 设备卡名称与状态拆成两行，名称最多两行按需省略，状态（未连接 / 已连接 / 离线）独占一行不被截断；顺带修掉分区头复用导致旧标题叠字的问题）。上一版 **v0.24.0**（`MARKETING_VERSION 0.24.0`，`CURRENT_PROJECT_VERSION 32`，tag `v0.24.0`：① 场景 `rejected` 终态对齐 Android —— 收到 `SCENE_*` 4xx 后落库拒绝码 / 可读原因 / `rejected_at`，终态不再自动重试，用户编辑字段才回 `pending`，429 的 `Retry-After` 落 `next_retry_at` 跨进程保留（迁移 v15，见 [docs/consistency.md](docs/consistency.md) 3.20）；② 首页筛选 chip 按固有宽度 + 内边距排布，常规字号横向滚动、AX 档竖排，不再出现半截字；③ 家庭成员显示「成员 N」而非原始用户 ID；④ 所有可滚动页面按悬浮 Tab 高度 + 安全区补底部 inset；⑤ 家庭管理与房间管理房间列表恢复一致；⑥ seed 读数改为 7 天 / 30 分钟一个点、按设备类型与型号差异化）。上一版 **v0.23.0**（`MARKETING_VERSION 0.23.0`，`CURRENT_PROJECT_VERSION 31`，tag `v0.23.0`：① e2e 项数稳定化 —— 定位到「本机 430 / CI 432」差异是导出轮询把 2 条断言写在循环内、按轮次动态生成，改为循环外累积布尔量后两边固定 430（详见 [docs/consistency.md](docs/consistency.md)）；② 归档 16 张模拟器真实截图到 [docs/screenshots](docs/screenshots)，数据为「模拟器 + 本机后端 + seed 数据」；③ 修场景指标名映射，服务端 `temperature_celsius` 等键不再原样显示）。上一版 v0.22.0：会话生命周期接通 —— 所有带 Bearer 的请求共用 401 → **单飞 `POST /auth/refresh`** → 原子替换 Keychain token → 重放原请求；刷新返回 401 才进入「需要重新登录」并保留本地设备 / 读数 / 家庭 / 场景，网络或 5xx 失败不清会话；「我的」新增登录会话管理（`GET /sessions` 标出当前会话、`DELETE /sessions/{id}` 单独吊销、`POST /auth/logout` 退出当前会话），退出登录与删除账号明确区分；映射 6 个 `SCENE_*` 错误码；4xx 一律终态、429 单独按 `Retry-After`；导出解析 `failureReason`；反馈详情 `GET /feedback/{id}` + 本人关闭 `PATCH /feedback/{id}`（409 明确文案）；单设备详情按平台路由（Android → `GET /my/devices/{mac}`）；契约对齐 `PJGoIoT` v0.22.0 / openapi 0.17.0） |
| 五模块（首页 / 智能 / 产品 / 市场 / 我的） | 已实现，纯代码 UIKit，真实数据路径；设备管理并入首页，规则与场景集中在「智能」 |
| CoreBluetooth 扫描 + 连接 | 已实现（`CBCentralManager`，真实 RSSI） |
| BLE 读数采集 | 已实现：连接后订阅心率 `0x2A37`、电量 `0x2A19`、温度 `0x2A6E`、Nordic UART TX `6E400003-…`；各特征独立解析器，失败静默丢弃并写本地日志 |
| 设备类型目录（v0.19.0） | **服务端为唯一事实源**：类型清单、展示名、GATT 服务、指标（`key` / `unit` / `characteristicUuid`）、限制与兼容性均来自 `GET /catalog/device-types`；本地只保留 SQLite 单行缓存（原始 JSON + `ETag` / `Last-Modified`），无第二份常量清单。下次请求带条件头，304 复用缓存并刷新 `last_used_at`；断网有缓存时展示缓存并标注「目录更新时间 / 离线缓存」，无缓存才给错误与重试。目录声明的指标按特征 UUID 与本地解析器对齐，解析不了的标注「当前版本不支持」；目录对 NUS 声明空指标时按透传处理 |
| 长周期读数图表 | 已实现：1 小时 / 24 小时 / 7 天 / 30 天区间切换（映射 `1m` / `1h` / `1h` / `1d`），X 轴按桶 `start` 真实时间比例定位，缺口断线，`avg` 折线 + `min`–`max` 区间带，Y 轴自适应并带单位；**v0.11.0 支持点选 / 长按桶查看 start–end、min/max/avg/last 与条数（本地时区），点空白取消，Y 轴不变，并给出无障碍摘要** |
| 本地持久化 | 已实现（SQLite3，含同步字段；迁移 **v18** 为 `saved_devices` 增加 `server_last_seen_at`（服务端最近上报时间，只读派生字段；`PRAGMA table_info` 判列、可重复执行，旧行保留，写入该列不改 `updatedAt` / 不置 pending）；迁移 **v17** 为 `saved_devices` 增加 `marked_at` / `marked_at_patch`（设备标记三态，`PRAGMA table_info` 判列、可重复执行，旧行保留）；迁移 **v16** 新增单行 `push_devices`（`token` / `remote_device_id` / `platform` / `status` / `last_error` / `attempts` / `next_retry_at` / 时间戳，`PRAGMA table_info` 判列、可重复执行，旧数据保留）；迁移 **v15** 为 `scenarios` 增加 `rejection_code` / `rejection_reason` / `rejected_at` / `next_retry_at`（`PRAGMA table_info` 判列、可重复执行，旧行保留）；迁移 **v14** 为 `scenarios` 增加 `kind` / `remote_id` / `version` / 字段级时间戳 / `sync_state` / `deleted_at` / `device_missing` 等列，旧手动场景保留；迁移 **v13** 新增 `device_catalog_cache`（单行原始 JSON + `etag` / `last_modified` / `fetched_at` / `last_used_at`，`PRAGMA table_info` 判列可重复执行）；迁移 **v12** 为 `feedback_drafts` 增加 `status` / `last_error` / `remote_id` / `next_retry_at`（`PRAGMA table_info` 判列可重复执行，旧行保留并默认 `pending`）；迁移 **v11** 新增 `feedback_drafts`；迁移 **v10** 为 `households` 增加 `room_count`（服务端真实房间数，不本地计数）；v9 新增 `households`（`id` / `remote_id` / `name` / `is_personal` / `role` / `member_count` / `device_count`）与 `device_assignment_pending`（设备归属上报队列），为 `rooms` 启用 `remote_id` 并增加 `household_id` / `sync_state` / `deleted`，为 `saved_devices` 增加 `household_id` / `remote_room_id` / `remote_household_id`；v8 新增 `rooms` 表与可空 `room_id`，v7 为 `rules` 加指标阈值字段，v6 新增仅本机的 `scenarios` 表；v5 新增 `readings` 表，本地保留 7 天；v4 区分 `advertised_name` 与用户别名并记录三态 patch） |
| 家庭（v0.15.0） | **已接入后端**：`GET /households` 的 `memberCount` / `deviceCount` / `roomCount` 全部使用服务端真实数字；「我的 → 家庭管理」按角色裁剪入口：owner 可签发 / 撤销邀请码、移除成员、改家庭名、退出家庭，member 只能查看与退出。成员支持左滑 / 点击移除（二次确认并说明对方设备回其个人家庭）；owner 还有其他成员时退出前置提示「请先转让所有权或移除其他成员」，服务端 409 同一文案。邀请码列表只展示哈希前缀 / 状态 / 过期时间并可撤销，绝无明文。房间支持拖拽与上下移动排序，整段提交 `PUT /rooms/order`；409（`ROOM_SET_MISMATCH` 或 v0.13.0 的 `CONFLICT`）自动重新 GET 并提示「房间列表已变化，已刷新」。设备归属仍走独立 `PATCH /my/devices/{platform}/{externalId}`；退出 / 被移除后本地设备回落个人家庭、房间脱钩保留并标注未同步 |
| 房间详情（v0.31.5） | **已实现**：首页房间分区标题进入；聚合本机 SQLite / 服务端同步的同一份 `saved_devices`，汇总为 4 行「共 N 台 / 本机在线 N · 最近上报 N / 已离线 N · 从未上报 N / 本机不可连接 N · 已标记 N」；**每台设备读数本机优先，本机没有时按需取服务端最近读数并标注「云端 X 前上报」**，查询中 / 失败分别显示「正在读取云端读数」「云端读数暂不可用」，两端都确认无数据才是「暂无读数」；状态优先级为 本机 BLE 连接 > 服务端 `presence`（`online` 写「最近上报 X 前」、`offline` 写「已离线 · 最近上报 X 前」、`unknown` 写「从未上报读数」，不把推导结果包装成权威在线绿灯），跨平台设备单独标「来自 Android，本机不可连接」而不并进离线（见 [docs/consistency.md](docs/consistency.md) 3.28）；批量标记 / 取消标记先写本机 `markedAt` 三态再 push，未同步显示「待同步」，无目标时按钮禁用；成员家庭进页说明房间管理仅 owner；空房间显示真实空态并可跳转扫描 |
| 本地化（v0.12.0） | **已实现**：全部界面文案走 `L10n.t` / `L10n.f`，资源为 `Resources/zh-Hans.lproj/Localizable.strings` 与 `en.lproj/Localizable.strings`；工程 `knownRegions` 含 `zh-Hans`，`CFBundleLocalizations = [en, zh-Hans]`，设置跟随系统语言；术语双语见第 11 节；单测强制扫描 View / ViewModel 源码不得硬编码中文，并校验两语言 key 集合与占位符一致 |
| 动态字体（v0.12.0） | **已实现**：字号统一走 `AppText`（`UIFontMetrics` 缩放）+ `applyFont(_:)`（`adjustsFontForContentSizeCategory = true`）；表格行高自适应；图表 Y 轴左侧留白随字号测量增长，超大字号缩为 3 个刻度且不与绘图区重叠 |
| 设计系统（v0.8.0） | **已落地**：`Palette` 36 个语义色（浅/深 `UIColor(dynamicProvider:)`）、`Layout` 4pt 阶梯 / 16 页边距 / 56·72·88 行高 / 12 圆角 / 1dp 描边、`AppText` 10 级字号与等宽数字；代码内无硬编码色值与字号（单测强制扫描） |
| 网络层 | 已实现（URLSession + Codable；账号删除 / 导出对齐 `PJGoIoT` v0.19.0 openapi 0.15.0：`POST /me/deletion-request` + `X-Deletion-Token` 删除、异步导出任务 + 一次性下载链接；设备类型目录 `GET /catalog/device-types` 对齐 openapi 0.14.0，带 `If-None-Match` / `If-Modified-Since` 条件请求并处理 304；反馈 `POST /feedback` / `GET /feedback/mine` 对齐 openapi 0.12.0，使用 `Idempotency-Key`（草稿本地 ID）、`Retry-After` 与 `Idempotent-Replayed`；家庭 / 邀请码 / 房间 / 设备归属对齐 openapi 0.9.0；设备/型号/同步对齐 openapi 0.7.0 起的既有契约；读数查询 / summary / series / metrics 对齐 v0.5.1 起；详情页远端刷新 800ms 去抖动 + 失败指数退避 ≤5 分钟，不可见/后台不请求；分页上限 changes 500 / readings 500 / feedback 50，导出不再分页） |
| 同步 | **已实现**：匿名登录、增量拉取、批量推送（设备 ≤100/批 + 读数 ≤200/批、幂等键含读数）、冲突提示、tombstone、Keychain token、前后台 / BGTask 触发、断网累积补传；**设备标记 `markedAt` 与 `alias` / `group` / `deviceType` 同一字段级 LWW（缺省 / `null` / 时间三态，RFC3339 编解码保留微秒）**；**服务端 `lastSeenAt` / `presence` 为只读派生字段**：`lastSeenAt` 落 `server_last_seen_at` 并随增量更新，但**不入 push、不置 pending、不推进本地 `updatedAt`**，`presence` 仅在响应中实时推导、不落库，本地按 900 秒窗口自行渲染；后台唤醒仅做受限推送（不拉增量、不建号、≥15 分钟间隔）；**410 `RESYNC_REQUIRED` 自动全量重同步（pending 不丢）**，503 `TIMEOUT` 指数退避 |
| 自绘 RSSI + 自绘折线图 + 代码组装空状态 | 已实现（读数图表纯 `draw(_:)`，无第三方图表库） |
| 首启引导 | **已实现**：3 步（蓝牙 / 通知 / 后台采集），仅首次或未走完时出现，可跳过；步骤与完成标记持久化到 `UserDefaults` |
| 推送注册（v0.26.0） | **已接入后端 v0.23.0**：`POST /push/devices`（Bearer，同 `(user_id, token)` 幂等 upsert，`inactive` 重置 `active`）与 `DELETE /push/devices/{deviceId}`（置 `inactive`，404 视为已不存在）。`PushRegistrationService` 在会话就绪 / 回到前台 / APNs token 变化时注册；登出与删除账号前先 DELETE 再清本地。通知权限只决定展示，拒绝后仍完成注册并在「我的 → 阈值告警」提示「已注册 · 通知未授权 / 推送不会展示」。**无推送证书与 entitlement 时拿不到 token，不写占位值、不调用注册接口，状态停在「未配置推送 · 无法获取令牌」，界面不显示「已开启」**；配好证书即可直接工作。失败按网络 / 5xx / 429 指数退避（30s 起、上限 1h，429 优先 `Retry-After`），400 `PUSH_DEVICE_INVALID` 为终态并记录可读原因。通知点击由 `PushMessageHandler` 解析 `alertId` / `kind` / `deviceId` / `externalId`，跳转设备详情或场景页 |
| 单元测试 | **495 个用例，0 失败**（`** TEST SUCCEEDED **`，2026-11-07，Xcode 27.2 / iPhone 18 Pro 模拟器；v0.31.6 新增 `DeviceLinkStatusTests` 四档判定 / BLE 优先 / 900 秒边界 / 跨平台同时呈现 / 不出现「在线」措辞，房间详情改为「只有 BLE 才算本机已连接」与 unknown 跳过云端请求，首页增加 unknown 跳过云端请求；v0.31.5 新增/更新 7 个 presence 用例：房间详情三态渲染、900 秒窗口边界、本机 BLE 连接优先、`/sync/changes` 增量覆盖本地 `serverLastSeenAt`、pending 设备只更新只读列且保留状态与 `updatedAt`、字段缺省不覆盖、`presence` 更新不触发同步脏位；`PersistenceTests` 增加 `serverLastSeenAt` 往返；`HomeViewModelTests` 未接入设备状态文案改为「从未上报读数」；v0.31.4 更新 `HomeLayoutTests.testDeviceCardShowsFullStatusUnderLongName` 按内容实测高度布局、`RoomTests` 断言数值与单位间为不换行空格；v0.31.3 新增 12 个云端读数测试：云端补齐缺失读数并保留来源边界 / 本机读数优先 / 云端失败显示不可用而非暂无读数 / 云端空且本机空仍暂无读数 / 首页云端读数与上报时间 / 云端失败不影响连接状态 / 服务端最新指标与单位映射 / 无指标为空且不再请求读数 / 404 为空 / 网络失败 / 读数失败 / 缓存命中不重复请求；v0.31.1 新增 2 个房间详情布局测试：AX5 下按钮竖排且文本不截断、iPad 1024×1366 下内容居中限宽 760 且按钮不溢出；v0.31.0 新增 9 个房间详情测试：聚合与真实读数、在线判定、批量标记、批量取消耗待同步、空批次无副作用、成员只读、owner 可管理、空态、跨家庭隔离；v0.30.0 新增 1 个 RFC3339 微秒往返测试；v0.29.0 新增 7 个：`markedAt` 三态解码 / push 三态编码 / 标记与取消走 push / 旧 `updatedAt` 冲突 / 增量落地与清除 / 换号重传隔离 / 详情待同步；既有用例全部保持） |
| 模拟器构建 | **通过**（`xcodebuild ... build`，`** BUILD SUCCEEDED **`） |
| CI | **main 与 tag 全绿**：tag run [42359937473](https://github.com/platojobs/codemagic/actions/runs/42359937473)（`Build & Test` **495 单测 0 失败**、`E2E contract` **460 项 0 失败**，后端 fixture `PJGoIoT` v0.25.0）；main run [42359926481](https://github.com/platojobs/codemagic/actions/runs/42359926481)（tag 同 sha 触发时被并发取消，tag 完成后重跑，同为 495 / 460）。上一版 v0.31.5 tag run [42353217809](https://github.com/platojobs/codemagic/actions/runs/42353217809)、main run [42354364200](https://github.com/platojobs/codemagic/actions/runs/42354364200)（487 / 460）。**CI 的 460 项全绿不包含 presence 断言**（fixture 仍 pin v0.25.0）；本地 `e2e-contract` / `e2e-postgres` 已用 `PJGoIoT` v0.26.0（契约 0.21.0 / 迁移 20）跑通 presence（unknown/null + 真 Postgres 的 online/offline） |
| 真机 BLE / 签名 | **未验证**：本机无真机与 Apple 开发者账号；读数采集与图表需真机 / 可穿戴设备验证（见第 9 节） |
| 真实后端同步 | **契约已联调**：`scripts/e2e-contract.sh` 对**干净 worktree 的 `PJGoIoT` v0.26.0**（`STORE=fixture`，openapi 0.21.0）跑 **460 项断言，全部 PASS**，CI 同为 **460 项**但 fixture 仍 pin v0.25.0（见上方 CI 覆盖边界）。本地 v0.26.0 新增 presence 断言：从未上报设备返回 `presence=unknown` / `lastSeenAt=null`；曾临时把期望改为 `online` 做反向验证，结果为 459 通过 / 1 失败 / 退出码 1，证明断言真实触发。`scripts/e2e-postgres.sh` 在**真实 Postgres** 上重跑同一套契约并直接查库：读数被接受后 `presence=online` 且 `lastSeenAt` 为服务端接收时间（≤ 60 秒），回拨 `user_devices.last_seen_at` 20 分钟后读接口返回 `presence=offline` 且保留最近上报时间；`push_devices` 表存在、同 `(user, token)` 幂等 1 行且沿用同一 `deviceId`、停用置 `inactive` 不硬删、同 token 再注册重置 `active`、跨用户同 token 各自独立且互不可停用、注册前后两个账号 `change_log` 条目数不变且无 push 实体，本轮同样 **PASS**（输出见 [docs/e2e-postgres.md](docs/e2e-postgres.md)）；通知权限、真实 APNs 推送与后台触发仍需真机手动验证 |
| 上架材料 | **已补齐但未上架**：`docs/store-listing.md`（中英文名称 / 副标题 / 促销文本 / 完整描述 / 关键词逐项标字数；隐私营养标签 8 类且 APNs 令牌明确「当前不采集」；审核备注；6.9 英寸 1320×2868 与 iPad 13 英寸 2064×2752 截图已导出；未上传 / 无开发者账号 / 无审核记录）、`docs/privacy-policy.md`、`docs/app-privacy.md` 与 `codemagic/Resources/PrivacyInfo.xcprivacy`（8 类不变，`plutil -lint` 通过）。**未上传 App Store Connect、无 Apple Developer Program 账号、无审核记录、无分发证书与 APNs 证书**，不得声称已上架或已过审 |

> **CI 覆盖边界（v0.31.6，必读）**：`.github/workflows/ios.yml:84` 仍 pin `PJGoIoT` **v0.25.0**，而 `presence` / `lastSeenAt` 是 **v0.26.0** 才有的字段。因此 CI 的 `e2e-contract` **「460 项全绿」并不包含新字段断言** —— 旧后端响应里没有 `presence`，新增断言在 CI 下不会命中新字段。新字段只在本地 v0.26.0 上验证：`scripts/e2e-contract.sh` 断言 `presence=unknown / lastSeenAt=null`（并做过反向验证，临时改成错误值后 459 通过 / 1 失败、退出码 1），`scripts/e2e-postgres.sh` 在真 Postgres 上断言读数推送后 `presence=online` / `lastSeenAt` 为服务端接收时间、回拨 `last_seen_at` 20 分钟后 `presence=offline`。**不要把 CI 全绿误认为新字段已覆盖**；修复需要给 GitHub 推送凭证补 `workflow` scope 后把 pin 升到 v0.26.0，目前无法在本机完成。

### 界面截图（模拟器 + 本机后端 + seed 数据）

> 以下截图由 **iOS 模拟器里运行的 Debug 构建** 实际截取：iPhone 端为 **iPhone 18 Pro Max · iOS 27.2（6.9 英寸，1320×2868）**，iPad 端为 **iPad Pro 13-inch (M5) · iPadOS 27.2（2064×2752）**。其中 18 张为 v0.28.0 构建；iPhone 首页 6 张、房间详情 24 张与 iPad 首页 / 房间详情为 **v0.31.5 用同一份 seed 数据重拍**，页面里的设备读数由 App 走真实链路 `GET /my/devices/{platform}/{externalId}/readings?metric=…&limit=1` 从本机后端取得，presence 与 `lastSeenAt` 由 `/sync/changes` 下发、不是夹具拼图。截图的后端均为**本机 Postgres（`PJGoIoT` v0.26.0，127.0.0.1:8080）**，数据由 `scripts/seed-demo-data.sh` 写入：3 个演示家庭（我的家 / 父母家 / 办公室）、6 个房间、12 台在用设备（另 1 台被已移除设备的场景引用）、7 天读数（每 30 分钟一个点）、4 个服务端场景（其中 1 个引用已移除设备）、3 条反馈（1 条已关闭）。
>
> **房间详情 24 张、首页 6 张与 iPad 首页 / 房间详情（v0.31.5）与本机后端同源、可复现**：`scripts/seed-demo-data.sh` 一键重建上述演示数据，并额外建 1 个只读成员账号（父母家成员，自带 1 个空个人家庭）用于「成员只读」截图；脚本连跑两次得到完全相同的形状（3 演示家庭 / 6 房间 / 12 台在用设备 + 1 台已移除 / 6384 条读数 / 4 场景 / 3 反馈），不会累积脏数据。
>
> 画面里的上报状态与读数怎么来（v0.31.5）：服务端有 7 天读数（seed 为 6384 条），`/sync/changes` 只拉家庭 / 房间 / 设备 / 场景、**不含读数**，所以设备行在本机没有读数时按需请求 `GET /readings?limit=1`，显示「云端 X 前上报 · 心率 72 bpm」这类真实读数；本机与云端都确认无数据才显示「暂无读数」。设备的上报状态来自后端 `UserDevice.lastSeenAt` / `presence`（契约 0.21.0）：seed 通过 `/sync/push` 上报读数后，服务端把接收时间写入 `last_seen_at`，900 秒内 `presence=online`，界面写「最近上报 X 前」；超过窗口转 `offline`，写「已离线 · 最近上报 X 前」。截图汇总为「共 3 台 / 本机在线 0 · 最近上报 3 / 已离线 0 · 从未上报 0 / 本机不可连接 3 · 已标记 1」，跨平台设备保留「来自 Android，本机不可连接」但不并进离线；**「最近上报」只是推导结果，不包装成权威在线绿灯**。这是真实链路结果，不是造数缺失；截图须在 seed 后 15 分钟窗口内拍摄。
>
> `household_rooms = 0` 的排查结论：`scripts/e2e-contract.sh` 使用内存 fixture，`scripts/e2e-postgres.sh` 固定独立库 `pjgoiot_e2e`，两者都不会 TRUNCATE 开发库；开发库只剩 e2e 残留家庭是旧的手工重置与反复匿名登录累积所致，**不是 e2e 清库**。`seed-demo-data.sh` 默认先清空用户数据表再按固定名称重建，是恢复开发库的标准手段；`e2e-postgres.sh` 已加库名断言，库名不含 `_e2e` 直接拒绝运行。
>
> seed 前置条件：后端 `PJGoIoT` **v0.26.0**，数据库迁移到 **20**（`000019_device_marked_at` / `000020_device_presence`）；Postgres 可连，`DATABASE_URL` 默认 `postgres://platojobs@127.0.0.1:5432/pjgoiot?sslmode=disable`；API 以 `STORE=postgres` 启动并可访问 `SEED_BASE_URL`（默认 `http://127.0.0.1:8080`）；本机有 `psql` / `python3` / `curl`。账号由脚本 `POST /auth/anonymous` 新建，结束时打印 10 分钟一次性 `pairingCode`（成员截图用 `memberPairingCode`），在 App「我的 → 用配对码恢复原账号」输入即可接管。默认只清 `pjgoiot` / `*_seed` / `*_demo` / `*_e2e`，其他库需 `SEED_ALLOW_RESET_ANY_DB=1`。不是设计稿、不是拼图，也不是真机 / 生产环境。

| 页面 | 截图 | 内容 |
| --- | --- | --- |
| 首页 | [home.png](docs/screenshots/home.png) | 筛选 chip 完整文案（排序 / 房间 · 3 / 我的家）、房间分段（客厅 · 3）、设备卡名称与状态分两行（「本机不可连接」与「最近上报」完整可见）；时间行「最近上报 X 前」，「已标记」独占一行不被拆成「已 / 标记」；**本机无读数时显示云端最近读数与「云端 X 前」上报时间**（客厅三台：心率 72 bpm / 湿度 52 % / 踏频 78 rpm）、快捷场景 |
| 首页 · 底部 | [home-bottom.png](docs/screenshots/home-bottom.png) | 滚到底：次卧两张设备卡完整位于悬浮 Tab 顶边（873pt）之上，Tab 胶囊下方条带内无卡片残片；卡片同样显示云端读数与上报时间；顶部可见上一分区末张卡的上半部分，属正常滚动截断 |
| 智能 · 场景列表 | [scenes.png](docs/screenshots/scenes.png) | 4 个服务端场景（含 1 个「设备已移除」）；同步完成后无独立本机场景 |
| 智能 · 场景详情 | [scene-detail.png](docs/screenshots/scene-detail.png) | 工作日早晨开窗提醒（定时 07:30、周一至周五、通知动作） |
| 产品 · 列表 | [products.png](docs/screenshots/products.png) | 服务端目录的 5 类设备 |
| 产品 · 详情 | [product-detail.png](docs/screenshots/product-detail.png) | 单个类型的功能与指标说明 |
| 市场 | [market.png](docs/screenshots/market.png) | 服务端下发的商品与固件条目 |
| 我的 | [profile.png](docs/screenshots/profile.png) | 从「登录会话」分区头开始，完整显示「阈值告警」4 行（含「推送注册 = 未配置推送」）与三行说明（首次命中请求通知权限；未配置推送 / 无法获取 APNs 令牌：未找到 `aps-environment` 授权字符串，不注册占位令牌），下接「外观」分区；顶部无半行、底部未被悬浮 Tab 条带遮挡（1320×2868） |
| 家庭管理 | [households.png](docs/screenshots/households.png) | 当前家庭「我的家」：1 位成员 / 7 台设备 / 3 个房间；成员显示「成员 1 · 所有者 · 我」；房间分区头右侧为「管理」入口，列表只有真实房间 |
| 家庭管理 · 底部 | [households-bottom.png](docs/screenshots/households-bottom.png) | 滚到底：房间列表（客厅 / 主卧 / 次卧）与说明文字完整位于悬浮 Tab 之上，Tab 胶囊下方无「创建家庭」按钮残片 |
| 家庭切换 | [households-list.png](docs/screenshots/households-list.png) | 3 个家庭（我的家 / 父母家 / 办公室） |
| 房间管理 | [rooms.png](docs/screenshots/rooms.png) | 当前家庭「我的家」的 3 个房间（客厅 · 3 / 主卧 · 2 / 次卧 · 2），与家庭管理页一致 |
| 房间详情 | [room-detail.png](docs/screenshots/room-detail.png) | 汇总 4 行：共 3 台 / 本机在线 0 · 最近上报 3 / 已离线 0 · 从未上报 0 / 本机不可连接 3 · 已标记 1；每行为名称、「来自 Android，本机不可连接 · 已标记」、「最近上报 X 前」与「云端 X 前上报 · 心率 72 bpm」；presence 与 `lastSeenAt` 来自后端 v0.26.0，读数来自 `GET /readings?metric=…&limit=1` 的真实链路；跨平台设备不计为离线，`online` 也只写「最近上报」 |
| 房间详情 · 待同步 | [room-detail-pending.png](docs/screenshots/room-detail-pending.png) | 批量标记后 3 台已标记，其中 2 台「待同步」并给出批次提示；「标记」禁用、「取消标记」可用，行内为「已标记 · 待同步」 |
| 房间详情 · 空态 | [room-detail-empty.png](docs/screenshots/room-detail-empty.png) | 父母家 · 书房（seed 中该房间无设备）显示「这个房间还没有设备」、说明与扫描入口，无白屏 |
| 房间详情 · 成员只读 | [room-detail-member.png](docs/screenshots/room-detail-member.png) | 成员账号进入「父母家 · 客厅」：进页说明「新建、改名、排序、删除房间仅家庭所有者可用」；2 台设备（最近上报 2 · 本机在线 0 · 本机不可连接 2）显示「最近上报 X 前」、云端读数（心率 72 bpm / 湿度 52 %）与「云端 X 前上报」，可查看、可标记，不必点进管理才看到 403 |
| 会话管理 | [sessions.png](docs/screenshots/sessions.png) | 共 6 条会话：当前会话（iPhone 18 Pro Max）与 5 条历史会话，可单独吊销 |
| 反馈列表 | [feedback-list.png](docs/screenshots/feedback-list.png) | 3 条反馈，状态含「已关闭」 |
| 反馈详情 | [feedback-detail.png](docs/screenshots/feedback-detail.png) | 单条反馈的正文、上下文与状态流转 |
| 账号与数据 | [account-data.png](docs/screenshots/account-data.png) | 导出我的数据、注销账号、匿名账号与会话到期日 |
| 首页（AX 最大字号） | [home-ax.png](docs/screenshots/home-ax.png) · [bottom](docs/screenshots/home-ax-bottom.png) | 三个筛选 chip 竖排；设备卡单列、按内容实测高度，名称 / 状态 / 读数 / 时间完整（`72 bpm` 不拆行，「最近上报 1 分钟前」整体不拆，「已标记」独占一行）；滚到底最后一张卡完整位于悬浮 Tab 之上 |
| 首页（200%，AX2） | [home-200.png](docs/screenshots/home-200.png) · [bottom](docs/screenshots/home-200-bottom.png) | iPhone AX 档复测：两列变单列后设备卡与时间行完整、不裁切，底部避让正常 |
| 场景页（AX 最大字号） | [scenes-ax.png](docs/screenshots/scenes-ax.png) | 场景名与「设备已移除」徽章改为上下排，文字完整 |

房间详情大字号与 iPad 走查（v0.31.5，均使用 `scripts/seed-demo-data.sh` 重建的 seed 数据）：

| 档位 / 设备 | 截图 | 内容 |
| --- | --- | --- |
| AX5（`accessibilityExtraExtraExtraLarge`）<br>iPhone 18 Pro Max · iOS 27.2 | [room-detail-ax5.png](docs/screenshots/room-detail-ax5.png) · [rows](docs/screenshots/room-detail-ax5-rows.png) · [pending](docs/screenshots/room-detail-ax5-pending.png) · [pending-rows](docs/screenshots/room-detail-ax5-pending-rows.png) · [empty](docs/screenshots/room-detail-ax5-empty.png) · [member](docs/screenshots/room-detail-ax5-member.png) | 汇总四行、批量按钮全宽竖排且高度随字号增长、设备行名称 / 上报状态 / 最近上报时间 / 云端读数 / 已标记·待同步完整，「来自 Android，」后强制断行避免「本机不可连接」拆成单字行、空态标题「这个房间 / 还没有设备」不拆词、成员只读说明分行、底部不被 Tab 条带遮挡 |
| 200%（AX2 `accessibilityLarge`，≈194%）<br>iPhone 18 Pro Max · iOS 27.2 | [room-detail-200.png](docs/screenshots/room-detail-200.png) · [rows](docs/screenshots/room-detail-200-rows.png) · [pending](docs/screenshots/room-detail-200-pending.png) · [pending-rows](docs/screenshots/room-detail-200-pending-rows.png) · [empty](docs/screenshots/room-detail-200-empty.png) · [member](docs/screenshots/room-detail-200-member.png) | 同一组页面在 200% 近似档复测；iOS 无 Android `fontScale` 的 200% 档，以 AX2 作为近似 |
| iPad 13 英寸（系统默认字号）<br>iPad Pro 13-inch (M5) · iPadOS 27.2 | [room-detail-ipad.png](docs/screenshots/room-detail-ipad.png) · [rows](docs/screenshots/room-detail-ipad-rows.png) · [pending](docs/screenshots/room-detail-ipad-pending.png) · [pending-rows](docs/screenshots/room-detail-ipad-pending-rows.png) · [empty](docs/screenshots/room-detail-ipad-empty.png) · [member](docs/screenshots/room-detail-ipad-member.png) | 列表居中限宽 760pt，不挤在左侧；按钮横排等宽且不溢出；iPad 为顶部浮动 Tab 栏，无底部条带遮挡 |

iPad 13 英寸同名整组 18 张见 [docs/screenshots/ipad-13](docs/screenshots/ipad-13)，尺寸 2064×2752；其中 `home.png` / `home-bottom.png` / `home-ax.png` 为 v0.31.5 重拍（presence 文案与卡片自适应高度），其余 15 张仍为 v0.28.0 构建。iPad 使用系统顶部浮动 Tab 栏，不存在底部条带遮挡。

seed 的边界（如实记录）：

- 后端设备类型目录只有 **5 种** `deviceType`，因此 12 台设备覆盖这 5 类（不是 12 种不同型号）；电量 / 温度 / 湿度 / 心率按设备类型与编号分别生成，不再出现两台不同型号设备读数完全相同。
- 「1 个 `rejected` 场景」在本轮 seed 中不存在：4 个场景均由服务端返回，其中「阳台信号弱记录」引用已移除设备并显示「设备已移除」徽章；没有伪造的拒绝状态。
- 房间详情与首页的上报状态优先级是 **本机 BLE 连接 > 服务端 `presence`**：同步落地的 Android 设备没有 BLE 连接，但后端 `lastSeenAt` 在 900 秒窗口内，因此显示「最近上报 X 前」；它们仍标「来自 Android，本机不可连接」且不并进「已离线」。超过窗口转「已离线 · 最近上报 X 前」，从未上报才是「从未上报读数」。读数来自服务端 `GET /readings?metric=…&limit=1`（真实链路），`lastSeenAt` / `presence` 来自 `/sync/changes`（契约 0.21.0），均不是夹具；`online` 只写「最近上报」，不宣称权威在线（见 [docs/consistency.md](docs/consistency.md) 3.28）。
- 首页底部留白实测（6.9 英寸 440×956pt）：滚到底时次卧最后两张设备卡完整位于悬浮 Tab 顶边 `873` 之上；`BottomBand` 覆盖 `873–956`（83pt，含 34pt home indicator），可访问性树在该区域内没有业务节点（见 `home-bottom.png`）。`home.png` 截于页面顶部，iOS 26/27 的悬浮玻璃 Tab 会把中段内容透出来，属于系统 Tab 样式，不是 inset 失效。
- Tab 条带遮挡（v0.25.1，本轮 6.9 英寸复测）：条带高度 `956 - 873 = 83`，铺在 Tab 之下、业务内容之上；各页面条带内除 Tab 自身按钮外没有可点到的业务节点。
- AX 最大字号下首页筛选 chip 与场景徽章已改为上下排；**v0.31.4 起设备卡在 AX 档改为单列（iPhone 紧凑横向）+ 按本段设备实测高度**，名称、状态、读数、时间多行完整，数值与单位用不换行空格绑定（`72 bpm` 不拆行），时间行按语义换行；常规字号仍为两列、最小 164pt（`home.png`）。顶部告警摘要卡与快捷场景卡（含空态）在 AX 档也改为按内容自适配高，不再被固定高度裁切。AX5 滚到底最后一张设备卡完整位于悬浮 Tab 顶边之上（`home-ax-bottom.png`），200% 同测（`home-200-bottom.png`）。房间详情的设备行已在 v0.31.1 改为自适应高度，云端读数链路在 AX 下同样生效。

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
- **场景（v0.21.0）**：服务端场景 + 仅本机手动场景，见下节。

### 场景（v0.21.0：服务端场景 + 仅本机手动场景）

**服务端场景（v0.21.0）**
- 数据源是 `GET /scenes`（本人全部场景，无分页）；`POST` / `GET` / `PUT` / `DELETE` 走服务端，跨用户与已软删统一 404。列表在「智能 → 场景」的「服务端场景」分区；本机新建 / 改名 / 停用先落 SQLite 并标「待同步」，联网后补传。
- **触发条件**：`device_offline`（设备 + 离线秒数 60–86400）、`rssi_below`（设备 + 阈值 -100–0）、`metric_threshold`（设备 + 目录声明的设备类型与指标 + `lt/lte/gt/gte` + 阈值 + 连续 1–30 条）、`schedule`（`HH:MM` + IANA 时区 + 可选 `daysOfWeek`，1=周一）。
- **动作**：1–4 个且种类不重复——`notify`（title / body）、`log`（message + `info|warn`）、`mark_device`（mark）。
- **执行**：触发条件映射到本地 `RuleEngine` / `SceneEngine`（离线、RSSI、指标连续条数），到点执行通知 / 日志 / 标记并受 `cooldownSeconds` 限制；定时触发用 `SceneScheduleCalculator.nextFire` 按 IANA 时区与 ISO 星期计算，通知使用带 `timeZone` 的日历组件重复注册，跨 DST 由系统与计算器共同保证。
- **占位符**：`notify` / `log` 文本支持 `{device}`、`{metric}`、`{value}`；缺失上下文替换为 `—`，未知占位符原样保留（见 `docs/consistency.md` 3.14）。
- **deviceMissing**：场景引用的设备不存在时，列表行标注「设备已移除」，执行时跳过该场景并写一条失败日志（冷却窗口内不重复刷日志），不级联禁用或删除场景。
- **同步与 LWW**：5 个字段各自保存 `updatedAt`，推送只发本地脏字段；服务端按字段比较时间戳，因此两端改不同字段都会保留。首次接入把本机已有 automation 场景逐条 `POST`，成功后写回 `remoteId` 与版本；无服务端幂等键，重试时先 `GET /scenes` 用内容签名认领孤儿场景，再决定 `POST` 还是 `PUT`。

**仅本机手动场景（v0.8.0 保留）**
- 手动场景是**真实可执行动作**的组合，只允许：连接指定设备、断开指定设备、开始后台采集、停止后台采集、静音告警 10 / 30 / 60 分钟、立即同步。
- 存于同一 `scenarios` 表（`kind='manual'`，迁移 v14 后仍默认 `sync_state='localOnly'`），**不参与云同步**，界面明确标注「仅本机场景」；编辑页说明「场景仅保存在本机，不随账号同步」。该动作集合无法无损映射到服务端 3 类动作，因此不做静默改写或上传。
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
- 数据来自 `GET /api/v1/catalog/device-types`（类型 / GATT / 指标 / 限制 / 兼容性）+ 逐个 `GET /api/v1/device-types/{type}/catalog`（仅取固件与配件）；目录有本地缓存时先渲染缓存再异步刷新，单个 catalog 失败降级为型号信息，全部失败显示错误空状态 + 重试。
- 详情页 GATT / 特征由代码动态组装；兼容性来自 catalog 的 `compatibility` 对象（0.3.2），按「平台 / 协议 / 特性 / 最低 App / 型号」摊平展示。

### 市场 Market（`Modules/Market`）
- 兼容性查询 / 选购指南 / 服务入口：机型画像来自目录的 `gattServices` / `metrics` / `limitations` / `compatibility`，指标按 `characteristicUuid` 与本地解析器对齐并标注「当前版本不支持」；配件与固件仍由各型号 `GET /api/v1/device-types/{type}/catalog` 聚合。
- **筛选**：顶部「厂商：全部/xx」与「兼容性：全部/xx」两个入口，取值直接来自服务端真实字段（`vendor`、`compatibility` 展开的平台 / 协议 / 特性 / 型号），不造假分类；可叠加、可一键清除，无结果显示「没有符合筛选条件的条目」。
- 页脚明确声明：**不提供下单、订单或支付**。

### 我的 Profile（`Modules/Profile`）
- 蓝牙授权与开关状态自检，跳转系统设置。
- 本地扫描日志列表、计数与清空。
- **同步状态**：上次同步时间、待同步条数、「立即同步」按钮、匿名账号；失败时展示错误码与降级说明，冲突时提示「另一台设备改过这条」。
- **登录失效（401）**：token 过期时显示「登录已失效」，出现「重新登录」入口；确认弹窗说明旧账号云端数据不自动合并、本机设备会重新同步，确认后才换新匿名账号（游标重置为 0）。未确认前前后台自动同步不会静默建号，见 `docs/troubleshooting.md` 第 3.1 节。
- **家庭管理（v0.14.0）**：「我的 → 家庭管理」展示当前家庭与角色、成员列表（owner / member、账号类型）、房间数量；支持创建家庭、生成 8 位一次性邀请码（服务端 `expiresAt` 倒计时、复制、过期后重新生成）、输入邀请码加入（复用 8 位输入规范化与 404 / 429 文案）；member 的写入口隐藏并给出只读说明。
- 基础设置：自动记录最近设备、启动自动扫描、**后台采集**（v0.7.0，默认开启并说明耗电；关闭后进入后台立即断开连接，状态实时显示）。
- **账号与数据（v0.7.0，v0.20.0 重做删除与导出）**：迁移到新设备（8 位一次性接管码、真实倒计时、复制/重新生成）、从旧设备接管（自动大写/过滤易混字符、404 统一提示、429 按 `Retry-After` 冷却）；「我的」新增独立「账号与数据」区域，两个入口均说明后果：
  - **导出我的数据**：`POST /me/export` 创建异步任务，界面展示「创建 / 处理中 / 下载中 / 刷新链接」；轮询 2.5s 起、×1.4、封顶 5s；ready 后用一次性链接下载（不带 Bearer）→ 临时 JSON 文件 → `UIActivityViewController`，分享关闭即删；410 自动重新查询任务换新链接并提示「下载链接已刷新」，只自动重试一次。
  - **删除账号**：申请 10 分钟一次性令牌 → 二次确认写明「设备、读数、场景、家庭关系、反馈都会被删除且不可恢复」→ `DELETE /me` 仅带 `X-Deletion-Token`；409 提示「请先转让所有权或移除成员」并提供跳转家庭页与「重试删除」（同一令牌可用）；403 提示重新申请；404 视为已删除并回到未登录态；网络失败保留可重试状态，不中途踢回首页。成功后断 BLE → 清 Keychain → 清全部业务表（含 v13 `device_catalog_cache`、`feedback_drafts`、`scenarios`）→ 清同步元数据 / `URLCache` / 导出临时文件 → 通知重建五个 Tab，重启不复活。
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
- 契约联调：`scripts/e2e-contract.sh` 直连本地 Go 服务，覆盖双平台推送、`catalog/device-types`（匿名 200 / `ETag` / 条件请求 304）与 `{type}/catalog`（含 vendor/compatibility）、复合键详情、UserDevice 新字段与 null 降级、别名/广播名分离、group 三态、幂等重放、LWW 冲突、401/404；**v0.14.0 起新增家庭链路**（创建家庭 → 邀请码 → 第二账号领取 → 成员可见设备 → member 改房间 403 → 跨家庭 404 → 设备归属三态 → 删除家庭级联）；已纳入 GitHub Actions `e2e-contract` job（见 4.2）。

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
codemagicTests/             # 402 个 XCTest 用例（设计令牌审计 / 场景执行 / 场景同步与 LWW / 定时 DST / 迁移 v14 / 家庭与邀请码 / 黄金读数 / 图表几何 / 节流退避 / 通知 / 删除令牌与异步导出 / 接管码 / 后台推送 / 首启持久化与术语审计）
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
- 本地 Go 服务需 **v0.18.0**（openapi 0.14.0），提供 `/api/v1/catalog/device-types`（目录唯一来源，支持 `ETag` / 304）、`/api/v1/device-types/{type}/catalog`（固件 / 配件）、`/api/v1/my/devices/{platform}/{externalId}`，并在 `UserDevice` / catalog 固件与配件上提供 `advertisedName` / `deviceType` / `vendor` / `firmwareVersion` / `compatibility`；iOS 已全部切换，不再请求 `api/products` / `api/market` / `api/device/{uuid}`；见 `docs/consistency.md` 第 3.4 节。

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
- 读数断言（第 7 节）采用**能力门控**：探针 `GET .../readings/summary` 返回 404（后端尚未发布 readings）时输出 `[SKIP]` 且不计通过；后端上线后自动执行真实断言。本地 agent 以 `RATE_LIMIT_PER_MINUTE=0` / `PAIRING_CLAIM_RATE_PER_MINUTE=0` 启动 fixture 服务，避免 ~120 次请求与多次邀请码领取触发 429。

本机 2026-11-06 实际运行（后端 `PJGoIoT` v0.22.0 干净 worktree `/tmp/pjgoiot-v022`，端口 18080）：

```
[e2e] health 200
[1. 匿名登录]
[2. 双平台推送（ios + android 同一台设备）]
[3. changes 拉回校验 platform / externalId]
[3.4 设备类型目录 /catalog/device-types（公开只读 + ETag/304）]
[3.5 device-types/catalog 与 my/devices/{platform}/{externalId}]
[3.6 UserDevice deviceType/vendor/compatibility 与 null 降级]
[3.7 advertisedName / alias 隔离与 group 三态]
[4. 同 Idempotency-Key 重放]
[5. LWW 冲突：旧版本不静默覆盖新版本]
[6. 无 token 401 / 跨用户 404]
[7. 设备读数 readings（推送 / 倒序 / summary / 重复 id / NaN）]
[8. 账号：配对码接管 / 异步导出 / 删除令牌注销]
[9. 家庭：创建 / 邀请码 / 成员可见设备 / 403 与跨家庭 404]
[10. 反馈：提交 / 幂等重放 / 冲突 / 我的列表]
[11. 场景：CRUD / 字段级 LWW / deviceMissing / 软删与 change_log]

=== E2E 合同联调结果 ===
通过：430 项，跳过：0 项，失败：0 项
结论：PASS
```

> 读数一节断言：推送 3 条 → `appliedReadings=3` / `skippedReadings=0`；`GET readings` 返回 3 条且按 `recordedAt` 倒序；`summary` 的 count/min/max/avg/last/unit/window 全部正确；重复 id 再推返回 200、`appliedReadings=0`、`skippedReadings=3`；`value="NaN"` 返回 400。v0.5.0 新增：追加 2 条温度读数后 `series` 按 `1m` 返回、桶按 `start` 升序、`count` 合计 3、每桶 `min ≤ avg ≤ max`；空区间返回 `buckets: []`；非法 `bucket=5m` 返回 400 `BAD_REQUEST`；`metrics` 按 `lastAt` 倒序、温度在首位、心率 `count=3`/`unit=bpm`。3.5 / 3.6 / 3.7 断言含义同前（固件 vendor/compatibility、未注册型号 null 降级、别名与广播名隔离、group 三态）；第 11 节覆盖 v0.21.0 服务端场景 CRUD / LWW / `deviceMissing` / 软删。
>
> **项数稳定性（v0.23.0）**：导出轮询的两条断言已从循环内移到循环外，任意轮询轮次都固定 2 条，因此本机与 CI 都是 **430**。定位过程与 diff 结论见 [docs/consistency.md](docs/consistency.md)。

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

迁移：`PRAGMA user_version` 线性递增。v1 建五张表；**v2（v0.2.0）** 为 `saved_devices` 增加 `platform`（默认 `ios`）与 `external_id`，由 `peripheral_id` 大写回填，并建立 `(platform, external_id) WHERE deleted_at IS NULL` 唯一索引；**v3（v0.3.3）** 增加 `device_type TEXT`（可空，旧库升级后为 `NULL`，由云端详情回填）；**v4（v0.3.6）** 增加 `advertised_name TEXT`（由历史 `name` 回填广播名）与 `alias_patch` / `advertised_name_patch` / `group_patch`（`absent` / `clear` / `set` 三态）；**v5（v0.4.0）** 新增 `readings` 表（`id` 主键、`device_id`、`metric`、`value`、`unit`、`recorded_at`、`sync_state`），并按 `(device_id, metric, recorded_at DESC)` 建索引，支撑最近 60 点查询与 7 天清理；**v6（v0.8.0）** 新增本地 `scenarios` 表（`id` / `name` / `actions` JSON / `created_at` / `updated_at`），**不含 `sync_state` / `deleted_at` / `platform` / `external_id`，不参与同步**；**v8（v0.13.0）** 新增本地 `rooms` 表（`id` / `name` / `sort_order` / `remote_id` / `created_at` / `updated_at`）并为 `saved_devices` 增加可空 `room_id`（NULL = 未分配），原 `group_name` 保留为兼容字段；**v9（v0.14.0）** 新增 `households`（`id` / `remote_id` / `name` / `is_personal` / `role`）与 `device_assignment_pending`，`rooms` 启用 `remote_id` 并增加 `household_id` / `sync_state` / `deleted`（离线墓碑），`saved_devices` 增加 `household_id` / `remote_room_id` / `remote_household_id`；全部条件 ALTER，旧库升级后无需重装或清数据，房间与归属不丢；**v14（v0.21.0）** 为 `scenarios` 增加 `kind`（`manual` / `automation`）、`remote_id`、`version`、`enabled`、`cooldown_seconds`、`trigger`、`sync_state`、`deleted_at`、`device_missing`、`last_synced_at`、`last_run_at` 与 5 个字段级时间戳（`name/enabled/cooldown/trigger/actions_updated_at`），并按 `remote_id` 建唯一索引；旧行保留为 `kind='manual'`、`sync_state='localOnly'`，缺失 `scenarios` 表的旧库直接建完整表（`PRAGMA table_info` 判列，可重复执行）。

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

### 7.4 账号（v0.20.0，契约对齐 PJGoIoT v0.19.0 / openapi 0.15.0）

| 接口 | 方法 | 说明 |
| --- | --- | --- |
| `/api/v1/auth/anonymous` | `POST` | 返回 `{userId, token, expiresAt}`；token 默认 180 天 TTL |
| `/api/v1/auth/pairing-code` | `POST` | Bearer；返回 `{code, expiresAt}`；8 位、10 分钟、一次性；重新生成使旧码失效 |
| `/api/v1/auth/pairing-code/claim` | `POST` | Body `{code}`，无需旧 token；返回 `{userId, token, expiresAt}`；404 统一「码无效或已过期」；429 带 `Retry-After` |
| `/api/v1/me/deletion-request` | `POST` | Bearer；201 `{token, expiresAt}`；令牌 10 分钟、只存哈希；再次申请作废旧令牌 |
| `/api/v1/me` | `DELETE` | **仅 `X-Deletion-Token`，无 Bearer**；204；缺令牌 400 `DELETION_TOKEN_REQUIRED`，无效 403 `DELETION_TOKEN_INVALID`，过期 410，owner 有成员 409 `ACCOUNT_DELETION_BLOCKED` |
| `/api/v1/me/export` | `POST` | Bearer；202 `{id, status, createdAt}` 异步任务 |
| `/api/v1/me/export/{id}` | `GET` | Bearer；轮询 `pending` / `ready` / `failed`；`ready` 每次签发新的一次性 `downloadUrl`（10 分钟、覆盖旧链接） |
| `/api/v1/me/export/{id}/download?token=` | `GET` | **无 Bearer**；首次 200，重放 410 `EXPORT_DOWNLOAD_EXPIRED`，错令牌 403 `EXPORT_DOWNLOAD_INVALID` |

接管成功后客户端替换 Keychain token，保留本机设备 / 读数并全部重新标记 pending，游标清零；注销成功后的本地清理顺序与错误分流见 `docs/consistency.md` 3.11；删除令牌 / 异步导出实现见 `docs/architecture.md` 6.2。

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

### 7.7 场景（v0.21.0，契约对齐 PJGoIoT v0.20.0 / openapi 0.16.0）

| 接口 | 方法 | 说明 |
| --- | --- | --- |
| `/api/v1/scenes` | `GET` / `POST` | `GET` 一次返回本人全部场景 `{items}`，无分页；`POST` 201 返回完整场景（`id` / `version=1` / `deviceMissing`） |
| `/api/v1/scenes/{id}` | `GET` / `PUT` / `DELETE` | `GET` 读取时实时计算 `deviceMissing`；`PUT` 200 返回完整场景，body 为 5 个字段各自 `{value, updatedAt}` 的子集，按字段 LWW（无字段应用时 version 不变）；`DELETE` 204 软删，tombstone 进 `change_log` |
| `/api/v1/sync/changes` | `GET` | 新增 `entity=scene`：upsert 携带完整场景，delete 携带 `deletedAt`；未知 entity 仍忽略且游标推进 |

约束：跨用户与已软删统一 404；创建时引用的设备必须属于本人且存在（否则 400 `SCENE_DEVICE_NOT_FOUND`），设备被删后场景保留并在读取时返回 `deviceMissing=true`；触发条件 4 种、动作 1–4 个且种类不重复；无服务端幂等键，客户端以 `GET /scenes` + 内容签名认领孤儿场景后再决定 `POST` / `PUT`。占位符口径见 `docs/consistency.md` 3.19，定时计算与 DST 见 `docs/consistency.md` 3.19。契约由 `scripts/e2e-contract.sh` 第 11 节覆盖（414 项全 PASS，后端 v0.20.0 干净 worktree）。

---

## 8. 持续集成

### 8.1 GitHub Actions（已实际运行，当前主用）

[`.github/workflows/ios.yml`](.github/workflows/ios.yml)：`runs-on: macos-15`，两个并行 job；只做构建、单元测试与契约联调，不做签名 / Archive。

- 触发：**仅 push 到 `main` 与 `v*` tag**（另保留 `workflow_dispatch` 手动触发）；**PR 不跑**。
- **去重**：`concurrency: group: ios-${{ github.sha }}` + `cancel-in-progress: true`。同一提交既推 `main` 又打 tag 时只保留后到的一次运行，先到的自动取消，避免重复消耗 macOS 分钟。
- Job `build-test`：`actions/checkout@v7` → 选择 Xcode（优先 `Xcode_16.4`）并打印 `xcodebuild -version` / 可用模拟器 → `xcodebuild build`（`generic/platform=iOS Simulator`）→ `xcodebuild test`（从 `xcrun simctl list devices available` 动态取首个 iPhone 模拟器 UDID）→ `actions/upload-artifact@v7` 上传 `*.xcresult`（`if: always()`）。
- Job `e2e-contract`（与 build 并行）：`actions/checkout@v7` 拉本仓库 + `platojobs/PJGoIoT`（`repository` + `path: PJGoIoT`）→ `actions/setup-go@v7`（`go-version-file: PJGoIoT/go.mod`）→ `PJGOIOT_DIR=${{ github.workspace }}/PJGoIoT bash scripts/e2e-contract.sh`；失败时 `actions/upload-artifact@v7` 上传 `.build/e2e/` 日志。失败即红，无 `|| true`。
- 两个 job 均使用 `CODE_SIGNING_ALLOWED=NO`，不需要证书与描述文件。
- **CI 覆盖边界（必读）**：`ios.yml:84` 仍 pin `PJGoIoT` **v0.25.0**。`presence` / `lastSeenAt` 是 v0.26.0 字段，CI 的 460 项 e2e 全绿**没有命中新字段**；新字段仅在本地 v0.26.0 的 `e2e-contract`（unknown/null）与 `e2e-postgres`（online/offline）验证。修改 pin 需要 `workflow` scope，当前推送凭证没有。
- 当前真实运行：[run 42065023214](https://github.com/platojobs/codemagic/actions/runs/42065023214)（`v0.16.0` 提交 `d00d315`，tag push），**success**（Xcode 16.4）：
  - `Build & Test (iOS Simulator)` **success**，`** BUILD SUCCEEDED **` / `Executed 315 tests, with 0 failures` / `** TEST SUCCEEDED **`；
  - `E2E contract (PJGoIoT fixture)` **success**，`通过：299 项，跳过：0 项，失败：0 项` / `结论：PASS`（含家庭 v0.14.0 / v0.15.0 链路：`isSelf`、转让、结构变更 change_log、移除后可见性）；
  - 同 sha 的 `main` 运行 [run 42065001018](https://github.com/platojobs/codemagic/actions/runs/42065001018) 先被 tag 运行按 `concurrency: ios-${sha}` 取消（结论 `cancelled`），手动 `gh run rerun` 后两个 job **success**；
  - 真实 Postgres e2e（`scripts/e2e-postgres.sh`）**不进 CI**：GitHub Actions 的 macOS runner 无 Docker；本机运行 PASS，输出见 `docs/e2e-postgres.md`。
  - 全部 action 已升到 `checkout@v7` / `upload-artifact@v7` / `setup-go@v7`，**Node 20 弃用告警已消除**（仅剩 macOS arm64 队列容量提示）。
- 上一轮记录：[run 42060000856](https://github.com/platojobs/codemagic/actions/runs/42060000856)（`v0.15.0`，303 单测 / 260 项 E2E，success）；更早：[run 42047411803](https://github.com/platojobs/codemagic/actions/runs/42047411803)（`v0.14.0`，293 单测 / 224 项 E2E，success）、[run 42012100360](https://github.com/platojobs/codemagic/actions/runs/42012100360)（`v0.11.0`，260 单测 / 151 项 E2E，success）、[run 42006790396](https://github.com/platojobs/codemagic/actions/runs/42006790396)（`v0.10.0`，236 单测 / 151 项 E2E，success）、[run 41973731269](https://github.com/platojobs/codemagic/actions/runs/41973731269)（`v0.9.0` 提交 `08f88d6`，226 单测 / 151 项 E2E，success）。
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
- 契约已用本地 fixture 服务端到端验证（430 项断言 PASS，后端 `PJGoIoT` v0.22.0 / openapi 0.17.0，含家庭 v0.12.0–v0.15.0、账号删除 / 导出 v0.19.0、场景 CRUD / 字段级 LWW / `deviceMissing` v0.20.0、会话生命周期（`/auth/refresh` 滚动刷新与旧 token 立即失效 / `/sessions` / `/auth/logout`）与反馈详情关闭（409 冲突）v0.22.0 链路）；同一套件在本地真实 Postgres 栈重跑同样 PASS，并直接 `psql` 校验邀请码只存哈希、成员行清理、转让后 `owner_user_id`、删房后 `household_rooms`、`change_log` 结构实体；410 / series / metrics / export / 注销亦由 `scripts/e2e-postgres.sh` 跑通（不进 CI）。App 内的 Keychain token、BGTask 调度、后台 BLE 采集与真实网络环境仍需真机验证。
- 后端 `PJGoIoT` 已打 tag **v0.22.0**（会话生命周期 `/auth/refresh`·`/auth/logout`·`/sessions`、`SCENE_*` 错误码、导出 `failureReason`、反馈详情 / 关闭、`GET /my/devices/{mac}`，openapi 0.17.0；v0.20.0 服务端场景 CRUD / 字段级 LWW / `deviceMissing`；v0.19.0 两步删除令牌与异步导出；v0.15.0 起家庭与房间结构变更进 `change_log`）；iOS 按该契约实现。CI 显式 checkout 后端 tag `v0.22.0`（`ref: v0.22.0`），430 项 E2E 全 PASS；若 checkout 到旧后端，e2e 相关分支会明确 SKIP。
- [ ] 真机：场景本地通知的权限申请 / 拒绝降级、点击通知跳转，以及跨 DST（春季跳过 / 秋季重复）与多时区的长期触发准确性。
- [ ] 真机 + 真实后端：断网编辑场景后恢复网络的 pending 补传、字段级 LWW 在两端时钟偏移下的实际表现、设备删除后的「设备已移除」与执行跳过日志。
- [ ] 真机 + 两个真实账号：创建家庭 / 邀请码领取 / 成员共享 / member 403 / 跨家庭 404 的界面表现（服务端契约已由 E2E 覆盖，App 端需实际走查）。
- [ ] 真机：家庭切换后的首页 / 房间管理刷新、邀请码倒计时与复制、离线房间「未同步」标注。
- [ ] 真机 + 两个真实账号：成员行「转让所有权 / 移除成员」的互斥与本人行隐藏、二次确认文案、转让后角色与入口即时更新、403 / 404 / 409 提示与刷新。
- [ ] 真机 + 真实后端：断网 90 天以上游标（改库 + cleanup 构造 410）后的自动全量重同步、pending 保留与 UI 提示。
- [ ] 真机 + 真实后端：503 `TIMEOUT` 的「服务端繁忙，稍后重试」与退避闸门（手动同步可立即重试）。
- [ ] 真机：token 过期后的「登录已失效」与「会话到期日」展示、接管 / 注销后的更新与清除。
- Release 签名与 App Store 上架未验证（无 Apple 开发者账号 / 证书）。

---

## 10. 版本记录

- `v0.22.0`：会话生命周期接通（`MARKETING_VERSION 0.22.0` / build 30，tag `v0.22.0`）。所有带 Bearer 的请求共用 `AuthenticatedHTTPClient`：401 先比对请求 token 与本地当前 token，不同则直接重放；相同才发 `POST /auth/refresh`，并发 401 挂在同一次刷新上（单飞），成功后 `SecItemUpdate` 原子写回 Keychain 再唤醒等待方。**只有刷新返回 401 才进入「需要重新登录」**，且只清失效 token，本地设备 / 读数 / 家庭 / 场景全部保留，绝不静默新建匿名账号；网络或 5xx 失败保留会话并标为可重试；重新登录可走「配对码恢复原账号」或显式「以新匿名账号继续」。新增「登录会话」区：`GET /sessions` 标出当前会话、`DELETE /sessions/{id}` 单独吊销、`POST /auth/logout` 退出当前会话，退出登录与删除账号明确区分。`APIErrorCatalog` 映射 6 个 `SCENE_*` 错误码；网络与 5xx 可重试、**4xx 一律终态**、429 按 `Retry-After`（缺失回退响应体）单独退避；导出解析 `failureReason` 并展示服务端原因；反馈详情 `GET /feedback/{id}` 展示状态 / `statusMessage`、本人可 `PATCH /feedback/{id}` 关闭，已关闭再改 409 给明确文案；单设备详情按平台路由（Android → `GET /my/devices/{mac}`，iOS → `platform/externalId`）。修正 `GET /scenes` 实为 `{"items":[...]}` 的解码问题。新增单测 13 个（共 **415** 个，0 失败），E2E **430** 项全 PASS（fixture，后端 v0.22.0 干净 worktree）；后端 `PJGoIoT` v0.22.0（openapi 0.17.0）。
- `v0.21.0`：场景接入服务端（`MARKETING_VERSION 0.21.0` / build 29，tag `v0.21.0`）。`GET /scenes` 作为基线，`POST` / `GET` / `PUT`（`name` / `enabled` / `cooldownSeconds` / `trigger` / `actions` 五字段 LWW）/ `DELETE`（204 软删）接入；`change_log` 的 `scene` 实体走现有 upsert / delete，未知 entity 仍忽略并推进游标。SQLite 迁移 **v14** 为 `scenarios` 增加 `kind` / `remote_id` / `version` / 字段级时间戳 / `sync_state` / `deleted_at` / `device_missing` 等列，旧手动场景保留为「仅本机」；首次接入逐条上传并写回 `remoteId`，离线编辑 pending 补传，重试先查基线认领孤儿避免重复创建。服务端场景由本地引擎执行：离线 / RSSI / 指标连续条数映射现有判定，定时按 IANA 时区与 ISO `daysOfWeek` 计算下一次触发（含跨 DST），通知文本支持 `{device}` / `{metric}` / `{value}`。`deviceMissing` 在列表标注「设备已移除」，执行时跳过并写失败日志。新增单测 38 个（共 **402** 个，0 失败），E2E **414** 项全 PASS（fixture，后端 v0.20.0 干净 worktree）；后端 `PJGoIoT` v0.20.0（openapi 0.16.0）。
- `v0.20.0`：账号删除两步令牌 + 异步数据导出（`MARKETING_VERSION 0.20.0` / build 28，tag `v0.20.0`）。「我的」新增独立「账号与数据」区域：**导出**改为 `POST /me/export`（202 异步任务）→ 轮询 `GET /me/export/{id}`（2.5s 起 ×1.4 封顶 5s）→ ready 后一次性链接下载（无 Bearer）→ 临时文件 + `UIActivityViewController`，分享关闭即删；410 自动重新查询任务换新链接并提示，只自动重试一次。**删除**改为 `POST /me/deletion-request` 取得 10 分钟一次性令牌 → 二次确认（写明设备 / 读数 / 场景 / 家庭关系 / 反馈永久删除）→ `DELETE /me` 仅带 `X-Deletion-Token`；409 如实提示「请先转让所有权或移除成员」并给家庭页入口与同一令牌重试，403 提示重新申请，404 视为已删除，网络失败保留可重试状态。成功后断 BLE → 清 Keychain → 清 9 张业务表（含 v13 `device_catalog_cache`、`feedback_drafts`、`scenarios`）→ 清同步元数据 / `URLCache` / 导出临时文件 → `.accountDeleted` 通知重建五个 Tab，重启不复活。新增单测 8 个（共 **364** 个，0 失败），E2E **367** 项全 PASS（fixture，后端 v0.19.0 干净 worktree）；后端 `PJGoIoT` v0.19.0（openapi 0.15.0）。
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
