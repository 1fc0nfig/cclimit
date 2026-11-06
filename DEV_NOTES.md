# DEV_NOTES

Append-only log of decisions and why. Newest last. The full design notes live in docs/PLAN.md.

## 2026-11-04: proxy traffic, proxy auto-detection, API-price estimates

- **Problem.** Claude Code moved to CLIProxyAPI through `~/.claude-cliproxy`. That dir signs in
  with an API token, not OAuth, so no account owned it, and Projects showed almost nothing.
- **Decision: one transcript pool for proxy-routed dirs.** The proxy picks the login per request,
  so per-account attribution of that traffic is unknowable. One pool, counted once, shown in
  "All", the only account, and proxy-served accounts. Rejected: guessing an account by timestamp.
- **Decision: detect, do not ask.** The address comes from Claude Code's own `ANTHROPIC_BASE_URL`.
  A keyless `GET /` confirms CLIProxyAPI. The management key is the only input left, because the
  proxy stores only its hash.
- **Decision: ATS off for http.** `NSAllowsArbitraryLoads`, because the proxy host is user-chosen
  and usually plain http. Before this, Settings > CLI Proxy could never connect to an http proxy.
  Undo: remove the key from `scripts/make-app.sh`.
- **Decision: dollar estimates, reversing the "no cost analytics" non-goal.** Matyas asked for
  prices in the charts. They show API list-price value ("≈ $"), not a bill. The y axis stays in
  tokens. Unknown models cost $0. A price table change needs a `TranscriptIndex` store version
  bump, so indexed costs are recomputed.

## 2026-11-04: review before v0.2.0

- **Fixed.** Rolling ranges ("Last 30 days", the 5-hour window without a known reset) now start
  on a fixed grid. Their cache key moved every minute, so the report was never found again.
  "Last 30 days" now means the 29 days before today, plus today.
- **Fixed.** A proxy ban seen on the usage path now holds every proxy call until it ends.
  Before, only the login listing honored it, so the next poll extended the ban.
- **Fixed.** `ProxyHub` reads the saved key off the main thread. A locked Keychain could freeze
  the menu bar for up to 10 s.
- **Fixed.** The proxy key goes to `security -i` on stdin, not on the command line, where `ps`
  showed it.
- **Fixed.** Popover opens in "Through Claude Code" mode no longer read usage sooner than the
  10-minute interval that protects the usage endpoint's budget.
- **Fixed.** `release.sh` no longer reads a SIGPIPE from `grep -q` as "no Developer ID cert".
- **Known, not fixed.** The transcript index removes duplicate responses per file, not across
  files. Measured on 31 days: 0.36% of responses in ~/.claude, 1.01% in the proxy folder. A fix
  needs an index-wide key set (about 150k keys). Not worth it for a 1% overcount.
- **Fixed (found while checking the release build).** A burn now needs 10 minutes of samples.
  Readings come in whole percents, so 1% → 2% in 30 s after a reset drew a full red forecast.
- **Fixed (seen after the v0.2.0 update).** Weekly forecasts vanished. Readings wobble by a
  point (64 → 63) with the same reset time, and any drop over 0.5 read as a rollover, so three
  days of history were cut to minutes. A drop under 3 points now counts only when the reset time
  moved later.

## 2026-11-05: menu bar percent drawn as an image

- **Fixed.** The Percent styles rendered as a SwiftUI `Text` label. MenuBarExtra redraws a
  `Text` in its own font and as a template, so the number was too big and never colored. It is
  now one `NSImage` at 11 pt, like the other styles.
- **Decision: green at rest for the text styles.** The number is the only thing in the icon, so
  it carries the full green/amber/red state like a bar. The popover and inline-bar numbers stay
  ink below 70%, because a bar sits beside them.
- **Decision: tighter status item, every icon style.** MenuBarExtra gives the item a variable
  length, and AppKit pads it by 8 pt per side. It now gets a fixed length of the icon width plus
  4 pt per side. MenuBarExtra hides its NSStatusItem, so `StatusItemFit` reads it from the
  status bar window by key and does nothing if the key goes away. The Percent icon went from
  42 pt to 34 pt. Undo: remove `StatusItemFit` and its calls in `CClimitApp.swift`.

## 2026-11-06: plain footer buttons, release signing check

- **Fixed.** On macOS 27 the round Liquid Glass footer buttons drew heavy rims, and the glyphs
  crowded the circles. The footer now has plain monochrome icons with a quiet circle on hover
  and press, on every macOS version. Undo: restore `.buttonStyle(.glass)` in `FooterButton`.
- **Found.** The v0.2.2 release went out signed with "Apple Development", not Developer ID,
  and not notarized (`ALLOW_DEV_SIGN`). Gatekeeper rejects its DMG on other Macs. The Developer
  ID cert and the notary profile now exist, so the next `scripts/release.sh` signs correctly.
