# App 隐私清单对照（v0.31.11）

隐私清单文件：[`codemagic/Resources/PrivacyInfo.xcprivacy`](../codemagic/Resources/PrivacyInfo.xcprivacy)。工程使用 Xcode 文件系统同步组，新增资源会自动进入 `codemagic` target 的 Resources 阶段（`Info.plist` 是唯一例外）。

## 1. 追踪声明

| 键 | 值 | 依据 |
| --- | --- | --- |
| `NSPrivacyTracking` | `false` | 无广告、无分析 SDK、无跨 App 追踪 |
| `NSPrivacyTrackingDomains` | 空数组 | 不访问任何追踪域名 |

## 2. 收集的数据类型

| 清单键 | App Store 问卷对应 | 代码位置 | 说明 |
| --- | --- | --- | --- |
| `NSPrivacyCollectedDataTypeDeviceID` | 标识符 → 设备 ID | `Core/Models/SavedDevice.swift`（`peripheralID` / `externalID`）；`Core/Bluetooth/CoreBluetoothService.swift`（`CBPeripheral.identifier`）；`Core/Persistence/SavedDeviceStore.swift`；`Core/Sync/SyncModels.swift`（`externalId`） | **当前版本实际采集的只有 BLE 外设 UUID**，用于区分与重连设备。`PushDeviceStore.swift` / `PushDeviceAPIClient.swift` 只保存「未配置推送」状态与错误，**不产生也不上报 APNs 令牌**；只有配置推送证书与 `aps-environment` 后，令牌才作为同一 DeviceID 类别的数据被采集 |
| `NSPrivacyCollectedDataTypeUserID` | 标识符 → 用户 ID | `Core/Sync/TokenStore.swift`（Keychain 中的 `AnonymousSession`）；`Core/Sync/SyncMetadataStore.swift`（`userID`）；`Core/Account/AccountAPIClient.swift` | 服务端匿名账号 ID 与 token，用于同步鉴权 |
| `NSPrivacyCollectedDataTypeOtherUserContent` | 用户内容 → 其他用户内容 | `Core/Models/SavedDevice.swift`（`advertisedName` / `remark` / `groupName`）；家庭与房间名；`Core/Support/FeedbackModels.swift`（反馈主题与正文） | 设备广播名、用户别名、分组、家庭 / 房间名与反馈正文 |
| `NSPrivacyCollectedDataTypeHealth` | 健康与健身 → 健康 | `Core/Models/DeviceReading.swift`（`heartRate`）；`Core/Readings/ReadingParser.swift`（`parseHeartRate`，特征 `0x2A37`） | 心率读数；仅用于展示、曲线与阈值判断，不做医疗诊断 |
| `NSPrivacyCollectedDataTypeOtherUsageData` | 使用数据 → 其他使用数据 | `Core/Models/DeviceReading.swift`（`recordedAt`）；`Core/Models/ScanLogEntry.swift`；`Core/Models/DeviceRule.swift` 与 `Core/Rules/RuleEvaluator.swift`（规则触发）；`Core/Sync/SyncMetadataStore.swift`；`Core/Models/SavedDevice.swift`（`serverLastSeenAt`，服务端 `lastSeenAt` 只读落地） | 读数时间戳、规则触发、本地扫描日志、同步元数据与设备最近上报时间（presence 推导依据；客户端只读，不上报、不参与 LWW） |
| `NSPrivacyCollectedDataTypeOtherDataTypes` | 其他数据类型 | `Core/Models/DeviceReading.swift`（温度、电量与 NUS 透传指标值与单位） | 非心率类传感器读数，仅用于展示、曲线、阈值与导出 |
| `NSPrivacyCollectedDataTypeOtherUserContactInfo` | 联系信息 → 其他用户联系信息 | `Core/Support/FeedbackModels.swift`（`contact`） | 反馈页可选联系方式，仅在用户主动填写并提交时上传 |
| `NSPrivacyCollectedDataTypeOtherDiagnosticData` | 诊断 → 其他诊断数据 | `Core/Support/FeedbackModels.swift`（`clientContext`：App 版本、iOS 版本、设备型号） | 随反馈提交的客户端诊断信息，仅用于排查问题 |

所有类型的共同声明：`Linked = true`（与匿名账号关联）、`Tracking = false`、用途 = `AppFunctionality`。

### 2.1 清单与商店问卷的 8 类逐项核对

`PrivacyInfo.xcprivacy` 的 `NSPrivacyCollectedDataTypes` **恰好 8 个键**，与 [`store-listing.md`](store-listing.md) 第 5 节一一对应：

| # | 清单键 | 商店问卷类别 | store-listing 对应行 |
| --- | --- | --- | --- |
| 1 | `NSPrivacyCollectedDataTypeDeviceID` | 标识符 → 设备 ID | BLE 外设 UUID；APNs 令牌同属本类 |
| 2 | `NSPrivacyCollectedDataTypeUserID` | 标识符 → 用户 ID | 匿名 `userId` 与 Keychain token |
| 3 | `NSPrivacyCollectedDataTypeHealth` | 健康与健身 → 健康 | 心率读数 |
| 4 | `NSPrivacyCollectedDataTypeOtherDataTypes` | 其他数据类型 | 温度 / 电量 / NUS 指标 |
| 5 | `NSPrivacyCollectedDataTypeOtherUsageData` | 使用数据 → 其他使用数据 | 时间戳 / 规则触发 / 扫描日志 / 同步元数据 |
| 6 | `NSPrivacyCollectedDataTypeOtherUserContent` | 用户内容 → 其他用户内容 | 设备名 / 家庭与房间名 / 反馈正文 |
| 7 | `NSPrivacyCollectedDataTypeOtherUserContactInfo` | 联系信息 → 其他用户联系信息 | 反馈可选联系方式 |
| 8 | `NSPrivacyCollectedDataTypeOtherDiagnosticData` | 诊断 → 其他诊断数据 | 反馈客户端诊断 |

> `store-listing.md` 的表格有 9 行数据，其中「BLE 外设 UUID」与「APNs 推送令牌」两行同属 **DeviceID**，不构成第 9 类。`PrivacyManifestTests` 会解析清单并断言键集合恰为上述 8 个、全部 `Linked=true` / `Tracking=false` / `AppFunctionality`。

### 2.2 当前版本与将来接推送的边界

- **当前二进制（0.31.5/build 45）**：`Info.plist` / `entitlements` 均无 `aps-environment`，`PushRegistrationService` 获取令牌失败后状态为 `missingToken`，界面显示「未配置推送」，本地 `push_devices` 只记录状态与错误，**不写占位 token，也不调用 `POST /push/devices`**。因此 APNs 令牌当前不属于「已采集」数据。
- **启用推送时必须同步修改的位置**：
  1. 工程签名：为 `codemagic` target 增加 `aps-environment` entitlement 与对应 Provisioning Profile / APNs 证书；
  2. `Core/Notifications/APNSTokenProvider.swift`：让 `registerForRemoteNotifications` 能拿到真实 token 并交给 `PushRegistrationService`；
  3. `codemagic/Resources/PrivacyInfo.xcprivacy`：`DeviceID` 保持同一类别（无需新增键），移除「当前不采集」注释并复核用途；
  4. `docs/app-privacy.md` 本篇 2.1 / 2.2 与 `docs/privacy-policy.md` 第 2、7 节：把 APNs 令牌从「将来」改为「已采集」，写清上报字段与保留期；
  5. `docs/store-listing.md` 第 5 节与 App Store 隐私问卷：DeviceID 的「触发条件」改为「配置推送后即采集」，审核备注移除「推送服务当前未配置」；
  6. `codemagicTests/PushRegistrationTests.swift` 与 `PrivacyManifestTests`：补真实 token 路径与申报一致性断言。
- **反向约束**：只要上述任一项未完成，商店文案与隐私问卷必须继续声明「当前不采集 APNs 令牌」。

## 3. 必需理由 API（Required Reason APIs）

| 清单类别 | 原因码 | 代码位置 | 用途 |
| --- | --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | `Core/Persistence/SettingsStore.swift`（排序、分组、后台采集、通知、告警静音、首启引导进度）；`Core/Sync/SyncMetadataStore.swift`（游标、上次同步、clientId） | 仅访问本 App 自己的偏好与同步元数据 |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | `Core/Account/AccountExportService.swift`（`contentModificationDate` 清理过期导出临时文件）；`Core/Export/ReadingsExportService.swift`（同上） | 判断并删除 App 容器内过期临时导出文件 |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | `App/LaunchMetrics.swift`（`DispatchTime.now().uptimeNanoseconds`） | 测量冷启动到首帧的耗时，仅本机日志输出 |

未声明（也未使用）：

- 位置：`Info.plist` 无 `NSLocation*`，代码无 `CLLocationManager`。
- 通讯录、照片、麦克风、相机、剪贴板、IDFA / ATT。
- 磁盘空间、活动键盘等其它必需理由 API。

## 4. Info.plist 权限文案对照

| 键 | 文件 | 文案用途 |
| --- | --- | --- |
| `NSBluetoothAlwaysUsageDescription` | `codemagic/Resources/Info.plist` | 扫描、连接 BLE 设备并读取读数 |
| `NSBluetoothPeripheralUsageDescription` | 同上 | 兼容旧系统 |
| `UIBackgroundModes` | 同上 | `bluetooth-central`（连接期间后台读数）与 `fetch`（后台同步） |

## 5. 自检

```bash
# 1) 清单语法
plutil -lint codemagic/Resources/PrivacyInfo.xcprivacy

# 2) 构建产物内确实打包了清单
find .build/DerivedData/Build/Products -name PrivacyInfo.xcprivacy

# 3) 清单键集合 / 属性与本文、store-listing.md 一一对应（单测）
xcodebuild test -scheme codemagic -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:codemagicTests/PrivacyManifestTests
```

> 版本变化时：新增收集字段先改代码与 `PrivacyInfo.xcprivacy`，再同步 `docs/privacy-policy.md` 与 `docs/store-listing.md`；不要把未实现的声明写进清单。
