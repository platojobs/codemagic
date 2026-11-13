# 跨端一致性（现行口径）

> 只记录 iOS / Android 必须一致的行为。历史对账与逐版本审计已删除；验证以单测、e2e 与截图为准。

## 1. 底部导航

| 序号 | 名称 | iOS | Android |
| --- | --- | --- | --- |
| 1 | 首页 | `Modules/Home`（设备卡片 + 快捷场景 + 告警摘要） | `ui/home/HomeFragment` |
| 2 | 智能 | `Modules/Smart`（自动化 + 场景） | 尚未跟进 |
| 3 | 产品 | `Modules/Products` | `ui/products/ProductsFragment` |
| 4 | 市场 | `Modules/Market` | `ui/market/MarketFragment` |
| 5 | 我的 | `Modules/Profile` | `ui/profile/ProfileFragment` |

原「设备」Tab 已取消，设备管理并入首页，规则与场景集中在「智能」；设备详情独立于底部导航。

## 2. 每模块数据来源

- **首页**：CoreBluetooth / BLE 扫描 + `saved_devices` / `recent_devices` / `readings` / `scenarios`。
- **智能**：本地 `rules` / `scan_logs` + 服务端场景。
- **产品 / 市场**：`GET /catalog/device-types`（类型 / GATT / 指标 / 限制 / 兼容性）+ `GET /device-types/{type}/catalog`（固件 / 配件）；本地 SQLite 仅缓存与断网兜底。
- **我的**：系统权限状态 + 扫描日志 + 同步状态。
- **设备详情**：云端 `GET /my/devices/ios/{externalId}` 优先，失败降级本地缓存；读数来自本地采集与云端汇总。
- 跨平台设备（`platform = android`）标注「来自 Android，本机不可连接」，不进入本机连接流程。

## 3. 网络契约

Base URL 由构建配置注入，不写死在源码：iOS 为 `Info.plist` 的 `BASE_URL`（`Config/*.xcconfig`，拼接 `/api/v1`）；Android 为 `BuildConfig.API_BASE_URL`。

| 用途 | 端点 |
| --- | --- |
| 匿名登录 / 刷新 / 登出 | `POST /auth/anonymous`、`POST /auth/refresh`、`POST /auth/logout` |
| 类型目录 / 型号 catalog | `GET /catalog/device-types`、`GET /device-types/{type}/catalog` |
| 设备详情（iOS） | `GET /my/devices/ios/{externalId}`；Android 用 `GET /my/devices/{mac}` |
| 增量拉取 / 批量推送 | `GET /sync/changes?cursor=&limit=`、`POST /sync/push`（`Idempotency-Key`） |
| 读数 | `GET /my/devices/{platform}/{externalId}/readings`、`.../readings/summary`、`.../readings/series`、`.../readings/metrics` |
| 家庭 / 成员 / 房间 | `/households`、`/households/{id}/members`、`/households/{id}/rooms`、`PUT /households/{id}/rooms/order` |
| 设备归属 | `PATCH /my/devices/{platform}/{externalId}`（`alias` / `roomId` / `householdId` 三态） |
| 场景 | `/scenes`（五字段 LWW，`DELETE` 软删） |
| 推送令牌 | `POST /push/devices`、`DELETE /push/devices/{deviceId}` |
| 反馈 | `POST /feedback`、`GET /feedback/mine`、`GET /feedback/{id}`、`PATCH /feedback/{id}` |

- 标识符：iOS 用 `platform + externalId` 复合键，不依赖 MAC；跨用户一律 404。
- 字段命名：JSON 为 camelCase，与 `PJGoIoT/api/openapi.yaml` 一致；契约只增不删。
- 错误体：`{"error":{"code":"...","message":"..."}}`。
- 时间：RFC3339 UTC，客户端编解码保留微秒。

## 4. 错误码与重试

客户端错误码（仅日志与反馈使用，不直接展示给用户）：`NET-001` 网络失败、`NET-002` 非 2xx、`NET-003` 解析失败、`NET-004` Base URL 非法、`DB-001` 本地库失败、`BT-004` 蓝牙前置条件不满足、`SYNC-001` 同步前置条件不满足。

服务端错误映射统一在 `Core/Networking/APIErrorCatalog.swift`：

| code | HTTP | 处理 |
| --- | --- | --- |
| `UNAUTHORIZED` | 401 | 单飞 `POST /auth/refresh` 后重放；刷新仍 401 才进入重新登录，且只清 token，保留本地数据 |
| `RESYNC_REQUIRED` | 410 | 清游标 + `cursor=0` 全量重拉，只处理一次，不进指数退避 |
| `TIMEOUT` / `UNAVAILABLE` / `INTERNAL` | 503 / 500 | 指数退避，不改游标、不重登 |
| `RATE_LIMITED` | 429 | 按 `Retry-After`（头优先）退避 |
| 其余 4xx（含 `CONFLICT`、`SCENE_*`） | 4xx | 终态，不自动重试，等用户修改后重提 |

「退出当前会话」只吊销本机 token，不删本地数据；「删除账号」才走两步删除令牌并清库。

## 5. 空状态与降级

- 无扫描记录、无设备、无规则、无读数等一律使用真实空状态 + 主行动，不展示假数据。
- 产品 / 市场请求失败或空列表：错误或空状态 +「重试 / 刷新」；市场页明确不提供下单、订单或支付。
- 设备详情网络失败但有缓存：降级显示缓存并标注缓存时间与错误码，不白屏；云端 `deviceType = null` 显示「型号未知」，别名 / 分组 / 最近出现照常展示。
- 有本地读数但云端失败：按同一 UTC 网格展示本地图表与汇总，标注「离线：本地数据」；30 天区间标注「离线：仅本地 7 天数据」。
- 家庭 / 房间无写权限：入口禁用 + 页脚说明；失败用 toast 展示可读文案，不展示 `FORBIDDEN` 码、不整页报错。
- 本地数据库不可用：回退内存库，应用仍可打开。

## 6. 权限

- iOS：`Info.plist` 声明 `NSBluetoothAlwaysUsageDescription` / `NSBluetoothPeripheralUsageDescription`，首次使用时由 `CBCentralManager` 触发系统授权，不额外弹自定义框。
- 「我的」页展示授权状态、蓝牙开关状态与跳系统设置入口；未授权 / 受限时给明确文案。
- 模拟器无真实蓝牙，状态通常为 `unsupported`，需真机验证真实授权与扫描。

## 7. 本地持久化与同步

iOS 使用 SQLite3（WAL / FULLMUTEX），业务表统一保留 `id`（UUID）、`updatedAt`、`deletedAt`、`syncState`（`pending` / `synced` / `pendingDelete`）。主要表：`saved_devices`、`rules`、`scan_logs`、`recent_devices`、`device_info_cache`、`readings`、`scenarios`（仅本机）、`rooms`、`households`、`device_assignment_pending`、`push_devices`。迁移逐版条件 ALTER，旧数据不重写。

**同步行为**

- 首次同步匿名登录，token 只存 Keychain；`expiresAt` 与游标存 UserDefaults。
- 增量拉取 `limit=200`（服务端上限 500），`hasMore` 继续，单次最多 10 页；本地无则插入，本地已同步则云端覆盖，未上传且云端更新则云端获胜并提示「另一台设备改过这条」。
- 批量推送每批设备 ≤100、读数 ≤200，幂等键由批次内容派生，重试复用同一键；成功标记 `synced`，失败保留 `pending`。
- 删除为软删 + `pendingDelete`，推送 `deleted: true`；拉取到删除写 tombstone。
- 前台节流 120 秒自动同步，后台用 `BGAppRefreshTask`（最早 15 分钟），手动同步不受节流限制。
- 可重试失败按指数退避（30s 起、上限 300s）；410 不进该退避。

**规则与信号**

- 断开：上一轮存在、本轮不再出现（iOS 以 10s 未出现判定）。
- RSSI 低于阈值：`rssi <= threshold` 触发一次，恢复后重新武装；Android 按同一比较符对齐。
- 指标阈值：满足 `comparison` + `reading_threshold` 且连续 `consecutive` 条（1–5，默认 1）触发一次。
- 规则仅本机，不参与 push / changes。
- RSSI 分档唯一口径见 `PKotlinApp/docs/rssi-signal-tiers.md`；iOS 用 `nil` 表示未知，非负占位值（`0` / `127`）与 `Int.min` 哨兵按未知处理，不显示为满格。展示与排序统一走 `RSISignalView.isValid` / `validRSSIMap`，不另设过滤。
- 设备详情：本机连接后每 **2 秒** `readRSSI` 一次（与 Android `readRemoteRssi()` 对齐），断开、页面退出、App 进后台即停表；未连接显示最近一次扫描值并标注「最近一次扫描」，连接中标注「实时读数」。刷新失败保留上一次值并标注「刷新失败」，无历史值或读到非负值时进入未知态。

**presence**

- 本机 BLE 已连接优先于云端 `presence`；`online` 只描述「900 秒内有上报」，不包装成权威在线。
- `lastSeenAt` / `presence` 是服务端只读派生字段：`lastSeenAt` 落 `server_last_seen_at`，不入 push、不置 pending、不推进本地 `updatedAt`；`presence` 不落库。
- 四档文案：本机已连接 / 云端 15 分钟内有上报 / 云端上报已超时 / 云端从未收到上报；跨平台设备另标「来自 Android，本机不可连接」。

## 8. 变更流程

1. 先改 `PJGoIoT/api/openapi.yaml`（只增不删）。
2. 更新本节端点 / 字段与两端 DTO。
3. 补单测与 e2e 断言；跨端行为变更需同时给出 Android 对应改动。
