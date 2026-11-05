# KNOWN_ISSUES

记录当前版本（v0.5.0）已知、且本机无法闭环验证的问题。已修复项不在此列。

## 需用户在真实环境验证

1. **真机 BLE 与读数采集未验证**
   - 模拟器无蓝牙硬件，`CBCentralManager.state` 为 `unsupported`；扫描、连接、RSSI 变化、断开事件均未在真机运行。
   - 需在真实 iPhone 上验证：首次授权弹窗、拒绝后跳系统设置、真实设备扫描与连接、12s 超时、规则触发。
   - 读数采集虽已实现 GATT 发现 + notify 订阅，但真实可穿戴设备的 notify 频率与帧格式（心率 flags、温度编码、NUS 文本）未在真机核对；解析器只按规范与常见实现编写。
2. **签名与分发未验证**
   - 本机无 Apple 开发者账号与证书，未执行 `archive` / `exportArchive`，未上架 App Store / TestFlight。
   - CI 与本地构建统一使用 `CODE_SIGNING_ALLOWED=NO`，只验证编译与测试。
3. **CI**
   - GitHub Actions `ios.yml` 已实际运行成功（v0.4.1 run [41945052635](https://github.com/platojobs/codemagic/actions/runs/41945052635)，macos-15 + Xcode 16.4；并行 `build-test` 140 单测与 `e2e-contract` 106 项均 PASS）；仅 push 到 `main` / tag 触发，PR 不跑（macOS runner 计费高），按 `github.sha` 去重。v0.5.0 的 CI 运行记录见 README 第 8.1 节。
   - CI 的 `e2e-contract` 使用 `platojobs/PJGoIoT` 默认分支与 `go.mod` 中的 Go 版本；后端后续若改变 fixture 数据或契约，CI 会先红，需要同步更新断言。
   - 根目录 `codemagic.yaml`（Codemagic）保留为可选替代方案，**仍未在 Codemagic 上运行**，不能作为当前 CI 证据。
   - 仓库 OAuth token 缺少 `workflow` scope，推送 `.github/workflows/*` 使用 SSH over 443（`ssh://git@ssh.github.com:443/platojobs/codemagic.git`），未改全局 git config。
4. **后台同步调度未在真机验证**
   - `BGAppRefreshTask`（`com.platojobs.codemagic.sync`）已注册并在前后台切换时提交，但模拟器不执行后台刷新，实际触发频率与时长需真机 / Xcode Devices 观察。
5. **App 内同步仍未在真机 + 真实后端闭环**
   - 服务端契约已通过 `scripts/e2e-contract.sh` 对本地 `PJGoIoT` **v0.5.1**（`STORE=fixture`）完成 **123 项**断言（匿名登录、双平台推送、changes 形状、device-types/catalog 的 vendor/compatibility、复合键详情、UserDevice 新字段与 null 降级、别名/广播名分离、group 三态、幂等重放、LWW 冲突、401/404、读数推送/倒序/summary/重复 id/NaN 400、series 升序与桶内 count、空区间 `[]`、非法 bucket 400、metrics 倒序与 count/unit），结果 PASS（2026-11-05）。
   - 该联调使用独立 Swift 可执行程序直连 localhost，**不覆盖** App 内的 Keychain token 读写、`BGAppRefreshTask` 调度、前后台触发与「我的」同步状态 UI；这些仍需真机 + 真实后端验证。
   - fixture 为内存存储，重启后数据清空；不等价于生产 PostgreSQL / 对象存储环境。

## 契约与配置相关

6. **Release BASE_URL 为临时 mock**
   - `Config/Release.xcconfig` 指向 `https://quickmock.dev/m/ecHT7ex3yQPA/`（与 Android 共用），预计 **2026-12-04 到期**。
   - 到期后产品 / 市场会显示错误空状态与重试；同步在 Release 下也会失败并保留待上传记录。需替换为正式域名。
7. **catalog 字段已补齐，但存在 null / 空串差异**
   - openapi 0.3.3 起 `UserDevice` 增加 `advertisedName`，且 `alias` / `advertisedName` / `group` 支持缺省（absent）与显式清空（`""`）；v0.3.6 已全量接入并把三态落库（各自的 `*_patch` 列）。
   - 仍需注意：固件 / 配件的 `vendor` 在未核实时是**空串**而非 `null`（iOS 模型保留 `""`，UI 显示「—」，且不进入市场厂商筛选项）；`UserDevice` 的四个新字段可能是 `null`（iOS 归一为 `nil`，显示「型号未知 / — / 暂无兼容性说明」）。这些差异由 E2E 断言覆盖，但真实数据下仍可能有服务端未补全的条目。
8. **Release mock 未必支持 0.3.3 新端点 / 新字段**
   - Debug `BASE_URL = http://127.0.0.1:8080`，需先 `git pull` 并运行 0.3.3 的 `PJGoIoT`。
   - Release 仍指向 `https://quickmock.dev/m/ecHT7ex3yQPA/`（与 Android 共用，预计 2026-12-04 到期）；该 mock 若未更新 `/device-types/{type}/catalog`、`/my/devices/{platform}/{externalId}` 与新增的 `advertisedName` / `deviceType` / `vendor` / `firmwareVersion` / `compatibility` 字段，产品 / 市场 / 详情会显示错误空状态、缓存降级，或字段一律为空。
9. **iOS 无法读取蓝牙 MAC（已规避）**
   - iOS `platform=ios`、`externalId=CBPeripheral.identifier`（大写），`mac` 为空；详情改用复合键 `/my/devices/ios/{externalId}`，不再依赖 MAC。
10. **跨平台拉取的设备无法在本机连接（已做 UI 防误触，未真机验证）**
    - 从服务端拉取的 Android 设备会以远端 `id` 生成占位 `peripheral_id`，CoreBluetooth 无法连接。
    - v0.3.0 已在列表标注「来自 Android，本机不可连接」，移除展开箭头、禁用高亮与点击，并在详情 ViewModel 增加守卫；仍需真机确认视觉效果与点击无响应。
11. **型号映射已可用，但依赖服务端补全**
    - openapi 0.3.2 的 `UserDevice.deviceType` 已可用于映射 catalog；v0.3.3 已把云端型号写回本地并在推送时携带。
    - 但服务端只有在 `deviceType` 命中 `public_devices` / `device_types`（或按 MAC 匹配）时才补全 `vendor` / `compatibility`；未注册型号返回 `null`，详情显示「型号未知」。此时 iOS 不会猜测型号，也不会把型号写进推送。
    - GATT 服务与特征仍来自 catalog 型号元数据；`UserDevice` 不返回 GATT，详情页在无型号时不展示 GATT 区。
12. **401 需用户确认重新登录，不自动建号**
    - 401 `UNAUTHORIZED` 表示 token 失效：按契约必须由用户重新登录（重新获取匿名会话）后重试，客户端不得静默调用 `auth/anonymous` 新建账号，避免设备归属漂移。
    - v0.3.2 已在「我的」页展示「登录已失效」+「重新登录」入口：确认弹窗说明旧账号云端数据**不会自动合并**，本机设备会重新上传；确认后才换新匿名账号，游标重置为 0 并重推本地活动设备；重登失败保持待重登，后台同步不会悄悄建号。
    - 未做「账号数据迁移 / 合并」：旧匿名账号的云端记录仍保留在原 `userId` 下，客户端没有导出或迁移入口；如需找回，只能由后端提供账号绑定或迁移能力。
    - 该交互仍需真机 + 真实 401（后端作废 token）验证，UI 与 Keychain 行为不在 E2E 覆盖范围。

## 功能未实现（与 Android 对齐范围内）

13. **GATT 特征写入 / OTA 未实现**：已做服务发现与四个读数特征（心率 / 电量 / 温度 / NUS TX）的 notify 订阅；GATT 元数据仍来自 catalog，不支持写入与固件升级。
14. **长周期图表未在真机核对**：区间切换、按时间定位与缺口断线已由单测 + 本地 e2e 覆盖服务端契约，但真机上的触摸切换、长区间渲染性能与动态字体布局仍需在真实 iPhone 上验收。
15. **后台蓝牙未实现**：未申请 `bluetooth-central` 后台模式，退到后台后扫描与读数采集会停止（同步不受影响）。
16. **规则提示仅落本地日志**：不发送系统通知 / 本地推送。
17. **同步范围仅设备与读数**：`rules` / `scan_logs` / `recent_devices` / `device_info_cache` 保留同步字段但未参与推送，与后端当前实体范围一致。
