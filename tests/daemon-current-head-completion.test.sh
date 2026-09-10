#!/usr/bin/env bash
# Tests for #184: the daemon can permanently consume a PR head it never proved was reviewed.
#   a) CI-readiness gate before dispatch -- QUEUED/IN_PROGRESS/PENDING on the current head defers
#      without marking anything; an empty rollup (no checks configured) counts as settled; the
#      deferral is bounded per (repo,pr,sha) so a check stuck pending forever cannot strand the PR.
#   b) mark_processed_heads marks ONLY the sha a valid decision proved was reviewed -- never a
#      worker self-push or an externally-advanced head.
#   c) completion requires a typed current-head outcome, never a bare subprocess exit code: a
#      completed run-granted-review worker and a report-only stop-without-new-review decision
#      complete the head; a successful agent-task is progress and gets its own bounded
#      no-progress attempt cap instead of completing the SHA.
#   d) #184c: exhausting a cap (CI-defer or agent-task no-progress) is BLOCKED (escalation), never
#      completion -- it is recorded only in blocked.tsv, never processed.tsv, regardless of what a
#      worker downstream would have returned; it suppresses further dispatch for that exact head so
#      the cap cannot re-fire every poll; and a new push (new sha) is never blocked.
# No network: gh/git/claude and the review-decision engine are all stubbed.
# Run: bash tests/daemon-current-head-completion.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FAILURES=0
check() { if [ "$2" = 0 ]; then echo "ok - $1"; else echo "FAIL - $1: ${3:-}"; TEST_FAILURES=$((TEST_FAILURES + 1)); fi; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-daemon-184-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT

HOME_D="$TDIR/home"; mkdir -p "$HOME_D"
export PRO_GATE_HOME="$HOME_D" PRO_GATE_DAEMON_LIB_ONLY=1
unset PRO_REVIEW_INPUT
. "$HERE/../daemon/daemon.sh"
unset PRO_GATE_DAEMON_LIB_ONLY

# #184 finding 2 (round 3): STATE_FILE now points at the NEW versioned ledger (processed-v2.tsv);
# LEGACY_FILE is the pre-#184x file (processed.tsv), QUARANTINE_FILE is the migration's audit
# trail for legacy rows lacking durable evidence, and AGENTFAIL_FILE is finding 3's bounded
# launch-failure ledger.
STATE_FILE="$HOME_D/processed-v2.tsv"; LEGACY_FILE="$HOME_D/processed.tsv"
QUARANTINE_FILE="$HOME_D/processed-quarantine.tsv"
FAILS_FILE="$HOME_D/failcount.tsv"
CIDEFER_FILE="$HOME_D/ci-defer.tsv"; AGENTCAP_FILE="$HOME_D/agent-task-attempts.tsv"
AGENTFAIL_FILE="$HOME_D/agent-task-failures.tsv"
BLOCKED_FILE="$HOME_D/blocked.tsv"
# #184 finding 3 (round 6): the new bounded no-progress ledger for exit-zero review workers whose
# re-resolved decision still requests the same unstarted run-granted-review.
REVIEWNOPROG_FILE="$HOME_D/review-worker-no-progress.tsv"
LOG_FILE="$HOME_D/t.log"; : > "$LOG_FILE"
log(){ printf '%s\n' "$*" >> "$LOG_FILE"; }

check 'daemon.sh created the bounded #184 ledger files at startup' "$([ -f "$CIDEFER_FILE" ] && [ -f "$AGENTCAP_FILE" ] && [ -f "$BLOCKED_FILE" ]; echo $?)" "$(ls "$HOME_D")"
check 'daemon.sh created the #184 finding-2/3 (round 3) ledger files at startup' "$([ -f "$STATE_FILE" ] && [ -f "$LEGACY_FILE" ] && [ -f "$QUARANTINE_FILE" ] && [ -f "$AGENTFAIL_FILE" ]; echo $?)" "$(ls "$HOME_D")"
check 'daemon.sh created the #184 finding-1/3 (round 6) evidence dir and no-progress ledger at startup' "$([ -d "$REVIEW_EVIDENCE_DIR" ] && [ -f "$REVIEWNOPROG_FILE" ]; echo $?)" "$(ls "$HOME_D")"

reset_state(){ : > "$STATE_FILE"; : > "$FAILS_FILE"; : > "$CIDEFER_FILE"; : > "$AGENTCAP_FILE"; : > "$AGENTFAIL_FILE"; : > "$BLOCKED_FILE"; : > "$REVIEWNOPROG_FILE"; : > "$LOG_FILE"; }

# --- corpus decision helper (mirrors tests/daemon-reload.test.sh) -----------------------------
typed_decision(){ # corpus-case index output
  local index="$1" out="$2" facts patch
  patch="$(jq -c ".cases[$index].patch" "$HERE/fixtures/review-decision/v1/corpus.json")"
  facts="$(jq -cS --arg cd "$(pg_review_decision_contract_digest)" --arg xd "$(pg_review_decision_corpus_digest)" --argjson patch "$patch" '.base_facts * $patch | .contract={contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd}' "$HERE/fixtures/review-decision/v1/corpus.json")"
  pg_review_decision_reduce "$facts" > "$out"
}
decision_for_action(){ # action -> corpus index
  jq -r --arg action "$1" '.cases | to_entries[] | select(.value.expected.action == $action) | .key' "$HERE/fixtures/review-decision/v1/corpus.json"
}
# Same base_facts as typed_decision, but with an ad-hoc patch not stored in the shared corpus --
# used for finding-1 coverage so this file's cases don't perturb corpus.json's case count (relied
# on by tests/review-decision-adapters.test.sh) or engine.test.sh's own corpus iteration.
typed_decision_patch(){ # patch-json output
  local patch="$1" out="$2" facts
  facts="$(jq -cS --arg cd "$(pg_review_decision_contract_digest)" --arg xd "$(pg_review_decision_corpus_digest)" --argjson patch "$patch" '.base_facts * $patch | .contract={contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd}' "$HERE/fixtures/review-decision/v1/corpus.json")"
  pg_review_decision_reduce "$facts" > "$out"
}

NWO=acme/widgets; NUM=1983
SHA=1111111111111111111111111111111111111111   # matches corpus.json base_facts.target.head_oid
BRANCH=branch; URL=https://example.test/pr/1983

REPO_DIR="$HOME_D/repo"; mkdir -p "$REPO_DIR/.git"
find_repo(){ printf '%s\n' "$REPO_DIR"; }
git(){
  if [ "${1:-}" = -C ] && [ "${3:-}" = worktree ] && [ "${4:-}" = add ]; then mkdir -p "$6"; fi
  return 0
}
runtime_gate(){ return 0; }

ENGINE="$HOME_D/oracle-review.sh"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" --review-decision-effect "*|*" --review-decision "*) cat "$MOCK_FRESH";;\n  *" --recover "*) :;;\nesac\n' > "$ENGINE"
chmod +x "$ENGINE"

# gh() answers the #184a CI-readiness query (statusCheckRollup) and, since round 6 (#184 finding
# 1), the evidence-persistence fetch daemon_prepare_review_evidence makes (gh pr diff --patch).
# GH_DIFF_RC lets individual checks simulate a fetch failure (no evidence ever gets persisted,
# reproducing the pre-fix daemon which never even tried). GH_DIFF_CALLS_FILE counts real fetch
# attempts so a test can prove the fetch actually happened (not just that a cached file already
# existed) -- a FILE, not a shell variable, because daemon_prepare_review_evidence invokes gh
# inside a `( cd "$wt" && gh ... )` subshell, and a subshell's variable mutations never propagate
# back to this outer shell; a file write does. Read the count with gh_diff_calls().
GH_ROLLUP='{"statusCheckRollup":[]}'   # default: no checks configured -> settled
GH_DIFF_RC=0
GH_DIFF_CALLS_FILE="$HOME_D/gh-diff-calls"; : > "$GH_DIFF_CALLS_FILE"
gh_diff_calls(){ wc -l < "$GH_DIFF_CALLS_FILE"; }
GH_DIFF='diff --git a/x b/x
index e69de29..d00491fd7e5bb6fa28c517a0bb32b8b506539d4d 100644
--- a/x
+++ b/x
@@ -0,0 +1 @@
+1
'
gh(){
  if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    case " $* " in
      *' --json statusCheckRollup '*) printf '%s\n' "$GH_ROLLUP"; return 0 ;;
    esac
  fi
  if [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
    case " $* " in
      *' --patch '*)
        printf 'x\n' >> "$GH_DIFF_CALLS_FILE"
        [ "${GH_DIFF_RC:-0}" -eq 0 ] && printf '%s\n' "$GH_DIFF"
        return "${GH_DIFF_RC:-0}" ;;
    esac
  fi
  return 1
}

CLAUDE_MODEL=test FALLBACK_MODEL=test MAX_BUDGET=1

echo '# a) CI-readiness gate before dispatch'

GH_ROLLUP='{"statusCheckRollup":[{"status":"QUEUED"}]}'
reset_state
rm -f "$HOME_D/dispatched"
daemon_run_review_worker(){ echo UNEXPECTED-DISPATCH >> "$HOME_D/dispatched"; return 0; }
DECISION="$HOME_D/run.json"; typed_decision "$(decision_for_action run-granted-review)" "$DECISION"
MOCK_FRESH="$DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'pending CI (QUEUED) defers without dispatching or marking' "$([ "$rc" -eq 2 ] && [ ! -f "$HOME_D/dispatched" ] && [ ! -s "$STATE_FILE" ]; echo $?)" "rc=$rc dispatched=$([ -f "$HOME_D/dispatched" ] && echo yes || echo no)"
check 'pending CI records exactly one bounded deferral for this repo/pr/sha' "$([ "$(wc -l < "$CIDEFER_FILE")" -eq 1 ] && grep -qF "$(printf '%s\t%s\t%s' "$NWO" "$NUM" "$SHA")" "$CIDEFER_FILE"; echo $?)" "$(cat "$CIDEFER_FILE")"

GH_ROLLUP='{"statusCheckRollup":[{"state":"PENDING"}]}'
state="$(ci_rollup_state "$NWO" "$NUM")"
check 'a status-context PENDING state (no .status field) also reads as not settled' "$([ "$state" = PENDING ]; echo $?)" "state=$state"

GH_ROLLUP='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"IN_PROGRESS"}]}'
state="$(ci_rollup_state "$NWO" "$NUM")"
check 'one unsettled check among several settled ones still reads as not settled' "$([ "$state" = IN_PROGRESS ]; echo $?)" "state=$state"

echo '# empty rollup proceeds (never a permanent block)'
GH_ROLLUP='{"statusCheckRollup":[]}'
reset_state
ci_ready "$NWO" "$NUM" "$SHA"; empty_rc=$?
check 'ci_ready treats an empty rollup as settled' "$([ "$empty_rc" -eq 0 ]; echo $?)" "rc=$empty_rc"
check 'an empty rollup never writes a deferral row' "$([ ! -s "$CIDEFER_FILE" ]; echo $?)"

GH_ROLLUP='{}'
ci_ready "$NWO" "$NUM" "$SHA"; missing_rc=$?
check 'a missing statusCheckRollup key (repo has no checks configured) also proceeds' "$([ "$missing_rc" -eq 0 ]; echo $?)" "rc=$missing_rc"

echo '# #184c finding 1: the deferral cap BLOCKS (never proceeds) once exhausted'
GH_ROLLUP='{"statusCheckRollup":[{"status":"IN_PROGRESS"}]}'
reset_state
below_cap_ok=1
i=1
while [ "$i" -lt "$CI_DEFER_MAX" ]; do
  ci_ready "$NWO" "$NUM" "$SHA"; each_rc=$?
  [ "$each_rc" -eq 1 ] || below_cap_ok=0
  i=$((i + 1))
done
check "every attempt below the cap ($((CI_DEFER_MAX - 1)) of them) still defers" "$([ "$below_cap_ok" -eq 1 ] && [ "$(wc -l < "$CIDEFER_FILE")" -eq $((CI_DEFER_MAX - 1)) ]; echo $?)" "$(wc -l < "$CIDEFER_FILE")"
ci_ready "$NWO" "$NUM" "$SHA"; cap_rc=$?
check 'the cap-th attempt BLOCKS (never proceeds), with a logged notice' "$([ "$cap_rc" -eq 1 ] && grep -Fq 'BLOCKED' "$LOG_FILE"; echo $?)" "rc=$cap_rc log=$(cat "$LOG_FILE")"
check 'cap exhaustion is recorded in blocked.tsv, never processed.tsv' "$([ ! -s "$STATE_FILE" ] && grep -qF "$(printf '%s\t%s\t%s\t' "$NWO" "$NUM" "$SHA")" "$BLOCKED_FILE"; echo $?)" "$(cat "$BLOCKED_FILE")"

echo '# #184c finding 1: the cap does not re-fire (re-log / re-increment) on every subsequent poll'
CIDEFER_LINES_AT_CAP="$(wc -l < "$CIDEFER_FILE")"
BLOCKED_LINES_AT_CAP="$(wc -l < "$BLOCKED_FILE")"
: > "$LOG_FILE"
poll_ok=1
i=1
while [ "$i" -le 5 ]; do
  ci_ready "$NWO" "$NUM" "$SHA"; poll_rc=$?
  [ "$poll_rc" -eq 1 ] || poll_ok=0
  i=$((i + 1))
done
check 'still-unsettled polls after the cap keep deferring (never proceed)' "$([ "$poll_ok" -eq 1 ]; echo $?)"
check 'the CI-defer counter does not keep incrementing once blocked' "$([ "$(wc -l < "$CIDEFER_FILE")" -eq "$CIDEFER_LINES_AT_CAP" ]; echo $?)" "before=$CIDEFER_LINES_AT_CAP after=$(wc -l < "$CIDEFER_FILE")"
check 'blocked.tsv gets no duplicate line on later polls' "$([ "$(wc -l < "$BLOCKED_FILE")" -eq "$BLOCKED_LINES_AT_CAP" ]; echo $?)" "before=$BLOCKED_LINES_AT_CAP after=$(wc -l < "$BLOCKED_FILE")"
check 'a later poll after the cap logs nothing (no re-fire spam)' "$([ ! -s "$LOG_FILE" ]; echo $?)" "$(cat "$LOG_FILE")"

echo '# #184c finding 1: a cap-exhausted head never writes processed.tsv even when the worker would succeed'
reset_state
rm -f "$HOME_D/dispatched"
daemon_run_review_worker(){ echo UNEXPECTED-DISPATCH >> "$HOME_D/dispatched"; return 0; }
DECISION="$HOME_D/run-cap.json"; typed_decision "$(decision_for_action run-granted-review)" "$DECISION"
i=1
while [ "$i" -lt "$CI_DEFER_MAX" ]; do
  MOCK_FRESH="$DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL" >/dev/null
  i=$((i + 1))
done
MOCK_FRESH="$DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; cap_process_rc=$?
check 'the cap-exhausting process_pr call blocks before ever dispatching the (would-succeed) worker' "$([ "$cap_process_rc" -eq 2 ] && [ ! -f "$HOME_D/dispatched" ] && [ ! -s "$STATE_FILE" ]; echo $?)" "rc=$cap_process_rc dispatched=$([ -f "$HOME_D/dispatched" ] && echo yes || echo no)"
MOCK_FRESH="$DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; cap_process_rc2=$?
check 'a further poll on the blocked head still never dispatches and never marks done' "$([ "$cap_process_rc2" -eq 2 ] && [ ! -f "$HOME_D/dispatched" ] && [ ! -s "$STATE_FILE" ]; echo $?)" "rc=$cap_process_rc2"
GH_ROLLUP='{"statusCheckRollup":[]}'

echo '# finding 2 (round 4): a ci-defer-cap block is lifted once CI positively settles on the SAME unchanged sha, and dispatch actually resumes'
reset_state
rm -f "$HOME_D/dispatched-ciclear"
daemon_run_review_worker(){ echo DISPATCHED >> "$HOME_D/dispatched-ciclear"; return 0; }
DECISION_F2="$HOME_D/run-f2.json"; typed_decision "$(decision_for_action run-granted-review)" "$DECISION_F2"
GH_ROLLUP='{"statusCheckRollup":[{"status":"IN_PROGRESS"}]}'
i=1
while [ "$i" -lt "$CI_DEFER_MAX" ]; do
  MOCK_FRESH="$DECISION_F2" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL" >/dev/null
  i=$((i + 1))
done
MOCK_FRESH="$DECISION_F2" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; drive_rc=$?
check 'driving the sha IN_PROGRESS through the cap blocks it (ci-defer-cap-exhausted)' "$([ "$drive_rc" -eq 2 ] && is_blocked "$NWO" "$NUM" "$SHA" && grep -qF "$(printf '%s\t%s\t%s\tci-defer-cap-exhausted' "$NWO" "$NUM" "$SHA")" "$BLOCKED_FILE"; echo $?)" "$(cat "$BLOCKED_FILE")"
check '(sanity) dispatch never fired while the sha was CI-not-settled' "$([ ! -f "$HOME_D/dispatched-ciclear" ]; echo $?)"

GH_ROLLUP='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'   # CI now positively settled, unchanged sha
MOCK_FRESH="$DECISION_F2" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL" >/dev/null
check 'CI settling on the unchanged sha lifts the ci-defer-cap block' "$(! is_blocked "$NWO" "$NUM" "$SHA"; echo $?)" "$(cat "$BLOCKED_FILE")"
check 'CI settling on the unchanged sha actually resumes dispatch (worker runs, not silently re-suppressed)' "$([ -f "$HOME_D/dispatched-ciclear" ]; echo $?)"
GH_ROLLUP='{"statusCheckRollup":[]}'

echo '# finding 2 (round 4): an agent-task-exhausted block on the SAME sha is a DIFFERENT condition and is untouched by CI settling'
reset_state
mark_blocked "$NWO" "$NUM" "$SHA" "agent-task-no-progress-cap-exhausted"
check 'sanity: the agent-task block is recorded' "$(is_blocked "$NWO" "$NUM" "$SHA"; echo $?)"
GH_ROLLUP='{"statusCheckRollup":[]}'   # empty rollup -> settled
ci_ready "$NWO" "$NUM" "$SHA"; agent_ci_rc=$?
check 'ci_ready itself proceeds (CI is settled) even though the head remains blocked for an unrelated reason' "$([ "$agent_ci_rc" -eq 0 ]; echo $?)"
check 'the agent-task block is left in place -- CI settling clears ONLY ci-defer-cap-exhausted rows' "$(is_blocked "$NWO" "$NUM" "$SHA" && grep -qF "$(printf '%s\t%s\t%s\tagent-task-no-progress-cap-exhausted' "$NWO" "$NUM" "$SHA")" "$BLOCKED_FILE"; echo $?)" "$(cat "$BLOCKED_FILE")"
rm -f "$HOME_D/dispatched-agentblock"
daemon_run_review_worker(){ echo UNEXPECTED-DISPATCH >> "$HOME_D/dispatched-agentblock"; return 0; }
MOCK_FRESH="$DECISION_F2" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; agent_block_rc=$?
check 'process_pr still suppresses dispatch for the agent-task-blocked head even though CI is settled' "$([ "$agent_block_rc" -eq 2 ] && [ ! -f "$HOME_D/dispatched-agentblock" ]; echo $?)" "rc=$agent_block_rc"

echo '# a gh query failure is treated the same as not-settled, bounded by the same cap'
GH_ROLLUP='{"statusCheckRollup":[]}'
reset_state
gh(){ return 1; }
state="$(ci_rollup_state "$NWO" "$NUM")"
check 'a gh query failure reads as query-failed, never settled' "$([ "$state" = query-failed ]; echo $?)" "state=$state"
ci_ready "$NWO" "$NUM" "$SHA"; query_fail_rc=$?
check 'a gh query failure defers (fails closed), does not mark anything' "$([ "$query_fail_rc" -eq 1 ] && [ "$(wc -l < "$CIDEFER_FILE")" -eq 1 ]; echo $?)" "rc=$query_fail_rc"
gh(){
  if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    case " $* " in
      *' --json statusCheckRollup '*) printf '%s\n' "$GH_ROLLUP"; return 0 ;;
    esac
  fi
  if [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
    case " $* " in
      *' --patch '*)
        printf 'x\n' >> "$GH_DIFF_CALLS_FILE"
        [ "${GH_DIFF_RC:-0}" -eq 0 ] && printf '%s\n' "$GH_DIFF"
        return "${GH_DIFF_RC:-0}" ;;
    esac
  fi
  return 1
}

echo '# b) mark only the reviewed SHA -- never a worker self-push or an externally-advanced head'

# #184 finding 1 (round 3): a real, producer-shape completion-proof patch (same shape as the
# PROOF_DECISION case below, and the same real-producer shape already verified against
# tests/engine.test.sh:5291-5292 -- see the comment there). The stub below reassigns MOCK_FRESH
# (a plain, non-`export`ed reassignment -- verified to update what a LATER child process within
# this same process_pr call sees, while never leaking past process_pr's return) to a NEW file
# holding this proof content, so process_pr's post-worker RE-RESOLUTION reads it, while the
# INITIAL decision resolution (which already ran, before the worker was ever dispatched) is
# unaffected.
PROOF_PATCH='{"prior_review":{"applicable":false,"binding_valid":true,"code_identity":"input-current","evidence_identity":"evidence-current","legacy":false,"marker":"pg-run-acme-widgets-1983-1700000400-1","provenance_valid":true,"verdict":"NONE"}}'
REWORKER_PROOF="$HOME_D/reworker-proof.json"; typed_decision_patch "$PROOF_PATCH" "$REWORKER_PROOF"

reset_state
daemon_run_review_worker(){ MOCK_FRESH="$REWORKER_PROOF"; return 0; }   # completed review; the re-resolution now attests proof
DECISION="$HOME_D/run.json"; typed_decision "$(decision_for_action run-granted-review)" "$DECISION"
PUSHED_SHA=2222222222222222222222222222222222222222   # what a self-push would advance the head to
MOCK_FRESH="$DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'a completed review worker marks the SHA it actually reviewed' "$([ "$rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$rc"
check 'a worker self-push does not mark the pushed (unreviewed) head' "$(! already_done "$NWO" "$NUM" "$PUSHED_SHA"; echo $?)"
check 'exactly one SHA is recorded for a completed review' "$([ "$(wc -l < "$STATE_FILE")" -eq 1 ]; echo $?)" "$(cat "$STATE_FILE")"

reset_state
EXTERNAL_SHA=3333333333333333333333333333333333333333   # a concurrent, unrelated push to the PR
MOCK_FRESH="$DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'an external head change during the run is never marked' "$([ "$rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA" && ! already_done "$NWO" "$NUM" "$EXTERNAL_SHA"; echo $?)" "rc=$rc"

echo '# c) completion requires a typed current-head outcome, not a bare exit code'

reset_state
AGENT_RUNS=0
daemon_run_agent_task(){ AGENT_RUNS=$((AGENT_RUNS + 1)); return 0; }
AGENT_DECISION="$HOME_D/agent.json"; typed_decision "$(decision_for_action fix-review-findings)" "$AGENT_DECISION"
MOCK_FRESH="$AGENT_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'a successful agent-task does not complete the head' "$([ "$rc" -eq 0 ] && ! already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$rc"
check 'the agent-task dispatch counted toward its bounded attempt cap' "$([ "$(wc -l < "$AGENTCAP_FILE")" -eq 1 ]; echo $?)" "$(cat "$AGENTCAP_FILE")"

echo '# #184c finding 2: the agent-task attempt cap BLOCKS a no-progress loop -- never marks done'
reset_state
AGENT_RUNS=0
below_cap_ok=1
i=1
while [ "$i" -lt "$AGENT_TASK_MAX" ]; do
  : > "$LOG_FILE"
  MOCK_FRESH="$AGENT_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
  { [ "$rc" -eq 0 ] && ! already_done "$NWO" "$NUM" "$SHA"; } || below_cap_ok=0
  i=$((i + 1))
done
check "every dispatch below the cap ($((AGENT_TASK_MAX - 1)) of them) leaves the head open" "$([ "$below_cap_ok" -eq 1 ]; echo $?)"
: > "$LOG_FILE"
MOCK_FRESH="$AGENT_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'the cap-th agent-task dispatch BLOCKS (never marks done), with a logged notice' "$([ "$rc" -eq 0 ] && ! already_done "$NWO" "$NUM" "$SHA" && grep -Fq 'no head progress' "$LOG_FILE"; echo $?)" "$(tail -1 "$LOG_FILE")"
check 'the cap-th dispatch is recorded in blocked.tsv, never processed.tsv' "$([ ! -s "$STATE_FILE" ] && grep -qF "$(printf '%s\t%s\t%s\t' "$NWO" "$NUM" "$SHA")" "$BLOCKED_FILE"; echo $?)" "$(cat "$BLOCKED_FILE")"
check "the agent task actually ran $AGENT_TASK_MAX times (each dispatch is real, not skipped)" "$([ "$AGENT_RUNS" -eq "$AGENT_TASK_MAX" ]; echo $?)" "runs=$AGENT_RUNS"

echo '# #184c finding 2: an exhausted (blocked) agent-task head suppresses ALL further dispatch'
: > "$LOG_FILE"
MOCK_FRESH="$AGENT_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'a further poll on the blocked head never re-dispatches the agent task' "$([ "$rc" -eq 2 ] && [ "$AGENT_RUNS" -eq "$AGENT_TASK_MAX" ]; echo $?)" "rc=$rc runs=$AGENT_RUNS"
check 'the attempt counter does not keep growing once blocked' "$([ "$(wc -l < "$AGENTCAP_FILE")" -eq "$AGENT_TASK_MAX" ]; echo $?)" "$(wc -l < "$AGENTCAP_FILE")"
check 'still not marked done after the extra poll' "$(! already_done "$NWO" "$NUM" "$SHA"; echo $?)"

echo '# #184c finding 2: a new head (new sha) is never blocked and re-enters normally'
check 'the blocked sha is blocked' "$(is_blocked "$NWO" "$NUM" "$SHA"; echo $?)"
check 'a real push (new sha) is not blocked' "$(! is_blocked "$NWO" "$NUM" "$PUSHED_SHA"; echo $?)"
check 'a real push (new sha) starts the attempt counter fresh, not a stuck loop' "$([ "$(agent_task_attempt_count "$NWO" "$NUM" "$PUSHED_SHA")" -eq 1 ]; echo $?)"
# process_pr itself is not re-exercised for PUSHED_SHA here: the decision stub's target head_oid is
# fixed to $SHA by the corpus fixture, so a mismatched sha would (correctly) defer on
# daemon_decision_target_matches -- a different gate than the one under test. The is_blocked checks
# above directly prove the new head is unaffected by the old head's block.

echo '# a completed current-head review does complete it'
reset_state
daemon_run_review_worker(){ MOCK_FRESH="$REWORKER_PROOF"; return 0; }
RUN_DECISION="$HOME_D/run2.json"; typed_decision "$(decision_for_action run-granted-review)" "$RUN_DECISION"
MOCK_FRESH="$RUN_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'run-granted-review completion marks the current head' "$([ "$rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$rc"

echo '# finding 1 (round 3): a worker rc=0 whose re-resolved decision does NOT attest completion leaves the ledger untouched'
reset_state
STATE_BEFORE_NOPROOF="$(cat "$STATE_FILE")"
daemon_run_review_worker(){ return 0; }   # rc=0, but MOCK_FRESH is left pointing at the SAME unproven base decision
NOPROOF_DECISION="$HOME_D/run-noproof.json"; typed_decision "$(decision_for_action run-granted-review)" "$NOPROOF_DECISION"
MOCK_FRESH="$NOPROOF_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; noproof_rc=$?
check 'a worker rc=0 whose re-resolved decision lacks completion proof does NOT mark the head' "$([ "$noproof_rc" -ne 0 ] && ! already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$noproof_rc"
check 'a worker rc=0 without re-resolved proof leaves processed-v2.tsv byte-identical' "$([ "$(cat "$STATE_FILE")" = "$STATE_BEFORE_NOPROOF" ]; echo $?)" "before=[$STATE_BEFORE_NOPROOF] after=[$(cat "$STATE_FILE")]"

echo '# finding 1 (round 3): a worker rc=0 WITH a re-resolved attested completion DOES mark it'
reset_state
daemon_run_review_worker(){ MOCK_FRESH="$REWORKER_PROOF"; return 0; }
WORKERPROOF_DECISION="$HOME_D/run-workerproof.json"; typed_decision "$(decision_for_action run-granted-review)" "$WORKERPROOF_DECISION"
MOCK_FRESH="$WORKERPROOF_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; withproof_rc=$?
check 'a worker rc=0 with a re-resolved attested completion marks the head' "$([ "$withproof_rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$withproof_rc"

echo '# finding 1: a report-only stop completes the head ONLY with positive current-head review proof'

reset_state
STOP_DECISION="$HOME_D/stop.json"; typed_decision "$(decision_for_action stop-without-new-review)" "$STOP_DECISION"
check 'sanity: the stop-without-new-review corpus fixture is a NON-completion reason (round-governor-denied)' "$([ "$(jq -r .reason "$STOP_DECISION")" = round-governor-denied ]; echo $?)" "$(jq -r .reason "$STOP_DECISION")"
STATE_BEFORE="$(cat "$STATE_FILE")"
MOCK_FRESH="$STOP_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'a stop without current-head review proof does NOT complete the head' "$([ "$rc" -eq 0 ] && ! already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$rc"
check 'a stop without current-head review proof leaves processed.tsv byte-identical' "$([ "$(cat "$STATE_FILE")" = "$STATE_BEFORE" ]; echo $?)" "before=[$STATE_BEFORE] after=[$(cat "$STATE_FILE")]"

reset_state
PROOF_DECISION="$HOME_D/stop-proof.json"
# #184c finding 3: the real producer (oracle-review.sh) ALWAYS emits prior_review.applicable=false
# (see oracle-review.sh:631-634 -- prior_review is built only from non-exact prior_candidates, which
# hardcode applicable:false) and legacy=false. A patch with applicable:true is a shape the producer
# can never emit; requiring it in daemon_decision_completes_current_head made a genuine
# identical-code/evidence stop unsatisfiable and caused the daemon to retry forever. This is the
# producer's real shape -- identical to the already-verified reducer-level case in
# tests/engine.test.sh:5291-5292 ("identical verified code and evidence cannot authorize another
# review") -- proving the helper against genuine producer output, not an invented equivalent.
typed_decision_patch '{"prior_review":{"applicable":false,"binding_valid":true,"code_identity":"input-current","evidence_identity":"evidence-current","legacy":false,"marker":"pg-run-acme-widgets-1983-1700000400-1","provenance_valid":true,"verdict":"NONE"}}' "$PROOF_DECISION"
check 'sanity: the real-shape decision is stop-without-new-review/identical-code-and-evidence' "$([ "$(jq -r .action "$PROOF_DECISION")" = stop-without-new-review ] && [ "$(jq -r .reason "$PROOF_DECISION")" = identical-code-and-evidence ]; echo $?)" "action=$(jq -r .action "$PROOF_DECISION") reason=$(jq -r .reason "$PROOF_DECISION")"
check 'the completion-proof helper accepts the producer real applicable:false identical-code-and-evidence shape' "$(daemon_decision_completes_current_head "$PROOF_DECISION"; echo $?)"
check 'the completion-proof helper rejects the round-governor-denied stop (non-completion reason)' "$(! daemon_decision_completes_current_head "$STOP_DECISION"; echo $?)"
MOCK_FRESH="$PROOF_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'a stop WITH positive current-head review proof (real applicable:false shape) completes the head' "$([ "$rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$rc"

echo '# #184 finding 1 (round 5): a FIRST successful SHIP puts its exact result in .facts.completed_results,'
echo '# never .facts.prior_review (which the real producer, oracle-review.sh, ALWAYS emits applicable:false --'
echo '# oracle-review.sh:589-592,631-634, built only from NON-exact prior candidates). The old helper only'
echo '# recognized the prior_review-based REPEAT shape above and missed this FIRST-SUCCESS shape entirely, so'
echo '# a first successful review re-reduced to allow-existing-merge-workflow, the old helper returned false,'
echo '# and the unchanged head was re-cloned and reprocessed on every poll forever.'

# Real-producer completed_results entry shape (verified by actually running pg_review_decision_reduce
# over it, /tmp/pgtest1/run.sh in the working session -- not a hand-built envelope): an exact-current,
# provenance-validated SHIP candidate with an EMPTY prior_review, matching what oracle-review.sh's
# "exact" branch installs.
SHIP_PATCH='{"completed_results":[{"applicable":true,"artifact_digest":"0000000000000000000000000000000000000000000000000000000000000000","binding_valid":true,"canonical_identity":"input-current","charged_spend_epoch":1700000004,"collected":true,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000004-4","provenance_valid":true,"verdict":"SHIP"}]}'
SHIP_DECISION="$HOME_D/ship-first-success.json"
typed_decision_patch "$SHIP_PATCH" "$SHIP_DECISION"
check 'sanity: the first-success completed_results patch reduces to allow-existing-merge-workflow/current-ship-is-merge-eligible' "$([ "$(jq -r .action "$SHIP_DECISION")" = allow-existing-merge-workflow ] && [ "$(jq -r .reason "$SHIP_DECISION")" = current-ship-is-merge-eligible ]; echo $?)" "action=$(jq -r .action "$SHIP_DECISION") reason=$(jq -r .reason "$SHIP_DECISION")"
check 'sanity: the first-success shape carries an EMPTY (non-applicable) prior_review, exactly like the real producer' "$([ "$(jq -r .facts.prior_review.applicable "$SHIP_DECISION")" = false ]; echo $?)" "$(jq -c .facts.prior_review "$SHIP_DECISION")"
check 'the completion-proof helper accepts the producer real first-success SHIP shape (completed_results, empty prior_review)' "$(daemon_decision_completes_current_head "$SHIP_DECISION"; echo $?)"

reset_state
daemon_run_review_worker(){ MOCK_FRESH="$SHIP_DECISION"; return 0; }
SHIP_RUN_DECISION="$HOME_D/ship-run.json"; typed_decision "$(decision_for_action run-granted-review)" "$SHIP_RUN_DECISION"
MOCK_FRESH="$SHIP_RUN_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; ship_rc=$?
check 'a first successful SHIP review (completed_results, empty prior_review) completes the current head end-to-end' "$([ "$ship_rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$ship_rc"

echo '# #184 finding 1 (round 5): the negative -- a FIX-FIRST or NEEDS-DISCUSSION decision at the SAME head must NOT complete'

FIXFIRST_PATCH='{"completed_results":[{"applicable":true,"artifact_digest":"0000000000000000000000000000000000000000000000000000000000000000","binding_valid":true,"canonical_identity":"input-current","charged_spend_epoch":1700000004,"collected":true,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000004-4","provenance_valid":true,"verdict":"FIX-FIRST"}]}'
FIXFIRST_DECISION="$HOME_D/fixfirst-first-success.json"
typed_decision_patch "$FIXFIRST_PATCH" "$FIXFIRST_DECISION"
check 'sanity: the FIX-FIRST completed_results patch reduces to fix-review-findings/review-findings-require-fix' "$([ "$(jq -r .action "$FIXFIRST_DECISION")" = fix-review-findings ] && [ "$(jq -r .reason "$FIXFIRST_DECISION")" = review-findings-require-fix ]; echo $?)" "action=$(jq -r .action "$FIXFIRST_DECISION") reason=$(jq -r .reason "$FIXFIRST_DECISION")"
check 'the completion-proof helper rejects a FIX-FIRST decision at the same head' "$(! daemon_decision_completes_current_head "$FIXFIRST_DECISION"; echo $?)"

NEEDSDISC_PATCH='{"completed_results":[{"applicable":true,"artifact_digest":"0000000000000000000000000000000000000000000000000000000000000000","binding_valid":true,"canonical_identity":"input-current","charged_spend_epoch":1700000004,"collected":true,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000004-4","provenance_valid":true,"verdict":"NEEDS-DISCUSSION"}]}'
NEEDSDISC_DECISION="$HOME_D/needsdisc-first-success.json"
typed_decision_patch "$NEEDSDISC_PATCH" "$NEEDSDISC_DECISION"
check 'sanity: the NEEDS-DISCUSSION completed_results patch (no named-choice outcomes) reduces to a non-completion stop reason' "$([ "$(jq -r .action "$NEEDSDISC_DECISION")" = stop-without-new-review ] && [ "$(jq -r .reason "$NEEDSDISC_DECISION")" != identical-code-and-evidence ]; echo $?)" "action=$(jq -r .action "$NEEDSDISC_DECISION") reason=$(jq -r .reason "$NEEDSDISC_DECISION")"
check 'the completion-proof helper rejects a NEEDS-DISCUSSION decision at the same head' "$(! daemon_decision_completes_current_head "$NEEDSDISC_DECISION"; echo $?)"

reset_state
daemon_run_review_worker(){ MOCK_FRESH="$FIXFIRST_DECISION"; return 0; }
FIXFIRST_RUN_DECISION="$HOME_D/fixfirst-run.json"; typed_decision "$(decision_for_action run-granted-review)" "$FIXFIRST_RUN_DECISION"
MOCK_FRESH="$FIXFIRST_RUN_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; fixfirst_rc=$?
# rc=2 (not 0) is the CORRECT outcome here, matching the existing "worker rc=0 whose re-resolved
# decision does NOT attest completion" case above: the worker ran, but with no completion proof the
# head stays retryable/deferred rather than being marked done.
check 'a FIX-FIRST result at the same head never completes it end-to-end (worker ran, no completion proof -> retryable, not marked)' "$([ "$fixfirst_rc" -eq 2 ] && ! already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$fixfirst_rc"

echo '# finding 2: an unrecognized/invented check state is UNSETTLED, never settled (closed allowlist)'

GH_ROLLUP='{"statusCheckRollup":[{"status":"SOMETHING_GITHUB_INVENTS_LATER"}]}'
state="$(ci_rollup_state "$NWO" "$NUM")"
check 'an unrecognized CheckRun .status (not in daemon.sh anywhere) reads as unsettled, not settled' "$([ "$state" = SOMETHING_GITHUB_INVENTS_LATER ]; echo $?)" "state=$state"

GH_ROLLUP='{"statusCheckRollup":[{"state":"SOMETHING_GITHUB_INVENTS_LATER"}]}'
state="$(ci_rollup_state "$NWO" "$NUM")"
check 'an unrecognized StatusContext .state (not in daemon.sh anywhere) reads as unsettled, not settled' "$([ "$state" = SOMETHING_GITHUB_INVENTS_LATER ]; echo $?)" "state=$state"

GH_ROLLUP='{"statusCheckRollup":[{"status":"REQUESTED"}]}'
state="$(ci_rollup_state "$NWO" "$NUM")"
check "GitHub's REQUESTED check-run status reads as unsettled" "$([ "$state" = REQUESTED ]; echo $?)" "state=$state"

GH_ROLLUP='{"statusCheckRollup":[{"state":"EXPECTED"}]}'
state="$(ci_rollup_state "$NWO" "$NUM")"
check "GitHub's EXPECTED status-context state reads as unsettled" "$([ "$state" = EXPECTED ]; echo $?)" "state=$state"
GH_ROLLUP='{"statusCheckRollup":[]}'

echo '# finding 3 (round 3 regression fix): repeated agent-task LAUNCH failures (rc=1) are bounded and land in blocked.tsv, never relaunched forever'

reset_state
AGENT_TASK_RUNS=0
daemon_run_agent_task(){ AGENT_TASK_RUNS=$((AGENT_TASK_RUNS + 1)); return 1; }   # the claude subprocess itself launched and failed -- a real, expensive attempt
below_cap_ok=1
i=1
while [ "$i" -lt "$AGENT_TASK_FAIL_MAX" ]; do
  : > "$LOG_FILE"
  MOCK_FRESH="$AGENT_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
  { [ "$rc" -eq 1 ] && ! already_done "$NWO" "$NUM" "$SHA"; } || below_cap_ok=0
  i=$((i + 1))
done
check "every rc=1 launch below the cap ($((AGENT_TASK_FAIL_MAX - 1)) of them) stays retryable, never completes the head" "$([ "$below_cap_ok" -eq 1 ] && [ "$(wc -l < "$AGENTFAIL_FILE")" -eq $((AGENT_TASK_FAIL_MAX - 1)) ]; echo $?)" "$(cat "$AGENTFAIL_FILE")"
: > "$LOG_FILE"
MOCK_FRESH="$AGENT_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; cap_rc=$?
check 'the cap-th rc=1 launch BLOCKS (never marks done), with a logged notice' "$([ "$cap_rc" -eq 1 ] && ! already_done "$NWO" "$NUM" "$SHA" && grep -Fq 'BLOCKED' "$LOG_FILE"; echo $?)" "$(tail -1 "$LOG_FILE")"
check 'the cap-th rc=1 launch is recorded in blocked.tsv, never processed-v2.tsv' "$([ ! -s "$STATE_FILE" ] && grep -qF "$(printf '%s\t%s\t%s\t' "$NWO" "$NUM" "$SHA")" "$BLOCKED_FILE"; echo $?)" "$(cat "$BLOCKED_FILE")"
check "the agent task actually launched $AGENT_TASK_FAIL_MAX times (each attempt is real, not skipped)" "$([ "$AGENT_TASK_RUNS" -eq "$AGENT_TASK_FAIL_MAX" ]; echo $?)" "runs=$AGENT_TASK_RUNS"
check 'repeated rc=1 launches never advance the (separate) no-progress attempt cap' "$([ ! -s "$AGENTCAP_FILE" ]; echo $?)" "$(cat "$AGENTCAP_FILE")"

: > "$LOG_FILE"
MOCK_FRESH="$AGENT_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; after_block_rc=$?
check 'a further poll on the launch-failure-blocked head never relaunches the agent task' "$([ "$after_block_rc" -eq 2 ] && [ "$AGENT_TASK_RUNS" -eq "$AGENT_TASK_FAIL_MAX" ]; echo $?)" "rc=$after_block_rc runs=$AGENT_TASK_RUNS"
check 'the launch-failure counter does not keep growing once blocked' "$([ "$(wc -l < "$AGENTFAIL_FILE")" -eq "$AGENT_TASK_FAIL_MAX" ]; echo $?)" "$(wc -l < "$AGENTFAIL_FILE")"
check 'still not marked done after the extra poll' "$(! already_done "$NWO" "$NUM" "$SHA"; echo $?)"

reset_state
daemon_run_agent_task(){ return 2; }   # no safe typed agent-task capability
below_cap_ok=1
i=1
while [ "$i" -le "$((AGENT_TASK_MAX * 2))" ]; do
  MOCK_FRESH="$AGENT_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
  { [ "$rc" -eq 2 ] && ! already_done "$NWO" "$NUM" "$SHA"; } || below_cap_ok=0
  i=$((i + 1))
done
check "a capability-unavailable agent task (rc=2), dispatched well past the cap ($((AGENT_TASK_MAX * 2))x), never completes the head" "$([ "$below_cap_ok" -eq 1 ]; echo $?)"
check 'a capability-unavailable agent task never advances the no-progress attempt cap' "$([ ! -s "$AGENTCAP_FILE" ]; echo $?)" "$(cat "$AGENTCAP_FILE")"
check 'a capability-unavailable agent task never writes processed.tsv' "$([ ! -s "$STATE_FILE" ]; echo $?)" "$(cat "$STATE_FILE")"

echo '# finding 2 (round 3): legacy-ledger migration -- durable evidence carries forward, missing evidence is quarantined and re-evaluated, migration is idempotent'

# "Durable evidence" = a CLEAN ledger.jsonl row, in the REAL pg_ledger_append/oracle-review.sh
# shape (oracle-review.sh:2428-2431, written here via the real pg_ledger_append writer, not an
# invented format), whose round_key matches the PR's slug, whose .marker names a real,
# structurally-complete (pg_is_review-passing) artifact in $(pg_completed_dir) -- the same
# write-once store oracle-review.sh itself writes into (pg_completed_write, v0.28 #56) -- AND
# (finding 1, round 4) whose marker carries a review-input-binding record whose target.head_oid
# is the EXACT legacy sha. write_input_binding below builds that record in the real producer
# shape oracle-review.sh installs for every dispatched attempt (oracle-review.sh:396-399,
# `pg_install_effect_input_binding` -> `pg_review_input_binding_write`), not an invented shape,
# and writes it through the real write-once writer (lib/pro-gate-lib.sh:3178+,
# `pg_review_binding_write_immutable`).
write_input_binding(){ # marker head-oid nwo num
  local marker="$1" head="$2" nwo="$3" num="$4" owner repo base raw endpoint binding
  owner="${nwo%%/*}"; repo="${nwo#*/}"
  base=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  raw=1111111111111111111111111111111111111111111111111111111111111111
  endpoint=2222222222222222222222222222222222222222222222222222222222222222
  binding="$(jq -cnS --arg cd "$PG_REVIEW_DECISION_CONTRACT_DIGEST" --arg marker "$marker" \
    --arg host github.com --arg owner "$owner" --arg repo "$repo" --argjson pr "$num" \
    --arg base "$base" --arg head "$head" --arg endpoint "$endpoint" --arg raw "$raw" \
    '{charged_spend_epoch:1,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("full-pr:"+$base+":"+$head),mode:"full-pr",proof:{base_oid:$base,endpoint_digest:$endpoint,head_oid:$head,raw_patch_digest:$raw}},marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:$host,owner:$owner,repo:$repo},target:{head_oid:$head,kind:"pull-request",pr:$pr}}')"
  pg_review_input_binding_write "$marker" "$binding"
}
# #184 finding 2 (round 6): mirrors the real producer's ONE writer of review-result-binding/v1
# records (pg_review_decision_repair_result_binding, oracle-review.sh:284-318) -- for a SHIP verdict,
# ship_proof is derived from the INPUT BINDING's own already-written evidence.proof fields, never a
# live re-fetch, which is exactly the offline-checkable invariant daemon_legacy_row_has_durable_evidence
# now requires (see its comment in daemon/daemon.sh). Requires write_input_binding for this marker
# to have already run. Written through the real write-once writer, exactly like write_input_binding.
write_result_binding(){ # marker verdict
  local marker="$1" verdict="$2" input_binding input_digest artifact_digest ship_proof result
  input_binding="$(pg_review_input_binding_read "$marker")" || return 1
  input_digest="$(pg_review_input_binding_digest "$marker")" || return 1
  artifact_digest="$(pg_sha256 "$COMPLETED_DIR/$marker")" || return 1
  if [ "$verdict" = SHIP ]; then
    ship_proof="$(jq -cnS --argjson b "$input_binding" '{base_oid:$b.evidence.proof.base_oid,diff_digest:$b.evidence.proof.raw_patch_digest,head_oid:$b.evidence.proof.head_oid}')"
  else
    ship_proof=null
  fi
  result="$(jq -cnS --arg cd "$PG_REVIEW_DECISION_CONTRACT_DIGEST" --arg marker "$marker" \
    --arg id "$input_digest" --arg ad "$artifact_digest" --arg verdict "$verdict" --argjson sp "$ship_proof" \
    '{accepted_epoch:1,artifact:{digest:$ad,path:("completed/"+$marker)},contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,input_binding_digest:$id,input_binding_identity:$marker,marker:$marker,named_choice:null,provenance:{outcome:"accepted",validated_epoch:1},record_type:"review-result-binding/v1",record_version:1,ship_proof:$sp,verdict:$verdict}')"
  pg_review_result_binding_write "$marker" "$result"
}
append_clean_ledger_row(){ # marker round-key pr artifact-path
  local marker="$1" round_key="$2" pr="$3" out="$4" line
  line="$(jq -nc --arg ts "2026-01-01T00:00:00+0000" --arg pr "$pr" --arg repo "/repos/widgets" \
    --argjson exit 0 --arg outcome clean --argjson secs 120 --argjson pre_slot_secs 0 --argjson post_slot_secs 0 \
    --arg kind pr --argjson attempts 1 --argjson conc 1 --argjson ceiling 1 --argjson live 0 --argjson salvaged 0 \
    --argjson diff_lines 10 --arg out "$out" --arg model test \
    --arg marker "$marker" --arg round_key "$round_key" --arg sha256 deadbeef \
    --arg reason "" --arg detail "" \
    '{ts:$ts,pr:$pr,repo:$repo,exit:$exit,outcome:$outcome,secs:$secs,pre_slot_secs:$pre_slot_secs,post_slot_secs:$post_slot_secs,kind:$kind,attempts:$attempts,conc:$conc,ceiling:$ceiling,live:$live,salvaged:$salvaged,diff_lines:$diff_lines,out:$out,model:$model,marker:$marker,round_key:$round_key,sha256:$sha256,reason:$reason,detail:$detail}')"
  pg_ledger_append "$line"
}

LEDGER_FILE="$HOME_D/ledger.jsonl"
COMPLETED_DIR="$(pg_completed_dir)"; mkdir -p "$COMPLETED_DIR"

EVIDENT_NWO=acme/widgets; EVIDENT_NUM=1983   # same slug as $NWO#$NUM -> round_key acme-widgets-1983
EVIDENT_SHA=4444444444444444444444444444444444444444
EVIDENT_MARKER=pg-run-acme-widgets-1983-1700000500-1
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP\n' > "$COMPLETED_DIR/$EVIDENT_MARKER"

UNEVIDENT_NWO=acme/gadgets; UNEVIDENT_NUM=77
UNEVIDENT_SHA=5555555555555555555555555555555555555555   # no ledger row, no completed artifact: unprovable

: > "$LEDGER_FILE"; : > "$LEGACY_FILE"; : > "$QUARANTINE_FILE"; : > "$STATE_FILE"
printf '%s\t%s\t%s\n' "$EVIDENT_NWO" "$EVIDENT_NUM" "$EVIDENT_SHA" >> "$LEGACY_FILE"
printf '%s\t%s\t%s\n' "$UNEVIDENT_NWO" "$UNEVIDENT_NUM" "$UNEVIDENT_SHA" >> "$LEGACY_FILE"

write_input_binding "$EVIDENT_MARKER" "$EVIDENT_SHA" "$EVIDENT_NWO" "$EVIDENT_NUM"
write_result_binding "$EVIDENT_MARKER" SHIP   # #184 finding 2 (round 6): durable evidence now also requires a validated, digest-matching result binding
append_clean_ledger_row "$EVIDENT_MARKER" "${EVIDENT_NWO//\//-}-${EVIDENT_NUM}" "$EVIDENT_NUM" "$COMPLETED_DIR/$EVIDENT_MARKER"

daemon_migrate_legacy_processed

check 'a legacy row WITH durable evidence bound to its exact sha is carried forward into the new ledger' "$(already_done "$EVIDENT_NWO" "$EVIDENT_NUM" "$EVIDENT_SHA"; echo $?)" "$(cat "$STATE_FILE")"
check 'a legacy row lacking durable evidence is quarantined, not carried forward' "$(! already_done "$UNEVIDENT_NWO" "$UNEVIDENT_NUM" "$UNEVIDENT_SHA" && grep -qF "$(printf '%s\t%s\t%s' "$UNEVIDENT_NWO" "$UNEVIDENT_NUM" "$UNEVIDENT_SHA")" "$QUARANTINE_FILE"; echo $?)" "$(cat "$QUARANTINE_FILE")"
check 'the legacy file itself is never deleted or truncated by migration' "$([ -s "$LEGACY_FILE" ] && [ "$(wc -l < "$LEGACY_FILE")" -eq 2 ]; echo $?)" "$(cat "$LEGACY_FILE")"
check 'a quarantined head is genuinely re-evaluated on the next poll, not permanently skipped (already_done is false, so the main loops already_done-continue gate does not suppress it)' "$(! already_done "$UNEVIDENT_NWO" "$UNEVIDENT_NUM" "$UNEVIDENT_SHA"; echo $?)"

STATE_AFTER_FIRST="$(cat "$STATE_FILE")"; QUARANTINE_AFTER_FIRST="$(cat "$QUARANTINE_FILE")"
daemon_migrate_legacy_processed
check 'migration run a second time is idempotent: processed-v2.tsv unchanged' "$([ "$(cat "$STATE_FILE")" = "$STATE_AFTER_FIRST" ]; echo $?)" "before=[$STATE_AFTER_FIRST] after=[$(cat "$STATE_FILE")]"
check 'migration run a second time is idempotent: quarantine unchanged (no duplicate row)' "$([ "$(cat "$QUARANTINE_FILE")" = "$QUARANTINE_AFTER_FIRST" ]; echo $?)" "before=[$QUARANTINE_AFTER_FIRST] after=[$(cat "$QUARANTINE_FILE")]"

echo '# finding 1 (round 4): sha-exact binding -- one round_key with a real artifact for head A only must promote A and quarantine B, never let As evidence vouch for B'

# Reproduces the actual #184 finding-1 defect: the pre-#184x mark_processed_heads wrote BOTH a
# genuinely-reviewed head (A) and its never-reviewed successor (B) into processed.tsv for the SAME
# PR. Only A has a real review-input-binding; B has none. A round_key-only check (the pre-fix
# behavior) validates both rows off the one artifact that actually backs A alone.
AB_NWO=acme/rockets; AB_NUM=42
AB_ROUND_KEY="${AB_NWO//\//-}-${AB_NUM}"
SHA_A=6666666666666666666666666666666666666666   # genuinely reviewed
SHA_B=7777777777777777777777777777777777777777   # never reviewed; only recorded because the old
                                                   # mark_processed_heads looked up the LIVE head
AB_MARKER=pg-run-acme-rockets-42-1700000600-1
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP\n' > "$COMPLETED_DIR/$AB_MARKER"
write_input_binding "$AB_MARKER" "$SHA_A" "$AB_NWO" "$AB_NUM"   # binding exists for A only
write_result_binding "$AB_MARKER" SHIP   # #184 finding 2 (round 6): A also has a validated, digest-matching result binding
append_clean_ledger_row "$AB_MARKER" "$AB_ROUND_KEY" "$AB_NUM" "$COMPLETED_DIR/$AB_MARKER"

: > "$LEGACY_FILE"; : > "$QUARANTINE_FILE"; : > "$STATE_FILE"
printf '%s\t%s\t%s\n' "$AB_NWO" "$AB_NUM" "$SHA_A" >> "$LEGACY_FILE"
printf '%s\t%s\t%s\n' "$AB_NWO" "$AB_NUM" "$SHA_B" >> "$LEGACY_FILE"

check 'sanity: the shared marker DOES carry durable completed-artifact evidence for the round_key (the old, insufficient check would pass both rows on this alone)' "$([ -s "$COMPLETED_DIR/$AB_MARKER" ]; echo $?)"

daemon_migrate_legacy_processed

check 'the genuinely-reviewed head A promotes into the new ledger' "$(already_done "$AB_NWO" "$AB_NUM" "$SHA_A"; echo $?)" "$(cat "$STATE_FILE")"
check 'the never-reviewed successor B does NOT promote, even though it shares As artifact-bearing round_key' "$(! already_done "$AB_NWO" "$AB_NUM" "$SHA_B"; echo $?)" "$(cat "$STATE_FILE")"
check 'B is quarantined (re-evaluated next poll), not silently dropped' "$(grep -qF "$(printf '%s\t%s\t%s' "$AB_NWO" "$AB_NUM" "$SHA_B")" "$QUARANTINE_FILE"; echo $?)" "$(cat "$QUARANTINE_FILE")"
check 'A is never quarantined' "$(! grep -qF "$(printf '%s\t%s\t%s' "$AB_NWO" "$AB_NUM" "$SHA_A")" "$QUARANTINE_FILE"; echo $?)"

echo '# #184 finding 2 (round 5): an exact-sha-bound legacy artifact still must not promote unless it is a genuine, unmixed SHIP -- outcome-appropriateness, not sha-binding alone'

# A FIX-FIRST review IS the reason the old daemon's separate agent-task ran; the new lifecycle
# deliberately treats agent-task success as non-terminal (see the "a successful agent-task does not
# complete the head" check above). If the exact-sha binding alone were sufficient, this exact-sha,
# structurally-complete, non-foreign FIX-FIRST artifact would satisfy the old check and re-promote a
# row the new lifecycle refuses to complete.
FF_NWO=acme/probes; FF_NUM=9
FF_SHA=9111111111111111111111111111111111111111
FF_MARKER=pg-run-acme-probes-9-1700000800-1
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: FIX-FIRST\n' > "$COMPLETED_DIR/$FF_MARKER"
write_input_binding "$FF_MARKER" "$FF_SHA" "$FF_NWO" "$FF_NUM"   # exact-sha binding, otherwise valid
append_clean_ledger_row "$FF_MARKER" "${FF_NWO//\//-}-${FF_NUM}" "$FF_NUM" "$COMPLETED_DIR/$FF_MARKER"
: > "$LEGACY_FILE"; : > "$QUARANTINE_FILE"; : > "$STATE_FILE"
printf '%s\t%s\t%s\n' "$FF_NWO" "$FF_NUM" "$FF_SHA" >> "$LEGACY_FILE"

daemon_migrate_legacy_processed

check 'sanity: the FIX-FIRST artifact is structurally a complete review (pg_is_review) with an exact-sha binding' "$(pg_is_review "$COMPLETED_DIR/$FF_MARKER"; echo $?)"
check 'an exact-sha-bound legacy artifact whose verdict is FIX-FIRST (not SHIP) is quarantined, not promoted' "$(! already_done "$FF_NWO" "$FF_NUM" "$FF_SHA" && grep -qF "$(printf '%s\t%s\t%s' "$FF_NWO" "$FF_NUM" "$FF_SHA")" "$QUARANTINE_FILE"; echo $?)" "$(cat "$STATE_FILE") / $(cat "$QUARANTINE_FILE")"

# A NEEDS-DISCUSSION review is the other non-terminal outcome; same requirement.
ND_NWO=acme/probes; ND_NUM=10
ND_SHA=9222222222222222222222222222222222222222
ND_MARKER=pg-run-acme-probes-10-1700000900-1
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: NEEDS-DISCUSSION\n' > "$COMPLETED_DIR/$ND_MARKER"
write_input_binding "$ND_MARKER" "$ND_SHA" "$ND_NWO" "$ND_NUM"
append_clean_ledger_row "$ND_MARKER" "${ND_NWO//\//-}-${ND_NUM}" "$ND_NUM" "$COMPLETED_DIR/$ND_MARKER"
: > "$LEGACY_FILE"; : > "$QUARANTINE_FILE"; : > "$STATE_FILE"
printf '%s\t%s\t%s\n' "$ND_NWO" "$ND_NUM" "$ND_SHA" >> "$LEGACY_FILE"

daemon_migrate_legacy_processed

check 'an exact-sha-bound legacy artifact whose verdict is NEEDS-DISCUSSION (not SHIP) is quarantined, not promoted' "$(! already_done "$ND_NWO" "$ND_NUM" "$ND_SHA" && grep -qF "$(printf '%s\t%s\t%s' "$ND_NWO" "$ND_NUM" "$ND_SHA")" "$QUARANTINE_FILE"; echo $?)" "$(cat "$STATE_FILE") / $(cat "$QUARANTINE_FILE")"

# A foreign/mixed capture: structurally a complete SHIP review, exact-sha bound to OUR marker, but
# its own trailing verdict line's "(run marker: ...)" annotation names a DIFFERENT marker --
# pg_capture_foreign_echo (the SAME rejection oracle-review.sh's own live path applies at its own
# read sites, e.g. oracle-review.sh:289,519,539) must reject it the same way here.
FOREIGN_NWO=acme/probes; FOREIGN_NUM=11
FOREIGN_SHA=9333333333333333333333333333333333333333
FOREIGN_MARKER=pg-run-acme-probes-11-1700001000-1
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP (run marker: pg-run-someone-elses-review-1)\n' > "$COMPLETED_DIR/$FOREIGN_MARKER"
write_input_binding "$FOREIGN_MARKER" "$FOREIGN_SHA" "$FOREIGN_NWO" "$FOREIGN_NUM"
append_clean_ledger_row "$FOREIGN_MARKER" "${FOREIGN_NWO//\//-}-${FOREIGN_NUM}" "$FOREIGN_NUM" "$COMPLETED_DIR/$FOREIGN_MARKER"
: > "$LEGACY_FILE"; : > "$QUARANTINE_FILE"; : > "$STATE_FILE"
printf '%s\t%s\t%s\n' "$FOREIGN_NWO" "$FOREIGN_NUM" "$FOREIGN_SHA" >> "$LEGACY_FILE"

daemon_migrate_legacy_processed

check 'sanity: the foreign-capture artifact DOES echo a foreign run-marker claim (pg_capture_foreign_echo non-empty)' "$([ -n "$(pg_capture_foreign_echo "$COMPLETED_DIR/$FOREIGN_MARKER" "$FOREIGN_MARKER")" ]; echo $?)" "$(pg_capture_foreign_echo "$COMPLETED_DIR/$FOREIGN_MARKER" "$FOREIGN_MARKER")"
check 'an exact-sha-bound legacy artifact carrying a foreign/mixed verdict claim is quarantined, not promoted' "$(! already_done "$FOREIGN_NWO" "$FOREIGN_NUM" "$FOREIGN_SHA" && grep -qF "$(printf '%s\t%s\t%s' "$FOREIGN_NWO" "$FOREIGN_NUM" "$FOREIGN_SHA")" "$QUARANTINE_FILE"; echo $?)" "$(cat "$STATE_FILE") / $(cat "$QUARANTINE_FILE")"

echo '# #184 finding 3 (round 5): round_key is a LOSSY composite (owner-repo-pr dashed together) -- two different repositories that collide on the same round_key string must never durable-evidence each others row, even sharing the same head sha'

# "${nwo//\//-}-${num}" collapses "foo-bar/baz#1" and "foo/bar-baz#1" to the identical string
# "foo-bar-baz-1" -- exactly the collision named in the finding.
COLLIDE_NWO_A=foo-bar/baz; COLLIDE_NUM_A=1     # owner=foo-bar repo=baz
COLLIDE_NWO_B=foo/bar-baz; COLLIDE_NUM_B=1     # owner=foo    repo=bar-baz
check 'sanity: the two different (owner,repo) pairs collide on the SAME lossy round_key' "$([ "${COLLIDE_NWO_A//\//-}-${COLLIDE_NUM_A}" = "${COLLIDE_NWO_B//\//-}-${COLLIDE_NUM_B}" ]; echo $?)" "${COLLIDE_NWO_A//\//-}-${COLLIDE_NUM_A} vs ${COLLIDE_NWO_B//\//-}-${COLLIDE_NUM_B}"

COLLIDE_SHA=9444444444444444444444444444444444444444   # the SAME sha on both rows, to isolate identity from sha
COLLIDE_MARKER=pg-run-foo-bar-baz-1-1700001100-1
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP\n' > "$COMPLETED_DIR/$COLLIDE_MARKER"
write_input_binding "$COLLIDE_MARKER" "$COLLIDE_SHA" "$COLLIDE_NWO_A" "$COLLIDE_NUM_A"   # binding exists for A (owner=foo-bar) only
write_result_binding "$COLLIDE_MARKER" SHIP   # #184 finding 2 (round 6): A also has a validated, digest-matching result binding
append_clean_ledger_row "$COLLIDE_MARKER" "${COLLIDE_NWO_A//\//-}-${COLLIDE_NUM_A}" "$COLLIDE_NUM_A" "$COMPLETED_DIR/$COLLIDE_MARKER"

: > "$LEGACY_FILE"; : > "$QUARANTINE_FILE"; : > "$STATE_FILE"
printf '%s\t%s\t%s\n' "$COLLIDE_NWO_A" "$COLLIDE_NUM_A" "$COLLIDE_SHA" >> "$LEGACY_FILE"
printf '%s\t%s\t%s\n' "$COLLIDE_NWO_B" "$COLLIDE_NUM_B" "$COLLIDE_SHA" >> "$LEGACY_FILE"   # different repo, SAME round_key, SAME sha

daemon_migrate_legacy_processed

check 'the genuinely-bound repository A promotes into the new ledger' "$(already_done "$COLLIDE_NWO_A" "$COLLIDE_NUM_A" "$COLLIDE_SHA"; echo $?)" "$(cat "$STATE_FILE")"
check 'a DIFFERENT repository B sharing As lossy round_key and even the same sha does NOT promote off As review' "$(! already_done "$COLLIDE_NWO_B" "$COLLIDE_NUM_B" "$COLLIDE_SHA"; echo $?)" "$(cat "$STATE_FILE")"
check 'B is quarantined rather than silently dropped' "$(grep -qF "$(printf '%s\t%s\t%s' "$COLLIDE_NWO_B" "$COLLIDE_NUM_B" "$COLLIDE_SHA")" "$QUARANTINE_FILE"; echo $?)" "$(cat "$QUARANTINE_FILE")"

echo '# #184 finding 2 (round 6): a SHIP artifact plus a valid exact-sha input binding but a MISSING result binding is quarantined, not promoted -- pg_persist_result (oracle-review.sh) explicitly tolerates result-binding repair failure, so a clean ledger row, a completed SHIP artifact, and a valid input binding can coexist with no result binding, and the live engine treats that as collect-existing-result, not terminal completion'

NORESULT_NWO=acme/relays; NORESULT_NUM=55
NORESULT_SHA=9555555555555555555555555555555555555555
NORESULT_MARKER=pg-run-acme-relays-55-1700001200-1
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP\n' > "$COMPLETED_DIR/$NORESULT_MARKER"
write_input_binding "$NORESULT_MARKER" "$NORESULT_SHA" "$NORESULT_NWO" "$NORESULT_NUM"   # valid exact-sha input binding; deliberately NO result binding
append_clean_ledger_row "$NORESULT_MARKER" "${NORESULT_NWO//\//-}-${NORESULT_NUM}" "$NORESULT_NUM" "$COMPLETED_DIR/$NORESULT_MARKER"
: > "$LEGACY_FILE"; : > "$QUARANTINE_FILE"; : > "$STATE_FILE"
printf '%s\t%s\t%s\n' "$NORESULT_NWO" "$NORESULT_NUM" "$NORESULT_SHA" >> "$LEGACY_FILE"

check 'sanity: no result binding exists yet for this marker' "$(! pg_review_result_binding_read "$NORESULT_MARKER" >/dev/null 2>&1; echo $?)"

daemon_migrate_legacy_processed

check 'RED: a SHIP artifact + valid input binding but a MISSING result binding is NOT promoted (the live engine would resolve this to collect-existing-result, not terminal completion)' "$(! already_done "$NORESULT_NWO" "$NORESULT_NUM" "$NORESULT_SHA"; echo $?)" "$(cat "$STATE_FILE")"
check 'the missing-result-binding row is quarantined so normal collect-existing-result can repair it, not silently dropped' "$(grep -qF "$(printf '%s\t%s\t%s' "$NORESULT_NWO" "$NORESULT_NUM" "$NORESULT_SHA")" "$QUARANTINE_FILE"; echo $?)" "$(cat "$QUARANTINE_FILE")"

# Attach a valid, digest-matching result binding for the SAME marker/artifact/input-binding and
# re-run migration: this is the GREEN half of the red-then-green pair above -- the identical
# artifact and input-binding state now promotes once (and only once) genuine collection evidence
# exists.
write_result_binding "$NORESULT_MARKER" SHIP
: > "$LEGACY_FILE"; : > "$QUARANTINE_FILE"; : > "$STATE_FILE"
printf '%s\t%s\t%s\n' "$NORESULT_NWO" "$NORESULT_NUM" "$NORESULT_SHA" >> "$LEGACY_FILE"

daemon_migrate_legacy_processed

check 'GREEN: the SAME row promotes once a validated, digest-matching result binding exists' "$(already_done "$NORESULT_NWO" "$NORESULT_NUM" "$NORESULT_SHA"; echo $?)" "$(cat "$STATE_FILE")"

echo '# #184 finding 2 (round 6): a result binding whose ship_proof does not match the input bindings own stored evidence proof (tampered, or written by a different query) is quarantined too -- offline-checkable per pg_review_decision_repair_result_binings own derivation, oracle-review.sh:284-318'

MISMATCH_NWO=acme/relays; MISMATCH_NUM=56
MISMATCH_SHA=9666666666666666666666666666666666666666
MISMATCH_MARKER=pg-run-acme-relays-56-1700001300-1
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP\n' > "$COMPLETED_DIR/$MISMATCH_MARKER"
write_input_binding "$MISMATCH_MARKER" "$MISMATCH_SHA" "$MISMATCH_NWO" "$MISMATCH_NUM"
mismatch_binding="$(pg_review_input_binding_read "$MISMATCH_MARKER")"
mismatch_input_digest="$(pg_review_input_binding_digest "$MISMATCH_MARKER")"
mismatch_artifact_digest="$(pg_sha256 "$COMPLETED_DIR/$MISMATCH_MARKER")"
mismatch_result="$(jq -cnS --arg cd "$PG_REVIEW_DECISION_CONTRACT_DIGEST" --arg marker "$MISMATCH_MARKER" \
  --arg id "$mismatch_input_digest" --arg ad "$mismatch_artifact_digest" --argjson b "$mismatch_binding" \
  '{accepted_epoch:1,artifact:{digest:$ad,path:("completed/"+$marker)},contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,input_binding_digest:$id,input_binding_identity:$marker,marker:$marker,named_choice:null,provenance:{outcome:"accepted",validated_epoch:1},record_type:"review-result-binding/v1",record_version:1,ship_proof:{base_oid:"cccccccccccccccccccccccccccccccccccccccc",diff_digest:$b.evidence.proof.raw_patch_digest,head_oid:$b.evidence.proof.head_oid},verdict:"SHIP"}')"
pg_review_result_binding_write "$MISMATCH_MARKER" "$mismatch_result"
append_clean_ledger_row "$MISMATCH_MARKER" "${MISMATCH_NWO//\//-}-${MISMATCH_NUM}" "$MISMATCH_NUM" "$COMPLETED_DIR/$MISMATCH_MARKER"
: > "$LEGACY_FILE"; : > "$QUARANTINE_FILE"; : > "$STATE_FILE"
printf '%s\t%s\t%s\n' "$MISMATCH_NWO" "$MISMATCH_NUM" "$MISMATCH_SHA" >> "$LEGACY_FILE"

daemon_migrate_legacy_processed

check 'a result binding whose ship_proof.base_oid does not match the input bindings own stored proof is quarantined, not promoted' "$(! already_done "$MISMATCH_NWO" "$MISMATCH_NUM" "$MISMATCH_SHA" && grep -qF "$(printf '%s\t%s\t%s' "$MISMATCH_NWO" "$MISMATCH_NUM" "$MISMATCH_SHA")" "$QUARANTINE_FILE"; echo $?)" "$(cat "$STATE_FILE") / $(cat "$QUARANTINE_FILE")"

echo '# #184 finding 1 (round 6): the daemon persists review evidence outside the disposable worktree and passes it (--diff plus PRO_GATE_REVIEW_ENDPOINT_PATCH) into every subsequent decision query for that exact head, so a head whose evidence is unavailable can never be proven complete, while a head whose evidence IS available resolves instead of looping on prepare-matching-review-evidence forever'

# CRITICAL TEST REQUIREMENT (round 6): the double above (ENGINE, defined near the top of this file)
# is ARGV-INSENSITIVE by construction -- it returns whatever $MOCK_FRESH points to on any
# --review-decision/--review-decision-effect call, regardless of whether --diff or
# PRO_GATE_REVIEW_ENDPOINT_PATCH were passed. That is exactly the flaw the finding names: such a
# double cannot distinguish a query that would really resolve (matching evidence present) from one
# that cannot (evidence absent), so it could not have caught a regression that silently stopped
# wiring evidence into these queries. A full run of the REAL engine (oracle-review.sh) needs a live
# git repo, gh auth, and a real claude subprocess, and is impractical inside this offline,
# ~20-test-file-budget unit suite -- so, per the finding's own stated fallback, the double is
# rebuilt here to be ARGV-AWARE instead: for every --review-decision/--review-decision-effect call
# it returns the same prepare-matching-review-evidence action the real engine's read-only query
# returns when it cannot establish a current evidence relation (the real engine's --diff-gated
# auto-fetch is DIFF_IS_CALLER_SUPPLIED-controlled; a query with neither --diff nor
# PRO_GATE_REVIEW_ENDPOINT_PATCH can never reach the evidence this fixture models) UNLESS BOTH
# --diff and PRO_GATE_REVIEW_ENDPOINT_PATCH are present, in which case it returns the nominated
# completing decision -- so a daemon regression that stops wiring evidence into a query reproduces
# the real engine's actual failure mode here, not a stub artifact that cannot fail the way
# production fails. This is scoped to this section only: it is installed after every prior check in
# this file has already run against the original argv-insensitive double, and nothing after this
# point relies on the original double's unconditional behavior.
NOEVID_DECISION="$HOME_D/noevid.json"; typed_decision "$(decision_for_action prepare-matching-review-evidence)" "$NOEVID_DECISION"
check 'sanity: the no-evidence corpus fixture is agent-task/prepare-matching-review-evidence' "$([ "$(jq -r .action "$NOEVID_DECISION")" = prepare-matching-review-evidence ] && [ "$(jq -r .effect_request.execution_class "$NOEVID_DECISION")" = agent-task ]; echo $?)" "$(jq -c '{action:.action,class:.effect_request.execution_class}' "$NOEVID_DECISION")"

cat > "$ENGINE" <<'ENGINESCRIPT'
#!/usr/bin/env bash
case " $* " in
  *" --review-decision-effect "*|*" --review-decision "*)
    case " $* " in
      *" --diff "*)
        if [ -n "${PRO_GATE_REVIEW_ENDPOINT_PATCH:-}" ]; then cat "$MOCK_FRESH"; else cat "$NOEVID_DECISION"; fi ;;
      *) cat "$NOEVID_DECISION" ;;
    esac
    ;;
  *" --recover "*) : ;;
esac
ENGINESCRIPT
chmod +x "$ENGINE"
export NOEVID_DECISION

echo '# finding 1 RED: evidence fetch unavailable -- the daemon can never resolve a completing decision for this head, only prepare-matching-review-evidence, bounded only by the pre-existing agent-task no-progress cap, never completed'
reset_state
rm -f "$REVIEW_EVIDENCE_DIR"/*.diff 2>/dev/null
GH_DIFF_RC=1   # simulate gh pr diff failing -- no evidence is ever persisted, matching a daemon that never wires evidence in at all
AGENT_RUNS_NOEVID=0
daemon_run_agent_task(){ AGENT_RUNS_NOEVID=$((AGENT_RUNS_NOEVID + 1)); return 0; }
i=1
noevid_ok=1
while [ "$i" -lt "$AGENT_TASK_MAX" ]; do
  MOCK_FRESH="$NOEVID_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL" >/dev/null; rc=$?
  { [ "$rc" -eq 0 ] && ! already_done "$NWO" "$NUM" "$SHA"; } || noevid_ok=0
  i=$((i + 1))
done
check "without evidence, every poll below the cap ($((AGENT_TASK_MAX - 1)) of them) resolves to prepare-matching-review-evidence and never completes the head" "$([ "$noevid_ok" -eq 1 ]; echo $?)"
MOCK_FRESH="$NOEVID_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; noevid_cap_rc=$?
check 'without evidence, the head is eventually BLOCKED by the pre-existing agent-task no-progress cap -- never completed, never marked done' "$([ "$noevid_cap_rc" -eq 0 ] && ! already_done "$NWO" "$NUM" "$SHA" && is_blocked "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$noevid_cap_rc $(cat "$BLOCKED_FILE")"
check 'the evidence directory stayed empty for this head the whole time (fetch never succeeded)' "$([ -z "$(ls -A "$REVIEW_EVIDENCE_DIR" 2>/dev/null)" ]; echo $?)" "$(ls "$REVIEW_EVIDENCE_DIR" 2>/dev/null)"

echo '# finding 1 GREEN: evidence fetch available -- the daemon persists it outside the worktree, passes it into the query, and the SAME head resolves to completion instead of relaunching'
reset_state
rm -f "$REVIEW_EVIDENCE_DIR"/*.diff 2>/dev/null
GH_DIFF_RC=0
: > "$GH_DIFF_CALLS_FILE"
GREEN_DECISION="$HOME_D/green-complete.json"
typed_decision_patch '{"prior_review":{"applicable":false,"binding_valid":true,"code_identity":"input-current","evidence_identity":"evidence-current","legacy":false,"marker":"pg-run-acme-widgets-1983-1700002000-1","provenance_valid":true,"verdict":"NONE"}}' "$GREEN_DECISION"
check 'sanity: the green completing fixture is stop-without-new-review/identical-code-and-evidence' "$([ "$(jq -r .action "$GREEN_DECISION")" = stop-without-new-review ] && [ "$(jq -r .reason "$GREEN_DECISION")" = identical-code-and-evidence ]; echo $?)"
MOCK_FRESH="$GREEN_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; green_rc=$?
check 'with evidence persisted and wired into the query, the SAME head completes on this poll (no agent-task relaunch)' "$([ "$green_rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$green_rc"
check 'the evidence fetch was actually made exactly once (not skipped)' "$([ "$(gh_diff_calls)" -eq 1 ]; echo $?)" "calls=$(gh_diff_calls)"
check 'completion cleans up the now-unneeded persisted evidence file for this exact head' "$([ ! -e "$(daemon_evidence_file "$NWO" "$NUM" "$SHA")" ]; echo $?)" "$(ls "$REVIEW_EVIDENCE_DIR" 2>/dev/null)"

echo '# finding 1: superseding a head (new push, new sha) prunes its now-stale persisted evidence rather than accumulating unboundedly'
reset_state
rm -f "$REVIEW_EVIDENCE_DIR"/*.diff 2>/dev/null
daemon_run_agent_task(){ return 2; }   # capability-unavailable; a deliberate no-op so this section only exercises evidence bookkeeping
MOCK_FRESH="$NOEVID_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL" >/dev/null
check 'evidence for the current sha now exists on disk' "$([ -s "$(daemon_evidence_file "$NWO" "$NUM" "$SHA")" ]; echo $?)" "$(ls "$REVIEW_EVIDENCE_DIR" 2>/dev/null)"
SUPERSEDE_SHA=8888888888888888888888888888888888888888
MOCK_FRESH="$NOEVID_DECISION" process_pr "$NWO" "$NUM" "$SUPERSEDE_SHA" "$BRANCH" "$URL" >/dev/null
check 'a new push (new sha) prunes the OLD shas persisted evidence rather than accumulating both' "$([ ! -e "$(daemon_evidence_file "$NWO" "$NUM" "$SHA")" ]; echo $?)" "$(ls "$REVIEW_EVIDENCE_DIR" 2>/dev/null)"
check 'the new shas own evidence file now exists in its place' "$([ -s "$(daemon_evidence_file "$NWO" "$NUM" "$SUPERSEDE_SHA")" ]; echo $?)" "$(ls "$REVIEW_EVIDENCE_DIR" 2>/dev/null)"

echo '# #184 finding 3 (round 6): a review worker that exits 0 but never actually submits (the re-resolved decision still requests the SAME unstarted run-granted-review) is bounded by its own no-progress cap, escalating to blocked.tsv, never the completion ledger; genuine progress toward a different outcome is never penalised'

reset_state
rm -f "$REVIEW_EVIDENCE_DIR"/*.diff 2>/dev/null
GH_DIFF_RC=0
NOPROG_RUN_DECISION="$HOME_D/noprog-run.json"; typed_decision "$(decision_for_action run-granted-review)" "$NOPROG_RUN_DECISION"
daemon_run_review_worker(){ return 0; }   # exits 0 but never actually submitted -- MOCK_FRESH stays the SAME unstarted run-granted-review decision on re-resolution
below_noprog_cap_ok=1
i=1
while [ "$i" -lt "$REVIEW_WORKER_NO_PROGRESS_MAX" ]; do
  MOCK_FRESH="$NOPROG_RUN_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
  { [ "$rc" -eq 2 ] && ! already_done "$NWO" "$NUM" "$SHA" && ! is_blocked "$NWO" "$NUM" "$SHA"; } || below_noprog_cap_ok=0
  i=$((i + 1))
done
check "every exit-0-no-progress review worker below the cap ($((REVIEW_WORKER_NO_PROGRESS_MAX - 1)) of them) stays retryable, never blocked, never completed" "$([ "$below_noprog_cap_ok" -eq 1 ] && [ "$(wc -l < "$REVIEWNOPROG_FILE")" -eq $((REVIEW_WORKER_NO_PROGRESS_MAX - 1)) ]; echo $?)" "$(cat "$REVIEWNOPROG_FILE")"
MOCK_FRESH="$NOPROG_RUN_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; noprog_cap_rc=$?
# Note: unlike the agent-task no-progress cap (which returns the underlying rc=0 agent-task exit
# code even once blocked), this review-worker re-resolve path returns 2 (retryable-defer)
# UNCONDITIONALLY on this branch, whether or not the no-progress cap was just exhausted -- see
# daemon.sh's process_pr, the "review_ran" re-resolve block. That numeric code carries no
# production meaning: the dispatch loop (daemon.sh ~line 1093) never reads process_pr's exit
# status at all, only is_blocked()/already_done() (checked at the top of the NEXT process_pr call)
# govern whether dispatch happens again. So the meaningful assertion here is is_blocked +
# !already_done, not a specific rc.
check 'the cap-th exit-0-no-progress review worker BLOCKS (never completes)' "$(! already_done "$NWO" "$NUM" "$SHA" && is_blocked "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$noprog_cap_rc $(cat "$BLOCKED_FILE")"
check 'the no-progress exhaustion is recorded as review-worker-no-progress-cap-exhausted in blocked.tsv, never processed-v2.tsv' "$([ ! -s "$STATE_FILE" ] && grep -qF "$(printf '%s\t%s\t%s\treview-worker-no-progress-cap-exhausted' "$NWO" "$NUM" "$SHA")" "$BLOCKED_FILE"; echo $?)" "$(cat "$BLOCKED_FILE")"

WORKER_RUNS_NOPROG=0
daemon_run_review_worker(){ WORKER_RUNS_NOPROG=$((WORKER_RUNS_NOPROG + 1)); return 0; }
MOCK_FRESH="$NOPROG_RUN_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"
check 'a further poll on the no-progress-blocked head never relaunches the review worker again' "$([ "$WORKER_RUNS_NOPROG" -eq 0 ]; echo $?)" "runs=$WORKER_RUNS_NOPROG"

echo '# finding 3: genuine progress toward a DIFFERENT outcome (collect-existing-result) is never charged against the no-progress cap, however many times it is driven past the cap'
reset_state
rm -f "$REVIEW_EVIDENCE_DIR"/*.diff 2>/dev/null
COLLECT_DECISION="$HOME_D/progress-collect.json"; typed_decision "$(decision_for_action collect-existing-result)" "$COLLECT_DECISION"
check 'sanity: the progress fixture is runtime-guarded-effect/collect-existing-result' "$([ "$(jq -r .action "$COLLECT_DECISION")" = collect-existing-result ]; echo $?)" "$(jq -r .action "$COLLECT_DECISION")"
daemon_run_review_worker(){ MOCK_FRESH="$COLLECT_DECISION"; return 0; }
PROGRESS_RUN_DECISION="$HOME_D/progress-run.json"; typed_decision "$(decision_for_action run-granted-review)" "$PROGRESS_RUN_DECISION"
i=1
while [ "$i" -le "$((REVIEW_WORKER_NO_PROGRESS_MAX * 2))" ]; do
  MOCK_FRESH="$PROGRESS_RUN_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL" >/dev/null
  i=$((i + 1))
done
check "a review worker whose re-resolved decision advances to a DIFFERENT action (collect-existing-result), driven well past the no-progress cap ($((REVIEW_WORKER_NO_PROGRESS_MAX * 2))x), never increments the no-progress counter" "$([ ! -s "$REVIEWNOPROG_FILE" ]; echo $?)" "$(cat "$REVIEWNOPROG_FILE")"
check 'and is therefore never blocked by it' "$(! is_blocked "$NWO" "$NUM" "$SHA"; echo $?)"

[ "$TEST_FAILURES" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$TEST_FAILURES FAILURES"; exit 1; }
