#!/usr/bin/env bash
# Exercise the shared round scorer, guard, facts, reducer, and fresh effect boundary.
# Overrides are set only inside isolated fixture subshells, never in the calling session.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-round-continue-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT
. "$HERE/../lib/pro-gate-lib.sh"
FAILURES=0
check(){
  if [ "$2" -eq 0 ]; then printf 'ok - %s\n' "$1";
  else printf 'not ok - %s: %s\n' "$1" "${3:-}"; FAILURES=$((FAILURES + 1)); fi
}
extract_function(){ # exact top-level function; no execution of the engine startup
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" { printing=1 } printing { print } printing && /^}/ { exit }' "$2"
}
# Overlay only the two repaired functions for baseline red evidence. All schema/reducer facts
# remain from the current library so later additive delivery-contract changes cannot fake red.
if [ -n "${PRO_GATE_TEST_ROUND_BASELINE:-}" ]; then
  extract_function pg_round_score "$PRO_GATE_TEST_ROUND_BASELINE" > "$TDIR/baseline-rounds.sh"
  extract_function pg_round_guard "$PRO_GATE_TEST_ROUND_BASELINE" >> "$TDIR/baseline-rounds.sh"
  . "$TDIR/baseline-rounds.sh"
fi
extract_function pg_fresh_dispatch_recheck "$HERE/../bin/oracle-review.sh" > "$TDIR/effect-functions.sh"
extract_function pg_fresh_dispatch_require_run "$HERE/../bin/oracle-review.sh" >> "$TDIR/effect-functions.sh"
. "$TDIR/effect-functions.sh"

clear_policy(){
  unset PRO_GATE_ROUND_GUARD PRO_GATE_ROUNDS_BASE PRO_GATE_ROUNDS_CEILING PRO_GATE_MAX_ROUNDS_PER_PR
  unset PRO_GATE_ROUNDS_CONTINUE PRO_GATE_FORCE_ROUND PRO_GATE_ROUNDS_DIR PRO_GATE_ROUNDS_WINDOW
  unset PRO_GATE_ACTIVE_DIR PRO_GATE_RUN_META_DIR PRO_GATE_RESERVATION_DIR PRO_GATE_ATTEMPT_DISPOSITION_DIR
  unset PRO_GATE_COMPLETED_DIR PRO_GATE_REVIEW_INPUT_BINDING_DIR PRO_GATE_REVIEW_RESULT_BINDING_DIR
  unset PRO_GATE_DELIVERY_CONDITION_DIR PRO_GATE_THROTTLE_COOLDOWN
}
seed(){ # key charged-count trajectory (three completed rounds, plus any unscored charges)
  local key="$1" used="$2" trajectory="$3" i=0 n now
  now="$(date +%s)"
  mkdir -p "$(pg_rounds_dir)"
  : > "$(pg_rounds_dir)/$key"
  while [ "$i" -lt "$used" ]; do printf '%s\n' "$now" >> "$(pg_rounds_dir)/$key"; i=$((i + 1)); done
  : > "$(pg_rounds_dir)/$key.hist"
  case "$trajectory" in churning) counts='3 3 3';; converging) counts='5 3 1';; clean) counts='0 0 0';; esac
  for n in $counts; do printf '%s\tFIX-FIRST\t0\t%s\t0\t0\t1\n' "$now" "$n" >> "$(pg_rounds_dir)/$key.hist"; done
}
facts_with_governor(){ # governor [patch]
  local patch="${2:-}"
  [ -n "$patch" ] || patch='{}'
  jq -cS --argjson governor "$1" --argjson patch "$patch" --argjson identity "$(pg_review_decision_identity_json)" \
    '.base_facts * $patch | .governor=$governor | .contract=$identity' "$HERE/fixtures/review-decision/v1/corpus.json"
}
matrix_case(){ (
  local mode="$1" override="$2" trajectory="$3" budget="$4" policy base=6 numeric earned=0 streak=0 used=3
  local expected_granted=true expected_grant granted=false governor decision reason expected_reason
  clear_policy
  PRO_GATE_HOME="$TDIR/$mode-$override-$trajectory-$budget"
  case "$mode" in
    advisory) PRO_GATE_ROUND_GUARD=''; PRO_GATE_ROUNDS_BASE=6; policy=advisory ;;
    enforced) PRO_GATE_ROUND_GUARD=1; PRO_GATE_ROUNDS_BASE=6; policy=enforced ;;
    off) PRO_GATE_ROUND_GUARD=0; PRO_GATE_ROUNDS_BASE=6; policy=off ;;
    flat) PRO_GATE_MAX_ROUNDS_PER_PR=6; policy=enforced ;;
    base0) PRO_GATE_ROUNDS_BASE=0; base=0; policy=lockdown ;;
    cap0) PRO_GATE_MAX_ROUNDS_PER_PR=0; policy=lockdown ;;
  esac
  case "$override" in continue) PRO_GATE_ROUNDS_CONTINUE=1;; force) PRO_GATE_FORCE_ROUND=1;; both) PRO_GATE_ROUNDS_CONTINUE=1; PRO_GATE_FORCE_ROUND=1;; esac
  if [ "$trajectory" = converging ]; then earned=2; else streak=2; fi
  case "$mode" in flat) numeric=6;; cap0) numeric=0;; *) numeric=$((base + earned));; esac
  if [ "$budget" = exhausted ] && [ "$numeric" -gt "$used" ]; then used="$numeric"; fi
  seed fixture "$used" "$trajectory"
  expected_grant="$numeric"
  if [ "$streak" -eq 2 ] && [ "${PRO_GATE_ROUNDS_CONTINUE:-0}" != 1 ] \
      && [ "$mode" != flat ] && [ "$mode" != cap0 ] && [ "$used" -lt "$numeric" ]; then expected_grant="$used"; fi
  if [ "$policy" != advisory ] && [ "$policy" != off ] && [ "${PRO_GATE_FORCE_ROUND:-0}" != 1 ]; then
    if [ "$policy" = lockdown ] || [ "$used" -ge "$numeric" ]; then expected_granted=false
    elif [ "$mode" != flat ] && [ "$streak" -ge 2 ] && [ "${PRO_GATE_ROUNDS_CONTINUE:-0}" != 1 ]; then expected_granted=false; fi
  fi
  pg_round_score fixture
  [ "$PG_ROUND_GRANT" -eq "$expected_grant" ] && [ "$PG_ROUND_EARNED" -eq "$earned" ] && [ "$PG_ROUND_STREAK" -eq "$streak" ] || {
    echo "score grant=$PG_ROUND_GRANT expected=$expected_grant earned=$PG_ROUND_EARNED streak=$PG_ROUND_STREAK"; return 1;
  }
  [ "$(pg_round_grant fixture)" -eq "$expected_grant" ] || return 1
  pg_round_guard fixture > "$PRO_GATE_HOME/guard.txt" && granted=true
  [ "$granted" = "$expected_granted" ] || { cat "$PRO_GATE_HOME/guard.txt"; echo "guard=$granted expected=$expected_granted"; return 1; }
  governor="$(pg_round_governor_facts_json fixture "$granted")" || return 1
  jq -e --arg mode "$policy" --argjson grant "$expected_grant" --argjson granted "$expected_granted" \
    '.policy_mode==$mode and .grant==$grant and .granted==$granted and .scored==3' <<<"$governor" >/dev/null || return 1
  decision="$(pg_review_decision_reduce "$(facts_with_governor "$governor")")" || return 1
  reason="$(jq -r .reason <<<"$decision")"
  if [ "$streak" -ge 2 ] && [ "${PRO_GATE_ROUNDS_CONTINUE:-0}" != 1 ]; then expected_reason=rounds-not-converging
  elif [ "$granted" != true ]; then expected_reason=round-governor-denied
  else expected_reason=round-granted-for-changed-input; fi
  [ "$reason" = "$expected_reason" ] || { echo "reason=$reason expected=$expected_reason"; return 1; }
  # Querying/scoring is read-only: even FORCE never charges a round here.
  [ "$(pg_round_count fixture)" -eq "$used" ]
); }

for mode in advisory enforced off flat base0 cap0; do
  for override in none continue force both; do
    for trajectory in churning converging; do
      for budget in remaining exhausted; do
        result="$(matrix_case "$mode" "$override" "$trajectory" "$budget" 2>&1)"; rc=$?
        check "$mode/$override/$trajectory/$budget shares numeric scoring and typed admission" "$rc" "$result"
      done
    done
  done
done

result="$(
  clear_policy
  PRO_GATE_HOME="$TDIR/default"
  seed default 8 clean
  [ "$(pg_round_policy_mode default)" = advisory ] && pg_round_guard default >/dev/null || exit 1
  governor="$(pg_round_governor_facts_json default true)"
  decision="$(pg_review_decision_reduce "$(facts_with_governor "$governor")")"
  [ "$(jq -r .action <<<"$decision")" = run-granted-review ] || exit 1
  PRO_GATE_ROUNDS_CONTINUE=1
  seed default 3 churning
  pg_round_score default
  [ "$PG_ROUND_GRANT" = 3 ] || exit 1
  unset PRO_GATE_ROUNDS_CONTINUE
  decision="$(pg_review_decision_reduce "$(facts_with_governor "$(pg_round_governor_facts_json default true)")")"
  [ "$(jq -r .reason <<<"$decision")" = rounds-not-converging ]
)"; rc=$?
check 'unset defaults remain advisory, clean rounds converge, and CONTINUE leaves no durable override' "$rc" "$result"

result="$(
  clear_policy
  PRO_GATE_HOME="$TDIR/other-gates"
  PRO_GATE_ROUNDS_BASE=6 PRO_GATE_ROUNDS_CONTINUE=1 PRO_GATE_FORCE_ROUND=1
  seed gates 3 churning
  governor="$(pg_round_governor_facts_json gates true)"
  for scenario in cooldown provenance ownership input binding; do
    case "$scenario" in
      cooldown) patch='{"cooldown":{"active":true,"seconds_remaining":30}}'; reason=account-cooldown-active ;;
      provenance) patch='{"prior_review":{"applicable":true,"binding_valid":true,"marker":"pg-run-acme-widgets-1983-1700000001-1","provenance_valid":false,"verdict":"SHIP"}}'; reason=invalid-result-provenance ;;
      ownership) patch='{"active_index":{"binding_valid":true,"marker":"pg-run-acme-widgets-1983-1700000001-1","state":"charged"}}'; reason=active-work-requires-recovery ;;
      input) patch='{"input":{"proven":false}}'; reason=unproven-input ;;
      binding) patch='{"input":{"binding_valid":false}}'; reason=invalid-binding ;;
    esac
    decision="$(pg_review_decision_reduce "$(facts_with_governor "$governor" "$patch")")"
    [ "$(jq -r .reason <<<"$decision")" = "$reason" ] || { printf '%s\n' "$scenario: $decision"; exit 1; }
  done
)"; rc=$?
check 'CONTINUE and FORCE preserve cooldown, provenance, ownership, and binding gates' "$rc" "$result"

effect_case(){ (
  clear_policy
  PRO_GATE_HOME="$TDIR/effect"
  PRO_GATE_ROUNDS_BASE=6 PRO_GATE_ROUNDS_CONTINUE=1
  PRO_GATE_COOLDOWN_FILE="$PRO_GATE_HOME/throttle.cooldown"
  ROUND_KEY=acme-widgets-1983 PR_NUM=1983 INPUT=bundle
  PG_META_HOST=github.com PG_META_OWNER=acme PG_META_REPO=widgets REPO="$TDIR/repository"
  local fixture_head=1111111111111111111111111111111111111111 fixture_base=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local boundary rc before saved
  mkdir -p "$REPO" "$PRO_GATE_HOME"
  # Only external repository/proof acquisition is replaced. Round, lifecycle, delivery facts,
  # reducer, and effect boundary functions below are their real production implementations.
  git(){ printf '%s\n' "$fixture_head"; }
  pg_pr_evidence_read(){ jq -cn --arg base "$fixture_base" '{metadata:{target:{base_oid:$base}}}'; }
  pg_pr_evidence_current(){ return 0; }
  pg_review_decision_input_proof_current(){ return 0; }
  pg_status(){ printf '%s\n' "$*" >> "$TDIR/effect-status"; }
  pg_finish(){ exit "$1"; }
  REVIEW_DECISION_INPUT_TEMPLATE="$(jq -cn --arg head "$fixture_head" --arg base "$fixture_base" \
    '{repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{pr:1983,head_oid:$head},evidence:{identity:"evidence-current",mode:"full-pr",proof:{base_oid:$base,head_oid:$head}}}')"
  seed "$ROUND_KEY" 3 churning
  pg_fresh_dispatch_recheck || { echo "headroom should grant: ${PG_FRESH_DECISION:-missing}"; return 1; }
  saved="$PG_FRESH_DECISION"
  [ "$(jq -r .action <<<"$saved")" = run-granted-review ] || return 1
  # Another spend exhausts the numeric grant after this advisory query was saved.
  seed "$ROUND_KEY" 6 churning
  before="$(pg_sha256 "$(pg_rounds_dir)/$ROUND_KEY")" || return 1
  [[ "$before" =~ ^[0-9a-f]{64}$ ]] || return 1
  for boundary in pre-lock under-lock post-slot-pre-charge; do
    grep -Fq "pg_fresh_dispatch_require_run $boundary" "$HERE/../bin/oracle-review.sh" || return 1
    (
      PG_FRESH_DECISION="$saved" PG_FRESH_ACTION=run-granted-review
      pg_fresh_dispatch_require_run "$boundary"
      printf 'unexpected charge/browser\n' >> "$TDIR/effect-dispatched"
    ) > "$TDIR/effect-$boundary.json" 2> "$TDIR/effect-$boundary.err"
    rc=$?
    [ "$rc" -eq 3 ] && [ ! -e "$TDIR/effect-dispatched" ] \
      && [ "$(pg_sha256 "$(pg_rounds_dir)/$ROUND_KEY")" = "$before" ] \
      && jq -e '.action=="stop-without-new-review" and .reason=="round-governor-denied" and .facts.governor.continue_override==true' "$TDIR/effect-$boundary.json" >/dev/null || return 1
  done
  seed "$ROUND_KEY" 3 churning
  PRO_GATE_FORCE_ROUND=1
  : > "$PRO_GATE_COOLDOWN_FILE"
  pg_fresh_dispatch_recheck; rc=$?
  [ "$rc" -ne 0 ] && [ "$(jq -r .reason <<<"$PG_FRESH_DECISION")" = account-cooldown-active ]
); }
result="$(effect_case 2>&1)"; rc=$?
check 'saved CONTINUE grant rechecks exhaustion before charge/browser at every boundary; cooldown still wins' "$rc" "$result"

printf '%s failures\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
