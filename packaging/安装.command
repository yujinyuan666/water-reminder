#!/bin/bash
#
#  💧 喝水提醒 —— 一键安装
#
#  双击本文件即可完成安装。脚本会：
#    1) 把 WaterReminder.app 复制到「应用程序」
#    2) 清除 macOS 的隔离标记（绕过「无法验证开发者」拦截）
#    3) 校验签名并启动应用
#
#  如果双击后被系统拦住，请右键本文件 →「打开」。
#

set -uo pipefail

APP_NAME="WaterReminder.app"
APP_ID="WaterReminder"
DST="/Applications/${APP_NAME}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/${APP_NAME}"

pause_exit() {
  echo ""
  read -n 1 -s -r -p "  按任意键关闭本窗口..." || true
  echo ""
  exit "${1:-0}"
}

clear 2>/dev/null || true
echo ""
echo "  💧  喝水提醒 —— 一键安装"
echo "  ──────────────────────────────────────────"
echo ""

# --- 1. 检查载荷 ---
if [ ! -d "${SRC}" ]; then
  echo "  ✗ 找不到 ${APP_NAME}"
  echo "    请确认「安装.command」和「${APP_NAME}」在同一个文件夹里。"
  pause_exit 1
fi

# --- 2. 关掉正在运行的旧版本 ---
if pgrep -x "${APP_ID}" >/dev/null 2>&1; then
  echo "  · 检测到应用正在运行，先退出它..."
  osascript -e "quit app \"${APP_ID}\"" >/dev/null 2>&1 || pkill -x "${APP_ID}" >/dev/null 2>&1 || true
  sleep 1
fi

# --- 3. 覆盖确认 ---
if [ -d "${DST}" ]; then
  echo "  · 「应用程序」中已有旧版本，将被覆盖。"
  printf "    继续安装？(y/N) "
  read -r ANSWER || ANSWER=""
  case "${ANSWER}" in
    [yY]*) ;;
    *) echo ""; echo "  已取消，未做任何改动。"; pause_exit 0 ;;
  esac
fi

# --- 4. 拷贝到 /Applications ---
echo "  · 正在安装到「应用程序」..."
if ! rm -rf "${DST}" 2>/dev/null || ! cp -R "${SRC}" "${DST}" 2>/dev/null; then
  echo "  ✗ 写入「应用程序」失败（权限不足？）"
  echo "    请用管理员权限重试，或手动把 App 拖进「应用程序」。"
  pause_exit 1
fi

# --- 5. 清除隔离标记 ---
echo "  · 正在清除系统隔离标记..."
xattr -rd com.apple.quarantine "${DST}" 2>/dev/null || true
xattr -rd com.apple.quarantine "${SRC}" 2>/dev/null || true

# --- 6. 校验签名 ---
echo "  · 正在校验签名..."
if codesign --verify --deep --strict "${DST}" >/dev/null 2>&1; then
  echo "    ✓ 签名有效"
else
  echo "    ! 签名校验未通过（不影响使用；若打不开请右键 App →「打开」）"
fi

# --- 7. 完成 ---
echo ""
echo "  ✓  安装完成：${DST}"
echo "     启动后菜单栏会出现水滴图标 💧"
echo ""
read -n 1 -s -r -p "  按任意键启动喝水提醒..." || true
echo ""
open "${DST}" 2>/dev/null || echo "  启动失败，请手动到「应用程序」中打开。"
sleep 1
exit 0
