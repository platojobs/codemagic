# 故障排查

命令默认在仓库根目录执行。

## 工具链与模拟器

- `xcodebuild -version` 确认 Xcode；`xcrun simctl list devices available` 找可用机型，不要写死设备名。
- 工程最低 iOS 15.0。`DerivedData` 损坏导致链接错误时：`rm -rf ./build` 后重建。
- 模拟器没有真实蓝牙（`unsupported`），首页显示「当前环境不支持蓝牙」是预期。

## 签名与证书

- 模拟器与 CI 用 `CODE_SIGNING_ALLOWED=NO`，不需要证书。
- 真机：Xcode 登录 Apple ID，target 勾选 Automatically manage signing 并选择 Team；Bundle ID 当前为 `com.platojobs.codemagic`。
- 换 Team / 重装后 Keychain 可能不可读，按下一节清理；仓库无开发者账号，Release 真机安装仍为 BLOCKED。

## Keychain / 401

- token 只写 Keychain（service 写死 `com.platojobs.codemagic.sync`）。写不进去时看「我的 → 本地扫描日志」的 `OSStatus`；模拟器可 `xcrun simctl uninstall booted com.platojobs.codemagic` 后重装。
- 401 表示 token 过期 / 被作废，客户端**不会自动建新匿名账号**。点「重新登录」后游标从 0 重置，旧账号云端数据不合并。
- 账号删除：409 `ACCOUNT_DELETION_BLOCKED` 先转让 / 移除成员，同一令牌仍有效；403 `DELETION_TOKEN_INVALID` 重新申请；404 按已删除处理并清本地。
- 数据导出：轮询 2.5s 起、×1.4、封顶 5s；下载链接 10 分钟一次性，410 `EXPORT_DOWNLOAD_EXPIRED` 会自动重试一次并换新链接。

## 后台同步（BGTask）

- 模拟器不执行后台刷新，必须真机；系统「后台 App 刷新」与低电量模式都会影响。
- `Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` 必须含 `com.platojobs.codemagic.sync`，注册在 `AppDelegate` 启动完成前。
- 手动触发：Xcode **Debug → Simulate Background Fetch**，或 LLDB：
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.platojobs.codemagic.sync"]`
- 任务回调必须 `setTaskCompleted`，成功 / 失败 / 过期三条路径都要走。

## BASE_URL 与后端

- 地址来自 xcconfig：Debug `Config/Debug.xcconfig` → `http://127.0.0.1:8080`；Release → mock（预计 2026-12-04 到期，之后只改 `Release.xcconfig`）。
- 非法地址启动即报 `NET-004`；临时覆盖用 `xcodebuild ... BASE_URL='https://your-host/' build`。
- 真机不能访问 `127.0.0.1`，需改成 Mac 局域网 IP 并让 Go 服务监听 `0.0.0.0`。
- 起后端：`cd ../PJGoIoT && STORE=fixture ADDR=127.0.0.1:8080 go run ./cmd/api`；健康检查 `curl -s http://127.0.0.1:8080/api/v1/health`。
- `NET-001` 但 curl 正常时，查模拟器代理 / VPN、`NSAllowsLocalNetworking`、真机网段。E2E 服务日志在 `.build/e2e/pjgoiot-server.log`。

## 端口占用

- `lsof -nP -iTCP:8080 -sTCP:LISTEN`、`lsof -nP -iTCP:18080 -sTCP:LISTEN` 查占用。
- E2E 默认 8080，被占用回退 18080，或 `E2E_PORT=18080 ./scripts/e2e-contract.sh`；App 联调需同步改 xcconfig。

## 快速定位

| 现象 | 先查 |
| --- | --- |
| 同步一直「正在同步…」 | 上次回调未返回；杀进程重开，查 15s 超时与后端响应 |
| `DB-001` | 磁盘满 / 沙盒迁移；必要时重装（已回退内存库） |
| 产品 / 市场空列表但无错误 | 后端返回空 `items` 是正常空状态 |
| 断网后仍显示旧目录 | 预期：有缓存时展示并标注「离线缓存」 |
| 目录指标「当前版本不支持」 | 本地未订阅该 characteristic，属如实标注 |
| 详情「来自 Android，本机不可连接」 | 预期行为 |
| 规则不触发 | 规则是否启用、设备是否在列表、首页扫描是否进行中 |

日志入口统一在「我的 → 本地扫描日志」。
