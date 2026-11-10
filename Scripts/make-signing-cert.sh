#!/bin/bash
#
# 生成一张「自签名代码签名证书」，用于让 App 的 designated requirement（DR）
# 变成「身份型」而不是「cdhash 型」。
#
# 为什么需要它：见 AGENTS.md「签名与通知身份」一节。
# 简单说 —— ad-hoc 签名时 DR = cdhash，每次重新构建 cdhash 都变，
# 于是每个版本在系统里都是一个全新的「通知身份」，
# 旧版本排下的通知新版本既看不见也清不掉，会永远按原计划弹。
#
# 用法（在你自己的终端里跑，不要在受限沙箱里跑 —— 需要访问钥匙串）：
#     ./Scripts/make-signing-cert.sh
#
# 产物（全部在 .signing/ 目录，该目录已被 .gitignore 忽略）：
#     cert.pem   证书（公开）
#     key.pem    私钥（绝密，不要提交、不要外发）
#     cert.p12   打包好的证书 + 私钥（用于导入 CI）
#
# 之后：
#     · 本地签名：./Scripts/sign-app.sh <path/to/App.app>
#     · CI 签名： 把 cert.p12 的 base64 存进 GitHub Secrets
#                 （变量名 SIGNING_CERT_P12_BASE64，密码存 SIGNING_CERT_PASSWORD）
#
set -euo pipefail

CERT_CN="${CERT_CN:-WaterReminder Self-Signed}"
DAYS="${DAYS:-3650}"
OUT_DIR="${OUT_DIR:-.signing}"

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

if [[ -e "${OUT_DIR}/cert.p12" ]]; then
  echo "⚠️  ${OUT_DIR}/cert.p12 已存在。"
  echo "    证书一旦替换，通知身份就会变，旧版本的通知又会清不掉。"
  echo "    确实要重新生成的话，先把它挪走再跑本脚本。"
  exit 1
fi

mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"

echo "==> 生成私钥与自签名证书（CN=${CERT_CN}，有效期 ${DAYS} 天）"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -days "${DAYS}" \
  -keyout "${OUT_DIR}/key.pem" \
  -out "${OUT_DIR}/cert.pem" \
  -subj "/CN=${CERT_CN}" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

chmod 600 "${OUT_DIR}/key.pem"

P12_PASS="${P12_PASS:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)}"

echo "==> 打包成 PKCS#12（-legacy：macOS 的 security 命令读不了新式 PBE）"
openssl pkcs12 -export -legacy \
  -inkey "${OUT_DIR}/key.pem" \
  -in "${OUT_DIR}/cert.pem" \
  -out "${OUT_DIR}/cert.p12" \
  -passout "pass:${P12_PASS}" 2>/dev/null

echo "==> 导入当前用户的登录钥匙串并信任（会要求你输入一次登录密码）"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if ! security import "${OUT_DIR}/cert.p12" \
      -k "${LOGIN_KEYCHAIN}" \
      -P "${P12_PASS}" \
      -T /usr/bin/codesign >/dev/null 2>&1; then
  echo
  echo "❌ 导入钥匙串失败。" >&2
  echo "   证书文件已经生成好了（${OUT_DIR}/），只是没能装进钥匙串。" >&2
  echo "   常见原因：" >&2
  echo "     · 在受限环境（沙箱 / 非图形会话）里跑 —— 请在你自己的终端窗口里重跑" >&2
  echo "     · 钥匙串被锁 —— 先执行 security unlock-keychain" >&2
  echo
  echo "   手工导入（双击也能装）：" >&2
  echo "     security import ${OUT_DIR}/cert.p12 -k \"${LOGIN_KEYCHAIN}\" -P '<上面那个密码>' -T /usr/bin/codesign" >&2
  echo "   注意 p12 密码 = ${P12_PASS}" >&2
  exit 1
fi

# set-key-partition-list 需要登录钥匙串的密码（不是 p12 的密码）。
# 不传 -k 的话 security 会自己弹提示，比硬编码空串可靠。
# 也可以用 KEYCHAIN_PASS 环境变量预先给，适合无人值守。
if [[ -n "${KEYCHAIN_PASS:-}" ]]; then
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "${KEYCHAIN_PASS}" "${LOGIN_KEYCHAIN}" >/dev/null 2>&1 || true
else
  echo "    （下面会要求输入一次「登录钥匙串」密码，用来授权 codesign 访问私钥）"
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s "${LOGIN_KEYCHAIN}" >/dev/null 2>&1 || {
      echo "⚠️  设置钥匙串分区列表失败。若之后 codesign 报找不到身份，"
      echo "    可在「钥匙串访问」里右键该证书 → 显示简介 → 访问控制 里允许 codesign。"
    }
fi

# 允许 codesign 使用这张证书（不信任的话 codesign 会报 "no identity found"）
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "${LOGIN_KEYCHAIN}" \
  "${OUT_DIR}/cert.pem" 2>/dev/null || {
    echo "⚠️  自动信任失败，请手动在「钥匙串访问」里双击 cert.pem 并把「代码签名」设为「始终信任」。"
  }

echo
echo "==> 验证：应该能在列表里看到这张证书"
security find-identity -v -p codesigning | grep -F "${CERT_CN}" || {
  echo "❌ 没找到签名身份。请到「钥匙串访问 → 登录」里确认证书已信任。"
  exit 1
}

echo
echo "✅ 完成。"
echo
echo "接下来：把下面这一行 base64 存进 GitHub Secrets（变量名 SIGNING_CERT_P12_BASE64）："
echo
base64 -i "${OUT_DIR}/cert.p12"
echo
echo "以及这个密码（变量名 SIGNING_CERT_PASSWORD）："
echo
echo "    ${P12_PASS}"
echo
echo "⚠️  密码只显示这一次。${OUT_DIR}/ 整个目录请妥善备份 ——"
echo "    丢了 cert.p12 就只能重新生成，而重新生成意味着通知身份改变。"
