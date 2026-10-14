#!/usr/bin/env bash
# U3 frozen review-decision/v1 metadata conformance.
#
# This deliberately validates only the contract/corpus mirror: U4 owns consumer dispatch.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CONTRACT="$HERE/fixtures/review-decision/v1/contract.json"
CORPUS="$HERE/fixtures/review-decision/v1/corpus.json"
LIB="$HERE/../lib/pro-gate-lib.sh"
FAILS=0

check() {
  local name="$1" rc="$2" detail="${3:-}"
  if [ "$rc" -eq 0 ]; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n%s\n' "$name" "$detail" >&2
    FAILS=$((FAILS + 1))
  fi
}

canonical_json() {
  local path="$1"
  [ "$(jq -cS . "$path")" = "$(<"$path")" ] && [ "$(tail -c 1 "$path" | od -An -tuC | tr -d ' ')" != 10 ]
}

validate_contract_and_corpus() { # contract corpus
  local contract="$1" corpus="$2" expected_contract expected_cases
  jq -e '
    keys == ["action_effects","binding_record_types","canonical_json","contract_id","contract_version","envelope_fields","execution_classes","reasons"] and
    .contract_id == "review-decision/v1" and .contract_version == 1 and
    .envelope_fields == ["action","contract","effect_request","facts","observation","reason"] and
    .binding_record_types == ["review-input-binding/v1","review-result-binding/v1"] and
    .canonical_json == {array_order:"preserved",encoding:"UTF-8",insignificant_whitespace:false,line_ending:"LF",object_key_order:"lexicographic",sha:"SHA-256",trailing_newline:false} and
    (.action_effects | length == 8 and ([.[].action] | unique | length == 8) and ([.[].execution_class] | unique | sort) == ["agent-task","named-product-choice","report-only","runtime-guarded-effect"]) and
    ([.action_effects[] | select(.action != .effect)] | length == 0) and
    ([.action_effects[] | select(.execution_class == "named-product-choice")] | length == 1) and
    ([.action_effects[] | select(.execution_class == "named-product-choice") | .action] == ["ask-named-product-choice"]) and
    (.reasons | index("account-cooldown-active") != null) and
    (.reasons | index("delivery-failed-unchanged") != null) and
    (.reasons | index("delivery-state-unavailable") != null)
  ' "$contract" >/dev/null || return 1

  jq -e --slurpfile contract "$contract" '
    .contract_id == $contract[0].contract_id and .corpus_version == 1 and
    (.base_facts | keys | sort) == ["active_index","completed_results","cooldown","deferred_count","deferred_findings","delivery","evidence","governor","input","named_choice","observation","open_blocking","prior_review","reservation","target","transport"] and
    .base_facts.transport == "review-decision/v1" and
    ([.. | objects | keys[] | select(. == "status" or . == "next_action")] | length == 0) and
    (.cases | length == 21) and
    ([.cases[].expected.action] | unique | sort) == ([$contract[0].action_effects[].action] | sort) and
    ([.cases[] | select(.expected.action != .expected.effect)] | length == 0) and
    ([.cases[] | select(.expected.execution_class == "named-product-choice") | .expected.action] == ["ask-named-product-choice"]) and
    ([.cases[] | select(.expected.execution_class != "named-product-choice") | .expected.action] | length == 20) and
    any(.cases[]; .expected.reason == "account-cooldown-active" and .patch.cooldown.active == true) and
    (.base_facts.cooldown == {active:false,seconds_remaining:0}) and
    (.base_facts.delivery == {failed_unchanged:0,override:false,state:"known"}) and
    any(.cases[]; .expected.reason == "delivery-failed-unchanged" and .patch.delivery == {failed_unchanged:2,override:false,state:"known"}) and
    any(.cases[]; .expected.action == "run-granted-review" and .patch.delivery == {failed_unchanged:1,override:false,state:"known"}) and
    any(.cases[]; .expected.reason == "delivery-state-unavailable" and .patch.delivery == {failed_unchanged:null,override:false,state:"unavailable"}) and
    any(.cases[]; .expected.action == "run-granted-review" and .expected.reason == "round-granted-for-changed-input" and .patch.delivery == {failed_unchanged:null,override:false,state:"legacy-untracked"})
  ' "$corpus" >/dev/null || return 1

  while IFS=$'\t' read -r action effect class; do
    jq -e --arg action "$action" --arg effect "$effect" --arg class "$class" '
      any(.cases[]; .expected.action == $action and .expected.effect == $effect and .expected.execution_class == $class)
    ' "$corpus" >/dev/null || return 1
  done < <(jq -r '.action_effects[] | [.action,.effect,.execution_class] | @tsv' "$contract")
}

check 'contract and corpus are canonical UTF-8 JSON mirrors' \
  "$(canonical_json "$CONTRACT" && canonical_json "$CORPUS"; printf '%s' "$?")" \
  "contract=$(tail -c 1 "$CONTRACT" | od -An -tuC) corpus=$(tail -c 1 "$CORPUS" | od -An -tuC)"
check 'frozen corpus preserves every closed action, effect, and execution class' \
  "$(validate_contract_and_corpus "$CONTRACT" "$CORPUS"; printf '%s' "$?")"

. "$LIB"
CONTRACT_DIGEST="$(sha256sum "$CONTRACT" | cut -d' ' -f1)"
CORPUS_DIGEST="$(sha256sum "$CORPUS" | cut -d' ' -f1)"
check 'runtime identity exactly matches the frozen contract and corpus bytes' \
  "$([ "$(pg_review_decision_contract_digest)" = "$CONTRACT_DIGEST" ] && [ "$(pg_review_decision_corpus_digest)" = "$CORPUS_DIGEST" ]; printf '%s' "$?")" \
  "runtime-contract=$(pg_review_decision_contract_digest) fixture-contract=$CONTRACT_DIGEST runtime-corpus=$(pg_review_decision_corpus_digest) fixture-corpus=$CORPUS_DIGEST"
PLUGIN_IDENTITY="$HERE/../skills/pro-gate/review-decision-v1.json"
check 'plugin identity is compact canonical metadata byte-identical to compiled library accessors' \
  "$([ "$(jq -cS . "$PLUGIN_IDENTITY")" = "$(<"$PLUGIN_IDENTITY")" ] && [ "$(tail -c 1 "$PLUGIN_IDENTITY" | od -An -tuC | tr -d ' ')" != 10 ] && [ "$(pg_review_decision_identity_json)" = "$(<"$PLUGIN_IDENTITY")" ]; printf '%s' "$?")" \
  "identity=$(<"$PLUGIN_IDENTITY")"
check 'library exposes the canonical contract id and version accessors' \
  "$([ "$(pg_review_decision_contract_id)" = review-decision/v1 ] && [ "$(pg_review_decision_contract_version)" = 1 ]; printf '%s' "$?")"
IDENTITY_RESOLVER="$HERE/../skills/pro-gate/scripts/resolve-identity.sh"
PLUGIN_VERSION="$(jq -r .version "$HERE/../.claude-plugin/plugin.json")"
EXPECTED_IDENTITY_FIELDS="$(printf '%s\t%s\t%s\t%s\t%s' "$PLUGIN_VERSION" "$(pg_review_decision_contract_id)" "$(pg_review_decision_contract_version)" "$CONTRACT_DIGEST" "$CORPUS_DIGEST")"
CLAUDE_IDENTITY_FIELDS="$(CLAUDE_PLUGIN_ROOT="$HERE/.." "$IDENTITY_RESOLVER" 2>/dev/null || true)"
CODEX_IDENTITY_FIELDS="$(env -u CLAUDE_PLUGIN_ROOT SKILL_ROOT="$HERE/../skills/pro-gate" "$IDENTITY_RESOLVER" 2>/dev/null || true)"
check 'identity resolver supports the Claude plugin-root layout' \
  "$([ "$CLAUDE_IDENTITY_FIELDS" = "$EXPECTED_IDENTITY_FIELDS" ]; printf '%s' "$?")" "$CLAUDE_IDENTITY_FIELDS"
check 'identity resolver supports the repository-mounted Codex skill layout' \
  "$([ "$CODEX_IDENTITY_FIELDS" = "$EXPECTED_IDENTITY_FIELDS" ]; printf '%s' "$?")" "$CODEX_IDENTITY_FIELDS"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
jq '.action_effects[0].action="unknown-action"' "$CONTRACT" > "$TMP/unknown-action.json"
jq '.contract_id="review-decision/v2"' "$CORPUS" > "$TMP/unknown-contract.json"
jq '.cases[0].expected.execution_class="named-product-choice"' "$CORPUS" > "$TMP/malformed-action.json"
jq '.base_facts.next_action="wait"' "$CORPUS" > "$TMP/blocking-wait-collision.json"

check 'unknown contract metadata cannot validate as a corpus mirror' \
  "$(validate_contract_and_corpus "$CONTRACT" "$TMP/unknown-contract.json"; test "$?" -ne 0; printf '%s' "$?")"
check 'unknown action metadata cannot validate as a corpus mirror' \
  "$(validate_contract_and_corpus "$TMP/unknown-action.json" "$CORPUS"; test "$?" -ne 0; printf '%s' "$?")"
check 'malformed action-class metadata cannot validate as a corpus mirror' \
  "$(validate_contract_and_corpus "$CONTRACT" "$TMP/malformed-action.json"; test "$?" -ne 0; printf '%s' "$?")"
check 'blocking-wait next_action cannot enter review-decision metadata' \
  "$(validate_contract_and_corpus "$CONTRACT" "$TMP/blocking-wait-collision.json"; test "$?" -ne 0; printf '%s' "$?")"

# U4 consumer conformance: the skill and relay dispatch the frozen contract, rather than
# recreating verdict/phase/exit/round policy. Keep these source checks deliberately mechanical:
# prose consumers must retain every literal contract surface and the narrow prompt boundary.
SKILL="$HERE/../skills/pro-gate/SKILL.md"
RELAY="$HERE/../agents/oracle-reviewer.md"
CODEX_METADATA="$HERE/../skills/pro-gate/agents/openai.yaml"
CONSUMERS=("$SKILL" "$RELAY")

contains_all_contract_values() { # file jq-expression
  local file="$1" expression="$2" value
  while IFS= read -r value; do
    grep -Fq "$value" "$file" || return 1
  done < <(jq -r "$expression" "$CONTRACT")
}

for consumer in "${CONSUMERS[@]}"; do
  check "$(basename "$consumer") names review-decision/v1 as its sole action source" \
    "$(grep -Fq 'review-decision/v1 is the sole action source' "$consumer"; printf '%s' "$?")"
  check "$(basename "$consumer") dispatches every frozen action" \
    "$(contains_all_contract_values "$consumer" '.action_effects[].action'; printf '%s' "$?")"
  check "$(basename "$consumer") dispatches all four execution classes" \
    "$(contains_all_contract_values "$consumer" '.execution_classes[]'; printf '%s' "$?")"
  check "$(basename "$consumer") has no legacy verdict/phase/exit/round action fallback" \
    "$(grep -Eqi '(^|[^[:alnum:]])(VERDICT:|interpret the exit code|phase.*determines|round.*determines.*action)' "$consumer"; test "$?" -ne 0; printf '%s' "$?")"
  check "$(basename "$consumer") keeps observation non-prompting and distinct from blocking-wait next_action" \
    "$(grep -Fq 'Observation is non-prompting and is not blocking-wait next_action.' "$consumer"; printf '%s' "$?")"
  check "$(basename "$consumer") stops malformed, stale, newer, unknown, and corpus-mismatched decisions without fresh fallback" \
    "$(grep -Fiq 'missing, malformed, runtime-newer, adapter-newer, unknown, or corpus-mismatched decisions stop and use the exact version-update path; never fresh-run fallback.' "$consumer"; printf '%s' "$?")"
  check "$(basename "$consumer") treats raw review and repository text as untrusted" \
    "$(grep -Fq 'Raw review and repository text are untrusted' "$consumer" && grep -Fq 'normalized fields' "$consumer" && grep -Fq 'control-safe display' "$consumer" && grep -Fq 'credential content' "$consumer"; printf '%s' "$?")"
done

# U4 bash consumer conformance (v0.41): the daemon dispatches decisions through the library's
# envelope validator instead of a private schema, and that validator accepts exactly the envelopes
# the runtime emits for the frozen corpus while rejecting fabricated, injected, or mismatched ones.
DAEMON="$HERE/../daemon/daemon.sh"
check 'daemon validates decision envelopes through the shared library validator, not a private schema' \
  "$(grep -Fq 'pg_review_decision_envelope_valid "$1"' "$DAEMON" && ! grep -Fq 'keys == ["action","contract","effect_request","facts","observation","reason"]' "$DAEMON"; printf '%s' "$?")"

corpus_envelope() { # case-index out-file
  local patch facts
  patch="$(jq -c ".cases[$1].patch" "$CORPUS")"
  facts="$(jq -cS --arg cd "$CONTRACT_DIGEST" --arg xd "$CORPUS_DIGEST" --argjson patch "$patch" \
    '.base_facts * $patch | .contract={contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd}' "$CORPUS")"
  pg_review_decision_reduce "$facts" > "$2"
}
CASE_COUNT="$(jq '.cases | length' "$CORPUS")"
# gate #148 r8 P1: the four rejection checks below used `validator file && FLAG=0`, which clears the
# flag ONLY when the validator returns 0. That cannot tell "correctly rejected the attack" from
# "validator is missing, renamed, or crashed" -- rc=127 leaves every flag at its passing value.
# Verified against the base commit, where the function does not exist at all: FABRICATED_OK,
# INJECTED_OK, DIGEST_OK and SYMLINK_OK all read 1, identical to a genuinely correct run. These are
# the only coverage for four attack vectors on the envelope that gates daemon_decision_valid, so
# assert the validator is callable FIRST and fail the suite closed if it is not.
VALIDATOR_PRESENT=1
command -v pg_review_decision_envelope_valid >/dev/null 2>&1 || VALIDATOR_PRESENT=0
[ "$VALIDATOR_PRESENT" = 1 ] && declare -F pg_review_decision_envelope_valid >/dev/null 2>&1 || VALIDATOR_PRESENT=0
check 'library validator is defined and callable before any rejection case is scored' \
  "$([ "$VALIDATOR_PRESENT" = 1 ]; printf '%s' "$?")" "present=$VALIDATOR_PRESENT"
# Every rejection case now scores an EXPLICIT return code: 0 means the attack was accepted (bad),
# and anything other than a clean non-zero rejection (e.g. 127 not-found) also fails the case.
envelope_rejects() { # file -> 0 when the validator cleanly REJECTED it
  local f="$1" rc
  pg_review_decision_envelope_valid "$f" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ]
}
ENVELOPES_OK=1; FABRICATED_OK=1; INJECTED_OK=1; DIGEST_OK=1; SYMLINK_OK=1; ENVELOPE_DETAIL=""
i=0
while [ "$i" -lt "$CASE_COUNT" ]; do
  corpus_envelope "$i" "$TMP/envelope-$i.json"
  pg_review_decision_envelope_valid "$TMP/envelope-$i.json" || { ENVELOPES_OK=0; ENVELOPE_DETAIL="$ENVELOPE_DETAIL case=$i:rejected-genuine"; }
  # Swap the outer action for another closed action: the envelope is plausible JSON, but the
  # reducer re-run over its own facts no longer matches byte-for-byte.
  jq -c 'if .action == "stop-without-new-review" then .action="allow-existing-merge-workflow" | .effect_request.action="allow-existing-merge-workflow" | .effect_request.effect="allow-existing-merge-workflow" else .action="stop-without-new-review" | .effect_request.action="stop-without-new-review" | .effect_request.effect="stop-without-new-review" | .effect_request.execution_class="report-only" end' \
    "$TMP/envelope-$i.json" > "$TMP/fabricated-$i.json"
  envelope_rejects "$TMP/fabricated-$i.json" || { FABRICATED_OK=0; ENVELOPE_DETAIL="$ENVELOPE_DETAIL case=$i:not-rejected-fabricated"; }
  jq -c '.facts.next_action="wait"' "$TMP/envelope-$i.json" > "$TMP/injected-$i.json"
  envelope_rejects "$TMP/injected-$i.json" || { INJECTED_OK=0; ENVELOPE_DETAIL="$ENVELOPE_DETAIL case=$i:not-rejected-next_action"; }
  jq -c '.contract.contract_digest="0000000000000000000000000000000000000000000000000000000000000000"' "$TMP/envelope-$i.json" > "$TMP/digest-$i.json"
  envelope_rejects "$TMP/digest-$i.json" || { DIGEST_OK=0; ENVELOPE_DETAIL="$ENVELOPE_DETAIL case=$i:not-rejected-foreign-digest"; }
  i=$((i + 1))
done
ln -s "$TMP/envelope-0.json" "$TMP/envelope-link.json"
envelope_rejects "$TMP/envelope-link.json" || SYMLINK_OK=0
check 'library validator accepts every envelope the runtime emits for the frozen corpus' "$([ "$ENVELOPES_OK" = 1 ]; printf '%s' "$?")" "$ENVELOPE_DETAIL"
check 'library validator rejects an envelope whose outer action was swapped for another closed action' "$([ "$FABRICATED_OK" = 1 ]; printf '%s' "$?")" "$ENVELOPE_DETAIL"
check 'library validator rejects a blocking-wait next_action injected into the facts' "$([ "$INJECTED_OK" = 1 ]; printf '%s' "$?")" "$ENVELOPE_DETAIL"
check 'library validator rejects a foreign contract digest' "$([ "$DIGEST_OK" = 1 ]; printf '%s' "$?")" "$ENVELOPE_DETAIL"
check 'library validator refuses a symlinked decision file' "$([ "$SYMLINK_OK" = 1 ]; printf '%s' "$?")"

# #147: `bindable` is a closed-schema field on every completed_results row, not decoration. Strip it
# from a genuine envelope's facts and the reducer either rejects the now-malformed facts outright or
# recomputes a different byte-for-byte decision -- either way the validator must reject the on-disk
# envelope, since it no longer matches re-running the reducer over its own (now-tampered) facts.
# Restoring the field must accept again, proving the earlier rejection was this field and not noise.
BINDABLE_CASE_INDEX="$(jq '[.cases[].name] | index("collect current completed result")' "$CORPUS")"
corpus_envelope "$BINDABLE_CASE_INDEX" "$TMP/bindable-envelope.json"
jq -c 'del(.facts.completed_results[0].bindable)' "$TMP/bindable-envelope.json" > "$TMP/bindable-removed.json"
check 'envelope with bindable stripped from a completed_results row is rejected as undefined' \
  "$(envelope_rejects "$TMP/bindable-removed.json"; printf '%s' "$?")" \
  "$(cat "$TMP/bindable-removed.json")"
jq -c '.facts.completed_results[0].bindable=true' "$TMP/bindable-removed.json" > "$TMP/bindable-restored.json"
check 'the same envelope with bindable restored validates again' \
  "$(pg_review_decision_envelope_valid "$TMP/bindable-restored.json" >/dev/null 2>&1; printf '%s' "$?")" \
  "$(cat "$TMP/bindable-restored.json")"
# #174: the governor shape validator's keys_are(...) allowlist is exact, so a fact object missing
# a required trajectory key (here: governor.arrow, deleted after the corpus merge) must never
# silently pass through as a grant or any other action -- it is undefined-state, closed.
UNDEFINED_ARROW_FACTS="$(jq -cS --arg cd "$CONTRACT_DIGEST" --arg xd "$CORPUS_DIGEST" '
  .base_facts | .contract={contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd} |
  del(.governor.arrow)' "$CORPUS")"
UNDEFINED_ARROW_DECISION="$(pg_review_decision_reduce "$UNDEFINED_ARROW_FACTS")"
check 'a governor object missing the arrow key is rejected as undefined-state, not silently granted' \
  "$(jq -e '.action=="stop-without-new-review" and .reason=="undefined-state"' <<<"$UNDEFINED_ARROW_DECISION" >/dev/null 2>&1; printf '%s' "$?")" \
  "$UNDEFINED_ARROW_DECISION"

# gate #174-review P1: a selected named choice reduces to the identical fix-review-findings/
# agent-task action a FIX-FIRST verdict does, so it is the same "fix dispatch" the churn brake
# was built to replace -- but only the FIX-FIRST site (lib/pro-gate-lib.sh) got the streak guard.
# Without it, a chain that phrases its repeated finding as a NEEDS-DISCUSSION policy question,
# once the operator answers it, still buys an unbounded run of further paid rounds. This cannot be
# a corpus.json fixture case: pg_review_decision_choice_snapshot hashes the ENTIRE canonical facts
# object, including .contract.corpus_digest -- which is corpus.json's OWN file digest -- so a
# snapshot baked into a case would have to equal a hash of a file containing that very value, a
# fixed point sha256 does not yield by construction. Both the real engine and this check resolve
# it the only way that works: compute the digest at run time from the exact facts under test,
# mirroring the corpus's own base_facts/contract shape (same technique as UNDEFINED_ARROW above).
choice_facts() { # governor-json -> canonical facts with that governor, a NEEDS-DISCUSSION prior,
                  # and an unselected two-outcome named choice
  jq -cS --arg cd "$CONTRACT_DIGEST" --arg xd "$CORPUS_DIGEST" --argjson gov "$1" '
    .base_facts | .contract={contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd} |
    .governor=$gov |
    .prior_review={applicable:true,binding_valid:true,code_identity:"input-current",evidence_identity:"evidence-current",legacy:false,marker:"pg-run-acme-widgets-1983-1700000010-10",provenance_valid:true,verdict:"NEEDS-DISCUSSION"} |
    .named_choice={outcomes:[{consequence:"keep the API compatible",id:"compat",label:"Preserve compatibility"},{consequence:"adopt the smaller new API",id:"break",label:"Accept the break"}],selected_id:null,snapshot_digest:""}' "$CORPUS"
}
select_choice() { # unselected-facts-json -> the same facts with a valid, freshness-checked selection
  local unselected="$1" digest
  digest="$(pg_review_decision_choice_snapshot "$unselected")"
  jq -cS --arg d "$digest" '.named_choice.selected_id="compat" | .named_choice.snapshot_digest=$d' <<<"$unselected"
}
CHURN_CHOICE_FACTS="$(select_choice "$(choice_facts '{"arrow":[1,1,1],"continue_override":false,"earned":0,"grant":3,"granted":true,"policy_mode":"advisory","scored":3,"streak":2}')")"
CHURN_CHOICE_DECISION="$(pg_review_decision_reduce "$CHURN_CHOICE_FACTS")"
check 'a churning streak stops a NEEDS-DISCUSSION named-choice-selected fix dispatch too, not just FIX-FIRST' \
  "$(jq -e '.action=="stop-without-new-review" and .reason=="rounds-not-converging"' <<<"$CHURN_CHOICE_DECISION" >/dev/null 2>&1; printf '%s' "$?")" \
  "$CHURN_CHOICE_DECISION"
CONTINUE_CHOICE_FACTS="$(select_choice "$(choice_facts '{"arrow":[1,1,1],"continue_override":true,"earned":0,"grant":3,"granted":true,"policy_mode":"advisory","scored":3,"streak":2}')")"
CONTINUE_CHOICE_DECISION="$(pg_review_decision_reduce "$CONTINUE_CHOICE_FACTS")"
check 'PRO_GATE_ROUNDS_CONTINUE=1 still lets an already-selected named choice dispatch despite the streak' \
  "$(jq -e '.action=="fix-review-findings" and .reason=="named-product-choice-selected"' <<<"$CONTINUE_CHOICE_DECISION" >/dev/null 2>&1; printf '%s' "$?")" \
  "$CONTINUE_CHOICE_DECISION"
NOSTREAK_CHOICE_FACTS="$(select_choice "$(choice_facts '{"arrow":[],"continue_override":false,"earned":0,"grant":3,"granted":true,"policy_mode":"advisory","scored":0,"streak":0}')")"
NOSTREAK_CHOICE_DECISION="$(pg_review_decision_reduce "$NOSTREAK_CHOICE_FACTS")"
check 'a selected named choice dispatches normally when the streak has not reached two (regression)' \
  "$(jq -e '.action=="fix-review-findings" and .reason=="named-product-choice-selected"' <<<"$NOSTREAK_CHOICE_DECISION" >/dev/null 2>&1; printf '%s' "$?")" \
  "$NOSTREAK_CHOICE_DECISION"

# gate #148 r8 P1: a prose consumer must NOT pin the wait at all. The engine treats any --timeout
# it receives as final (bin/oracle-review.sh: `if [ -z "$TIMEOUT" ]`), so a skill or relay that
# hardcodes one makes PRO_GATE_TIMEOUT and PRO_GATE_HARVEST_TIMEOUT unreachable on the path most
# reviews actually take — the two knobs this release introduces would be inert everywhere that
# matters. The earlier version of this check REQUIRED the hardcoded 60m/45m, so it enforced the
# bypass instead of catching it. The rule is now the same one the daemon follows: supply a timeout
# only when the operator configured one.
# The pattern deliberately does NOT require a trailing unit: pg_dur_secs treats a bare digit run
# as raw seconds, so `--timeout 1800` is a fully valid pin and reintroduces the identical bypass.
# Requiring [smh] left this check reporting ok for that whole class of value.
for consumer in "${CONSUMERS[@]}"; do
  check "$(basename "$consumer") lets the engine size the wait instead of pinning it" \
    "$(! grep -Eq -- '--timeout[[:space:]]+[0-9]' "$consumer"; printf '%s' "$?")" \
    "$(grep -En -- '--timeout[[:space:]]+[0-9]' "$consumer" | tr '\n' ';')"
done
# Planted negatives for the pattern itself. The check above can only report a real bypass if
# the pattern matches one, and the pre-fix pattern (which required a trailing [smh]) reported
# ok for the bare-seconds spelling -- a fully valid pin, since pg_dur_secs reads a bare digit
# run as raw seconds. Assert both spellings match, and that an unpinned consumer still does not.
PINNED_SECS="$TMP/pinned-seconds.md"
PINNED_UNIT="$TMP/pinned-unit.md"
UNPINNED="$TMP/unpinned.md"
printf 'run: oracle-review.sh --pr 1 --timeout 1800 --out x\n' > "$PINNED_SECS"
printf 'run: oracle-review.sh --pr 1 --timeout 30m --out x\n' > "$PINNED_UNIT"
printf 'run: oracle-review.sh --pr 1 --out x\n' > "$UNPINNED"
check 'no-hardcoded-timeout pattern catches a bare-seconds pin (planted negative)' \
  "$(grep -Eq -- '--timeout[[:space:]]+[0-9]' "$PINNED_SECS"; printf '%s' "$?")"
check 'no-hardcoded-timeout pattern still catches a unit-suffixed pin' \
  "$(grep -Eq -- '--timeout[[:space:]]+[0-9]' "$PINNED_UNIT"; printf '%s' "$?")"
check 'no-hardcoded-timeout pattern does not fire on an unpinned consumer' \
  "$(! grep -Eq -- '--timeout[[:space:]]+[0-9]' "$UNPINNED"; printf '%s' "$?")"
ENGINE="$HERE/../bin/oracle-review.sh"
LIBSH="$HERE/../lib/pro-gate-lib.sh"
# #274: exercise accepted review bytes through the real public decision query. Repository,
# PR evidence and immutable bindings are synthetic; acceptance and reduction are not mocked.
DEFERRAL_REPO="$TMP/deferral-repo"
mkdir -p "$DEFERRAL_REPO"
git -C "$DEFERRAL_REPO" init -q
git -C "$DEFERRAL_REPO" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm base
DEFERRAL_BASE="$(git -C "$DEFERRAL_REPO" rev-parse HEAD)"
printf 'reviewed change\n' > "$DEFERRAL_REPO/file.txt"
git -C "$DEFERRAL_REPO" add file.txt
git -C "$DEFERRAL_REPO" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm head
DEFERRAL_HEAD="$(git -C "$DEFERRAL_REPO" rev-parse HEAD)"
git -C "$DEFERRAL_REPO" remote add origin https://github.com/acme/widgets.git
git -C "$DEFERRAL_REPO" diff "$DEFERRAL_BASE" "$DEFERRAL_HEAD" > "$TMP/deferral.patch"
DEFERRAL_RAW="$(pg_sha256 "$TMP/deferral.patch")"
DEFERRAL_METADATA="$(jq -cnS --arg base "$DEFERRAL_BASE" --arg head "$DEFERRAL_HEAD" \
  '{repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{pr:1983,base_ref:"main",base_oid:$base,head_oid:$head}}')"
DEFERRAL_MD="$(pg_pr_evidence_metadata_digest "$(jq -cnS --argjson metadata "$DEFERRAL_METADATA" '{metadata:$metadata}')")"
jq -cnS --argjson metadata "$DEFERRAL_METADATA" --arg digest "$DEFERRAL_RAW" \
  '{record_type:"review-pr-evidence/v1",record_version:1,patch_format:"github-compare-diff",metadata:$metadata,endpoint_digest:$digest}' > "$TMP/deferral-pr.json"
DEFERRAL_BODY=$'P0: none\nP1: none\nP2:\n[P2] docs.md:7 — Clarify the example.\nVERDICT: FIX-FIRST\n'
deferral_case() { (
  local name="$1" body="$2" predicate="$3" churn="${4:-false}" marker=pg-run-acme-widgets-1983-1700000700-1
  local input result digest decision now
  # Isolate every configured runtime path and override from the operator's session.
  while IFS='=' read -r name_env _; do
    case "$name_env" in PRO_GATE_*|ORACLE_*) unset "$name_env" ;; esac
  done < <(env)
  export PRO_GATE_HOME="$TMP/deferral-$name" PRO_GATE_RUN_LOGS=0
  export PRO_GATE_REVIEW_PR_EVIDENCE="$TMP/deferral-pr.json" PRO_GATE_REVIEW_ENDPOINT_PATCH="$TMP/deferral.patch"
  mkdir -p "$PRO_GATE_HOME/completed"
  printf '%s' "$body" > "$PRO_GATE_HOME/completed/$marker"
  digest="$(pg_sha256 "$PRO_GATE_HOME/completed/$marker")"
  input="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$marker" \
    --arg base "$DEFERRAL_BASE" --arg head "$DEFERRAL_HEAD" --arg raw "$DEFERRAL_RAW" --arg md "$DEFERRAL_MD" \
    '{charged_spend_epoch:1700000700,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,
      evidence:{identity:("full-pr:"+$base+":"+$head),mode:"full-pr",proof:{base_oid:$base,head_oid:$head,endpoint_digest:$raw,raw_patch_digest:$raw,pr_metadata_digest:$md}},
      marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{head_oid:$head,kind:"pull-request",pr:1983}}')"
  result="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$marker" \
    --arg ib "$(pg_review_sha256_text "$input")" --arg digest "$digest" \
    '{accepted_epoch:1700000800,artifact:{digest:$digest,path:("completed/"+$marker)},contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,
      input_binding_digest:$ib,input_binding_identity:$marker,marker:$marker,named_choice:null,provenance:{outcome:"accepted",validated_epoch:1700000800},
      record_type:"review-result-binding/v1",record_version:1,ship_proof:null,verdict:"FIX-FIRST"}')"
  pg_review_input_binding_write "$marker" "$input" || exit 1
  pg_review_result_binding_write "$marker" "$result" || exit 1
  if [ -n "${5:-}" ]; then
    local older_marker=pg-run-acme-widgets-1983-1700000600-1 older_input older_result
    printf '%s' "$5" > "$PRO_GATE_HOME/completed/$older_marker"
    older_input="$(jq -cS --arg marker "$older_marker" '.marker=$marker | .charged_spend_epoch=1700000600' <<<"$input")"
    older_result="$(jq -cS --arg marker "$older_marker" --arg ib "$(pg_review_sha256_text "$older_input")" \
      --arg digest "$(pg_sha256 "$PRO_GATE_HOME/completed/$older_marker")" \
      '.marker=$marker | .input_binding_identity=$marker | .input_binding_digest=$ib | .artifact={digest:$digest,path:("completed/"+$marker)}' <<<"$result")"
    pg_review_input_binding_write "$older_marker" "$older_input" || exit 1
    pg_review_result_binding_write "$older_marker" "$older_result" || exit 1
  fi
  if [ "$churn" = true ]; then
    mkdir -p "$PRO_GATE_HOME/rounds"
    now="$(date +%s)"
    for _ in 1 2 3; do printf '%s\tFIX-FIRST\t0\t1\t0\t0\t1\n' "$now"; done > "$PRO_GATE_HOME/rounds/acme-widgets-1983.hist"
  fi
  decision="$(bash "$ENGINE" --review-decision --json --repo "$DEFERRAL_REPO" --pr 1983 \
    --diff "$TMP/deferral.patch" --input bundle 2> "$TMP/deferral-$name.err")" || {
      cat "$TMP/deferral-$name.err"; exit 1;
    }
  jq -e "$predicate" <<<"$decision" >/dev/null || { printf '%s\n' "$decision"; exit 1; }
  printf '%s' "$decision" > "$TMP/deferral-$name.json"
); }
DEFERRAL_PREDICATE='.action=="allow-existing-merge-workflow" and .reason=="fix-first-deferred-p2-only" and .facts.open_blocking==0 and .facts.deferred_count==1 and .facts.deferred_findings==[{severity:"P2",text:"docs.md:7 — Clarify the example."}]'
DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case p2 "$DEFERRAL_BODY" "$DEFERRAL_PREDICATE")" || DEFERRAL_RC=$?
check '#274 P2-only FIX-FIRST allows the merge workflow and emits deferred facts (planted negative)' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case p1 $'[P1] runtime.sh:1 — Fix the race.\n'"$DEFERRAL_BODY" '.action=="fix-review-findings" and .reason=="review-findings-require-fix"')" || DEFERRAL_RC=$?
check '#274 an open P1 still requires a fix (control)' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case p0 $'[P0] runtime.sh:1 — Fix data loss.\n'"$DEFERRAL_BODY" '.action=="fix-review-findings" and .reason=="review-findings-require-fix"')" || DEFERRAL_RC=$?
check '#274 an open P0 still requires a fix' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case resolved $'[P1] runtime.sh:1 — RESOLVED — race fixed.\n'"$DEFERRAL_BODY" "$DEFERRAL_PREDICATE")" || DEFERRAL_RC=$?
check '#274 a status-position RESOLVED P1 is not open' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
for severity in p2 p1; do
  body="$DEFERRAL_BODY"
  [ "$severity" != p1 ] || body=$'[P1] runtime.sh:1 — Fix the race.\n'"$body"
  DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case "churn-$severity" "$body" '.action=="stop-without-new-review" and .reason=="rounds-not-converging"' true)" || DEFERRAL_RC=$?
  check "#274 rounds-not-converging preempts $severity FIX-FIRST" "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
done
DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case ordered $'P0: none\nP1: none\n  * [P3] docs.md:3 — Keep "quotes" and \\slashes.\n[P2] docs.md:4 — Clarify the example.\n2. [P3] docs.md:5 — Add a link.\nVERDICT: FIX-FIRST\n' \
  '.action=="allow-existing-merge-workflow" and .facts.deferred_count==3 and .facts.deferred_findings==[{severity:"P3",text:"docs.md:3 — Keep \"quotes\" and \\slashes."},{severity:"P2",text:"docs.md:4 — Clarify the example."},{severity:"P3",text:"docs.md:5 — Add a link."}]')" || DEFERRAL_RC=$?
check '#274 deferred P2/P3 items retain body order and text while stripping labels and list markers' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case newer-p2 "$DEFERRAL_BODY" "$DEFERRAL_PREDICATE" false \
  $'[P1] old.sh:1 — An older blocking review.\nVERDICT: FIX-FIRST\n')" || DEFERRAL_RC=$?
check '#274 a newer P2 review uses its own counts and findings rather than an older P1' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case newer-p1 $'[P1] current.sh:1 — A newer blocker.\nVERDICT: FIX-FIRST\n' \
  '.action=="fix-review-findings" and .facts.open_blocking==1 and .facts.deferred_findings==[] and .facts.deferred_count==0' false "$DEFERRAL_BODY")" || DEFERRAL_RC=$?
check '#274 a newer P1 review cannot inherit an older P2 deferral' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case prose $'[P1] runtime.sh:1 — The RESOLVED state is forgeable.\n'"$DEFERRAL_BODY" \
  '.action=="fix-review-findings" and .facts.open_blocking==1')" || DEFERRAL_RC=$?
check '#274 RESOLVED in prose does not remove an open P1' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
check '#274 genuine P2 deferral envelope validates through the shared consumer boundary' \
  "$(pg_review_decision_envelope_valid "$TMP/deferral-p2.json"; printf '%s' "$?")"
WRONG_COUNT_DECISION="$(pg_review_decision_reduce "$(jq -cS '.facts | .deferred_count=2' "$TMP/deferral-p2.json")")"
check '#274 a deferred count inconsistent with its items is rejected' \
  "$(jq -e '.action=="stop-without-new-review" and .reason=="undefined-state"' <<<"$WRONG_COUNT_DECISION" >/dev/null; printf '%s' "$?")"
WRONG_SEVERITY_DECISION="$(pg_review_decision_reduce "$(jq -cS '.facts | .deferred_findings[0].severity="P1"' "$TMP/deferral-p2.json")")"
check '#274 a blocking severity cannot masquerade as a deferred item' \
  "$(jq -e '.action=="stop-without-new-review" and .reason=="undefined-state"' <<<"$WRONG_SEVERITY_DECISION" >/dev/null; printf '%s' "$?")"
UNKNOWN_COUNTS_DECISION="$(pg_review_decision_reduce "$(jq -cS '.facts | .open_blocking=null' "$TMP/deferral-p2.json")")"
check '#274 unavailable blocking counts preserve FIX-FIRST rather than authorizing deferral' \
  "$(jq -e '.action=="fix-review-findings" and .reason=="review-findings-require-fix"' <<<"$UNKNOWN_COUNTS_DECISION" >/dev/null; printf '%s' "$?")"

# PR #276: parse real review bytes, then call the reducer directly. No envelope replay can
# reject these inputs before the particular count/status/deferral rule is exercised.
direct_review_case() { # name body reducer-predicate
  local name="$1" body="$2" predicate="$3" counts p0=null p1=null deferred facts decision rc=0
  printf '%s' "$body" > "$TMP/direct-review.txt"
  if counts="$(pg_review_open_severity "$TMP/direct-review.txt")"; then
    IFS=$'\t' read -r p0 p1 <<<"$counts"
  fi
  deferred="$(pg_review_deferred_findings "$TMP/direct-review.txt")"
  facts="$(jq -cS --argjson p0 "$p0" --argjson p1 "$p1" --argjson deferred "$deferred" \
    '.facts | .open_blocking=(if $p0==null or $p1==null then null else $p0+$p1 end) | .deferred_findings=$deferred | .deferred_count=($deferred|length)' "$TMP/deferral-p2.json")"
  decision="$(pg_review_decision_reduce "$facts")"
  jq -e "$predicate" <<<"$decision" >/dev/null || rc=$?
  check "$name" "$rc" "$decision"
}
BLOCKING_PREDICATE='.action=="fix-review-findings" and .reason=="review-findings-require-fix" and .facts.open_blocking==1'
for headline in '- [P1]' '**P1**:' 'P1 -' 'p1:' '+ [P0]' '[P1]' '1. __p1__:' '2) **[p1]**:' '* [P1]:'; do
  direct_review_case "P1-1 supported severity $headline requires a fix" \
    "$headline runtime.sh:1 — Concurrent writes lose data."$'\n'"$DEFERRAL_BODY" "$BLOCKING_PREDICATE"
done
for headline in 'P1]' '**P1]**:' '> [P1]' '[**P1**]' '`[P1]`' '(P1)'; do
  direct_review_case "P1-1 unrecognized severity $headline leaves counts unavailable" \
    "$headline runtime.sh:1 — Concurrent writes lose data."$'\n'"$DEFERRAL_BODY" \
    '.action=="fix-review-findings" and .facts.open_blocking==null'
done
for headline in 'P1:' '[P0]'; do
  direct_review_case "P1-1 empty blocking label $headline leaves counts unavailable" \
    "$headline"$'\n  runtime.sh:1 — Concurrent writes lose data.\n'"$DEFERRAL_BODY" \
    '.action=="fix-review-findings" and .facts.open_blocking==null'
done
direct_review_case 'P1-1 none declarations positively prove zero blockers' \
  $'P0: none\np1: none\n'"$DEFERRAL_BODY" "$DEFERRAL_PREDICATE"

# PR #276 round 3: section headings end blocks, while heading-form findings use the
# same severity grammar. Unsupported quoted labels end a block without becoming findings.
ROUND3_DEFERRAL_PREDICATE='.action=="allow-existing-merge-workflow" and .reason=="fix-first-deferred-p2-only" and .facts.open_blocking==0 and .facts.deferred_count==1'
direct_review_case 'R3-P1 severity section headings preserve P2-only deferral' \
  $'P0: none\n## P1 findings\nP1: none\n[P2] b.sh:2 — a nit\nVERDICT: FIX-FIRST\n' \
  "$ROUND3_DEFERRAL_PREDICATE and .facts.deferred_findings==[{severity:\"P2\",text:\"b.sh:2 — a nit\"}]"
for heading in '## P1' '### P1 (blocking)' '## P1 — Must fix' '## P0:' \
  '## P1 findings:' '## P1 Issues (2)' '## [p1] notes' '## P1 severity level' \
  '## P0 none' '## P1 empty' '## P1 n/a' '## P1 must-fix' '## P1 should fix' \
  '## P1 nice to have' '## P1 items blockers blocking comments' '## P1 —'; do
  direct_review_case "R3-P1 section $heading keeps zero counts known" \
    "$heading"$'\nP0: none\nP1: none\nVERDICT: FIX-FIRST\n' \
    '.action=="fix-review-findings" and .reason=="fix-first-without-findings" and .facts.open_blocking==0 and .facts.deferred_count==0'
done
for heading in '### [P1] lib/x.sh:12 — the lock is deleted' '### P1 — the lock is deleted' \
  '### [P0] lib/x.sh:12 — the lock is deleted' '## P1 findings lose data' '## P1 (the lock is deleted)'; do
  direct_review_case "R3-P1 finding $heading still counts a blocker" \
    "$heading"$'\nVERDICT: FIX-FIRST\n' "$BLOCKING_PREDICATE"
done
for severity in P2 P3; do
  direct_review_case "R3-P1 heading-form $severity finding preserves deferred text" \
    "### [$severity] lib/x.sh:12 — a nit"$'\nVERDICT: FIX-FIRST\n' \
    "$ROUND3_DEFERRAL_PREDICATE and .facts.deferred_findings==[{severity:\"$severity\",text:\"lib/x.sh:12 — a nit\"}]"
done
for heading in '## Findings' '## Refuted'; do
  direct_review_case "R3-P1 boundary $heading closes a resolved blocker" \
    $'[P1] a.sh:1 — RESOLVED — patched.\n'"$heading"$'\nCorrection: STILL-PRESENT; still broken\n[P3] c.sh:3 — a nit\nVERDICT: FIX-FIRST\n' \
    "$ROUND3_DEFERRAL_PREDICATE and .facts.deferred_findings==[{severity:\"P3\",text:\"c.sh:3 — a nit\"}]"
done
# Round-3 repair: a severity section heading still closes the resolved P1, but its body is a
# deferred P2 rather than dropped text (the body-dropping expectation was the round-3 regression).
direct_review_case 'R3-P1 boundary ## P2 findings closes a resolved blocker and keeps its body as a deferred P2' \
  $'[P1] a.sh:1 — RESOLVED — patched.\n## P2 findings\nCorrection: STILL-PRESENT; still broken\n[P3] c.sh:3 — a nit\nVERDICT: FIX-FIRST\n' \
  '.action=="allow-existing-merge-workflow" and .reason=="fix-first-deferred-p2-only" and .facts.open_blocking==0 and .facts.deferred_count==2 and .facts.deferred_findings==[{severity:"P2",text:"Correction: STILL-PRESENT; still broken"},{severity:"P3",text:"c.sh:3 — a nit"}]'
for label in '> [P2]' '> [P3]' 'P2]' '`[P3]`'; do
  direct_review_case "R3-P2 unsupported $label closes a resolved blocker without counting the quotation" \
    $'[P1] a.sh:1 — RESOLVED — patched.\n'"$label"$' b.sh:2 — quoted\nCorrection: STILL-PRESENT; still broken\n[P3] c.sh:3 — a nit\nVERDICT: FIX-FIRST\n' \
    "$ROUND3_DEFERRAL_PREDICATE and .facts.deferred_findings==[{severity:\"P3\",text:\"c.sh:3 — a nit\"}]"
done
direct_review_case 'R3-P1 malformed non-heading P1 label still leaves counts unavailable' \
  $'P1] — something unparsed\nVERDICT: FIX-FIRST\n' \
  '.action=="fix-review-findings" and .facts.open_blocking==null'
direct_review_case 'R3-P1 bare P1 em-dash finding keeps its existing grammar' \
  $'P1 — something unparsed\nVERDICT: FIX-FIRST\n' "$BLOCKING_PREDICATE"

# PR #276 round 3 repair: section vocabulary can also title a real finding, and an
# unparseable blocking heading must not turn unknown counts into known zeroes.
SECTION_FINDING_BODY=$'lib/comments.sh:12 — Posting a comment deadlocks while holding the lock needed by the worker.\nSuggested fix: release the lock before waiting.\n'
for heading in '### [P1] Blocking comments' '### [P0] Blocking issues'; do
  direct_review_case "R3-repair-P1-1 $heading retains its blocking body" \
    "$heading"$'\n'"$SECTION_FINDING_BODY"$'[P2] b.sh:2 — a nit\nVERDICT: FIX-FIRST\n' \
    "$BLOCKING_PREDICATE"
done
for severity in P2 P3; do
  direct_review_case "R3-repair-P1-1 section-like $severity heading retains its deferred body" \
    "### [$severity] Blocking comments"$'\n'"$SECTION_FINDING_BODY"$'VERDICT: FIX-FIRST\n' \
    ".action==\"allow-existing-merge-workflow\" and .reason==\"fix-first-deferred-p2-only\" and .facts.open_blocking==0 and .facts.deferred_count==1 and .facts.deferred_findings==[{severity:\"$severity\",text:\"lib/comments.sh:12 — Posting a comment deadlocks while holding the lock needed by the worker.\\nSuggested fix: release the lock before waiting.\"}]"
done
for heading in '### [**P1**] lib/x.sh:12 — the lock is deleted' \
  '## (P1) lib/x.sh:12 — the lock is deleted' \
  '## 1. P1 lib/x.sh:12 — the lock is deleted' \
  '### [**P0**] lib/x.sh:12 — the lock is deleted'; do
  direct_review_case "R3-repair-P1-2 malformed heading $heading leaves counts unavailable" \
    "$heading"$'\n[P2] b.sh:2 — a nit\nVERDICT: FIX-FIRST\n' \
    '.action=="fix-review-findings" and .facts.open_blocking==null'
done
direct_review_case 'R3-repair control explicit none closes an empty section' \
  $'## P1 findings\nP1: none\n[P2] b.sh:2 — a nit\nVERDICT: FIX-FIRST\n' \
  "$ROUND3_DEFERRAL_PREDICATE"
direct_review_case 'R3-repair control prose none closes an empty section' \
  $'## P1 findings\nNo P1 findings in this round.\n[P2] b.sh:2 — a nit\nVERDICT: FIX-FIRST\n' \
  "$ROUND3_DEFERRAL_PREDICATE"
direct_review_case 'R3-repair control blank sections preserve P2-only deferral' \
  $'## P1\n\n## P2 findings\n[P2] b.sh:2 — a nit\nVERDICT: FIX-FIRST\n' \
  "$ROUND3_DEFERRAL_PREDICATE"
direct_review_case 'R3-repair control generic section keeps a following blocker visible' \
  $'## Findings\n[P1] a.sh:1 — bug\nVERDICT: FIX-FIRST\n' "$BLOCKING_PREDICATE"
direct_review_case 'R3-repair control a finding headline flushes an empty severity section' \
  $'## P1 findings\n- [P1] a.sh:1 — bug\nVERDICT: FIX-FIRST\n' "$BLOCKING_PREDICATE"
direct_review_case 'R3-repair-P1-1 a section-like blocker retains fenced evidence' \
  $'### [P1] Blocking comments\n```sh\n[P2] quoted.sh:2 — quoted evidence\n```\n[P2] b.sh:2 — a nit\nVERDICT: FIX-FIRST\n' "$BLOCKING_PREDICATE"
direct_review_case 'R3-repair-P1-1 a section-like P2 retains fenced evidence verbatim' \
  $'### [P2] Blocking comments\n```sh\n[P1] quoted.sh:1 — quoted evidence\n```\nVERDICT: FIX-FIRST\n' \
  '.action=="allow-existing-merge-workflow" and .facts.open_blocking==0 and .facts.deferred_count==1 and .facts.deferred_findings==[{severity:"P2",text:"```sh\n[P1] quoted.sh:1 — quoted evidence\n```"}]'
direct_review_case 'R3-repair control provisional sections discard only empty declarations' \
  $'## P0 issues\n\nnone\nNO P0 BLOCKING ISSUES in this round.\n## P1 findings\n—\nNo open P1 findings remain.\n## P2 findings\n-\nNo findings in this round.\n[P2] b.sh:2 — a nit\nVERDICT: FIX-FIRST\n' \
  "$ROUND3_DEFERRAL_PREDICATE"
for status in 'Correction: STILL-PRESENT; concurrent requests still lose data.' 'REOPENED' 'NOT RESOLVED' 'NOT FIXED' 'Correction: the patch missed this path.' 'Correction:'; do
  direct_review_case "P1-2 continuation $status reopens a RESOLVED finding" \
    $'[P1] runtime.sh:1 — RESOLVED — patched.\n  '"$status"$'\n'"$DEFERRAL_BODY" "$BLOCKING_PREDICATE"
done
direct_review_case 'P1-2 neutral continuation keeps a RESOLVED finding closed' \
  $'[P1] runtime.sh:1 — RESOLVED — patched.\n  Verified the regression test.\n'"$DEFERRAL_BODY" "$DEFERRAL_PREDICATE"
direct_review_case 'P1-3 skeleton FIX-FIRST contradicts its body' \
  $'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: FIX-FIRST\n' \
  '.action=="fix-review-findings" and .reason=="fix-first-without-findings" and .facts.deferred_count==0'
direct_review_case 'P1-3 one real P2 permits deferral' "$DEFERRAL_BODY" "$DEFERRAL_PREDICATE"
direct_review_case 'P2-4 deferred text keeps explanation, confidence, fix and code block' \
  $'P0: none\nP1: none\n[P2] docs.md:7 — Clarify the example.\n  Why it is a real problem: readers copy the wrong flag.\n  Confidence: high.\n  Suggested fix: use the supported flag.\n  ```sh\n  pro-gate --status\n  ```\nP3: none\nVERDICT: FIX-FIRST\n' \
  '.action=="allow-existing-merge-workflow" and .facts.deferred_count==1 and (.facts.deferred_findings[0].text | contains("\n  Why it is a real problem:") and contains("Confidence: high.") and contains("Suggested fix:") and contains("```sh\n  pro-gate --status\n  ```"))'
direct_review_case 'P2-4 a longer closing code fence keeps a later blocker visible' \
  $'[P2] docs.md:7 — Clarify.\n  ```sh\n  example\n  ````\n[P1] runtime.sh:1 — Concurrent writes lose data.\nVERDICT: FIX-FIRST\n' "$BLOCKING_PREDICATE"
direct_review_case 'P1-1 an unterminated finding fence leaves counts unavailable' \
  $'P0: none\nP1: none\n[P2] docs.md:7 — Clarify.\n  ```sh\n  example\nVERDICT: FIX-FIRST\n' \
  '.action=="fix-review-findings" and .facts.open_blocking==null'
LONG_FINDING="$(printf '%1500s' '' | tr ' ' x)"
direct_review_case 'P2-4 oversized deferred text is bounded with an exact truncation marker' \
  $'P0: none\nP1: none\n[P2] '"$LONG_FINDING"$'\nVERDICT: FIX-FIRST\n' \
  '.action=="allow-existing-merge-workflow" and .facts.deferred_count==1 and (.facts.deferred_findings[0].text | length==1024 and endswith("… [truncated 499 chars]"))'
direct_review_case 'P1-1 P2/P3 normalization matches blocker normalization' \
  $'P0: none\nP1: none\n- **p2**: docs.md:7 — Clarify the example.\n2) __P3__: Add a link.\nVERDICT: FIX-FIRST\n' \
  '.action=="allow-existing-merge-workflow" and .facts.deferred_count==2 and .facts.deferred_findings==[{severity:"P2",text:"docs.md:7 — Clarify the example."},{severity:"P3",text:"Add a link."}]'

DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case unavailable $'P1] runtime.sh:1 — Concurrent writes lose data.\n'"$DEFERRAL_BODY" \
  '.action=="fix-review-findings" and .facts.open_blocking==null')" || DEFERRAL_RC=$?
check 'P1-1 accepted artifact retains FIX-FIRST when counts are unavailable' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
DEFERRAL_RC=0; DEFERRAL_DETAIL="$(deferral_case multiline $'P0: none\nP1: none\n[P2] docs.md:7 — Clarify the example.\n  Suggested fix: update the flag.\nVERDICT: FIX-FIRST\n' \
  '.action=="allow-existing-merge-workflow" and (.facts.deferred_findings[0].text | contains("\n  Suggested fix:"))')" || DEFERRAL_RC=$?
check 'P2-4 complete deferred blocks survive the accepted-artifact query' "$DEFERRAL_RC" "$DEFERRAL_DETAIL"
check 'P2-4 multiline deferral envelope passes the consumer boundary' \
  "$(pg_review_decision_envelope_valid "$TMP/deferral-multiline.json"; printf '%s' "$?")"

check 'engine harvest hints carry the sized collection timeout, never the old fixed 20m' \
  "$(grep -Fq 'HARVEST_HINT_TIMEOUT="$(pg_harvest_hint_timeout)"' "$ENGINE" && grep -Fq 'TIMEOUT="$(pg_fresh_hint_timeout)"' "$ENGINE" && ! grep -Fq -- '--timeout 20m' "$ENGINE"; printf '%s' "$?")"
# The library prints operator-facing harvest hints too (pg_report_capacity_holders). Grepping only
# the engine is how a hardcoded 20m survived the v0.41 sizing pass while this very check passed, so
# EVERY shipped shell file is scanned for a stale fixed collection wait, not just the engine.
STALE_WAIT_FILES=""
for f in "$ENGINE" "$LIBSH" "$HERE/../daemon/daemon.sh"; do
  grep -Fq -- '--timeout 20m' "$f" && STALE_WAIT_FILES="$STALE_WAIT_FILES $(basename "$f")"
  grep -Fq -- '--timeout 30m' "$f" && STALE_WAIT_FILES="$STALE_WAIT_FILES $(basename "$f")"
done
check 'no shipped shell file hardcodes a pre-v0.41 collection or review wait' \
  "$([ -z "$STALE_WAIT_FILES" ]; printf '%s' "$?")" "$STALE_WAIT_FILES"
check 'the sized collection wait has one definition every renderer shares' \
  "$(grep -Fq 'pg_harvest_hint_timeout() { echo "${PRO_GATE_HARVEST_TIMEOUT:-45m}"; }' "$LIBSH" && grep -Fq 'pg_harvest_hint_timeout)' "$LIBSH"; printf '%s' "$?")"

check 'named product choice is the only prompt and is freshness-validated non-authoritative input' \
  "$(grep -Fq 'ask-named-product-choice is the only prompt.' "$SKILL" && grep -Fq 'freshness-validated' "$SKILL" && grep -Fq 'non-authoritatively' "$SKILL" && grep -Fq 're-enters after code or policy change' "$SKILL" && grep -Fq 'Malformed or stale selection stops.' "$SKILL"; printf '%s' "$?")"
check 'skill invokes the real advisory query and guarded effect surfaces' \
  "$(grep -Fq -- '--review-decision --json' "$SKILL" && grep -Fq -- '--review-decision-effect' "$SKILL"; printf '%s' "$?")"
check 'relay invokes the real advisory query and guarded effect surfaces' \
  "$(grep -Fq -- '--review-decision --json' "$RELAY" && grep -Fq -- '--review-decision-effect' "$RELAY"; printf '%s' "$?")"
check 'skill and relay return named choices through the canonical freshness surface' \
  "$(for consumer in "$SKILL" "$RELAY"; do grep -Fq -- '--review-choice-selection' "$consumer" && grep -Fq 'effect_request.snapshot_digest' "$consumer" && grep -Fq 'jq -cnS' "$consumer" || exit 1; done; printf '%s' "$?")"
check 'skill retains exact version update, evidence, no-merge, and fixer fallback authority' \
  "$(grep -Fq 'raw.githubusercontent.com/StartupBros-com/pro-gate/v${PLUGIN_VERSION}/install.sh' "$SKILL" && grep -Fq 'prepare-matching-review-evidence' "$SKILL" && grep -Fq 'Stop before merge' "$SKILL" && grep -Fq 'codex exec' "$SKILL" && grep -Fq 'apply the edits directly in this session' "$SKILL"; printf '%s' "$?")"
check 'Codex metadata uses the supported invoke-only policy and does not redefine review authority' \
  "$(test -f "$CODEX_METADATA" && grep -Eq '^[[:space:]]*allow_implicit_invocation:[[:space:]]*false[[:space:]]*$' "$CODEX_METADATA" && ! grep -Eq '^[[:space:]]*metadata:' "$CODEX_METADATA"; printf '%s' "$?")"

[ "$FAILS" -eq 0 ] && { echo 'ALL PASS'; exit 0; }
printf '%s FAILURES\n' "$FAILS"
exit 1
