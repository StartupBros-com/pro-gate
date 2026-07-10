#!/usr/bin/env bash
# oracle-review.sh — run a GPT-5.5 Pro Extended FINAL-TIER review of a PR (or diff) via oracle.
# Single source of truth for "how we call oracle for a review" — the /pro-gate skill and the
# daemon both call this. Cross-platform: macOS drives signed-in Chrome natively; WSL/Linux
# attaches to the durable Xvfb Chrome over CDP.
#
# CALLERS — keep in sync IN THE SAME PR whenever the caller contract changes (status file,
# exit codes, recovery semantics); they have drifted before (v0.18 missed the agent):
#   skills/pro-gate/SKILL.md      (authoritative caller guide)
#   agents/oracle-reviewer.md     (thin relay agent for other pipelines)
#
# Usage:
#   oracle-review.sh --pr <url|number> [--repo <dir>] [--input both|bundle|connector]
#                    [--out <file>] [--timeout <dur>] [--extra-files <glob>]
#   oracle-review.sh --diff <patchfile> --repo <dir> [--out <file>] ...
#   oracle-review.sh --harvest <run-marker> --out <file> [--timeout <dur>]
#       Collect a review whose run ended in-progress (exit 9): the Pro slot was spent but the
#       model was still generating when the salvage budget ran out. No new slot is spent.
set -uo pipefail

# --- locate + source the shared lib (works from repo and from deployed location) ---
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in "$SELF/lib.sh" "$SELF/../lib/pro-gate-lib.sh" "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/lib.sh"; do
  [ -f "$c" ] && { . "$c"; break; }
done
type pg_os >/dev/null 2>&1 || { echo "ERROR: pro-gate lib not found (lib.sh)" >&2; exit 10; }

pg_augment_path
pg_load_env
OS="$(pg_os)"; MODE="$(pg_browser_mode)"

PR=""; REPO=""; DIFF_FILE=""; INPUT="both"; OUT=""; TIMEOUT="30m"; EXTRA_GLOB=""; HARVEST_MARKER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --diff) DIFF_FILE="$2"; shift 2;;
    --input) INPUT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --extra-files) EXTRA_GLOB="$2"; shift 2;;
    --harvest) HARVEST_MARKER="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

PORT="${ORACLE_BROWSER_PORT:-9222}"
MODEL="${ORACLE_MODEL:-gpt-5.5-pro}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pro-review.XXXXXX")"
[ -n "$OUT" ] || OUT="$WORK/findings.md"
# Fresh runs need oracle; --harvest only needs node+CDP and checks that prerequisite inside
# its branch below (moving this gate matters when oracle is temporarily unavailable but a spent
# review is waiting in an open conversation).

# --- machine-readable run status (v0.18) ---
# Callers (the /pro-gate skill, the daemon's headless agent) poll "$OUT.status" — a
# single-line JSON updated ATOMICALLY at every phase change — instead of scraping the
# engine's stderr. Phases: preflight, waiting-pr-lock, waiting-slot, launching,
# watchdog-killed, live-detected, salvaging, retry-wait, throttled, cloudflare, oversized,
# deferred, done, failed, in-progress.
# Terminal phases: done (read $OUT), failed, deferred (no slot spent: retry later),
# oversized (no slot spent: scope the diff), in-progress (slot SPENT, model still
# generating: collect later with --harvest <marker>, NEVER relaunch).
# v0.20: the JSON carries `marker`, the run's conversation correlation id, so callers can
# harvest an in-progress review without grepping engine logs.
STATUS_FILE="$OUT.status"
pg_status() {  # $1 phase, $2 optional detail — variable fields are JSON-escaped (v0.18.1:
  # $OUT is caller-supplied; a quote/backslash in it would corrupt the polling contract)
  local phase="$1" detail="${2:-}" ts
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  if pg_have jq; then
    jq -nc --arg phase "$phase" --argjson attempt "${attempt:-0}" --arg detail "$detail" \
       --arg pr "${PR_NUM:-diff}" --arg out "$OUT" --arg ts "$ts" --arg marker "${RUN_MARKER:-}" \
       '{phase:$phase,attempt:$attempt,detail:$detail,pr:$pr,out:$out,ts:$ts,marker:$marker}' \
       > "$STATUS_FILE.tmp" 2>/dev/null
  else
    printf '{"phase":"%s","attempt":%d,"detail":"%s","pr":"%s","out":"%s","ts":"%s","marker":"%s"}\n' \
      "$phase" "${attempt:-0}" "$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')" \
      "${PR_NUM:-diff}" "$(printf '%s' "$OUT" | tr -d '"\\' | tr '\n' ' ')" "$ts" \
      "$(printf '%s' "${RUN_MARKER:-}" | tr -d '"\\' | tr '\n' ' ')" \
      > "$STATUS_FILE.tmp" 2>/dev/null
  fi
  { [ -s "$STATUS_FILE.tmp" ] && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"; } 2>/dev/null || true
}
pg_status preflight

# --- v0.19: run bookkeeping for the ledger + adaptive ramp ---
RUN_START="$(date +%s)"
SALVAGED=0
EFF_CONC=0
pg_finish() {  # $1 exit code — write the ledger line, feed the ramp governor, exit
  local rc="$1" outcome dur line
  dur=$(( $(date +%s) - RUN_START ))
  case "$rc" in
    0) outcome=clean ;;
    6) outcome=failed ;;
    7) outcome=lock-timeout ;;
    8) outcome=deferred ;;
    9) outcome=in-progress ;;
    11) outcome=oversized ;;
    *) outcome=other ;;
  esac
  [ "${THROTTLED:-0}" = 1 ] && outcome=throttle
  [ "${CLOUDFLARE:-0}" = 1 ] && outcome=cloudflare
  # cloudflare is an account-level block just like a throttle: drop concurrency (feed the ramp
  # the throttle signal) while recording the distinct outcome in the ledger.
  # in-progress and oversized teach the ramp nothing (the account behaved fine); harvest runs
  # (HARVEST=1) never feed it either: a harvest is not a fresh Pro spend, so a clean harvest
  # must not inflate the clean streak that earns concurrency.
  if [ "${HARVEST:-0}" != 1 ]; then
    case "$outcome" in
      clean|throttle|failed) pg_ramp_update "$outcome" "${MAX_CONC:-1}" ;;
      cloudflare)            pg_ramp_update throttle "${MAX_CONC:-1}" ;;
    esac
  fi
  if pg_have jq; then
    line="$(jq -nc --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg pr "${PR_NUM:-diff}" \
      --arg repo "${REPO:-}" --argjson exit "$rc" --arg outcome "$outcome" \
      --argjson secs "$dur" --argjson attempts "${attempt:-0}" \
      --argjson conc "${EFF_CONC:-0}" --argjson ceiling "${MAX_CONC:-1}" \
      --argjson live "${LIVE_CONVERSATION:-0}" --argjson salvaged "${SALVAGED:-0}" \
      --argjson diff_lines "${DIFF_LINES:-0}" --arg out "$OUT" \
      '{ts:$ts,pr:$pr,repo:$repo,exit:$exit,outcome:$outcome,secs:$secs,attempts:$attempts,conc:$conc,ceiling:$ceiling,live:$live,salvaged:$salvaged,diff_lines:$diff_lines,out:$out}' 2>/dev/null)"
  else
    line="$(printf '{"ts":"%s","pr":"%s","exit":%d,"outcome":"%s","secs":%d,"attempts":%d,"conc":%d,"ceiling":%d,"live":%d,"salvaged":%d}' \
      "$(date +%Y-%m-%dT%H:%M:%S%z)" "${PR_NUM:-diff}" "$rc" "$outcome" "$dur" "${attempt:-0}" \
      "${EFF_CONC:-0}" "${MAX_CONC:-1}" "${LIVE_CONVERSATION:-0}" "${SALVAGED:-0}")"
  fi
  pg_ledger_append "$line"
  # Close this run's conversation tab. We run oracle with --browser-archive=never (so probe and
  # salvage can always find the conversation by marker), which means WE own cleanup, otherwise
  # /c/ tabs accumulate and add load to the account. Best-effort, bounded, non-fatal; matched by
  # RUN_MARKER so we never touch another run's tab. remote-chrome only (native drives the user's
  # own Chrome, where closing tabs is not ours to do). PRO_GATE_KEEP_TABS=1 opts out (debugging).
  # Skip cleanup for lock-timeout (7), deferred (8), and oversized (11): no slot was spent, so
  # no conversation tab exists, and a CDP scan there would just waste time. Skip it for
  # in-progress (9) because the model is STILL GENERATING in that tab: closing it destroys a
  # spent Pro slot's answer (a 65-minute Pro review was lost exactly this way on 2026-07-09);
  # the tab stays open for --harvest, which closes it once the review is finally captured.
  if [ "$rc" != 7 ] && [ "$rc" != 8 ] && [ "$rc" != 9 ] && [ "$rc" != 11 ] \
     && [ "$MODE" = remote-chrome ] && [ "${PRO_GATE_KEEP_TABS:-0}" != 1 ] \
     && [ -n "${RUN_MARKER:-}" ] && command -v node >/dev/null 2>&1; then
    timeout 30 node "$SELF/cdp-salvage.mjs" --close "$RUN_MARKER" 25 "$PORT" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}

# --- preflight: browser reachable / signed in (per platform) ---
if [ "$MODE" = "remote-chrome" ]; then
  export DISPLAY="${ORACLE_DISPLAY:-:99}"
  # v0.19: one self-heal attempt (non-interactive service start) before giving up.
  if ! pg_cdp_heal; then
    echo "ERROR: oracle browser session (CDP) not reachable on ${PORT} (self-heal attempted)." >&2
    [ "$(pg_service_mgr)" = systemd ] && echo "  start it: sudo systemctl start oracle-chrome" >&2
    pg_status failed "browser CDP unreachable"
    exit 3
  fi
else
  # native (macOS): oracle drives your signed-in Chrome. Nothing to pre-start; oracle errors
  # clearly if you're not signed into ChatGPT.
  :
fi

# --- v0.20: harvest mode: collect an in-progress run's review, spending NO new slot ---
# A run that exits 9 (in-progress) spent its Pro slot but hit the salvage budget while the
# model was still generating; its conversation tab was deliberately left open. This mode
# re-runs ONLY the marker-matched CDP collection. Exit: 0 done, 9 still generating (run it
# again later), 8 deferred (cooldown/box unfit: the account must not be rendered against),
# 6 conversation gone (review lost; only now is a re-run justified).
if [ -n "$HARVEST_MARKER" ]; then
  HARVEST=1
  RUN_MARKER="$HARVEST_MARKER"
  if [ "$MODE" != remote-chrome ]; then
    echo "ERROR: --harvest requires remote-chrome/CDP mode; native browser mode exposes no marker-addressable CDP tab." >&2
    pg_status failed "harvest unsupported in native browser mode"
    pg_finish 3
  fi
  # ledger/status pr field from the marker's "pg-run-<pr>-<epoch>-<pid>" shape (best-effort)
  PR_NUM="$(printf '%s' "$HARVEST_MARKER" | sed -nE 's/^pg-run-([A-Za-z0-9]+)-[0-9]+.*$/\1/p')"
  command -v node >/dev/null 2>&1 || { echo "ERROR: --harvest needs node for CDP salvage" >&2; pg_status failed "node missing"; pg_finish 3; }
  # A harvest spends NO Pro slot and only reads over CDP, so the box-fitness parts of
  # pg_health_gate (memory, service uptime) don't apply: memory pressure is likeliest exactly
  # when a long review forced the harvest. Only the account cooldown defers it: salvage renders
  # against a throttled/challenged account deepen the block.
  if GATE_REASON="$(pg_cooldown_active)"; then
    echo "[oracle-review] harvest deferred: ${GATE_REASON}." >&2
    pg_status deferred "$GATE_REASON"
    pg_finish 8
  fi
  HARVEST_SECS="$(pg_dur_secs "$TIMEOUT")"
  echo "[oracle-review] harvesting in-progress review (marker ${RUN_MARKER}, up to ${HARVEST_SECS}s, no new slot spent)..." >&2
  pg_status salvaging "harvest up to ${HARVEST_SECS}s"
  HARVEST_RC=0
  node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "$HARVEST_SECS" "$PORT" > "$OUT.cdp" || HARVEST_RC=$?
  if [ "$HARVEST_RC" -eq 0 ] && pg_is_review "$OUT.cdp"; then
    mv "$OUT.cdp" "$OUT"
    pg_reservation_remove "$RUN_MARKER" || true
    SALVAGED=1
    echo "[oracle-review] harvest recovered the completed review ($(wc -c < "$OUT" 2>/dev/null) bytes)." >&2
    pg_status done
    cat "$OUT"
    echo "RESULT_FILE=$OUT"
    pg_finish 0
  fi
  rm -f "$OUT.cdp"
  case "$HARVEST_RC" in
    3) pg_reservation_write "$RUN_MARKER" "${PR_NUM:-diff}" "$OUT" || true
       echo "[oracle-review] still generating: tab left open; run --harvest again later." >&2
       pg_status in-progress "still generating; retry --harvest later"
       pg_finish 9 ;;
    5) echo "[oracle-review] ChatGPT throttle hit during harvest: cooldown written; retry --harvest after it expires." >&2
       THROTTLED=1
       pg_status deferred "throttle during harvest; retry after cooldown"
       pg_finish 8 ;;
    *) pg_reservation_remove "$RUN_MARKER" || true
       echo "ERROR: no conversation matches marker ${RUN_MARKER} (tab closed/archived or review lost)." >&2
       pg_status failed "harvest found no matching conversation"
       pg_finish 6 ;;
  esac
fi

pg_have oracle || { echo "ERROR: oracle not installed (pnpm add -g @steipete/oracle)" >&2; pg_status failed "oracle missing"; pg_finish 3; }

# --- resolve repo + PR, assemble the diff (ground truth) ---
PR_URL=""; PR_NUM=""
if [ -n "$PR" ]; then
  if [[ "$PR" =~ ^https?:// ]]; then
    PR_URL="$PR"; PR_NUM="${PR##*/}"
    if [ -z "$REPO" ]; then
      NAME="$(printf '%s' "$PR_URL" | sed -E 's#https?://github.com/[^/]+/([^/]+)/pull/.*#\1#')"
      for base in "${PRO_GATE_REPOS_DIR:-$HOME/SITES}" "$HOME/src" "$HOME/code" "$HOME/dev"; do
        [ -d "$base/$NAME/.git" ] && { REPO="$base/$NAME"; break; }
      done
    fi
  else
    PR_NUM="$PR"
  fi
fi
[ -n "$REPO" ] || REPO="$(pwd)"
cd "$REPO" || { echo "ERROR: repo dir not found: $REPO" >&2; pg_status failed "repo dir not found"; exit 4; }
[ -n "$PR_URL" ] || PR_URL="$(gh pr view "$PR_NUM" --json url -q .url 2>/dev/null || echo "")"

if [ -z "$DIFF_FILE" ]; then
  DIFF_FILE="$WORK/pr.diff"
  gh pr diff "$PR_NUM" --patch > "$DIFF_FILE" 2>"$WORK/diff.err" || {
    echo "ERROR: gh pr diff $PR_NUM failed in $REPO: $(cat "$WORK/diff.err")" >&2; pg_status failed "gh pr diff failed"; exit 5; }
fi

# --- diff hygiene: drop lockfiles/generated/vendored from the review payload so Pro Extended
# spends its (finite, disconnect-exposed) thinking window on real code, not lockfile churn. ---
if [ -s "$DIFF_FILE" ] && [ "${PRO_GATE_DIFF_FILTER:-1}" = 1 ]; then
  FILTERED="$WORK/pr.filtered.diff"
  if pg_filter_diff "$DIFF_FILE" "$FILTERED" 2>"$WORK/excluded.raw" && [ -s "$FILTERED" ]; then
    # a path can appear in several per-commit patches (gh pr diff --patch) — dedupe for the report
    sort -u "$WORK/excluded.raw" 2>/dev/null > "$WORK/excluded.txt" || cp "$WORK/excluded.raw" "$WORK/excluded.txt"
    # grep -c prints "0" AND exits 1 on an empty file, so `|| echo 0` produced "0\n0"
    # (the "[: 0\n0: integer expression expected" noise on every run). Default only when empty.
    NEX="$(grep -c . "$WORK/excluded.txt" 2>/dev/null)"; [ -n "$NEX" ] || NEX=0
    if [ "$NEX" -gt 0 ] 2>/dev/null; then
      echo "[oracle-review] diff hygiene: excluded ${NEX} noise file(s) from the payload: $(paste -sd', ' "$WORK/excluded.txt" 2>/dev/null | cut -c1-200)" >&2
      DIFF_FILE="$FILTERED"
    fi
  fi
fi

DIFF_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo 0)
echo "[oracle-review] os=$OS mode=$MODE repo=$REPO pr=#${PR_NUM} url=${PR_URL:-n/a} diff_lines=$DIFF_LINES input=$INPUT" >&2

# --- v0.20: diff-size guard: refuse to burn a Pro Extended slot on a payload that will not
# converge. Ledger data: 984-1402-line diffs complete in 12-21 min; a ~10k-line diff (6.5k
# insertions, 40 files) reasoned 65 minutes without emitting a verdict (2026-07-09, exactly the
# review window the timeout+salvage budgets cannot cover). Oversized diffs exit 11 BEFORE any
# lock or slot is taken, with the delta-scoping recipe on stderr. PRO_GATE_MAX_DIFF_LINES
# raises the cap, PRO_GATE_DIFF_GUARD=0 downgrades the hard stop to a warning.
DIFF_WARN_LINES="${PRO_GATE_DIFF_WARN_LINES:-2500}"
DIFF_MAX_LINES="${PRO_GATE_MAX_DIFF_LINES:-6000}"
if [ "${DIFF_LINES:-0}" -gt "$DIFF_MAX_LINES" ] 2>/dev/null && [ "${PRO_GATE_DIFF_GUARD:-1}" = 1 ]; then
  echo "ERROR: diff is ${DIFF_LINES} lines (> PRO_GATE_MAX_DIFF_LINES=${DIFF_MAX_LINES}): Pro Extended does not converge on payloads this size within any review budget; not spending a slot." >&2
  echo "  Scope the gate to what actually needs the final tier, then re-run with the patch:" >&2
  echo "    git -C <repo> diff <last-gated-sha>..<head> -- ':!*.lock' > delta.patch" >&2
  echo "    oracle-review.sh --diff delta.patch --repo <repo> --extra-files '<context globs>' --out <out>" >&2
  echo "  (Or split the PR; or raise PRO_GATE_MAX_DIFF_LINES / set PRO_GATE_DIFF_GUARD=0 to override.)" >&2
  pg_status oversized "diff ${DIFF_LINES} lines > max ${DIFF_MAX_LINES}; scope with --diff"
  pg_finish 11
elif [ "${DIFF_LINES:-0}" -gt "$DIFF_WARN_LINES" ] 2>/dev/null; then
  echo "[oracle-review] WARNING: diff is ${DIFF_LINES} lines (> ${DIFF_WARN_LINES}); large diffs risk exceeding the Pro Extended review window: consider scoping with --diff to the unreviewed delta." >&2
fi

# --- build the review prompt (the product) ---
# RUN_MARKER (v0.15, pro-gate PR#5 review P1): a per-attempt correlation id
# embedded in the prompt, so the CDP probe/salvage match THIS run's
# conversation tab and never a leftover tab from an earlier review of the
# same PR (which would suppress the retry and serve a stale review for a
# new head). The marker lands in the user message, hence in the tab's
# innerText, without asking the model to echo anything.
RUN_MARKER="pg-run-${PR_NUM:-diff}-$(date +%s)-$$"
PROMPT_FILE="$WORK/prompt.md"
{
  # Lead with the @GitHub connector tag + an explicit directive (belt-and-suspenders: oracle
  # pastes the prompt in one shot, so @GitHub is a recognized hint, not a bound mention pill;
  # ORACLE_CHATGPT_URL can pin a connector-bound Project for true binding).
  if [ "$INPUT" = "connector" ] || [ "$INPUT" = "both" ]; then
    [ -n "$PR_URL" ] && cat <<EOF
@GitHub — use the GitHub connector for anything GitHub-related in this review. Fetch this pull request and read its full diff plus the surrounding code, callers, tests, and history directly from GitHub via the connector (do not answer from memory): $PR_URL

EOF
  fi
  cat <<EOF
You are the FINAL, highest-tier code reviewer (GPT-5.5 Pro Extended) for a pull request that has ALREADY been through automated review tiers (Claude correctness/security/maintainability personas and a cloud bug+security scan) and their fixes have been applied. The cheap, obvious issues are already gone.

Your job is to find what those tiers MISSED — go deep:
- logic errors and incorrect assumptions; intent-vs-implementation mismatches
- subtle edge cases, off-by-one, null/empty/boundary handling
- race conditions, ordering, idempotency, partial-failure and retry behavior
- security holes (authz, injection, SSRF, secret handling, unsafe deserialization)
- data integrity (migrations, transactions, constraints, irreversible/lossy ops)
- broken invariants, resource leaks, error-swallowing, performance cliffs at scale

Be skeptical, specific, and concrete. Prefer a few HIGH-CONFIDENCE real defects over a long list of style nits.

Cite a concrete <file>:<line> for EVERY finding — if you cannot point to a specific changed line, do not raise it.
Do NOT flag: style/formatting/naming; anything CI, linters, or type-checkers already enforce; generated files or lockfiles; pre-existing issues unrelated to this change; or speculative/theoretical problems with no demonstrated impact path.
EOF
  if [ "$INPUT" = "bundle" ] || [ "$INPUT" = "both" ]; then
    cat <<EOF

The AUTHORITATIVE change is the attached unified diff "pr.diff" (ground truth — review EVERY changed hunk). Do not assume; if the diff contradicts what the connector shows, trust the diff for what changed.
EOF
  fi
  cat <<'EOF'

OUTPUT FORMAT — output ONLY findings, nothing else, each exactly:

[Pn] <file>:<line> — <one-line issue>
  Why it's a real problem: <concise reasoning>
  Confidence: <high|medium|low>
  Suggested fix: <concrete change>

where Pn is one of: P0 (critical / blocker / data-loss / security), P1 (major bug), P2 (minor), P3 (nit).
Group by severity, P0 first. If a severity has no findings, write "Pn: none".
End with one final line:  VERDICT: SHIP | FIX-FIRST | NEEDS-DISCUSSION  — <=15 word reason.
EOF
  echo
  echo "(run marker: ${RUN_MARKER} — internal correlation id; ignore it and do not mention it)"
} > "$PROMPT_FILE"

# --- assemble --file attachments (bundle mode) ---
FILES=()
if [ "$INPUT" = "bundle" ] || [ "$INPUT" = "both" ]; then
  FILES+=("$DIFF_FILE")
  if [ -n "$EXTRA_GLOB" ]; then
    while IFS= read -r f; do [ -f "$f" ] && FILES+=("$f"); done < <(compgen -G "$EXTRA_GLOB" 2>/dev/null || true)
  fi
fi
FILE_ARGS=(); for f in "${FILES[@]:-}"; do [ -n "$f" ] && FILE_ARGS+=(--file "$f"); done

# Route through a connector-bound ChatGPT Project when configured (pre-binds GitHub).
URL_ARGS=()
if [ -n "${ORACLE_CHATGPT_URL:-}" ] && [ "${ORACLE_CHATGPT_URL}" != "https://chatgpt.com/" ]; then
  URL_ARGS+=(--chatgpt-url "$ORACLE_CHATGPT_URL")
fi

# Platform browser flags: WSL/Linux attaches to the Xvfb Chrome; macOS lets oracle drive Chrome.
ENGINE_ARGS=(-e browser)
[ "$MODE" = "remote-chrome" ] && ENGINE_ARGS+=(--remote-chrome "127.0.0.1:${PORT}")
# Keep oracle from auto-archiving the conversation. Its default (auto) archives a "successful"
# one-shot and navigates the tab off the conversation, which strips the RUN_MARKER from the
# open tabs and blinds BOTH the pre-retry liveness probe (-> false "dead submission" -> a
# double-spending retry) and the last-resort CDP salvage. We own the conversation lifecycle:
# leave the tab intact so probe/salvage can always find it, and close it ourselves once the
# review is confirmed (pg_close_run_tab in pg_finish). Override with PRO_GATE_BROWSER_ARCHIVE.
ENGINE_ARGS+=(--browser-archive "${PRO_GATE_BROWSER_ARCHIVE:-never}")

# --- Bound concurrent Pro Extended runs against the single ChatGPT account ---
# DEFAULT IS SERIALIZED (1). The 2026-07-03 throttle incident showed one account under
# 3 parallel runs (plus their salvage page-loads) trips ChatGPT's anti-scraping limiter
# ("temporarily limited access to your conversations"). PRO_GATE_MAX_CONCURRENCY is the
# CEILING; v0.19's ramp governor (pg_ramp_level) decides the EFFECTIVE slots — earned up
# one level per PRO_GATE_RAMP_STREAK clean runs, dropped to 1 on any throttle. Excess
# callers QUEUE on the semaphore. A SEPARATE per-PR guard ensures the SAME pr is never
# under two simultaneous reviews (that would double-spend a slot on one diff). NOTE:
# oracle itself caps concurrent browser tabs (3 in <=0.15.x) — a ceiling above oracle's
# cap just queues inside oracle.
LOCKFILE="${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}"
LOCK_WAIT="${PRO_GATE_LOCK_WAIT:-2400}"
MAX_CONC="${PRO_GATE_MAX_CONCURRENCY:-1}"
EFF_CONC="$(pg_ramp_level "$MAX_CONC")"

# Housekeeping: per-PR lock files are 0-byte and used to accumulate forever. Sweep ones
# untouched for >24h — any legitimate holder finishes within the ~35 min hard cap.
find "$(dirname "$LOCKFILE")" -maxdepth 1 -name "$(basename "$LOCKFILE").pr-*" -mmin +1440 -delete 2>/dev/null || true

# Reconcile durable reservations from earlier exit-9 runs before dispatch. A same-PR
# reservation redirects this invocation to HARVEST instead of spending a second slot. This is
# enforced in the engine (not merely caller docs), so a killed headless caller cannot double-
# spend on its next daemon cycle. Native mode has no marker-addressable CDP, so no reservations
# are created there.
if [ "$MODE" = remote-chrome ]; then
  pg_reservation_reconcile "$SELF/cdp-salvage.mjs" "$PORT"
  if [ -n "${PR_NUM}" ]; then
    RESERVED_MARKER="$(pg_reservation_find_pr "$PR_NUM" 2>/dev/null || true)"
    if [ -n "$RESERVED_MARKER" ]; then
      echo "[oracle-review] pr #${PR_NUM} already has an in-progress Pro conversation (${RESERVED_MARKER}): harvesting it instead of submitting again." >&2
      pg_status in-progress "existing reservation ${RESERVED_MARKER}; harvest required"
      echo "  ${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh --harvest '${RESERVED_MARKER}' --out '${OUT}' --timeout 20m" >&2
      pg_finish 9
    fi
  fi
fi

# Per-PR guard (acquire BEFORE a slot, so same-PR callers serialize without holding a scarce slot).
if [ -n "${PR_NUM}" ]; then
  echo "[oracle-review] per-PR guard for pr #${PR_NUM} (serializes same-PR reviews)..." >&2
  pg_status waiting-pr-lock
  if ! pg_lock "${LOCKFILE}.pr-${PR_NUM}" "$LOCK_WAIT"; then
    echo "ERROR: timed out after ${LOCK_WAIT}s — pr #${PR_NUM} is already under review elsewhere." >&2
    pg_status failed "per-PR lock timeout"
    pg_finish 7
  fi
  # The previous same-PR process may have exited 9 while we waited and written a reservation
  # just before releasing this flock. Re-check now that we own the per-PR lock; otherwise this
  # waiter would immediately submit a duplicate review.
  RESERVED_MARKER="$(pg_reservation_find_pr "$PR_NUM" 2>/dev/null || true)"
  if [ -n "$RESERVED_MARKER" ]; then
    echo "[oracle-review] pr #${PR_NUM} became in-progress while waiting (${RESERVED_MARKER}): harvest required, not resubmitting." >&2
    pg_status in-progress "existing reservation ${RESERVED_MARKER}; harvest required"
    pg_finish 9
  fi
fi

echo "[oracle-review] acquiring a review slot (effective ${EFF_CONC} of ceiling ${MAX_CONC}; waits up to ${LOCK_WAIT}s if all busy)..." >&2
pg_status waiting-slot "effective ${EFF_CONC} / ceiling ${MAX_CONC}"
# v0.19.1 (pro-gate self-review P1): re-read the ramp level every wait slice — a run that
# queued at level 3 must NOT acquire slot 3 after a concurrent throttle dropped the level
# to 1 mid-wait. Short pg_lock_n slices keep the wait responsive to governor changes.
SLOT_DEADLINE=$(( $(date +%s) + LOCK_WAIT ))
SLOT_OK=0
while :; do
  EFF_CONC="$(pg_ramp_level "$MAX_CONC")"
  # Durable reservations count as occupied Pro capacity even though their wrapper process has
  # exited. Reduce process-owned semaphore capacity accordingly; if reservations consume the
  # full effective level, wait without calling pg_lock_n (which clamps maxn<=0 back to 1).
  if ! pg_reservation_guard_acquire; then sleep 3; continue; fi
  RESERVED_COUNT="$(pg_reservation_count)"
  AVAILABLE_CONC=$(( EFF_CONC - RESERVED_COUNT ))
  # Nonblocking while holding the short handoff guard: waiting here would prevent an active
  # run from writing its reservation before releasing its process slot (writer waits 10s; the
  # old slot scan waited 15s). One immediate scan gives an atomic count+acquire decision; the
  # outer loop releases the guard and retries.
  if [ "$AVAILABLE_CONC" -gt 0 ] && pg_lock_n "$LOCKFILE" "$AVAILABLE_CONC" 0; then
    # Keep the acquired process slot, release only the short reservation handoff guard.
    pg_reservation_guard_release; SLOT_OK=1; break
  fi
  pg_reservation_guard_release
  if [ "$(date +%s)" -ge "$SLOT_DEADLINE" ]; then break; fi
  sleep 3
done
if [ "$SLOT_OK" != 1 ]; then
  echo "ERROR: timed out after ${LOCK_WAIT}s — all ${EFF_CONC} review slots are busy." >&2
  pg_status failed "slot timeout"
  pg_finish 7
fi

RUNLOG="$WORK/oracle.log"

# The oracle CLI's own --timeout has been observed NOT to fire while it waits on a ChatGPT
# tab that never starts thinking (a "dead submission" squatted a browser slot for 3.5h on
# 2026-07-02). The engine therefore enforces its own bounds:
#   hard cap   — coreutils timeout at TIMEOUT + PRO_GATE_TIMEOUT_GRACE (default +120s)
#   stall      — no oracle log output for PRO_GATE_STALL_SECS (default 600) and no findings
#   no-think   — still "no thinking status detected" after PRO_GATE_NOTHINK_SECS (default 600)
# A watchdog kill returns 124; the caller's salvage + guarded-retry path takes over. Dead
# submissions never consumed the Pro Extended thinking window, so the retry is not a
# double-spend.
HARD_SECS=$(( $(pg_dur_secs "$TIMEOUT") + ${PRO_GATE_TIMEOUT_GRACE:-120} ))
STALL_SECS="${PRO_GATE_STALL_SECS:-600}"
NOTHINK_SECS="${PRO_GATE_NOTHINK_SECS:-600}"

run_oracle() {  # $1 = browser model strategy (select|current|ignore)
  local strategy="$1" job started size last_size last_change now last_line prc
  # v0.16 (#873 lesson): a watchdog-killed attempt leaves its session record
  # status "running", and oracle's duplicate-prompt guard then blocks the
  # engine's OWN retry of the same prompt/slug. Retries only happen after the
  # probe judged the submission truly dead (no conversation tab, quota not
  # spent), so forcing a fresh session on retry is exactly oracle's documented
  # escape hatch for this state.
  local force_args=()
  [ "${attempt:-0}" -gt 0 ] && force_args+=(--force)
  ( stdbuf -oL -eL timeout --signal=TERM --kill-after=30 "$HARD_SECS" \
      "${PRO_GATE_ORACLE_BIN:-oracle}" "${ENGINE_ARGS[@]}" -m "$MODEL" \
      --browser-model-strategy "$strategy" ${force_args[0]:+"${force_args[@]}"} \
      --slug "pro gate review pr ${PR_NUM:-diff}" \
      "${URL_ARGS[@]}" "${FILE_ARGS[@]}" \
      -p "$(cat "$PROMPT_FILE")" \
      --no-notify --timeout "$TIMEOUT" \
      --write-output "$OUT" 2>&1 | tee -a "$RUNLOG" | stdbuf -oL sed 's/^/[oracle] /' >&2 ) &
  job=$!
  started=$SECONDS; last_size=-1; last_change=$SECONDS
  while kill -0 "$job" 2>/dev/null; do
    sleep 10
    [ -s "$OUT" ] && continue   # findings are landing — let the run finish undisturbed
    size=$(wc -c < "$RUNLOG" 2>/dev/null) || size=0
    if [ "$size" != "$last_size" ]; then last_size="$size"; last_change=$SECONDS; fi
    now=$SECONDS
    last_line="$(tail -n 1 "$RUNLOG" 2>/dev/null || true)"
    if [ $(( now - last_change )) -ge "$STALL_SECS" ]; then
      echo "[oracle-review] watchdog: oracle silent for ${STALL_SECS}s with no findings — killing this attempt (salvage/retry follows)." >&2
      pg_status watchdog-killed "stall ${STALL_SECS}s"
    elif [ $(( now - started )) -ge "$NOTHINK_SECS" ] && printf '%s' "$last_line" | grep -q "no thinking status detected"; then
      # v0.14: oracle's thinking detection can lag reality (ChatGPT UI drift,
      # first seen PR pushbot#863 2026-07-02: killed a run that was 11m into a
      # live Pro Extended thought). Before declaring the submission dead, ask
      # Chrome whether a conversation tab matching this PR exists. If it does,
      # the run is LIVE: quota is already spent and a resubmit would
      # double-spend. Kill the blind CLI anyway (frees the browser slot) but
      # flag it so the caller skips reattach+retry and goes straight to the
      # outcome-based CDP salvage with the full remaining budget.
      # v0.18: probe exit 5 = ChatGPT throttle interstitial. The submission's
      # fate is UNKNOWN (it may have landed before the throttle), so treat it
      # like live: never resubmit, and let the post-cooldown salvage decide.
      prc=2
      if command -v node >/dev/null 2>&1; then
        node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT" >/dev/null 2>>"$RUNLOG"; prc=$?
      fi
      if [ "$prc" -eq 0 ]; then
        echo "[oracle-review] watchdog: no-think after $(( now - started ))s BUT a conversation tab matches this PR — submission is LIVE, detection missed. Freeing the slot; CDP salvage will collect the review (retry suppressed: quota already spent)." >&2
        LIVE_CONVERSATION=1
        pg_status live-detected "no-think probe found the conversation"
      elif [ "$prc" -eq 5 ]; then
        echo "[oracle-review] watchdog: ChatGPT is rate-limiting this account — killing this attempt; retry suppressed, cooldown started (salvage after the pause)." >&2
        THROTTLED=1
        pg_status throttled "interstitial during no-think probe"
      else
        echo "[oracle-review] watchdog: ChatGPT never started thinking after $(( now - started ))s — dead submission; killing this attempt (salvage/retry follows)." >&2
        pg_status watchdog-killed "no-think ${NOTHINK_SECS}s"
      fi
    else
      continue
    fi
    pkill -TERM -P "$job" 2>/dev/null; kill -TERM "$job" 2>/dev/null
    sleep 5
    pkill -KILL -P "$job" 2>/dev/null; kill -KILL "$job" 2>/dev/null
    wait "$job" 2>/dev/null
    return 124
  done
  wait "$job"
}

# --- spend the slot: health-gate -> run -> salvage -> one guarded retry ---
# A precious Pro Extended slot is spent only when the box is fit; a dropped connection is first
# SALVAGED (the answer may have finished server-side), and only a truly-lost run is retried once.
# Exit 8 = deferred (no slot spent); exit 6 = ran but produced nothing after salvage + retry.
SLUG_BASE="pro-gate-review-pr-${PR_NUM:-diff}"
REATTACH_TIMEOUT="${PRO_GATE_REATTACH_TIMEOUT:-150}"
MAX_RETRIES="${PRO_GATE_MAX_RETRIES:-1}"
BACKOFF="${PRO_GATE_RETRY_BACKOFF:-20}"
LIVE_CONVERSATION=0
THROTTLED=0
CLOUDFLARE=0
attempt=0
while :; do
  if ! GATE_REASON="$(pg_health_gate)"; then
    # v0.18: exit 8 ("deferred, NO slot spent") is only true before the first attempt.
    # On a retry iteration a slot HAS been spent — abandoning to exit 8 here would skip
    # the salvage of a possibly-completed review. Stop retrying and salvage instead.
    if [ "$attempt" -eq 0 ]; then
      echo "ERROR: not spending a Pro Extended slot — ${GATE_REASON}." >&2
      echo "  Deferred (no slot spent). Retry once the box settles, or run on macOS (native Chrome)." >&2
      pg_status deferred "$GATE_REASON"
      pg_finish 8
    fi
    echo "[oracle-review] not retrying (${GATE_REASON}) — falling through to salvage." >&2
    # v0.18.1 (pro-gate self-review P1): when the gate failure IS the throttle cooldown,
    # take the throttle path — otherwise the final salvage would render conversations
    # against the still-throttled account immediately, bypassing the protective pause.
    case "$GATE_REASON" in *"throttle cooldown"*) THROTTLED=1 ;; esac
    break
  fi

  echo "[oracle-review] launching GPT-5.5 Pro Extended review (attempt $((attempt + 1)), oracle timeout $TIMEOUT, hard cap ${HARD_SECS}s, stall/no-think watchdog ${STALL_SECS}s/${NOTHINK_SECS}s)..." >&2
  pg_status launching "strategy ${PRO_GATE_MODEL_STRATEGY:-select}"
  : > "$RUNLOG"; rm -f "$OUT"   # clear any prior attempt's output so stale garbage can't survive
  run_oracle "${PRO_GATE_MODEL_STRATEGY:-select}" || true
  # UI fallback (notably macOS): model picker not found + no output -> retry with the default model.
  if [ ! -s "$OUT" ] && grep -qiE "model selector|model.?picker" "$RUNLOG" 2>/dev/null; then
    echo "[oracle-review] model picker not found — retrying with --browser-model-strategy current (ensure GPT-5.5 Pro Extended is your ChatGPT default)..." >&2
    run_oracle current || true
  fi
  # Accept ONLY a real review, not just any non-empty file — a corrupted capture (e.g. a stray "A")
  # must NOT pass as success; it falls through to salvage + retry below.
  if pg_is_review "$OUT"; then
    echo "[oracle-review] findings written ($(wc -c < "$OUT" 2>/dev/null) bytes)." >&2; break
  fi
  if [ -s "$OUT" ]; then
    echo "[oracle-review] discarding a non-review capture ($(wc -c < "$OUT" 2>/dev/null) bytes, no VERDICT/Pn markers) — will salvage/retry." >&2
  fi

  # Cloudflare / ChatGPT anti-bot challenge: oracle detects the "Just a moment" interstitial and
  # logs "Cloudflare anti-bot page detected" / throws stage=cloudflare-challenge. The submission
  # did NOT land, so a retry only hammers the challenge and deepens the block (the headless,
  # concurrency-driven trigger that a warm interactive session never hits). Treat it like the
  # throttle: back off. Write the account cooldown the health gate already honors, drop the ramp
  # to 1 (concurrency is the real trigger), suppress the retry, and skip salvage (nothing landed).
  # Match oracle's own Cloudflare emissions ("Cloudflare anti-bot page detected" logger line and
  # the "Cloudflare challenge detected ..." thrown-error message / cloudflare-challenge stage).
  # Guarded by `! pg_is_review`, so a successful review that merely discusses Cloudflare (its text
  # also lands in the log) can never be misread as a block.
  if ! pg_is_review "$OUT" \
     && grep -qiE 'Cloudflare (anti-bot page|challenge) detected|cloudflare-challenge' "$RUNLOG" 2>/dev/null; then
    echo "[oracle-review] ChatGPT/Cloudflare anti-bot challenge detected; backing off (account cooldown + concurrency drop), NOT retrying (a resubmit only deepens the block)." >&2
    CLOUDFLARE=1
    pg_status cloudflare "anti-bot challenge; cooldown started"
    cdf="${PRO_GATE_COOLDOWN_FILE:-$PRO_GATE_HOME/throttle.cooldown}"
    { printf '%s cloudflare-challenge (pr %s)\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "${PR_NUM:-diff}" > "$cdf"; } 2>/dev/null || true
    break
  fi

  # v0.14: a live conversation means the quota is already spent. Reattach is
  # useless here (it binds the pre-kill tab target, which goes stale) and a
  # resubmit would double-spend — skip both and let the outcome-based CDP
  # salvage below collect the review when it finishes.
  # v0.18: same for a throttle kill — the submission's fate is unknown, and
  # both reattach and a resubmit would hit the throttled account again.
  if [ "$LIVE_CONVERSATION" = 1 ] || [ "$THROTTLED" = 1 ]; then
    break
  fi

  # No output. The generation may have COMPLETED server-side after a dropped Chrome connection —
  # try a bounded salvage (never hangs) before spending another slot. Capture the slug oracle
  # actually used (it may differ from SLUG_BASE on a collision, e.g. ...-pr-804-2).
  SLUG="$(grep -oE 'oracle session [A-Za-z0-9._-]+' "$RUNLOG" 2>/dev/null | tail -1 | awk '{print $NF}')"
  [ -n "$SLUG" ] || SLUG="$SLUG_BASE"
  echo "[oracle-review] no output — bounded salvage via reattach (session ${SLUG}, ${REATTACH_TIMEOUT}s)..." >&2
  pg_status salvaging "reattach ${SLUG}"
  if pg_reattach_render "$SLUG" "$OUT" "$REATTACH_TIMEOUT"; then
    echo "[oracle-review] salvaged a completed review via reattach." >&2
    SALVAGED=1
    break
  fi

  attempt=$((attempt + 1))
  [ "$attempt" -gt "$MAX_RETRIES" ] && break
  # v0.16.1 (self-review P1): the retry passes --force, which bypasses
  # oracle's duplicate-prompt guard — previously the LAST defense against
  # resubmitting a live-but-silent run. The no-think path probes before its
  # kill, but stall and hard-cap kills reach here unprobed. Probe RIGHT
  # BEFORE every retry: a conversation tab matching this run's marker means
  # the quota is spent, so suppress the retry and let the CDP salvage below
  # collect the review instead. (If Chrome itself is unreachable the probe
  # errors and the retry proceeds — a server-side-completed run cannot be
  # salvaged through a dead browser anyway.)
  PRC=2
  if command -v node >/dev/null 2>&1; then
    node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT" >/dev/null 2>>"$RUNLOG"; PRC=$?
  fi
  if [ "$PRC" -eq 0 ]; then
    echo "[oracle-review] pre-retry probe found a live conversation for this run — retry suppressed (quota already spent); CDP salvage will collect it." >&2
    LIVE_CONVERSATION=1
    pg_status live-detected "pre-retry probe found the conversation"
    break
  elif [ "$PRC" -eq 5 ]; then
    echo "[oracle-review] pre-retry probe hit the ChatGPT throttle — retry suppressed; cooldown started (salvage after the pause)." >&2
    THROTTLED=1
    pg_status throttled "interstitial during pre-retry probe"
    break
  fi
  # FAIL CLOSED (self-review P1): a probe that neither found the conversation (0) nor throttle
  # (5) is INCONCLUSIVE, not proof of a dead submission: a transient CDP/render hiccup returns
  # the same non-0/5 code, and retrying a submission that actually LANDED double-spends the Pro
  # slot. Only a run that died BEFORE it submitted is safe to retry. Oracle logs "Acquired
  # ChatGPT browser slot" / "Session: ..." once the prompt is in flight; if that evidence is
  # present the quota is spent, so suppress the retry and let the full-budget CDP salvage below
  # collect it (now reliable: we run --browser-archive=never, so the tab is still findable).
  # RUNLOG holds oracle's RAW output (the "[oracle] " prefix is added only to the live display),
  # so match oracle's own strings. Bias toward "landed" (suppress the retry): a double-spend is
  # worse than a missed retry, which the caller re-runs.
  if grep -qE 'Launching browser mode|Acquired ChatGPT browser slot|Reattach: oracle session ' "$RUNLOG" 2>/dev/null; then
    echo "[oracle-review] pre-retry probe inconclusive, but oracle had already submitted (browser slot/session in the log); treating as spent, retry suppressed, falling through to CDP salvage." >&2
    LIVE_CONVERSATION=1
    pg_status live-detected "submission landed (log evidence); retry suppressed"
    break
  fi
  echo "[oracle-review] pre-retry probe found no conversation AND no evidence oracle ever submitted (genuine dead submission). Retrying once after ${BACKOFF}s + a health re-check..." >&2
  pg_status retry-wait "backoff ${BACKOFF}s"
  sleep "$BACKOFF"
done

# v0.13: last-resort CDP tab salvage. oracle (<=0.15.0) can fail to DETECT
# thinking after ChatGPT UI drift even though the submission landed: the
# no-think watchdog then kills a LIVE run, and reattach harvests a stale tab
# target ("Assistant turns: 0") while the real conversation finishes in
# another tab. Before declaring failure, read the review straight off the
# conversation tab's DOM, matched by PR marker so concurrent review slots
# cannot cross-contaminate. First seen: pushbot PR #863, 2026-07-02.
# Skip salvage entirely on a Cloudflare challenge: the submission never landed (nothing to
# collect), and rendering conversation pages against a challenged account only deepens the block.
if ! pg_is_review "$OUT" && [ "${CLOUDFLARE:-0}" != 1 ] && command -v node >/dev/null 2>&1; then
  # Live conversation (v0.14 probe hit): the review may still be thinking, so
  # wait with the full hard-cap budget; otherwise a short window suffices.
  SALVAGE_SECS="$STALL_SECS"; [ "$LIVE_CONVERSATION" = 1 ] && SALVAGE_SECS="$HARD_SECS"
  # v0.18: after a throttle hit, pause before the single polite salvage pass —
  # rendering the conversation immediately just re-triggers the limiter. The
  # salvage itself exits 5 fast if the account is still throttled.
  if [ "$THROTTLED" = 1 ]; then
    THROTTLE_PAUSE="${PRO_GATE_THROTTLE_PAUSE:-300}"
    echo "[oracle-review] throttled — pausing ${THROTTLE_PAUSE}s before one polite salvage attempt..." >&2
    pg_status throttled "pausing ${THROTTLE_PAUSE}s before salvage"
    sleep "$THROTTLE_PAUSE"
    SALVAGE_SECS="$HARD_SECS"
  fi
  echo "[oracle-review] last-resort CDP tab salvage (marker ${RUN_MARKER}, up to ${SALVAGE_SECS}s)..." >&2
  pg_status salvaging "cdp up to ${SALVAGE_SECS}s"
  SALVAGE_RC=0
  node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "$SALVAGE_SECS" "$PORT" > "$OUT.cdp" 2>>"$RUNLOG" || SALVAGE_RC=$?
  if [ "$SALVAGE_RC" -eq 0 ] && pg_is_review "$OUT.cdp"; then
    mv "$OUT.cdp" "$OUT"
    echo "[oracle-review] CDP salvage recovered a completed review." >&2
    SALVAGED=1
  else
    rm -f "$OUT.cdp"
  fi
fi

if pg_is_review "$OUT"; then
  pg_status done
  cat "$OUT"
  echo "RESULT_FILE=$OUT"
  pg_finish 0
elif [ "${SALVAGE_RC:-0}" -eq 3 ]; then
  # The salvage budget ran out while the conversation was STILL GENERATING: the Pro slot is
  # spent and the answer may land any minute. Persist a durable reservation BEFORE this process
  # releases its flock slot, leave the tab open (pg_finish skips close for exit 9), and hand the
  # caller a no-respend collection path. Fresh runs reconcile/respect the reservation, so actual
  # account concurrency and same-PR serialization remain correct after this wrapper exits.
  if ! pg_reservation_write "$RUN_MARKER" "${PR_NUM:-diff}" "$OUT"; then
    # Fail closed: without the durable reservation, exit 9 would under-count a live Pro tab and
    # let the next invocation double-spend. Keep the process/locks alive rather than release
    # unreserved capacity; this should only happen on a broken/unwritable PRO_GATE_HOME.
    echo "ERROR: review still generating, but could not persist its capacity reservation; keeping the engine alive to preserve the slot." >&2
    pg_status salvaging "still generating; reservation write failed; slot held"
    while node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT" >/dev/null 2>&1; do sleep 60; done
    echo "ERROR: live conversation disappeared before it could be reserved; review lost." >&2
    pg_status failed "reservation write failed; conversation gone"
    pg_finish 6
  fi
  echo "ERROR: review still generating after the salvage budget: conversation tab LEFT OPEN and account capacity RESERVED." >&2
  echo "  Collect it later WITHOUT spending another Pro slot:" >&2
  echo "    ${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh --harvest '${RUN_MARKER}' --out '${OUT}' --timeout 20m" >&2
  pg_status in-progress "slot spent, model still generating; harvest with --harvest"
  pg_finish 9
else
  RETRIES=$(( attempt > 0 ? attempt - 1 : 0 ))
  echo "ERROR: oracle produced no usable review after salvage + ${RETRIES} retr$([ "${RETRIES}" -eq 1 ] && echo y || echo ies) (reattach: oracle session ${SLUG_BASE})." >&2
  pg_status failed "no usable review after salvage"
  pg_finish 6
fi
