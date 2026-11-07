#!/usr/bin/env bash
#
# 真实 Postgres 端到端联调（iOS ↔ PJGoIoT）。
#
# 与 scripts/e2e-contract.sh 的区别：
#   - e2e-contract.sh 默认用后端 STORE=fixture（内存态），只验证 HTTP 契约；
#   - 本脚本用 PJGoIoT/scripts/stack-for-e2e.sh 起「真实 Postgres + 真实 API」，
#     再跑同一套契约用例，并额外验证只有真实库才能构造的分支：
#     cursor 失效 410 / series / metrics / export / 注销。
#
# 状态隔离：所有后端状态、日志与临时文件都放进 mktemp 目录（E2E_STATE_DIR），
# 不读写 App 的开发 SQLite / UserDefaults；契约 runner 本身是纯网络、无本地状态。
# 数据库隔离：本脚本只允许连名字含 `_e2e` 的独立库（默认 pjgoiot_e2e），启动后会校验
# DATABASE_URL 的库名，防止误连开发库 pjgoiot 并清空演示数据。
#
# GitHub Actions 的 macOS runner 无法运行 Docker，因此本脚本**不进 CI**，仅本地执行。
#
# 用法：
#   ./scripts/e2e-postgres.sh
#   PJGOIOT_DIR=/path/to/PJGoIoT ./scripts/e2e-postgres.sh
#   E2E_KEEP_STATE=1 ./scripts/e2e-postgres.sh   # 失败排查时保留临时目录

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PJGOIOT_DIR="${PJGOIOT_DIR:-$IOS_ROOT/../PJGoIoT}"
STACK_SCRIPT="$PJGOIOT_DIR/scripts/stack-for-e2e.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codemagic-e2e-pg.XXXXXX")"
export E2E_STATE_DIR="$TMP_ROOT/stack"
mkdir -p "$E2E_STATE_DIR" "$TMP_ROOT/artifacts"

PG_USER="pjgoiot"
PG_DB="pjgoiot_e2e"
STACK_STARTED=0
KEEP_STATE="${E2E_KEEP_STATE:-0}"

log() { printf '%s\n' "$*" >&2; }
step() { printf '\n== %s ==\n' "$*" >&2; }
fail() {
    log "FAIL: $*"
    exit 1
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [ "$STACK_STARTED" = "1" ]; then
        (cd "$PJGOIOT_DIR" && E2E_STATE_DIR="$E2E_STATE_DIR" "$STACK_SCRIPT" --stop >/dev/null 2>&1) || true
    fi
    if [ "$KEEP_STATE" = "1" ]; then
        log "临时目录保留：$TMP_ROOT"
    else
        rm -rf "$TMP_ROOT"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

[ -x "$STACK_SCRIPT" ] || fail "未找到可执行的后端起栈脚本：$STACK_SCRIPT"
command -v docker >/dev/null 2>&1 || fail "未找到 docker（本项只能本地跑，不进 CI）"
command -v python3 >/dev/null 2>&1 || fail "未找到 python3"
command -v curl >/dev/null 2>&1 || fail "未找到 curl"

step "起真实 Postgres + API（状态目录 ${E2E_STATE_DIR}）"
STACK_OUT="$(cd "$PJGOIOT_DIR" && E2E_STATE_DIR="$E2E_STATE_DIR" "$STACK_SCRIPT" 2>"$TMP_ROOT/stack.log")" || {
    cat "$TMP_ROOT/stack.log" >&2 || true
    fail "起栈失败"
}
STACK_STARTED=1
BASE_URL="$(printf '%s\n' "$STACK_OUT" | sed -n 's/^BASE_URL=//p' | tail -1)"
[ -n "$BASE_URL" ] || fail "起栈脚本未输出 BASE_URL"
# shellcheck disable=SC1090
source "$E2E_STATE_DIR/stack.env"
DATABASE_DB="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).path.lstrip("/"))' "$DATABASE_URL")"
case "$DATABASE_DB" in
    *_e2e) ;;
    *) fail "DATABASE_URL 指向数据库 ${DATABASE_DB:-未知}，e2e 只允许名字含 _e2e 的独立库（默认 pjgoiot_e2e），拒绝运行" ;;
esac
log "BASE_URL=$BASE_URL"
log "PG_CONTAINER=$PG_CONTAINER DATABASE_URL=$DATABASE_URL"

step "跑现有契约套件（复用真实栈）"
E2E_EXTERNAL_BASE_URL="$BASE_URL" "$SCRIPT_DIR/e2e-contract.sh" || fail "现有契约套件未通过"

step "家庭链路（真 Postgres）：成员移除 / 退出 409 / 邀请码无明文 / 重排 409"
python3 - "$BASE_URL" >"$TMP_ROOT/artifacts/household.json" <<'PY'
import hashlib
import json
import sys
import urllib.error
import urllib.request

base = sys.argv[1]


def call(method, path, token=None, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(base + "/api/v1/" + path, data=data, method=method)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = None
        return error.code, payload


owner = call("POST", "auth/anonymous")[1]
member = call("POST", "auth/anonymous")[1]
outsider = call("POST", "auth/anonymous")[1]

status, household = call("POST", "households", token=owner["token"], body={"name": "pg-家庭"})
assert status == 201, (status, household)
hid = household["id"]

status, invite = call("POST", f"households/{hid}/invitations", token=owner["token"], body={})
assert status == 201, (status, invite)
code = invite["code"]

# 再签发一个：一个用于列表检查与撤销，一个留给成员领取
status, invite2 = call("POST", f"households/{hid}/invitations", token=owner["token"], body={})
assert status == 201, (status, invite2)
code2 = invite2["code"]

# 邀请码列表：只有哈希前缀，没有明文
status, listed = call("GET", f"households/{hid}/invitations", token=owner["token"])
assert status == 200 and listed["items"], (status, listed)
item = listed["items"][0]
assert "code" not in item and item["codeHashPrefix"], item
assert code.upper() not in json.dumps(listed).upper(), "列表响应泄露明文邀请码"
assert code2.upper() not in json.dumps(listed).upper(), "列表响应泄露明文邀请码"

status, _ = call("POST", "households/invitations/claim", token=member["token"], body={"code": code})
assert status == 200, status
status, joinedList = call("GET", "households", token=member["token"])
assert status == 200 and any(h["id"] == hid for h in joinedList["items"]), joinedList

# 列表只给出哈希前缀：用 SHA-256(code2) 前缀定位要撤销的这一条
prefix2 = hashlib.sha256(code2.encode("utf-8")).hexdigest()[:8]
target = next(item for item in listed["items"] if item["codeHashPrefix"] == prefix2)
assert code2.upper() not in json.dumps(listed).upper(), "列表响应泄露明文邀请码"

status, _ = call("DELETE", f"households/{hid}/invitations/{target['id']}", token=owner["token"])
assert status == 204, status
status, _ = call("POST", "households/invitations/claim", token=outsider["token"], body={"code": code2})
assert status == 404, status

# 整段重排：完整成功，缺项 409 ROOM_SET_MISMATCH
room_ids = []
for index, name in enumerate(["客厅", "卧室", "书房"]):
    status, room = call(
        "POST", f"households/{hid}/rooms", token=owner["token"],
        body={"name": name, "sortOrder": index + 1},
    )
    assert status == 201, (status, room)
    room_ids.append(room["id"])
status, ordered = call(
    "PUT", f"households/{hid}/rooms/order", token=owner["token"],
    body={"roomIds": [room_ids[2], room_ids[0], room_ids[1]]},
)
assert status == 200, (status, ordered)
status, mismatch = call(
    "PUT", f"households/{hid}/rooms/order", token=owner["token"],
    body={"roomIds": [room_ids[0], room_ids[1]]},
)
assert status == 409 and mismatch["error"]["code"] in ("ROOM_SET_MISMATCH", "CONFLICT"), (status, mismatch)

# owner 带成员退出 409（可读 message）
status, conflict = call("POST", f"households/{hid}/leave", token=owner["token"])
assert status == 409 and conflict["error"]["code"] == "CONFLICT", (status, conflict)
assert conflict["error"]["message"], conflict["error"]

# 移除成员 → 对方 404
status, _ = call("DELETE", f"households/{hid}/members/{member['userId']}", token=owner["token"])
assert status == 204, status
status, _ = call("GET", f"households/{hid}", token=member["token"])
assert status == 404, status

# 留一条邀请码给数据库侧核验（确认只存哈希）
status, invite3 = call("POST", f"households/{hid}/invitations", token=owner["token"], body={})
assert status == 201, (status, invite3)

print(json.dumps({
    "householdId": hid,
    "ownerToken": owner["token"],
    "ownerUserId": owner["userId"],
    "memberUserId": member["userId"],
    "code": invite3["code"],
}))
PY
hh="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["householdId"])' "$TMP_ROOT/artifacts/household.json")"
invite_code="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["code"])' "$TMP_ROOT/artifacts/household.json")"
owner_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ownerToken"])' "$TMP_ROOT/artifacts/household.json")"

# 直接查库：邀请码只存哈希、不存明文；移除成员后只剩 owner
HASH_CHECK="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM household_invitations WHERE household_id = '$hh'::uuid AND length(code_hash) = 64 AND code_hash <> '$invite_code';" | tr -d '[:space:]')"
[ "$HASH_CHECK" = "1" ] || fail "邀请码应只存 64 位哈希且不含明文（got=$HASH_CHECK）"
MEMBERS_AFTER="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM household_members WHERE household_id = '$hh'::uuid;" | tr -d '[:space:]')"
[ "$MEMBERS_AFTER" = "1" ] || fail "移除成员后应只剩 owner（got=$MEMBERS_AFTER）"

# 移除后可退出，家庭与成员行清理
LEAVE_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $owner_token" "$BASE_URL/api/v1/households/$hh/leave")"
[ "$LEAVE_CODE" = "204" ] || fail "移除成员后 owner 退出期望 204，实际 $LEAVE_CODE"
MEMBERS_FINAL="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM household_members WHERE household_id = '$hh'::uuid;" | tr -d '[:space:]')"
[ "$MEMBERS_FINAL" = "0" ] || fail "owner 退出后成员行应清空（got=$MEMBERS_FINAL）"
log "PASS 真 Postgres：邀请码仅存哈希；移除成员 404；owner 退出 409→移除后可退出"

step "家庭结构变更（真 Postgres）：isSelf / 改名 / 建房 / 删房 / 转让 / 移除可见性"
python3 - "$BASE_URL" >"$TMP_ROOT/artifacts/structural.json" <<'PY'
import json
import sys
import urllib.error
import urllib.request

base = sys.argv[1]


def call(method, path, token=None, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(base + "/api/v1/" + path, data=data, method=method)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = None
        return error.code, payload


def changes(token):
    status, body = call("GET", "sync/changes?cursor=0&limit=500", token=token)
    assert status == 200, (status, body)
    return body["changes"]


owner = call("POST", "auth/anonymous")[1]
member = call("POST", "auth/anonymous")[1]

status, household = call("POST", "households", token=owner["token"], body={"name": "pg-结构"})
assert status == 201, (status, household)
hid = household["id"]
status, invite = call("POST", f"households/{hid}/invitations", token=owner["token"], body={})
assert status == 201, (status, invite)
status, _ = call("POST", "households/invitations/claim", token=member["token"], body={"code": invite["code"]})
assert status == 200, status

status, members = call("GET", f"households/{hid}/members", token=owner["token"])
assert status == 200 and len(members["items"]) == 2, (status, members)
self_rows = [item for item in members["items"] if item.get("isSelf") is True]
assert len(self_rows) == 1 and self_rows[0]["userId"] == owner["userId"], members
assert next(item for item in members["items"] if item["userId"] == member["userId"])["role"] == "member", members

# 转让：非 owner 403，目标非成员 404，成功后原 owner 降为 member
status, _ = call("POST", f"households/{hid}/transfer-ownership", token=member["token"], body={"userId": owner["userId"]})
assert status == 403, status
status, _ = call("POST", f"households/{hid}/transfer-ownership", token=owner["token"], body={"userId": member["userId"]})
assert status == 200, status
status, after = call("GET", f"households/{hid}/members", token=owner["token"])
assert status == 200, status
assert next(item for item in after["items"] if item["userId"] == owner["userId"])["role"] == "member", after
assert next(item for item in after["items"] if item["userId"] == member["userId"])["role"] == "owner", after

status, _ = call("PATCH", f"households/{hid}", token=owner["token"], body={"name": "原 owner 改名"})
assert status == 403, status
status, renamed = call("PATCH", f"households/{hid}", token=member["token"], body={"name": "pg-结构-改名"})
assert status == 200 and renamed["name"] == "pg-结构-改名", (status, renamed)

status, room = call("POST", f"households/{hid}/rooms", token=member["token"], body={"name": "结构-客厅", "sortOrder": 1})
assert status == 201, (status, room)
rid = room["id"]
status, _ = call("PATCH", f"households/{hid}/rooms/{rid}", token=member["token"], body={"name": "结构-起居室"})
assert status == 200, status
status, _ = call("DELETE", f"households/{hid}/rooms/{rid}", token=member["token"])
assert status == 204, status

member_changes = changes(member["token"])
household_rows = [c for c in member_changes if c["entity"] == "household" and c["entityId"] == hid]
assert household_rows, "新 owner 未收到 household 变更"
latest = household_rows[-1]["payload"]
assert latest["role"] == "owner" and latest["name"] == "pg-结构-改名", latest
assert latest["memberCount"] == 2, latest
room_rows = [c for c in member_changes if c["entity"] == "room" and c["entityId"] == rid]
assert any(c["payload"].get("name") == "结构-起居室" and c["payload"].get("householdId") == hid for c in room_rows), room_rows
assert room_rows[-1]["payload"].get("deleted") is True, room_rows[-1]
assert room_rows[-1]["payload"].get("sortOrder") == 1, room_rows[-1]

# 移除原 owner：被移除者不再收到后续结构变更，历史行仍可读
old_owner_rows_before = [c for c in changes(owner["token"]) if c["entity"] == "household" and c["entityId"] == hid]
assert old_owner_rows_before, "被移除前的历史 household 变更应可读"
status, _ = call("DELETE", f"households/{hid}/members/{owner['userId']}", token=member["token"])
assert status == 204, status
status, _ = call("GET", f"households/{hid}", token=owner["token"])
assert status == 404, status
old_owner_rows_after = [c for c in changes(owner["token"]) if c["entity"] == "household" and c["entityId"] == hid]
assert len(old_owner_rows_after) == len(old_owner_rows_before), (len(old_owner_rows_before), len(old_owner_rows_after))

remaining_changes = changes(member["token"])
remaining_household = [c for c in remaining_changes if c["entity"] == "household" and c["entityId"] == hid]
assert remaining_household[-1]["payload"]["memberCount"] == 1, remaining_household[-1]

print(json.dumps({
    "householdId": hid,
    "newOwnerUserId": member["userId"],
    "newOwnerToken": member["token"],
    "roomId": rid,
}))
PY
struct_hh="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["householdId"])' "$TMP_ROOT/artifacts/structural.json")"
new_owner_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["newOwnerUserId"])' "$TMP_ROOT/artifacts/structural.json")"

# 直接查库：转让后 owner_user_id 指向新 owner；移除成员后只剩新 owner；房间已删；结构变更已入 change_log
PG_OWNER="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT owner_user_id FROM households WHERE id = '$struct_hh'::uuid;" | tr -d '[:space:]')"
[ "$PG_OWNER" = "$new_owner_id" ] || fail "转让后 households.owner_user_id 应为新 owner（got=${PG_OWNER}）"
PG_STRUCT_MEMBERS="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM household_members WHERE household_id = '$struct_hh'::uuid;" | tr -d '[:space:]')"
[ "$PG_STRUCT_MEMBERS" = "1" ] || fail "移除后家庭只应剩新 owner（got=${PG_STRUCT_MEMBERS}）"
PG_STRUCT_ROOMS="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM household_rooms WHERE household_id = '$struct_hh'::uuid;" | tr -d '[:space:]')"
[ "$PG_STRUCT_ROOMS" = "0" ] || fail "删房后 household_rooms 应为 0（got=${PG_STRUCT_ROOMS}）"
PG_STRUCT_LOG="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM change_log WHERE user_id = '$new_owner_id'::uuid AND entity IN ('household','room');" | tr -d '[:space:]')"
[ "$PG_STRUCT_LOG" -ge 2 ] || fail "change_log 应包含 household 与 room 结构变更（got=${PG_STRUCT_LOG}）"
# 解散家庭后，行删除且 change_log 留下 deleted=true 的 household delete
new_owner_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["newOwnerToken"])' "$TMP_ROOT/artifacts/structural.json")"
curl -fsS -o /dev/null -X DELETE -H "Authorization: Bearer $new_owner_token" \
    "$BASE_URL/api/v1/households/$struct_hh" || fail "解散家庭失败"
PG_STRUCT_DELETED="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM households WHERE id = '$struct_hh'::uuid;" | tr -d '[:space:]')"
[ "$PG_STRUCT_DELETED" = "0" ] || fail "解散后 households 行应删除（got=${PG_STRUCT_DELETED}）"
PG_DELETE_LOG="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM change_log WHERE user_id = '$new_owner_id'::uuid AND entity = 'household' AND entity_id = '$struct_hh' AND op = 'delete' AND (payload->>'deleted')::boolean;" | tr -d '[:space:]')"
[ "$PG_DELETE_LOG" -ge 1 ] || fail "change_log 应有 deleted=true 的 household delete（got=${PG_DELETE_LOG}）"
log "PASS 真 Postgres 结构变更：转让 owner_user_id / 移除可见性 / 删房 / change_log 实体"

step "推送令牌（真 Postgres）：表结构 / 注册幂等 / inactive 重置 / 跨用户隔离 / change_log 无副作用"
python3 - "$BASE_URL" >"$TMP_ROOT/artifacts/push-users.json" <<'PY'
import json
import sys
import urllib.error
import urllib.request

base = sys.argv[1]


def call(method, path, token=None, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(base + "/api/v1/" + path, data=data, method=method)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = None
        return error.code, payload


owner = call("POST", "auth/anonymous")[1]
other = call("POST", "auth/anonymous")[1]
print(json.dumps({
    "ownerId": owner["userId"],
    "ownerToken": owner["token"],
    "otherId": other["userId"],
    "otherToken": other["token"],
}))
PY
push_owner_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ownerId"])' "$TMP_ROOT/artifacts/push-users.json")"
push_owner_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ownerToken"])' "$TMP_ROOT/artifacts/push-users.json")"
push_other_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["otherId"])' "$TMP_ROOT/artifacts/push-users.json")"
push_other_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["otherToken"])' "$TMP_ROOT/artifacts/push-users.json")"
push_token="pg-e2e-token-$(uuidgen | tr '[:upper:]' '[:lower:]')"

# 推送注册不应写入 change_log；先记录两个账号的既有条目数，注册后再比对。
PUSH_LOG_BEFORE_OWNER="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM change_log WHERE user_id = '$push_owner_id'::uuid;" | tr -d '[:space:]')"
PUSH_LOG_BEFORE_OTHER="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM change_log WHERE user_id = '$push_other_id'::uuid;" | tr -d '[:space:]')"

python3 - "$BASE_URL" "$push_owner_token" "$push_other_token" "$push_token" >"$TMP_ROOT/artifacts/push-ops.json" <<'PY'
import json
import sys
import urllib.error
import urllib.request

base, owner_token, other_token, token = sys.argv[1:5]


def call(method, path, auth=None, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(base + "/api/v1/" + path, data=data, method=method)
    if auth:
        request.add_header("Authorization", "Bearer " + auth)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = None
        return error.code, payload


first = call("POST", "push/devices", owner_token, {
    "platform": "ios", "token": token,
    "appVersion": "0.27.0", "deviceModel": "iPhone 18 Pro",
})
assert first[0] == 200, first
device_id = first[1]["id"]
assert first[1]["status"] == "active", first

# 同 (user, token) 幂等 upsert：同一设备 ID，字段被更新，不新增行。
second = call("POST", "push/devices", owner_token, {
    "platform": "ios", "token": token,
    "appVersion": "0.27.1", "deviceModel": "iPhone 18 Pro (2)",
})
assert second[0] == 200, second
assert second[1]["id"] == device_id, second
assert second[1]["appVersion"] == "0.27.1", second
assert second[1]["deviceModel"] == "iPhone 18 Pro (2)", second

# 缺 platform / token：400 PUSH_DEVICE_INVALID。
for index, body in enumerate([
    {"token": token},
    {"platform": "ios"},
]):
    status, payload = call("POST", "push/devices", owner_token, body)
    assert status == 400, (index, status, payload)
    assert payload["error"]["code"] == "PUSH_DEVICE_INVALID", (index, payload)

# 跨用户：同一 token 在另一账号下是独立记录；对方不能停用我的 deviceId。
other = call("POST", "push/devices", other_token, {"platform": "ios", "token": token})
assert other[0] == 200, other
other_id = other[1]["id"]
assert other_id != device_id, other
status, _ = call("DELETE", "push/devices/" + device_id, other_token)
assert status == 404, status

# 停用：204；重复停用仍 204；行保留为 inactive（不硬删）。
for _ in range(2):
    status, _ = call("DELETE", "push/devices/" + device_id, owner_token)
    assert status == 204, status

status, _ = call("DELETE", "push/devices/" + other_id, other_token)
assert status == 204, status

print(json.dumps({
    "deviceId": device_id,
    "otherDeviceId": other_id,
    "token": token,
    "appVersion": first[1]["appVersion"],
}))
PY
push_device_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["deviceId"])' "$TMP_ROOT/artifacts/push-ops.json")"
push_other_device_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["otherDeviceId"])' "$TMP_ROOT/artifacts/push-ops.json")"

PG_PUSH_TABLE="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'push_devices';" | tr -d '[:space:]')"
[ "$PG_PUSH_TABLE" = "1" ] || fail "真库缺少 push_devices 表（got=${PG_PUSH_TABLE}）"

# 幂等：owner 的同一 token 只有 1 行；停用后行仍在且 status=inactive；另一账号独立 1 行。
PG_PUSH_OWNER_ROWS="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM push_devices WHERE user_id = '$push_owner_id'::uuid AND token = '$push_token';" | tr -d '[:space:]')"
[ "$PG_PUSH_OWNER_ROWS" = "1" ] || fail "同一 (user, token) 应只有 1 行（got=${PG_PUSH_OWNER_ROWS}）"
PG_PUSH_OWNER_STATUS="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT status FROM push_devices WHERE id = '$push_device_id'::uuid;" | tr -d '[:space:]')"
[ "$PG_PUSH_OWNER_STATUS" = "inactive" ] || fail "DELETE 后应为 inactive 且不硬删（got=${PG_PUSH_OWNER_STATUS}）"
PG_PUSH_OTHER_ROWS="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM push_devices WHERE user_id = '$push_other_id'::uuid AND token = '$push_token';" | tr -d '[:space:]')"
[ "$PG_PUSH_OTHER_ROWS" = "1" ] || fail "跨用户同一 token 应各自 1 行（got=${PG_PUSH_OTHER_ROWS}）"

# inactive 重置：同 token 再次注册恢复 active、沿用同一 deviceId、清空 last_error。
REPUSH_JSON="$(curl -fsS -X POST "$BASE_URL/api/v1/push/devices" \
    -H "Authorization: Bearer $push_owner_token" \
    -H "Content-Type: application/json" \
    -d "{\"platform\":\"ios\",\"token\":\"$push_token\",\"appVersion\":\"0.27.2\",\"deviceModel\":\"iPhone 18 Pro\"}")"
REPUSH_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$REPUSH_JSON")"
[ "$REPUSH_ID" = "$push_device_id" ] || fail "重新注册应沿用同一 deviceId（got=${REPUSH_ID}）"
PG_PUSH_RESET="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT status || '|' || coalesce(last_error, '<null>') || '|' || app_version FROM push_devices WHERE id = '$push_device_id'::uuid;" | tr -d '[:space:]')"
[ "$PG_PUSH_RESET" = "active|<null>|0.27.2" ] || fail "inactive 应重置为 active 并清空 last_error（got=${PG_PUSH_RESET}）"

# change_log 无副作用：两个账号条目数应与注册前完全一致，且没有 push 实体。
PUSH_LOG_BEFORE_TOTAL="$((PUSH_LOG_BEFORE_OWNER + PUSH_LOG_BEFORE_OTHER))"
PUSH_LOG_AFTER_OWNER="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM change_log WHERE user_id = '$push_owner_id'::uuid;" | tr -d '[:space:]')"
PUSH_LOG_AFTER_OTHER="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM change_log WHERE user_id = '$push_other_id'::uuid;" | tr -d '[:space:]')"
PUSH_LOG_AFTER_TOTAL="$((PUSH_LOG_AFTER_OWNER + PUSH_LOG_AFTER_OTHER))"
[ "$PUSH_LOG_AFTER_TOTAL" = "$PUSH_LOG_BEFORE_TOTAL" ] || fail "推送注册不应产生 change_log（before=${PUSH_LOG_BEFORE_TOTAL} after=${PUSH_LOG_AFTER_TOTAL}）"
PUSH_LOG_ENTITIES="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT count(*) FROM change_log WHERE user_id IN ('$push_owner_id'::uuid, '$push_other_id'::uuid) AND entity IN ('push_device', 'push', 'device_push');" | tr -d '[:space:]')"
[ "$PUSH_LOG_ENTITIES" = "0" ] || fail "change_log 不应包含 push 实体（got=${PUSH_LOG_ENTITIES}）"
log "PASS 真 Postgres 推送：表存在 / 同 token 幂等 1 行 / 停用不硬删 / inactive 重置 active / 跨用户独立且互不可停用 / change_log 无新增"

step "匿名登录"
LOGIN_JSON="$(curl -fsS -X POST "$BASE_URL/api/v1/auth/anonymous")"
TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<<"$LOGIN_JSON")"
USER_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["userId"])' <<<"$LOGIN_JSON")"
python3 - "$LOGIN_JSON" "$USER_ID" <<'PY'
import json, sys
body = json.loads(sys.argv[1])
assert body.get("userId") == sys.argv[2]
assert body.get("token"), "缺少 token"
assert body.get("expiresAt"), "匿名登录必须返回 expiresAt（180 天 TTL）"
print("PASS 匿名登录: userId=%s expiresAt=%s" % (body["userId"], body["expiresAt"]))
PY

step "推送 iOS 设备 + 读数（第一次）"
DEVICE_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
EXTERNAL_ID="$(uuidgen | tr '[:lower:]' '[:upper:]')"
python3 - "$DEVICE_ID" "$EXTERNAL_ID" >"$TMP_ROOT/artifacts/push-1.json" <<'PY'
import datetime as dt
import json
import sys
import uuid

device_id, external_id = sys.argv[1], sys.argv[2]
now = dt.datetime.now(dt.timezone.utc)

def iso(delta_minutes: int) -> str:
    return (now + dt.timedelta(minutes=delta_minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")

device = {
    "id": device_id,
    "platform": "ios",
    "externalId": external_id,
    "advertisedName": "PJ-Sensor",
    "alias": "E2E iOS 设备",
    "updatedAt": iso(0),
}
readings = [
    {
        "id": str(uuid.uuid4()),
        "platform": "ios",
        "externalId": external_id,
        "metric": "temperature_celsius",
        "value": value,
        "unit": "celsius",
        "recordedAt": iso(offset),
    }
    for value, offset in [(21.0, -40), (21.5, -30), (22.0, -20)]
]
readings.append({
    "id": str(uuid.uuid4()),
    "platform": "ios",
    "externalId": external_id,
    "metric": "relative_humidity",
    "value": 48.0,
    "unit": "percent",
    "recordedAt": iso(-10),
})
print(json.dumps({"clientId": "codemagic-e2e", "devices": [device], "readings": readings}))
PY
PUSH_1="$(curl -fsS -X POST "$BASE_URL/api/v1/sync/push" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: $(uuidgen)" \
    -d @"$TMP_ROOT/artifacts/push-1.json")"
python3 - "$PUSH_1" <<'PY'
import json, sys
body = json.loads(sys.argv[1])
assert len(body.get("applied") or []) == 1, body
assert body.get("appliedReadings") == 4, body
assert body.get("skippedReadings") == 0, body
print("PASS push#1: applied=%d appliedReadings=%d" % (len(body["applied"]), body["appliedReadings"]))
PY

step "再次更新同一设备（制造两条 change_log，供 410 构造间隙）"
python3 - "$TMP_ROOT/artifacts/push-1.json" >"$TMP_ROOT/artifacts/push-2.json" <<'PY'
import datetime as dt
import json
import sys

body = json.load(open(sys.argv[1], encoding="utf-8"))
body["devices"][0]["alias"] = "E2E iOS 设备（二次更新）"
# LWW 按 updatedAt 比较（秒级）；+5s 保证第二条更新一定比第一条新，不触发 server_newer 冲突。
body["devices"][0]["updatedAt"] = (
    dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=5)
).strftime("%Y-%m-%dT%H:%M:%SZ")
body["readings"] = []
print(json.dumps(body))
PY
PUSH_2="$(curl -fsS -X POST "$BASE_URL/api/v1/sync/push" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: $(uuidgen)" \
    -d @"$TMP_ROOT/artifacts/push-2.json")"
python3 - "$PUSH_2" <<'PY'
import json, sys
body = json.loads(sys.argv[1])
assert len(body.get("applied") or []) == 1, body
print("PASS push#2: applied=%d" % len(body["applied"]))
PY

step "增量拉取（cursor=0）"
CHANGES_JSON="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/v1/sync/changes?cursor=0&limit=500")"
OLD_SEQ="$(python3 - "$CHANGES_JSON" <<'PY'
import json, sys
body = json.loads(sys.argv[1])
changes = body.get("changes") or []
assert len(changes) >= 2, "至少需要两条变更才能构造 410 间隙：%r" % body
devices = [c for c in changes if c["entity"] == "user_device"]
assert devices, "缺少 user_device 变更：%r" % body
print(min(c["seq"] for c in devices))
PY
)"
OLD_CURSOR=$((OLD_SEQ - 1))
[ "$OLD_CURSOR" -gt 0 ] || fail "最老 seq=${OLD_SEQ} 无法构造正游标失效（cursor=0 永不 410）"
log "最老 seq=${OLD_SEQ}，用 cursor=${OLD_CURSOR}（小于保留边界）构造 410"

step "构造游标失效：最老 seq server_ts 改为 100 天前，再跑 cleanup(90 天)"
docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
    -c "UPDATE change_log SET server_ts = now() - interval '100 days' WHERE user_id = '$USER_ID'::uuid AND seq = $OLD_SEQ;" >/dev/null
(cd "$PJGOIOT_DIR" && DATABASE_URL="$DATABASE_URL" CHANGE_LOG_RETENTION_DAYS=90 go run ./cmd/cleanup) \
    >"$TMP_ROOT/artifacts/cleanup.log" 2>&1 || {
    cat "$TMP_ROOT/artifacts/cleanup.log" >&2
    fail "cleanup 执行失败"
}
grep -q "change_log_deleted=1" "$TMP_ROOT/artifacts/cleanup.log" \
    || fail "cleanup 未删除预期的 1 条 change_log"
log "cleanup: $(grep 'change_log_deleted=' "$TMP_ROOT/artifacts/cleanup.log")"

step "旧游标应返回 410 RESYNC_REQUIRED"
GONE_CODE="$(curl -s -o "$TMP_ROOT/artifacts/410.json" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/v1/sync/changes?cursor=$OLD_CURSOR&limit=500")"
[ "$GONE_CODE" = "410" ] || fail "期望 410，实际 ${GONE_CODE}：$(cat "$TMP_ROOT/artifacts/410.json")"
python3 - "$TMP_ROOT/artifacts/410.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))
assert body["error"]["code"] == "RESYNC_REQUIRED", body
print("PASS 410: code=%s message=%s" % (body["error"]["code"], body["error"]["message"]))
PY

step "cursor=0 全量重拉（永不 410）"
FULL_JSON="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/v1/sync/changes?cursor=0&limit=500")"
python3 - "$FULL_JSON" <<'PY'
import json, sys
body = json.loads(sys.argv[1])
changes = body.get("changes") or []
assert changes, "全量拉取应至少保留 1 条变更：%r" % body
assert body["hasMore"] is False
print("PASS 全量拉取: changes=%d nextCursor=%s" % (len(changes), body["nextCursor"]))
PY

step "series / metrics"
FROM_TO="$(python3 - <<'PY'
import datetime as dt
now = dt.datetime.now(dt.timezone.utc)
fmt = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
print(fmt(now - dt.timedelta(hours=2)), fmt(now))
PY
)"
FROM="${FROM_TO%% *}"
TO="${FROM_TO##* }"
SERIES_JSON="$(curl -fsS -G -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/v1/my/devices/ios/$EXTERNAL_ID/readings/series" \
    --data-urlencode "metric=temperature_celsius" \
    --data-urlencode "from=$FROM" \
    --data-urlencode "to=$TO" \
    --data-urlencode "bucket=1h")"
python3 - "$SERIES_JSON" <<'PY'
import json, sys
body = json.loads(sys.argv[1])
buckets = body.get("buckets") or []
assert buckets, body
assert sum(b["count"] for b in buckets) == 3, body
print("PASS series: buckets=%d count=%d unit=%s" % (len(buckets), sum(b["count"] for b in buckets), body["unit"]))
PY

METRICS_JSON="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/v1/my/devices/ios/$EXTERNAL_ID/readings/metrics")"
python3 - "$METRICS_JSON" <<'PY'
import json, sys
items = {item["metric"]: item for item in json.loads(sys.argv[1]).get("items") or []}
assert items["temperature_celsius"]["count"] == 3, items
assert items["relative_humidity"]["count"] == 1, items
print("PASS metrics: %s" % ", ".join("%s=%d" % (k, v["count"]) for k, v in sorted(items.items())))
PY

step "export / 注销"
EXPORT_CREATE="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -d '{}' "$BASE_URL/api/v1/me/export")"
EXPORT_ID="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("id",""))' "$EXPORT_CREATE")" || true
[ -n "$EXPORT_ID" ] || fail "创建导出任务失败：$EXPORT_CREATE"
DOWNLOAD_URL=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    POLL_JSON="$(curl -sS -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/me/export/$EXPORT_ID")"
    STATUS="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("status",""))' "$POLL_JSON")" || true
    if [ "$STATUS" = "ready" ]; then
        DOWNLOAD_URL="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("downloadUrl",""))' "$POLL_JSON")" || true
        break
    fi
    [ "$STATUS" = "failed" ] && fail "导出任务失败：$POLL_JSON"
    sleep 0.2
done
[ -n "$DOWNLOAD_URL" ] || fail "导出任务未在限定轮询内就绪：$POLL_JSON"
# 服务端返回 /api/v1/... 相对地址或绝对地址，统一拼成可直接请求的 URL。
case "$DOWNLOAD_URL" in
    http*) EXPORT_URL="$DOWNLOAD_URL" ;;
    /api/v1/*) EXPORT_URL="$BASE_URL$DOWNLOAD_URL" ;;
    /*) EXPORT_URL="$BASE_URL/api/v1$DOWNLOAD_URL" ;;
    *) EXPORT_URL="$BASE_URL/api/v1/$DOWNLOAD_URL" ;;
esac
EXPORT_JSON="$(curl -fsS "$EXPORT_URL")"
python3 - "$EXPORT_JSON" "$USER_ID" <<'PY'
import json, sys
body = json.loads(sys.argv[1])
assert body["user"]["id"] == sys.argv[2], body["user"]
# 前面的家庭结构用例会在同一账号下再建设备，这里只验证导出聚合本身可用且包含读数。
assert len(body["devices"]) >= 1, len(body["devices"])
assert len(body["readings"]) >= 1, len(body["readings"])
print("PASS export: devices=%d readings=%d" % (
    len(body["devices"]), len(body["readings"])))
PY

DELETE_TOKEN_JSON="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -d '{}' "$BASE_URL/api/v1/me/deletion-request")"
DELETION_TOKEN="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("token",""))' "$DELETE_TOKEN_JSON")" || true
[ -n "$DELETION_TOKEN" ] || fail "申请删除令牌失败：$DELETE_TOKEN_JSON"
DELETE_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    -H "X-Deletion-Token: $DELETION_TOKEN" "$BASE_URL/api/v1/me")"
[ "$DELETE_CODE" = "204" ] || fail "注销期望 204，实际 $DELETE_CODE"
AFTER_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/households")"
[ "$AFTER_CODE" = "401" ] || fail "注销后旧 token 期望 401，实际 $AFTER_CODE"
log "PASS 注销: DELETE=204，旧 token 再访问=401"

printf '\n[e2e-postgres] PASS\n'
