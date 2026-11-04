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
│   ├── Networking/             # APIConfiguration / HTTPClient / ProductAPIClient / AppError
│   ├── Persistence/            # SQLiteDatabase 与各 Store
│   ├── Sync/                   # SyncEngine / SyncAPIClient / SyncModels / KeychainTokenStore / SyncMetadataStore
│   ├── Bluetooth/              # CoreBluetoothService（扫描 / 连接 / 授权）
│   ├── Rules/                  # RuleEvaluator（断开 / RSSI 阈值）
│   └── Formatting/             # 时间与 RSSI 格式化
├── DesignSystem/               # 主题、自绘 RSSI、代码组装空状态、Loading、图标名
├── Modules/
│   ├── Home/                   # Scenes / ViewModels / Views
│   ├── Devices/                # 设备列表、规则编辑、设备详情
│   ├── Products/               # 型号库与详情
│   ├── Market/                 # 配件与固件信息
│   └── Profile/                # 权限自检、扫描日志、设置、关于
└── Resources/                  # Info.plist、Assets.xcassets
Config/
├── Debug.xcconfig              # BASE_URL → 本地 Go 服务
└── Release.xcconfig            # BASE_URL → 线上（当前为与 Android 共用的 mock）
codemagicTests/                 # XCTest 单元测试（81 个用例）
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
| `RSISignalView` | `DesignSystem/RSISignalView.swift` | 自绘 `UIView`。`draw(_:)` 画 4 根圆角信号柱，按 RSSI 分档（≥-55:4、≥-67:3、≥-78:2、≥-90:1），无信号时灰色，带 accessibilityLabel。 |
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

模拟器没有真实蓝牙，状态为 `unsupported`，页面显示对应空状态；真实扫描、连接与授权弹窗需真机验证。

## 6. 网络

- `APIConfiguration` 从 `Info.plist` 读取 `BASE_URL`（由 xcconfig 注入），校验 scheme 与 host，源码不含地址。
- `URLSessionHTTPClient`：15s 超时、`ephemeral` 配置、`reloadIgnoringLocalCacheData`；非 2xx → `AppError.server`。
- `ProductAPIClient`：`GET /api/v1/device-types` + `GET /api/v1/device-types/{type}/catalog`（产品 / 市场）、`GET /api/v1/my/devices/ios/{externalId}`（设备详情，Bearer token）；Codable 宽松解码，兼容 `{items}` 包裹与裸数组。0.3.2 起解析 `UserDevice` 的 `deviceType` / `vendor` / `firmwareVersion` / `compatibility` 与 catalog 固件 / 配件的 `vendor` / `compatibility`，`null` / 缺失 / 空串统一归一为 `nil`；0.3.3 起解析 `advertisedName`，可选字段缺省时按 absent 处理。
- `CompatibilityInfo`（`Core/Models/DeviceCatalog.swift`）：动态 key 解码，`displayItems` 供展示、`filterTags` 供市场筛选（`deviceTypes` 显示为「型号」）。
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
  └─ push：fetchPending（≤100/批，按 id 排序）
       ├─ Idempotency-Key = SHA-256(批次内容) → 失败重试复用
       ├─ 成功 → markSynced；conflicts → 写回云端版本 + 提示
       └─ tombstone（deleted: true）同样走推送
```

- token 仅存 Keychain；游标 / userId / clientId 存 UserDefaults（非凭据）。
- 同步状态通过 `SyncEngine.onChange` 推给「我的」页，失败时保留 pending 并展示错误码与降级说明。
- 401：`AppError.isUnauthorized` → `metadata.reloginRequired = true`，「我的」页展示「登录已失效」与「重新登录」；用户确认后才换号（旧账号数据不合并），否则前后台自动同步直接失败，不会静默建号。
- 后台任务标识 `com.platojobs.codemagic.sync` 已在 `Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` 声明。
- 契约联调：`scripts/e2e-contract.sh` 启动本地 `PJGoIoT`（`STORE=fixture`）并运行独立 Swift runner，真实网络覆盖匿名登录、双平台推送、device-types/catalog（含 `vendor` / `compatibility`）、复合键详情、`UserDevice` 新字段与 null 降级、别名/广播名分离、group 三态、幂等重放、LWW 冲突与 401/404；已接入 GitHub Actions `e2e-contract` job。
- 产品 / 市场 / 详情：`ProductAPIClient` 使用 `device-types` + `{type}/catalog`（一次拿固件与配件），设备详情使用 `my/devices/ios/{externalId}` 复合键，不依赖 MAC。
- 市场筛选：`MarketViewModel` 维护 `allItems` + `selectedVendor` / `selectedCompatibility`，选项由 `item.vendor` 与 `item.compatibilityTags` 去重排序得到；`dropInvalidFilters` 在刷新后清除已失效的筛选值。
- 跨平台设备：`SavedDevice.isConnectable` 仅在 `platform == "ios"` 时为真；Android 设备在列表标注不可连接并禁用入口。

## 7. 持久化（SQLite）

选型理由：同步字段（`id / updatedAt / deletedAt / syncState`）需要逐列控制；schema 以 SQL 明示，便于与 Android Room 表逐列对照；不依赖 `.xcdatamodeld` 编辑器，CI 与代码评审都更直接。

- 数据库文件：`Application Support/com.platojobs.codemagic/codemagic.sqlite`。
- 打开参数：`READWRITE | CREATE | FULLMUTEX`；迁移使用 `PRAGMA user_version`，多语句脚本用 `sqlite3_exec`。
- 所有读写串行在一个专用队列；软删除保留行以便后续同步。
- 迁移版本：v1 建五张表；v2（v0.2.0）给 `saved_devices` 增加 `platform` / `external_id`，并由 `peripheral_id` 大写回填；v3（v0.3.3）增加 `device_type TEXT`（可空，供 `PushDevice` 使用）；**v4（v0.3.6）** 增加 `advertised_name TEXT`（由历史 `name` 回填广播名）与 `alias_patch` / `advertised_name_patch` / `group_patch`（`absent` / `clear` / `set`），后者在 `markSynced` 成功后归零。
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
