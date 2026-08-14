#!/bin/bash
# Install DSH Desktop.app into /Applications and relaunch from there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/DSH Desktop.app"
DEST="/Applications/DSH Desktop.app"

if [[ ! -d "$APP" ]]; then
  echo "先构建：$ROOT/scripts/build.sh"
  exit 1
fi

if [[ -d "$DEST" ]]; then
  echo "替换已有安装：$DEST"
  rm -rf "$DEST"
fi

cp -R "$APP" "$DEST"
echo "已安装：$DEST"
open "$DEST"
