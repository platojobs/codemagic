# KNOWN_ISSUES

记录当前版本（v0.1.0）已知、且本机无法闭环验证的问题。已修复项不在此列。

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

## 契约与配置相关

4. **Release BASE_URL 为临时 mock**
   - `Config/Release.xcconfig` 指向 `https://quickmock.dev/m/ecHT7ex3yQPA/`（与 Android 共用），预计 **2026-12-04 到期**。
   - 到期后产品 / 市场显示错误空状态与重试；需替换为正式域名。
5. **与 `PJGoIoT/api/openapi.yaml` 尚未完全对齐**
   - 客户端端点：`api/products`、`api/market`、`api/device/{peripheralUUID}`。
   - openapi：`/api/v1/devices/{mac}`、`/api/v1/device-types/...`、`/api/v1/my/devices`、`/api/v1/sync/*`。
   - 详见 `docs/consistency.md` 第 3.4 节，均标注「待与 openapi.yaml 对齐」。
6. **Debug 本地 Go 服务路径不匹配**
   - Debug `BASE_URL = http://127.0.0.1:8080`，但本地服务实现的是 `/api/v1/...`；Debug 下产品 / 市场可能返回 404 错误空状态，不会崩溃。
   - 可临时用 `xcodebuild ... BASE_URL='https://quickmock.dev/m/ecHT7ex3yQPA/'` 覆盖验证网络路径。
7. **iOS 无法读取蓝牙 MAC**
   - CoreBluetooth 不暴露 MAC，设备详情以 `CBPeripheral.identifier` 请求；后端按 MAC 查询的接口无法直接复用。

## 功能未实现（与 Android 对齐范围内）

8. **GATT 服务发现 / 读写 / OTA 未实现**：GATT 表仅展示网络返回的元数据。
9. **后台蓝牙未实现**：未申请 `bluetooth-central` 后台模式，退到后台后扫描会停止。
10. **账号与同步未接入**：本地已保留 `id / updatedAt / deletedAt / syncState`，未调用 `/auth/*` 与 `/sync/*`。
11. **规则提示仅落本地日志**：不发送系统通知 / 本地推送。
