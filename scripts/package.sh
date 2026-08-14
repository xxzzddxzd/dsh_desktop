#!/bin/bash
# Package dist/DSH Desktop.app into a release zip + sha256 checksum.
# Output: dist/release/dsh-desktop.zip(.sha256)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/DSH Desktop.app"
OUT="$ROOT/dist/release"

if [[ ! -d "$APP" ]]; then
  echo "先构建：$ROOT/scripts/build.sh"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
echo "==> 打包 DSH Desktop v$VERSION"

mkdir -p "$OUT"
rm -f "$OUT/dsh-desktop.zip" "$OUT/dsh-desktop.zip.sha256"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/dsh-desktop.zip"
(cd "$OUT" && shasum -a 256 dsh-desktop.zip > dsh-desktop.zip.sha256)

echo "==> 完成：$OUT/dsh-desktop.zip"
cat "$OUT/dsh-desktop.zip.sha256"
