# BLE 设备数据面板（codemagic · iOS）

纯 **Swift + UIKit（纯代码，无 Storyboard/XIB）** 实现的蓝牙设备数据面板，与 Android 端 [`PKotlinApp`](https://github.com/platojobs/PKotlinApp) 保持五模块命名、数据结构与行为口径一致。

**不包含** SwiftUI 主界面、第三方 UI 库、假数据、假购物车 / 订单 / 支付。

> 行为口径（模块顺序、字段、错误码、空状态、权限）见 **[docs/consistency.md](docs/consistency.md)**。结构与分层见 **[docs/architecture.md](docs/architecture.md)**。

---

## 1. 当前状态

| 项 | 结果 |
| --- | --- |
| 版本 | **v0.3.0**（`MARKETING_VERSION 0.3.0`，`CURRENT_PROJECT_VERSION 4`，tag `v0.3.0`） |
| 五模块（首页 / 设备 / 产品 / 市场 / 我的） | 已实现，纯代码 UIKit，真实数据路径 |
| CoreBluetooth 扫描 + 连接 | 已实现（`CBCentralManager`，真实 RSSI） |
| 本地持久化 | 已实现（SQLite3，含同步字段；迁移 v2 补齐 `platform / external_id`） |
| 网络层 | 已实现（URLSession + Codable，兼容 Android mock 契约） |
| 同步 | **已实现**：匿名登录、增量拉取、批量推送（幂等键）、冲突提示、tombstone、Keychain token、前后台 / BGTask 触发 |
| 自绘 RSSI + 代码组装空状态 | 已实现 |
| 单元测试 | **63 个用例，0 失败**（`** TEST SUCCEEDED **`，2026-11-05，Xcode 27.2 / iPhone 17 模拟器） |
| 模拟器构建 | **通过**（`xcodebuild ... build`，`** BUILD SUCCEEDED **`） |
| CI | Codemagic `codemagic.yaml` 已配置（macOS + Xcode 16.4，构建 + 测试 + artifact）；**尚未在 Codemagic 上实际运行** |
| 真机 BLE / 签名 | **未验证**：本机无真机与 Apple 开发者账号，需自行验证（见第 9 节） |
| 真实后端同步 | **契约已联调**：`scripts/e2e-contract.sh` 对本地 `PJGoIoT`（`STORE=fixture`）跑 **43 项断言，全部 PASS**；App 内同步 UI 仍需真机手动验证 |

---

## 2. 五模块能力

### 首页 Home（`Modules/Home`）
- `CBCentralManager` 真实扫描，展示名称 / 标识符 / RSSI，并用自绘 `RSISignalView` 显示信号格数。
- 扫描结果按 RSSI 排序；「最近设备」持久化到 SQLite，重启后仍可查看。
- 空状态：未扫描 / 扫描中 / 蓝牙关闭 / 未授权 / 模拟器不支持，各有明确文案与操作。
- 支持保存设备到「设备」模块；扫描会话写本地日志。

### 设备 Devices（`Modules/Devices`）
- 已保存设备：备注名、分组、最后出现时间、厂商与固件（详情页回写）。
- 本地规则：**断开**、**RSSI 低于阈值**；可新增 / 启停 / 删除，规则持久化。
- 规则触发写扫描日志并在首页提示；规则可绑定单台设备或全部已保存设备。
- 设备详情：连接蓝牙 → 拉取设备信息 → 展示厂商 / 固件 / GATT / 兼容性；网络失败降级读本地缓存并标注缓存时间；无缓存显示失败空状态与重试。
- 跨平台设备：服务端拉回的 `platform = android` 设备标注「来自 Android，本机不可连接」，无展开箭头、禁用点击与连接，不进入详情。

### 产品 Products（`Modules/Products`）
- 型号库：厂商、型号、固件版本、GATT 服务与特征表、兼容性。
- 数据来自 `GET api/products`，失败显示错误空状态 + 重试；空列表显示空状态，不造假数据。
- 详情页 GATT / 特征由代码动态组装。

### 市场 Market（`Modules/Market`）
- 配件与固件信息列表 + 兼容性说明，数据来自 `GET api/market`。
- 页脚明确声明：**不提供下单、订单或支付**。

### 我的 Profile（`Modules/Profile`）
- 蓝牙授权与开关状态自检，跳转系统设置。
- 本地扫描日志列表、计数与清空。
- **同步状态**：上次同步时间、待上传条数、「立即同步」按钮、匿名账号；失败时展示错误码与降级说明，冲突时提示「另一台设备改过这条」。
- 基础设置：自动记录最近设备、启动自动扫描。
- 版本与关于：读取 `CFBundleShortVersionString / CFBundleVersion` 与当前 `BASE_URL`。

### 同步（`Core/Sync`）
- 首次同步自动匿名登录，token 存 **Keychain**（非 UserDefaults）。
- 增量拉取 `GET /api/v1/sync/changes`（游标持久化，`hasMore` 循环，最多 10 页）。
- 批量推送 `POST /api/v1/sync/push`（每批 ≤100，`Idempotency-Key` 由批次内容哈希派生）。
- 冲突按服务端 LWW：云端获胜时写回并提示，**不静默覆盖本地修改**；tombstone 删除同样上传 / 写回。
- 触发：回到前台（节流 120s）、进入后台（`BGAppRefreshTask`）、手动按钮。
- 契约联调：`scripts/e2e-contract.sh` 直连本地 Go 服务，覆盖双平台推送、幂等重放、LWW 冲突、401/404；默认不进 CI（见 4.2）。

---

## 3. 目录结构

```
codemagic/
├── App/                    # AppDelegate / SceneDelegate / AppEnvironment / MainTabBarController / SyncCoordinator
├── Core/
│   ├── Models/             # ScannedDevice、SavedDevice、DeviceRule、ProductModel、MarketItem…
│   ├── Networking/         # APIConfiguration、HTTPClient、ProductAPIClient、AppError
│   ├── Persistence/        # SQLiteDatabase + 5 个 Store
│   ├── Sync/               # SyncEngine、SyncAPIClient、SyncModels、KeychainTokenStore、SyncMetadataStore
│   ├── Bluetooth/          # CoreBluetoothService
│   ├── Rules/              # RuleEvaluator
│   └── Formatting/         # AppDateFormat
├── DesignSystem/           # AppTheme、RSISignalView（自绘）、EmptyStateView（代码组装）、LoadingStateView
├── Modules/
│   ├── Home/               # Scenes / ViewModels / Views
│   ├── Devices/
│   ├── Products/
│   ├── Market/
│   └── Profile/
└── Resources/              # Info.plist、Assets.xcassets
Config/
├── Debug.xcconfig          # BASE_URL → http://127.0.0.1:8080（本地 Go 服务）
└── Release.xcconfig        # BASE_URL → https://quickmock.dev/m/ecHT7ex3yQPA/（与 Android 共用 mock）
scripts/
├── e2e-contract.sh         # 启动本地 fixture 服务 + 运行联调 runner（不进 CI）
└── e2e-contract.swift      # 独立 Swift 可执行 runner，真实 URLSession 直连 localhost
codemagicTests/             # 63 个 XCTest 用例
docs/
├── architecture.md
└── consistency.md
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
- 本地 Go 服务实现 `openapi.yaml` 的 `/api/v1/...` 路径，同步链路可直接联调；产品 / 市场仍为客户端历史端点 `api/products` / `api/market`，Debug 下可能显示 404 错误空状态；见 `docs/consistency.md` 第 3.4 节。

### 4.2 端到端契约联调（手动运行，默认不进 CI）

脚本会自行构建并启动本地 `PJGoIoT`（`STORE=fixture`），跑完自动关闭服务：

```bash
cd /path/to/codemagic
./scripts/e2e-contract.sh
```

- 端口：优先 **8080**，被占用自动改用 **18080**；也可显式指定 `E2E_PORT=18080`。
- 后端目录：默认 `../PJGoIoT`，可用 `PJGOIOT_DIR=/path/to/PJGoIoT` 覆盖。
- 健康检查：轮询 `GET /api/v1/health`，必须在 30s 内返回 200，否则脚本失败。
- 联调 runner：`scripts/e2e-contract.swift` 由 `swiftc` 编译为独立 macOS 可执行文件，使用真实 `URLSession` 直连 `127.0.0.1`，**不走 iOS 模拟器**。
- 依赖本地 Go 服务与 fixture 数据，因此**不加入 `codemagic.yaml` 的 CI 流程**。

本机 2026-11-05 实际运行（8080 被其他进程占用，自动使用 18080）：

```
[e2e] health 200
[1. 匿名登录] 3/3 PASS
[2. 双平台推送（ios + android 同一台设备）] 7/7 PASS
[3. changes 拉回校验 platform / externalId] 12/12 PASS
[4. 同 Idempotency-Key 重放] 5/5 PASS
[5. LWW 冲突：旧版本不静默覆盖新版本] 9/9 PASS
[6. 无 token 401 / 跨用户 404] 7/7 PASS

=== E2E 合同联调结果 ===
通过：43 项，失败：0 项
结论：PASS
```

服务端日志写入 `.build/e2e/pjgoiot-server.log`；脚本退出时通过 `trap` 关闭后端进程。

---

## 5. 权限（iOS）

`Info.plist` 已声明：

- `NSBluetoothAlwaysUsageDescription`：扫描附近设备、显示信号强度、连接设备读取厂商与固件信息。
- `NSBluetoothPeripheralUsageDescription`：兼容旧系统声明。
- `NSAppTransportSecurity / NSAllowsLocalNetworking = true`：仅允许本地 HTTP（Debug 的 `127.0.0.1`）。

授权流程：iOS 13+ 由 `CBCentralManager` 首次初始化 / 扫描时触发系统授权弹窗，不自建权限页。「我的」页展示 `CBManager.authorization` 与蓝牙开关状态，未授权 / 受限时提供跳转系统设置入口。

> iOS 不向 App 暴露蓝牙 MAC，因此设备唯一键使用 `platform="ios"` + `externalId=CBPeripheral.identifier`（大写），`mac` 允许为空；型号元数据走 `GET /api/v1/device-types/{type}`，不依赖 MAC。

---

## 6. 持久化选择

使用 **SQLite3**（系统库，`-lsqlite3`）而不是 Core Data，原因：

1. 同步字段（`id / updatedAt / deletedAt / syncState`）需要逐列精确控制，SQL 更直观。
2. schema 以 SQL 明示，便于与 Android Room 表逐列对照，评审与排查成本低。
3. 不依赖 `.xcdatamodeld` 编辑器，CI 与代码合并不会产生模型文件冲突。
4. 软删除、WAL、迁移版本（`PRAGMA user_version`）都可直接控制。

数据库位置：`Application Support/com.platojobs.codemagic/codemagic.sqlite`。磁盘库失败时回退内存库，并在「我的」页提示。

迁移：`PRAGMA user_version` 线性递增。v1 建五张表；**v2（v0.2.0）** 为 `saved_devices` 增加 `platform`（默认 `ios`）与 `external_id`，由 `peripheral_id` 大写回填，并建立 `(platform, external_id) WHERE deleted_at IS NULL` 唯一索引。旧库升级后无需重装或清数据。

---

## 7. 网络契约

### 7.1 同步 / 鉴权（v0.2.0 起，与 `PJGoIoT/api/openapi.yaml` 对齐）

| 接口 | 方法 | 说明 |
| --- | --- | --- |
| `/api/v1/auth/anonymous` | `POST` | 返回 `{userId, token}`；token 存 Keychain |
| `/api/v1/sync/changes?cursor=&limit=` | `GET` | 返回 `{changes[], nextCursor, hasMore}`，需 `Authorization: Bearer <token>` |
| `/api/v1/sync/push` | `POST` | Body `{clientId, devices[]}`；Header `Idempotency-Key`；返回 `{applied[], conflicts[], nextCursor}` |
| `/api/v1/device-types/{type}` | `GET` | 型号元数据（不依赖 MAC） |

错误体 `{"error":{"code","message"}}` 解析为 `AppError.api`（客户端码 `NET-002`，保留服务端 code）。字段解码容忍未知字段与缺失字段。

### 7.2 产品 / 市场 / 设备详情（历史端点）

- `GET api/products` → `{"products":[...]}`，兼容裸数组
- `GET api/market` → `{"marketItems":[...]}`，兼容裸数组
- `GET api/device/{peripheralUUID}` → 单个设备信息对象

字段：`mac, vendor, deviceType, firmwareVersion, gattServices[{uuid,name,characteristics?}], compatibility`；解析忽略未知字段、缺失字段给空值，并兼容 Android 的 `model` / `services` / `title` / `category` / `description` 别名。错误码见 `docs/consistency.md` 第 4 节。

---

## 8. 持续集成

仓库根目录 `codemagic.yaml`（Codemagic）：

- 运行环境：Codemagic `mac_mini_m2`（macOS），指定 **Xcode 16.4**。
- 步骤：`xcodebuild -version` → `xcodebuild -list` → 模拟器 `build` → 模拟器 `test` → 打包 `codemagic.app`。
- 产物（artifact）：`codemagic-simulator-app.zip`（Debug-iphonesimulator）与 `build/ios/Logs/Test/*.xcresult`。
- 使用 `CODE_SIGNING_ALLOWED=NO`，不依赖签名证书。
- **该配置尚未在 Codemagic 上实际运行**；本地已用等价命令构建与测试通过。
- 此前尝试 GitHub Actions 时，当前仓库 OAuth token 缺少 `workflow` 权限，无法推送 `.github/workflows/*`，因此改用 Codemagic（根目录配置不受该限制）。如需 GitHub Actions，请由仓库管理员补充 workflow 权限后自行添加。

---

## 9. 已知限制与需真机验证

已知问题汇总见 **[KNOWN_ISSUES.md](KNOWN_ISSUES.md)**。以下内容只完成编译、单元测试与静态验证，**必须在真实 iPhone 上自测**：

- [ ] 首次蓝牙授权弹窗、允许 / 拒绝 / 受限三种状态的实际表现与跳系统设置。
- [ ] 真实 BLE 扫描能否发现设备、名称 / 标识符 / RSSI 是否随距离变化。
- [ ] 连接设备后的状态流转、断开事件，以及 12s 连接超时。
- [ ] 断开规则在设备离开范围后是否按预期触发（10s 未出现判定）。
- [ ] RSSI 阈值规则的触发 / 恢复重新武装。
- [ ] 后台 / 锁屏后的扫描与回调行为（当前未申请后台蓝牙模式）。
- [ ] 真实后端域名下的产品 / 市场 / 设备详情数据。
- [ ] App 内同步在真机 + 真实后端的完整闭环（E2E 已覆盖服务端契约，但未覆盖 App 的 Keychain、BGTask 与 UI 提示）。
- [ ] `BGAppRefreshTask` 在真机上的实际调度（模拟器不执行后台刷新）。
- [ ] 真机上确认「来自 Android，本机不可连接」设备的列表样式与点击无响应。

其他限制：

- 模拟器无真实蓝牙，状态为 `unsupported`；产品 / 市场依赖网络，Debug 本地 Go 服务路径尚未对齐。
- 未实现真实 GATT 服务发现 / 读写 / OTA，GATT 仅展示网络返回的元数据。
- 同步契约已用本地 fixture 服务端到端验证（43 项断言 PASS）；App 内的 Keychain token、BGTask 调度与真实网络环境仍需真机验证。
- Release 签名与 App Store 上架未验证（无 Apple 开发者账号 / 证书）。

---

## 10. 版本记录

- `v0.3.0`：版本号对齐（`MARKETING_VERSION 0.3.0` / build 4，tag `v0.3.0`，保留 `v0.2.0`）；新增 `scripts/e2e-contract.sh` + 独立 Swift runner，对本地 `PJGoIoT`（`STORE=fixture`）完成 43 项契约联调（匿名登录、双平台推送、changes 形状、幂等重放、LWW 冲突、401/404）；跨平台 Android 设备在列表标注「来自 Android，本机不可连接」并禁用连接；按 `openapi.yaml` 修正 `docs/consistency.md` 的错误码与对齐状态；单测增至 63 个。
- `v0.2.0`：落地同步层（匿名登录 / Keychain token / 增量拉取 / 批量推送幂等 / 冲突提示 / tombstone）、SQLite 迁移 v2（`platform` + `external_id`）、`BGAppRefreshTask` 与前后台触发、「我的」同步状态与手动同步、版本号对齐；新增同步相关单元测试并更新 `docs/consistency.md`。
- `v0.1.0`：五模块（首页 / 设备 / 产品 / 市场 / 我的）、CoreBluetooth 扫描与连接、SQLite 持久化、URLSession + Codable 网络层、本地规则、设备详情缓存降级、自绘 RSSI、代码空状态、44 个单元测试、Codemagic CI。
