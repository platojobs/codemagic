# 故障排查（iOS · v0.21.0）

按「现象 → 可能原因 → 处理」组织。命令默认在仓库根目录 `codemagic/` 执行。

---

## 1. Xcode 版本与模拟器

**现象**：`xcodebuild` 报 `unsupported Swift version`、`SDK does not support`，或模拟器列表里找不到目标设备。

**处理**
1. 确认工具链：
   ```bash
   xcodebuild -version          # 本地验证为 Xcode 27.2，CI 目标 16.4
   xcrun simctl list devices available
   ```
2. 指定一个**已安装**的模拟器，不要写死设备名：
   ```bash
   xcodebuild -project codemagic.xcodeproj -scheme codemagic \
     -destination 'platform=iOS Simulator,name=iPhone 17' \
     -derivedDataPath ./build build
   ```
   没有 iPhone 17 时替换为 `xcrun simctl list devices available` 中的任意可用机型。
3. 工程最低支持 **iOS 15.0**；用更低版本的模拟器会编译/运行失败。
4. 清理缓存后再试（`DerivedData` 损坏常导致莫名其妙的链接错误）：
   ```bash
   rm -rf ./build
   xcodebuild -project codemagic.xcodeproj -scheme codemagic \
     -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath ./build CODE_SIGNING_ALLOWED=NO build
   ```
5. **模拟器没有真实蓝牙**：`CBCentralManager` 状态为 `unsupported`，首页显示「当前环境不支持蓝牙」是预期行为，不是 Bug。

---

## 2. 签名与证书

**现象**：真机运行报 `No signing certificate "iOS Development" found`、`Provisioning profile doesn't match`；或 `codesign` 失败。

**处理**
1. 模拟器构建不需要签名，加上 `CODE_SIGNING_ALLOWED=NO` 即可；CI 也用这个开关。
2. 真机需要：
   - Xcode → Settings → Accounts 登录 Apple ID；
   - target `codemagic` → Signing & Capabilities 勾选 **Automatically manage signing**，选择 Team；
   - Bundle Identifier 必须与证书/描述文件一致（当前 `com.platojobs.codemagic`），被占用时改成本人唯一 ID。
3. 报「设备未注册」时，在 Xcode 的 Devices 窗口等待设备变为 Ready，或到开发者后台注册 UDID。
4. 修改 Bundle ID 后，**Keychain 的 service 名不会自动变化**（代码写死为 `com.platojobs.codemagic.sync`）。旧 token 仍可读到，但换签名 Team 后 Keychain 可能不可读，按第 3 节清理。
5. 仓库没有 Apple 开发者账号；Release 真机安装属于已知 BLOCKED，见 `docs/acceptance.md` V-04。

---

## 3. Keychain 异常（token 读不到 / 写入失败）

**现象**：日志出现「匿名登录成功，但 token 写入 Keychain 失败」；或每次启动都重新匿名登录；或 401 后一直无法恢复。

**可能原因**
- Keychain 访问组 / 签名变化（重装、换 Team、模拟器重置）；
- `kSecAttrAccessibleAfterFirstUnlock` 在设备未解锁时不可读（后台任务偶发）；
- 设备恢复备份导致 Keychain 项残留但不可读。

**处理**
1. 先看「我的 → 本地扫描日志」是否有 `sync` 类日志与 `OSStatus` 错误码。
2. 在模拟器上彻底重置：
   ```bash
   xcrun simctl uninstall booted com.platojobs.codemagic
   # 或 Device → Erase All Content and Settings
   ```
3. 真机上删除 App 后重装（Keychain 项默认随 App 删除保留，必要时在「设置 → 通用 → 传输或还原 iPhone → 还原」后重装）。
4. token 已失效（HTTP 401）时不要反复点「立即同步」，按第 3.1 节走重新登录。
5. 排查 Keychain 是否可写的最小验证：在「我的」完成一次同步，确认「匿名账号」从「尚未创建」变为具体 `userId`；若重启后又变回未创建，说明写入未持久化。

### 3.1 登录已失效（401）

- 现象：「我的」显示「登录已失效」，出现「重新登录」按钮。
- 这是 **token 过期/被作废**，客户端**不会自动建新匿名账号**（避免设备归属漂移）。
- 处理：点「重新登录」→ 确认弹窗 → 新账号创建后游标从 0 重置，本机设备重新上传；旧账号云端数据不会合并。
- 重登失败（断网/后端不可用）时保持「登录已失效」，恢复网络后再点一次即可；不会自动建号。

### 3.2 账号删除 / 数据导出（v0.20.0）

**删除账号**
- 409 `ACCOUNT_DELETION_BLOCKED`：当前账号仍是家庭 owner 且还有其他成员。按弹窗进入「家庭管理」→ 转让所有权或移除成员，再点「重试删除」；**同一个未消耗令牌仍有效**，不需要重新申请。
- 403 `DELETION_TOKEN_INVALID`：令牌过期（10 分钟）或被新的申请作废。按提示「重新申请」获取新令牌后再确认删除。
- 404：账号已不存在（例如同一令牌重放或本地清理失败后重试）。客户端按「已删除」处理，仍执行本地清空并回到未登录态。
- 网络中断：流程停在当前步骤并保留令牌 / 可重试，不会把用户踢回首页；恢复网络后重试即可。
- 删除成功后业务表与缓存全部清空，重启不会「复活」；若仍看到设备，检查是否停在旧 Tab 内存实例（`.accountDeleted` 会重建五个 Tab）。

**数据导出**
- 轮询间隔为 2.5s 起、×1.4、封顶 5s，不是每秒请求；任务长时间 `pending` 属正常，60 次后报超时并允许重试。
- 下载链接 10 分钟有效且一次性。若出现 410 `EXPORT_DOWNLOAD_EXPIRED`，点「重试导出」后客户端会自动重新查询任务并换取新链接（只自动重试一次），界面提示「下载链接已刷新」。
- 403 `EXPORT_DOWNLOAD_INVALID`：链接被篡改或与任务不匹配，重新导出即可。
- 文件写入临时目录，分享面板关闭即删除；异常退出后遗留文件会在下次清理时（1 天）删除。

### 3.3 场景（v0.21.0）

**列表显示「设备已移除」**
- 场景引用的设备已被删除。服务端读取时返回 `deviceMissing=true`，本地按 `(platform, externalId)` 也解析不到设备。
- 场景不会被级联删除，也不会静默失效：执行时跳过并写一条 `rule / warning` 日志（冷却窗口内不重复）。请重新保存该设备，或删除 / 修改场景。

**一直显示「待同步」**
- 新建 / 改名 / 停用 / 删除先在本地落 `pending`；断网、401 未重新登录或后端不可达时不会清除。恢复网络后进入「我的 → 立即同步」或在场景页重新进入触发同步。
- 若 `remoteId` 为空且上传失败，不会写回假的 `remoteId`；排障时可看同步结果里的场景失败项与错误码。

**两端同时改场景，有的字段没生效**
- 服务端是**字段级 LWW**：同一个字段以 `updatedAt` 较新的为准，不同字段互不覆盖。若设备时钟明显落后，自己的改动可能被判旧；请开启系统「自动设置时间」。
- 客户端重试时若上次 `POST` 已成功但响应丢失，会先 `GET /scenes` 用内容签名认领孤儿；仍出现重复通常是内容签名不一致，手动删除多余一条即可。

**定时场景不触发**
- 只有包含 `notify` 动作的启用场景会注册本地通知；点击通知需系统通知权限。`device_offline` / `rssi_below` / `metric_threshold` 依赖扫描或读数到达，不是纯定时任务。
- 时区使用 IANA 标识（如 `Asia/Shanghai`），`daysOfWeek` 1=周一。春季 DST 跳过的本地时间会顺延到下一个有效时刻，秋季重复时间取第一次，属预期行为。
- 修改触发条件后需要重新保存，调度会取消旧的 `scene-` 通知再按新配置注册。

**升级后旧场景不见了**
- v0.8.0 的手动场景迁移后是 `kind='manual'`、`sync_state='localOnly'`，在「智能 → 场景」的「仅本机场景」分区；它们不会上传，也不会被服务端场景覆盖。若整段列表为空，检查是否停在旧 Tab 实例或数据库打开失败（「我的」页会提示 `DB-001`）。

**创建场景返回 400 `SCENE_DEVICE_NOT_FOUND`**
- 触发条件引用的设备必须属于当前账号且未被删除。先在设备页保存该设备，或改用已存在的设备；设备删除后创建会失败，但已存在的场景会保留并显示 `deviceMissing`。

---

## 4. BGTask 未调度（后台同步不执行）

**现象**：App 进入后台后长时间没有同步；日志无后台同步记录。

**可能原因与处理**
1. **模拟器不执行后台刷新**，必须真机。
2. 系统开关被关闭：设置 → 通用 → 后台 App 刷新（全局与本 App 均需开启）；低电量模式会暂停后台任务。
3. `Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` 必须包含 `com.platojobs.codemagic.sync`；与 `SyncCoordinator.taskIdentifier` 不一致会导致注册失败。
4. 系统只保证「择机执行」，`earliestBeginDate = 15 分钟` 不是精确时间。排查时可手动触发：
   - Xcode 菜单 **Debug → Simulate Background Fetch**（需真机调试会话）；
   - 或在 LLDB 执行：
     ```
     e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.platojobs.codemagic.sync"]
     ```
5. 注册必须在 App 启动完成前（`AppDelegate`）完成；若日志无注册记录，检查 `SyncCoordinator.configure(engine:)` 是否被调用。
6. 后台任务回调必须 `setTaskCompleted`，否则系统会惩罚后续调度；本项目已在成功/失败/过期路径调用。

---

## 5. BASE_URL 配置与 mock 到期

**现象**：产品 / 市场一直报 `NET-004` 或加载失败；「我的 → 关于」显示的地址不对。

**处理**
1. 地址来自 xcconfig 注入 `Info.plist` 的 `BASE_URL`，源码不写死：
   - Debug → `Config/Debug.xcconfig` → `http://127.0.0.1:8080`
   - Release → `Config/Release.xcconfig` → `https://quickmock.dev/m/ecHT7ex3yQPA/`
2. 校验格式：必须是 `http(s)://host[:port][/path]`，缺失或非法时启动即提示 `NET-004`。
3. **mock 预计 2026-12-04 到期**：到期后 Release 构建的产品 / 市场会显示错误空状态与重试（不会 Crash）。正式域名确定后只需改 `Release.xcconfig` 并重新构建。
4. 临时覆盖：
   ```bash
   xcodebuild ... BASE_URL='https://your-host/' build
   ```
5. **真机不能访问 `127.0.0.1`**（那是手机自己）。真机联调需把 Debug 地址改成 Mac 的局域网 IP（如 `http://192.168.1.10:8080`），并确认 Go 服务监听 `0.0.0.0`。

---

## 6. Go 服务未启动 / 后端不可达

**现象**：同步报 `NET-001`；产品 / 市场空状态；`scripts/e2e-contract.sh` 健康检查超时。

**处理**
1. 确认服务与版本：
   ```bash
   cd ../PJGoIoT && git pull && git describe --tags        # 应为 v0.3.1
   curl -s http://127.0.0.1:8080/api/v1/health             # 期望 200
   ```
2. 本地启动（与 E2E 相同方式）：
   ```bash
   cd ../PJGoIoT
   STORE=fixture ADDR=127.0.0.1:8080 go run ./cmd/api
   ```
3. 若 App 显示 `NET-001` 而 `curl` 正常，检查：
   - 模拟器是否走代理 / VPN；
   - `Info.plist` 的 `NSAllowsLocalNetworking` 是否仍为 true（仅 Debug 本地 HTTP）；
   - 真机是否与 Mac 同一网段（见第 5 节第 5 点）。
4. 服务日志：E2E 模式写入 `codemagic/.build/e2e/pjgoiot-server.log`。

---

## 7. 端口占用（8080 / 18080）

**现象**：E2E 脚本报端口被占用；或 App 连不上本地服务。

**处理**
1. 查占用：
   ```bash
   lsof -nP -iTCP:8080 -sTCP:LISTEN
   lsof -nP -iTCP:18080 -sTCP:LISTEN
   ```
2. 结束占用进程（确认是自己的 Go 服务）：
   ```bash
   kill <PID>
   ```
3. E2E 脚本会优先 8080、被占用自动回退 18080；也可显式指定：
   ```bash
   E2E_PORT=18080 ./scripts/e2e-contract.sh
   ```
   注意：脚本使用 18080 时，Debug 的 `BASE_URL` 仍是 8080，App 内联调需同步改 xcconfig 或临时覆盖。
4. 启动前等待端口释放；反复失败可用 `lsof` 确认是否为上一次脚本残留进程。

---

## 8. 其它快速定位

| 现象 | 先查 |
| --- | --- |
| 同步一直「正在同步…」 | 上一次回调未返回；杀进程重开，检查网络 15s 超时与后端响应 |
| 数据库相关 `DB-001` | 「我的」启动提示；磁盘满 / 沙盒迁移；必要时重装（数据不跨启动保留时已回退内存库） |
| 产品 / 市场空列表但无错误 | 后端返回空 `items` 是正常空状态；确认 `GET /api/v1/catalog/device-types` 返回 `{version, generatedAt, items:[...]}`，且 `items` 中每项有 `metrics` |
| 断网后产品 / 市场仍显示旧目录 | 预期行为：`device_catalog_cache` 有缓存时展示缓存并在列表尾部标注「目录更新时间 / 离线缓存」；无缓存时才显示错误与重试。需要强制刷新时删除 App 数据或调用 `reload()` |
| 目录指标显示「当前版本不支持」 | 本地解析器未订阅该 `characteristicUuid`；属于如实标注，不是解析失败。新增本地解析器后即可自动转为普通展示 |
| 详情页显示「来自 Android，本机不可连接」 | 预期行为；iOS 无法连接 Android 设备 |
| 规则不触发 | 规则是否启用、绑定设备是否仍在列表、扫描是否进行中（首页离开会停止扫描） |

日志与证据统一入口：「我的 → 本地扫描日志」；构建/测试输出见 `README.md` 第 4 节。
