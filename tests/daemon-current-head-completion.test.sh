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

STATE_FILE="$HOME_D/processed.tsv"; FAILS_FILE="$HOME_D/failcount.tsv"
CIDEFER_FILE="$HOME_D/ci-defer.tsv"; AGENTCAP_FILE="$HOME_D/agent-task-attempts.tsv"
LOG_FILE="$HOME_D/t.log"; : > "$LOG_FILE"
log(){ printf '%s\n' "$*" >> "$LOG_FILE"; }

check 'daemon.sh created the bounded #184 ledger files at startup' "$([ -f "$CIDEFER_FILE" ] && [ -f "$AGENTCAP_FILE" ]; echo $?)" "$(ls "$HOME_D")"

reset_state(){ : > "$STATE_FILE"; : > "$FAILS_FILE"; : > "$CIDEFER_FILE"; : > "$AGENTCAP_FILE"; : > "$LOG_FILE"; }

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

echo '# the deferral cap eventually proceeds'
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
check 'the cap-th attempt proceeds once, with a logged notice' "$([ "$cap_rc" -eq 0 ] && grep -Fq 'proceeding once (deferral cap reached)' "$LOG_FILE"; echo $?)" "rc=$cap_rc"

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

reset_state
daemon_run_review_worker(){ return 0; }   # completed review; the worker may also have pushed a fix
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

echo '# the agent-task attempt cap terminates a no-progress loop with a logged notice'
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
check 'the cap-th agent-task dispatch gives up: marks done with a logged notice' "$([ "$rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA" && grep -Fq 'no head progress' "$LOG_FILE"; echo $?)" "$(tail -1 "$LOG_FILE")"
check "the agent task actually ran $AGENT_TASK_MAX times (each dispatch is real, not skipped)" "$([ "$AGENT_RUNS" -eq "$AGENT_TASK_MAX" ]; echo $?)" "runs=$AGENT_RUNS"
check 'a real push (new sha) starts the attempt counter fresh, not a stuck loop' "$([ "$(agent_task_attempt_count "$NWO" "$NUM" "$PUSHED_SHA")" -eq 1 ]; echo $?)"

echo '# a completed current-head review does complete it'
reset_state
daemon_run_review_worker(){ return 0; }
RUN_DECISION="$HOME_D/run2.json"; typed_decision "$(decision_for_action run-granted-review)" "$RUN_DECISION"
MOCK_FRESH="$RUN_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'run-granted-review completion marks the current head' "$([ "$rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$rc"

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
typed_decision_patch '{"prior_review":{"applicable":true,"binding_valid":true,"code_identity":"input-current","evidence_identity":"evidence-current","legacy":false,"marker":"pg-run-test-identical","provenance_valid":true,"verdict":"NONE"}}' "$PROOF_DECISION"
check 'sanity: the synthetic decision is stop-without-new-review/identical-code-and-evidence' "$([ "$(jq -r .action "$PROOF_DECISION")" = stop-without-new-review ] && [ "$(jq -r .reason "$PROOF_DECISION")" = identical-code-and-evidence ]; echo $?)" "action=$(jq -r .action "$PROOF_DECISION") reason=$(jq -r .reason "$PROOF_DECISION")"
MOCK_FRESH="$PROOF_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
check 'a stop WITH positive current-head review proof completes the head' "$([ "$rc" -eq 0 ] && already_done "$NWO" "$NUM" "$SHA"; echo $?)" "rc=$rc"

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

echo '# finding 3: only a SUCCESSFUL (rc=0) agent task counts toward the no-progress cap'

reset_state
daemon_run_agent_task(){ return 1; }   # agent task ended without completion
below_cap_ok=1
i=1
while [ "$i" -le "$((AGENT_TASK_MAX * 2))" ]; do
  MOCK_FRESH="$AGENT_DECISION" process_pr "$NWO" "$NUM" "$SHA" "$BRANCH" "$URL"; rc=$?
  { [ "$rc" -eq 1 ] && ! already_done "$NWO" "$NUM" "$SHA"; } || below_cap_ok=0
  i=$((i + 1))
done
check "a failing agent task (rc=1), dispatched well past the cap ($((AGENT_TASK_MAX * 2))x), never completes the head" "$([ "$below_cap_ok" -eq 1 ]; echo $?)"
check 'a failing agent task never advances the no-progress attempt cap' "$([ ! -s "$AGENTCAP_FILE" ]; echo $?)" "$(cat "$AGENTCAP_FILE")"
check 'a failing agent task never writes processed.tsv' "$([ ! -s "$STATE_FILE" ]; echo $?)" "$(cat "$STATE_FILE")"

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

[ "$TEST_FAILURES" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$TEST_FAILURES FAILURES"; exit 1; }
