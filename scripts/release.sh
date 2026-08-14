#!/bin/bash
# Build + package + publish a GitHub release for the current version.
# Requires: gh (authenticated), and a clean build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh"
"$ROOT/scripts/package.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"

# Ad-hoc builds are not byte-reproducible across rebuilds: the zip's sha256
# changes on every build, so the cask checksum must always match the freshly
# packaged artifact. Fail loudly instead of publishing a stale hash.
ZIP_SHA="$(awk '{print $1}' "$ROOT/dist/release/dsh-desktop.zip.sha256")"
if ! grep -q "$ZIP_SHA" "$ROOT/Casks/dsh-desktop.rb"; then
  echo "错误：Casks/dsh-desktop.rb 的 sha256 与本次打包产物不一致（$ZIP_SHA）。" >&2
  echo "请先更新 cask 的 sha256 再发布。" >&2
  exit 1
fi

gh release create "v$VERSION" \
  "$ROOT/dist/release/dsh-desktop.zip" \
  "$ROOT/dist/release/dsh-desktop.zip.sha256" \
  --repo xxzzddxzd/dsh_desktop \
  --title "DSH Desktop v$VERSION" \
  --notes "macOS 13+（Apple Silicon）。应用为 ad-hoc 签名，安装脚本会自动去除 quarantine。

一键安装：
\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/xxzzddxzd/dsh_desktop/main/install.sh | bash
\`\`\`"
