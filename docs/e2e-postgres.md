# 真实 Postgres 端到端联调（v0.15.0）

本文件记录 `scripts/e2e-postgres.sh` 的**真实本地运行输出**。与 `scripts/e2e-contract.sh`（后端 `STORE=fixture` 内存态）不同，本项起真实 Postgres + 真实 API，额外覆盖只有真实库才能构造的分支，并直接查库核对家庭链路的数据不变量。

## 环境与命令

- iOS 仓库：`codemagic`（v0.15.0）
- 后端：`PJGoIoT` `v0.13.0`（openapi `0.9.0`），通过 `PJGOIOT_DIR` 指向干净 worktree
- 本机：macOS + Docker + Go 1.24+（Docker daemon 可用）
- 命令：

```bash
cd /Users/platojobs/Desktop/GitHub/platojobs/codemagic
PJGOIOT_DIR=/tmp/pjgoiot-v013 ./scripts/e2e-postgres.sh
```

脚本行为：

1. 用 `$PJGOIOT_DIR/scripts/stack-for-e2e.sh` 在 `mktemp` 目录里起独立 Postgres 容器与 API，stdout 输出 `BASE_URL`；
2. **以 `E2E_EXTERNAL_BASE_URL` 复用该栈**跑现有 **260 项**契约套件（`e2e-contract.sh` 支持外部后端后不再自起 fixture），其中第 9 节覆盖家庭链路；
3. **家庭链路（真 Postgres）**：新建 owner / member / outsider 三个匿名账号，创建家庭 → 两个邀请码（一个用于列表与撤销、一个给成员领取）→ 列表无明文 → 撤销后 claim 404 → 建 3 间房并整段排序成功 → 缺项 409 → owner 带成员退出 409 → 移除成员后对方 404 → owner 退出 204；再用 `psql` 直接查库：邀请码只存 64 位哈希、移除成员后成员行删除、退出后成员行清空；
4. 用真实 SQL 把最老 `change_log.seq` 的 `server_ts` 改到 100 天前，再跑 `cmd/cleanup`（保留 90 天），构造 **410 `RESYNC_REQUIRED`**；
5. 验证 `cursor=0` 全量重拉永不 410、series / metrics、export（limit=5000）、注销；
6. `trap` 停止栈并删除临时目录；`E2E_KEEP_STATE=1` 可保留现场。

隔离说明：所有后端状态与日志都在 `mktemp` 目录（`E2E_STATE_DIR`）；契约 runner 是纯网络、无本地状态，**不读写 App 开发用的 SQLite / UserDefaults**。

## 真实输出（2026-11-05）

```text
== 起真实 Postgres + API（状态目录 /var/folders/…/codemagic-e2e-pg.UJ7ITk/stack） ==
BASE_URL=http://127.0.0.1:59939
PG_CONTAINER=pjgoiot-e2e-pg-10806-1 DATABASE_URL=postgres://pjgoiot:pjgoiot-e2e-only@127.0.0.1:59919/pjgoiot_e2e?sslmode=disable

== 跑现有契约套件（复用真实栈） ==
[e2e] 复用外部后端：http://127.0.0.1:59939（跳过构建与启动）
[e2e] health 200
[e2e] 编译 Swift 联调 runner…
[e2e] 运行联调用例（真实网络，直连 http://127.0.0.1:59939）
…
=== E2E 合同联调结果 ===
通过：260 项，跳过：0 项，失败：0 项
结论：PASS

=== e2e-contract 摘要 ===
后端：外部复用 http://127.0.0.1:59939
结果：PASS

== 家庭链路（真 Postgres）：成员移除 / 退出 409 / 邀请码无明文 / 重排 409 ==
PASS 真 Postgres：邀请码仅存哈希；移除成员 404；owner 退出 409→移除后可退出

== 匿名登录 ==
PASS 匿名登录: userId=d4c1a721-8be4-414f-8ccb-b64f7c2a6972 expiresAt=2027-05-04T15:53:20.376737Z

== 推送 iOS 设备 + 读数（第一次） ==
PASS push#1: applied=1 appliedReadings=4

== 再次更新同一设备（制造两条 change_log，供 410 构造间隙） ==
PASS push#2: applied=1

== 增量拉取（cursor=0） ==
最老 seq=10，用 cursor=9（小于保留边界）构造 410

== 构造游标失效：最老 seq server_ts 改为 100 天前，再跑 cleanup(90 天) ==
cleanup: change_log_deleted=1 change_log_cutoff=2026-08-07T… change_log_retention_days=90

== 旧游标应返回 410 RESYNC_REQUIRED ==
PASS 410: code=RESYNC_REQUIRED message=游标已过期，请全量重新同步

== cursor=0 全量重拉（永不 410） ==
PASS 全量拉取: changes=1 nextCursor=20

== series / metrics ==
PASS series: buckets=1 count=3 unit=celsius
PASS metrics: relative_humidity=1, temperature_celsius=3

== export / 注销 ==
PASS export: devices=1 readings=4 nextCursor=''
PASS 注销: DELETE=204，旧 token 再访问=401

[e2e-postgres] PASS
```

> 契约套件的 260 条逐项断言与 v0.14.0 相同并按 v0.15.0 增补（匿名登录 / 双平台推送 / changes / 幂等重放 / LWW / 401·404 / readings / series·metrics / 接管码 / 导出 / 注销 / 家庭 v0.12.0 链路 / 家庭 v0.13.0 链路），全部 PASS，上方仅省略明细。

## 家庭链路覆盖矩阵（真 Postgres）

| 需求 | 覆盖方式 | 结果 |
| --- | --- | --- |
| 邀请码列表无明文 | `GET /households/{id}/invitations` 断言无 `code` 字段、响应原文不含明文；`psql` 断言 `household_invitations.code_hash` 为 64 位且 ≠ 明文 | PASS |
| 撤销后 claim 404 | `DELETE .../invitations/{id}` 204 → 第三人 `POST /invitations/claim` | PASS，404 |
| 重排缺项 409 | 3 间房整段成功 → 提交 2 间 `PUT /rooms/order` | PASS，409 `CONFLICT`（v0.13.0；后续版本 `ROOM_SET_MISMATCH`，客户端两者都识别） |
| owner 带成员退出 409 | 家庭内有 member 时 `POST /leave`，断言 `code=CONFLICT` 且 `message` 非空 | PASS |
| 移除成员 → 对方 404 | `DELETE /members/{userId}` 204 → member `GET /households/{id}` | PASS，404；`psql` 成员行只剩 owner |
| 移除后可退出 | 移除成员后 owner `POST /leave` 204 → `psql` 成员行清零 | PASS |
| 设备回个人家庭 | 契约套件断言移除后 member `GET /my/devices` 的 `householdId` 为个人家庭、`roomId=null` | PASS |

## 既有基础设施覆盖（本机）

| 需求 | 覆盖方式 | 结果 |
| --- | --- | --- |
| 匿名登录 | 真实 `POST /auth/anonymous` | PASS，返回 `expiresAt` |
| 推送设备 + 读数 | 真实 `POST /sync/push`（1 设备 / 4 读数） | PASS |
| changes | `cursor=0&limit=500` | PASS |
| 410 分支 | SQL 改 `server_ts` 100 天前 + `cleanup(90)`，再 `cursor=9` | PASS，`410 RESYNC_REQUIRED` |
| 410 后全量 | `cursor=0` | PASS，`200` + `nextCursor=20` |
| series / metrics | 2h / 1h 桶、指标清单 | PASS（3 + 1 条） |
| export | `limit=5000` | PASS（1 设备 / 4 读数） |
| 注销 | `DELETE /me` 后用旧 token 再访问 | PASS（204 → 401） |

## CI 边界

GitHub Actions 的 macOS runner **无法运行 Docker**，因此本项 **不进 CI**，只在本地执行；CI 中仍只跑 `scripts/e2e-contract.sh`（fixture）。上表结果来自本机真实运行，不是 CI 截图。
