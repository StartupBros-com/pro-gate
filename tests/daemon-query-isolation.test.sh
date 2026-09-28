#!/usr/bin/env bash
# A per-PR query failure must not latch poll admission for unrelated or recovered PRs.
# Real process_pr, dispatch, runtime_gate and validators; isolated external process doubles.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-daemon-query-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT
export TMPDIR="$TDIR" PRO_GATE_REPOS_DIR="$TDIR/repos" PRO_GATE_HOME="$TDIR/runtime" PRO_GATE_CONSENT_HOME="$TDIR/consent"
export PRO_GATE_PLUGIN_SEARCH_DIR="$TDIR/plugins"
export PRO_GATE_DAEMON_LIB_ONLY=1 PRO_GATE_BROWSER_MODE=native
unset PRO_REVIEW_INPUT GH_HOST PRO_GATE_EXPECTED_VERSION PRO_GATE_CONSENT_VERSION
mkdir -p "$PRO_GATE_REPOS_DIR" "$PRO_GATE_HOME" "$PRO_GATE_CONSENT_HOME"
cp "$HERE/../lib/pro-gate-lib.sh" "$PRO_GATE_HOME/lib.sh"
cp "$HERE/../VERSION" "$PRO_GATE_HOME/VERSION"
cp "$HERE/../VERSION" "$PRO_GATE_HOME/EXPECTED_VERSION"
cp "$HERE/../skills/pro-gate/review-decision-v1.json" "$PRO_GATE_HOME/review-decision-v1.json"
printf '1\n' > "$PRO_GATE_CONSENT_HOME/dangerous-mode-consent"
# The override supports red-before-green execution against an extracted baseline daemon.
. "${PRO_GATE_TEST_DAEMON_SOURCE:-$HERE/../daemon/daemon.sh}"
unset PRO_GATE_DAEMON_LIB_ONLY
FAILURES=0
check(){
  if [ "$2" -eq 0 ]; then printf 'ok - %s\n' "$1";
  else printf 'not ok - %s (%s)\n' "$1" "${3:-}"; FAILURES=$((FAILURES + 1)); fi
}
log(){ printf '%s\n' "$*" >> "$TDIR/daemon.log"; }
SHA=1111111111111111111111111111111111111111
BASE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEXT_BASE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$TDIR/repo"
find_repo(){ printf '%s\n' "$TDIR/repo"; }
ci_ready(){ return 0; }
git(){
  if [ "${1:-}" = -C ] && [ "${3:-}" = worktree ] && [ "${4:-}" = add ]; then mkdir -p "$6"; fi
  return 0
}
# A changing base is supplied by the poll and reaches evidence preparation on each retry.
daemon_prepare_review_evidence(){ printf '%s\t%s\n' "$2" "$4" >> "$TDIR/evidence-bases"; return 0; }
export FIXTURES="$TDIR/fixtures" ENGINE_CALLS="$TDIR/engine-calls" WORKER_CALLS="$TDIR/workers"
mkdir -p "$FIXTURES"
cat > "$PRO_GATE_HOME/oracle-review.sh" <<'ENGINE'
#!/usr/bin/env bash
pr=''; effect=0
while [ "$#" -gt 0 ]; do
  case "$1" in --pr) pr="$2"; shift;; --review-decision-effect) effect=1; shift;; esac
  shift
done
printf '%s\t%s\n' "$pr" "$effect" >> "$ENGINE_CALLS"
if [ "$effect" = 1 ]; then prefix=effect
elif [ -s "$WORKER_CALLS" ] && [ "$pr" = 1983 ]; then prefix=after
else prefix="$pr"; fi
cat "$FIXTURES/$prefix.json"
exit "$(cat "$FIXTURES/$prefix.rc")"
ENGINE
chmod +x "$PRO_GATE_HOME/oracle-review.sh"
daemon_run_review_worker(){ printf '%s\n' "$DD_NUM" >> "$WORKER_CALLS"; return "${WORKER_RC:-0}"; }
daemon_run_agent_task(){ printf 'unexpected agent\n' >> "$WORKER_CALLS"; return 1; }
typed(){ # patch output
  local facts
  facts="$(jq -cS --argjson patch "$1" --argjson identity "$(pg_review_decision_identity_json)" \
    '.base_facts * $patch | .contract=$identity' "$HERE/fixtures/review-decision/v1/corpus.json")"
  pg_review_decision_reduce "$facts" > "$2"
}
typed '{}' "$TDIR/run.json"
typed '{"governor":{"granted":false}}' "$TDIR/stop-a.json"
typed '{"target":{"pr":1984},"governor":{"granted":false}}' "$TDIR/stop-b.json"
typed '{"target":{"head_oid":"2222222222222222222222222222222222222222"}}' "$TDIR/moved-head.json"
typed '{"target":{"pr":1984}}' "$TDIR/wrong-pr.json"
typed '{"target":{"host":"enterprise.example"}}' "$TDIR/wrong-host.json"
typed '{"active_index":{"binding_valid":true,"charged_spend_epoch":1700000002,"marker":"pg-run-acme-widgets-1983-1700000002-2","state":"charged"}}' "$TDIR/recover.json"
printf '{bad json}\n' > "$TDIR/malformed.json"
printf 'ERROR: incompatible runtime; please reinstall\n' > "$TDIR/prose.json"
: > "$TDIR/empty.json"
jq '.contract.corpus_digest="bad"' "$TDIR/run.json" > "$TDIR/malformed-identity.json"
jq '.action="unknown-action"' "$TDIR/run.json" > "$TDIR/unknown-action.json"
jq '.contract.corpus_digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$TDIR/run.json" > "$TDIR/incompatible.json"
cat "$TDIR/run.json" "$TDIR/incompatible.json" > "$TDIR/multiple-values.json"
reset_case(){
  DECISION_DEFERRED=0; RUNTIME_DEFERRED=0; WORKER_RC=0
  : > "$STATE"; : > "$FAILS"; : > "$BLOCKED"; : > "$REVIEWNOPROG"
  : > "$WORKER_CALLS"; : > "$ENGINE_CALLS"; : > "$TDIR/evidence-bases"
  cp "$TDIR/stop-a.json" "$FIXTURES/1983.json"
  cp "$TDIR/stop-b.json" "$FIXTURES/1984.json"
  cp "$TDIR/stop-a.json" "$FIXTURES/after.json"
  cp "$TDIR/stop-a.json" "$FIXTURES/effect.json"
  printf '0\n' > "$FIXTURES/1983.rc"; printf '0\n' > "$FIXTURES/1984.rc"
  printf '0\n' > "$FIXTURES/after.rc"; printf '0\n' > "$FIXTURES/effect.rc"
}
poll_pr(){ # use the production poll-admission gate, then the actual PR path
  runtime_gate || return 2
  process_pr acme/widgets "$1" "$SHA" branch "https://github.com/acme/widgets/pull/$1" "${2:-$BASE}" main
}
no_effects(){ [ ! -s "$WORKER_CALLS" ] && [ ! -s "$STATE" ] && [ ! -s "$FAILS" ] && [ ! -s "$BLOCKED" ] && [ ! -s "$REVIEWNOPROG" ]; }

check 'fixture admits the real privileged runtime gate' "$(runtime_gate; echo $?)"
for scenario in moved-head wrong-pr wrong-host; do
  check "$scenario is a valid typed envelope before target rejection" "$(daemon_decision_valid "$TDIR/$scenario.json"; echo $?)"
done
for scenario in empty prose malformed malformed-identity unknown-action multiple-values moved-head wrong-pr wrong-host moved-base; do
  reset_case
  if [ "$scenario" = moved-base ]; then
    cp "$TDIR/empty.json" "$FIXTURES/1983.json"; printf '2\n' > "$FIXTURES/1983.rc"
  else
    cp "$TDIR/$scenario.json" "$FIXTURES/1983.json"
    case "$scenario" in empty|prose) printf '2\n' > "$FIXTURES/1983.rc";; esac
  fi
  poll_pr 1983; rc=$?
  check "$scenario rejects A without worker/spend or completion/failure ledgers" "$([ "$rc" -eq 2 ] && no_effects; echo $?)" "rc=$rc"
  check "$scenario leaves global poll admission open" "$([ "$DECISION_DEFERRED" -eq 0 ] && runtime_gate; echo $?)" "deferred=$DECISION_DEFERRED"
  poll_pr 1984; rc=$?
  check "$scenario permits B in the same poll" "$([ "$rc" -eq 0 ] && grep -q '^1984' "$ENGINE_CALLS" && no_effects; echo $?)" "rc=$rc"
  cp "$TDIR/stop-a.json" "$FIXTURES/1983.json"; printf '0\n' > "$FIXTURES/1983.rc"
  poll_pr 1983 "$NEXT_BASE"; rc=$?
  check "$scenario lets A recover next poll without a deploy" "$([ "$rc" -eq 0 ] && [ "$(grep -c '^1983' "$ENGINE_CALLS")" -eq 2 ] && grep -q "$NEXT_BASE" "$TDIR/evidence-bases" && no_effects; echo $?)" "rc=$rc"
done

# Initial, effect replacement, and both post-worker outcomes use the same classification.
for stage in initial effect failed-worker successful-worker; do
  for scenario in empty malformed moved-head incompatible; do
    reset_case
    case "$stage" in
      initial) destination=1983 ;;
      effect) cp "$TDIR/recover.json" "$FIXTURES/1983.json"; destination=effect ;;
      failed-worker) cp "$TDIR/run.json" "$FIXTURES/1983.json"; WORKER_RC=1; destination=after ;;
      successful-worker) cp "$TDIR/run.json" "$FIXTURES/1983.json"; destination=after ;;
    esac
    cp "$TDIR/$scenario.json" "$FIXTURES/$destination.json"
    [ "$scenario" != empty ] || printf '2\n' > "$FIXTURES/$destination.rc"
    poll_pr 1983; rc=$?
    expected=0; [ "$scenario" != incompatible ] || expected=1
    check "$stage/$scenario rejects without completion or failure charges at the correct scope" \
      "$([ "$rc" -eq 2 ] && [ "$DECISION_DEFERRED" -eq "$expected" ] && [ ! -s "$STATE" ] && [ ! -s "$FAILS" ] && [ ! -s "$REVIEWNOPROG" ]; echo $?)" "rc=$rc deferred=$DECISION_DEFERRED"
    if [ "$expected" -eq 1 ]; then
      before="$(wc -l < "$ENGINE_CALLS")"
      poll_pr 1984; rc=$?
      check "$stage genuine incompatibility blocks B before querying or dispatch" "$([ "$rc" -eq 2 ] && [ "$(wc -l < "$ENGINE_CALLS")" -eq "$before" ]; echo $?)"
      cp "$TDIR/stop-a.json" "$FIXTURES/1983.json"
      check "$stage healthy installed identity cannot clear a positive incompatibility latch" "$(runtime_gate; test "$?" -ne 0; echo $?)"
    else
      poll_pr 1984; rc=$?
      check "$stage/$scenario preserves B admission" "$([ "$rc" -eq 0 ] && grep -q '^1984' "$ENGINE_CALLS"; echo $?)" "rc=$rc"
    fi
  done
done

reset_case
printf 'different-version\n' > "$PRO_GATE_HOME/EXPECTED_VERSION"
poll_pr 1983; rc=$?
check 'positive installed runtime mismatch still stops poll admission before any PR query' \
  "$([ "$rc" -eq 2 ] && [ "$RUNTIME_DEFERRED" -eq 1 ] && [ ! -s "$ENGINE_CALLS" ] && no_effects; echo $?)"
cp "$HERE/../VERSION" "$PRO_GATE_HOME/EXPECTED_VERSION"
poll_pr 1983; rc=$?
check 'existing readiness recovery works without clearing a decision incompatibility latch' "$([ "$rc" -eq 0 ] && [ "$RUNTIME_DEFERRED" -eq 0 ]; echo $?)"
printf '%s failures\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
