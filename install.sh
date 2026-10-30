#!/bin/sh
# Install / update the MiMo TTS plugin into a KOReader plugins directory.
#
# Usage:
#   ./install.sh                 # installs into the default user plugins dir
#   ./install.sh <plugins-dir>   # installs into <plugins-dir>
set -eu

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEST_ROOT=${1:-"$HOME/.config/koreader/plugins"}
DEST="$DEST_ROOT/mimo-tts.koplugin"

mkdir -p "$DEST_ROOT"
rm -rf "$DEST"
cp -r "$SRC_DIR" "$DEST"
rm -rf "$DEST/install.sh" "$DEST/.git" "$DEST/dist"

# stamp the version (source of truth: git tags) and report it
if [ -d "$SRC_DIR/.git" ]; then
    ( cd "$SRC_DIR" && sh tools/stamp-version.sh >/dev/null )
fi
VERSION=$(sed -n 's/^return "\(.*\)"/\1/p' "$DEST/mimo_version.lua" 2>/dev/null)
echo "MiMo TTS plugin ${VERSION:+v$VERSION }installed to: $DEST"
echo "Restart KOReader, then: 菜单 → 更多工具 → MiMo TTS 语音听书"
