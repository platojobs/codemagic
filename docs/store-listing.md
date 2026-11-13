# App Store 上架材料（iOS v0.31.11）

> 状态：**材料已补齐，但尚未上传 App Store Connect、尚未提交审核、未上架**。
> 本机没有 Apple Developer Program 账号，也没有任何 App Store 审核记录；仓库中没有分发证书、
> Provisioning Profile 与 APNs 推送证书。`MARKETING_VERSION 0.31.11` / `CURRENT_PROJECT_VERSION 52`
> 只用于模拟器构建与 CI，不能直接提交商店。
>
> 本文只描述仓库中**已实现并有代码证据**的能力。未实现的能力（账号密码、云备份、OTA、
> 内购、广告、真实 APNs 推送）一律不写入商店文案。

## 1. 基本信息

| 项 | 值 |
| --- | --- |
| 应用名称（中文，≤30 字符） | `codemagic：蓝牙设备读数`（16 字符） |
| 应用名称（英文，≤30 字符） | `codemagic: BLE Readings`（23 字符） |
| 副标题（中文，≤30 字符） | `扫描、读数、曲线与阈值告警`（13 字符） |
| 副标题（英文，≤30 字符） | `Scan, read, chart, alert`（24 字符） |
| Bundle ID | `com.platojobs.codemagic` |
| 版本 | `MARKETING_VERSION 0.31.11`、`CURRENT_PROJECT_VERSION 52` |
| 默认语言 | 中文（简体）；另含英文 `en` |
| 主分类 | 工具 |
| 次分类 | 效率 |
| 内容分级 | **4+**（无广告、无博彩、无公开用户生成内容、无医疗诊断结论） |
| 价格 / 内购 / 广告 | 免费 / **无** / **无** |
| 账号体系 | 无账号密码；首次启动自动创建匿名账号，token 只存本机 Keychain |
| 隐私政策 | `docs/privacy-policy.md`（**尚未发布为公网可访问 URL**，上架前必须补齐） |
| 联系方式 | https://github.com/platojobs/codemagic/issues |

## 2. 促销文本（≤170 字符）

**中文（72 字符）**

```
连接附近的 BLE 设备，实时查看心率、温度、电量与信号；保留历史曲线，按阈值本地提醒。支持多家庭与房间、匿名账号同步；无广告、无内购、无交易。
```

**English（167 字符）**

```
Connect nearby BLE devices to see heart rate, temperature, battery and signal, keep charts, and get threshold alerts. Multi-home, anonymous sync, no ads, no purchases.
```

## 3. 完整描述（≤4000 字符）

**中文（1387 字符）**

```
codemagic 是一个本机优先的蓝牙设备读数面板：连接附近的 BLE 设备，看清读数变化，并把设备、读数与规则同步到匿名账号。

【首页】
· 设备卡片显示名称、连接状态、最近一条读数与信号强度；支持搜索、排序与分组筛选。
· 按房间分段展示，房间头可折叠；「未分配」固定最后。
· 「今日告警摘要」显示当天真实触发条数，点按进入「智能」。
· 「快捷场景」展示前 3 个本机场景，一键执行并逐条给出结果。

【设备读数】
· 连接后订阅并解析心率（0x2A37）、电量（0x2A19）、温度（0x2A6E）与 Nordic UART TX（6E400003）特征。
· 历史曲线支持 1 小时、24 小时、7 天、30 天；按桶起止时间定位，缺口断线，展示平均值与最小–最大区间。
· 读数与时间戳写入本机 SQLite，联网时按匿名账号同步；可导出 CSV 经系统分享发出。
· 设备详情优先读取服务端，断网时回退本地缓存并标注「离线：本地数据」。

【智能】
· 自动化规则：断开连接、RSSI 低于阈值、指标越界；可增删启停，保留最近 5 条真实触发。
· 场景把「连接设备 / 断开设备 / 开始或停止后台采集 / 静音告警 10、30、60 分钟 / 立即同步」组合成本机有序动作，一键执行；失败不阻断后续并汇总原因。
· 通知权限被拒绝时仍会注册推送令牌（如已配置推送），但通知不会展示。

【家庭与房间】
· 支持创建多个家庭与房间、邀请成员、签发或撤销一次性邀请码、转让或退出家庭。
· 房间支持拖拽排序；设备可移动到指定房间。
· 服务端房间为权威来源，离线编辑会标注「未同步」。

【产品与市场】
· 产品页展示服务端设备类型目录：类型、GATT 服务、指标、限制与兼容性。
· 市场页展示配件与固件条目；只读信息，不包含购物车、下单、支付或任何交易。

【账号与数据】
· 首次启动自动创建匿名账号，无需注册或密码；token 仅存本机 Keychain。
· 支持用 8 位一次性接管码在新设备接管同一账号、导出我的数据、注销账号。
· 注销会删除服务端账号，并先停用已注册的推送设备，再清理本机 Keychain、业务表与同步元数据。
· 服务端读数保留 90 天；本机已同步读数保留 7 天，未同步读数保留到补传成功。

【后台采集】
· 声明 bluetooth-central：仅在设备保持连接时于后台接收读数；iOS 可能延后唤醒，断开后停止采集。
· 可在「我的」关闭后台采集。

【隐私与安全】
· 无广告 SDK、无统计分析 SDK、无第三方 UI 或网络依赖；不收集位置、通讯录、照片、麦克风、IDFA。
· 数据只发送到本 App 配置的服务端，Release 走 HTTPS；不含广告、内购与订阅。
· 详见 docs/privacy-policy.md。

【已知限制】
· 需要设备本身支持标准 GATT 服务或 NUS 透传；未实现 OTA 固件升级与 GATT 写入。
· 当前构建未配置推送证书与 aps-environment entitlement，拿不到 APNs 令牌，因此推送注册显示「未配置推送」，告警只在本机通知中展示。
· 本 App 不是医疗设备，心率等读数仅供日常参考，不构成诊断或治疗建议。
```

**English（3138 字符）**

```
codemagic is a local-first dashboard for Bluetooth Low Energy device readings. It connects to nearby BLE devices, shows live readings and history, and syncs devices, readings and rules to an anonymous account.

Home: device cards with name, connection state, latest reading and signal strength; search, sort and group filters; room sections with collapsible headers; a real "today's alerts" count; and up to three local quick scenarios with per-action results.

Readings: after connecting, the app subscribes to Heart Rate (0x2A37), Battery (0x2A19), Temperature (0x2A6E) and Nordic UART TX (6E400003), stores readings and timestamps locally, draws 1-hour / 24-hour / 7-day / 30-day charts, and exports CSV through the system share sheet. Device detail prefers the server and falls back to the local cache offline.

Smart: automation rules for disconnect, low RSSI and out-of-range metrics, with the latest five real triggers. Local scenarios combine connect, disconnect, start/stop background collection, mute alerts for 10/30/60 minutes and sync now; actions run in order and a failure does not block the rest. If notification permission is denied, the push token is still registered when push is configured, but notifications are not shown.

Households and rooms: create multiple households and rooms, invite members, issue or revoke one-time invite codes, transfer or leave a household, reorder rooms and move devices between rooms. The server is the source of truth for rooms; offline edits are marked unsynced.

Products and Market: read-only device type catalog (types, GATT services, metrics, limits, compatibility) plus accessory and firmware entries. No cart, ordering, payment or other transactions.

Account and data: an anonymous account is created on first launch, with no registration or password; the token is stored in the local Keychain. An existing account can be claimed on a new device with an 8-character one-time code. You can export your data or delete the account; deletion removes the server account, deactivates registered push devices first, then clears local Keychain, business tables and sync metadata. Readings are kept 90 days on the server and 7 days locally once synced.

Background: the app declares bluetooth-central and receives readings in the background only while a device stays connected. iOS may defer wake-ups; collection stops after disconnect and can be turned off in Me.

Privacy and security: no ad SDK, no analytics SDK, no third-party UI or networking dependencies; no location, contacts, photos, microphone or IDFA. Data is sent only to the service configured by this app over HTTPS in Release builds. No ads, in-app purchases or subscriptions.

Known limitations: devices must support standard GATT services or NUS passthrough; OTA firmware updates and GATT writes are not implemented. This build has no push certificate or aps-environment entitlement, so it cannot obtain an APNs token and push registration shows "not configured"; alerts are local notifications only. codemagic is not a medical device. Readings are for general reference only and are not diagnosis or treatment advice.
```

字符数可按以下方式复核（含标点，不含代码块围栏）：

```bash
python3 - <<'PY'
import pathlib, re
text = pathlib.Path("docs/store-listing.md").read_text(encoding="utf-8")
for section in re.split(r"^## ", text, flags=re.M):
    if section.startswith(("2. 促销文本", "3. 完整描述", "4. 关键词")):
        for chunk in section.split("```")[1::2]:
            print(section.splitlines()[0], len(chunk.strip()))
PY
```

## 4. 关键词（≤100 字符，逗号分隔）

**中文（46 字符）**

```
蓝牙,BLE,设备读数,心率,温度,电量,历史曲线,阈值告警,家庭,房间,数据同步,设备面板
```

**English（66 字符）**

```
bluetooth,ble,sensor,readings,heart rate,chart,alerts,home,devices
```

## 5. 隐私营养标签（Privacy Nutrition Labels）

与 [`PrivacyInfo.xcprivacy`](../codemagic/Resources/PrivacyInfo.xcprivacy)、[`docs/app-privacy.md`](app-privacy.md)
和实际本地存储 / 服务端上报逐项对齐。所有类别均为 **不用于追踪（Tracking = No）**、
**与匿名账号关联（Linked = Yes）**、用途 **App Functionality**。

| App Store 类别 | 具体数据 | 清单键 | 本地存储 | 服务端 | 触发条件 |
| --- | --- | --- | --- | --- | --- |
| 标识符 → 设备 ID | BLE 外设 `CBPeripheral.identifier`（大写 UUID） | `NSPrivacyCollectedDataTypeDeviceID` | `saved_devices` / `device_info_cache` | `user_devices.external_id` | 扫描并保存设备后（**当前版本 DeviceID 唯一实际采集项**） |
| 标识符 → 设备 ID | **APNs 推送令牌**（`push_devices.token`） | `NSPrivacyCollectedDataTypeDeviceID` | `push_devices`（迁移 v16；当前只存状态 / 错误） | `push_devices.token` | **仅配置推送证书与 entitlement 后**；当前构建不产生、不上报 |
| 标识符 → 用户 ID | 匿名 `userId`、Keychain token | `NSPrivacyCollectedDataTypeUserID` | Keychain + `sync_metadata` | `users.id` | 首次匿名登录 |
| 健康与健身 → 健康 | 心率读数（特征 `0x2A37`） | `NSPrivacyCollectedDataTypeHealth` | `readings`（7 天） | `readings`（90 天） | 设备上报心率时 |
| 其他数据类型 | 温度、电量与 NUS 透传指标值、单位、`recordedAt` | `NSPrivacyCollectedDataTypeOtherDataTypes` | `readings`（7 天） | `readings`（90 天） | 设备上报对应指标时 |
| 使用数据 → 其他使用数据 | 读数时间戳、规则触发记录、本机扫描日志、同步元数据、设备最近上报时间（服务端 `lastSeenAt`，用于推导 `presence`；客户端只读、不上报） | `NSPrivacyCollectedDataTypeOtherUsageData` | `readings` / `scan_logs` / `sync_metadata` / `saved_devices.server_last_seen_at` | 规则与触发记录；设备读数被 `/sync/push` 接受时由服务端记录接收时间 | App 运行、规则命中与读数上报时 |
| 用户内容 → 其他用户内容 | 设备广播名 / 别名 / 分组；家庭名与房间名；反馈主题与正文 | `NSPrivacyCollectedDataTypeOtherUserContent` | `saved_devices` / `households` / `rooms` / `feedback_drafts` | 对应业务表 | 用户输入或蓝牙广播 |
| 联系信息 → 其他用户联系信息 | 反馈页**可选**联系方式（自由文本） | `NSPrivacyCollectedDataTypeOtherUserContactInfo` | `feedback_drafts.contact` | `feedback.contact` | 仅在用户主动填写并提交反馈时 |
| 诊断 → 其他诊断数据 | 反馈附带的 App 版本、iOS 版本、设备型号 | `NSPrivacyCollectedDataTypeOtherDiagnosticData` | `feedback_drafts.client_context` | `feedback.client_context` | 仅在提交反馈时 |
| 推送令牌归类说明 | 推送令牌本质是设备标识，归入 **标识符 → 设备 ID**，不单独建立类别 | 同上 | — | — | 当前未配置推送 |

**数据不用于追踪、不出售、不与第三方广告共享。** 不收集位置、通讯录、照片、麦克风、IDFA、
浏览历史或搜索历史；无第三方 SDK。

**8 类一致性**：`PrivacyInfo.xcprivacy` 的 `NSPrivacyCollectedDataTypes` **恰好 8 个键**，与上表 8 个「清单键」逐项一致；上表有 9 行数据，但「BLE 外设 UUID」与「APNs 推送令牌」两行同属 `DeviceID`，不是第 9 类。`PrivacyManifestTests` 会解析清单与本文并断言键集合完全相同，防止一边 8 类、另一边另一套。

**APNs 令牌当前不采集**：当前二进制（0.31.9/build 49）没有 `aps-environment` entitlement，`registerForRemoteNotifications` 拿不到令牌，`PushRegistrationService` 停在 `missingToken`，本地 `push_devices` 仅记录状态与错误，**不写占位 token、不调用 `POST /push/devices`**。因此隐私问卷中 DeviceID 的实际内容只有 BLE 外设 UUID。启用推送时必须同步修改：① 工程增加 `aps-environment` entitlement 与 APNs 证书；② `Core/Notifications/APNSTokenProvider.swift` 取真实令牌；③ 本表「触发条件」改为「配置推送后即采集」；④ 审核备注移除「推送服务当前未配置」；⑤ `docs/privacy-policy.md` 与 `docs/app-privacy.md` 同步改写；⑥ `PrivacyManifestTests` 复核。完整清单见 [`app-privacy.md`](app-privacy.md) 2.2 节。

> v0.27.0 在清单中新增 `OtherDataTypes`、`OtherUserContactInfo`、`OtherDiagnosticData` 三类以覆盖传感器指标、反馈可选联系方式与客户端诊断；v0.28.0 **未新增类别**，只把 APNs 令牌的「当前不采集」边界写清；v0.31.5 接入后端 `lastSeenAt` / `presence` 后**仍未新增类别**——设备最近上报时间属于「使用数据 → 其他使用数据」（同步元数据），`PrivacyInfo.xcprivacy` 键集合仍恰好 8 类。`plutil -lint` 已通过。

## 6. 审核备注（给 App Review）

- **蓝牙权限**：`NSBluetoothAlwaysUsageDescription` / `NSBluetoothPeripheralUsageDescription`
  说明用于扫描、连接 BLE 设备并读取读数；`UIBackgroundModes` 仅 `bluetooth-central` 与 `fetch`。
  拒绝蓝牙权限时 App 仍可查看已保存设备与历史读数，并展示「仅本机可用」与「去系统设置」。
- **没有真实蓝牙设备时**：首页显示空态与「开始扫描」，不会伪造设备或读数；「智能」可创建规则与
  场景，但没有设备时不会产生触发记录；产品与市场为服务端只读目录，可直接浏览。审核无需配对外设
  即可完成大部分界面检查。
- **推送服务当前未配置**：审核构建没有 APNs 证书与 `aps-environment` entitlement，
  `registerForRemoteNotifications` 拿不到令牌；界面如实显示「未配置推送 · 无法获取令牌」，
  不会注册占位 token，也不会出现远程推送。通知权限仅用于本地阈值告警；拒绝后仍会完成注册尝试，
  但明确提示「未授权通知，推送不会展示」。
- **匿名账号**：首次启动自动创建，无需登录、无测试账号；注销入口在「我的 → 注销账号」，
  删除前会先 `DELETE /push/devices/{deviceId}` 停用推送设备。
- **交易与广告**：无内购、无订阅、无支付、无广告、无外链商城。
- **反馈**：仅由用户在「我的 → 意见反馈」主动提交，含主题、正文与可选联系方式；不会公开展示。

## 7. 商店截图现状

- **iPhone 6.9 英寸**：已在 **iPhone 18 Pro Max · iOS 27.2 模拟器** 导出整组 **18 张**，尺寸 **1320×2868**，落在 [`docs/screenshots/`](screenshots/)，文件名与原截图集完全一致。逐张核对内容与标题对应：`profile.png` 从「登录会话」分区开始，完整显示「阈值告警」4 行（含「推送注册 = 未配置推送」）与三行说明，顶部无半行、底部未被悬浮 Tab 条带切断（Tab 顶边 873pt / 条带高 83pt，条带内无业务节点）。
- **iPad 13 英寸**：工程 `TARGETED_DEVICE_FAMILY = "1,2"`，`Info.plist` 声明 iPad 四个方向，且**没有** `UIRequiresFullScreen`（即支持 iPad 多任务、非全屏强制），因此 iPad 规格为必需项。已在 **iPad Pro 13-inch (M5) · iPadOS 27.2 模拟器** 导出同名 18 张，尺寸 **2064×2752**，落在 [`docs/screenshots/ipad-13/`](screenshots/ipad-13/)。iPad 顶部为系统浮动 Tab 栏，不存在底部条带遮挡，截图按内容可视区顶部对齐。
- 两组截图均为「模拟器 + 本机 Postgres 后端 + seed 数据」，页面内可见匿名账号 UUID 与本地后端地址，**不是生产环境截图**；上架前如需隐藏本机信息，应另用生产配置重截。
- 旧的 1206×2622（iPhone 18 Pro）原图已被本组替换，不再作为商店候选。

## 8. 明确未完成 / 未验证

| 项 | 状态 |
| --- | --- |
| 上传 App Store Connect | **未上传** |
| Apple Developer Program 账号 | **无** |
| App Store 审核记录 | **无** |
| 分发证书与 Provisioning Profile | **无**（仓库仅有模拟器构建） |
| APNs 推送证书与 `aps-environment` entitlement | **无**，远程推送未验证 |
| 公网隐私政策 URL | **未发布**（仅仓库内 Markdown） |
| 商店规格截图（6.9 英寸 1320×2868） | **已导出 18 张**（iPhone 18 Pro Max 模拟器） |
| iPad 13 英寸规格截图（2064×2752） | **已导出 18 张**（iPad Pro 13-inch (M5) 模拟器） |
| 生产环境 / 隐藏本机信息的商店截图 | **未重截**（当前可见本地后端地址与匿名账号 UUID） |
| 真机 BLE 读数 / 图表 / 后台采集 | **未验证**（无真机与外设） |
| App Store 隐私问卷实际提交 | **未填写**（本文仅为填写依据） |
