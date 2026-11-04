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
> **Update 2026-10-07 — Keychain prompt removed for good.** The prompt still came back every
> ~15 min. Root cause, read from the item's ACL (`security dump-keychain -a`): every
> `CClimit.app` entry failed validation (status -2147415734), so "Always Allow" never stuck,
> and Claude Code rewrites the item on each token refresh. The only entry that always
> validates is `/usr/bin/security`, the tool Claude Code uses to write the item. Fix:
> `SecurityToolCredentialSource` runs `security find-generic-password -s … -w` and is now
> first in the default chain. The direct `SecItemCopyMatching` source stays in the code but
> is out of the chain. No prompt, independent of signing identity (issue #3 no longer gates
> this).
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

> **Update 2026-10-23: multi-account.** Matyas asked for it, so this item is no longer a
> non-goal. Claude Code keeps each login in its own Keychain item. The default login uses
> `Claude Code-credentials`. A login made with `CLAUDE_CONFIG_DIR` set uses
> `Claude Code-credentials-<first 8 hex of sha256(dir)>` (binary fn `vj`). `AccountDiscovery`
> reads the item names with `security dump-keychain`, which shows no secrets and no dialog.
> It skips items without a `claudeAiOauth` block, because Claude Code also stores MCP-only
> items under the same name. It maps each hash back to a config dir: it scans dirs named
> like "claude" in `~` and `~/.config`, and `CLAUDE_CONFIG_DIR=` values in shell startup
> files. The dir gives the name ("Work" for `~/.claude-work`) and the email in
> `<dir>/.claude.json`. Each login gets an `AccountMonitor`, which holds the old per-account
> `AppState` logic. `AppState` is now the container: discovery every 10 min, selection,
> names, and show/hide. The popover gets a segmented switcher (All + one segment per
> account) when two or more accounts show. "All" shows a pooled 5h + weekly reading,
> weighted by plan (Pro 1, Max 5x 5, Max 20x 20, from `rateLimitTier`), then one compact
> row per account. The menu bar icon follows the switcher. A login whose token expired more
> than 7 days ago starts hidden. The default login keeps its original data files, and other
> logins use `samples-<hash>.jsonl` and `per-model-<hash>.json`. Debug:
> `swift run cclimit-dump --accounts` lists the logins. A debug build with
> `CCLIMIT_RENDER_POPOVER=/dir` renders the popover with demo accounts.

> **Update 2026-10-23 (later): forecast on the bars, project range.** Matyas said the
> forecast read as plain text. The forecast section is gone. Each window bar now draws a
> faint extension to where the window lands at reset at the current pace
> (`ForecastEngine.*Projection` returns a `Projection`). The row shows "→ 63% at reset" for a
> calm pace. When the limit runs out before reset, the row shows a red warning line with the
> time. Idle windows show nothing extra. The project breakdown no longer resets with each 5h
> window only: a menu in its header picks this window, today, the last 7 days (calendar days that
> end with today), or the last 30 days (`AttributionRange`, key `attributionRange`). It shows the top
> five projects, folds the rest into one row, and shows the token total.

> **Update 2026-10-23 (later): project stats.** The project section is now a small stats
> panel. It shows an activity chart for the range, with the hovered project lit in the
> accent color, and rows with token counts. A click on a row opens its sessions, model mix,
> subagent share, and input, output, and cache-write split. Two counting fixes: Claude Code
> writes each response once per content block, so cclimit now counts a message once (key
> sessionId + message.id + requestId). Before this fix, counts ran about 3x high. Projects
> are named after their repository: a worktree path (`.claude/worktrees/…`) or a subfolder
> counts toward the repository. `TranscriptIndex` (an actor) keeps 15-minute slices per
> file in Application Support (`transcripts<suffix>.plist`) and parses only appended bytes.
> On this Mac, 30 days is 4.8 GB of transcripts: the first scan takes about 58 s, later
> scans take 0.5 s. Debug: `swift run -c release cclimit-dump --projects month`.

> **Update 2026-10-25: native look, two fixes.** Matyas said the popover did not look
> native. The activity chart now uses Swift Charts in a Screen Time style: accent bars,
> dashed hour grid, a token axis, and the full day or week as the x range. The header shows
> "Projects" and a range menu, then the range total in large type. Project rows keep their
> short grey share bar. The bar extension keeps the fill's own color, and
> the run-out warning is secondary text with an orange icon. Fix 1: a `MenuBarExtra` window
> keeps its view alive, so `onAppear` ran on the first open only and the stats went stale.
> The popover now also refreshes when its own window becomes key. Fix 2: a burst pace now
> counts only when it reaches the cap within 36 h (`maxBurstHorizon`). Past that, the
> sustained pace decides. Before this fix, one busy morning at 11% raised a warning for
> four days out.
>
> A second pass follows the Wi-Fi and Battery menus. The popover has a bold "Claude Code"
> title with the plan on the right. Window titles use the menu text size. "Projects" and
> "Pooled" are grey section headers. The range total is caption text. The footer keeps
> its three icons. On macOS 26 and later they are round Liquid Glass buttons
> (`.buttonStyle(.glass)`), with ⌘R, ⌘, and ⌘Q.
>
> Third pass, from the `swiftui-expert-skill` and `swiftui-liquid-glass` skills: the popover
> follows Control Center. Limits and projects each sit in a rounded module (a quiet fill,
> not glass: glass is for controls, and glass on glass reads muddy). Usage bars are the
> system linear `ProgressView`, tinted on the state ramp. The forecast is text only. The
> footer buttons share one `GlassEffectContainer`. Debug: `CCLIMIT_RENDER_LIVE=1` with
> `CCLIMIT_RENDER_POPOVER=/dir` shows each render on screen and captures the composited
> window, so glass draws. It needs screen recording permission.
>
> **Update 2026-10-25 (later): add accounts, replaced logins, usage through Claude Code.**
> Research (T3 Code, Claude Usage Tracker, CodexBar, claude-swap, Anthropic docs): the
> good tools give each account its own `CLAUDE_CONFIG_DIR` and let Claude Code do the
> login. Anthropic forbids third parties to collect or store Claude credentials.
>
> - Add Account (Settings > Accounts): a sheet takes a name, creates `~/.claude-<slug>`,
>   and opens Terminal on `CLAUDE_CONFIG_DIR=… claude auth login` through a `.command`
>   file (no AppleScript). An optional checkbox adds a `claude-<slug>` alias to the login
>   shell's rc file. cclimit checks the Keychain item names every 3 s for 10 min and names
>   the new account. Created folders persist in `accountFolders`. Logic: `AccountSetup.swift`.
> - Replaced logins: discovery saves each account id's UUID in `accountIdentities`. When
>   `/login` puts another account into a folder, the old one goes to `replacedLogins` and
>   Settings shows it with "Add Back…".
> - Usage through Claude Code (`ClaudeCodeUsage.swift`), as T3 Code does it: cclimit runs
>   `claude -p --output-format stream-json --input-format stream-json` with hooks, MCP,
>   IDE, and session saving off, and sends the `initialize` and `get_usage` control
>   requests. The answer is the usage endpoint payload, and cclimit reads no token.
>   `get_usage` spends the usage endpoint's small budget, which Claude Code's `/usage`
>   shares. So Settings > General > Usage source "Through Claude Code" reads every 10
>   minutes, and discovery reads no secret (login and plan come from `.claude.json`).
>   "Directly" (the default) keeps the token-based header probe every minute. Its 15-minute
>   per-model call now also goes through Claude Code. Debug: `cclimit-dump --via-claude [dir]`.
> - Popover padding is smaller: 8 pt outside, 11 by 9 pt inside the modules.
> - Sparkle starts only in a bundle with a feed URL. In a bare debug binary it raised an
>   error alert that blocked the live renders.
>
> **Update 2026-10-25 (evening): All follows Layout, window fits content.** The All screen
> shows the same sections as one account (Settings > Layout), pooled: the 5-hour, weekly,
> and model windows (Fable pools only the accounts that have it), and the projects of all
> visible accounts merged (`UsageReport.merge` lines the bars up on one grid). Layout has a
> "Show each account on the All screen" switch (`poolShowsAccounts`). The MenuBarExtra
> window grows with its content but never shrinks, and it moves sideways on growth. So the
> popover measures its content and sets the window frame itself: top under the menu bar,
> left edge where it opened (`PopoverAnchor`). No animation on tab switches or resizes:
> Matyas tried both and rejected them. Live check: `/tmp/cclimit-postest/cycle.sh` clicks
> the real popover and checks every frame.
>
> Open speed: the Keychain read (`/usr/bin/security`) now runs off the main thread. The
> project stats refresh every 5 minutes in the background (`statsTimer` in `AppState`), so
> the popover opens on finished numbers. While a scan runs, the stats area keeps the chart's
> height, so the popover does not grow after it opens.

> **Update 2026-10-31: no 5-hour limit on Ultra, CLI proxy accounts.** Anthropic removed the
> 5-hour limit from Ultra (the new name of Max 20x). The weekly limits stay. The rollout goes
> account by account: on this Mac the Ultra login lost the window, and the other login still
> has it. On an account without the window, the usage endpoint sends `five_hour: null` and no
> `session` entry in `limits[]`. The rate-limit headers drop `5h` too. So cclimit decides per
> account, from its own reading (`UsageSnapshot.lacksFiveHour`):
>
> - The popover drops the 5-hour row, and the weekly cap leads.
> - The account row on the All screen shows Week and the fullest model cap instead of 5h.
> - The pooled 5-hour bar counts only the accounts that still have the window.
> - The menu bar icon: stacked bars show weekly and the fullest model cap. A 5h bar in a
>   composition drops out. The "5-hour window" icon source reads the weekly cap.
> - The project range "This 5-hour window" reads as Today, and the menu hides it.
> - Poll cadence watches the weekly cap for activity when the 5h window is gone.
> - A cached payload from before the change no longer brings an old 5h window back.
> - The plan label "Max 20x" is now "Ultra". The tier strings `max_20x` and `ultra` both map to it.
>
> CLI proxy (Settings > Accounts > CLI Proxy): cclimit connects to a CLIProxyAPI server through
> its management API. The address goes to UserDefaults (`proxyURL`). The management key goes
> to the Keychain item "CClimit CLI Proxy", written and read through `/usr/bin/security`.
> `auth-files` lists every login, and the proxy keeps the rate-limit headers of the last
> response per login (`quota.signals`). These give 5h and weekly at no cost. `api-call` makes
> the proxy call the usage endpoint with the login's own token, for the per-model windows,
> on the supplement's 15-minute schedule and backoff. The token never leaves the proxy. A
> proxy login with the same email as a local login merges into that account, and the proxy
> becomes its usage source, so the Mac sends no probe for it. Other proxy logins become
> accounts of their own (`proxy-<auth_index>`), with no transcripts and an unknown plan.
> The proxy bans an IP after a few wrong keys and extends the ban on each try. So
> `ProxyHub` stops all calls after a rejected key until the settings change, and waits out
> a ban. Debug: `CCLIMIT_PROXY_KEY=… swift run cclimit-dump --proxy <url> [--full]`, and
> `cclimit-dump --account <id>` dumps the raw payload of one login.

> **Update 2026-11-04: proxy traffic in Projects, proxy auto-detection, API-price estimates.**
> Matyas moved his Claude Code to CLIProxyAPI (`~/.claude-cliproxy`, `ANTHROPIC_BASE_URL` in its
> `settings.json`). Its transcripts then went to `~/.claude-cliproxy/projects`, which no account
> owned, so Projects lost almost all activity. The fixes form one system:
>
> - **Proxy routes** (`ProxyDetection`): a config dir counts as routed when its `settings.json`
>   sets `env.ANTHROPIC_BASE_URL`, or a shell file exports it, to a non-Anthropic host. The scan
>   reuses the account discovery's candidate dirs. A keyless `GET /` answers
>   `"message": "CLI Proxy API Server"` on CLIProxyAPI, so the check can never trip the ban.
> - **Transcript pool**: routed dirs that no local login owns form one `TranscriptIndex` with
>   several roots (`transcripts-proxy.plist`). The proxy picks the login per request, so this
>   traffic belongs to no single account. The pool joins "All", the only account, and accounts
>   the proxy serves (`AppState.showsProxyTranscripts`). It counts once in a merge.
> - **`TranscriptReports`**: the per-page report cache moved out of `AccountMonitor`, so an
>   account and the pool share one implementation.
> - **Setup**: the popover shows "Claude Code uses a CLI proxy at host:port. Connect" while
>   cclimit is not connected. Connect opens Settings > Accounts with the address filled in and
>   the key field focused. Dismiss hides it for that address. The management key stays the one
>   input: the proxy keeps only its bcrypt hash.
> - **ATS**: the bundle had no `NSAppTransportSecurity`, so every `http://` proxy load failed,
>   the Settings connect included. `make-app.sh` now sets `NSAllowsArbitraryLoads`: the proxy is
>   a host the user picks, usually plain http on a LAN or tailnet.
> - **Prices** (`Pricing`): each response is priced at API list price as it is parsed: per model,
>   input, output, cache reads, 5-minute and 1-hour cache writes, fast mode, the Haiku 5.5
>   long-prompt rate. Unknown models cost $0, never a guess. Slices carry `read` and `cost`
>   (store version 2, one re-index). The summary, the hovered bar, each project row and its
>   detail show "≈ $". The chart's y axis stays in tokens, to match the limits.
>
> Debug: `cclimit-dump --proxy-routes`, `cclimit-dump --projects week --root <projects dir>`, and
> `CCLIMIT_RENDER_POPOVER=<dir> CCLIMIT_RENDER_REAL=1` (debug build) renders the real popover.

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

**Non-goals (product.md §7):** Windows/Linux, statusline, iOS. Billing-style cost analytics
stay out. Dollar estimates on project stats came in on 2026-11-04. Peak-hours badge: cut entirely.

## Open items (deliberation leaves — full text in `.deliberation/cclimit-shape/LEAVES.md`)

- **[judgment]** Launch at v0.2 (hook, assumed here) vs hold for v1.0 (moat in the launch post).
- **[fact]** Phase 0 checklist not yet run on this machine.
- **[fact]** Apple Developer account assumed active from MacSnap.
- Auto-crossed for review: build (hybrid) · session-aware forecast · quiet-v0.1 sequencing.

**Status 2026-10-25, review pass (0.1.3.18):**
- Child processes (`security`, login shell, `claude`, `auth logout`) run through `ChildProcess` with a deadline, then SIGTERM and SIGKILL. A hung `claude` reads as "Claude Code did not answer", not "Offline". SIGPIPE is ignored.
- Forecasts and sample IO run off the main thread. Samples stay in memory after the first load.
- Discovery: the newest run wins. A denied Keychain read keeps a known login. An empty result keeps the known monitors. The default login always dedupes first.
- A login replaced by another account gets a fresh monitor. Its old history moves to `CClimit/Replaced`.
- Refresh during a poll runs again after it. The footer shows a spinner.
- Account order: Settings > Layout > Account order (drag). Not yet confirmed by a real drag.
- No bar animation on account switch.

**Status 2026-10-26, projects and pool (0.1.3.20):**
- Projects steps back by day (Today) or by 7 days (Last 7 days), up to 31 days. A past page loads once and stays cached.
- The index warms the full 31 days in the background at launch. A range switch then only adds up slices.
- A page that loads shows a static skeleton at the height of the real content.
- Each pooled bar splits into one slice per account, as wide as its plan weight. A limit that one account has keeps one bar.
- Forecasts setting (Layout > Forecasts): On the bars (default), As text, Bars and text, Off. On the bars draws a faded stretch to the landing point at reset, in the color of that point. Pointing at a bar swaps its caption line for the forecast (the menu bar window shows no `.help` tooltips). The All warning lines show only with text.
