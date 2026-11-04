# BLE 设备数据面板（codemagic · iOS）

纯 **Swift + UIKit（纯代码，无 Storyboard/XIB）** 实现的蓝牙设备数据面板，与 Android 端 [`PKotlinApp`](https://github.com/platojobs/PKotlinApp) 保持五模块命名、数据结构与行为口径一致。

**不包含** SwiftUI 主界面、第三方 UI 库、假数据、假购物车 / 订单 / 支付。

> 行为口径（模块顺序、字段、错误码、空状态、权限）见 **[docs/consistency.md](docs/consistency.md)**。结构与分层见 **[docs/architecture.md](docs/architecture.md)**。

---

## 1. 当前状态

| 项 | 结果 |
| --- | --- |
| 五模块（首页 / 设备 / 产品 / 市场 / 我的） | 已实现，纯代码 UIKit，真实数据路径 |
| CoreBluetooth 扫描 + 连接 | 已实现（`CBCentralManager`，真实 RSSI） |
| 本地持久化 | 已实现（SQLite3，含同步字段） |
| 网络层 | 已实现（URLSession + Codable，兼容 Android mock 契约） |
| 自绘 RSSI + 代码组装空状态 | 已实现 |
| 单元测试 | **44 个用例，0 失败**（`** TEST SUCCEEDED **`，2026-11-05，Xcode 27.2 / iPhone 17 模拟器） |
| 模拟器构建 | **通过**（`xcodebuild ... build`，`** BUILD SUCCEEDED **`） |
| CI | Codemagic `codemagic.yaml` 已配置（macOS + Xcode 16.4，构建 + 测试 + artifact）；**尚未在 Codemagic 上实际运行** |
| 真机 BLE / 签名 | **未验证**：本机无真机与 Apple 开发者账号，需自行验证（见第 9 节） |

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
- 基础设置：自动记录最近设备、启动自动扫描。
- 版本与关于：读取 `CFBundleShortVersionString / CFBundleVersion` 与当前 `BASE_URL`。

---

## 3. 目录结构

```
codemagic/
├── App/                    # AppDelegate / SceneDelegate / AppEnvironment / MainTabBarController
├── Core/
│   ├── Models/             # ScannedDevice、SavedDevice、DeviceRule、ProductModel、MarketItem…
│   ├── Networking/         # APIConfiguration、HTTPClient、ProductAPIClient、AppError
│   ├── Persistence/        # SQLiteDatabase + 5 个 Store
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
codemagicTests/             # 44 个 XCTest 用例
docs/
├── architecture.md
└── consistency.md
```

### 分层

`ViewController（Scenes）` → `ViewModel` → `Service / Store` → `SQLite / URLSession / CoreBluetooth`，模型与设计系统独立。所有依赖在 `App/AppEnvironment.swift` 组装，界面层不直接创建数据库或网络客户端。

### 如何新增一个模块

1. 在 `codemagic/Modules/<Feature>/` 新建 `Scenes/`、`ViewModels/`、`Views/`，命名沿用现有风格（如 `XxxViewController` / `XxxViewModel` / `XxxCell`）。
2. ViewModel 用构造器注入依赖，使用 `private(set)` 状态 + `onChange` 回调驱动 UI。
3. 新增表：在 `Core/Persistence/SQLiteDatabase.swift` 的 `migrate()` 提高版本并加 `CREATE TABLE`，再写对应 Store（保留 `id / updated_at / deleted_at / sync_state`）。
4. 新增网络接口：扩展 `ProductServicing` 或新建 Service，错误统一用 `AppError`。
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
- 本地 Go 服务当前实现 `openapi.yaml` 的 `/api/v1/...` 路径，与客户端 `api/products` / `api/market` 尚未完全对齐，Debug 下产品 / 市场可能显示 404 错误空状态；见 `docs/consistency.md` 第 3.4 节。

---

## 5. 权限（iOS）

`Info.plist` 已声明：

- `NSBluetoothAlwaysUsageDescription`：扫描附近设备、显示信号强度、连接设备读取厂商与固件信息。
- `NSBluetoothPeripheralUsageDescription`：兼容旧系统声明。
- `NSAppTransportSecurity / NSAllowsLocalNetworking = true`：仅允许本地 HTTP（Debug 的 `127.0.0.1`）。

授权流程：iOS 13+ 由 `CBCentralManager` 首次初始化 / 扫描时触发系统授权弹窗，不自建权限页。「我的」页展示 `CBManager.authorization` 与蓝牙开关状态，未授权 / 受限时提供跳转系统设置入口。

> iOS 不向 App 暴露蓝牙 MAC，设备详情接口使用 `CBPeripheral.identifier`；与后端 `openapi.yaml` 的 `/devices/{mac}` 存在差异，已在 `docs/consistency.md` 标注「待与 openapi.yaml 对齐」。

---

## 6. 持久化选择

使用 **SQLite3**（系统库，`-lsqlite3`）而不是 Core Data，原因：

1. 同步字段（`id / updatedAt / deletedAt / syncState`）需要逐列精确控制，SQL 更直观。
2. schema 以 SQL 明示，便于与 Android Room 表逐列对照，评审与排查成本低。
3. 不依赖 `.xcdatamodeld` 编辑器，CI 与代码合并不会产生模型文件冲突。
4. 软删除、WAL、迁移版本（`PRAGMA user_version`）都可直接控制。

数据库位置：`Application Support/com.platojobs.codemagic/codemagic.sqlite`。磁盘库失败时回退内存库，并在「我的」页提示。

---

## 7. 网络契约

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

其他限制：

- 模拟器无真实蓝牙，状态为 `unsupported`；产品 / 市场依赖网络，Debug 本地 Go 服务路径尚未对齐。
- 未实现真实 GATT 服务发现 / 读写 / OTA，GATT 仅展示网络返回的元数据。
- 未实现账号体系与同步推送；本地已保留同步字段。
- Release 签名与 App Store 上架未验证（无 Apple 开发者账号 / 证书）。

---

## 10. 版本记录

- `v0.1.0`：五模块（首页 / 设备 / 产品 / 市场 / 我的）、CoreBluetooth 扫描与连接、SQLite 持久化、URLSession + Codable 网络层、本地规则、设备详情缓存降级、自绘 RSSI、代码空状态、44 个单元测试、GitHub Actions 工作流。
