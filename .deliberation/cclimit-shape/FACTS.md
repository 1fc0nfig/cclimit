# Facts

- **Endpoint spec** — `GET https://api.anthropic.com/api/oauth/usage`, requires
  `User-Agent: claude-code/<version>` + `anthropic-beta: oauth-2025-04-20`; per-token rate limits,
  429s without Retry-After. Source: docs/product.md §3 (community threads anthropics/claude-code
  #30930, #31021, #31637; Maciek-roboblog/Claude-Code-Usage-Monitor #202). Date: 2026-07-15.
  Status: NOT yet verified on this machine (permission-blocked; see LEAVES #5).
- **Credential location** — Keychain service `Claude Code-credentials`, JSON with
  claudeAiOauth.{accessToken,refreshToken,expiresAt,scopes}; file fallback
  ~/.claude/.credentials.json. Source: docs/product.md §3. Date: 2026-07-15. Unverified locally.
- **`user:profile` scope required** for the usage endpoint; `claude setup-token` creds (inference
  only) get 403. Source: docs/product.md §3.
- **Local JSONL diverges from server truth** for limits (e.g. 1.4% local vs 12% server) — usable
  only for relative attribution, never limits. Source: docs/product.md §3 Option D.
- **Competitive set** — 8 direct free competitors; none lead with prediction; Claude God most
  polished. Source: docs/product.md §2. Date of survey: as of doc writing.
- **OAuth third-party policy (Feb 2026)** — enforcement seen against third-party *inference* use;
  read-only usage-metadata calls are gray-zone-lowest-risk. Source: docs/product.md §6.
- **Matyas has shipped native Swift before (MacSnap)** — stack risk low. Source: docs/product.md §4.
