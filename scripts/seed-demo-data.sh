#!/usr/bin/env bash
#
# 重建截图用的演示数据（本机 PJGoIoT + Postgres）。
#
# 目标数据形状与 docs/screenshots 一致：
#   3 个家庭（我的家 / 父母家 / 办公室）、6 个房间、12 台在用设备
#   （另 1 台已移除设备被「阳台信号弱记录」场景引用）、4 个场景、3 条反馈（1 条已关闭）、
#   每台在用设备 7 天读数（30 分钟一个点），客厅骑行台已标记。
#   另建 1 个只读成员账号（父母家成员），用于「成员只读」截图；该账号自带 1 个空个人家庭，
#   所以库里家庭总数是 4，但演示家庭仍是 3 个。
#
# 脚本默认先清空用户数据表（保留设备类型目录 / 固件 / 配件等公共数据）再按固定名称与
# 数量重建，因此**可重复执行**：每次都得到同样的形状，不会累积脏数据。
#
# 前置条件：
#   1. 后端 PJGoIoT v0.25.x，数据库迁移到 19（000019_device_marked_at）；
#   2. Postgres 已启动，`DATABASE_URL` 可连（默认与本机开发库一致）；
#   3. API 已以 STORE=postgres 启动并可访问 `SEED_BASE_URL`（默认 127.0.0.1:8080）；
#   4. 本机有 psql、python3、curl。
#
# 账号如何取得：
#   脚本通过 POST /auth/anonymous 新建一个匿名账号，结束时打印一次性配对码。
#   在 App「我的 → 用配对码恢复原账号」输入该码即可接管同一账号（10 分钟内有效）。
#   另打印成员账号的 memberPairingCode，用于「成员只读」截图。
#   App 会拉取 /sync/changes 里的家庭、房间、设备与场景；读数只存在于服务端，
#   本机房间详情页不读取云端读数，因此截图里设备行会显示「暂无读数」。
#
# 用法：
#   ./scripts/seed-demo-data.sh
#   DATABASE_URL='postgres://platojobs@127.0.0.1:5432/pjgoiot?sslmode=disable' ./scripts/seed-demo-data.sh
#   SEED_BASE_URL=http://127.0.0.1:8080 ./scripts/seed-demo-data.sh
#   SEED_SKIP_RESET=1 ./scripts/seed-demo-data.sh   # 不清库，仅追加（不建议，会重复家庭/场景）
#
# 安全：默认只允许清空名字为 pjgoiot / pjgoiot_seed / pjgoiot_demo 或以 _seed / _demo / _e2e
# 结尾的数据库；确需其他库时显式设置 SEED_ALLOW_RESET_ANY_DB=1。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_URL="${SEED_BASE_URL:-http://127.0.0.1:8080}"
DATABASE_URL="${DATABASE_URL:-postgres://platojobs@127.0.0.1:5432/pjgoiot?sslmode=disable}"
SKIP_RESET="${SEED_SKIP_RESET:-0}"
STATE_PATH="${SEED_STATE_PATH:-$SCRIPT_DIR/../.build/seed-state.json}"

fail() {
    echo "[seed] FAIL: $*" >&2
    exit 1
}

step() { printf '\n== %s ==\n' "$*"; }

command -v psql >/dev/null 2>&1 || fail "未找到 psql"
command -v python3 >/dev/null 2>&1 || fail "未找到 python3"
command -v curl >/dev/null 2>&1 || fail "未找到 curl"

step "检查后端健康"
HEALTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/api/v1/health" || true)"
[ "$HEALTH" = "200" ] || fail "$BASE_URL/api/v1/health 未返回 200（当前 ${HEALTH}）。请以 STORE=postgres 启动后端"

DB_NAME="$(psql "$DATABASE_URL" -tAc 'select current_database();' 2>/dev/null | tr -d '[:space:]')"
[ -n "$DB_NAME" ] || fail "无法连接 DATABASE_URL=${DATABASE_URL}"
DB_VERSION="$(psql "$DATABASE_URL" -tAc 'select max(version) from schema_migrations;' | tr -d '[:space:]')"
[ "$DB_VERSION" -ge 19 ] 2>/dev/null || fail "数据库迁移版本为 ${DB_VERSION:-未知}，需要 >= 19（先在后端仓库执行 make migrate）"
echo "[seed] 数据库：${DB_NAME}（迁移 ${DB_VERSION}）"

if [ "$SKIP_RESET" != "1" ]; then
    ALLOWED=0
    case "$DB_NAME" in
        pjgoiot|pjgoiot_seed|pjgoiot_demo) ALLOWED=1 ;;
        *_seed|*_demo|*_e2e) ALLOWED=1 ;;
    esac
    if [ "$ALLOWED" != "1" ] && [ "${SEED_ALLOW_RESET_ANY_DB:-0}" != "1" ]; then
        fail "拒绝清空数据库 ${DB_NAME}（允许 pjgoiot / *_seed / *_demo / *_e2e；确需清空请设 SEED_ALLOW_RESET_ANY_DB=1）"
    fi

    step "清空用户数据（保留设备目录 / 固件 / 配件）"
    # 动态列出所有用户数据表，排除公共目录表；push_devices 等后续迁移新增的表也会被覆盖。
    RESET_SQL="$(psql "$DATABASE_URL" -tAc "
        select coalesce(string_agg(format('%I', table_name), ', '), '')
        from information_schema.tables
        where table_schema = 'public'
          and table_name not in ('schema_migrations','device_types','device_type_catalog',
                                 'device_type_catalog_meta','device_type_catalog_audits',
                                 'gatt_services','firmwares','accessories','public_devices');
    ")"
    [ -n "$RESET_SQL" ] || fail "未找到可清空的用户数据表"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "TRUNCATE ${RESET_SQL} RESTART IDENTITY CASCADE;" >/dev/null
    echo "[seed] 已清空：$RESET_SQL"
else
    step "跳过清库（SEED_SKIP_RESET=1）"
fi

step "创建账号与演示数据"
mkdir -p "$(dirname "$STATE_PATH")"
python3 - "$BASE_URL" "$STATE_PATH" <<'PY'
import json
import math
import os
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

BASE = sys.argv[1].rstrip("/")
API = BASE + "/api/v1"
NAMESPACE = uuid.UUID("6f6f0a52-2f3b-4d4f-9b2e-0d3f2b8c7a11")

client_id = "codemagic-demo-seed"


def request(method, path, token=None, body=None, idem=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(API + "/" + path, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if idem:
        req.add_header("Idempotency-Key", idem)
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            raw = res.read()
            return res.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as err:
        raw = err.read()
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = raw.decode("utf-8", "replace")
        raise SystemExit(f"[seed] {method} {path} -> {err.code}: {payload}")


def stable_id(label):
    return str(uuid.uuid5(NAMESPACE, label))


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


now = datetime.now(timezone.utc)
anchor = now.replace(minute=(now.minute // 30) * 30, second=0, microsecond=0)
now_iso = iso(anchor)

# ---- 账号 ----
status, account = request("POST", "auth/anonymous", body={})
assert status == 201, (status, account)
token = account["token"]
user_id = account["userId"]

status, household_list = request("GET", "households", token=token)
assert status == 200, (status, household_list)
personal = next((h for h in household_list["items"] if h.get("personal")), None)
assert personal, "匿名账号应自带个人家庭"
my_home = personal["id"]

# ---- 家庭 ----
extra_households = {}
for name in ["父母家", "办公室"]:
    status, household = request("POST", "households", token=token, body={"name": name})
    assert status == 201, (status, household)
    extra_households[name] = household["id"]

parents = extra_households["父母家"]
office = extra_households["办公室"]

# ---- 房间 ----
rooms = {}


def add_room(key, household_id, name, sort_order):
    status, room = request(
        "POST", f"households/{household_id}/rooms", token=token,
        body={"name": name, "sortOrder": sort_order},
    )
    assert status == 201, (status, room)
    rooms[key] = {"id": room["id"], "household": household_id, "name": name}


add_room("living", my_home, "客厅", 1)
add_room("master", my_home, "主卧", 2)
add_room("second", my_home, "次卧", 3)
add_room("parents-living", parents, "客厅", 1)
add_room("parents-study", parents, "书房", 2)
add_room("office-desk", office, "工位", 1)

# ---- 设备 ----
# (key, room key, 名称, 序号, deviceType, 指标)
devices = [
    ("living-env", "living", "客厅温湿度计", "01", "environmental_sensor", ["temperature_celsius", "relative_humidity"]),
    ("living-bike", "living", "客厅骑行台", "02", "cycling_speed_cadence", ["cadence_rpm", "wheel_speed_kmh"]),
    ("living-hr", "living", "客厅心率带", "03", "heart_rate_monitor", ["heart_rate"]),
    ("master-scale", "master", "主卧体脂秤", "04", "smart_scale", ["weight_kg", "body_fat_percent"]),
    ("master-env", "master", "主卧温湿度计", "05", "environmental_sensor", ["temperature_celsius", "relative_humidity"]),
    ("second-env", "second", "次卧温湿度计", "06", "environmental_sensor", ["temperature_celsius", "relative_humidity"]),
    ("second-hr", "second", "次卧心率带", "07", "heart_rate_monitor", ["heart_rate"]),
    ("parents-env", "parents-living", "父母家温湿度计", "08", "environmental_sensor", ["temperature_celsius", "relative_humidity"]),
    ("parents-hr", "parents-living", "父母家心率带", "09", "heart_rate_monitor", ["heart_rate"]),
    ("office-env", "office-desk", "办公室环境传感器", "10", "environmental_sensor", ["temperature_celsius", "relative_humidity"]),
    ("office-hr", "office-desk", "办公室心率带", "11", "heart_rate_monitor", ["heart_rate"]),
    ("office-scale", "office-desk", "办公室体脂秤", "12", "smart_scale", ["weight_kg"]),
]

def external_id(index): return f"AA:BB:CC:00:00:{index}"

push_devices = []
device_meta = {}
for key, room_key, alias, index, dtype, metrics in devices:
    ext = external_id(index)
    device_meta[key] = {"externalId": ext, "room": rooms[room_key], "metrics": metrics, "type": dtype}
    entry = {
        "id": stable_id("device:" + ext),
        "platform": "android",
        "externalId": ext,
        "mac": ext.lower(),
        "alias": alias,
        "advertisedName": alias,
        "updatedAt": now_iso,
        "deleted": False,
        "deviceType": dtype,
    }
    if key == "living-bike":
        entry["markedAt"] = iso(anchor - timedelta(hours=2))
    push_devices.append(entry)

# 已移除设备：先创建，供「阳台信号弱记录」场景引用，最后再发 tombstone。
removed_ext = external_id("13")
push_devices.append({
    "id": stable_id("device:" + removed_ext),
    "platform": "android",
    "externalId": removed_ext,
    "mac": removed_ext.lower(),
    "alias": "阳台温湿度计",
    "advertisedName": "阳台温湿度计",
    "updatedAt": now_iso,
    "deleted": False,
    "deviceType": "environmental_sensor",
})

status, result = request(
    "POST", "sync/push", token=token,
    body={"clientId": client_id, "devices": push_devices},
    idem=stable_id("push:devices"),
)
assert status == 200, (status, result)
assert not result.get("conflicts"), result

# 分配到家庭 / 房间
for key, meta in device_meta.items():
    ext = meta["externalId"]
    status, _ = request(
        "PATCH", f"my/devices/android/{ext}", token=token,
        body={"householdId": meta["room"]["household"], "roomId": meta["room"]["id"]},
    )
    assert status == 200, (status, key)

# ---- 读数：7 天，每 30 分钟一个点 ----
readings = []
POINTS = 7 * 48


def series_value(metric, step):
    # 稳定的日周期 + 小步长抖动，避免随机数导致每次重跑形状漂移。
    phase = step / 48.0 * 2 * math.pi
    if metric == "temperature_celsius":
        return round(24.5 + 2.1 * math.sin(phase) + 0.05 * (step % 5), 1)
    if metric == "relative_humidity":
        return round(52.0 - 6.0 * math.sin(phase) + 0.2 * (step % 4), 1)
    if metric == "heart_rate":
        return float(72 + int(6 * math.sin(phase)) + (step % 3))
    if metric == "cadence_rpm":
        return float(78 + int(4 * math.sin(phase)) + (step % 2))
    if metric == "wheel_speed_kmh":
        return round(24.5 + 1.5 * math.sin(phase), 1)
    if metric == "weight_kg":
        return round(68.2 + 0.3 * math.sin(phase), 1)
    if metric == "body_fat_percent":
        return round(18.4 + 0.2 * math.sin(phase), 1)
    raise ValueError(metric)


UNIT = {
    "temperature_celsius": "celsius",
    "relative_humidity": "%",
    "heart_rate": "bpm",
    "cadence_rpm": "rpm",
    "wheel_speed_kmh": "km/h",
    "weight_kg": "kg",
    "body_fat_percent": "%",
}

for key, meta in device_meta.items():
    for step in range(POINTS):
        recorded = anchor - timedelta(minutes=30 * step)
        for metric in meta["metrics"]:
            readings.append({
                "id": stable_id(f"reading:{meta['externalId']}:{metric}:{iso(recorded)}"),
                "platform": "android",
                "externalId": meta["externalId"],
                "metric": metric,
                "value": series_value(metric, step),
                "unit": UNIT[metric],
                "recordedAt": iso(recorded),
                "deviceType": meta["type"],
            })

BATCH = 500
for index in range(0, len(readings), BATCH):
    chunk = readings[index:index + BATCH]
    status, result = request(
        "POST", "sync/push", token=token,
        body={"clientId": client_id, "readings": chunk},
        idem=stable_id(f"push:readings:{index}"),
    )
    assert status == 200, (status, result)
    assert not result.get("conflicts"), result

# ---- 场景 ----
scenes = [
    {
        "name": "客厅温度过高提醒",
        "trigger": {
            "kind": "metric_threshold",
            "device": {"platform": "android", "externalId": device_meta["living-env"]["externalId"]},
            "deviceType": "environmental_sensor",
            "metric": {"metric": "temperature_celsius", "comparator": "gte", "threshold": 28, "consecutive": 3},
        },
        "actions": [
            {"kind": "notify", "title": "客厅温度过高", "body": "客厅温度已连续 3 次超过 28℃，请检查通风。"},
            {"kind": "log", "message": "客厅温度超过阈值", "level": "warn"},
        ],
    },
    {
        "name": "主卧设备离线提醒",
        "trigger": {
            "kind": "device_offline",
            "device": {"platform": "android", "externalId": device_meta["master-env"]["externalId"]},
            "offlineSeconds": 900,
        },
        "actions": [
            {"kind": "notify", "title": "主卧设备离线", "body": "主卧温湿度计已离线超过 15 分钟。"},
        ],
    },
    {
        "name": "阳台信号弱记录",
        "trigger": {
            "kind": "rssi_below",
            "device": {"platform": "android", "externalId": removed_ext},
            "rssiThreshold": -75,
        },
        "actions": [
            {"kind": "log", "message": "阳台设备信号低于 -75 dBm", "level": "info"},
        ],
    },
    {
        "name": "工作日早晨开窗提醒",
        "trigger": {
            "kind": "schedule",
            "timeOfDay": "08:00",
            "timezone": "Asia/Shanghai",
            "daysOfWeek": [1, 2, 3, 4, 5],
        },
        "actions": [
            {"kind": "notify", "title": "该开窗通风了", "body": "工作日早晨 08:00，记得开窗通风。"},
        ],
    },
]
for scene in scenes:
    status, created = request("POST", "scenes", token=token, body=scene)
    assert status == 201, (status, created)

# 场景引用存在后，再把设备标记为已移除（deviceMissing 徽章就是这么来的）。
status, result = request(
    "POST", "sync/push", token=token,
    body={"clientId": client_id, "devices": [{
        "id": stable_id("device:" + removed_ext),
        "platform": "android",
        "externalId": removed_ext,
        "mac": removed_ext.lower(),
        "updatedAt": iso(anchor + timedelta(minutes=1)),
        "deleted": True,
        "deviceType": "environmental_sensor",
    }]},
    idem=stable_id("push:removed-device"),
)
assert status == 200, (status, result)
assert not result.get("conflicts"), result

# ---- 反馈 ----
feedback = [
    ("experience", "市场页的配件说明太长了，建议折叠到详情里。"),
    ("feature", "希望场景支持按房间批量启停。"),
    ("bug", "在 2.0 倍字号下，场景列表的冷却时间会被截断。"),
]
created_feedback = []
for kind, body in feedback:
    status, created = request(
        "POST", "feedback", token=token,
        body={
            "kind": kind,
            "body": body,
            "context": {
                "platform": "ios",
                "appVersion": "0.31.1",
                "buildType": "simulator",
                "osVersion": "iOS 27.2",
                "deviceModel": "iPhone 18 Pro Max",
            },
        },
    )
    assert status == 201, (status, created)
    created_feedback.append(created["feedbackId"])

status, _ = request(
    "PATCH", f"feedback/{created_feedback[-1]}", token=token, body={"status": "closed"}
)
assert status == 200, status

# ---- 配对码：交给 App「用配对码恢复原账号」 ----
status, pairing = request("POST", "auth/pairing-code", token=token)
assert status == 201, (status, pairing)

# ---- 成员账号：用于「成员只读」截图（父母家·客厅）----
# 成员账号由 /auth/anonymous 新建，会自带一个空的个人家庭，因此总数是 4（3 个演示家庭 + 1 个空个人家庭）。
status, invitation = request("POST", f"households/{parents}/invitations", token=token)
assert status == 201, (status, invitation)

status, member_account = request("POST", "auth/anonymous", body={})
assert status == 201, (status, member_account)
member_token = member_account["token"]
member_user_id = member_account["userId"]

status, _ = request(
    "POST", "households/invitations/claim", token=member_token,
    body={"code": invitation["code"]},
)
assert status in (200, 201), (status, "成员领取邀请码失败")

status, member_pairing = request("POST", "auth/pairing-code", token=member_token)
assert status == 201, (status, member_pairing)

status, summary = request("GET", "sync/changes?cursor=0&limit=500", token=token)
assert status == 200, (status, summary)

result = {
    "userId": user_id,
    "households": 3,
    "memberHouseholds": 2,
    "memberUserId": member_user_id,
    "rooms": len(rooms),
    "devices": len(devices),
    "removedDevices": 1,
    "readings": len(readings),
    "scenes": len(scenes),
    "feedback": len(feedback),
    "closedFeedback": 1,
    "pairingCode": pairing["code"],
    "pairingExpiresAt": pairing["expiresAt"],
    "memberPairingCode": member_pairing["code"],
    "memberPairingExpiresAt": member_pairing["expiresAt"],
    "memberToken": member_token,
    "changeLog": len(summary.get("changes", [])),
    "token": token,
}

state_path = sys.argv[2]
with open(state_path, "w", encoding="utf-8") as handle:
    json.dump(result, handle, ensure_ascii=False, indent=2)
os.chmod(state_path, 0o600)

print(json.dumps({k: v for k, v in result.items() if k not in ("token", "memberToken")}, ensure_ascii=False, indent=2))
print(f"\n[seed] token 与配对码已写入 {state_path}（600，勿提交）")
PY

step "完成"
echo "[seed] 数据形状：3 家庭 / 6 房间 / 12 在用设备 + 1 台已移除 / 4 场景 / 3 反馈（1 已关闭）"
echo "[seed] 成员账号：父母家·客厅只读（成员自带 1 个空个人家庭，总家庭数 4）"
echo "[seed] 在 App「我的 → 用配对码恢复原账号」输入上面的 pairingCode 即可接管账号（10 分钟内有效）"
echo "[seed] 成员只读截图使用 memberPairingCode 接管成员账号（同样是 10 分钟一次性）"
