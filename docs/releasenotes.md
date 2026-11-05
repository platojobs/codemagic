# 版本发布说明（iOS · codemagic）

按 tag 记录真实变更。版本号与 `PJGoIoT` / `PKotlinApp` 保持同一序列；同一 tag 的 iOS 构建号见下表。

| Tag | MARKETING_VERSION | Build | 日期 | 对齐后端 |
| --- | --- | --- | --- | --- |
| `v0.4.0` | 0.4.0 | 11 | 2026-11-05 | readings 契约（main `7acab36`，未打 tag） |
| `v0.3.6` | 0.3.6 | 10 | 2026-11-05 | 0.3.3 |
| `v0.3.5` | 0.3.5 | 9 | 2026-11-05 | 0.3.2 |
| `v0.3.4` | 0.3.4 | 8 | 2026-11-05 | 0.3.2 |
| `v0.3.3` | 0.3.3 | 7 | 2026-11-05 | 0.3.2 |
| `v0.3.2` | 0.3.2 | 6 | 2026-11-05 | 0.3.1 |
| `v0.3.1` | 0.3.1 | 5 | 2026-11-05 | 0.3.1 |
| `v0.3.0` | 0.3.0 | 4 | 2026-11-05 | 0.3.0 |
| `v0.2.0` | 0.2.0 | 3 | 2026-11-05 | 0.2.0 |
| `v0.1.0` | — | 1 | 2026-11-05 | — |

---

## v0.4.0（build 11）

**主题：设备读数采集、存储、同步与展示**

### 新增
- CoreBluetooth 连接后订阅读数特征：心率 `0x2A37`、电量 `0x2A19`、温度 `0x2A6E`、Nordic UART TX `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`。
- 四个独立解析器：心率按 flags 取 uint8 / uint16；电量百分比；温度支持 0.01℃ sint16、IEEE-754 半精度与 float32；NUS 支持 `metric=value` 与纯数字文本行。解析失败静默丢弃并写本地「读数」日志，不崩溃、不写脏数据。
- SQLite 迁移 **v5** 新增 `readings` 表（`id` 主键、`device_id`、`metric`、`value`、`unit`、`recorded_at`、`sync_state`），本地保留 7 天，启动与同步成功后清理已同步过期数据。
- 读数并入 `POST /api/v1/sync/push`：每批 ≤200，按 `id` 幂等，失败重试复用同一幂等体；`readings` 为空时字段省略，兼容旧后端；响应解析 `appliedReadings` / `skippedReadings`。
- 读数查询客户端：`GET .../readings`（倒序、cursor）与 `GET .../readings/summary`（24h min/max/avg/last）。
- 设备详情新增「数据」区：指标选择（仅该设备真实已有指标）→ 最近 60 点自绘折线图（`draw(_:)` 手绘坐标轴/网格/折线/点，无第三方库）→ 24h 汇总 → 最近记录。
- 三种真实空状态：无读数「连接设备后开始采集」、蓝牙未授权指向系统设置、无数据不造假数据；云端汇总失败时展示本地数据并标注「离线：本地数据」。

### 测试
- 单测 **122 个**：解析器合法 / 非法 / 超长 / 非数字、幂等键含读数、7 天清理、v4→v5 迁移、折线图 0/1/60 点、同步批次与 skipped、详情指标切换与空状态。
- E2E **106 项**：新增第 7 节 19 项——推送读数、倒序、summary、重复 id skipped、非法 NaN 400；后端未发布 readings 时能力门控 `[SKIP]`，不伪造 PASS。
- `xcodebuild build` 与 `xcodebuild test` 全绿。

---

## v0.3.6（build 10）

**主题：接入 openapi 0.3.3 —— 别名与广播名分离 + 缺省字段三态**

### 新增
- `UserDevice.advertisedName`：服务端设备广播名，与用户别名分离。
- 本地迁移 **v4**：`saved_devices` 增加 `advertised_name TEXT`（由历史 `name` 回填）与 `alias_patch` / `advertised_name_patch` / `group_patch` 三态列。
- `Patch<String>` 三态（`absent` / `clear` / `set`）+ `PushDevice` 自定义 `encode`：未上报字段完全省略，显式清除编码 `""`。

### 变更
- 扫描只写 `advertisedName`，用户编辑只写 `alias`，互不覆盖；列表/详情展示顺序：用户别名 → 广播名 → 型号名/型号键。
- 删除分组上报 `"group": ""`；未修改分组时省略字段，不编码空串。清空后再次同步不会复活旧分组。
- 幂等键改为按上报字段的规范化 JSON 计算，absent 字段不参与哈希；同内容重试/换键均不触发 409。
- 冲突响应中缺省的可选字段按 `absent` 解析，合并时保留本地值（`RemoteDevice.alias` / `advertisedName` / `group` 改为可选）。
- `MARKETING_VERSION 0.3.6` / build 10。

### 验证
- `xcodebuild test`：**81 个用例，0 失败**（新增三态编码、别名/广播名隔离、清空分组不复活、幂等键稳定、v4 迁移与 patch 持久化）。
- `scripts/e2e-contract.sh`（后端 0.3.3，fixture）：**87 项断言全部 PASS**，新增 3.7 的 16 项（扫描只写广播名、编辑别名不覆盖、缺省 group 保留、`""` 清除、重放不 409）。

---

## v0.3.5（build 9）

**主题：CI 与 Android 对齐（e2e 入 CI + action 升级）**

### 新增
- `.github/workflows/ios.yml` 新增并行 job `e2e-contract`：checkout 本仓库 + `platojobs/PJGoIoT`（`path: PJGoIoT`）→ `actions/setup-go@v7`（`go-version-file: PJGoIoT/go.mod`）→ `PJGOIOT_DIR=${{ github.workspace }}/PJGoIoT bash scripts/e2e-contract.sh`；失败时上传 `.build/e2e/` 日志。

### 变更
- `actions/checkout@v4 → v7`、`actions/upload-artifact@v4 → v7`、`actions/setup-go@v5 → v7`，Node 20 弃用告警消除。
- `concurrency` 由按 ref 改为按 `github.sha` 分组：同一提交既推 main 又打 tag 时只跑一次，后到运行取消先到运行。
- `MARKETING_VERSION 0.3.5` / build 9。

### 验证
- CI run [41906015761](https://github.com/platojobs/codemagic/actions/runs/41906015761)：**success**
  - `build-test` 4m44s：`** BUILD SUCCEEDED **`、`Executed 74 tests, with 0 failures`、`** TEST SUCCEEDED **`，xcresult artifact 已上传；
  - `e2e-contract` 约 1m16s：`通过：71 项，失败：0 项`、`结论：PASS`。
- 本地 `PJGOIOT_DIR=... bash scripts/e2e-contract.sh`：71 项全部 PASS。

---

## v0.3.4（build 8）

**主题：GitHub Actions CI 首次真实运行**

### 新增
- `.github/workflows/ios.yml`：`runs-on: macos-15`，checkout → 选择 Xcode 16.4 并打印版本/模拟器 → `xcodebuild build`（generic iOS Simulator）→ `xcodebuild test`（动态选首个可用 iPhone 模拟器）→ 上传 `*.xcresult`。
- 触发仅 `push` 到 `main` 与 `v*` tag（另有手动 `workflow_dispatch`），PR 不跑；macOS runner 计费高于 Linux，用 `concurrency` 取消同 ref 重复运行。

### 修复
- 首次 workflow 因 `run: |` 内多行 Python 未随块缩进导致 YAML 解析失败（无任何 job，run 直接 failure）；改为单行 `simctl + grep/sed` 提取模拟器 UDID 后通过。

### 验证
- GitHub Actions run [41902292283](https://github.com/platojobs/codemagic/actions/runs/41902292283)：**success**，Xcode 16.4，`** BUILD SUCCEEDED **`、`Executed 74 tests, with 0 failures`、`** TEST SUCCEEDED **`，xcresult 已作为 artifact 上传。
- `codemagic.yaml` 保留为可选替代方案，仍未在 Codemagic 上运行。
- `MARKETING_VERSION 0.3.4` / build 8。

---

## v0.3.3（build 7）

**主题：接入 openapi 0.3.2 新字段**

### 新增
- **设备详情**：展示云端 `deviceType` / `vendor` / `firmwareVersion` / `compatibility`；`compatibility` 按「平台 / 协议 / 特性 / 最低 App / 型号」摊平，并以「；」连接。云端优先，本地缓存仅断网降级。
- **null 语义**：`deviceType` 为 `null` 显示「型号未知」，厂商 / 固件显示「—」，兼容性显示「暂无兼容性说明」；不渲染 `"null"` 或空串。未注册型号仍展示别名、分组与最近出现时间，并新增「云端记录」区展示同步信息。
- **市场筛选**：顶部「厂商：全部/xx」「兼容性：全部/xx」，取值来自服务端真实 `vendor` 与 `compatibility` 展开字段，可叠加、可清除；刷新后自动清除失效筛选；无结果显示「没有符合筛选条件的条目」。
- **catalog**：`firmwares[]` / `accessories[]` 解析 `vendor` 与 `compatibility`（配件 `deviceTypes` 映射为「型号」）；产品 / 市场详情展示真实厂商与兼容性。

### 变更
- `PushDevice` 增加可选 `deviceType`：设备详情拿到云端型号后写回本地，下次推送带上；无法推导时整体省略，不填假值。
- SQLite 迁移 **v3**：`saved_devices` 增加 `device_type TEXT`（可空），旧库升级后为 `NULL`。
- `MARKETING_VERSION 0.3.3` / build 7。

### 修复
- 固件 / 配件不再用所属型号厂商兜底，避免展示未经核实的厂商。

### 验证
- `xcodebuild build`：`** BUILD SUCCEEDED **`
- `xcodebuild test`：**74 个用例，0 失败**
- `scripts/e2e-contract.sh`（后端 0.3.2，fixture）：**71 项断言全部 PASS**，新增 catalog `vendor` / `compatibility` 与 `UserDevice` 新字段、null 降级断言

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
