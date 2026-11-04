# KNOWN_ISSUES

记录当前版本（v0.3.2）已知、且本机无法闭环验证的问题。已修复项不在此列。

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
5. **App 内同步仍未在真机 + 真实后端闭环**
   - 服务端契约已通过 `scripts/e2e-contract.sh` 对本地 `PJGoIoT` 0.3.1（`STORE=fixture`）完成 55 项断言（匿名登录、双平台推送、changes 形状、device-types/catalog、复合键详情、幂等重放、LWW 冲突、401/404），结果 PASS（2026-11-05）。
   - 该联调使用独立 Swift 可执行程序直连 localhost，**不覆盖** App 内的 Keychain token 读写、`BGAppRefreshTask` 调度、前后台触发与「我的」同步状态 UI；这些仍需真机 + 真实后端验证。
   - fixture 为内存存储，重启后数据清空；不等价于生产 PostgreSQL / 对象存储环境。

## 契约与配置相关

6. **Release BASE_URL 为临时 mock**
   - `Config/Release.xcconfig` 指向 `https://quickmock.dev/m/ecHT7ex3yQPA/`（与 Android 共用），预计 **2026-12-04 到期**。
   - 到期后产品 / 市场会显示错误空状态与重试；同步在 Release 下也会失败并保留待上传记录。需替换为正式域名。
7. **catalog 与设备详情的字段缺口（已按 openapi 实现，但展示不完整）**
   - `GET /device-types/{type}/catalog` 没有 `compatibility` 字段，产品详情「兼容性」只能显示空；固件 / 配件也没有 vendor，市场列表用所属型号的 vendor 填充。
   - `UserDevice` 没有 `deviceType` / `model` 字段，iOS 设备详情无法自动选择 catalog，因此详情只展示云端记录（别名、分组、externalId）与本地缓存，不再显示厂商 / GATT / 固件。
   - 旧 `GET /api/v1/devices/{mac}` 仍可用，但**仅 Android 使用**；iOS 无 MAC 不再调用。
8. **Release mock 未必支持 0.3.1 新端点**
   - Debug `BASE_URL = http://127.0.0.1:8080`，需先 `git pull` 并运行 0.3.1 的 `PJGoIoT`。
   - Release 仍指向 `https://quickmock.dev/m/ecHT7ex3yQPA/`（与 Android 共用，预计 2026-12-04 到期）；该 mock 若未更新 `/device-types/{type}/catalog` 与 `/my/devices/{platform}/{externalId}`，产品 / 市场 / 详情会显示错误空状态或缓存降级。
9. **iOS 无法读取蓝牙 MAC（已规避）**
   - iOS `platform=ios`、`externalId=CBPeripheral.identifier`（大写），`mac` 为空；详情改用复合键 `/my/devices/ios/{externalId}`，不再依赖 MAC。
10. **跨平台拉取的设备无法在本机连接（已做 UI 防误触，未真机验证）**
    - 从服务端拉取的 Android 设备会以远端 `id` 生成占位 `peripheral_id`，CoreBluetooth 无法连接。
    - v0.3.0 已在列表标注「来自 Android，本机不可连接」，移除展开箭头、禁用高亮与点击，并在详情 ViewModel 增加守卫；仍需真机确认视觉效果与点击无响应。
11. **catalog 缺少字段导致详情无法复用**
    - `DeviceTypeInfo` 有 `type/name/vendor/description/gattServices`，`DeviceCatalog` 有 `firmwares/accessories`，但 `UserDevice` 无型号标识；iOS 无法把一台本机设备映射到某个 catalog。
    - 若后端后续在 `UserDevice` 增加 `deviceType`，详情可恢复厂商 / 固件 / GATT 展示。
12. **401 需用户确认重新登录，不自动建号**
    - 401 `UNAUTHORIZED` 表示 token 失效：按契约必须由用户重新登录（重新获取匿名会话）后重试，客户端不得静默调用 `auth/anonymous` 新建账号，避免设备归属漂移。
    - v0.3.2 已在「我的」页展示「登录已失效」+「重新登录」入口：确认弹窗说明旧账号云端数据**不会自动合并**，本机设备会重新上传；确认后才换新匿名账号，游标重置为 0 并重推本地活动设备；重登失败保持待重登，后台同步不会悄悄建号。
    - 未做「账号数据迁移 / 合并」：旧匿名账号的云端记录仍保留在原 `userId` 下，客户端没有导出或迁移入口；如需找回，只能由后端提供账号绑定或迁移能力。
    - 该交互仍需真机 + 真实 401（后端作废 token）验证，UI 与 Keychain 行为不在 E2E 覆盖范围。

## 功能未实现（与 Android 对齐范围内）

13. **GATT 服务发现 / 读写 / OTA 未实现**：GATT 表仅展示网络返回的元数据。
14. **后台蓝牙未实现**：未申请 `bluetooth-central` 后台模式，退到后台后扫描会停止（同步不受影响）。
15. **规则提示仅落本地日志**：不发送系统通知 / 本地推送。
16. **同步范围仅设备表**：`rules` / `scan_logs` / `recent_devices` / `device_info_cache` 保留同步字段但未参与推送，与后端当前 `devices` 实体范围一致。
