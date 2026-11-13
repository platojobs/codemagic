# iOS 工程架构

行为口径（模块命名、字段、错误码、空状态）见 [consistency.md](consistency.md)。

## 基本信息

| 项目 | 取值 |
| --- | --- |
| 语言 / UI | Swift 5，UIKit 纯代码（无 Storyboard / XIB / SwiftUI） |
| 最低版本 | iOS 15.0 |
| 依赖 | 无第三方库；SQLite3 由系统提供（`-lsqlite3`） |
| 工程 | `codemagic.xcodeproj`，target：`codemagic` / `codemagicTests` |
| 本地验证 | Xcode 27.2，iPhone 17 模拟器 |

## 目录

```
codemagic/
├── App/            # AppDelegate、SceneDelegate、AppEnvironment（唯一组合根）、
│                   # SyncCoordinator、MainTabBarController（首页/智能/产品/市场/我的）
├── Core/
│   ├── Models/     # 领域模型（Codable，宽松解析）
│   ├── Networking/ # APIConfiguration / HTTPClient / 各 APIClient / AppError
│   ├── Persistence/# SQLiteDatabase 与各 Store
│   ├── Readings/   # ReadingParser（四特征独立解析）+ ReadingsIngestor
│   ├── Sync/       # SyncEngine、KeychainTokenStore、SyncMetadataStore
│   ├── Account/    # 删除令牌、异步导出
│   ├── Bluetooth/  # CoreBluetoothService（扫描 / 连接 / 授权 / notify）
│   ├── Rules/      # RuleEvaluator（断开 / RSSI / 指标阈值）
│   ├── Scenes/     # SceneEngine、调度与模板
│   └── Formatting/ # 时间与 RSSI 格式化
├── DesignSystem/   # 主题、自绘 RSSI、空状态、Loading、图标名
├── Modules/        # Home / Devices / Products / Market / Profile（Scenes + ViewModels + Views）
└── Resources/      # Info.plist、Assets.xcassets
Config/             # Debug / Release xcconfig（BASE_URL）
codemagicTests/     # XCTest
scripts/            # e2e-contract.sh + 独立 Swift 联调 runner
docs/               # 本文件与行为口径、验收、排障等
```

Xcode file-system synchronized group 已开启：`codemagic/` 与 `codemagicTests/` 下新增 Swift 文件自动入 target。

## 分层

| 层 | 职责 | 依赖方向 |
| --- | --- | --- |
| `App` | 生命周期、组合根、Tab 装配 | Modules、Core |
| `Scenes` | 布局、导航、列表刷新、弹窗；不直接访问数据库 / URLSession | ViewModels、DesignSystem |
| `ViewModels` | 状态机与业务编排，`onChange` 驱动界面 | Models、Persistence、Networking、Bluetooth |
| `Views` | 纯展示，`configure(model:)` | Models、DesignSystem |
| `DesignSystem` | 颜色、字体、间距、复用组件 | 无业务依赖 |
| `Core` | 蓝牙、网络、规则、读数、同步、持久化 | Models |

首页数据流：

```
CoreBluetoothService.discoveryHandler
  → HomeViewModel.handleDiscovery
      → RecentDeviceStore / SavedDeviceStore 写入
      → RuleEvaluator.evaluate（断开 / RSSI 阈值）
      → rows 变更 → onChange → ViewController.reload
```

所有 ViewModel 回调最终在主队列刷新 UI。

## 纯代码 UI 代表

- `RSISignalView`：`draw(_:)` 画 4 根圆角柱；分档以 `PKotlinApp/docs/rssi-signal-tiers.md` 为唯一真源（`Tier` + `tier(for:)`），未知与极弱均 0 格但文案区分，非负占位值按未知处理；带 accessibilityLabel。
- `EmptyStateView`：代码组装 `UIStackView + UIImageView + UILabel + UIButton`，首页、设备、产品、市场、日志页复用。
- 不使用 XIB / Storyboard / `ContentUnavailableView`。

## 蓝牙

- `CBCentralManager` 主队列创建，首次使用触发系统授权。
- 扫描 `scanForPeripherals(withServices: nil, allowDuplicates: true)`；同一设备 RSSI 变化 > ±2 dBm 或间隔 > 3s 才回调。
- `connect` 超时 12s；连接 / 断开 / 失败走 `connectionHandler`。
- 读数订阅：`discoverServices(nil)` 后匹配 `0x2A37` / `0x2A19` / `0x2A6E` / NUS TX `6E400003-…`，`setNotifyValue(true)` 后把原始 `Data` 封成 `BluetoothReadingSample`；不限定服务 UUID。

读数链路：

```
readingHandler → ReadingsIngestor.ingest
  ├─ ReadingParser.parse：失败写 ScanLog 并丢弃
  ├─ SavedDeviceStore.fetch：未保存设备丢弃并记日志
  └─ ReadingsStore.insert（pending）→ onSaved → 详情页刷新
```

启动与每次同步成功后 `ReadingsStore.prune(olderThan: now-7d)`；只删已同步读数。模拟器蓝牙为 `unsupported`，真实扫描 / 连接 / 授权需真机验证。

## 网络与同步

- `APIConfiguration` 从 `Info.plist` 的 `BASE_URL` 读取（xcconfig 注入），校验 scheme / host，源码不写地址。
- `URLSessionHTTPClient`：15s 超时、`ephemeral`、忽略本地缓存；非 2xx → `AppError.server`。
- `ProductAPIClient`：`/catalog/device-types` 为类型目录唯一事实源，`/device-types/{type}/catalog` 只补固件 / 配件，详情用 `/my/devices/ios/{externalId}`；`DeviceCatalogClient` 负责 `If-None-Match` / 304 / SQLite 缓存兜底。
- `ReadingsAPIClient`：设备详情优先云端 24h 汇总，失败回退本地并标注「离线：本地数据」；折线与记录列表始终读本地 7 天数据。
- 同步：前台 120s 节流、后台 `BGAppRefreshTask`、手动「立即同步」；`pull` 增量（≤10 页）+ `push` 幂等批次（设备 ≤100、读数 ≤200）；401 只标记 `reloginRequired`，用户确认后才换号，不静默建号。
- 契约联调：`scripts/e2e-contract.sh` 启动本地 `PJGoIoT`（`STORE=fixture`）并跑独立 Swift runner，覆盖匿名登录、双平台推送、目录 200 / 304、复合键详情、LWW 冲突与 401 / 404。

## 持久化

- 文件：`Application Support/com.platojobs.codemagic/codemagic.sqlite`；`READWRITE | CREATE | FULLMUTEX`，专用串行队列，软删除保留行。
- 迁移用 `PRAGMA user_version`；逐版条件 ALTER，旧数据不重写。表与字段见 [consistency.md](consistency.md) 第 7 节。
- 磁盘库打开失败回退 `:memory:`，「我的」页提示 `DB-001`。
- 名称语义：`advertised_name` 由扫描写入，`remark` 由编辑写入，互不覆盖；展示名 alias → advertisedName → deviceType。

## 规则

`RuleEvaluator` 状态保存在实例内，扫描开始时 `reset()`：

- 断开：上一轮出现、本轮消失时触发一次。
- RSSI：`rssi <= threshold` 触发一次，恢复后重新武装。
- 指标：满足比较与阈值且连续 N 条（1–5，默认 1）触发一次。
- 可绑定具体设备或对所有已保存设备生效；停用不触发。结果写 `scan_logs`，首页展示最近一条。

## 扩展模块

1. 在 `Modules/<Feature>/` 下建 `Scenes/`、`ViewModels/`、`Views/`。
2. ViewModel 构造器注入依赖，`private(set)` 状态 + `onChange`，不直接引用 `AppEnvironment.shared`。
3. 新表在 `SQLiteDatabase.migrate()` 增加版本与 `CREATE TABLE`，再写 Store。
4. 页面用 `UITableView` / `UIStackView` 纯代码；空状态用 `EmptyStateView`。
5. 在 `MainTabBarController` 或模块入口装配，并在 `consistency.md` 第 1 节登记。
6. 补 XCTest，`xcodebuild test` 必须通过。
