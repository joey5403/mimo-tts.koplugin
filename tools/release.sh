#!/bin/sh
# Build a release zip: dist/mimo-tts.koplugin-vX.Y.Z.zip
#
# The version is stamped into the artifact at build time (mimo_version.lua);
# its single source of truth is the git tag. Three ways to resolve it:
#
#   tools/release.sh                    # the tag HEAD is on (release builds)
#   tools/release.sh --version 1.0.3    # an explicit version
#   tools/release.sh --bump patch       # next version = latest tag + bump
set -e
cd "$(dirname "$0")/.."

LUAJIT=${LUAJIT:-luajit}
VERSION=""
BUMP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --bump)    BUMP=$2; shift 2 ;;
        *) echo "release: unknown argument $1" >&2; exit 1 ;;
    esac
done

if [ -n "$VERSION" ]; then
    :
elif [ -n "$BUMP" ]; then
    VERSION=$(sh tools/next-version.sh "$BUMP")
else
    TAG=$(git describe --tags --exact-match 2>/dev/null) || {
        echo "release: HEAD is not tagged; use --version X.Y.Z or --bump patch|minor|major" >&2
        exit 1
    }
    VERSION=${TAG#v}
fi
TAG="v$VERSION"
echo "release: building $TAG"

# 1) stamp the version into the package
sh tools/stamp-version.sh "$VERSION"

# 2) syntax check every lua file
for f in *.lua; do
    "$LUAJIT" -bl "$f" >/dev/null
done
echo "release: syntax OK"

# 3) compile and verify translations
make mo >/dev/null
echo "release: catalogs OK"

# 4) release notes generated from git history
mkdir -p dist
python3 tools/release-notes.py "${TAG}" > "dist/$TAG-notes.md" 2>/dev/null \
    || python3 tools/release-notes.py HEAD > "dist/$TAG-notes.md"
echo "release: notes written to dist/$TAG-notes.md"

# 5) build the zip with the directory layout users extract into plugins/
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/mimo-tts.koplugin"
cp -r _meta.lua main.lua mimoapi.lua textprovider.lua chunker.lua base64.lua \
      player.lua openslesplayer.lua translations.lua mimo_version.lua icons l10n \
      README.md README.zh-CN.md CHANGELOG.md install.sh \
      "$STAGING/mimo-tts.koplugin/"
OUT="dist/mimo-tts.koplugin-$TAG.zip"
rm -f "$OUT"
(cd "$STAGING" && zip -qr "$OLDPWD/$OUT" mimo-tts.koplugin)
echo "release: built $OUT ($(du -h "$OUT" | cut -f1))"
