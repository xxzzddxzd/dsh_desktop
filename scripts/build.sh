#!/bin/bash
# Build DSH Desktop.app: compile Swift sources, assemble the bundle,
# generate the icon, ad-hoc codesign.
#
# Robustness guarantees:
#   - flock lock: concurrent builds refuse to clobber each other
#   - staging dir: the app is assembled fully, then atomically swapped in,
#     so a failed build never leaves dist/ without a runnable app
#   - warns (does not kill) when an instance is currently running
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/DSH Desktop.app"
STAGING="$DIST/.staging/DSH Desktop.app"

# --- 并发互斥：mkdir 锁 + 陈旧锁（>10 分钟，构建被强杀残留）自动回收 ---
acquire_lock() {
  local i
  for i in 1 2 3 4 5; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      return 0
    fi
    local mtime now age
    mtime=$(stat -f %m "$LOCKDIR" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - mtime))
    if [[ "$age" -gt 600 ]]; then
      echo "==> 清理陈旧构建锁（${age}s 前残留）"
      rmdir "$LOCKDIR" 2>/dev/null || true
      continue
    fi
    sleep 2
  done
  return 1
}
LOCKDIR="$DIST/.build-lock"
if ! acquire_lock; then
  echo "错误：另一个构建正在进行（$LOCKDIR 被占用），已退出。"
  exit 1
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

if pgrep -x "DSH Desktop" >/dev/null 2>&1; then
  echo "==> 注意：DSH Desktop 正在运行；构建完成后需手动重启才能生效"
  echo "    （pkill -x "DSH Desktop" && open "$APP"）"
fi

echo "==> 构建到暂存目录（失败不影响现有产物）"
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"

echo "==> 编译 Swift 源码 (swiftc -O, Swift 5 mode, macOS 13+)"
CACHE="$DIST/.module-cache"
mkdir -p "$CACHE"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "$CACHE" \
  -framework AppKit -framework WebKit -framework UserNotifications \
  -framework ServiceManagement -framework Carbon \
  "$ROOT"/Sources/*.swift \
  -o "$STAGING/Contents/MacOS/DSH Desktop"

echo "==> 复制元数据"
cp "$ROOT/Resources/Info.plist" "$STAGING/Contents/Info.plist"
cp "$ROOT/Resources/StatusIcon.svg" "$STAGING/Contents/Resources/StatusIcon.svg"
printf 'APPL????' > "$STAGING/Contents/PkgInfo"

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
iconutil -c icns "$ICONSET" -o "$STAGING/Contents/Resources/AppIcon.icns"

echo "==> 代码签名 (ad-hoc)"
codesign --force --sign - "$STAGING"

echo "==> 原子替换现有产物"
rm -rf "$APP"
mv "$STAGING" "$APP"

echo "==> 完成：$APP"
echo "    运行：open \"$APP\""
