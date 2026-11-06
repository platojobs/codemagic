# App 隐私清单对照（v0.27.0）

隐私清单文件：[`codemagic/Resources/PrivacyInfo.xcprivacy`](../codemagic/Resources/PrivacyInfo.xcprivacy)。工程使用 Xcode 文件系统同步组，新增资源会自动进入 `codemagic` target 的 Resources 阶段（`Info.plist` 是唯一例外）。

## 1. 追踪声明

| 键 | 值 | 依据 |
| --- | --- | --- |
| `NSPrivacyTracking` | `false` | 无广告、无分析 SDK、无跨 App 追踪 |
| `NSPrivacyTrackingDomains` | 空数组 | 不访问任何追踪域名 |

## 2. 收集的数据类型

| 清单键 | App Store 问卷对应 | 代码位置 | 说明 |
| --- | --- | --- | --- |
| `NSPrivacyCollectedDataTypeDeviceID` | 标识符 → 设备 ID | `Core/Models/SavedDevice.swift`（`peripheralID` / `externalID`）；`Core/Bluetooth/CoreBluetoothService.swift`（`CBPeripheral.identifier`）；`Core/Persistence/SavedDeviceStore.swift`；`Core/Sync/SyncModels.swift`（`externalId`）；`Core/Persistence/PushDeviceStore.swift`（APNs token）；`Core/Sync/PushDeviceAPIClient.swift` | BLE 外设标识符，用于区分与重连设备；APNs 推送令牌用于告警推送，均随匿名账号同步 |
| `NSPrivacyCollectedDataTypeUserID` | 标识符 → 用户 ID | `Core/Sync/TokenStore.swift`（Keychain 中的 `AnonymousSession`）；`Core/Sync/SyncMetadataStore.swift`（`userID`）；`Core/Account/AccountAPIClient.swift` | 服务端匿名账号 ID 与 token，用于同步鉴权 |
| `NSPrivacyCollectedDataTypeOtherUserContent` | 用户内容 → 其他用户内容 | `Core/Models/SavedDevice.swift`（`advertisedName` / `remark` / `groupName`）；家庭与房间名；`Core/Support/FeedbackModels.swift`（反馈主题与正文） | 设备广播名、用户别名、分组、家庭 / 房间名与反馈正文 |
| `NSPrivacyCollectedDataTypeHealth` | 健康与健身 → 健康 | `Core/Models/DeviceReading.swift`（`heartRate`）；`Core/Readings/ReadingParser.swift`（`parseHeartRate`，特征 `0x2A37`） | 心率读数；仅用于展示、曲线与阈值判断，不做医疗诊断 |
| `NSPrivacyCollectedDataTypeOtherUsageData` | 使用数据 → 其他使用数据 | `Core/Models/DeviceReading.swift`（`recordedAt`）；`Core/Models/ScanLogEntry.swift`；`Core/Models/DeviceRule.swift` 与 `Core/Rules/RuleEvaluator.swift`（规则触发）；`Core/Sync/SyncMetadataStore.swift` | 读数时间戳、规则触发、本地扫描日志与同步元数据 |
| `NSPrivacyCollectedDataTypeOtherDataTypes` | 其他数据类型 | `Core/Models/DeviceReading.swift`（温度、电量与 NUS 透传指标值与单位） | 非心率类传感器读数，仅用于展示、曲线、阈值与导出 |
| `NSPrivacyCollectedDataTypeOtherUserContactInfo` | 联系信息 → 其他用户联系信息 | `Core/Support/FeedbackModels.swift`（`contact`） | 反馈页可选联系方式，仅在用户主动填写并提交时上传 |
| `NSPrivacyCollectedDataTypeOtherDiagnosticData` | 诊断 → 其他诊断数据 | `Core/Support/FeedbackModels.swift`（`clientContext`：App 版本、iOS 版本、设备型号） | 随反馈提交的客户端诊断信息，仅用于排查问题 |

所有类型的共同声明：`Linked = true`（与匿名账号关联）、`Tracking = false`、用途 = `AppFunctionality`。

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

# 3) 隐私文案与清单键一致（人工核对本文第 2、3 节）
```

> 版本变化时：新增收集字段先改代码与 `PrivacyInfo.xcprivacy`，再同步 `docs/privacy-policy.md` 与 `docs/store-listing.md`；不要把未实现的声明写进清单。
