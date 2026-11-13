# 真实 Postgres 端到端联调

`scripts/e2e-postgres.sh` 起真实 Postgres + API，复用现有 460 项契约套件，并额外验证只有真实库能构造的分支。与 `e2e-contract.sh`（`STORE=fixture`）互补。

## 运行

```bash
git -C ../PJGoIoT worktree add /tmp/pjgoiot-v026 v0.26.0
PJGOIOT_DIR=/tmp/pjgoiot-v026 ./scripts/e2e-postgres.sh
```

脚本用 `stack-for-e2e.sh` 在 `mktemp` 目录启动独立容器与 API，以 `E2E_EXTERNAL_BASE_URL` 复用该栈跑契约套件，结束后 `trap` 清理；`E2E_KEEP_STATE=1` 保留现场。所有状态与日志都在临时目录，不读写 App 的 SQLite / UserDefaults。

## 覆盖

- 家庭链路：邀请码只存哈希、撤销后 claim 404、房间重排缺项 409、owner 带成员退出 409、移除成员后 404。
- 家庭结构：`isSelf`、转让、改名 / 建房 / 删房、双方 `change_log`、移除后的可见性。
- 推送令牌：同 token 幂等、`inactive` 重置、跨用户隔离、`change_log` 无副作用。
- 游标失效：SQL 把最老 `server_ts` 改到 100 天前 + `cleanup(90)`，构造 410 `RESYNC_REQUIRED`；`cursor=0` 永不 410。
- series / metrics、export 异步任务与下载、注销令牌。

## 最近结果（2026-11-07，后端 v0.26.0 / 契约 0.21.0 / 迁移 20）

契约套件 460 通过 / 0 跳过 / 0 失败；家庭链路、结构变更、推送令牌均 PASS；410 与全量重拉 PASS；export / 注销 PASS。

## CI 边界

- GitHub Actions macOS runner 不能跑 Docker，本项**不进 CI**，只在本地执行。
- CI 只跑 `e2e-contract.sh`（fixture）。fixture 不记录读数接收时间，`presence` 恒为 `unknown`，不能证明 online / offline；这两条由本文件的真实 Postgres 步骤覆盖。
- CI 的 `e2e-contract` 仍 pin `PJGoIoT` v0.25.0（无 presence 字段），遇到缺字段时打印 `[SKIP]` 并显式跳过，不计入通过；字段存在时走硬断言。
