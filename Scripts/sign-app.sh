#!/bin/bash
#
# 用「身份型」证书给 App 签名。
#
# 与 ad-hoc（`codesign --sign -`）的区别：
#   ad-hoc      → DR = cdhash H"..."    每次构建都不同 ⇒ 每版都是新的通知身份
#   证书        → DR = identifier + 证书  跨构建相同     ⇒ 新版能清掉旧版的通知
#
# 用法：
#     ./Scripts/sign-app.sh build/dd/Build/Products/Release/WaterReminder.app
#
# 身份查找顺序：
#   1. 环境变量 SIGNING_IDENTITY（CI 里用，值是证书 CN）
#   2. `security find-identity` 里包含 "WaterReminder Self-Signed" 的证书
#   3. 兜底：ad-hoc，并打警告（不会让构建失败）
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
  echo "⚠️  没有找到 WaterReminder Self-Signed 证书，降级为 ad-hoc 签名。" >&2
  echo "    ad-hoc 意味着 DR=cdhash：每构建一次就换一个通知身份，" >&2
  echo "    旧版本排下的通知将无法被新版本清理（会一直弹）。" >&2
  echo "    修复：跑 ./Scripts/make-signing-cert.sh 生成证书，或设置 SIGNING_IDENTITY。" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::本次产物是 ad-hoc 签名，通知身份每次构建都会变；旧版本的通知将无法被清理。"
  fi
  codesign --force --deep --sign - "${APP}"
  exit 0
fi

# ---------- 用证书签名 ----------
echo "==> 签名身份：${IDENTITY}"

# 不用 --deep：它会用同一身份递归签嵌套的 helper，对我们这种单体 App 反而容易
# 把 framework 的 entitlements 搞乱。本 App 没有嵌套 bundle。
#
# 不加 --options runtime：本工程一直是 ENABLE_HARDENED_RUNTIME=NO 出包，
# 这次只改「签名身份」，不顺带改运行时加固，避免把两件事混在一个改动里。
# （要加固的话是另一个决定：加固后 DYLD_INSERT_LIBRARIES 会被拦，
#   也不影响通知身份这件事。）
codesign --force --timestamp=none --sign "${IDENTITY}" "${APP}"

# ---------- 校验与报告 ----------
echo "==> 校验"
# 注意：自签名证书在 CI 里只是导入到临时钥匙串、没有 add-trusted-cert，
# 所以 `--verify` 可能报「证书链不受信任」。这种情况下 App 仍能运行、
# 通知身份也仍然是稳定的 —— 不把它当致命错误，只提示。
# （管道里要拿 codesign 自己的退出码，所以先存输出再判断，不能直接 `if | sed`）
VERIFY_OUT="$(codesign --verify --strict --verbose=2 "${APP}" 2>&1)" && VERIFY_RC=0 || VERIFY_RC=$?
echo "${VERIFY_OUT}" | sed 's/^/    /'
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
echo "    签名身份：${IDENTITY}"
echo "    CDHash  ：${CDHASH}"
echo "    DR      ：${DR}"

if echo "${DR}" | grep -q 'cdhash H"'; then
  echo
  echo "❌ DR 仍然是 cdhash 型 —— 这次签名没起到「稳定通知身份」的作用。" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::签名后的 designated requirement 仍是 cdhash 型，通知身份会随构建变化。"
  fi
  exit 1
fi

echo
echo "✅ DR 是身份型，跨构建稳定。"
