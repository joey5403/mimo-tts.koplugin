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
rm -f "$DEST/install.sh"

VERSION=$(sed -n 's/^[[:space:]]*version = "\(.*\)".*$/\1/p' "$SRC_DIR/main.lua" | head -1)
echo "MiMo TTS plugin v$VERSION installed to: $DEST"
echo "Restart KOReader, then: 菜单 → 更多工具 → MiMo TTS 语音听书"
