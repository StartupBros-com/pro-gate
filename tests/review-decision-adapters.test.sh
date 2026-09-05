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
ENVELOPES_OK=1; FABRICATED_OK=1; INJECTED_OK=1; DIGEST_OK=1; SYMLINK_OK=1; ENVELOPE_DETAIL=""
i=0
while [ "$i" -lt "$CASE_COUNT" ]; do
  corpus_envelope "$i" "$TMP/envelope-$i.json"
  pg_review_decision_envelope_valid "$TMP/envelope-$i.json" || { ENVELOPES_OK=0; ENVELOPE_DETAIL="$ENVELOPE_DETAIL case=$i:rejected-genuine"; }
  # Swap the outer action for another closed action: the envelope is plausible JSON, but the
  # reducer re-run over its own facts no longer matches byte-for-byte.
  jq -c 'if .action == "stop-without-new-review" then .action="allow-existing-merge-workflow" | .effect_request.action="allow-existing-merge-workflow" | .effect_request.effect="allow-existing-merge-workflow" else .action="stop-without-new-review" | .effect_request.action="stop-without-new-review" | .effect_request.effect="stop-without-new-review" | .effect_request.execution_class="report-only" end' \
    "$TMP/envelope-$i.json" > "$TMP/fabricated-$i.json"
  pg_review_decision_envelope_valid "$TMP/fabricated-$i.json" && { FABRICATED_OK=0; ENVELOPE_DETAIL="$ENVELOPE_DETAIL case=$i:accepted-fabricated"; }
  jq -c '.facts.next_action="wait"' "$TMP/envelope-$i.json" > "$TMP/injected-$i.json"
  pg_review_decision_envelope_valid "$TMP/injected-$i.json" && { INJECTED_OK=0; ENVELOPE_DETAIL="$ENVELOPE_DETAIL case=$i:accepted-next_action"; }
  jq -c '.contract.contract_digest="0000000000000000000000000000000000000000000000000000000000000000"' "$TMP/envelope-$i.json" > "$TMP/digest-$i.json"
  pg_review_decision_envelope_valid "$TMP/digest-$i.json" && { DIGEST_OK=0; ENVELOPE_DETAIL="$ENVELOPE_DETAIL case=$i:accepted-foreign-digest"; }
  i=$((i + 1))
done
ln -s "$TMP/envelope-0.json" "$TMP/envelope-link.json"
pg_review_decision_envelope_valid "$TMP/envelope-link.json" && SYMLINK_OK=0
check 'library validator accepts every envelope the runtime emits for the frozen corpus' "$([ "$ENVELOPES_OK" = 1 ]; printf '%s' "$?")" "$ENVELOPE_DETAIL"
check 'library validator rejects an envelope whose outer action was swapped for another closed action' "$([ "$FABRICATED_OK" = 1 ]; printf '%s' "$?")" "$ENVELOPE_DETAIL"
check 'library validator rejects a blocking-wait next_action injected into the facts' "$([ "$INJECTED_OK" = 1 ]; printf '%s' "$?")" "$ENVELOPE_DETAIL"
check 'library validator rejects a foreign contract digest' "$([ "$DIGEST_OK" = 1 ]; printf '%s' "$?")" "$ENVELOPE_DETAIL"
check 'library validator refuses a symlinked decision file' "$([ "$SYMLINK_OK" = 1 ]; printf '%s' "$?")"

# The wait each prose consumer tells a caller to pass must match the engine's sized defaults
# (v0.41): 60m for a fresh review, 45m for recovery and harvest. A drift here silently reinstates
# the repeat-collection churn the sizing removed.
for consumer in "${CONSUMERS[@]}"; do
  check "$(basename "$consumer") passes the sized fresh-review and recovery timeouts" \
    "$(grep -Fq -- '--out "$OUT" --timeout 60m' "$consumer" && grep -Fq -- '--out "$OUT" --timeout 45m' "$consumer" && grep -Fq -- '--out <out> --timeout 45m' "$consumer" && ! grep -Fq -- '--timeout 20m' "$consumer" && ! grep -Fq -- '--timeout 30m' "$consumer"; printf '%s' "$?")"
done
ENGINE="$HERE/../bin/oracle-review.sh"
check 'engine harvest hints carry the sized collection timeout, never the old fixed 20m' \
  "$(grep -Fq 'HARVEST_HINT_TIMEOUT="${PRO_GATE_HARVEST_TIMEOUT:-45m}"' "$ENGINE" && grep -Fq 'TIMEOUT="${PRO_GATE_TIMEOUT:-60m}"' "$ENGINE" && ! grep -Fq -- '--timeout 20m' "$ENGINE"; printf '%s' "$?")"

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
