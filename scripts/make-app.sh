#!/bin/bash
# Assemble a runnable cclimit.app from the SPM build product.
# Ad-hoc signed for local development; Developer ID signing comes later (docs/PLAN.md).
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Version is overridable for releases: `VERSION=0.2.0 BUILD=5 scripts/make-app.sh release`.
# Sparkle shows CFBundleShortVersionString and orders updates by CFBundleVersion.
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$VERSION}"
APP="$ROOT/build/cclimit.app"

# Sparkle: the appcast the app polls, and the public half of the EdDSA update-signing key.
# The private half lives only in the release machine's login Keychain (never committed).
SPARKLE_FEED_URL="https://cclimit.app/appcast.xml"
SPARKLE_PUBLIC_KEY="rnEM6inRl6G2eKQHKzyC50/5vh0qxKNi2xwqvL536gU="
SPARKLE_FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CClimit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/cclimit"

# App icon (Finder, Dock-if-shown, About box). Built from assets/brand/app-icon-1024.png.
cp "$ROOT/assets/brand/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Embed Sparkle.framework (with its Autoupdate + Updater.app + XPC helpers) and point the
# executable at it. install_name_tool tolerates a pre-existing rpath, so ignore that error.
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/cclimit" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>cclimit</string>
	<key>CFBundleIdentifier</key><string>com.cernymatyas.cclimit</string>
	<key>CFBundleName</key><string>cclimit</string>
	<key>CFBundleDisplayName</key><string>cclimit</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>© Matyáš Černý · MIT</string>
	<key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
	<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
	<key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# Prefer the stable "CClimit Dev" identity (scripts/dev-cert.sh) so the Keychain consent
# for reading Claude Code's token survives rebuilds. Fall back to ad-hoc if it's absent.
# Note: the dev cert is self-signed/untrusted by design, so it's listed by `find-identity`
# WITHOUT -v (which filters to trusted identities only).
DEV_IDENTITY="CClimit Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_IDENTITY"; then
    SIGN_IDENTITY="$DEV_IDENTITY"
else
    SIGN_IDENTITY="-"
fi

# Sign inside-out: the embedded framework (and its nested helpers) before the app that
# contains it, or the outer signature is invalidated. `--deep` is fine for the dev cert;
# Developer ID + notarization will sign each helper explicitly (docs/PLAN.md).
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Built $APP ($CONFIG) — ad-hoc signed (run 'make dev-cert' for stable consent)"
else
    echo "Built $APP ($CONFIG) — signed with '$SIGN_IDENTITY'"
fi
