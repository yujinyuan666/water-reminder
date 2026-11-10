#!/bin/bash
#
# 检查系统通知库里属于本 App 的通知记录 —— 包括旧版本遗留、新版本清不掉的那些。
#
# 什么时候需要跑：
#   通知栏每天还在弹「喝水时间到 💧」，但当前版本根本不该发通知
#   （规则全是「全屏提示」）。这说明有历史构建的身份留下的请求还在系统里。
#
# 为什么 App 自己清不掉：
#   见 ./Scripts/check-notification-identity.sh 的注释。简言之 —— 通知按代码签名身份隔离，
#   ad-hoc 签名每个构建都是新身份，removeAllPendingNotificationRequests() 只能清自己的。
#
# ⚠️⚠️ 重要：这个脚本**默认只诊断，不修改**。原因是真的改不动了（2026-11-10 实测）：
#
#   macOS 26 / SIP 下，usernoted 停不掉 ——
#     launchctl bootout   gui/$UID/com.apple.usernoted → 150: Operation not permitted while SIP is engaged
#     launchctl kickstart gui/$UID/com.apple.usernoted → 150: 同上
#     launchctl kill SIGTERM gui/$UID/com.apple.usernoted → Not privileged to signal service.
#   只有 `kill -TERM <usernoted pid>` 能真的停掉它，但那条路会触发
#   「库被判损坏 → 旧库改名成 db.corrupt → 重建一个空库」，
#   等于把**所有 App** 的通知历史一次性清空（实测：160 个 app 行 → 0 行）。
#   而且重启后 behavior 不稳定，重建出来的库可能长时间不落盘。
#   ⇒ 所以「保证生效」和「不伤及无辜」这两件事在现阶段无法兼得，
#     脚本不再默默做无效的 SQL 写入（那正是上次清理看似成功、实际被回写覆盖的原因）。
#
# 真正有效且安全的清理方式（用户侧一条命令都不用跑）：
#   系统设置 → 通知 → 找到「喝水提醒」 → 关掉「允许通知」
#   这一步按 bundle id 生效，与代码签名身份无关，因此对**所有历史身份**的残留都有效。
#
# 用法：
#     ./Scripts/cleanup-orphan-notifications.sh --dry-run   # 只看现状（默认行为）
#     ./Scripts/cleanup-orphan-notifications.sh --force-db  # 仍尝试直接改库（高风险，见上）
#
set -euo pipefail

DB="${HOME}/Library/Group Containers/group.com.apple.usernoted/db2/db"
BUNDLE_ID="com.waterreminder.app"
PLIST="${HOME}/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
DRY_RUN=1

for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --force-db) DRY_RUN=0 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${arg}" >&2; exit 2 ;;
  esac
done

# 这个库是 WAL 模式。用 "file:...?mode=ro" 打开时，如果目录里没有现成的
# -shm/-wal（例如刚从 db.corrupt 拷出来的干净副本），SQLite 会直接报
# "unable to open database file (14)" —— 看起来像「库里没有数据」，
# 其实是打开方式的问题。所以统一走一个带回退的只读查询函数。
q_ro() {
  local db="$1" sql="$2"
  if [[ -e "${db}-shm" || -e "${db}-wal" ]]; then
    sqlite3 "file:${db}?mode=ro" "${sql}" 2>/dev/null && return 0
  fi
  sqlite3 "file:${db}?immutable=1" "${sql}" 2>/dev/null && return 0
  sqlite3 "${db}" "${sql}" 2>/dev/null
}

if [[ ! -e "${DB}" ]]; then
  echo "❌ 找不到通知库：${DB}" >&2
  echo "   可能需要给终端开启「完整磁盘访问」：系统设置 → 隐私与安全性 → 完整磁盘访问。" >&2
  exit 1
fi

# ---------- 1. 先看清楚要删什么 ----------
# 说明：usernoted 有时会把「读不动的旧库」改名成 db.corrupt 再重建一个空库
# （2026-11-10 实测发生过）。那种情况下活动库是空的，历史数据全在 db.corrupt 里，
# 所以没有 app 行时回退去读 db.corrupt，否则会误报「没什么可清的」。
CORRUPT_DB="${DB}.corrupt"
SCAN_DB="${DB}"
APP_ID="$(q_ro "${DB}" \
  "SELECT app_id FROM app WHERE lower(identifier) = lower('${BUNDLE_ID}');" || echo "")"

if [[ -z "${APP_ID}" && -e "${CORRUPT_DB}" ]]; then
  CORRUPT_ID="$(q_ro "${CORRUPT_DB}" \
    "SELECT app_id FROM app WHERE lower(identifier) = lower('${BUNDLE_ID}');" || echo "")"
  if [[ -n "${CORRUPT_ID}" ]]; then
    echo "⚠️ 活动通知库是空的，但发现被 usernoted 归档的旧库：${CORRUPT_DB}"
    echo "   下面显示的是那个旧库里的记录（仅供你了解历史残留，已不影响当前系统）。"
    echo
    SCAN_DB="${CORRUPT_DB}"
    APP_ID="${CORRUPT_ID}"
  fi
fi

if [[ -z "${APP_ID}" ]]; then
  echo "通知库里没有 ${BUNDLE_ID} 的条目，没什么可清的。"
  exit 0
fi

echo "════════════════════════════════════════════════════════════"
echo " 清理 ${BUNDLE_ID}（app_id=${APP_ID}）的通知记录"
echo "════════════════════════════════════════════════════════════"
echo

# 待发 / 已送达，以及按来源身份分组
q_ro "${SCAN_DB}" "
  SELECT '  record 总数  : ' || count(*) FROM record WHERE app_id=${APP_ID};
  SELECT '  其中待发     : ' || count(*) FROM record WHERE app_id=${APP_ID} AND delivered_date IS NULL;
  SELECT '  其中已送达   : ' || count(*) FROM record WHERE app_id=${APP_ID} AND delivered_date IS NOT NULL;
  SELECT '  requests 行  : ' || count(*) FROM requests  WHERE app_id=${APP_ID};
  SELECT '  delivered 行 : ' || count(*) FROM delivered WHERE app_id=${APP_ID};
  SELECT '  displayed 行 : ' || count(*) FROM displayed WHERE app_id=${APP_ID};
  SELECT '  snoozed 行   : ' || count(*) FROM snoozed   WHERE app_id=${APP_ID};
" 2>/dev/null | sed 's/^/  /'

echo
echo "  按来源身份分组（srce 不同 = 不同构建留下的通知）："
python3 - "${SCAN_DB}" "${APP_ID}" <<'PY' 2>/dev/null || echo "    （解析跳过）"
import plistlib, sqlite3, sys, datetime
db, app_id = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(f"file:{db}?immutable=1", uri=True)
stat = {}
for data, deliv in con.execute(
        "SELECT data, delivered_date FROM record WHERE app_id=?", (app_id,)):
    try:
        pl = plistlib.loads(data)
        srce = pl.get("srce")
        key = srce.hex()[:16] if isinstance(srce, (bytes, bytearray)) else "?"
        iden = pl.get("req", {}).get("iden", "?")
    except Exception:
        key, iden = "?", "?"
    g = stat.setdefault(key, {"pending": 0, "delivered": 0, "sample": iden})
    g["delivered" if deliv is not None else "pending"] += 1
if not stat:
    print("    （无记录）")
for key, g in sorted(stat.items(), key=lambda kv: -(kv[1]["pending"] + kv[1]["delivered"])):
    print(f"    srce={key}  待发={g['pending']}  已送达={g['delivered']}  例：{g['sample']}")
PY

echo
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "════════════════════════════════════════════════════════════"
  echo " 结论"
  echo "════════════════════════════════════════════════════════════"
  cat <<'TXT'
  以上记录全部属于历史构建留下的身份（srce 不同 = 不同构建）。

  ⚠️ 本脚本默认不改库。真实原因（2026-11-10 实测）：
     在 SIP 保护下 usernoted 停不掉（bootout / kickstart 均被 150 拒绝，
     launchctl kill 报 Not privileged），唯一能停它的是 kill -TERM，
     而那会让 usernoted 把库判为损坏、改名成 db.corrupt 后重建空库，
     结果是所有 App 的通知历史一次性清空。

  真正有效且安全的两条路：
     1) 系统设置 → 通知 → 喝水提醒 → 关掉「允许通知」
        （按 bundle id 生效，对所有历史身份的残留都有效）
     2) 让未来的版本不再产生新残留：签名走 ./Scripts/sign-app.sh，
        它会嵌入身份型 DR，使各版本共享同一个通知身份。

  如果你确实要尝试直接改库（高风险），加 --force-db。它会在动手前
  明确告诉你 usernoted 是否已停、并把备份路径打印出来。
TXT
  echo
  exit 0
fi

# ---------- 2. 备份 ----------
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${HOME}/Desktop/waterreminder-notif-backup-${STAMP}.db"
cp "${DB}" "${BACKUP}"
echo "已备份：${BACKUP}"
echo

# ---------- 3. 退出 App ----------
echo "==> 退出 App"
osascript -e 'tell application "WaterReminder" to quit' >/dev/null 2>&1 || true
pkill -x WaterReminder >/dev/null 2>&1 || true
sleep 1

# ---------- 3b. 停掉 usernoted —— 先如实检查，不假装成功 ----------
# 历史上这里写的是
#   launchctl bootout ... || launchctl stop ...
# 两个分支在 SIP 下都会失败，失败又被 >/dev/null 2>&1 || true 吞掉，
# 于是 SQL 写在守护进程活着的时候，随后被它的内存态回写覆盖 —— 清理「看似成功、实际无效」。
# 现在改成：必须真的确认 pid 变了才继续，否则明确拒绝。
USERNOTED_PID="$(launchctl print "gui/$(id -u)/com.apple.usernoted" 2>/dev/null \
  | awk '/^[ \t]*pid = /{print $3; exit}' || true)"
echo "==> 通知守护进程 usernoted 当前 pid：${USERNOTED_PID:-未知}"

if [[ -n "${USERNOTED_PID}" ]]; then
  echo "    尝试 bootout（SIP 下预期失败，仅作为记录）…"
  launchctl bootout "gui/$(id -u)/com.apple.usernoted" 2>&1 | sed 's/^/      /' || true
  sleep 1
  NEW_PID="$(launchctl print "gui/$(id -u)/com.apple.usernoted" 2>/dev/null \
    | awk '/^[ \t]*pid = /{print $3; exit}' || true)"
  if [[ "${NEW_PID}" == "${USERNOTED_PID}" ]]; then
    echo
    echo "⚠️  usernoted 仍在运行（pid=${USERNOTED_PID}）。SIP 不允许我们停掉它。"
    echo "    这意味着接下来的 SQL 极可能被它的内存态回写覆盖 —— 上次就是这样失效的。"
    if [[ "${DRY_RUN}" -ne 0 ]]; then
      echo "    已装好备份：${BACKUP}"
      exit 1
    fi
    echo "    你显式加了 --force-db，所以继续执行，但请把上面这句当作「大概率白做」。"
    echo
  else
    echo "    usernoted 已停止（新 pid=${NEW_PID:-无}）"
  fi
fi

# ---------- 4. 执行清理 ----------
# 保守做法：只删记录表，保留 app 行。
# 保留 app 行的原因：app 行承载「用户已授权通知」这件事，
# 删掉它（虽然有 trigger 会级联清 record）会要求用户重新授权一次。
echo "==> 删除记录"
sqlite3 "${DB}" <<SQL
BEGIN IMMEDIATE;
DELETE FROM record    WHERE app_id = ${APP_ID};
DELETE FROM requests  WHERE app_id = ${APP_ID};
DELETE FROM delivered WHERE app_id = ${APP_ID};
DELETE FROM displayed WHERE app_id = ${APP_ID};
DELETE FROM snoozed   WHERE app_id = ${APP_ID};
COMMIT;
SQL

# ---------- 5. 重启 usernoted ----------
echo "==> 重启通知守护进程"
launchctl bootstrap "gui/$(id -u)" /System/Library/LaunchAgents/com.apple.usernoted.plist >/dev/null 2>&1 \
  || launchctl start com.apple.usernoted >/dev/null 2>&1 || true
sleep 1

# ---------- 6. 复核 ----------
echo
echo "════════════════════════════════════════════════════════════"
echo " 清理后复核"
echo "════════════════════════════════════════════════════════════"
q_ro "${DB}" "
  SELECT '  record 剩余    : ' || count(*) FROM record    WHERE app_id=${APP_ID};
  SELECT '  requests 剩余  : ' || count(*) FROM requests  WHERE app_id=${APP_ID};
  SELECT '  delivered 剩余 : ' || count(*) FROM delivered WHERE app_id=${APP_ID};
  SELECT '  app 行是否保留 : ' || count(*) FROM app       WHERE app_id=${APP_ID};
  SELECT '  完整性检查     : ' || (SELECT * FROM pragma_integrity_check);
" 2>/dev/null | sed 's/^/  /'

echo
echo "  其他 App 的记录数（确认没有误伤）："
q_ro "${DB}" "
  SELECT '    ' || a.identifier || ' : ' || count(r.rec_id)
  FROM app a LEFT JOIN record r ON r.app_id = a.app_id
  WHERE a.app_id <> ${APP_ID}
  GROUP BY a.app_id HAVING count(r.rec_id) > 0
  ORDER BY count(r.rec_id) DESC LIMIT 8;
" 2>/dev/null || true

echo
echo "守护进程状态："
launchctl print "gui/$(id -u)/com.apple.usernoted" 2>/dev/null | grep -E '^\s+(state|active count)' | sed 's/^/    /' || true

echo
echo "✅ 完成。备份在 ${BACKUP}"
echo
echo "⚠️ 复查提示：usernoted 有 KeepAlive，被停后会立刻重起。重起之后它可能"
echo "   把本次改动视为不需要、并用内存态覆盖磁盘（上次就是这样失效的）。"
echo "   请在 1 分钟后重跑本脚本的 --dry-run，确认记录数确实归零；若又长回来，"
echo "   说明这条路在当前系统上不可用，请改用「系统设置 → 通知 → 喝水提醒 → 关掉」。"
