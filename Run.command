#!/bin/bash

set -u

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR" || exit 1

clear
printf '%s\n' "=============================================="
printf '%s\n' " MacBook Duo Screen · 转轴角度传感器测试"
printf '%s\n' "=============================================="
printf '\n'

pause_before_exit() {
  printf '\n'
  read -r -n 1 -s -p "按任意键关闭此窗口……"
  printf '\n'
}

if [ "$(uname -s)" != "Darwin" ]; then
  echo "错误：本项目只能在 macOS 上运行。"
  pause_before_exit
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "首次运行需要 Apple Command Line Tools，用来编译本地程序。"
  echo "正在尝试打开 Apple 的安装窗口……"
  xcode-select --install >/dev/null 2>&1 || true
  echo
  echo "安装完成后，请再次双击 Run.command。"
  pause_before_exit
  exit 1
fi

mkdir -p .build
SOURCE="Sources/main.swift"
BINARY=".build/MacBookDuoScreen"

if [ ! -f "$SOURCE" ]; then
  echo "错误：找不到 $SOURCE。请确保 Run.command 位于项目根目录。"
  pause_before_exit
  exit 1
fi

NEED_BUILD=0
if [ ! -x "$BINARY" ]; then
  NEED_BUILD=1
elif [ "$SOURCE" -nt "$BINARY" ]; then
  NEED_BUILD=1
fi

if [ "$NEED_BUILD" -eq 1 ]; then
  echo "首次运行：正在编译原生 LAS 测试程序……"
  if ! xcrun swiftc -O "$SOURCE" -o "$BINARY" -framework IOKit -framework CoreFoundation; then
    echo
    echo "编译失败。请把上面的完整错误信息发出来。"
    pause_before_exit
    exit 1
  fi
  chmod +x "$BINARY"
  echo "✓ 编译完成"
  echo
fi

"$BINARY" "$@"
STATUS=$?

if [ "$STATUS" -eq 130 ]; then
  echo
  echo "已停止监测。"
elif [ "$STATUS" -ne 0 ]; then
  echo
  echo "程序退出，状态码：$STATUS"
fi

pause_before_exit
exit "$STATUS"
