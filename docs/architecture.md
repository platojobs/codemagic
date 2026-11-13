# iOS 工程架构说明

本文件说明 `codemagic` 的目录结构、分层约定、数据流、持久化与 UI 构建方式。行为口径（五模块命名、字段、错误码、空状态）见 [consistency.md](consistency.md)。

## 1. 基本信息

| 项目 | 取值 |
| --- | --- |
| 语言 | Swift 5 |
| UI | UIKit，纯代码（无 Storyboard / XIB） |
| 最低版本 | iOS 15.0 |
| 依赖 | 无第三方依赖（SQLite3 由系统提供，`OTHER_LDFLAGS = -lsqlite3`） |
| 工程 | `codemagic.xcodeproj`，两个 target：`codemagic` / `codemagicTests` |
| 本地验证 | Xcode 27.2、iPhone 17 模拟器（iOS 27.x） |

## 2. 目录结构

```
codemagic/
├── App/                        # 应用入口与组合根
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift     # 纯代码 UIWindow → MainTabBarController
│   ├── AppEnvironment.swift    # 数据库、Store、网络、蓝牙的唯一组装点
│   ├── SyncCoordinator.swift   # BGAppRefreshTask 注册、前后台触发同步
│   └── MainTabBarController.swift # 五个 Tab：首页/设备/产品/市场/我的
├── Core/
│   ├── Models/                 # 领域模型（Codable，宽松解析）
│   ├── Networking/             # APIConfiguration / HTTPClient / ProductAPIClient / ReadingsAPIClient / AppError
│   ├── Persistence/            # SQLiteDatabase 与各 Store（含 ReadingsStore）
│   ├── Readings/               # ReadingParser（四特征独立解析）+ ReadingsIngestor
│   ├── Sync/                   # SyncEngine / SyncAPIClient / SyncModels / KeychainTokenStore / SyncMetadataStore
│   ├── Account/                # AccountAPIClient（配对 / 删除令牌 / 异步导出）、AccountDeletionService、AccountExportService
│   ├── Bluetooth/              # CoreBluetoothService（扫描 / 连接 / 授权 / notify 订阅）
│   ├── Rules/                  # RuleEvaluator（断开 / RSSI 阈值）
│   └── Formatting/             # 时间与 RSSI 格式化
├── DesignSystem/               # 主题、自绘 RSSI、代码组装空状态、Loading、图标名
├── Modules/
│   ├── Home/                   # Scenes / ViewModels / Views
│   ├── Devices/                # 设备列表、规则编辑、设备详情（含读数图表）
│   ├── Products/               # 型号库与详情
│   ├── Market/                 # 配件与固件信息
│   └── Profile/                # 权限自检、扫描日志、设置、关于
└── Resources/                  # Info.plist、Assets.xcassets
Config/
├── Debug.xcconfig              # BASE_URL → 本地 Go 服务
└── Release.xcconfig            # BASE_URL → 线上（当前为与 Android 共用的 mock）
codemagicTests/                 # XCTest 单元测试（402 个用例）
scripts/                        # e2e-contract.sh + 独立 Swift 联调 runner（CI 的 e2e-contract job 复用）
docs/
├── architecture.md             # 本文件
└── consistency.md              # Android/iOS 共用行为说明
```

Xcode 16+ 的 file-system synchronized group 已开启：在 `codemagic/` 与 `codemagicTests/` 下新增 Swift 文件会自动加入 target，无需手动改 `project.pbxproj`。

## 3. 分层约定

| 层 | 职责 | 依赖方向 |
| --- | --- | --- |
| `App` | 生命周期、组合根、Tab 装配 | 依赖 Modules、Core |
| `Scenes`（ViewController） | 布局、导航、列表刷新、弹窗；不直接访问数据库/URLSession | 依赖 ViewModels、DesignSystem |
| `ViewModels` | 状态机与业务编排；回调 `onChange` 驱动界面 | 依赖 Models、Persistence、Networking、Bluetooth |
| `Views`（Cell/子视图） | 纯展示，`configure(model:)` 注入数据 | 依赖 Models、DesignSystem |
| `DesignSystem` | 颜色、字体、间距、复用组件与自绘控件 | 无业务依赖 |
| `Core/Services` | 蓝牙、网络、规则评估 | 依赖 Models、Persistence |
| `Core/Persistence` | SQLite 封装与各表 Store | 依赖 Models |
| `Models` | 纯数据 | 无 |

数据流示例（首页）：

```
CoreBluetoothService.discoveryHandler
  → HomeViewModel.handleDiscovery
      → RecentDeviceStore.upsert（本地最近设备）
      → SavedDeviceStore.upsert（更新 lastSeenAt/updatedAt/syncState）
      → RuleEvaluator.evaluate（断开 / RSSI 阈值）
      → rows 变更 → onChange → HomeViewController.reload
```

所有 ViewModel 回调最终在 `DispatchQueue.main` 上刷新 UI（网络层显式切主队列）。

## 4. 纯代码 UI 的两个代表

| 组件 | 位置 | 说明 |
| --- | --- | --- |
| `RSISignalView` | `DesignSystem/RSISignalView.swift` | 自绘 `UIView`。`draw(_:)` 画 4 根圆角信号柱；分档阈值以 `PKotlinApp/docs/rssi-signal-tiers.md` 为唯一真源（`Tier` + `tier(for:)`），未知与极弱均为 0 格但文案区分，非负占位值按未知处理；带 accessibilityLabel。 |
| `EmptyStateView` | `DesignSystem/EmptyStateView.swift` | 完全由代码组装 `UIStackView + UIImageView + UILabel + UIButton`，`configure(...)` 支持可选按钮，被首页、设备、产品、市场、日志页复用。 |

两者不使用 XIB / Storyboard，也不使用 iOS 16+ 的 `ContentUnavailableView`。

## 5. 蓝牙

`CoreBluetoothService`（`Core/Bluetooth/CoreBluetoothService.swift`）：

- `CBCentralManager` 固定在主队列创建；首次使用触发系统蓝牙授权（iOS 13+ 流程）。
- 扫描 `scanForPeripherals(withServices: nil, options: [CBCentralScanOptionAllowDuplicatesKey: true])`。
- RSSI 节流：同一设备 RSSI 变化超过 ±2 dBm 或距上次上报超过 3s 才回调，降低列表刷新频率。
- `connect(peripheralID:)` 超时 12s；连接 / 断开 / 失败通过 `connectionHandler` 上报。
- 授权状态映射为 `BluetoothAuthorization`（allowed / notDetermined / denied / restricted / unknown）。
- 状态映射为 `BluetoothState`（unknown / unsupported / unauthorized / poweredOff / poweredOn / resetting）。
- 读数订阅（v0.4.0）：`startReading(peripheralID:)` → `discoverServices(nil)` → 逐个服务发现特征，命中 `0x2A37` / `0x2A19` / `0x2A6E` / NUS TX `6E400003-…` 且支持 notify 时 `setNotifyValue(true)`；`didUpdateValueFor` 把原始 `Data` 封装为 `BluetoothReadingSample` 交给 `readingHandler`。不限定服务 UUID，兼容把 NUS 放在自定义服务下的设备。

读数链路：

```
CoreBluetoothService.readingHandler
  → ReadingsIngestor.ingest(sample)
      ├─ ReadingParser.parse：四特征独立解析；失败写 ScanLog（category=reading）并丢弃
      ├─ SavedDeviceStore.fetch(peripheralID:)：未保存设备丢弃并记日志
      └─ ReadingsStore.insert：id 为客户端 UUID，sync_state=pending；onSaved(deviceID)
          → DeviceDetailViewModel.reloadReadings（主线程刷新图表）
```

保留策略：启动时 `ReadingsStore.prune(olderThan: now-7d)`；`SyncEngine` 每次 push 全部成功后再次 prune。只删除已同步的过期读数，未上传读数保留到补传完成。

模拟器没有真实蓝牙，状态为 `unsupported`，页面显示对应空状态；真实扫描、连接与授权弹窗需真机验证。

## 6. 网络

- `APIConfiguration` 从 `Info.plist` 读取 `BASE_URL`（由 xcconfig 注入），校验 scheme 与 host，源码不含地址。
- `URLSessionHTTPClient`：15s 超时、`ephemeral` 配置、`reloadIgnoringLocalCacheData`；非 2xx → `AppError.server`。
- `ProductAPIClient`：`GET /api/v1/catalog/device-types`（设备类型目录，类型 / GATT / 指标 / 限制 / 兼容性）+ `GET /api/v1/device-types/{type}/catalog`（仅固件 / 配件）、`GET /api/v1/my/devices/ios/{externalId}`（设备详情，Bearer token）；`DeviceCatalogClient` 负责 `If-None-Match` / `If-Modified-Since` 条件请求、304 复用与 SQLite 缓存兜底。Codable 宽松解码，兼容缺失字段。0.3.2 起解析 `UserDevice` 的 `deviceType` / `vendor` / `firmwareVersion` / `compatibility` 与 catalog 固件 / 配件的 `vendor` / `compatibility`，`null` / 缺失 / 空串统一归一为 `nil`；0.3.3 起解析 `advertisedName`，可选字段缺省时按 absent 处理。
- `CompatibilityInfo`（`Core/Models/DeviceCatalog.swift`）：动态 key 解码，`displayItems` 供展示、`filterTags` 供市场筛选（`deviceTypes` 显示为「型号」）。
- `ReadingsAPIClient`（v0.4.0）：`GET .../readings`（`ReadingsPage`）与 `GET .../readings/summary`（`ReadingSummary`）；设备详情优先展示云端 24h 汇总，失败回退本地计算并标注「离线：本地数据」。折线与记录列表始终读本地 SQLite（7 天内）。
- `AppError` 统一错误码：`NET-001` / `NET-002` / `NET-003` / `NET-004` / `DB-001` / `BT-004` / `SYNC-001`。

### 6.1 同步（v0.2.0 起）

```
场景回到前台 → SyncCoordinator.syncOnForeground（120s 节流）
场景进入后台 → BGAppRefreshTask(com.platojobs.codemagic.sync)
「我的」立即同步 → SyncEngine.sync

SyncEngine
  ├─ ensureSession：Keychain 有 token 则复用，否则 POST /auth/anonymous → 写 Keychain
  │    例外：reloginRequired（登录已失效待确认）时失败返回，禁止静默建号
  ├─ relogin：清 token + 游标归零 + 本地设备全部置 pending → 新建匿名账号 → 重跑下面的 pull/push
  ├─ pull：GET /sync/changes(cursor, limit=200) 循环 hasMore（≤10 页）
  │    └─ apply：本地无 → 插入 synced；本地已同步 → 云端覆盖；
  │              本地 pending 且云端更新 → 云端获胜 + 提示「另一台设备改过这条」
  └─ push：fetchPending（设备 ≤100/批 + 读数 ≤200/批，按 id 排序）
       ├─ Idempotency-Key = SHA-256(设备字段 + 读数内容) → 失败重试复用
       ├─ 成功 → markSynced（设备 + 读数）；conflicts → 写回云端版本 + 提示
       ├─ appliedReadings / skippedReadings 汇总进「我的」同步结果
       ├─ 全部成功 → prune 7 天前的已同步读数
       └─ tombstone（deleted: true）同样走推送
```

- token 仅存 Keychain；游标 / userId / clientId 存 UserDefaults（非凭据）。
- 同步状态通过 `SyncEngine.onChange` 推给「我的」页，失败时保留 pending 并展示错误码与降级说明。
- 401：`AppError.isUnauthorized` → `metadata.reloginRequired = true`，「我的」页展示「登录已失效」与「重新登录」；用户确认后才换号（旧账号数据不合并），否则前后台自动同步直接失败，不会静默建号。
- 后台任务标识 `com.platojobs.codemagic.sync` 已在 `Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` 声明。
- 契约联调：`scripts/e2e-contract.sh` 启动本地 `PJGoIoT`（`STORE=fixture`）并运行独立 Swift runner，真实网络覆盖匿名登录、双平台推送、`catalog/device-types`（200 + `ETag` + 304）与 `{type}/catalog`（含 `vendor` / `compatibility`）、复合键详情、`UserDevice` 新字段与 null 降级、别名/广播名分离、group 三态、幂等重放、LWW 冲突与 401/404；已接入 GitHub Actions `e2e-contract` job。
- 产品 / 市场 / 详情：`ProductAPIClient` 以 `catalog/device-types` 为目录唯一事实源，`{type}/catalog` 只补充固件与配件，设备详情使用 `my/devices/ios/{externalId}` 复合键，不依赖 MAC。
- 市场筛选：`MarketViewModel` 维护 `allItems` + `selectedVendor` / `selectedCompatibility`，选项由 `item.vendor` 与 `item.compatibilityTags` 去重排序得到；`dropInvalidFilters` 在刷新后清除已失效的筛选值。
- 跨平台设备：`SavedDevice.isConnectable` 仅在 `platform == "ios"` 时为真；Android 设备在列表标注不可连接并禁用入口。

### 6.2 账号删除与数据导出（v0.20.0）

```
「我的 → 账号与数据」
  ├─ 导出：POST /me/export(202) → 轮询 GET /me/export/{id}（2.5s 起 ×1.4 封顶 5s）
  │      → ready: downloadUrl(一次性, 10 分钟) → GET download（无 Bearer）
  │      → 410：重新 GET 任务换新链接，只重试一次并提示「链接已刷新」
  │      → 临时文件 → UIActivityViewController → 关闭即删
  └─ 删除：POST /me/deletion-request(Bearer) → {token, expiresAt}
         → 二次确认（设备/读数/场景/家庭关系/反馈将永久删除）
         → DELETE /me（仅 X-Deletion-Token，无 Authorization）
         → 204：断 BLE → Keychain → 业务表（含 v13 目录缓存 / 反馈草稿 / 场景）
                → 同步元数据 → URLCache → 导出临时文件 → 通知重建 Tab
         → 409：保留令牌，提示「先转让所有权或移除成员」+ 家庭页入口
         → 403：提示重新申请；404：视为已删除，仍执行本地清空
```

- 删除令牌与 Bearer 分离：`DELETE /me` 明确不带 `Authorization`，避免服务端用旧 Bearer 走其他分支；令牌重放得到 404 而不是 401。
- 409 不消耗令牌，界面保留同一个 `DeletionChallenge` 供「重试」；转让所有权后无需重新申请。
- 本地清理顺序先断 BLE，再单事务清业务表，避免清理后 notify 继续写回读数；`.accountDeleted` 通知让 `MainTabBarController` 重建五个 Tab，清除内存中的旧设备与读数。
- 导出轮询采用退避而非每秒请求；`AccountExportService.cancel()` 用 generation 标记让旧回调失效，避免取消后仍弹分享。

### 6.3 场景同步与执行（v0.21.0）

```
SyncEngine.runSync
  ├─ prepareScenes：GET /scenes 基线 → 逐条 applyRemote；基线缺失的已同步场景软删
  ├─ pull：change_log 的 entity=scene → SceneSyncService.apply（upsert / delete tombstone）
  ├─ pushScenes：SceneStore.fetchPending 串行
  │    ├─ pendingDelete + remoteId → DELETE /scenes/{id}
  │    ├─ remoteId 为空 →（必要时先 GET /scenes 按内容签名认领孤儿）→ POST /scenes
  │    └─ remoteId 非空 → PUT 只含脏字段（5 字段各自 {value, updatedAt}）
  └─ 场景数累加进同步结果；失败保留 pending，不阻断设备主链路
```

- **本地表**：`scenarios` 用 `kind` 区分 `manual`（v0.8.0 手动动作组，不上传）与 `automation`（服务端场景）；`remoteId` / `version` / `syncState` / `deletedAt` / `deviceMissing` / 5 个字段级时间戳由 `SceneStore` 单点维护。
- **LWW**：保存时只推进被编辑字段的 `updatedAt`；推送只发 `fieldUpdatedAt > lastSyncedAt` 的字段；拉取 pending 场景时脏字段保留本地、其余采用远端，非脏字段时间戳回落到旧同步基线，避免时钟超前导致反复推送。
- **幂等**：服务端无幂等键；`remoteId` 为空时先拉基线，用 `name/enabled/cooldown/trigger/actions` 排序 JSON 的内容签名唯一匹配并认领，再决定 `POST` 还是 `PUT`。
- **执行**：`SceneEngine` 复用 `SavedDeviceStore` / `ScanLogStore` / `ReadingsIngestor`：
  - `evaluateScans` 处理 `device_offline` / `rssi_below`（状态机避免重复触发），`evaluateReadings` 处理 `metric_threshold` 的连续条数；
  - `fire` 统一检查 `enabled` / 软删 / 冷却，执行 `notify`（本地通知）/ `log`（扫描日志）/ `mark_device`（标记日志），最后写 `lastRunAt`；
  - 设备按 `(platform, externalId)` 解析，找不到即 `deviceMissing`：列表标注、执行跳过并写失败日志，不级联禁用。
- **定时**：`SceneScheduleCalculator` 用 IANA `timeZone` + `Calendar.nextDate(.nextTime, .first)` 计算下一次触发（ISO 星期映射到 Calendar weekday），`SceneScheduler` 以带 `timeZone` 的重复日历组件注册通知，跨 DST 不漂移。
- **占位符**：`SceneTemplate.render` 在提交通知 / 日志前替换 `{device}` / `{metric}` / `{value}`，缺失为 `—`，未知原样保留。

## 7. 持久化（SQLite）

选型理由：同步字段（`id / updatedAt / deletedAt / syncState`）需要逐列控制；schema 以 SQL 明示，便于与 Android Room 表逐列对照；不依赖 `.xcdatamodeld` 编辑器，CI 与代码评审都更直接。

- 数据库文件：`Application Support/com.platojobs.codemagic/codemagic.sqlite`。
- 打开参数：`READWRITE | CREATE | FULLMUTEX`；迁移使用 `PRAGMA user_version`，多语句脚本用 `sqlite3_exec`。
- 所有读写串行在一个专用队列；软删除保留行以便后续同步。
- 迁移版本：v1 建五张表；v2（v0.2.0）给 `saved_devices` 增加 `platform` / `external_id`，并由 `peripheral_id` 大写回填；v3（v0.3.3）增加 `device_type TEXT`（可空，供 `PushDevice` 使用）；**v4（v0.3.6）** 增加 `advertised_name TEXT`（由历史 `name` 回填广播名）与 `alias_patch` / `advertised_name_patch` / `group_patch`（`absent` / `clear` / `set`），后者在 `markSynced` 成功后归零；**v14（v0.21.0）** 给 `scenarios` 增加 `kind` / `remote_id` / `version` / `enabled` / `cooldown_seconds` / `trigger` / `sync_state` / `deleted_at` / `device_missing` / `last_synced_at` / `last_run_at` 与 5 个字段级时间戳，`PRAGMA table_info` 判列后条件 ALTER，缺失该表的旧库直接建完整表；旧行保持 `kind='manual'`、`sync_state='localOnly'`。
- 名称语义：`advertised_name` 由扫描写入，`remark`（用户别名）由编辑写入，互不覆盖；展示名回落顺序 alias → advertisedName → deviceType。`PushDevice` 用 `Patch<String>` 三态编码，absent 省略键、clear 编 `""`；幂等键取规范化 JSON，absent 字段不参与哈希。
- 5 张表：`saved_devices`、`rules`、`scan_logs`、`recent_devices`、`device_info_cache`。
- 磁盘库打开失败时回退 `:memory:`，应用仍可启动，「我的」页显示 `DB-001` 启动提示。

## 8. 本地规则

`RuleEvaluator` 是无状态的纯逻辑类（状态保存在实例内，扫描开始时 `reset()`）：

- **断开**：上一轮出现的设备本轮消失时触发一次。
- **RSSI 阈值**：`rssi <= threshold` 触发一次，恢复后重新武装。
- 规则可绑定具体设备，也可对所有已保存设备生效；停用规则不触发。
- 触发结果写 `scan_logs`（category = rule），首页展示最近一条提示。

## 9. 扩展新模块

1. 在 `Modules/<Feature>/` 下建 `Scenes/`、`ViewModels/`、`Views/` 三个目录，命名沿用现有风格。
2. ViewModel 通过构造器注入依赖，使用 `private(set)` 状态 + `onChange` 回调，不直接引用 `AppEnvironment.shared`。
3. 若需要新表：在 `SQLiteDatabase.migrate()` 增加迁移版本与 `CREATE TABLE`，再写对应 Store。
4. 页面骨架用 `UITableView` / `UIStackView` 纯代码搭建；空状态统一用 `EmptyStateView`。
5. 在 `MainTabBarController` 或所属模块的导航处装配，并在 `docs/consistency.md` 第 1 节登记。
6. 为 ViewModel 与解析逻辑补 XCTest；`xcodebuild test` 必须通过。
