#!/bin/bash
# Build a distributable disk image: CClimit.app + a drag-to-Applications shortcut.
#
#   VERSION=0.1.0 scripts/make-dmg.sh
#
# Assembles the app first (embeds + signs Sparkle), then packages a compressed UDZO image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$VERSION}"
APP="$ROOT/build/CClimit.app"
DMG="$ROOT/dist/CClimit-$VERSION.dmg"

mkdir -p "$ROOT/dist"
VERSION="$VERSION" BUILD="$BUILD" "$ROOT/scripts/make-app.sh" release

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/CClimit.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "CClimit $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "Built $DMG"
