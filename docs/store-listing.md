# App Store 上架材料（v0.9.0）

> 只描述已实现能力，不写规划、不写未验证能力。版本与 `docs/releasenotes.md` 的 `v0.9.0（build 17）` 一致。

## 1. 基本信息

| 项 | 填写建议 |
| --- | --- |
| App 名称（30 字内） | `codemagic：蓝牙设备读数` |
| 副标题（30 字内） | `扫描、读数、曲线与阈值告警` |
| 主分类 | 工具 |
| 次分类 | 效率 |
| 内容分级 | **4+**（无广告、无博彩、无用户生成内容、无医疗诊断结论） |
| 价格 | 免费 |
| 内购 | **无** |
| 广告 | **无** |
| 账号体系 | **无账号密码登录**；首次启动自动创建匿名账号，token 只存本机 Keychain |

## 2. 短描述

**中文（≤80 字）**

> 扫描并连接附近的蓝牙设备，查看心率、温度、电量与信号，记录历史曲线并设置阈值告警；数据仅同步到你的匿名账号。

**English（≤30 words）**

> Scan and connect nearby Bluetooth devices to view heart rate, temperature, battery and signal, keep history charts, and set threshold alerts. Data syncs only to your anonymous account.

## 3. 长描述（仅列已实现功能）

**中文**

```
codemagic 是一个蓝牙设备读数面板：把附近的 BLE 设备连起来，看清读数变化。

【首页】
· 设备卡片展示名称、连接状态、最近一条读数与信号强度
· 按分组分段，支持搜索、排序与分组筛选
· 「今日告警摘要」显示当天真实触发条数，点按进入「智能」
· 「快捷场景」展示前 3 个本地场景，一键执行并给出逐条结果

【设备读数】
· 连接后订阅并解析心率（0x2A37）、电量（0x2A19）、温度（0x2A6E）与 Nordic UART TX（6E400003）
· 历史曲线按 1 分钟 / 1 小时 / 1 天分桶；读数与时间戳保存在本机并同步到匿名账号
· 读数可导出为 CSV，通过系统分享保存或发送

【智能】
· 自动化规则：断开连接、RSSI 低于阈值、指标越界；可增删启停，并保留最近 5 条真实触发
· 场景：把「连接设备 / 断开设备 / 开始或停止后台采集 / 静音告警 10、30、60 分钟 / 立即同步」组合成本地动作，一键顺序执行，失败不阻断后续并汇总原因

【后台采集】
· 声明 bluetooth-central：仅在设备保持连接时于后台接收读数
· iOS 可能延后唤醒，断开连接后停止采集；可在「我的」关闭后台采集

【账号与数据】
· 匿名账号自动创建，无需注册或密码
· 支持跨设备接管（8 位一次性接管码）、导出我的数据、注销账号
· 注销会删除服务端账号，并清理本机 Keychain、业务表与同步元数据

【产品与市场】
· 产品页展示型号说明与兼容信息；市场页展示配件与固件条目
· 只读信息展示，不提供下单、支付或交易

说明：本 App 不是医疗设备，读数仅供日常参考，不构成诊断或治疗建议。
```

**English**

```
codemagic is a dashboard for Bluetooth Low Energy device readings.

Home: device cards with name, connection state, latest reading and signal strength; grouping, search, sort and filter; a real "today's alerts" count; and up to three local quick scenarios with per-action results.

Readings: after connecting, the app subscribes to Heart Rate (0x2A37), Battery (0x2A19), Temperature (0x2A6E) and Nordic UART TX (6E400003), stores readings and timestamps locally, draws 1-minute / 1-hour / 1-day history buckets, and exports CSV through the system share sheet.

Smart: automation rules for disconnect, low RSSI and out-of-range metrics with the latest five real triggers; local scenarios that combine connect, disconnect, start/stop background collection, mute alerts for 10/30/60 minutes and sync now. Actions run in order; a failure does not block the rest and results are summarized.

Background: the app declares bluetooth-central and receives readings in the background only while a device stays connected. iOS may defer wake-ups; collection stops after disconnect and can be turned off in Me.

Account: an anonymous account is created automatically, with no registration or password. You can claim an existing account on a new device with an 8-character one-time takeover code, export your data, or delete your account. Deletion removes the server account and clears the local Keychain, business tables and sync metadata.

Products and Market: read-only model, accessory and firmware information. No ordering, payment or transactions.

codemagic is not a medical device. Readings are for general reference only and are not diagnosis or treatment advice.
```

## 4. 关键词（≤100 字符）

```
蓝牙,设备读数,心率,温度,电量,历史曲线,阈值告警,后台采集,数据同步,BLE,设备面板
```

## 5. 明确的边界声明

- **不含交易**：无内购、无订阅、无支付、无下单；「市场」页只展示配件与固件信息。
- **不含广告**：无广告 SDK、无推广位、无联盟链接。
- **不含账号密码登录**：仅匿名账号；不收集手机号、邮箱或密码。
- **不含位置权限**：`Info.plist` 未声明任何 `NSLocation*` 键，App 不调用定位 API。
- **不含分析 / 归因 SDK**：工程无第三方依赖（无 SPM / CocoaPods 包），不接入统计、崩溃归因或广告归因 SDK。
- **不是医疗设备**：心率等读数仅供日常参考，不做诊断、治疗或用药建议。

## 6. 审核备注（给 App Review）

- 蓝牙用途：扫描与连接附近 BLE 设备并读取读数；拒绝授权时 App 仍可查看已保存设备与历史读数（首页展示「仅本机可用」与「去系统设置」）。
- 后台模式：仅 `bluetooth-central` 与 `fetch`；后台接收读数依赖设备保持连接，符合系统限制。
- 匿名账号：首次启动创建，无需登录；`DELETE /api/v1/me` 可在「我的 → 注销账号」触发。
- 测试路径：首页空态 →「开始扫描」→ 保存设备 → 详情查看读数 →「智能」新建规则 / 场景 →「我的」导出与注销。
