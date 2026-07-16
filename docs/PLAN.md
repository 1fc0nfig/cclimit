# cclimit — development plan

Derived from [product.md](product.md) after a brainstorm + deliberation pass (2026-07-15; state in
`.deliberation/cclimit-shape/`). Settled calls baked in: **build** (hybrid — Claude God installed as
the daily benchmark), **session-aware forecast with honest framing**, **quiet v0.1 → public launch
at v0.2**, **attribution stays v1.0 with prerequisites front-loaded**. Peak-hours badge: cut.

> **Status 2026-07-15:** Matyas resolved the leaves — build everything at once, skip Phase 0
> verification, no Apple Developer account yet (ad-hoc local signing for now). All three phases'
> features are implemented in one pass: core gauge + forecast engine + attribution, 40 unit tests
> green, `make run` produces a runnable ad-hoc-signed `build/cclimit.app`. **Validated live** — the
> endpoint returned 200 for Matyas's account and the full pipeline (Keychain → API → decode →
> persist) works.
>
> **Endpoint reality (verified via `swift run cclimit-dump`):** the payload has moved past the
> doc's documented shape. It now carries a generic **`limits[]` array** — entries with
> `kind` ∈ {session, weekly_all, weekly_scoped}, each `weekly_scoped` one carrying
> `scope.model.display_name` (e.g. **Fable**). Legacy `seven_day_opus`/`_sonnet` fields still
> exist but were null. cclimit parses `limits[]` generically, so any new model (Fable, Mythos, …)
> appears automatically; per-model rows are individually toggleable in Settings, and an active
> model cap correctly binds the menu bar icon. `cclimit-dump` is kept as a debug target.
>
> Remaining before public launch: dogfood + fix, Developer ID sign/notarize (needs Apple account),
> Homebrew cask.
>
> **Update 2026-07-16 — auto-update landed early + first public cut.** Sparkle 2.9.4 is
> integrated (SPM dep on `CClimit`; framework embedded + deep-signed by `scripts/make-app.sh`).
> Feed = `https://cclimit.app/appcast.xml`, EdDSA public key in Info.plist, private key in the
> login Keychain. UI: Settings → General → Updates (auto-check toggle + "Check Now"). Release
> tooling: `make dmg` (drag-install image) + `scripts/release.sh` (signed zip + appcast);
> runbook in `docs/RELEASING.md`. v0.1.0 shipped as a **GitHub prerelease** signed with the
> local "CClimit Dev" cert — **not yet notarized**, so other Macs need right-click → Open.
> Two follow-ups gate a promoted launch: (1) Developer ID + notarization, (2) host
> `appcast.xml` on cclimit.app (cclimit-web has no git remote yet) so auto-update goes live.
>
> **Update 2026-07-16 (later) — rate-limit recovery + keychain friction fix.** Live 429s
> revealed the endpoint now DOES send `Retry-After` (observed 1300s ≈ 22 min penalties);
> the old 300s backoff cap retried inside the penalty and never recovered. Fixes:
> `UsageError.rateLimited(retryAfter:)` honors the header (+30s margin, 2h ceiling), blind
> backoff cap raised to 1800s, stale `asyncAfter` timers no longer wake later sleeps early
> (generation counter in AppState — manual refreshes used to permanently accelerate polling),
> UA auto-detected from the installed Claude Code (`ClaudeCodeVersion.detect()`: native
> installer symlink/versions dir + nvm/npm package.json, highest semver; pinned fallback
> bumped 2.1.0 → 2.1.173). Keychain prompt friction (issue #4): credentials now cached in
> memory, re-read only on expiry (2 min skew) or 401 — previously every poll re-read the
> Keychain, and every Claude Code token refresh resets the item's ACL, so prompts recurred
> constantly. Full ACL persistence still needs the stable Developer ID signature (issue #3).
>
> **Endpoint rate-limit reality (established live, 2026-07-16):** the 429 penalty ESCALATES
> (1300s → 3600s) and waiting out one Retry-After did not clear it — probing during/near the
> penalty extends it. Claude Code's real UA is `claude-cli/${VERSION} (external, cli)`
> (extracted from the 2.1.173 binary), not `claude-code/…`; cclimit now sends the exact
> string, but the corrected UA alone did not lift an active penalty, so the bucket looks
> account-keyed, sized for Claude Code's own modest pattern. Claude Code never *shows* the
> problem because it learns utilization from response headers on normal message traffic and
> its `fetchUtilization` falls back to cache on 429 — its /usage screen can render cached
> data straight through a penalty. Consequence for cclimit: polls are a shared, scarce
> resource; cadence must stay conservative and Retry-After must always be honored.

## Phase 0 — Verify before code (~1 hour, Matyas-gated)

The permission classifier blocks the agent from reading the Keychain credential, so this is manual:

1. Run the appendix checklist in product.md: credential shape, endpoint response with correct
   headers, note the plan's window shape (which per-model fields are `null`).
2. Save the (redacted) JSON payload as a test fixture — it seeds the decoding tests.
3. `brew install --cask` Claude God — benchmark + energy/UX reference for the whole build.
4. Confirm Apple Developer account is active (signing gate for v0.1).

**Kill criterion:** endpoint 403s on this account or shape differs materially from the doc → stop,
re-deliberate data source (Option B) before writing Swift.

## Phase 1 — v0.1 core gauge (one focused weekend)

Xcode project: Swift 5.10+, SwiftUI, `MenuBarExtra`, target macOS 14, no dock icon (LSUIElement).

Build order (each step leaves the app runnable):

1. **CredentialStore** — read-only Keychain (`Claude Code-credentials`) → file fallback
   (`~/.claude/.credentials.json`). Token in memory only. On 401: re-read store (piggyback on
   Claude Code's own refresh) — no own refresh flow in v0.1.
2. **UsageClient** — `GET /api/oauth/usage` with required headers; tolerant `Codable` (every field
   optional); unit tests against the Phase-0 fixture incl. `null` per-model windows.
3. **PollScheduler** — 60–120 s active / 5–10 min idle; exponential backoff 60 s → 5 min cap on
   429 with circuit breaker; pause on screen lock / battery+idle. This module embodies the
   non-negotiable politeness constraints — test it with a mocked clock.
4. **SampleStore** — append every successful poll `(timestamp, window, utilization, resets_at)` to
   a local file (JSONL or SQLite, whichever is less code). Non-sensitive numbers only. This is the
   v0.2 forecast's and v1.0 attribution's raw material — it ships in v0.1 so history exists.
5. **Menu bar icon** — color state (green <70 / amber 70–89 / red ≥90) on the more-utilized
   window; monochrome template variant; optional `42% · 1h13m` text mode.
6. **Popover** — 5 h + weekly rows (bar, %, absolute reset + countdown); per-model rows when
   non-null; footer: last-updated, refresh, settings, quit.
7. **Failure states** — implement the full matrix from product.md §5 (grey-never-stale-green,
   staleness labels, onboarding card for missing creds, Keychain-consent explainer).
8. **Notifications** — 75 % / 90 % thresholds, once per window per threshold.
9. **Ship plumbing** — launch at login (`SMAppService`), hardened runtime, Developer ID sign +
   notarize, `.dmg`. Test on clean user account (first-launch Keychain consent) + both arches.

**Exit:** public GitHub repo (MIT, honest README incl. OAuth-policy note), tagged v0.1.
**No promotion** — the launch channels are reserved for v0.2.

## Phase 2 — v0.2 the wedge (1–2 weeks calendar, needs live usage data)

1. **Forecast engine** (design settled — D2b):
   - *5 h window:* burn-detector (utilization moving across ≥3 recent polls) gates the forecast.
     Output is a **verdict**: "At this pace: wall in ~40 min — before reset (1 h 10 m)" vs
     "Pace is fine — reset arrives first." No forecast shown when idle.
   - *Weekly:* two-pace band (revised 2026-07-15 on Matyas's ask for hour estimates):
     sustained trailing pace vs recent (6 h) pace, both projected to the cap; the band
     between the ETAs is the estimate, floor/ceil to whole hours. Steady pace → tight
     band rendered hour-precise ("cap ≈ tomorrow 14:00"); erratic pace → wide band that
     falls back to day names past 48 h of spread ("Thu–Sat"). Single pace gets a ±15%
     stripe. Precision is earned by the data — the original "never hour-precision"
     rule survives as the wide-band fallback, not as a blanket ban.
   - Unit-test against synthetic burn patterns (steady, bursty, idle-then-spike, reset rollover).
2. **Predictive notification** — fires once per window, only on a "you won't make it" verdict,
   ≥15 min lead. This notification firing is the launch GIF.
3. **Settings pane** — poll interval, thresholds, icon style, credential source.
4. **Distribution** — Homebrew cask (`1fc0nfig/tap/cclimit`), Sparkle auto-updates (fast-release
   muscle is the mitigation for the undocumented endpoint).
5. **Dogfood gate:** ≥1 week of real use where the forecast never felt wrong before launching.

**Exit = public launch**, in product.md §8 order: README GIF → r/ClaudeAI + r/ClaudeCode (forecast
angle) → Show HN → X → cask/awesome lists → build-log post on cernymatyas.com. Matyas fires the
posts.

## Phase 3 — v1.0 the moat (after launch feedback)

1. **JSONL feasibility spike (1 day, do first):** parse own `~/.claude/projects/**/*.jsonl`;
   verify per-project/per-session *relative* burn shares are derivable at useful fidelity.
   Attribution needs relative shares only — server-truth stays with the OAuth endpoint.
2. **Fleet attribution** — popover section: "today's window by project/session"
   ("gitsocket runner ate 60 % of today's window"). Wave-2 post when it ships: "now it tells you
   *which agent* ate your window."

**Non-goals (unchanged from product.md §7):** multi-account, cost analytics, Windows/Linux,
statusline, iOS. Peak-hours badge: cut entirely.

## Open items (deliberation leaves — full text in `.deliberation/cclimit-shape/LEAVES.md`)

- **[judgment]** Launch at v0.2 (hook, assumed here) vs hold for v1.0 (moat in the launch post).
- **[fact]** Phase 0 checklist not yet run on this machine.
- **[fact]** Apple Developer account assumed active from MacSnap.
- Auto-crossed for review: build (hybrid) · session-aware forecast · quiet-v0.1 sequencing.
