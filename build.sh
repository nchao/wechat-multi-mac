#!/usr/bin/env bash
# 编译「微信多开.app」并安装到 /Applications
# 用法: ./build.sh [输出目录]   默认 /Applications
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="微信多开.app"
SRC="src/wxmulti.applescript"
ICNS="icon/wxmulti.icns"
OUT_DIR="${1:-/Applications}"
TARGET="${OUT_DIR%/}/${APP_NAME}"

[[ -f "$SRC" ]] || { echo "找不到 $SRC" >&2; exit 1; }

if [[ ! -w "$OUT_DIR" ]]; then
  echo "对 $OUT_DIR 没有写权限" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "编译 AppleScript..."
osacompile -o "$TMP/${APP_NAME}" "$SRC"

if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$TMP/${APP_NAME}/Contents/Resources/applet.icns"
  echo "已应用图标"
fi

PL="$TMP/${APP_NAME}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName 微信多开" "$PL" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string 微信多开" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.wxmulti" "$PL" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.wxmulti" "$PL"

# 改过 bundle 内容必须重签，否则 macOS 认为签名失效
codesign --force --deep --sign - "$TMP/${APP_NAME}" >/dev/null 2>&1

if [[ -e "$TARGET" ]]; then
  echo "覆盖已有的 $TARGET"
  rm -rf "$TARGET"
fi
mv "$TMP/${APP_NAME}" "$TARGET"

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$LSREG" ]] && "$LSREG" -f "$TARGET"

echo "完成: $TARGET"
echo "双击即可使用。首次从别处拷贝的 app 可能需要在「系统设置 → 隐私与安全性」放行。"
