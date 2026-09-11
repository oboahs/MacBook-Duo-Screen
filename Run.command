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
SIGNING_MODE_FILE="$BUILD_DIR/signing-mode.txt"

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

find_stable_signing_identity() {
  # Explicit override for advanced/local development use.
  if [ -n "${MDS_SIGNING_IDENTITY:-}" ]; then
    printf '%s\n' "$MDS_SIGNING_IDENTITY"
    return 0
  fi

  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  # Prefer a normal Apple Development identity. It gives the app a stable
  # designated requirement, so TCC can remember Screen Recording permission
  # across rebuilds. Older Xcode certificates used the Mac Developer name.
  local identity
  identity="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "$identity" ]; then
    identity="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Mac Developer: [^"]*\)".*/\1/p' | head -n 1)"
  fi
  if [ -z "$identity" ]; then
    identity="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
  fi

  printf '%s\n' "$identity"
}

sign_app() {
  local stable_identity
  stable_identity="$(find_stable_signing_identity)"

  if [ -n "$stable_identity" ]; then
    echo "正在使用稳定代码签名：$stable_identity"
    if codesign --force --deep --sign "$stable_identity" \
        --identifier com.oboahs.MacBookDuoScreen "$APP_DIR"; then
      printf 'stable:%s\n' "$stable_identity" > "$SIGNING_MODE_FILE"
      echo "✓ 稳定签名完成（屏幕录制权限可跨后续构建保留）"
      return 0
    fi
    echo "⚠ 稳定签名失败，将退回临时签名。"
  fi

  # Ad-hoc signing is enough to run locally, but its designated requirement is
  # tied to this exact build. macOS may therefore ask for Screen Recording again
  # after the source code changes and the binary is rebuilt.
  if codesign --force --deep --sign - \
      --identifier com.oboahs.MacBookDuoScreen "$APP_DIR" >/dev/null 2>&1; then
    printf 'adhoc\n' > "$SIGNING_MODE_FILE"
    echo "⚠ 当前使用临时 ad-hoc 签名。"
    echo "  本次构建授权后可正常使用，但下一次源码更新重新编译时，macOS 可能再次要求屏幕录制权限。"
    echo "  如果钥匙串中安装 Apple Development 证书，脚本会自动切换到稳定签名。"
    return 0
  fi

  echo "错误：应用代码签名失败。"
  return 1
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
      -framework CoreGraphics \
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
  echo "✓ 编译完成"

  if ! sign_app; then
    pause_before_exit
    exit 1
  fi
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
if [ -f "$SIGNING_MODE_FILE" ] && grep -q '^adhoc' "$SIGNING_MODE_FILE"; then
  echo "提示：当前构建使用临时签名；源码再次更新并重新编译后，macOS 可能要求重新授权屏幕录制。"
fi
echo "请点击菜单栏角度，选择“启用视觉锁定”。"
echo "若首次授权屏幕录制，授权后请退出应用并重新双击 Run.command。"
echo "这个终端窗口可以直接关闭。"
exit 0
