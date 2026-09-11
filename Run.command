#!/bin/bash

set -u

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR" || exit 1

pause_before_exit() {
  printf '\n'
  read -r -n 1 -s -p "按任意键关闭此窗口……"
  printf '\n'
}

if [ "$(uname -s)" != "Darwin" ]; then
  echo "错误：MacBook Duo Screen 只能在 macOS 上运行。"
  pause_before_exit
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  clear
  echo "首次运行需要 Apple Command Line Tools。"
  echo "正在打开 Apple 的安装窗口……"
  xcode-select --install >/dev/null 2>&1 || true
  echo
  echo "安装完成后，请再次双击 Run.command。"
  pause_before_exit
  exit 1
fi

BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/MacBook Duo Screen.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BINARY="$MACOS_DIR/MacBookDuoScreen"
PLIST="$CONTENTS_DIR/Info.plist"

mkdir -p "$MACOS_DIR"

SOURCE_FILES=("$ROOT_DIR"/Sources/*.swift)
if [ ! -e "${SOURCE_FILES[0]}" ]; then
  clear
  echo "错误：Sources 目录中没有找到 Swift 源码。"
  pause_before_exit
  exit 1
fi

# Avoid accidentally launching an older in-memory build after pulling new code.
if pgrep -x MacBookDuoScreen >/dev/null 2>&1; then
  pkill -x MacBookDuoScreen >/dev/null 2>&1 || true
  sleep 0.3
fi

NEED_BUILD=0
if [ ! -x "$BINARY" ]; then
  NEED_BUILD=1
else
  for source in "${SOURCE_FILES[@]}"; do
    if [ "$source" -nt "$BINARY" ]; then
      NEED_BUILD=1
      break
    fi
  done
fi

write_plist() {
  cat > "$PLIST" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>MacBookDuoScreen</string>
  <key>CFBundleIdentifier</key>
  <string>com.oboahs.MacBookDuoScreen</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MacBook Duo Screen</string>
  <key>CFBundleDisplayName</key>
  <string>MacBook Duo Screen</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>MacBook Duo Screen 需要实时读取内置屏幕画面，用转轴角度做透视补偿。画面只在本机内存中处理，不会保存或上传。</string>
</dict>
</plist>
PLIST_EOF
}

write_plist

if [ "$NEED_BUILD" -eq 1 ]; then
  clear
  echo "=============================================="
  echo " MacBook Duo Screen 2.0 · Perspective Lock"
  echo "=============================================="
  echo
  echo "正在编译 Intel/macOS 原生应用……"

  if ! xcrun swiftc -O "${SOURCE_FILES[@]}" \
      -o "$BINARY" \
      -framework AppKit \
      -framework IOKit \
      -framework CoreFoundation \
      -framework CoreMedia \
      -framework CoreVideo \
      -framework ScreenCaptureKit \
      -framework Metal \
      -framework MetalKit; then
    echo
    echo "编译失败。请把上面的完整错误信息发出来。"
    pause_before_exit
    exit 1
  fi

  chmod +x "$BINARY"
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
  fi
  echo "✓ 编译完成"
fi

if [ "$#" -gt 0 ]; then
  "$BINARY" "$@"
  STATUS=$?
  if [ "$STATUS" -ne 0 ]; then
    pause_before_exit
  fi
  exit "$STATUS"
fi

open "$APP_DIR"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo "启动失败，状态码：$STATUS"
  pause_before_exit
  exit "$STATUS"
fi

echo "✓ MacBook Duo Screen 2.0 已启动。"
echo "请点击菜单栏角度，选择“启用视觉锁定”。"
echo "首次启用时 macOS 会请求“屏幕录制”权限。"
echo "这个终端窗口可以直接关闭。"
exit 0
