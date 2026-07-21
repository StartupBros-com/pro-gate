#!/usr/bin/env bash
# oracle-review.sh: run a FINAL-TIER Pro review of a PR (or diff) via oracle.
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
#                    [--confirm <prior-review-file>]
#   oracle-review.sh --diff <patchfile> --repo <dir> [--out <file>] ...
#       Pass --pr TOGETHER with --diff when the diff belongs to a PR: the change identity
#       (round budget, per-change lock, reservations) stays the PR's instead of forking into
#       a separate repo+branch identity.
#   oracle-review.sh --confirm <prior-review-file> ...
#       Confirming pass (v0.22): attaches the prior review and instructs the model to verify
#       EVERY prior P0/P1 as RESOLVED or STILL-PRESENT before reporting new findings. A
#       budget-accounted engine run like any other.
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

PR=""; REPO=""; DIFF_FILE=""; INPUT="both"; OUT=""; TIMEOUT="30m"; EXTRA_GLOB=""; HARVEST_MARKER=""; HARVEST_REQUESTED=0; CONFIRM_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --diff) DIFF_FILE="$2"; shift 2;;
    --input) INPUT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --extra-files) EXTRA_GLOB="$2"; shift 2;;
    --confirm) CONFIRM_FILE="$2"; shift 2;;
    --harvest) HARVEST_REQUESTED=1; HARVEST_MARKER="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
if [ "$HARVEST_REQUESTED" = 1 ] && [ -z "$HARVEST_MARKER" ]; then
  echo "ERROR: --harvest requires a non-empty run marker" >&2
  exit 2
fi
if [ -n "$CONFIRM_FILE" ] && [ ! -s "$CONFIRM_FILE" ]; then
  echo "ERROR: --confirm file not found or empty: $CONFIRM_FILE" >&2
  exit 2
fi

PORT="${ORACLE_BROWSER_PORT:-9222}"
MODEL="${ORACLE_MODEL:-gpt-5.6}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pro-review.XXXXXX")"
[ -n "$OUT" ] || OUT="$WORK/findings.md"
# issue #35 self-heal: cdp-salvage records the live conversation URL here so a mid-run browser
# restart (usually OOM) can be recovered by reopening + salvaging it, with no new Pro spend. Only a
# FRESH run truncates it; a --harvest run PRESERVES a prior run's captured URL so it can reopen a
# conversation whose tab was lost to a restart before the harvest (gate #36 P1).
export PRO_GATE_CONVURL_OUT="$OUT.convurl"
if [ "${HARVEST_REQUESTED:-0}" != 1 ]; then : > "$PRO_GATE_CONVURL_OUT" 2>/dev/null || true; fi
# Fresh runs need oracle; --harvest only needs node+CDP and checks that prerequisite inside
# its branch below (moving this gate matters when oracle is temporarily unavailable but a spent
# review is waiting in an open conversation).

# --- machine-readable run status (v0.18) ---
# Callers (the /pro-gate skill, the daemon's headless agent) poll "$OUT.status" — a
# single-line JSON updated ATOMICALLY at every phase change — instead of scraping the
# engine's stderr. Phases: preflight, waiting-pr-lock, waiting-slot, launching,
# watchdog-killed, live-detected, salvaging, retry-wait, throttled, cloudflare, oversized,
# round-capped, deferred, done, failed, in-progress.
# Terminal phases: done (read $OUT), failed, deferred (no slot spent: retry later),
# oversized (no slot spent: scope the diff), round-capped (no slot spent: this PR/branch
# already used its review round budget for the window; escalate to a human, do not re-run),
# in-progress (slot SPENT, model still generating: collect later with --harvest <marker>,
# NEVER relaunch).
# v0.20: the JSON carries `marker`, the run's conversation correlation id, so callers can
# harvest an in-progress review without grepping engine logs.
STATUS_FILE="$OUT.status"
pg_status() {  # $1 phase, $2 optional detail — variable fields are JSON-escaped (v0.18.1:
  # $OUT is caller-supplied; a quote/backslash in it would corrupt the polling contract)
  local phase="$1" detail="${2:-}" ts model_label
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  # v0.21: `model` is the run's resolved model rendered through pg_model_label (captured label or
  # role-based fallback, never a hardcoded version); `model_warn` carries the advisory downgrade
  # marker (empty unless the model looked weak/unreadable). Human surfaces read both from here.
  model_label="$(pg_model_label "${RESOLVED_MODEL:-}")"
  if pg_have jq; then
    jq -nc --arg phase "$phase" --argjson attempt "${attempt:-0}" --arg detail "$detail" \
       --arg pr "${PR_NUM:-diff}" --arg out "$OUT" --arg ts "$ts" --arg marker "${RUN_MARKER:-}" \
       --arg model "$model_label" --arg model_warn "${MODEL_WARN:-}" \
       '{phase:$phase,attempt:$attempt,detail:$detail,pr:$pr,out:$out,ts:$ts,marker:$marker,model:$model,model_warn:$model_warn}' \
       > "$STATUS_FILE.tmp" 2>/dev/null
  else
    printf '{"phase":"%s","attempt":%d,"detail":"%s","pr":"%s","out":"%s","ts":"%s","marker":"%s","model":"%s","model_warn":"%s"}\n' \
      "$phase" "${attempt:-0}" "$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')" \
      "${PR_NUM:-diff}" "$(printf '%s' "$OUT" | tr -d '"\\' | tr '\n' ' ')" "$ts" \
      "$(printf '%s' "${RUN_MARKER:-}" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "$model_label" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "${MODEL_WARN:-}" | tr -d '"\\' | tr '\n' ' ')" \
      > "$STATUS_FILE.tmp" 2>/dev/null
  fi
  { [ -s "$STATUS_FILE.tmp" ] && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"; } 2>/dev/null || true
}
pg_status preflight

# --- v0.19: run bookkeeping for the ledger + adaptive ramp ---
RUN_START="$(date +%s)"
SALVAGED=0
EFF_CONC=0
# v0.21: the model oracle actually resolved for THIS run, plus the selection status. Captured
# (best-effort) from oracle's "Model selection evidence:" line on fresh paths, or read back from
# the reservation record on --harvest; empty until known and whenever the resolved label is
# "(unavailable)". Oracle 0.15.2 emits that line only at completion, so exit-9/harvest runs
# usually leave this empty (dogfood PR #20); every model surface renders it through
# pg_model_label so an unknown model degrades to role-based text, never a hardcoded version.
RESOLVED_MODEL=""
MODEL_STATUS=""   # oracle's status= field (e.g. already-selected); gates the R6 warning
MODEL_WARN=""     # U5: advisory downgrade marker (weak/unconfirmable model); never blocks the run
pg_finish() {  # $1 exit code — write the ledger line, feed the ramp governor, exit
  local rc="$1" outcome dur line model_label
  dur=$(( $(date +%s) - RUN_START ))
  model_label="$(pg_model_label "${RESOLVED_MODEL:-}")"   # resolved model or role-based fallback
  case "$rc" in
    0) outcome=clean ;;
    6) outcome=failed ;;
    7) outcome=lock-timeout ;;
    8) outcome=deferred ;;
    9) outcome=in-progress ;;
    11) outcome=oversized ;;
    12) outcome=round-capped ;;
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
      --argjson diff_lines "${DIFF_LINES:-0}" --arg out "$OUT" --arg model "$model_label" \
      '{ts:$ts,pr:$pr,repo:$repo,exit:$exit,outcome:$outcome,secs:$secs,attempts:$attempts,conc:$conc,ceiling:$ceiling,live:$live,salvaged:$salvaged,diff_lines:$diff_lines,out:$out,model:$model}' 2>/dev/null)"
  else
    line="$(printf '{"ts":"%s","pr":"%s","exit":%d,"outcome":"%s","secs":%d,"attempts":%d,"conc":%d,"ceiling":%d,"live":%d,"salvaged":%d,"model":"%s"}' \
      "$(date +%Y-%m-%dT%H:%M:%S%z)" "${PR_NUM:-diff}" "$rc" "$outcome" "$dur" "${attempt:-0}" \
      "${EFF_CONC:-0}" "${MAX_CONC:-1}" "${LIVE_CONVERSATION:-0}" "${SALVAGED:-0}" \
      "$(printf '%s' "$model_label" | tr -d '"\\' | tr '\n' ' ')")"
  fi
  pg_ledger_append "$line"
  # Close this run's conversation tab. We run oracle with --browser-archive=never (so probe and
  # salvage can always find the conversation by marker), which means WE own cleanup, otherwise
  # /c/ tabs accumulate and add load to the account. Best-effort, bounded, non-fatal; matched by
  # RUN_MARKER so we never touch another run's tab. remote-chrome only (native drives the user's
  # own Chrome, where closing tabs is not ours to do). PRO_GATE_KEEP_TABS=1 opts out (debugging).
  # Skip cleanup for lock-timeout (7), deferred (8), oversized (11), and round-capped (12): no
  # slot was spent, so no conversation tab exists, and a CDP scan there would just waste time.
  # Skip it for in-progress (9) because the model is STILL GENERATING in that tab: closing it
  # destroys a spent Pro slot's answer (a 65-minute Pro review was lost exactly this way on
  # 2026-07-09); the tab stays open for --harvest, which closes it once finally captured.
  if [ "$rc" != 7 ] && [ "$rc" != 8 ] && [ "$rc" != 9 ] && [ "$rc" != 11 ] && [ "$rc" != 12 ] \
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
  if ! pg_reservation_marker_ok "$RUN_MARKER"; then
    echo "ERROR: invalid --harvest marker (expected pg-run-... safe filename syntax)." >&2
    pg_status failed "invalid harvest marker"
    pg_finish 2
  fi
  # KTD3: name the model the original in-progress run persisted into the reservation record. The
  # harvest runs in a separate process with no $RUNLOG to grep, so it reads the model straight
  # back; a legacy/empty record leaves RESOLVED_MODEL empty -> role-based fallback. Derive the R6
  # warning HERE too (dogfood PR #20 P2): the harvest branch pg_finishes before the fresh-path
  # warning block, so without this a harvested weak/unconfirmable model would lose its marker. No
  # selection status is available in this process, so an empty model here warns "cannot confirm".
  RESOLVED_MODEL="$(pg_reservation_read_model "$RUN_MARKER" 2>/dev/null || true)"
  MODEL_WARN="$(pg_derive_model_warn "$RESOLVED_MODEL" "")"
  [ -n "$MODEL_WARN" ] && echo "[oracle-review] WARNING: ${MODEL_WARN}." >&2
  if [ "$MODE" != remote-chrome ]; then
    echo "ERROR: --harvest requires remote-chrome/CDP mode; native browser mode exposes no marker-addressable CDP tab." >&2
    pg_status failed "harvest unsupported in native browser mode"
    pg_finish 3
  fi
  # ledger/status pr field from the marker's "pg-run-<key>-<epoch>-<pid>" shape (best-effort;
  # the key may itself contain dashes, so strip the two trailing numeric segments instead)
  PR_NUM="${HARVEST_MARKER#pg-run-}"
  PR_NUM="${PR_NUM%-*-*}"
  command -v node >/dev/null 2>&1 || { echo "ERROR: --harvest needs node for CDP salvage" >&2; pg_status failed "node missing"; pg_finish 3; }
  # Serialize the entire marker harvest. Without this, two collectors can share $OUT.cdp,
  # both read the same completed tab, and one closes it underneath the other (exit 6 + false
  # reservation removal). Linux uses flock; macOS/no-flock uses the existing pg_lock mkdir path.
  HARVEST_LOCK="${PRO_GATE_HARVEST_LOCK_DIR:-$PRO_GATE_HOME/harvest-locks}/${RUN_MARKER}"
  mkdir -p "$(dirname "$HARVEST_LOCK")" 2>/dev/null || { pg_status failed "harvest lock dir unavailable"; pg_finish 3; }
  if ! pg_lock "$HARVEST_LOCK" "${PRO_GATE_HARVEST_LOCK_WAIT:-5}"; then
    echo "ERROR: another harvest is already collecting marker ${RUN_MARKER}; not racing it." >&2
    pg_status failed "harvest already running"
    pg_finish 7
  fi
  # A harvest spends NO Pro slot and only reads over CDP, so the box-fitness parts of
  # pg_health_gate (memory, service uptime) don't apply: memory pressure is likeliest exactly
  # when a long review forced the harvest. Only the account cooldown defers it: salvage renders
  # against a throttled/challenged account deepen the block.
  if GATE_REASON="$(pg_cooldown_active)"; then
    echo "[oracle-review] harvest deferred: ${GATE_REASON}." >&2
    pg_status deferred "$GATE_REASON"
    pg_finish 8
  fi
  # gate #36 P1: if this reserved conversation's tab is no longer open (e.g. Chrome restarted since
  # the exit-9 run) but a prior run captured its URL (preserved: --harvest does not truncate the
  # sidecar), reopen it first so the harvest salvage below reads it through the normal path.
  # Memory-gated; no new spend; only reopens when the tab is actually gone (avoids duplicate tabs).
  if [ "${PRO_GATE_SELF_HEAL_OOM:-1}" = 1 ]; then
    _hv_url="$(head -n1 "$PRO_GATE_CONVURL_OUT" 2>/dev/null || true)"
    if [ -n "$_hv_url" ] && ! node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 5 "$PORT" >/dev/null 2>&1 \
       && pg_mem_headroom_ok >/dev/null 2>&1; then
      echo "[oracle-review] SELF-HEAL: reserved conversation tab not open; reopening it before harvest (no new spend)..." >&2
      pg_reopen_conversation "$_hv_url" "$PORT" || true
    fi
  fi
  HARVEST_SECS="$(pg_dur_secs "$TIMEOUT")"
  echo "[oracle-review] harvesting in-progress review (marker ${RUN_MARKER}, up to ${HARVEST_SECS}s, no new slot spent)..." >&2
  pg_status salvaging "harvest up to ${HARVEST_SECS}s"
  HARVEST_RC=0
  HARVEST_TMP="$OUT.cdp.$$"
  node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "$HARVEST_SECS" "$PORT" > "$HARVEST_TMP" || HARVEST_RC=$?
  if [ "$HARVEST_RC" -eq 0 ] && pg_is_review "$HARVEST_TMP"; then
    mv "$HARVEST_TMP" "$OUT"
    pg_reservation_remove "$RUN_MARKER" || true
    # v0.22: a harvest completes the round the exit-9 run already recorded, so refresh the
    # round budget's last-severity sidecar too. The marker embeds ROUND_KEY
    # ("pg-run-<key>-<epoch>-<pid>") for PR and --diff runs alike; legacy markers resolve to
    # keys with no recorded rounds and are skipped inside the helper (best-effort, advisory).
    HARVEST_KEY="${RUN_MARKER#pg-run-}"; HARVEST_KEY="${HARVEST_KEY%-*-*}"
    pg_round_note_severity "$HARVEST_KEY" "$OUT"
    SALVAGED=1
    echo "[oracle-review] harvest recovered the completed review ($(wc -c < "$OUT" 2>/dev/null) bytes)." >&2
    pg_status done
    cat "$OUT"
    echo "RESULT_FILE=$OUT"
    pg_finish 0
  fi
  rm -f "$HARVEST_TMP"
  case "$HARVEST_RC" in
    3) pg_reservation_write "$RUN_MARKER" "" "$OUT" || true
       echo "[oracle-review] still generating: tab left open; run --harvest again later." >&2
       pg_status in-progress "still generating; retry --harvest later"
       pg_finish 9 ;;
    5) echo "[oracle-review] ChatGPT throttle hit during harvest: cooldown written; retry --harvest after it expires." >&2
       THROTTLED=1
       pg_status deferred "throttle during harvest; retry after cooldown"
       pg_finish 8 ;;
    4) # Confirmed absent THIS probe, which is not yet proof of loss (suspended renderer,
       # hydration): apply the shared consecutive-miss policy instead of destroying the
       # reservation on one observation (dogfood review P1).
       MISS_VERDICT="$(pg_reservation_note_miss "$RUN_MARKER")"
       if [ "$MISS_VERDICT" = released ]; then
         echo "ERROR: no conversation matches marker ${RUN_MARKER} after repeated confirmed misses (review lost or already collected)." >&2
         pg_status failed "harvest found no matching conversation (miss limit reached)"
         pg_finish 6
       fi
       echo "[oracle-review] conversation not found this pass (${MISS_VERDICT}); reservation kept fail-closed. Retry --harvest later." >&2
       pg_status in-progress "harvest miss (${MISS_VERDICT}); retry --harvest later"
       pg_finish 9 ;;
    *) # Runtime trouble (node crash, CDP outage, usage error) or a capture that failed
       # validation: NOT evidence the conversation is gone. Keep the reservation and the tab;
       # exit 3 = engine/browser trouble, safe to retry.
       echo "ERROR: harvest failed (salvage rc=${HARVEST_RC}); reservation and tab kept. Retry --harvest once the browser/CDP is healthy." >&2
       pg_status failed "harvest runtime error rc=${HARVEST_RC}; reservation kept"
       pg_finish 3 ;;
  esac
fi

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

# PR_KEY: repo-scoped identity for locks, reservations, and markers. PR numbers repeat across
# repositories; keying on the bare number let an in-progress repo-A#77 redirect a repo-B#77 gate
# to repo A's conversation (dogfood review P1, 2026-07-10). Derived from the PR URL when known,
# else from the git remote, else the checkout name; sanitized to the marker-safe charset.
REPO_SLUG=""
if [ -n "$PR_URL" ]; then
  REPO_SLUG="$(printf '%s' "$PR_URL" | sed -nE 's#https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\1-\2#p')"
fi
[ -n "$REPO_SLUG" ] || REPO_SLUG="$(git -C "$REPO" remote get-url origin 2>/dev/null \
  | sed -nE 's#.*[:/]([^/]+)/([^/]+?)(\.git)?$#\1-\2#p')"
[ -n "$REPO_SLUG" ] || REPO_SLUG="$(basename "$REPO")"
PR_KEY=""
[ -n "$PR_NUM" ] && PR_KEY="$(printf '%s-%s' "$REPO_SLUG" "$PR_NUM" | tr -c 'A-Za-z0-9.\n-' '-')"

# ROUND_KEY (v0.22): identity for the review round budget. PR runs use PR_KEY. --diff runs loop
# just as hard (ledger: 11 diff re-gates of one worktree in a day) but have no PR number, so
# they key on repo+branch: the unit a review->fix->re-review loop actually iterates on.
if [ -n "$PR_KEY" ]; then
  ROUND_KEY="$PR_KEY"
else
  ROUND_BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  # A detached checkout reports the literal ref name "HEAD" (typical for CI checkouts of a
  # bare SHA): one shared per-repo bucket would cross-cap unrelated diffs, so key those
  # per-commit instead. That under-caps a detached loop that rewrites its SHA every round,
  # but false-capping strangers is the worse failure for a default-on guard.
  if [ -z "$ROUND_BRANCH" ] || [ "$ROUND_BRANCH" = HEAD ]; then
    ROUND_BRANCH="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo detached)"
  fi
  # Disambiguate with a checksum of the RAW identity: sanitization is lossy ("feature/foo"
  # and "feature-foo" both sanitize to "feature-foo"), and colliding keys would share one
  # branch's budget and lock across unrelated branches (dogfood gate P1). The checksum input
  # must be UNSANITIZED end to end: the remote URL (or absolute checkout path) plus the raw
  # branch, never REPO_SLUG, whose owner/repo separator is itself already flattened
  # (a-b/c and a/b-c share a slug; dogfood gate round-2 P1). The human-readable prefix is
  # bounded so a deeply nested ref can never push the key past NAME_MAX, where state writes
  # fail and pg_lock silently proceeds unlocked.
  ROUND_RAW="$(git -C "$REPO" remote get-url origin 2>/dev/null || printf '%s' "$REPO"):${ROUND_BRANCH}"
  ROUND_SUM="$(printf '%s' "$ROUND_RAW" | cksum 2>/dev/null | awk '{print $1}')"
  ROUND_KEY="$(printf '%.120s%s-diff' "${REPO_SLUG}-${ROUND_BRANCH}" "${ROUND_SUM:+-$ROUND_SUM}" | tr -c 'A-Za-z0-9.\n-' '-')"
fi

if [ -z "$DIFF_FILE" ]; then
  DIFF_FILE="$WORK/pr.diff"
  gh pr diff "$PR_NUM" --patch > "$DIFF_FILE" 2>"$WORK/diff.err" || {
    echo "ERROR: gh pr diff $PR_NUM failed in $REPO: $(cat "$WORK/diff.err")" >&2; pg_status failed "gh pr diff failed"; exit 5; }
fi

# --- diff hygiene: drop lockfiles/generated/vendored from the review payload so the Pro model
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

# --- v0.20: diff-size guard: refuse to burn a Pro review slot on a payload that will not
# converge. Ledger data: 984-1402-line diffs complete in 12-21 min; a ~10k-line diff (6.5k
# insertions, 40 files) reasoned 65 minutes without emitting a verdict (2026-07-09, exactly the
# review window the timeout+salvage budgets cannot cover). Oversized diffs exit 11 BEFORE any
# lock or slot is taken, with the delta-scoping recipe on stderr. PRO_GATE_MAX_DIFF_LINES
# raises the cap, PRO_GATE_DIFF_GUARD=0 downgrades the hard stop to a warning.
DIFF_WARN_LINES="${PRO_GATE_DIFF_WARN_LINES:-2500}"
DIFF_MAX_LINES="${PRO_GATE_MAX_DIFF_LINES:-6000}"
if [ "${DIFF_LINES:-0}" -gt "$DIFF_MAX_LINES" ] 2>/dev/null && [ "${PRO_GATE_DIFF_GUARD:-1}" = 1 ]; then
  echo "ERROR: diff is ${DIFF_LINES} lines (> PRO_GATE_MAX_DIFF_LINES=${DIFF_MAX_LINES}): the Pro model does not converge on payloads this size within any review budget; not spending a slot." >&2
  echo "  Scope the gate to what actually needs the final tier, then re-run with the patch:" >&2
  echo "    git -C <repo> diff <last-gated-sha>..<head> -- ':!*.lock' > delta.patch" >&2
  echo "    oracle-review.sh --diff delta.patch --repo <repo> --extra-files '<context globs>' --out <out>" >&2
  echo "  (Or split the PR; or raise PRO_GATE_MAX_DIFF_LINES / set PRO_GATE_DIFF_GUARD=0 to override.)" >&2
  pg_status oversized "diff ${DIFF_LINES} lines > max ${DIFF_MAX_LINES}; scope with --diff"
  pg_finish 11
elif [ "${DIFF_LINES:-0}" -gt "$DIFF_WARN_LINES" ] 2>/dev/null; then
  echo "[oracle-review] WARNING: diff is ${DIFF_LINES} lines (> ${DIFF_WARN_LINES}); large diffs risk exceeding the Pro review window: consider scoping with --diff to the unreviewed delta." >&2
fi

ORACLE_BIN="${PRO_GATE_ORACLE_BIN:-oracle}"
TIMEOUT_BIN="${PRO_GATE_TIMEOUT_BIN:-timeout}"
if [[ "$TIMEOUT_BIN" == */* ]]; then
  [ -x "$TIMEOUT_BIN" ] || { echo "ERROR: configured timeout executable not found: $TIMEOUT_BIN" >&2; pg_status failed "timeout missing"; pg_finish 3; }
else
  pg_have "$TIMEOUT_BIN" || { echo "ERROR: coreutils timeout not installed" >&2; pg_status failed "timeout missing"; pg_finish 3; }
fi
if [[ "$ORACLE_BIN" == */* ]]; then
  [ -x "$ORACLE_BIN" ] || { echo "ERROR: configured oracle executable not found: $ORACLE_BIN" >&2; pg_status failed "oracle missing"; pg_finish 3; }
else
  pg_have "$ORACLE_BIN" || { echo "ERROR: oracle not installed (pnpm add -g @steipete/oracle)" >&2; pg_status failed "oracle missing"; pg_finish 3; }
fi

# --- build the review prompt (the product) ---
# RUN_MARKER (v0.15, pro-gate PR#5 review P1): a per-attempt correlation id
# embedded in the prompt, so the CDP probe/salvage match THIS run's
# conversation tab and never a leftover tab from an earlier review of the
# same PR (which would suppress the retry and serve a stale review for a
# new head). The marker lands in the user message, hence in the tab's
# innerText, without asking the model to echo anything.
# v0.22 (dogfood gate P1): embed ROUND_KEY, not PR_KEY. It is identical for PR runs, but it
# gives --diff runs a real per-change identity instead of the shared literal "diff", so their
# exit-9 reservations can redirect same-branch re-runs to harvest like PR runs always could.
RUN_MARKER="pg-run-${ROUND_KEY:-diff}-$(date +%s)-$$"
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
You are the FINAL, highest-tier code reviewer for a pull request that has ALREADY been through automated review tiers (Claude correctness/security/maintainability personas and a cloud bug+security scan) and their fixes have been applied. The cheap, obvious issues are already gone.

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
  if [ -n "$CONFIRM_FILE" ]; then
    cat <<'EOF'

THIS IS A CONFIRMING PASS: this change was already reviewed once and fixes were applied. The previous review is attached as "prior-review.md". BEFORE anything else, verify EVERY P0 and P1 finding in that prior review against the CURRENT code and list each one as either RESOLVED (with the file:line of the fix) or STILL-PRESENT (report it again as a finding). Only then report genuinely NEW findings per the standard format. Do not re-litigate a prior finding whose fix is present but shaped differently than you would have chosen.
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
# --confirm attaches the prior review REGARDLESS of input mode: the confirming instructions
# in the prompt reference it by the stable name "prior-review.md".
if [ -n "$CONFIRM_FILE" ]; then
  cp "$CONFIRM_FILE" "$WORK/prior-review.md" 2>/dev/null \
    && FILES+=("$WORK/prior-review.md") \
    || { echo "ERROR: could not stage --confirm file: $CONFIRM_FILE" >&2; pg_status failed "confirm file unreadable"; pg_finish 2; }
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

# --- Bound concurrent Pro review runs against the single ChatGPT account ---
# DEFAULT IS SERIALIZED (1). The 2026-07-03 throttle incident showed one account under
# 3 parallel runs (plus their salvage page-loads) trips ChatGPT's anti-scraping limiter
# ("temporarily limited access to your conversations"). PRO_GATE_MAX_CONCURRENCY is the
# CEILING; v0.19's ramp governor (pg_ramp_level) decides the EFFECTIVE slots — earned up
# one level per PRO_GATE_RAMP_STREAK clean runs, dropped to 1 on any throttle. Excess
# callers QUEUE on the semaphore. A SEPARATE per-PR guard ensures the SAME pr is never
# under two simultaneous reviews (that would double-spend a slot on one diff). NOTE:
# oracle itself caps concurrent browser tabs (default 3; since 0.16.0 configurable via the
# ORACLE_BROWSER_MAX_CONCURRENT_TABS env). A ceiling above oracle's cap just queues inside
# oracle unless that env raises the cap to match (the ChatGPT account throttle, not oracle's
# tab cap, is the real limiter, so raising it only helps a genuinely tolerant account).
LOCKFILE="${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}"
LOCK_WAIT="${PRO_GATE_LOCK_WAIT:-2400}"
MAX_CONC="${PRO_GATE_MAX_CONCURRENCY:-1}"
EFF_CONC="$(pg_ramp_level "$MAX_CONC")"

# Housekeeping: per-PR lock files are 0-byte and used to accumulate forever. Sweep ones
# untouched for >24h — any legitimate holder finishes within the ~35 min hard cap. Same for
# per-marker harvest locks (v0.20.2 dogfood left one stale for 10h; flock holders keep the
# file's inode alive, so deleting an unheld file is always safe).
find "$(dirname "$LOCKFILE")" -maxdepth 1 -name "$(basename "$LOCKFILE").pr-*" -mmin +1440 -delete 2>/dev/null || true
find "${PRO_GATE_HARVEST_LOCK_DIR:-$PRO_GATE_HOME/harvest-locks}" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
# Round-budget state (v0.22): entries self-prune on write, but a key never gated again keeps
# its file (and its 0-byte .lock) forever. Sweep files untouched for longer than the rounds
# window (every entry inside is expired), floored at 24h so a short window never deletes a
# lock a live process might hold (same safety argument as the sweeps above).
ROUND_SWEEP_MIN=$(( $(pg_round_window_secs) / 60 ))
[ "$ROUND_SWEEP_MIN" -lt 1440 ] && ROUND_SWEEP_MIN=1440
find "$(pg_rounds_dir)" -maxdepth 1 -type f -mmin "+${ROUND_SWEEP_MIN}" -delete 2>/dev/null || true
# Sweep idle chatgpt.com ROOT tabs (leaked by killed pre-submission runs; the marker-based
# close can't see them, and each is a renderer eating the review box's memory headroom).
# Only when NO oracle CLI is <120s old: a younger one may still be pre-navigation on a root
# tab. Age check engine-side (CDP can't see processes). PRO_GATE_TAB_SWEEP=0 disables.
if [ "$MODE" = remote-chrome ] && [ "${PRO_GATE_TAB_SWEEP:-1}" = 1 ] && command -v node >/dev/null 2>&1; then
  YOUNGEST_ORACLE=999999
  while read -r ORACLE_AGE; do
    case "$ORACLE_AGE" in ''|*[!0-9]*) continue;; esac
    [ "$ORACLE_AGE" -lt "$YOUNGEST_ORACLE" ] && YOUNGEST_ORACLE="$ORACLE_AGE"
  done < <(pgrep -f 'bin/oracle-cli\.js' 2>/dev/null | xargs -r -I{} ps -o etimes= -p {} 2>/dev/null | tr -d ' ')
  if [ "$YOUNGEST_ORACLE" -ge 120 ]; then
    timeout 30 node "$SELF/cdp-salvage.mjs" --sweep-root - 25 "$PORT" 2>&1 | sed 's/^/[oracle-review] /' >&2 || true
  fi
fi

# Reconcile durable reservations from earlier exit-9 runs before dispatch. A same-change
# reservation redirects this invocation to HARVEST instead of spending a second slot. This is
# enforced in the engine (not merely caller docs), so a killed headless caller cannot double-
# spend on its next daemon cycle. v0.22 (dogfood gate P1): keyed by ROUND_KEY so --diff runs
# redirect too; before, their reservations carried the shared literal "diff" and a same-branch
# re-run could submit a duplicate while the first review was still generating. Native mode has
# no marker-addressable CDP, so no reservations are created there.
if [ "$MODE" = remote-chrome ]; then
  pg_reservation_reconcile "$SELF/cdp-salvage.mjs" "$PORT"
  RESERVED_MARKER="$(pg_reservation_find_pr "$ROUND_KEY" 2>/dev/null || true)"
  if [ -n "$RESERVED_MARKER" ]; then
    # Publish the RESERVED conversation's marker, not this invocation's fresh one: callers
    # harvest whatever the status JSON names (dogfood review P1: the fresh marker names a
    # conversation that does not exist).
    RUN_MARKER="$RESERVED_MARKER"
    echo "[oracle-review] ${ROUND_KEY} already has an in-progress Pro conversation (${RESERVED_MARKER}): harvesting it instead of submitting again." >&2
    pg_status in-progress "existing reservation ${RESERVED_MARKER}; harvest required"
    echo "  ${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh --harvest '${RESERVED_MARKER}' --out '${OUT}' --timeout 20m" >&2
    pg_finish 9
  fi
fi

# v0.22: review round budget. Refuse to spend ANOTHER Pro slot on a PR/branch that already
# used its rounds inside the rolling window (default 4 per 24h): unbounded review->fix->
# re-review loops burned 10-16 slots on single PRs (8h+ gates, queue starvation). Checked
# AFTER the reservation redirect above: an in-progress conversation harvests for FREE and must
# never be blocked by the budget. Exit 12, NO quota spent; escalate remaining findings to a
# human instead of re-running.
round_capped() {  # $1 = reason
  # Severity-aware stop note: the budget still refuses the run (severity labels are the
  # reviewer's own claims, exactly the signal observed to oscillate across rounds), but a cap
  # hit while the change's LAST completed review reported P0s is the one case a human may
  # want to grant PRO_GATE_FORCE_ROUND=1, so say it loudly instead of burying it.
  local sev="" last_p0="" last_p1="" note="" pfd inflight=0
  if sev="$(pg_round_last_severity "$ROUND_KEY")"; then
    last_p0="${sev%% *}"; last_p1="${sev##* }"
    note="; last completed review: ${last_p0} P0 / ${last_p1} P1 unconfirmed by a re-review"
  fi
  # Non-blocking probe: a same-change run holding the per-change lock right now means the
  # sidecar note above describes the round BEFORE the one in flight; its completion may
  # change the picture, so tell the human to re-read before granting a forced round (the
  # refusal itself stays correct either way: a recorded spend never un-spends). Skipped when
  # THIS process owns the lock (post-lock re-check site): flock on a second fd would report
  # our own lock as a foreign in-flight run.
  if [ "${CHANGE_LOCK_HELD:-0}" = 1 ]; then
    inflight=0
  elif pg_have flock; then
    if { exec {pfd}>>"${LOCKFILE}.pr-${ROUND_KEY}"; } 2>/dev/null; then
      flock -n "$pfd" 2>/dev/null || inflight=1
      eval "exec ${pfd}>&-" 2>/dev/null
    fi
  elif [ -d "${LOCKFILE}.pr-${ROUND_KEY}.d" ]; then
    inflight=1
  fi
  [ "$inflight" = 1 ] && [ -n "$note" ] && note="${note} (a same-change review is in flight NOW: re-check this note after it completes)"
  echo "ERROR: ${1}; not spending another Pro review slot on this change." >&2
  if [ "${last_p0:-0}" -gt 0 ] 2>/dev/null; then
    echo "  ATTENTION: OPEN P0. The most recent completed review reported ${last_p0} P0 finding(s) that no re-review has confirmed fixed. If the fixes have landed, this is the case PRO_GATE_FORCE_ROUND=1 exists for: surface it to a human now." >&2
    [ "$inflight" = 1 ] && echo "  (A same-change review is in flight right now; wait for it before deciding, its result may already settle these.)" >&2
  fi
  echo "  A gate that keeps cycling review->fix->re-review is not converging: escalate the remaining findings to a human instead." >&2
  echo "  Deliberate override for ONE run: PRO_GATE_FORCE_ROUND=1. Tunables: PRO_GATE_MAX_ROUNDS_PER_PR, PRO_GATE_ROUNDS_WINDOW; PRO_GATE_ROUND_GUARD=0 disables." >&2
  pg_status round-capped "${1}${note}"
  pg_finish 12
}
if ! ROUND_REASON="$(pg_round_guard "$ROUND_KEY")"; then
  round_capped "$ROUND_REASON"
fi

# Per-change guard (acquire BEFORE a slot, so same-change callers serialize without holding a
# scarce slot). Keyed by ROUND_KEY: the repo-scoped PR_KEY for PR runs (bare numbers collide
# across repositories; the lock filename is unchanged for them), repo+branch for --diff runs.
# v0.22: --diff runs serialize here too. Without this, concurrent same-branch diff gates raced
# the round-budget check-then-record window and overshot the cap (review P0: 5 concurrent
# diff runs all passed a cap of 1), and two parallel reviews of one branch are the same
# double-spend the per-PR lock exists to stop.
echo "[oracle-review] per-change guard for ${PR_NUM:+pr #}${PR_NUM:-this diff} (${ROUND_KEY}; serializes same-change reviews)..." >&2
pg_status waiting-pr-lock
if ! pg_lock "${LOCKFILE}.pr-${ROUND_KEY}" "$LOCK_WAIT"; then
  echo "ERROR: timed out after ${LOCK_WAIT}s — ${ROUND_KEY} is already under review elsewhere." >&2
  pg_status failed "per-change lock timeout"
  pg_finish 7
fi
CHANGE_LOCK_HELD=1   # round_capped's in-flight probe must not mistake our own lock for a peer
# The previous same-change process may have exited 9 while we waited and written a reservation
# just before releasing this flock. Re-check now that we own the per-change lock; otherwise
# this waiter would immediately submit a duplicate review.
RESERVED_MARKER="$(pg_reservation_find_pr "$ROUND_KEY" 2>/dev/null || true)"
if [ -n "$RESERVED_MARKER" ]; then
  RUN_MARKER="$RESERVED_MARKER"
  echo "[oracle-review] ${ROUND_KEY} became in-progress while waiting (${RESERVED_MARKER}): harvest required, not resubmitting." >&2
  pg_status in-progress "existing reservation ${RESERVED_MARKER}; harvest required"
  pg_finish 9
fi
# Round-budget re-check for ALL runs, now that we own the per-change lock: the same-change
# run(s) this waiter queued behind may have consumed the last round during the (up to 40 min)
# wait. Check-then-record is race-free from here on because the lock is held until exit.
if ! ROUND_REASON="$(pg_round_guard "$ROUND_KEY")"; then
  round_capped "$ROUND_REASON (spent while this run waited on the per-change lock)"
fi

echo "[oracle-review] acquiring a review slot (effective ${EFF_CONC} of ceiling ${MAX_CONC}; waits up to ${LOCK_WAIT}s if all busy)..." >&2
pg_status waiting-slot "effective ${EFF_CONC} / ceiling ${MAX_CONC}"
# v0.19.1 (pro-gate self-review P1): re-read the ramp level every wait slice — a run that
# queued at level 3 must NOT acquire slot 3 after a concurrent throttle dropped the level
# to 1 mid-wait. Short pg_lock_n slices keep the wait responsive to governor changes.
SLOT_DEADLINE=$(( $(date +%s) + LOCK_WAIT ))
SLOT_OK=0
SLOT_HELD=""
while :; do
  EFF_CONC="$(pg_ramp_level "$MAX_CONC")"
  # Durable reservations occupy real account capacity even though their wrapper process has
  # exited. Slot-tagged reservations EXCLUDE their exact slot from acquisition (shrinking the
  # scan range instead overbooked capacity when a lower-numbered slot freed: dogfood review
  # P1); legacy/out-of-range reservations shrink the range.
  if ! pg_reservation_guard_acquire; then sleep 3; continue; fi
  SLOT_PLAN="$(pg_reservation_slot_plan "$EFF_CONC")"
  SCAN_MAX="${SLOT_PLAN%%|*}"
  SCAN_EXCLUDE="${SLOT_PLAN#*|}"
  # Nonblocking while holding the short handoff guard: waiting here would prevent an active
  # run from writing its reservation before releasing its process slot (writer waits 10s).
  # One immediate scan gives an atomic plan+acquire decision; the outer loop releases the
  # guard and retries.
  if [ "${SCAN_MAX:-0}" -gt 0 ] 2>/dev/null && pg_lock_n "$LOCKFILE" "$SCAN_MAX" 0 "$SCAN_EXCLUDE"; then
    # Keep the acquired process slot, release only the short reservation handoff guard.
    SLOT_HELD="$PG_SLOT_ACQUIRED"
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
# submissions never consumed the Pro thinking window, so the retry is not a
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
  ( stdbuf -oL -eL "$TIMEOUT_BIN" --signal=TERM --kill-after=30 "$HARD_SECS" \
      "$ORACLE_BIN" "${ENGINE_ARGS[@]}" -m "$MODEL" \
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
      # live Pro thought). Before declaring the submission dead, ask
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
# A precious Pro review slot is spent only when the box is fit; a dropped connection is first
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
      echo "ERROR: not spending a Pro review slot (${GATE_REASON})." >&2
      case "$GATE_REASON" in
        *memory*|*thrashing*|*swap*)
          echo "  Your machine is low on memory, so the Pro review browser can't run reliably right now. Nothing was spent. Close some apps / browser tabs / other AI tools to free memory, then retry." >&2 ;;
        *)
          echo "  Deferred (no slot spent). Retry once the box settles, or run on macOS (native Chrome)." >&2 ;;
      esac
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

  # v0.22: this invocation is now committed to spending a slot: record its round (once; the
  # guarded retry below is the same round, and pre-launch exits above never record).
  [ "$attempt" -eq 0 ] && pg_round_record "$ROUND_KEY"

  # A non-blocking heads-up when memory is tight but not blocking (the gate is deliberately
  # conservative, so a swap-heavy box with moderate free RAM still runs). Warns low-memory users
  # BEFORE a long review that a mid-run browser restart is the likely failure mode. Advisory only.
  if [ "$attempt" -eq 0 ] && MEM_NOTE="$(pg_mem_pressure_note)"; then
    echo "[oracle-review] NOTE: ${MEM_NOTE}. Proceeding; if the review fails, this is the likely reason — free memory and retry." >&2
  fi

  # gate #34/#36 P2: capture the browser service's activation GENERATION at the first launch as the
  # restart-detection baseline — this excludes the pre-launch queue, so a Chrome restart before the
  # review launched is not misblamed as this run's OOM. gate #36 P1: also start a lightweight
  # background probe that records the conversation's /c/ URL as soon as it appears — BEFORE any
  # mid-run restart can lose the tab — so the self-heal has a URL to reopen even when the crash
  # happens during ordinary generation (when no other CDP scan would have run yet).
  if [ "$attempt" -eq 0 ]; then
    REVIEW_ACT_BASELINE="$(pg_service_active_epoch || echo '')"
    if [ "$MODE" = remote-chrome ] && [ "${PRO_GATE_SELF_HEAL_OOM:-1}" = 1 ] && command -v node >/dev/null 2>&1; then
      ( node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" "${PRO_GATE_URLCAP_SECS:-$HARD_SECS}" "$PORT" >/dev/null 2>&1 ) &
      URLCAP_PID=$!
    fi
  fi

  echo "[oracle-review] launching the final-tier Pro review (attempt $((attempt + 1)), oracle timeout $TIMEOUT, hard cap ${HARD_SECS}s, stall/no-think watchdog ${STALL_SECS}s/${NOTHINK_SECS}s)..." >&2
  # issue #34 gate P2: fold the memory heads-up into the status detail so background status-polling
  # callers (the primary skill polls <out>.status, not stderr) actually see the advance warning.
  LAUNCH_DETAIL="strategy ${PRO_GATE_MODEL_STRATEGY:-current}"
  [ -n "${MEM_NOTE:-}" ] && LAUNCH_DETAIL="${LAUNCH_DETAIL}; heads-up: ${MEM_NOTE}"
  pg_status launching "$LAUNCH_DETAIL"
  : > "$RUNLOG"; rm -f "$OUT"   # clear any prior attempt's output so stale garbage can't survive
  run_oracle "${PRO_GATE_MODEL_STRATEGY:-current}" || true
  # UI fallback: the requested model was not selectable in the picker (select strategy) -> retry
  # pinned to the account's already-selected model. oracle's wording varies ("model selector",
  # "model picker", "model switcher", "Unable to find model option matching ..."), so match them
  # all: without the switcher/option forms a `select` mismatch failed the WHOLE run instead of
  # falling back (dogfood 2026-07-17, PR #32: `select` + gpt-5.6 emitted "Unable to find model
  # option matching 'GPT-5.6 Sol' in the model switcher" and released the slot without submitting,
  # then the engine burned ~32 min on a pointless salvage). Skip when the primary run was already
  # `current` (a second current pass changes nothing).
  if [ ! -s "$OUT" ] && [ "${PRO_GATE_MODEL_STRATEGY:-current}" != current ] \
     && grep -qiE "model selector|model.?picker|model switcher|unable to find model option" "$RUNLOG" 2>/dev/null; then
    echo "[oracle-review] requested model not selectable in the picker; retrying with --browser-model-strategy current (reviews whichever model your ChatGPT account already has selected)..." >&2
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
    # The challenge PROVES no prompt reached the model: refund this invocation's round so a
    # few challenge hits inside the window cannot exit-12-block a change that spent nothing
    # (dogfood gate round-2 P1). Unknown-fate paths (throttle, watchdogs) never refund.
    pg_round_unrecord "$ROUND_KEY"
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

# v0.21 (R4/R5): capture the model oracle resolved for THIS run from its "Model selection
# evidence: ...; resolved=<label>; status=<st>; ..." line in $RUNLOG, plus the selection status.
# BEST-EFFORT by design: dogfooding PR #20 showed oracle 0.15.2 emits this line at COMPLETION
# (right after it releases the browser slot), NOT early at model selection. So on the fresh
# in-progress/exit-9 path the watchdog kills oracle before the line is emitted and capture yields
# nothing (empty -> role-based fallback, and the reservation persists no model). On the fresh
# SUCCESS path the line is present; under `current` a model that was already selected reports
# resolved=(unavailable); status=already-selected (still healthy). resolved=(unavailable) or
# absence degrades to empty. Mirrors the $RUNLOG session-slug recovery grep above.
if [ -f "$RUNLOG" ]; then
  EVIDENCE_LINE="$(grep -a 'Model selection evidence:' "$RUNLOG" 2>/dev/null | tail -1)"
  if [ -n "$EVIDENCE_LINE" ] && [ "${EVIDENCE_LINE#*resolved=}" != "$EVIDENCE_LINE" ]; then
    RM="${EVIDENCE_LINE#*resolved=}"; RM="${RM%%;*}"; RM="${RM%.}"
    RM="$(printf '%s' "$RM" | tr -d '\t\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$RM" in ''|'(unavailable)') RESOLVED_MODEL="" ;; *) RESOLVED_MODEL="$RM" ;; esac
    if [ "${EVIDENCE_LINE#*status=}" != "$EVIDENCE_LINE" ]; then
      ST="${EVIDENCE_LINE#*status=}"; ST="${ST%%;*}"; ST="${ST%.}"
      MODEL_STATUS="$(printf '%s' "$ST" | tr -d '\t\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    fi
  fi
fi

# v0.21 (R6): soft, advisory downgrade warning (see pg_derive_model_warn). Fires on a weak-model
# denylist match or a genuinely unconfirmable model (killed before oracle reported, or none
# captured); it stays SILENT on the benign `current`+already-selected steady state so it does not
# cry wolf on healthy default runs. A WARN log line plus a status-file marker the composer shows;
# it NEVER changes the exit code.
MODEL_WARN="$(pg_derive_model_warn "$RESOLVED_MODEL" "$MODEL_STATUS")"
[ -n "$MODEL_WARN" ] && echo "[oracle-review] WARNING: ${MODEL_WARN}." >&2

# gate #36 P1: stop the early URL-capture probe. It self-exits once it records the conversation URL
# (or times out); by here the URL is captured, or the last-resort salvage below will record it.
[ -n "${URLCAP_PID:-}" ] && kill "$URLCAP_PID" 2>/dev/null; URLCAP_PID=""

# v0.13: last-resort CDP tab salvage. oracle (historically <=0.15.x; hardened upstream in
# 0.16.0) could fail to DETECT thinking after ChatGPT UI drift even though the submission landed: the
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
  SALVAGE_TMP="$OUT.cdp.$$"
  node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "$SALVAGE_SECS" "$PORT" > "$SALVAGE_TMP" 2>>"$RUNLOG" || SALVAGE_RC=$?
  if [ "$SALVAGE_RC" -eq 0 ] && pg_is_review "$SALVAGE_TMP"; then
    mv "$SALVAGE_TMP" "$OUT"
    echo "[oracle-review] CDP salvage recovered a completed review." >&2
    SALVAGED=1
  else
    rm -f "$SALVAGE_TMP"
  fi
fi

# gate #36 P1/P2 self-heal (issue #35): if the last-resort salvage did NOT recover a review AND the
# browser restarted mid-review (usually OOM) AND we captured the conversation URL before the tab was
# lost, reopen it in the restarted browser and salvage ONCE — memory-gated, no new Pro spend, never
# re-submits. The result feeds the SAME decision below: a recovered review flows through the shared
# success path (finalization intact); a still-generating reopened conversation sets SALVAGE_RC=3 and
# is RESERVED as in-progress (NEVER destroyed); anything else falls through to the failure path.
if ! pg_is_review "$OUT" && [ "${CLOUDFLARE:-0}" != 1 ] && [ "${PRO_GATE_SELF_HEAL_OOM:-1}" = 1 ] \
   && command -v node >/dev/null 2>&1; then
  _heal_up="$(pg_browser_restarted_since "${REVIEW_ACT_BASELINE:-}")" || _heal_up=""
  _heal_url="$(head -n1 "$PRO_GATE_CONVURL_OUT" 2>/dev/null || true)"
  if [ -n "$_heal_up" ] && [ -n "$_heal_url" ] && pg_mem_headroom_ok >/dev/null 2>&1; then
    echo "[oracle-review] SELF-HEAL: the review browser restarted ${_heal_up}s ago (mid-review, likely OOM); reopening the conversation and salvaging it (no new quota)..." >&2
    pg_status salvaging "self-heal: reopening conversation after mid-run restart"
    HEAL_TMP="$OUT.heal.$$"
    if pg_reopen_conversation "$_heal_url" "$PORT"; then
      SALVAGE_RC=0
      node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "${PRO_GATE_RECOVER_SECS:-180}" "$PORT" > "$HEAL_TMP" 2>>"$RUNLOG" || SALVAGE_RC=$?
      if [ "$SALVAGE_RC" -eq 0 ] && pg_is_review "$HEAL_TMP"; then
        mv "$HEAL_TMP" "$OUT"; SALVAGED=1
        echo "[oracle-review] SELF-HEAL recovered the review after the mid-run restart (no new spend)." >&2
      else
        rm -f "$HEAL_TMP"
        echo "[oracle-review] SELF-HEAL: reopened conversation not yet complete (salvage rc=${SALVAGE_RC}); the in-progress/failure handling below applies." >&2
      fi
    else
      rm -f "$HEAL_TMP"
      echo "[oracle-review] SELF-HEAL: could not reopen the conversation tab; falling through." >&2
    fi
  fi
fi

if pg_is_review "$OUT"; then
  # v0.22: remember this review's P0/P1 counts so a later round-capped refusal can flag an
  # unconfirmed open P0 to the human (advisory sidecar; see pg_round_note_severity).
  pg_round_note_severity "$ROUND_KEY" "$OUT"
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
  if ! pg_reservation_write "$RUN_MARKER" "${ROUND_KEY:-diff}" "$OUT" "${SLOT_HELD:-}" "$RESOLVED_MODEL"; then
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
  # Attribute the failure when the review browser restarted mid-review — almost always memory
  # pressure on a small box (Chrome's subprocesses get reclaimed, oracle-chrome restarts, the CDP
  # tab is lost). The self-heal above already TRIED to reopen + recover; reaching here means it
  # could not (no URL captured before the tab was lost, memory still starved, or the conversation is
  # truly gone). Say so plainly so a non-technical user knows what happened and that the review may
  # still exist server-side.
  FAIL_DETAIL="no usable review after salvage"
  if _svc_up="$(pg_browser_restarted_since "${REVIEW_ACT_BASELINE:-}")"; then
    _mem="$(pg_mem_status)"; [ -n "$_mem" ] || _mem="memory usage unknown"
    echo "  LIKELY CAUSE: the review browser (Chrome) restarted ${_svc_up}s ago — mid-review — almost always because the machine ran low on memory (${_mem})." >&2
    echo "  The slot was likely already spent and the review may still exist in ChatGPT, so do NOT immediately re-run. Free memory (close other apps / browser tabs) and try again." >&2
    FAIL_DETAIL="review browser restarted mid-run (chrome up ${_svc_up}s); likely out of memory"
  fi
  pg_status failed "$FAIL_DETAIL"
  pg_finish 6
fi
