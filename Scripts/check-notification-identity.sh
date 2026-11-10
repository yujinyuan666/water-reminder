#!/bin/bash
#
# 检查「通知身份」是否稳定，以及系统里还挂着多少属于本 App 的通知。
#
# 背景（务必读一遍，否则会误判）：
#
#   macOS 的 UNUserNotificationCenter 按**代码签名身份**隔离待发/已送达通知。
#   ad-hoc 签名（`codesign --sign -`）的 designated requirement 就是 cdhash 本身，
#   而 cdhash 每构建一次都不一样 ⇒ 每一次发版都是一个全新的「通知身份」。
#
#   后果：新版本调用 removeAllPendingNotificationRequests() 时，只能清掉
#   「自己这个身份」排下的通知；旧版本排下的通知它既看不见、也清不掉，
#   会继续按原计划每天弹，直到有人手工清库。
#
#   修法不是「必须上证书」：只要签名时显式嵌入一条身份型 DR，例如
#     codesign --force --sign - -r='designated => identifier "com.waterreminder.app"' <App>
#   DR 就只绑 bundle id、不绑 cdhash，跨构建稳定 ⇒ 新版能看见并清理旧版的通知。
#   ./Scripts/sign-app.sh 默认就是这么签的（无需证书、无需钥匙串、无需 Secret）。
#
# 用法：
#     ./Scripts/check-notification-identity.sh                        # 检查已装 App
#     ./Scripts/check-notification-identity.sh path/to/App.app       # 检查指定产物
#
# 退出码：0 = DR 是身份型；1 = DR 是 cdhash 型（有跨版本残留风险）；2 = 用法错误
#
set -uo pipefail

DB="${HOME}/Library/Group Containers/group.com.apple.usernoted/db2/db"
CORRUPT_DB="${DB}.corrupt"

# 这个库是 WAL 模式：目录里没有现成的 -shm/-wal 时，
# "file:...?mode=ro" 会报 "unable to open database file (14)"，
# 看起来像「库里没数据」，其实是打开方式的问题。带 immutable 回退。
q_ro() {
  local db="$1" sql="$2"
  if [[ -e "${db}-shm" || -e "${db}-wal" ]]; then
    sqlite3 "file:${db}?mode=ro" "${sql}" 2>/dev/null && return 0
  fi
  sqlite3 "file:${db}?immutable=1" "${sql}" 2>/dev/null && return 0
  sqlite3 "${db}" "${sql}" 2>/dev/null
}
BUNDLE_ID="com.waterreminder.app"
APP="${1:-/Applications/WaterReminder.app}"

echo "════════════════════════════════════════════════════════════"
echo " 通知身份自检"
echo "════════════════════════════════════════════════════════════"

# ---------- 1. 签名身份 ----------
if [[ ! -e "${APP}" ]]; then
  echo "❌ 找不到 App：${APP}" >&2
  exit 2
fi

echo
echo "【1】签名身份"
echo "    路径：${APP}"

IDENTIFIER="$(codesign -dvvv "${APP}" 2>&1 | grep -m1 '^Identifier=' | cut -d= -f2 || true)"
# 未签名的产物，codesign 会把 Identifier 报成可执行文件名（如 "WaterReminder"），
# 那不代表真实 bundle id —— 以 Info.plist 为准
PLIST_ID="$(plutil -extract CFBundleIdentifier raw "${APP}/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "${PLIST_ID}" ]]; then
  IDENTIFIER="${PLIST_ID}"
fi
CDHASH="$(codesign -dvvv "${APP}" 2>&1 | grep -m1 '^CDHash=' | cut -d= -f2 || true)"
AUTHORITY="$(codesign -dvvv "${APP}" 2>&1 | grep -m1 '^Authority=' | cut -d= -f2 || true)"
# 注意：App 没有嵌入 DR 时，codesign 会打印「计算出来的」DR，行首带 "# " 前缀
# （`# designated => cdhash H"..."`），所以不能 grep '^designated'
DR="$(codesign -d -r- "${APP}" 2>&1 | grep 'designated' | sed 's/^# *//' || true)"

echo "    Bundle ID ：${IDENTIFIER:-未知}"
echo "    CDHash    ：${CDHASH:-未知}"
echo "    签发者    ：${AUTHORITY:-（无 —— ad-hoc 签名）}"
echo "    指定要求  ：${DR:-未知}"

# 判据是 DR 的类型，不是「有没有证书」：
#   cdhash 型 ⇒ 每构建换通知身份（坏）
#   身份型   ⇒ 跨构建稳定（好，ad-hoc 或证书都行）
IS_CDHASH=0
if echo "${DR}" | grep -q 'cdhash H"'; then
  IS_CDHASH=1
fi

echo
if [[ "${IS_CDHASH}" -eq 1 ]]; then
  echo "    ⚠️  DR 是 **cdhash 型**：每次构建都是新的通知身份。"
  echo "        旧版本排下的通知，新版本清不掉，会一直弹。"
  echo "        修法：用 ./Scripts/sign-app.sh 重新签名（它会嵌入身份型 DR，不需要证书）。"
else
  echo "    ✅ DR 是 **身份型**：跨构建稳定，新版能清理旧版的通知。"
fi

# ---------- 2. 系统通知库里的存量 ----------
echo
echo "【2】系统通知库里属于本 App 的记录"

SCAN_DB="${DB}"
SCAN_NOTE=""

if [[ ! -e "${DB}" ]]; then
  echo "    ⚠️  找不到通知库：${DB}"
  echo "        （未开启「完整磁盘访问」时读不到，跳过这一节）"
else
  # 有些 macOS 版本库里 identifier 是小写，用 lower() 兜住
  QUERY_APP="SELECT app_id FROM app WHERE lower(identifier) = lower('${BUNDLE_ID}');"
  APP_ID="$(q_ro "${DB}" "${QUERY_APP}" || echo "")"

  # usernoted 有时会把「读不动的旧库」改名成 db.corrupt 再重建空库，
  # 那种情况下活动库是空的，历史残留全在 db.corrupt 里 —— 必须一并报告，
  # 否则会误报「本 App 从未注册过通知」。
  if [[ -z "${APP_ID}" && -e "${CORRUPT_DB}" ]]; then
    CORRUPT_ID="$(q_ro "${CORRUPT_DB}" "${QUERY_APP}" || echo "")"
    if [[ -n "${CORRUPT_ID}" ]]; then
      SCAN_DB="${CORRUPT_DB}"
      APP_ID="${CORRUPT_ID}"
      SCAN_NOTE="    ⚠️  活动库是空的，下面读的是被 usernoted 归档的旧库：${CORRUPT_DB}"
    fi
  fi

  if [[ -z "${APP_ID}" ]]; then
    echo "    通知库里没有 ${BUNDLE_ID} 的条目（本 App 从未注册过通知）。"
  else
    [[ -n "${SCAN_NOTE}" ]] && echo "${SCAN_NOTE}"
    echo "    app_id = ${APP_ID}"

    # 待发（未送达）/ 已送达
    PENDING="$(q_ro "${SCAN_DB}" \
      "SELECT count(*) FROM record WHERE app_id=${APP_ID} AND delivered_date IS NULL;" || echo "?")"
    DELIVERED="$(q_ro "${SCAN_DB}" \
      "SELECT count(*) FROM record WHERE app_id=${APP_ID} AND delivered_date IS NOT NULL;" || echo "?")"

    echo "    待发记录：${PENDING}"
    echo "    已送达  ：${DELIVERED}"

    # record.data 是 bplist，identifier 得用 python 解
    echo
    echo "    最近的记录（identifier / 送达时间 / 标题）："
    python3 - "${SCAN_DB}" "${APP_ID}" <<'PY' 2>/dev/null || echo "    （解析失败，可跳过）"
import plistlib, sqlite3, sys, datetime
db, app_id = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(f"file:{db}?immutable=1", uri=True)
rows = con.execute(
    "SELECT rec_id, data, delivered_date FROM record WHERE app_id=? "
    "ORDER BY rec_id DESC LIMIT 8", (app_id,)).fetchall()

def cocoa(ts):
    if ts is None:
        return "未送达"
    return (datetime.datetime(2001, 1, 1) + datetime.timedelta(seconds=ts)
            + datetime.timedelta(hours=8)).strftime("%m-%d %H:%M")

def read(d):
    try:
        pl = plistlib.loads(d)
        req = pl.get("req", {}) if isinstance(pl, dict) else {}
        return req.get("iden", "?"), req.get("titl", "?")
    except Exception:
        return "?", "?"

for rec_id, data, deliv in rows:
    iden, titl = read(data)
    print(f"      {iden}  送达={cocoa(deliv)}  标题={titl}")

# 按来源身份（srce）分组 —— 不同 srce 就是不同构建
print()
print("    按来源身份分组（srce 不同 = 不同构建留下的）：")
try:
    groups = con.execute(
        "SELECT data, delivered_date FROM record WHERE app_id=?", (app_id,)).fetchall()
    stat = {}
    for data, deliv in groups:
        try:
            pl = plistlib.loads(data)
            srce = pl.get("srce")
            key = srce.hex()[:16] if isinstance(srce, (bytes, bytearray)) else "?"
        except Exception:
            key = "?"
        g = stat.setdefault(key, [0, 0])
        if deliv is None:
            g[0] += 1
        else:
            g[1] += 1
    if not stat:
        print("      （无记录）")
    for key, (pend, deliv) in sorted(stat.items(), key=lambda kv: -(kv[1][0] + kv[1][1])):
        print(f"      srce={key}  待发={pend}  已送达={deliv}")
    if len(stat) > 1:
        print()
        print(f"      ⚠️  共有 {len(stat)} 个来源身份 —— 说明历史上跑过 "
              f"{len(stat)} 个不同构建，它们的通知互不可见。")
except Exception as e:
    print(f"      （分组统计失败：{e}）")
PY
  fi
fi

# ---------- 3. 结论 ----------
echo
echo "════════════════════════════════════════════════════════════"
if [[ "${IS_CDHASH}" -eq 1 ]]; then
  echo "结论：DR 是 cdhash 型 —— 通知身份不跨构建，存在旧版本通知残留风险。"
  echo
  echo "  查看已有残留：./Scripts/cleanup-orphan-notifications.sh   # 默认只诊断"
  echo "  根治：        ./Scripts/sign-app.sh <App>    # 嵌入身份型 DR，无需证书"
  echo
  echo "  已有残留想真正静音：系统设置 → 通知 → 喝水提醒 → 关掉「允许通知」"
  echo "  （按 bundle id 生效，对所有历史身份都有效；SIP 下没有别的安全办法）"
  exit 1
else
  echo "结论：DR 是身份型 —— 通知身份跨构建稳定，新版能清理旧版的通知。"
  exit 0
fi
