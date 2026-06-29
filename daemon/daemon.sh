#!/usr/bin/env bash
# pro-review-daemon — set-and-forget GPT-5.5 Pro Extended final-gate reviewer.
# Watches for open PRs labeled `pro-review`, and for each new head SHA spawns a headless
# Claude Code run of `/pro-gate` (auto-fix, STOP before merge). Fixes-only: never merges.
#
# Trigger:    add the `pro-review` label to a PR in a watched owner.
# Re-review:  push new commits (head SHA changes) -> re-processed automatically.
# Pause:      touch $PRO_GATE_HOME/PAUSE   (resume: rm it)
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in "$SELF/lib.sh" "$SELF/../lib/pro-gate-lib.sh" "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/lib.sh"; do
  [ -f "$c" ] && { . "$c"; break; }
done
type pg_os >/dev/null 2>&1 || { echo "ERROR: pro-gate lib not found (lib.sh)" >&2; exit 10; }
pg_augment_path; pg_load_env
OS="$(pg_os)"; MODE="$(pg_browser_mode)"

ROOT="$PRO_GATE_HOME"
STATE="$ROOT/processed.tsv"          # repo<TAB>pr<TAB>sha  (idempotency)
FAILS="$ROOT/failcount.tsv"          # repo<TAB>pr<TAB>sha  (one line per failed attempt)
LOGDIR="$ROOT/logs"; mkdir -p "$LOGDIR"
PAUSE="$ROOT/PAUSE"
touch "$STATE" "$FAILS"

OWNERS="${PRO_REVIEW_OWNERS:-}"                          # space-separated gh owners to watch (REQUIRED)
POLL="${PRO_REVIEW_POLL_SECONDS:-180}"
LABEL="${PRO_REVIEW_LABEL:-pro-review}"
CLAUDE_MODEL="${PRO_REVIEW_CLAUDE_MODEL:-sonnet}"
FALLBACK_MODEL="${PRO_REVIEW_FALLBACK_MODEL:-haiku}"
MAX_BUDGET="${PRO_REVIEW_MAX_BUDGET_USD:-5}"
MAX_FAILS="${PRO_REVIEW_MAX_FAILS:-3}"
CDP_PORT="${ORACLE_BROWSER_PORT:-9222}"
REPOS_DIR="${PRO_GATE_REPOS_DIR:-$HOME/SITES}"

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*"; }

if [ -z "$OWNERS" ]; then
  log "FATAL: PRO_REVIEW_OWNERS is not set in $ROOT/.env (e.g. PRO_REVIEW_OWNERS=my-org). Idling."
  while true; do sleep 600; pg_load_env; OWNERS="${PRO_REVIEW_OWNERS:-}"; [ -n "$OWNERS" ] && break; done
  log "PRO_REVIEW_OWNERS now set to '$OWNERS' — continuing."
fi

# --- guardrails (universal + best-effort) -----------------------------------
session_up(){
  [ "$MODE" = remote-chrome ] || return 0   # native (macOS): oracle drives Chrome; errors per-run if not signed in
  curl -sf "localhost:${CDP_PORT}/json/version" >/dev/null 2>&1
}

# Optional: only meaningful for codex users. No-op (returns "not tripped") without ~/.codex.
doghouse_tripped(){
  local f="$HOME/.codex/.doghouse"
  [ -f "$f" ] && pg_have node || return 1
  node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(s.until>Date.now()?0:1)}catch{process.exit(1)}' "$f" 2>/dev/null
}

# Optional best-effort account-usage check (codex auth). No-op without creds/jq -> never blocks.
usage_saturated(){
  pg_have jq || return 1
  local tok acct js auth="$HOME/.codex/auth.json"
  [ -f "$auth" ] || return 1
  tok=$(jq -r '.tokens.access_token // empty' "$auth" 2>/dev/null)
  acct=$(jq -r '.tokens.account_id // .tokens.chatgpt_account_id // empty' "$auth" 2>/dev/null)
  [ -z "$tok" ] && return 1
  js=$(curl -s --max-time 10 https://chatgpt.com/backend-api/wham/usage \
        -H "Authorization: Bearer $tok" -H "chatgpt-account-id: $acct" 2>/dev/null)
  [ -z "$js" ] && return 1
  echo "$js" | jq -e '(.rate_limit.allowed==false) or (.rate_limit.limit_reached==true) or ((.rate_limit.primary_window.used_percent // 0)>=90)' >/dev/null 2>&1
}

already_done(){ grep -qF "$(printf '%s\t%s\t%s' "$1" "$2" "$3")" "$STATE"; }
mark_done(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE"; }

# --- find a local checkout of owner/repo ------------------------------------
find_repo(){
  local nwo="$1" name="${1##*/}"
  [ -d "$REPOS_DIR/$name/.git" ] && { echo "$REPOS_DIR/$name"; return; }
  local d dd r
  for d in "$REPOS_DIR"/*/.git; do
    [ -e "$d" ] || continue; dd=${d%/.git}
    r=$(git -C "$dd" config --get remote.origin.url 2>/dev/null)
    case "$r" in *"$nwo"*) echo "$dd"; return;; esac
  done
}

# --- process one PR ---------------------------------------------------------
process_pr(){
  local nwo="$1" num="$2" sha="$3" branch="$4" url="$5"
  local slug="${nwo//\//-}-${num}"
  local repodir; repodir="$(find_repo "$nwo")"
  if [ -z "$repodir" ]; then
    log "  ! no local checkout for $nwo under $REPOS_DIR — skipping (clone it there to enable)"; return 1
  fi

  local wt="${TMPDIR:-/tmp}/pro-review-${slug}"
  local lg="$LOGDIR/${slug}-$(date +%s).log"
  log "  → reviewing $nwo#$num @ ${sha:0:8} (branch $branch); repo=$repodir log=$lg"

  ( cd "$repodir" && git fetch --quiet origin "$branch" 2>/dev/null )
  git -C "$repodir" worktree remove --force "$wt" 2>/dev/null || true
  if ! git -C "$repodir" worktree add --force "$wt" "origin/$branch" >>"$lg" 2>&1; then
    log "  ! worktree add failed for $nwo#$num (see $lg)"; return 1
  fi
  ( cd "$wt" && git switch -C "$branch" "origin/$branch" >>"$lg" 2>&1 || git checkout -B "$branch" >>"$lg" 2>&1 )

  # Headless Claude runs the /pro-gate skill (which picks the best available fixer). Ironclad: never merge.
  local prompt="Run the /pro-gate skill for PR #${num} (${url}) in this repository in auto-fix mode: get the GPT-5.5 Pro Extended review, sanity-check each P0/P1 finding against the actual code, apply the confirmed fixes on this branch, run available tests/lint, commit as 'fix(pro-gate): <summary>', push to origin/${branch}, and post ONE PR comment containing the full Pro Extended review plus what you fixed.
CRITICAL: do NOT merge the PR, do NOT open new PRs, do NOT change the base branch. Stop after pushing fixes and posting the comment. If no fixes are warranted, just post the review summary comment and stop."

  ( cd "$wt" && timeout 5400 claude -p "$prompt" \
        --model "$CLAUDE_MODEL" \
        --fallback-model "$FALLBACK_MODEL" \
        --max-budget-usd "$MAX_BUDGET" \
        --add-dir "$wt" \
        --dangerously-skip-permissions \
        --output-format text >>"$lg" 2>&1 )
  local rc=$?
  git -C "$repodir" worktree remove --force "$wt" 2>/dev/null || true

  if [ $rc -eq 0 ]; then
    mark_done "$nwo" "$num" "$sha"
    # The fix push changes the head SHA — mark the daemon's OWN resulting commit done too,
    # so it never re-triggers on its own push (only a later HUMAN push re-reviews the PR).
    local newsha; newsha=$(gh pr view "$num" -R "$nwo" --json headRefOid -q .headRefOid 2>/dev/null)
    [ -n "$newsha" ] && [ "$newsha" != "$sha" ] && mark_done "$nwo" "$num" "$newsha"
    log "  ✓ done $nwo#$num (rc=0; head now ${newsha:0:8})"
  else
    printf '%s\t%s\t%s\n' "$nwo" "$num" "$sha" >> "$FAILS"
    local fc; fc=$(grep -cF "$(printf '%s\t%s\t%s' "$nwo" "$num" "$sha")" "$FAILS" 2>/dev/null || echo 1)
    if [ "${fc:-1}" -ge "$MAX_FAILS" ]; then
      log "  ✗ $nwo#$num failed ${fc}x at ${sha:0:8} — giving up (marking done; fix manually or re-push to retry). log $lg"
      mark_done "$nwo" "$num" "$sha"
    else
      log "  ! claude run failed for $nwo#$num (rc=$rc, attempt ${fc}/${MAX_FAILS}) — will retry next cycle (log $lg)"
    fi
  fi
}

# --- main loop --------------------------------------------------------------
log "pro-review-daemon starting (os=$OS mode=$MODE owners='$OWNERS' label='$LABEL' poll=${POLL}s model=$CLAUDE_MODEL)"
while true; do
  if [ -f "$PAUSE" ]; then log "PAUSE present — idling"; sleep "$POLL"; continue; fi
  if ! session_up; then log "browser session down — idling"; sleep "$POLL"; continue; fi
  if doghouse_tripped; then log "codex doghouse tripped — idling"; sleep "$POLL"; continue; fi
  if usage_saturated; then log "account usage saturated (>=90% / limit) — idling"; sleep "$POLL"; continue; fi

  found=0
  for owner in $OWNERS; do
    prs=$(gh search prs --owner "$owner" --label "$LABEL" --state open --limit 30 \
            --json 'repository,number,url' 2>/dev/null)
    [ -z "$prs" ] && continue
    while IFS=$'\t' read -r nwo num url; do
      [ -z "$nwo" ] && continue
      meta=$(gh pr view "$num" -R "$nwo" --json headRefOid,headRefName 2>/dev/null)
      sha=$(echo "$meta" | jq -r '.headRefOid // empty'); branch=$(echo "$meta" | jq -r '.headRefName // empty')
      [ -z "$sha" ] && continue
      already_done "$nwo" "$num" "$sha" && continue
      found=1
      process_pr "$nwo" "$num" "$sha" "$branch" "$url"
      [ -f "$PAUSE" ] && break
    done < <(echo "$prs" | jq -r '.[] | [.repository.nameWithOwner, (.number|tostring), .url] | @tsv')
  done
  [ "$found" -eq 0 ] && log "no labeled PRs pending"
  sleep "$POLL"
done
