#!/usr/bin/env bash
# #262: the real classifier and terminal ledger writer, isolated from browser/account IO.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-template-verdict.XXXXXX")"
trap '[ -z "${MOCK_PID:-}" ] || kill "$MOCK_PID" 2>/dev/null; rm -rf "$TDIR"' EXIT
export PRO_GATE_HOME="$TDIR/home" PRO_GATE_LEDGER="$TDIR/ledger.jsonl"
mkdir -p "$PRO_GATE_HOME" "$TDIR/work"
. "$ROOT/lib/pro-gate-lib.sh"
FAILS=0 CHECKS=0
check() {
  CHECKS=$((CHECKS + 1))
  if [ "$2" = 0 ]; then echo "ok - $1"; else echo "FAIL - $1"; FAILS=$((FAILS + 1)); fi
}
for name in pg_preserve_rejected_capture pg_check_review_shape pg_require_review_shape pg_finish; do
  eval "$(awk -v name="$name" '$0 ~ "^" name "\\(\\)" {p=1} p{print} p && /^}/{exit}' "$ROOT/bin/oracle-review.sh")"
done
# Only lifecycle effects are stubbed; classification, bytes, hashing and ledger JSON are real.
pg_status() { PG_FAIL_DETAIL="${2:-}"; }
pg_organizer_join() { :; }
pg_organize_chat() { :; }
pg_ramp_update() { printf '%s\n' "$*" >> "$TDIR/ramp-calls"; }
pg_active_clear() { :; }
pg_model_label() { echo fixture; }
WORK="$TDIR/work" OUT="$TDIR/out.md" RUN_START="$(date +%s)" LAUNCH_EPOCH=""
RUN_MARKER=pg-run-acme-review-262-1791683605-1 ROUND_KEY=acme-review-262 PR_NUM=262
DIFF_FILE="$ROOT/tests/fixtures/template-verdict/review.diff"
pg_review_tokens_write "$RUN_MARKER" "$DIFF_FILE"
TOKENS="$(pg_review_tokens_dir)/$RUN_MARKER"

# Exact retained bodies for #4451 (pg-run-StartupBros-com-pushbot-4451-1791683605-982808)
# and #4445 (pg-run-StartupBros-com-pushbot-4445-1791688070-728692), copied byte-for-byte.
cp "$ROOT/tests/fixtures/template-verdict/pushbot-4445.txt" "$TDIR/54.md"
cp "$ROOT/tests/fixtures/template-verdict/pushbot-4451.txt" "$TDIR/159.md"
for size in 54 159; do
  pg_review_shape "$TDIR/$size.md" "$TOKENS"; rc=$?
  check "reported $size-byte skeleton names nothing" "$([ "$rc" = 1 ] && [ "$PG_NAMES_NOTHING" = true ] && [ "$PG_BODY_BYTES" = "$size" ]; echo $?)"
done
printf 'P0: none / P1: none / P2: none / P3: none / VERDICT: SHIP\n' > "$TDIR/inline.md"
pg_review_shape "$TDIR/inline.md" "$TOKENS"; rc=$?
check 'one-line skeleton is rejected' "$([ "$rc" = 1 ] && [ "$PG_NAMES_NOTHING" = true ]; echo $?)"

review() { printf 'P0: none\nP1: none\nP2: none\nP3: none\n\n%s\n\nVERDICT: SHIP\n' "$1" > "$OUT"; }
pg_review_shape "$ROOT/tests/fixtures/template-verdict/compliant-clean.txt" "$TOKENS"
check 'P1-a: compliant clean review with a separate rationale is accepted' "$?"
for rationale in 'Checked src/review-engine.ts:22 for failure handling.' 'Checked classifyReview for failure handling.' 'Checked policy_name for failure handling.' 'Checked review-engine.ts for failure handling.' 'Checked review-engine.ts:22-40 for failure handling.' 'Checked src/review-engine.ts:22-40 for failure handling.' 'Checked classifyReview:22-40 for failure handling.'; do
  review "$rationale"
  pg_review_shape "$OUT" "$TOKENS"; rc=$?
  check "token overlap: $rationale" "$([ "$rc" = 0 ]; echo $?)"
done
for rationale in 'tests clean function migration' 'Checked inventedIdentifier for regressions.' 'Checked src/not-reviewed.ts.' 'Checked classifyReviewExtra.' 'Checked not-reviewed.ts:22-40.' 'Checked src/not-reviewed.ts:22-40.' 'Checked classifyReviewExtra:22-40.' 'Checked review-engine.ts:22-40-extra.'; do
  review "$rationale"
  pg_review_shape "$OUT" "$TOKENS"; rc=$?
  check "no invented/plain/substr token credit: $rationale" "$([ "$rc" = 1 ] && [ "$PG_NAMES_NOTHING" = true ]; echo $?)"
done
printf 'P0: none classifyReview\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP — ordinary explanation.\n' > "$OUT"
pg_review_shape "$OUT" "$TOKENS"; rc=$?
check 'severity-label names and plain-English verdict reasons do not establish rationale' "$([ "$rc" = 1 ] && [ "$PG_NAMES_NOTHING" = true ]; echo $?)"
# Gate r1 P2: the verdict line is excluded whole, so a diff path appended to it is still the
# skeleton; the same path in its own paragraph beside a reasoned verdict line passes.
for verdict_line in 'VERDICT: SHIP — Checked src/review-engine.ts for failure handling.' 'VERDICT: SHIP — reviewed src/review-engine.ts' '**VERDICT:** SHIP (src/review-engine.ts:22, classifyReview)' 'VERDICT: SHIP — reviewed review-engine.ts:22-40'; do
  printf 'P0: none\nP1: none\nP2: none\nP3: none\n%s\n' "$verdict_line" > "$OUT"
  pg_review_shape "$OUT" "$TOKENS"; rc=$?
  check "gate r1 P2: a diff reference only on the verdict line does not establish rationale: $verdict_line" "$([ "$rc" = 1 ] && [ "$PG_NAMES_NOTHING" = true ]; echo $?)"
done
printf 'P0: none\nP1: none\nP2: none\nP3: none\n\nChecked classifyReview for failure handling.\n\nVERDICT: SHIP — reviewed src/review-engine.ts\n' > "$OUT"
pg_review_shape "$OUT" "$TOKENS"; rc=$?
check 'gate r1 P2: a separate grounded paragraph still passes beside a reasoned verdict line' "$([ "$rc" = 0 ] && [ "$PG_NAMES_NOTHING" = false ]; echo $?)"
check 'P1-a: prompt requires a separate grounded clean-review paragraph' "$(grep -qF 'If there are no findings, include a short rationale paragraph' "$ROOT/bin/oracle-review.sh" && ! grep -qF 'output ONLY findings, nothing else' "$ROOT/bin/oracle-review.sh"; echo $?)"

# Gate r1 P1: a completion bound before retained vocabulary (every pre-0.62.0 input binding) has
# neither tokens nor a manifest left on disk. It is judged on its own shape; a binding written
# by this engine, or no binding at all, keeps the full requirement.
shape_binding() { # marker contract-digest
  jq -cnS --arg cd "$2" --arg marker "$1" '{charged_spend_epoch:1700000000,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:"full-pr:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",mode:"full-pr",proof:{base_oid:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",endpoint_digest:"2222222222222222222222222222222222222222222222222222222222222222",head_oid:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",raw_patch_digest:"1111111111111111111111111111111111111111111111111111111111111111"}},marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"review"},target:{head_oid:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",kind:"pull-request",pr:262}}'
}
PRE_MARKER=pg-run-acme-review-262-1700000000-11 POST_MARKER=pg-run-acme-review-262-1700000000-12 UNBOUND_MARKER=pg-run-acme-review-262-1700000000-13
VOCAB_MARKER=pg-run-acme-review-262-1700000000-14
VOCABULARY_CONTRACT_DIGEST=246b9e4e1d58f1820b4381a90cf93cf3fb7fb849f3ce4dd34b4d757be79c2e4f
PRE_VOCABULARY_EXPECTED='bf36fdb5f8625e917be0539ca014fec518649d1160584846aca1cb9149533abb 7f5ece9bfa5aa19f858431da23302a9bc02a4a8f5770830d529f22484e5982ee 5fcd19c12600061af6d90ed9cb980dd7067cff199c374910639003eec4caf5c3 6da6866bab4e95ad138cdc946fa1388be9c386bca7b592c3370c9f52e34b315f fa91787e3fbf3c0852c78f5269b2f670d84b86561be64d6edef4229bf46aee9b'
pg_review_input_binding_write "$PRE_MARKER" "$(shape_binding "$PRE_MARKER" fa91787e3fbf3c0852c78f5269b2f670d84b86561be64d6edef4229bf46aee9b)"
pg_review_input_binding_write "$POST_MARKER" "$(shape_binding "$POST_MARKER" "$(pg_review_decision_contract_digest)")"
pg_review_input_binding_write "$VOCAB_MARKER" "$(shape_binding "$VOCAB_MARKER" "$VOCABULARY_CONTRACT_DIGEST")"
check 'gate r1 P1: the pre-vocabulary digest list stays frozen to the five pre-0.62.0 digests' \
  "$([ "$(printf '%s\n' $PG_REVIEW_PRE_VOCABULARY_CONTRACT_DIGESTS | LC_ALL=C sort | paste -sd' ')" = "$(printf '%s\n' $PRE_VOCABULARY_EXPECTED | LC_ALL=C sort | paste -sd' ')" ] \
    && ! printf '%s\n' $PG_REVIEW_PRE_VOCABULARY_CONTRACT_DIGESTS | grep -qxF "$(pg_review_decision_contract_digest)" \
    && ! printf '%s\n' $PG_REVIEW_PRE_VOCABULARY_CONTRACT_DIGESTS | grep -qxF "$VOCABULARY_CONTRACT_DIGEST"; echo $?)"
review 'Checked src/review-engine.ts for failure handling.'
pg_review_shape_for_marker "$PRE_MARKER" "$OUT" 2>/dev/null; rc=$?
check 'gate r1 P1: a pre-vocabulary grounded completion is accepted without tokens or manifest' "$([ "$rc" = 0 ] && [ "$PG_NAMES_NOTHING" = false ]; echo $?)"
for size in 54 159; do
  pg_review_shape_for_marker "$PRE_MARKER" "$TDIR/$size.md" 2>/dev/null; rc=$?
  check "gate r1 P1: a pre-vocabulary $size-byte skeleton is still refused" "$([ "$rc" = 6 ] && [ "$PG_NAMES_NOTHING" = true ]; echo $?)"
done
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP — reviewed src/review-engine.ts\n' > "$OUT"
pg_review_shape_for_marker "$PRE_MARKER" "$OUT" 2>/dev/null; rc=$?
check 'gate r1 P1: a pre-vocabulary verdict-line-only citation is still refused' "$([ "$rc" = 6 ]; echo $?)"
review 'Checked src/review-engine.ts for failure handling.'
pg_review_shape_for_marker "$POST_MARKER" "$OUT" 2>/dev/null; rc=$?
check 'gate r1 P1: a current-contract completion without retained vocabulary stays refused' "$([ "$rc" = 6 ]; echo $?)"
pg_review_shape_for_marker "$VOCAB_MARKER" "$OUT" 2>/dev/null; rc=$?
check 'gate r1 P1: a released 0.62.0 completion without retained vocabulary stays refused' "$([ "$rc" = 6 ]; echo $?)"
pg_review_tokens_write "$VOCAB_MARKER" "$DIFF_FILE"
pg_review_shape_for_marker "$VOCAB_MARKER" "$OUT" 2>/dev/null; rc=$?
check 'gate r1 P1: a released 0.62.0 binding remains readable with matching retained vocabulary' "$([ "$rc" = 0 ]; echo $?)"
pg_review_shape_for_marker "$UNBOUND_MARKER" "$OUT" 2>/dev/null; rc=$?
check 'gate r1 P1: a completion with no input binding stays refused' "$([ "$rc" = 6 ]; echo $?)"
review 'Checked src/not-reviewed.ts for failure handling.'
pg_review_shape_for_marker "$PRE_MARKER" "$OUT" 2>/dev/null; rc=$?
check 'gate r1 P1: without vocabulary a pre-vocabulary citation cannot be checked against the diff' "$([ "$rc" = 0 ]; echo $?)"
pg_review_tokens_write "$PRE_MARKER" "$DIFF_FILE"
pg_review_shape_for_marker "$PRE_MARKER" "$OUT" 2>/dev/null; rc=$?
check 'gate r1 P1: retained vocabulary outranks the pre-vocabulary fallback' "$([ "$rc" = 6 ] && [ "$PG_NAMES_NOTHING" = true ]; echo $?)"
cat > "$TDIR/deleted.diff" <<'DIFF'
diff --git a/src/deleted.ts b/src/deleted.ts
index abc1234..def5678 100644
--- a/src/deleted.ts
+++ b/src/deleted.ts
@@ -1 +0,0 @@
-readPolicy();
DIFF
pg_review_tokens "$TDIR/deleted.diff" > "$TDIR/deleted.tokens"
review 'Checked readPolicy.'
pg_review_shape "$OUT" "$TDIR/deleted.tokens"; rc=$?
check 'P2-a: removed identifier matches without the deletion prefix' "$([ "$rc" = 0 ]; echo $?)"
sed 's/readPolicy/otherPolicy/' "$TDIR/deleted.diff" > "$TDIR/other.diff"
pg_review_tokens "$TDIR/other.diff" > "$TDIR/other.tokens"
pg_review_shape "$OUT" "$TDIR/other.tokens"; rc=$?
check 'P2-a: identifier absent from the diff still rejects' "$([ "$rc" = 1 ]; echo $?)"
cat > "$TDIR/hunk-context.diff" <<'DIFF'
@@ -10,3 +10,3 @@ function readPolicy() {
-0
+1
DIFF
pg_review_tokens "$TDIR/hunk-context.diff" > "$TDIR/hunk-context.tokens"
review 'Checked readPolicy for regressions.'
pg_review_shape "$OUT" "$TDIR/hunk-context.tokens"; rc=$?
check 'round 2: hunk-context identifier grounds a clean review' "$([ "$rc" = 0 ] && [ "$PG_NAMES_NOTHING" = false ]; echo $?)"
review 'Checked otherPolicy for regressions.'
pg_review_shape "$OUT" "$TDIR/hunk-context.tokens"; rc=$?
check 'round 2: absent hunk-context identifier still rejects' "$([ "$rc" = 1 ] && [ "$PG_NAMES_NOTHING" = true ]; echo $?)"
sed 's/@@ function readPolicy() {/@@/' "$TDIR/hunk-context.diff" > "$TDIR/headerless.diff"
pg_review_tokens "$TDIR/headerless.diff" > "$TDIR/headerless.tokens"
check 'round 2: hunk header without context contributes no tokens' "$([ ! -s "$TDIR/headerless.tokens" ]; echo $?)"
printf 'diff --git a/VERSION b/VERSION\n--- a/VERSION\n+++ b/VERSION\n@@ -1 +1 @@\n-0.61.2\n+0.62.0\n' > "$TDIR/version.diff"
pg_review_tokens "$TDIR/version.diff" > "$TDIR/version.tokens"
review 'Checked VERSION for release consistency.'
pg_review_shape "$OUT" "$TDIR/version.tokens"; rc=$?
check 'P1-a: VERSION-only changes can be cited by path' "$([ "$rc" = 0 ]; echo $?)"
review 'Checked classifyReview; café paths remain safe.'
pg_review_shape "$OUT" "$TOKENS"
check 'body_bytes counts UTF-8 bytes, not characters' "$([ "$PG_BODY_BYTES" = "$(wc -c < "$OUT" | tr -d '[:space:]')" ]; echo $?)"

ledger_run() { # body, expected exit (the unguarded pg_finish 0 also must refuse templates)
  cp "$1" "$OUT"
  ( PG_FINAL_SRC="$OUT" PG_KEEP_FINAL=1 PG_PRESERVE_STATE=1 PG_RESULT_DURABLE=1 RESULT_PATH="$OUT" HARVEST=1 SALVAGED=1
    pg_finish 0 ) > "$TDIR/run.stdout" 2> "$TDIR/run.stderr"
  rc=$?
  check "ledger writer exits $2 for $(basename "$1")" "$([ "$rc" = "$2" ]; echo $?)"
}
ledger_run "$TDIR/54.md" 6
ledger_run "$TDIR/159.md" 6
check 'templates never write clean ledger rows' "$(jq -se 'length==2 and all(.[]; .outcome=="template-verdict" and .exit==6 and .names_nothing==true and .salvaged==1) and ([.[].body_bytes]==[54,159])' "$PRO_GATE_LEDGER" >/dev/null; echo $?)"
for rationale in 'Checked src/review-engine.ts:22 for failure handling.' 'Checked classifyReview for failure handling.'; do
  review "$rationale"; cp "$OUT" "$TDIR/real.md"
  ledger_run "$TDIR/real.md" 0
  check 'real review writes clean with byte count and boolean' "$(tail -1 "$PRO_GATE_LEDGER" | jq -e --argjson bytes "$(wc -c < "$OUT")" '.outcome=="clean" and .exit==0 and .names_nothing==false and .body_bytes==$bytes and has("diff_lines") and has("sha256") and has("reason") and has("detail")' >/dev/null; echo $?)"
done
DIFF_FILE="" PG_REVIEW_TOKENS_FILE=""
pg_check_review_shape "$OUT"
check 'later harvest uses retained diff tokens without refetch' "$?"
legacy_replay() (
  RUN_MARKER=pg-run-legacy-262-1791683605-9 DIFF_FILE="" PG_REVIEW_TOKENS_FILE=""
  mkdir -p "$(pg_manifest_dir)"
  pg_diff_paths "$ROOT/tests/fixtures/template-verdict/review.diff" > "$(pg_manifest_dir)/$RUN_MARKER"
  review 'Checked src/review-engine.ts for failure handling.'
  pg_check_review_shape "$OUT" || return 1
  rm "$(pg_manifest_dir)/$RUN_MARKER"
  PG_REVIEW_TOKENS_FILE=""
  pg_check_review_shape "$OUT"
)
legacy_replay
check 'legacy path-manifest collection remains replayable after manifest cleanup' "$?"
pg_salvage_class_write "$RUN_MARKER" template-verdict
check 'salvage sidecar round-trips the typed outcome' "$([ "$(pg_salvage_class_read "$RUN_MARKER" | cut -f1)" = template-verdict ]; echo $?)"
stats="$(bash "$ROOT/bin/pro-gate-stats.sh" --json)"
check 'stats preserves new fields and template outcome' "$(jq -e '[.runs[] | select(.outcome=="template-verdict" and .names_nothing==true and .body_bytes>0)] | length==2' <<<"$stats" >/dev/null; echo $?)"
summary="$(bash "$ROOT/bin/pro-gate-stats.sh" | sed -n '/^{/,$p')"
check 'stats counts the names_nothing rate' "$(jq -e '.names_nothing==2 and .names_nothing_rate_pct==50 and .by_outcome["template-verdict"]==2' <<<"$summary" >/dev/null; echo $?)"
saved_have="$(declare -f pg_have)"
pg_have() { [ "$1" != jq ] && command -v "$1" >/dev/null 2>&1; }
ledger_run "$TDIR/54.md" 6
eval "$saved_have"
check 'fallback ledger JSON also carries bytes and the boolean flag' "$(tail -1 "$PRO_GATE_LEDGER" | jq -e '.outcome=="template-verdict" and .body_bytes==54 and .names_nothing==true' >/dev/null; echo $?)"
pg_ledger_append '{"marker":"pg-run-flagged-262-1791683605-2","outcome":"clean","out":"refuse.md","sha256":"abc","names_nothing":true,"body_bytes":54}'
check 'clean-result lookup refuses an explicitly flagged row' "$([ -z "$(pg_ledger_lookup_clean pg-run-flagged-262-1791683605-2)" ]; echo $?)"

# A diagnostic from an earlier capture must not overwrite deferred recovery or train the ramp.
: > "$TDIR/ramp-calls"
( TEMPLATE_VERDICT=1 HARVEST=0 PG_PRESERVE_STATE=1 SALVAGE_PRESERVE=1; pg_finish 9 ) > "$TDIR/deferred.stdout" 2> "$TDIR/deferred.stderr"
rc=$?
check 'P2-b: deferred skeleton records in-progress and leaves ramp unchanged' "$([ "$rc" = 9 ] && [ ! -s "$TDIR/ramp-calls" ] && tail -1 "$PRO_GATE_LEDGER" | jq -e '.exit==9 and .outcome=="in-progress"' >/dev/null; echo $?)"

# Exercise the actual wrapper with the same mock CDP endpoint as the engine suite.
printf 'run marker: %s\nP0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP (run marker: %s)\n' "$RUN_MARKER" "$RUN_MARKER" > "$TDIR/tab.txt"
node "$ROOT/tests/mock-cdp.mjs" "$TDIR/tab.txt" > "$TDIR/port" 2> "$TDIR/cdp.log" &
MOCK_PID=$!
for _ in $(seq 1 100); do [ -s "$TDIR/port" ] && break; sleep 0.1; done
ENGINE_HOME="$TDIR/engine-home"
mkdir -p "$ENGINE_HOME/review-tokens"
cp "$TOKENS" "$ENGINE_HOME/review-tokens/$RUN_MARKER"
env PRO_GATE_HOME="$ENGINE_HOME" PRO_GATE_LEDGER="$TDIR/engine-ledger.jsonl" \
  ORACLE_BROWSER_PORT="$(cat "$TDIR/port")" PRO_GATE_BROWSER_MODE=remote-chrome \
  PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_CHAT_RENAME=0 PRO_GATE_KEEP_TABS=1 \
  bash "$ROOT/bin/oracle-review.sh" --harvest "$RUN_MARKER" --out "$TDIR/harvest.md" --timeout 1s \
  > "$TDIR/harvest.stdout" 2> "$TDIR/harvest.stderr"
rc=$?
check 'real harvest rejects a final skeleton with exit 6' "$([ "$rc" = 6 ]; echo $?)"
check 'real harvest records typed outcome, bytes and flag without a clean row' "$(jq -se 'length==1 and all(.[]; .outcome=="template-verdict" and .exit==6 and .body_bytes>0 and .names_nothing==true)' "$TDIR/engine-ledger.jsonl" >/dev/null; echo $?)"
check 'real harvest publishes neither result nor completed artifact' "$([ ! -s "$TDIR/harvest.md" ] && [ ! -e "$ENGINE_HOME/completed/$RUN_MARKER" ] && ! grep -q RESULT_FILE "$TDIR/harvest.stdout"; echo $?)"
check '#271: rejected skeleton bytes survive harvest for inspection' "$(grep -lF 'VERDICT: SHIP' "$TDIR"/harvest.md.rejected.* >/dev/null 2>&1; echo $?)"
mkdir "$TDIR/default-work"
env PRO_GATE_HOME="$ENGINE_HOME" PRO_GATE_LEDGER="$TDIR/default-ledger.jsonl" TMPDIR="$TDIR/default-work" \
  ORACLE_BROWSER_PORT="$(cat "$TDIR/port")" PRO_GATE_BROWSER_MODE=remote-chrome \
  PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_CHAT_RENAME=0 PRO_GATE_KEEP_TABS=1 \
  bash "$ROOT/bin/oracle-review.sh" --harvest "$RUN_MARKER" --timeout 1s \
  > "$TDIR/default.stdout" 2> "$TDIR/default.stderr"
rc=$?
default_capture="$(find "$TDIR/default-work" -name 'findings.md.rejected.*' -print -quit)"
check '#271: default output cleanup retains rejected bytes too' "$([ "$rc" = 6 ] && [ -s "$default_capture" ] && grep -qF 'VERDICT: SHIP' "$default_capture"; echo $?)"

mkdir "$TDIR/storage-work"
long_out="$TDIR/$(printf '%0245d' 0)"
env PRO_GATE_HOME="$ENGINE_HOME" PRO_GATE_LEDGER="$TDIR/storage-ledger.jsonl" TMPDIR="$TDIR/storage-work" \
  ORACLE_BROWSER_PORT="$(cat "$TDIR/port")" PRO_GATE_BROWSER_MODE=remote-chrome \
  PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_CHAT_RENAME=0 PRO_GATE_KEEP_TABS=1 \
  bash "$ROOT/bin/oracle-review.sh" --harvest "$RUN_MARKER" --out "$long_out" --timeout 1s \
  > "$TDIR/storage.stdout" 2> "$TDIR/storage.stderr"
rc=$?
private_capture="$(find "$TDIR/storage-work" -name harvest.capture -print -quit)"
check '#271: rejected-output storage failure preserves private evidence' "$([ "$rc" = 3 ] && [ -s "$private_capture" ] && grep -qF 'VERDICT: SHIP' "$private_capture" && ! grep -q RESULT_FILE "$TDIR/storage.stdout"; echo $?)"

# Retaining rejected bytes must not release recovery ownership or refund a charge.
# Ungrounded, missing/foreign, stale and incomplete answers retain their existing protection.
serial=40
for ownership in owned foreign missing stale skeleton; do
  serial=$((serial + 1))
  reject_home="$TDIR/rejected-$ownership"
  PRO_GATE_HOME="$reject_home" pg_round_record "$ROUND_KEY"
  reject_epoch="$PG_ROUND_SPEND_EPOCH"
  reject_marker="pg-run-$ROUND_KEY-$reject_epoch-$serial"
  reject_out="$TDIR/rejected-$ownership.md"
  PRO_GATE_HOME="$reject_home" pg_run_meta_write "$reject_marker" github.com acme review "$ROUND_KEY" 262 "$reject_out" "$reject_epoch"
  PRO_GATE_HOME="$reject_home" pg_reservation_write "$reject_marker" "$ROUND_KEY" "$reject_out" "" fixture "$reject_epoch"
  PRO_GATE_HOME="$reject_home" pg_review_tokens_write "$reject_marker" "$ROOT/tests/fixtures/template-verdict/review.diff"
  reject_binding="$(shape_binding "$reject_marker" "$(pg_review_decision_contract_digest)" | jq -cS --argjson epoch "$reject_epoch" '.charged_spend_epoch=$epoch')"
  PRO_GATE_HOME="$reject_home" pg_review_input_binding_write "$reject_marker" "$reject_binding"
  case "$ownership" in
    owned|stale|skeleton) echo_marker=" (run marker: $reject_marker)" ;;
    foreign) echo_marker=' (run marker: pg-run-acme-other-999-1700000000-7)' ;;
    missing) echo_marker='' ;;
  esac
  {
    printf 'P0: none\nP1: none\nP2: none\nP3: none\n'
    [ "$ownership" = skeleton ] || printf '\nChecked unrelatedIdentifier for regressions.\n\n'
    printf 'VERDICT: SHIP%s\n' "$echo_marker"
  } > "$TDIR/rejected-expected.md"
  {
    printf 'run marker: %s\n' "$reject_marker"
    cat "$TDIR/rejected-expected.md"
    [ "$ownership" != stale ] || printf '\nNew prompt: run marker: %s\n' "$reject_marker"
  } > "$TDIR/tab.txt"
  env PRO_GATE_HOME="$reject_home" PRO_GATE_LEDGER="$reject_home/ledger.jsonl" \
    ORACLE_BROWSER_PORT="$(cat "$TDIR/port")" PRO_GATE_BROWSER_MODE=remote-chrome \
    PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_CHAT_RENAME=0 PRO_GATE_KEEP_TABS=1 \
    bash "$ROOT/bin/oracle-review.sh" --harvest "$reject_marker" --out "$reject_out" --timeout 1s \
    > "$TDIR/rejected-$ownership.stdout" 2> "$TDIR/rejected-$ownership.stderr"
  rc=$?
  check "#271: $ownership rejection never publishes approval" "$([ ! -e "$reject_out" ] && [ ! -e "$reject_home/completed/$reject_marker" ] && ! grep -q RESULT_FILE "$TDIR/rejected-$ownership.stdout"; echo $?)"
  check "#271: $ownership capture cannot release or refund a charged attempt" "$([ "$rc" != 0 ] && [ ! -e "$reject_home/attempt-dispositions/$reject_marker" ] && [ -s "$reject_home/in-progress/$reject_marker" ] && PRO_GATE_HOME="$reject_home" pg_round_has_epoch "$ROUND_KEY" "$reject_epoch"; echo $?)"
  check "#271: $ownership rejection preserves its input binding" "$([ "$(PRO_GATE_HOME="$reject_home" pg_review_input_binding_read "$reject_marker")" = "$reject_binding" ]; echo $?)"
  if [ "$ownership" = owned ]; then
    kept_capture="$(find "$TDIR" -maxdepth 1 -name "rejected-$ownership.md.rejected.*" -print -quit)"
    check '#271: retained rejected terminal matches the extracted bytes' "$(cmp -s "$TDIR/rejected-expected.md" "$kept_capture"; echo $?)"
  fi
done
serial=1
for name in 'src/review-engine.ts:22' classifyReview 'review-engine.ts:22-40' 'src/review-engine.ts:22-40'; do
  serial=$((serial + 1)); RUN_MARKER="pg-run-acme-review-262-1791683605-$serial"
  cp "$TOKENS" "$ENGINE_HOME/review-tokens/$RUN_MARKER"
  printf 'run marker: %s\nP0: none\nP1: none\nP2: none\nP3: none\nChecked %s for failure handling.\nVERDICT: SHIP (run marker: %s)\n' "$RUN_MARKER" "$name" "$RUN_MARKER" > "$TDIR/tab.txt"
  env PRO_GATE_HOME="$ENGINE_HOME" PRO_GATE_LEDGER="$TDIR/engine-ledger.jsonl" \
    ORACLE_BROWSER_PORT="$(cat "$TDIR/port")" PRO_GATE_BROWSER_MODE=remote-chrome \
    PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_CHAT_RENAME=0 PRO_GATE_KEEP_TABS=1 \
    bash "$ROOT/bin/oracle-review.sh" --harvest "$RUN_MARKER" --out "$TDIR/harvest.md" --timeout 2s \
    > "$TDIR/harvest.stdout" 2> "$TDIR/harvest.stderr"
  rc=$?
  check "real harvest accepts diff reference $name" "$([ "$rc" = 0 ] && grep -qF "$name" "$TDIR/harvest.md" && tail -1 "$TDIR/engine-ledger.jsonl" | jq -e --argjson bytes "$(wc -c < "$TDIR/harvest.md")" '.outcome=="clean" and .names_nothing==false and .body_bytes==$bytes' >/dev/null; echo $?)"
done

# The primary capture must also take the ordinary guarded salvage path instead of succeeding
# on Oracle exit 0. The live marker probe suppresses a second submission of this conversation.
cat > "$TDIR/oracle-template" <<'ORACLE'
#!/usr/bin/env bash
case "${1:-}" in --version) echo fixture; exit 0;; session) exit 1;; esac
prompt=""; output=""
while [ "$#" -gt 0 ]; do
  case "$1" in -p) prompt="$2"; shift 2;; --write-output) output="$2"; shift 2;; *) shift;; esac
done
marker="$(printf '%s' "$prompt" | grep -oE 'pg-run-[A-Za-z0-9.-]+' | tail -1)"
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP (run marker: %s)\n' "$marker" > "$output"
{ printf 'run marker: %s\n' "$marker"; cat "$output"; } > "$TEMPLATE_TAB"
printf 'submitted\n' >> "$TEMPLATE_SUBMISSIONS"
[ -z "${TEMPLATE_OUTAGE_PID:-}" ] || kill "$TEMPLATE_OUTAGE_PID"
ORACLE
printf '#!/usr/bin/env bash\nexit 1\n' > "$TDIR/no-gh"
chmod +x "$TDIR/oracle-template" "$TDIR/no-gh"
env PRO_GATE_HOME="$TDIR/fresh-home" PRO_GATE_LEDGER="$TDIR/fresh-ledger.jsonl" \
  ORACLE_BROWSER_PORT="$(cat "$TDIR/port")" PRO_GATE_BROWSER_MODE=remote-chrome \
  PRO_GATE_ORACLE_BIN="$TDIR/oracle-template" PRO_GATE_GH_BIN="$TDIR/no-gh" \
  PRO_GATE_INPUT_POLICY=bundle-only PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_MIN_AVAIL_MB=0 PRO_GATE_MAX_SWAP_PCT=101 PRO_GATE_EARLY_PROBE_SECS=0 \
  PRO_GATE_CHAT_RENAME=0 PRO_GATE_KEEP_TABS=1 PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=1 \
  PRO_GATE_SALVAGE_SECS=1 PRO_GATE_REATTACH_TIMEOUT=1 PRO_GATE_TIMEOUT_GRACE=0 \
  PRO_GATE_TEST_MODE=ci-fixture PRO_GATE_TEST_PRE_RETRY_PROBE_SECS=1 \
  TEMPLATE_TAB="$TDIR/tab.txt" TEMPLATE_SUBMISSIONS="$TDIR/submissions" \
  bash "$ROOT/bin/oracle-review.sh" --diff "$ROOT/tests/fixtures/template-verdict/review.diff" \
    --repo "$TDIR" --out "$TDIR/fresh.md" --timeout 2s \
    > "$TDIR/fresh.stdout" 2> "$TDIR/fresh.stderr"
rc=$?
check 'fresh skeleton exits 6 after guarded salvage' "$([ "$rc" = 6 ]; echo $?)"
check 'fresh skeleton never records clean or dispatches a second submission' "$(jq -se 'length==1 and .[0].outcome=="template-verdict" and .[0].names_nothing==true and .[0].body_bytes>0' "$TDIR/fresh-ledger.jsonl" >/dev/null && [ "$(wc -l < "$TDIR/submissions")" = 1 ]; echo $?)"
env PRO_GATE_HOME="$TDIR/outage-home" PRO_GATE_LEDGER="$TDIR/outage-ledger.jsonl" \
  ORACLE_BROWSER_PORT="$(cat "$TDIR/port")" PRO_GATE_BROWSER_MODE=remote-chrome \
  PRO_GATE_ORACLE_BIN="$TDIR/oracle-template" PRO_GATE_GH_BIN="$TDIR/no-gh" \
  PRO_GATE_INPUT_POLICY=bundle-only PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_MIN_AVAIL_MB=0 PRO_GATE_MAX_SWAP_PCT=101 PRO_GATE_EARLY_PROBE_SECS=0 \
  PRO_GATE_CHAT_RENAME=0 PRO_GATE_KEEP_TABS=1 PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=1 \
  PRO_GATE_SALVAGE_SECS=1 PRO_GATE_REATTACH_TIMEOUT=1 PRO_GATE_TIMEOUT_GRACE=0 \
  PRO_GATE_TEST_MODE=ci-fixture PRO_GATE_TEST_PRE_RETRY_PROBE_SECS=1 \
  TEMPLATE_TAB="$TDIR/tab.txt" TEMPLATE_SUBMISSIONS="$TDIR/outage-submissions" TEMPLATE_OUTAGE_PID="$MOCK_PID" \
  bash "$ROOT/bin/oracle-review.sh" --diff "$ROOT/tests/fixtures/template-verdict/review.diff" \
    --repo "$TDIR" --out "$TDIR/outage.md" --timeout 2s \
    > "$TDIR/outage.stdout" 2> "$TDIR/outage.stderr"
rc=$?
check 'P2-b: primary skeleton then salvage outage exits 9 with in-progress ledger' "$([ "$rc" = 9 ] && jq -se 'length==1 and .[0].exit==9 and .[0].outcome=="in-progress" and .[0].names_nothing==true' "$TDIR/outage-ledger.jsonl" >/dev/null; echo $?)"
echo "$CHECKS checks, $FAILS failures"
[ "$FAILS" = 0 ] && { echo 'ALL PASS'; exit 0; }
exit 1
