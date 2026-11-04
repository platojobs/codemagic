# 版本发布说明（iOS · codemagic）

按 tag 记录真实变更。版本号与 `PJGoIoT` / `PKotlinApp` 保持同一序列；同一 tag 的 iOS 构建号见下表。

| Tag | MARKETING_VERSION | Build | 日期 | 对齐后端 |
| --- | --- | --- | --- | --- |
| `v0.3.2` | 0.3.2 | 6 | 2026-11-05 | 0.3.1 |
| `v0.3.1` | 0.3.1 | 5 | 2026-11-05 | 0.3.1 |
| `v0.3.0` | 0.3.0 | 4 | 2026-11-05 | 0.3.0 |
| `v0.2.0` | 0.2.0 | 3 | 2026-11-05 | 0.2.0 |
| `v0.1.0` | — | 1 | 2026-11-05 | — |

---

## v0.3.2（build 6）

**主题：文档补齐 + 登录失效交互**

### 新增
- `docs/acceptance.md`：真机验收清单，覆盖五模块逐页走查、蓝牙授权三态、真实扫描与 RSSI、连接与断开规则、12s 超时、Android 设备不可连接、断网与同步降级、`BGAppRefreshTask`、Release 域名切换；每项含步骤 / 预期 / 失败判定。
- `docs/troubleshooting.md`：Xcode 与模拟器、签名证书、Keychain 异常、BGTask 未调度、BASE_URL 与 mock 到期、Go 服务未启动、端口占用等排查路径。
- `docs/releasenotes.md`：本文件。

### 变更
- **401 交互**：「我的」页在 token 失效时明确展示「登录已失效」，并提供「重新登录」入口；点击后弹出确认框，说明「旧账号云端数据不会自动合并，本机设备会重新上传到新账号」，用户确认后才创建新匿名账号。
- 重新登录时重置同步游标（从 0 拉取），并把本机全部活动设备重新标记为待上传，避免换号后云端缺数据。
- 登录失效状态持久化（UserDefaults `sync.reloginRequired`）：后台 / 前台自动同步不会静默新建匿名账号；重登失败同样保持待重新登录。
- `AppError` 增加 `isUnauthorized`，401 在状态区显示专门的降级文案并写入同步日志。

### 修复
- 重新登录失败（断网）后不再回退到自动匿名登录，避免设备归属漂移。

### 验证
- `xcodebuild build`：`** BUILD SUCCEEDED **`
- `xcodebuild test`：**68 个用例，0 失败**
- `scripts/e2e-contract.sh`（后端 0.3.1，fixture）：55 项断言全部 PASS

---

## v0.3.1（build 5）

**主题：对齐 openapi 0.3.1**

### 变更
- 产品：`GET /api/v1/device-types`（兼容 `{items}` 与裸数组）+ 逐个 `GET /api/v1/device-types/{type}/catalog`。
- 市场：由同一批 catalog 聚合 `firmwares` + `accessories`，不再请求 `api/market`。
- iOS 设备详情：改用 `GET /api/v1/my/devices/ios/{externalId}` 复合键（大写 UUID + Bearer token），不再请求 `api/device/{peripheralUUID}`。
- 新增 `Core/Models/DeviceCatalog.swift`（`FirmwareInfo` / `AccessoryInfo` / `DeviceCatalog` / `UserDeviceInfo`），catalog 解析容忍缺失与未知字段。
- 单个 catalog 失败只降级该型号；全部失败才整页报错。
- 无 token 时设备详情返回 `SYNC-001`，不发起请求、不创建匿名账号。

### 文档
- `docs/consistency.md`：版本行改为 0.3.1；接口表补 `device-types` / `catalog` / 复合键 / 按 MAC 查询；401 语义明确「需用户重新登录，不得静默建号」；删除全部「仍为历史端点」条目，仅保留「`/api/v1/devices/{mac}` 仍可用但仅 Android 使用」。
- `KNOWN_ISSUES.md`：记录 catalog 无 compatibility、无 vendor，`UserDevice` 无 `deviceType` 等结构差异。

### 验证
- 单元测试 64 个，0 失败；E2E 扩至 55 项（含 catalog 与复合键 200/404）。

---

## v0.3.0（build 4）

**主题：版本对齐 + 端到端契约联调**

### 新增
- `scripts/e2e-contract.sh`：从 `../PJGoIoT` 以 `STORE=fixture` 构建并启动 Go 服务（8080 → 18080 回退），健康检查后运行独立 Swift runner，结束自动清理。
- `scripts/e2e-contract.swift`：真实 `URLSession` 直连本地服务的联调 runner，覆盖匿名登录、双平台推送、changes 形状、幂等重放、LWW 冲突、401/404。

### 变更
- `MARKETING_VERSION 0.3.0` / build 4；保留 `v0.2.0` tag 不重打。
- Android 设备在「设备」列表标注「来自 Android，本机不可连接」，无展开箭头、禁用点击与连接入口；详情页增加守卫。
- `docs/consistency.md` 按 `openapi.yaml` 修正错误码、`platform` / `externalId` 与同步触发说明。

### 验证
- 单元测试 63 个；E2E 43 项断言 PASS（随后 docs 修正分组计数）。

---

## v0.2.0（build 3）

**主题：同步层落地**

### 新增
- 匿名登录 `POST /api/v1/auth/anonymous`，token 存 Keychain（`KeychainTokenStore`）。
- 增量拉取 `GET /api/v1/sync/changes`（游标持久化、`hasMore` 最多 10 页）。
- 批量推送 `POST /api/v1/sync/push`（每批 ≤100、`Idempotency-Key` 由批次内容哈希派生、重试复用）。
- 冲突处理：服务端 LWW 获胜时写回云端版本并提示「另一台设备改过这条」，不静默覆盖本地修改；tombstone 上传 / 写回。
- `BGAppRefreshTask`（`com.platojobs.codemagic.sync`）与前后台触发（前台 120s 节流）。
- 「我的」同步区：上次同步时间、待上传、立即同步、匿名账号、错误码与降级说明。

### 迁移
- SQLite 迁移 v2：`saved_devices` 增加 `platform` / `external_id`，由 `peripheral_id` 大写回填，并建立 `(platform, external_id) WHERE deleted_at IS NULL` 唯一索引；旧库升级无需重装。

---

## v0.1.0（build 1）

**首个可用版本**

- 五模块：首页 / 设备 / 产品 / 市场 / 我的，纯 Swift + UIKit（无 Storyboard / XIB）。
- CoreBluetooth 真实扫描（名称 / 标识符 / RSSI）、连接（12s 超时）、断开回调。
- SQLite3 持久化：`saved_devices` / `rules` / `scan_logs` / `recent_devices` / `device_info_cache`；软删除与 `sync_state`。
- 网络层：URLSession + Codable，`BASE_URL` 由 xcconfig 注入 `Info.plist`；产品 / 市场 / 设备详情（当时为历史端点）。
- 本地规则：断开、RSSI 低于阈值；触发写扫描日志并在首页提示。
- 自绘 `RSISignalView`、代码组装 `EmptyStateView`；设备详情网络失败降级本地缓存。
- 44 个单元测试；Codemagic CI 配置（构建 + 测试 + artifact）。

---

## 发布流程（维护者）

1. 改代码与文档 → `xcodebuild build` + `xcodebuild test` 通过。
2. 跑 `./scripts/e2e-contract.sh`（后端同步到对应版本）并记录输出。
3. 更新本文件、`README.md` 第 10 节、`docs/consistency.md` 版本行。
4. 提升 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`（`codemagic.xcodeproj/project.pbxproj` 的 app Debug + Release 两处）。
5. 提交推送 `main`，创建 **annotated** tag 并推送；**不重打或强推已有 tag**。
