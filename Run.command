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
PLIST_EXPECTED="$BUILD_DIR/Info.plist.expected"
SIGNING_MODE_FILE="$BUILD_DIR/signing-mode.txt"
TCC_IDENTITY_FILE="$BUILD_DIR/tcc-screen-capture-identity.txt"
BUNDLE_ID="com.oboahs.MacBookDuoScreen"

mkdir -p "$MACOS_DIR"

SOURCE_FILES=("$ROOT_DIR"/Sources/*.swift)
if [ ! -e "${SOURCE_FILES[0]}" ]; then
  clear
  echo "错误：Sources 目录中没有找到 Swift 源码。"
  pause_before_exit
  exit 1
fi

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

render_plist() {
  cat <<'PLIST_EOF'
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
  if [ -n "${MDS_SIGNING_IDENTITY:-}" ]; then
    printf '%s\n' "$MDS_SIGNING_IDENTITY"
    return 0
  fi

  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

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
        --identifier "$BUNDLE_ID" "$APP_DIR"; then
      printf 'stable:%s\n' "$stable_identity" > "$SIGNING_MODE_FILE"
      echo "✓ 稳定签名完成"
      return 0
    fi
    echo "⚠ 稳定签名失败，将退回临时签名。"
  fi

  if codesign --force --deep --sign - \
      --identifier "$BUNDLE_ID" "$APP_DIR" >/dev/null 2>&1; then
    printf 'adhoc\n' > "$SIGNING_MODE_FILE"
    echo "✓ 本地临时签名完成"
    return 0
  fi

  echo "错误：应用代码签名失败。"
  return 1
}

current_code_identity() {
  local cdhash
  cdhash="$(codesign -dvvv "$APP_DIR" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
  if [ -n "$cdhash" ]; then
    printf '%s\n' "$cdhash"
    return 0
  fi

  if [ -f "$BINARY" ]; then
    shasum -a 256 "$BINARY" | awk '{print $1}'
    return 0
  fi

  return 1
}

reset_stale_screen_capture_permission_if_needed() {
  local signing_mode
  signing_mode="$(cat "$SIGNING_MODE_FILE" 2>/dev/null || true)"

  if [[ "$signing_mode" != adhoc* ]]; then
    return 0
  fi

  local current_identity previous_identity
  current_identity="$(current_code_identity 2>/dev/null || true)"
  previous_identity="$(cat "$TCC_IDENTITY_FILE" 2>/dev/null || true)"

  if [ -z "$current_identity" ]; then
    echo "⚠ 无法读取当前 App 的代码身份；跳过屏幕录制授权清理。"
    return 0
  fi

  if [ "$current_identity" = "$previous_identity" ]; then
    return 0
  fi

  echo "检测到新的本地临时签名构建。"
  echo "正在清理旧构建遗留的屏幕录制授权记录……"
  if tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1; then
    printf '%s\n' "$current_identity" > "$TCC_IDENTITY_FILE"
    echo "✓ 已清理旧授权记录。"
    echo "  本次点击“启用视觉锁定”时，请重新允许一次屏幕录制；之后同一构建不会再次清理。"
  else
    echo "⚠ 无法自动清理旧授权记录。"
    echo "  可手动执行：tccutil reset ScreenCapture $BUNDLE_ID"
  fi
}

render_plist > "$PLIST_EXPECTED"
PLIST_CHANGED=0
if [ ! -f "$PLIST" ] || ! cmp -s "$PLIST_EXPECTED" "$PLIST"; then
  cp "$PLIST_EXPECTED" "$PLIST"
  PLIST_CHANGED=1
fi
rm -f "$PLIST_EXPECTED"

NEED_SIGN="$PLIST_CHANGED"

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
      -framework MetalKit \
      -framework MetalPerformanceShaders; then
    echo
    echo "编译失败。请把上面的完整错误信息发出来。"
    pause_before_exit
    exit 1
  fi

  chmod +x "$BINARY"
  echo "✓ 编译完成"
  NEED_SIGN=1
fi

if [ -x "$BINARY" ] && ! codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
  echo "检测到 App 签名失效，正在修复……"
  NEED_SIGN=1
fi

STABLE_IDENTITY="$(find_stable_signing_identity)"
CURRENT_SIGNING_MODE="$(cat "$SIGNING_MODE_FILE" 2>/dev/null || true)"
if [ -n "$STABLE_IDENTITY" ] && [ "$CURRENT_SIGNING_MODE" != "stable:$STABLE_IDENTITY" ]; then
  echo "检测到稳定代码签名证书，正在升级现有 App 签名……"
  NEED_SIGN=1
fi

if [ "$NEED_SIGN" -eq 1 ]; then
  if ! sign_app; then
    pause_before_exit
    exit 1
  fi
  if ! codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
    echo "错误：签名后验证仍未通过。"
    pause_before_exit
    exit 1
  fi
fi

reset_stale_screen_capture_permission_if_needed

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
  echo "当前为本地临时签名；同一构建不会重复改写、签名或重置屏幕录制权限。"
fi
echo "请点击菜单栏角度，选择“启用视觉锁定”。"
echo "这个终端窗口可以直接关闭。"
exit 0
