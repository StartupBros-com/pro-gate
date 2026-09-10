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
LOG_FILE="$HOME_D/t.log"; : > "$LOG_FILE"
log(){ printf '%s\n' "$*" >> "$LOG_FILE"; }

check 'daemon.sh created the bounded #184 ledger files at startup' "$([ -f "$CIDEFER_FILE" ] && [ -f "$AGENTCAP_FILE" ] && [ -f "$BLOCKED_FILE" ]; echo $?)" "$(ls "$HOME_D")"
check 'daemon.sh created the #184 finding-2/3 (round 3) ledger files at startup' "$([ -f "$STATE_FILE" ] && [ -f "$LEGACY_FILE" ] && [ -f "$QUARANTINE_FILE" ] && [ -f "$AGENTFAIL_FILE" ]; echo $?)" "$(ls "$HOME_D")"

reset_state(){ : > "$STATE_FILE"; : > "$FAILS_FILE"; : > "$CIDEFER_FILE"; : > "$AGENTCAP_FILE"; : > "$AGENTFAIL_FILE"; : > "$BLOCKED_FILE"; : > "$LOG_FILE"; }

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

# gh() answers only the #184a CI-readiness query (statusCheckRollup). Nothing else in the fixed
# daemon.sh flow should call gh once mark_processed_heads no longer looks up the live head.
GH_ROLLUP='{"statusCheckRollup":[]}'   # default: no checks configured -> settled
gh(){
  if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    case " $* " in
      *' --json statusCheckRollup '*) printf '%s\n' "$GH_ROLLUP"; return 0 ;;
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
# can never emit; requiring it in daemon_stop_is_completion_proof made a genuine identical-code/
# evidence stop unsatisfiable and caused the daemon to retry forever. This is the producer's real
# shape -- identical to the already-verified reducer-level case in
# tests/engine.test.sh:5291-5292 ("identical verified code and evidence cannot authorize another
# review") -- proving the helper against genuine producer output, not an invented equivalent.
typed_decision_patch '{"prior_review":{"applicable":false,"binding_valid":true,"code_identity":"input-current","evidence_identity":"evidence-current","legacy":false,"marker":"pg-run-acme-widgets-1983-1700000400-1","provenance_valid":true,"verdict":"NONE"}}' "$PROOF_DECISION"
check 'sanity: the real-shape decision is stop-without-new-review/identical-code-and-evidence' "$([ "$(jq -r .action "$PROOF_DECISION")" = stop-without-new-review ] && [ "$(jq -r .reason "$PROOF_DECISION")" = identical-code-and-evidence ]; echo $?)" "action=$(jq -r .action "$PROOF_DECISION") reason=$(jq -r .reason "$PROOF_DECISION")"
check 'the completion-proof helper accepts the producer real applicable:false identical-code-and-evidence shape' "$(daemon_stop_is_completion_proof "$PROOF_DECISION"; echo $?)"
check 'the completion-proof helper rejects the round-governor-denied stop (non-completion reason)' "$(! daemon_stop_is_completion_proof "$STOP_DECISION"; echo $?)"
MOCK_FRESH="$PROOF_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'a stop WITH positive current-head review proof (real applicable:false shape) completes the head' "$([ "$rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$rc"

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
# invented format), whose round_key matches the PR's slug, and whose .marker names a real,
# structurally-complete (pg_is_review-passing) artifact in $(pg_completed_dir) -- the same
# write-once store oracle-review.sh itself writes into (pg_completed_write, v0.28 #56).
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

LEDGER_LINE="$(jq -nc --arg ts "2026-01-01T00:00:00+0000" --arg pr "$EVIDENT_NUM" --arg repo "/repos/widgets" \
  --argjson exit 0 --arg outcome clean --argjson secs 120 --argjson pre_slot_secs 0 --argjson post_slot_secs 0 \
  --arg kind pr --argjson attempts 1 --argjson conc 1 --argjson ceiling 1 --argjson live 0 --argjson salvaged 0 \
  --argjson diff_lines 10 --arg out "$COMPLETED_DIR/$EVIDENT_MARKER" --arg model test \
  --arg marker "$EVIDENT_MARKER" --arg round_key "${EVIDENT_NWO//\//-}-${EVIDENT_NUM}" --arg sha256 deadbeef \
  --arg reason "" --arg detail "" \
  '{ts:$ts,pr:$pr,repo:$repo,exit:$exit,outcome:$outcome,secs:$secs,pre_slot_secs:$pre_slot_secs,post_slot_secs:$post_slot_secs,kind:$kind,attempts:$attempts,conc:$conc,ceiling:$ceiling,live:$live,salvaged:$salvaged,diff_lines:$diff_lines,out:$out,model:$model,marker:$marker,round_key:$round_key,sha256:$sha256,reason:$reason,detail:$detail}')"
pg_ledger_append "$LEDGER_LINE"

daemon_migrate_legacy_processed

check 'a legacy row WITH durable completed-artifact evidence is carried forward into the new ledger' "$(already_done "$EVIDENT_NWO" "$EVIDENT_NUM" "$EVIDENT_SHA"; echo $?)" "$(cat "$STATE_FILE")"
check 'a legacy row lacking durable evidence is quarantined, not carried forward' "$(! already_done "$UNEVIDENT_NWO" "$UNEVIDENT_NUM" "$UNEVIDENT_SHA" && grep -qF "$(printf '%s\t%s\t%s' "$UNEVIDENT_NWO" "$UNEVIDENT_NUM" "$UNEVIDENT_SHA")" "$QUARANTINE_FILE"; echo $?)" "$(cat "$QUARANTINE_FILE")"
check 'the legacy file itself is never deleted or truncated by migration' "$([ -s "$LEGACY_FILE" ] && [ "$(wc -l < "$LEGACY_FILE")" -eq 2 ]; echo $?)" "$(cat "$LEGACY_FILE")"
check 'a quarantined head is genuinely re-evaluated on the next poll, not permanently skipped (already_done is false, so the main loops already_done-continue gate does not suppress it)' "$(! already_done "$UNEVIDENT_NWO" "$UNEVIDENT_NUM" "$UNEVIDENT_SHA"; echo $?)"

STATE_AFTER_FIRST="$(cat "$STATE_FILE")"; QUARANTINE_AFTER_FIRST="$(cat "$QUARANTINE_FILE")"
daemon_migrate_legacy_processed
check 'migration run a second time is idempotent: processed-v2.tsv unchanged' "$([ "$(cat "$STATE_FILE")" = "$STATE_AFTER_FIRST" ]; echo $?)" "before=[$STATE_AFTER_FIRST] after=[$(cat "$STATE_FILE")]"
check 'migration run a second time is idempotent: quarantine unchanged (no duplicate row)' "$([ "$(cat "$QUARANTINE_FILE")" = "$QUARANTINE_AFTER_FIRST" ]; echo $?)" "before=[$QUARANTINE_AFTER_FIRST] after=[$(cat "$QUARANTINE_FILE")]"

[ "$TEST_FAILURES" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$TEST_FAILURES FAILURES"; exit 1; }
