# Releasing cclimit

cclimit auto-updates via [Sparkle](https://sparkle-project.org). A release is: a signed
`.app`, packaged as a `.zip` (for the updater) and a `.dmg` (for first-time install), plus
an `appcast.xml` that points at the zip and carries its EdDSA signature.

## One-time setup

- **EdDSA signing key** — generated once with Sparkle's `generate_keys`; the private key
  lives in the login Keychain, the public key is baked into `Info.plist` as `SUPublicEDKey`
  (see `scripts/make-app.sh`). Never commit the private key.
- **Developer ID cert**: a "Developer ID Application" certificate in the login Keychain.
  `scripts/make-app.sh` picks it first and signs with the hardened runtime and a timestamp.
- **Notary profile**: store the notary credentials once, under the profile `cclimit-notary`:
  ```bash
  xcrun notarytool store-credentials cclimit-notary --apple-id <apple-id> --team-id <team-id>
  ```
  It asks for an app-specific password from appleid.apple.com.

## Cut a release

```bash
VERSION=1.1.0 scripts/release.sh
```

It builds the app, notarizes and staples it, zips it for Sparkle, builds and notarizes the
disk image, and writes the appcast. Output: `dist/cclimit-1.1.0.zip`, `dist/cclimit-1.1.0.dmg`,
and `dist/appcast.xml`.

Then publish:

1. **Binaries → GitHub Releases** (the appcast enclosure URL points here):
   ```bash
   gh release create v0.2.0 dist/cclimit-0.2.0.dmg dist/cclimit-0.2.0.zip \
     --repo 1fc0nfig/cclimit --title "v0.2.0" --notes "…"
   ```
2. **Appcast → cclimit.app**: copy `dist/appcast.xml` to `cclimit-web/public/appcast.xml`
   and deploy. The installed app polls `https://cclimit.app/appcast.xml`, so auto-update
   only activates once this file is live.

`scripts/release.sh` regenerates a single-item appcast for the newest build — Sparkle
upgrades every older user to the top item, so one entry is enough.

## Versioning

`VERSION` sets `CFBundleShortVersionString` (marketing) and, unless `BUILD` is given,
`CFBundleVersion` (Sparkle's ordering key). Keep them monotonic across releases.
