#!/usr/bin/env bash
# 编译「微信多开.app」并安装到 /Applications
# 用法: ./build.sh [输出目录]   默认 /Applications
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="微信多开.app"
SRC_DIR="src/WxMulti"
ICNS="icon/wxmulti.icns"
OUT_DIR="${1:-/Applications}"
TARGET="${OUT_DIR%/}/${APP_NAME}"
BUNDLE_ID="local.wxmulti"
EXEC="WxMulti"

command -v swiftc >/dev/null || {
  echo "找不到 swiftc。安装命令行工具： xcode-select --install" >&2
  exit 1
}
[[ -d "$SRC_DIR" ]] || { echo "找不到 $SRC_DIR" >&2; exit 1; }

if [[ ! -w "$OUT_DIR" ]]; then
  echo "对 $OUT_DIR 没有写权限" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/${APP_NAME}"

echo "编译 Swift 源码..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/${EXEC}" \
  "$SRC_DIR"/Core.swift "$SRC_DIR"/Operations.swift \
  "$SRC_DIR"/Window.swift "$SRC_DIR"/main.swift

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${EXEC}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>微信多开</string>
  <key>CFBundleDisplayName</key><string>微信多开</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
  echo "已应用图标"
fi

# adhoc 签名。改过 bundle 内容必须重签，否则 macOS 认为签名失效
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

if [[ -e "$TARGET" ]]; then
  echo "覆盖已有的 $TARGET"
  rm -rf "$TARGET"
fi
mv "$APP" "$TARGET"

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$LSREG" ]] && "$LSREG" -f "$TARGET"

echo "完成: $TARGET"
echo "双击即可使用。从别处拷贝来的 app 首次打开需在「系统设置 → 隐私与安全性」放行。"
