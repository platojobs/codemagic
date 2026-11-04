# KNOWN_ISSUES

记录当前版本（v0.2.0）已知、且本机无法闭环验证的问题。已修复项不在此列。

## 需用户在真实环境验证

1. **真机 BLE 未验证**
   - 模拟器无蓝牙硬件，`CBCentralManager.state` 为 `unsupported`；扫描、连接、RSSI 变化、断开事件均未在真机运行。
   - 需在真实 iPhone 上验证：首次授权弹窗、拒绝后跳系统设置、真实设备扫描与连接、12s 超时、规则触发。
2. **签名与分发未验证**
   - 本机无 Apple 开发者账号与证书，未执行 `archive` / `exportArchive`，未上架 App Store / TestFlight。
   - CI 与本地构建统一使用 `CODE_SIGNING_ALLOWED=NO`，只验证编译与测试。
3. **CI 尚未实际运行**
   - 根目录 `codemagic.yaml` 已编写（Codemagic，macOS + Xcode 16.4），但本机无法代替远端执行；需在 Codemagic 上首次运行后观察结果。
   - GitHub Actions 方式因当前 OAuth token 缺少 `workflow` 权限被拒绝推送，未纳入仓库。
4. **后台同步调度未在真机验证**
   - `BGAppRefreshTask`（`com.platojobs.codemagic.sync`）已注册并在前后台切换时提交，但模拟器不执行后台刷新，实际触发频率与时长需真机 / Xcode Devices 观察。
5. **真实后端同步未联调**
   - 同步客户端按 `PJGoIoT/api/openapi.yaml`（v0.2.0）实现，幂等、冲突、tombstone 均由单元测试（桩接口）覆盖；未对运行中的 `PJGoIoT` 做端到端验证。
   - 联调前请确认 Debug `BASE_URL` 指向 `127.0.0.1:8080` 且后端已启动。

## 契约与配置相关

6. **Release BASE_URL 为临时 mock**
   - `Config/Release.xcconfig` 指向 `https://quickmock.dev/m/ecHT7ex3yQPA/`（与 Android 共用），预计 **2026-12-04 到期**。
   - 到期后产品 / 市场会显示错误空状态与重试；同步在 Release 下也会失败并保留待上传记录。需替换为正式域名。
7. **产品 / 市场 / 设备详情仍为历史端点**
   - 客户端：`api/products`、`api/market`、`api/device/{peripheralUUID}`。
   - openapi：按设备类型拆分 `firmwares` / `accessories`，设备元数据为 `/api/v1/devices/{mac}`、`/api/v1/device-types/{type}`。
   - 同步与鉴权（`/api/v1/auth/anonymous`、`/api/v1/sync/*`）**已对齐**；上述三项未切换，见 `docs/consistency.md` 第 3.4 节。
8. **Debug 本地 Go 服务路径不匹配（仅产品 / 市场）**
   - Debug `BASE_URL = http://127.0.0.1:8080`；`/api/v1/*` 同步链路可直连，但 `api/products` / `api/market` 可能返回 404 错误空状态，不会崩溃。
   - 可临时用 `xcodebuild ... BASE_URL='https://quickmock.dev/m/ecHT7ex3yQPA/'` 覆盖验证网络路径。
9. **iOS 无法读取蓝牙 MAC**
   - 已按 `(platform, externalId)` 规避：iOS `platform=ios`、`externalId=CBPeripheral.identifier`（大写），`mac` 为空；设备详情接口仍使用 `peripheralUUID`。
10. **跨平台拉取的设备无法在本机连接**
    - 从服务端拉取的 Android 设备会以远端 `id` 生成占位 `peripheral_id`，可在「设备」列表展示，但本机无法通过 CoreBluetooth 连接该占位标识；详情页连接会失败。只有本机扫描到的 iOS 设备可连接。

## 功能未实现（与 Android 对齐范围内）

11. **GATT 服务发现 / 读写 / OTA 未实现**：GATT 表仅展示网络返回的元数据。
12. **后台蓝牙未实现**：未申请 `bluetooth-central` 后台模式，退到后台后扫描会停止（同步不受影响）。
13. **规则提示仅落本地日志**：不发送系统通知 / 本地推送。
14. **同步范围仅设备表**：`rules` / `scan_logs` / `recent_devices` / `device_info_cache` 保留同步字段但未参与推送，与后端当前 `devices` 实体范围一致。
