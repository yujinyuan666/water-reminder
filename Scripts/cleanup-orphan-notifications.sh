#!/bin/bash
#
# 清理系统通知库里属于本 App 的**全部**通知记录 —— 包括旧版本遗留、新版本清不掉的那些。
#
# 什么时候需要跑：
#   通知栏每天还在弹「喝水时间到 💧」，但当前版本根本不该发通知
#   （规则全是「全屏提示」）。这说明有历史构建的身份留下的请求还在系统里。
#
# 为什么 App 自己清不掉：
#   见 ./Scripts/check-notification-identity.sh 的注释。简言之 —— 通知按代码签名身份隔离，
#   ad-hoc 签名每个构建都是新身份，removeAllPendingNotificationRequests() 只能清自己的。
#
# 这个脚本必须由**你自己在终端里跑**，不能由 App 或 CI 代劳：
#   需要「完整磁盘访问」才能写通知库，而 App 没有、也不该有那个权限。
#
# 用法：
#     ./Scripts/cleanup-orphan-notifications.sh --dry-run   # 先看会删多少
#     ./Scripts/cleanup-orphan-notifications.sh             # 真删（会先自动备份）
#
set -euo pipefail

DB="${HOME}/Library/Group Containers/group.com.apple.usernoted/db2/db"
BUNDLE_ID="com.waterreminder.app"
PLIST="${HOME}/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
DRY_RUN=0

for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${arg}" >&2; exit 2 ;;
  esac
done

if [[ ! -e "${DB}" ]]; then
  echo "❌ 找不到通知库：${DB}" >&2
  echo "   可能需要给终端开启「完整磁盘访问」：系统设置 → 隐私与安全性 → 完整磁盘访问。" >&2
  exit 1
fi

# ---------- 1. 先看清楚要删什么 ----------
APP_ID="$(sqlite3 "file:${DB}?mode=ro" \
  "SELECT app_id FROM app WHERE lower(identifier) = lower('${BUNDLE_ID}');" 2>/dev/null || echo "")"

if [[ -z "${APP_ID}" ]]; then
  echo "通知库里没有 ${BUNDLE_ID} 的条目，没什么可清的。"
  exit 0
fi

echo "════════════════════════════════════════════════════════════"
echo " 清理 ${BUNDLE_ID}（app_id=${APP_ID}）的通知记录"
echo "════════════════════════════════════════════════════════════"
echo

# 待发 / 已送达，以及按来源身份分组
sqlite3 "file:${DB}?mode=ro" "
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
python3 - "${DB}" "${APP_ID}" <<'PY' 2>/dev/null || echo "    （解析跳过）"
import plistlib, sqlite3, sys, datetime
db, app_id = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
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
  echo "--dry-run：什么都没改。去掉 --dry-run 就会执行清理。"
  exit 0
fi

# ---------- 2. 备份 ----------
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${HOME}/Desktop/waterreminder-notif-backup-${STAMP}.db"
cp "${DB}" "${BACKUP}"
echo "已备份：${BACKUP}"
echo

# ---------- 3. 停掉 App 与 usernoted，避免边写边被覆盖 ----------
echo "==> 退出 App 与通知守护进程"
# osascript 可能因为 App 不在运行而失败，用 || true 兜住
osascript -e 'tell application "WaterReminder" to quit' >/dev/null 2>&1 || true
pkill -x WaterReminder >/dev/null 2>&1 || true
sleep 1

# 注意：较新的 macOS 上 usernoted 是 bootstrap-only 的，kickstart 会报
# "Domain does not support specified action"，忽略即可；bootout/bootstrap 才是有效路径
launchctl bootout "gui/$(id -u)/com.apple.usernoted" >/dev/null 2>&1 \
  || launchctl stop com.apple.usernoted >/dev/null 2>&1 || true
sleep 1

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
sqlite3 "file:${DB}?mode=ro" "
  SELECT '  record 剩余    : ' || count(*) FROM record    WHERE app_id=${APP_ID};
  SELECT '  requests 剩余  : ' || count(*) FROM requests  WHERE app_id=${APP_ID};
  SELECT '  delivered 剩余 : ' || count(*) FROM delivered WHERE app_id=${APP_ID};
  SELECT '  app 行是否保留 : ' || count(*) FROM app       WHERE app_id=${APP_ID};
  SELECT '  完整性检查     : ' || (SELECT * FROM pragma_integrity_check);
" 2>/dev/null | sed 's/^/  /'

echo
echo "  其他 App 的记录数（确认没有误伤）："
sqlite3 "file:${DB}?mode=ro" "
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
echo "提醒：如果 App 是 ad-hoc 签名的，下次发版还会重演。根治办法是"
echo "      ./Scripts/make-signing-cert.sh && ./Scripts/sign-app.sh <App>"
