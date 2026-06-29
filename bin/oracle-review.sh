#!/usr/bin/env bash
# oracle-review.sh — run a GPT-5.5 Pro Extended FINAL-TIER review of a PR (or diff)
# via the durable oracle-chrome.service browser session. Single source of truth for
# "how we call oracle for a review" — the /pro-gate skill and the daemon both call this.
#
# Usage:
#   oracle-review.sh --pr <url|number> [--repo <dir>] [--input both|bundle|connector]
#                    [--out <file>] [--timeout <dur>] [--extra-files <glob>]
#   oracle-review.sh --diff <patchfile> --repo <dir> [--out <file>] ...
#
# Output: writes the Pro Extended findings to --out (default: stdout + a temp file path
# echoed on the last line as  RESULT_FILE=<path>).
set -uo pipefail

export PATH=/home/will/.local/bin:/home/will/.local/share/mise/installs/node/24.13.1/bin:/usr/local/bin:/usr/bin:/bin
set -a; [ -f /home/will/.pro-review-daemon/.env ] && source /home/will/.pro-review-daemon/.env; set +a
export DISPLAY="${ORACLE_DISPLAY:-:99}"

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
WORK="$(mktemp -d /tmp/pro-review.XXXXXX)"
[ -n "$OUT" ] || OUT="$WORK/findings.md"

# --- preflight: browser session must be up + signed in ---
if ! curl -sf "localhost:${PORT}/json/version" >/dev/null 2>&1; then
  echo "ERROR: oracle-chrome.service CDP not reachable on ${PORT}. Start it: sudo systemctl start oracle-chrome" >&2
  exit 3
fi

# --- resolve repo + PR, assemble the diff (ground truth) ---
PR_URL=""; PR_NUM=""
if [ -n "$PR" ]; then
  if [[ "$PR" =~ ^https?:// ]]; then
    PR_URL="$PR"; PR_NUM="${PR##*/}"
    # derive repo dir from URL if not given: github.com/<owner>/<name>/pull/<n>
    if [ -z "$REPO" ]; then
      NAME="$(printf '%s' "$PR_URL" | sed -E 's#https?://github.com/[^/]+/([^/]+)/pull/.*#\1#')"
      [ -d "$HOME/SITES/$NAME" ] && REPO="$HOME/SITES/$NAME"
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
DIFF_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo 0)
echo "[oracle-review] repo=$REPO pr=#${PR_NUM} url=${PR_URL:-n/a} diff_lines=$DIFF_LINES input=$INPUT" >&2

# --- build the review prompt (the product) ---
PROMPT_FILE="$WORK/prompt.md"
{
  # Belt-and-suspenders connector nudge: the literal @GitHub tag (ChatGPT recognizes it even
  # though oracle's paste doesn't render it as a real mention pill) PLUS an explicit instruction
  # to use the connector for anything GitHub-related. (ORACLE_CHATGPT_URL can also pin a
  # connector-bound Project.)
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

# --- run oracle against the durable session ---
echo "[oracle-review] launching GPT-5.5 Pro Extended review (timeout $TIMEOUT)..." >&2
FILE_ARGS=(); for f in "${FILES[@]:-}"; do [ -n "$f" ] && FILE_ARGS+=(--file "$f"); done
# Route through a connector-bound ChatGPT Project when configured (pre-binds GitHub).
URL_ARGS=()
if [ -n "${ORACLE_CHATGPT_URL:-}" ] && [ "${ORACLE_CHATGPT_URL}" != "https://chatgpt.com/" ]; then
  URL_ARGS+=(--chatgpt-url "$ORACLE_CHATGPT_URL")
fi

# --- Serialize Pro Extended runs against the single shared ChatGPT account ---
# Oracle has NO cross-process limit in --remote-chrome mode (verified in source: the tab-lease
# registry only activates with --browser-manual-login). One Pro account cannot take many
# simultaneous generations, so concurrent callers (e.g. 10 agents) QUEUE on this lock and run
# one-at-a-time. Lock auto-releases when fd 9 closes at script exit.
LOCKFILE="${PRO_GATE_LOCKFILE:-/home/will/.pro-review-daemon/oracle.lock}"
LOCK_WAIT="${PRO_GATE_LOCK_WAIT:-2400}"
exec 9>"$LOCKFILE" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  echo "[oracle-review] acquiring review lock (serialized; waits up to ${LOCK_WAIT}s if busy)..." >&2
  if ! flock -w "$LOCK_WAIT" 9; then
    echo "ERROR: timed out after ${LOCK_WAIT}s waiting for the review lock — another Pro Extended review is running. Re-run later." >&2
    exit 7
  fi
  echo "[oracle-review] lock acquired; running." >&2
fi

stdbuf -oL -eL oracle -e browser --remote-chrome "127.0.0.1:${PORT}" -m "$MODEL" \
  --browser-model-strategy select \
  --slug "pro gate review pr ${PR_NUM:-diff}" \
  "${URL_ARGS[@]}" "${FILE_ARGS[@]}" \
  -p "$(cat "$PROMPT_FILE")" \
  --no-notify --timeout "$TIMEOUT" \
  --write-output "$OUT" 2>&1 | stdbuf -oL sed 's/^/[oracle] /' >&2

if [ -s "$OUT" ]; then
  echo "[oracle-review] findings written." >&2
  cat "$OUT"
  echo "RESULT_FILE=$OUT"
  exit 0
else
  echo "ERROR: oracle produced no output (may have detached on timeout — reattach: oracle session pro-gate-review-pr-${PR_NUM:-diff})" >&2
  exit 6
fi
