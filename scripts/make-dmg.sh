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
# release.sh builds and notarizes the app first, then sets SKIP_BUILD=1 to package it as is.
if [ -z "${SKIP_BUILD:-}" ]; then
    VERSION="$VERSION" BUILD="$BUILD" "$ROOT/scripts/make-app.sh" release
fi

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
# A Developer ID signature on the image itself, so Gatekeeper checks it before mounting.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
if [ -n "$DEV_ID" ]; then
    codesign --force --timestamp --sign "$DEV_ID" "$DMG"
fi
echo "Built $DMG"
