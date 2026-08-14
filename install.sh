#!/bin/bash
# Install DSH Desktop into /Applications.
#
# Two ways to use this script:
#   1) after a local build:   ./install.sh
#   2) one-liner (no build):  curl -fsSL \
#        https://raw.githubusercontent.com/xxzzddxzd/dsh_desktop/main/install.sh | bash
#
# Env overrides (mostly for CI/testing):
#   DSH_DESKTOP_INSTALL_DIR   install destination, full path including the app
#                             name (default /Applications/DSH Desktop.app)
#   DSH_DESKTOP_NO_OPEN=1     skip launching the app after install
set -euo pipefail

REPO="xxzzddxzd/dsh_desktop"
APP="DSH Desktop.app"
DEST="${DSH_DESKTOP_INSTALL_DIR:-/Applications/DSH Desktop.app}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Script's own directory; empty when piped through curl | bash (bash 3.2 has
# no BASH_SOURCE for stdin scripts, hence the :- fallback).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || true)"

if [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/dist/$APP" ]]; then
  SRC="$SCRIPT_DIR/dist/$APP"
  echo "安装本地构建：$SRC"
else
  echo "下载最新发布版 dsh-desktop.zip …"
  curl -fL --retry 3 -o "$TMP/dsh-desktop.zip" \
    "https://github.com/$REPO/releases/latest/download/dsh-desktop.zip"
  curl -fL --retry 3 -o "$TMP/dsh-desktop.zip.sha256" \
    "https://github.com/$REPO/releases/latest/download/dsh-desktop.zip.sha256"
  (cd "$TMP" && shasum -a 256 -c dsh-desktop.zip.sha256)
  ditto -x -k "$TMP/dsh-desktop.zip" "$TMP/unpacked"
  SRC="$TMP/unpacked/$APP"
  [[ -d "$SRC" ]] || { echo "错误：压缩包内未找到 $APP"; exit 1; }
  echo "下载并校验完成。"
fi

# The app is ad-hoc signed (not notarized): clear the quarantine attribute
# inherited from the download so it opens directly (right-click → 打开 also
# works). Errors are ignored for locally built copies.
xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true

if [[ -d "$DEST" ]]; then
  echo "替换已有安装：$DEST"
  rm -rf "$DEST"
fi
mkdir -p "$(dirname "$DEST")"
cp -R "$SRC" "$DEST"
echo "已安装：$DEST"

if [[ "${DSH_DESKTOP_NO_OPEN:-}" != "1" ]]; then
  open "$DEST"
fi
