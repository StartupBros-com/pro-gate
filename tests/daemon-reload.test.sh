#!/usr/bin/env bash
# Tests for the daemon self-reload: pick up a redeploy at the idle top of the poll loop by
# re-execing in place, instead of a control-group-killing `systemctl restart`. The trigger is an
# atomic deploy stamp ($PRO_GATE_HOME/.deploy-stamp) that install.sh writes LAST, after every
# runtime file has landed (so the daemon never re-execs onto a half-deployed file set).
#   - pg_file_sig: stable + change-sensitive content signature (the stamp content)
#   - install.sh writes .deploy-stamp last, = sig of the deployed daemon code
#   - integration: a running daemon re-execs itself when the stamp changes, keeps its PID (proving
#     exec, not a fresh spawn), reloads exactly once, and stays put when self-reload is disabled
# No ChatGPT/gh/network: gh is stubbed, sudo is a no-op, browser mode is forced native.
# Run: bash tests/daemon-reload.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/pro-gate-lib.sh"
FAILS=0
check() { if [ "$2" = 0 ]; then echo "ok - $1"; else echo "FAIL - $1: ${3:-}"; FAILS=$((FAILS + 1)); fi; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-daemon-test.XXXXXX")"
DPID=""
cleanup() {
  [ -n "$DPID" ] && { kill "$DPID" 2>/dev/null; pkill -P "$DPID" 2>/dev/null; }
  pkill -f "$TDIR/daemon.sh" 2>/dev/null
  rm -rf "$TDIR"
}
trap cleanup EXIT

echo '# pg_file_sig: stable + change-sensitive'
mkdir -p "$TDIR/sig"
printf 'alpha\n' > "$TDIR/sig/a"; printf 'beta\n' > "$TDIR/sig/b"
S1="$(bash -c ". '$LIB'; pg_file_sig '$TDIR/sig/a' '$TDIR/sig/b'")"
S2="$(bash -c ". '$LIB'; pg_file_sig '$TDIR/sig/a' '$TDIR/sig/b'")"
check 'sig is non-empty' "$([ -n "$S1" ]; echo $?)" "s1=$S1"
check 'sig is stable across calls' "$([ "$S1" = "$S2" ]; echo $?)" "s1=$S1 s2=$S2"
printf 'beta-CHANGED\n' > "$TDIR/sig/b"
S3="$(bash -c ". '$LIB'; pg_file_sig '$TDIR/sig/a' '$TDIR/sig/b'")"
check 'sig changes when a file changes' "$([ "$S1" != "$S3" ]; echo $?)" "s1=$S1 s3=$S3"
rm -f "$TDIR/sig/b"
S4="$(bash -c ". '$LIB'; pg_file_sig '$TDIR/sig/a' '$TDIR/sig/b'")"
check 'sig changes when a file disappears' "$([ "$S3" != "$S4" ]; echo $?)" "s3=$S3 s4=$S4"

echo '# install.sh writes an atomic deploy stamp (= sig of the deployed daemon code) as its last deploy step'
SBI="$TDIR/inst"; mkdir -p "$SBI/shim" "$SBI/claude" "$SBI/home" "$SBI/oracle"
printf '#!/bin/sh\n[ "$1" = tee ] && cat >/dev/null\nexit 0\n' > "$SBI/shim/sudo"; chmod +x "$SBI/shim/sudo"   # neutralize systemd steps
INSTALL_DAEMON=0 CLAUDE_DIR="$SBI/claude" PRO_GATE_HOME="$SBI/home" ORACLE_DIR="$SBI/oracle" \
  PATH="$SBI/shim:$PATH" bash "$HERE/../install.sh" --local-source > "$SBI/install.log" 2>&1 || true
check 'install wrote .deploy-stamp' "$([ -s "$SBI/home/.deploy-stamp" ]; echo $?)" "$(ls -1 "$SBI/home" 2>/dev/null | tr '\n' ' ')"
EXP="$(bash -c ". '$LIB'; pg_file_sig '$SBI/home/daemon.sh' '$SBI/home/lib.sh' '$SBI/home/run-daemon.sh'")"
GOT="$(cat "$SBI/home/.deploy-stamp" 2>/dev/null || true)"
check 'stamp == sig of deployed daemon code' "$([ -n "$GOT" ] && [ "$GOT" = "$EXP" ]; echo $?)" "got=$GOT exp=$EXP"
check 'no leftover .deploy-stamp.tmp (atomic rename)' "$([ ! -e "$SBI/home/.deploy-stamp.tmp" ]; echo $?)" 'tmp left behind'
check 'installer does not copy plugin-owned skill' "$([ ! -e "$SBI/claude/skills/pro-gate/SKILL.md" ]; echo $?)" 'duplicate skill installed'
check 'installer does not copy plugin-owned agent' "$([ ! -e "$SBI/claude/agents/oracle-reviewer.md" ]; echo $?)" 'duplicate agent installed'

echo '# U4: daemon consumes all typed actions without legacy policy inference'
TYPED_HOME="$TDIR/typed-runtime"; mkdir -p "$TYPED_HOME"
unset PRO_REVIEW_INPUT
export PRO_GATE_HOME="$TYPED_HOME" PRO_GATE_DAEMON_LIB_ONLY=1
. "$HERE/../daemon/daemon.sh"
unset PRO_GATE_DAEMON_LIB_ONLY
check 'daemon defaults PRO_REVIEW_INPUT to both' "$([ "$DD_INPUT" = both ]; echo $?)" "input=$DD_INPUT"
PRO_GATE_HOME="$TYPED_HOME" PRO_REVIEW_INPUT=invalid bash "$HERE/../daemon/daemon.sh" >"$TYPED_HOME/invalid-input.log" 2>&1; input_rc=$?
check 'invalid PRO_REVIEW_INPUT fails closed at startup' "$([ "$input_rc" -ne 0 ] && grep -Fq 'must be one of: both, bundle, connector' "$TYPED_HOME/invalid-input.log"; echo $?)" "rc=$input_rc"
TYPED_STATE="$TYPED_HOME/processed.tsv"; TYPED_FAILS="$TYPED_HOME/failcount.tsv"; : > "$TYPED_STATE"; : > "$TYPED_FAILS"
TYPED_LOG="$TYPED_HOME/typed.log"; : > "$TYPED_LOG"
log(){ printf '%s\n' "$*" >> "$TYPED_LOG"; }
TYPED_ENGINE="$TYPED_HOME/oracle-review.sh"; TYPED_ENGINE_CALLS="$TYPED_HOME/engine-calls.log"; : > "$TYPED_ENGINE_CALLS"; export MOCK_ENGINE_CALLS="$TYPED_ENGINE_CALLS"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$MOCK_ENGINE_CALLS"\ncase " $* " in\n  *" --review-decision-effect "*|*" --review-decision "*) cat "$MOCK_FRESH";;\n  *" --recover "*) printf "recover\\n" >> "$MOCK_RECOVERED";;\nesac\n' > "$TYPED_ENGINE"
chmod +x "$TYPED_ENGINE"
typed_decision(){ # corpus-case index output
  local index="$1" out="$2" facts patch
  patch="$(jq -c ".cases[$index].patch" "$HERE/fixtures/review-decision/v1/corpus.json")"
  facts="$(jq -cS --arg cd "$(pg_review_decision_contract_digest)" --arg xd "$(pg_review_decision_corpus_digest)" --argjson patch "$patch" '.base_facts * $patch | .contract={contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd}' "$HERE/fixtures/review-decision/v1/corpus.json")"
  pg_review_decision_reduce "$facts" > "$out"
}

# Prompt contracts carry only validated handles; they do not interpolate decision JSON or bypass the
# full fixer lifecycle after the first exact guarded runtime effect.
TYPED_BIN="$TYPED_HOME/bin"; mkdir -p "$TYPED_BIN"
printf '#!/usr/bin/env bash\nprintf "%%s" "$2" > "$MOCK_PROMPT"\n' > "$TYPED_BIN/claude"; chmod +x "$TYPED_BIN/claude"
PATH="$TYPED_BIN:$PATH"; CLAUDE_MODEL=test FALLBACK_MODEL=test MAX_BUDGET=1
RUN_DECISION="$TYPED_HOME/run-decision.json"; typed_decision 2 "$RUN_DECISION"
RUN_PROMPT="$TYPED_HOME/run.prompt"
printf -v EXPECTED_EFFECT '%q ' "$TYPED_ENGINE" --review-decision --review-decision-effect "$RUN_DECISION" --pr 1983 --repo "$TYPED_HOME" --input both --out "$TYPED_LOG.review" --timeout "${PRO_REVIEW_ENGINE_TIMEOUT:-30m}"
MOCK_PROMPT="$RUN_PROMPT" DD_ENGINE="$TYPED_ENGINE" DD_INPUT=both DD_NWO=acme/widgets DD_NUM=1983 DD_SHA=1111111111111111111111111111111111111111 DD_WORKTREE="$TYPED_HOME" DD_LOG="$TYPED_LOG" daemon_run_review_worker "$RUN_DECISION"; worker_rc=$?
check 'run worker prompt starts with the exact argv-quoted saved guarded effect' "$(grep -Fqx 'First action: execute this exact argv-quoted guarded runtime effect; it rechecks the saved review-decision/v1 before any charge or submission:' "$RUN_PROMPT" && grep -Fq "$EXPECTED_EFFECT" "$RUN_PROMPT"; echo $?)" "rc=$worker_rc"
check 'run worker prompt restores fix/test/commit/push/comment lifecycle and no-merge guard' "$(grep -Fq '/pro-gate skill' "$RUN_PROMPT" && grep -Fq 'sanity-check every P0/P1' "$RUN_PROMPT" && grep -Fq 'tests and lint' "$RUN_PROMPT" && grep -Fq 'commit the fixes' "$RUN_PROMPT" && grep -Fq 'push this branch to origin' "$RUN_PROMPT" && grep -Fq 'exactly one audit PR comment' "$RUN_PROMPT" && grep -Fq 'Never merge' "$RUN_PROMPT"; echo $?)"
AGENT_DECISION="$TYPED_HOME/agent-decision.json"; typed_decision 3 "$AGENT_DECISION"
AGENT_PROMPT="$TYPED_HOME/agent.prompt"; raw_marker="$(jq -r '.facts.prior_review.marker' "$AGENT_DECISION")"
MOCK_PROMPT="$AGENT_PROMPT" DD_ENGINE="$TYPED_ENGINE" DD_INPUT=both DD_NWO=acme/widgets DD_NUM=1983 DD_SHA=1111111111111111111111111111111111111111 DD_WORKTREE="$TYPED_HOME" DD_LOG="$TYPED_LOG" daemon_run_agent_task "$AGENT_DECISION" fix-review-findings
check 'agent-task prompt identifies typed action target saved decision and valid query-only re-entry route' "$(grep -Fq 'Control-safe typed action: fix-review-findings.' "$AGENT_PROMPT" && grep -Fq "PR #1983 (acme/widgets), local repository $TYPED_HOME." "$AGENT_PROMPT" && grep -Fq "$AGENT_DECISION" "$AGENT_PROMPT" && grep -Fq -- '--review-decision --json --pr 1983' "$AGENT_PROMPT" && grep -Fq -- '--input both' "$AGENT_PROMPT" && ! grep -F -- '--review-decision --json' "$AGENT_PROMPT" | grep -Fq -- '--out'; echo $?)"
check 'agent-task prompt excludes raw decision-envelope content' "$(! grep -Fq "$raw_marker" "$AGENT_PROMPT"; echo $?)" "marker=$raw_marker"

# A nonzero run worker must re-query with the same input before it can consume the wrapper budget.
FAIL_NOTES=0
note_fail(){ FAIL_NOTES=$((FAIL_NOTES + 1)); }
for fresh_index in 0 1; do
  FRESH_DECISION="$TYPED_HOME/fresh-$fresh_index.json"; typed_decision "$fresh_index" "$FRESH_DECISION"
  FAIL_NOTES=0
  MOCK_ENGINE_CALLS="$TYPED_ENGINE_CALLS" MOCK_FRESH="$FRESH_DECISION" DD_ENGINE="$TYPED_ENGINE" DD_INPUT=both DD_NWO=acme/widgets DD_NUM=1983 DD_SHA=1111111111111111111111111111111111111111 DD_WORKTREE="$TYPED_HOME" DD_LOG="$TYPED_LOG" daemon_handle_review_worker_failure 124; failure_rc=$?
  fresh_action="$(jq -r .action "$FRESH_DECISION")"
  check "nonzero run worker + fresh typed $fresh_action leaves wrapper failure budget untouched" "$([ "$failure_rc" -eq 2 ] && [ "$FAIL_NOTES" -eq 0 ]; echo $?)" "rc=$failure_rc notes=$FAIL_NOTES"
done
NONRECOVERABLE_DECISION="$TYPED_HOME/fresh-run.json"; typed_decision 2 "$NONRECOVERABLE_DECISION"; FAIL_NOTES=0
MOCK_ENGINE_CALLS="$TYPED_ENGINE_CALLS" MOCK_FRESH="$NONRECOVERABLE_DECISION" DD_ENGINE="$TYPED_ENGINE" DD_INPUT=both DD_NWO=acme/widgets DD_NUM=1983 DD_SHA=1111111111111111111111111111111111111111 DD_WORKTREE="$TYPED_HOME" DD_LOG="$TYPED_LOG" daemon_handle_review_worker_failure 124; failure_rc=$?
check 'nonrecoverable fresh typed replacement retains note_fail behavior' "$([ "$failure_rc" -eq 1 ] && [ "$FAIL_NOTES" -eq 1 ]; echo $?)" "rc=$failure_rc notes=$FAIL_NOTES"
check 'default both input is reused by fresh query' "$(grep -F -- '--review-decision --json' "$TYPED_ENGINE_CALLS" | grep -Fq -- '--input both'; echo $?)"

REVIEW_WORKERS=0; AGENT_TASKS=0
daemon_run_review_worker(){ REVIEW_WORKERS=$((REVIEW_WORKERS + 1)); return 0; }
daemon_agent_task_available(){ return 0; }
daemon_run_agent_task(){ AGENT_TASKS=$((AGENT_TASKS + 1)); return 0; }
for index in $(seq 0 7); do
  decision="$TYPED_HOME/decision-$index.json"; typed_decision "$index" "$decision"
  action="$(jq -r .action "$decision")"; expected="$(jq -r ".cases[$index].expected.action" "$HERE/fixtures/review-decision/v1/corpus.json")"
  before_review="$REVIEW_WORKERS"; before_agent="$AGENT_TASKS"; before_state="$(wc -c < "$TYPED_STATE")"; before_fails="$(wc -c < "$TYPED_FAILS")"
  MOCK_FRESH="$decision" MOCK_RECOVERED="$TYPED_HOME/recovered-$index" DD_ENGINE="$TYPED_ENGINE" DD_NWO=acme/widgets DD_NUM=1983 DD_SHA=1111111111111111111111111111111111111111 DD_WORKTREE="$TYPED_HOME" DD_LOG="$TYPED_LOG" daemon_dispatch_decision "$decision"; rc=$?
  check "typed daemon accepts corpus action $expected" "$([ "$rc" -eq 0 ] && [ "$action" = "$expected" ]; echo $?)" "rc=$rc action=$action"
  case "$action" in
    run-granted-review) expected_review=$((before_review + 1)); expected_agent="$before_agent";;
    fix-review-findings|prepare-matching-review-evidence) expected_review="$before_review"; expected_agent=$((before_agent + 1));;
    *) expected_review="$before_review"; expected_agent="$before_agent";;
  esac
  check "$action dispatches only its runtime-provided execution class without a routine prompt" "$([ "$REVIEW_WORKERS" -eq "$expected_review" ] && [ "$AGENT_TASKS" -eq "$expected_agent" ]; echo $?)" "review=$REVIEW_WORKERS agent=$AGENT_TASKS"
  check "$action has zero SHA/failure-budget effects unless it runs a granted review" "$([ "$action" = run-granted-review ] || { [ "$(wc -c < "$TYPED_STATE")" = "$before_state" ] && [ "$(wc -c < "$TYPED_FAILS")" = "$before_fails" ]; }; echo $?)" "processed=$(wc -c < "$TYPED_STATE") failures=$(wc -c < "$TYPED_FAILS")"
done
check 'default both input is reused by guarded effect rechecks' "$(grep -F -- '--review-decision-effect' "$TYPED_ENGINE_CALLS" | grep -Fq -- '--input both'; echo $?)"
# Observation is progress only: it reports, but never changes action selection or prompts.
typed_decision 2 "$TYPED_HOME/observed-base.json"
observed_facts="$(jq -cS '.facts | .observation.kind="waiting"' "$TYPED_HOME/observed-base.json")"
pg_review_decision_reduce "$observed_facts" > "$TYPED_HOME/observed-run.json"
before_review="$REVIEW_WORKERS"
MOCK_FRESH="$TYPED_HOME/observed-run.json" DD_ENGINE="$TYPED_ENGINE" DD_NWO=acme/widgets DD_NUM=1983 DD_SHA=1111111111111111111111111111111111111111 DD_WORKTREE="$TYPED_HOME" DD_LOG="$TYPED_LOG" daemon_dispatch_decision "$TYPED_HOME/observed-run.json"
check 'observation reports progress without changing granted runtime dispatch' "$([ "$REVIEW_WORKERS" -eq $((before_review + 1)) ] && grep -Fq 'review observation: waiting' "$TYPED_LOG"; echo $?)"
# A rechecked stale effect must return and dispatch the replacement, not a guessed retry.
typed_decision 0 "$TYPED_HOME/stale-original.json"; typed_decision 2 "$TYPED_HOME/stale-replacement.json"
before_review="$REVIEW_WORKERS"
MOCK_FRESH="$TYPED_HOME/stale-replacement.json" DD_ENGINE="$TYPED_ENGINE" DD_NWO=acme/widgets DD_NUM=1983 DD_SHA=1111111111111111111111111111111111111111 DD_WORKTREE="$TYPED_HOME" DD_LOG="$TYPED_LOG" daemon_dispatch_decision "$TYPED_HOME/stale-original.json"
check 'stale runtime effect re-dispatches the fresh replacement action' "$([ "$REVIEW_WORKERS" -eq $((before_review + 1)) ]; echo $?)" "review=$REVIEW_WORKERS"
# Malformed, incompatible, unknown, and stale target envelopes globally defer without effects.
for invalid in malformed corpus unknown stale; do
  typed_decision 2 "$TYPED_HOME/invalid-$invalid.json"
  case "$invalid" in
    malformed) printf '{not-json}\n' > "$TYPED_HOME/invalid-$invalid.json" ;;
    corpus) jq '.contract.corpus_digest="bad"' "$TYPED_HOME/invalid-$invalid.json" > "$TYPED_HOME/invalid-$invalid.tmp" && mv "$TYPED_HOME/invalid-$invalid.tmp" "$TYPED_HOME/invalid-$invalid.json" ;;
    unknown) jq '.action="unknown-action" | .effect_request.action="unknown-action" | .effect_request.effect="unknown-action"' "$TYPED_HOME/invalid-$invalid.json" > "$TYPED_HOME/invalid-$invalid.tmp" && mv "$TYPED_HOME/invalid-$invalid.tmp" "$TYPED_HOME/invalid-$invalid.json" ;;
    stale) jq '.effect_request.target.head_oid="2222222222222222222222222222222222222222" | .facts.target.head_oid="2222222222222222222222222222222222222222"' "$TYPED_HOME/invalid-$invalid.json" > "$TYPED_HOME/invalid-$invalid.tmp" && mv "$TYPED_HOME/invalid-$invalid.tmp" "$TYPED_HOME/invalid-$invalid.json" ;;
  esac
  DECISION_DEFERRED=0; RUNTIME_DEFERRED=0; before_review="$REVIEW_WORKERS"; before_agent="$AGENT_TASKS"; before_state="$(wc -c < "$TYPED_STATE")"; before_fails="$(wc -c < "$TYPED_FAILS")"
  MOCK_FRESH="$TYPED_HOME/invalid-$invalid.json" DD_ENGINE="$TYPED_ENGINE" DD_NWO=acme/widgets DD_NUM=1983 DD_SHA=1111111111111111111111111111111111111111 DD_WORKTREE="$TYPED_HOME" DD_LOG="$TYPED_LOG" daemon_dispatch_decision "$TYPED_HOME/invalid-$invalid.json"; rc=$?
  check "$invalid decision globally defers with zero worker/SHA/failure-budget effects" "$([ "$rc" -eq 2 ] && [ "$DECISION_DEFERRED" = 1 ] && [ "$REVIEW_WORKERS" -eq "$before_review" ] && [ "$AGENT_TASKS" -eq "$before_agent" ] && [ "$(wc -c < "$TYPED_STATE")" = "$before_state" ] && [ "$(wc -c < "$TYPED_FAILS")" = "$before_fails" ]; echo $?)" "rc=$rc deferred=$DECISION_DEFERRED"
done
unset PRO_GATE_HOME

echo '# integration: daemon re-execs itself in place when the deploy stamp changes'
cp "$HERE/../daemon/daemon.sh"      "$TDIR/daemon.sh"
cp "$HERE/../lib/pro-gate-lib.sh"   "$TDIR/lib.sh"
cp "$HERE/../daemon/run-daemon.sh"  "$TDIR/run-daemon.sh"
chmod +x "$TDIR/daemon.sh" "$TDIR/run-daemon.sh"
mkdir -p "$TDIR/.local/bin" "$TDIR/logs" "$TDIR/.config/pro-gate"
RUNTIME_VERSION="$(tr -d '[:space:]' < "$HERE/../VERSION")"
printf '%s\n' "$RUNTIME_VERSION" > "$TDIR/VERSION"
printf '%s\n' "$RUNTIME_VERSION" > "$TDIR/EXPECTED_VERSION"
printf '1\n' > "$TDIR/.config/pro-gate/dangerous-mode-consent"
# Stub gh so the daemon finds no PRs and just idles through its poll loop (wins in PATH because
# pg_augment_path prepends $HOME/.local/bin first, and HOME is pinned to $TDIR below).
printf '#!/bin/sh\nexit 0\n' > "$TDIR/.local/bin/gh"; chmod +x "$TDIR/.local/bin/gh"

DLOG="$TDIR/daemon.log"
HOME="$TDIR" PRO_GATE_HOME="$TDIR" PRO_REVIEW_OWNERS=fakeowner PRO_REVIEW_POLL_SECONDS=1 \
  PRO_GATE_BROWSER_MODE=native PRO_GATE_DAEMON_SELF_RELOAD=1 PATH="/usr/bin:/bin" \
  bash "$TDIR/run-daemon.sh" > "$DLOG" 2>&1 &
DPID=$!

for _ in $(seq 1 50); do grep -q 'pro-review-daemon starting' "$DLOG" 2>/dev/null && break; sleep 0.2; done
check 'daemon started' "$(grep -q 'pro-review-daemon starting' "$DLOG"; echo $?)" "$(tail -3 "$DLOG" 2>/dev/null)"
check 'daemon process alive before reload' "$(kill -0 "$DPID" 2>/dev/null; echo $?)" "pid=$DPID"

# Simulate install.sh finishing a deploy: write the stamp atomically (this is the ONLY trigger now,
# so merely editing daemon.sh on disk would NOT reload -- the stamp is the deploy-complete signal).
printf 'deploy-v2-%s\n' "$(date +%s)" > "$TDIR/.deploy-stamp.tmp" && mv -f "$TDIR/.deploy-stamp.tmp" "$TDIR/.deploy-stamp"

for _ in $(seq 1 60); do grep -q 'detected a new daemon deploy' "$DLOG" 2>/dev/null && break; sleep 0.2; done
check 'daemon detected the new deploy stamp' "$(grep -q 'detected a new daemon deploy' "$DLOG"; echo $?)" "$(tail -5 "$DLOG" 2>/dev/null)"
for _ in $(seq 1 40); do [ "$(grep -c 'pro-review-daemon starting' "$DLOG" 2>/dev/null)" -ge 2 ] && break; sleep 0.2; done
check 'daemon re-started after reload (2 startup lines)' "$([ "$(grep -c 'pro-review-daemon starting' "$DLOG")" -ge 2 ]; echo $?)" "starts=$(grep -c 'pro-review-daemon starting' "$DLOG")"
check 'PID unchanged across reload (exec, not a fresh spawn)' "$(kill -0 "$DPID" 2>/dev/null; echo $?)" "pid=$DPID"

# No reload-loop: several more polls, and re-writing the SAME stamp content, must not reload again.
sleep 2
cp "$TDIR/.deploy-stamp" "$TDIR/.deploy-stamp.tmp" && mv -f "$TDIR/.deploy-stamp.tmp" "$TDIR/.deploy-stamp"
sleep 2
check 'reloaded exactly once (no reload-loop; identical stamp is inert)' "$([ "$(grep -c 'detected a new daemon deploy' "$DLOG")" -eq 1 ]; echo $?)" "reloads=$(grep -c 'detected a new daemon deploy' "$DLOG")"
check 'started exactly twice (no reload-loop)' "$([ "$(grep -c 'pro-review-daemon starting' "$DLOG")" -eq 2 ]; echo $?)" "starts=$(grep -c 'pro-review-daemon starting' "$DLOG")"

echo '# integration: self-reload disabled -> no re-exec on a new stamp'
kill "$DPID" 2>/dev/null; pkill -P "$DPID" 2>/dev/null; DPID=""
sleep 0.5
rm -f "$TDIR/.deploy-stamp"
DLOG2="$TDIR/daemon2.log"
HOME="$TDIR" PRO_GATE_HOME="$TDIR" PRO_REVIEW_OWNERS=fakeowner PRO_REVIEW_POLL_SECONDS=1 \
  PRO_GATE_BROWSER_MODE=native PRO_GATE_DAEMON_SELF_RELOAD=0 PATH="/usr/bin:/bin" \
  bash "$TDIR/run-daemon.sh" > "$DLOG2" 2>&1 &
DPID=$!
for _ in $(seq 1 50); do grep -q 'pro-review-daemon starting' "$DLOG2" 2>/dev/null && break; sleep 0.2; done
printf 'deploy-v3-%s\n' "$(date +%s)" > "$TDIR/.deploy-stamp.tmp" && mv -f "$TDIR/.deploy-stamp.tmp" "$TDIR/.deploy-stamp"
sleep 3
check 'self-reload=0 does not detect/reload' "$([ "$(grep -c 'detected a new daemon deploy' "$DLOG2")" -eq 0 ]; echo $?)" "reloads=$(grep -c 'detected a new daemon deploy' "$DLOG2")"
check 'self-reload=0 keeps a single startup line' "$([ "$(grep -c 'pro-review-daemon starting' "$DLOG2")" -eq 1 ]; echo $?)" "starts=$(grep -c 'pro-review-daemon starting' "$DLOG2")"

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILURES"; exit 1; }
