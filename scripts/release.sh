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
# NOTE: for updates to launch cleanly on OTHER Macs the .app must be Developer ID signed +
# notarized first (needs an Apple Developer account — see docs/PLAN.md). Local dogfooding
# with the "CClimit Dev" cert works today.
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

# 1. Build the release bundle at this version (embeds + signs Sparkle.framework).
VERSION="$VERSION" BUILD="$BUILD" "$ROOT/scripts/make-app.sh" release

# 2. Archive it — Sparkle installs from a zip that preserves the .app at the top level.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

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
echo "  $APPCAST"
echo
echo "Next:"
echo "  1. gh release create v$VERSION $ZIP --repo $GH_REPO --title \"v$VERSION\" --notes \"…\""
echo "  2. Publish $APPCAST to https://cclimit.app/appcast.xml (cclimit-web/public/appcast.xml → deploy)"
