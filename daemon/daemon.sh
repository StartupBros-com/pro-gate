#!/usr/bin/env bash
# pro-review-daemon — set-and-forget GPT-5.5 Pro Extended final-gate reviewer.
# Watches for open PRs labeled `pro-review`, and for each new head SHA spawns a headless
# Claude Code run of `/pro-gate` (auto-fix, STOP before merge). Fixes-only: never merges.
#
# Trigger:    add the `pro-review` label to a PR (any configured owner/repo).
# Re-review:  push new commits (head SHA changes) -> re-processed automatically.
# Pause:      touch ~/.pro-review-daemon/PAUSE   (resume: rm it)
set -uo pipefail

ENV_FILE=/home/will/.pro-review-daemon/.env
set -a; [ -f "$ENV_FILE" ] && source "$ENV_FILE"; set +a

ROOT=/home/will/.pro-review-daemon
STATE="$ROOT/processed.tsv"          # repo<TAB>pr<TAB>sha  (idempotency)
FAILS="$ROOT/failcount.tsv"          # repo<TAB>pr<TAB>sha  (one line per failed attempt)
LOGDIR="$ROOT/logs"; mkdir -p "$LOGDIR"
PAUSE="$ROOT/PAUSE"
touch "$STATE" "$FAILS"

OWNERS="${PRO_REVIEW_OWNERS:-StartupBros-com}"          # space-separated gh owners to watch
POLL="${PRO_REVIEW_POLL_SECONDS:-180}"                  # idle poll interval
LABEL="${PRO_REVIEW_LABEL:-pro-review}"
CLAUDE_MODEL="${PRO_REVIEW_CLAUDE_MODEL:-sonnet}"       # orchestrator model (deep reasoning is in Pro Extended + codex)
FALLBACK_MODEL="${PRO_REVIEW_FALLBACK_MODEL:-haiku}"    # claude -p resilience on model overload
MAX_BUDGET="${PRO_REVIEW_MAX_BUDGET_USD:-5}"            # hard $ ceiling per PR (headless claude bills API credits)
MAX_FAILS="${PRO_REVIEW_MAX_FAILS:-3}"                  # give up on a PR+SHA after this many failed attempts
CDP_PORT="${ORACLE_BROWSER_PORT:-9222}"

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# --- guardrails -------------------------------------------------------------
session_up(){ curl -sf "localhost:${CDP_PORT}/json/version" >/dev/null 2>&1; }

doghouse_tripped(){
  local f=/home/will/.codex/.doghouse
  [ -f "$f" ] || return 1
  node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(s.until>Date.now()?0:1)}catch{process.exit(1)}' "$f" 2>/dev/null
}

usage_saturated(){   # best-effort: account-level signal via the same endpoint the doghouse uses
  local tok acct js
  tok=$(jq -r '.tokens.access_token // empty' /home/will/.codex/auth.json 2>/dev/null)
  acct=$(jq -r '.tokens.account_id // .tokens.chatgpt_account_id // empty' /home/will/.codex/auth.json 2>/dev/null)
  [ -z "$tok" ] && return 1   # can't determine -> don't block
  js=$(curl -s --max-time 10 https://chatgpt.com/backend-api/wham/usage \
        -H "Authorization: Bearer $tok" -H "chatgpt-account-id: $acct" 2>/dev/null)
  [ -z "$js" ] && return 1
  echo "$js" | jq -e '(.rate_limit.allowed==false) or (.rate_limit.limit_reached==true) or ((.rate_limit.primary_window.used_percent // 0)>=90)' >/dev/null 2>&1
}

already_done(){ grep -qF "$(printf '%s\t%s\t%s' "$1" "$2" "$3")" "$STATE"; }
mark_done(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE"; }

# --- process one PR ---------------------------------------------------------
process_pr(){
  local nwo="$1" num="$2" sha="$3" branch="$4" url="$5"
  local slug="${nwo//\//-}-${num}"
  local repodir="$HOME/SITES/${nwo##*/}"
  # fall back: try to find a local checkout of this repo by remote
  if [ ! -d "$repodir/.git" ]; then
    repodir=$(for d in "$HOME"/SITES/*/.git; do
                dd=${d%/.git}; r=$(git -C "$dd" config --get remote.origin.url 2>/dev/null)
                case "$r" in *"$nwo"*) echo "$dd"; break;; esac
              done)
  fi
  if [ -z "$repodir" ] || [ ! -d "$repodir/.git" ]; then
    log "  ! no local checkout for $nwo — skipping (clone it under ~/SITES to enable)"; return 1
  fi

  local wt="/tmp/pro-review-${slug}"
  local lg="$LOGDIR/${slug}-$(date +%s).log"
  log "  → reviewing $nwo#$num @ ${sha:0:8} (branch $branch); repo=$repodir log=$lg"

  ( cd "$repodir" && git fetch --quiet origin "$branch" 2>/dev/null )
  git -C "$repodir" worktree remove --force "$wt" 2>/dev/null || true
  if ! git -C "$repodir" worktree add --force "$wt" "origin/$branch" >>"$lg" 2>&1; then
    log "  ! worktree add failed for $nwo#$num (see $lg)"; return 1
  fi
  ( cd "$wt" && git switch -C "$branch" "origin/$branch" >>"$lg" 2>&1 || git checkout -B "$branch" >>"$lg" 2>&1 )

  # Headless Claude runs the final-gate pipeline. Explicit, ironclad: never merge.
  local prompt="Run the /pro-gate skill for PR #${num} (${url}) in this repository, in auto-fix mode.
Steps: run the GPT-5.5 Pro Extended review via ~/.pro-review-daemon/oracle-review.sh, sanity-check each P0/P1 finding against the actual code, apply the confirmed fixes on this branch (prefer codex via ce-work-beta delegate:codex), run available tests/lint, commit as fix(pro-gate): <summary>, push to origin/${branch}, and post ONE PR comment containing the full Pro Extended review plus what you fixed.
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
log "pro-review-daemon starting (owners='$OWNERS' label='$LABEL' poll=${POLL}s model=$CLAUDE_MODEL)"
while true; do
  if [ -f "$PAUSE" ]; then log "PAUSE present — idling"; sleep "$POLL"; continue; fi
  if ! session_up; then log "oracle-chrome session down — idling (start: sudo systemctl start oracle-chrome)"; sleep "$POLL"; continue; fi
  if doghouse_tripped; then log "codex doghouse tripped — idling"; sleep "$POLL"; continue; fi
  if usage_saturated; then log "account usage saturated (>=90% / limit) — idling"; sleep "$POLL"; continue; fi

  found=0
  for owner in $OWNERS; do
    prs=$(gh search prs --owner "$owner" --label "$LABEL" --state open --limit 30 \
            --json 'repository,number,url' 2>/dev/null)
    [ -z "$prs" ] && continue
    while IFS=$'\t' read -r nwo num url; do
      [ -z "$nwo" ] && continue
      # resolve head sha + branch (search payload omits them)
      meta=$(gh pr view "$num" -R "$nwo" --json headRefOid,headRefName 2>/dev/null)
      sha=$(echo "$meta" | jq -r '.headRefOid // empty'); branch=$(echo "$meta" | jq -r '.headRefName // empty')
      [ -z "$sha" ] && continue
      already_done "$nwo" "$num" "$sha" && continue
      found=1
      process_pr "$nwo" "$num" "$sha" "$branch" "$url"
      # re-check guardrails between PRs
      [ -f "$PAUSE" ] && break
    done < <(echo "$prs" | jq -r '.[] | [.repository.nameWithOwner, (.number|tostring), .url] | @tsv')
  done
  [ "$found" -eq 0 ] && log "no labeled PRs pending"
  sleep "$POLL"
done
