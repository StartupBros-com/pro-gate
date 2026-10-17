#!/usr/bin/env bash
# Synthetic retained records exercise the installed public CLI, not live model quality or shipping.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-review-facts-test.XXXXXX")"
trap 'chmod -R u+rwX "$TDIR"; rm -rf "$TDIR"' EXIT
while IFS='=' read -r name _; do
  case "$name" in PRO_GATE_*|ORACLE_*) unset "$name" ;; esac
done < <(env)
export HOME="$TDIR/user" PRO_GATE_HOME="$TDIR/state"
mkdir -p "$HOME/.local/bin" "$TDIR/installed" "$TDIR/checkout" "$PRO_GATE_HOME/completed"
cp "$ROOT/bin/oracle-review.sh" "$TDIR/installed/oracle-review.sh"
cp "$ROOT/lib/pro-gate-lib.sh" "$TDIR/installed/lib.sh"
# Neither acceptance nor proof is mocked. Effects and external executables are forbidden sentinels.
cat > "$HOME/.local/bin/forbidden" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "${PG_FACTS_EFFECT_LOG:?}"
exit 99
STUB
chmod +x "$HOME/.local/bin/forbidden"
for name in gh oracle node curl timeout; do ln -s forbidden "$HOME/.local/bin/$name"; done
cat >> "$TDIR/installed/lib.sh" <<'TRAPS'
pg_facts_forbidden() { printf '%s\n' "$*" >> "${PG_FACTS_EFFECT_LOG:?}"; return 99; }
pg_lock() { pg_facts_forbidden lock; }
pg_round_guard() { pg_facts_forbidden round-guard; }
pg_round_record() { pg_facts_forbidden round-record; }
pg_attempt_snapshot() { pg_facts_forbidden lifecycle; }
pg_pr_metadata_fetch() { pg_facts_forbidden network-metadata; }
pg_review_decision_reduce() { pg_facts_forbidden decision; }
TRAPS
export PG_FACTS_EFFECT_LOG="$TDIR/effects" PATH="$HOME/.local/bin:$PATH"
export PRO_GATE_INPUT_POLICY=invalid-for-fresh PRO_GATE_BROWSER_ATTACHMENTS=invalid-for-fresh
export PRO_GATE_GH_BIN="$HOME/.local/bin/gh" PRO_GATE_ORACLE_BIN="$HOME/.local/bin/oracle"
export PRO_GATE_TIMEOUT_BIN="$HOME/.local/bin/timeout"
. "$ROOT/lib/pro-gate-lib.sh"
git -C "$TDIR/checkout" init -q
git -C "$TDIR/checkout" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm base
BASE="$(git -C "$TDIR/checkout" rev-parse HEAD)"
printf 'one\n' > "$TDIR/checkout/file.txt"
git -C "$TDIR/checkout" add file.txt
git -C "$TDIR/checkout" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm head
HEAD="$(git -C "$TDIR/checkout" rev-parse HEAD)"
git -C "$TDIR/checkout" remote add origin https://github.com/acme/widgets.git
git -C "$TDIR/checkout" diff "$BASE" "$HEAD" > "$TDIR/endpoint.patch"
RAW="$(pg_sha256 "$TDIR/endpoint.patch")"
METADATA="$(jq -cnS --arg base "$BASE" --arg head "$HEAD" '{repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{pr:1983,base_ref:"main",base_oid:$base,head_oid:$head}}')"
METADATA_DIGEST="$(pg_pr_evidence_metadata_digest "$(jq -cnS --argjson metadata "$METADATA" '{metadata:$metadata}')")"
jq -cnS --argjson metadata "$METADATA" --arg digest "$RAW" '{record_type:"review-pr-evidence/v1",record_version:1,patch_format:"github-compare-diff",metadata:$metadata,endpoint_digest:$digest}' > "$TDIR/pr-evidence.json"
MARKER=pg-run-acme-widgets-1983-1700000700-1
INPUT="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$MARKER" --arg base "$BASE" --arg head "$HEAD" --arg raw "$RAW" --arg md "$METADATA_DIGEST" '{charged_spend_epoch:1700000700,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("full-pr:"+$base+":"+$head),mode:"full-pr",proof:{base_oid:$base,head_oid:$head,endpoint_digest:$raw,raw_patch_digest:$raw,pr_metadata_digest:$md}},marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{head_oid:$head,kind:"pull-request",pr:1983}}')"
printf 'P0: none\nP1: none\nP2: none\nChecked file.txt for regressions.\nVERDICT: SHIP\n' > "$PRO_GATE_HOME/completed/$MARKER"
pg_review_tokens_write "$MARKER" "$TDIR/endpoint.patch"
DIGEST="$(pg_sha256 "$PRO_GATE_HOME/completed/$MARKER")"
RESULT="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$MARKER" --arg ib "$(pg_review_sha256_text "$INPUT")" --arg digest "$DIGEST" --arg base "$BASE" --arg head "$HEAD" --arg raw "$RAW" '{accepted_epoch:1700000800,artifact:{digest:$digest,path:("completed/"+$marker)},contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,input_binding_digest:$ib,input_binding_identity:$marker,marker:$marker,named_choice:null,provenance:{outcome:"accepted",validated_epoch:1700000800},record_type:"review-result-binding/v1",record_version:1,ship_proof:{base_oid:$base,head_oid:$head,diff_digest:$raw},verdict:"SHIP"}')"
pg_review_input_binding_write "$MARKER" "$INPUT"
pg_review_result_binding_write "$MARKER" "$RESULT"
# Populate unrelated runtime state too: no upkeep, scoring, lock, or recovery mutation is allowed.
mkdir -p "$PRO_GATE_HOME/rounds" "$PRO_GATE_HOME/in-progress" "$PRO_GATE_HOME/pending" "$PRO_GATE_HOME/conversation-urls"
printf '0,0,0\n' > "$PRO_GATE_HOME/rounds/acme-widgets-1983.last"
printf 'retained sentinel\n' > "$PRO_GATE_HOME/in-progress/unrelated"
snapshot() {
  find "$PRO_GATE_HOME" -exec stat -c '%n %F %a %s %Y' {} + | LC_ALL=C sort
  find "$PRO_GATE_HOME" -type f -readable -exec sha256sum {} + | LC_ALL=C sort
  find "$PRO_GATE_HOME" -type l -exec readlink {} \;
}
query() {
  local before after
  before="$(snapshot)"
  RC=0
  QUERY_START=$SECONDS
  bash "$TDIR/installed/oracle-review.sh" --review-facts --repo "$TDIR/checkout" --pr 1983 --json "$@" > "$TDIR/out.json" 2> "$TDIR/err" || RC=$?
  QUERY_SECONDS=$((SECONDS - QUERY_START))
  after="$(snapshot)"
  [ "$before" = "$after" ] || { printf 'FAIL - public inspection mutated runtime state\n' >&2; exit 1; }
  [ ! -e "$PG_FACTS_EFFECT_LOG" ] || { printf 'FAIL - effect entrypoint invoked\n' >&2; cat "$PG_FACTS_EFFECT_LOG" >&2; exit 1; }
}
PRECHECKS=0 PRECHECK_FAILS=0
precheck() {
  PRECHECKS=$((PRECHECKS + 1))
  if [ "$2" = 0 ]; then printf 'ok - %s\n' "$1"; else printf 'FAIL - %s\n' "$1"; PRECHECK_FAILS=$((PRECHECK_FAILS + 1)); fi
}
typed_query() {
  local before
  before="$(snapshot)"
  TYPED_RC=0
  env PRO_GATE_INPUT_POLICY=bundle-only PRO_GATE_BROWSER_ATTACHMENTS=auto \
    PRO_GATE_REVIEW_PR_EVIDENCE="$TDIR/pr-evidence.json" PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/endpoint.patch" \
    bash "$ROOT/bin/oracle-review.sh" --review-decision --repo "$TDIR/checkout" --pr 1983 \
      --diff "$TDIR/endpoint.patch" --input bundle --json > "$TDIR/decision.json" 2> "$TDIR/decision.err" || TYPED_RC=$?
  [ "$before" = "$(snapshot)" ] && [ ! -e "$PG_FACTS_EFFECT_LOG" ]
}
typed_envelope() { # expected action reason; the consumer validator re-reduces the full facts
  [ "$TYPED_RC" = 0 ] && pg_review_decision_envelope_valid "$TDIR/decision.json" &&
    jq -e --arg action "$1" --arg reason "$2" '
      .action==$action and .reason==$reason and .effect_request.execution_class=="report-only" and
      (.facts|type=="object" and length>0) and
      (.contract.contract_digest|test("^[0-9a-f]{64}$")) and
      (.contract.corpus_digest|test("^[0-9a-f]{64}$")) and
      (.effect_request.snapshot_digest|test("^[0-9a-f]{64}$"))
    ' "$TDIR/decision.json" >/dev/null
}
for function in pg_review_decision_ship_mode_bindable pg_review_decision_repair_result_binding; do
  eval "$(awk -v name="$function" '$0 ~ "^" name "\\(\\)"{p=1} p{print} p && /^}/{exit}' "$ROOT/bin/oracle-review.sh")"
done
# The same digest-bound saved artifact exercises every public reader and binding repair.
# No state writes, scoring, browser calls or network requests are allowed while reading it.
cp "$PRO_GATE_HOME/completed/$MARKER" "$TDIR/real-review"
# legacy*: the input binding carries a pre-0.62.0 contract digest and nothing retains its diff
# (gate r1 P1); a grounded review keeps its acceptance, a skeleton is still refused.
LEGACY_INPUT="$(jq -cS '.contract_digest="fa91787e3fbf3c0852c78f5269b2f670d84b86561be64d6edef4229bf46aee9b"' <<<"$INPUT")"
for shape in skeleton real no-vocabulary manifest legacy legacy-skeleton; do
  CASE_INPUT="$INPUT"; case "$shape" in legacy*) CASE_INPUT="$LEGACY_INPUT";; esac
  rm -f "$(pg_review_input_binding_dir)/$MARKER"
  pg_review_input_binding_write "$MARKER" "$CASE_INPUT"
  cp "$TDIR/real-review" "$PRO_GATE_HOME/completed/$MARKER"
  case "$shape" in *skeleton) cp "$ROOT/tests/fixtures/template-verdict/pushbot-4451.txt" "$PRO_GATE_HOME/completed/$MARKER";; esac
  mkdir -p "$(pg_manifest_dir)"
  pg_review_tokens_write "$MARKER" "$TDIR/endpoint.patch"
  case "$shape" in no-vocabulary|manifest|legacy*) rm "$(pg_review_tokens_dir)/$MARKER";; esac
  if [ "$shape" = manifest ]; then pg_diff_paths "$TDIR/endpoint.patch" > "$(pg_manifest_dir)/$MARKER"; fi
  SAVED_RESULT="$(jq -cS --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$MARKER")" --arg ib "$(pg_review_sha256_text "$CASE_INPUT")" '.artifact.digest=$digest | .input_binding_digest=$ib' <<<"$RESULT")"
  printf '%s' "$SAVED_RESULT" > "$(pg_review_result_binding_dir)/$MARKER"
  expected=0; case "$shape" in skeleton|no-vocabulary|legacy-skeleton) expected=6;; esac
  rc=0; pg_review_accepted_artifact_read "$MARKER" > "$TDIR/accepted.json" 2> "$TDIR/accepted.err" || rc=$?
  precheck "P1-b: accepted-artifact reader $shape exits $expected" "$([ "$rc" = "$expected" ]; echo $?)"
  query
  precheck "P1-b: review-facts $shape exits $expected" "$([ "$RC" = "$expected" ] && { [ "$expected" = 0 ] || jq -e '.status=="invalid" and .reason=="template-verdict" and .review==null' "$TDIR/out.json" >/dev/null; }; echo $?)"
  rc=0; bash "$TDIR/installed/oracle-review.sh" --recover "$MARKER" > "$TDIR/recover.out" 2> "$TDIR/recover.err" || rc=$?
  precheck "P1-b: recover $shape exits $expected" "$([ "$rc" = "$expected" ] && { [ "$expected" = 0 ] || { grep -q template-verdict "$TDIR/recover.err" && ! grep -q 'Review ready' "$TDIR/recover.err" && [ ! -s "$TDIR/recover.out" ]; }; }; echo $?)"
  mv "$PRO_GATE_HOME/completed/$MARKER" "$PRO_GATE_HOME/pending/$MARKER"
  rc=0; bash "$TDIR/installed/oracle-review.sh" --recover "$MARKER" > "$TDIR/recover.out" 2> "$TDIR/recover.err" || rc=$?
  precheck "P1-b: pending recovery $shape exits $expected" "$([ "$rc" = "$expected" ] && { [ "$expected" = 0 ] || { grep -q template-verdict "$TDIR/recover.err" && ! grep -q 'Review ready' "$TDIR/recover.err" && [ ! -s "$TDIR/recover.out" ]; }; }; echo $?)"
  mv "$PRO_GATE_HOME/pending/$MARKER" "$PRO_GATE_HOME/completed/$MARKER"
  typed_query
  action=allow-existing-merge-workflow reason=current-ship-is-merge-eligible
  if [ "$expected" = 6 ]; then action=stop-without-new-review reason=template-verdict; fi
  precheck "round 2: typed $shape returns a complete $action envelope at exit 0 without effects" "$(typed_envelope "$action" "$reason"; echo $?)"
  if [ "$expected" = 6 ]; then
    precheck "round 2: typed $shape facts name the rejected marker and artifact digest" "$(jq -e --arg marker "$MARKER" --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$MARKER")" 'any(.facts.completed_results[]?; .marker==$marker and .artifact_digest==$digest and .shape=="template-verdict" and .applicable==false)' "$TDIR/decision.json" >/dev/null; echo $?)"
  fi
  # A rejection must occur before the repair lock and before it can write a new binding.
  rm "$(pg_review_result_binding_dir)/$MARKER"
  rc=0; pg_review_decision_repair_result_binding "$MARKER" "$CASE_INPUT" > "$TDIR/repair.out" 2> "$TDIR/repair.err" || rc=$?
  precheck "P1-b: binding repair $shape exits $expected" "$([ "$rc" = "$expected" ] && { [ "$expected" = 0 ] || [ ! -e "$(pg_review_result_binding_dir)/$MARKER" ]; }; echo $?)"
  rm -f "$(pg_review_result_binding_dir)/$MARKER" "$(pg_manifest_dir)/$MARKER"
done
rm -f "$(pg_review_input_binding_dir)/$MARKER"
pg_review_input_binding_write "$MARKER" "$INPUT"
# Both marker enumeration orders must defer to charged epoch. The rejected artifact has no
# result binding, as with a real skeleton capture; the grounded completion is digest-bound.
for order in skeleton-first grounded-first; do
  NEWER=pg-run-acme-widgets-1983-1700000900-2
  if [ "$order" = skeleton-first ]; then
    cp "$ROOT/tests/fixtures/template-verdict/pushbot-4451.txt" "$PRO_GATE_HOME/completed/$MARKER"
    cp "$TDIR/real-review" "$PRO_GATE_HOME/completed/$NEWER"
    GROUNDED="$NEWER" REJECTED="$MARKER"
  else
    cp "$TDIR/real-review" "$PRO_GATE_HOME/completed/$MARKER"
    cp "$ROOT/tests/fixtures/template-verdict/pushbot-4451.txt" "$PRO_GATE_HOME/completed/$NEWER"
    GROUNDED="$MARKER" REJECTED="$NEWER"
  fi
  NEW_INPUT="$(jq -cS --arg marker "$NEWER" '.marker=$marker | .charged_spend_epoch=1700000900' <<<"$INPUT")"
  pg_review_input_binding_write "$NEWER" "$NEW_INPUT"
  pg_review_tokens_write "$MARKER" "$TDIR/endpoint.patch"
  pg_review_tokens_write "$NEWER" "$TDIR/endpoint.patch"
  GROUNDED_INPUT="$(pg_review_input_binding_read "$GROUNDED")"
  GROUNDED_RESULT="$(jq -cS --arg marker "$GROUNDED" --arg ib "$(pg_review_sha256_text "$GROUNDED_INPUT")" --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$GROUNDED")" '.marker=$marker | .input_binding_identity=$marker | .input_binding_digest=$ib | .artifact={digest:$digest,path:("completed/"+$marker)}' <<<"$RESULT")"
  printf '%s' "$GROUNDED_RESULT" > "$(pg_review_result_binding_dir)/$GROUNDED"
  typed_query
  if [ "$order" = skeleton-first ]; then
    precheck 'round 2: newer grounded review supersedes older skeleton' "$(typed_envelope allow-existing-merge-workflow current-ship-is-merge-eligible && jq -e --arg ref "$(pg_review_sha256_text "$GROUNDED_RESULT")" '.effect_request.applicable_ref==$ref' "$TDIR/decision.json" >/dev/null; echo $?)"
  else
    precheck 'round 2: newer skeleton supersedes older grounded review with a typed stop' "$(typed_envelope stop-without-new-review template-verdict && jq -e --arg marker "$REJECTED" --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$REJECTED")" '.effect_request.applicable_ref==$marker and any(.facts.completed_results[]; .marker==$marker and .shape=="template-verdict" and .artifact_digest==$digest and .applicable==false)' "$TDIR/decision.json" >/dev/null; echo $?)"
  fi
  rm -f "$(pg_review_result_binding_dir)/$GROUNDED" "$(pg_review_input_binding_dir)/$NEWER" "$PRO_GATE_HOME/completed/$NEWER" "$(pg_review_tokens_dir)/$NEWER"
done
cp "$TDIR/real-review" "$PRO_GATE_HOME/completed/$MARKER"
printf '%s' "$RESULT" > "$(pg_review_result_binding_dir)/$MARKER"
pg_review_tokens_write "$MARKER" "$TDIR/endpoint.patch"
query
if [ "$RC" -ne 0 ] || ! jq -e --arg head "$HEAD" --arg digest "$DIGEST" --arg marker "$MARKER" --arg canonical "$(pg_review_sha256_text "$RESULT")" '.schema=="review-facts/v1" and .status=="accepted" and .selected_marker==$marker and .candidate_head==$head and .applicable==null and .review.reviewed_head==$head and .review.artifact_digest==$digest and .review.canonical_identity==$canonical and .review.verdict=="SHIP" and .review.open_p0==0 and .review.open_p1==0' "$TDIR/out.json"; then
  printf 'FAIL - installed public CLI returns retained facts without current proof; exit=%s\n' "$RC" >&2
  cat "$TDIR/err" >&2
  exit 1
fi
printf 'ok - installed public CLI returns retained facts with unknown applicability despite invalid fresh policy; all runtime state unchanged\n'
CHECKS=$((PRECHECKS + 1)) FAILS=$PRECHECK_FAILS
check() { # label jq predicate (against the actual public output)
  CHECKS=$((CHECKS + 1))
  if [ "$RC" -eq 0 ] && jq -e "$2" "$TDIR/out.json" >/dev/null; then
    printf 'ok - %s\n' "$1"
  else
    printf 'FAIL - %s; exit=%s\n' "$1" "$RC" >&2
    cat "$TDIR/out.json" "$TDIR/err" >&2
    FAILS=$((FAILS + 1))
  fi
}
PRISTINE="$PRO_GATE_HOME"
new_case() {
  export PRO_GATE_HOME="$TDIR/state-$1"
  cp -R "$PRISTINE" "$PRO_GATE_HOME"
  unset PRO_GATE_REVIEW_PR_EVIDENCE PRO_GATE_REVIEW_ENDPOINT_PATCH PRO_GATE_REVIEW_FILTER_MANIFEST
}
current_proof() {
  export PRO_GATE_REVIEW_PR_EVIDENCE="$TDIR/pr-evidence.json" PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/endpoint.patch"
}
new_case current
current_proof
query --diff "$TDIR/endpoint.patch"
check 'complete full-PR proof is applicable despite invalid fresh policy' '.status=="accepted" and .applicable==true and .review.verdict=="SHIP" and .reason=="matching-current-proof"'
# Missing and malformed current proof leave historical acceptance intact, never imply current SHIP.
unset PRO_GATE_REVIEW_PR_EVIDENCE
query --diff "$TDIR/endpoint.patch"
check 'head and patch equality without PR metadata is unknown, not current SHIP' '.status=="accepted" and .applicable==null and .review.open_p0==0'
printf '{bad\n' > "$TDIR/bad-pr-evidence.json"
export PRO_GATE_REVIEW_PR_EVIDENCE="$TDIR/bad-pr-evidence.json"
query --diff "$TDIR/endpoint.patch"
check 'malformed current metadata does not destroy accepted historical facts or prove current SHIP' '.status=="accepted" and .applicable==null'
current_proof
jq -cS '.metadata.target.base_oid=("2"*40)' "$TDIR/pr-evidence.json" > "$TDIR/moved-base.json"
export PRO_GATE_REVIEW_PR_EVIDENCE="$TDIR/moved-base.json"
query --diff "$TDIR/endpoint.patch"
check 'known changed PR base metadata is false applicability, not unknown' '.status=="accepted" and .applicable==false'
current_proof
printf 'different supplied payload\n' > "$TDIR/different.patch"
query --diff "$TDIR/different.patch"
check 'known changed reviewed bytes keep historical facts but are not applicable' '.status=="accepted" and .applicable==false and .review.verdict=="SHIP"'
git -C "$TDIR/checkout" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm moved-head
query --diff "$TDIR/endpoint.patch"
check 'moving checkout HEAD keeps the reviewed revision, verdict, and counts but is not applicable' '.status=="accepted" and .applicable==false and .candidate_head!=.review.reviewed_head and .review.open_p0==0'
query --candidate-head "$HEAD" --diff "$TDIR/endpoint.patch"
check 'explicit candidate with complete matching proof is applicable independently of checkout HEAD' '.status=="accepted" and .applicable==true and .candidate_head==.review.reviewed_head'
query --candidate-head "$BASE" --diff "$TDIR/endpoint.patch"
check 'explicit different candidate preserves historical evidence but refuses applicability' '.status=="accepted" and .applicable==false and .candidate_head!=.review.reviewed_head'
unset PRO_GATE_REVIEW_PR_EVIDENCE
query --candidate-head "$HEAD" --diff "$TDIR/endpoint.patch"
check 'explicit candidate without complete proof does not establish current SHIP' '.status=="accepted" and .applicable==null'
current_proof
git -C "$TDIR/checkout" checkout --detach -q "$HEAD"
new_case missing
mkdir -p "$TDIR/empty-state"
export PRO_GATE_HOME="$TDIR/empty-state"
query
check 'no relevant completions means missing with unavailable counts, never zero' '.status=="missing" and .review==null and .selected_marker==null and .applicable==null'
new_case url
# The public URL spelling selects the same repository/PR without network or a different parser.
query --pr https://github.com/acme/widgets/pull/1983/
check 'canonical PR URL retains the same accepted target' '.status=="accepted" and .repository=={host:"github.com",owner:"acme",repo:"widgets"} and .pr==1983'
NEWER=pg-run-acme-widgets-1983-1700000900-2
newer_completion() {
  NEW_INPUT="$(jq -cS --arg marker "$NEWER" '.marker=$marker | .charged_spend_epoch=1700000900' <<<"$INPUT")"
  NEW_RESULT="$(jq -cS --arg marker "$NEWER" --arg ib "$(pg_review_sha256_text "$NEW_INPUT")" '.marker=$marker | .input_binding_identity=$marker | .input_binding_digest=$ib | .artifact.path=("completed/"+$marker)' <<<"$RESULT")"
  cp "$PRO_GATE_HOME/completed/$MARKER" "$PRO_GATE_HOME/completed/$NEWER"
  pg_review_tokens_write "$NEWER" "$TDIR/endpoint.patch"
  pg_review_input_binding_write "$NEWER" "$NEW_INPUT"
  pg_review_result_binding_write "$NEWER" "$NEW_RESULT"
}
# Repository spelling is case-insensitive; authenticated record bytes and marker paths are not.
SAVED_NEWER="$NEWER"
for shape in scoped generic; do
  NEWER=pg-run-AcMe-WiDgEtS-1983-1700000900-2
  [ "$shape" != generic ] || NEWER=pg-run-mixed-case
  sidecars=(absent damaged)
  [ "$shape" != scoped ] || sidecars+=(valid)
  for sidecar in "${sidecars[@]}"; do
    new_case "case-$shape-$sidecar"
    newer_completion
    CASE_INPUT="$(jq -cS '.repository.owner="AcMe" | .repository.repo="WiDgEtS"' <<<"$NEW_INPUT")"
    printf '[P0] file.txt:1 - Latest blocker\nVERDICT: FIX-FIRST\n' > "$PRO_GATE_HOME/completed/$NEWER"
    CASE_RESULT="$(jq -cS --arg ib "$(pg_review_sha256_text "$CASE_INPUT")" --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$NEWER")" '.input_binding_digest=$ib | .artifact.digest=$digest | .verdict="FIX-FIRST" | .ship_proof=null' <<<"$NEW_RESULT")"
    printf '%s' "$CASE_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER"
    printf '%s' "$CASE_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
    case "$sidecar" in
      valid) pg_run_meta_write "$NEWER" github.com ACME widgets AcMe-WiDgEtS-1983 1983 "$TDIR/review.md" 1700000900 ;;
      damaged) mkdir -p "$PRO_GATE_HOME/run-meta"; printf 'github.com\tACME\twidgets\tbroken\t1983\n' > "$PRO_GATE_HOME/run-meta/$NEWER" ;;
    esac
    for spelling in acme/widgets ACME/WIDGETS; do
      query --pr "https://github.com/$spelling/pull/1983"
      check "$shape $sidecar mixed-case newest P0 survives query $spelling" ".status==\"accepted\" and .selected_marker==\"$NEWER\" and .review.verdict==\"FIX-FIRST\" and .review.open_p0==1 and .review.canonical_identity==\"$(pg_review_sha256_text "$CASE_RESULT")\""
    done
  done
done
NEWER=pg-run-AcMe-WiDgEtS-1983-1700000900-2
for record in input result both; do
  new_case "case-unbound-$record"
  newer_completion
  [ "$record" = result ] || rm "$PRO_GATE_HOME/review-input-bindings/$NEWER"
  [ "$record" = input ] || rm "$PRO_GATE_HOME/review-result-bindings/$NEWER"
  query
  check "mixed-case scoped marker with missing $record obstructs older SHIP" '.status=="ambiguous" and .review==null'
done
new_case case-tampered
newer_completion
jq -cjS '.repository.owner="AcMe" | .repository.repo="WiDgEtS"' <<<"$NEW_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER"
query
check 'case-only input tampering without digest rebinding remains invalid evidence' '.status!="accepted" and .status!="missing" and .review==null'
new_case case-foreign
newer_completion
FOREIGN_INPUT="$(jq -cS '.repository.owner="AcMe" | .repository.repo="WiDgEtS-Other"' <<<"$NEW_INPUT")"
FOREIGN_RESULT="$(jq -cS --arg ib "$(pg_review_sha256_text "$FOREIGN_INPUT")" '.input_binding_digest=$ib' <<<"$NEW_RESULT")"
printf '%s' "$FOREIGN_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER"
printf '%s' "$FOREIGN_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
query
check 'case folding does not conflate genuinely different repository names' '.status=="accepted" and (.selected_marker|endswith("1700000700-1"))'
NEWER="$SAVED_NEWER"
for scenario in corrupt unreadable missing-input missing-result missing-artifact malformed-input malformed-result input-digest wrong-target wrong-marker verdict-disagreement; do
  new_case "$scenario"
  newer_completion
  case "$scenario" in
    corrupt) printf 'corrupted after acceptance\n' >> "$PRO_GATE_HOME/completed/$NEWER" ;;
    unreadable) chmod 000 "$PRO_GATE_HOME/completed/$NEWER" ;;
    missing-input) rm "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
    missing-result) rm "$PRO_GATE_HOME/review-result-bindings/$NEWER" ;;
    missing-artifact) rm "$PRO_GATE_HOME/completed/$NEWER" ;;
    malformed-input) printf 'broken input\n' > "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
    malformed-result) printf '{bad\n' > "$PRO_GATE_HOME/review-result-bindings/$NEWER" ;;
    input-digest) jq -cjS '.input_binding_digest=("a"*64)' <<<"$NEW_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER" ;;
    wrong-target) jq -cjS '.target.pr=1984' <<<"$NEW_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
    wrong-marker) jq -cjS --arg marker "$MARKER" '.marker=$marker' <<<"$NEW_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER" ;;
    verdict-disagreement) jq -cjS '.verdict="FIX-FIRST" | .ship_proof=null' <<<"$NEW_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER" ;;
  esac
  # Existing charged metadata locates a completion even when its input sibling cannot be read.
  pg_run_meta_write "$NEWER" github.com acme widgets acme-widgets-1983 1983 "$TDIR/review.md" 1700000900
  query
  check "newer relevant $scenario obstructs older SHIP and exposes no accepted counts" '.status!="accepted" and .status!="missing" and .review==null and .applicable==null'
  [ "$scenario" != unreadable ] || chmod 600 "$PRO_GATE_HOME/completed/$NEWER"
  # Near-identical allowed case: restoring only the failing record yields the selected newer facts.
  printf '%s' "$NEW_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER"
  printf '%s' "$NEW_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
  cp "$PRISTINE/completed/$MARKER" "$PRO_GATE_HOME/completed/$NEWER"
  query
  check "restored $scenario completion is accepted as newest" '.status=="accepted" and (.selected_marker|endswith("1700000900-2")) and .review.open_p0==0'
done
new_case unrelated
printf '{bad\n' > "$PRO_GATE_HOME/completed/pg-run-other-repo-99-1700009900-1"
printf '{bad\n' > "$PRO_GATE_HOME/review-input-bindings/pg-run-other-repo-99-1700009900-1"
printf '{bad\n' > "$PRO_GATE_HOME/review-result-bindings/pg-run-other-repo-99-1700009900-1"
query
check 'unrelated malformed records do not hide this target accepted review' '.status=="accepted" and (.selected_marker|endswith("1700000700-1"))'
new_case other-host
newer_completion
OTHER_INPUT="$(jq -cS '.repository.host="github.example.com"' <<<"$NEW_INPUT")"
printf '%s' "$OTHER_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER"
printf '{bad\n' > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
pg_run_meta_write "$NEWER" github.example.com acme widgets acme-widgets-1983 1983 "$TDIR/review.md" 1700000900
query
check 'known other-host sidecar disambiguates a malformed completion with the same host-less key' '.status=="accepted" and (.selected_marker|endswith("1700000700-1"))'
rm "$PRO_GATE_HOME/run-meta/$NEWER"
query
check 'unbound other-host input cannot hide a malformed completion without a sidecar' '.status!="accepted" and .status!="missing" and .review==null'
OTHER_RESULT="$(jq -cS --arg ib "$(pg_review_sha256_text "$OTHER_INPUT")" '.input_binding_digest=$ib' <<<"$NEW_RESULT")"
printf '%s' "$OTHER_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
query
check 'digest-bound other-host input disambiguates the same marker key without a run sidecar' '.status=="accepted" and (.selected_marker|endswith("1700000700-1"))'
pg_run_meta_write "$NEWER" github.com acme widgets acme-widgets-1983 1983 "$TDIR/review.md" 1700000900
query
check 'conflicting relevant sidecar prevents unrelated input attribution from hiding the newest record' '.status=="invalid" and .reason=="conflicting-completion-metadata" and .review==null'
new_case epoch-conflict
newer_completion
pg_run_meta_write "$NEWER" github.com acme widgets acme-widgets-1983 1983 "$TDIR/review.md" 1700000600
query
check 'conflicting charge epochs are unknown ordering, not permission to select older SHIP' '.status=="ambiguous" and .reason=="unproved-completion-order" and .review==null'
for location in pending recovered; do
  new_case "$location"
  newer_completion
  mkdir -p "$PRO_GATE_HOME/$location"
  path="$PRO_GATE_HOME/$location/$NEWER"; [ "$location" != recovered ] || path="$path.md"
  mv "$PRO_GATE_HOME/completed/$NEWER" "$path"
  rm "$PRO_GATE_HOME/review-result-bindings/$NEWER"
  pg_run_meta_write "$NEWER" github.com acme widgets acme-widgets-1983 1983 "$TDIR/review.md" 1700000900
  query
  check "newer $location artifact obstructs old accepted facts without collecting or repairing" '.status=="incomplete" and .review==null and (.selected_marker|endswith("1700000900-2"))'
done
new_case directory-overrides
export PRO_GATE_COMPLETED_DIR="$PRO_GATE_HOME/alternate-completed" PRO_GATE_REVIEW_INPUT_BINDING_DIR="$PRO_GATE_HOME/alternate-input" PRO_GATE_REVIEW_RESULT_BINDING_DIR="$PRO_GATE_HOME/alternate-result"
mv "$PRO_GATE_HOME/completed" "$PRO_GATE_COMPLETED_DIR"
mv "$PRO_GATE_HOME/review-input-bindings" "$PRO_GATE_REVIEW_INPUT_BINDING_DIR"
mv "$PRO_GATE_HOME/review-result-bindings" "$PRO_GATE_REVIEW_RESULT_BINDING_DIR"
query
check 'existing completed/input/result directory overrides remain supported without effects' '.status=="accepted" and .review.open_p0==0 and .review.open_p1==0'
unset PRO_GATE_COMPLETED_DIR PRO_GATE_REVIEW_INPUT_BINDING_DIR PRO_GATE_REVIEW_RESULT_BINDING_DIR
new_case unknown-order
newer_completion
rm "$PRO_GATE_HOME/review-input-bindings/$NEWER"
query
check 'relevant completion with no charged epoch cannot silently select older favorable evidence' '.status=="ambiguous" and .reason=="unproved-completion-order" and .review==null'
new_case tied
newer_completion
jq -cjS '.charged_spend_epoch=1700000700' <<<"$NEW_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER"
printf '{bad\n' > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
pg_run_meta_write "$NEWER" github.com acme widgets acme-widgets-1983 1983 "$TDIR/review.md" 1700000700
query
check 'equal charged epochs with unproved canonical identity are ambiguous, not a lexicographic SHIP pick' '.status=="ambiguous" and .reason=="ambiguous-completion-order" and .review==null'
# With both immutable identities proven, the documented canonical tie-break is deterministic.
TIED_INPUT="$(jq -cS '.charged_spend_epoch=1700000700' <<<"$NEW_INPUT")"
TIED_RESULT="$(jq -cS --arg ib "$(pg_review_sha256_text "$TIED_INPUT")" '.input_binding_digest=$ib' <<<"$NEW_RESULT")"
printf '%s' "$TIED_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
query
check 'distinct proven canonical identities at one epoch are selectable' '.status=="accepted" and .review.charged_spend_epoch==1700000700'
EXPECTED_CANONICAL="$(printf '%s\n%s\n' "$(pg_review_sha256_text "$TIED_RESULT")" "$(pg_review_sha256_text "$RESULT")" | LC_ALL=C sort | tail -n 1)"
[ "$(jq -r .review.canonical_identity "$TDIR/out.json")" = "$EXPECTED_CANONICAL" ] || { printf 'FAIL - canonical identity tie-break\n' >&2; FAILS=$((FAILS + 1)); }
new_case precedence
newer_completion
printf '[P0] file.txt:1 - RESOLVED - already fixed\n[P0] file.txt:2 - the RESOLVED state is forgeable\n[P1] file.txt:3 - RESOLVED_MODEL is clobbered\nVERDICT: FIX-FIRST\n' > "$PRO_GATE_HOME/completed/$NEWER"
FIX_RESULT="$(jq -cS --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$NEWER")" '.artifact.digest=$digest | .verdict="FIX-FIRST" | .ship_proof=null' <<<"$NEW_RESULT")"
printf '%s' "$FIX_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
# A deliberately favorable mutable round tuple must not provide the public counts.
printf '0,0,0\n' > "$PRO_GATE_HOME/rounds/acme-widgets-1983.last"
query
check 'newest FIX-FIRST wins over older SHIP and reports artifact-bound U1 open severity' '.status=="accepted" and .review.verdict=="FIX-FIRST" and .review.open_p0==1 and .review.open_p1==1 and .applicable==null'
current_proof
query --diff "$TDIR/endpoint.patch"
check 'applicability is separate from verdict: a matching FIX-FIRST review is applicable' '.status=="accepted" and .applicable==true and .review.verdict=="FIX-FIRST"'
# #291: a standalone label resolved by an explicit same-severity finding reports artifact-bound
# counts through the installed CLI (pushbot#4377 shape); an empty standalone section stays unknown.
for shape in pushbot-4377 blank-run empty; do
  new_case "standalone-$shape"
  newer_completion
  case "$shape" in
    pushbot-4377) printf 'P0: none\n\nP1\n\n[P1] file.txt:1 - concurrent started inserts race\n\nP2\n\nP2: none\n\nP3\n\nP3: none\n\nVERDICT: FIX-FIRST\n' ;;
    blank-run) printf 'P0\n\n \t\n\n[P0] file.txt:1 - data loss\nP1: none\nVERDICT: FIX-FIRST\n' ;;
    empty) printf 'P0: none\n\nP1\n\nP2: none\nChecked file.txt for regressions.\nVERDICT: FIX-FIRST\n' ;;
  esac > "$PRO_GATE_HOME/completed/$NEWER"
  STANDALONE_DIGEST="$(pg_sha256 "$PRO_GATE_HOME/completed/$NEWER")"
  jq -cjS --arg digest "$STANDALONE_DIGEST" '.artifact.digest=$digest | .verdict="FIX-FIRST" | .ship_proof=null' <<<"$NEW_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
  query
  STANDALONE_IDENTITY=".status==\"accepted\" and .selected_marker==\"$NEWER\" and .review.artifact_digest==\"$STANDALONE_DIGEST\" and .review.verdict==\"FIX-FIRST\""
  case "$shape" in
    pushbot-4377) check '#291 standalone P1 label between blank lines reports its finding' "$STANDALONE_IDENTITY and .review.open_p0==0 and .review.open_p1==1" ;;
    blank-run) check '#291 standalone P0 label before whitespace-only lines reports its finding' "$STANDALONE_IDENTITY and .review.open_p0==1 and .review.open_p1==0" ;;
    empty) check '#291 empty standalone P1 section keeps public counts unavailable' "$STANDALONE_IDENTITY and .review.open_p0==null and .review.open_p1==null" ;;
  esac
done
# No sidecar: unbound target/epoch edits must never demote a newer blocking review.
SAVED_NEWER="$NEWER"
for shape in keyed generic numeric-generic partial-key; do
  case "$shape" in
    keyed) NEWER="$SAVED_NEWER" ;;
    generic) NEWER=pg-run-newer ;;
    numeric-generic) NEWER=pg-run-newer-1700000900-2 ;;
    partial-key) NEWER=pg-run-newer-1983-1700000900-2 ;;
  esac
  for mutation in repo pr epoch symlink missing-input named-choice; do
    new_case "unbound-$shape-$mutation"
    newer_completion
    printf '[P0] file.txt:1 - Latest blocker\nVERDICT: FIX-FIRST\n' > "$PRO_GATE_HOME/completed/$NEWER"
    BLOCKING_RESULT="$(jq -cS --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$NEWER")" '.artifact.digest=$digest | .verdict="FIX-FIRST" | .ship_proof=null' <<<"$NEW_RESULT")"
    printf '%s' "$BLOCKING_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
    case "$mutation" in
      repo) jq -cjS '.repository.repo="Elsewhere"' <<<"$NEW_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
      pr) jq -cjS '.target.pr=1984' <<<"$NEW_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
      epoch) jq -cjS '.charged_spend_epoch=99' <<<"$NEW_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
      symlink) mv "$PRO_GATE_HOME/review-input-bindings/$NEWER" "$PRO_GATE_HOME/saved-input"; ln -s "$PRO_GATE_HOME/saved-input" "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
      missing-input) rm "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
      named-choice) jq -cjS '.named_choice={id:"keep",label:"Preserve",consequence:"Keep compatibility"}' <<<"$BLOCKING_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER" ;;
    esac
    query
    if [ "$mutation" = named-choice ]; then
      check "$shape named choice remains selected for downstream owner policy" '.status=="accepted" and .review.open_p0==1 and .review.named_choice.id=="keep"'
    else
      check "$shape unbound $mutation refuses older favorable facts" '.status!="accepted" and .status!="missing" and .review==null'
      if [ "$mutation" != symlink ] && [ "$mutation" != missing-input ]; then
        CHECKS=$((CHECKS + 1))
        grep -Fq 'digest mismatch' "$TDIR/err" || { printf 'FAIL - missing digest mismatch diagnostic\n' >&2; FAILS=$((FAILS + 1)); }
      fi
    fi
  done
done
for mutation in missing-input malformed-input; do
  new_case "unrelated-$mutation"
  NEWER=pg-run-other-repo-99-1700000900-2
  newer_completion
  OTHER_INPUT="$(jq -cS '.repository.owner="other" | .repository.repo="repo" | .target.pr=99' <<<"$NEW_INPUT")"
  OTHER_RESULT="$(jq -cS --arg ib "$(pg_review_sha256_text "$OTHER_INPUT")" '.input_binding_digest=$ib' <<<"$NEW_RESULT")"
  printf '%s' "$OTHER_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
  case "$mutation" in
    missing-input) rm "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
    malformed-input) printf '{bad\n' > "$PRO_GATE_HOME/review-input-bindings/$NEWER" ;;
  esac
  query
  check "other-PR scoped result with $mutation does not obstruct this target" '.status=="accepted" and (.selected_marker|endswith("1700000700-1"))'
done
# A full-shape name without this PR's key never rules a completion out by itself (#292): its
# input binding, bound or not, or a damaged sidecar naming this target keeps it relevant, including
# when unrelated bytes are not ASCII. A sidecar naming another PR does not.
NEWER=pg-run-other-repo-99-1700000900-2
for evidence in bound-input unbound-input unbound-input-nonascii damaged-sidecar damaged-sidecar-nonascii sidecar-other-pr; do
  new_case "foreign-name-$evidence"
  newer_completion
  case "$evidence" in
    unbound-input) printf '{bad\n' > "$PRO_GATE_HOME/review-result-bindings/$NEWER" ;;
    unbound-input-nonascii)
      jq -cjS '.evidence.identity="full-pr:révisé"' <<<"$NEW_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER"
      printf '{bad\n' > "$PRO_GATE_HOME/review-result-bindings/$NEWER" ;;
    *sidecar*)
      rm "$PRO_GATE_HOME/review-input-bindings/$NEWER"
      mkdir -p "$PRO_GATE_HOME/run-meta"
      case "$evidence" in
        damaged-sidecar) printf 'github.com\tACME\tWidgets\tbroken\t1983\n' ;;
        damaged-sidecar-nonascii) printf 'github.com\tacme\twidgets\tbr\303\266ken\t1983\n' ;;
        sidecar-other-pr) printf 'github.com\tacme\twidgets\tbroken\t1984\n' ;;
      esac > "$PRO_GATE_HOME/run-meta/$NEWER" ;;
  esac
  query
  case "$evidence" in
    bound-input) check "foreign-named completion with a digest-bound input for this PR is selected" ".status==\"accepted\" and .selected_marker==\"$NEWER\"" ;;
    sidecar-other-pr) check 'foreign-named completion whose damaged sidecar names another PR does not obstruct' '.status=="accepted" and (.selected_marker|endswith("1700000700-1"))' ;;
    *) check "foreign-named completion kept relevant by its $evidence obstructs older SHIP" '.status!="accepted" and .status!="missing" and .review==null' ;;
  esac
done
# The one-pass relevance read must never open a FIFO: the per-marker readers skip non-regular files.
new_case fifo
FIFO_MARKER=pg-run-other-repo-99-1700000900-3
cp "$PRISTINE/completed/$MARKER" "$PRO_GATE_HOME/completed/$FIFO_MARKER"
mkdir -p "$PRO_GATE_HOME/run-meta"
mkfifo "$PRO_GATE_HOME/review-input-bindings/$FIFO_MARKER" "$PRO_GATE_HOME/run-meta/$FIFO_MARKER"
# Unblocks a reader that wrongly opened a FIFO, so a regression fails the bound instead of hanging.
( sleep 60; : > "$PRO_GATE_HOME/review-input-bindings/$FIFO_MARKER"; : > "$PRO_GATE_HOME/run-meta/$FIFO_MARKER" ) \
  > /dev/null 2>&1 < /dev/null &
FIFO_UNBLOCKER=$!
FIFO_START=$SECONDS
query
FIFO_ELAPSED=$((SECONDS - FIFO_START))
pkill -P "$FIFO_UNBLOCKER" 2>/dev/null || true
kill "$FIFO_UNBLOCKER" 2>/dev/null || true
wait "$FIFO_UNBLOCKER" 2>/dev/null || true
check "FIFO binding and sidecar files are skipped without blocking (${FIFO_ELAPSED}s)" "$FIFO_ELAPSED < 60 and .status==\"accepted\" and (.selected_marker|endswith(\"1700000700-1\"))"
# Thousands of well-formed completions for other PRs and repositories must not cost a per-marker
# validation each (#292). Every seeded completion is newer than the accepted review, so treating
# one as relevant would change the outcome. Most carry a valid sidecar and a digest-bound input;
# every tenth has no sidecar and every fifteenth no input binding. The first five reuse this PR's
# key on another host, so only full validation can exclude them. Measured on this fixture: the
# per-marker scan took 142 s and selected the same marker; the one-pass prefilter takes 2 s. The
# 30 s bound fails the old scan with headroom for a loaded runner.
new_case scale
SCALE_COUNT=3000
mkdir -p "$PRO_GATE_HOME/run-meta"
SCALE_ARTIFACT="$(cat "$PRO_GATE_HOME/completed/$MARKER")"
SCALE_INPUT="$(jq -cjS '.marker="@MARKER@" | .charged_spend_epoch="@EPOCH@" | .repository={host:"@HOST@",owner:"@OWNER@",repo:"@REPO@"} | .target.pr="@PR@"' <<<"$INPUT")"
SCALE_RESULT="$(jq -cjS '.marker="@MARKER@" | .input_binding_identity="@MARKER@" | .input_binding_digest="@DIGEST@" | .artifact.path="completed/@MARKER@"' <<<"$RESULT")"
for ((i = 0; i < SCALE_COUNT; i++)); do
  scale_host=github.com scale_owner=acme scale_repo=widgets scale_pr=$((2000 + i))
  case $((i % 3)) in
    1) scale_repo="gadgets$((i % 50))" scale_pr=1983 ;;
    2) scale_owner=Other-Org scale_pr=$((i + 1)) ;;
  esac
  [ "$i" -ge 5 ] || scale_host=ghe.example.com scale_owner=acme scale_repo=widgets scale_pr=1983
  scale_epoch=$((1700001000 + i))
  scale_marker="pg-run-$scale_owner-$scale_repo-$scale_pr-$scale_epoch-$((10 + i))"
  printf '%s\n' "$SCALE_ARTIFACT" > "$PRO_GATE_HOME/completed/$scale_marker"
  if [ $((i % 15)) -eq 7 ]; then
    scale_json="${SCALE_RESULT//@MARKER@/$scale_marker}"
    printf '%s' "${scale_json/@DIGEST@/$RAW}" > "$PRO_GATE_HOME/review-result-bindings/$scale_marker"
  else
    scale_json="${SCALE_INPUT/@MARKER@/$scale_marker}"
    scale_json="${scale_json/\"@EPOCH@\"/$scale_epoch}"
    scale_json="${scale_json/@HOST@/$scale_host}"
    scale_json="${scale_json/@OWNER@/$scale_owner}"
    scale_json="${scale_json/@REPO@/$scale_repo}"
    printf '%s' "${scale_json/\"@PR@\"/$scale_pr}" > "$PRO_GATE_HOME/review-input-bindings/$scale_marker"
  fi
  if [ $((i % 10)) -ne 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$scale_host" "$scale_owner" "$scale_repo" "$scale_owner-$scale_repo-$scale_pr" \
      "$scale_pr" "$PRO_GATE_HOME/completed/$scale_marker" "$scale_epoch" > "$PRO_GATE_HOME/run-meta/$scale_marker"
  fi
  printf '%s\n' "$scale_marker" >> "$TDIR/scale-markers"
done
# One digest pass binds every seeded result to its input bytes.
while read -r scale_digest scale_marker; do
  [ "$scale_marker" != "$MARKER" ] || continue
  scale_json="${SCALE_RESULT//@MARKER@/$scale_marker}"
  printf '%s' "${scale_json/@DIGEST@/$scale_digest}" > "$PRO_GATE_HOME/review-result-bindings/$scale_marker"
done < <(cd "$PRO_GATE_HOME/review-input-bindings" && sha256sum -- pg-run-*)
CHECKS=$((CHECKS + 1))
scale_sample="$(sed -n '1,3p;8p;11p' "$TDIR/scale-markers")"
scale_bad=0
while IFS= read -r scale_marker; do
  if [ -e "$PRO_GATE_HOME/review-input-bindings/$scale_marker" ]; then
    [ "$(pg_review_input_binding_digest "$scale_marker")" = "$(pg_review_result_binding_read "$scale_marker" | jq -r .input_binding_digest)" ] || scale_bad=1
  fi
  pg_review_result_binding_read "$scale_marker" > /dev/null || scale_bad=1
  [ ! -e "$PRO_GATE_HOME/run-meta/$scale_marker" ] || pg_run_meta_read "$scale_marker" > /dev/null || scale_bad=1
done <<<"$scale_sample"
if [ "$scale_bad" -eq 0 ]; then printf 'ok - seeded scale records pass the production validators\n'; else printf 'FAIL - seeded scale records are malformed\n' >&2; FAILS=$((FAILS + 1)); fi
query
check "$SCALE_COUNT unrelated completions leave the same accepted review selected within 30s (${QUERY_SECONDS}s)" "$QUERY_SECONDS <= 30 and .status==\"accepted\" and .selected_marker==\"$MARKER\" and .review.verdict==\"SHIP\""
NEWER="$SAVED_NEWER"
new_case publication-temp
printf 'partial publication\n' > "$PRO_GATE_HOME/completed/$NEWER.tmp.456"
query
check 'numeric publication suffix is ignored' '.status=="accepted" and .review.open_p0==0'
new_case literal-tmp
NEWER=pg-run-latest.tmp.v2
newer_completion
query
check 'literal nonnumeric tmp suffix remains a real candidate' '.status=="accepted" and .selected_marker=="pg-run-latest.tmp.v2"'
NEWER="$SAVED_NEWER"
new_case choices
printf '[P1] file.txt:1 - select a compatibility policy\nCHOICE: keep | Preserve | Keep compatibility\nCHOICE: break | Replace | Use new API\nVERDICT: NEEDS-DISCUSSION\n' > "$PRO_GATE_HOME/completed/$MARKER"
CHOICE_RESULT="$(jq -cS --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$MARKER")" '.artifact.digest=$digest | .verdict="NEEDS-DISCUSSION" | .ship_proof=null' <<<"$RESULT")"
printf '%s' "$CHOICE_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$MARKER"
query
check 'named choices come from accepted artifact bytes without choosing for the owner' '.status=="accepted" and .review.named_choice==null and (.review.named_choices|map(.id))==["keep","break"] and .review.open_p1==1'
for verdict in FIX-FIRST SHIP; do
  printf 'P0: none\nP1: none\nChecked file.txt for regressions.\nCHOICE: keep | Preserve | Keep compatibility\nCHOICE: break | Replace | Use new API\nVERDICT: %s\n' "$verdict" > "$PRO_GATE_HOME/completed/$MARKER"
  OTHER_CHOICE_RESULT="$(jq -cS --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$MARKER")" --arg verdict "$verdict" '.artifact.digest=$digest | .verdict=$verdict | if $verdict=="SHIP" then . else .ship_proof=null end' <<<"$RESULT")"
  printf '%s' "$OTHER_CHOICE_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$MARKER"
  query
  check "accepted $verdict preserves valid named choices for downstream policy without changing verdict" ".status==\"accepted\" and .review.verdict==\"$verdict\" and (.review.named_choices|map(.id))==[\"keep\",\"break\"] and .review.named_choice==null"
done
new_case predecessor
OLD_CD="$(pg_review_decision_compatible_contract_digests_json | jq -r '.[0]')"
OLD_INPUT="$(jq -cS --arg cd "$OLD_CD" '.contract_digest=$cd | del(.evidence.proof.pr_metadata_digest)' <<<"$INPUT")"
OLD_RESULT="$(jq -cS --arg cd "$OLD_CD" --arg ib "$(pg_review_sha256_text "$OLD_INPUT")" '.contract_digest=$cd | .input_binding_digest=$ib' <<<"$RESULT")"
printf '%s' "$OLD_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$MARKER"
printf '%s' "$OLD_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$MARKER"
current_proof
query --diff "$TDIR/endpoint.patch"
check 'supported predecessor with no PR metadata remains historical, never current by head equality' '.status=="accepted" and .applicable==null and .review.verdict=="SHIP"'
new_case ship-proof
BAD_SHIP="$(jq -cS '.ship_proof.diff_digest=("a"*64)' <<<"$RESULT")"
printf '%s' "$BAD_SHIP" > "$PRO_GATE_HOME/review-result-bindings/$MARKER"
current_proof
query --diff "$TDIR/endpoint.patch"
check 'matching current input cannot excuse a mismatched retained SHIP proof' '.status=="invalid" and .review==null and .applicable==null'
new_case connector
CONNECTOR_INPUT="$(jq -cS --arg head "$HEAD" '.evidence={identity:("connector:github.com/acme/widgets:"+$head),mode:"connector",proof:{commit_target:$head,endpoint_digest:null,raw_diff_digest:null,repository_target:"github.com/acme/widgets"}}' <<<"$INPUT")"
printf 'P0: none\n[P1] file.txt:1 - fix the incompatible interface\nVERDICT: FIX-FIRST\n' > "$PRO_GATE_HOME/completed/$MARKER"
CONNECTOR_RESULT="$(jq -cS --arg ib "$(pg_review_sha256_text "$CONNECTOR_INPUT")" --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$MARKER")" '.input_binding_digest=$ib | .artifact.digest=$digest | .verdict="FIX-FIRST" | .ship_proof=null' <<<"$RESULT")"
printf '%s' "$CONNECTOR_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$MARKER"
printf '%s' "$CONNECTOR_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$MARKER"
query
check 'producer-supported connector FIX-FIRST remains accepted historical facts without current proof' '.status=="accepted" and .review.verdict=="FIX-FIRST" and .review.open_p1==1 and .applicable==null'
query --input connector
check 'matching connector progress proof remains applicable without SHIP handoff authority' '.status=="accepted" and .review.verdict=="FIX-FIRST" and .applicable==true'
for mode in connector caller-patch; do
  new_case "fabricated-$mode-ship"
  FABRICATED_INPUT="$(jq -cS --arg mode "$mode" --arg head "$HEAD" '.evidence.mode=$mode | .evidence.identity=($mode+":github.com/acme/widgets:"+$head)' <<<"$CONNECTOR_INPUT")"
  FABRICATED_RESULT="$(jq -cS --arg ib "$(pg_review_sha256_text "$FABRICATED_INPUT")" '.input_binding_digest=$ib' <<<"$RESULT")"
  printf '%s' "$FABRICATED_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$MARKER"
  printf '%s' "$FABRICATED_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$MARKER"
  query --input connector
  check "fabricated $mode SHIP binding is unaccepted because the real producer refuses that mode" '.status=="invalid" and .review==null and .applicable==null'
done
new_case scoped
printf 'filtered payload\n' > "$TDIR/scoped.patch"
printf 'file.txt\n' > "$TDIR/manifest"
printf 'P0: none\nP1: none\nP2: none\nVERDICT: SHIP - confirmation retained.\n' > "$TDIR/confirmation.md"
SCOPED_INPUT="$(jq -cS --arg base "$BASE" --arg head "$HEAD" --arg raw "$RAW" --arg reviewed "$(pg_sha256 "$TDIR/scoped.patch")" --arg manifest "$(pg_sha256 "$TDIR/manifest")" --arg lineage "confirmation:$(pg_sha256 "$TDIR/confirmation.md")" --arg md "$METADATA_DIGEST" '.evidence={identity:("scoped-delta:"+$base+":"+$head+":"+$reviewed),mode:"scoped-delta",proof:{base_oid:$base,end_oid:$head,raw_digest:$raw,reviewed_payload_digest:$reviewed,filtering_manifest_digest:$manifest,lineage_identity:$lineage,pr_metadata_digest:$md,scope_algorithm:"unified-diff-v1"}}' <<<"$INPUT")"
SCOPED_RESULT="$(jq -cS --arg ib "$(pg_review_sha256_text "$SCOPED_INPUT")" '.input_binding_digest=$ib' <<<"$RESULT")"
printf '%s' "$SCOPED_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$MARKER"
printf '%s' "$SCOPED_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$MARKER"
current_proof
export PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/manifest"
query --diff "$TDIR/scoped.patch" --confirm "$TDIR/confirmation.md"
check 'complete scoped proof requires distinct endpoint/payload plus manifest and confirmation' '.status=="accepted" and .review.evidence_mode=="scoped-delta" and .applicable==true'
for field in manifest confirmation; do
  path="$TDIR/manifest"; [ "$field" != confirmation ] || path="$TDIR/confirmation.md"
  cp "$path" "$TDIR/restore-$field"
  printf 'changed\n' >> "$path"
  query --diff "$TDIR/scoped.patch" --confirm "$TDIR/confirmation.md"
  check "changed scoped $field keeps historical facts with false applicability" '.status=="accepted" and .applicable==false'
  cp "$TDIR/restore-$field" "$path"
done
unset PRO_GATE_REVIEW_FILTER_MANIFEST
query --diff "$TDIR/scoped.patch" --confirm "$TDIR/confirmation.md"
check 'incomplete scoped proof is unknown, not current SHIP or full-PR fallback' '.status=="accepted" and .applicable==null'
# Retained SHIP relationships are acceptance, not fresh applicability or owner policy.
git -C "$TDIR/checkout" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm advanced-candidate
ADVANCED_HEAD="$(git -C "$TDIR/checkout" rev-parse HEAD)"
for mode in full-pr scoped-delta; do
  for position in reviewed advanced; do
    candidate="$HEAD"; [ "$position" != advanced ] || candidate="$ADVANCED_HEAD"
    git -C "$TDIR/checkout" checkout --detach -q "$candidate"
    new_case "coherent-$mode-$position"
    newer_completion
    HISTORICAL_INPUT="$NEW_INPUT"
    if [ "$mode" = scoped-delta ]; then HISTORICAL_INPUT="$(jq -cS --arg marker "$NEWER" '.marker=$marker | .charged_spend_epoch=1700000900' <<<"$SCOPED_INPUT")"; fi
    HISTORICAL_RESULT="$(jq -cS --arg ib "$(pg_review_sha256_text "$HISTORICAL_INPUT")" '.input_binding_digest=$ib' <<<"$NEW_RESULT")"
    printf '%s' "$HISTORICAL_INPUT" > "$PRO_GATE_HOME/review-input-bindings/$NEWER"
    printf '%s' "$HISTORICAL_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
    query
    applicability=null; [ "$position" != advanced ] || applicability=false
    check "coherent historical $mode SHIP at $position candidate remains accepted without current proof" ".status==\"accepted\" and .review.verdict==\"SHIP\" and .applicable==$applicability and (.selected_marker|endswith(\"1700000900-2\"))"
    for field in head_oid base_oid diff_digest; do
      BAD_VALUE='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; [ "$field" != diff_digest ] || BAD_VALUE='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      jq -cjS --arg field "$field" --arg value "$BAD_VALUE" '.ship_proof[$field]=$value' <<<"$HISTORICAL_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
      query
      check "historical $mode SHIP $field mismatch at $position candidate is invalid, never older fallback" '.status=="invalid" and .review==null and .applicable==null and (.selected_marker|endswith("1700000900-2"))'
    done
  done
done
git -C "$TDIR/checkout" checkout --detach -q "$HEAD"
new_case flags
for flag in --recover --harvest --brief --out --timeout --extra-files --review-decision-effect --review-choice-selection --prepare-review-evidence; do
  query "$flag" "$TDIR/must-not-be-created"
  CHECKS=$((CHECKS + 1))
  if [ "$RC" -eq 2 ] && [ ! -s "$TDIR/out.json" ] && [ ! -e "$TDIR/must-not-be-created" ]; then
    printf 'ok - incompatible %s rejects as usage before effects\n' "$flag"
  else
    printf 'FAIL - incompatible %s; exit=%s\n' "$flag" "$RC" >&2; cat "$TDIR/err" >&2; FAILS=$((FAILS + 1))
  fi
done
for flag in --status --review-decision; do
  query "$flag"
  CHECKS=$((CHECKS + 1))
  if [ "$RC" -eq 2 ] && [ ! -s "$TDIR/out.json" ]; then printf 'ok - incompatible %s rejects as usage\n' "$flag"; else FAILS=$((FAILS + 1)); fi
done
query --out ''
CHECKS=$((CHECKS + 1))
[ "$RC" -eq 2 ] || { printf 'FAIL - empty incompatible flag silently accepted\n' >&2; FAILS=$((FAILS + 1)); }
query --input typo
CHECKS=$((CHECKS + 1))
[ "$RC" -eq 2 ] || { printf 'FAIL - invalid explicit proof mode accepted\n' >&2; FAILS=$((FAILS + 1)); }
for candidate in '' short not-a-sha; do
  query --candidate-head "$candidate"
  CHECKS=$((CHECKS + 1))
  if [ "$RC" -eq 2 ] && grep -Fq -- '--candidate-head requires a full commit SHA' "$TDIR/err"; then
    printf 'ok - malformed explicit candidate rejects before effects\n'
  else
    printf 'FAIL - malformed explicit candidate accepted\n' >&2; FAILS=$((FAILS + 1))
  fi
done
for mode in fresh decision status; do
  mode_args=(); [ "$mode" != decision ] || mode_args=(--review-decision --json)
  [ "$mode" != status ] || mode_args=(--status --json)
  RC=0
  bash "$TDIR/installed/oracle-review.sh" --repo "$TDIR/checkout" --pr 1983 --candidate-head "$HEAD" "${mode_args[@]}" > "$TDIR/out.json" 2> "$TDIR/err" || RC=$?
  CHECKS=$((CHECKS + 1))
  if [ "$RC" -eq 2 ] && grep -Fq -- '--candidate-head is only supported' "$TDIR/err" && [ ! -e "$PG_FACTS_EFFECT_LOG" ]; then
    printf 'ok - explicit candidate cannot select %s execution\n' "$mode"
  else
    printf 'FAIL - explicit candidate escaped into %s mode\n' "$mode" >&2; FAILS=$((FAILS + 1))
  fi
done
query
check 'same invocation without incompatible flags is permitted' '.status=="accepted" and .applicable==null'
# Startup must not execute the inspected data root, even for malformed facts invocations.
new_case env-isolation
printf 'printf executed > "%s"\n' "$TDIR/env-executed" > "$PRO_GATE_HOME/.env"
for invocation in valid invalid missing-value; do
  args=(--review-facts --repo "$TDIR/checkout" --pr 1983 --json)
  [ "$invocation" != invalid ] || args=(--unknown --review-facts)
  [ "$invocation" != missing-value ] || args=(--review-facts --pr)
  RC=0
  bash "$TDIR/installed/oracle-review.sh" "${args[@]}" > "$TDIR/out.json" 2> "$TDIR/err" || RC=$?
  CHECKS=$((CHECKS + 1))
  expected=2; [ "$invocation" != valid ] || expected=0
  if [ "$RC" -eq "$expected" ] && [ ! -e "$TDIR/env-executed" ]; then printf 'ok - %s facts invocation never sources data-root env\n' "$invocation"; else FAILS=$((FAILS + 1)); printf 'FAIL - %s facts env isolation\n' "$invocation" >&2; fi
  rm -f "$TDIR/env-executed"
done
bash "$TDIR/installed/oracle-review.sh" --help > "$TDIR/help" 2> "$TDIR/err" || true
CHECKS=$((CHECKS + 1))
[ -e "$TDIR/env-executed" ] || { printf 'FAIL - normal mode lost env loading\n' >&2; FAILS=$((FAILS + 1)); }
rm -f "$TDIR/env-executed"
RC=0
bash "$TDIR/installed/oracle-review.sh" --out --review-facts --unknown > "$TDIR/out.json" 2> "$TDIR/err" || RC=$?
CHECKS=$((CHECKS + 1))
if [ "$RC" -eq 2 ] && [ -e "$TDIR/env-executed" ]; then printf 'ok - facts spelling used as an option value keeps normal env loading\n'; else FAILS=$((FAILS + 1)); printf 'FAIL - option value mistaken for facts mode\n' >&2; fi
rm -f "$TDIR/env-executed"
RC=0
bash "$TDIR/installed/oracle-review.sh" --out --review-facts --review-facts --json > "$TDIR/out.json" 2> "$TDIR/err" || RC=$?
CHECKS=$((CHECKS + 1))
if [ "$RC" -eq 2 ] && [ ! -e "$TDIR/env-executed" ]; then printf 'ok - facts flag following an option value still isolates startup\n'; else FAILS=$((FAILS + 1)); printf 'FAIL - facts flag hidden after an option value\n' >&2; fi
mkdir "$TDIR/standalone"
cp "$ROOT/bin/oracle-review.sh" "$TDIR/standalone/oracle-review.sh"
printf 'printf executed > "%s"\n' "$TDIR/fallback-executed" > "$PRO_GATE_HOME/lib.sh"
RC=0
bash "$TDIR/standalone/oracle-review.sh" --review-facts --json > "$TDIR/out.json" 2> "$TDIR/err" || RC=$?
CHECKS=$((CHECKS + 1))
if [ "$RC" -eq 10 ] && [ ! -e "$TDIR/fallback-executed" ]; then printf 'ok - facts without distribution lib refuses data-root fallback\n'; else FAILS=$((FAILS + 1)); printf 'FAIL - facts executed data-root library fallback\n' >&2; fi
printf '%s checks, %s failures\n' "$CHECKS" "$FAILS"
[ "$FAILS" -eq 0 ]
