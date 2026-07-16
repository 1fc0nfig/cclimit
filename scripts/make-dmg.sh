#!/bin/bash
# Build a distributable disk image with a styled installer window: the CClimit app icon,
# a drag arrow, and the Applications shortcut. Uses create-dmg (brew install create-dmg).
#
#   VERSION=0.1.0 scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$VERSION}"
APP="$ROOT/build/cclimit.app"
DMG="$ROOT/dist/cclimit-$VERSION.dmg"

command -v create-dmg >/dev/null || { echo "need create-dmg: brew install create-dmg" >&2; exit 1; }

mkdir -p "$ROOT/dist"
VERSION="$VERSION" BUILD="$BUILD" "$ROOT/scripts/make-app.sh" release

# create-dmg builds the Applications symlink itself, so stage only the app.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/cclimit.app"

rm -f "$DMG"
create-dmg \
    --volname "cclimit $VERSION" \
    --volicon "$ROOT/assets/brand/AppIcon.icns" \
    --background "$ROOT/assets/dmg/background.png" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "cclimit.app" 150 175 \
    --app-drop-link 450 175 \
    --hide-extension "cclimit.app" \
    --no-internet-enable \
    "$DMG" "$STAGE" || true   # create-dmg returns non-zero on benign codesign-of-volicon skips

[ -f "$DMG" ] || { echo "DMG build failed" >&2; exit 1; }
echo "Built $DMG"
