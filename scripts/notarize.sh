#!/bin/bash
# Notarize and staple a Developer ID signed .app or .dmg.
#
#   scripts/notarize.sh build/cclimit.app
#   scripts/notarize.sh dist/cclimit-1.1.0.dmg
#
# One-time setup: store the notary credentials in the login Keychain under a profile name.
#   xcrun notarytool store-credentials cclimit-notary \
#       --apple-id <apple-id> --team-id <team-id>    # asks for an app-specific password
# NOTARY_PROFILE overrides the profile name.
set -euo pipefail

TARGET="${1:?usage: scripts/notarize.sh <app-or-dmg>}"
PROFILE="${NOTARY_PROFILE:-cclimit-notary}"

if [[ "$TARGET" == *.app ]]; then
    # notarytool takes a zip, dmg, or pkg. Zip the app, submit, then staple the app itself.
    SUBMIT="$(mktemp -d)/$(basename "$TARGET" .app).zip"
    ditto -c -k --keepParent "$TARGET" "$SUBMIT"
else
    SUBMIT="$TARGET"
fi

xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.app ]]; then
    spctl --assess --type execute --verbose=2 "$TARGET"
else
    spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi
