# 真实 Postgres 端到端联调（v0.10.0）

本文件记录 `scripts/e2e-postgres.sh` 的**真实本地运行输出**。与 `scripts/e2e-contract.sh`（后端 `STORE=fixture` 内存态）不同，本项起真实 Postgres + 真实 API，额外覆盖只有真实库才能构造的分支。

## 环境与命令

- iOS 仓库：`codemagic`（v0.10.0）
- 后端：`PJGoIoT` `v0.9.0-1-g1af7dc9`（openapi `0.7.0`）
- 本机：macOS + Docker + Go 1.24+（Docker daemon 可用）
- 命令：

```bash
cd /Users/platojobs/Desktop/GitHub/platojobs/codemagic
./scripts/e2e-postgres.sh
```

脚本行为：

1. 用 `$PJGOIOT_DIR/scripts/stack-for-e2e.sh` 在 `mktemp` 目录里起独立 Postgres 容器与 API，stdout 输出 `BASE_URL`；
2. **以 `E2E_EXTERNAL_BASE_URL` 复用该栈**跑现有 151 项契约套件（`e2e-contract.sh` 支持外部后端后不再自起 fixture）；
3. 用真实 SQL 把最老 `change_log.seq` 的 `server_ts` 改到 100 天前，再跑 `cmd/cleanup`（保留 90 天），构造 **410 `RESYNC_REQUIRED`**；
4. 验证 `cursor=0` 全量重拉永不 410、series / metrics、export（limit=5000）、注销；
5. `trap` 停止栈并删除临时目录；`E2E_KEEP_STATE=1` 可保留现场。

隔离说明：所有后端状态与日志都在 `mktemp` 目录（`E2E_STATE_DIR`）；契约 runner 是纯网络、无本地状态，**不读写 App 开发用的 SQLite / UserDefaults**。

## 真实输出（2026-11-05）

```text
== 起真实 Postgres + API（状态目录 /var/folders/…/codemagic-e2e-pg.bL4yIw/stack） ==
BASE_URL=http://127.0.0.1:56342
PG_CONTAINER=pjgoiot-e2e-pg-10913-1 DATABASE_URL=postgres://pjgoiot:pjgoiot-e2e-only@127.0.0.1:56328/pjgoiot_e2e?sslmode=disable

== 跑现有契约套件（复用真实栈） ==
[e2e] 复用外部后端：http://127.0.0.1:56342（跳过构建与启动）
[e2e] health 200
[e2e] 编译 Swift 联调 runner…
[e2e] 运行联调用例（真实网络，直连 http://127.0.0.1:56342）
…
=== E2E 合同联调结果 ===
通过：151 项，跳过：0 项，失败：0 项
结论：PASS

=== e2e-contract 摘要 ===
后端：外部复用 http://127.0.0.1:56342
结果：PASS

== 匿名登录 ==
PASS 匿名登录: userId=124de1c8-6a8f-478d-a4b1-e0d5232d67ef expiresAt=2027-05-04T06:06:49.216292Z

== 推送 iOS 设备 + 读数（第一次） ==
PASS push#1: applied=1 appliedReadings=4

== 再次更新同一设备（制造两条 change_log，供 410 构造间隙） ==
PASS push#2: applied=1

== 增量拉取（cursor=0） ==
最老 seq=10，用 cursor=9（小于保留边界）构造 410

== 构造游标失效：最老 seq server_ts 改为 100 天前，再跑 cleanup(90 天) ==
cleanup: change_log_deleted=1 change_log_cutoff=2026-08-07T06:06:51Z change_log_retention_days=90

== 旧游标应返回 410 RESYNC_REQUIRED ==
PASS 410: code=RESYNC_REQUIRED message=游标已过期，请全量重新同步

== cursor=0 全量重拉（永不 410） ==
PASS 全量拉取: changes=1 nextCursor=11

== series / metrics ==
PASS series: buckets=1 count=3 unit=celsius
PASS metrics: relative_humidity=1, temperature_celsius=3

== export / 注销 ==
PASS export: devices=1 readings=4 nextCursor=''
PASS 注销: DELETE=204，旧 token 再访问=401

[e2e-postgres] PASS
```

> 契约套件的 151 条逐项断言与 v0.9.0 相同（匿名登录 / 双平台推送 / changes / 幂等重放 / LWW / 401·404 / readings / series·metrics / 接管码 / 导出 / 注销），本次全部 PASS，仅在上方省略明细。

## 覆盖矩阵

| 需求 | 覆盖方式 | 结果 |
| --- | --- | --- |
| 匿名登录 | 真实 `POST /auth/anonymous` | PASS，返回 `expiresAt` |
| 推送设备 + 读数 | 真实 `POST /sync/push`（1 设备 / 4 读数） | PASS |
| changes | `cursor=0&limit=500` | PASS，2 条变更 |
| 410 分支 | SQL 改 `server_ts` 100 天前 + `cleanup(90)`，再 `cursor=9` | PASS，`410 RESYNC_REQUIRED` |
| 410 后全量 | `cursor=0` | PASS，`200` + `nextCursor=11` |
| series / metrics | 2h / 1h 桶、指标清单 | PASS（3 + 1 条） |
| export | `limit=5000` | PASS（1 设备 / 4 读数） |
| 注销 | `DELETE /me` 后用旧 token 再访问 | PASS（204 → 401） |

## CI 边界

GitHub Actions 的 macOS runner **无法运行 Docker**，因此本项 **不进 CI**，只在本地执行；CI 中仍只跑 `scripts/e2e-contract.sh`（fixture）。上表结果来自本机真实运行，不是 CI 截图。
