# 双端一致性说明（Android / iOS）

本文件是 **Android `PKotlinApp` 与 iOS `codemagic` 共用的行为说明**，用于保证两端在模块划分、数据来源、字段命名、错误码、空状态与权限行为上口径一致。

- Android 侧口径以 `PKotlinApp/README.md` 与 `PJGoIoT/api/openapi.yaml` 为准。
- iOS 侧以本仓库 `README.md`、`docs/architecture.md` 为准。
- 后端 `openapi.yaml` 当前标注版本 **0.3.3**，但 `PJGoIoT` main 已合入读数链路（提交 `292e493`，**尚未打 v0.4.0 tag**）。iOS v0.4.0（`MARKETING_VERSION 0.4.0`，build 11）按冻结的 readings 契约实现：推送 `readings`（≤500/批、按 `id` 幂等）、查询 `readings`（倒序、cursor）、`readings/summary`（24h min/max/avg/last）；服务端保留 90 天，客户端本地保留 7 天。0.3.3 的 `advertisedName` 与三态语义保持不变。

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
| 设备详情 | 连接蓝牙后拉取设备信息，失败降级本地缓存；读数来自本地采集 + 云端汇总 | Retrofit `GET /api/v1/devices/{mac}` + Room 缓存 | `GET /api/v1/my/devices/ios/{externalId}`（复合键）优先；云端字段缺失或断网时降级 SQLite `device_info_cache` / `saved_devices`；读数折线/最近记录读 SQLite `readings`，24h 汇总优先 `.../readings/summary`，失败回退本地计算并标注「离线：本地数据」 |
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
| 读数查询 | — | `GET /api/v1/my/devices/{platform}/{externalId}/readings?metric=&from=&to=&limit=100&cursor=` | 返回 `{items[], nextCursor, hasMore}`，按 `recordedAt` 倒序 |
| 读数汇总 | — | `GET /api/v1/my/devices/{platform}/{externalId}/readings/summary?metric=&hours=24` | 返回 `{metric, unit, count, min, max, avg, last, windowStart, windowEnd}` |

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

`PJGoIoT/api/openapi.yaml`（当前标注 v0.3.3）提供 `POST /auth/anonymous`、`GET /sync/changes`、`POST /sync/push`、`GET /device-types/{type}/catalog`、`GET /my/devices/{platform}/{externalId}` 等。逐项核对结果：

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
- catalog 的固件全部带 `vendor` 与 `compatibility.platforms`，配件全部带 `compatibility` 对象，且至少 1 个配件带 `vendor`；
- `GET /my/devices/ios/{externalId}` 返回 `platform=ios` 与大写 UUID；
- 推送已注册型号（`deviceType = nordic_uart`）后拉回：`deviceType`、`vendor`、`compatibility` 均补全；推送未注册型号后拉回：三者均为 `null`，且 `alias` / `group` 仍在；
- 扫描只上报 `advertisedName` 时服务端 `alias` 保持空串；随后只上报 `alias` 不覆盖广播名；
- 推送省略 `group` 时服务端保留原分组；推送 `"group": ""` 显式清除；随后同内容重放与换幂等键均返回 200（不 409）；
- 相同 `Idempotency-Key` 重放返回 `Idempotent-Replayed: true`，不新增变更；
- 旧 `updatedAt` 推送触发 `server_newer` 冲突，服务端保留较新版本；
- 无 token 返回 401 `UNAUTHORIZED`；第二用户访问他人设备（按 MAC 与复合键）均返回 404 `NOT_FOUND`；
- 读数：推送 3 条（`appliedReadings=3`）→ 查询按 `recordedAt` 倒序 → `summary` 的 count/min/max/avg/last/unit/window 正确 → 重复 id 推送 `appliedReadings=0`、`skippedReadings=3` → 非法 `NaN` 返回 400。

当前共 **106 项断言全部通过**（v0.4.0 联调记录，后端 `PJGoIoT` main `7acab36`，尚未打 v0.4.0 tag）。

运行记录见 `README.md` 第 4.2 节；该脚本已接入 GitHub Actions `ios.yml` 的 `e2e-contract` job（macOS runner，与 build 并行）。v0.4.0 实际 CI 运行 [41941929495](https://github.com/platojobs/codemagic/actions/runs/41941929495) 中 `e2e-contract` 56s、106 项全 PASS（0 SKIP），`build-test` 3m47s、122 单测全绿。若 CI checkout 到的后端尚未包含 readings，第 7 节会输出 `[SKIP]`（能力门控，不计通过、不伪造 PASS），其余断言照常执行。

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

**展示**：设备详情「数据」区依次为指标选择（仅该设备真实已有指标）→ 最近 60 点自绘折线图（`draw(_:)` 手绘坐标轴/网格/折线/数据点，支持 0/1/60 点）→ 24h 汇总（min/max/avg/last）→ 最近记录。无读数展示「连接设备后开始采集」；蓝牙未授权提示前往系统设置；不展示任何伪造数据。

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
- iOS 当前在 401 时保留待上传记录并展示「登录已失效」：「我的」页显示状态与「重新登录」入口，用户确认后才调用 `auth/anonymous` 换新匿名账号；**不做自动重登**。确认后同步游标重置为 0，本机活动设备重新上传到新账号；旧账号云端数据不自动合并。见 `KNOWN_ISSUES.md`。

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
| 设备详情有本地读数但云端汇总失败 | 展示本地 24h 汇总与最近 60 点，并标注「数据来源：离线：本地数据」 |
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
- v3（v0.3.3，对齐 openapi 0.3.2）：`saved_devices` 增加 `device_type TEXT`（可空）；旧库升级后为 `NULL`，由设备详情拿到云端 `deviceType` 后回填。
- v4（v0.3.6）：`saved_devices` 增加 `advertised_name TEXT`（广播名），以及 `alias_patch` / `advertised_name_patch` / `group_patch` 三态标记列，用于区分「未修改」与「显式清除」。
- v5（v0.4.0）：新增 `readings` 表（`id`, `device_id`, `metric`, `value`, `unit`, `recorded_at`, `sync_state`），索引 `(device_id, metric, recorded_at DESC)` 支撑最近 60 点与 7 天清理。

iOS 表结构（`codemagic.sqlite`）：

| 表 | 关键字段 |
| --- | --- |
| `saved_devices` | `id, peripheral_id, platform, external_id, name, remark, group_name, mac, vendor, device_type, firmware_version, last_seen_at, created_at, updated_at, deleted_at, sync_state` |
| `rules` | `id, name, trigger, threshold, device_id, enabled, created_at, updated_at, deleted_at, sync_state` |
| `scan_logs` | `id, category, level, message, created_at, updated_at, deleted_at, sync_state` |
| `recent_devices` | `peripheral_id, name, rssi, last_seen_at, updated_at, deleted_at, sync_state` |
| `device_info_cache` | `peripheral_id, payload(JSON), fetched_at, updated_at, deleted_at, sync_state` |
| `readings` | `id, device_id, metric, value, unit, recorded_at, sync_state` |

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
- 失败不影响本地读写；「我的」页展示上次同步时间、待上传条数、错误码与降级说明。

---

## 8. 变更与对齐流程

1. 先改 `PJGoIoT/api/openapi.yaml`（后端契约只增不删）。
2. 同步更新本文件第 3、4 节与两端字段映射。
3. Android 更新 `data/remote/Dtos.kt`，iOS 更新 `Core/Models/DeviceCatalog.swift` / `ProductModel.swift` / `MarketItem.swift` 与 `Core/Networking/ProductAPIClient.swift`。
4. 两端运行单元测试：Android `./gradlew testDebugUnitTest`，iOS `xcodebuild ... test`；iOS 另跑 `scripts/e2e-contract.sh` 验证新端点。
5. 同步相关变更需同时覆盖：push 幂等、冲突不覆盖、tombstone、未知字段容错（iOS 见 `codemagicTests/SyncEngineTests.swift`）。
6. 端点以 `openapi.yaml` 为准；若暂时无法对齐，必须在本文件与 `KNOWN_ISSUES.md` 显式记录，不静默假设。
