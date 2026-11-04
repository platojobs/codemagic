# 双端一致性说明（Android / iOS）

本文件是 **Android `PKotlinApp` 与 iOS `codemagic` 共用的行为说明**，用于保证两端在模块划分、数据来源、字段命名、错误码、空状态与权限行为上口径一致。

- Android 侧口径以 `PKotlinApp/README.md` 与 `PJGoIoT/api/openapi.yaml` 为准。
- iOS 侧以本仓库 `README.md`、`docs/architecture.md` 为准。
- 后端 `openapi.yaml` 已存在（`PJGoIoT/api/openapi.yaml`，版本 **0.2.0**）。iOS v0.2.0 已按该契约实现匿名登录、增量同步、批量推送与型号元数据；仅产品 / 市场仍沿用客户端历史端点（见 3.4）。

---

## 1. 五模块命名与顺序

两端底部导航必须严格保持以下名称与顺序，不得增删或调换：

| 序号 | 名称 | Android | iOS |
| --- | --- | --- | --- |
| 1 | 首页 | `ui/home/HomeFragment` | `Modules/Home` |
| 2 | 设备 | `ui/devices/DevicesFragment` | `Modules/Devices` |
| 3 | 产品 | `ui/products/ProductsFragment` | `Modules/Products` |
| 4 | 市场 | `ui/market/MarketFragment` | `Modules/Market` |
| 5 | 我的 | `ui/profile/ProfileFragment` | `Modules/Profile` |

iOS 设备详情页独立于底部导航：`Modules/Devices/Scenes/DeviceDetailViewController`（Android 为 `ui/detail/DeviceDetailActivity`）。

---

## 2. 每模块数据来源

| 模块 | 数据来源 | Android 实现 | iOS 实现 |
| --- | --- | --- | --- |
| 首页 | CoreBluetooth / BLE 真实扫描 + 本地最近设备 | `BluetoothLeScanner` + `ScanCallback` → Room | `CBCentralManager` → `CoreBluetoothService` → `RecentDeviceStore`（SQLite） |
| 设备 | 本地已保存设备 + 本地规则 | Room `devices` / `rules` | SQLite `saved_devices` / `rules` |
| 产品 | 网络型号库 | Retrofit `GET api/products` | URLSession `GET api/products` |
| 市场 | 网络配件与固件信息 | Retrofit `GET api/market` | URLSession `GET api/market` |
| 我的 | 系统权限状态 + 本地扫描日志 + 版本信息 + 同步状态 | 系统 API + Room `scan_logs` + 同步引擎 | `CBManager.authorization` + SQLite `scan_logs` + `SyncEngine` 状态 |
| 设备详情 | 连接蓝牙后拉取设备信息，失败降级本地缓存 | Retrofit `GET api/device/{mac}` + Room 缓存 | URLSession `GET api/device/{peripheralUUID}` + SQLite `device_info_cache` |
| 同步（后台） | 后端 `/api/v1/sync/*` + Keychain token | Android 同步客户端 | `Core/Sync/SyncEngine` + `SyncAPIClient` + `KeychainTokenStore` |

规则/日志/最近设备均为本地数据，**不依赖网络**；断网时首页、设备、我的仍可用，同步进入降级状态并保留待上传记录。

---

## 3. 网络端点与字段命名规则

### 3.1 端点

| 用途 | Android | iOS | 说明 |
| --- | --- | --- | --- |
| 匿名登录 | `POST /api/v1/auth/anonymous` | `POST /api/v1/auth/anonymous` | 返回 `{userId, token}`；token 存 Keychain |
| 产品列表 | `GET api/products` | `GET api/products` | 历史端点，见 3.4 |
| 市场列表 | `GET api/market` | `GET api/market` | 历史端点，见 3.4 |
| 设备信息 | `GET api/device/{mac}` | `GET api/device/{peripheralUUID}` | 历史端点，见 3.3 / 3.4 |
| 型号元数据 | `GET /api/v1/device-types/{type}` | `GET /api/v1/device-types/{type}` | iOS 不依赖 MAC |
| 增量拉取 | `GET /api/v1/sync/changes?cursor=&limit=` | 同左 | 返回 `{changes[], nextCursor, hasMore}` |
| 批量推送 | `POST /api/v1/sync/push` | 同左 | 批量 + `Idempotency-Key` |

Base URL 均由构建配置注入，**不写死在源码**：

- Android：`BuildConfig.API_BASE_URL`（`app/build.gradle.kts`）。
- iOS：`Info.plist` 的 `BASE_URL` ← `Config/Debug.xcconfig` / `Config/Release.xcconfig`。
- `/api/v1/*` 路径由客户端在 `BASE_URL` 后拼接，因此 Debug 下 `http://127.0.0.1:8080` 可直接访问本地 `PJGoIoT`。

### 3.2 字段命名（canonical）

设备信息 / 型号条目统一使用：

```
mac, vendor, deviceType, firmwareVersion,
gattServices: [{ uuid, name, characteristics? }],
compatibility
```

- 字段名使用 **lowerCamelCase**，与后端 JSON 一致。
- 未知字段必须忽略，不得因未知字段导致整包解析失败。
- 缺失字段给空值（字符串 `""`、数组 `[]`），不得抛错。
- `compatibility` 允许字符串、字符串数组、对象三种形态；对象按 key 排序后摊平为字符串数组。

为与 Android 现有 DTO / mock 兼容，iOS 额外接受以下别名（**只读兼容，不写入缓存**）：

| canonical | 兼容别名 | 来源 |
| --- | --- | --- |
| `deviceType` | `model` | Android `ProductDto` |
| `gattServices` | `services` | Android `ProductDto` |
| `name` | `title` | Android `MarketItemDto` |
| `kind` | `category`（「固件」→ firmware，「配件」→ accessory，其余 → other） | Android `MarketItemDto` |
| `summary` | `description` | Android `MarketItemDto` |
| `note` | — | Android `ProductDto.note`（可选展示） |

响应包裹同时兼容 `{"products":[...]}` / `{"marketItems":[...]}` 与裸数组。

### 3.3 设备标识符（与 openapi 一致）

- 服务端设备唯一键为 **`(user_id, platform, external_id)`**，与 MAC 无关。
- iOS `platform = "ios"`，`externalId = CBPeripheral.identifier.uuidString`（**统一大写**）；`mac` 允许为空。
- Android `platform = "android"`、`externalId` 使用 MAC（大写）。
- 设备表同时保留本机 `peripheral_id`（CoreBluetooth 标识）与服务端键 `platform + external_id`；迁移 v2 由 `peripheral_id` 回填 `external_id`。
- iOS 的型号元数据查询使用 `GET /api/v1/device-types/{type}`，不依赖 MAC。

### 3.4 与 `openapi.yaml` 的对齐状态

`PJGoIoT/api/openapi.yaml`（v0.2.0）提供 `POST /auth/anonymous`、`GET /sync/changes`、`POST /sync/push`、`GET /device-types/{type}` 等。对齐结果：

| 项 | 状态 |
| --- | --- |
| `platform` / `externalId` 设备唯一键 | **已对齐**：iOS 迁移 v2 已补齐字段并参与推送 |
| `POST /api/v1/auth/anonymous` + Bearer token | **已对齐**：token 存 Keychain，`Authorization: Bearer <token>` |
| `GET /api/v1/sync/changes` 游标分页 | **已对齐**：`cursor` 持久化，`hasMore` 循环拉取（最多 10 页） |
| `POST /api/v1/sync/push` + `Idempotency-Key` | **已对齐**：幂等键由批次内容哈希得到，重试复用 |
| 冲突 `conflicts[].reason`（`server_newer` / `clock_clamped` / `key_taken`） | **已对齐**：服务端获胜并提示「另一台设备改过这条」 |
| `deleted` / `deletedAt` tombstone | **已对齐**：软删除上传 `deleted: true`，拉取删除写本地 tombstone |
| 错误体 `{"error":{"code","message"}}` | **已对齐**：客户端解析为 `AppError.api`，保留服务端 code |
| `GET /api/v1/device-types/{type}` | **已对齐**：`SyncAPIClient.fetchDeviceType` |
| 产品 / 市场列表 | **仍为历史端点** `api/products` / `api/market`；openapi 按设备类型拆分 `firmwares` / `accessories`，客户端未切换 |
| 设备详情 | **仍为历史端点** `api/device/{peripheralUUID}`（iOS 无 MAC）；openapi 公共元数据为 `/api/v1/devices/{mac}` |

未对齐的两项不影响五模块功能与同步主链路，后续切换时只需改 `ProductAPIClient` 的路径与 DTO，不影响本地表结构。

---

## 4. 错误码

客户端错误码用于日志、空状态副标题与问题反馈，**两端含义一致**：

| 错误码 | 含义 | Android 触发场景 | iOS 触发场景 |
| --- | --- | --- | --- |
| `NET-001` | 网络请求失败（无网络、超时、连接被拒） | OkHttp IOException | URLSession 传输错误 |
| `NET-002` | 服务端返回非 2xx | HTTP 4xx/5xx | HTTP 4xx/5xx |
| `NET-003` | 响应无法解析为约定结构 | JSON 解析异常 | Codable 解码失败 |
| `NET-004` | Base URL 缺失或非法 | 配置缺失 | `BASE_URL` 缺失/非法 |
| `DB-001` | 本地数据库读写失败 | Room 异常 | SQLite 打开/读写失败 |
| `BT-004` | 蓝牙前置条件不满足（不支持/未授权/已关闭/连接失败） | BLE 调用异常 | `CBManager` 状态异常 |
| `SYNC-001` | 同步流程前置条件不满足（如并发触发） | — | 上一次同步尚未结束 |

后端 `openapi.yaml` 的错误体为 `{"error":{"code":"...","message":"..."}}`，错误码（`BAD_REQUEST`、`UNAUTHORIZED`、`NOT_FOUND`、`CONFLICT`、`RATE_LIMITED`、`IDEMPOTENCY_KEY_REUSED` 等）由客户端 `SyncAPIClient` 解析：

- 客户端错误码仍为 `NET-002`，便于两端统一统计；
- 展示与日志中同时保留服务端 `code` 与 `message`（如 `NET-002 RATE_LIMITED too many requests`）；
- 401 表示匿名 token 失效，重新匿名登录后重试。

---

## 5. 空状态与降级行为

统一使用代码组装的空状态视图：

- Android：`ui/common/EmptyStateView.kt`（Kotlin 组装 `LinearLayout + ImageView + TextView + Button`）。
- iOS：`DesignSystem/EmptyStateView.swift`（纯代码 Auto Layout，`configure(symbolName:title:message:actionTitle:action:)`）。

| 场景 | 行为 |
| --- | --- |
| 首页无扫描记录 | 空状态 +「开始扫描」按钮，不展示假设备 |
| 首页蓝牙不支持/未授权/关闭 | 空状态说明原因；未授权引导去「我的」跳系统设置 |
| 设备无已保存设备 | 空状态说明去首页扫描并保存 |
| 设备无规则 | 空状态说明新增规则；规则可增删启停 |
| 产品请求失败 | 错误空状态（含错误码）+「重试」，不展示假型号 |
| 产品返回空数组 | 空状态 +「刷新」，不展示假数据 |
| 市场请求失败 / 空列表 | 错误或空状态 +「重试/刷新」；页脚明确「不提供下单、订单或支付」 |
| 设备详情网络失败且无缓存 | 失败空状态 +「重试读取设备信息」 |
| 设备详情网络失败但有缓存 | **降级显示缓存**，并标注缓存时间与错误码，不白屏 |
| 我的扫描日志为空 | 空状态说明扫描会话会自动记录 |
| 我的同步未完成 / 失败 | 显示上次同步时间、待上传条数、错误码与降级说明；本地功能不受影响 |
| 我的同步冲突 | 明确提示「另一台设备改过这条」，并说明已采用云端版本 |
| 本地数据库不可用 | 应用仍可打开（回退内存库），「我的」显示 `DB-001` 启动提示 |

---

## 6. 权限行为

| 平台 | 声明 / 流程 |
| --- | --- |
| Android | Manifest 声明 `BLUETOOTH_SCAN`（`neverForLocation`）、`BLUETOOTH_CONNECT`；SDK < 31 追加 `ACCESS_FINE_LOCATION`；运行时按版本申请。 |
| iOS | `Info.plist` 声明 `NSBluetoothAlwaysUsageDescription`、`NSBluetoothPeripheralUsageDescription`；iOS 13+ 由 `CBCentralManager` 首次使用时触发系统授权，不额外弹自定义权限框。 |

两端「我的」页均提供：

- 当前蓝牙授权状态（allowed / notDetermined / denied / restricted / unknown）。
- 当前蓝牙开关状态（poweredOn / poweredOff / unauthorized / unsupported / resetting）。
- 跳转系统设置入口（Android `Settings.ACTION_APPLICATION_DETAILS_SETTINGS`；iOS `UIApplication.openSettingsURLString`）。
- 未授权/受限时的明确文案引导。

iOS 模拟器不提供真实蓝牙，`CBCentralManager` 状态通常为 `unsupported`；该情形直接展示「当前环境不支持蓝牙」空状态，**需真机验证真实授权弹窗与扫描**。

---

## 7. 本地持久化与同步字段

| 平台 | 方案 | 理由 |
| --- | --- | --- |
| Android | Room 2.8.5（KSP） | 与现有工程一致，DAO + Flow 观察 |
| iOS | SQLite3（原生 C API，WAL/FULLMUTEX） | 同步字段需精确控制、schema 用 SQL 明示、无需 `.xcdatamodeld`、便于与 Android 表字段逐列对照 |

两端业务表均保留同步字段：

- `id`：客户端生成的 UUID（iOS `saved_devices.id` / Android `devices.id`）。
- `updatedAt`：最后修改时间（RFC 3339 / 本地 `REAL` 秒）。
- `deletedAt`：软删除时间；未删除为 `NULL`。
- `syncState`：`pending` / `synced` / `pendingDelete`。

iOS 迁移版本：

- v1：五张业务表，含上述同步字段。
- v2（v0.2.0）：`saved_devices` 增加 `platform`（默认 `ios`）与 `external_id`，由 `peripheral_id` 大写回填；唯一索引 `(platform, external_id) WHERE deleted_at IS NULL`。

iOS 表结构（`codemagic.sqlite`）：

| 表 | 关键字段 |
| --- | --- |
| `saved_devices` | `id, peripheral_id, platform, external_id, name, remark, group_name, mac, vendor, firmware_version, last_seen_at, created_at, updated_at, deleted_at, sync_state` |
| `rules` | `id, name, trigger, threshold, device_id, enabled, created_at, updated_at, deleted_at, sync_state` |
| `scan_logs` | `id, category, level, message, created_at, updated_at, deleted_at, sync_state` |
| `recent_devices` | `peripheral_id, name, rssi, last_seen_at, updated_at, deleted_at, sync_state` |
| `device_info_cache` | `peripheral_id, payload(JSON), fetched_at, updated_at, deleted_at, sync_state` |

规则触发语义（两端一致）：

- **断开**：上一轮扫描存在、本轮不再出现（iOS 以 10s 未再出现为离开判定）。
- **RSSI 低于阈值**：低于或等于阈值触发一次，恢复后重新武装。
- 规则触发写本地日志；不做系统级通知（两端均未实现推送）。

### 7.1 同步行为（v0.2.0，与 openapi 对齐）

**身份与鉴权**

- 首次同步调用 `POST /api/v1/auth/anonymous`，得到 `{userId, token}`。
- token 只存 **Keychain**（`kSecClassGenericPassword`，`AfterFirstUnlock`），不写 UserDefaults；userId 与游标存 UserDefaults（非凭据）。
- 之后所有请求带 `Authorization: Bearer <token>`。

**增量拉取**

- `GET /api/v1/sync/changes?cursor=<上次游标>&limit=200`，`cursor` 持久化；`hasMore = true` 时继续拉取，单次同步最多 10 页。
- 应用规则：
  - 本地不存在 → 插入并标记 `synced`；
  - 本地已同步 → 以云端字段覆盖；
  - 本地有未上传修改且云端 `updatedAt` 更新 → **云端获胜**，写回云端版本，同时提示「另一台设备改过这条」；
  - 本地有未上传修改且本地更新 → 保留本地，稍后推送由服务端裁决。

**批量推送**

- 取 `syncState != synced` 的记录（含 `pendingDelete` 的 tombstone），每批最多 100 条，按 `id` 排序。
- `Idempotency-Key` 由批次内容（id / platform / externalId / updatedAt / deleted）做 SHA-256 派生，**重试网络失败时复用同一键**；内容变化则键自动变化，避免 409。
- 成功：本批全部标记 `synced`；`conflicts` 中的记录写回云端版本并提示，不静默丢弃本地修改。
- 失败：保留 `pending`，下次同步用相同键重试。

**Tombstone**

- 本地删除为软删除（`deleted_at` + `syncState = pendingDelete`），推送时 `deleted: true`。
- 拉取到 `op = delete` 或 `deletedAt != nil` → 本地写 tombstone 并标记 `synced`，列表不再展示。

**触发时机**

- 回到前台：`sceneDidBecomeActive` → 节流 120 秒后自动同步。
- 进入后台：提交 `BGAppRefreshTask`（`com.platojobs.codemagic.sync`，最早 15 分钟），系统择机执行。
- 「我的」页「立即同步」：手动触发，不受节流限制。
- 失败不影响本地读写；「我的」页展示上次同步时间、待上传条数、错误码与降级说明。

---

## 8. 变更与对齐流程

1. 先改 `PJGoIoT/api/openapi.yaml`（后端契约只增不删）。
2. 同步更新本文件第 3、4 节与两端字段映射。
3. Android 更新 `data/remote/Dtos.kt`，iOS 更新 `Core/Models/ProductModel.swift` / `MarketItem.swift`。
4. 两端运行单元测试：Android `./gradlew testDebugUnitTest`，iOS `xcodebuild ... test`。
5. 同步相关变更需同时覆盖：push 幂等、冲突不覆盖、tombstone、未知字段容错（iOS 见 `codemagicTests/SyncEngineTests.swift`）。
6. 差异未消除前，在本文件显式保留「仍为历史端点」标记，不静默假设。
