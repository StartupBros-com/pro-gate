#!/usr/bin/env bash
# oracle-review.sh — run a GPT-5.5 Pro Extended FINAL-TIER review of a PR (or diff) via oracle.
# Single source of truth for "how we call oracle for a review" — the /pro-gate skill and the
# daemon both call this. Cross-platform: macOS drives signed-in Chrome natively; WSL/Linux
# attaches to the durable Xvfb Chrome over CDP.
#
# Usage:
#   oracle-review.sh --pr <url|number> [--repo <dir>] [--input both|bundle|connector]
#                    [--out <file>] [--timeout <dur>] [--extra-files <glob>]
#   oracle-review.sh --diff <patchfile> --repo <dir> [--out <file>] ...
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

PR=""; REPO=""; DIFF_FILE=""; INPUT="both"; OUT=""; TIMEOUT="30m"; EXTRA_GLOB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --diff) DIFF_FILE="$2"; shift 2;;
    --input) INPUT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --extra-files) EXTRA_GLOB="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

PORT="${ORACLE_BROWSER_PORT:-9222}"
MODEL="${ORACLE_MODEL:-gpt-5.5-pro}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pro-review.XXXXXX")"
[ -n "$OUT" ] || OUT="$WORK/findings.md"
pg_have oracle || { echo "ERROR: oracle not installed (pnpm add -g @steipete/oracle)" >&2; exit 3; }

# --- machine-readable run status (v0.18) ---
# Callers (the /pro-gate skill, the daemon's headless agent) poll "$OUT.status" — a
# single-line JSON updated ATOMICALLY at every phase change — instead of scraping the
# engine's stderr. Phases: preflight, waiting-pr-lock, waiting-slot, launching,
# watchdog-killed, live-detected, salvaging, retry-wait, throttled, deferred, done, failed.
# Terminal phases: done (read $OUT), failed, deferred (no slot spent — retry later).
STATUS_FILE="$OUT.status"
pg_status() {  # $1 phase, $2 optional detail (keep both free of double quotes)
  printf '{"phase":"%s","attempt":%d,"detail":"%s","pr":"%s","out":"%s","ts":"%s"}\n' \
    "$1" "${attempt:-0}" "${2:-}" "${PR_NUM:-diff}" "$OUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    > "$STATUS_FILE.tmp" 2>/dev/null && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null || true
}
pg_status preflight

# --- preflight: browser reachable / signed in (per platform) ---
if [ "$MODE" = "remote-chrome" ]; then
  export DISPLAY="${ORACLE_DISPLAY:-:99}"
  if ! curl -sf "localhost:${PORT}/json/version" >/dev/null 2>&1; then
    echo "ERROR: oracle browser session (CDP) not reachable on ${PORT}." >&2
    [ "$(pg_service_mgr)" = systemd ] && echo "  start it: sudo systemctl start oracle-chrome" >&2
    pg_status failed "browser CDP unreachable"
    exit 3
  fi
else
  # native (macOS): oracle drives your signed-in Chrome. Nothing to pre-start; oracle errors
  # clearly if you're not signed into ChatGPT.
  :
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

# --- Bound concurrent Pro Extended runs against the single ChatGPT account ---
# DEFAULT IS SERIALIZED (1). The 2026-07-03 throttle incident showed one account under
# 3 parallel runs (plus their salvage page-loads) trips ChatGPT's anti-scraping limiter
# ("temporarily limited access to your conversations"). Raise PRO_GATE_MAX_CONCURRENCY
# only if your account demonstrably tolerates it; excess callers QUEUE on the semaphore.
# A SEPARATE per-PR guard ensures the SAME pr is never under two simultaneous reviews
# (that would double-spend a slot on one diff). Both auto-release at exit.
LOCKFILE="${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}"
LOCK_WAIT="${PRO_GATE_LOCK_WAIT:-2400}"
MAX_CONC="${PRO_GATE_MAX_CONCURRENCY:-1}"

# Housekeeping: per-PR lock files are 0-byte and used to accumulate forever. Sweep ones
# untouched for >24h — any legitimate holder finishes within the ~35 min hard cap.
find "$(dirname "$LOCKFILE")" -maxdepth 1 -name "$(basename "$LOCKFILE").pr-*" -mmin +1440 -delete 2>/dev/null || true

# Per-PR guard (acquire BEFORE a slot, so same-PR callers serialize without holding a scarce slot).
if [ -n "${PR_NUM}" ]; then
  echo "[oracle-review] per-PR guard for pr #${PR_NUM} (serializes same-PR reviews)..." >&2
  pg_status waiting-pr-lock
  if ! pg_lock "${LOCKFILE}.pr-${PR_NUM}" "$LOCK_WAIT"; then
    echo "ERROR: timed out after ${LOCK_WAIT}s — pr #${PR_NUM} is already under review elsewhere." >&2
    pg_status failed "per-PR lock timeout"
    exit 7
  fi
fi

echo "[oracle-review] acquiring a review slot (up to ${MAX_CONC} concurrent; waits up to ${LOCK_WAIT}s if all busy)..." >&2
pg_status waiting-slot
if ! pg_lock_n "$LOCKFILE" "$MAX_CONC" "$LOCK_WAIT"; then
  echo "ERROR: timed out after ${LOCK_WAIT}s — all ${MAX_CONC} review slots are busy." >&2
  pg_status failed "slot timeout"
  exit 7
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
      oracle "${ENGINE_ARGS[@]}" -m "$MODEL" \
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
        node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 >/dev/null 2>>"$RUNLOG"; prc=$?
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
      exit 8
    fi
    echo "[oracle-review] not retrying (${GATE_REASON}) — falling through to salvage." >&2
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
    node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 >/dev/null 2>>"$RUNLOG"; PRC=$?
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
  echo "[oracle-review] pre-retry probe found no conversation for this run — dead submission confirmed. Retrying once after ${BACKOFF}s + a health re-check..." >&2
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
if ! pg_is_review "$OUT" && command -v node >/dev/null 2>&1; then
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
  if node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "$SALVAGE_SECS" > "$OUT.cdp" 2>>"$RUNLOG" && pg_is_review "$OUT.cdp"; then
    mv "$OUT.cdp" "$OUT"
    echo "[oracle-review] CDP salvage recovered a completed review." >&2
  else
    rm -f "$OUT.cdp"
  fi
fi

if pg_is_review "$OUT"; then
  pg_status done
  cat "$OUT"
  echo "RESULT_FILE=$OUT"
  exit 0
else
  RETRIES=$(( attempt > 0 ? attempt - 1 : 0 ))
  echo "ERROR: oracle produced no usable review after salvage + ${RETRIES} retr$([ "${RETRIES}" -eq 1 ] && echo y || echo ies) (reattach: oracle session ${SLUG_BASE})." >&2
  pg_status failed "no usable review after salvage"
  exit 6
fi
