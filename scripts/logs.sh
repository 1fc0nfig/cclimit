#!/bin/bash
# Watch cclimit's poll activity in the macOS unified log.
#
#   scripts/logs.sh                # live stream (Ctrl-C to stop)
#   scripts/logs.sh --last 1h      # replay the last hour of history
#   scripts/logs.sh --last 30m
#
# Shows every poll: which source answered, the utilization, the next-poll interval, any
# 429 + its Retry-After, supplement (per-model) outcomes, and popover-open refreshes.
# Nothing sensitive is logged — utilization numbers and HTTP statuses only, never the token.

# Single-line predicate on purpose: a backslash-continued predicate inside quotes is passed
# literally to `log` and silently matches nothing.
PRED='eventMessage CONTAINS "probe " OR eventMessage CONTAINS "next poll" OR eventMessage CONTAINS "supplement" OR eventMessage CONTAINS "RATE LIMITED" OR eventMessage CONTAINS "popover open" OR eventMessage CONTAINS "manual refresh"'

if [ "$1" = "--last" ]; then
  log show --last "${2:-1h}" --info --debug --predicate "$PRED"
else
  echo "Streaming cclimit poll log (Ctrl-C to stop)…"
  log stream --level debug --predicate "$PRED"
fi
