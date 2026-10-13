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
printf 'P0: none\nP1: none\nP2: none\nAll reviewed changes are consistent.\nVERDICT: SHIP\n' > "$PRO_GATE_HOME/completed/$MARKER"
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
  bash "$TDIR/installed/oracle-review.sh" --review-facts --repo "$TDIR/checkout" --pr 1983 --json "$@" > "$TDIR/out.json" 2> "$TDIR/err" || RC=$?
  after="$(snapshot)"
  [ "$before" = "$after" ] || { printf 'FAIL - public inspection mutated runtime state\n' >&2; exit 1; }
  [ ! -e "$PG_FACTS_EFFECT_LOG" ] || { printf 'FAIL - effect entrypoint invoked\n' >&2; cat "$PG_FACTS_EFFECT_LOG" >&2; exit 1; }
}
query
if [ "$RC" -ne 0 ] || ! jq -e --arg head "$HEAD" --arg digest "$DIGEST" --arg marker "$MARKER" --arg canonical "$(pg_review_sha256_text "$RESULT")" '.schema=="review-facts/v1" and .status=="accepted" and .selected_marker==$marker and .candidate_head==$head and .applicable==null and .review.reviewed_head==$head and .review.artifact_digest==$digest and .review.canonical_identity==$canonical and .review.verdict=="SHIP" and .review.open_p0==0 and .review.open_p1==0' "$TDIR/out.json"; then
  printf 'FAIL - installed public CLI returns retained facts without current proof; exit=%s\n' "$RC" >&2
  cat "$TDIR/err" >&2
  exit 1
fi
printf 'ok - installed public CLI returns retained facts with unknown applicability despite invalid fresh policy; all runtime state unchanged\n'
CHECKS=1 FAILS=0
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
  pg_review_input_binding_write "$NEWER" "$NEW_INPUT"
  pg_review_result_binding_write "$NEWER" "$NEW_RESULT"
}
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
check 'canonical other-host input disambiguates the same marker key even without a run sidecar' '.status=="accepted" and (.selected_marker|endswith("1700000700-1"))'
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
printf '[P0] f:1 - RESOLVED - already fixed\n[P0] f:2 - the RESOLVED state is forgeable\n[P1] f:3 - RESOLVED_MODEL is clobbered\nVERDICT: FIX-FIRST\n' > "$PRO_GATE_HOME/completed/$NEWER"
FIX_RESULT="$(jq -cS --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$NEWER")" '.artifact.digest=$digest | .verdict="FIX-FIRST" | .ship_proof=null' <<<"$NEW_RESULT")"
printf '%s' "$FIX_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$NEWER"
# A deliberately favorable mutable round tuple must not provide the public counts.
printf '0,0,0\n' > "$PRO_GATE_HOME/rounds/acme-widgets-1983.last"
query
check 'newest FIX-FIRST wins over older SHIP and reports artifact-bound U1 open severity' '.status=="accepted" and .review.verdict=="FIX-FIRST" and .review.open_p0==1 and .review.open_p1==1 and .applicable==null'
current_proof
query --diff "$TDIR/endpoint.patch"
check 'applicability is separate from verdict: a matching FIX-FIRST review is applicable' '.status=="accepted" and .applicable==true and .review.verdict=="FIX-FIRST"'
new_case choices
printf '[P1] f:1 - select a compatibility policy\nCHOICE: keep | Preserve | Keep compatibility\nCHOICE: break | Replace | Use new API\nVERDICT: NEEDS-DISCUSSION\n' > "$PRO_GATE_HOME/completed/$MARKER"
CHOICE_RESULT="$(jq -cS --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$MARKER")" '.artifact.digest=$digest | .verdict="NEEDS-DISCUSSION" | .ship_proof=null' <<<"$RESULT")"
printf '%s' "$CHOICE_RESULT" > "$PRO_GATE_HOME/review-result-bindings/$MARKER"
query
check 'named choices come from accepted artifact bytes without choosing for the owner' '.status=="accepted" and .review.named_choice==null and (.review.named_choices|map(.id))==["keep","break"] and .review.open_p1==1'
for verdict in FIX-FIRST SHIP; do
  printf 'P0: none\nP1: none\nCHOICE: keep | Preserve | Keep compatibility\nCHOICE: break | Replace | Use new API\nVERDICT: %s\n' "$verdict" > "$PRO_GATE_HOME/completed/$MARKER"
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
query
check 'same invocation without incompatible flags is permitted' '.status=="accepted" and .applicable==null'
printf '%s checks, %s failures\n' "$CHECKS" "$FAILS"
[ "$FAILS" -eq 0 ]
