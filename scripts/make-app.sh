#!/bin/bash
# Assemble a runnable cclimit.app from the SPM build product.
# Signed with the best identity in the keychain: Developer ID for releases (see below).
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
	<!-- The CLI proxy is a host the user picks, usually plain http on a LAN or tailnet.
	     ATS refuses every http load without this, so the proxy could never connect. -->
	<key>NSAppTransportSecurity</key>
	<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# Signing identity, best first. A release for other Macs needs "Developer ID Application":
# it is the only one notarization accepts. Apple Development and the local "CClimit Dev"
# cert are for this Mac. SIGN_IDENTITY overrides the choice.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    :
elif DEV_ID="$(echo "$IDENTITIES" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')" && [ -n "$DEV_ID" ]; then
    SIGN_IDENTITY="$DEV_ID"
elif APPLE_DEV="$(echo "$IDENTITIES" | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')" && [ -n "$APPLE_DEV" ]; then
    SIGN_IDENTITY="$APPLE_DEV"
elif echo "$IDENTITIES" | grep -q "CClimit Dev"; then
    SIGN_IDENTITY="CClimit Dev"
else
    SIGN_IDENTITY="-"
fi

# Sign inside-out: each nested helper, then the framework, then the app, or the outer
# signature is invalidated. Developer ID adds the hardened runtime and a secure timestamp,
# which notarization requires. The order and flags follow Sparkle's own guide.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
    "${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
    "${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
    "${SIGN[@]}" "$FW/Versions/B/Autoupdate"
    "${SIGN[@]}" "$FW/Versions/B/Updater.app"
    "${SIGN[@]}" "$FW"
    "${SIGN[@]}" "$APP"
    codesign --verify --deep --strict "$APP"
else
    codesign --force --deep --sign "$SIGN_IDENTITY" "$FW"
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Built $APP ($CONFIG) — ad-hoc signed (run 'make dev-cert' for stable consent)"
else
    echo "Built $APP ($CONFIG) — signed with '$SIGN_IDENTITY'"
fi
