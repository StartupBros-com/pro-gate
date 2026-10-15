#!/usr/bin/env bash
# #271 (U5): collection-to-decision characterization for a completed current response whose
# review validation fails. The shipped review-text expression reads a ChatGPT-shaped mock DOM
# (tests/mock-cdp.mjs `dom`), the real harvest retains or refuses the evidence, and the real
# --review-decision reads the same home afterwards. Isolated fixtures prove this contract; they
# are not a live reproduction of the better-ccflare#486 report that motivated it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-rejected-capture.XXXXXX")"
trap '[ -z "${MOCK_PID:-}" ] || kill "$MOCK_PID" 2>/dev/null; chmod -R u+rwX "$TDIR" 2>/dev/null; rm -rf "$TDIR"' EXIT
while IFS='=' read -r name _; do
  case "$name" in PRO_GATE_*|ORACLE_*) unset "$name" ;; esac
done < <(env)
export PRO_GATE_HOME="$TDIR/unused-home" PRO_GATE_LEDGER="$TDIR/unused-ledger.jsonl"
. "$ROOT/lib/pro-gate-lib.sh"
FAILS=0 CHECKS=0
check() {
  CHECKS=$((CHECKS + 1))
  if [ "$2" = 0 ]; then echo "ok - $1"; else echo "FAIL - $1"; FAILS=$((FAILS + 1)); fi
}

# No path below may send: any Oracle invocation is recorded and fails.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/oracle-calls"\nexit 99\n' "$TDIR" > "$TDIR/forbidden-oracle"
chmod +x "$TDIR/forbidden-oracle"

# Exact-current PR evidence for a real checkout, as tests/review-facts.test.sh builds it.
CHECKOUT="$TDIR/checkout"
mkdir -p "$CHECKOUT"
git -C "$CHECKOUT" init -q
git -C "$CHECKOUT" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm base
BASE="$(git -C "$CHECKOUT" rev-parse HEAD)"
printf 'one\n' > "$CHECKOUT/file.txt"
git -C "$CHECKOUT" add file.txt
git -C "$CHECKOUT" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm head
HEAD_OID="$(git -C "$CHECKOUT" rev-parse HEAD)"
git -C "$CHECKOUT" remote add origin https://github.com/acme/widgets.git
git -C "$CHECKOUT" diff "$BASE" "$HEAD_OID" > "$TDIR/endpoint.patch"
RAW="$(pg_sha256 "$TDIR/endpoint.patch")"
METADATA="$(jq -cnS --arg base "$BASE" --arg head "$HEAD_OID" '{repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{pr:1983,base_ref:"main",base_oid:$base,head_oid:$head}}')"
METADATA_DIGEST="$(pg_pr_evidence_metadata_digest "$(jq -cnS --argjson metadata "$METADATA" '{metadata:$metadata}')")"
jq -cnS --argjson metadata "$METADATA" --arg digest "$RAW" '{record_type:"review-pr-evidence/v1",record_version:1,patch_format:"github-compare-diff",metadata:$metadata,endpoint_digest:$digest}' > "$TDIR/pr-evidence.json"
ROUND_KEY=acme-widgets-1983
CONVERSATION=https://chatgpt.com/c/mock-conversation

binding() { # marker epoch -> exact-current review-input-binding/v1 for the checkout head
  jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$1" --argjson epoch "$2" \
    --arg base "$BASE" --arg head "$HEAD_OID" --arg raw "$RAW" --arg md "$METADATA_DIGEST" \
    '{charged_spend_epoch:$epoch,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("full-pr:"+$base+":"+$head),mode:"full-pr",proof:{base_oid:$base,head_oid:$head,endpoint_digest:$raw,raw_patch_digest:$raw,pr_metadata_digest:$md}},marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{head_oid:$head,kind:"pull-request",pr:1983}}'
}
attempt() { # home serial [no-binding]: one charged, reserved attempt; sets MARKER EPOCH BINDING OUT_FILE
  HOME_DIR="$1"; mkdir -p "$HOME_DIR"
  PRO_GATE_HOME="$HOME_DIR" pg_round_record "$ROUND_KEY"
  EPOCH="$PG_ROUND_SPEND_EPOCH"
  MARKER="pg-run-$ROUND_KEY-$EPOCH-$2"
  OUT_FILE="$HOME_DIR.out.md"
  PRO_GATE_HOME="$HOME_DIR" pg_run_meta_write "$MARKER" github.com acme widgets "$ROUND_KEY" 1983 "$OUT_FILE" "$EPOCH"
  PRO_GATE_HOME="$HOME_DIR" pg_reservation_write "$MARKER" "$ROUND_KEY" "$OUT_FILE" "" fixture "$EPOCH"
  PRO_GATE_HOME="$HOME_DIR" pg_review_tokens_write "$MARKER" "$TDIR/endpoint.patch"
  BINDING="$(binding "$MARKER" "$EPOCH")"
  [ "${3:-}" = no-binding ] || PRO_GATE_HOME="$HOME_DIR" pg_review_input_binding_write "$MARKER" "$BINDING"
  RECORD="$HOME_DIR/rejected-captures/$MARKER"
}

prompt() { printf 'Review the attached change.\n(run marker: %s — internal correlation id; echo it on the VERDICT line)' "$MARKER"; }
# better-ccflare#486's retained shape: a priority skeleton whose verdict names the marker in prose.
answer_271() { printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP (Documentation-only change; no actionable defects found. run marker: %s)' "$MARKER"; }
answer_unechoed() { printf 'P0: none\nP1: none\nP2: none\nP3: none\n\nChecked file.txt for regressions.\n\nVERDICT: SHIP'; }
answer_ungrounded() { printf 'P0: none\nP1: none\nP2: none\nP3: none\n\nChecked src/unknown.ts for regressions.\n\nVERDICT: SHIP (run marker: %s)' "$MARKER"; }
answer_grounded() { printf 'P0: none\nP1: none\nP2: none\nP3: none\n\nChecked file.txt for regressions.\n\nVERDICT: SHIP (run marker: %s)' "$MARKER"; }

page() { # generating(true|false) href turns-json|none: the conversation the next harvest reads
  local turns="$3"
  if [ "$turns" = none ]; then
    printf 'run marker: %s\n%s\n' "$MARKER" "$PAGE_FLAT" > "$TDIR/tab.txt"
    jq -n '{title:null,archived:false,events:[]}' > "$TDIR/cdp-state.json"
    return
  fi
  jq -r '[.[].text] | join("\n\n")' <<<"$turns" > "$TDIR/tab.txt"
  jq -n --argjson generating "$1" --arg href "$2" --argjson turns "$turns" \
    '{title:null,archived:false,events:[],dom:{generating:$generating,href:$href,turns:$turns}}' > "$TDIR/cdp-state.json"
}
turn() { jq -cn --arg role "$1" --arg text "$2" --argjson actions "$3" '{role:$role,text:$text,actions:$actions}'; }
turns() { jq -cs . ; }
completed_page() { # assistant-text: one marked prompt and one finished assistant response
  printf '%s\n%s\n' "$(turn user "$(prompt)" true)" "$(turn assistant "$1" true)" | turns
}

node "$ROOT/tests/mock-cdp.mjs" "$TDIR/tab.txt" "$TDIR/cdp-state.json" > "$TDIR/port" 2> "$TDIR/cdp.log" &
MOCK_PID=$!
printf 'no conversation yet\n' > "$TDIR/tab.txt"
for _ in $(seq 1 100); do [ -s "$TDIR/port" ] && break; sleep 0.1; done
PORT="$(cat "$TDIR/port")"

harvest() { # label: real harvest of $MARKER in $HOME_DIR -> HARVEST_RC
  env PRO_GATE_HOME="$HOME_DIR" PRO_GATE_LEDGER="$HOME_DIR.ledger.jsonl" \
    ORACLE_BROWSER_PORT="$PORT" PRO_GATE_BROWSER_MODE=remote-chrome PRO_GATE_ORACLE_BIN="$TDIR/forbidden-oracle" \
    PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_CHAT_RENAME=0 PRO_GATE_KEEP_TABS="${KEEP_TABS:-1}" \
    PRO_GATE_TEST_MODE=ci-fixture PRO_GATE_TEST_POLL_MS=100 PRO_GATE_TEST_COMPLETION_CONFIRM_MS=50 \
    bash "$ROOT/bin/oracle-review.sh" --harvest "$MARKER" --out "$OUT_FILE" --timeout 2s \
    > "$TDIR/$1.harvest.out" 2> "$TDIR/$1.harvest.err"
  HARVEST_RC=$?
}
snapshot() {
  find "$HOME_DIR" -exec stat -c '%n %F %a %s %Y' {} + | LC_ALL=C sort
  find "$HOME_DIR" -type f -readable -exec sha256sum {} + | LC_ALL=C sort
}
decide() { # label: real read-only decision over $HOME_DIR -> DECISION_RC, $TDIR/<label>.decision.json
  local before
  before="$(snapshot)"
  env PRO_GATE_HOME="$HOME_DIR" PRO_GATE_INPUT_POLICY=bundle-only PRO_GATE_BROWSER_ATTACHMENTS=auto \
    PRO_GATE_ORACLE_BIN="$TDIR/forbidden-oracle" \
    PRO_GATE_REVIEW_PR_EVIDENCE="$TDIR/pr-evidence.json" PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/endpoint.patch" \
    bash "$ROOT/bin/oracle-review.sh" --review-decision --repo "$CHECKOUT" --pr 1983 \
      --diff "$TDIR/endpoint.patch" --input bundle --json > "$TDIR/$1.decision.json" 2> "$TDIR/$1.decision.err"
  DECISION_RC=$?
  DECISION_PURE=1; [ "$before" = "$(snapshot)" ] && DECISION_PURE=0
}
decision_is() { # label action reason
  [ "$DECISION_RC" = 0 ] && [ "$DECISION_PURE" = 0 ] && pg_review_decision_envelope_valid "$TDIR/$1.decision.json" \
    && jq -e --arg a "$2" --arg r "$3" '.action==$a and .reason==$r' "$TDIR/$1.decision.json" >/dev/null
}
retained() { # label: the charged attempt keeps every recovery handle and publishes nothing
  [ ! -e "$OUT_FILE" ] && [ ! -e "$HOME_DIR/completed/$MARKER" ] && [ ! -e "$HOME_DIR/pending/$MARKER" ] \
    && [ ! -e "$HOME_DIR/attempt-dispositions/$MARKER" ] && [ -s "$HOME_DIR/in-progress/$MARKER" ] \
    && [ ! -e "$(PRO_GATE_HOME="$HOME_DIR" pg_review_result_binding_dir)/$MARKER" ] \
    && PRO_GATE_HOME="$HOME_DIR" pg_round_has_epoch "$ROUND_KEY" "$EPOCH" \
    && { [ "${2:-}" = no-binding ] || [ "$(PRO_GATE_HOME="$HOME_DIR" pg_review_input_binding_read "$MARKER")" = "$BINDING" ]; } \
    && ! grep -q RESULT_FILE "$TDIR/$1.harvest.out" \
    && { [ ! -s "$HOME_DIR.ledger.jsonl" ] || jq -se 'all(.[]; .outcome != "clean")' "$HOME_DIR.ledger.jsonl" >/dev/null; }
}
kept_bytes() { # rejection: the operator-visible retained capture for this harvest
  case "$1" in
    unbound) find "$(dirname "$OUT_FILE")" -maxdepth 1 -name "$(basename "$OUT_FILE").unbound.*" -print -quit ;;
    *) find "$(dirname "$OUT_FILE")" -maxdepth 1 -name "$(basename "$OUT_FILE").rejected.*" -print -quit ;;
  esac
}
record_ok() { # rejection: one write-once private record binding bytes to attempt, input and conversation
  local kept
  kept="$(kept_bytes "$1")"
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] && [ "$(stat -c %a "$RECORD")" = 600 ] && [ -s "$kept" ] \
    && jq -e --arg marker "$MARKER" --arg rejection "$1" --argjson epoch "$EPOCH" --arg url "$CONVERSATION" \
      --arg ib "$(pg_review_sha256_text "$BINDING")" --arg digest "$(pg_sha256 "$kept")" --rawfile bytes "$kept" '
      .record_type=="rejected-capture/v1" and .record_version==1 and .marker==$marker
      and .rejection==$rejection and .charged_spend_epoch==$epoch and .input_binding_digest==$ib
      and .conversation_url==$url and .capture==$bytes and .capture_sha256==$digest' "$RECORD" >/dev/null
}
stop_row_ok() { # label: the typed stop names this marker and the retained bytes, never authority
  [ -s "$RECORD" ] && jq -e --arg marker "$MARKER" --arg digest "$(jq -r .capture_sha256 "$RECORD")" '
    .effect_request.applicable_ref==$marker and
    any(.facts.completed_results[]; .marker==$marker and .shape=="rejected-capture" and .artifact_digest==$digest
      and .applicable==false and .verdict=="NONE" and .provenance_valid==false and .bindable==false)' \
    "$TDIR/$1.decision.json" >/dev/null
}

# ── 1. better-ccflare#486 shape, completed and in scope: one stable typed stop ──────────────────
attempt "$TDIR/home-271" 1
page false "$CONVERSATION" "$(completed_page "$(answer_271)")"
KEEP_TABS=0 harvest t271
check '#271: completed template answer is still refused at harvest (exit 6)' "$([ "$HARVEST_RC" = 6 ]; echo $?)"
check '#271: refusal never archives or closes the conversation, even with tab cleanup enabled' "$(jq -e '(.events // []) == [] and ((.closed // []) | index("tab1")) == null' "$TDIR/cdp-state.json" >/dev/null; echo $?)"
check '#271: refusal keeps charge, reservation and input binding and publishes nothing' "$(retained t271; echo $?)"
check '#271: refusal writes one private record binding the bytes to attempt, input and conversation' "$(record_ok template-verdict; echo $?)"
decide t271
check '#271: next decision is the typed stop, not another recovery' "$(decision_is t271 stop-without-new-review rejected-capture; echo $?)"
check '#271: typed stop facts name the retained bytes without accepted authority' "$(stop_row_ok t271; echo $?)"
cp "$RECORD" "$TDIR/t271.record" 2>/dev/null || :
harvest t271-again
check '#271: a restarted harvest stays refused and keeps every handle' "$([ "$HARVEST_RC" = 6 ] && retained t271-again; echo $?)"
check '#271: the record is write-once across restarts' "$(cmp -s "$TDIR/t271.record" "$RECORD"; echo $?)"
decide t271-again
check '#271: the stop is stable across restart' "$(decision_is t271-again stop-without-new-review rejected-capture && jq -e --slurpfile first "$TDIR/t271.decision.json" '.facts.completed_results==$first[0].facts.completed_results and .effect_request.applicable_ref==$first[0].effect_request.applicable_ref' "$TDIR/t271-again.decision.json" >/dev/null; echo $?)"
T271_HOME="$HOME_DIR" T271_MARKER="$MARKER" T271_EPOCH="$EPOCH" T271_BINDING="$BINDING"

# ── 2. A grounded completion without the run-marker echo stays unaccepted but stops typed ───────
attempt "$TDIR/home-unechoed" 2
page false "$CONVERSATION" "$(completed_page "$(answer_unechoed)")"
harvest unechoed
check 'nonce rule unchanged: an unechoed completion is not accepted (exit 9)' "$([ "$HARVEST_RC" = 9 ] && retained unechoed; echo $?)"
check 'unechoed completion is retained as an unbound rejected capture' "$(record_ok unbound; echo $?)"
decide unechoed
check 'unechoed completion stops typed instead of recovering forever' "$(decision_is unechoed stop-without-new-review rejected-capture && stop_row_ok unechoed; echo $?)"

# ── 3. Reinspection after a classifier/vocabulary repair: no silent resumption, no rewrite ──────
attempt "$TDIR/home-repair" 3
page false "$CONVERSATION" "$(completed_page "$(answer_ungrounded)")"
harvest repair
check 'shape rule unchanged: an ungrounded echoed completion is refused (exit 6)' "$([ "$HARVEST_RC" = 6 ] && retained repair; echo $?)"
check 'ungrounded echoed completion is retained as a rejected capture' "$(record_ok template-verdict; echo $?)"
cp "$RECORD" "$TDIR/repair.record" 2>/dev/null || :
# Simulated repair: the retained vocabulary now names the cited path, so the bytes would pass.
printf '%s\n' src/unknown.ts unknown.ts >> "$(PRO_GATE_HOME="$HOME_DIR" pg_review_tokens_dir)/$MARKER"
decide repair-after
check 'repair does not resume the stopped owner by itself' "$(decision_is repair-after stop-without-new-review rejected-capture; echo $?)"
check 'reclassification never rewrites retained bytes' "$(cmp -s "$TDIR/repair.record" "$RECORD"; echo $?)"
harvest repair-reinspect
check 'an explicit reinspection may collect the repaired completion' "$([ "$HARVEST_RC" = 0 ] && [ -s "$HOME_DIR/completed/$MARKER" ] && grep -q RESULT_FILE "$TDIR/repair-reinspect.harvest.out"; echo $?)"
decide repair-reinspected
check 'the collected completion, not the retained rejection, drives the next decision' "$([ "$DECISION_RC" = 0 ] && jq -e '.reason != "rejected-capture" and (.action=="allow-existing-merge-workflow" or .action=="collect-existing-result")' "$TDIR/repair-reinspected.decision.json" >/dev/null && cmp -s "$TDIR/repair.record" "$RECORD"; echo $?)"

# ── 4. Without proven completion and scope the capture stays ambiguous (recover, no record) ─────
# Flat text is today's mock shape: the same bytes with no DOM, so no response scope is provable.
attempt "$TDIR/home-flat" 10
PAGE_FLAT="$(answer_271)"
page false "$CONVERSATION" none
harvest flat
check 'flat text without DOM scope: harvest outcome unchanged (exit 6)' "$([ "$HARVEST_RC" = 6 ]; echo $?)"
check 'flat text without DOM scope: no record and every handle kept' "$([ ! -e "$RECORD" ] && retained flat; echo $?)"
decide flat
check 'flat text without DOM scope: decision keeps recovering' "$(decision_is flat recover-existing-review active-work-requires-recovery; echo $?)"
# Each page needs the marker attempt() mints, so the page is assembled after it.
ambiguous_page() { # label serial rc generating href kind
  attempt "$TDIR/home-$1" "$2"
  local user assistant
  user="$(turn user "$(prompt)" true)"
  case "$6" in
    generating) assistant="$(turn assistant "$(answer_271)" false)"; set -- "$1" "$2" "$3" true "$5" "$(printf '%s\n%s\n' "$user" "$assistant" | turns)" ;;
    unfinished) assistant="$(turn assistant "$(answer_271)" false)"; set -- "$1" "$2" "$3" false "$5" "$(printf '%s\n%s\n' "$user" "$assistant" | turns)" ;;
    newer-user) assistant="$(turn assistant "$(answer_271)" true)"; set -- "$1" "$2" "$3" false "$5" "$(printf '%s\n%s\n%s\n' "$user" "$assistant" "$(turn user 'One more question about the change.' true)" | turns)" ;;
    resent) assistant="$(turn assistant "$(answer_271)" true)"; set -- "$1" "$2" "$3" false "$5" "$(printf '%s\n%s\n%s\n' "$user" "$assistant" "$user" | turns)" ;;
    two-assistant) assistant="$(turn assistant "$(answer_271)" true)"; set -- "$1" "$2" "$3" false "$5" "$(printf '%s\n%s\n%s\n' "$user" "$(turn assistant 'Reading the diff now.' true)" "$assistant" | turns)" ;;
    foreign) assistant="$(turn assistant "$(answer_271 | sed 's/run marker: pg-run-[A-Za-z0-9.-]*/(run marker: pg-run-acme-other-999-1700000000-7)/')" true)"; set -- "$1" "$2" "$3" false "$5" "$(printf '%s\n%s\n' "$user" "$assistant" | turns)" ;;
    unmarked-prompt) assistant="$(turn assistant "$(printf 'Quoting your request: run marker: %s\n\n%s' "$MARKER" "$(answer_271)")" true)"; set -- "$1" "$2" "$3" false "$5" "$(printf '%s\n%s\n' "$(turn user 'Review the attached change.' true)" "$assistant" | turns)" ;;
    *) assistant="$(turn assistant "$(answer_271)" true)"; set -- "$1" "$2" "$3" false "$5" "$(printf '%s\n%s\n' "$user" "$assistant" | turns)" ;;
  esac
  page "$4" "$5" "$6"
  harvest "$1"
  check "$1: harvest outcome unchanged (exit $3)" "$([ "$HARVEST_RC" = "$3" ]; echo $?)"
  check "$1: no rejected-capture record and every handle kept" "$([ ! -e "$RECORD" ] && retained "$1"; echo $?)"
  decide "$1"
  check "$1: decision keeps recovering the attempt" "$(decision_is "$1" recover-existing-review active-work-requires-recovery; echo $?)"
}
ambiguous_page generating 11 6 true "$CONVERSATION" generating
ambiguous_page unfinished-actions 12 6 false "$CONVERSATION" unfinished
ambiguous_page newer-user-turn 13 6 false "$CONVERSATION" newer-user
# A re-sent prompt has no answer yet (still generating, exit 9). Two assistant turns hit the
# nonce refusal (exit 9) and a foreign echo is cross-bound (miss, exit 9): none may record.
ambiguous_page resent-same-marker 14 9 false "$CONVERSATION" resent
ambiguous_page two-assistant-turns 15 9 false "$CONVERSATION" two-assistant
ambiguous_page foreign-echo 16 9 false "$CONVERSATION" foreign
ambiguous_page unmarked-prompt 17 6 false "$CONVERSATION" unmarked-prompt
ambiguous_page other-conversation 18 6 false https://chatgpt.com/c/another-conversation in-scope

# An attempt without an immutable input binding cannot be bound, whatever the page shows.
attempt "$TDIR/home-unbound-input" 19 no-binding
page false "$CONVERSATION" "$(completed_page "$(answer_271)")"
harvest unbound-input
check 'missing input binding: harvest outcome unchanged and no record' "$([ "$HARVEST_RC" = 6 ] && [ ! -e "$RECORD" ] && retained unbound-input no-binding; echo $?)"

# ── 5. Retention failure surfaces and leaves recovery state intact ───────────────────────────────
attempt "$TDIR/home-storage" 20
mkdir -p "$HOME_DIR/rejected-captures" && chmod 500 "$HOME_DIR/rejected-captures"
if [ -w "$HOME_DIR/rejected-captures" ]; then
  echo 'ok - storage failure case skipped: directory permissions are not enforced for this user'
else
  page false "$CONVERSATION" "$(completed_page "$(answer_271)")"
  harvest storage
  check 'retention failure: refusal exit unchanged and every handle kept' "$([ "$HARVEST_RC" = 6 ] && [ ! -e "$RECORD" ] && retained storage; echo $?)"
  check 'retention failure is reported, not silent' "$(grep -Eqi 'rejected-capture record.*(could not|failed|unwritable)' "$TDIR/storage.harvest.err"; echo $?)"
  decide storage
  check 'retention failure: decision keeps recovering' "$(decision_is storage recover-existing-review active-work-requires-recovery; echo $?)"
fi
chmod 700 "$HOME_DIR/rejected-captures"

# ── 6. A damaged, partial or foreign record never terminalizes ───────────────────────────────────
damaged() { # label jq-filter|partial|truncated
  HOME_DIR="$TDIR/home-$1" MARKER="$T271_MARKER" EPOCH="$T271_EPOCH" BINDING="$T271_BINDING"
  if [ ! -s "$TDIR/t271.record" ]; then
    check "$1: decision stays recover, never the typed stop (needs the #271 record)" 1
    return
  fi
  cp -R "$T271_HOME" "$HOME_DIR"
  RECORD="$HOME_DIR/rejected-captures/$MARKER"
  if [ "$2" = partial ]; then
    mv "$RECORD" "$RECORD.tmp.4242"
    head -c 40 "$RECORD.tmp.4242" > "$RECORD.tmp.4242.cut" && mv "$RECORD.tmp.4242.cut" "$RECORD.tmp.4242"
  elif [ "$2" = truncated ]; then
    head -c 40 "$TDIR/t271.record" > "$RECORD"
  else
    jq -c "$2" "$TDIR/t271.record" > "$RECORD"
  fi
  decide "$1"
  check "$1: decision stays recover, never the typed stop" "$(decision_is "$1" recover-existing-review active-work-requires-recovery; echo $?)"
}
damaged tampered-bytes '.capture += "\nP1: injected"'
damaged tampered-digest '.capture_sha256 = ("0" * 64)'
damaged other-input '.input_binding_digest = ("1" * 64)'
damaged other-marker '.marker = "pg-run-acme-widgets-1983-1700000000-99"'
damaged truncated truncated
damaged interrupted-write partial

# ── 7. A newer live attempt for the same head is recovered, not stopped by an older rejection ───
# The older attempt is released by the real proven supersession, so the snapshot selects the
# newer reservation while the older record stays exact-current and valid.
HOME_DIR="$TDIR/home-newer"
cp -R "$T271_HOME" "$HOME_DIR"
OLD_MARKER="$T271_MARKER"
PRO_GATE_HOME="$HOME_DIR" pg_reservation_supersede "$OLD_MARKER" "$ROUND_KEY" "$T271_EPOCH" "$HEAD_OID"
SUPERSEDE_RC=$?
sleep 1
attempt "$HOME_DIR" 21
decide newer
check 'newer live attempt: the older rejection does not stop its recovery' "$([ -s "$TDIR/t271.record" ] && [ -s "$HOME_DIR/rejected-captures/$OLD_MARKER" ] && [ "$SUPERSEDE_RC" = 0 ] && decision_is newer recover-existing-review active-work-requires-recovery && jq -e --arg m "$MARKER" --arg old "$OLD_MARKER" '.effect_request.applicable_ref==$m and .effect_request.applicable_ref!=$old and any(.facts.completed_results[]; .marker==$old and .shape=="rejected-capture")' "$TDIR/newer.decision.json" >/dev/null; echo $?)"

# ── 8. Proof never changes acceptance of a valid completion ─────────────────────────────────────
attempt "$TDIR/home-accepted" 22
page false "$CONVERSATION" "$(completed_page "$(answer_grounded)")"
harvest accepted
check 'valid completion with proof is accepted exactly as before' "$([ "$HARVEST_RC" = 0 ] && [ -s "$HOME_DIR/completed/$MARKER" ] && [ ! -e "$RECORD" ] && grep -q RESULT_FILE "$TDIR/accepted.harvest.out"; echo $?)"
decide accepted
check 'accepted completion never reports a rejected capture' "$([ "$DECISION_RC" = 0 ] && jq -e '.action != "stop-without-new-review"' "$TDIR/accepted.decision.json" >/dev/null; echo $?)"

check 'no path invoked Oracle or sent a new review' "$([ ! -e "$TDIR/oracle-calls" ]; echo $?)"
echo "$CHECKS checks, $FAILS failures"
[ "$FAILS" = 0 ] && { echo 'ALL PASS'; exit 0; }
exit 1
