# 双端一致性说明（Android / iOS）

本文件是 **Android `PKotlinApp` 与 iOS `codemagic` 共用的行为说明**，用于保证两端在模块划分、数据来源、字段命名、错误码、空状态与权限行为上口径一致。

- Android 侧口径以 `PKotlinApp/README.md` 与 `PJGoIoT/api/openapi.yaml` 为准。
- iOS 侧以本仓库 `README.md`、`docs/architecture.md` 为准。
- 后端 `openapi.yaml` 当前标注版本 **0.3.1**（本地 `PJGoIoT` HEAD `ebf542f`，tag `v0.3.1`）。iOS v0.3.1（`MARKETING_VERSION 0.3.1`，build 5）已按该版本切换产品 / 市场 / 设备详情端点；端到端联调以运行中的 fixture 服务实际行为为准（见 3.5）。

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
| 产品 | 网络型号库 | Retrofit `GET api/products` | `GET /api/v1/device-types` + `GET /api/v1/device-types/{type}/catalog` |
| 市场 | 网络配件与固件信息 | Retrofit `GET api/market` | `GET /api/v1/device-types/{type}/catalog` 聚合 firmware + accessories |
| 我的 | 系统权限状态 + 本地扫描日志 + 版本信息 + 同步状态 | 系统 API + Room `scan_logs` + 同步引擎 | `CBManager.authorization` + SQLite `scan_logs` + `SyncEngine` 状态 |
| 设备详情 | 连接蓝牙后拉取设备信息，失败降级本地缓存 | Retrofit `GET /api/v1/devices/{mac}` + Room 缓存 | `GET /api/v1/my/devices/ios/{externalId}`（复合键）+ SQLite `device_info_cache` |
| 同步（后台） | 后端 `/api/v1/sync/*` + Keychain token | Android 同步客户端 | `Core/Sync/SyncEngine` + `SyncAPIClient` + `KeychainTokenStore` |

规则/日志/最近设备均为本地数据，**不依赖网络**；断网时首页、设备、我的仍可用，同步进入降级状态并保留待上传记录。

跨平台设备（从服务端拉回、`platform = android`）只在本机占位展示：列表会标注「来自 Android，本机不可连接」并禁用连接入口，不进入设备详情。只有本机扫描得到的 `platform = ios` 设备可通过 CoreBluetooth 连接。

---

## 3. 网络端点与字段命名规则

### 3.1 端点

| 用途 | Android | iOS | 说明 |
| --- | --- | --- | --- |
| 匿名登录 | `POST /api/v1/auth/anonymous` | `POST /api/v1/auth/anonymous` | 返回 `{userId, token}`；token 存 Keychain |
| 产品列表 | `GET api/products` | `GET /api/v1/device-types` + `.../{type}/catalog` | 见 3.4 |
| 市场列表 | `GET api/market` | `GET /api/v1/device-types/{type}/catalog` | 聚合 firmware + accessories |
| 设备信息 | `GET /api/v1/devices/{mac}` | `GET /api/v1/my/devices/ios/{externalId}` | iOS 用复合键，不依赖 MAC |
| 型号元数据 | `GET /api/v1/device-types/{type}` | `GET /api/v1/device-types/{type}` | iOS 型号列表与 catalog |
| 增量拉取 | `GET /api/v1/sync/changes?cursor=&limit=` | 同左 | 返回 `{changes[], nextCursor, hasMore}` |
| 批量推送 | `POST /api/v1/sync/push` | 同左 | 批量 + `Idempotency-Key` |
| 型号 catalog | `GET /api/v1/device-types/{type}/catalog` | 同左 | 一次返回 `deviceType` + `firmwares` + `accessories`；产品 / 市场的数据源 |
| 用户设备列表 | `GET /api/v1/my/devices` | — | iOS App 未使用（拉取走 `sync/changes`）；仅 E2E 校验鉴权 |
| 用户设备详情（复合键） | `GET /api/v1/my/devices/ios/{externalId}` | 同左 | iOS 设备详情主数据源；需要 Bearer token；跨用户返回 404 |
| 用户设备详情（按 MAC） | `GET /api/v1/my/devices/{mac}` | — | iOS 不再使用；仅 E2E 校验越权 |
| 公共设备元数据（按 MAC） | `GET /api/v1/devices/{mac}` | 同左 | 仍可用，但**仅 Android 使用**；iOS 无 MAC 不走该端点 |

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

`GET /api/v1/device-types` 的包裹为 `{"items":[...]}`，客户端同时兼容裸数组；`catalog` 直接返回对象，无包裹层。旧 `{"products":[...]}` / `{"marketItems":[...]}` 客户端已不再请求（历史别名解析仍保留在 `ProductModel` / `MarketItem` 中以兼容本地缓存）。

### 3.3 设备标识符（与 openapi 一致）

- 服务端设备唯一键为 **`(user_id, platform, external_id)`**，与 MAC 无关。
- iOS `platform = "ios"`，`externalId = CBPeripheral.identifier.uuidString`（**统一大写**）；`mac` 允许为空。
- Android `platform = "android"`、`externalId` 必须为 MAC（规范化为**大写**、冒号分隔）；未传时由 `mac` 派生，`mac` 与 `externalId` 不一致返回 400。
- 服务端只做大小写规范化，不改写格式：iOS 的 `externalId` 必须是 UUID，Android 的必须是 6 字节 MAC，否则 400 `INVALID_MAC` / `BAD_REQUEST`。
- 设备表同时保留本机 `peripheral_id`（CoreBluetooth 标识）与服务端键 `platform + external_id`；迁移 v2 由 `peripheral_id` 回填 `external_id`。
- iOS 的型号元数据与固件 / 配件使用 `GET /api/v1/device-types/{type}/catalog`；单台设备详情使用 `GET /api/v1/my/devices/ios/{externalId}`，均不依赖 MAC。
- `PushDevice` / `UserDevice` **没有 `model` / `type` 字段**：同一型号或同一台实体设备只能用 `alias`、`group` 与可选 `mac` 元数据表达。iOS 与 Android 即使 `mac` 相同，也按 `platform` 分为两条独立记录（键为 `(platform, externalId)`）。
- 拉回的 Android 设备保留 `mac` 但没有可用的 `CBPeripheral.identifier`，因此 iOS 列表标注「来自 Android，本机不可连接」并禁用连接。

### 3.4 与 `openapi.yaml` 的对齐状态

`PJGoIoT/api/openapi.yaml`（当前标注 v0.3.1）提供 `POST /auth/anonymous`、`GET /sync/changes`、`POST /sync/push`、`GET /device-types/{type}/catalog`、`GET /my/devices/{platform}/{externalId}` 等。逐项核对结果：

| 项 | 状态 |
| --- | --- |
| `platform` / `externalId` 设备唯一键 | **已对齐**：iOS 迁移 v2 已补齐字段并参与推送；E2E 校验双平台形状与大写规范化 |
| `POST /api/v1/auth/anonymous` + Bearer token | **已对齐**：token 存 Keychain，`Authorization: Bearer <token>` |
| `GET /api/v1/sync/changes` 游标分页 | **已对齐**：`cursor` 持久化，`hasMore` 循环拉取（最多 10 页） |
| `POST /api/v1/sync/push` + `Idempotency-Key` | **已对齐**：幂等键由批次内容哈希得到，重试复用；E2E 校验重放返回 `Idempotent-Replayed: true` 且不产生重复变更 |
| 冲突 `conflicts[].reason`（`server_newer` / `clock_clamped` / `key_taken`） | **已对齐**：服务端获胜并提示「另一台设备改过这条」；E2E 校验旧版本 push 返回 `server_newer` 且服务端数据未被覆盖 |
| `deleted` / `deletedAt` tombstone | **已对齐**：软删除上传 `deleted: true`，拉取删除写本地 tombstone |
| 错误体 `{"error":{"code","message"}}` | **已对齐**：客户端解析为 `AppError.api`，保留服务端 code；错误码枚举见第 4 节 |
| `GET /api/v1/device-types` | **已对齐**：产品列表数据源；兼容 `{items}` 与裸数组 |
| `GET /api/v1/device-types/{type}/catalog` | **已对齐**：产品型号元数据、市场固件 + 配件、型号 GATT 均来自该端点；E2E 校验结构 |
| `GET /api/v1/my/devices/ios/{externalId}` | **已对齐**：iOS 设备详情主数据源，携带 Bearer token；E2E 校验 200 与跨用户 404 |
| `GET /api/v1/my/devices` / `GET /api/v1/my/devices/{mac}` | **App 未使用**：列表走 `sync/changes`，iOS 详情走复合键；仅 E2E 校验鉴权与越权 |
| 产品 / 市场 / 设备详情（iOS） | **已切到新端点**，不再请求 `api/products` / `api/market` / `api/device/{peripheralUUID}` |
| `GET /api/v1/devices/{mac}` | **仍可用，但仅 Android 使用**；iOS 本机设备没有 MAC，不再调用该端点 |

iOS 端不再存在“历史端点”调用；唯一保留的旧路径 `/api/v1/devices/{mac}` 由 Android 使用，iOS 不涉及。

### 3.5 端到端契约联调（本地 fixture，默认不进 CI）

`scripts/e2e-contract.sh` 从 `../PJGoIoT` 构建并以 `STORE=fixture` 启动服务（优先 8080，被占用则 18080），健康检查 200 后运行 `scripts/e2e-contract.swift`（独立 Swift 可执行程序，真实 URLSession 直连 localhost，不走模拟器）。断言覆盖：

- 匿名登录取得 `token`；
- 同一台实体设备分别以 `platform=ios`（`externalId` 大写 UUID）与 `platform=android`（`externalId` 大写 MAC）推送，两条记录共享 `mac` / `alias` / `group`；
- `changes` 拉回 `platform` / `externalId` / `mac` 形状；
- `GET /device-types` 与 `GET /device-types/{type}/catalog` 返回型号、固件、配件；
- `GET /my/devices/ios/{externalId}` 返回 `platform=ios` 与大写 UUID；
- 相同 `Idempotency-Key` 重放返回 `Idempotent-Replayed: true`，不新增变更；
- 旧 `updatedAt` 推送触发 `server_newer` 冲突，服务端保留较新版本；
- 无 token 返回 401 `UNAUTHORIZED`；第二用户访问他人设备（按 MAC 与复合键）均返回 404 `NOT_FOUND`。

运行记录见 `README.md` 第 4.2 节；该脚本依赖本地 Go 服务，**不纳入 Codemagic CI**。

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
| `SYNC-001` | 同步 / 云端记录前置条件不满足 | — | 上一次同步尚未结束、缺少匿名会话 |

后端 `openapi.yaml` 的错误体为 `{"error":{"code":"...","message":"..."}}`，完整枚举（与 `PJGoIoT/internal/httpapi/errors.go` 一致）：

`BAD_REQUEST`、`INVALID_MAC`、`INVALID_JSON`、`UNAUTHORIZED`、`NOT_FOUND`、`METHOD_NOT_ALLOWED`、`CONFLICT`、`IDEMPOTENCY_CONFLICT`、`RATE_LIMITED`、`PAYLOAD_TOO_LARGE`、`NOT_IMPLEMENTED`、`UNAVAILABLE`、`INTERNAL`。

客户端 `SyncAPIClient` 统一解析为 `AppError.api`：

- 客户端错误码仍为 `NET-002`，便于两端统一统计；
- 展示与日志中同时保留服务端 `code` 与 `message`（如 `NET-002 RATE_LIMITED 请求过于频繁`）；
- 同一 `Idempotency-Key` 用于不同请求体时返回 409 `IDEMPOTENCY_CONFLICT`（不是 `IDEMPOTENCY_KEY_REUSED`）；
- **401 `UNAUTHORIZED` 语义**：token 已失效，必须由用户重新登录（重新获取匿名会话）后重试。客户端**不得在 401 时静默调用 `auth/anonymous` 新建匿名账号**，以免设备归属漂移。
- iOS 当前在 401 时保留待上传记录并展示错误；由于暂无独立登录入口，需用户清理 Keychain token 后主动触发同步才会建立新会话（不会自动重登）。见 `KNOWN_ISSUES.md`。

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

### 7.1 同步行为（v0.2.0 起，与 openapi 对齐）

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
3. Android 更新 `data/remote/Dtos.kt`，iOS 更新 `Core/Models/DeviceCatalog.swift` / `ProductModel.swift` / `MarketItem.swift` 与 `Core/Networking/ProductAPIClient.swift`。
4. 两端运行单元测试：Android `./gradlew testDebugUnitTest`，iOS `xcodebuild ... test`；iOS 另跑 `scripts/e2e-contract.sh` 验证新端点。
5. 同步相关变更需同时覆盖：push 幂等、冲突不覆盖、tombstone、未知字段容错（iOS 见 `codemagicTests/SyncEngineTests.swift`）。
6. 端点以 `openapi.yaml` 为准；若暂时无法对齐，必须在本文件与 `KNOWN_ISSUES.md` 显式记录，不静默假设。
