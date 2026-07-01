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

# --- preflight: browser reachable / signed in (per platform) ---
if [ "$MODE" = "remote-chrome" ]; then
  export DISPLAY="${ORACLE_DISPLAY:-:99}"
  if ! curl -sf "localhost:${PORT}/json/version" >/dev/null 2>&1; then
    echo "ERROR: oracle browser session (CDP) not reachable on ${PORT}." >&2
    [ "$(pg_service_mgr)" = systemd ] && echo "  start it: sudo systemctl start oracle-chrome" >&2
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
cd "$REPO" || { echo "ERROR: repo dir not found: $REPO" >&2; exit 4; }
[ -n "$PR_URL" ] || PR_URL="$(gh pr view "$PR_NUM" --json url -q .url 2>/dev/null || echo "")"

if [ -z "$DIFF_FILE" ]; then
  DIFF_FILE="$WORK/pr.diff"
  gh pr diff "$PR_NUM" --patch > "$DIFF_FILE" 2>"$WORK/diff.err" || {
    echo "ERROR: gh pr diff $PR_NUM failed in $REPO: $(cat "$WORK/diff.err")" >&2; exit 5; }
fi

# --- diff hygiene: drop lockfiles/generated/vendored from the review payload so Pro Extended
# spends its (finite, disconnect-exposed) thinking window on real code, not lockfile churn. ---
if [ -s "$DIFF_FILE" ] && [ "${PRO_GATE_DIFF_FILTER:-1}" = 1 ]; then
  FILTERED="$WORK/pr.filtered.diff"
  if pg_filter_diff "$DIFF_FILE" "$FILTERED" 2>"$WORK/excluded.raw" && [ -s "$FILTERED" ]; then
    # a path can appear in several per-commit patches (gh pr diff --patch) — dedupe for the report
    sort -u "$WORK/excluded.raw" 2>/dev/null > "$WORK/excluded.txt" || cp "$WORK/excluded.raw" "$WORK/excluded.txt"
    NEX=$(grep -c . "$WORK/excluded.txt" 2>/dev/null || echo 0)
    if [ "${NEX:-0}" -gt 0 ]; then
      echo "[oracle-review] diff hygiene: excluded ${NEX} noise file(s) from the payload: $(paste -sd', ' "$WORK/excluded.txt" 2>/dev/null | cut -c1-200)" >&2
      DIFF_FILE="$FILTERED"
    fi
  fi
fi

DIFF_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo 0)
echo "[oracle-review] os=$OS mode=$MODE repo=$REPO pr=#${PR_NUM} url=${PR_URL:-n/a} diff_lines=$DIFF_LINES input=$INPUT" >&2

# --- build the review prompt (the product) ---
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
# Up to PRO_GATE_MAX_CONCURRENCY reviews run at once (the account tolerates several parallel chats);
# excess callers QUEUE on the semaphore. A SEPARATE per-PR guard ensures the SAME pr is never under
# two simultaneous reviews (that would double-spend a slot on one diff). Both auto-release at exit.
LOCKFILE="${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}"
LOCK_WAIT="${PRO_GATE_LOCK_WAIT:-2400}"
MAX_CONC="${PRO_GATE_MAX_CONCURRENCY:-3}"

# Per-PR guard (acquire BEFORE a slot, so same-PR callers serialize without holding a scarce slot).
if [ -n "${PR_NUM}" ]; then
  echo "[oracle-review] per-PR guard for pr #${PR_NUM} (serializes same-PR reviews)..." >&2
  if ! pg_lock "${LOCKFILE}.pr-${PR_NUM}" "$LOCK_WAIT"; then
    echo "ERROR: timed out after ${LOCK_WAIT}s — pr #${PR_NUM} is already under review elsewhere." >&2
    exit 7
  fi
fi

echo "[oracle-review] acquiring a review slot (up to ${MAX_CONC} concurrent; waits up to ${LOCK_WAIT}s if all busy)..." >&2
if ! pg_lock_n "$LOCKFILE" "$MAX_CONC" "$LOCK_WAIT"; then
  echo "ERROR: timed out after ${LOCK_WAIT}s — all ${MAX_CONC} review slots are busy." >&2
  exit 7
fi

RUNLOG="$WORK/oracle.log"
run_oracle() {  # $1 = browser model strategy (select|current|ignore)
  stdbuf -oL -eL oracle "${ENGINE_ARGS[@]}" -m "$MODEL" \
    --browser-model-strategy "$1" \
    --slug "pro gate review pr ${PR_NUM:-diff}" \
    "${URL_ARGS[@]}" "${FILE_ARGS[@]}" \
    -p "$(cat "$PROMPT_FILE")" \
    --no-notify --timeout "$TIMEOUT" \
    --write-output "$OUT" 2>&1 | tee -a "$RUNLOG" | stdbuf -oL sed 's/^/[oracle] /' >&2
  return "${PIPESTATUS[0]}"
}

# --- spend the slot: health-gate -> run -> salvage -> one guarded retry ---
# A precious Pro Extended slot is spent only when the box is fit; a dropped connection is first
# SALVAGED (the answer may have finished server-side), and only a truly-lost run is retried once.
# Exit 8 = deferred (no slot spent); exit 6 = ran but produced nothing after salvage + retry.
SLUG_BASE="pro-gate-review-pr-${PR_NUM:-diff}"
REATTACH_TIMEOUT="${PRO_GATE_REATTACH_TIMEOUT:-150}"
MAX_RETRIES="${PRO_GATE_MAX_RETRIES:-1}"
BACKOFF="${PRO_GATE_RETRY_BACKOFF:-20}"
attempt=0
while :; do
  if ! GATE_REASON="$(pg_health_gate)"; then
    echo "ERROR: not spending a Pro Extended slot — ${GATE_REASON}." >&2
    echo "  Deferred (no slot spent). Retry once the box settles, or run on macOS (native Chrome)." >&2
    exit 8
  fi

  echo "[oracle-review] launching GPT-5.5 Pro Extended review (attempt $((attempt + 1)), timeout $TIMEOUT)..." >&2
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

  # No output. The generation may have COMPLETED server-side after a dropped Chrome connection —
  # try a bounded salvage (never hangs) before spending another slot. Capture the slug oracle
  # actually used (it may differ from SLUG_BASE on a collision, e.g. ...-pr-804-2).
  SLUG="$(grep -oE 'oracle session [A-Za-z0-9._-]+' "$RUNLOG" 2>/dev/null | tail -1 | awk '{print $NF}')"
  [ -n "$SLUG" ] || SLUG="$SLUG_BASE"
  echo "[oracle-review] no output — bounded salvage via reattach (session ${SLUG}, ${REATTACH_TIMEOUT}s)..." >&2
  if pg_reattach_render "$SLUG" "$OUT" "$REATTACH_TIMEOUT"; then
    echo "[oracle-review] salvaged a completed review via reattach." >&2
    break
  fi

  attempt=$((attempt + 1))
  [ "$attempt" -gt "$MAX_RETRIES" ] && break
  echo "[oracle-review] review lost (likely a transient Chrome/connection drop, not a quota issue). Retrying once after ${BACKOFF}s + a health re-check..." >&2
  sleep "$BACKOFF"
done

if pg_is_review "$OUT"; then
  cat "$OUT"
  echo "RESULT_FILE=$OUT"
  exit 0
else
  echo "ERROR: oracle produced no usable review after salvage + ${attempt} retr$([ "${attempt:-0}" -eq 1 ] && echo y || echo ies) (reattach: oracle session ${SLUG_BASE})." >&2
  exit 6
fi
