#!/bin/sh
# Print the next release version by bumping the latest v* tag.
#
#   tools/next-version.sh [patch|minor|major]   (default: patch)
set -e
BUMP=${1:-patch}
LATEST=$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)
V=${LATEST#v}
MAJOR=${V%%.*}
REST=${V#*.}
MINOR=${REST%%.*}
PATCH=${REST#*.}
PATCH=${PATCH%%[.-]*}
case $BUMP in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    *) echo "next-version: unknown bump '$BUMP' (use patch|minor|major)" >&2; exit 1 ;;
esac
echo "$MAJOR.$MINOR.$PATCH"
