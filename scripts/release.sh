#!/bin/bash
# Cut a Sparkle release: build a versioned .app, zip it, EdDSA-sign the archive, and
# (re)generate appcast.xml pointing at the GitHub release download.
#
#   VERSION=0.2.0 scripts/release.sh
#
# Output lands in dist/:
#   dist/CClimit-<version>.zip   → upload as an asset to GitHub release tag v<version>
#   dist/appcast.xml             → publish to https://cclimit.app/appcast.xml
#
# The archive is signed with the private EdDSA key in your login Keychain (generated once
# via Sparkle's generate_keys); the app verifies it against SUPublicEDKey in Info.plist.
# The app and the disk image are Developer ID signed and notarized, so they open on other
# Macs without a Gatekeeper warning. Needs a "Developer ID Application" cert in the login
# Keychain and the notary profile (see scripts/notarize.sh). ALLOW_DEV_SIGN=1 skips both,
# for a test release only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:?set VERSION, e.g. VERSION=0.2.0 scripts/release.sh}"
BUILD="${BUILD:-$VERSION}"
GH_REPO="1fc0nfig/cclimit"

DIST="$ROOT/dist"
APP="$ROOT/build/cclimit.app"
ZIP="$DIST/cclimit-$VERSION.zip"
APPCAST="$DIST/appcast.xml"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

mkdir -p "$DIST"

DMG="$DIST/cclimit-$VERSION.dmg"
NOTARIZE=1
# Read the list first: `grep -q` exits on the first match, and under pipefail the SIGPIPE
# that `security` then gets would read as "no cert".
IDENTITIES="$(security find-identity -v -p codesigning)"
if [[ "$IDENTITIES" != *'"Developer ID Application: '* ]]; then
    if [ -n "${ALLOW_DEV_SIGN:-}" ]; then
        NOTARIZE=""
        echo "warning: no Developer ID cert, building a release that is not notarized" >&2
    else
        echo "error: no 'Developer ID Application' cert in the keychain (ALLOW_DEV_SIGN=1 to skip)" >&2
        exit 1
    fi
fi

# 1. Build the release bundle at this version (embeds + signs Sparkle.framework), then
#    notarize and staple it, so the zip and the disk image carry the ticket.
VERSION="$VERSION" BUILD="$BUILD" "$ROOT/scripts/make-app.sh" release
[ -n "$NOTARIZE" ] && "$ROOT/scripts/notarize.sh" "$APP"

# 2. Archive it — Sparkle installs from a zip that preserves the .app at the top level.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 2b. The disk image for first installs, from the same stapled app.
VERSION="$VERSION" BUILD="$BUILD" SKIP_BUILD=1 "$ROOT/scripts/make-dmg.sh"
[ -n "$NOTARIZE" ] && "$ROOT/scripts/notarize.sh" "$DMG"

# 3. Sign + measure the archive. sign_update prints: sparkle:edSignature="…" length="…"
SIG_ATTRS="$("$SIGN_UPDATE" "$ZIP")"
PUB_DATE="$(date -R)"
URL="https://github.com/$GH_REPO/releases/download/v$VERSION/cclimit-$VERSION.zip"

# 4. Emit a single-item appcast for the newest build. Sparkle upgrades every older user to
#    the top item, so one entry is enough; regenerate on each release.
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
	<channel>
		<title>cclimit</title>
		<link>https://cclimit.app/appcast.xml</link>
		<description>Menu bar usage gauge for Claude Code.</description>
		<language>en</language>
		<item>
			<title>Version $VERSION</title>
			<pubDate>$PUB_DATE</pubDate>
			<sparkle:version>$BUILD</sparkle:version>
			<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
			<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
			<enclosure url="$URL" type="application/octet-stream" $SIG_ATTRS />
		</item>
	</channel>
</rss>
XML

echo
echo "Release $VERSION prepared:"
echo "  $ZIP"
echo "  $DMG"
echo "  $APPCAST"
echo
echo "Next:"
echo "  1. gh release create v$VERSION $DMG $ZIP --repo $GH_REPO --title \"v$VERSION\" --notes \"…\""
echo "  2. Publish $APPCAST to https://cclimit.app/appcast.xml (cclimit-web/public/appcast.xml → deploy)"
