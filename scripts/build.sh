#!/bin/bash
# Build DSH Desktop.app: compile Swift sources, assemble the bundle,
# generate the icon, ad-hoc codesign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/DSH Desktop.app"
CONTENTS="$APP/Contents"

echo "==> 清理旧产物"
rm -rf "$APP"

echo "==> 创建 bundle 结构"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "==> 编译 Swift 源码 (swiftc -O, Swift 5 mode, macOS 13+)"
CACHE="$DIST/.module-cache"
mkdir -p "$CACHE"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "$CACHE" \
  -framework AppKit -framework WebKit -framework UserNotifications \
  -framework ServiceManagement -framework Carbon \
  "$ROOT"/Sources/*.swift \
  -o "$CONTENTS/MacOS/DSH Desktop"

echo "==> 复制元数据"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/StatusIcon.svg" "$CONTENTS/Resources/StatusIcon.svg"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> 生成应用图标"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift -module-cache-path "$CACHE" "$ROOT/tools/genicon.swift" "$ICONSET/icon_1024x1024.png" "$ROOT/Resources/StatusIcon.svg" >/dev/null
for size in 16 32 64 128 256 512; do
  half=$((size / 2))
  sips -z $size $size "$ICONSET/icon_1024x1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $size $size "$ICONSET/icon_1024x1024.png" --out "$ICONSET/icon_${half}x${half}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

echo "==> 代码签名 (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> 完成：$APP"
echo "    运行：open \"$APP\""
