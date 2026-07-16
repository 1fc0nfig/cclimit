# Releasing CClimit

CClimit auto-updates via [Sparkle](https://sparkle-project.org). A release is: a signed
`.app`, packaged as a `.zip` (for the updater) and a `.dmg` (for first-time install), plus
an `appcast.xml` that points at the zip and carries its EdDSA signature.

## One-time setup

- **EdDSA signing key** — generated once with Sparkle's `generate_keys`; the private key
  lives in the login Keychain, the public key is baked into `Info.plist` as `SUPublicEDKey`
  (see `scripts/make-app.sh`). Never commit the private key.
- **Apple Developer ID** *(pending)* — until the app is Developer ID signed **and
  notarized**, downloads run on other Macs only via right-click → Open. Notarization is the
  last gate before a promoted public launch (see `docs/PLAN.md`).

## Cut a release

```bash
VERSION=0.2.0 make dmg          # dist/CClimit-0.2.0.dmg  (drag-install image)
VERSION=0.2.0 scripts/release.sh # dist/CClimit-0.2.0.zip + dist/appcast.xml (signed)
```

Then publish:

1. **Binaries → GitHub Releases** (the appcast enclosure URL points here):
   ```bash
   gh release create v0.2.0 dist/CClimit-0.2.0.dmg dist/CClimit-0.2.0.zip \
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
