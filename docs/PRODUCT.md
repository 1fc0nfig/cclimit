# CClimit

**A native macOS menu bar utility that shows your Claude Code usage limits — the 5-hour window, the weekly cap, and time to reset — at a glance, before you hit the wall.**

Tagline candidates:

- *"Know before you hit the wall."*
- *"Your Claude limits, always in sight."*
- *"See the wall before it sees you."*

**Name: CClimit** — domain **cclimit.app** (purchased). The "cc" prefix is the established community shorthand for Claude Code (ccusage, ccstatusline, …), so the name is instantly parseable by the target audience, is search-friendly, and avoids the "Claude" trademark issue (see Risks). Styling convention to keep consistent everywhere: **CClimit** in prose/UI, `cclimit` for the binary, cask, repo, and bundle-id suffix (`com.cernymatyas.cclimit`). Names considered earlier: Headroom, Kvóta, Windowsill, BurnBar.

---

## 1. The problem

Claude Code subscription plans (Pro/Max) enforce two rolling limits: a **5-hour session window** and a **7-day weekly cap**, with additional per-model weekly caps (Sonnet/Opus) on some plans. Hitting either one mid-session hard-stops your work with no warning. Checking usage means running `/usage` inside a session or opening claude.ai — friction every time you wonder how much is left. There is also **peak-hour throttling** (weekdays, roughly 5–11 AM PT per recent reports), which makes limits even less predictable.

For someone running multiple agents in parallel (headless runners, worktrees, orchestrated sessions), burn rate is invisible until it isn't.

## 2. Market reality check (do this with eyes open)

This niche is **crowded**. Existing tools, all found in a single search:

| Tool | Approach | Notes |
|---|---|---|
| Claude God (claudegod.app) | Swift, OAuth creds, ring gauges, cost analytics | Most polished; Homebrew cask; free/OSS |
| Claude Usage Tracker (hamed-elfayome) | Swift/SwiftUI, Keychain, multi-profile | Very feature-rich, signed, auto profile switching |
| ClaudeMeter (eddmann) | Swift, session-key based | JSON export for statuslines |
| ClaudeUsageBar | Session cookie from claude.ai | Manual cookie paste = fragile |
| Usagebar (usagebar.com) | Menu bar, 5h + weekly + reset timers | |
| Claude Usage Barometer | SwiftBar/xbar plugin, pure Bash | Zero-build, reads Keychain token |
| CodexBar (steipete) | Multi-provider usage bar | Claude is one source among many |
| linuxlewis/claude-usage | Swift, manual credential paste | |

**Implication:** don't build this expecting to win on "shows a percentage in the menu bar." Build it (a) as a fast, scoped personal tool + portfolio piece, and (b) differentiate on one wedge nobody nails (see §7). Alternatively, seriously consider just installing Claude God and moving on — writing this doc forces that honest question. If the answer is still "build," the wedge is **burn-rate forecasting + agent-fleet awareness**.

## 3. Getting the data

### Option A — OAuth usage endpoint (recommended)

The same endpoint that powers Claude Code's own `/usage` command:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth_access_token>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/<version>
Content-Type: application/json
```

Response shape (as documented by the community):

```json
{
  "five_hour":        { "utilization": 33.0, "resets_at": "2026-04-11T07:00:00Z" },
  "seven_day":        { "utilization": 13.0, "resets_at": "2026-04-17T00:59:59Z" },
  "seven_day_opus":   null,
  "seven_day_sonnet": { "utilization": 1.0,  "resets_at": "2026-04-16T03:00:00Z" },
  "extra_usage":      { "is_enabled": false }
}
```

This is **server-side authoritative** — correct across devices, unlike local JSONL parsing. Critical operational facts learned from community issue threads:

- **The `User-Agent: claude-code/<version>` header is required.** Without it you land in an aggressively rate-limited bucket and get persistent 429s.
- Rate limiting is **per access token** and the endpoint 429s hard if polled too often; multiple open issues (anthropics/claude-code #30930, #31021, #31637) document 429 storms with no Retry-After header. Poll conservatively: every **60–120 s while a session is active, 5–10 min when idle**, with exponential backoff and a circuit breaker on 429.
- **This endpoint is undocumented.** It can change or disappear. Treat it as a soft dependency and design graceful degradation (see §5, §8).

**Credentials — where to find them:**

- macOS Keychain, generic password, service **`Claude Code-credentials`** (verify locally: `security find-generic-password -s "Claude Code-credentials" -w`). Value is JSON: `{"claudeAiOauth": {"accessToken": "sk-ant-oat01-…", "refreshToken": "sk-ant-ort01-…", "expiresAt": …, "scopes": ["user:inference", "user:profile"]}}`.
- Fallback file: `~/.claude/.credentials.json` (same JSON; used on Linux and headless setups).
- Access tokens are **short-lived** (order of an hour); on 401, refresh via the OAuth refresh token (community reports the token endpoint expects **form-encoded** bodies per RFC 6749). Alternatively, the lazy-but-robust path: on 401, just re-read the Keychain — Claude Code itself refreshes the token whenever you use it, and CClimit can piggyback on the freshest stored value. Start with piggybacking; add own refresh only if staleness is a real problem in practice.
- Keychain ACL gotcha: reading another app's Keychain item triggers a **one-time user consent dialog** ("CClimit wants to access…"). Expected; explain it in onboarding. Also note Keychain reads fail in non-GUI contexts (SSH/tmux daemons) — irrelevant for a menu bar app, but relevant if a CLI companion is ever added.
- The `/api/oauth/usage` endpoint reportedly requires the `user:profile` scope — normal `/login` credentials have it; long-lived `claude setup-token` credentials (`user:inference` only) get 403.

### Option B — rate-limit headers from a minimal inference call (fallback)

A tiny `POST /v1/messages` call returns `anthropic-ratelimit-unified-5h-utilization` / `-reset` style headers with the subscription's unified limits. Costs ~1 token per poll and works with `user:inference`-scoped setup tokens. Downsides: it consumes (a hair of) quota, doesn't expose per-model weekly windows, and polling with inference calls to measure inference limits is aesthetically cursed. Keep as a documented fallback only.

### Option C — claude.ai session cookie

What ClaudeUsageBar does. Requires the user to manually paste a browser cookie; breaks on logout/rotation. **Rejected** — worst UX of the three.

### Option D — local JSONL parsing (ccusage-style)

Parse `~/.claude/projects/**/*.jsonl` and estimate windows locally. Fast and offline, but community testing shows it's **wrong across devices** (window boundaries and utilization diverge from server truth; e.g. local 1.4% vs server 12%). Use only as an *enrichment* layer (per-project/per-model burn attribution, cost estimates), never as the source of truth for limits.

**Decision: A as source of truth, D as optional enrichment, B as break-glass fallback.**

## 4. Presenting the data

**Stack:** native Swift + SwiftUI, `MenuBarExtra` (macOS 13+; target macOS 14 to keep API modern). No Electron — this category lives or dies on being invisible until needed. You've shipped native Swift before (MacSnap); same muscle.

**Menu bar icon** (the whole product in ~22 px):

- Compact dual indicator: a small two-segment bar or a percentage of the *more constrained* window. Color state: green < 70 % used, amber 70–89 %, red ≥ 90 % — matching the convention users already know from competing tools.
- Optional text mode: `42% · 1h13m` (utilization of the binding window + time to its reset).
- Monochrome template-image variant for people who hate colorful menu bars.

**Popover (one click):**

- Two rows — **5-hour window** and **weekly cap** — each with a progress bar, % used, and absolute reset countdown ("resets 17:00, in 1 h 13 m").
- Per-model weekly rows (Sonnet/Opus) when the API returns them; hidden when `null`.
- **Burn-rate forecast** (the wedge): from the last N polls compute utilization slope and show *"At this pace: weekly cap Thursday ~14:00"* or *"Pace is fine — window resets before you'd hit it."* Nobody in the table above leads with prediction; they all show the present.
- Peak-hours hint: subtle badge during the reported weekday 5–11 AM PT throttling band ("peak window — limits may be tighter").
- Footer: last-updated time, manual refresh, settings, quit.

**Notifications** (UserNotifications framework): thresholds at 75 % and 90 % per window (configurable), plus one *predictive* notification: "You'll hit the 5-hour limit in ~20 min at current pace." Never notify more than once per window per threshold.

**Settings:** poll interval, thresholds, icon style, launch at login (`SMAppService`), credential source (auto: Keychain → file fallback).

## 5. Making sure everything is OK (reliability, security, correctness)

**Failure-mode matrix — every state must render as something honest, never a stale green:**

| State | Behavior |
|---|---|
| 401 (token expired) | Re-read Keychain (Claude Code likely refreshed it); if still stale, attempt refresh-token flow; else icon → grey `!` with "Sign in via `claude` to reconnect" |
| 429 (rate limited) | Exponential backoff (60 s → 5 min cap), show last data with "stale · Xm ago" label, never hammer |
| Network offline | Grey icon, cached data with staleness label |
| Endpoint schema change / 404 | Grey icon + "usage API changed — update CClimit"; app must not crash on unknown JSON (tolerant decoding, all fields optional) |
| No credentials found | Onboarding card: "Install Claude Code and run `claude` once to log in" |
| Keychain consent denied | Explain why access is needed; offer the file-fallback path |

**Security posture (also a marketing asset — see §9):**

- Read-only: CClimit never writes to Claude Code's Keychain item or credentials file (community bug #37512 shows how easily tools clobber each other's credentials — don't be that tool).
- Tokens live in memory only; nothing is persisted by CClimit except non-sensitive usage history (utilization numbers) for the forecast.
- Zero telemetry, no analytics, no network calls except `api.anthropic.com`. Open source so this is verifiable.
- App Sandbox where feasible; hardened runtime; **Developer ID signed + notarized** (unsigned menu bar apps reading Keychain tokens is a terrible look, and Gatekeeper friction kills casual installs).

**Correctness checks:**

- Cross-validate against `/usage` in Claude Code during development; the numbers must match, since it's the same endpoint.
- Unit-test the JSON decoding against captured real payloads including `null` per-model windows and `extra_usage` variants.
- Test the full lifecycle: fresh login → hour of use → token expiry → refresh → limit hit → reset rollover (mock the clock).
- Energy: adaptive polling (pause when screen locked / on battery + idle), no timers hotter than needed — Claude God's changelog shows energy regressions are a real trap in this category.

**Distribution QA:** notarize, test on Intel + Apple Silicon, test first-launch Keychain prompt on a clean user account, Homebrew cask tap from day one (`brew install --cask 1fc0nfig/tap/cclimit`).

## 6. Risks

1. **Undocumented endpoint.** `/api/oauth/usage` is not a public API; Anthropic can change or gate it any day. Mitigation: tolerant parsing, loud-but-graceful degradation, Option B fallback, and fast-release muscle (Sparkle auto-updates).
2. **OAuth-token policy.** Anthropic introduced an explicit policy (reported Feb 2026) on how Claude Code OAuth tokens may be used by third-party tools, and has enforced against third-party *inference* use. CClimit performs read-only usage-metadata calls with the user's own token on their own machine — the lowest-risk use — but this is a gray zone. State it plainly in the README; don't oversell.
3. **Crowded market.** Eight direct competitors, some excellent. Mitigation: the forecast wedge, ruthless simplicity, and honest expectations (§2). Worst case: great portfolio piece for the job search, genuinely useful daily tool.
4. **Naming/trademark.** Don't put "Claude" in the product name or domain; "for Claude Code" as descriptive text only. (Half the competitors ignore this; don't copy them.)
5. **Endpoint rate limits punish exactly this use case** (documented 429 issues). Conservative polling is non-negotiable.

## 7. MVP scope

**v0.1 (one focused weekend):** MenuBarExtra icon with color state · Keychain + file credential discovery (read-only) · poll `/api/oauth/usage` with correct headers + backoff · popover with 5 h / weekly bars and reset countdowns · 90 % notification · launch at login · signed + notarized `.dmg`.

**v0.2:** burn-rate forecast + predictive notification · per-model weekly rows · Homebrew cask · Sparkle updates · settings pane.

**v1.0 wedge:** agent-fleet awareness — attribute burn to projects/sessions via local JSONL enrichment ("gitsocket runner ate 60 % of today's window"), which no competitor does and which matches the multi-agent-orchestration story you're already telling in job applications.

**Explicit non-goals (v1):** multi-account profiles, cost/dollar analytics, Windows/Linux, statusline integration, iOS companion. Competitors do these; CClimit stays a gauge that predicts.

## 8. Marketing

**Positioning statement:** *For developers running Claude Code hard — especially in parallel and agentic workflows — CClimit is the menu bar gauge that doesn't just show your usage, it tells you when you'll run out. Unlike existing trackers that report the present, CClimit forecasts the wall.*

**Three message pillars:**

1. **Predictive, not reactive.** "Every usage tracker shows you a percentage. CClimit shows you *Thursday, 14:00* — the moment you'll hit the weekly cap at your current pace."
2. **Trust by architecture.** Read-only, Keychain-native, zero telemetry, open source, signed & notarized. One sentence of threat model on the landing page beats ten badges.
3. **Native and invisible.** < 5 MB, SwiftUI, no Electron, no dock icon, negligible energy use.

**Landing page skeleton** (single page at **cclimit.app**):

- Hero: menu bar screenshot with the amber bar + one line: *"See the wall before it sees you."* + `brew install` one-liner.
- Three-panel: forecast popover / notification screenshot / security blurb.
- Honest FAQ: "How does it get my data?" (endpoint + read-only token, plainly), "Is this affiliated with Anthropic?" (no), "Why not [competitor]?" (link to them — confidence sells; the wedge is the forecast).

**Launch channels, in order of expected yield:**

1. **GitHub + README GIF** — this category spreads via "found it on GitHub." A 10-second GIF of the forecast notification firing is the whole pitch.
2. **r/ClaudeAI and r/ClaudeCode** — Usagebar's own testimonial cites Reddit as its discovery channel; post the *forecast* angle, not "another usage tracker" ("I made my menu bar predict when I'll hit the Claude weekly cap").
3. **Hacker News (Show HN)** — lead with the technical wedge: predicting rolling-window exhaustion from utilization slope; HN loves the "undocumented endpoint archaeology" story told responsibly.
4. **X/Twitter dev community** — tag the ecosystem (steipete's CodexBar audience overlaps 100 %); short screen recording.
5. **Homebrew cask + awesome-claude-code lists** — long-tail discovery.
6. Personal angle: a build-log blog post on cernymatyas.com ("Building a native macOS gauge for Claude Code limits") doubles as job-search portfolio evidence for the agentic-tooling positioning.

**Pricing:** free and open source (MIT). This market has excellent free incumbents; charging is a losing fight. The ROI is daily utility + portfolio + distribution surface. If a paid tier ever makes sense, it's the v1.0 fleet-awareness layer for teams — decide later, never gate the gauge.

**Success metrics (90 days):** 500 GitHub stars, 1 000 installs via cask analytics, one front-page community post, and — the real one — you stop getting surprised by limits.

---

## Appendix: verification checklist before writing code

```bash
# 1. Confirm credential location and shape on this machine
security find-generic-password -s "Claude Code-credentials" -w | jq .

# 2. Confirm the endpoint responds for your account (note the UA header!)
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w \
  | jq -r .claudeAiOauth.accessToken)
curl -s https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-code/2.1.0" | jq .

# 3. Cross-check numbers against /usage inside Claude Code
# 4. Note your plan's windows (Pro vs Max) — UI must handle nulls
```

Sources worth keeping open during the build: anthropics/claude-code issues #30930, #31021, #31637 (rate limiting), #9403/#44089 (Keychain behavior), Maciek-roboblog/Claude-Code-Usage-Monitor #202 (endpoint spec), steipete/CodexBar #1894 (header-based fallback).
