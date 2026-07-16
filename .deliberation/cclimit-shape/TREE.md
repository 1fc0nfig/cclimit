# Option tree — CClimit shape decisions

## D1 — Build vs install Claude God (root rubicon)
- **D1a Build CClimit (hybrid: install Claude God NOW as daily benchmark)** — LIVE, auto-crossed (see LEAVES #1)
  - Rationale: doc's stated ROI is utility + portfolio + distribution surface; Claude God delivers
    only utility. Building is cheap (weekend timebox), reversible (stop anytime), low blast radius.
    Hybrid dominates pure-build: dogfooding a competitor daily = free design intel + honest "why
    not X" FAQ material.
  - Assumption filled: portfolio/job-search motive is live (doc cites job applications twice).
- **D1b Install Claude God, don't build** — PRUNED: forfeits portfolio + distribution goals that
  motivated the doc; utility alone is satisfiable but is not the binding goal.
- **D1c Build from scratch, ignore competitors** — PRUNED: strictly dominated by D1a (loses the
  benchmark for zero gain).

## D2 — Forecast design (the wedge's mechanism)
- **D2a Naive linear slope over last N polls, timestamp output ("Thursday ~14:00")** — PRUNED:
  usage is bursty; confidently-wrong timestamps destroy trust in the one differentiator.
- **D2b Session-aware pace + honest framing** — LIVE, auto-crossed (see LEAVES #2)
  - 5h window: detect active-burn (utilization moving across recent polls) → forecast ONLY during
    burn → output a verdict, not just a time: "At this pace: wall in ~40 min — before reset (1 h 10 m)"
    vs "Pace is fine — reset arrives first."
  - Weekly: trailing multi-day average → day-granularity range ("At this week's pace: Thu–Fri"),
    never an hour-precision timestamp.
  - Assumption filled: API utilization resolution is coarse (integer-ish %) → slope needs visible
    movement over ≥3–5 polls; fine for 5h under load, hence the burn-gate.
  - Assumption filled: predictive notification fires once per window, only when verdict = "you
    won't make it," lead time ≥ ~15 min.
- **D2c Statistical models (EWMA, hour-of-day usage profile)** — DEFERRED, not pruned: needs weeks
  of persisted samples; layer on top of D2b post-v0.2 if forecasts feel dumb in practice.
  Persistence from v0.1 keeps this branch open for free.

## D3 — Launch sequencing
- **D3a Quiet v0.1 (public repo, no promotion) → public launch at v0.2 with forecast GIF** — LIVE,
  auto-crossed (see LEAVES #3)
  - Assumption filled: repo public from day one (OSS trust-by-architecture requires it; no secret
    sauce to protect). "Launch" = the Reddit/HN/X posts, which Matyas writes/fires himself anyway —
    external actions stay with him.
- **D3b Promote v0.1 early for feedback** — PRUNED: spends the one-shot channels on
  "another usage tracker"; violates the wedge-positioning constraint.
- **D3c Hold repo private until v0.2** — PRUNED: delays cask/star long-tail for no benefit;
  contradicts open-source trust pillar.

## D4 — Fleet-attribution timing
- **D4a Keep at v1.0, but front-load prerequisites** — LIVE, depends on LEAVES #4 (judgment)
  - v0.1: persist utilization samples (already settled). Between v0.2 launch and v1.0: 1-day JSONL
    feasibility spike (parse own ~/.claude/projects, verify per-project attribution is derivable
    at useful fidelity). Attribution is *relative* burn share — doesn't need server-truth
    absolutes, which is why local JSONL is acceptable here and not for limits.
- **D4b Pull full attribution into v0.2** — PRUNED: bloats the release the launch depends on;
  JSONL multi-project parsing is the hairiest code in the app; delays the hook to ship the moat.
- **D4c Drop attribution entirely** — PRUNED: it's the only hard-to-copy differentiator and the
  job-story tie-in; forecast alone is a weekend-copyable feature.
