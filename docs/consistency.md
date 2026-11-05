# 双端一致性说明（Android / iOS）

本文件是 **Android `PKotlinApp` 与 iOS `codemagic` 共用的行为说明**，用于保证两端在模块划分、数据来源、字段命名、错误码、空状态与权限行为上口径一致。

- Android 侧口径以 `PKotlinApp/README.md` 与 `PJGoIoT/api/openapi.yaml` 为准。
- iOS 侧以本仓库 `README.md`、`docs/architecture.md` 为准。
- 后端 `PJGoIoT/api/openapi.yaml` 在 **v0.5.1** 起包含读数链路（v0.4.0 首次引入，v0.5.0 新增 `readings/series` 与 `readings/metrics`）。`v0.5.1` 修正 4 处契约表述：`/readings/metrics` 补 400 响应、`PushReading.unit` 允许空串（0–16）、9 个公共端点补 `security: []`、`compatibility` 的 nullable 写法；这些均不影响客户端逻辑。iOS v0.5.0（`MARKETING_VERSION 0.5.0`，build 13）在此基础上实现：推送 `readings`（≤500/批、按 `id` 幂等）、查询 `readings`（倒序、cursor）、`readings/summary`（24h min/max/avg/last）、**`readings/series`（1m/1h/1d 分桶）与 `readings/metrics`（指标清单）**；服务端保留 90 天，客户端本地保留 7 天。v0.4.1 起两端读数解析以 **3.8 黄金用例表**为唯一口径；v0.5.0 的长周期图表口径见 **3.9**。
- **v0.8.0（iOS）** 无后端契约变更：新增设计令牌（`Palette` / `Layout` / `AppText`）与米家信息架构，新增仅本机的 `scenarios` 表（迁移 v6，不同步）；口径见 **3.12**。

---

## 1. 五模块命名与顺序

两端底部导航以本表为目标口径；**iOS v0.8.0 已落地，Android 端尚未跟进**（见下方变更说明），不得在单端随意增删或调换。

| 序号 | 名称 | Android | iOS |
| --- | --- | --- | --- |
| 1 | 首页 | `ui/home/HomeFragment` | `Modules/Home`（设备卡片网格 + 快捷场景 + 告警摘要） |
| 2 | 智能 | —（尚未跟进） | `Modules/Smart`（自动化 + 场景） |
| 3 | 产品 | `ui/products/ProductsFragment` | `Modules/Products` |
| 4 | 市场 | `ui/market/MarketFragment` | `Modules/Market` |
| 5 | 我的 | `ui/profile/ProfileFragment` | `Modules/Profile` |

> **v0.8.0 变更（iOS 先行）**：iOS 已按米家信息架构重组为 **首页 / 智能 / 产品 / 市场 / 我的**，取消原「设备」Tab，设备管理（搜索 / 排序 / 分组）并入首页，规则与场景集中到「智能」；Android 端尚未跟进，本轮不强制对齐。`Modules/Devices` 保留设备详情、规则编辑与读数图表，不再作为底部 Tab。

iOS 设备详情页独立于底部导航：`Modules/Devices/Scenes/DeviceDetailViewController`（Android 为 `ui/detail/DeviceDetailActivity`）。

---

## 2. 每模块数据来源

| 模块 | 数据来源 | Android 实现 | iOS 实现 |
| --- | --- | --- | --- |
| 首页 | CoreBluetooth / BLE 真实扫描 + 本地最近设备 + 本地已保存设备 + 本地场景 | `BluetoothLeScanner` + `ScanCallback` → Room | `CBCentralManager` → `CoreBluetoothService`；卡片读 `SavedDeviceStore` / `ReadingsStore` / `RecentDeviceStore`，告警数读 `ScanLogStore`，场景读 `ScenarioStore` |
| 智能 | 本地规则 + 本地触发日志 + 本地场景 | Room `rules` / `scan_logs` | SQLite `rules` / `scan_logs` / `scenarios`（场景仅本机） |
| 产品 | 网络型号库 | Retrofit `GET api/products` | `GET /api/v1/device-types` + `GET /api/v1/device-types/{type}/catalog` |
| 市场 | 网络配件与固件信息 | Retrofit `GET api/market` | `GET /api/v1/device-types/{type}/catalog` 聚合 firmware + accessories |
| 我的 | 系统权限状态 + 本地扫描日志 + 版本信息 + 同步状态 | 系统 API + Room `scan_logs` + 同步引擎 | `CBManager.authorization` + SQLite `scan_logs` + `SyncEngine` 状态 |
| 设备详情 | 连接蓝牙后拉取设备信息，失败降级本地缓存；读数来自本地采集 + 云端汇总 | Retrofit `GET /api/v1/devices/{mac}` + Room 缓存 | `GET /api/v1/my/devices/ios/{externalId}`（复合键）优先；云端字段缺失或断网时降级 SQLite `device_info_cache` / `saved_devices`；读数折线/最近记录读 SQLite `readings`，24h 汇总优先 `.../readings/summary`，失败回退本地计算并标注「离线：本地数据」 |
| 同步（后台） | 后端 `/api/v1/sync/*` + Keychain token | Android 同步客户端 | `Core/Sync/SyncEngine` + `SyncAPIClient` + `KeychainTokenStore` |

规则/日志/最近设备均为本地数据，**不依赖网络**；断网时首页、设备、我的仍可用，同步进入降级状态并保留待上传记录。

跨平台设备（从服务端拉回、`platform = android`）只在本机占位展示：列表会标注「来自 Android，本机不可连接」并禁用连接入口，不进入设备详情。只有本机扫描得到的 `platform = ios` 设备可通过 CoreBluetooth 连接。

---

## 3. 网络端点与字段命名规则

### 3.1 端点

| 用途 | Android | iOS | 说明 |
| --- | --- | --- | --- |
| 匿名登录 | `POST /api/v1/auth/anonymous` | `POST /api/v1/auth/anonymous` | 返回 `{userId, token, expiresAt}`；token 存 Keychain，到期日只读展示 |
| 产品列表 | `GET api/products` | `GET /api/v1/device-types` + `.../{type}/catalog` | 见 3.4 |
| 市场列表 | `GET api/market` | `GET /api/v1/device-types/{type}/catalog` | 聚合 firmware + accessories |
| 设备信息 | `GET /api/v1/devices/{mac}` | `GET /api/v1/my/devices/ios/{externalId}` | iOS 用复合键，不依赖 MAC |
| 型号元数据 | `GET /api/v1/device-types/{type}` | `GET /api/v1/device-types/{type}` | iOS 型号列表与 catalog |
| 增量拉取 | `GET /api/v1/sync/changes?cursor=&limit=` | 同左 | 返回 `{changes[], nextCursor, hasMore}`；cursor 失效返回 410，客户端以 0 全量重拉 |
| 批量推送 | `POST /api/v1/sync/push` | 同左 | 批量 + `Idempotency-Key` |
| 型号 catalog | `GET /api/v1/device-types/{type}/catalog` | 同左 | 一次返回 `deviceType` + `firmwares` + `accessories`；产品 / 市场的数据源 |
| 用户设备列表 | `GET /api/v1/my/devices` | — | iOS App 未使用（拉取走 `sync/changes`）；仅 E2E 校验鉴权 |
| 用户设备详情（复合键） | `GET /api/v1/my/devices/ios/{externalId}` | 同左 | iOS 设备详情主数据源；需要 Bearer token；跨用户返回 404 |
| 用户设备详情（按 MAC） | `GET /api/v1/my/devices/{mac}` | — | iOS 不再使用；仅 E2E 校验越权 |
| 公共设备元数据（按 MAC） | `GET /api/v1/devices/{mac}` | 同左 | 仍可用，但**仅 Android 使用**；iOS 无 MAC 不走该端点 |
| 读数查询 | — | `GET /api/v1/my/devices/{platform}/{externalId}/readings?metric=&from=&to=&limit=100&cursor=` | 返回 `{items[], nextCursor, hasMore}`，按 `recordedAt` 倒序 |
| 读数汇总 | — | `GET /api/v1/my/devices/{platform}/{externalId}/readings/summary?metric=&hours=24` | 返回 `{metric, unit, count, min, max, avg, last, windowStart, windowEnd}` |
| 家庭（v0.14.0） | — | `GET/POST /api/v1/households`、`GET/PATCH/DELETE /households/{id}` | 返回 `{items}` / 单个家庭；个人家庭不可删（403）；v0.15.0 起 `memberCount` / `deviceCount` / `roomCount` 均为服务端真实值 |
| 家庭成员 / 邀请码（v0.14.0） | — | `GET /households/{id}/members`、`POST /households/{id}/invitations`、`POST /households/invitations/claim` | 邀请码 201 + `{code, expiresAt}`，8 位一次性、大小写不敏感 |
| 成员移除 / 退出（v0.15.0） | — | `DELETE /households/{id}/members/{userId}`、`POST /households/{id}/leave` | 均 204；owner 还有其他成员时退出 409 `CONFLICT`（可读 message）；被移除成员访问家庭 404，设备回个人家庭、房间清空 |
| 邀请码管理（v0.15.0） | — | `GET /households/{id}/invitations`、`DELETE .../invitations/{invitationId}` | 列表只返回 `codeHashPrefix` / `status` / `attempts` / `expiresAt`，无明文；撤销 204，撤销后 claim 404 |
| 家庭房间（v0.14.0） | — | `GET/POST /households/{id}/rooms`、`PATCH/DELETE /rooms/{roomId}` | 仅 owner 可写，member 403 `FORBIDDEN` |
| 房间整段排序（v0.15.0） | — | `PUT /households/{id}/rooms/order` | 请求 `{roomIds}` 必须是完整集合；缺项 / 多项 / 重复 409（v0.13.0 `CONFLICT`，后续 `ROOM_SET_MISMATCH`） |
| 设备归属（v0.14.0） | — | `PATCH /api/v1/my/devices/{platform}/{externalId}` | `alias` / `roomId` / `householdId` 三态（缺失 / 空串 / 非空） |

Base URL 均由构建配置注入，**不写死在源码**：

- Android：`BuildConfig.API_BASE_URL`（`app/build.gradle.kts`）。
- iOS：`Info.plist` 的 `BASE_URL` ← `Config/Debug.xcconfig` / `Config/Release.xcconfig`。
- `/api/v1/*` 路径由客户端在 `BASE_URL` 后拼接，因此 Debug 下 `http://127.0.0.1:8080` 可直接访问本地 `PJGoIoT`。

### 3.2 字段命名（canonical，openapi 0.3.3）

设备信息 / 型号条目统一使用：

```
mac, vendor, deviceType, firmwareVersion, compatibility,
gattServices: [{ uuid, name, characteristics? }]
```

`GET /api/v1/my/devices/{platform}/{externalId}`（`UserDevice`）与 `POST /api/v1/sync/push`（`PushDevice`）字段：

| 字段 | 类型 | 0.3.3 语义 | iOS 处理 |
| --- | --- | --- | --- |
| `platform` | string | `ios` / `android`，与 `externalId` 组成唯一键 | 必填，`ios` |
| `externalId` | string | iOS 为大写 UUID，Android 为大写 MAC | 必填 |
| `alias` | string | **用户别名**（用户编辑产生的名字） | 用户编辑只写 `alias`；未修改时省略 |
| `advertisedName` | string | **设备广播名**（BLE Local Name） | 扫描只写 `advertisedName`；未修改时省略 |
| `group` | string | 分组名；`""` 表示未分组 | 用户清空分组必须上报 `"group": ""`；未修改时省略 |
| `deviceType` | string \| null | 型号 id（如 `nordic_uart`） | **可 null**；null/空串 → 不展示、不落库、推送不带 |
| `vendor` | string \| null | 厂商名，服务端按 `deviceType` / MAC 补全 | **可 null**；null/空串 → `nil` |
| `firmwareVersion` | string \| null | 固件版本字符串 | **可 null**；null/空串 → `nil` |
| `compatibility` | object \| null | 结构见下 | **可 null**；`displayItems` 供展示、`filterTags` 供筛选 |
| `mac` / `note` | string | 与 0.3.1 一致 | 与固件/厂商缺失无关，始终展示 |

**缺省字段三态（0.3.3 核心语义）**

| 状态 | JSON 表现 | 语义 | iOS 实现 |
| --- | --- | --- | --- |
| absent | 键完全省略 | 未上报，服务端保持原值 | `Patch.absent`（默认；未修改字段） |
| clear | `""` | 显式清除（仅 `alias` / `advertisedName` / `group`） | `Patch.clear` |
| set | 具体值 | 上报新值 | `Patch.set(value)` |

- 构造 `PushDevice` 与幂等键时，**只有被上报的字段参与**；absent 字段不写入 JSON，因此不会因空值进入哈希。
- `nil`（absent）与 `""`（clear）绝不可混淆：解码时缺省 → `nil` → 保留本地值；显式空串 → 清空。

**展示顺序（列表 / 详情一致）**：用户别名 `alias` → 广播名 `advertisedName` → 型号名/型号键 `deviceType` → 「未命名设备」。

`catalog` 的 `firmwares[]` / `accessories[]`：

| 字段 | 类型 | 0.3.2 语义 |
| --- | --- | --- |
| `vendor` | string | 厂商名；**未核实时为空串**（不是 null） |
| `compatibility` | object | 兼容性描述对象，`accessories` 用 `deviceTypes` 表达适用型号 |

`Compatibility` 为 `additionalProperties: true` 的开放对象，当前已知 key：

- `platforms`：字符串数组，如 `["ios", "android"]`；
- `minAppVersion`：字符串，最低 App 版本；
- `protocol` / `protocolName`：字符串，如 `ble-gatt`；
- `features`：字符串数组，如 `["dfu"]`；
- `deviceTypes`：字符串数组（配件专用，表示适用型号）。

未知 key 不丢弃：iOS 解析为 `extras` 并按「显示名：值」摊平。

**null 语义（全端统一）**

- `null`、字段缺失、空串 `""`、纯空白串，在 iOS 模型层一律归一为 `nil`，**绝不渲染为字符串 `"null"` 或空串占位**。
- 展示层：`deviceType` 为 `nil` → 「型号未知」；`vendor` / `firmwareVersion` 为 `nil` → 「—」；`compatibility` 为 `nil` → 「暂无兼容性说明」。
- `null` 不等于 0 值：不写入本地缓存，不参与推送（`PushDevice` 用 `encodeIfPresent`，字段整体省略而不是 `null`）。
- 服务端补全失败时返回 `null` 而非猜测值；客户端**不得自行编造厂商/型号/兼容性**。

其他通用规则：

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
- 迁移 **v4** 新增 `advertised_name`，并从历史 `name` 列回填广播名；`name` 列为 v4 前的遗留列，与 `advertised_name` 同值写入以兼容降级版本。同版本新增 `alias_patch` / `advertised_name_patch` / `group_patch` 记录待上报三态，`markSynced` 成功后归零。
- iOS 的型号元数据与固件 / 配件使用 `GET /api/v1/device-types/{type}/catalog`；单台设备详情使用 `GET /api/v1/my/devices/ios/{externalId}`，均不依赖 MAC。
- `PushDevice` / `UserDevice` **不再缺型号字段**（openapi 0.3.2）：`UserDevice` 已含 `deviceType` / `vendor` / `firmwareVersion` / `compatibility`；`PushDevice.deviceType` 为**可选**字段。
- openapi 0.3.3 起 `UserDevice` 新增 `advertisedName`：扫描只写广播名，用户编辑只写别名，二者互不覆盖；本地展示名回落顺序为 alias → advertisedName → deviceType。
- iOS 推送 `deviceType` 的真实来源：设备详情从 `GET /my/devices/ios/{externalId}` 或 catalog 匹配拿到型号后写回 `saved_devices.device_type`，下次推送带上；无法推导时**保持 NULL 不传**，不填假值。`vendor` / `firmwareVersion` 仍为展示用元数据，不参与同类设备归类。
- iOS 与 Android 即使 `mac` 相同，也按 `platform` 分为两条独立记录（键为 `(platform, externalId)`）。
- 拉回的 Android 设备保留 `mac` 但没有可用的 `CBPeripheral.identifier`，因此 iOS 列表标注「来自 Android，本机不可连接」并禁用连接。

### 3.4 与 `openapi.yaml` 的对齐状态

`PJGoIoT/api/openapi.yaml`（v0.15.0 起标注 0.9.0，后端 v0.13.0；设备 / 同步等既有端点为 0.7.0 起）提供 `POST /auth/anonymous`、`GET /sync/changes`、`POST /sync/push`、`GET /device-types/{type}/catalog`、`GET /my/devices/{platform}/{externalId}`、`/households*`、`/households/{id}/rooms*`、`/households/{id}/members/{userId}`、`/households/{id}/leave`、`/households/{id}/invitations*`、`/households/{id}/rooms/order`、`PATCH /my/devices/{platform}/{externalId}` 等。逐项核对结果：

| 项 | 状态 |
| --- | --- |
| `platform` / `externalId` 设备唯一键 | **已对齐**：iOS 迁移 v2 已补齐字段并参与推送；E2E 校验双平台形状与大写规范化 |
| `POST /api/v1/auth/anonymous` + Bearer token | **已对齐**：token 存 Keychain，`Authorization: Bearer <token>` |
| `GET /api/v1/sync/changes` 游标分页 | **已对齐**：`cursor` 持久化，`hasMore` 循环拉取（最多 10 页） |
| `POST /api/v1/sync/push` + `Idempotency-Key` | **已对齐**：幂等键由批次**上报字段**的规范化 JSON 哈希得到，`absent` 字段不进入哈希，重试复用；E2E 校验重放返回 `Idempotent-Replayed: true` 且不产生重复变更 |
| 冲突 `conflicts[].reason`（`server_newer` / `clock_clamped` / `key_taken`） | **已对齐**：服务端获胜并提示「另一台设备改过这条」；冲突响应中缺省的可选字段按 `absent` 解析（保留本地值）；E2E 校验旧版本 push 返回 `server_newer` 且服务端数据未被覆盖 |
| `deleted` / `deletedAt` tombstone | **已对齐**：软删除上传 `deleted: true`，拉取删除写本地 tombstone |
| 错误体 `{"error":{"code","message"}}` | **已对齐**：客户端解析为 `AppError.api`，保留服务端 code；错误码枚举见第 4 节 |
| `GET /api/v1/device-types` | **已对齐**：产品列表数据源；兼容 `{items}` 与裸数组 |
| `GET /api/v1/device-types/{type}/catalog` | **已对齐**：产品型号元数据、市场固件 + 配件、型号 GATT 均来自该端点；E2E 校验结构 |
| `GET /api/v1/my/devices/ios/{externalId}` | **已对齐**：iOS 设备详情主数据源，携带 Bearer token；E2E 校验 200 与跨用户 404 |
| `UserDevice.deviceType` / `vendor` / `firmwareVersion` / `compatibility`（0.3.2） | **已对齐**：四个字段均可 null；`ProductModel` 解析后参与详情页展示，`deviceType` 同时写回本地供推送；E2E 校验已注册型号（`nordic_uart` → `vendor=Nordic Semiconductor`、`compatibility.platforms` 含 `ios`）与未注册型号（三字段均为 `null`，`alias` / `group` 仍返回） |
| catalog `firmwares[]` / `accessories[]` 的 `vendor` / `compatibility`（0.3.2） | **已对齐**：固件与配件均解析 `vendor` 与兼容性对象；市场条目展示真实厂商与兼容性，筛选维度直接取自这些字段；E2E 校验固件全部带 `vendor` 与 `compatibility.platforms`、配件全部带 `compatibility` |
| `PushDevice.deviceType`（0.3.2，可选） | **已对齐**：本地新增 `saved_devices.device_type`（迁移 v3）；已知型号才编码该字段，未知时省略；E2E 覆盖带 `deviceType` 的推送与拉回比对 |
| `UserDevice.advertisedName` + `PushDevice` 别名/广播名分离（0.3.3） | **已对齐**：本地迁移 v4 新增 `advertised_name`；扫描只上报 `advertisedName`，用户编辑只上报 `alias`；E2E 校验扫描上报后 `advertisedName` 落库、别名仍为空，随后编辑别名不覆盖广播名 |
| 缺省字段 / 显式清除三态（0.3.3） | **已对齐**：`Patch<String>` 三态 + 自定义 `encode`，absent 省略键、clear 编码 `""`；清空分组上报 `"group": ""` 且再次同步不复活；未修改字段不参与 LWW 与幂等哈希；E2E 覆盖缺省 group 不覆盖原值、显式空串清除、同内容换键不 409 |
| `GET /api/v1/my/devices` / `GET /api/v1/my/devices/{mac}` | **v0.14.0 起使用**：`GET my/devices` 用于成员可见设备的契约校验；iOS 设备详情仍走复合键；E2E 校验鉴权与越权 |
| `households` / `invitations` / `rooms` / `PATCH my/devices`（0.8.0） | **已对齐**：家庭落库与当前家庭持久化；邀请码 201 + `expiresAt`；房间以服务端为准（local / pending / synced）；设备归属独立 PATCH，三态（缺失 / 空串 / 非空）；member 403 `FORBIDDEN`、跨家庭 404、个人家庭不可删；E2E 第 9 节覆盖完整链路 |
| 成员移除 / 退出 / 邀请码管理 / 房间整段排序（0.9.0，v0.15.0） | **已对齐**：`DELETE /households/{id}/members/{userId}` 与 `POST /households/{id}/leave` 均 204；owner 带成员退出 409 `CONFLICT`，客户端按 HTTP 状态 + 端点上下文机读判定并映射为「请先转让所有权或移除其他成员」，不解析 message；`GET /invitations` 只取 `codeHashPrefix` / `status` / `attempts` / `expiresAt`（模型无 `code`），撤销 204 且撤销后 claim 404；`PUT /rooms/order` 整段提交，缺项 / 多项 / 重复 409 后自动重新 GET 并提示「房间列表已变化，已刷新」；`GET /households` 计数直接用服务端值；E2E 第 9 节与真 Postgres 脚本均覆盖 |
| 产品 / 市场 / 设备详情（iOS） | **已切到新端点**，不再请求 `api/products` / `api/market` / `api/device/{peripheralUUID}` |
| `GET /api/v1/devices/{mac}` | **仍可用，但仅 Android 使用**；iOS 本机设备没有 MAC，不再调用该端点 |

iOS 端不再存在“历史端点”调用；唯一保留的旧路径 `/api/v1/devices/{mac}` 由 Android 使用，iOS 不涉及。

### 3.5 端到端契约联调（本地 fixture，默认不进 CI）

`scripts/e2e-contract.sh` 从 `../PJGoIoT` 构建并以 `STORE=fixture` 启动服务（优先 8080，被占用则 18080），健康检查 200 后运行 `scripts/e2e-contract.swift`（独立 Swift 可执行程序，真实 URLSession 直连 localhost，不走模拟器）。断言覆盖：

- 匿名登录取得 `token`；
- 同一台实体设备分别以 `platform=ios`（`externalId` 大写 UUID）与 `platform=android`（`externalId` 大写 MAC）推送，两条记录共享 `mac` / `alias` / `group`；
- `changes` 拉回 `platform` / `externalId` / `mac` 形状；
- `GET /device-types` 与 `GET /device-types/{type}/catalog` 返回型号、固件、配件；
- catalog 的固件全部带 `vendor` 与 `compatibility.platforms`，配件全部带 `compatibility` 对象，且至少 1 个配件带 `vendor`；
- `GET /my/devices/ios/{externalId}` 返回 `platform=ios` 与大写 UUID；
- 推送已注册型号（`deviceType = nordic_uart`）后拉回：`deviceType`、`vendor`、`compatibility` 均补全；推送未注册型号后拉回：三者均为 `null`，且 `alias` / `group` 仍在；
- 扫描只上报 `advertisedName` 时服务端 `alias` 保持空串；随后只上报 `alias` 不覆盖广播名；
- 推送省略 `group` 时服务端保留原分组；推送 `"group": ""` 显式清除；随后同内容重放与换幂等键均返回 200（不 409）；
- 相同 `Idempotency-Key` 重放返回 `Idempotent-Replayed: true`，不新增变更；
- 旧 `updatedAt` 推送触发 `server_newer` 冲突，服务端保留较新版本；
- 无 token 返回 401 `UNAUTHORIZED`；第二用户访问他人设备（按 MAC 与复合键）均返回 404 `NOT_FOUND`；
- 读数：推送 3 条（`appliedReadings=3`）→ 查询按 `recordedAt` 倒序 → `summary` 的 count/min/max/avg/last/unit/window 正确 → 重复 id 推送 `appliedReadings=0`、`skippedReadings=3` → 非法 `NaN` 返回 400；
- 长周期（v0.5.0）：`series` 按 `1m` 返回、桶按 `start` 升序且 `count` 合计等于推送条数、每桶 `min ≤ avg ≤ max`；空区间返回 `buckets: []`；非法 `bucket=5m` 返回 400 `BAD_REQUEST`；`metrics` 按 `lastAt` 倒序、最新温度指标在首位、心率指标 `count=3` 且 `unit=bpm`。
- 家庭（v0.14.0）：三个匿名账号（owner / member / outsider）——个人家庭自动创建且不可删（403 `FORBIDDEN`）→ 创建家庭 → 邀请码 8 位且 `expiresAt` 为未来、一次性（重复领取 404）→ member 用小写码领取成功（`role=member`、成员数 2）→ 成员列表 owner / member 对应 → owner 建房并 PATCH 设备归属 → member `GET /my/devices` 可见该设备及 `householdId` / `roomId` → member 改房间 / 建房 / 签发邀请码 / 改家庭名均 403 `FORBIDDEN` → 跨家庭读取家庭 / 成员 / 房间均 404 `NOT_FOUND` → 非成员读取与改房间 404 → member 改 owner 设备 404 → 归属三态（缺失不变 / 空串清除 `roomId` 与 `householdId` 回落个人家庭 / 非空覆盖）→ 删除家庭后设备回到个人家庭、`roomId = null`。
- 家庭管理（v0.15.0）：owner 创建家庭 → 邀请 `member` 领取 → 邀请码列表只含 `codeHashPrefix` / `status` / `expiresAt`（响应无明文字段、响应原文不含明文）→ 撤销 204 后第三人 claim 404 → 建房 3 间 → 整段 `PUT /rooms/order` 成功且顺序生效 → 缺项 / 多项 / 重复均 409（`CONFLICT` 或 `ROOM_SET_MISMATCH`）→ `GET /households` 的 `memberCount=2` / `roomCount=3` / `deviceCount=0` 为真实值 → 成员设备 PATCH 加入家庭 → owner 带成员退出 409 `CONFLICT` 且 message 非空 → owner 移除成员 204 → 被移除成员 `GET /households/{id}` 404、其设备回个人家庭且 `roomId=null` → 移除后 owner 退出 204、家庭 404。

当前共 **260 项断言全部通过**（v0.15.0 联调记录，后端 `PJGoIoT` **v0.13.0**，`STORE=fixture`）；真 Postgres 运行同一套契约，并额外直接查库验证邀请码只存 64 位哈希、移除成员后成员行删除、owner 退出后成员行清空。

运行记录见 `README.md` 第 4.2 节；该脚本已接入 GitHub Actions `ios.yml` 的 `e2e-contract` job（macOS runner，与 build 并行）。若 CI checkout 到的后端尚未包含读数链路，第 7 节会输出 `[SKIP]`（能力门控，不计通过、不伪造 PASS）；`series` / `metrics` 自 v0.5.0 起属于必需契约，缺失即真实失败，不会跳过。

### 3.6 市场筛选维度（真实字段，不造假分类）

市场页筛选只使用接口返回的字段，不做本地臆造分类：

| 维度 | 来源字段 | 取值 | 说明 |
| --- | --- | --- | --- |
| 厂商 | `MarketItem.vendor` ← catalog `firmwares[].vendor` / `accessories[].vendor` | 去重后的真实厂商名；空串（未核实）不进入筛选项 | 不伪造厂商名，也不生成「未知厂商」假分类 |
| 兼容性 | `MarketItem.compatibilityTags` ← `CompatibilityInfo.filterTags` | 「平台：ios」「协议：ble-gatt」「特性：dfu」「型号：xxx」等 | 由 `platforms` / `protocol` / `features` / `deviceTypes` / 扩展 key 生成 |

- 两个维度可叠加；筛选结果为空时展示「没有符合筛选条件的条目」并提供清除筛选。
- 刷新后若某厂商或某兼容性标签已不存在，自动清除失效筛选，避免卡在空结果。
- 不提供「按价格 / 按分类」等接口未提供的维度。

### 3.7 设备读数 readings（v0.4.0）

**推送**：`POST /api/v1/sync/push` 请求体新增可选 `readings`（≤500/批；iOS 客户端按 200/批合并进同一批次）：

```
{"id": uuid, "platform": "ios", "externalId": "...", "metric": "...", "value": number, "unit": "...", "recordedAt": RFC3339}
```

- 服务端按 `id` 幂等：重复 id 计入 `skippedReadings`，仍返回 200；
- 响应新增 `appliedReadings` / `skippedReadings`；旧后端缺省时 iOS 按 0 解析；
- 读数与设备同批推送；断网时本地 `sync_state` 保持 `pending`，恢复后按相同内容与幂等键重试；`readings` 为空数组时整个字段省略，兼容 0.3.3 后端。

**查询**：`GET /api/v1/my/devices/{platform}/{externalId}/readings?metric=&from=&to=&limit=100&cursor=` → `{items[], nextCursor, hasMore}`，**倒序**（最新在前）。

**汇总**：`GET .../readings/summary?metric=&hours=24` → `{metric, unit, count, min, max, avg, last, windowStart, windowEnd}`。iOS 优先展示云端汇总；请求失败（未登录 / 离线 / 后端未上线）时用本地 24h 窗口计算同结构汇总，并标注「离线：本地数据」。

**指标白名单**：`temperature` / `humidity` / `battery` / `heart_rate` / `co2` / `pressure` / `other`；白名单外文本指标一律归一为 `other`，不丢弃数值。

**保留期**：服务端 90 天；iOS 本地 7 天。iOS 在启动与每次同步成功后清理 `recorded_at` 超过 7 天且**已同步**的读数（未上传读数保留至补传完成，避免离线静默丢数据）。

**订阅特征与解析**：

| 特征 | UUID | 解析规则 |
| --- | --- | --- |
| 心率测量 | `0x2A37` | 首字节 flags：bit0=0 → 下一字节 uint8；bit0=1 → 后两字节 uint16（LE）；只接受 1…300 bpm |
| 电池电量 | `0x2A19` | 单字节百分比 0…100 |
| 温度测量 | `0x2A6E` | 2 字节优先按 sint16 × 0.01 ℃；不合理时尝试 IEEE-754 半精度；4 字节按 IEEE-754 float32；只接受 -50…150 ℃ |
| Nordic UART TX | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | UTF-8 文本行，`metric=value`（未知指标 → `other`）或纯数字（指标 `other`、单位留空）；支持多行，单行失败只丢该行；>256 字节或单行 >64 字符拒收 |

解析失败（空帧、NaN/Inf、越界、非 UTF-8、超长）**静默丢弃并写本地日志（分类「读数」）**，不崩溃、不写脏数据。

**展示（v0.5.0）**：设备详情「数据」区依次为区间切换（1 小时 / 24 小时 / 7 天 / 30 天，默认 24 小时）→ 指标选择（来自服务端 `readings/metrics`，展示「指标名 · N 条」）→ 按时间定位的分桶折线图（`draw(_:)` 手绘坐标轴/网格/折线/数据点/min–max 区间带，不引第三方库）→ 24h 汇总（min/max/avg/last）→ 最近记录。无读数展示「连接设备后开始采集」；蓝牙未授权提示前往系统设置；不展示任何伪造数据。区间、分桶与缺口规则见 3.9。

### 3.8 读数解析黄金用例（v0.4.1，两端共用）

两端（iOS `ReadingParser` / Android 解析器）以**同一张黄金表**为准：每条固定为「特征 + 原始字节 → 唯一期望」。
iOS 用例固化在 `codemagicTests/ReadingsGoldenTests.swift`；新增特征或调整规则时，先在此表补行、再写用例、最后改实现，避免两端口径漂移。

| 特征 | 输入 hex | 期望 |
| --- | --- | --- |
| 心率 | `00 48` | heart_rate 72 bpm |
| 心率 | `00 00` | 丢弃 |
| 心率 | `01 2C 01` | heart_rate 300 bpm |
| 心率 | `01 2D 01` | 丢弃（301 越界） |
| 电池 | `64` | battery 100 % |
| 电池 | `00` | battery 0 %（真实值，非缺测） |
| 电池 | `65` | 丢弃（101 越界） |
| 温度 | `2A 08` | temperature 20.90 ℃（sint16 × 0.01） |
| 温度 | `70 FE` | temperature −4.00 ℃（sint16 × 0.01） |
| 温度 | `00 4A` | binary16 `0x4A00` = **12.0 ℃**（见下方脚注） |
| 温度 | `00 4D` | binary16 `0x4D00` = 20.0 ℃ |
| 温度 | `00 00 C0 3F` | temperature 1.5 ℃（float32） |
| 温度 | `FF FF` | temperature −0.01 ℃（sint16 −1，不得按 NaN 丢弃） |
| NUS | `temperature=23.5` | temperature 23.5 ℃ |
| NUS | `42` | other 42，单位空 |
| NUS | `abc` | 丢弃 |
| NUS | `temperature=23.5\nbattery=88\nxx` | 2 条（第 3 行丢弃，前两行保留） |
| 任意特征 | 空字节 | 丢弃并记录原因，不崩溃 |

口径说明：

- 温度 2 字节：**先**按 sint16 × 0.01 ℃；结果不落在 −50…150 ℃ 时回退 IEEE-754 binary16；4 字节按 binary32；最终 NaN / Inf / 越界一律丢弃。
- 心率 uint16 为**小端**；flags bit0 = 0 时取 uint8；有效范围 1…300 bpm。
- 电池 0 % 与 100 % 都合法，只拒绝 >100。
- NUS 按 `\n` 分行逐行解析，单行失败只丢该行；整帧 ≤256 字节、单行 ≤64 字符。

> **脚注（v0.4.1 核对发现）**：原黄金表 `00 4A → 20.0` 与 IEEE-754 binary16 不符：位型 `0x4A00` = 1.5 × 2³ = **12.0**，20.0 对应位型 `0x4D00`（字节 `00 4D`）。
> iOS 按规范解码，未对 `0x4A00` 做任何硬编码；两种位型都已固化为用例。Android 侧联调时请以本表两行为准修正期望值。

### 3.9 长周期分桶序列与指标清单（v0.5.0）

**区间 → bucket 映射**（「数据」区顶部切换，默认 24 小时；切换立即重绘并按新区间重新查询）：

| 区间 | `bucket` | 覆盖桶数 |
| --- | --- | --- |
| 1 小时 | `1m` | 60 |
| 24 小时 | `1h` | 24 |
| 7 天 | `1h` | 168 |
| 30 天 | `1d` | 30 |

组合均在服务端 500 桶上限以内。请求为 `GET /api/v1/my/devices/{platform}/{externalId}/readings/series?metric=&from=&to=&bucket=`，`from` / `to` 使用 **UTC RFC3339**；响应 `{metric, unit, bucket, from, to, buckets[{start, end, count, min, max, avg, last}]}`，`buckets` 按 `start` 升序。

**UTC 网格**：桶起点按时段取整对齐到 UTC。1970-01-01T00:00:00Z 同时是 1m / 1h / 1d 的整数倍，因此客户端本地兜底用「绝对秒数向下取整」即可得到与后端（2000-01-01T00:00:00Z 原点）完全一致的桶边界，不受本地时区与夏令时影响。

**只返回有数据的桶，因此必须按时间定位**：
- X 轴按每个桶 `start` 在查询区间内的**真实时间比例**定位，**不按数组下标等距绘制**；30 天区间只有 24 个桶时，首尾留白如实反映缺数据的天数。
- 相邻桶 `start - 前一个 end > 1s` 即判定为缺口，折线在缺口处**断开**（区间带同样断开），绝不跨缺口连线。原因：服务端不返回空桶，等距或跨缺口连线会把「设备断采」画成「数值缓慢变化」，属于伪造趋势。
- 每桶用 `avg` 连线，并叠加该桶 `min`–`max` 的浅色区间带，展示波动幅度。
- Y 轴按区间内真实 `min` / `max` 自适应（全相等时上下留白），刻度标签带真实单位；NaN / Inf 桶直接丢弃，不污染整条折线。
- 几何计算独立在 `ReadingsChartGeometry`，单测覆盖 空 / 单桶 / 等距 / 带缺口 / 30 天 24 桶 / 异常值过滤。

**指标清单**：`GET .../readings/metrics` → `{items:[{metric, unit, count, firstAt, lastAt}]}`，按 `lastAt` 倒序（同一时间按指标名升序）。详情页展示「指标名 · N 条」；单位以响应中该指标最近一条读数的单位为准，切换指标时同步更新 Y 轴与 24h 汇总行单位。服务端为空而本地有待同步读数时用本地清单兜底；完全没有指标时展示「连接设备后开始采集」。

**离线降级**：`series` 请求失败时用同一 UTC 网格聚合本地读数并即时重绘；本地只保留 7 天，30 天区间明确标注「离线：仅本地 7 天数据」，时间轴仍按 30 天绘制（缺数据处留白，不拉伸）。24h 汇总请求失败时同样回退本地 24h 窗口。

### 3.10 客户端请求节流、通知与导出口径（v0.6.0）

本节为两端共用的客户端行为口径，不新增服务端接口。

**详情页远端刷新**
- 读数入库（notify）只做**本地增量重绘**，不逐条打 `metrics` / `series` / `summary`。
- 远端查询去抖动 **800ms**：详情页可见时窗口内最多发起一轮合并刷新；`series` 的 `from` / `to` 与 `summary` 的 24 小时窗口基于**同一次时间锚点**，避免同一轮请求区间漂移（`metrics` 无区间参数）。
- 详情页不可见或 App 进入后台时不发远端请求；回到前台 / 重新可见补刷一次。
- 失败按指数退避（1s、2s、4s …，上限 **300s**；任一请求成功复位），与读数频率无关。
- 服务端 `metrics` 为空但本地存在 pending / failed 读数时：指标 Chip 与序列都用本地聚合（同一 UTC 网格），数据来源显示「待同步：本地数据」。

**阈值告警通知**
- 规则事件分 `triggered` / `recovered` 两类；仅对实际发出过告警的「规则 + 设备」发「已恢复」。
- 通知开关默认开启；**首次真正需要通知时**才请求系统授权；被拒绝时「我的」提示前往系统设置。
- 节流窗口可配 **1 / 5 / 30 分钟**（默认 5），同一设备同一规则窗口内只提醒一次；窗口按首次发出时间计算，重复事件不延长窗口。
- 通知携带设备 ID，点击通知进入对应设备详情。

**读数 CSV 导出**
- 范围：当前设备 + 当前指标 + 当前区间（1h / 24h / 7d / 30d）。
- 7 天内直接读本地；更长区间走服务端 `readings` cursor 分页，单次上限 **50,000 条**，超限提示缩短区间。
- 文件格式：UTF-8 **BOM**、表头 `recordedAt,metric,value,unit`、时间为 **ISO8601 UTC**、按 RFC 4180 转义含逗号 / 引号 / 换行的字段、行按时间升序。
- 文件只写临时目录并在分享结束后删除；导出中显示真实已读取条数，失败可重试。

**外观**
- 三态：跟随系统 / 浅色 / 深色；图表与卡片只使用动态语义色，禁止硬编码黑白或十六进制色值。

### 3.11 跨设备接管、账号导出注销与后台采集（v0.7.0）

后端契约 `PJGoIoT` v0.9.0（openapi **0.7.0**）。以下均为客户端行为口径，排序 / 格式化断言必须显式 Locale（`en_US_POSIX`）。

**配对码（跨设备接管）**
- `POST /api/v1/auth/pairing-code`（Bearer）→ `{code, expiresAt}`；码为 **8 位大写字母/数字**，字符集去掉易混的 `0/O/1/I`，10 分钟有效、一次性使用。
- 真机接入另一台设备：`POST /api/v1/auth/pairing-code/claim`（无需旧 token）→ `{userId, token, expiresAt}`；新 token 默认 180 天有效，接管后写入 Keychain 与会话到期日。
- 输入规范化：自动大写、过滤空白与 `0/O/1/I`、截断 8 位；不足 8 位不发起请求。
- 重新生成：新码生成后旧码立即失效（服务端保证）；界面在生成前二次确认并明确提示旧码失效。
- 错误口径：**404 一律「码无效或已过期」，不区分原因**；**429 读取 `Retry-After` 秒数并显示冷却倒计时**，冷却期间禁用提交；网络错误可重试。401 提示登录失效。
- 接管成功后：用返回 token **替换 Keychain**；保留本机已有设备与全部读数，并把设备（含本地别名/分组/广播名状态）与读数**全部重新标记 pending**；同步游标清零、`userID` 更新、`reloginRequired` 清除，随后自动触发一次前台同步把本机数据推给新账号。
- 旧账号云端数据不会自动合并；tombstone 设备不上传。

**账号数据导出**
- `GET /api/v1/me/export?limit=5000[&cursor=…]`，按 `hasMore` / `nextCursor` 循环拉全；`cursor` **不透明**，原样回传、不解析不构造，重复游标或超过 1000 页视为异常失败。
- 合并各页 `readings`；`user` / `devices` / `exportedAt` 取第一页。
- 写临时 JSON 文件后 `UIActivityViewController` 分享，分享面板关闭即删除；退出遗留文件 1 天后自动清理。
- 进度为真实已读取读数条数；失败按 401 / 网络 / 解析分别提示，网络与游标/写入错误可重试。

**注销账号**
- `DELETE /api/v1/me`（Bearer）→ 204。二次确认文案必须写明「设备与读数将永久删除且不可恢复」。
- 顺序：**服务端删除成功后** → 清 Keychain token → 清 SQLite 全部业务表（`readings` / `saved_devices` / `rules` / `scan_logs` / `recent_devices` / `device_info_cache`，单事务）→ 清同步元数据（`cursor` / `lastSyncAt` / `userID` / `reloginRequired` / `lastBackgroundPushAt`），保留 `clientID` 与界面设置，回到全新匿名状态。
- 401 与网络错误**不清理本地数据**，分别提示且网络错误可重试；本地清理失败必须明确上报（不得静默假装成功）。

**后台采集**
- `Info.plist` 声明 `UIBackgroundModes = fetch + bluetooth-central`；连接状态下后台继续接收 notify 并走同一 `ReadingsIngestor` 入库。
- 「我的 → 后台采集」开关持久化（`settings.backgroundCollection`，默认开启）；关闭时进入后台立即 `disconnectAll()`，不保持 BLE 链路，并在「我的」显示当前状态与耗电说明。
- 后台唤醒只做**受限推送**：不拉取增量、不创建匿名账号；单次最多 **100 台设备 / 200 条读数**；与上次后台推送间隔 **≥15 分钟**，失败同样记录时间以避免唤醒风暴。前台去抖 800ms 与指数退避 ≤300s 策略不变。
- 7 天保留清理只删除 `synced` 且超期的读数，`pending` / `failed` 在后台路径同样受保护。

### 3.12 设计令牌与本地场景（v0.8.0）

**设计令牌**
- 所有颜色、字号、间距、圆角、描边、动效与阴影来自 `DesignSystem/DesignTokens.swift`，**源码禁止硬编码色值与字号**；单测扫描 `codemagic/`（除 `DesignTokens.swift`）中的 `UIColor(...)`、`.white/.black`、`.systemGray`、`systemFont(ofSize: 数字)`、裸 `font = UIFont.` 赋值。
- `Palette` 36 个语义色，浅 / 深各一套（`UIColor(dynamicProvider:)`）；`Layout` 使用 4pt 阶梯、16 页边距、56 / 72 / 88 行高、12 圆角、1dp 描边；`AppText` 10 级字号，数值统一等宽数字。
- 按压态：浅色 6% / 深色 8% 遮罩（不使用整体 alpha）；按钮只变色不缩放，卡片按下 0.98；列表卡片 1dp 描边零阴影，仅浮层用 2 / 4 / 8dp 阴影。
- 自绘大标题：展开 96、收起 56，滚动阈值 12pt，200ms 插值。

**场景（仅本机）**
- SQLite 迁移 **v6** 新增 `scenarios`（`id` / `name` / `actions` JSON / `created_at` / `updated_at`），**不含同步字段，不参与 push / changes**；注销账号的业务表清理同样包含 `scenarios`。
- 动作集合固定 6 类：`connectDevice(uuid)`、`disconnectDevice(uuid)`、`startBackgroundCollection`、`stopBackgroundCollection`、`muteAlerts(10|30|60)`、`syncNow`；不接受任意脚本或网络自定义动作。
- 执行：严格按数组顺序逐个调用真实服务；单个动作失败**不阻断后续**；返回逐动作 `{action, succeeded, message}` 与汇总（成功 / 失败数）。重复执行校验（已连接 / 已开启 / 已静音）视为失败并给出原因，而非静默成功。
- 连接动作前置校验蓝牙授权与设备存在；静音写入 `SettingsStore.ruleAlertsMutedUntil` 并让 `RuleAlertCoordinator` 停止告警；同步复用 `SyncEngine` 返回真实推送 / 拉取条数。
- UI：场景列表与编辑页标注「仅本机」；首页快捷场景只展示前 3 个，点击执行并显示进度浮层与结果 Toast。

### 3.13 游标失效 410、503 TIMEOUT、分页上限与会话到期（v0.10.0）

后端契约为 `PJGoIoT` **v0.9.0 / openapi 0.7.0**；客户端行为口径如下。

**410 `RESYNC_REQUIRED`（游标早于保留边界）**

- 触发：`GET /sync/changes?cursor=` 的游标早于该用户最老保留 `change_log.seq`（服务端判定 `cursor > 0 && cursor < minSeq - 1`）时返回 `410 {"error":{"code":"RESYNC_REQUIRED","message":"游标已过期，请全量重新同步"}}`；**`cursor=0` 永不 410**。
- 客户端处理（`SyncEngine.handleResyncRequired`）：
  1. `SyncMetadataStore.resetCursor()`：清空本地游标与 `lastSyncAt`；
  2. **不清理**本地 pending 设备 / 读数，全量拉取后仍由 `pushPending` 重新上传；
  3. 立即以 `cursor=0` 全量重拉，合并规则复用 `apply`（与首次拉取完全一致：本地无 → 插入；已同步 → 覆盖；pending 且云端更新 → 云端获胜；pending 且本地更新 → 保留待推送）；
  4. 410 属于**终态分支**：不进指数退避、只处理一次（`hasResynced` 守卫；二次仍 410 则直接失败，不死循环）；
  5. 成功后在「我的」同步状态区明确展示「**云端变更记录已过期，已重新全量同步**；同步完成：拉取 N 条…」，不静默。
- 单测：`SyncEngineTests.testResyncRequiredClearsCursorKeepsPendingAndPullsFromZero`（游标归零 / pending 保留 / 二次从 0 / UI 文案）、`testResyncRequiredOnlyHandledOnceWhenFullPullAlsoFails`、`testResyncRequiredEndToEndThroughHTTPTransport`（fake transport 410 → 全量 200 → push）。
- 真 Postgres 分支：`scripts/e2e-postgres.sh` 用 SQL 改最老 `server_ts` + `cleanup(90)` 真实触发 410，再用 `cursor=0` 拉回；输出见 `docs/e2e-postgres.md`。

**503 `TIMEOUT`（查询超时）**

- `503 {"error":{"code":"TIMEOUT"}}`（以及 `UNAVAILABLE` / 裸 503）映射为「**服务端繁忙，稍后重试**」，属于**可重试**错误，按指数退避（30s 起、翻倍、上限 5 分钟）；**绝不可按 410 处理**，也不改动游标、不进入重新登录。
- 退避闸门 `nextAutomaticRetryAt`：`syncIfNeeded` 在窗口内直接跳过，手动「立即同步」不受限。
- 测试：`testTimeoutMapsToBusyAndEntersBackoffInsteadOfResync`（文案 / 游标不变 / 窗口内不再请求）。

**401 登录失效（token 180 天 TTL）**

- 401 语义不变：必须由用户确认重新登录，客户端不静默建号；文案统一「**登录已失效**」。
- `/auth/anonymous` 与 `claim` 返回 `expiresAt`（默认 180 天，服务端 `TOKEN_TTL_DAYS` 可配）。客户端解析后存 `sync.sessionExpiresAt`（UserDefaults，非凭据），在「我的」以只读行「会话到期日」展示；过期时间**不参与鉴权**（是否失效只以 401 为准）。旧后端不返回时显示「服务端未返回」，不臆造日期。
- 重新登录 / 注销 / 接管时同步更新或清除该字段。

**分页上限（客户端先收敛，避免越界 400）**

| 端点 | 服务端上限 | 客户端请求 |
| --- | --- | --- |
| `GET /sync/changes` | 500 | 默认 200 / 页，`APILimits.clamp(…, 500)` |
| `GET /my/devices/…/readings` | 500 | 详情页默认 100，导出翻页 200，均 `clamp(…, 500)` |
| `GET /me/export` | 5000 | 单页 5000，`clamp(…, 5000)` |

- `APILimits`（`Core/Networking/APIErrorCatalog.swift`）集中定义三个上限；`SyncEngine` 的 `pageLimit` 在 init 时同样收敛。
- 测试：`NetworkingTests.testChangesLimitIsClampedTo500` / `testReadingsLimitIsClampedTo500` / `testExportLimitIsClampedTo5000`。

---

### 3.14 指标阈值规则与「仅本机」语义（v0.11.0）

- **规则仅本机**：`rules` / `scan_logs` / `scenarios` 均不参与 `GET /sync/changes` 与 `push`；新增的 `metric` / `comparison` / `reading_threshold` / `consecutive` 字段**不进入任何请求体**。后端没有规则端点，云端不会保存规则，换机 / 重装后规则不迁移。注销账号时随业务表一并清理。
- **指标清单**：`temperature`（℃）、`humidity`（%）、`battery`（%）、`heart_rate`（bpm）、`co2`（ppm），与 3.9 的 `metrics` 枚举一致；比较符为 `gt` / `gte` / `lt` / `lte`，界面展示 `>` / `>=` / `<` / `<=`。
- **判定链路**：BLE notify → `ReadingParser` → `ReadingsStore.insert` → `ReadingsIngestor.evaluateReadingRules` → `RuleEvaluator.evaluateReadings` → `ScanLogStore`（触发 `warning` / 恢复 `info`）→ `RuleAlertCoordinator`（节流 + 通知授权 + 恢复只在已送达告警后补发）。
- **防抖语义**：连续 `N` 条读数（按 `recordedAt` 升序，且仅统计该规则指标）全部满足才触发一次；触发后继续满足不重复告警；任一条不满足即计数清零并恢复一次。阈值与单位在规则描述、命中日志与通知文案中成对出现，不显示裸数字。
- **升级兼容**：v7 迁移逐列判断 `PRAGMA table_info(rules)` 后补列；旧规则保持原 `trigger` / `threshold` / `sync_state`，回填 `metric = NULL`、`comparison = 'lte'`、`consecutive = 1`，升级后仍生效（`PersistenceTests.testLegacyRulesSurviveVersion7MigrationAndStillFire`）。
- **不改变契约**：本节不涉及网络字段，`openapi 0.7.0` 保持原样；E2E 契约套件不变。

### 3.15 推荐规则、本地化与动态字体（v0.12.0）

- **推荐规则不新建模型**：模板由 `RuleTemplateCatalog` 生成（温度 > 30℃、湿度 > 70%、电量 < 20%、心率 > 120、CO₂ > 1000ppm），一键添加写入现有 `rules`（`trigger = readingThreshold`、`consecutive = 1`），不新增表 / 列，SQLite 保持 v7。模板来源只取 `ReadingsStore.availableMetrics(deviceID:)`（该设备真实出现过的指标），`pressure` / `other` 不产生模板。
- **推荐规则仅本机**：与 3.14 的规则同口径，不参与 push / changes，换机不迁移。
- **本地化**：界面文案一律 `L10n.t(key)` / `L10n.f(key, args...)`，key 命名 `<域>.<界面>.<语义>`；`zh-Hans` 与 `en` 两份 `Localizable.strings` 的 key 集合与 `%@` 数量必须一致（`LocalizationTests` 强制）。新增文案必须同时补两份文件，禁止只补中文。
- **术语**：Device / Reading / Sync / Scan / Group / Alert / **Transfer Code**（不使用 `pairing code`，旧接口字段名除外）。
- **数字与日期**：界面一律 `Locale.current`（`String(format:locale:)`、`DateFormatter.dateFormat(fromTemplate:options:locale:)`）；CSV 内容、表头与文件名保持 `en_US_POSIX` + UTC，不随系统语言变化。
- **动态字体**：字号统一 `AppText`（`UIFontMetrics`）+ `applyFont(_:)`（`adjustsFontForContentSizeCategory = true`），禁止新增固定 `UIFont.systemFont(ofSize:)` 字号；表格行高 `automaticDimension`；图表 Y 轴左侧留白按当前字号测量，AX 字号下保持 3 个刻度且不与绘图区重叠。
- **不改变契约**：本节不涉及网络字段，`openapi 0.7.0` 保持原样；E2E 契约套件不变。

### 3.16 房间归属与首页分区（v0.13.0，仅本机）

- **数据模型**：SQLite **v8** 新增 `rooms(id TEXT PK, name TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0, remote_id TEXT, created_at REAL, updated_at REAL)`；`saved_devices` 增加可空 `room_id TEXT`（`NULL` = 未分配）。原 `group_name` 保留为兼容字段，不再参与首页分区。
- **房间仅本机**：`rooms` 与 `room_id` **不进入** `GET /sync/changes` 与 `POST /sync/push`；同步的 `PushDevice` 字段不变。`setRoom` 只执行 `UPDATE saved_devices SET room_id = ?`，不修改 `sync_state` / `updated_at`，不触发 pending。
- **远端映射预留**：`rooms.remote_id` 可空，暂不使用；后端若提供家庭 / 房间接口，可按本地 `id` ↔ `remote_id` 增量对接，无需再改表结构。
- **迁移与兼容**：v7→v8 只建表 / 加列 / 建索引，不重写旧数据；旧设备升级后 `room_id = NULL`，即进入「未分配」，`group_name` 原值保留（`RoomTests.testMigrationFromV7KeepsDevicesAndAddsRoomsAndRoomColumn`）。
- **写入一致性**：`SavedDeviceStore.upsert` 的列清单必须包含 `room_id`，否则 `INSERT OR REPLACE` 删行重插会把归属重置为 `NULL`（`RoomTests.testRoomAssignmentSurvivesDeviceUpsert`）。
- **删除语义**：删除房间先逐台 `setRoom(nil)` 再 `DELETE FROM rooms`；设备、读数、连接状态均不删除，全部回到「未分配」。需二次确认。
- **首页分区口径**：房间按 `sort_order, created_at` 升序；未知 / 空 `room_id` 归「未分配」且固定最后。搜索只匹配设备字段（别名 / 广播名 / 型号 / 标识符），有关键字时隐藏无命中的房间；排序（最近出现 / 名称 / 信号 / 添加时间）只在房间内生效，不改变分区顺序。
- **不改变契约**：本节不涉及网络字段，`openapi 0.7.0` 保持原样；E2E 契约套件不变。

### 3.17 家庭 / 邀请码 / 房间 / 设备归属（v0.14.0 起，v0.15.0 补齐，openapi 0.9.0）

- **数据模型（迁移 v9 / v10）**：
  - `households(id TEXT PK, remote_id TEXT UNIQUE NOT NULL, name TEXT NOT NULL, is_personal INTEGER NOT NULL DEFAULT 0, role TEXT NOT NULL, member_count INTEGER NOT NULL DEFAULT 0, device_count INTEGER NOT NULL DEFAULT 0, room_count INTEGER NOT NULL DEFAULT 0, created_at REAL, updated_at REAL)`，`id` **复用远端 UUID**，避免本地 / 远端双主键映射。
  - `member_count` / `device_count` / `room_count` 只读服务端 `GET /households` 的值，**不在本地重算**，避免成员 / 设备在其他端变化后计数漂移。
  - `rooms` 的 `remote_id` 真正启用，并新增 `household_id TEXT`（可空 = 未归属 / 已脱钩）、`sync_state TEXT NOT NULL DEFAULT 'local'`（`local` / `pending` / `synced`）、`deleted INTEGER NOT NULL DEFAULT 0`（离线删除墓碑）。
  - `saved_devices` 新增 `household_id TEXT`、`remote_room_id TEXT`、`remote_household_id TEXT`；`room_id` 仍为本机房间主键。
  - 新增 `device_assignment_pending(device_id TEXT PK, remote_room_id TEXT, remote_household_id TEXT, created_at REAL)`。
  - 迁移全部走条件 `ALTER TABLE`（`PRAGMA table_info` 查缺列）+ `CREATE TABLE IF NOT EXISTS`，旧库升级不重写数据、不丢房间与归属。
- **当前家庭**：`SyncMetadataStore.currentHouseholdRemoteID` 持久化；`GET /households` 结果合并到 `households`，服务端已不存在的家庭 `prune` 掉，其房间 `clearHousehold` **脱钩保留**（不删除），且本轮不再被认领，避免静默搬进别的家庭。
- **首次接入房间合并策略（不静默丢弃）**：本机 `unclaimedRooms()`（`household_id IS NULL` 且非墓碑）→ 认领到当前家庭 → `pushLocalRooms` 按 `sort_order, created_at` 顺序 `POST /households/{id}/rooms` → 拉回远端房间时若存在**同名**（`normalizedName` 去空白 + 忽略大小写）本机未上报房间，则 `applyRemote` **认领**该本地房间（保留本地 `id` 与设备归属），不重复创建 → 失败保持 `local / pending` 下次重试。种子完成后写 `seededHouseholdRemoteID`，不再重复搬迁。策略**只创建 / 认领，不删除任何本机房间**。
- **房间以服务端为准**：`syncHouseholdRooms` 顺序为 墓碑删除 → 改名 → 拉远端 → 推本地 → 设备归属补报；远端删除的房间本地 `markDeleted` + `purge`（设备 `room_id` 置空）；离线新建 / 改名 / 删除落 `pending` / 墓碑，界面标「未同步」。
- **设备归属与 push 解耦**：归属**不进** `PushDevice` / `sync/push`（避免 LWW 把 `updatedAt` 抢走），统一走 `PATCH /my/devices/{platform}/{externalId}`：
  - 三态：字段**缺失 = 不变**、**空串 = 清除**（服务端写 `null`）、**非空 = 覆盖**；「未分配」必须发送 `roomId: ""`（`assignDevice` 的 `reportedRoomID = roomRemoteID ?? ""`），不能省略字段。
  - 顺序：本机先行（`setAssignment`）→ 入 `device_assignment_pending` → 立即 PATCH → 成功出队、`applyRemoteAssignment`；网络失败保留队列下次同步重试。
  - 401 交给同步流程（不进终态）；403 / 404 为**终态**：出队 + 写 `lastAssignmentError` 可读文案，避免无限重试。
  - 拉取时若设备有 pending 归属，**不被远端旧值覆盖**（pending 优先）。
- **权限降级**：owner 可建 / 改 / 删房间、签发 / 撤销邀请码、移除成员、改家庭名、退出、排序；member 一律 403 `FORBIDDEN`。客户端入口按角色隐藏（member 看不到邀请码分区、成员移除、改名），`HouseholdAPIError.userMessage` 统一转文案（「你没有修改该家庭 / 房间的权限」），不展示 `FORBIDDEN` 码、不整页报错；跨家庭 / 非成员由服务端 404（不泄露存在性），客户端提示「家庭不存在或你没有访问权限」。个人家庭不可删（403 `FORBIDDEN`），也不可退出。
- **邀请码**：`POST /households/{id}/invitations` 201 返回 8 位一次性明文码 + `expiresAt`；客户端倒计时按服务端时间，过期后「重新生成」；领取 `POST /households/invitations/claim` 复用接管码输入规范化（大写、过滤易混字符），404 统一「邀请码无效或已过期」，429 按 `Retry-After` 冷却。
- **邀请码管理（v0.15.0）**：`GET /households/{id}/invitations` 只解析 `id` / `codeHashPrefix` / `status`（`active` / `expired` / `locked`）/ `attempts` / `expiresAt` / `createdAt`；本地模型 `HouseholdInvitationInfo` **没有 `code` 字段**，界面只显示哈希前缀与状态，绝不展示明文。`DELETE .../invitations/{id}` 204 后刷新列表；撤销后领取 404。
- **成员移除 / 退出（v0.15.0）**：`DELETE /households/{id}/members/{userId}` 与 `POST /households/{id}/leave` 成功均 204。成功（或当前账号被移除）时本地回落：设备改挂个人家庭、`room_id` / `remote_room_id` 清空、`remote_household_id` 指向个人家庭、清掉该设备 pending 归属；该家庭房间 `clearHousehold` **脱钩保留**（不删除，标注未同步）；家庭快照删除；当前家庭切回个人家庭；随后 `GET /households` 覆盖真实计数。失败不改本地状态。
- **退出 409**：owner 还有其他成员时服务端 409 `CONFLICT`；界面先本地拦截并提示「请先转让所有权或移除其他成员」，服务端 409 映射为同一文案；**机读判断只看 HTTP 状态与端点，不解析 message**。
- **房间整段排序（v0.15.0）**：`PUT /households/{id}/rooms/order`，请求 `{roomIds}` 必须覆盖家庭全部房间；缺项 / 多项 / 重复在客户端先判 `.roomSetMismatch`，不发请求；服务端 409（`ROOM_SET_MISMATCH`；v0.13.0 为 `CONFLICT`）时**不改本地顺序**，自动 `GET /rooms` 重新拉取并提示「房间列表已变化，已刷新」。网络失败同样不落本地顺序，避免与服务端分叉；本地未同步房间不参与整段提交，保持原相对位置。
- **离线**：保留本机房间与设备，房间 `local / pending` 与设备 pending 归属在首页与房间管理标注「未同步」；恢复网络后由 `prepareForSync` 补报，不丢数据。
- **契约**：openapi 0.9.0（后端 v0.13.0）；E2E 第 9 节覆盖创建家庭 → 邀请码 → 领取 → 成员可见设备 → member 403 → 跨家庭 404 → 归属三态 → 删除家庭级联，以及 v0.15.0 的成员移除 404、owner 退出 409→移除后可退出、邀请码列表无明文 / 撤销后 404、整段重排成功与 409。

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

后端 `openapi.yaml` 的错误体为 `{"error":{"code":"...","message":"..."}}`。完整枚举（与 `PJGoIoT/internal/httpapi/errors.go` 一致，v0.10.0 起含 410 / 503 新码）：

`BAD_REQUEST`、`INVALID_MAC`、`INVALID_JSON`、`UNAUTHORIZED`、`FORBIDDEN`、`NOT_FOUND`、`METHOD_NOT_ALLOWED`、`CONFLICT`、`IDEMPOTENCY_CONFLICT`、`RATE_LIMITED`、`PAYLOAD_TOO_LARGE`、`NOT_IMPLEMENTED`、`UNAVAILABLE`、`INTERNAL`、**`RESYNC_REQUIRED`**、**`TIMEOUT`**。

`FORBIDDEN`（v0.14.0）用于家庭 / 房间写权限：member 修改家庭名、创建 / 修改 / 删除房间、签发邀请码，以及删除个人家庭。家庭相关调用统一由 `HouseholdAPIError.userMessage` 转成可读文案（「你没有修改该家庭 / 房间的权限」），**不在 UI 展示错误码、不整页报错**；跨家庭 / 非成员一律由服务端返回 `NOT_FOUND`（404），客户端文案为「家庭不存在或你没有访问权限」，不区分存在性。

**唯一映射表**：`Core/Networking/APIErrorCatalog.swift` 把服务端 code 映射为「处理方式 + 展示文案」，`AppError` 与同步流程都只查这一张表：

| code | HTTP | 处理方式 | 展示文案 |
| --- | --- | --- | --- |
| `RESYNC_REQUIRED` | 410 | `resyncRequired`：清游标 + `cursor=0` 全量重拉，只处理一次，不进退避 | 云端变更记录已过期，需要全量重新同步 |
| `TIMEOUT` | 503 | `retryWithBackoff`：指数退避，不改游标、不重登 | 服务端繁忙，稍后重试 |
| `UNAUTHORIZED` | 401 | `reloginRequired`：等用户确认重新登录 | 登录已失效，请在「我的」页重新登录 |
| `IDEMPOTENCY_CONFLICT` | 409 | `terminal`：不自动重试 | 同步请求与已有幂等键冲突，请稍后重试 |
| `RATE_LIMITED` / `UNAVAILABLE` / `INTERNAL` | 429 / 503 / 500 | `retryWithBackoff` | 请求过于频繁 / 服务暂时不可用 / 服务端内部错误 |
| 其余（`BAD_REQUEST` / `NOT_FOUND` / `CONFLICT` 等） | 4xx | `terminal` | 按表内固定文案 |

客户端 `SyncAPIClient` 统一解析为 `AppError.api`：

- 客户端错误码仍为 `NET-002`，便于两端统一统计；
- 展示与日志中同时保留服务端 `code` 与 `HTTP status`（如 `NET-002 服务端繁忙，稍后重试（HTTP 503 / TIMEOUT）`）；
- 同一 `Idempotency-Key` 用于不同请求体时返回 409 `IDEMPOTENCY_CONFLICT`（不是 `IDEMPOTENCY_KEY_REUSED`），客户端不自动重试；
- **401 `UNAUTHORIZED` 语义**：token 已失效，必须由用户重新登录（重新获取匿名会话）后重试。客户端**不得在 401 时静默调用 `auth/anonymous` 新建匿名账号**，以免设备归属漂移。
- iOS 在 401 时保留待上传记录并展示「登录已失效」：「我的」页显示状态与「重新登录」入口，用户确认后才调用 `auth/anonymous` 换新匿名账号；**不做自动重登**。确认后同步游标重置为 0，本机活动设备重新上传到新账号；旧账号云端数据不自动合并。见 `KNOWN_ISSUES.md`。
- **410 与 503 不可混用**：`AppError.isResyncRequired` 只认 410 / `RESYNC_REQUIRED`；`isServerBusy` 只认 503 / `TIMEOUT` / `UNAVAILABLE`；两者都有单测锁定。

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
| 市场筛选无结果 | 空状态「没有符合筛选条件的条目」+「清除筛选」；不展示假数据 |
| 设备详情网络失败且无缓存 | 失败空状态 +「重试读取设备信息」 |
| 设备详情网络失败但有缓存 | **降级显示缓存**，并标注缓存时间与错误码，不白屏 |
| 设备详情云端型号为空（`deviceType = null`） | 型号显示「型号未知」；厂商 / 固件显示「—」；兼容性显示「暂无兼容性说明」；**alias、分组、最近出现时间照常展示** |
| 设备详情无读数 | 「数据」区只展示一条真实空状态「连接设备后开始采集」；蓝牙未授权时改为提示前往系统设置；不渲染空图表、不造 0 值 |
| 设备详情有本地读数但云端请求失败 | 按同一 UTC 网格展示本地分桶图表与本地 24h 汇总，并标注「离线：本地数据」；30 天区间标注「离线：仅本地 7 天数据」 |
| 我的扫描日志为空 | 空状态说明扫描会话会自动记录 |
| 我的同步未完成 / 失败 | 显示上次同步时间、待上传条数、错误码与降级说明；本地功能不受影响 |
| 我的同步冲突 | 明确提示「另一台设备改过这条」，并说明已采用云端版本 |
| 家庭 / 房间无写权限（v0.14.0） | 写入口禁用 + 页脚「你没有修改该家庭 / 房间的权限」；操作失败用 toast 展示可读文案，不弹 `FORBIDDEN` 码、不整页报错 |
| 跨家庭 / 非成员（v0.14.0） | 统一「家庭不存在或你没有访问权限」（服务端 404，不泄露存在性），页面回到可用空状态 |
| 离线房间 / 归属（v0.14.0） | 本机房间与设备照常展示并标「未同步」；恢复网络后自动补报，不丢数据 |
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
- v3（v0.3.3，对齐 openapi 0.3.2）：`saved_devices` 增加 `device_type TEXT`（可空）；旧库升级后为 `NULL`，由设备详情拿到云端 `deviceType` 后回填。
- v4（v0.3.6）：`saved_devices` 增加 `advertised_name TEXT`（广播名），以及 `alias_patch` / `advertised_name_patch` / `group_patch` 三态标记列，用于区分「未修改」与「显式清除」。
- v5（v0.4.0）：新增 `readings` 表（`id`, `device_id`, `metric`, `value`, `unit`, `recorded_at`, `sync_state`），索引 `(device_id, metric, recorded_at DESC)` 支撑最近 60 点与 7 天清理。
- v6（v0.8.0）：新增仅本机的 `scenarios` 表（`id`, `name`, `actions` JSON, `created_at`, `updated_at`），无同步字段。
- v7（v0.11.0）：`rules` 增加 `metric TEXT`（可空）、`comparison TEXT NOT NULL DEFAULT 'lte'`、`reading_threshold REAL NOT NULL DEFAULT 0`、`consecutive INTEGER NOT NULL DEFAULT 1`；旧行回填为 `metric = NULL` / `lte` / `1`，仍按原 RSSI / 断开条件生效。
- v8（v0.13.0）：新增仅本机的 `rooms` 表（`id`, `name`, `sort_order`, `remote_id`, `created_at`, `updated_at`）并为 `saved_devices` 增加可空 `room_id TEXT`（NULL = 未分配）；旧数据不重写，`group_name` 保留为兼容字段。
- v9（v0.14.0）：新增 `households(id, remote_id UNIQUE, name, is_personal, role, created_at, updated_at)` 与 `device_assignment_pending(device_id PK, remote_room_id, remote_household_id, created_at)`；`rooms` 增加 `household_id TEXT`（可空）、`sync_state TEXT NOT NULL DEFAULT 'local'`、`deleted INTEGER NOT NULL DEFAULT 0`；`saved_devices` 增加 `household_id TEXT`、`remote_room_id TEXT`、`remote_household_id TEXT`。全部条件 ALTER，旧数据不重写，房间与归属保留。

iOS 表结构（`codemagic.sqlite`）：

| 表 | 关键字段 |
| --- | --- |
| `saved_devices` | `id, peripheral_id, platform, external_id, name, remark, group_name, room_id, household_id, remote_room_id, remote_household_id, mac, vendor, device_type, firmware_version, last_seen_at, created_at, updated_at, deleted_at, sync_state` |
| `rules` | `id, name, trigger, threshold, metric, comparison, reading_threshold, consecutive, device_id, enabled, created_at, updated_at, deleted_at, sync_state` |
| `scan_logs` | `id, category, level, message, created_at, updated_at, deleted_at, sync_state` |
| `recent_devices` | `peripheral_id, name, rssi, last_seen_at, updated_at, deleted_at, sync_state` |
| `device_info_cache` | `peripheral_id, payload(JSON), fetched_at, updated_at, deleted_at, sync_state` |
| `readings` | `id, device_id, metric, value, unit, recorded_at, sync_state` |
| `scenarios`（仅本机） | `id, name, actions(JSON), created_at, updated_at` — 无 `deleted_at` / `sync_state` |
| `rooms`（v0.14.0 起服务端为准） | `id, remote_id, household_id, name, sort_order, sync_state, deleted, created_at, updated_at` — 无 `deleted_at`，删除用 `deleted` 墓碑 |
| `households`（v0.14.0） | `id, remote_id, name, is_personal, role, created_at, updated_at` |
| `device_assignment_pending`（v0.14.0） | `device_id PK, remote_room_id, remote_household_id, created_at` |

规则触发语义（两端一致）：

- **断开**：上一轮扫描存在、本轮不再出现（iOS 以 10s 未再出现为离开判定）。
- **RSSI 低于阈值**：低于或等于阈值触发一次，恢复后重新武装。
- **指标阈值（v0.11.0）**：`metric` 读数满足 `comparison` + `reading_threshold` 且**连续 `consecutive` 条（1–5，默认 1）**才触发一次；任一条不满足即清零并（若已告警）恢复一次。判定接在 `ReadingsIngestor` 落库之后，命中日志含触发值、阈值、时间与设备，进入「智能 → 最近触发」。
- 规则触发写本地日志并（若用户授权通知）发本地通知；恢复通知只在确实发过触发通知后补一条。规则**不参与 push / changes**（仅本机），详见 3.14。

### 7.1 同步行为（v0.2.0 起，与 openapi 对齐）

**身份与鉴权**

- 首次同步调用 `POST /api/v1/auth/anonymous`，得到 `{userId, token, expiresAt}`；`expiresAt` 存入 `sync.sessionExpiresAt`（UserDefaults，非凭据），仅供「我的」只读展示。
- token 只存 **Keychain**（`kSecClassGenericPassword`，`AfterFirstUnlock`），不写 UserDefaults；userId 与游标存 UserDefaults（非凭据）。
- 之后所有请求带 `Authorization: Bearer <token>`。

**增量拉取**

- `GET /api/v1/sync/changes?cursor=<上次游标>&limit=200`（服务端上限 500，客户端先收敛），`cursor` 持久化；`hasMore = true` 时继续拉取，单次同步最多 10 页。
- 游标早于保留边界 → 410 `RESYNC_REQUIRED`：清游标 + `cursor=0` 全量重拉（只处理一次，pending 不丢，详见 3.13）。
- 应用规则：
  - 本地不存在 → 插入并标记 `synced`；
  - 本地已同步 → 以云端字段覆盖；
  - 本地有未上传修改且云端 `updatedAt` 更新 → **云端获胜**，写回云端版本，同时提示「另一台设备改过这条」；
  - 本地有未上传修改且本地更新 → 保留本地，稍后推送由服务端裁决。

**批量推送**

- 取 `syncState != synced` 的记录（含 `pendingDelete` 的 tombstone），每批最多 100 条，按 `id` 排序；读数并入同一批次，每批最多 200 条，同样按 `id` 排序。
- `Idempotency-Key` 由批次内容（设备字段 + 读数 `id`/`metric`/`value`/`unit`/`recordedAt`）规范化后派生，**重试网络失败时复用同一键**；内容变化则键自动变化，避免 409。读数按 `id` 幂等，重复条目由服务端计入 `skippedReadings`。
- 成功：本批全部标记 `synced`；`conflicts` 中的记录写回云端版本并提示，不静默丢弃本地修改。
- 失败：保留 `pending`，下次同步用相同键重试。

**Tombstone**

- 本地删除为软删除（`deleted_at` + `syncState = pendingDelete`），推送时 `deleted: true`。
- 拉取到 `op = delete` 或 `deletedAt != nil` → 本地写 tombstone 并标记 `synced`，列表不再展示。

**触发时机**

- 回到前台：`sceneDidBecomeActive` → 节流 120 秒后自动同步。
- 进入后台：提交 `BGAppRefreshTask`（`com.platojobs.codemagic.sync`，最早 15 分钟），系统择机执行。
- 「我的」页「立即同步」：手动触发，不受节流限制。
- 失败不影响本地读写；「我的」页展示上次同步时间、待上传条数、会话到期日、错误码与降级说明。
- 可重试失败（网络 / 503 `TIMEOUT` / 5xx / 429）按指数退避（30s 起、翻倍、上限 300s）设 `nextAutomaticRetryAt`，窗口内自动同步跳过，手动同步不受限；410 不进该退避。

---

## 8. 变更与对齐流程

1. 先改 `PJGoIoT/api/openapi.yaml`（后端契约只增不删）。
2. 同步更新本文件第 3、4 节与两端字段映射。
3. Android 更新 `data/remote/Dtos.kt`，iOS 更新 `Core/Models/DeviceCatalog.swift` / `ProductModel.swift` / `MarketItem.swift` 与 `Core/Networking/ProductAPIClient.swift`。
4. 两端运行单元测试：Android `./gradlew testDebugUnitTest`，iOS `xcodebuild ... test`；iOS 另跑 `scripts/e2e-contract.sh` 验证新端点。
5. 同步相关变更需同时覆盖：push 幂等、冲突不覆盖、tombstone、未知字段容错（iOS 见 `codemagicTests/SyncEngineTests.swift`）。
6. 端点以 `openapi.yaml` 为准；若暂时无法对齐，必须在本文件与 `KNOWN_ISSUES.md` 显式记录，不静默假设。
