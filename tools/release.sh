#!/bin/sh
# Build a release zip: dist/mimo-tts.koplugin-vX.Y.Z.zip
#
# The version is read from main.lua (single source of truth); when HEAD is
# tagged, the tag must match it.
set -e

cd "$(dirname "$0")/.."

LUAJIT=${LUAJIT:-luajit}
VERSION=$(sed -n 's/^[[:space:]]*version = "\(.*\)".*$/\1/p' main.lua | head -1)
if [ -z "$VERSION" ]; then
    echo "release: cannot read version from main.lua" >&2
    exit 1
fi
TAG="v$VERSION"
echo "release: building $TAG"

# 1) syntax check every lua file
for f in *.lua; do
    "$LUAJIT" -bl "$f" >/dev/null
done
echo "release: syntax OK"

# 2) compile and verify translations
make mo >/dev/null
echo "release: catalogs OK"

# 3) version consistency with git
HEAD_TAG=$(git describe --tags --exact-match 2>/dev/null || true)
if [ -n "$HEAD_TAG" ] && [ "$HEAD_TAG" != "$TAG" ]; then
    echo "release: HEAD is tagged $HEAD_TAG but main.lua says $TAG" >&2
    echo "release: fix: set version = \"${TAG#v}\" in main.lua (and a CHANGELOG.md" >&2
    echo "release:       entry), commit, then re-tag: git tag -d $HEAD_TAG &&" >&2
    echo "release:       git tag $TAG && git push -f origin $TAG" >&2
    exit 1
fi
if [ -z "$HEAD_TAG" ]; then
    echo "release: note: HEAD is not tagged yet (expected tag: $TAG)"
fi

# 4) build the zip with the directory layout users extract into plugins/
mkdir -p dist
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/mimo-tts.koplugin"
cp -r _meta.lua main.lua mimoapi.lua textprovider.lua chunker.lua base64.lua \
      player.lua openslesplayer.lua translations.lua icons l10n \
      README.md README.zh-CN.md CHANGELOG.md install.sh \
      "$STAGING/mimo-tts.koplugin/"
OUT="dist/mimo-tts.koplugin-$TAG.zip"
rm -f "$OUT"
(cd "$STAGING" && zip -qr "$OLDPWD/$OUT" mimo-tts.koplugin)
echo "release: built $OUT ($(du -h "$OUT" | cut -f1))"

# 5) release notes from the CHANGELOG (same source the CI workflow uses)
python3 tools/release-notes.py "$TAG" > "dist/$TAG-notes.md"
echo "release: notes written to dist/$TAG-notes.md"
echo "release: next: git tag $TAG && git push origin main --tags"
