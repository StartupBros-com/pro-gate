#!/usr/bin/env bash
# pro-review-daemon: set-and-forget final-tier Pro review gate (the account's selected Pro model).
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

# --- self-reload signal: `install.sh` writes a single atomic deploy stamp
# ($PRO_GATE_HOME/.deploy-stamp) as the LAST step of a deploy, after every runtime file is in
# place. The daemon records the stamp at startup and re-execs itself when it changes (see
# maybe_self_reload). Recording it at process start is what makes the reload fire at most once per
# deploy. Disable the whole behavior with PRO_GATE_DAEMON_SELF_RELOAD=0.
DAEMON_SELF_RELOAD="${PRO_GATE_DAEMON_SELF_RELOAD:-1}"
DAEMON_STAMP_FILE="${PRO_GATE_HOME}/.deploy-stamp"
DAEMON_START_STAMP="$(cat "$DAEMON_STAMP_FILE" 2>/dev/null || true)"

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
ALL_PRS="${PRO_REVIEW_ALL_PRS:-0}"                      # 1 = review ALL open non-draft PRs in OWNERS (not just `pro-review`-labeled)
SKIP_LABEL="${PRO_REVIEW_SKIP_LABEL:-skip-pro-review}"  # in all-PRs mode, this label opts a PR back OUT
AUTOCLONE="${PRO_REVIEW_AUTOCLONE:-1}"                  # clone a missing repo under REPOS_DIR instead of skipping it

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# maybe_self_reload: call ONLY at an idle point (no review child running). If `install.sh` has
# landed a new deploy since startup, re-exec the daemon in place to pick it up. The stamp flips
# once per deploy and only after all runtime files are consistent (install.sh writes it last, via
# atomic rename), so there is no mid-deploy mixed-file window and no reload-loop (the re-exec'd
# process re-reads the now-current stamp as its baseline). `exec` preserves the PID and cgroup, so
# systemd sees no restart and KillMode=control-group never fires -> an in-flight review is never
# killed. Prefers run-daemon.sh (the systemd ExecStart, which re-augments PATH); daemon.sh
# re-sources lib.sh + env on its own, so either entrypoint fully reloads the code.
maybe_self_reload(){
  [ "$DAEMON_SELF_RELOAD" = 1 ] || return 0
  local cur; cur="$(cat "$DAEMON_STAMP_FILE" 2>/dev/null || true)"
  [ "$cur" = "$DAEMON_START_STAMP" ] && return 0
  log "detected a new daemon deploy (stamp changed); reloading in place via exec (idle: no review running)"
  if [ -f "$SELF/run-daemon.sh" ]; then exec "$SELF/run-daemon.sh"; else exec "$SELF/daemon.sh"; fi
}

if [ -z "$OWNERS" ]; then
  log "FATAL: PRO_REVIEW_OWNERS is not set in $ROOT/.env (e.g. PRO_REVIEW_OWNERS=my-org). Idling."
  # Still pick up a redeploy while parked here (this branch is idle -- no reviews run without OWNERS).
  while true; do maybe_self_reload; sleep 600; pg_load_env; OWNERS="${PRO_REVIEW_OWNERS:-}"; [ -n "$OWNERS" ] && break; done
  log "PRO_REVIEW_OWNERS now set to '$OWNERS' — continuing."
fi

# --- guardrails (universal + best-effort) -----------------------------------
session_up(){
  [ "$MODE" = remote-chrome ] || return 0   # native (macOS): oracle drives Chrome; errors per-run if not signed in
  pg_cdp_heal || return 1   # v0.19: reachable-or-one-self-heal-attempt (PRO_GATE_SELF_HEAL=0 disables)
  # v0.19.1 (pro-gate self-review P1): a just-healed Chrome must AGE past the engine's
  # min-uptime gate before the daemon dispatches — otherwise process_pr launches into a
  # guaranteed engine defer and can burn a MAX_FAILS strike on a healthy PR.
  [ "$(pg_service_uptime)" -ge "${PRO_GATE_MIN_UPTIME:-60}" ]
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

# Per-cycle memo around usage_saturated, checked lazily just before the FIRST review of a
# cycle — the old top-of-loop check hit chatgpt.com/backend-api every POLL even when there
# was nothing to review (~480 needless account hits/day). Returns 0 = saturated.
SATURATED=""
usage_gate(){
  if [ -z "$SATURATED" ]; then
    if usage_saturated; then SATURATED=1; else SATURATED=0; fi
  fi
  [ "$SATURATED" = 1 ]
}

# Count a failed attempt for repo#pr@sha (ANY failure class: clone, worktree, claude run) and
# give up permanently after MAX_FAILS — previously only claude-run failures were counted, so a
# broken clone/worktree retried every cycle forever.
note_fail(){ # nwo num sha log reason
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FAILS"
  local fc; fc=$(grep -cF "$(printf '%s\t%s\t%s' "$1" "$2" "$3")" "$FAILS" 2>/dev/null || echo 1)
  if [ "${fc:-1}" -ge "$MAX_FAILS" ]; then
    log "  ✗ $1#$2 failed ${fc}x (${5}) — giving up (marking done; fix manually or re-push to retry). log $4"
    mark_done "$1" "$2" "$3"
  else
    log "  ! $1#$2 failed (${5}, attempt ${fc}/${MAX_FAILS}) — will retry next cycle (log $4)"
  fi
}

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
    if [ "$AUTOCLONE" = "1" ]; then
      repodir="$REPOS_DIR/${nwo##*/}"
      log "  + autoclone $nwo -> $repodir"
      gh repo clone "$nwo" "$repodir" >>"$LOGDIR/autoclone.log" 2>&1 || { note_fail "$nwo" "$num" "$sha" "$LOGDIR/autoclone.log" "clone failed"; return 1; }
    else
      log "  ! no local checkout for $nwo under $REPOS_DIR — skipping (clone it there, or set PRO_REVIEW_AUTOCLONE=1)"; return 1
    fi
  fi

  local wt="${TMPDIR:-/tmp}/pro-review-${slug}"
  local lg="$LOGDIR/${slug}-$(date +%s).log"
  log "  → reviewing $nwo#$num @ ${sha:0:8} (branch $branch); repo=$repodir log=$lg"

  ( cd "$repodir" && git fetch --quiet origin "$branch" 2>/dev/null )
  git -C "$repodir" worktree remove --force "$wt" 2>/dev/null || true
  if ! git -C "$repodir" worktree add --force "$wt" "origin/$branch" >>"$lg" 2>&1; then
    note_fail "$nwo" "$num" "$sha" "$lg" "worktree add failed"; return 1
  fi
  ( cd "$wt" && git switch -C "$branch" "origin/$branch" >>"$lg" 2>&1 || git checkout -B "$branch" >>"$lg" 2>&1 )

  # Headless Claude runs the /pro-gate skill (which picks the best available fixer). Ironclad: never merge.
  local prompt="Run the /pro-gate skill for PR #${num} (${url}) in this repository in auto-fix mode: get the final-tier Pro review, sanity-check each P0/P1 finding against the actual code, apply the confirmed fixes on this branch, run available tests/lint, commit as 'fix(pro-gate): <summary>', push to origin/${branch}, and post ONE PR comment containing the full Pro review plus what you fixed. In the PR comment name the model from the run's status 'model' field (jq -r .model on the engine's <out>.status; role-based text when unreadable), never a hardcoded version, and if the status 'model_warn' field is non-empty include it as an advisory model-downgrade note.
SYNCHRONOUS EXECUTION (critical): you are running headless: you will NOT receive any asynchronous background-task notification. After you launch the oracle review, you MUST poll its status file in a loop yourself: the engine writes single-line JSON to '<out>.status' at every phase change (poll it, e.g. repeatedly: sleep 60; cat the status file). Phase 'done' means read the --out file; 'failed'/'deferred'/'oversized' are terminal: report them, do NOT relaunch. Phase 'in-progress' means the model is STILL generating after the engine's budget: do NOT relaunch; wait 10 minutes, read the marker field from the status JSON, then run the deployed engine again as: \"\${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh\" --harvest '<marker>' --out '<out>' --timeout 20m (repeat while it exits 9; it spends no new quota). The oracle takes 10-30 minutes; that is expected. Do NOT end your turn, and do NOT say 'I will be notified', while the oracle is still running. Your turn is only complete once the PR comment has actually been posted.
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
    note_fail "$nwo" "$num" "$sha" "$lg" "claude run rc=$rc"
  fi
}

# --- main loop --------------------------------------------------------------
log "pro-review-daemon starting (os=$OS mode=$MODE owners='$OWNERS' poll=${POLL}s model=$CLAUDE_MODEL all_prs=$ALL_PRS autoclone=$AUTOCLONE $( [ "$ALL_PRS" = 1 ] && echo "skip-label='$SKIP_LABEL'" || echo "label='$LABEL'" ))"
while true; do
  # Idle point: the review loop is fully synchronous, so no review child is running here. Adopt a
  # new deploy in place if one landed since startup (no systemctl restart -> the control-group kill
  # never fires -> an in-flight review is never interrupted).
  maybe_self_reload
  if [ -f "$PAUSE" ]; then log "PAUSE present — idling"; sleep "$POLL"; continue; fi
  if ! session_up; then log "browser session down — idling"; sleep "$POLL"; continue; fi
  if doghouse_tripped; then log "codex doghouse tripped — idling"; sleep "$POLL"; continue; fi

  found=0; SATURATED=""
  for owner in $OWNERS; do
    if [ "$ALL_PRS" = "1" ]; then
      # Review EVERY open non-draft PR in the owner, except ones opted out via $SKIP_LABEL.
      # The exclusion query starts with "-", so it must come AFTER "--" or gh's flag parser
      # rejects it ("unknown shorthand flag: 'l'") — which 2>/dev/null used to swallow,
      # silently reviewing nothing in all-PRs mode.
      prs=$(gh search prs --owner "$owner" --state open --draft=false --limit 50 \
              --json 'repository,number,url' -- "-label:$SKIP_LABEL" 2>/dev/null)
    else
      prs=$(gh search prs --owner "$owner" --label "$LABEL" --state open --limit 30 \
              --json 'repository,number,url' 2>/dev/null)
    fi
    [ -z "$prs" ] && continue
    while IFS=$'\t' read -r nwo num url; do
      [ -z "$nwo" ] && continue
      meta=$(gh pr view "$num" -R "$nwo" --json headRefOid,headRefName 2>/dev/null)
      sha=$(echo "$meta" | jq -r '.headRefOid // empty'); branch=$(echo "$meta" | jq -r '.headRefName // empty')
      [ -z "$sha" ] && continue
      already_done "$nwo" "$num" "$sha" && continue
      if usage_gate; then log "account usage saturated (>=90% / limit) — skipping this cycle"; break; fi
      found=1
      process_pr "$nwo" "$num" "$sha" "$branch" "$url"
      [ -f "$PAUSE" ] && break
    done < <(echo "$prs" | jq -r '.[] | [.repository.nameWithOwner, (.number|tostring), .url] | @tsv')
    [ "$SATURATED" = 1 ] && break
  done
  [ "$found" -eq 0 ] && log "no PRs pending"
  sleep "$POLL"
done
