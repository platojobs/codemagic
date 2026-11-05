#!/usr/bin/env bash
#
# 端到端契约联调（iOS ↔ PJGoIoT）。
#
# 依赖本地 Go 服务，默认不纳入 CI。
#
# 用法：
#   ./scripts/e2e-contract.sh
#   PJGOIOT_DIR=/path/to/PJGoIoT ./scripts/e2e-contract.sh
#   E2E_PORT=18080 ./scripts/e2e-contract.sh
#
# 流程：
#   1. 从 ../PJGoIoT 构建并启动服务（STORE=fixture，端口 8080，被占用则用 18080）；
#   2. 等待 GET /api/v1/health 返回 200；
#   3. 编译并运行 scripts/e2e-contract.swift（真实 URLSession，直连 localhost，不走模拟器）；
#   4. 退出时关闭服务并打印摘要。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PJGOIOT_DIR="${PJGOIOT_DIR:-$ROOT_DIR/../PJGoIoT}"
BUILD_DIR="$ROOT_DIR/.build/e2e"
SERVER_LOG="$BUILD_DIR/pjgoiot-server.log"
SERVER_BIN="$BUILD_DIR/pjgoiot-api"
RUNNER_BIN="$BUILD_DIR/e2e-contract-runner"

SERVER_PID=""
RUNNER_EXIT=1
PORT=""

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

fail() {
    echo "[e2e] FAIL: $1" >&2
    exit 1
}

port_in_use() {
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

echo "[e2e] 仓库：$ROOT_DIR"
echo "[e2e] 后端：$PJGOIOT_DIR"

command -v go >/dev/null 2>&1 || fail "未找到 go，无法启动 PJGoIoT"
command -v swiftc >/dev/null 2>&1 || fail "未找到 swiftc，无法编译联调 runner"
command -v curl >/dev/null 2>&1 || fail "未找到 curl，无法做健康检查"
[ -d "$PJGOIOT_DIR" ] || fail "后端目录不存在：$PJGOIOT_DIR"
[ -f "$PJGOIOT_DIR/cmd/api/main.go" ] || fail "未找到 $PJGOIOT_DIR/cmd/api/main.go"

mkdir -p "$BUILD_DIR"

echo "[e2e] 构建后端二进制…"
if ! (cd "$PJGOIOT_DIR" && go build -o "$SERVER_BIN" ./cmd/api) >"$SERVER_LOG" 2>&1; then
    echo "[e2e] 后端构建失败，日志：$SERVER_LOG" >&2
    sed -n '1,80p' "$SERVER_LOG" >&2
    exit 1
fi

if [ -n "${E2E_PORT:-}" ]; then
    if port_in_use "$E2E_PORT"; then
        fail "E2E_PORT=$E2E_PORT 已被占用"
    fi
    PORT="$E2E_PORT"
elif ! port_in_use 8080; then
    PORT=8080
elif ! port_in_use 18080; then
    PORT=18080
else
    fail "8080 与 18080 均被占用，请设置 E2E_PORT 指定空闲端口"
fi

echo "[e2e] 启动后端：STORE=fixture ADDR=127.0.0.1:${PORT}（本套用例 ~100 次请求，关闭限流避免 429 抖动）"
(
    cd "$PJGOIOT_DIR" || exit 1
    STORE=fixture \
    ADDR="127.0.0.1:$PORT" \
    APP_VERSION="e2e" \
    LOG_LEVEL=warn \
    RATE_LIMIT_PER_MINUTE=0 \
    RATE_LIMIT_BURST=0 \
    FIXTURES_DIR="$PJGOIOT_DIR/fixtures" \
    "$SERVER_BIN" >>"$SERVER_LOG" 2>&1
) &
SERVER_PID=$!

HEALTH_URL="http://127.0.0.1:$PORT/api/v1/health"
echo "[e2e] 等待 $HEALTH_URL 返回 200…"
HEALTH_OK=0
for _ in $(seq 1 60); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "[e2e] 后端进程已退出，日志：$SERVER_LOG" >&2
        sed -n '1,120p' "$SERVER_LOG" >&2
        exit 1
    fi
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$HEALTH_URL" 2>/dev/null || true)"
    if [ "$HTTP_CODE" = "200" ]; then
        HEALTH_OK=1
        break
    fi
    sleep 0.5
done
[ "$HEALTH_OK" = "1" ] || fail "健康检查未在 30s 内返回 200（日志：$SERVER_LOG）"
echo "[e2e] health 200"

echo "[e2e] 编译 Swift 联调 runner…"
if ! swiftc -O "$SCRIPT_DIR/e2e-contract.swift" -o "$RUNNER_BIN" >"$BUILD_DIR/swiftc.log" 2>&1; then
    echo "[e2e] runner 编译失败：" >&2
    sed -n '1,120p' "$BUILD_DIR/swiftc.log" >&2
    exit 1
fi

echo "[e2e] 运行联调用例（真实网络，直连 127.0.0.1:${PORT}）"
E2E_BASE_URL="http://127.0.0.1:$PORT" "$RUNNER_BIN"
RUNNER_EXIT=$?

echo
echo "=== e2e-contract 摘要 ==="
echo "后端：${SERVER_BIN}（STORE=fixture）"
echo "端口：$PORT"
echo "服务日志：$SERVER_LOG"
if [ "$RUNNER_EXIT" = "0" ]; then
    echo "结果：PASS"
else
    echo "结果：FAIL（exit=${RUNNER_EXIT}）"
fi

exit "$RUNNER_EXIT"
