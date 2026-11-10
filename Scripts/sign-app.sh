#!/bin/bash
#
# 给 App 签名，并保证「通知身份」跨构建稳定。
#
# 关键在 designated requirement（DR）：它才是系统认的「代码身份」。
#   ad-hoc 默认   → DR = cdhash H"..."       每次构建都不同 ⇒ 每版都是新的通知身份
#   显式嵌入 DR   → DR = identifier "..."     跨构建相同     ⇒ 新版能清掉旧版的通知
#
# 所以本脚本**总是**显式嵌入一条身份型 DR（`-r`），即便走 ad-hoc。
# 这条 DR 只绑 bundle id，不绑证书、不绑 cdhash —— 不需要证书、不需要钥匙串、
# 不需要任何 Secret，CI 与本地行为一致。
#
# 想用更强的身份（证书）时可以配 SIGNING_IDENTITY，脚本会用它签名；
# 那时 DR 由证书决定（同样是身份型，跨构建稳定）。
# 注意：从「只绑 bundle id」升级到「证书 DR」是安全的 —— 新版能清掉旧版的残留；
# 反向不成立。所以这个 DR 一旦选定就不要再改回去。
#
# 用法：
#     ./Scripts/sign-app.sh build/dd/Build/Products/Release/WaterReminder.app
#
# 环境变量：
#     SIGNING_IDENTITY     有则用该证书签名；没有则走 ad-hoc + 身份型 DR
#     SIGNING_REQUIREMENT  覆盖嵌入的 DR（默认 `designated => identifier "<bundle id>"`）
#
# 注意：xcodebuild 内部的 CODE_SIGN_IDENTITY 会拒绝非 Apple 签发的证书，
# 所以签名必须在 xcodebuild **之后**单独跑（构建时用 CODE_SIGNING_ALLOWED=NO）。
#
set -euo pipefail

APP="${1:-}"
if [[ -z "${APP}" || ! -d "${APP}" ]]; then
  echo "用法：$0 <path/to/App.app>" >&2
  exit 2
fi

PLIST="${APP}/Contents/Info.plist"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "${PLIST}" 2>/dev/null || true)"
if [[ -z "${BUNDLE_ID}" ]]; then
  echo "❌ 读不到 CFBundleIdentifier：${PLIST}" >&2
  exit 2
fi

# 身份型 DR：只绑 bundle id。
# 故意不掺 cdhash（那正是问题根源），也不用证书（ad-hoc 环境下拿不到）。
REQUIREMENT="${SIGNING_REQUIREMENT:-designated => identifier \"${BUNDLE_ID}\"}"

# ---------- 选择签名身份 ----------
IDENTITY=""

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  IDENTITY="${SIGNING_IDENTITY}"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "WaterReminder Self-Signed"; then
  # 取 SHA-1（比 CN 稳：CN 里若有重名/特殊字符会出问题）
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "WaterReminder Self-Signed" \
    | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]*([0-9A-F]{40}).*/\1/')"
fi

if [[ -z "${IDENTITY}" ]]; then
  echo "==> 没有可用证书，走 ad-hoc 签名（并显式嵌入身份型 DR）"
  echo "    注意：ad-hoc 不提供证书链，通知系统可能不把它当「可信 App」；"
  echo "    但 DR 是我们指定的那条，所以通知身份跨构建稳定 —— 这正是与裸 ad-hoc 的区别。"
  # 关键就是 -r：不指定它，codesign 会写入 cdhash 型 DR，问题就回来了
  if ! codesign --force --sign - -r="${REQUIREMENT}" "${APP}"; then
    echo "❌ codesign 失败。" >&2
    echo "   注意：失败时它可能已经删掉旧签名并退回 cdhash 型 DR（通知身份就断了），" >&2
    echo "   所以这里必须当致命错误处理，不能继续往下走。" >&2
    echo "   常见原因：包内存在不该有的文件（如 Contents/ 下多出的散文件）。" >&2
    echo "   可以用 codesign --force --sign - <App> 复现具体报错。" >&2
    exit 1
  fi
  SIGN_MODE="ad-hoc + 身份型 DR"
else
  # 用证书签名。
  #
  # 不用 --deep：它会用同一身份递归签嵌套的 helper，对我们这种单体 App 反而容易
  # 把 framework 的 entitlements 搞乱。本 App 没有嵌套 bundle。
  #
  # 不加 --options runtime：本工程一直是 ENABLE_HARDENED_RUNTIME=NO 出包，
  # 这次只改「签名身份」，不顺带改运行时加固，避免把两件事混在一个改动里。
  #
  # 同时显式带上 -r：万一证书以后换掉，DR 仍绑 bundle id，不会把通知身份弄断。
  if ! codesign --force --timestamp=none --sign "${IDENTITY}" -r="${REQUIREMENT}" "${APP}"; then
    echo "❌ codesign 失败。" >&2
    echo "   失败时可能已删掉旧签名并退回 cdhash 型 DR，必须当致命错误处理。" >&2
    exit 1
  fi
  SIGN_MODE="证书签名（${IDENTITY}）"
fi

# ---------- 校验与报告 ----------
echo "==> 校验"
# 注意：自签名证书在 CI 里只是导入到临时钥匙串、没有 add-trusted-cert，
# 所以 `--verify` 可能报「证书链不受信任」。这种情况下 App 仍能运行、
# 通知身份也仍然是稳定的 —— 不把它当致命错误，只提示。
# （管道里要拿 codesign 自己的退出码，所以先存输出再判断，不能直接 `if | sed`）
VERIFY_OUT="$(codesign --verify --strict --verbose=2 "${APP}" 2>&1)" && VERIFY_RC=0 || VERIFY_RC=$?
echo "${VERIFY_OUT}" | sed 's/^/    /'

# 「产物不满足自己声明的 DR」是**致命**问题：那是 DR 写成了 ad-hoc 根本做不到的东西
# （例如 SIGNING_REQUIREMENT 里带了 `anchor apple generic` 却走 ad-hoc 签名）。
# 这种 App 一旦被系统拿去校验 DR 就会被判非法，不能放过。
# 注意不能用退出码判定：证书链不受信任同样会返回非 0，那是可接受的自签名现象。
if echo "${VERIFY_OUT}" | grep -q 'does not satisfy its designated Requirement'; then
  echo
  echo "❌ 产物不满足自己声明的 designated requirement。" >&2
  echo "   说明 SIGNING_REQUIREMENT 与签名方式不匹配：" >&2
  echo "   当前的 DR 是：${REQUIREMENT}" >&2
  echo "   ad-hoc 签名只有 identifier 有意义，不能声明 anchor/certificate 之类的条件。" >&2
  echo "   去掉 SIGNING_REQUIREMENT 用默认值即可（默认只绑 bundle id）。" >&2
  exit 1
fi

if [[ "${VERIFY_RC}" -eq 0 ]]; then
  echo "    ✅ 签名自校验通过"
else
  echo "    ⚠️  签名自校验未通过（rc=${VERIFY_RC}）。自签名证书未加进系统信任时属正常现象；" >&2
  echo "        本地可跑 make-signing-cert.sh（含 add-trusted-cert）消除。" >&2
fi

DR="$(codesign -d -r- "${APP}" 2>&1 | grep 'designated' | sed 's/^# *//' || true)"
# 注意 `|| true`：grep -m1 提前退出会给 codesign 发 SIGPIPE，
# 配上 set -o pipefail 后整条管道返回 141，赋值就会被 set -e 判成失败
CDHASH="$(codesign -dvvv "${APP}" 2>&1 | grep -m1 '^CDHash=' | cut -d= -f2 || true)"

echo
echo "    签名方式：${SIGN_MODE}"
echo "    CDHash  ：${CDHASH}"
echo "    DR      ：${DR}"

# 判据：DR 里出现 cdhash 就是坏的 —— 那正是「每构建换身份」的根源
if echo "${DR}" | grep -q 'cdhash H"'; then
  echo
  echo "❌ DR 仍是 cdhash 型 —— 这次签名没起到「稳定通知身份」的作用。" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::签名后的 designated requirement 仍是 cdhash 型，通知身份会随构建变化。"
  fi
  exit 1
fi

echo
echo "✅ DR 是身份型，跨构建稳定。"
