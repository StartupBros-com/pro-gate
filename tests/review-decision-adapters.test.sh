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
    ([.action_effects[] | select(.execution_class == "named-product-choice") | .action] == ["ask-named-product-choice"])
  ' "$contract" >/dev/null || return 1

  jq -e --slurpfile contract "$contract" '
    .contract_id == $contract[0].contract_id and .corpus_version == 1 and
    (.base_facts | keys | sort) == ["active_index","completed_results","evidence","governor","input","named_choice","observation","prior_review","reservation","target","transport"] and
    .base_facts.transport == "review-decision/v1" and
    ([.. | objects | keys[] | select(. == "status" or . == "next_action")] | length == 0) and
    (.cases | length == 8) and
    ([.cases[].expected.action] | unique | sort) == ([$contract[0].action_effects[].action] | sort) and
    ([.cases[] | select(.expected.action != .expected.effect)] | length == 0) and
    ([.cases[] | select(.expected.execution_class == "named-product-choice") | .expected.action] == ["ask-named-product-choice"]) and
    ([.cases[] | select(.expected.execution_class != "named-product-choice") | .expected.action] | length == 7)
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

# The frozen corpus is the U3 representation of the prompt boundary. It does not claim that an
# adapter dispatches it; U4 adds those consumer-level assertions.
check 'frozen corpus marks seven prompt-free classes and one named-choice-only prompt' \
  "$(jq -e '[.cases[].expected | select(.execution_class == "named-product-choice")] | length == 1 and .[0].action == "ask-named-product-choice"' "$CORPUS" >/dev/null && [ "$(jq '[.cases[].expected | select(.execution_class != "named-product-choice")] | length' "$CORPUS")" -eq 7 ]; printf '%s' "$?")"

[ "$FAILS" -eq 0 ] && { echo 'ALL PASS'; exit 0; }
printf '%s FAILURES\n' "$FAILS"
exit 1
