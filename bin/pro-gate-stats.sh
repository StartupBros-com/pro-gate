#!/usr/bin/env bash
# pro-gate-stats.sh — observability over the run ledger + ramp governor (v0.19).
#
# The engine appends one JSON line per finished/deferred run to $PRO_GATE_HOME/ledger.jsonl
# (fields: ts, pr, repo, exit, outcome, secs, attempts, conc, ceiling, live, salvaged,
# diff_lines, out) and the ramp governor keeps its level in $PRO_GATE_HOME/ramp.state.
# This tool answers "is raising concurrency causing trouble?" at a glance.
#
# Usage: pro-gate-stats.sh [--tail N] [--since ISO-DATE] [--json]
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in "$SELF/lib.sh" "$SELF/../lib/pro-gate-lib.sh" "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/lib.sh"; do
  [ -f "$c" ] && { . "$c"; break; }
done
type pg_os >/dev/null 2>&1 || { echo "ERROR: pro-gate lib not found (lib.sh)" >&2; exit 10; }
pg_load_env

LEDGER="${PRO_GATE_LEDGER:-$PRO_GATE_HOME/ledger.jsonl}"
STATE="${PRO_GATE_RAMP_STATE:-$PRO_GATE_HOME/ramp.state}"
TAIL=0; SINCE=""; AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tail) TAIL="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    --json) AS_JSON=1; shift;;
    *) echo "usage: pro-gate-stats.sh [--tail N] [--since ISO-DATE] [--json]" >&2; exit 2;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "pro-gate-stats: jq required" >&2; exit 3; }

# --json is the automation mode: ONE JSON document on stdout, no banner (v0.19.1,
# pro-gate self-review P2 — the header lines broke `pro-gate-stats.sh --json | jq`).
if [ "$AS_JSON" = 1 ]; then
  RL="$(awk -F'\t' 'NR==1{print $1}' "$STATE" 2>/dev/null)"; case "$RL" in ''|*[!0-9]*) RL=1;; esac
  RS="$(awk -F'\t' 'NR==1{print $2}' "$STATE" 2>/dev/null)"; case "$RS" in ''|*[!0-9]*) RS=0;; esac
  FILTER='.'; [ -n "$SINCE" ] && FILTER="select(.ts >= \"$SINCE\")"
  if [ -s "$LEDGER" ]; then
    jq -s --argjson level "$RL" --argjson streak "$RS" \
      --argjson ceiling "${PRO_GATE_MAX_CONCURRENCY:-1}" \
      "{ramp: {level: \$level, streak: \$streak, ceiling: \$ceiling}, runs: [.[] | $FILTER]}" "$LEDGER"
  else
    jq -nc --argjson level "$RL" --argjson streak "$RS" \
      --argjson ceiling "${PRO_GATE_MAX_CONCURRENCY:-1}" \
      '{ramp: {level: $level, streak: $streak, ceiling: $ceiling}, runs: []}'
  fi
  exit 0
fi

echo "== pro-gate observability =="
if [ -f "$STATE" ]; then
  awk -F'\t' 'NR==1{printf "  ramp:    level %s, streak %s (since %s)\n", $1, $2, $3}' "$STATE"
else
  echo "  ramp:    no state yet (level 1 until first clean runs)"
fi
echo "  ceiling: ${PRO_GATE_MAX_CONCURRENCY:-1} (PRO_GATE_MAX_CONCURRENCY)  ramp=${PRO_GATE_RAMP:-1} streak-need=${PRO_GATE_RAMP_STREAK:-5}"

if [ ! -s "$LEDGER" ]; then
  echo "  ledger:  empty ($LEDGER) — stats appear after the first v0.19 run"
  exit 0
fi

FILTER='.'
[ -n "$SINCE" ] && FILTER="select(.ts >= \"$SINCE\")"

jq -s "[.[] | $FILTER] | {
  runs: length,
  by_outcome: (group_by(.outcome) | map({(.[0].outcome): length}) | add // {}),
  success_rate_pct: (if length > 0 then (100 * ([.[] | select(.outcome == \"clean\")] | length) / length | floor) else null end),
  throttles: ([.[] | select(.outcome == \"throttle\")] | length),
  salvage_rate_pct: (if length > 0 then (100 * ([.[] | select(.salvaged == 1)] | length) / length | floor) else null end),
  duration_p50_s: ([.[] | select(.outcome == \"clean\") | .secs] | sort | if length > 0 then .[(length / 2 | floor)] else null end),
  duration_p95_s: ([.[] | select(.outcome == \"clean\") | .secs] | sort | if length > 0 then .[((length * 95 / 100) | floor)] else null end),
  by_concurrency: (group_by(.conc) | map({level: .[0].conc, runs: length,
    clean: ([.[] | select(.outcome == \"clean\")] | length),
    throttle: ([.[] | select(.outcome == \"throttle\")] | length)}))
}" "$LEDGER"

if [ "${TAIL:-0}" -gt 0 ] 2>/dev/null; then
  echo "-- last $TAIL runs --"
  tail -n "$TAIL" "$LEDGER" | jq -r '[.ts, .pr, .outcome, "\(.secs)s", "conc=\(.conc)", (if .salvaged == 1 then "salvaged" else "" end)] | @tsv'
fi
