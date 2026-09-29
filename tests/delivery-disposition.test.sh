#!/usr/bin/env bash
# Isolated delivery-history faults through the real library and extracted engine functions.
# No browser, service, paid review, or timing override. Repository proof acquisition alone is
# replaced in the effect-boundary fixture; disposition, accounting, facts and reducer stay real.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-delivery-disposition.XXXXXX")" || exit 2
trap 'rm -rf "$TDIR"' EXIT
FAILURES=0
if [ -n "${PG_TEST_BASELINE_REV:-}" ]; then
  BASELINE_SOURCE="$(git -C "$ROOT" show "$PG_TEST_BASELINE_REV:lib/pro-gate-lib.sh")" || exit 2
  eval "$BASELINE_SOURCE"
else
  . "$ROOT/lib/pro-gate-lib.sh"
fi

clear_fixture_env(){
  unset PRO_GATE_ACTIVE_DIR PRO_GATE_RUN_META_DIR PRO_GATE_RESERVATION_DIR PRO_GATE_ATTEMPT_DISPOSITION_DIR
  unset PRO_GATE_COMPLETED_DIR PRO_GATE_REVIEW_INPUT_BINDING_DIR PRO_GATE_REVIEW_RESULT_BINDING_DIR
  unset PRO_GATE_DELIVERY_CONDITION_DIR PRO_GATE_ROUNDS_DIR PRO_GATE_ROUNDS_WINDOW
  unset PRO_GATE_RESERVATION_LOCK PRO_GATE_MANIFEST_DIR PRO_GATE_SALVAGE_CLASS_DIR PRO_GATE_TITLE_SEQ_DIR
  unset PG_RESERVATION_GUARD_FD PG_RESERVATION_GUARD_DIR PG_RESERVATION_GUARD_OWNER
  unset PRO_GATE_ROUND_GUARD PRO_GATE_ROUNDS_BASE PRO_GATE_ROUNDS_CEILING PRO_GATE_MAX_ROUNDS_PER_PR
  unset PRO_GATE_FORCE_ROUND PRO_GATE_ROUNDS_CONTINUE PG_FRESH_DELIVERY_SNAPSHOT PG_DISPATCH_DELIVERY_CONDITION
  unset PRO_GATE_THROTTLE_COOLDOWN
  PRO_GATE_BROWSER_ATTACHMENTS=auto
}
fixture_timeout(){ [ "$1" = 5s ] || return 97; shift; "$@"; }
fixture_oracle(){
  [ "${1:-}" = --version ] || return 98
  printf 'version\n' >> "$PRO_GATE_HOME/oracle-probes"
  printf '%s\n' "$fixture_version"
  return "$fixture_version_rc"
}
basic_setup(){
  clear_fixture_env
  PRO_GATE_HOME="$TDIR/$1"; mkdir -p "$PRO_GATE_HOME" || return 1
  PRO_GATE_COOLDOWN_FILE="$PRO_GATE_HOME/throttle.cooldown"
  PRO_GATE_ORACLE_BIN=fixture_oracle PRO_GATE_TIMEOUT_BIN=fixture_timeout
  fixture_version=1.0-fixture fixture_version_rc=0
  ROUND_KEY=acme-delivery-77 PR_NUM=77 INPUT=connector
  PG_META_HOST=github.com PG_META_OWNER=acme PG_META_REPO=delivery
  fixture_head=1111111111111111111111111111111111111111
  fixture_epoch=$(( $(date +%s) - 10000 )); fixture_serial=0
  RUN_MARKER="" REVIEW_DECISION_EXECUTE=1
}
legacy_disposition(){ # serial [condition digest] [count]
  local serial="$1" digest="${2:-}" n="${3:-1}" epoch
  epoch=$((fixture_epoch + serial)); LEGACY_MARKER="pg-run-$ROUND_KEY-$epoch-$serial"
  pg_attempt_disposition_write github.com acme delivery 77 "$ROUND_KEY" "$LEGACY_MARKER" "$epoch" not-submitted proven-no-submit || return 1
  [ -z "$digest" ] || pg_delivery_condition_write "$LEGACY_MARKER" "$ROUND_KEY" "$digest" "$n"
}
attempt_snapshot(){ pg_attempt_snapshot github.com acme delivery 77 "$ROUND_KEY"; }
corrupt_sidecar_probe(){
  basic_setup corrupt-probe || return 1
  legacy_disposition 1 || return 1
  mkdir -p "$(pg_delivery_condition_dir)" || return 1
  printf '{broken' > "$(pg_delivery_condition_dir)/$LEGACY_MARKER"
  local got
  got="$(pg_delivery_facts_json "$(attempt_snapshot)" relation:aaa connector)" || return 1
  printf '%s\n' "$got"
  jq -e '.state=="unavailable" and .failed_unchanged==null' <<<"$got" >/dev/null
}
if [ "${1:-}" = --corrupt-sidecar-probe ]; then corrupt_sidecar_probe; exit "$?"; fi
[ -z "${PG_TEST_BASELINE_REV:-}" ] || { echo 'baseline mode supports --corrupt-sidecar-probe only' >&2; exit 2; }

extract_function(){
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" { printing=1 } printing { print } printing && /^}/ { exit }' "$ROOT/bin/oracle-review.sh"
}
for function_name in pg_fresh_dispatch_capture_delivery_condition pg_fresh_dispatch_record_undelivered pg_fresh_dispatch_refund pg_fresh_dispatch_recheck pg_fresh_dispatch_require_run pg_fresh_dispatch_release_no_conversation pg_salvage_fail_reason; do
  function_source="$(extract_function "$function_name")"
  [ -n "$function_source" ] || { echo "missing engine function: $function_name" >&2; exit 2; }
  eval "$function_source"
done
setup(){
  basic_setup "$1" || return 1
  REVIEW_DECISION_INPUT_TEMPLATE="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg head "$fixture_head" '
    {charged_spend_epoch:1,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,
     evidence:{identity:("connector:github.com/acme/delivery:"+$head),mode:"connector",proof:{commit_target:$head,endpoint_digest:null,raw_diff_digest:null,repository_target:"github.com/acme/delivery"}},
     marker:"pg-run-prospective-acme-delivery-77",record_type:"review-input-binding/v1",record_version:1,
     repository:{host:"github.com",owner:"acme",repo:"delivery"},target:{head_oid:$head,kind:"pull-request",pr:77}}')" || return 1
  RELATION="$(pg_review_relation_identity "$REVIEW_DECISION_INPUT_TEMPLATE")" || return 1
}
charge(){
  local binding
  pg_fresh_dispatch_capture_delivery_condition || return 1
  fixture_serial=$((fixture_serial + 1)); RUN_SPEND_EPOCH=$((fixture_epoch + fixture_serial))
  RUN_MARKER="pg-run-$ROUND_KEY-$RUN_SPEND_EPOCH-$fixture_serial"
  OUT="$PRO_GATE_HOME/out-$fixture_serial.md"
  mkdir -p "$(pg_rounds_dir)" "$(pg_active_dir)" || return 1
  printf '%s\n' "$RUN_SPEND_EPOCH" >> "$(pg_rounds_dir)/$ROUND_KEY" || return 1
  pg_run_meta_write "$RUN_MARKER" github.com acme delivery "$ROUND_KEY" 77 "$OUT" "$RUN_SPEND_EPOCH" || return 1
  binding="$(jq -cS --arg marker "$RUN_MARKER" --argjson epoch "$RUN_SPEND_EPOCH" '.marker=$marker | .charged_spend_epoch=$epoch' <<<"$REVIEW_DECISION_INPUT_TEMPLATE")" || return 1
  pg_review_input_binding_write "$RUN_MARKER" "$binding" || return 1
  printf '%s\t%s\t%s\t%s\tremote-chrome\tfixture-token\tinput-bound\t%s\n' "$RUN_MARKER" "$OUT" "$$" "$RUN_SPEND_EPOCH" "$RUN_SPEND_EPOCH" > "$(pg_active_dir)/$ROUND_KEY" || return 1
  pg_reservation_write "$RUN_MARKER" "$ROUND_KEY" "$OUT" 1 GPT-Y "$RUN_SPEND_EPOCH"
}
no_send(){ charge && pg_fresh_dispatch_record_undelivered && pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT"; }
delivery_facts(){ pg_delivery_facts_json "$(attempt_snapshot)" "$RELATION" "$INPUT"; }
expect_facts(){
  local got
  got="$(delivery_facts)" || return 1
  jq -e --arg state "$1" --argjson n "$2" '.state==$state and .failed_unchanged==$n' <<<"$got" >/dev/null || { printf 'unexpected facts: %s\n' "$got"; return 1; }
}
assert_refunded(){
  [ ! -s "$(pg_rounds_dir)/$ROUND_KEY" ] && [ ! -e "$(pg_run_meta_dir)/$RUN_MARKER" ] \
    && [ ! -e "$(pg_reservation_dir)/$RUN_MARKER" ] && [ ! -e "$(pg_active_dir)/$ROUND_KEY" ] \
    && [ ! -e "$(pg_review_input_binding_dir)/$RUN_MARKER" ]
}
disposition_digest(){
  local digest
  digest="$(pg_sha256 "$(pg_attempt_disposition_dir)/$RUN_MARKER")" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
}
assert_disposition_unchanged(){
  local digest
  digest="$(disposition_digest)" || return 1
  [ "$digest" = "$1" ]
}
mutate_disposition(){
  local changed
  changed="$(jq -cS "$1" "$(pg_attempt_disposition_dir)/$RUN_MARKER")" || return 1
  printf '%s' "$changed" > "$(pg_attempt_disposition_dir)/$RUN_MARKER"
}
run_case(){
  if ( "$2" ); then printf 'ok - %s\n' "$1";
  else printf 'not ok - %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); fi
}
# #246: Send was clicked and produced no ChatGPT conversation; the engine settles the attempt here.
no_conversation(){ charge && pg_fresh_dispatch_release_no_conversation; }
assert_no_conversation_refunded(){ # expected consecutive failed deliveries
  [ "$PG_NO_CONVERSATION_REFUNDED" = 1 ] && ! pg_round_has_epoch "$ROUND_KEY" "$RUN_SPEND_EPOCH" \
    && [ ! -e "$(pg_run_meta_dir)/$RUN_MARKER" ] && [ ! -e "$(pg_reservation_dir)/$RUN_MARKER" ] \
    && [ ! -e "$(pg_active_dir)/$ROUND_KEY" ] \
    && jq -e --argjson n "$1" '.record_version==2 and .terminal_kind=="recovery-exhausted" and
         .proof_kind=="no-conversation-after-send" and .delivery.state=="known" and .delivery.consecutive==$n' \
         "$(pg_attempt_disposition_dir)/$RUN_MARKER" >/dev/null \
    && [ "$(pg_salvage_fail_reason "$FAIL_DETAIL")" = no-conversation ]
}
decision_fixture(){ # the effect recheck's real query; only repository proof acquisition is replaced
  REPO="$PRO_GATE_HOME/repository"; mkdir -p "$REPO"
  git(){ printf '%s\n' "$fixture_head"; }
  pg_pr_evidence_read(){ return 1; }
  pg_review_decision_input_proof_current(){ return 0; }
}

known_chain(){
  setup known-chain && no_send && assert_refunded && expect_facts known 1 || return 1
  no_send && assert_refunded && expect_facts known 2 || return 1
  jq -e '.record_version==2 and .delivery.state=="known" and .delivery.consecutive==2' "$(pg_attempt_disposition_dir)/$RUN_MARKER" >/dev/null || return 1
  local before
  before="$(disposition_digest)" || return 1
  pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" && assert_refunded \
    && assert_disposition_unchanged "$before"
}
exclude_published_current(){
  setup exclude-current && no_send || return 1
  local predecessor="$RUN_MARKER" current snapshot
  no_send || return 1
  current="$RUN_MARKER"
  snapshot="$(pg_attempt_snapshot github.com acme delivery 77 "$ROUND_KEY" "$current")" || return 1
  jq -e --arg m "$predecessor" '.marker==$m and .source=="disposition" and .terminal.delivery.consecutive==1' <<<"$snapshot" >/dev/null
}
published_snapshot_replay(){
  setup published-replay && no_send && charge && pg_fresh_dispatch_record_undelivered || return 1
  local original="$PG_FRESH_DELIVERY_SNAPSHOT" original_sidecar before saved
  jq -e '.consecutive==2' <<<"$original" >/dev/null || return 1
  original_sidecar="$(pg_delivery_condition_read "$RUN_MARKER")" || return 1
  saved="$(declare -f pg_round_unrecord_epoch)"
  pg_round_unrecord_epoch(){ return 1; }
  if pg_fresh_dispatch_refund "$original"; then return 1; fi
  before="$(disposition_digest)" || return 1
  pg_round_has_epoch "$ROUND_KEY" "$RUN_SPEND_EPOCH" || return 1
  # After publication even a changed caller condition must replay the published evidence.
  PG_DISPATCH_DELIVERY_CONDITION="$(pg_delivery_condition_json relation:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bundle never 2.0-fixture)" || return 1
  pg_delivery_snapshot_validate "$(jq -cnS --argjson c "$PG_DISPATCH_DELIVERY_CONDITION" '{condition:$c,consecutive:1,state:"known"}')" >/dev/null || return 1
  pg_fresh_dispatch_record_undelivered || return 1
  [ "$PG_FRESH_DELIVERY_SNAPSHOT" = "$original" ] \
    && [ "$(pg_delivery_condition_read "$RUN_MARKER")" = "$original_sidecar" ] || return 1
  eval "$saved"
  pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" && assert_refunded \
    && assert_disposition_unchanged "$before" && expect_facts known 2 || return 1
  pg_fresh_dispatch_record_undelivered && [ "$PG_FRESH_DELIVERY_SNAPSHOT" = "$original" ] \
    && pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" && assert_refunded \
    && assert_disposition_unchanged "$before"
}
superseded_sent_predecessor(){
  setup superseded-sent && no_send && charge || return 1
  local sent="$RUN_MARKER" snapshot
  pg_reservation_set_state "$sent" superseded || return 1
  charge || return 1
  snapshot="$(pg_attempt_snapshot github.com acme delivery 77 "$ROUND_KEY" "$RUN_MARKER")" || return 1
  jq -e --arg m "$sent" '.marker==$m and .state=="superseded" and .fresh_eligible==true' <<<"$snapshot" >/dev/null || return 1
  pg_fresh_dispatch_record_undelivered || return 1
  jq -e '.state=="known" and .consecutive==1' <<<"$PG_FRESH_DELIVERY_SNAPSHOT" >/dev/null || return 1
  pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" && expect_facts known 1
}
bounded_disposition_read(){
  setup bounded-disposition && no_send || return 1
  local old="$RUN_MARKER" changed f
  f="$(pg_attempt_disposition_dir)/$old"
  changed="$(jq -cS '.delivery={padding:("x"*70000)}' "$f")" || return 1
  printf '%s' "$changed" > "$f"
  if pg_attempt_disposition_read "$old" >/dev/null; then return 1; fi
  charge && pg_fresh_dispatch_refund '{"state":"not-applicable"}' || return 1
  # Even valid outer metadata cannot order an oversized unreadable payload behind newer work.
  expect_facts unavailable null || return 1
  rm "$f" && mkfifo "$f" || return 1
  [ -p "$f" ] || return 1
  expect_facts unavailable null
}
disposition_read_status(){
  setup disposition-read-status && no_send || return 1
  head(){ command head "$@"; return 1; }
  expect_facts unavailable null
}
sidecar_write_fault(){
  setup sidecar-write && charge || return 1
  ln(){ case "${2:-}" in "$PRO_GATE_HOME"/delivery-conditions/*) return 1;; esac; command ln "$@"; }
  pg_fresh_dispatch_record_undelivered && pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" && assert_refunded && expect_facts known 1 || return 1
  [ ! -e "$(pg_delivery_condition_dir)/$RUN_MARKER" ] || return 1
  no_send && expect_facts known 2
}
v2_ignores_sidecar_damage(){
  setup v2-sidecar && no_send || return 1
  printf '{broken' > "$(pg_delivery_condition_dir)/$RUN_MARKER"
  expect_facts known 1 || return 1
  PRO_GATE_DELIVERY_CONDITION_DIR="$PRO_GATE_HOME/broken-store"
  printf 'not a directory' > "$PRO_GATE_DELIVERY_CONDITION_DIR"
  expect_facts known 1
}
legacy_read_fault(){
  setup legacy-read || return 1
  legacy_disposition 1 "$(pg_delivery_condition_digest "$RELATION" "$INPUT" auto 1.0-fixture)" 2 || return 1
  fixture_fault_path="$(pg_delivery_condition_dir)/$LEGACY_MARKER"
  cat(){ command cat "$@"; [ "${1:-}" != "$fixture_fault_path" ]; }
  # The injected read prints all valid bytes, then fails: status must still win.
  expect_facts unavailable null
}
legacy_broken_store(){
  setup legacy-store && legacy_disposition 1 || return 1
  PRO_GATE_DELIVERY_CONDITION_DIR="$PRO_GATE_HOME/broken-store"
  printf 'not a directory' > "$PRO_GATE_DELIVERY_CONDITION_DIR"
  expect_facts unavailable null
}
legacy_list_fault(){
  setup legacy-list && legacy_disposition 1 || return 1
  mkdir -p "$(pg_delivery_condition_dir)"
  ls(){ case "${2:-}" in "$PRO_GATE_HOME"/delivery-conditions) return 1;; esac; command ls "$@"; }
  expect_facts unavailable null
}
legacy_absent_then_no_send(){
  setup legacy-untracked && legacy_disposition 1 && expect_facts legacy-untracked null || return 1
  fixture_serial=1
  no_send && assert_refunded && expect_facts unavailable null || return 1
  jq -e '.delivery.state=="unavailable" and .delivery.consecutive==null' "$(pg_attempt_disposition_dir)/$RUN_MARKER" >/dev/null
}
history_acquisition_fault(){
  setup history-fault && charge || return 1
  local saved
  saved="$(declare -f pg_attempt_snapshot)"
  pg_attempt_snapshot(){ return 1; }
  pg_fresh_dispatch_record_undelivered || return 1
  eval "$saved"
  pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" && assert_refunded && expect_facts unavailable null
}
malformed_history(){
  setup malformed-history && charge || return 1
  local saved
  saved="$(declare -f pg_attempt_snapshot)"
  pg_attempt_snapshot(){ printf '{}'; }
  pg_fresh_dispatch_record_undelivered || return 1
  eval "$saved"
  pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" && assert_refunded && expect_facts unavailable null
}
comparison_fault(){
  setup compare-fault && charge || return 1
  local saved
  saved="$(declare -f pg_delivery_state_json)"
  pg_delivery_state_json(){ return 1; }
  pg_fresh_dispatch_record_undelivered || return 1
  eval "$saved"
  pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" && assert_refunded && expect_facts unavailable null
}
serialization_fault(){
  setup serialization-fault && charge || return 1
  pg_delivery_snapshot_json(){ return 1; }
  if pg_fresh_dispatch_record_undelivered; then return 1; fi
  if pg_fresh_dispatch_refund "${PG_FRESH_DELIVERY_SNAPSHOT:-}"; then return 1; fi
  pg_round_has_epoch "$ROUND_KEY" "$RUN_SPEND_EPOCH" && [ -f "$(pg_run_meta_dir)/$RUN_MARKER" ]
}
disposition_publish_fault(){
  setup disposition-write && charge && pg_fresh_dispatch_record_undelivered || return 1
  ln(){ case "${2:-}" in "$PRO_GATE_HOME"/attempt-dispositions/*) return 1;; esac; command ln "$@"; }
  if pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT"; then return 1; fi
  pg_round_has_epoch "$ROUND_KEY" "$RUN_SPEND_EPOCH" && [ -f "$(pg_run_meta_dir)/$RUN_MARKER" ] \
    && [ -f "$(pg_reservation_dir)/$RUN_MARKER" ] && [ ! -e "$(pg_attempt_disposition_dir)/$RUN_MARKER" ]
}
cleanup_interruption(){
  setup cleanup-crash && charge && pg_fresh_dispatch_record_undelivered || return 1
  local saved before
  saved="$(declare -f pg_round_unrecord_epoch)"
  pg_round_unrecord_epoch(){ return 1; }
  if pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT"; then return 1; fi
  pg_round_has_epoch "$ROUND_KEY" "$RUN_SPEND_EPOCH" || return 1
  jq -e '.delivery.consecutive==1' "$(pg_attempt_disposition_dir)/$RUN_MARKER" >/dev/null || return 1
  before="$(disposition_digest)" || return 1
  eval "$saved"
  pg_attempt_reconcile_terminal "$RUN_MARKER" && assert_refunded && expect_facts known 1 \
    && assert_disposition_unchanged "$before"
}
post_refund_interruption(){
  setup post-refund-crash && charge && pg_fresh_dispatch_record_undelivered || return 1
  local saved before later_epoch
  saved="$(declare -f pg_reservation_remove)"
  pg_reservation_remove(){ return 1; }
  if pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT"; then return 1; fi
  [ ! -s "$(pg_rounds_dir)/$ROUND_KEY" ] && [ -f "$(pg_reservation_dir)/$RUN_MARKER" ] || return 1
  before="$(disposition_digest)" || return 1
  later_epoch=$((RUN_SPEND_EPOCH + 99))
  printf '%s\n' "$later_epoch" >> "$(pg_rounds_dir)/$ROUND_KEY"
  eval "$saved"
  pg_attempt_reconcile_terminal "$RUN_MARKER" || return 1
  [ "$(cat "$(pg_rounds_dir)/$ROUND_KEY")" = "$later_epoch" ] \
    && [ ! -e "$(pg_reservation_dir)/$RUN_MARKER" ] && [ ! -e "$(pg_run_meta_dir)/$RUN_MARKER" ] \
    && [ ! -e "$(pg_active_dir)/$ROUND_KEY" ] \
    && assert_disposition_unchanged "$before"
}
unknown_build(){
  setup unknown-build
  fixture_version=unknown
  no_send && assert_refunded && expect_facts unavailable null || return 1
  fixture_version=2.0-fixture
  expect_facts unavailable null || return 1
  PRO_GATE_BROWSER_ATTACHMENTS=never
  : > "$PRO_GATE_HOME/oracle-probes"
  expect_facts known 0 && [ ! -s "$PRO_GATE_HOME/oracle-probes" ]
}
current_build_failure(){
  setup current-build && no_send || return 1
  fixture_version_rc=1
  : > "$PRO_GATE_HOME/oracle-probes"
  [ "$(pg_oracle_identity)" = unknown ] && [ "$(wc -l < "$PRO_GATE_HOME/oracle-probes")" -eq 2 ] \
    && expect_facts unavailable null
}
component_changes(){
  setup component-change && no_send || return 1
  local original_relation="$RELATION"
  : > "$PRO_GATE_HOME/oracle-probes"
  RELATION="relation:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  expect_facts known 0 || return 1
  RELATION="$original_relation" INPUT=bundle
  expect_facts known 0 || return 1
  INPUT=connector PRO_GATE_BROWSER_ATTACHMENTS=never
  expect_facts known 0 && [ ! -s "$PRO_GATE_HOME/oracle-probes" ] || return 1
  PRO_GATE_BROWSER_ATTACHMENTS=auto fixture_version=2.0-fixture
  expect_facts known 0
}
unknown_components(){
  setup unknown-components && charge || return 1
  PG_DISPATCH_DELIVERY_CONDITION="$(pg_delivery_condition_json '' unknown auto unknown)"
  pg_fresh_dispatch_record_undelivered && pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" || return 1
  expect_facts unavailable null || return 1
  PRO_GATE_BROWSER_ATTACHMENTS=never
  : > "$PRO_GATE_HOME/oracle-probes"
  expect_facts known 0 && [ ! -s "$PRO_GATE_HOME/oracle-probes" ]
}
attempt_time_components(){
  setup attempt-time && charge || return 1
  fixture_version=2.0-fixture PRO_GATE_BROWSER_ATTACHMENTS=never INPUT=bundle
  pg_fresh_dispatch_record_undelivered && pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT" || return 1
  jq -e '.delivery.condition.oracle=="1.0-fixture" and .delivery.condition.attachments=="auto" and .delivery.condition.input=="connector"' "$(pg_attempt_disposition_dir)/$RUN_MARKER" >/dev/null \
    && expect_facts known 0
}
legacy_known_and_unknown(){
  setup legacy-known
  legacy_disposition 1 "$(pg_delivery_condition_digest "$RELATION" "$INPUT" auto 1.0-fixture)" 2 && expect_facts known 2 || return 1
  fixture_version=2.0-fixture
  expect_facts known 0 || return 1
  fixture_version_rc=1 PRO_GATE_BROWSER_ATTACHMENTS=never
  expect_facts unavailable null || return 1
  fixture_version_rc=0 PRO_GATE_BROWSER_ATTACHMENTS=auto
  legacy_disposition 2 "$(pg_delivery_condition_digest "$RELATION" "$INPUT" auto unknown)" 1 && expect_facts unavailable null
}
cloudflare_and_ordering(){
  setup cloudflare && no_send || return 1
  mutate_disposition 'del(.delivery)' || return 1
  expect_facts unavailable null || return 1
  charge && pg_fresh_dispatch_refund '{"state":"not-applicable"}' && assert_refunded || return 1
  : > "$PRO_GATE_HOME/oracle-probes"
  expect_facts known 0 && [ ! -s "$PRO_GATE_HOME/oracle-probes" ] || return 1
  no_send && expect_facts known 1
}
sent_breaks_history(){
  setup sent-break && no_send && mutate_disposition '.delivery.consecutive="broken"' || return 1
  local marker epoch
  epoch=$((fixture_epoch + 2)); marker="pg-run-$ROUND_KEY-$epoch-2"
  pg_attempt_disposition_write github.com acme delivery 77 "$ROUND_KEY" "$marker" "$epoch" recovery-exhausted no-conversation-after-send || return 1
  expect_facts known 0
}
malformed_v2(){
  local damage
  for damage in 'del(.delivery)' '.delivery.consecutive="broken"' '.delivery.condition.input="not-a-mode"'; do
    setup "malformed-${damage//[^A-Za-z]/}" && no_send && mutate_disposition "$damage" || return 1
    if pg_attempt_disposition_read "$RUN_MARKER" >/dev/null 2>&1; then return 1; fi
    expect_facts unavailable null || return 1
  done
  printf '{truncated' > "$(pg_attempt_disposition_dir)/$RUN_MARKER"
  expect_facts unavailable null
}
listed_history_access_lost(){
  setup listed-access-lost && no_send && mutate_disposition 'del(.delivery)' || return 1
  local dir condition terminal rc=0
  dir="$(pg_attempt_disposition_dir)"
  condition="$(pg_delivery_condition_json "$RELATION" "$INPUT" auto 1.0-fixture)" || return 1
  # Access lost after the checked listing keeps the damaged record uncertain, never absent.
  ls(){ command ls "$@" || return; [ "${2:-}" != "$dir" ] || chmod 000 "$dir"; }
  expect_facts unavailable null || rc=1
  chmod 700 "$dir"
  terminal="$(pg_delivery_snapshot_json github.com acme delivery 77 "$ROUND_KEY" \
    "pg-run-$ROUND_KEY-$((fixture_epoch + 99))-99" "$condition")" || rc=1
  chmod 700 "$dir"
  jq -e '.state=="unavailable" and .consecutive==null' <<<"$terminal" >/dev/null || rc=1
  return "$rc"
}
single_json_and_binding(){
  setup single-json && charge && pg_fresh_dispatch_record_undelivered || return 1
  if pg_fresh_dispatch_refund "$PG_FRESH_DELIVERY_SNAPSHOT $PG_FRESH_DELIVERY_SNAPSHOT"; then return 1; fi
  pg_round_has_epoch "$ROUND_KEY" "$RUN_SPEND_EPOCH" || return 1
  local previous
  previous="$(jq -cS '.contract_digest="6da6866bab4e95ad138cdc946fa1388be9c386bca7b592c3370c9f52e34b315f"' <<<"$REVIEW_DECISION_INPUT_TEMPLATE")"
  pg_review_input_binding_validate "$previous"
}
legacy_multiple_json(){
  setup legacy-multi
  legacy_disposition 1 "$(pg_delivery_condition_digest "$RELATION" "$INPUT" auto 1.0-fixture)" 1 || return 1
  local bytes
  bytes="$(cat "$(pg_delivery_condition_dir)/$LEGACY_MARKER")" || return 1
  printf '%s\n%s' "$bytes" "$bytes" > "$(pg_delivery_condition_dir)/$LEGACY_MARKER"
  expect_facts unavailable null
}
symlink_disposition(){
  setup symlink-disposition && no_send || return 1
  local old_marker="$RUN_MARKER" held="$PRO_GATE_HOME/held-disposition"
  mv "$(pg_attempt_disposition_dir)/$old_marker" "$held" || return 1
  ln -s "$held" "$(pg_attempt_disposition_dir)/$old_marker" || return 1
  charge && pg_fresh_dispatch_refund '{"state":"not-applicable"}' || return 1
  expect_facts unavailable null
}
no_history_no_probe(){
  setup no-probe
  expect_facts known 0 && [ ! -e "$PRO_GATE_HOME/oracle-probes" ]
}
reducer_force_and_legacy(){
  setup reducer
  local state count facts decision
  for state in known unavailable legacy-untracked; do
    count=null; [ "$state" != known ] || count=2
    facts="$(jq -cS --argjson contract "$(pg_review_decision_identity_json)" --arg state "$state" --argjson n "$count" '
      .base_facts | .contract=$contract | .delivery={state:$state,failed_unchanged:$n,override:true}' "$HERE/fixtures/review-decision/v1/corpus.json")" || return 1
    decision="$(pg_review_decision_reduce "$facts")" || return 1
    if [ "$state" = unavailable ]; then
      jq -e '.action=="stop-without-new-review" and .reason=="delivery-state-unavailable"' <<<"$decision" >/dev/null || return 1
    else
      jq -e '.action=="run-granted-review"' <<<"$decision" >/dev/null || return 1
    fi
  done
}
effect_recheck(){
  setup effect-recheck
  REPO="$PRO_GATE_HOME/repository"; mkdir -p "$REPO"
  git(){ printf '%s\n' "$fixture_head"; }
  pg_pr_evidence_read(){ return 1; }
  pg_review_decision_input_proof_current(){ return 0; }
  pg_status(){ printf '%s\n' "$*" >> "$PRO_GATE_HOME/effect-status"; }
  pg_finish(){ exit "$1"; }
  pg_fresh_dispatch_recheck || return 1
  local saved="$PG_FRESH_DECISION" boundary rc
  no_send && mutate_disposition 'del(.delivery)' || return 1
  RUN_MARKER=""
  for boundary in pre-lock under-lock post-slot-pre-charge; do
    grep -Fq "pg_fresh_dispatch_require_run $boundary" "$ROOT/bin/oracle-review.sh" || return 1
    (
      PG_FRESH_DECISION="$saved" PG_FRESH_ACTION=run-granted-review
      pg_fresh_dispatch_require_run "$boundary"
      printf 'browser/spend reached\n' > "$PRO_GATE_HOME/dispatched"
    ) > "$PRO_GATE_HOME/$boundary.json" 2> "$PRO_GATE_HOME/$boundary.err"
    rc=$?
    [ "$rc" -eq 3 ] && [ ! -e "$PRO_GATE_HOME/dispatched" ] && [ ! -s "$(pg_rounds_dir)/$ROUND_KEY" ] || return 1
    jq -e '.reason=="delivery-state-unavailable" and .facts.delivery.failed_unchanged==null' "$PRO_GATE_HOME/$boundary.json" >/dev/null || return 1
    grep -Fq 'stop-without-new-review/delivery-state-unavailable; no browser submission.' "$PRO_GATE_HOME/$boundary.err" || return 1
    if grep -Fq recheck-failed "$PRO_GATE_HOME/$boundary.err"; then return 1; fi
  done
}
cooldown_boundary(){
  setup cooldown-boundary
  REPO="$PRO_GATE_HOME/repository"; mkdir -p "$REPO"
  git(){ printf '%s\n' "$fixture_head"; }
  pg_pr_evidence_read(){ return 1; }
  pg_review_decision_input_proof_current(){ return 0; }
  pg_status(){ printf '%s\n' "$*" >> "$PRO_GATE_HOME/effect-status"; }
  pg_finish(){ exit "$1"; }
  : > "$PRO_GATE_COOLDOWN_FILE"
  local rc
  ( pg_fresh_dispatch_require_run post-slot-pre-charge ) > "$PRO_GATE_HOME/decision.json" 2> "$PRO_GATE_HOME/decision.err"
  rc=$?
  [ "$rc" -eq 8 ] && jq -e '.reason=="account-cooldown-active"' "$PRO_GATE_HOME/decision.json" >/dev/null \
    && grep -Fq 'stop-without-new-review/account-cooldown-active; no browser submission.' "$PRO_GATE_HOME/decision.err"
}

no_conversation_chain(){
  setup no-conversation-chain && no_conversation && assert_no_conversation_refunded 1 && expect_facts known 1 || return 1
  local before
  before="$(disposition_digest)" || return 1
  # Replaying the settled attempt republishes nothing and refunds nothing more.
  pg_fresh_dispatch_release_no_conversation && assert_no_conversation_refunded 1 \
    && assert_disposition_unchanged "$before" || return 1
  no_conversation && assert_no_conversation_refunded 2 && expect_facts known 2 \
    && [ ! -s "$(pg_rounds_dir)/$ROUND_KEY" ]
}
no_send_and_no_conversation_share_count(){
  setup shared-count && no_send && assert_refunded && expect_facts known 1 || return 1
  no_conversation && assert_no_conversation_refunded 2 || return 1
  setup shared-count-reverse && no_conversation && assert_no_conversation_refunded 1 || return 1
  no_send && assert_refunded && expect_facts known 2
}
no_conversation_unknown_build_keeps_round(){
  setup no-conversation-unknown-build
  fixture_version_rc=1
  no_conversation || return 1
  [ "$PG_NO_CONVERSATION_REFUNDED" = 0 ] && pg_round_has_epoch "$ROUND_KEY" "$RUN_SPEND_EPOCH" \
    && [ ! -e "$(pg_run_meta_dir)/$RUN_MARKER" ] \
    && jq -e '.record_version==1 and .terminal_kind=="recovery-exhausted" and .proof_kind=="no-conversation-after-send"' \
         "$(pg_attempt_disposition_dir)/$RUN_MARKER" >/dev/null \
    && [ "$(pg_salvage_fail_reason "$FAIL_DETAIL")" = no-conversation ] || return 1
  # The retained round bounds this attempt; it must not become a delivery-state-unavailable stop.
  fixture_version_rc=0
  expect_facts known 0
}
no_conversation_v2_requires_known_evidence(){
  setup v2-known-only && charge || return 1
  local known unavailable
  known="$(jq -cnS --argjson c "$PG_DISPATCH_DELIVERY_CONDITION" '{condition:$c,consecutive:1,state:"known"}')" || return 1
  unavailable="$(jq -cnS --argjson c "$PG_DISPATCH_DELIVERY_CONDITION" '{condition:$c,consecutive:null,state:"unavailable"}')" || return 1
  if pg_attempt_disposition_write github.com acme delivery 77 "$ROUND_KEY" "$RUN_MARKER" "$RUN_SPEND_EPOCH" \
       recovery-exhausted no-conversation-after-send "$unavailable"; then return 1; fi
  if pg_attempt_disposition_write github.com acme delivery 77 "$ROUND_KEY" "$RUN_MARKER" "$RUN_SPEND_EPOCH" \
       recovery-exhausted bounded-recovery-exhausted "$known"; then return 1; fi
  if pg_attempt_disposition_write github.com acme delivery 77 "$ROUND_KEY" "$RUN_MARKER" "$RUN_SPEND_EPOCH" \
       submitted-terminal exact-owned-infrastructure-terminal "$known"; then return 1; fi
  [ ! -e "$(pg_attempt_disposition_dir)/$RUN_MARKER" ] && pg_round_has_epoch "$ROUND_KEY" "$RUN_SPEND_EPOCH"
}
no_conversation_cleanup_interruption(){
  setup no-conversation-interrupted && charge || return 1
  local saved before
  saved="$(declare -f pg_round_unrecord_epoch)"
  pg_round_unrecord_epoch(){ return 1; }
  if pg_fresh_dispatch_release_no_conversation; then return 1; fi
  pg_round_has_epoch "$ROUND_KEY" "$RUN_SPEND_EPOCH" \
    && jq -e '.state=="cleanup-pending"' <<<"$(attempt_snapshot)" >/dev/null || return 1
  before="$(disposition_digest)" || return 1
  eval "$saved"
  pg_fresh_dispatch_release_no_conversation && assert_no_conversation_refunded 1 \
    && assert_disposition_unchanged "$before"
}
no_conversation_decisions(){
  setup no-conversation-decisions && decision_fixture
  PRO_GATE_ROUND_GUARD=1 PRO_GATE_ROUNDS_BASE=3
  pg_fresh_dispatch_recheck || return 1
  # The #246 shape: sends that produced no conversation, each under a changed condition, spend none
  # of the enforced three-round cap, so the next query still grants a review.
  local policy
  for policy in auto never always; do
    PRO_GATE_BROWSER_ATTACHMENTS="$policy"
    no_conversation && assert_no_conversation_refunded 1 || return 1
  done
  RUN_MARKER=""
  pg_fresh_dispatch_recheck || { printf 'unexpected decision: %s\n' "$PG_FRESH_DECISION"; return 1; }
  # Two in a row under one unchanged condition stop typed instead of spending more.
  no_conversation && assert_no_conversation_refunded 2 || return 1
  RUN_MARKER=""
  if pg_fresh_dispatch_recheck; then return 1; fi
  jq -e '.action=="stop-without-new-review" and .reason=="delivery-failed-unchanged" and .facts.delivery.failed_unchanged==2' \
    <<<"$PG_FRESH_DECISION" >/dev/null || { printf 'unexpected decision: %s\n' "$PG_FRESH_DECISION"; return 1; }
}

run_case 'no-conversation send with known evidence refunds its round and counts as a failed delivery' no_conversation_chain
run_case 'proven no-sends and no-conversation sends share one failed-delivery count' no_send_and_no_conversation_share_count
run_case 'no-conversation send with an unknown Oracle build keeps its round and no delivery stop' no_conversation_unknown_build_keeps_round
run_case 'only a no-conversation send may carry delivery evidence past not-submitted, and only known' no_conversation_v2_requires_known_evidence
run_case 'crash before the no-conversation refund reconciles without rewriting evidence' no_conversation_cleanup_interruption
run_case 'no-conversation sends spend no enforced round; two unchanged stop typed' no_conversation_decisions
run_case 'known no-send chain persists, refunds, and replays idempotently' known_chain
run_case 'excluding a published current disposition exposes its predecessor' exclude_published_current
run_case 'cleanup and recorder replay retain immutable published count and components' published_snapshot_replay
run_case 'superseded SENT predecessor breaks v2 failure streak while current attempt is excluded' superseded_sent_predecessor
run_case 'oversized and FIFO dispositions cannot provide fallback ordering evidence' bounded_disposition_read
run_case 'disposition read failure wins even after complete valid stdout' disposition_read_status
run_case 'sidecar link failure cannot lose durable evidence or block proven refund' sidecar_write_fault
run_case 'valid v2 evidence survives corrupt and inaccessible compatibility storage' v2_ignores_sidecar_damage
run_case 'legacy read EIO overrides even syntactically valid emitted bytes' legacy_read_fault
run_case 'a broken legacy store is unavailable, not absent history' legacy_broken_store
run_case 'legacy directory enumeration failure is unavailable' legacy_list_fault
run_case 'v1 missing sidecar is explicit legacy-untracked; next no-send retains uncertainty' legacy_absent_then_no_send
run_case 'failed prior-history acquisition records unavailable and still refunds' history_acquisition_fault
run_case 'malformed acquired history records unavailable and still refunds' malformed_history
run_case 'failed comparison records unavailable and still refunds' comparison_fault
run_case 'unserializable delivery snapshot preserves charge rather than falling back to v1' serialization_fault
run_case 'failed disposition publication preserves charge and recovery ownership' disposition_publish_fault
run_case 'crash after disposition before refund reconciles without rewriting evidence' cleanup_interruption
run_case 'crash after refund retries slot cleanup without refunding a later charge' post_refund_interruption
run_case 'unknown-to-known Oracle alone cannot reset an unknown historical build' unknown_build
run_case 'failed current version command cannot turn its stdout into build evidence' current_build_failure
run_case 'known relation/input/policy changes recover without Oracle probes' component_changes
run_case 'unknown components do not masquerade as changes; a known policy change recovers' unknown_components
run_case 'terminal evidence uses attempt-time policy, input and Oracle build' attempt_time_components
run_case 'v1 sidecars remain readable without treating unknown build as changed' legacy_known_and_unknown
run_case 'new Cloudflare is not a delivery failure and supersedes older damaged payloads' cloudflare_and_ordering
run_case 'a newer sent terminal attempt supersedes an older damaged delivery payload' sent_breaks_history
run_case 'missing, malformed and truncated v2 records never disappear into a fresh grant' malformed_v2
run_case 'access lost after the checked listing keeps damaged history unavailable' listed_history_access_lost
run_case 'multiple JSON snapshots are refused and previous contract bindings stay valid' single_json_and_binding
run_case 'multiple legacy JSON records cannot hide corruption behind a final valid value' legacy_multiple_json
run_case 'symlinked disposition cannot supply ordering evidence' symlink_disposition
run_case 'ordinary query with no failed delivery does not probe Oracle' no_history_no_probe
run_case 'FORCE bypasses known count only; legacy compatibility remains explicit' reducer_force_and_legacy
run_case 'saved grants stop at every real effect recheck before browser or spend' effect_recheck
run_case 'effect boundary preserves typed cooldown reason and deferred exit 8' cooldown_boundary
if [ "$FAILURES" -ne 0 ]; then printf '%s delivery disposition case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf 'ALL PASS: delivery disposition faults\n'
