#!/usr/bin/env bash
# oracle-review.sh: run a FINAL-TIER Pro review of a PR (or diff) via oracle.
# Single source of truth for "how we call oracle for a review" — the /pro-gate skill and the
# daemon both call this. Cross-platform: macOS drives signed-in Chrome natively; WSL/Linux
# attaches to the durable Xvfb Chrome over CDP.
#
# CALLERS — keep in sync IN THE SAME PR whenever the caller contract changes (status file,
# exit codes, recovery semantics); they have drifted before (v0.18 missed the agent):
#   skills/pro-gate/SKILL.md      (authoritative caller guide)
#   agents/oracle-reviewer.md     (thin relay agent for other pipelines)
#
# Usage:
#   oracle-review.sh --pr <url|number> [--repo <dir>] [--input both|bundle|connector]
#                    [--out <file>] [--timeout <dur>] [--extra-files <glob>]
#                    [--confirm <prior-review-file>]
#   oracle-review.sh --diff <patchfile> --repo <dir> [--out <file>] ...
#       Pass --pr TOGETHER with --diff when the diff belongs to a PR: the change identity
#       (round budget, per-change lock, reservations) stays the PR's instead of forking into
#       a separate repo+branch identity.
#   oracle-review.sh --confirm <prior-review-file> ...
#       Confirming pass (v0.22): attaches the prior review and instructs the model to verify
#       EVERY prior P0/P1 as RESOLVED or STILL-PRESENT before reporting new findings. A
#       budget-accounted engine run like any other.
#   oracle-review.sh --harvest <run-marker> --out <file> [--timeout <dur>]
#       Collect a review whose run ended in-progress (exit 9): the Pro slot was spent but the
#       model was still generating when the salvage budget ran out. No new slot is spent.
#   oracle-review.sh --status [<pr-number|pr-url|pg-run-marker>] [--json]
#       Expert/read-only diagnostics (v0.27): join reservations, round budget, remembered
#       conversation URLs, and the ledger, and print each matching run's state plus the exact
#       next command. `--json` is the detailed machine contract; omit the query for all state.
#   oracle-review.sh --recover <pr-number|pr-url|pg-run-marker> [--repo <dir>] [--out <file>] [--timeout <dur>]
#       Recover exactly one existing review (v0.35). Accepts a decimal PR number, canonical PR
#       URL, or exact marker. Exact markers win; repository-qualified queries select the unique
#       newest charged run, while unproved or ambiguous candidates only disambiguate. It returns
#       a verified artifact or runs marker-only harvest; it never dispatches --pr, creates a new
#       slot, or spends a new round. Plain states: Review ready; Checking for completed review;
#       Still working; Review superseded; No review remains; Browser needs attention. A readable
#       tab can be stale, so the engine safely
#       revalidates the canonical server conversation without changing the source tab.
set -uo pipefail

# --- locate + source the shared lib (works from repo and from deployed location) ---
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in "$SELF/lib.sh" "$SELF/../lib/pro-gate-lib.sh" "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/lib.sh"; do
  [ -f "$c" ] && { . "$c"; break; }
done
type pg_os >/dev/null 2>&1 || { echo "ERROR: pro-gate lib not found (lib.sh)" >&2; exit 10; }

pg_augment_path
pg_load_env
OS="$(pg_os)"; MODE="$(pg_browser_mode)"

# One live run per --out (gate #54 r11): the status sidecar is keyed by $OUT, so two
# concurrent runs sharing it would overwrite each other's phase/marker and cross-feed their
# pollers even with distinct result artifacts. Held for the process lifetime; best-effort
# where flock or the directory is unavailable. gate #91 round3 P1 (:880): extracted to a
# function — defined here, ahead of both callers — so --recover's own publications (:191-219)
# can take the IDENTICAL guard before writing $OUT instead of doing it unguarded. A fast-path
# recovery used to publish straight to --out with no lock at all, racing a live fresh/harvest
# run (or a second concurrent recovery) that IS holding this guard: two publishers, two
# "success" reports, one silently overwritten. Logic, fallbacks, and messages are VERBATIM
# from the original inline block; only the failure signal changed (return 1, not exit) so
# each caller can map "cannot acquire" onto its own contract — a fresh/harvest run keeps its
# long-standing exit 2, --recover maps it onto the trouble state its own contract promises.
pg_out_guard_acquire() {
  PG_OUT_GUARD_OK=0
  if pg_have flock; then
    if { exec {PG_OUT_GUARD_FD}>>"$OUT.lock"; } 2>/dev/null; then
      if flock -n "$PG_OUT_GUARD_FD" 2>/dev/null; then PG_OUT_GUARD_OK=1; else
        echo "ERROR: another live run is already using --out $OUT (its status sidecar would be overwritten). Use a distinct --out per run." >&2
        return 1
      fi
    fi
  fi
  if [ "$PG_OUT_GUARD_OK" != 1 ]; then
    # mkdir/PID fallback (gate #54 r12): stock macOS has no flock, and skipping the guard
    # there reopens the sidecar cross-feed. Dead owners self-heal; a live owner refuses.
    PG_OUT_GUARD_DIR="$OUT.lock.d"
    if mkdir "$PG_OUT_GUARD_DIR" 2>/dev/null; then
      echo "$$" > "$PG_OUT_GUARD_DIR/pid" 2>/dev/null || true
      PG_OUT_GUARD_OK=1
    else
      OG_PID="$(cat "$PG_OUT_GUARD_DIR/pid" 2>/dev/null || true)"
      case "$OG_PID" in
        ''|*[!0-9]*) ;;
        *) if kill -0 "$OG_PID" 2>/dev/null; then
             echo "ERROR: another live run (pid $OG_PID) is already using --out $OUT. Use a distinct --out per run." >&2
             return 1
           fi ;;
      esac
      # Atomic TAKEOVER of the stale dir (gate #54 r14): rename it aside first — exactly one
      # racer's mv succeeds; the loser's retake mkdir then fails against the winner's fresh
      # dir and it refuses below. Immediate rm+mkdir let both racers "win".
      if mv "$PG_OUT_GUARD_DIR" "$PG_OUT_GUARD_DIR.reap.$$" 2>/dev/null; then
        rm -f "$PG_OUT_GUARD_DIR.reap.$$/pid" 2>/dev/null
        rmdir "$PG_OUT_GUARD_DIR.reap.$$" 2>/dev/null
        if mkdir "$PG_OUT_GUARD_DIR" 2>/dev/null; then
          echo "$$" > "$PG_OUT_GUARD_DIR/pid" 2>/dev/null || true
          [ "$(cat "$PG_OUT_GUARD_DIR/pid" 2>/dev/null)" = "$$" ] && PG_OUT_GUARD_OK=1
        fi
      fi
    fi
    if [ "$PG_OUT_GUARD_OK" != 1 ]; then
      # Fail CLOSED: with no ownership established, two runs could share one sidecar.
      echo "ERROR: cannot establish ownership of --out $OUT (directory unwritable?). Choose an --out in a writable directory." >&2
      return 1
    fi
  fi
  return 0
}

PR=""; REPO=""; DIFF_FILE=""; DIFF_IS_CALLER_SUPPLIED=0; INPUT="both"; OUT=""; TIMEOUT="30m"; EXTRA_GLOB=""; HARVEST_MARKER=""; HARVEST_REQUESTED=0; CONFIRM_FILE=""
STATUS_REQUESTED=0; STATUS_QUERY=""; AS_JSON=0; RECOVER_REQUESTED=0; RECOVER_QUERY=""
REVIEW_DECISION_REQUESTED=0; REVIEW_DECISION_EFFECT_FILE=""; REVIEW_CHOICE_SELECTION_FILE=""
while [ $# -gt 0 ]; do
  # gate #91 P2 (:65): every flag below except --status takes a REQUIRED second argument via raw
  # "$2"/"${2:-}" + "shift 2". With no errexit, a flag left trailing (no operand) hit one of two
  # silent failures instead of a usage error: "$2" with no fallback tripped `set -u`'s unbound-
  # variable abort (--pr and friends), while "${2:-}" (--harvest/--recover, added so a bare flag
  # could be a deliberate no-op) suppressed that abort but left `shift 2` failing on only one
  # argument remaining — shift is atomic, so it shifts NOTHING, $1 stays pinned on the flag, and
  # the loop spins forever. One guard here, before any branch consumes its operand, replaces both
  # symptoms with a clean usage error. --status is excluded: its second argument is deliberately
  # optional (its own branch below already handles "missing").
  case "$1" in
    --pr|--repo|--diff|--input|--out|--timeout|--extra-files|--confirm|--harvest|--recover|--review-decision-effect|--review-choice-selection)
      [ $# -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; };;
  esac
  case "$1" in
    --pr) PR="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --diff) DIFF_FILE="$2"; DIFF_IS_CALLER_SUPPLIED=1; shift 2;;
    --input) INPUT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --extra-files) EXTRA_GLOB="$2"; shift 2;;
    --confirm) CONFIRM_FILE="$2"; shift 2;;
    --harvest) HARVEST_REQUESTED=1; HARVEST_MARKER="${2:-}"; shift 2;;
    --recover) RECOVER_REQUESTED=1; RECOVER_QUERY="${2:-}"; shift 2;;
    --review-decision) REVIEW_DECISION_REQUESTED=1; shift;;
    --review-decision-effect) REVIEW_DECISION_REQUESTED=1; REVIEW_DECISION_EFFECT_FILE="$2"; shift 2;;
    --review-choice-selection) REVIEW_CHOICE_SELECTION_FILE="$2"; shift 2;;
    # --status takes an OPTIONAL query (a following --flag or nothing means "all state").
    --status) STATUS_REQUESTED=1
      case "${2:-}" in ''|--*) shift 1;; *) STATUS_QUERY="$2"; shift 2;; esac;;
    --json) AS_JSON=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
if [ "$AS_JSON" = 1 ] && [ "$STATUS_REQUESTED" != 1 ] && [ "$REVIEW_DECISION_REQUESTED" != 1 ]; then
  echo "ERROR: --json is only meaningful with --status or --review-decision" >&2
  exit 2
fi
if [ -n "$REVIEW_CHOICE_SELECTION_FILE" ] && [ "$REVIEW_DECISION_REQUESTED" != 1 ]; then
  echo 'ERROR: --review-choice-selection requires --review-decision' >&2
  exit 2
fi
if [ "$HARVEST_REQUESTED" = 1 ] && [ -z "$HARVEST_MARKER" ]; then
  echo "ERROR: --harvest requires a non-empty run marker" >&2
  exit 2
fi
if [ -n "$CONFIRM_FILE" ] && [ ! -s "$CONFIRM_FILE" ]; then
  echo "ERROR: --confirm file not found or empty: $CONFIRM_FILE" >&2
  exit 2
fi

# review-decision/v1 resolution is deliberately an early, read-only path. It must never borrow
# the regular engine's housekeeping, browser preflight, locks, reconciliation, status sidecars,
# slots, round recording, or binding/publication writes: the answer is advisory until an effect
# boundary assembles the same facts again. The U1 reducer remains the sole policy authority.
pg_review_decision_repair_result_binding() { # marker input-binding-json
  local marker="$1" input="$2" artifact verdict input_digest accepted epoch base head proof result lock
  pg_reservation_marker_ok "$marker" || return 1
  artifact="$(pg_completed_dir)/$marker"
  [ -f "$artifact" ] && [ ! -L "$artifact" ] && pg_is_review "$artifact" || return 1
  input_digest="$(pg_review_sha256_text "$input")" || return 1
  verdict="$(pg_extract_verdict "$artifact")"
  case "$verdict" in SHIP|FIX-FIRST|NEEDS-DISCUSSION) ;; *) return 1;; esac
  epoch="$(jq -r .charged_spend_epoch <<<"$input")"
  case "$epoch" in ''|*[!0-9]*) return 1;; esac
  accepted="$(date +%s)"
  proof=null
  if [ "$verdict" = SHIP ]; then
    case "$(jq -r .evidence.mode <<<"$input")" in
      full-pr)
        base="$(jq -r .evidence.proof.base_oid <<<"$input")"; head="$(jq -r .evidence.proof.head_oid <<<"$input")"
        proof="$(jq -cnS --arg base "$base" --arg head "$head" --arg digest "$(jq -r .evidence.proof.raw_patch_digest <<<"$input")" '{base_oid:$base,diff_digest:$digest,head_oid:$head}')" || return 1 ;;
      scoped-delta)
        base="$(jq -r .evidence.proof.base_oid <<<"$input")"; head="$(jq -r .evidence.proof.end_oid <<<"$input")"
        # Merge eligibility binds the complete raw endpoint, never the filtered review payload.
        proof="$(jq -cnS --arg base "$base" --arg head "$head" --arg digest "$(jq -r .evidence.proof.raw_digest <<<"$input")" '{base_oid:$base,diff_digest:$digest,head_oid:$head}')" || return 1 ;;
      *) return 1 ;;
    esac
  fi
  result="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$marker" --arg digest "$(pg_sha256 "$artifact")" \
    --arg ib "$input_digest" --arg verdict "$verdict" --argjson accepted "$accepted" --argjson proof "$proof" \
    '{accepted_epoch:$accepted,artifact:{digest:$digest,path:("completed/"+$marker)},contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,input_binding_digest:$ib,input_binding_identity:$marker,marker:$marker,named_choice:null,provenance:{outcome:"accepted",validated_epoch:$accepted},record_type:"review-result-binding/v1",record_version:1,ship_proof:$proof,verdict:$verdict}')" || return 1
  lock="${PRO_GATE_REVIEW_DECISION_LOCK_DIR:-$PRO_GATE_HOME/review-decision-locks}/$marker"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 1
  pg_lock "$lock" "${PRO_GATE_REVIEW_EFFECT_LOCK_WAIT:-5}" || return 1
  # The no-clobber artifact was already persisted. This only installs its one immutable sibling;
  # a byte-identical replay succeeds, while a conflicting sibling remains collect-only.
  pg_review_result_binding_write "$marker" "$result"
}

# Rebuild a binding's evidence relation from the exact files named by the invocation. This checks
# proof only: marker and charged epoch remain immutable history, and are separately validated.
# Scoped review deliberately hashes its raw endpoint and reviewed payload independently.
pg_review_decision_input_proof_current() { # binding repo pr host owner name head base
  local binding="$1" repo="$2" pr="$3" host="$4" owner="$5" name="$6" head="$7" base="$8"
  local mode endpoint reviewed manifest confirmation raw_digest reviewed_digest manifest_digest confirmation_digest lineage
  pg_review_input_binding_validate "$binding" "$(jq -r '.marker // ""' <<<"$binding" 2>/dev/null)" || return 1
  jq -e --arg h "$host" --arg o "$owner" --arg r "$name" --argjson p "$pr" --arg head "$head" \
    '.repository.host==$h and .repository.owner==$o and .repository.repo==$r and .target.pr==$p and .target.head_oid==$head' \
    <<<"$binding" >/dev/null 2>&1 || return 1
  mode="$(jq -r .evidence.mode <<<"$binding")"
  reviewed="${REVIEW_DECISION_REVIEWED_DIFF_FILE:-${DIFF_FILE:-}}"
  case "$mode" in
    connector)
      [ "$INPUT" = connector ] || [ "$INPUT" = both ] || return 1
      jq -e --arg target "$host/$owner/$name" --arg head "$head" \
        '.evidence.proof.repository_target==$target and .evidence.proof.commit_target==$head' \
        <<<"$binding" >/dev/null 2>&1 ;;
    full-pr)
      [ "$INPUT" = bundle ] || [ "$INPUT" = both ] || return 1
      endpoint="${PRO_GATE_REVIEW_ENDPOINT_PATCH:-}"
      [ -n "$base" ] && [ -f "$endpoint" ] && [ ! -L "$endpoint" ] \
        && [ -f "$reviewed" ] && [ ! -L "$reviewed" ] || return 1
      [ "$(wc -c < "$endpoint" 2>/dev/null | tr -d ' ')" -le 26214400 ] \
        && [ "$(wc -c < "$reviewed" 2>/dev/null | tr -d ' ')" -le 26214400 ] || return 1
      raw_digest="$(pg_sha256 "$reviewed" 2>/dev/null || true)"
      endpoint="$(pg_sha256 "$endpoint" 2>/dev/null || true)"
      jq -e --arg base "$base" --arg head "$head" --arg raw "$raw_digest" --arg endpoint "$endpoint" \
        '.evidence.proof.base_oid==$base and .evidence.proof.head_oid==$head and .evidence.proof.raw_patch_digest==$raw and .evidence.proof.endpoint_digest==$endpoint' \
        <<<"$binding" >/dev/null 2>&1 ;;
    scoped-delta)
      [ "$INPUT" = bundle ] || [ "$INPUT" = both ] || return 1
      endpoint="${PRO_GATE_REVIEW_ENDPOINT_PATCH:-}"; manifest="${PRO_GATE_REVIEW_FILTER_MANIFEST:-}"; confirmation="${CONFIRM_FILE:-}"
      [ -n "$base" ] && [ -f "$endpoint" ] && [ ! -L "$endpoint" ] \
        && [ -f "$reviewed" ] && [ ! -L "$reviewed" ] && [ -f "$manifest" ] && [ ! -L "$manifest" ] \
        && [ -f "$confirmation" ] && [ ! -L "$confirmation" ] || return 1
      [ "$(wc -c < "$endpoint" 2>/dev/null | tr -d ' ')" -le 26214400 ] \
        && [ "$(wc -c < "$reviewed" 2>/dev/null | tr -d ' ')" -le 26214400 ] \
        && [ "$(wc -c < "$manifest" 2>/dev/null | tr -d ' ')" -le 65536 ] \
        && [ "$(wc -c < "$confirmation" 2>/dev/null | tr -d ' ')" -le 262144 ] && pg_is_review "$confirmation" || return 1
      raw_digest="$(pg_sha256 "$endpoint" 2>/dev/null || true)"
      reviewed_digest="$(pg_sha256 "$reviewed" 2>/dev/null || true)"
      manifest_digest="$(pg_sha256 "$manifest" 2>/dev/null || true)"
      confirmation_digest="$(pg_sha256 "$confirmation" 2>/dev/null || true)"
      lineage="confirmation:${confirmation_digest}"
      jq -e --arg base "$base" --arg head "$head" --arg raw "$raw_digest" --arg reviewed "$reviewed_digest" \
        --arg manifest "$manifest_digest" --arg lineage "$lineage" \
        '.evidence.proof.base_oid==$base and .evidence.proof.end_oid==$head and .evidence.proof.raw_digest==$raw and .evidence.proof.reviewed_payload_digest==$reviewed and .evidence.proof.filtering_manifest_digest==$manifest and .evidence.proof.lineage_identity==$lineage' \
        <<<"$binding" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# A query never writes an uncharged record. When the invocation itself proves a current relation,
# it supplies this deterministic, validated template for the guarded effect to clone after charge.
pg_review_decision_prospective_input_binding() { # repo pr host owner name head base round-key
  local repo="$1" pr="$2" host="$3" owner="$4" name="$5" head="$6" base="$7" round_key="$8"
  local marker="pg-run-prospective-${round_key}" endpoint reviewed manifest confirmation raw_digest reviewed_digest manifest_digest confirmation_digest lineage binding
  reviewed="${REVIEW_DECISION_REVIEWED_DIFF_FILE:-${DIFF_FILE:-}}"
  binding=""
  if { [ "$INPUT" = bundle ] || [ "$INPUT" = both ]; } && [ -n "${PRO_GATE_REVIEW_FILTER_MANIFEST:-}" ] && [ -n "${CONFIRM_FILE:-}" ]; then
    endpoint="${PRO_GATE_REVIEW_ENDPOINT_PATCH:-}"; manifest="$PRO_GATE_REVIEW_FILTER_MANIFEST"; confirmation="$CONFIRM_FILE"
    if [ -n "$base" ] && [ -f "$endpoint" ] && [ ! -L "$endpoint" ] && [ -f "$reviewed" ] && [ ! -L "$reviewed" ] \
       && [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -f "$confirmation" ] && [ ! -L "$confirmation" ] \
       && [ "$(wc -c < "$endpoint" 2>/dev/null | tr -d ' ')" -le 26214400 ] \
       && [ "$(wc -c < "$reviewed" 2>/dev/null | tr -d ' ')" -le 26214400 ] \
       && [ "$(wc -c < "$manifest" 2>/dev/null | tr -d ' ')" -le 65536 ] \
       && [ "$(wc -c < "$confirmation" 2>/dev/null | tr -d ' ')" -le 262144 ] && pg_is_review "$confirmation"; then
      raw_digest="$(pg_sha256 "$endpoint")"; reviewed_digest="$(pg_sha256 "$reviewed")"
      manifest_digest="$(pg_sha256 "$manifest")"; confirmation_digest="$(pg_sha256 "$confirmation")"; lineage="confirmation:${confirmation_digest}"
      binding="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$marker" --arg host "$host" --arg owner "$owner" --arg repo "$name" --argjson pr "$pr" --arg base "$base" --arg head "$head" --arg raw "$raw_digest" --arg reviewed "$reviewed_digest" --arg manifest "$manifest_digest" --arg lineage "$lineage" '{charged_spend_epoch:1,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("scoped-delta:"+$base+":"+$head+":"+$reviewed),mode:"scoped-delta",proof:{base_oid:$base,end_oid:$head,filtering_manifest_digest:$manifest,lineage_identity:$lineage,raw_digest:$raw,reviewed_payload_digest:$reviewed,scope_algorithm:"unified-diff-v1"}},marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:$host,owner:$owner,repo:$repo},target:{head_oid:$head,kind:"pull-request",pr:$pr}}')"
    fi
  fi
  if [ -z "$binding" ] && { [ "$INPUT" = bundle ] || [ "$INPUT" = both ]; }; then
    endpoint="${PRO_GATE_REVIEW_ENDPOINT_PATCH:-}"
    if [ -n "$base" ] && [ -f "$endpoint" ] && [ ! -L "$endpoint" ] && [ -f "$reviewed" ] && [ ! -L "$reviewed" ] \
       && [ "$(wc -c < "$endpoint" 2>/dev/null | tr -d ' ')" -le 26214400 ] && [ "$(wc -c < "$reviewed" 2>/dev/null | tr -d ' ')" -le 26214400 ]; then
      endpoint="$(pg_sha256 "$endpoint")"; raw_digest="$(pg_sha256 "$reviewed")"
      binding="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$marker" --arg host "$host" --arg owner "$owner" --arg repo "$name" --argjson pr "$pr" --arg base "$base" --arg head "$head" --arg endpoint "$endpoint" --arg raw "$raw_digest" '{charged_spend_epoch:1,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("full-pr:"+$base+":"+$head),mode:"full-pr",proof:{base_oid:$base,endpoint_digest:$endpoint,head_oid:$head,raw_patch_digest:$raw}},marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:$host,owner:$owner,repo:$repo},target:{head_oid:$head,kind:"pull-request",pr:$pr}}')"
    fi
  fi
  # `both` requires a bundle relation. Connector is a distinct, explicitly requested current
  # relation, never a fallback when bundle proof is absent.
  if [ -z "$binding" ] && [ "$INPUT" = connector ]; then
    binding="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$marker" --arg host "$host" --arg owner "$owner" --arg repo "$name" --argjson pr "$pr" --arg head "$head" '{charged_spend_epoch:1,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("connector:"+$host+"/"+$owner+"/"+$repo+":"+$head),mode:"connector",proof:{commit_target:$head,endpoint_digest:null,raw_diff_digest:null,repository_target:($host+"/"+$owner+"/"+$repo)}},marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:$host,owner:$owner,repo:$repo},target:{head_oid:$head,kind:"pull-request",pr:$pr}}')"
  fi
  [ -n "$binding" ] && pg_review_decision_input_proof_current "$binding" "$repo" "$pr" "$host" "$owner" "$name" "$head" "$base" || return 1
  printf '%s' "$binding"
}

# Selection is input to an advisory reduction, never a durable authorization record. Canonical
# bytes make a copied selection deterministic and prevent trailing prose from becoming a channel.
pg_review_decision_choice_selection_read() { # file -> canonical {selected_id,snapshot_digest}
  local f="$1" json canonical
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" -le 65536 ] || return 1
  json="$(cat "$f" 2>/dev/null)" || return 1
  canonical="$(pg_review_json_canonical "$json")" || return 1
  [ "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" = "${#canonical}" ] || return 1
  jq -e 'keys == ["selected_id","snapshot_digest"] and
    (.selected_id|type=="string" and length>0 and length<=256 and test("^[A-Za-z0-9._:/+-]+$")) and
    (.snapshot_digest|type=="string" and test("^[0-9a-f]{64}$"))' <<<"$canonical" >/dev/null 2>&1 || return 1
  printf '%s' "$canonical"
}

pg_review_decision_cli() {
  local repo pr_num remote ident host owner repo_name head base raw_digest round_key code_identity
  local input_proven=false input_binding_valid=false input_identity evidence_identity evidence_state
  local input_marker="" input_record="" input_digest="" f marker candidate candidate_relation desired_relation exact=false active_marker="" active_state=none
  local endpoint reviewed manifest confirmation endpoint_digest reviewed_digest manifest_digest confirmation_digest lineage mode ship_digest
  local reservation_marker="" reservation_state=none governor_granted=false completed='[]' prior_candidates='[]' prior_review result artifact artifact_digest canonical
  local facts decision effect_ok=false prospective exact_inputs='[]' choice_candidates='[]' choice_outcomes='[]' choice_selected="" choice_snapshot="" selection="" selection_supplied=false current_verdict=NONE current_canonical="" effect_input attempt_snapshot attempt_source

  pg_have jq || { echo 'ERROR: review-decision/v1 requires jq' >&2; return 2; }
  repo="${REPO:-$(pwd)}"
  # Linked worktrees have a .git *file*, while bare repositories answer false. Ask Git itself
  # for the bounded working-tree proof instead of inferring repository shape from its metadata.
  [ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
    || { echo 'ERROR: review-decision requires a local git working tree' >&2; return 2; }
  case "$PR" in
    http*://*/pull/*)
      pr_num="${PR%/}"; pr_num="${pr_num##*/}"
      ident="$(pg_repo_identity_from_url "${PR%/}" 2>/dev/null || true)"
      [ -n "$ident" ] || { echo 'ERROR: review-decision requires a canonical PR target' >&2; return 2; }
      ;;
    *)
      pr_num="$PR"
      remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
      ident="$(pg_repo_identity_from_url "$remote" 2>/dev/null || true)"
      [ -n "$ident" ] || { echo 'ERROR: review-decision requires canonical origin repository proof' >&2; return 2; }
      ;;
  esac
  pr_num="$(pg_pr_number_normalize "$pr_num")" \
    || { echo 'ERROR: review-decision requires a numeric or canonical PR target' >&2; return 2; }
  IFS=$'\t' read -r host owner repo_name <<< "$ident"
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  case "$head" in *[!0-9a-f]*|'') echo 'ERROR: review-decision cannot prove the current head' >&2; return 2;; esac
  base="$(git -C "$repo" merge-base HEAD '@{upstream}' 2>/dev/null || git -C "$repo" rev-parse HEAD^ 2>/dev/null || true)"
  case "$base" in *[!0-9a-f]*|'') base="";; esac
  if [ -n "$DIFF_FILE" ]; then
    [ -f "$DIFF_FILE" ] && [ ! -L "$DIFF_FILE" ] || { echo 'ERROR: review-decision diff must be a regular file' >&2; return 2; }
    raw_digest="$(pg_sha256 "$DIFF_FILE")"
  else
    raw_digest=""
  fi
  # The effect path must rehash the caller's reviewed bytes even if normal diff hygiene later
  # chooses a filtered engine payload. It is never interchangeable with the raw endpoint bytes.
  REVIEW_DECISION_REVIEWED_DIFF_FILE="$DIFF_FILE"
  round_key="$(printf '%s-%s-%s' "$owner" "$repo_name" "$pr_num" | tr -c 'A-Za-z0-9.\n-' '-')"
  # Code identity is deliberately independent from the marker, spend epoch, and immutable-binding
  # digest. It describes only the canonical repository target and current PR head.
  code_identity="${host}:${owner}/${repo_name}:${pr_num}:${head}"
  input_identity="$code_identity"
  evidence_identity='evidence:none'; evidence_state=missing

  # Build the invocation's desired relation before looking at history. In `both` mode, this is
  # bundle-only: a historical connector proof can inform progress but can never become current.
  prospective="$(pg_review_decision_prospective_input_binding "$repo" "$pr_num" "$host" "$owner" "$repo_name" "$head" "$base" "$round_key" 2>/dev/null || true)"
  if [ -n "$prospective" ]; then
    desired_relation="$(jq -cS '{repository,target,evidence}' <<<"$prospective")"
    input_marker="$(jq -r .marker <<<"$prospective")"; input_record="$prospective"
    input_digest="$(pg_review_sha256_text "$prospective")"
    input_binding_valid=true; input_proven=true
    # The reducer sees the complete relation identity, not the human-facing evidence label: a
    # scoped manifest or confirmation change is changed evidence even when its label is stable.
    evidence_identity="relation:$(pg_review_sha256_text "$desired_relation")"; evidence_state=matching
  else
    desired_relation=""
  fi

  # Read every structurally valid, same-code binding in deterministic marker order. An input is
  # exact-current only if all proof bytes revalidate and its target/evidence relation is exactly
  # the desired invocation relation; marker and charged epoch are intentionally excluded.
  while IFS= read -r marker; do
    candidate="$(pg_review_input_binding_read "$marker" 2>/dev/null || true)"
    [ -n "$candidate" ] || continue
    jq -e --arg h "$host" --arg o "$owner" --arg r "$repo_name" --argjson p "$pr_num" --arg head "$head" \
      '.repository.host==$h and .repository.owner==$o and .repository.repo==$r and .target.pr==$p and .target.head_oid==$head' \
      <<<"$candidate" >/dev/null 2>&1 || continue
    candidate_relation="$(jq -cS '{repository,target,evidence}' <<<"$candidate")"
    exact=false
    if [ -n "$desired_relation" ] && [ "$candidate_relation" = "$desired_relation" ] \
       && pg_review_decision_input_proof_current "$candidate" "$repo" "$pr_num" "$host" "$owner" "$repo_name" "$head" "$base"; then
      exact=true
      exact_inputs="$(jq -cS --arg marker "$marker" --argjson binding "$candidate" '. + [{binding:$binding,marker:$marker}]' <<<"$exact_inputs")"
    fi

    # Classify this exact marker's own captured bytes before result-binding validation. completed/
    # is preferred; pending/ is the durable fallback and remains uncollected-only. This must happen
    # per binding rather than only for the newest exact marker, or marker ordering can hide recovery.
    artifact=""
    if [ "$exact" = true ]; then
      if [ -f "$(pg_completed_dir)/$marker" ] && [ ! -L "$(pg_completed_dir)/$marker" ] && pg_is_review "$(pg_completed_dir)/$marker"; then
        artifact="$(pg_completed_dir)/$marker"
      elif [ -f "$PRO_GATE_HOME/pending/$marker" ] && [ ! -L "$PRO_GATE_HOME/pending/$marker" ] && pg_is_review "$PRO_GATE_HOME/pending/$marker"; then
        artifact="$PRO_GATE_HOME/pending/$marker"
      fi
    fi

    # A result is credible only when its own marker-bound input digest and canonical completed
    # artifact bytes validate. Missing bindings expose exact bytes as collect/recover-only facts.
    result="$(pg_review_result_binding_read "$marker" 2>/dev/null || true)"
    if [ -z "$result" ]; then
      if [ "$exact" = true ] && [ -n "$artifact" ]; then
        artifact_digest="$(pg_sha256 "$artifact" 2>/dev/null || true)"
        [ -n "$artifact_digest" ] && completed="$(jq -cS --arg marker "$marker" --arg artifact "$artifact_digest" --argjson epoch "$(jq -r .charged_spend_epoch <<<"$candidate")" \
          '. + [{applicable:true,artifact_digest:$artifact,binding_valid:false,canonical_identity:$marker,charged_spend_epoch:$epoch,collected:false,legacy:false,marker:$marker,provenance_valid:false,verdict:"NONE"}]' <<<"$completed")"
      fi
      continue
    fi
    artifact="$(pg_completed_dir)/$marker"
    [ -f "$artifact" ] && [ ! -L "$artifact" ] && pg_is_review "$artifact" || continue
    artifact_digest="$(pg_sha256 "$artifact" 2>/dev/null || true)"
    [ -n "$artifact_digest" ] || continue
    input_digest="$(pg_review_sha256_text "$candidate")"
    jq -e --arg ib "$input_digest" --arg digest "$artifact_digest" \
      '.input_binding_digest==$ib and .artifact.digest==$digest' <<<"$result" >/dev/null 2>&1 || continue
    canonical="$(pg_review_result_binding_digest "$marker" 2>/dev/null || true)"
    [ -n "$canonical" ] || continue

    if [ "$exact" = true ]; then
      if [ "$(jq -r .verdict <<<"$result")" = SHIP ]; then
        mode="$(jq -r .evidence.mode <<<"$candidate")"
        case "$mode" in
          full-pr)
            [ -n "$base" ] && [ -n "$raw_digest" ] || continue
            ship_digest="$raw_digest" ;;
          scoped-delta)
            # The binding recheck above proved endpoint, reviewed payload, manifest, confirmation,
            # base, and head. Handoff additionally binds the result to that full raw endpoint.
            ship_digest="$(jq -r .evidence.proof.raw_digest <<<"$candidate")" ;;
          connector)
            # Connector observations never become merge handoff authority.
            continue ;;
          *) continue ;;
        esac
        jq -e --arg base "$base" --arg head "$head" --arg digest "$ship_digest" \
          '.ship_proof.base_oid==$base and .ship_proof.head_oid==$head and .ship_proof.diff_digest==$digest' \
          <<<"$result" >/dev/null 2>&1 || continue
      fi
      completed="$(jq -cS --arg marker "$marker" --arg canonical "$canonical" --arg artifact "$artifact_digest" \
        --argjson epoch "$(jq -r .charged_spend_epoch <<<"$candidate")" --arg verdict "$(jq -r .verdict <<<"$result")" \
        '. + [{applicable:true,artifact_digest:$artifact,binding_valid:true,canonical_identity:$canonical,charged_spend_epoch:$epoch,collected:true,legacy:false,marker:$marker,provenance_valid:true,verdict:$verdict}]' <<<"$completed")"
      if [ "$(jq -r .verdict <<<"$result")" = NEEDS-DISCUSSION ]; then
        choice_outcomes="$(pg_review_decision_named_choices "$artifact" 2>/dev/null || true)"
        [ -n "$choice_outcomes" ] || choice_outcomes='[]'
        choice_candidates="$(jq -cS --arg canonical "$canonical" --argjson outcomes "$choice_outcomes" \
          '. + [{canonical_identity:$canonical,outcomes:$outcomes}]' <<<"$choice_candidates")"
      fi
    else
      prior_candidates="$(jq -cS --arg marker "$marker" --arg canonical "$canonical" --arg code "$code_identity" \
        --arg evidence "relation:$(pg_review_sha256_text "$candidate_relation")" --argjson epoch "$(jq -r .charged_spend_epoch <<<"$candidate")" \
        --arg verdict "$(jq -r .verdict <<<"$result")" \
        '. + [{canonical_identity:$canonical,charged_spend_epoch:$epoch,code_identity:$code,evidence_identity:$evidence,marker:$marker,verdict:$verdict}]' <<<"$prior_candidates")"
    fi
  done < <(find "$(pg_review_input_binding_dir)" -mindepth 1 -maxdepth 1 -type f -name 'pg-run-*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort)

  # A persisted exact relation is preferred over its equivalent prospective template. Pick it
  # deterministically so recover/repair effects never depend on directory enumeration order.
  if [ "$(jq 'length' <<<"$exact_inputs")" -gt 0 ]; then
    input_marker="$(jq -r 'sort_by(.binding.charged_spend_epoch,.marker) | last.marker' <<<"$exact_inputs")"
    input_record="$(jq -cS 'sort_by(.binding.charged_spend_epoch,.marker) | last.binding' <<<"$exact_inputs")"
  fi
  [ -z "$input_record" ] || input_digest="$(pg_review_sha256_text "$input_record")"
  current_canonical="$(jq -r 'sort_by(.charged_spend_epoch,.canonical_identity) | last.canonical_identity // ""' <<<"$completed")"
  current_verdict="$(jq -r 'sort_by(.charged_spend_epoch,.canonical_identity) | last.verdict // "NONE"' <<<"$completed")"
  if [ "$current_verdict" = NEEDS-DISCUSSION ]; then
    choice_outcomes="$(jq -cS --arg canonical "$current_canonical" '[.[] | select(.canonical_identity==$canonical)] | last.outcomes // []' <<<"$choice_candidates")"
  else
    choice_outcomes='[]'
  fi
  # A supplied selection may only enter facts after the exact current NEEDS-DISCUSSION result
  # and its immutable artifact have supplied bounded outcomes. Unknown or malformed selections
  # deliberately empty the outcomes so the reducer emits its existing closed invalid-choice stop.
  if [ -n "$REVIEW_CHOICE_SELECTION_FILE" ]; then
    selection_supplied=true
    selection="$(pg_review_decision_choice_selection_read "$REVIEW_CHOICE_SELECTION_FILE" 2>/dev/null || true)"
    if [ "$current_verdict" = NEEDS-DISCUSSION ] && [ -n "$selection" ] \
       && [ "$(jq 'length' <<<"$choice_outcomes")" -ge 2 ] \
       && jq -e --arg id "$(jq -r .selected_id <<<"$selection")" 'any(.[]; .id==$id)' <<<"$choice_outcomes" >/dev/null 2>&1; then
      choice_selected="$(jq -r .selected_id <<<"$selection")"
      choice_snapshot="$(jq -r .snapshot_digest <<<"$selection")"
    elif [ "$current_verdict" = NEEDS-DISCUSSION ]; then
      choice_outcomes='[]'
    fi
  fi
  # A selection is meaningful only for the exact current NEEDS-DISCUSSION artifact. If that
  # artifact ceased to be current (head/evidence moved), keep reduction inside its closed stop
  # branch rather than letting the unrelated fresh-review grant treat selection as a new spend.
  if [ "$selection_supplied" = true ] && [ "$current_verdict" != NEEDS-DISCUSSION ]; then
    evidence_state=invalid
  fi
  prior_review="$(jq -cS '
    sort_by(.charged_spend_epoch,.canonical_identity) | last //
    {code_identity:"",evidence_identity:"",marker:"",verdict:"NONE"} |
    {applicable:false,binding_valid:(.marker != ""),code_identity,evidence_identity,legacy:false,marker,provenance_valid:(.marker != ""),verdict}' <<<"$prior_candidates")"

  # Lifecycle ownership comes from one canonical snapshot. Querying stale mutable state remains
  # conservative (recover); reconciliation stays an effect and cannot happen in this read-only path.
  attempt_snapshot="$(pg_attempt_snapshot "$host" "$owner" "$repo_name" "$pr_num" "$round_key" 2>/dev/null || true)"
  [ -n "$attempt_snapshot" ] || { echo 'ERROR: review-decision could not assemble attempt lifecycle' >&2; return 2; }
  attempt_source="$(jq -r .source <<<"$attempt_snapshot")"
  active_marker="$(jq -r '.marker // ""' <<<"$attempt_snapshot")"
  active_state="$(jq -r '.state // "none"' <<<"$attempt_snapshot")"
  if [ "$attempt_source" = artifact ]; then
    active_marker=""; active_state=none
  elif [ "$attempt_source" = disposition ]; then
    if [ "$(jq -r .fresh_eligible <<<"$attempt_snapshot")" = true ]; then active_marker=""; active_state=none; else active_state=unknown-fate; fi
  fi
  reservation_marker=""; reservation_state=none
  if [ "$attempt_source" = reservation ]; then
    if [ "$active_state" = superseded ]; then
      active_marker=""; active_state=none
    else
      reservation_marker="$active_marker"; reservation_state=live
      active_marker=""; active_state=none
    fi
  fi
  if pg_round_guard "$round_key" >/dev/null 2>&1; then governor_granted=true; fi

  facts="$(jq -cnS --arg h "$host" --arg o "$owner" --arg r "$repo_name" --arg head "$head" --argjson pr "$pr_num" \
    --arg identity "$input_identity" --arg evidence "$evidence_identity" --arg state "$evidence_state" \
    --arg marker "$active_marker" --arg astate "$active_state" --arg reservation "$reservation_marker" --arg rstate "$reservation_state" \
    --argjson input_proven "$input_proven" --argjson input_binding "$input_binding_valid" --argjson granted "$governor_granted" \
    --argjson completed "$completed" --argjson prior "$prior_review" --argjson choices "$choice_outcomes" --arg choice "$choice_selected" --arg choice_snap "$choice_snapshot" --arg cd "$(pg_review_decision_contract_digest)" --arg xd "$(pg_review_decision_corpus_digest)" '
    {active_index:{binding_valid:$input_binding,charged_spend_epoch:0,marker:$marker,state:$astate},completed_results:$completed,
     contract:{contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd},
     evidence:{identity:$evidence,safe_to_prepare:true,state:$state},governor:{granted:$granted},
     input:{binding_valid:$input_binding,identity:$identity,proven:$input_proven},named_choice:{outcomes:$choices,selected_id:(if $choice=="" then null else $choice end),snapshot_digest:$choice_snap},
     observation:{kind:"idle"},prior_review:$prior,
     reservation:{binding_valid:false,legacy:false,marker:$reservation,state:$rstate},target:{head_oid:$head,host:$h,owner:$o,pr:$pr,repo:$r},transport:"review-decision/v1"}')" || return 2
  decision="$(pg_review_decision_reduce "$facts")" || { echo 'ERROR: review-decision reduction failed' >&2; return 2; }

  # An effect request is an immutable comparison target, never an authorization token. Re-reading
  # it is bounded and control-safe; a mismatch simply returns this freshly reduced replacement.
  if [ -n "$REVIEW_DECISION_EFFECT_FILE" ]; then
    [ -f "$REVIEW_DECISION_EFFECT_FILE" ] && [ ! -L "$REVIEW_DECISION_EFFECT_FILE" ] \
      && [ "$(wc -c < "$REVIEW_DECISION_EFFECT_FILE" 2>/dev/null | tr -d ' ')" -le 65536 ] \
      && jq -e --argjson fresh "$decision" '
        .contract == $fresh.contract and .effect_request.action == .action and
        .effect_request.snapshot_digest == $fresh.effect_request.snapshot_digest and
        .effect_request.target == $fresh.effect_request.target and
        .effect_request.applicable_ref == $fresh.effect_request.applicable_ref' "$REVIEW_DECISION_EFFECT_FILE" >/dev/null 2>&1 \
      && effect_ok=true
    # Effects acquire their own marker protection only after a byte-for-byte request match and
    # fresh reduction. A mismatch falls through to the replacement decision with no mutation.
    if [ "$effect_ok" = true ] && [ "$(jq -r .action <<<"$decision")" = recover-existing-review ]; then
      effect_marker="$(jq -r '.effect_request.applicable_ref // ""' <<<"$decision")"
      if [ -n "$(pg_attempt_disposition_read "$effect_marker" 2>/dev/null || true)" ]; then
        if ! pg_lock "${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}.pr-${round_key}" "${PRO_GATE_RECOVER_LOCK_WAIT:-30}"; then
          echo 'ERROR: terminal attempt cleanup is busy; retry recovery.' >&2; return 7
        fi
        pg_attempt_reconcile_terminal "$effect_marker" \
          || { echo 'ERROR: terminal attempt cleanup failed closed; inspect --status.' >&2; return 3; }
        REVIEW_DECISION_EFFECT_FILE=""
        pg_review_decision_cli
        return
      fi
    elif [ "$effect_ok" = true ] && [ "$(jq -r .action <<<"$decision")" = collect-existing-result ]; then
      effect_marker="$(jq -r '.effect_request.applicable_ref // ""' <<<"$decision")"
      effect_input="$(pg_review_input_binding_read "$effect_marker" 2>/dev/null || true)"
      if [ -n "$effect_input" ] \
         && [ "$(jq -cS '{repository,target,evidence}' <<<"$effect_input" 2>/dev/null || true)" = "$desired_relation" ] \
         && pg_review_decision_input_proof_current "$effect_input" "$repo" "$pr_num" "$host" "$owner" "$repo_name" "$head" "$base"; then
        pg_review_decision_repair_result_binding "$effect_marker" "$effect_input" || true
      fi
    elif [ "$effect_ok" = true ] && [ "$(jq -r .action <<<"$decision")" = run-granted-review ]; then
      # The advisory request matched a freshly reduced grant. It still carries no authority:
      # the normal engine re-reduces at its pre-lock, under-lock, and pre-charge boundaries.
      # Retain only the validated immutable input relation to clone onto this attempt's marker.
      REVIEW_DECISION_EXECUTE=1
      REVIEW_DECISION_INPUT_TEMPLATE="$input_record"
      REVIEW_DECISION_INPUT_TEMPLATE_MARKER="$input_marker"
      REVIEW_DECISION_INPUT_TEMPLATE_DIGEST="$input_digest"
      return 0
    fi
  fi
  printf '%s\n' "$decision"
}

if [ "$REVIEW_DECISION_REQUESTED" = 1 ]; then
  if [ "$HARVEST_REQUESTED" = 1 ] || [ "$RECOVER_REQUESTED" = 1 ] || [ "$STATUS_REQUESTED" = 1 ] || { [ -n "$REVIEW_DECISION_EFFECT_FILE" ] && [ -n "$EXTRA_GLOB" ]; } || { [ -z "$REVIEW_DECISION_EFFECT_FILE" ] && [ -n "$OUT$EXTRA_GLOB" ]; }; then
    echo 'ERROR: review-decision accepts only --pr, --repo, --diff, --input, --confirm, --out for run effects, and --review-decision-effect' >&2
    exit 2
  fi
  REVIEW_DECISION_EXECUTE=0
  pg_review_decision_cli
  REVIEW_DECISION_RC=$?
  if [ "$REVIEW_DECISION_RC" -ne 0 ] || [ "$REVIEW_DECISION_EXECUTE" != 1 ]; then exit "$REVIEW_DECISION_RC"; fi
  # A matching run-granted effect now enters the existing fresh-dispatch path. Plain queries and
  # every other effect retain their strictly read-only/repair-only behavior above.
  REVIEW_DECISION_REQUESTED=0
fi

# --- v0.35: --recover — resolve exactly one already-spent marker, never dispatch ---
# This deliberately precedes status, organizer housekeeping, WORK creation, browser preflight,
# output locks, status writes, repository/diff assembly, round accounting, and Oracle validation.
# It is not a friendlier spelling of a fresh review: after selection it either returns the immutable
# artifact or delegates ONLY to the pre-existing marker-addressed --harvest path.
if [ "$RECOVER_REQUESTED" = 1 ]; then
  if [ -z "$RECOVER_QUERY" ] || [ -n "$PR$DIFF_FILE$EXTRA_GLOB$CONFIRM_FILE$HARVEST_MARKER$STATUS_QUERY" ] \
     || [ "$HARVEST_REQUESTED" = 1 ] || [ "$STATUS_REQUESTED" = 1 ] || [ "$AS_JSON" = 1 ]; then
    echo "ERROR: --recover <PR|URL|marker> accepts only --repo, --out, and --timeout modifiers" >&2
    exit 2
  fi

  recover_disambiguate() { # reason [markers...]
    local why="$1"; shift
    echo "Disambiguation required: $why. Specify an exact pg-run-... marker." >&2
    [ $# -eq 0 ] || printf 'Candidates: %s\n' "$*" >&2
    exit 2
  }
  recover_marker_key() { local m="$1" k; k="${m#pg-run-}"; printf '%s\n' "${k%-*-*}"; }
  recover_superseded_reason() { # marker -> proof-backed reason when PR closed/merged or head moved
    local marker="$1" binding meta host owner repo pr bound_head binding_epoch mh mo mr mkey mpr mout mspend rkey rspend gh_bin timeout_bin payload state current_head
    # The immutable binding and canonical charged run metadata must identify the same exact attempt.
    # A valid-but-crossed sidecar must never let another repository/PR release this marker.
    binding="$(pg_review_input_binding_read "$marker" 2>/dev/null || true)"; [ -n "$binding" ] || return 1
    meta="$(pg_run_meta_read "$marker" 2>/dev/null || true)"; [ -n "$meta" ] || return 1
    IFS=$'\t' read -r mh mo mr mkey mpr mout mspend <<<"$meta"
    host="$(jq -r .repository.host <<<"$binding")"; owner="$(jq -r .repository.owner <<<"$binding")"
    repo="$(jq -r .repository.repo <<<"$binding")"; pr="$(jq -r .target.pr <<<"$binding")"
    bound_head="$(jq -r .target.head_oid <<<"$binding")"; binding_epoch="$(jq -r .charged_spend_epoch <<<"$binding")"
    pg_canonical_repo_ok "$host" "$owner" "$repo" || return 1
    case "$pr" in ''|*[!0-9]*) return 1;; esac
    case "$bound_head" in ''|*[!0-9a-f]*) return 1;; esac
    { [ "${#bound_head}" -eq 40 ] || [ "${#bound_head}" -eq 64 ]; } || return 1
    [ "$host" = "$mh" ] && [ "$owner" = "$mo" ] && [ "$repo" = "$mr" ] \
      && [ "$pr" = "$mpr" ] && [ "$binding_epoch" = "$mspend" ] || return 1
    rkey="$(awk -F'\t' 'NR==1{print $1}' "$(pg_reservation_dir)/$marker" 2>/dev/null)"
    rspend="$(awk -F'\t' 'NR==1{print $7}' "$(pg_reservation_dir)/$marker" 2>/dev/null)"
    [ "$rkey" = "$mkey" ] && [ "$rspend" = "$mspend" ] || return 1
    gh_bin="${PRO_GATE_GH_BIN:-gh}"; command -v "$gh_bin" >/dev/null 2>&1 || return 1
    timeout_bin="${PRO_GATE_TIMEOUT_BIN:-timeout}"
    command -v "$timeout_bin" >/dev/null 2>&1 || return 1
    payload="$("$timeout_bin" -k 1s 10s "$gh_bin" pr view "$pr" --repo "$host/$owner/$repo" --json state,headRefOid 2>/dev/null || true)"
    state="$(jq -r '.state // ""' <<<"$payload" 2>/dev/null)"
    current_head="$(jq -r '.headRefOid // ""' <<<"$payload" 2>/dev/null)"
    case "$state" in
      MERGED|CLOSED) printf 'pr-%s\n' "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"; return 0;;
      OPEN) ;;
      *) return 1;;
    esac
    case "$current_head" in ''|*[!0-9a-f]*) return 1;; esac
    { [ "${#current_head}" -eq 40 ] || [ "${#current_head}" -eq 64 ]; } || return 1
    [ "$current_head" = "$bound_head" ] && return 1
    printf 'head-moved:%s:%s\n' "$bound_head" "$current_head"
  }
  REC_SELECTED=""; REC_SELECTED_OUT=""; REC_QUERY_NUM=""; REC_HOST=""; REC_OWNER=""; REC_REPO_NAME=""
  case "$RECOVER_QUERY" in
    pg-run-*)
      pg_reservation_marker_ok "$RECOVER_QUERY" || { echo "ERROR: invalid recovery marker syntax" >&2; exit 2; }
      REC_SELECTED="$RECOVER_QUERY";;
    http*://*/pull/*)
      # pg_repo_identity_from_url's own regex already accepts one trailing slash (it is the
      # canonical spelling GitHub itself sometimes renders), but the number extraction below
      # takes everything after the FINAL slash — a trailing slash left that empty and forced a
      # spurious disambiguation even though the URL was otherwise canonical. Normalize once.
      REC_URL_NORM="${RECOVER_QUERY%/}"
      REC_QUERY_NUM="${REC_URL_NORM##*/}"; REC_QUERY_NUM="${REC_QUERY_NUM%%[!0-9]*}"
      REC_IDENT="$(pg_repo_identity_from_url "$REC_URL_NORM" 2>/dev/null || true)"
      { [ -n "$REC_QUERY_NUM" ] && [ -n "$REC_IDENT" ]; } \
        || recover_disambiguate "the PR URL is not a canonical host/owner/repo pull URL"
      IFS=$'\t' read -r REC_HOST REC_OWNER REC_REPO_NAME <<< "$REC_IDENT";;
    *[!0-9]*) echo "ERROR: --recover takes a PR number, a PR URL, or a pg-run-... marker" >&2; exit 2;;
    *)
      REC_QUERY_NUM="$RECOVER_QUERY"
      # A bare number needs a proved current repository. Never fall back to the checkout basename:
      # it is neither canonical nor unique and reopens the historical lossy-slug cross-bind.
      REC_REPO_DIR="${REPO:-$(pwd)}"
      REC_REMOTE="$(git -C "$REC_REPO_DIR" remote get-url origin 2>/dev/null || true)"
      REC_IDENT="$(pg_repo_identity_from_url "$REC_REMOTE" 2>/dev/null || true)"
      [ -n "$REC_IDENT" ] || recover_disambiguate "bare PR #$REC_QUERY_NUM has no canonical repository proof"
      IFS=$'\t' read -r REC_HOST REC_OWNER REC_REPO_NAME <<< "$REC_IDENT";;
  esac
  if [ -z "$REC_SELECTED" ]; then
    REC_QUERY_NUM="$(pg_pr_number_normalize "$REC_QUERY_NUM")" \
      || recover_disambiguate "PR target is not a canonical positive number"
  fi

  if [ -z "$REC_SELECTED" ]; then
    REC_SEEN=""; REC_NEW_COUNT=0; REC_LEGACY=""; REC_CONFLICT=""; REC_BEST_EPOCH=""; REC_BEST_MARKER=""; REC_BEST_OUT=""; REC_TIED=0
    # The run-meta scan is the canonical candidate source. It retains exact identity and the
    # pg_round_record charge after a completed artifact retires its reservation.
    while IFS=$'\t' read -r m h o r key pr mout spend; do
      [ "$pr" = "$REC_QUERY_NUM" ] && [ "$h" = "$REC_HOST" ] && [ "$o" = "$REC_OWNER" ] && [ "$r" = "$REC_REPO_NAME" ] || continue
      REC_SEEN="$REC_SEEN $m"; REC_NEW_COUNT=$(( REC_NEW_COUNT + 1 ))
      r_spend="$(pg_reservation_read_spend "$m" 2>/dev/null || true)"
      case "$r_spend" in ''|*[!0-9]*) ;; *) [ "$r_spend" = "$spend" ] || REC_CONFLICT="$REC_CONFLICT $m";; esac
      case "$spend" in ''|*[!0-9]*) REC_CONFLICT="$REC_CONFLICT $m"; continue;; esac
      if [ -z "$REC_BEST_EPOCH" ] || [ "$spend" -gt "$REC_BEST_EPOCH" ]; then
        REC_BEST_EPOCH="$spend"; REC_BEST_MARKER="$m"; REC_BEST_OUT="$mout"; REC_TIED=0
      elif [ "$spend" = "$REC_BEST_EPOCH" ]; then
        REC_TIED=1
      fi
    done < <(pg_run_meta_scan)
    # A terminal disposition intentionally retires run-meta. Include it as the same canonical
    # candidate class so PR/URL recovery can explain terminal truth without requiring its marker.
    while IFS= read -r disposition; do
      [ -n "$disposition" ] || continue
      h="$(jq -r .repository.host <<<"$disposition")"; o="$(jq -r .repository.owner <<<"$disposition")"
      r="$(jq -r .repository.repo <<<"$disposition")"; pr="$(jq -r .target.pr <<<"$disposition")"
      [ "$pr" = "$REC_QUERY_NUM" ] && [ "$h" = "$REC_HOST" ] && [ "$o" = "$REC_OWNER" ] && [ "$r" = "$REC_REPO_NAME" ] || continue
      m="$(jq -r .marker <<<"$disposition")"; spend="$(jq -r .charged_spend_epoch <<<"$disposition")"
      case " $REC_SEEN " in *" $m "*) continue;; esac
      REC_SEEN="$REC_SEEN $m"; REC_NEW_COUNT=$(( REC_NEW_COUNT + 1 ))
      if [ -z "$REC_BEST_EPOCH" ] || [ "$spend" -gt "$REC_BEST_EPOCH" ]; then
        REC_BEST_EPOCH="$spend"; REC_BEST_MARKER="$m"; REC_BEST_OUT=""; REC_TIED=0
      elif [ "$spend" = "$REC_BEST_EPOCH" ]; then
        REC_TIED=1
      fi
    done < <(pg_attempt_disposition_scan)

    # gate #91 round3 P1 (:165): the charge site's run-meta write is best-effort — its failure
    # only WARNs, because a failed sidecar write must never block a real review from running —
    # so a NEWER run can be live right now with no run-meta row at all, while an OLDER completed
    # sidecar for this same change still exists above. Left unchecked, the scan above would
    # silently return that older, WRONG artifact while the real answer is still generating.
    # active/<key> is written unconditionally at charge time (pg_active_write, before the
    # metadata write), so cross-check it here using the IDENTICAL liveness rule --status already
    # applies to active records (pid alive, then a process-identity token match when the record
    # carries one) rather than inventing a second rule that could disagree with --status's own
    # verdict. active/ is keyed by the lossy ROUND_KEY slug (owner-repo-PR#, no host) — a slug
    # COLLISION here can only ever cause an OVER-refusal (ask for an exact marker instead of
    # guessing), never a wrong review, which is the correct direction to fail.
    REC_ROUND_KEY="$(printf '%s-%s-%s' "$REC_OWNER" "$REC_REPO_NAME" "$REC_QUERY_NUM" | tr -c 'A-Za-z0-9.\n-' '-')"
    REC_ACTIVE_F="$PRO_GATE_HOME/active/$REC_ROUND_KEY"
    if [ -f "$REC_ACTIVE_F" ]; then
      IFS=$'\t' read -r REC_A_MARKER REC_A_OUT REC_A_PID REC_A_EPOCH REC_A_MODE REC_A_TOKEN < "$REC_ACTIVE_F" 2>/dev/null || true
      REC_A_ALIVE=0
      case "$REC_A_PID" in ''|*[!0-9]*) ;; *) kill -0 "$REC_A_PID" 2>/dev/null && REC_A_ALIVE=1;; esac
      if [ "$REC_A_ALIVE" = 1 ] && [ -n "$REC_A_TOKEN" ]; then
        [ "$(pg_pid_token "$REC_A_PID" 2>/dev/null || true)" = "$REC_A_TOKEN" ] || REC_A_ALIVE=0
      fi
      if [ "$REC_A_ALIVE" = 1 ] && [ -n "$REC_A_MARKER" ]; then
        case " $REC_SEEN " in
          *" $REC_A_MARKER "*) ;;  # already a run-meta candidate — no new information, no refusal
          *) recover_disambiguate "a newer run for this change is LIVE right now and has not yet recorded its metadata ($REC_A_MARKER)" "$REC_A_MARKER";;
        esac
      fi
    fi

    # Legacy markers remain visible candidates so an old lossy round key cannot be silently
    # bypassed. They never provide canonical identity proof; a mixed set therefore disambiguates.
    for f in "$PRO_GATE_HOME/in-progress"/pg-run-* "$(pg_completed_dir)"/pg-run-* "$PRO_GATE_HOME/pending"/pg-run-*; do
      [ -f "$f" ] || continue
      m="$(basename "$f")"; pg_reservation_marker_ok "$m" || continue
      case " $REC_SEEN " in *" $m "*) continue;; esac
      key="$(recover_marker_key "$m")"
      case "$key" in *"-$REC_QUERY_NUM") REC_LEGACY="$REC_LEGACY $m";; esac
    done
    [ -z "$REC_LEGACY" ] || recover_disambiguate "legacy candidate(s) lack canonical repository proof" "$REC_LEGACY"
    [ -z "$REC_CONFLICT" ] || recover_disambiguate "candidate charge evidence conflicts or is incomplete" "$REC_CONFLICT"
    [ "$REC_NEW_COUNT" -gt 0 ] || recover_disambiguate "no canonically identified run matches this PR"
    [ "$REC_TIED" = 0 ] || recover_disambiguate "newest charged-spend epoch is tied"
    REC_SELECTED="$REC_BEST_MARKER"; REC_SELECTED_OUT="$REC_BEST_OUT"
  fi

  # Artifact-first is intentionally smaller than --harvest's historical fast path: no work dir,
  # preflight, status/ledger/active records, reservation retirement, organizer, or lock. stdout is
  # exclusively review bytes; the novice state remains a single plain stderr line.
  #
  # gate #91 P1 (:169): pg_persist_result's own durability ladder falls through to pending/<marker>
  # BYTES whenever the completed store is unwritable (and retires the reservation there, same as a
  # completed write) — pending/ is verified review content, not a lesser record. Checking only
  # pg_completed_dir() meant a review durable ONLY under pending/ was invisible here: recovery fell
  # through to a fresh harvest that could report failure after the tab was gone, even though the
  # only bytes that ever needed collecting were already sitting on disk. Pending is checked as a
  # fallback (completed still wins when both somehow exist) and is READ-ONLY here — no promotion
  # into completed/, no removal: --recover stays side-effect free, exactly like the completed path.
  REC_ART="$(pg_completed_dir)/$REC_SELECTED"
  REC_PENDING_ART="$PRO_GATE_HOME/pending/$REC_SELECTED"
  REC_SRC=""
  if [ -s "$REC_ART" ] && [ ! -L "$REC_ART" ] && pg_is_review "$REC_ART"; then
    REC_SRC="$REC_ART"
  elif [ -s "$REC_PENDING_ART" ] && [ ! -L "$REC_PENDING_ART" ] && pg_is_review "$REC_PENDING_ART"; then
    REC_SRC="$REC_PENDING_ART"
  fi
  if [ -n "$REC_SRC" ]; then
    if [ -n "$OUT" ]; then
      # pg_completed_lookup only knows the completed store's own path, so the pending source needs
      # the identical copy-then-rename discipline inline: never pre-delete an existing --out (a
      # copy/rename failure must leave it intact), and skip the copy entirely when --out already
      # IS the source (pg_completed_lookup's own no-op case).
      if [ "$REC_SRC" = "$OUT" ]; then
        :
      else
        # gate #91 round3 P1 (:208): this fast path used to write $OUT with no lock at all —
        # a second recovery, or a fresh/harvest run, racing it could each replace the same file
        # and each report success while the other's bytes vanished. Take the SAME process-lifetime
        # guard the engine's own dispatch takes (pg_out_guard_acquire, defined near the top of the
        # file) before the first byte moves; a recovery that loses the race reports the trouble
        # state instead of a "successful" publish nobody can trust.
        # 2>/dev/null: pg_out_guard_acquire narrates its own "ERROR: another live run..." to
        # stderr, which is right for the engine's dispatch but breaks --recover's promise of
        # EXACTLY ONE plain state line. Every other failure site in this branch calls a silent
        # helper; this one must be silenced explicitly or contention prints two lines.
        pg_out_guard_acquire 2>/dev/null || { echo "Browser needs attention" >&2; exit 6; }
        if [ "$REC_SRC" = "$REC_ART" ]; then
          pg_completed_lookup "$REC_SELECTED" "$OUT" || { echo "Browser needs attention" >&2; exit 6; }
        else
          cp "$REC_SRC" "$OUT.already.$$" 2>/dev/null && mv -f "$OUT.already.$$" "$OUT" 2>/dev/null
          REC_PUB_RC=$?
          rm -f "$OUT.already.$$" 2>/dev/null
          [ "$REC_PUB_RC" = 0 ] || { echo "Browser needs attention" >&2; exit 6; }
        fi
      fi
    fi
    echo "Review ready" >&2
    cat "$REC_SRC"
    exit 0
  fi

  REC_DISPOSITION="$(pg_attempt_disposition_read "$REC_SELECTED" 2>/dev/null || true)"
  if [ -n "$REC_DISPOSITION" ]; then
    REC_TERMINAL_KEY="$(jq -r .round_key <<<"$REC_DISPOSITION")"
    if ! pg_lock "${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}.pr-${REC_TERMINAL_KEY}" "${PRO_GATE_RECOVER_LOCK_WAIT:-30}"; then
      echo "Checking for completed review" >&2; exit 7
    fi
    pg_attempt_reconcile_terminal "$REC_SELECTED" \
      || { echo "Browser needs attention" >&2; exit 3; }
    echo "No review remains" >&2
    exit 6
  fi

  # v0.37.1 upgrade compatibility: pre-disposition releases can leave canonical charged run-meta
  # after their reservation disappeared. Restore only that marker's original recovery ownership;
  # no new round, slot, model, or timestamp is invented. Existing recovery then owns all proof.
  REC_RESTORED=0; REC_RESTORE_STATE=""
  if [ ! -f "$(pg_reservation_dir)/$REC_SELECTED" ] \
     && [ -n "$(pg_run_meta_read "$REC_SELECTED" 2>/dev/null || true)" ]; then
    REC_RESTORE_STATE="$(pg_reservation_restore_from_meta "$REC_SELECTED" 2>/dev/null || true)"
    case "$REC_RESTORE_STATE" in created) REC_RESTORED=1;; existing) :;; *) echo "Browser needs attention" >&2; exit 3;; esac
  fi
  # A closed/merged PR or immutable binding to an older head makes this review obsolete, not
  # unsubmitted. Preserve its charge and all marker-addressed artifacts for optional audit harvest,
  # but release shared capacity before any browser probe. Missing or malformed proof stays fail-closed.
  REC_RES_STATE="$(pg_reservation_state "$REC_SELECTED" 2>/dev/null || true)"
  if [ "$REC_RES_STATE" = superseded ]; then
    echo "Review superseded" >&2
    exit 6
  fi
  REC_SUPERSEDED_PROOF="$(recover_superseded_reason "$REC_SELECTED" 2>/dev/null || true)"
  if [ -n "$REC_SUPERSEDED_PROOF" ]; then
    pg_reservation_set_state "$REC_SELECTED" superseded \
      || { echo "Browser needs attention" >&2; exit 3; }
    REC_SUPERSEDED_EVENT="$(jq -nc --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
      --arg marker "$REC_SELECTED" --arg proof "$REC_SUPERSEDED_PROOF" \
      '{ts:$ts,outcome:"superseded",marker:$marker,proof:$proof,holds_capacity:false,charge_retained:true}' 2>/dev/null || true)"
    pg_ledger_append "$REC_SUPERSEDED_EVENT"
    echo "Review superseded" >&2
    exit 6
  fi

  if [ "$REC_RESTORED" = 1 ] && [ "${PRO_GATE_HARVEST_TTL_SWEEP:-1}" = 1 ] \
     && [ "$(pg_reservation_expire_if_stale "$REC_SELECTED")" = stale ] \
     && command -v node >/dev/null 2>&1; then
    REC_PROBES="${PRO_GATE_RESERVATION_MISSES:-3}"; case "$REC_PROBES" in ''|*[!0-9]*) REC_PROBES=3;; esac
    [ "$REC_PROBES" -ge 2 ] 2>/dev/null || REC_PROBES=2
    REC_PROBE_INTERVAL="${PRO_GATE_RECONCILE_INTERVAL:-60}"; case "$REC_PROBE_INTERVAL" in ''|*[!0-9]*) REC_PROBE_INTERVAL=60;; esac
    REC_PROBE_N=0
    [ "$REC_PROBE_INTERVAL" -eq 0 ] || sleep "$REC_PROBE_INTERVAL"
    while [ "$REC_PROBE_N" -lt "$REC_PROBES" ]; do
      REC_PROBE_N=$(( REC_PROBE_N + 1 )); REC_PROBE_RC=2
      node "$SELF/cdp-salvage.mjs" --probe "$REC_SELECTED" 10 "${ORACLE_BROWSER_PORT:-9222}" >/dev/null 2>/dev/null; REC_PROBE_RC=$?
      case "$REC_PROBE_RC" in
        0) break ;;
        4)
          REC_MISS="$(pg_reservation_note_miss "$REC_SELECTED")"
          if [ "$REC_MISS" = released ]; then echo "No review remains" >&2; exit 6; fi
          [ "$REC_PROBE_N" -ge "$REC_PROBES" ] || [ "$REC_PROBE_INTERVAL" -eq 0 ] || sleep "$REC_PROBE_INTERVAL"
          ;;
        *) break ;;
      esac
    done
  fi

  # Exact-marker input does not pass through the candidate scan, so recover its publication path
  # from marker-addressed metadata or the live reservation before choosing a safe local default.
  if [ -z "$REC_SELECTED_OUT" ]; then
    REC_META="$(pg_run_meta_read "$REC_SELECTED" 2>/dev/null || true)"
    if [ -n "$REC_META" ]; then
      IFS=$'\t' read -r _rh _ro _rr _rk _rp REC_SELECTED_OUT _rs <<< "$REC_META"
    elif [ -f "$(pg_reservation_dir)/$REC_SELECTED" ]; then
      REC_SELECTED_OUT="$(awk -F'\t' 'NR==1{print $2}' "$(pg_reservation_dir)/$REC_SELECTED" 2>/dev/null)"
    fi
  fi
  if [ -z "$OUT" ]; then
    # gate #91 P1 (:192): a fresh run persists $OUT verbatim (see the charge-time write below), and
    # a caller's relative --out is resolved against $REPO there, not against wherever --recover
    # happens to run from (it never `cd`s anywhere). Reusing a recorded relative path here would
    # therefore publish into whatever sits under THIS invocation's cwd — an unrelated file, not the
    # run's real output. Only trust a recorded OUT that is unambiguous on its own: absolute, with a
    # parent directory that still exists and still accepts writes (the default --out lives inside a
    # per-run mktemp dir, which the engine deletes on exit — a dead parent must fall back exactly
    # like "no metadata at all" instead of failing later at the publish step).
    REC_OUT_PARENT=""
    case "$REC_SELECTED_OUT" in
      /*) REC_OUT_PARENT="$(dirname "$REC_SELECTED_OUT")";;
    esac
    if [ -n "$REC_SELECTED_OUT" ] && [ -n "$REC_OUT_PARENT" ] \
       && [ -d "$REC_OUT_PARENT" ] && [ -w "$REC_OUT_PARENT" ]; then
      OUT="$REC_SELECTED_OUT"
    else
      mkdir -p "$PRO_GATE_HOME/recovered" 2>/dev/null \
        || { echo "Browser needs attention" >&2; exit 3; }
      OUT="$PRO_GATE_HOME/recovered/$REC_SELECTED.md"
    fi
  fi
  # gate #91 P2 (:199): --harvest is an operational tool, not the novice contract this mode
  # promises — its stdout/stderr carry CDP probe noise, marker echoes, and (on success) a leading
  # "RESULT_FILE=" line meant for scripted callers. Left to inherit the parent's streams, all of
  # that leaked in front of (or instead of) the single plain state line documented above. Capture
  # both streams and reconstruct the clean contract from what the child itself verified and printed
  # (gate #91 P1 (:271): never from re-reading $OUT — see below) instead of relaying whatever the
  # child happened to print. The raw streams stay reachable behind PRO_GATE_RECOVER_VERBOSE=1 for
  # debugging a stuck recovery.
  if [ "${PRO_GATE_RECOVER_VERBOSE:-0}" = 1 ]; then
    bash "$0" --harvest "$REC_SELECTED" --out "$OUT" --timeout "$TIMEOUT"
    REC_HARVEST_RC=$?
    case "$REC_HARVEST_RC" in
      0) echo "Review ready" >&2;;
      8|7) echo "Checking for completed review" >&2;;
      9) echo "Still working" >&2;;
      *) echo "Browser needs attention" >&2;;
    esac
    exit "$REC_HARVEST_RC"
  fi
  REC_HV_OUT="$(mktemp "${TMPDIR:-/tmp}/pg-recover-hv.XXXXXX" 2>/dev/null)" \
    || { echo "Browser needs attention" >&2; exit 3; }
  REC_HV_ERR="$(mktemp "${TMPDIR:-/tmp}/pg-recover-hv.XXXXXX" 2>/dev/null)" \
    || { rm -f "$REC_HV_OUT"; echo "Browser needs attention" >&2; exit 3; }
  REC_HV_BODY=""
  bash "$0" --harvest "$REC_SELECTED" --out "$OUT" --timeout "$TIMEOUT" \
    >"$REC_HV_OUT" 2>"$REC_HV_ERR"
  REC_HARVEST_RC=$?
  case "$REC_HARVEST_RC" in
    0)
      # gate #91 P1 (:271): the child publishes $OUT under its own process-lifetime output lock
      # and then EXITS, releasing it. In the window between that exit and this read, another run
      # reusing the same --out path can replace or truncate the file — trusting $OUT here can
      # print a DIFFERENT run's review while this still announces "Review ready". The child's
      # captured stdout (this process's own private temp file) is immune to that race: prefer the
      # "RESULT_FILE=<path>" locator it prints, naming the write-once, marker-addressed completed
      # artifact — re-reading that path is safe precisely because nothing can overwrite a
      # write-once artifact. Validate it before trusting it (a stale or foreign path is not proof
      # of anything). Fall back to the review bytes the child printed directly (same captured,
      # race-free stdout, minus the locator line) when no locator is present or it doesn't check
      # out. gate #91 round3 P1 (:304): there is deliberately NO third rung that re-reads $OUT.
      # An earlier version fell back to $OUT once the locator AND the captured body both failed
      # to validate — but by then the child has already released its output guard, and $OUT is
      # exactly the mutable, unlocked path a concurrent run (or a second recovery) can have
      # already overwritten with a DIFFERENT, unrelated review. Reading it here would announce
      # "Review ready" and hand back a foreign review that happens to pass pg_is_review. Failing
      # closed on the two race-free sources is correct even though it costs recoverability in the
      # rare case both legitimately fail.
      REC_BODY=""
      REC_LOCATOR="$(sed -n 's/^RESULT_FILE=//p' "$REC_HV_OUT" 2>/dev/null | head -1)"
      if [ -n "$REC_LOCATOR" ] && pg_is_review "$REC_LOCATOR" 2>/dev/null; then
        REC_BODY="$REC_LOCATOR"
      else
        REC_HV_BODY="$(mktemp "${TMPDIR:-/tmp}/pg-recover-hvbody.XXXXXX" 2>/dev/null)"
        if [ -n "$REC_HV_BODY" ]; then
          grep -v '^RESULT_FILE=' "$REC_HV_OUT" > "$REC_HV_BODY" 2>/dev/null
          pg_is_review "$REC_HV_BODY" 2>/dev/null && REC_BODY="$REC_HV_BODY"
        fi
      fi
      # Neither race-free source yielded a valid review: report trouble, not success — a
      # published file we cannot actually verify and read back race-free is a worse lie than
      # "Browser needs attention", and $OUT itself is not trustworthy evidence (see above).
      if [ -z "$REC_BODY" ] || ! cat "$REC_BODY" 2>/dev/null; then
        rm -f "$REC_HV_OUT" "$REC_HV_ERR" "$REC_HV_BODY" 2>/dev/null
        echo "Browser needs attention" >&2
        exit 6
      fi
      echo "Review ready" >&2
      ;;
    8|7) echo "Checking for completed review" >&2;;
    9) echo "Still working" >&2;;
    *) echo "Browser needs attention" >&2;;
  esac
  rm -f "$REC_HV_OUT" "$REC_HV_ERR" "$REC_HV_BODY" 2>/dev/null
  exit "$REC_HARVEST_RC"
fi

# --- v0.27: --status — read-only run rediscovery (issue #47) ---
# Joins the state the engine already keeps (in-progress/ reservations, rounds/<key> budget,
# conversation-urls/ memos, ledger.jsonl) so a caller with NOTHING but a PR number can answer:
# what runs exist for this change, what state are they in, where is the output, what marker do
# I harvest, and how many budget rounds remain. Pure inspection — no locks, no status file, no
# browser, no writes — safe any time, including while a run is live. Exit 0 even when nothing
# is found (absence is an answer); 2 on usage errors.
if [ "$STATUS_REQUESTED" = 1 ]; then
  if [ "$AS_JSON" = 1 ] && ! pg_have jq; then
    echo "ERROR: --status --json requires jq" >&2; exit 2
  fi
  ST_RES_DIR="$(pg_reservation_dir)"
  ST_ROUNDS_DIR="$(pg_rounds_dir)"
  ST_LEDGER="${PRO_GATE_LEDGER:-$PRO_GATE_HOME/ledger.jsonl}"
  ST_URLS_DIR="$PRO_GATE_HOME/conversation-urls"
  ST_ENGINE="$PRO_GATE_HOME/oracle-review.sh"
  # v0.31: the cap is per-key (governor grant varies with each key's trajectory). ST_CAP_DESC
  # is the human-readable header; per-key grants come from pg_round_grant in the loop below.
  if [ -n "${PRO_GATE_MAX_ROUNDS_PER_PR:-}" ]; then
    ST_CAP_DESC="flat cap ${PRO_GATE_MAX_ROUNDS_PER_PR}"
  else
    ST_CAP_DESC="adaptive (base ${PRO_GATE_ROUNDS_BASE:-3}, +1 per shrinking re-review, ceiling ${PRO_GATE_ROUNDS_CEILING:-8})"
  fi
  ST_WIN="$(pg_round_window_secs)"
  ST_NOW="$(date +%s)"
  ST_LOCKFILE="${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}"
  ST_INFLIGHT_KEY=""; ST_SPENT_KEY=""; ST_SPENT_N=0; ST_ACTIVE_HINT=""
  ST_ATTEMPT_JSON=null; ST_ATTEMPT_EPOCH=0; ST_ATTEMPT_HINT=""

  # Non-blocking in-flight probe (same technique as round_capped's): a held per-change lock
  # means a same-change review is RUNNING right now — the one state with no reservation and no
  # ledger row yet, where "no state found" would wrongly invite a duplicate launch. Read-only:
  # probe only locks that already exist (opening would otherwise create the file).
  st_inflight() {  # $1 = round key -> rc 0 when a same-change run holds the lock now
    local lf="${ST_LOCKFILE}.pr-$1" pfd opid otok
    if [ -d "${lf}.d" ]; then
      # mkdir-fallback lock (no flock, e.g. stock macOS): live only when the recorded owner
      # is a running pid. A dead/absent owner is a stale dir from SIGKILL/reboot — pg_lock
      # self-heals it at the next acquisition; report it NOT live, mutate nothing
      # (gate #53 r3 P1: existence alone reported stale locks as RUNNING forever).
      opid="$(cat "${lf}.d/pid" 2>/dev/null || true)"
      case "$opid" in ''|*[!0-9]*) return 1;; esac
      kill -0 "$opid" 2>/dev/null || return 1
      # Token-verify when the lock recorded one: a recycled pid must not report a long-dead
      # holder as RUNNING (gate #61 r2 P1). Token-less locks (legacy) keep the pid-only check.
      otok="$(cat "${lf}.d/token" 2>/dev/null || true)"
      [ -z "$otok" ] || [ "$(pg_pid_token "$opid" 2>/dev/null || true)" = "$otok" ] || return 1
      return 0
    fi
    [ -e "$lf" ] || return 1
    pg_have flock || return 1
    if { exec {pfd}>>"$lf"; } 2>/dev/null; then
      if flock -n "$pfd" 2>/dev/null; then eval "exec ${pfd}>&-" 2>/dev/null; return 1; fi
      eval "exec ${pfd}>&-" 2>/dev/null; return 0
    fi
    return 1
  }

  # Normalize the query: marker, PR URL (repo-scoped slug + number), bare number, or all.
  Q_NUM=""; Q_SLUG=""; Q_MARKER=""
  case "$STATUS_QUERY" in
    '') ;;
    pg-run-*)
      pg_reservation_marker_ok "$STATUS_QUERY" \
        || { echo "ERROR: invalid marker syntax: $STATUS_QUERY" >&2; exit 2; }
      Q_MARKER="$STATUS_QUERY";;
    http*://*/pull/*)
      Q_NUM="${STATUS_QUERY##*/}"; Q_NUM="${Q_NUM%%[!0-9]*}"
      Q_SLUG="$(printf '%s' "$STATUS_QUERY" \
        | sed -nE 's#https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\1-\2#p' | tr -c 'A-Za-z0-9.\n-' '-')"
      [ -n "$Q_NUM" ] || { echo "ERROR: could not parse a PR number from: $STATUS_QUERY" >&2; exit 2; };;
    *[!0-9]*)
      echo "ERROR: --status takes a PR number, a PR URL, or a pg-run-... marker (omit for all)" >&2
      exit 2;;
    *) Q_NUM="$STATUS_QUERY";;
  esac

  # A reservation matches on: exact marker; or the COMPLETE key embedded in the marker
  # (strip the pg-run- prefix and the trailing -epoch-pid). Round keys are not prefix-free
  # (acme-widgets-42-tools-7 contains acme-widgets-42-), so slugged queries compare the whole
  # key for equality and bare-number queries require the key's FINAL segment — substring
  # matches leak foreign changes, and reservations outrank every other status source
  # (gate #53 r3 P1). A bare number still shows every repo's match by design (keys are
  # repo-scoped precisely so numbers can collide; the marker display disambiguates).
  st_match() {  # $1 marker, $2 recorded pr field ('' when unknown)
    local m="$1" pr="${2:-}" km
    [ -n "$Q_MARKER" ] && { [ "$m" = "$Q_MARKER" ]; return; }
    [ -n "$Q_NUM" ] || return 0
    km="${m#pg-run-}"; km="${km%-*-*}"
    if [ -n "$Q_SLUG" ]; then
      [ "$km" = "${Q_SLUG}-${Q_NUM}" ]; return
    fi
    [ "$pr" = "$Q_NUM" ] && return 0
    case "$km" in *"-${Q_NUM}") return 0;; esac
    return 1
  }

  ST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pg-status.XXXXXX")"
  trap 'rm -rf "$ST_TMP"' EXIT
  : > "$ST_TMP/res.jsonl"; : > "$ST_TMP/rounds.jsonl"; : > "$ST_TMP/ledger.jsonl"
  ST_HINT=""
  # v0.30 (#52 item 1): machine-consumable recoverability. recoverable=true means "a paid
  # review is live or still collectable WITHOUT a new spend — do not treat this change's
  # failure as terminal". Computed ONLY from freshness-checked state (unexpired reservation,
  # live per-change lock/pid, fresh dead-wrapper on a harvest-capable mode), never from hint
  # prose, so automation (the daemon's fail-budget guard) cannot rot when wording changes.
  # Static-but-collectable states (failed run with a URL memo, in-progress ledger history)
  # deliberately do NOT set it: retrying those is charged work, bounded by the caller's own
  # fail budget, not an open-ended deferral.
  ST_RECOVERABLE=0; ST_RECOVER_REASON=""
  ST_RES_TTL="${PRO_GATE_RESERVATION_TTL:-21600}"
  case "$ST_RES_TTL" in ''|*[!0-9]*) ST_RES_TTL=21600;; esac

  # 1) Reservations: in-progress runs whose review is collectable for FREE.
  if [ -d "$ST_RES_DIR" ]; then
    for f in "$ST_RES_DIR"/pg-run-*; do
      [ -f "$f" ] || continue
      m="$(basename "$f")"
      r_pr=""; r_out=""; r_created=""; r_miss=""; r_slot=""; r_model=""
      IFS=$'\t' read -r r_pr r_out r_created r_miss r_slot r_model < "$f" 2>/dev/null || true
      st_match "$m" "$r_pr" || continue
      case "$r_created" in ''|*[!0-9]*) r_age="";; *) r_age=$(( ST_NOW - r_created ));; esac
      r_life="$(pg_reservation_state "$m" 2>/dev/null || echo generating)"
      # Only an UNEXPIRED, applicable reservation marks the change recoverable. Superseded review
      # state remains optionally collectable but cannot block current-head admission or capacity.
      # reaped at the next fresh-run reconciliation, and treating it as live would let a
      # repeatedly-failing caller defer forever (gate #61 r1 P1).
      if { [ -z "$r_age" ] || [ "$r_age" -lt "$ST_RES_TTL" ] 2>/dev/null; } && [ "$r_life" != superseded ]; then
        ST_RECOVERABLE=1
        [ -n "$ST_RECOVER_REASON" ] || ST_RECOVER_REASON="unexpired in-progress reservation ($m)"
      fi
      r_url=""; [ -f "$ST_URLS_DIR/$m" ] && r_url="$(head -c 300 "$ST_URLS_DIR/$m" 2>/dev/null | tr -d '\n')"
      [ -n "$r_out" ] || r_out="${TMPDIR:-/tmp}/pro-gate-${r_pr:-review}.md"
      r_cmd="$ST_ENGINE --harvest '$m' --out '$r_out' --timeout 20m"
      # #67/#68: distinguish three states, not two. A set-aside <out>.unbound.* capture alone
      # is AMBIGUOUS — strict nonce mode deliberately produces one when an older completed
      # answer is visible while OUR answer may still be generating, and that case IS
      # retryable. Only a positively convicted cross-bind (cdp-salvage saw another run's
      # completed answer BELOW our prompt and recorded it in crossbound/<marker>) is
      # terminally stuck. Reporting every .unbound as STUCK would tell the operator to remove
      # a possibly-live reservation (#68 gate P2).
      r_unbound=0
      for _ub in "$r_out".unbound.*; do [ -e "$_ub" ] && r_unbound=$(( r_unbound + 1 )); done
      r_crossbound=0
      [ -s "$PRO_GATE_HOME/crossbound/$m" ] && r_crossbound="$(grep -c . "$PRO_GATE_HOME/crossbound/$m" 2>/dev/null || echo 1)"
      # v0.33+ lifecycle state distinguishes capacity ownership from optional collectability.
      if [ "$r_life" = superseded ]; then
        [ -n "$ST_HINT" ] || ST_HINT="superseded old-head review holds no capacity and cannot authorize the current PR; optional audit harvest: $r_cmd"
      elif [ "$r_crossbound" -gt 0 ] 2>/dev/null; then
        ST_HINT="STUCK (cross-bound): the conversation remembered for $m carries ANOTHER run's completed answer — see $PRO_GATE_HOME/crossbound/$m. Do NOT delete state or set PRO_GATE_REQUIRE_NONCE=0. The bad memo is discarded; bounded exact-marker misses will terminalize recovery while retaining the charged round."
      elif [ "$r_unbound" -gt 0 ]; then
        ST_HINT="AMBIGUOUS: ${r_unbound} harvested capture(s) for $m completed but carried no run-marker echo (see ${r_out}.unbound.*). This is retryable — it may be an older answer while yours still generates. Retry the FREE harvest: $r_cmd"
      else
        [ -n "$ST_HINT" ] || ST_HINT="in-progress reservation found — collect it for FREE: $r_cmd"
      fi
      if pg_have jq; then
        jq -nc --arg marker "$m" --arg pr "${r_pr:-}" --arg out "$r_out" \
          --arg age "${r_age:-}" --arg miss "${r_miss:-}" --arg model "${r_model:-}" \
          --arg url "$r_url" --arg harvest_cmd "$r_cmd" --argjson unbound "$r_unbound" \
          --argjson crossbound "$r_crossbound" --arg life "$r_life" \
          '{marker:$marker,pr:$pr,out:$out,age_secs:(($age|tonumber?)//null),miss_streak:(($miss|tonumber?)//null),model:$model,conversation_url:$url,harvest_cmd:$harvest_cmd,unbound_captures:$unbound,crossbound_hits:$crossbound,holds_capacity:($life != "complete" and $life != "superseded"),state:(if $life == "superseded" then "superseded-awaiting-optional-harvest" elif $crossbound > 0 then "cross-bound" elif $unbound > 0 then "unbindable-ambiguous" elif $life == "complete" then "complete-awaiting-harvest" else "generating-or-recoverable" end)}' \
          >> "$ST_TMP/res.jsonl" 2>/dev/null
      else
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$m" "${r_pr:-?}" "${r_age:-?}" "${r_miss:-?}" "$r_unbound" "$r_crossbound" "$r_cmd" >> "$ST_TMP/res.tsv"
      fi
    done
  fi

  # 1b) Completed artifacts + pending-recovery records: collected reviews that need no
  # browser and no spend. Collected WITHOUT setting the hint here (gate #54 r10): live-run
  # signals must outrank an artifact, and among artifacts the NEWEST round wins (markers
  # embed their creation epoch) — the oldest marker sorting first must not steer automation
  # at a stale review.
  : > "$ST_TMP/artifacts.jsonl"
  ST_ARTIFACT_HINT=""; ST_ART_EPOCH=0
  # pending scanned FIRST so a completed artifact wins equal-epoch ties (>= keeps the last
  # seen); temp suffixes and non-review content never drive a hint (gate #54 r11 P2).
  for f in "$PRO_GATE_HOME/pending"/pg-run-* "$(pg_completed_dir)"/pg-run-*; do
    [ -f "$f" ] || continue
    m="$(basename "$f")"
    # Skip only OUR generated temp names — "<marker>.tmp.<pid>" (all-numeric tail after the
    # LAST .tmp.). Marker syntax permits dots, so a blanket *.tmp.* filter would hide a
    # legitimate marker like ...foo.tmp.api-... (gate #54 r12 P2).
    OG_TAIL="${m##*.tmp.}"
    if [ "$OG_TAIL" != "$m" ]; then case "$OG_TAIL" in ''|*[!0-9]*) ;; *) continue;; esac; fi
    st_match "$m" "" || continue
    pg_is_review "$f" || continue
    a_kind=completed; case "$f" in */pending/*) a_kind=pending;; esac
    a_epoch="${m%-*}"; a_epoch="${a_epoch##*-}"; case "$a_epoch" in ''|*[!0-9]*) a_epoch=0;; esac
    if [ "$a_epoch" -ge "$ST_ART_EPOCH" ]; then
      ST_ART_EPOCH="$a_epoch"
      if [ "$a_kind" = completed ]; then
        ST_ARTIFACT_HINT="a collected review already EXISTS for this change (newest: $f) — return it with $ST_ENGINE --harvest '$m' --out <file> (no browser, nothing spent)"
      else
        ST_ARTIFACT_HINT="a captured review awaits MANUAL recovery: the record $f names its snapshot path and digest — copy it out by hand; do NOT respend"
      fi
    fi
    if pg_have jq; then
      jq -nc --arg marker "$m" --arg artifact "$f" --arg kind "$a_kind" \
        '{marker:$marker,artifact:$artifact,kind:$kind}' >> "$ST_TMP/artifacts.jsonl" 2>/dev/null
    else
      printf '%s\t%s\t%s\n' "$m" "$f" "$a_kind" >> "$ST_TMP/artifacts.tsv"
    fi
  done

  # 2) Round budget + live-run probes, per change key. The key set is the UNION of rounds/*,
  # active/*, held per-change lock files, and the query-derived key — not rounds/* alone: a
  # first-ever run holds the per-change lock (and, once committed, an active record) while it
  # waits for an account slot, BEFORE any rounds file exists; enumerating only rounds/ would
  # report "no state" for that whole wait and invite a duplicate wrapper (gate #53 r2 P1).
  ST_KEYS=""
  st_add_key() { pg_round_key_ok "$1" || return 0; case " $ST_KEYS " in *" $1 "*) ;; *) ST_KEYS="$ST_KEYS $1";; esac; }
  if [ -d "$ST_ROUNDS_DIR" ]; then
    for f in "$ST_ROUNDS_DIR"/*; do
      [ -f "$f" ] || continue
      case "$f" in *.last) continue;; esac
      st_add_key "$(basename "$f")"
    done
  fi
  if [ -d "$PRO_GATE_HOME/active" ]; then
    for f in "$PRO_GATE_HOME/active"/*; do [ -f "$f" ] && st_add_key "$(basename "$f")"; done
  fi
  for f in "${ST_LOCKFILE}.pr-"*; do
    [ -e "$f" ] || continue
    k="${f#"${ST_LOCKFILE}".pr-}"; k="${k%.d}"; st_add_key "$k"
  done
  # Same marker-addressed durable source used by --recover. This only contributes a key to
  # status's existing state join; it neither parses rendered status output nor changes its schema.
  while IFS=$'\t' read -r _sm _sh _so _sr _sk _sp _sout _sspend; do
    st_add_key "$_sk"
  done < <(pg_run_meta_scan)
  [ -n "$Q_SLUG" ] && [ -n "$Q_NUM" ] && st_add_key "${Q_SLUG}-${Q_NUM}"
  for k in $ST_KEYS; do
    if [ -n "$Q_MARKER" ]; then
      km="${Q_MARKER#pg-run-}"; km="${km%-*-*}"   # same best-effort strip the harvest path uses
      [ "$k" = "$km" ] || continue
    elif [ -n "$Q_NUM" ]; then
      case "$k" in "${Q_SLUG:+${Q_SLUG}-}${Q_NUM}"|*"-${Q_NUM}") [ -z "$Q_SLUG" ] || [ "$k" = "${Q_SLUG}-${Q_NUM}" ] || continue;; *) continue;; esac
    fi
    spent="$(pg_round_count "$k")"
    k_live=0
    if st_inflight "$k"; then
      k_live=1; ST_INFLIGHT_KEY="$k"
      ST_RECOVERABLE=1
      [ -n "$ST_RECOVER_REASON" ] || ST_RECOVER_REASON="a same-change run holds the per-change lock ($k)"
    fi
    # Active-run index: sees a live run before any reservation/ledger row exists, AND the
    # wrapper-died-mid-generation case (which releases the flock, so st_inflight misses it).
    a_marker=""; a_out=""; a_pid=""; a_epoch=""; a_mode=""; a_token=""; a_alive=""; a_fresh=0
    if [ -f "$PRO_GATE_HOME/active/$k" ]; then
      IFS=$'\t' read -r a_marker a_out a_pid a_epoch a_mode a_token < "$PRO_GATE_HOME/active/$k" 2>/dev/null || true
      # Liveness = pid alive AND, when the record carries a process-identity token, the token
      # still matches — a recycled pid must not resurrect a dead run (gate #61 r2 P1). Legacy
      # token-less records keep the pid-only check but never extend past the freshness bound.
      case "$a_pid" in ''|*[!0-9]*) a_alive=0;; *) if kill -0 "$a_pid" 2>/dev/null; then a_alive=1; else a_alive=0; fi;; esac
      if [ "$a_alive" = 1 ] && [ -n "$a_token" ]; then
        [ "$(pg_pid_token "$a_pid" 2>/dev/null || true)" = "$a_token" ] || a_alive=0
      fi
      case "$a_epoch" in
        ''|*[!0-9]*) : ;;
        *) [ $(( ST_NOW - a_epoch )) -lt "$ST_RES_TTL" ] && [ "$a_epoch" -le "$ST_NOW" ] && a_fresh=1 ;;
      esac
      if [ "$a_alive" = 1 ]; then
        k_live=1; ST_INFLIGHT_KEY="$k"
        if [ "$a_fresh" = 1 ] || [ -n "$a_token" ]; then
          ST_RECOVERABLE=1
          [ -n "$ST_RECOVER_REASON" ] || ST_RECOVER_REASON="a same-change run is live (pid ${a_pid})"
        fi
        [ -n "$ST_ACTIVE_HINT" ] || ST_ACTIVE_HINT="a same-change review is RUNNING right now (pid ${a_pid}): poll ${a_out}.status — do NOT launch another"
      elif [ "$a_mode" = native ]; then
        # Native has no marker-addressable harvest (--harvest exits 3 there): pointing at it
        # would be an unusable loop that never clears (gate #53 r2 P1). Manual recovery only.
        [ -n "$ST_ACTIVE_HINT" ] || ST_ACTIVE_HINT="the last run's wrapper DIED (native mode: no marker-addressed harvest path) — check ${a_out} and ${a_out}.status plus the ChatGPT UI. Do not delete state manually; the same typed pro-gate request will remain fail-closed until proof can settle it."
      elif [ -n "$a_marker" ]; then
        # Recoverable only while FRESH: past the reservation TTL the browser is not still
        # generating; the stale record is debris awaiting the 24h sweep (gate #61 r1 P1).
        if [ "$a_fresh" = 1 ]; then
          ST_RECOVERABLE=1
          [ -n "$ST_RECOVER_REASON" ] || ST_RECOVER_REASON="dead wrapper, browser may still be generating ($a_marker)"
        fi
        [ -n "$ST_ACTIVE_HINT" ] || ST_ACTIVE_HINT="the last run's wrapper DIED but the browser may still be generating — recover by marker, never a fresh run: $ST_ENGINE --harvest '$a_marker' --out '${a_out:-${TMPDIR:-/tmp}/pro-gate-recovered.md}' --timeout 20m"
      fi
    fi
    # 'all' queries skip idle debris — but never a key with anything live on it.
    if [ -z "$Q_NUM$Q_MARKER" ] && ! [ "$spent" -gt 0 ] 2>/dev/null && [ "$k_live" != 1 ] && [ -z "$a_marker$a_out" ]; then
      continue
    fi
    # Score IN THIS SHELL (#66 gate P2): a command substitution would return only the number
    # and drop the trajectory globals, leaving --status unable to distinguish ordinary
    # exhaustion from a churn brake — the very signal this release exists to surface.
    pg_round_score "$k"
    k_policy="$(pg_round_policy_mode "$k")"; k_policy_source="$(pg_round_policy_source)"
    k_cap="$PG_ROUND_GRANT"; k_arrow="$PG_ROUND_ARROW"; k_earned="$PG_ROUND_EARNED"
    k_streak="$PG_ROUND_STREAK"; k_braked=0
    # ledger-timing-split R2: total wall clock spent on this change's rounds, alongside spent/cap.
    # elapsed_h is pre-formatted here (never in jq): jq's number formatting collapses "2.0" to
    # "2", so the human-readable string is built once, in shell, with the same pg_hours_1dp
    # round_capped() uses, and carried through as an opaque string field.
    k_elapsed="$PG_ROUND_ELAPSED_SECS"; k_elapsed_h="$(pg_hours_1dp "$k_elapsed")"
    # ledger-timing-split R2: the population the elapsed hours were summed across — distinct
    # from $spent (every charge in the window), so the rendered line can name its own scope
    # rather than implying the hours cover every spent round.
    k_scored="$PG_ROUND_SCORED"
    [ "$PG_ROUND_STREAK" -ge 2 ] && [ -z "${PRO_GATE_MAX_ROUNDS_PER_PR:-}" ] && k_braked=1
    rem=$(( k_cap - spent )); [ "$rem" -lt 0 ] && rem=0
    if [ "$spent" -gt 0 ] 2>/dev/null; then ST_SPENT_KEY="$k"; ST_SPENT_N="$spent"; fi
    if pg_have jq; then
      jq -nc --arg key "$k" --argjson spent "$spent" --argjson cap "$k_cap" \
        --argjson remaining "$rem" --argjson window_secs "$ST_WIN" --argjson in_flight "$k_live" \
        --arg amarker "$a_marker" --arg aout "$a_out" --arg aalive "$a_alive" --arg amode "$a_mode" \
        --arg arrow "$k_arrow" --argjson earned "$k_earned" --argjson streak "$k_streak" \
        --argjson braked "$k_braked" --argjson elapsed_secs "$k_elapsed" --arg elapsed_h "$k_elapsed_h" \
        --argjson scored "$k_scored" --arg policy "$k_policy" --arg policy_source "$k_policy_source" \
        '{key:$key,spent:$spent,cap:$cap,remaining:$remaining,window_secs:$window_secs,policy:$policy,policy_source:$policy_source,enforced:($policy=="enforced" or $policy=="lockdown"),in_flight:($in_flight == 1),trajectory:(if $arrow == "" then null else $arrow end),earned:$earned,streak:$streak,churn_braked:($braked == 1),elapsed_secs:$elapsed_secs,elapsed_h:$elapsed_h,scored:$scored,active:(if $amarker == "" and $aout == "" then null else {marker:$amarker,out:$aout,wrapper_alive:($aalive == "1"),mode:$amode} end)}' \
        >> "$ST_TMP/rounds.jsonl" 2>/dev/null
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$spent" "$k_cap" "$rem" "$k_live" "$k_arrow" "$k_braked" "$k_elapsed" "$k_scored" "$k_policy" "$k_policy_source" >> "$ST_TMP/rounds.tsv"
    fi
  done

  # 2b) Canonical attempt lifecycle. This snapshot owns recoverability and terminal retry truth;
  # ledger history below is diagnostic only and cannot resurrect an in-progress hint after the
  # lifecycle module has settled or exhausted that attempt.
  if pg_have jq && [ -n "$Q_NUM$Q_MARKER" ]; then
    ST_ATTEMPT_SEEN=""
    st_consider_attempt() { # canonical snapshot
      local candidate="$1" candidate_epoch
      [ -n "$candidate" ] && jq -e . <<<"$candidate" >/dev/null 2>&1 || return 0
      candidate_epoch="$(jq -r '.charged_spend_epoch // 0' <<<"$candidate")"
      case "$candidate_epoch" in ''|*[!0-9]*) candidate_epoch=0;; esac
      if [ "$candidate_epoch" -gt "$ST_ATTEMPT_EPOCH" ] || [ "$ST_ATTEMPT_JSON" = null ]; then
        ST_ATTEMPT_JSON="$candidate"; ST_ATTEMPT_EPOCH="$candidate_epoch"
      fi
    }
    while IFS=$'\t' read -r m h o r key pr _out _spend; do
      st_match "$m" "$pr" || continue
      st_target="${h}/${o}/${r}#${pr}"
      case "|$ST_ATTEMPT_SEEN|" in *"|$st_target|"*) continue;; esac
      ST_ATTEMPT_SEEN="${ST_ATTEMPT_SEEN:+${ST_ATTEMPT_SEEN}|}${st_target}"
      st_consider_attempt "$(pg_attempt_snapshot "$h" "$o" "$r" "$pr" "$key" 2>/dev/null || true)"
    done < <(pg_run_meta_scan)
    while IFS= read -r disposition; do
      [ -n "$disposition" ] || continue
      m="$(jq -r .marker <<<"$disposition")"; pr="$(jq -r .target.pr <<<"$disposition")"
      st_match "$m" "$pr" || continue
      h="$(jq -r .repository.host <<<"$disposition")"; o="$(jq -r .repository.owner <<<"$disposition")"
      r="$(jq -r .repository.repo <<<"$disposition")"; key="$(jq -r .round_key <<<"$disposition")"
      st_target="${h}/${o}/${r}#${pr}"
      case "|$ST_ATTEMPT_SEEN|" in *"|$st_target|"*) continue;; esac
      ST_ATTEMPT_SEEN="${ST_ATTEMPT_SEEN:+${ST_ATTEMPT_SEEN}|}${st_target}"
      st_consider_attempt "$(pg_attempt_snapshot "$h" "$o" "$r" "$pr" "$key" 2>/dev/null || true)"
    done < <(pg_attempt_disposition_scan)
    if [ "$ST_ATTEMPT_JSON" != null ]; then
      st_state="$(jq -r .state <<<"$ST_ATTEMPT_JSON")"; st_marker="$(jq -r .marker <<<"$ST_ATTEMPT_JSON")"
      st_source="$(jq -r .source <<<"$ST_ATTEMPT_JSON")"
      if [ "$(jq -r .recoverable <<<"$ST_ATTEMPT_JSON")" = true ]; then
        ST_RECOVERABLE=1; ST_RECOVER_REASON="canonical attempt $st_marker is $st_state"
        ST_ATTEMPT_HINT="canonical attempt is recoverable — inspect without new spend: $ST_ENGINE --recover '$st_marker'"
      elif [ "$st_source" = disposition ]; then
        st_terminal="$(jq -r '.terminal.terminal_kind' <<<"$ST_ATTEMPT_JSON")"
        if [ "$(jq -r .cleanup_pending <<<"$ST_ATTEMPT_JSON")" = true ]; then
          ST_ATTEMPT_HINT="terminal attempt cleanup is pending for $st_marker — re-run the same typed pro-gate request; cleanup finishes before any new charge"
        elif [ "$st_terminal" = not-submitted ]; then
          ST_ATTEMPT_HINT="the prior attempt was proven not submitted and its round was refunded — a fresh typed pro-gate review is eligible"
        else
          ST_ATTEMPT_HINT="the prior attempt ended $st_terminal; its round remains charged but no review is recoverable — a fresh typed pro-gate review is eligible"
        fi
      fi
    fi
  fi

  # 3) Ledger: recent finished runs for the query (newest first). Rows from engines <v0.27
  # carry no marker/round_key fields; treat them as empty rather than skipping the row. A URL
  # query pins the repo slug: PR numbers repeat across repositories, and a newer FOREIGN row
  # must never drive next_step or point at another repo's output (gate #53 P1) — legacy rows
  # with no scoping identity are excluded under a slugged query rather than guessed at. The
  # bare-number query also matches round_key suffixes, which is what harvest rows record.
  if [ -s "$ST_LEDGER" ] && pg_have jq; then
    tail -n 400 "$ST_LEDGER" | jq -c --arg num "$Q_NUM" --arg slug "$Q_SLUG" --arg marker "$Q_MARKER" '
      select(
        if $marker != "" then (.marker // "") == $marker
        elif $num == "" then true
        elif $slug != "" then
          # exact key only: round keys are NOT prefix-free (acme-widgets-42-tools-7 would pass
          # a startswith("…acme-widgets-42-") marker check), and every marker-carrying v0.27
          # row carries round_key too, so the exact match loses nothing (gate #53 r2 P1)
          ((.round_key // "") == ($slug + "-" + $num))
        else
          (.pr == $num) or ((.marker // "") | contains("-" + $num + "-")) or
          ((.round_key // "") | endswith("-" + $num))
        end
      )' 2>/dev/null | tail -n 8 \
      | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' >> "$ST_TMP/ledger.jsonl" || true
  fi

  # Hint priority after reservations: the active-run index (live run OR dead wrapper with the
  # browser possibly still generating), then a held per-change lock, then the newest matching
  # ledger row — never "no state" while any of those say otherwise.
  [ -n "$ST_HINT" ] || ST_HINT="$ST_ACTIVE_HINT"
  if [ -z "$ST_HINT" ] && [ -n "$ST_INFLIGHT_KEY" ]; then
    ST_HINT="a same-change review is RUNNING right now (per-change lock held for ${ST_INFLIGHT_KEY}): do NOT launch another — wait, then run --status again"
  fi
  # Artifacts rank BELOW live-run signals but above ledger history (gate #54 r10).
  [ -n "$ST_HINT" ] || ST_HINT="$ST_ARTIFACT_HINT"
  [ -n "$ST_HINT" ] || ST_HINT="$ST_ATTEMPT_HINT"
  if [ -z "$ST_HINT" ] && [ -s "$ST_TMP/ledger.jsonl" ] && pg_have jq; then
    ST_LAST_OUTCOME="$(head -n1 "$ST_TMP/ledger.jsonl" | jq -r '.outcome // ""')"
    ST_LAST_OUT="$(head -n1 "$ST_TMP/ledger.jsonl" | jq -r '.out // ""')"
    ST_LAST_MARKER="$(head -n1 "$ST_TMP/ledger.jsonl" | jq -r '.marker // ""')"
    case "$ST_LAST_OUTCOME" in
      in-progress)
        if [ -n "$ST_LAST_MARKER" ]; then
          ST_HINT="last run is in-progress — harvest it for FREE: $ST_ENGINE --harvest '$ST_LAST_MARKER' --out '$ST_LAST_OUT' --timeout 20m"
        else
          ST_HINT="last run is in-progress but predates v0.27 (no marker in ledger): read the run's <out>.status for .marker, or re-run the identical --pr command and let the engine redirect"
        fi;;
      clean)
        ST_HINT="last run completed clean — the review is already on disk: $ST_LAST_OUT (spend nothing)";;
      failed)
        # #35: a failed run whose conversation URL was memoized may be complete server-side
        # (Chrome died before collection). Offer the FREE harvest before any fresh spend.
        if [ -n "$ST_LAST_MARKER" ] && [ -f "$ST_URLS_DIR/$ST_LAST_MARKER" ]; then
          ST_FAILED_URL="$(head -c 300 "$ST_URLS_DIR/$ST_LAST_MARKER" 2>/dev/null | tr -d '\n')"
          ST_HINT="last run FAILED but its conversation URL is remembered (${ST_FAILED_URL:-unknown}) — the review may exist server-side; try a FREE harvest before spending: $ST_ENGINE --harvest '$ST_LAST_MARKER' --out '$ST_LAST_OUT' --timeout 20m"
        else
          ST_HINT="last run ended 'failed' with no reservation held — a fresh run will SPEND a slot (round budget permitting)"
        fi;;
      '') ;;
      *)
        ST_HINT="last run ended '$ST_LAST_OUTCOME' with no reservation held — a fresh run will SPEND a slot (round budget permitting)";;
    esac
  fi
  # Fail CLOSED when the ledger exists but cannot be read: without jq a clean row (review
  # already on disk) is invisible here, and a fresh-run recommendation would be a blind spend.
  if [ -z "$ST_HINT" ] && [ -s "$ST_LEDGER" ] && ! pg_have jq; then
    ST_HINT="a ledger exists but jq is unavailable to read it — inspect $ST_LEDGER for this change BEFORE spending anything"
  fi
  if [ -z "$ST_HINT" ] && [ "$ST_SPENT_N" -gt 0 ] 2>/dev/null; then
    ST_HINT="${ST_SPENT_N} round(s) already spent in the window for ${ST_SPENT_KEY} but no reservation, active record, ledger row, or live lock — a run may have just started or died early; a fresh run will SPEND a slot"
  fi
  [ -n "$ST_HINT" ] || ST_HINT="no engine state found for this query — a fresh run will SPEND a slot"

  if [ "$AS_JSON" = 1 ]; then
    jq -n --arg query "${STATUS_QUERY:-all}" --arg home "$PRO_GATE_HOME" --arg hint "$ST_HINT" \
      --arg rec "$ST_RECOVERABLE" --arg rec_reason "$ST_RECOVER_REASON" --argjson attempt "$ST_ATTEMPT_JSON" \
      --slurpfile res <(cat "$ST_TMP/res.jsonl" 2>/dev/null; echo null) \
      --slurpfile rounds <(cat "$ST_TMP/rounds.jsonl" 2>/dev/null; echo null) \
      --slurpfile ledger <(cat "$ST_TMP/ledger.jsonl" 2>/dev/null; echo null) \
      --slurpfile artifacts <(cat "$ST_TMP/artifacts.jsonl" 2>/dev/null; echo null) \
      '{query:$query,home:$home,recoverable:($rec == "1"),recoverable_reason:$rec_reason,attempt:$attempt,reservations:($res[:-1]),completed_artifacts:($artifacts[:-1]),rounds:($rounds[:-1]),recent_runs:($ledger[:-1]),next_step:$hint}'
    exit 0
  fi

  echo "[pro-gate status] query: ${STATUS_QUERY:-all}   home: $PRO_GATE_HOME"
  if [ "$ST_RECOVERABLE" = 1 ]; then
    echo "recoverable: YES — ${ST_RECOVER_REASON} (do not treat this change's failure as terminal; no new spend needed)"
  fi
  if [ -s "$ST_TMP/res.jsonl" ] || [ -s "$ST_TMP/res.tsv" ]; then
    echo "in-progress reservations (harvest these for FREE — never re-run):"
    if pg_have jq && [ -s "$ST_TMP/res.jsonl" ]; then
      jq -r '"  " + .marker + "  pr=" + .pr + (if .age_secs then "  age=\(.age_secs / 60 | floor)m" else "" end) + (if .conversation_url != "" then "  url=remembered" else "" end)
             + (if .holds_capacity then "  [holding a review slot]" else "  [complete — slot already released, collect when convenient]" end)
             + (if .crossbound_hits > 0 then "  [STUCK: cross-bound to another run - retrying cannot bind it]" else (if .unbound_captures > 0 then "  [\(.unbound_captures) unbindable capture(s) - ambiguous, still retryable]" else "" end) end)
             + "\n    harvest: " + .harvest_cmd' "$ST_TMP/res.jsonl"
    else
      awk -F'\t' '{printf "  %s  pr=%s  age=%ss  miss=%s%s\n    harvest: %s\n", $1, $2, $3, $4, ($6 > 0 ? "  [STUCK: cross-bound to another run]" : ($5 > 0 ? "  [" $5 " unbindable capture(s) — ambiguous, retryable]" : "")), $7}' "$ST_TMP/res.tsv" 2>/dev/null
    fi
  else
    echo "in-progress reservations: none"
  fi
  if [ -s "$ST_TMP/artifacts.jsonl" ] || [ -s "$ST_TMP/artifacts.tsv" ]; then
    echo "collected artifacts (return with --harvest, no browser, no spend):"
    if pg_have jq && [ -s "$ST_TMP/artifacts.jsonl" ]; then
      jq -r '"  " + .marker + "  -> " + .artifact' "$ST_TMP/artifacts.jsonl"
    else
      awk -F'\t' '{printf "  %s  -> %s\n", $1, $2}' "$ST_TMP/artifacts.tsv" 2>/dev/null
    fi
  fi
  if [ -s "$ST_TMP/rounds.jsonl" ] || [ -s "$ST_TMP/rounds.tsv" ]; then
    echo "round history (rolling window $(( ST_WIN / 3600 ))h, ${ST_CAP_DESC}):"
    if pg_have jq && [ -s "$ST_TMP/rounds.jsonl" ]; then
      jq -r '"  " + .key + ": \(.spent) spent, policy=" + .policy + " (source " + .policy_source + ")"
             + (if .enforced then ", \(.remaining) enforced remaining" else ", computed grant \(.cap) is advisory" end)
             + "  (\(.spent) rounds; ~" + .elapsed_h + "h recorded across \(.scored) scored round(s))"
             + (if .trajectory then "  (open P0/P1 by round: " + .trajectory + ")" else "" end)
             + (if .churn_braked then "  [CHURN: not converging]" else "" end)
             + (if .in_flight then "  [REVIEW RUNNING NOW]" else "" end)' "$ST_TMP/rounds.jsonl"
    else
      awk -F'\t' '{printf "  %s: %s spent, policy=%s (source %s), computed grant %s  (%s rounds; ~%.1fh recorded across %s scored round(s))%s%s%s\n", $1, $2, $10, $11, $3, $2, ($8+0)/3600, $9, ($6 == "" ? "" : "  (open P0/P1 by round: " $6 ")"), ($7 == 1 ? "  [CHURN: not converging]" : ""), ($5 == 1 ? "  [REVIEW RUNNING NOW]" : "")}' "$ST_TMP/rounds.tsv" 2>/dev/null
    fi
  else
    echo "round history: nothing spent in the current window for this query"
  fi
  if [ -s "$ST_TMP/ledger.jsonl" ]; then
    echo "recent runs (newest first):"
    jq -r '"  " + .ts + "  exit=\(.exit) " + .outcome + "  \(.secs)s  out=" + .out' "$ST_TMP/ledger.jsonl"
  elif ! pg_have jq; then
    echo "recent runs: (jq not installed — read $ST_LEDGER directly)"
  else
    echo "recent runs: none matching"
  fi
  echo "next step: $ST_HINT"
  exit 0
fi

# Organizer locks are marker-unique and held for at most 95s. Sweep crash-left flock files and
# mkdir fallbacks at the first write-capable boundary so artifact recovery and every --harvest path
# self-heal too. --status exits above and remains strictly read-only; fresh locks survive one day.
find "${PRO_GATE_ORGANIZER_LOCK_DIR:-$PRO_GATE_HOME/organizer-locks}" \
  -mindepth 1 -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
find "${PRO_GATE_ORGANIZER_LOCK_DIR:-$PRO_GATE_HOME/organizer-locks}" \
  -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

PORT="${ORACLE_BROWSER_PORT:-9222}"
# v0.28 (gate #54 r10): normalize the binding policy ONCE, fail-closed — "true"/"2"/typos
# satisfied neither the =1 nor the =0 branch and bypassed both enforcement modes.
case "${PRO_GATE_REQUIRE_NONCE:-1}" in 0) REQUIRE_NONCE=0;; *) REQUIRE_NONCE=1;; esac
# v0.32: these controls gate independent UI mutations. Invalid booleans fail safe for only the
# corresponding mutation; legacy PRO_GATE_KEEP_TABS and PRO_GATE_BROWSER_ARCHIVE retain their
# exact historical interpretation below.
CHAT_RENAME_DEFAULT=0
[ "$MODE" = remote-chrome ] && CHAT_RENAME_DEFAULT=1
case "${PRO_GATE_CHAT_RENAME:-$CHAT_RENAME_DEFAULT}" in
  0) CHAT_RENAME=0;;
  1) CHAT_RENAME=1;;
  *) CHAT_RENAME=0
     echo "[oracle-review] WARNING: invalid PRO_GATE_CHAT_RENAME='${PRO_GATE_CHAT_RENAME}'; conversation rename disabled for safety (use 0 or 1)." >&2 ;;
esac
case "${PRO_GATE_CHAT_ARCHIVE:-1}" in
  0) CHAT_ARCHIVE=0;;
  1) CHAT_ARCHIVE=1;;
  *) CHAT_ARCHIVE=0
     echo "[oracle-review] WARNING: invalid PRO_GATE_CHAT_ARCHIVE='${PRO_GATE_CHAT_ARCHIVE}'; conversation archive disabled for safety (use 0 or 1)." >&2 ;;
esac
MODEL="${ORACLE_MODEL:-gpt-5.6}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pro-review.XXXXXX")"
[ -n "$OUT" ] || OUT="$WORK/findings.md"
# gate #91 P1 (:192): a caller-supplied relative --out is resolved against whatever directory
# this process happened to start in (below this line and before the later `cd "$REPO"`), which
# is invisible once the string is written verbatim into run-meta at charge time. --recover runs
# from an unrelated cwd and never `cd`s anywhere, so replaying a recorded relative path there
# would publish into a different, unrelated file instead of this run's real output. Resolve to
# an absolute path HERE, once, before anything else reads or locks $OUT, so every later use
# (the guard lock, the status sidecar, the charge-time run-meta write) already sees the
# unambiguous form. Only the parent directory needs to exist — $OUT itself is written later.
case "$OUT" in
  /*) ;;
  *)
    OUT_PARENT_ABS="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)" \
      || { echo "ERROR: --out parent directory not found: $(dirname "$OUT")" >&2; exit 2; }
    OUT="$OUT_PARENT_ABS/$(basename "$OUT")"
    ;;
esac
# #50: scratch dirs used to leak on every exit path (5,900+ observed on one box). The trap
# persists this run's diagnostics log, then removes WORK — EXCEPT when a failure path
# deliberately retained recovery bytes in it (PG_KEEP_FINAL/PG_PRESERVE_STATE: the retained
# snapshot is the ONLY copy of a paid review), and never touching $OUT/$OUT.status when the
# default --out placed them inside WORK (callers read them after exit).
pg_scratch_cleanup() {
  # Revoke every delayed organizer before preserving or removing WORK. A volatile-only result
  # deliberately keeps WORK, so directory cleanup alone cannot be the revocation mechanism.
  rm -f "$WORK"/early-organizer.*.lease 2>/dev/null || true
  # Drain the run-log tee FIRST: restore the original stderr (closing the tee's pipe) and
  # reap it, so run.log holds every line and nothing later is lost or misordered.
  if [ -n "${PG_RUNLOG_TEE_PID:-}" ]; then
    exec 2>&3 3>&- 2>/dev/null || true
    wait "$PG_RUNLOG_TEE_PID" 2>/dev/null || true
    PG_RUNLOG_TEE_PID=""
  fi
  # Pre-marker failures (browser preflight, bad repo, diff fetch, oversized) are exactly the
  # outage diagnostics worth keeping (gate #61 r1 P2): persist under a provisional identity
  # when the run died before earning a marker. Never clobber (gate #61 r2 P2): harvests reuse
  # the fresh run's marker, and each invocation's diagnostics must survive independently —
  # later invocations land as <marker>.<epoch>.<pid>.log (still swept by the pg-run-* glob).
  if [ "${PRO_GATE_RUN_LOGS:-1}" = 1 ] && [ -s "$WORK/run.log" ]; then
    _logdst="$PRO_GATE_HOME/logs/${RUN_MARKER:-$PG_RUNLOG_ID}.log"
    [ -e "$_logdst" ] && _logdst="$PRO_GATE_HOME/logs/${RUN_MARKER:-$PG_RUNLOG_ID}.$(date +%s).$$.log"
    mkdir -p "$PRO_GATE_HOME/logs" 2>/dev/null \
      && cp "$WORK/run.log" "$_logdst" 2>/dev/null || true
  fi
  [ "${PG_KEEP_FINAL:-0}" = 1 ] && return 0
  [ "${PG_PRESERVE_STATE:-0}" = 1 ] && return 0
  case "$OUT" in
    "$WORK"/*)
      find "$WORK" -mindepth 1 -maxdepth 1 \
        ! -name "$(basename "$OUT")" ! -name "$(basename "$OUT").status" \
        -exec rm -rf {} + 2>/dev/null || true ;;
    *) rm -rf "$WORK" 2>/dev/null || true ;;
  esac
  return 0
}
pg_on_exit pg_scratch_cleanup
# #50 item 8: per-run diagnostics are durable again. Mirror stderr into $WORK/run.log via a
# tee whose output goes to the SAVED original stderr (fd 3); the EXIT trap restores fd 2,
# drains the tee, and persists the log to logs/<marker>.log. PRO_GATE_RUN_LOGS=0 disables.
if [ "${PRO_GATE_RUN_LOGS:-1}" = 1 ]; then
  # Provisional log identity for runs that die before a marker exists; matches the
  # pg-run-*.log sweep pattern so it ages out like every other run log.
  PG_RUNLOG_ID="pg-run-unidentified-$(date +%s)-$$"
  exec 3>&2 2> >(tee -a "$WORK/run.log" >&3)
  PG_RUNLOG_TEE_PID=$!
fi
if [ -d "$OUT" ]; then
  # mv into an existing directory "succeeds" by moving the file INSIDE it, so a directory
  # here would let publication report done while $OUT is still not the promised file
  # (gate #54 r9 P2). Reject up front.
  echo "ERROR: --out must be a file path, not an existing directory: $OUT" >&2
  exit 2
fi
# One live run per --out (gate #54 r11): the status sidecar is keyed by $OUT, so two
# concurrent runs sharing it would overwrite each other's phase/marker and cross-feed their
# pollers even with distinct result artifacts. Held for the process lifetime; best-effort
# where flock or the directory is unavailable. Logic lives in pg_out_guard_acquire (defined
# near the top of the file, ahead of --recover) so --recover's own publications take the
# IDENTICAL guard — see that function's comment for why a second, unguarded publisher is a bug.
if [ "$STATUS_REQUESTED" != 1 ]; then
  pg_out_guard_acquire || exit 2
fi
# Fresh runs need oracle; --harvest only needs node+CDP and checks that prerequisite inside
# its branch below (moving this gate matters when oracle is temporarily unavailable but a spent
# review is waiting in an open conversation).

# --- machine-readable run status (v0.18) ---
# Callers (the /pro-gate skill, the daemon's headless agent) poll "$OUT.status" — a
# single-line JSON updated ATOMICALLY at every phase change — instead of scraping the
# engine's stderr. Phases: preflight, waiting-pr-lock, waiting-slot, launching,
# watchdog-killed, live-detected, salvaging, retry-wait, throttled, cloudflare, oversized,
# round-capped, deferred, done, failed, in-progress.
# Terminal phases: done (read $OUT), failed, deferred (no slot spent: retry later),
# oversized (no slot spent: past the hard ceiling PRO_GATE_DIFF_HARD_MAX; scope the diff — a
# merely large diff instead proceeds and lands in-progress), round-capped (no slot spent: this PR/branch
# already used its review round budget for the window; escalate to a human, do not re-run),
# in-progress (slot SPENT, model still generating: collect later with --harvest <marker>,
# NEVER relaunch).
# v0.20: the JSON carries `marker`, the run's conversation correlation id, so callers can
# harvest an in-progress review without grepping engine logs.
STATUS_FILE="$OUT.status"
pg_status() {  # $1 phase, $2 optional detail — variable fields are JSON-escaped (v0.18.1:
  # $OUT is caller-supplied; a quote/backslash in it would corrupt the polling contract)
  local phase="$1" detail="${2:-}" ts model_label
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  # v0.21: `model` is the run's resolved model rendered through pg_model_label (captured label or
  # role-based fallback, never a hardcoded version); `model_warn` carries the advisory downgrade
  # marker (empty unless the model looked weak/unreadable). Human surfaces read both from here.
  model_label="$(pg_model_label "${RESOLVED_MODEL:-}")"
  if pg_have jq; then
    jq -nc --arg phase "$phase" --argjson attempt "${attempt:-0}" --arg detail "$detail" \
       --arg pr "${PR_NUM:-diff}" --arg out "$OUT" --arg ts "$ts" --arg marker "${RUN_MARKER:-}" \
       --arg model "$model_label" --arg model_warn "${MODEL_WARN:-}" \
       --arg result "${RESULT_PATH:-}" \
       '{phase:$phase,attempt:$attempt,detail:$detail,pr:$pr,out:$out,ts:$ts,marker:$marker,model:$model,model_warn:$model_warn,result:$result}' \
       > "$STATUS_FILE.tmp" 2>/dev/null
  else
    printf '{"phase":"%s","attempt":%d,"detail":"%s","pr":"%s","out":"%s","ts":"%s","marker":"%s","model":"%s","model_warn":"%s","result":"%s"}\n' \
      "$phase" "${attempt:-0}" "$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')" \
      "${PR_NUM:-diff}" "$(printf '%s' "$OUT" | tr -d '"\\' | tr '\n' ' ')" "$ts" \
      "$(printf '%s' "${RUN_MARKER:-}" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "$model_label" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "${MODEL_WARN:-}" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "${RESULT_PATH:-}" | tr -d '"\\' | tr '\n' ' ')" \
      > "$STATUS_FILE.tmp" 2>/dev/null
  fi
  { [ -s "$STATUS_FILE.tmp" ] && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"; } 2>/dev/null || true
}
pg_status preflight

# --- v0.19: run bookkeeping for the ledger + adaptive ramp ---
RUN_START="$(date +%s)"
# ledger-timing-split (R1/R3): stamped once the run acquires its account slot — never at marker
# mint or RUN_START — so pg_finish can split pre-slot lifecycle time from post-slot lifecycle
# time without a budget or history window ever keying off a pre-lock epoch. This marks SLOT
# ACQUISITION, not the start of model generation (browser preflight, diff retrieval/filtering
# and prompt preparation all still lie ahead post-slot). Stays empty on any path that never
# reaches that point (lock-timeout, preflight failure, round-cap): pg_finish then counts the
# run's whole life as pre_slot_secs with post_slot_secs 0.
LAUNCH_EPOCH=""
SALVAGED=0
EFF_CONC=0
PG_RESULT_DURABLE=0
PG_ACCEPTED_URL=""
# v0.21: the model oracle actually resolved for THIS run, plus the selection status. Captured
# (best-effort) from oracle's "Model selection evidence:" line on fresh paths, or read back from
# the reservation record on --harvest; empty until known and whenever the resolved label is
# "(unavailable)". Oracle 0.15.2 emits that line only at completion, so exit-9/harvest runs
# usually leave this empty (dogfood PR #20); every model surface renders it through
# pg_model_label so an unknown model degrades to role-based text, never a hardcoded version.
RESOLVED_MODEL=""
MODEL_STATUS=""   # oracle's status= field (e.g. already-selected); gates the R6 warning
MODEL_WARN=""     # U5: advisory downgrade marker (weak/unconfirmable model); never blocks the run
# v0.27: active-run index — $PRO_GATE_HOME/active/<ROUND_KEY> (marker\tout\tpid\tstarted_epoch),
# written the moment a fresh run commits to spending a slot, cleared by pg_finish. Covers the
# window where a run is live — or its wrapper DIED while the browser kept generating — but
# neither a reservation nor a ledger row exists yet: --status reads this instead of concluding
# "no state" and inviting a duplicate spend (gate #53 P1; a dead wrapper also releases the
# per-change flock, so the lock probe alone cannot see that case).
PG_ACTIVE_WRITTEN=0
pg_active_write() { # [state] [charged epoch]
  local state="${1:-live}" charged_epoch="${2:-0}"
  [ -n "${ROUND_KEY:-}" ] || return 1
  case "$state" in pre-charge|round-recorded|charged|run-meta-written|input-bound|submitted|unknown-fate|live) ;; *) return 1;; esac
  case "$charged_epoch" in ''|*[!0-9]*) return 1;; esac
  mkdir -p "$(pg_active_dir)" 2>/dev/null || return 1
  # Fields 1-6 are the stable active-index layout consumed by status/recovery. The optional
  # state+epoch suffix is additive: U2's charge protocol makes crash phases inspectable without
  # changing run-meta or reservation layouts.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${RUN_MARKER:-}" "$OUT" "$$" "$(date +%s)" "$MODE" \
    "$(pg_pid_token "$$" 2>/dev/null || true)" "$state" "$charged_epoch" \
    > "$(pg_active_dir)/$ROUND_KEY" 2>/dev/null || return 1
  PG_ACTIVE_WRITTEN=1
  return 0
}
pg_active_clear() {  # $1 = exit code
  local f m o p e md
  f="$(pg_active_dir)/${ROUND_KEY:-}"
  { [ -n "${ROUND_KEY:-}" ] && [ -f "$f" ]; } || return 0
  if [ "${HARVEST:-0}" = 1 ]; then
    # A harvest may conclude a DEAD wrapper's run (collected: 0, or confirmed lost: 6) — then
    # its record is stale and goes. But only the record whose MARKER this harvest actually
    # collected/declared lost (legacy empty markers accepted), and only when its wrapper is
    # dead: a live wrapper still owns its record and clears it itself.
    case "$1" in 0|6) ;; *) return 0;; esac
    IFS=$'\t' read -r m o p e md < "$f" 2>/dev/null || true
    [ -z "$m" ] || [ "$m" = "${RUN_MARKER:-}" ] || return 0
    case "$p" in ''|*[!0-9]*) ;; *) kill -0 "$p" 2>/dev/null && return 0;; esac
  else
    # Fresh path: clear ONLY a record THIS process wrote (gate #53 r3 P1). Exits that occur
    # before pg_active_write — diff-fetch failure, round-cap refusal, health deferral — must
    # never erase a dead predecessor's record: it may be the only marker/output pointer that
    # run left, and deleting it lets a later --status authorize a duplicate spend.
    [ "${PG_ACTIVE_WRITTEN:-0}" = 1 ] || return 0
    IFS=$'\t' read -r m o p e md < "$f" 2>/dev/null || true
    [ "$p" = "$$" ] || return 0
  fi
  rm -f "$f" 2>/dev/null || true
}
pg_install_full_pr_input_binding() { # marker; only endpoint-fetched full PRs gain automatic applicability
  local marker="$1" binding
  [ "${PG_FULL_PR_PROVEN:-0}" = 1 ] || return 0  # caller-supplied/scoped/bare patches remain bounded
  [ -n "${RUN_SPEND_EPOCH:-}" ] && [ -n "${PG_META_HOST:-}${PG_META_OWNER:-}${PG_META_REPO:-}" ] || return 1
  binding="$(jq -cnS --arg cd "$(pg_review_decision_contract_digest)" --arg marker "$marker" \
    --arg host "$PG_META_HOST" --arg owner "$PG_META_OWNER" --arg repo "$PG_META_REPO" --argjson pr "$PR_NUM" \
    --arg base "$PG_FULL_PR_BASE" --arg head "$PG_FULL_PR_HEAD" --arg endpoint "$PG_FULL_PR_ENDPOINT_DIGEST" --arg raw "$PG_FULL_PR_RAW_DIGEST" \
    --argjson epoch "$RUN_SPEND_EPOCH" \
    '{charged_spend_epoch:$epoch,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("full-pr:"+$base+":"+$head),mode:"full-pr",proof:{base_oid:$base,endpoint_digest:$endpoint,head_oid:$head,raw_patch_digest:$raw}},marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:$host,owner:$owner,repo:$repo},target:{head_oid:$head,kind:"pull-request",pr:$pr}}')" || return 1
  pg_review_input_binding_write "$marker" "$binding"
}

# A run-granted effect is advisory until this shared snapshot has been rebuilt at the existing
# dispatch boundaries. It deliberately uses the U1 reducer and existing active/reservation/round
# authorities; it neither creates an action token nor a second ledger or lock.
pg_fresh_dispatch_recheck() { # sets PG_FRESH_DECISION/PG_FRESH_ACTION
  local template="$REVIEW_DECISION_INPUT_TEMPLATE" marker="" state=none epoch=0 f rec m astate="" completed='[]' attempt_snapshot attempt_source
  local input_ok=false input_digest evidence identity head base active_marker="" reservation="" granted=false facts
  local template_relation="" candidate="" candidate_relation="" artifact="" artifact_digest=""
  [ -n "$template" ] || return 1
  input_digest="$(pg_review_sha256_text "$template" 2>/dev/null || true)"
  head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
  base="$(git -C "$REPO" merge-base HEAD '@{upstream}' 2>/dev/null || git -C "$REPO" rev-parse HEAD^ 2>/dev/null || true)"
  # Reassemble every evidence byte relation at each dispatch boundary. In particular, scoped
  # raw endpoint, reviewed payload, manifest, and confirmation remain four separate inputs.
  if pg_review_decision_input_proof_current "$template" "$REPO" "$PR_NUM" "$PG_META_HOST" "$PG_META_OWNER" "$PG_META_REPO" "$head" "$base"; then
    input_ok=true
    template_relation="$(jq -cS '{repository,target,evidence}' <<<"$template" 2>/dev/null || true)"
  fi
  identity="${input_digest:-input-unproven}"
  evidence="$(jq -r '.evidence.identity // "evidence:none"' <<<"$template" 2>/dev/null || echo evidence:none)"

  # A saved grant may be superseded only by its exact-current marker-bound relation. Filename
  # affinity alone is never proof: inspect the immutable input sibling, its target, relation
  # (excluding marker/charged epoch), and live evidence before accepting completed or pending
  # bytes. pending/ intentionally yields only an uncollected fact, so it cannot confer SHIP
  # authority and the existing --recover path remains the no-spend recovery route.
  if [ "$input_ok" = true ] && [ -n "$template_relation" ]; then
    while IFS= read -r m; do
      candidate="$(pg_review_input_binding_read "$m" 2>/dev/null || true)"
      [ -n "$candidate" ] || continue
      jq -e --arg h "$PG_META_HOST" --arg o "$PG_META_OWNER" --arg r "$PG_META_REPO" --argjson p "$PR_NUM" --arg head "$head" \
        '.repository.host==$h and .repository.owner==$o and .repository.repo==$r and .target.pr==$p and .target.head_oid==$head' \
        <<<"$candidate" >/dev/null 2>&1 || continue
      candidate_relation="$(jq -cS '{repository,target,evidence}' <<<"$candidate" 2>/dev/null || true)"
      [ "$candidate_relation" = "$template_relation" ] \
        && pg_review_decision_input_proof_current "$candidate" "$REPO" "$PR_NUM" "$PG_META_HOST" "$PG_META_OWNER" "$PG_META_REPO" "$head" "$base" || continue
      artifact="$(pg_completed_dir)/$m"
      if ! { [ -f "$artifact" ] && [ ! -L "$artifact" ] && pg_is_review "$artifact"; }; then
        artifact="$PRO_GATE_HOME/pending/$m"
      fi
      [ -f "$artifact" ] && [ ! -L "$artifact" ] && pg_is_review "$artifact" || continue
      artifact_digest="$(pg_sha256 "$artifact" 2>/dev/null || true)"
      [ -n "$artifact_digest" ] || continue
      completed="$(jq -cS --arg marker "$m" --arg digest "$artifact_digest" --argjson charged "$(jq -r .charged_spend_epoch <<<"$candidate")" \
        '. + [{applicable:true,artifact_digest:$digest,binding_valid:false,canonical_identity:$marker,charged_spend_epoch:$charged,collected:false,legacy:false,marker:$marker,provenance_valid:false,verdict:"NONE"}]' <<<"$completed")"
    done < <(find "$(pg_review_input_binding_dir)" -mindepth 1 -maxdepth 1 -type f -name "pg-run-$ROUND_KEY-*" -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
  fi
  attempt_snapshot="$(pg_attempt_snapshot "$PG_META_HOST" "$PG_META_OWNER" "$PG_META_REPO" "$PR_NUM" "$ROUND_KEY" "${RUN_MARKER:-}" 2>/dev/null || true)"
  [ -n "$attempt_snapshot" ] || return 1
  attempt_source="$(jq -r .source <<<"$attempt_snapshot")"
  active_marker="$(jq -r '.marker // ""' <<<"$attempt_snapshot")"
  astate="$(jq -r '.state // "none"' <<<"$attempt_snapshot")"
  reservation=""
  if [ "$attempt_source" = artifact ]; then
    active_marker=""; astate=none
  elif [ "$attempt_source" = disposition ]; then
    if [ "$(jq -r .fresh_eligible <<<"$attempt_snapshot")" = true ]; then active_marker=""; astate=none; else astate=unknown-fate; fi
  elif [ "$attempt_source" = reservation ]; then
    if [ "$astate" = superseded ]; then active_marker=""; astate=none
    else reservation="$active_marker"; active_marker=""; astate=none; fi
  fi
  pg_round_guard "$ROUND_KEY" >/dev/null 2>&1 && granted=true
  facts="$(jq -cnS --arg h "$PG_META_HOST" --arg o "$PG_META_OWNER" --arg r "$PG_META_REPO" --arg head "$head" --argjson p "$PR_NUM" \
    --arg identity "$identity" --arg evidence "$evidence" --arg marker "$active_marker" --arg astate "${astate:-none}" --arg reservation "$reservation" \
    --argjson valid "$input_ok" --argjson granted "$granted" --argjson completed "$completed" --arg cd "$(pg_review_decision_contract_digest)" --arg xd "$(pg_review_decision_corpus_digest)" \
    '{active_index:{binding_valid:$valid,charged_spend_epoch:0,marker:$marker,state:$astate},completed_results:$completed,contract:{contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd},evidence:{identity:$evidence,safe_to_prepare:true,state:(if $valid then "matching" else "missing" end)},governor:{granted:$granted},input:{binding_valid:$valid,identity:$identity,proven:$valid},named_choice:{outcomes:[],selected_id:null,snapshot_digest:""},observation:{kind:"idle"},prior_review:{applicable:false,binding_valid:false,code_identity:"",evidence_identity:"",legacy:false,marker:"",provenance_valid:false,verdict:"NONE"},reservation:{binding_valid:false,legacy:false,marker:$reservation,state:(if $reservation=="" then "none" else "live" end)},target:{head_oid:$head,host:$h,owner:$o,pr:$p,repo:$r},transport:"review-decision/v1"}')" || return 1
  PG_FRESH_DECISION="$(pg_review_decision_reduce "$facts")" || return 1
  PG_FRESH_ACTION="$(jq -r .action <<<"$PG_FRESH_DECISION")"
  [ "$PG_FRESH_ACTION" = run-granted-review ]
}
pg_fresh_dispatch_require_run() { # boundary label; exits through existing status/finish path
  local boundary="$1" reason
  if pg_fresh_dispatch_recheck; then return 0; fi
  reason="$(jq -r .reason <<<"${PG_FRESH_DECISION:-{}}" 2>/dev/null || echo recheck-failed)"
  echo "[oracle-review] review-decision fresh dispatch superseded at ${boundary}: ${PG_FRESH_ACTION:-stop-without-new-review}/${reason}; no browser submission." >&2
  # A replacement is data, not an authorization token. Emit it before the legacy status/exit so
  # callers can re-enter through the ordinary collect/recover/stop path without inferring action.
  [ -n "${PG_FRESH_DECISION:-}" ] && printf '%s\n' "$PG_FRESH_DECISION"
  case "${PG_FRESH_ACTION:-}" in
    collect-existing-result|recover-existing-review) pg_status in-progress "review-decision superseded at $boundary: $PG_FRESH_ACTION/$reason"; pg_finish 9 ;;
    *) pg_status failed "review-decision superseded at $boundary: ${PG_FRESH_ACTION:-stop-without-new-review}/$reason"; pg_finish 3 ;;
  esac
}
pg_install_effect_input_binding() { # clone the already-current validated relation to this charged marker
  local binding
  [ -n "${RUN_SPEND_EPOCH:-}" ] || return 1
  binding="$(jq -cS --arg marker "$RUN_MARKER" --argjson epoch "$RUN_SPEND_EPOCH" '.marker=$marker | .charged_spend_epoch=$epoch' <<<"$REVIEW_DECISION_INPUT_TEMPLATE")" || return 1
  pg_review_input_binding_write "$RUN_MARKER" "$binding"
}
pg_fresh_dispatch_refund() { # terminalize and refund only the current exact charged attempt
  [ -n "${RUN_SPEND_EPOCH:-}" ] || return 1
  if [ -n "${PR_NUM:-}" ] && [ -n "${PG_META_HOST:-}" ] && [ -n "${PG_META_OWNER:-}" ] && [ -n "${PG_META_REPO:-}" ]; then
    pg_attempt_terminal_transition "$PG_META_HOST" "$PG_META_OWNER" "$PG_META_REPO" "$PR_NUM" \
      "$ROUND_KEY" "$RUN_MARKER" "$RUN_SPEND_EPOCH" not-submitted proven-no-submit || return 1
    PG_ACTIVE_WRITTEN=0
    return 0
  fi
  # Legacy --diff without a canonical PR has no durable target identity for a disposition.
  # Preserve its exact historical refund behavior under the already-held per-change lock.
  pg_round_unrecord "$ROUND_KEY"
  pg_run_meta_remove "$RUN_MARKER"
  rm -f "$(pg_review_input_binding_dir)/$RUN_MARKER" "$(pg_active_dir)/$ROUND_KEY" 2>/dev/null || true
  PG_ACTIVE_WRITTEN=0
}

pg_publish_out() {  # $1 = verified snapshot → atomically publish to $OUT; rc 0 only when
  # $OUT is a readable regular file afterwards (an existing directory or a failed rename is
  # a publication FAILURE, never silently "done" — gate #54 r9).
  local src="$1" rc=1
  if cp "$src" "$OUT.pub.$$" 2>/dev/null && mv -f "$OUT.pub.$$" "$OUT" 2>/dev/null \
     && [ -f "$OUT" ] && [ ! -d "$OUT" ]; then rc=0; fi
  rm -f "$OUT.pub.$$" 2>/dev/null
  return "$rc"
}
pg_persist_result() {  # $1 = verified snapshot — persist the CANONICAL, marker-addressed
  # result and set RESULT_PATH (gate #54 r10/r11). Ladder: completed artifact → pending BYTES
  # (a pointer to a /tmp snapshot dies with reboots and tmp sweeps; the review itself must be
  # durable) → the kept private snapshot (PG_KEEP_FINAL). Shared $OUT is NEVER canonical:
  # two runs sharing it can both "win" a rename, and cross-feeding callers is worse than a
  # non-preferred path.
  local src="$1" input_binding
  PG_RESULT_DURABLE=0
  if pg_completed_write "$RUN_MARKER" "$src" 2>/dev/null \
     && [ -f "$(pg_completed_dir)/$RUN_MARKER" ] && [ -r "$(pg_completed_dir)/$RUN_MARKER" ] \
     && [ -s "$(pg_completed_dir)/$RUN_MARKER" ] && cmp -s "$src" "$(pg_completed_dir)/$RUN_MARKER"; then
    RESULT_PATH="$(pg_completed_dir)/$RUN_MARKER"
    PG_RESULT_DURABLE=1
    # Canonical bytes may exist after a prior crash without their result binding. Repair is
    # marker-locked and idempotent; failure preserves collectable bytes and never exposes SHIP.
    if input_binding="$(pg_review_input_binding_read "$RUN_MARKER" 2>/dev/null)"; then
      pg_review_decision_repair_result_binding "$RUN_MARKER" "$input_binding" || true
    fi
    pg_reservation_remove "$RUN_MARKER" 2>/dev/null || true
    return 0
  fi
  if { mkdir -p "$PRO_GATE_HOME/pending" \
       && cp "$src" "$PRO_GATE_HOME/pending/$RUN_MARKER.tmp.$$" \
       && mv -f "$PRO_GATE_HOME/pending/$RUN_MARKER.tmp.$$" "$PRO_GATE_HOME/pending/$RUN_MARKER" \
       && [ -f "$PRO_GATE_HOME/pending/$RUN_MARKER" ] \
       && [ -r "$PRO_GATE_HOME/pending/$RUN_MARKER" ] \
       && [ -s "$PRO_GATE_HOME/pending/$RUN_MARKER" ] \
       && cmp -s "$src" "$PRO_GATE_HOME/pending/$RUN_MARKER"; } 2>/dev/null; then
    RESULT_PATH="$PRO_GATE_HOME/pending/$RUN_MARKER"
    PG_RESULT_DURABLE=1
    # A durably persisted review retires its reservation (gate #54 r12): the harvest path
    # deliberately kept it when the completed store was unwritable, but with the bytes safe
    # under pending/ a live reservation would only hold capacity and outrank the result.
    pg_reservation_remove "$RUN_MARKER" 2>/dev/null || true
    echo "[oracle-review] WARNING: completed-artifact store unwritable; the review is durable at $RESULT_PATH instead." >&2
    return 0
  fi
  rm -f "$PRO_GATE_HOME/pending/$RUN_MARKER.tmp.$$" 2>/dev/null
  PG_KEEP_FINAL=1
  RESULT_PATH="$src"
  echo "[oracle-review] WARNING: no durable store writable; the review is KEPT at $RESULT_PATH (survives only until temp cleanup) — copy it out now." >&2
  return 0
}
pg_publish_fail() {  # $1 = snapshot — shared failure path: durability decides the message,
  # and when NOTHING could be persisted the snapshot itself is retained (gate #54 r9).
  local src="$1"
  if pg_completed_write "$RUN_MARKER" "$src" \
     && [ -f "$(pg_completed_dir)/$RUN_MARKER" ] && [ -r "$(pg_completed_dir)/$RUN_MARKER" ] \
     && [ -s "$(pg_completed_dir)/$RUN_MARKER" ] && cmp -s "$src" "$(pg_completed_dir)/$RUN_MARKER"; then
    PG_RESULT_DURABLE=1
    pg_reservation_remove "$RUN_MARKER" 2>/dev/null || true
    echo "ERROR: review captured but could not be written to --out ($OUT). It is durable at $(pg_completed_dir)/$RUN_MARKER — copy it from there or re-run --harvest '$RUN_MARKER'; do NOT respend." >&2
    pg_status failed "already collected; --out unwritable; artifact at $(pg_completed_dir)/$RUN_MARKER"
  else
    # Durable MARKER-ADDRESSED copy of the review BYTES (gate #54 r10/r11): a pointer to a
    # /tmp snapshot dies with reboots and temp sweeps. If no durable location exists at all,
    # keep the run's active record and tab so --status still shows a live trail.
    if { mkdir -p "$PRO_GATE_HOME/pending" \
         && cp "$src" "$PRO_GATE_HOME/pending/$RUN_MARKER.tmp.$$" \
         && mv -f "$PRO_GATE_HOME/pending/$RUN_MARKER.tmp.$$" "$PRO_GATE_HOME/pending/$RUN_MARKER" \
         && [ -f "$PRO_GATE_HOME/pending/$RUN_MARKER" ] \
         && [ -r "$PRO_GATE_HOME/pending/$RUN_MARKER" ] \
         && [ -s "$PRO_GATE_HOME/pending/$RUN_MARKER" ] \
         && cmp -s "$src" "$PRO_GATE_HOME/pending/$RUN_MARKER"; } 2>/dev/null; then
      PG_RESULT_DURABLE=1
      pg_reservation_remove "$RUN_MARKER" 2>/dev/null || true
      echo "ERROR: review captured but --out ($OUT) and the artifact store are unwritable. The review is durable at $PRO_GATE_HOME/pending/$RUN_MARKER — copy it from there; do NOT respend." >&2
      pg_status failed "captured; --out unwritable; review durable at pending/$RUN_MARKER"
    else
      rm -f "$PRO_GATE_HOME/pending/$RUN_MARKER.tmp.$$" 2>/dev/null
      PG_KEEP_FINAL=1
      PG_PRESERVE_STATE=1
      echo "ERROR: review captured but nothing under $PRO_GATE_HOME is writable either. The verified snapshot is KEPT at $src; the run's tab and active record are PRESERVED — recover manually; do NOT respend." >&2
      pg_status failed "captured; no durable location writable; snapshot kept at $src; state preserved"
    fi
  fi
  pg_finish 6
}

# v0.32: serialize every organizer for one marker. The delayed early rename and terminal
# archive/close must never overlap: on a short run the latter can finish before the former wakes,
# and an unsynchronized helper would then reopen the remembered URL after successful cleanup.
# Linux uses a dedicated dynamic flock fd (never the engine's lock fds); stock macOS uses an
# owner-verified mkdir lock. Globals are process-local inside the early organizer's subshell.
pg_organizer_lock_acquire() {  # <marker> [wait-seconds]
  local marker="$1" wait_s="${2:-95}" lock start self self_token probe_pid
  case "$wait_s" in ''|*[!0-9]*) wait_s=95;; esac
  PG_ORGANIZER_LOCK_FD=""; PG_ORGANIZER_LOCK_DIR=""
  PG_ORGANIZER_LOCK_OWNER=""; PG_ORGANIZER_LOCK_TOKEN=""
  lock="${PRO_GATE_ORGANIZER_LOCK_DIR:-$PRO_GATE_HOME/organizer-locks}/$marker"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 1
  if [ "${PRO_GATE_TEST_ORGANIZER_NO_FLOCK:-0}" != 1 ] && command -v flock >/dev/null 2>&1; then
    if { exec {PG_ORGANIZER_LOCK_FD}>>"$lock"; } 2>/dev/null \
       && flock -w "$wait_s" "$PG_ORGANIZER_LOCK_FD" 2>/dev/null; then
      return 0
    fi
    [ -n "${PG_ORGANIZER_LOCK_FD:-}" ] && eval "exec ${PG_ORGANIZER_LOCK_FD}>&-" 2>/dev/null
    PG_ORGANIZER_LOCK_FD=""
    return 1
  fi
  PG_ORGANIZER_LOCK_DIR="${lock}.d"; start="$(date +%s)"
  # BASHPID is absent in macOS's Bash 3.2, and $$ stays the parent engine's pid inside a
  # background subshell. The PPID of a short child is the actual current shell process; unlike
  # a $$-named temp file, this cannot collide between sibling helpers.
  self="${BASHPID:-}"
  if [ -z "$self" ]; then
    sleep 5 & probe_pid=$!
    self="$(ps -o ppid= -p "$probe_pid" 2>/dev/null | tr -d ' ')"
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
  fi
  case "$self" in ''|*[!0-9]*) self="$$";; esac
  self_token="$(pg_pid_token "$self" 2>/dev/null || true)"
  [ -n "$self_token" ] || { PG_ORGANIZER_LOCK_DIR=""; return 1; }
  # Existing directories are always BUSY, including missing/torn/dead owner metadata. Reaping a
  # path after reading its metadata cannot be made conditional with portable Bash: a live winner
  # can replace the directory before rm/rename and be deleted instead. The startup sweep removes
  # crash-left organizer locks only after one day; this bounded acquisition therefore fails closed.
  while ! mkdir "$PG_ORGANIZER_LOCK_DIR" 2>/dev/null; do
    [ $(( $(date +%s) - start )) -ge "$wait_s" ] \
      && { PG_ORGANIZER_LOCK_DIR=""; return 1; }
    sleep 1
  done
  # Ownership publication is part of acquisition, not best-effort diagnostics. A process may run
  # browser work only after both fields are atomically installed and read back from its directory.
  if ! printf '%s\n' "$self" > "$PG_ORGANIZER_LOCK_DIR/pid.tmp.$self" 2>/dev/null \
     || ! mv -f "$PG_ORGANIZER_LOCK_DIR/pid.tmp.$self" "$PG_ORGANIZER_LOCK_DIR/pid" 2>/dev/null \
     || ! printf '%s\n' "$self_token" > "$PG_ORGANIZER_LOCK_DIR/token.tmp.$self" 2>/dev/null \
     || ! mv -f "$PG_ORGANIZER_LOCK_DIR/token.tmp.$self" "$PG_ORGANIZER_LOCK_DIR/token" 2>/dev/null \
     || [ "$(cat "$PG_ORGANIZER_LOCK_DIR/pid" 2>/dev/null || true)" != "$self" ] \
     || [ "$(cat "$PG_ORGANIZER_LOCK_DIR/token" 2>/dev/null || true)" != "$self_token" ]; then
    rm -rf "$PG_ORGANIZER_LOCK_DIR" 2>/dev/null
    PG_ORGANIZER_LOCK_DIR=""
    return 1
  fi
  PG_ORGANIZER_LOCK_OWNER="$self"
  PG_ORGANIZER_LOCK_TOKEN="$self_token"
  return 0
}

pg_organizer_lock_release() {
  local owner owner_token
  [ -n "${PG_ORGANIZER_LOCK_FD:-}" ] && eval "exec ${PG_ORGANIZER_LOCK_FD}>&-" 2>/dev/null
  if [ -n "${PG_ORGANIZER_LOCK_DIR:-}" ]; then
    owner="$(cat "$PG_ORGANIZER_LOCK_DIR/pid" 2>/dev/null || true)"
    owner_token="$(cat "$PG_ORGANIZER_LOCK_DIR/token" 2>/dev/null || true)"
    [ "$owner" = "${PG_ORGANIZER_LOCK_OWNER:-}" ] \
      && [ "$owner_token" = "${PG_ORGANIZER_LOCK_TOKEN:-}" ] \
      && rm -rf "$PG_ORGANIZER_LOCK_DIR" 2>/dev/null
  fi
  PG_ORGANIZER_LOCK_FD=""; PG_ORGANIZER_LOCK_DIR=""
  PG_ORGANIZER_LOCK_OWNER=""; PG_ORGANIZER_LOCK_TOKEN=""
}

pg_organizer_join() {  # wait for and retire any early organizer without browser traffic
  local marker="${RUN_MARKER:-}"
  [ "$MODE" = remote-chrome ] || return 0
  pg_reservation_marker_ok "$marker" || return 0
  if pg_organizer_lock_acquire "$marker" "${PRO_GATE_TEST_ORGANIZER_LOCK_WAIT:-95}"; then
    pg_organizer_lock_release
    return 0
  fi
  echo "[oracle-review] organizer source=none rename=failed archive=disabled close=skipped reason=organizer-lock-timeout" >&2
  return 1
}

pg_organize_chat() {  # rename|finalize [early-lease] [diagnostic-log] [helper-seconds] [scan-seconds]
  local action="$1" lease="${2:-}" diagnostic_log="${3:-}" helper_s="${4:-35}" scan_s="${5:-25}"
  local marker="${RUN_MARKER:-}" timeout_bin line cooldown_reason
  local -a organizer_args=(--organize)
  [ "$MODE" = remote-chrome ] || return 0
  pg_reservation_marker_ok "$marker" || return 0
  timeout_bin="${PRO_GATE_TIMEOUT_BIN:-timeout}"
  # Most revoked helpers are still asleep and can exit before creating even a lock file. The
  # second lease check below remains authoritative for the race where finalization revokes while
  # this helper is queued behind an active organizer.
  [ -n "$lease" ] && [ ! -f "$lease" ] && return 0
  if ! pg_organizer_lock_acquire "$marker" 95; then
    line='organizer source=none rename=failed archive=disabled close=skipped reason=organizer-lock-timeout'
  elif [ -n "$lease" ] && [ ! -f "$lease" ]; then
    # Terminal finalization (or a newer retry) revoked this delayed helper before it acquired
    # mutation authority. Acquiring the lock first joins any already-running helper before this
    # process returns, so cooldown evidence cannot abandon browser work outside serialization.
    pg_organizer_lock_release
    return 0
  elif [ "${THROTTLED:-0}" = 1 ] || [ "${CLOUDFLARE:-0}" = 1 ] \
       || cooldown_reason="$(pg_cooldown_active)"; then
    # Browser organization is traffic against the same account surface as salvage. Check every
    # process-local and shared signal under the marker lock: a peer may write the cooldown while
    # this helper waits, and terminal cleanup must still join an early helper before returning.
    pg_organizer_lock_release
    return 0
  elif ! command -v node >/dev/null 2>&1; then
    pg_organizer_lock_release
    return 0
  elif [[ "$timeout_bin" == */* ]] && [ ! -x "$timeout_bin" ]; then
    pg_organizer_lock_release
    return 0
  elif [[ "$timeout_bin" != */* ]] && ! command -v "$timeout_bin" >/dev/null 2>&1; then
    pg_organizer_lock_release
    return 0
  else
    [ "${CHAT_RENAME:-0}" = 1 ] || organizer_args+=(--no-rename)
    # The scan/render window may be followed by a 15s mutation evaluation and a 5s positive-
    # cancellation attempt. Keep the shell helper beyond that lifecycle so timeout can never
    # release the marker lock while the renderer's absolute 10s mutation lease is still live.
    local helper_min_s=$(( scan_s + 25 ))
    if [ "$action" = finalize ]; then
      [ "${PG_RESULT_DURABLE:-0}" = 1 ] && [ -s "${RESULT_PATH:-}" ] || {
        pg_organizer_lock_release
        return 0
      }
      organizer_args+=(--finalize --result-file "$RESULT_PATH")
      [ -n "${PG_ACCEPTED_URL:-}" ] && organizer_args+=(--accepted-url "$PG_ACCEPTED_URL")
      [ "${CHAT_ARCHIVE:-0}" = 1 ] && organizer_args+=(--archive)
      # Finalization may perform both rename and archive, so reserve two mutation windows.
      helper_min_s=$(( scan_s + 50 ))
    fi
    [ "$helper_s" -ge "$helper_min_s" ] 2>/dev/null || helper_s="$helper_min_s"
    line="$("$timeout_bin" "$helper_s" node "$SELF/cdp-salvage.mjs" "${organizer_args[@]}" \
      "$marker" "$scan_s" "$PORT" 2>/dev/null | sed -n '/^organizer /p' | tail -n 1)"
    # The helper may be the early organizer's subshell, so its THROTTLED assignment cannot reach
    # the parent. Publish a run-private sentinel before releasing serialization; pg_finish joins
    # this lock and consumes it before the one ramp update and ledger append.
    if case "$line" in *' reason=throttle') true;; *) false;; esac \
       || pg_cooldown_active >/dev/null 2>&1; then
      THROTTLED=1
      : > "$WORK/organizer-throttle" 2>/dev/null || true
    fi
    pg_organizer_lock_release
    [ -n "$line" ] || line='organizer source=none rename=failed archive=disabled close=skipped reason=helper-failed'
  fi
  if [ -n "$diagnostic_log" ]; then
    printf '[oracle-review] %s\n' "$line" >> "$diagnostic_log" 2>/dev/null || true
  else
    echo "[oracle-review] $line" >&2
  fi
  return 0
}

pg_finish() {  # $1 exit code — settle organization, ramp, and ledger exactly once, then exit
  local rc="$1" outcome dur now pre_slot_secs post_slot_secs kind line model_label fsrc title_memo=""
  # Revoke every sleeping early organizer before anything at the terminal boundary can settle.
  # Every path below then acquires the marker lock — either to mutate or only to join — so no
  # helper can keep scanning/rendering after the parent records its final account state.
  rm -f "$WORK"/early-organizer.*.lease 2>/dev/null || true
  now="$(date +%s)"
  dur=$(( now - RUN_START ))
  # RUN_START and now are two independent `date +%s` samples possibly minutes apart; an NTP
  # correction or WSL suspend/resume between them can make dur negative. Clamp FIRST, before any
  # branch below reads it, so a backward clock jump can never write a negative `secs` OR break
  # the pre/post split that's derived from this same clamped value.
  [ "$dur" -lt 0 ] 2>/dev/null && dur=0
  # ledger-timing-split (R1/R3): split `secs` (unchanged, kept for backward compatibility) into
  # pre_slot_secs (this run's life before it held an account slot) and post_slot_secs (its life
  # after), by field name. LAUNCH_EPOCH marks SLOT ACQUISITION, not the start of model
  # generation: RUN_START precedes browser preflight, diff retrieval/filtering and prompt
  # preparation; the post-slot health gate can still exit 8 without ever invoking the model; and
  # retry backoff plus salvage land after LAUNCH_EPOCH too. So these fields measure pre-slot vs.
  # post-slot lifecycle time, NOT queue-wait vs. model-generation time — name and comment say so
  # plainly to avoid overclaiming. A harvest never queues for a slot at all — it reads an
  # existing/in-progress conversation over CDP — so its pre_slot_secs is always 0 and
  # post_slot_secs is this invocation's own short wall time (collection, not generation); that
  # semantic is DOCUMENTED here rather than reconstructed from a phase epoch harvest never has. A
  # fresh run that reached "launching" (LAUNCH_EPOCH set) splits at that phase transition; one
  # that never did (lock-timeout, preflight failure, round-cap) records its whole life as
  # pre_slot_secs with post_slot_secs 0. The partition is exact BY CONSTRUCTION, not by
  # independent defensive floors on each side: post_slot_secs is always derived from the
  # already-clamped dur minus the clamped pre_slot_secs, so pre_slot_secs + post_slot_secs ==
  # secs holds under every clock condition.
  kind="fresh"; [ "${HARVEST:-0}" = 1 ] && kind="harvest"
  if [ "${HARVEST:-0}" = 1 ]; then
    pre_slot_secs=0
    post_slot_secs=$dur
  elif [ -n "$LAUNCH_EPOCH" ]; then
    pre_slot_secs=$(( LAUNCH_EPOCH - RUN_START ))
    [ "$pre_slot_secs" -lt 0 ] 2>/dev/null && pre_slot_secs=0
    [ "$pre_slot_secs" -gt "$dur" ] 2>/dev/null && pre_slot_secs=$dur
    post_slot_secs=$(( dur - pre_slot_secs ))
  else
    pre_slot_secs=$dur
    post_slot_secs=0
  fi
  model_label="$(pg_model_label "${RESOLVED_MODEL:-}")"   # resolved model or role-based fallback

  # v0.28 (#56): a clean run's review becomes the write-once completed artifact before any
  # archive/close is eligible. The private verified snapshot is authoritative for both durable
  # bytes and the ledger digest; a shared --out can be reused by unrelated markers.
  fsrc="${PG_FINAL_SRC:-$OUT}"
  [ -s "$fsrc" ] || fsrc="$OUT"
  OUT_SHA=""
  if [ "$rc" = 0 ] && [ -n "${RUN_MARKER:-}" ] && [ -s "$fsrc" ]; then
    # Persist EXACTLY ONCE (gate #54 r12): when pg_persist_result already ran, a retry here
    # could replace a pending result already named by status/stdout with a different path.
    if [ -z "${RESULT_PATH:-}" ]; then
      if pg_completed_write "$RUN_MARKER" "$fsrc" \
         && [ -f "$(pg_completed_dir)/$RUN_MARKER" ] && [ -r "$(pg_completed_dir)/$RUN_MARKER" ] \
         && [ -s "$(pg_completed_dir)/$RUN_MARKER" ] && cmp -s "$fsrc" "$(pg_completed_dir)/$RUN_MARKER"; then
        RESULT_PATH="$(pg_completed_dir)/$RUN_MARKER"
        PG_RESULT_DURABLE=1
      else
        echo "[oracle-review] WARNING: completed artifact could not be persisted for ${RUN_MARKER} ($(pg_completed_dir) unwritable?); already-collected recovery will rely on the ledgered digest only." >&2
      fi
    fi
    OUT_SHA="$(pg_sha256 "$fsrc")"
  fi

  # v0.32: mutation is a positive state machine, never the former "close unless excluded"
  # heuristic. A mutation-capable call also joins the early helper under the same marker lock;
  # every non-mutating terminal path performs an explicit join-only acquisition.
  if pg_reservation_marker_ok "${RUN_MARKER:-}"; then
    title_memo="$(pg_conversation_title_dir)/${RUN_MARKER}"
  fi
  case "$rc" in
    0)
      if [ "${PG_RESULT_DURABLE:-0}" = 1 ] && [ "${PG_PRESERVE_STATE:-0}" != 1 ]; then
        if [ "${PRO_GATE_KEEP_TABS:-0}" = 1 ]; then
          if [ "${CHAT_RENAME:-0}" = 1 ] && [ -s "$title_memo" ]; then
            pg_organize_chat rename
          else
            pg_organizer_join || true
          fi
        else
          pg_organize_chat finalize
        fi
      elif [ "${CHAT_RENAME:-0}" = 1 ] && [ -s "$title_memo" ]; then
        pg_organize_chat rename
      else
        pg_organizer_join || true
      fi ;;
    3|6|9)
      if [ "${CHAT_RENAME:-0}" = 1 ] && [ -s "$title_memo" ]; then
        pg_organize_chat rename
      else
        pg_organizer_join || true
      fi ;;
    *) pg_organizer_join || true ;;
  esac

  # Organizer scans and scratch renders can discover an account throttle in a child process.
  # The marker join makes its run-private sentinel authoritative before classification; do not
  # infer this run's outcome from a cooldown that may have predated artifact-only recovery.
  [ -f "$WORK/organizer-throttle" ] && THROTTLED=1
  case "$rc" in
    0) outcome=clean ;;
    4) outcome=bad-repo ;;
    5) outcome=diff-fetch-failed ;;
    6) outcome=failed ;;
    7) outcome=lock-timeout ;;
    8) outcome=deferred ;;
    9) outcome=in-progress ;;
    11) outcome=oversized ;;
    12) outcome=round-capped ;;
    *) outcome=other ;;
  esac
  [ "${THROTTLED:-0}" = 1 ] && outcome=throttle
  [ "${CLOUDFLARE:-0}" = 1 ] && outcome=cloudflare
  # Harvests spend no Pro slot and never teach the ramp. Fresh clean/throttle/failure outcomes do;
  # Cloudflare records its distinct ledger outcome while feeding the same account-level backoff.
  if [ "${HARVEST:-0}" != 1 ]; then
    case "$outcome" in
      clean|throttle|failed) pg_ramp_update "$outcome" "${MAX_CONC:-1}" ;;
      cloudflare)            pg_ramp_update throttle "${MAX_CONC:-1}" ;;
    esac
  fi

  [ -n "${PG_FINAL_SRC:-}" ] && [ "$PG_FINAL_SRC" != "$OUT" ] && [ "${PG_KEEP_FINAL:-0}" != 1 ] \
    && rm -f "$PG_FINAL_SRC" 2>/dev/null
  # v0.27: marker and round_key make every row independently recoverable. Failures before
  # identity derivation carry empty values — present, not absent.
  if pg_have jq; then
    line="$(jq -nc --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg pr "${PR_NUM:-diff}" \
      --arg repo "${REPO:-}" --argjson exit "$rc" --arg outcome "$outcome" \
      --argjson secs "$dur" --argjson pre_slot_secs "$pre_slot_secs" --argjson post_slot_secs "$post_slot_secs" \
      --arg kind "$kind" \
      --argjson attempts "${attempt:-0}" \
      --argjson conc "${EFF_CONC:-0}" --argjson ceiling "${MAX_CONC:-1}" \
      --argjson live "${LIVE_CONVERSATION:-0}" --argjson salvaged "${SALVAGED:-0}" \
      --argjson diff_lines "${DIFF_LINES:-0}" --arg out "$OUT" --arg model "$model_label" \
      --arg marker "${RUN_MARKER:-}" --arg round_key "${ROUND_KEY:-}" --arg sha256 "$OUT_SHA" \
      '{ts:$ts,pr:$pr,repo:$repo,exit:$exit,outcome:$outcome,secs:$secs,pre_slot_secs:$pre_slot_secs,post_slot_secs:$post_slot_secs,kind:$kind,attempts:$attempts,conc:$conc,ceiling:$ceiling,live:$live,salvaged:$salvaged,diff_lines:$diff_lines,out:$out,model:$model,marker:$marker,round_key:$round_key,sha256:$sha256}' 2>/dev/null)"
  else
    line="$(printf '{"ts":"%s","pr":"%s","exit":%d,"outcome":"%s","secs":%d,"pre_slot_secs":%d,"post_slot_secs":%d,"kind":"%s","attempts":%d,"conc":%d,"ceiling":%d,"live":%d,"salvaged":%d,"out":"%s","model":"%s","marker":"%s","round_key":"%s","sha256":"%s"}' \
      "$(date +%Y-%m-%dT%H:%M:%S%z)" "${PR_NUM:-diff}" "$rc" "$outcome" "$dur" "$pre_slot_secs" "$post_slot_secs" "$kind" "${attempt:-0}" \
      "${EFF_CONC:-0}" "${MAX_CONC:-1}" "${LIVE_CONVERSATION:-0}" "${SALVAGED:-0}" \
      "$(printf '%s' "$OUT" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "$model_label" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "${RUN_MARKER:-}" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "${ROUND_KEY:-}" | tr -d '"\\' | tr '\n' ' ')" \
      "$OUT_SHA")"
  fi
  pg_ledger_append "$line"
  [ "${PG_PRESERVE_STATE:-0}" = 1 ] || pg_active_clear "$rc"
  exit "$rc"
}

# --- preflight: browser reachable / signed in (per platform) ---
# v0.28 (#56, gate #54 r4 P2): the completed artifact needs NO browser at all — return it
# before even the global CDP preflight, so a collected review stays retrievable while Chrome
# is down (the exact condition the artifact exists for). No lock needed: the artifact is
# write-once and installed atomically, so a concurrent reader can never observe a torn copy.
if [ -n "$HARVEST_MARKER" ] && pg_reservation_marker_ok "$HARVEST_MARKER" \
   && [ -s "$(pg_completed_dir)/$HARVEST_MARKER" ] && [ ! -L "$(pg_completed_dir)/$HARVEST_MARKER" ] \
   && pg_is_review "$(pg_completed_dir)/$HARVEST_MARKER"; then
  # Full run identity BEFORE any status/ledger write (gate #54 r5 P2): without it this row
  # landed as pr=diff with no round_key, invisible to --status/stats and unable to retire a
  # dead active record. The RETURNED bytes come from a process-private snapshot of the
  # write-once artifact (r5 P1): two markers sharing one caller --out can race the final
  # rename, but each invocation still outputs and ledgers exactly the bytes it verified.
  HARVEST=1
  RUN_MARKER="$HARVEST_MARKER"
  ROUND_KEY="${HARVEST_MARKER#pg-run-}"; ROUND_KEY="${ROUND_KEY%-*-*}"
  # #50 item 3: the ledger/status pr field is the trailing PR NUMBER; round_key carries the
  # full repo-scoped key. Jamming the whole key into pr produced malformed identity rows
  # (pr:"org-repo-953", repo:"") that polluted every per-PR ledger join.
  PR_NUM="${ROUND_KEY##*-}"
  case "$PR_NUM" in ''|*[!0-9]*) PR_NUM="$ROUND_KEY";; esac
  RESOLVED_MODEL="$(pg_reservation_read_model "$RUN_MARKER" 2>/dev/null || true)"
  FASTPATH_ART="$(pg_completed_dir)/$RUN_MARKER"
  FASTPATH_SNAP="$WORK/fastpath.snap"
  if cp "$FASTPATH_ART" "$FASTPATH_SNAP" 2>/dev/null && pg_is_review "$FASTPATH_SNAP"; then
    PG_FINAL_SRC="$FASTPATH_SNAP"
    PG_RESULT_DURABLE=1
    SALVAGED=1
    # Retire any leftover reservation/manifest for this marker (gate #54 r7): a crash between
    # a prior run's artifact write and its reservation removal must not hold account capacity
    # (and keep redirecting this change to harvest) for the whole 6h TTL.
    pg_reservation_remove "$RUN_MARKER" || true
    echo "[oracle-review] review already collected (completed artifact); result retrieval needed no browser and spent nothing; best-effort organization may follow." >&2
    if ! pg_publish_out "$FASTPATH_SNAP"; then
      echo "ERROR: collected review could not be written to --out ($OUT). It remains durable at $FASTPATH_ART — copy it from there; do NOT respend." >&2
      pg_status failed "already collected; could not publish to --out (artifact at $FASTPATH_ART)"
      pg_finish 6
    fi
    RESULT_PATH="$FASTPATH_ART"
    echo "RESULT_FILE=$RESULT_PATH"
    pg_status done "already collected; result: $RESULT_PATH"
    cat "$FASTPATH_SNAP"
    pg_finish 0
  fi
  rm -f "$FASTPATH_SNAP" 2>/dev/null
fi

if [ "$MODE" = "remote-chrome" ]; then
  export DISPLAY="${ORACLE_DISPLAY:-:99}"
  # v0.19: one self-heal attempt (non-interactive service start) before giving up.
  if ! pg_cdp_heal; then
    echo "ERROR: oracle browser session (CDP) not reachable on ${PORT} (self-heal attempted)." >&2
    [ "$(pg_service_mgr)" = systemd ] && echo "  start it: sudo systemctl start oracle-chrome" >&2
    pg_status failed "browser CDP unreachable"
    exit 3
  fi
else
  # native (macOS): oracle drives your signed-in Chrome. Nothing to pre-start; oracle errors
  # clearly if you're not signed into ChatGPT.
  :
fi

# --- v0.20: harvest mode: collect an in-progress run's review, spending NO new slot ---
# A run that exits 9 (in-progress) spent its Pro slot but hit the salvage budget while the
# model was still generating; its conversation tab was deliberately left open. This mode
# re-runs ONLY the marker-matched CDP collection. Exit: 0 done, 9 still generating / retry later
# (also: the browser never answered, which is NOT counted as a miss), 8 deferred (cooldown/box
# unfit: the account must not be rendered against), 6 conversation gone (review lost; only now is
# a re-run justified).
# v0.25: the collection is no longer limited to OPEN TABS. cdp-salvage remembers the run's
# conversation URL once it proves which conversation is ours, and re-renders that URL when no tab
# carries the marker — so a Chrome restart (the common ending on a memory-pressured box) stops
# turning a finished, server-side review into "conversation gone".
if [ -n "$HARVEST_MARKER" ]; then
  HARVEST=1
  RUN_MARKER="$HARVEST_MARKER"
  if ! pg_reservation_marker_ok "$RUN_MARKER"; then
    echo "ERROR: invalid --harvest marker (expected pg-run-... safe filename syntax)." >&2
    pg_status failed "invalid harvest marker"
    pg_finish 2
  fi
  # KTD3: name the model the original in-progress run persisted into the reservation record. The
  # harvest runs in a separate process with no $RUNLOG to grep, so it reads the model straight
  # back; a legacy/empty record leaves RESOLVED_MODEL empty -> role-based fallback. Derive the R6
  # warning HERE too (dogfood PR #20 P2): the harvest branch pg_finishes before the fresh-path
  # warning block, so without this a harvested weak/unconfirmable model would lose its marker. No
  # selection status is available in this process, so an empty model here warns "cannot confirm".
  RESOLVED_MODEL="$(pg_reservation_read_model "$RUN_MARKER" 2>/dev/null || true)"
  MODEL_WARN="$(pg_derive_model_warn "$RESOLVED_MODEL" "")"
  [ -n "$MODEL_WARN" ] && echo "[oracle-review] WARNING: ${MODEL_WARN}." >&2
  if [ "$MODE" != remote-chrome ]; then
    echo "ERROR: --harvest requires remote-chrome/CDP mode; native browser mode exposes no marker-addressable CDP tab." >&2
    pg_status failed "harvest unsupported in native browser mode"
    pg_finish 3
  fi
  # #67: TTL must be reachable from the harvest path. pg_reservation_reconcile used to run ONLY
  # in fresh dispatch, so the documented free-recovery flow ("just --harvest") could never
  # retire a reservation — and a fresh run is redirected to that reservation before it can
  # submit, so both exits were closed and a stranded change stayed stranded (pushbot#1334 lost
  # its review that way). TTL-only here: no probe, no miss increment, so a harvest of a
  # genuinely-live conversation is untouched, and the caller's own capture below is the real
  # evidence. PRO_GATE_HARVEST_TTL_SWEEP=0 opts out.
  # ledger/status identity from the marker's "pg-run-<key>-<epoch>-<pid>" shape (best-effort;
  # the key may itself contain dashes, so strip the two trailing numeric segments instead).
  # v0.27: the stripped key lands as round_key so --status can join harvest rows to their
  # change. #50 item 3: pr is the key's trailing PR NUMBER, never the whole key — the old
  # behavior wrote malformed rows (pr:"org-repo-953", repo:"") that broke per-PR joins.
  ROUND_KEY="${HARVEST_MARKER#pg-run-}"
  ROUND_KEY="${ROUND_KEY%-*-*}"
  PR_NUM="${ROUND_KEY##*-}"
  case "$PR_NUM" in ''|*[!0-9]*) PR_NUM="$ROUND_KEY";; esac
  command -v node >/dev/null 2>&1 || { echo "ERROR: --harvest needs node for CDP salvage" >&2; pg_status failed "node missing"; pg_finish 3; }
  # Serialize the entire marker harvest. Without this, two collectors can share $OUT.cdp,
  # both read the same completed tab, and one closes it underneath the other (exit 6 + false
  # reservation removal). Linux uses flock; macOS/no-flock uses the existing pg_lock mkdir path.
  HARVEST_LOCK="${PRO_GATE_HARVEST_LOCK_DIR:-$PRO_GATE_HOME/harvest-locks}/${RUN_MARKER}"
  mkdir -p "$(dirname "$HARVEST_LOCK")" 2>/dev/null || { pg_status failed "harvest lock dir unavailable"; pg_finish 3; }
  if ! pg_lock "$HARVEST_LOCK" "${PRO_GATE_HARVEST_LOCK_WAIT:-5}"; then
    echo "ERROR: another harvest is already collecting marker ${RUN_MARKER}; not racing it." >&2
    pg_status failed "harvest already running"
    pg_finish 7
  fi
  # #67: TTL must be reachable from the harvest path. pg_reservation_reconcile used to run ONLY
  # in fresh dispatch, so the documented free-recovery flow ("just --harvest") could never
  # retire a reservation — and a fresh run is redirected to that reservation before it can
  # submit, so both exits were closed and a stranded change stayed stranded (pushbot#1334 lost
  # its review that way). Runs AFTER the harvest lock (#68 gate r2 P1): the lock file IS this
  # marker's active-collection claim, and every reconciler skips actively-claimed markers, so
  # no concurrent sweep can reap a reservation mid-collection either. TTL-only: no probe, no
  # miss increment. PRO_GATE_HARVEST_TTL_SWEEP=0 opts out.
  if [ "${PRO_GATE_HARVEST_TTL_SWEEP:-1}" = 1 ]; then
    PG_RES_TTL_ONLY=1 pg_reservation_reconcile "" "$PORT" || true
  fi
  # (Completed-artifact returns happen BEFORE the global preflight — see the fast path above
  # the MODE check; by this point the artifact is known absent.)
  # A harvest spends NO Pro slot and only reads over CDP, so the box-fitness parts of
  # pg_health_gate (memory, service uptime) don't apply: memory pressure is likeliest exactly
  # when a long review forced the harvest. Only the account cooldown defers it: salvage renders
  # against a throttled/challenged account deepen the block.
  if GATE_REASON="$(pg_cooldown_active)"; then
    echo "[oracle-review] harvest deferred: ${GATE_REASON}." >&2
    pg_status deferred "$GATE_REASON"
    pg_finish 8
  fi
  HARVEST_SECS="$(pg_dur_secs "$TIMEOUT")"
  # Stamp the trajectory row with when the ROUND WAS CHARGED. Authoritative source is the
  # reservation's spend field, written from pg_round_record's own epoch (#66 gate r3 P1); the
  # marker's launch epoch is only a fallback for legacy reservations, since a queued run mints
  # its marker up to two lock waits before the charge. NOT the reservation's `created` field:
  # that is stamped at exit-9 time, 35 min after the charge on the run that exposed this.
  HARVEST_SPEND_EPOCH="$(pg_reservation_read_spend "$RUN_MARKER" 2>/dev/null || true)"
  case "$HARVEST_SPEND_EPOCH" in ''|*[!0-9]*)
    HARVEST_SPEND_EPOCH="$(pg_marker_epoch "$RUN_MARKER" 2>/dev/null || true)";;
  esac
  echo "[oracle-review] harvesting in-progress review (marker ${RUN_MARKER}, up to ${HARVEST_SECS}s, no new slot spent)..." >&2
  pg_status salvaging "harvest up to ${HARVEST_SECS}s"
  HARVEST_RC=0
  HARVEST_TMP="$WORK/harvest.capture"
  node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "$HARVEST_SECS" "$PORT" > "$HARVEST_TMP" 2> "$HARVEST_TMP.err" || HARVEST_RC=$?
  [ -s "$HARVEST_TMP.err" ] && sed 's/^/[cdp-salvage] /' "$HARVEST_TMP.err" >&2
  # v0.28 (gate #54 r5): the CDP child names its capture's exact source URL.
  HARVEST_URL="$(sed -n 's/^matched-url //p' "$HARVEST_TMP.err" 2>/dev/null | tail -1)"
  rm -f "$HARVEST_TMP.err"
  if [ "$HARVEST_RC" -eq 0 ] && pg_is_review "$HARVEST_TMP"; then
    # v0.28 (#48/#55): provenance before acceptance, positive binding first. A capture whose
    # VERDICT line echoes this run's nonce was provably written for this prompt — that
    # overrides path heuristics entirely. Absent a nonce (model non-compliance, or a pre-v0.28
    # conversation), fall back to the manifest overlap check; a complete review citing NONE of
    # the change's files is a foreign conversation's answer. Rejection preserves the
    # reservation, counts no miss, and invalidates the memoized candidate (blacklist + memo
    # removal) so the NEXT pass rescans instead of replaying the same foreign conversation.
    HARVEST_MANIFEST="$(pg_manifest_dir)/${RUN_MARKER}"
    if pg_capture_nonce_ok "$HARVEST_TMP" "$RUN_MARKER"; then
      :  # positively bound to this run
    elif [ "$REQUIRE_NONCE" = 1 ]; then
      # NONCE OR NOTHING (gate #54 r3-r6): under REQUIRE_NONCE a nonce-less capture is never
      # accepted AND never used to blacklist — a "foreign-looking" capture may be an OLDER
      # verdict scraped from the very conversation still generating THIS run's answer (the
      # marker sits in the submitted prompt below it), so condemning its URL would skip the
      # eventual nonce-bearing result (r6 P1). Preserve everything and retry: the real answer
      # arrives with the echo, or the reservation ages out for manual recovery. Deliberately
      # independent of manifest/sidecar persistence (r4 P1): missing metadata fails CLOSED.
      mv "$HARVEST_TMP" "$OUT.unbound.$$" 2>/dev/null || rm -f "$HARVEST_TMP"
      # The exit-9 contract PROMISES a live reservation keyed to the real change; a harvest
      # can reach here for a marker whose reservation already released. An EMPTY key would
      # default to the literal "diff" and be undiscoverable (gate #54 r14): derive the key
      # from the marker, and fail CLOSED (state preserved, exit 3) when even the reservation
      # cannot be persisted — exit 9 must never claim protection it does not have.
      RES_KEY="${RUN_MARKER#pg-run-}"; RES_KEY="${RES_KEY%-*-*}"
      if ! pg_reservation_write "$RUN_MARKER" "$RES_KEY" "$OUT" 2>/dev/null; then
        PG_PRESERVE_STATE=1
        echo "ERROR: unbindable capture preserved, but its reservation could not be persisted ($PRO_GATE_HOME unwritable?). Tab and state KEPT; retry --harvest once the home is writable." >&2
        pg_status failed "unbindable capture; reservation write failed; state preserved"
        pg_finish 3
      fi
      # #68 gate r3 P1: an unbindable capture does NOT prove the review is live, so this is a
      # legitimate moment to apply the target's own TTL — and the only one, since reconcilers
      # skip markers under active collection. Without it the harvest target could never expire
      # and #67's "a stranded change frees itself" property died for the very marker it was
      # written for. Done while we still hold the harvest lock, so no peer races the decision.
      if [ "${PRO_GATE_HARVEST_TTL_SWEEP:-1}" = 1 ] && [ "$(pg_reservation_expire_if_stale "$RUN_MARKER")" = stale ]; then
        TTL_MISS="$(pg_reservation_note_miss "$RUN_MARKER")"
        if [ "$TTL_MISS" = released ]; then
          echo "ERROR: this reservation is past its ${PRO_GATE_RESERVATION_TTL:-21600}s TTL and bounded marker probes proved no recoverable conversation. Recovery is exhausted; the round remains charged and a fresh typed review is eligible. The set-aside capture is at $OUT.unbound.$$." >&2
          pg_status failed "recovery exhausted after TTL and confirmed marker misses; round retained"
          pg_finish 6
        fi
        echo "[oracle-review] past-TTL recovery remains fail-closed until confirmed marker misses reach the threshold (${TTL_MISS})." >&2
      fi
      echo "ERROR: harvested a complete review that cannot be bound to this run (no run-marker echo — possibly an older answer while the current one is still generating). Reservation and candidate kept. Retry --harvest; inspect $OUT.unbound.$$; PRO_GATE_REQUIRE_NONCE=0 accepts best-effort captures." >&2
      pg_status in-progress "harvested review unbindable (no nonce echo); reservation kept, retry"
      pg_finish 9
    elif [ -s "$HARVEST_MANIFEST" ] && ! pg_review_matches_change "$HARVEST_TMP" "$HARVEST_MANIFEST"; then
      # Legacy mode (REQUIRE_NONCE=0): path overlap is authoritative, so a zero-overlap
      # capture IS foreign here — blacklist its exact source and rescan.
      mv "$HARVEST_TMP" "$OUT.foreign.$$" 2>/dev/null || rm -f "$HARVEST_TMP"
      pg_provenance_reject "$RUN_MARKER" "${HARVEST_URL:-}"
      RES_KEY="${RUN_MARKER#pg-run-}"; RES_KEY="${RES_KEY%-*-*}"
      if ! pg_reservation_write "$RUN_MARKER" "$RES_KEY" "$OUT" 2>/dev/null; then
        PG_PRESERVE_STATE=1
        echo "ERROR: foreign capture set aside, but the reservation could not be persisted ($PRO_GATE_HOME unwritable?). Tab and state KEPT; retry --harvest once the home is writable." >&2
        pg_status failed "foreign capture set aside; reservation write failed; state preserved"
        pg_finish 3
      fi
      echo "ERROR: harvested a complete review that cites NONE of this change's files — foreign conversation suspected. Reservation kept, its memoized candidate invalidated; retry --harvest. The rejected capture is at $OUT.foreign.$$ for inspection." >&2
      pg_status in-progress "harvested review failed provenance (cites no change files); reservation kept"
      pg_finish 9
    else
      echo "[oracle-review] NOTE: PRO_GATE_REQUIRE_NONCE=0 — accepted a nonce-less capture on best-effort path overlap." >&2
    fi
    # Only now—after structural, nonce, and provenance acceptance—may the exact CDP source URL
    # narrow finalization. A merely observed candidate never gains mutation authority.
    PG_ACCEPTED_URL="${HARVEST_URL:-}"
    pg_strip_nonce "$HARVEST_TMP" "$RUN_MARKER"
    # Private verified snapshot is the authoritative return (gate #54 r6): $OUT is
    # publication only — a concurrent marker sharing the caller's --out cannot change what
    # THIS invocation returns, persists, or ledgers. Publication is VERIFIED (r8): "done"
    # promises a readable --out, so a failed publish routes to manual recovery instead.
    PG_FINAL_SRC="$HARVEST_TMP"
    pg_publish_out "$PG_FINAL_SRC" || pg_publish_fail "$PG_FINAL_SRC"
    # Durability ladder (gate #54 r6/r14): pg_persist_result retires the reservation on the
    # durable rungs; only the volatile last-resort rung keeps it (the review then remains
    # re-collectable).
    pg_persist_result "$PG_FINAL_SRC"
    # v0.22: a harvest completes the round the exit-9 run already recorded, so refresh the
    # round budget's last-severity sidecar too. The marker embeds ROUND_KEY
    # ("pg-run-<key>-<epoch>-<pid>") for PR and --diff runs alike; legacy markers resolve to
    # keys with no recorded rounds and are skipped inside the helper (best-effort, advisory).
    HARVEST_KEY="${RUN_MARKER#pg-run-}"; HARVEST_KEY="${HARVEST_KEY%-*-*}"
    pg_round_note_severity "$HARVEST_KEY" "$PG_FINAL_SRC" "$HARVEST_SPEND_EPOCH"
    SALVAGED=1
    echo "[oracle-review] harvest recovered the completed review ($(wc -c < "$PG_FINAL_SRC" 2>/dev/null) bytes)." >&2
    echo "RESULT_FILE=$RESULT_PATH"
    pg_status done "result: $RESULT_PATH"
    cat "$PG_FINAL_SRC"
    pg_finish 0
  fi
  rm -f "$HARVEST_TMP"
  case "$HARVEST_RC" in
    3) pg_reservation_write "$RUN_MARKER" "" "$OUT" || true
       echo "[oracle-review] still generating: tab left open; run --harvest again later." >&2
       pg_status in-progress "still generating; retry --harvest later"
       pg_finish 9 ;;
    5) echo "[oracle-review] ChatGPT throttle hit during harvest: cooldown written; retry --harvest after it expires." >&2
       THROTTLED=1
       pg_status deferred "throttle during harvest; retry after cooldown"
       pg_finish 8 ;;
    7) # v0.25: INCONCLUSIVE — either the salvage never got one successful CDP tab list (browser
       # down or restarting, the very condition that loses tabs in the first place), or the
       # remembered conversation would not render decisively. Absence of evidence, so it must NOT
       # advance the miss counter toward "conversation gone": keep the reservation untouched and
       # let the caller retry. The reservation TTL bounds how long an undecidable marker can hold
       # capacity.
       if [ -f "$(pg_reservation_dir)/$RUN_MARKER" ]; then
         echo "[oracle-review] harvest inconclusive (browser unreachable, or the conversation would not render decisively). Reservation kept, NO miss counted. Retry --harvest once the browser is healthy." >&2
         pg_status in-progress "harvest inconclusive; retry later"
         pg_finish 9
       fi
       # No reservation is held (already collected, or released/expired while the URL memo was
       # deliberately kept for later human recovery). Do NOT promise an in-progress review that
       # will never complete — but do NOT claim the conversation is gone either: rc=7 is still
       # absence of evidence, and exit 6 both invites a fresh Pro spend and permits tab cleanup
       # (gate P1). Exit 3 says exactly what is true: engine/browser trouble, nothing destroyed,
       # retry when healthy. pg_finish skips tab cleanup on 3.
       echo "ERROR: harvest inconclusive for ${RUN_MARKER} and no reservation is held (already collected, or released earlier). Nothing was destroyed; retry once the browser is healthy, or open the conversation in ChatGPT." >&2
       pg_status failed "harvest inconclusive; no reservation held; retry when healthy"
       pg_finish 3 ;;
    4) # Confirmed absent THIS probe, which is not yet proof of loss (suspended renderer,
       # hydration): apply the shared consecutive-miss policy instead of destroying the
       # reservation on one observation (dogfood review P1).
       MISS_VERDICT="$(pg_reservation_note_miss "$RUN_MARKER")"
       if [ "$MISS_VERDICT" = released ]; then
         # v0.28 (#52 item 2, #56): "released" conflates two very different states — a genuine
         # miss-limit loss, and a reservation ALREADY ABSENT because another pass collected
         # this review. Declaring the second one lost invited a duplicate Pro spend; return
         # the collected review idempotently instead, spending nothing. The write-once
         # completed artifact (marker-addressed, written at collection) is the primary proof;
         # the ledgered path is the fallback for pre-artifact collections, DIGEST-VERIFIED
         # when the row carries one — a reused/overwritten output path must never impersonate
         # a collection (gate #54 r1+r2 P1), and pre-existing $OUT content never counts.
         PRIOR_OUT=""; PRIOR_SHA=""; COLLECT_OK=0; COLLECT_SRC=""
         if [ -s "$(pg_completed_dir)/$RUN_MARKER" ] \
            && [ ! -L "$(pg_completed_dir)/$RUN_MARKER" ] \
            && cp "$(pg_completed_dir)/$RUN_MARKER" "$WORK/already.snap" 2>/dev/null \
            && pg_is_review "$WORK/already.snap"; then
           # Snapshot-first here too (gate #54 r8): this branch is reachable when a second
           # collector passes the initial fast path before the first publishes the artifact.
           COLLECT_OK=1; COLLECT_SRC="$(pg_completed_dir)/$RUN_MARKER"
           PG_FINAL_SRC="$WORK/already.snap"
         else
           LEDGER_HIT="$(pg_ledger_lookup_clean "$RUN_MARKER")"
           PRIOR_OUT="${LEDGER_HIT%%$'\t'*}"
           PRIOR_SHA="${LEDGER_HIT#*$'\t'}"; [ "$PRIOR_SHA" = "$LEDGER_HIT" ] && PRIOR_SHA=""
           # Auto-recover from the ledger ONLY under a verified digest (gate #54 r3): a
           # pre-v0.28 row without one, or a box with no hash tool, cannot prove the mutable
           # path still holds the collected review — report its location for MANUAL recovery
           # instead of copying whatever occupies it. All v0.28+ collections have the
           # completed artifact anyway (checked above), so this fallback only ages out.
           # Snapshot FIRST, then verify the snapshot (gate #54 r4 P1): hashing the mutable
           # source and copying it later is a race — another run can overwrite a reused path
           # between the two. Only bytes whose digest matched are ever installed or returned;
           # the same-path case snapshots too, so the returned bytes ARE the verified ones.
           if [ -n "$PRIOR_OUT" ] && [ -n "$PRIOR_SHA" ] && [ -s "$PRIOR_OUT" ]; then
             SNAP="$WORK/ledger.snap"
             if cp "$PRIOR_OUT" "$SNAP" 2>/dev/null && pg_is_review "$SNAP" 2>/dev/null \
                && [ "$(pg_sha256 "$SNAP")" = "$PRIOR_SHA" ]; then
               COLLECT_OK=1; COLLECT_SRC="$PRIOR_OUT"
               PG_FINAL_SRC="$SNAP"
             else
               rm -f "$SNAP" 2>/dev/null
             fi
           fi
         fi
         if [ "$COLLECT_OK" = 1 ]; then
           SALVAGED=1
           echo "[oracle-review] this review was ALREADY collected (${COLLECT_SRC}); returning it idempotently — nothing spent, nothing lost." >&2
           # Same checked publication as every other success (gate #54 r9): done is set only
           # once $OUT verifiably holds the snapshot.
           pg_publish_out "$PG_FINAL_SRC" || pg_publish_fail "$PG_FINAL_SRC"
           pg_persist_result "$PG_FINAL_SRC"
           echo "RESULT_FILE=$RESULT_PATH"
           pg_status done "already collected; result: $RESULT_PATH"
           cat "$PG_FINAL_SRC"
           pg_finish 0
         fi
         if [ -n "$PRIOR_OUT" ]; then
           echo "ERROR: this review was already collected (ledger row exists) but cannot be returned automatically: the prior output ($PRIOR_OUT) is gone, unreadable, digest-mismatched, or carries no verifiable digest (pre-v0.28 row). Not a loss — recover it MANUALLY from that path, the PR comment/audit trail, or the ChatGPT conversation; do NOT spend a fresh slot for it." >&2
           pg_status failed "already collected; prior output unavailable or unverifiable ($PRIOR_OUT) — manual recovery, do NOT respend"
           pg_finish 6
         fi
         echo "ERROR: no conversation matches marker ${RUN_MARKER} after repeated confirmed misses, and no collected copy is ledgered (review lost, or collected by an engine <v0.27 that ledgered no marker)." >&2
         pg_status failed "harvest found no matching conversation (miss limit reached)"
         pg_finish 6
       fi
       echo "[oracle-review] conversation not found this pass (${MISS_VERDICT}); reservation kept fail-closed. Retry --harvest later." >&2
       pg_status in-progress "harvest miss (${MISS_VERDICT}); retry --harvest later"
       pg_finish 9 ;;
    *) # Runtime trouble (node crash, CDP outage, usage error) or a capture that failed
       # validation: NOT evidence the conversation is gone. Keep the reservation and the tab;
       # exit 3 = engine/browser trouble, safe to retry.
       echo "ERROR: harvest failed (salvage rc=${HARVEST_RC}); reservation and tab kept. Retry --harvest once the browser/CDP is healthy." >&2
       pg_status failed "harvest runtime error rc=${HARVEST_RC}; reservation kept"
       pg_finish 3 ;;
  esac
fi

# --- resolve repo + PR, assemble the diff (ground truth) ---
PR_URL=""; PR_NUM=""
if [ -n "$PR" ]; then
  if [[ "$PR" =~ ^https?:// ]]; then
    PR_URL="${PR%/}"; PR_NUM="${PR_URL##*/}"
    if [ -z "$REPO" ]; then
      NAME="$(printf '%s' "$PR_URL" | sed -E 's#https?://github.com/[^/]+/([^/]+)/pull/.*#\1#')"
      for base in "${PRO_GATE_REPOS_DIR:-$HOME/SITES}" "$HOME/src" "$HOME/code" "$HOME/dev"; do
        [ -d "$base/$NAME/.git" ] && { REPO="$base/$NAME"; break; }
      done
    fi
  else
    PR_NUM="$PR"
  fi
fi
if [ -n "$PR_NUM" ]; then
  PR_NUM="$(pg_pr_number_normalize "$PR_NUM")" || usage
fi
[ -n "$REPO" ] || REPO="$(pwd)"
cd "$REPO" || { echo "ERROR: repo dir not found: $REPO" >&2; pg_status failed "repo dir not found"; pg_finish 4; }
[ -n "$PR_URL" ] || PR_URL="$(gh pr view "$PR_NUM" --json url -q .url 2>/dev/null || echo "")"

# PR_KEY: repo-scoped identity for locks, reservations, and markers. PR numbers repeat across
# repositories; keying on the bare number let an in-progress repo-A#77 redirect a repo-B#77 gate
# to repo A's conversation (dogfood review P1, 2026-07-10). Derived from the PR URL when known,
# else from the git remote, else the checkout name; sanitized to the marker-safe charset.
REPO_SLUG=""
if [ -n "$PR_URL" ]; then
  REPO_SLUG="$(printf '%s' "$PR_URL" | sed -nE 's#https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\1-\2#p')"
fi
[ -n "$REPO_SLUG" ] || REPO_SLUG="$(git -C "$REPO" remote get-url origin 2>/dev/null \
  | sed -nE 's#.*[:/]([^/]+)/([^/]+?)(\.git)?$#\1-\2#p')"
[ -n "$REPO_SLUG" ] || REPO_SLUG="$(basename "$REPO")"
PR_KEY=""
[ -n "$PR_NUM" ] && PR_KEY="$(printf '%s-%s' "$REPO_SLUG" "$PR_NUM" | tr -c 'A-Za-z0-9.\n-' '-')"
# Keep a non-lossy identity alongside the historical safe filename key. It is intentionally
# absent when no canonical remote/PR URL can prove it; recovery must then ask for a marker.
PG_META_IDENT="$(pg_repo_identity_from_url "${PR_URL:-}" 2>/dev/null || pg_repo_identity_from_url "$(git -C "$REPO" remote get-url origin 2>/dev/null || true)" 2>/dev/null || true)"
PG_META_HOST=""; PG_META_OWNER=""; PG_META_REPO=""
[ -z "$PG_META_IDENT" ] || IFS=$'\t' read -r PG_META_HOST PG_META_OWNER PG_META_REPO <<< "$PG_META_IDENT"

# ROUND_KEY (v0.22): identity for the review round budget. PR runs use PR_KEY. --diff runs loop
# just as hard (ledger: 11 diff re-gates of one worktree in a day) but have no PR number, so
# they key on repo+branch: the unit a review->fix->re-review loop actually iterates on.
if [ -n "$PR_KEY" ]; then
  ROUND_KEY="$PR_KEY"
else
  ROUND_BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  # A detached checkout reports the literal ref name "HEAD" (typical for CI checkouts of a
  # bare SHA): one shared per-repo bucket would cross-cap unrelated diffs, so key those
  # per-commit instead. That under-caps a detached loop that rewrites its SHA every round,
  # but false-capping strangers is the worse failure for a default-on guard.
  if [ -z "$ROUND_BRANCH" ] || [ "$ROUND_BRANCH" = HEAD ]; then
    ROUND_BRANCH="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo detached)"
  fi
  # Disambiguate with a checksum of the RAW identity: sanitization is lossy ("feature/foo"
  # and "feature-foo" both sanitize to "feature-foo"), and colliding keys would share one
  # branch's budget and lock across unrelated branches (dogfood gate P1). The checksum input
  # must be UNSANITIZED end to end: the remote URL (or absolute checkout path) plus the raw
  # branch, never REPO_SLUG, whose owner/repo separator is itself already flattened
  # (a-b/c and a/b-c share a slug; dogfood gate round-2 P1). The human-readable prefix is
  # bounded so a deeply nested ref can never push the key past NAME_MAX, where state writes
  # fail and pg_lock silently proceeds unlocked.
  ROUND_RAW="$(git -C "$REPO" remote get-url origin 2>/dev/null || printf '%s' "$REPO"):${ROUND_BRANCH}"
  ROUND_SUM="$(printf '%s' "$ROUND_RAW" | cksum 2>/dev/null | awk '{print $1}')"
  ROUND_KEY="$(printf '%.120s%s-diff' "${REPO_SLUG}-${ROUND_BRANCH}" "${ROUND_SUM:+-$ROUND_SUM}" | tr -c 'A-Za-z0-9.\n-' '-')"
fi

if [ -z "$DIFF_FILE" ]; then
  DIFF_FILE="$WORK/pr.diff"
  gh pr diff "$PR_NUM" --patch > "$DIFF_FILE" 2>"$WORK/diff.err" || {
    echo "ERROR: gh pr diff $PR_NUM failed in $REPO: $(cat "$WORK/diff.err")" >&2; pg_status failed "gh pr diff failed"; pg_finish 5; }
fi

# An engine-fetched endpoint patch is the only normal path that earns full-PR proof. A caller
# patch may still be reviewed/recovered, but it is deliberately bare until scoped lineage is
# independently assembled; filtering below never changes these retained raw endpoint bytes.
PG_FULL_PR_PROVEN=0
if [ "$DIFF_IS_CALLER_SUPPLIED" = 0 ] && [ -n "$PR_NUM" ] \
   && [ -n "${PG_META_HOST:-}${PG_META_OWNER:-}${PG_META_REPO:-}" ] \
   && [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
  PG_FULL_PR_HEAD="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
  PG_FULL_PR_BASE="$(git -C "$REPO" merge-base HEAD '@{upstream}' 2>/dev/null || git -C "$REPO" rev-parse HEAD^ 2>/dev/null || true)"
  PG_FULL_PR_ENDPOINT_DIGEST="$(pg_sha256 "$DIFF_FILE")"
  PG_FULL_PR_RAW_DIGEST="$PG_FULL_PR_ENDPOINT_DIGEST"
  if [[ "$PG_FULL_PR_HEAD" =~ ^[0-9a-f]{40,64}$ ]] && [[ "$PG_FULL_PR_BASE" =~ ^[0-9a-f]{40,64}$ ]] \
     && [[ "$PG_FULL_PR_ENDPOINT_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
    PG_FULL_PR_PROVEN=1
  fi
fi

# --- diff hygiene: drop lockfiles/generated/vendored from the review payload so the Pro model
# spends its (finite, disconnect-exposed) thinking window on real code, not lockfile churn. ---
if [ -s "$DIFF_FILE" ] && [ "${PRO_GATE_DIFF_FILTER:-1}" = 1 ]; then
  FILTERED="$WORK/pr.filtered.diff"
  if pg_filter_diff "$DIFF_FILE" "$FILTERED" 2>"$WORK/excluded.raw" && [ -s "$FILTERED" ]; then
    # a path can appear in several per-commit patches (gh pr diff --patch) — dedupe for the report
    sort -u "$WORK/excluded.raw" 2>/dev/null > "$WORK/excluded.txt" || cp "$WORK/excluded.raw" "$WORK/excluded.txt"
    # grep -c prints "0" AND exits 1 on an empty file, so `|| echo 0` produced "0\n0"
    # (the "[: 0\n0: integer expression expected" noise on every run). Default only when empty.
    NEX="$(grep -c . "$WORK/excluded.txt" 2>/dev/null)"; [ -n "$NEX" ] || NEX=0
    if [ "$NEX" -gt 0 ] 2>/dev/null; then
      echo "[oracle-review] diff hygiene: excluded ${NEX} noise file(s) from the payload: $(paste -sd', ' "$WORK/excluded.txt" 2>/dev/null | cut -c1-200)" >&2
      DIFF_FILE="$FILTERED"
    fi
  fi
fi

DIFF_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo 0)
# v0.28 (#48): the change's file manifest, used to provenance-check any salvaged/reattached
# capture before accepting it as this change's review (and persisted beside an exit-9
# reservation so a later --harvest can run the same check).
pg_diff_paths "$DIFF_FILE" > "$WORK/diff.paths" 2>/dev/null || true
echo "[oracle-review] os=$OS mode=$MODE repo=$REPO pr=#${PR_NUM} url=${PR_URL:-n/a} diff_lines=$DIFF_LINES input=$INPUT" >&2

# --- v0.20/v0.24: diff-size handling. The deep think IS the product of this gate, and the engine
# already has a harvest path (exit 9 -> --harvest) that collects a review outlasting the slot
# window for FREE. So a large diff no longer refuses: past PRO_GATE_MAX_DIFF_LINES (the "cook"
# threshold, default 6000) the run proceeds and is EXPECTED to exit 9 (in-progress), then be
# harvested. Only past the hard ceiling PRO_GATE_DIFF_HARD_MAX (default 25000) does the engine
# still refuse up front (exit 11, BEFORE any lock/slot, no spend): a payload that large risks
# context overflow and is almost always a generated blob the diff filter missed. PRO_GATE_DIFF_GUARD=0
# disables even the hard ceiling (cook any size). Ledger origin: 984-1402-line diffs complete in
# 12-21 min; a ~10k-line diff reasoned 65 min (2026-07-09) then had to be harvested — which is
# exactly the path this now takes by default instead of refusing.
DIFF_WARN_LINES="${PRO_GATE_DIFF_WARN_LINES:-2500}"
DIFF_COOK_LINES="${PRO_GATE_MAX_DIFF_LINES:-6000}"
DIFF_HARD_MAX="${PRO_GATE_DIFF_HARD_MAX:-25000}"
# A nonnumeric override must not silently disable the size checks: with stderr suppressed, a bad
# value used to propagate through the reconciliation below and let ANY diff through. Validate every
# operand as a nonnegative integer, restoring each invalid threshold to its own documented default.
case "$DIFF_WARN_LINES" in ''|*[!0-9]*) DIFF_WARN_LINES=2500 ;; esac
case "$DIFF_COOK_LINES" in ''|*[!0-9]*) DIFF_COOK_LINES=6000 ;; esac
case "$DIFF_HARD_MAX"   in ''|*[!0-9]*) DIFF_HARD_MAX=25000 ;; esac
case "$DIFF_LINES"      in ''|*[!0-9]*) DIFF_LINES=0 ;; esac
# The hard ceiling can never sit below the cook threshold: raising PRO_GATE_MAX_DIFF_LINES past
# the ceiling floats the ceiling up with it (so that knob still means "refuse above N" when set
# high), and setting PRO_GATE_DIFF_HARD_MAX <= the cook threshold collapses the cook band, which
# restores the pre-v0.24 hard-refuse-at-N behavior for anyone who wants it.
[ "$DIFF_HARD_MAX" -ge "$DIFF_COOK_LINES" ] || DIFF_HARD_MAX="$DIFF_COOK_LINES"
# Cooking a large diff only pays off where the harvest path can collect a run that outlasts the
# slot window. Native browser mode (macOS) has NO marker-addressable harvest and creates no
# reservation, so a cooked large diff there spends a slot it can never collect (exit 6, quota
# wasted). Keep the hard refusal at the cook threshold when harvest is unavailable: no cook band on
# native. (An explicit PRO_GATE_DIFF_GUARD=0 still overrides everything, native included.)
# #50 item 5: the coercion below used to be silent — an operator-raised hard max was ignored
# with no signal. Say so once, before clamping, only when a configured value is actually cut.
if [ "$MODE" != remote-chrome ] && [ -n "${PRO_GATE_DIFF_HARD_MAX:-}" ] \
   && [ "$DIFF_HARD_MAX" -gt "$DIFF_COOK_LINES" ]; then
  echo "NOTE: native browser mode has no harvest path, so the configured hard max (${DIFF_HARD_MAX} lines) is capped to the cook threshold (${DIFF_COOK_LINES}) on this platform." >&2
fi
[ "$MODE" = remote-chrome ] || DIFF_HARD_MAX="$DIFF_COOK_LINES"
if [ "$DIFF_LINES" -gt "$DIFF_HARD_MAX" ] && [ "${PRO_GATE_DIFF_GUARD:-1}" = 1 ]; then
  if [ "$MODE" = remote-chrome ]; then
    echo "ERROR: diff is ${DIFF_LINES} lines (> PRO_GATE_DIFF_HARD_MAX=${DIFF_HARD_MAX}): beyond the size the Pro model can review even via the harvest path; not spending a slot." >&2
  else
    echo "ERROR: diff is ${DIFF_LINES} lines (> ${DIFF_HARD_MAX}): native browser mode has no harvest path, so a diff over the cook threshold cannot be collected if it outruns the review window; not spending a slot." >&2
  fi
  echo "  Scope the gate to what actually needs the final tier, then re-run with the patch:" >&2
  echo "    git -C <repo> diff <last-gated-sha>..<head> -- ':!*.lock' > delta.patch" >&2
  echo "    oracle-review.sh --diff delta.patch --repo <repo> --extra-files '<context globs>' --out <out>" >&2
  echo "  (Or split the PR; or raise PRO_GATE_DIFF_HARD_MAX / set PRO_GATE_DIFF_GUARD=0 to override.)" >&2
  pg_status oversized "diff ${DIFF_LINES} lines > hard max ${DIFF_HARD_MAX}; scope with --diff"
  pg_finish 11
elif [ "$DIFF_LINES" -gt "$DIFF_COOK_LINES" ]; then
  echo "[oracle-review] NOTE: diff is ${DIFF_LINES} lines (> PRO_GATE_MAX_DIFF_LINES=${DIFF_COOK_LINES}): a payload this size usually reasons past the slot window. Proceeding — the deep review is the point; expect exit 9 (in-progress) and collect it with --harvest (no new slot spent). To narrow instead, scope with --diff to the unreviewed delta." >&2
elif [ "$DIFF_LINES" -gt "$DIFF_WARN_LINES" ]; then
  echo "[oracle-review] WARNING: diff is ${DIFF_LINES} lines (> ${DIFF_WARN_LINES}); large diffs risk exceeding the Pro review window: consider scoping with --diff to the unreviewed delta." >&2
fi

ORACLE_BIN="${PRO_GATE_ORACLE_BIN:-oracle}"
TIMEOUT_BIN="${PRO_GATE_TIMEOUT_BIN:-timeout}"
# Internal seam (like the two above): the run-log tee whose clean drain authorizes a transcript
# proof. Overridable so a regression can inject a FAILING tee — PATH injection cannot reach it,
# because pg_augment_path re-prepends the system paths before this pipeline ever runs.
TEE_BIN="${PRO_GATE_TEE_BIN:-tee}"
if [[ "$TIMEOUT_BIN" == */* ]]; then
  [ -x "$TIMEOUT_BIN" ] || { echo "ERROR: configured timeout executable not found: $TIMEOUT_BIN" >&2; pg_status failed "timeout missing"; pg_finish 3; }
else
  pg_have "$TIMEOUT_BIN" || { echo "ERROR: coreutils timeout not installed" >&2; pg_status failed "timeout missing"; pg_finish 3; }
fi
if [[ "$ORACLE_BIN" == */* ]]; then
  [ -x "$ORACLE_BIN" ] || { echo "ERROR: configured oracle executable not found: $ORACLE_BIN" >&2; pg_status failed "oracle missing"; pg_finish 3; }
else
  pg_have "$ORACLE_BIN" || { echo "ERROR: oracle not installed (pnpm add -g @steipete/oracle)" >&2; pg_status failed "oracle missing"; pg_finish 3; }
fi

# --- build the review prompt (the product) ---
# RUN_MARKER (v0.15, pro-gate PR#5 review P1): a per-attempt correlation id
# embedded in the prompt, so the CDP probe/salvage match THIS run's
# conversation tab and never a leftover tab from an earlier review of the
# same PR (which would suppress the retry and serve a stale review for a
# new head). The marker lands in the user message, hence in the tab's
# innerText, without asking the model to echo anything.
# v0.22 (dogfood gate P1): embed ROUND_KEY, not PR_KEY. It is identical for PR runs, but it
# gives --diff runs a real per-change identity instead of the shared literal "diff", so their
# exit-9 reservations can redirect same-branch re-runs to harvest like PR runs always could.
RUN_MARKER="pg-run-${ROUND_KEY:-diff}-$(date +%s)-$$"
# The marker is minted before queue/slot acquisition, but recovery metadata is published only
# together with the authoritative charge (the adjacent pg_round_record + charged
# pg_run_meta_write below, near pg_round_record's call site). An attempt that never charges a
# round (round-capped, per-change-lock-timeout, deferred, oversized, ...) must never mint a
# run-meta record: an uncharged attempt has nothing to recover, and a stray sidecar for it would
# poison PR/URL recovery with a candidate that no reservation or ledger row backs. This sidecar
# is never removed with a reservation or completed artifact.
# v0.28 (gate #54 r8): oracle/reattach/salvage capture into a PROCESS-PRIVATE file from the
# outset; the caller's $OUT is publication-only, written once after acceptance. Two runs whose
# callers share one --out (same bare PR number in different repos, retries, orchestrator
# reuse) can no longer swap each other's bytes into the validation window.
CAPTURE_OUT="$WORK/capture.md"
PROMPT_FILE="$WORK/prompt.md"
RUNLOG="$WORK/oracle.log"
# Each run_oracle invocation publishes a private transcript + digest only after its tee drains
# successfully. The shared RUNLOG remains the live diagnostic stream, while these immutable
# captures let retry/refund accounting distinguish a trustworthy no-match from missing output.
ORACLE_LOG_TRANSCRIPTS=()
ORACLE_LOG_PROOFS=()
{
  # (The run-naming title line is PREPENDED after the per-change lock is held — see below.
  # Computing r<N> here raced: a queued same-change run would prebuild a duplicate label.)
  # Lead with the @GitHub connector tag + an explicit directive (belt-and-suspenders: oracle
  # pastes the prompt in one shot, so @GitHub is a recognized hint, not a bound mention pill;
  # ORACLE_CHATGPT_URL can pin a connector-bound Project for true binding).
  if [ "$INPUT" = "connector" ] || [ "$INPUT" = "both" ]; then
    [ -n "$PR_URL" ] && cat <<EOF
@GitHub — use the GitHub connector for anything GitHub-related in this review. Fetch this pull request and read its full diff plus the surrounding code, callers, tests, and history directly from GitHub via the connector (do not answer from memory): $PR_URL

EOF
  fi
  cat <<EOF
You are the FINAL, highest-tier code reviewer for a pull request that has ALREADY been through automated review tiers (Claude correctness/security/maintainability personas and a cloud bug+security scan) and their fixes have been applied. The cheap, obvious issues are already gone.

Your job is to find what those tiers MISSED — go deep:
- logic errors and incorrect assumptions; intent-vs-implementation mismatches
- subtle edge cases, off-by-one, null/empty/boundary handling
- race conditions, ordering, idempotency, partial-failure and retry behavior
- security holes (authz, injection, SSRF, secret handling, unsafe deserialization)
- data integrity (migrations, transactions, constraints, irreversible/lossy ops)
- broken invariants, resource leaks, error-swallowing, performance cliffs at scale

Be skeptical, specific, and concrete. Prefer a few HIGH-CONFIDENCE real defects over a long list of style nits.

Cite a concrete <file>:<line> for EVERY finding — if you cannot point to a specific changed line, do not raise it.
Do NOT flag: style/formatting/naming; anything CI, linters, or type-checkers already enforce; generated files or lockfiles; pre-existing issues unrelated to this change; or speculative/theoretical problems with no demonstrated impact path.
EOF
  if [ "$INPUT" = "bundle" ] || [ "$INPUT" = "both" ]; then
    cat <<EOF

The AUTHORITATIVE change is the attached unified diff "pr.diff" (ground truth — review EVERY changed hunk). Do not assume; if the diff contradicts what the connector shows, trust the diff for what changed.
EOF
  fi
  if [ -n "$CONFIRM_FILE" ]; then
    cat <<'EOF'

THIS IS A CONFIRMING PASS: this change was already reviewed once and fixes were applied. The previous review is attached as "prior-review.md". BEFORE anything else, verify EVERY P0 and P1 finding in that prior review against the CURRENT code and list each one as either RESOLVED (with the file:line of the fix) or STILL-PRESENT (report it again as a finding). Only then report genuinely NEW findings per the standard format. Do not re-litigate a prior finding whose fix is present but shaped differently than you would have chosen.
EOF
  fi
  cat <<'EOF'

OUTPUT FORMAT — output ONLY findings, nothing else, each exactly:

[Pn] <file>:<line> — <one-line issue>
  Why it's a real problem: <concise reasoning>
  Confidence: <high|medium|low>
  Suggested fix: <concrete change>

where Pn is one of: P0 (critical / blocker / data-loss / security), P1 (major bug), P2 (minor), P3 (nit).
Group by severity, P0 first. If a severity has no findings, write "Pn: none".
If and only if your verdict is NEEDS-DISCUSSION, emit 2-8 choice lines immediately before the final VERDICT line, each exactly: CHOICE: <safe-id> | <label> | <consequence>. Use a unique safe-id containing only letters, digits, dot, underscore, colon, slash, plus, or hyphen; label is 1-120 printable characters and consequence is 1-240 printable characters. Do not emit CHOICE lines for SHIP or FIX-FIRST. Do not add fields or extra pipes.
End with one final line:  VERDICT: SHIP | FIX-FIRST | NEEDS-DISCUSSION  — <=15 word reason.
EOF
  echo
  # v0.28 (#55): positive run-binding. The marker was previously "ignore and do not mention";
  # now the model must ECHO it on the VERDICT line, proving the answer was written for THIS
  # prompt (a foreign or stale conversation's review cannot carry it). It sits ON the VERDICT
  # line because the collector's extraction ends at that line; the engine strips it before
  # returning output. Non-compliance degrades gracefully to the path-overlap check.
  echo "(run marker: ${RUN_MARKER} — internal correlation id. Do not discuss it, but append it verbatim to the end of your final VERDICT line, i.e.: VERDICT: <your verdict> (run marker: ${RUN_MARKER}))"
} > "$PROMPT_FILE"

# --- assemble --file attachments (bundle mode) ---
FILES=()
if [ "$INPUT" = "bundle" ] || [ "$INPUT" = "both" ]; then
  FILES+=("$DIFF_FILE")
  if [ -n "$EXTRA_GLOB" ]; then
    while IFS= read -r f; do [ -f "$f" ] && FILES+=("$f"); done < <(compgen -G "$EXTRA_GLOB" 2>/dev/null || true)
  fi
fi
# --confirm attaches the prior review REGARDLESS of input mode: the confirming instructions
# in the prompt reference it by the stable name "prior-review.md".
if [ -n "$CONFIRM_FILE" ]; then
  cp "$CONFIRM_FILE" "$WORK/prior-review.md" 2>/dev/null \
    && FILES+=("$WORK/prior-review.md") \
    || { echo "ERROR: could not stage --confirm file: $CONFIRM_FILE" >&2; pg_status failed "confirm file unreadable"; pg_finish 2; }
fi
FILE_ARGS=(); for f in "${FILES[@]:-}"; do [ -n "$f" ] && FILE_ARGS+=(--file "$f"); done

# Route through a connector-bound ChatGPT Project when configured (pre-binds GitHub).
URL_ARGS=()
if [ -n "${ORACLE_CHATGPT_URL:-}" ] && [ "${ORACLE_CHATGPT_URL}" != "https://chatgpt.com/" ]; then
  URL_ARGS+=(--chatgpt-url "$ORACLE_CHATGPT_URL")
fi

# Platform browser flags: WSL/Linux attaches to the Xvfb Chrome; macOS lets oracle drive Chrome.
ENGINE_ARGS=(-e browser)
[ "$MODE" = "remote-chrome" ] && ENGINE_ARGS+=(--remote-chrome "127.0.0.1:${PORT}")
# Keep oracle from auto-archiving the conversation. Its default (auto) archives a "successful"
# one-shot and navigates the tab off the conversation, which strips the RUN_MARKER from the
# open tabs and blinds BOTH the pre-retry liveness probe (-> false "dead submission" -> a
# double-spending retry) and the last-resort CDP salvage. We own the conversation lifecycle:
# leave the tab intact so probe/salvage can always find it, then let the marker-owned organizer
# archive/close only after durable validation in pg_finish. Override with PRO_GATE_BROWSER_ARCHIVE.
ENGINE_ARGS+=(--browser-archive "${PRO_GATE_BROWSER_ARCHIVE:-never}")

# --- Bound concurrent Pro review runs against the single ChatGPT account ---
# DEFAULT IS SERIALIZED (1). The 2026-07-03 throttle incident showed one account under
# 3 parallel runs (plus their salvage page-loads) trips ChatGPT's anti-scraping limiter
# ("temporarily limited access to your conversations"). PRO_GATE_MAX_CONCURRENCY is the
# CEILING; v0.19's ramp governor (pg_ramp_level) decides the EFFECTIVE slots — earned up
# one level per PRO_GATE_RAMP_STREAK clean runs, dropped to 1 on any throttle. Excess
# callers QUEUE on the semaphore. A SEPARATE per-PR guard ensures the SAME pr is never
# under two simultaneous reviews (that would double-spend a slot on one diff). NOTE:
# oracle itself caps concurrent browser tabs (default 3; since 0.16.0 configurable via the
# ORACLE_BROWSER_MAX_CONCURRENT_TABS env). A ceiling above oracle's cap just queues inside
# oracle unless that env raises the cap to match (the ChatGPT account throttle, not oracle's
# tab cap, is the real limiter, so raising it only helps a genuinely tolerant account).
LOCKFILE="${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}"
LOCK_WAIT="${PRO_GATE_LOCK_WAIT:-2400}"
MAX_CONC="${PRO_GATE_MAX_CONCURRENCY:-1}"
EFF_CONC="$(pg_ramp_level "$MAX_CONC")"

# Housekeeping: per-PR lock files are 0-byte and used to accumulate forever. Sweep ones
# untouched for >24h — any legitimate holder finishes within the ~35 min hard cap. Same for
# per-marker harvest locks (v0.20.2 dogfood left one stale for 10h; flock holders keep the
# file's inode alive, so deleting an unheld file is always safe).
find "$(dirname "$LOCKFILE")" -maxdepth 1 -name "$(basename "$LOCKFILE").pr-*" -mmin +1440 -delete 2>/dev/null || true
find "${PRO_GATE_HARVEST_LOCK_DIR:-$PRO_GATE_HOME/harvest-locks}" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
find "$(pg_active_dir)" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
find "$(pg_manifest_dir)" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
# Terminal dispositions survive long enough to make cleanup idempotent across both existing
# recovery clocks. Cleanup-pending proof is never swept merely because it aged.
pg_attempt_disposition_sweep
# #50 item 4: conversation-urls memos get the same time-based hygiene as every other state
# dir. 14 days dwarfs every recovery window (reservation TTL 6h; pending/ holds real bytes)
# while still covering late manual recovery of a weeks-old run.
find "$PRO_GATE_HOME/conversation-urls" -maxdepth 1 -type f -mmin +20160 -delete 2>/dev/null || true
# Canonical title memos serve the same late-harvest lifecycle as URL memos. Sequence counters
# remain exempt below because they prevent server-side title reuse across idle windows.
find "$(pg_conversation_title_dir)" -maxdepth 1 -type f -mmin +20160 -delete 2>/dev/null || true
# #50 item 8: per-run diagnostic logs are swept on the same 14-day horizon. An ALLOWLIST of
# run-log shapes, not a *.log denylist (#63 gate P1: a *.log-minus-autoupdate.log sweep would
# unlink logs/daemon.{out,err}.log, which the macOS launchd plist keeps OPEN for the live
# daemon — the path dies while the invisible inode eats disk until restart). Matched shapes:
# pg-run-* (v0.27+, incl. harvest sub-logs) and the pre-v0.27 '<owner>-<repo>-<pr>-<epoch>'
# names, whose 10-digit epoch suffix no service log can carry.
find "$PRO_GATE_HOME/logs" -maxdepth 1 -type f \
  \( -name 'pg-run-*.log' -o -name '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].log' \) \
  -mmin +20160 -delete 2>/dev/null || true
# title-seq counters are deliberately NOT swept: pg_title_seq_next documents them as
# monotonic and never window-pruned (gate #57 r4) — a pruned counter would re-title a
# post-idle round r1 while the old r1 conversation still exists server-side, recreating the
# stale-verdict ambiguity the ordinal exists to prevent. 1-byte files; unbounded is fine.
# The foreign-conversation blacklist (salvage-nonmatching.txt) is deliberately NOT
# compacted here: it has concurrent writers in two languages (engines' pg_provenance_reject
# and the Node salvage children), and any read→rename compaction can silently drop an
# append unless every writer shares one cross-platform lock — flock is absent on stock
# macOS and a pgrep guard is only a point-in-time check (#63 gate r1+r2). A dropped line
# can replay a provenance-rejected conversation in legacy nonce mode, so correctness beats
# tidiness: the file stays append-only (~16KB/week observed; revisit only if that changes).
# #50 item 1 (backfill): scratch dirs leaked by pre-trap engines and kill -9 runs. Only our
# own naming patterns, only dirs old enough (7d) that every recovery pointer into them has
# long expired (reservation TTL 6h; PG_KEEP_FINAL messages say "copy it out now").
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d \( -name 'pro-review.*' -o -name 'pg-status.*' \) \
  -mmin +10080 -exec rm -rf {} + 2>/dev/null || true
# Round-budget state (v0.22): entries self-prune on write, but a key never gated again keeps
# its file (and its 0-byte .lock) forever. Sweep files untouched for longer than the rounds
# window (every entry inside is expired), floored at 24h so a short window never deletes a
# lock a live process might hold (same safety argument as the sweeps above).
ROUND_SWEEP_MIN=$(( $(pg_round_window_secs) / 60 ))
[ "$ROUND_SWEEP_MIN" -lt 1440 ] && ROUND_SWEEP_MIN=1440
find "$(pg_rounds_dir)" -maxdepth 1 -type f ! -name '*.seq' -mmin "+${ROUND_SWEEP_MIN}" -delete 2>/dev/null || true
# Sweep idle chatgpt.com ROOT tabs (leaked by killed pre-submission runs; the marker-based
# close can't see them, and each is a renderer eating the review box's memory headroom).
# Only when NO oracle CLI is <120s old: a younger one may still be pre-navigation on a root
# tab. Age check engine-side (CDP can't see processes). PRO_GATE_TAB_SWEEP=0 disables.
if [ "$MODE" = remote-chrome ] && [ "${PRO_GATE_TAB_SWEEP:-1}" = 1 ] && command -v node >/dev/null 2>&1; then
  YOUNGEST_ORACLE=999999
  while read -r ORACLE_AGE; do
    case "$ORACLE_AGE" in ''|*[!0-9]*) continue;; esac
    [ "$ORACLE_AGE" -lt "$YOUNGEST_ORACLE" ] && YOUNGEST_ORACLE="$ORACLE_AGE"
  done < <(pgrep -f 'bin/oracle-cli\.js' 2>/dev/null | xargs -r -I{} ps -o etimes= -p {} 2>/dev/null | tr -d ' ')
  if [ "$YOUNGEST_ORACLE" -ge 120 ]; then
    timeout 30 node "$SELF/cdp-salvage.mjs" --sweep-root - 25 "$PORT" 2>&1 | sed 's/^/[oracle-review] /' >&2 || true
  fi
fi

# Reconcile durable reservations from earlier exit-9 runs before dispatch. A same-change
# reservation redirects this invocation to HARVEST instead of spending a second slot. This is
# enforced in the engine (not merely caller docs), so a killed headless caller cannot double-
# spend on its next daemon cycle. v0.22 (dogfood gate P1): keyed by ROUND_KEY so --diff runs
# redirect too; before, their reservations carried the shared literal "diff" and a same-branch
# re-run could submit a duplicate while the first review was still generating. Native mode has
# no marker-addressable CDP, so no reservations are created there.
if [ "$MODE" = remote-chrome ]; then
  pg_reservation_reconcile "$SELF/cdp-salvage.mjs" "$PORT"
  RESERVED_MARKER="$(pg_reservation_find_pr "$ROUND_KEY" 2>/dev/null || true)"
  if [ -n "$RESERVED_MARKER" ]; then
    # Publish the RESERVED conversation's marker, not this invocation's fresh one: callers
    # harvest whatever the status JSON names (dogfood review P1: the fresh marker names a
    # conversation that does not exist).
    RUN_MARKER="$RESERVED_MARKER"
    echo "[oracle-review] ${ROUND_KEY} already has an in-progress Pro conversation (${RESERVED_MARKER}): harvesting it instead of submitting again." >&2
    pg_status in-progress "existing reservation ${RESERVED_MARKER}; harvest required"
    echo "  ${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh --harvest '${RESERVED_MARKER}' --out '${OUT}' --timeout 20m" >&2
    pg_finish 9
  fi
fi

# A matching run-granted effect is still advisory at this pre-lock boundary. Rebuild the
# normalized facts before either the round guard or per-change lock can lead to a browser slot.
[ "${REVIEW_DECISION_EXECUTE:-0}" != 1 ] || pg_fresh_dispatch_require_run pre-lock

# v0.22/v0.31: review round budget. Refuse to spend ANOTHER Pro slot on a PR/branch whose
# budget is exhausted inside the rolling window: unbounded review->fix->re-review loops
# burned 10-16 slots on single PRs (8h+ gates, queue starvation). Since v0.31 the budget is
# a trajectory-aware governor (base 3, +1 earned per strictly-shrinking re-review, ceiling 8,
# early stop after 2 consecutive non-shrinking re-reviews; an explicitly set
# PRO_GATE_MAX_ROUNDS_PER_PR pins the legacy flat cap — see pg_round_guard). Checked AFTER
# the reservation redirect above: an in-progress conversation harvests for FREE and must
# never be blocked by the budget. Exit 12, NO quota spent; escalate remaining findings to a
# human instead of re-running.
round_capped() {  # $1 = reason
  # Severity-aware stop note: the budget still refuses the run (severity labels are the
  # reviewer's own claims, exactly the signal observed to oscillate across rounds), but a cap
  # hit while the change's LAST completed review reported P0s is the one case a human may
  # want to grant PRO_GATE_FORCE_ROUND=1, so say it loudly instead of burying it.
  local sev="" last_p0="" last_p1="" note="" pfd inflight=0 used elapsed_h totals
  if sev="$(pg_round_last_severity "$ROUND_KEY")"; then
    last_p0="${sev%% *}"; last_p1="${sev##* }"
    note="; last completed review: ${last_p0} P0 / ${last_p1} P1 unconfirmed by a re-review"
  fi
  # ledger-timing-split R2: state rounds used + total wall clock spent on this change alongside
  # the severity note above. pg_round_guard's refusal ($1) already carries the scored
  # trajectory, but it ran as "ROUND_REASON=\"\$(pg_round_guard ...)\"" — a command
  # substitution — so the PG_ROUND_* globals it set are gone by the time we get here (same
  # pitfall the --status renderer's "score IN THIS SHELL" comment guards against). Re-score
  # directly, in-shell, rather than re-deriving totals from $1's text.
  pg_round_score "$ROUND_KEY"
  used="$(pg_round_count "$ROUND_KEY")"
  elapsed_h="$(pg_hours_1dp "$PG_ROUND_ELAPSED_SECS")"
  totals="${used} rounds; ~${elapsed_h}h recorded across ${PG_ROUND_SCORED} scored round(s)"
  note="${note}; ${totals}"
  # pg_round_guard's refusal already carries the scored trajectory. Do not re-read .hist here:
  # the reason becomes the status detail below, and a second parse can only duplicate I/O.
  # Non-blocking probe: a same-change run holding the per-change lock right now means the
  # sidecar note above describes the round BEFORE the one in flight; its completion may
  # change the picture, so tell the human to re-read before granting a forced round (the
  # refusal itself stays correct either way: a recorded spend never un-spends). Skipped when
  # THIS process owns the lock (post-lock re-check site): flock on a second fd would report
  # our own lock as a foreign in-flight run.
  if [ "${CHANGE_LOCK_HELD:-0}" = 1 ]; then
    inflight=0
  elif pg_have flock; then
    if { exec {pfd}>>"${LOCKFILE}.pr-${ROUND_KEY}"; } 2>/dev/null; then
      flock -n "$pfd" 2>/dev/null || inflight=1
      eval "exec ${pfd}>&-" 2>/dev/null
    fi
  elif [ -d "${LOCKFILE}.pr-${ROUND_KEY}.d" ]; then
    inflight=1
  fi
  # Gated on $sev (a SEVERITY claim is being shown), not on $note: since the totals summary
  # above is now appended unconditionally, $note is never empty and would otherwise always
  # pass this check regardless of whether a severity claim is present.
  [ "$inflight" = 1 ] && [ -n "$sev" ] && note="${note} (a same-change review is in flight NOW: re-check this note after it completes)"
  echo "ERROR: ${1}; not spending another Pro review slot on this change." >&2
  echo "  ${totals}." >&2
  if [ "${last_p0:-0}" -gt 0 ] 2>/dev/null; then
    echo "  ATTENTION: OPEN P0. The most recent completed review reported ${last_p0} P0 finding(s) that no re-review has confirmed fixed. If the fixes have landed, this is the case PRO_GATE_FORCE_ROUND=1 exists for: surface it to a human now." >&2
    [ "$inflight" = 1 ] && echo "  (A same-change review is in flight right now; wait for it before deciding, its result may already settle these.)" >&2
  fi
  echo "  A gate that keeps cycling review->fix->re-review is not converging: escalate the remaining findings to a human instead." >&2
  echo "  Deliberate override for ONE run: PRO_GATE_FORCE_ROUND=1. Tunables: PRO_GATE_ROUNDS_BASE/PRO_GATE_ROUNDS_CEILING (governor), PRO_GATE_MAX_ROUNDS_PER_PR (pins the legacy flat cap), PRO_GATE_ROUNDS_WINDOW; PRO_GATE_ROUND_GUARD=0 disables." >&2
  pg_status round-capped "${1}${note}"
  pg_finish 12
}
if ! ROUND_REASON="$(pg_round_guard "$ROUND_KEY")"; then
  round_capped "$ROUND_REASON"
fi

# Per-change guard (acquire BEFORE a slot, so same-change callers serialize without holding a
# scarce slot). Keyed by ROUND_KEY: the repo-scoped PR_KEY for PR runs (bare numbers collide
# across repositories; the lock filename is unchanged for them), repo+branch for --diff runs.
# v0.22: --diff runs serialize here too. Without this, concurrent same-branch diff gates raced
# the round-budget check-then-record window and overshot the cap (review P0: 5 concurrent
# diff runs all passed a cap of 1), and two parallel reviews of one branch are the same
# double-spend the per-PR lock exists to stop.
echo "[oracle-review] per-change guard for ${PR_NUM:+pr #}${PR_NUM:-this diff} (${ROUND_KEY}; serializes same-change reviews)..." >&2
pg_status waiting-pr-lock
if ! pg_lock "${LOCKFILE}.pr-${ROUND_KEY}" "$LOCK_WAIT"; then
  echo "ERROR: timed out after ${LOCK_WAIT}s — ${ROUND_KEY} is already under review elsewhere." >&2
  pg_status failed "per-change lock timeout"
  pg_finish 7
fi
CHANGE_LOCK_HELD=1   # round_capped's in-flight probe must not mistake our own lock for a peer
# The previous same-change process may have exited 9 while we waited and written a reservation
# just before releasing this flock. Re-check now that we own the per-change lock; otherwise
# this waiter would immediately submit a duplicate review.
RESERVED_MARKER="$(pg_reservation_find_pr "$ROUND_KEY" 2>/dev/null || true)"
if [ -n "$RESERVED_MARKER" ]; then
  RUN_MARKER="$RESERVED_MARKER"
  echo "[oracle-review] ${ROUND_KEY} became in-progress while waiting (${RESERVED_MARKER}): harvest required, not resubmitting." >&2
  pg_status in-progress "existing reservation ${RESERVED_MARKER}; harvest required"
  pg_finish 9
fi
# A queued effect can be superseded by completed, active, reserved, or unknown-fate work while
# it waits for this same existing change lock. Re-reduce before continuing to the slot queue.
[ "${REVIEW_DECISION_EXECUTE:-0}" != 1 ] || pg_fresh_dispatch_require_run under-lock

# Round-budget re-check for ALL runs, now that we own the per-change lock: the same-change
# run(s) this waiter queued behind may have consumed the last round during the (up to 40 min)
# wait. Check-then-record is race-free from here on because the lock is held until exit.
if ! ROUND_REASON="$(pg_round_guard "$ROUND_KEY")"; then
  round_capped "$ROUND_REASON (spent while this run waited on the per-change lock)"
fi

# v0.29 (#49 phase 1, gate #57 r2): the LITERAL FIRST LINE of the prompt names the run so
# ChatGPT's auto-titler is biased toward a legible sidebar title, r<N> distinguishing review
# ROUNDS of one change. Computed HERE — under the per-change lock, after the round-guard
# recheck — because rounds record only under this lock: the count is stable for our change,
# so a queued same-change run can no longer prebuild a duplicate label. The ordinal comes
# from a monotonic, never-window-pruned sequence (gate #57 r3: window counts repeat labels
# across expiry). The engine's own machinery is unaffected (marker matching, never title).
if TITLE_SEQ="$(pg_title_seq_next "$ROUND_KEY")"; then
  TITLE_ROUND="r$TITLE_SEQ"
else
  # Unique fallback when the sequence store is unwritable (gate #57 r4 P2): the marker's
  # pid tail cannot collide with ordinal labels, so duplicates are impossible either way.
  TITLE_ROUND="r?${RUN_MARKER##*-}"
  echo "[oracle-review] NOTE: title sequence store unwritable; using unique fallback label $TITLE_ROUND." >&2
fi
if [ -n "$PR_NUM" ]; then
  TITLE_LINE="$(printf 'pro-gate review: PR #%s %s [%s]' "$PR_NUM" "$TITLE_ROUND" "$REPO_SLUG")"
else
  TITLE_LINE="$(printf 'pro-gate review: %s %s' "${ROUND_KEY:-diff}" "$TITLE_ROUND")"
fi
# Normalize once so the prompt and marker-addressed memo carry byte-identical display text.
# Generated titles are already one line; the collapse is defense-in-depth for unusual repo data.
TITLE_LINE="$(printf '%s' "$TITLE_LINE" | tr '\r\n\t' '   ' | awk '{$1=$1; print}' | cut -c 1-180)"
if ! { { printf '%s\n\n' "$TITLE_LINE"; cat "$PROMPT_FILE"; } > "$PROMPT_FILE.titled" 2>/dev/null \
       && mv -f "$PROMPT_FILE.titled" "$PROMPT_FILE" 2>/dev/null; }; then
  rm -f "$PROMPT_FILE.titled" 2>/dev/null
  echo "[oracle-review] WARNING: could not prepend the canonical conversation title to the prompt." >&2
fi
if ! pg_conversation_title_write "$RUN_MARKER" "$TITLE_LINE"; then
  echo "[oracle-review] WARNING: could not publish the canonical conversation-title memo; browser rename will be skipped safely." >&2
fi

echo "[oracle-review] acquiring a review slot (effective ${EFF_CONC} of ceiling ${MAX_CONC}; waits up to ${LOCK_WAIT}s if all busy)..." >&2
pg_status waiting-slot "effective ${EFF_CONC} / ceiling ${MAX_CONC}"
# v0.19.1 (pro-gate self-review P1): re-read the ramp level every wait slice — a run that
# queued at level 3 must NOT acquire slot 3 after a concurrent throttle dropped the level
# to 1 mid-wait. Short pg_lock_n slices keep the wait responsive to governor changes.
SLOT_DEADLINE=$(( $(date +%s) + LOCK_WAIT ))
SLOT_OK=0
SLOT_HELD=""
while :; do
  EFF_CONC="$(pg_ramp_level "$MAX_CONC")"
  # Durable reservations occupy real account capacity even though their wrapper process has
  # exited. Slot-tagged reservations EXCLUDE their exact slot from acquisition (shrinking the
  # scan range instead overbooked capacity when a lower-numbered slot freed: dogfood review
  # P1); legacy/out-of-range reservations shrink the range.
  if ! pg_reservation_guard_acquire; then sleep 3; continue; fi
  SLOT_PLAN="$(pg_reservation_slot_plan "$EFF_CONC")"
  SCAN_MAX="${SLOT_PLAN%%|*}"
  SCAN_EXCLUDE="$(printf '%s' "$SLOT_PLAN" | cut -d'|' -f2)"
  # Gate on the plan's AVAILABLE count (field 3), never on the scan bound: a bound of 1 whose
  # only slot is excluded is an EMPTY set, and gating on the bound spent every wait slice
  # calling pg_lock_n against an impossible plan while reporting "all slots busy" (#82).
  SCAN_AVAIL="$(printf '%s' "$SLOT_PLAN" | cut -d'|' -f3)"
  # Nonblocking while holding the short handoff guard: waiting here would prevent an active
  # run from writing its reservation before releasing its process slot (writer waits 10s).
  # One immediate scan gives an atomic plan+acquire decision; the outer loop releases the
  # guard and retries.
  if [ "${SCAN_AVAIL:-0}" -gt 0 ] 2>/dev/null && pg_lock_n "$LOCKFILE" "$SCAN_MAX" 0 "$SCAN_EXCLUDE"; then
    # Keep the acquired process slot, release only the short reservation handoff guard.
    SLOT_HELD="$PG_SLOT_ACQUIRED"
    pg_reservation_guard_release; SLOT_OK=1; break
  fi
  pg_reservation_guard_release
  # Name what actually holds capacity. An operator staring at a free-looking account and an idle
  # browser cannot tell "another review is generating" from "a finished review was never
  # collected" — and only the second is theirs to fix, for free (#82).
  if [ "${SCAN_AVAIL:-0}" -le 0 ] 2>/dev/null \
     && { [ -z "${SLOT_BLOCK_LOGGED:-}" ] || [ $(( $(date +%s) - ${SLOT_BLOCK_LOGGED:-0} )) -ge 300 ]; }; then
    SLOT_BLOCK_LOGGED="$(date +%s)"
    pg_report_capacity_holders "$EFF_CONC"
  fi
  if [ "$(date +%s)" -ge "$SLOT_DEADLINE" ]; then break; fi
  sleep 3
done
if [ "$SLOT_OK" != 1 ]; then
  if [ "$(pg_reservation_holding_count 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; then
    echo "ERROR: timed out after ${LOCK_WAIT}s — 0 of ${EFF_CONC} effective slots free; capacity is held by uncollected review(s), not by running ones." >&2
    pg_report_capacity_holders "$EFF_CONC"
  else
    echo "ERROR: timed out after ${LOCK_WAIT}s — all ${EFF_CONC} review slots are busy with running reviews." >&2
  fi
  pg_status failed "slot timeout"
  pg_finish 7
fi
# Slot acquisition is not submission authority. A completed/recoverable predecessor, moved
# target/evidence, or governor change that arrived in the slot wait must win before charging.
[ "${REVIEW_DECISION_EXECUTE:-0}" != 1 ] || pg_fresh_dispatch_require_run post-slot-pre-charge

# ledger-timing-split (R1/R3): the run leaves the queue HERE — a slot is held, not yet
# generating. One site, hit exactly once per invocation (retries below reuse this same slot).
LAUNCH_EPOCH="$(date +%s)"

# The oracle CLI's own --timeout has been observed NOT to fire while it waits on a ChatGPT
# tab that never starts thinking (a "dead submission" squatted a browser slot for 3.5h on
# 2026-07-02). The engine therefore enforces its own bounds:
#   hard cap   — coreutils timeout at TIMEOUT + PRO_GATE_TIMEOUT_GRACE (default +120s)
#   stall      — no oracle log output for PRO_GATE_STALL_SECS (default 600) and no findings
#   no-think   — still "no thinking status detected" after PRO_GATE_NOTHINK_SECS (default 600)
# A watchdog kill returns 124; the caller's salvage + guarded-retry path takes over. Dead
# submissions never consumed the Pro thinking window, so the retry is not a
# double-spend.
HARD_SECS=$(( $(pg_dur_secs "$TIMEOUT") + ${PRO_GATE_TIMEOUT_GRACE:-120} ))
STALL_SECS="${PRO_GATE_STALL_SECS:-600}"
NOTHINK_SECS="${PRO_GATE_NOTHINK_SECS:-600}"

run_oracle() {  # $1 = browser model strategy (select|current|ignore)
  local strategy="$1" job started size last_size last_change now last_line prc watchdog_sleep_secs
  local transcript="$WORK/oracle.${#ORACLE_LOG_TRANSCRIPTS[@]}.log"
  local proof="$WORK/oracle.${#ORACLE_LOG_TRANSCRIPTS[@]}.sha256"
  local producer_file="${transcript%.log}.pid" producer drained
  watchdog_sleep_secs="$(pg_test_watchdog_sleep_secs)"
  ORACLE_LOG_TRANSCRIPTS+=("$transcript")
  ORACLE_LOG_PROOFS+=("$proof")
  rm -f "$transcript" "$proof" "$producer_file"
  # v0.16 (#873 lesson): a watchdog-killed attempt leaves its session record
  # status "running", and oracle's duplicate-prompt guard then blocks the
  # engine's OWN retry of the same prompt/slug. Retries only happen after the
  # probe judged the submission truly dead (no conversation tab, quota not
  # spent), so forcing a fresh session on retry is exactly oracle's documented
  # escape hatch for this state.
  local force_args=()
  [ "${attempt:-0}" -gt 0 ] && force_args+=(--force)
  # Oracle runs as its OWN reapable job inside the pipeline, and publishes its pid. The watchdog
  # kills only that producer, so tee always reaches EOF and reports whether it captured everything
  # (gate #72 r10 P1) — killing tee instead leaves a prefix that is immutable but NOT complete.
  ( ( set -m   # job control: the producer leads its OWN process group, so one signal reaches
                # `timeout`, Oracle, and the browser client it drives (gate #72 r11 P1).
      stdbuf -oL -eL "$TIMEOUT_BIN" --signal=TERM --kill-after=30 "$HARD_SECS" \
        "$ORACLE_BIN" "${ENGINE_ARGS[@]}" -m "$MODEL" \
        --browser-model-strategy "$strategy" ${force_args[0]:+"${force_args[@]}"} \
        --slug "pro gate review pr ${PR_NUM:-diff}" \
        "${URL_ARGS[@]}" "${FILE_ARGS[@]}" \
        -p "$(cat "$PROMPT_FILE")" \
        --no-notify --timeout "$TIMEOUT" \
        --write-output "$CAPTURE_OUT" 2>&1 &
      _producer=$!
      set +m
      # If the pid never reaches the sidecar the watchdog cannot target this group, so the blunt
      # fallback signals THIS shell instead. Take the producer's group down with us rather than
      # letting the wrappers die and reparent a live Oracle onto init.
      trap 'pg_signal_producer TERM "$_producer"; sleep 2; pg_signal_producer KILL "$_producer"' TERM HUP INT
      printf '%s\n' "$_producer" > "$producer_file.tmp" 2>/dev/null \
        && mv -f "$producer_file.tmp" "$producer_file" 2>/dev/null \
        || rm -f "$producer_file.tmp" 2>/dev/null
      wait "$_producer" ) \
        | "$TEE_BIN" -a "$RUNLOG" "$transcript" | stdbuf -oL sed 's/^/[oracle] /' >&2
    _pipeline_status=("${PIPESTATUS[@]}")
    # Publish ONLY when tee drained to EOF AND Oracle exited on its OWN. tee's success proves we
    # captured the stream; the producer's status proves the stream was finished. A producer that was
    # timed out or signalled (124, or 128+signal) was interrupted mid-flight, and an interrupted Node
    # process loses queued stdout — so a lifecycle line it had already written can be missing.
    # This covers the killer the watchdog never sees: the inner TIMEOUT_BIN reaching HARD_SECS while
    # output still flows, which exits through the normal wait path (gate #72 r13 P1).
    if [ "${_pipeline_status[1]:-1}" -eq 0 ] && [ "${_pipeline_status[0]:-1}" -lt 124 ]; then
      pg_publish_log_proof "$transcript" "$proof" || true
    fi
    [ "${_pipeline_status[1]:-1}" -eq 0 ] && [ "${_pipeline_status[2]:-1}" -eq 0 ] \
      || exit 1
    exit "${_pipeline_status[0]:-1}"
  ) &
  job=$!
  started=$SECONDS; last_size=-1; last_change=$SECONDS
  while kill -0 "$job" 2>/dev/null; do
    sleep "$watchdog_sleep_secs"
    [ -s "$CAPTURE_OUT" ] && continue   # findings are landing — let the run finish undisturbed
    size=$(wc -c < "$RUNLOG" 2>/dev/null) || size=0
    if [ "$size" != "$last_size" ]; then last_size="$size"; last_change=$SECONDS; fi
    now=$SECONDS
    last_line="$(tail -n 1 "$RUNLOG" 2>/dev/null || true)"
    if [ $(( now - last_change )) -ge "$STALL_SECS" ]; then
      echo "[oracle-review] watchdog: oracle silent for ${STALL_SECS}s with no findings — killing this attempt (salvage/retry follows)." >&2
      pg_status watchdog-killed "stall ${STALL_SECS}s"
    elif [ $(( now - started )) -ge "$NOTHINK_SECS" ] && printf '%s' "$last_line" | grep -q "no thinking status detected"; then
      # v0.14: oracle's thinking detection can lag reality (ChatGPT UI drift,
      # first seen PR pushbot#863 2026-07-02: killed a run that was 11m into a
      # live Pro thought). Before declaring the submission dead, ask
      # Chrome whether a conversation tab matching this PR exists. If it does,
      # the run is LIVE: quota is already spent and a resubmit would
      # double-spend. Kill the blind CLI anyway (frees the browser slot) but
      # flag it so the caller skips reattach+retry and goes straight to the
      # outcome-based CDP salvage with the full remaining budget.
      # v0.18: probe exit 5 = ChatGPT throttle interstitial. The submission's
      # fate is UNKNOWN (it may have landed before the throttle), so treat it
      # like live: never resubmit, and let the post-cooldown salvage decide.
      prc=2
      if command -v node >/dev/null 2>&1; then
        node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT" >/dev/null 2>>"$RUNLOG"; prc=$?
      fi
      if [ "$prc" -eq 0 ]; then
        echo "[oracle-review] watchdog: no-think after $(( now - started ))s BUT a conversation tab matches this PR — submission is LIVE, detection missed. Freeing the slot; CDP salvage will collect the review (retry suppressed: quota already spent)." >&2
        LIVE_CONVERSATION=1
        pg_status live-detected "no-think probe found the conversation"
      elif [ "$prc" -eq 5 ]; then
        echo "[oracle-review] watchdog: ChatGPT is rate-limiting this account — killing this attempt; retry suppressed, cooldown started (salvage after the pause)." >&2
        THROTTLED=1
        pg_status throttled "interstitial during no-think probe"
      else
        echo "[oracle-review] watchdog: ChatGPT never started thinking after $(( now - started ))s — dead submission; killing this attempt (salvage/retry follows)." >&2
        pg_status watchdog-killed "no-think ${NOTHINK_SECS}s"
      fi
    else
      continue
    fi
    # Stop ONLY Oracle and let the rest of the pipeline finish on its own: tee then reads EOF,
    # flushes, and exits 0, which is what lets the subshell publish a proof that means "complete",
    # not merely "immutable". Killing tee here instead would silently drop anything still buffered
    # between Oracle and tee — including a browser-lifecycle line printed just before the kill —
    # and that lost line is the difference between a charged send and a duplicate retry + refund.
    producer=""
    [ -r "$producer_file" ] && IFS= read -r producer < "$producer_file" 2>/dev/null
    if [ -n "$producer" ]; then
      pg_signal_producer TERM "$producer"
      drained=0
      while [ "$drained" -lt 30 ] && kill -0 "$job" 2>/dev/null; do sleep 1; drained=$((drained + 1)); done
    fi
    # Refused to drain (or the pid was never published): publish NOTHING, so the attempt stays
    # charged rather than resting on a possibly-truncated capture. Take Oracle's process group down
    # FIRST and reap it: the wrappers are only its parents, and killing them alone would reparent a
    # live Oracle that keeps driving the browser after this run's slot and locks are released
    # (gate #72 r11 P1). The inner shell's TERM trap covers the case where no pid was published.
    if kill -0 "$job" 2>/dev/null; then
      pg_signal_producer KILL "$producer"
      pkill -TERM -P "$job" 2>/dev/null; kill -TERM "$job" 2>/dev/null
      sleep 5
      pg_signal_producer KILL "$producer"
      pkill -KILL -P "$job" 2>/dev/null; kill -KILL "$job" 2>/dev/null
    fi
    wait "$job" 2>/dev/null
    # Unconditional, even when the pipeline drained cleanly: `timeout` exits on TERM, so a
    # signal-ignoring Oracle can be left holding the browser while its wrappers die tidily and the
    # drain looks successful. This attempt is over — nothing from its group may outlive it.
    pg_signal_producer KILL "$producer"
    # A KILLED ATTEMPT NEVER CERTIFIES ITS TRANSCRIPT. Killing the producer also closes its pipe, so
    # tee can reach EOF and the subshell can publish a proof — but we interrupted Oracle, and a Node
    # process loses queued stdout on SIGKILL, so "tee succeeded" no longer implies "we saw
    # everything Oracle sent". Rather than infer completeness from kill paths (three gate rounds,
    # three races: #72 r10/r11/r12), revoke it outright. `wait` above reaped the only publisher, so
    # nothing can re-create this. Refunds therefore require Oracle to have EXITED on its own —
    # exactly the send/upload failure the refund was built for. A killed attempt stays charged.
    rm -f "$proof" "$proof.tmp" 2>/dev/null
    return 124
  done
  wait "$job"
}

# --- spend the slot: health-gate -> run -> salvage -> one guarded retry ---
# A precious Pro review slot is spent only when the box is fit; a dropped connection is first
# SALVAGED (the answer may have finished server-side), and only a truly-lost run is retried once.
# Exit 8 = deferred (no slot spent); exit 6 = ran but produced nothing after salvage + retry.
SLUG_BASE="pro-gate-review-pr-${PR_NUM:-diff}"
REATTACH_TIMEOUT="${PRO_GATE_REATTACH_TIMEOUT:-150}"
MAX_RETRIES="${PRO_GATE_MAX_RETRIES:-1}"
BACKOFF="${PRO_GATE_RETRY_BACKOFF:-20}"
LIVE_CONVERSATION=0
THROTTLED=0
CLOUDFLARE=0

pg_oracle_prompt_submitted_state() { # verified transcript proof -> true|false from exact Oracle session metadata
  local transcript="$1" proof="$2" session meta root state expected actual
  [ -f "$transcript" ] && [ ! -L "$transcript" ] && [ -f "$proof" ] && [ ! -L "$proof" ] || return 1
  expected="$(tr -d '[:space:]' < "$proof" 2>/dev/null)"; actual="$(pg_sha256 "$transcript" 2>/dev/null || true)"
  [ -n "$expected" ] && [ "$actual" = "$expected" ] || return 1
  session="$(sed -nE 's/^Session: ([A-Za-z0-9._-]+)$/\1/p' "$transcript" | tail -1)"
  case "$session" in ''|*[!A-Za-z0-9._-]*) return 1;; esac
  root="${ORACLE_HOME_DIR:-$HOME/.oracle}"; meta="$root/sessions/$session/meta.json"
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ "$(wc -c < "$meta" 2>/dev/null)" -le 1048576 ] || return 1
  state="$(jq -r --arg id "$session" --arg marker "$RUN_MARKER" '
    select(.id==$id) | select(.options.prompt|type=="string" and contains($marker)) |
    [.browser.runtime.promptSubmitted?,.error.details.runtime.promptSubmitted?]
    | map(select(type=="boolean")) | unique | select(length==1) | .[0]
  ' "$meta" 2>/dev/null)" || return 1
  case "$state" in true|false) printf '%s\n' "$state";; *) return 1;; esac
}

# pg_attempt_provably_unsubmitted <marker-scan-rc>: the ONE shared bar for a no-spend
# retry/refund. A clean marker scan, no remembered URL, no throttle/live evidence, and a stable
# browser remain mandatory. Every Oracle invocation must have a complete digest-verified transcript
# bound to structured session metadata that says Send was never dispatched. Missing, conflicting,
# or promptSubmitted=true metadata is ambiguous and therefore remains charged.
pg_attempt_provably_unsubmitted() {
  local scan_rc="${1:-}" i state
  [ "$scan_rc" = 4 ] || return 1
  [ "${LIVE_CONVERSATION:-0}" != 1 ] || return 1
  [ "${THROTTLED:-0}" != 1 ] || return 1
  [ ! -f "$PRO_GATE_HOME/conversation-urls/${RUN_MARKER}" ] || return 1
  ! pg_browser_restarted_midrun "$RUN_START" >/dev/null || return 1
  [ "${#ORACLE_LOG_TRANSCRIPTS[@]}" -gt 0 ] || return 1
  for i in "${!ORACLE_LOG_TRANSCRIPTS[@]}"; do
    state="$(pg_oracle_prompt_submitted_state "${ORACLE_LOG_TRANSCRIPTS[$i]}" "${ORACLE_LOG_PROOFS[$i]}" 2>/dev/null || true)"
    [ "$state" = false ] || return 1
  done
  return 0
}

attempt=0
while :; do
  if ! GATE_REASON="$(pg_health_gate)"; then
    # v0.18: exit 8 ("deferred, NO slot spent") is only true before the first attempt.
    # On a retry iteration a slot HAS been spent — abandoning to exit 8 here would skip
    # the salvage of a possibly-completed review. Stop retrying and salvage instead.
    if [ "$attempt" -eq 0 ]; then
      echo "ERROR: not spending a Pro review slot (${GATE_REASON})." >&2
      case "$GATE_REASON" in
        *memory*|*thrashing*|*swap*)
          echo "  Your machine is low on memory, so the Pro review browser can't run reliably right now. Nothing was spent. Close some apps / browser tabs / other AI tools to free memory, then retry." >&2 ;;
        *)
          echo "  Deferred (no slot spent). Retry once the box settles, or run on macOS (native Chrome)." >&2 ;;
      esac
      pg_status deferred "$GATE_REASON"
      pg_finish 8
    fi
    echo "[oracle-review] not retrying (${GATE_REASON}) — falling through to salvage." >&2
    # v0.18.1 (pro-gate self-review P1): when the gate failure IS the throttle cooldown,
    # take the throttle path — otherwise the final salvage would render conversations
    # against the still-throttled account immediately, bypassing the protective pause.
    case "$GATE_REASON" in *"throttle cooldown"*) THROTTLED=1 ;; esac
    break
  fi

  # v0.22: this invocation is now committed to spending a slot: record its round (once; the
  # guarded retry below is the same round, and pre-launch exits above never record).
  # v0.27: and publish the active-run record at the same moment, so --status can see a live
  # (or wrapper-dead-but-generating) run before any reservation or ledger row exists.
  # PG_ROUND_SPEND_EPOCH (set by pg_round_record) is this run's charge time — the stamp every
  # trajectory row for this round must carry (#66 gate r3 P1). Keep it for the completion path
  # and for the reservation an exit-9 hands to a later harvest process.
  [ "$attempt" -eq 0 ] && {
    if [ "${REVIEW_DECISION_EXECUTE:-0}" = 1 ]; then
      # Marker-bound pre-charge state is durable BEFORE the round write. Any persistence failure
      # below remains recover-only; no browser process can be started without all three records.
      if ! pg_active_write pre-charge 0; then
        PG_PRESERVE_STATE=1
        echo "ERROR: could not publish pre-charge active state; not submitting." >&2
        pg_status failed "pre-charge active state unavailable; recovery required"
        pg_finish 3
      fi
      pg_round_record "$ROUND_KEY"; RUN_SPEND_EPOCH="$PG_ROUND_SPEND_EPOCH"
      if [ -z "${RUN_SPEND_EPOCH:-}" ]; then
        PG_PRESERVE_STATE=1
        echo "ERROR: round charge could not be persisted; active state preserved and not submitting." >&2
        pg_status failed "round charge unavailable; recovery required"
        pg_finish 3
      fi
      if ! pg_active_write charged "$RUN_SPEND_EPOCH"; then
        PG_PRESERVE_STATE=1
        echo "ERROR: charged active state could not be persisted; not submitting." >&2
        pg_status failed "charged active state unavailable; recovery required"
        pg_finish 3
      fi
      if ! pg_run_meta_write "$RUN_MARKER" "$PG_META_HOST" "$PG_META_OWNER" "$PG_META_REPO" \
        "$ROUND_KEY" "$PR_NUM" "$OUT" "$RUN_SPEND_EPOCH"; then
        PG_PRESERVE_STATE=1
        echo "ERROR: charged run metadata could not be persisted; active state preserved and not submitting." >&2
        pg_status failed "charged run metadata unavailable; recovery required"
        pg_finish 3
      fi
      if ! pg_install_effect_input_binding; then
        PG_PRESERVE_STATE=1
        echo "ERROR: charged input binding could not be installed; preserving active recovery state and not submitting." >&2
        pg_status failed "charged input binding unavailable; recovery required"
        pg_finish 3
      fi
      pg_active_write input-bound "$RUN_SPEND_EPOCH" || {
        PG_PRESERVE_STATE=1
        echo "ERROR: input-bound active state could not be persisted; not submitting." >&2
        pg_status failed "input-bound active state unavailable; recovery required"
        pg_finish 3
      }
    else
      pg_round_record "$ROUND_KEY"; RUN_SPEND_EPOCH="$PG_ROUND_SPEND_EPOCH"
      # pg_round_record is the sole authority for charged-spend ordering. Preserve that epoch in
      # run-meta before any later exit-9 reservation can retire, so recovery never reorders queued
      # rounds by their earlier marker-mint time.
      if [ -n "${RUN_SPEND_EPOCH:-}" ] && [ -n "${PG_META_HOST:-}${PG_META_OWNER:-}${PG_META_REPO:-}" ]; then
        pg_run_meta_write "$RUN_MARKER" "$PG_META_HOST" "$PG_META_OWNER" "$PG_META_REPO" \
          "$ROUND_KEY" "$PR_NUM" "$OUT" "$RUN_SPEND_EPOCH" 2>/dev/null \
          || echo "[oracle-review] WARNING: could not persist recovery charge metadata for $RUN_MARKER" >&2
      fi
      pg_active_write charged "$RUN_SPEND_EPOCH"
      # Charge ordering is marker-bound: a proven endpoint run is not submitted until its immutable
      # input relation is installed. A failure leaves the charged active record recoverable rather
      # than launching an unbound attempt; bare/scoped callers retain existing non-merge behavior.
      if ! pg_install_full_pr_input_binding "$RUN_MARKER"; then
        PG_PRESERVE_STATE=1
        echo "ERROR: charged full-PR input binding could not be installed; preserving active recovery state and not submitting." >&2
        pg_status failed "charged input binding unavailable; recovery required"
        pg_finish 3
      fi
    fi
  }

  # A non-blocking heads-up when memory is tight but not blocking (the gate is deliberately
  # conservative, so a swap-heavy box with moderate free RAM still runs). Warns low-memory users
  # BEFORE a long review that a mid-run browser restart is the likely failure mode. Advisory only.
  if [ "$attempt" -eq 0 ] && MEM_NOTE="$(pg_mem_pressure_note)"; then
    echo "[oracle-review] NOTE: ${MEM_NOTE}. Proceeding; if the review fails, this is the likely reason — free memory and retry." >&2
  fi

  echo "[oracle-review] launching the final-tier Pro review (attempt $((attempt + 1)), oracle timeout $TIMEOUT, hard cap ${HARD_SECS}s, stall/no-think watchdog ${STALL_SECS}s/${NOTHINK_SECS}s)..." >&2
  pg_status launching "strategy ${PRO_GATE_MODEL_STRATEGY:-current}"
  [ "${REVIEW_DECISION_EXECUTE:-0}" != 1 ] || pg_active_write submitted "$RUN_SPEND_EPOCH" || {
    PG_PRESERVE_STATE=1
    echo "ERROR: submission handoff state could not be persisted; not submitting." >&2
    pg_status failed "submission handoff state unavailable; recovery required"
    pg_finish 3
  }
  : > "$RUNLOG"; rm -f "$CAPTURE_OUT"   # clear prior-attempt diagnostics/capture before arming background work
  # v0.32: capture the URL AND apply the exact canonical title early. One bounded background
  # organizer shortly after submission proves marker ownership, remembers the conversation URL,
  # and renames through ChatGPT's rendered UI. It never archives or closes a live/in-progress
  # conversation. Open-tab scan only in the common case; non-fatal; bounded; remote-chrome only.
  # PRO_GATE_EARLY_PROBE_SECS retains its existing delay/disable contract.
  EARLY_PROBE_DELAY="${PRO_GATE_EARLY_PROBE_SECS:-75}"
  case "$EARLY_PROBE_DELAY" in ''|*[!0-9]*) EARLY_PROBE_DELAY=75;; esac
  # Armed on EVERY attempt (gate #54 P1): a dead first attempt commonly outlives the probe
  # window, and a successful retry would otherwise generate with no early pointer at all.
  if [ "$MODE" = remote-chrome ] && [ "$EARLY_PROBE_DELAY" -gt 0 ] \
     && command -v node >/dev/null 2>&1; then
    # Close inherited descriptors FIRST: the subshell inherits every open fd, including the
    # per-change flock and the account-slot fd — without this, the sleeping probe holds the
    # lock AND a Pro slot for up to ~165s after the engine exits, blocking the next same-change
    # run (found the hard way: the whole test suite serialized behind it).
    # A retry supersedes the previous attempt's sleeping helper. Its subshell may remain asleep,
    # but the revoked lease prevents any later CDP scan, scratch render, or UI mutation.
    rm -f "$WORK"/early-organizer.*.lease 2>/dev/null || true
    EARLY_ORGANIZER_LEASE="$WORK/early-organizer.${attempt}.$$.lease"
    : > "$EARLY_ORGANIZER_LEASE"
    ( i=3; while [ "$i" -le 40 ]; do eval "exec $i>&-" 2>/dev/null; i=$((i + 1)); done
      sleep "$EARLY_PROBE_DELAY"
      pg_organize_chat rename "$EARLY_ORGANIZER_LEASE" "$WORK/run.log" 90 60
    ) >/dev/null 2>&1 &
  fi
  run_oracle "${PRO_GATE_MODEL_STRATEGY:-current}" || true
  # UI fallback: the requested model was not selectable in the picker (select strategy) -> retry
  # pinned to the account's already-selected model. oracle's wording varies ("model selector",
  # "model picker", "model switcher", "Unable to find model option matching ..."), so match them
  # all: without the switcher/option forms a `select` mismatch failed the WHOLE run instead of
  # falling back (dogfood 2026-07-17, PR #32: `select` + gpt-5.6 emitted "Unable to find model
  # option matching 'GPT-5.6 Sol' in the model switcher" and released the slot without submitting,
  # then the engine burned ~32 min on a pointless salvage). Skip when the primary run was already
  # `current` (a second current pass changes nothing).
  if [ ! -s "$CAPTURE_OUT" ] && [ "${PRO_GATE_MODEL_STRATEGY:-current}" != current ] \
     && grep -qiE "model selector|model.?picker|model switcher|unable to find model option" "$RUNLOG" 2>/dev/null; then
    echo "[oracle-review] requested model not selectable in the picker; retrying with --browser-model-strategy current (reviews whichever model your ChatGPT account already has selected)..." >&2
    run_oracle current || true
  fi
  # Accept ONLY a real review, not just any non-empty file — a corrupted capture (e.g. a stray "A")
  # must NOT pass as success; it falls through to salvage + retry below.
  if pg_is_review "$CAPTURE_OUT"; then
    echo "[oracle-review] findings written ($(wc -c < "$CAPTURE_OUT" 2>/dev/null) bytes)." >&2; break
  fi
  if [ -s "$CAPTURE_OUT" ]; then
    echo "[oracle-review] discarding a non-review capture ($(wc -c < "$CAPTURE_OUT" 2>/dev/null) bytes, no VERDICT/Pn markers) — will salvage/retry." >&2
  fi

  # Cloudflare / ChatGPT anti-bot challenge: oracle detects the "Just a moment" interstitial and
  # logs "Cloudflare anti-bot page detected" / throws stage=cloudflare-challenge. The submission
  # did NOT land, so a retry only hammers the challenge and deepens the block (the headless,
  # concurrency-driven trigger that a warm interactive session never hits). Treat it like the
  # throttle: back off. Write the account cooldown the health gate already honors, drop the ramp
  # to 1 (concurrency is the real trigger), suppress the retry, and skip salvage (nothing landed).
  # Match oracle's own Cloudflare emissions ("Cloudflare anti-bot page detected" logger line and
  # the "Cloudflare challenge detected ..." thrown-error message / cloudflare-challenge stage).
  # Guarded by `! pg_is_review`, so a successful review that merely discusses Cloudflare (its text
  # also lands in the log) can never be misread as a block.
  if ! pg_is_review "$CAPTURE_OUT" \
     && grep -qiE 'Cloudflare (anti-bot page|challenge) detected|cloudflare-challenge' "$RUNLOG" 2>/dev/null; then
    echo "[oracle-review] ChatGPT/Cloudflare anti-bot challenge detected; backing off (account cooldown + concurrency drop), NOT retrying (a resubmit only deepens the block)." >&2
    CLOUDFLARE=1
    # The challenge PROVES no prompt reached the model: refund this invocation's round so a
    # few challenge hits inside the window cannot exit-12-block a change that spent nothing
    # (dogfood gate round-2 P1). Unknown-fate paths (throttle, watchdogs) never refund.
    pg_fresh_dispatch_refund \
      || echo "[oracle-review] charged marker state could not be proven for refund; preserving it for recovery." >&2
    pg_status cloudflare "anti-bot challenge; cooldown started"
    cdf="${PRO_GATE_COOLDOWN_FILE:-$PRO_GATE_HOME/throttle.cooldown}"
    { printf '%s cloudflare-challenge (pr %s)\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "${PR_NUM:-diff}" > "$cdf"; } 2>/dev/null || true
    break
  fi

  # v0.14: a live conversation means the quota is already spent. Reattach is
  # useless here (it binds the pre-kill tab target, which goes stale) and a
  # resubmit would double-spend — skip both and let the outcome-based CDP
  # salvage below collect the review when it finishes.
  # v0.18: same for a throttle kill — the submission's fate is unknown, and
  # both reattach and a resubmit would hit the throttled account again.
  if [ "$LIVE_CONVERSATION" = 1 ] || [ "$THROTTLED" = 1 ]; then
    break
  fi

  # No output. The generation may have COMPLETED server-side after a dropped Chrome connection —
  # try a bounded salvage (never hangs) before spending another slot. Capture the slug oracle
  # actually used (it may differ from SLUG_BASE on a collision, e.g. ...-pr-804-2).
  SLUG="$(grep -oE 'oracle session [A-Za-z0-9._-]+' "$RUNLOG" 2>/dev/null | tail -1 | awk '{print $NF}')"
  [ -n "$SLUG" ] || SLUG="$SLUG_BASE"
  echo "[oracle-review] no output — bounded salvage via reattach (session ${SLUG}, ${REATTACH_TIMEOUT}s)..." >&2
  pg_status salvaging "reattach ${SLUG}"
  if pg_reattach_render "$SLUG" "$CAPTURE_OUT" "$REATTACH_TIMEOUT"; then
    REATTACHED=1   # v0.28: browser-matched capture — subject to the provenance choke below
    CAPTURE_SOURCE=reattach   # gate #54 r3: reattach ALSO sets SALVAGED, so the memo-
                              # invalidation guard must discriminate by source, not SALVAGED
    echo "[oracle-review] salvaged a completed review via reattach." >&2
    SALVAGED=1
    break
  fi

  attempt=$((attempt + 1))
  [ "$attempt" -gt "$MAX_RETRIES" ] && break
  # v0.16.1 (self-review P1): the retry passes --force, which bypasses
  # oracle's duplicate-prompt guard — previously the LAST defense against
  # resubmitting a live-but-silent run. The no-think path probes before its
  # kill, but stall and hard-cap kills reach here unprobed. Probe RIGHT
  # BEFORE every retry: a conversation tab matching this run's marker means
  # the quota is spent, so suppress the retry and let the CDP salvage below
  # collect the review instead. (If Chrome itself is unreachable the probe
  # errors and the retry proceeds — a server-side-completed run cannot be
  # salvaged through a dead browser anyway.)
  # CI ambiguity fixtures alone may shorten this otherwise-30s CDP absence wait.
  PRE_RETRY_PROBE_SECS="$(pg_test_pre_retry_probe_secs)"
  PRC=2
  if command -v node >/dev/null 2>&1; then
    node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" "$PRE_RETRY_PROBE_SECS" "$PORT" >/dev/null 2>>"$RUNLOG"; PRC=$?
  fi
  if [ "$PRC" -eq 0 ]; then
    echo "[oracle-review] pre-retry probe found a live conversation for this run — retry suppressed (quota already spent); CDP salvage will collect it." >&2
    LIVE_CONVERSATION=1
    pg_status live-detected "pre-retry probe found the conversation"
    break
  elif [ "$PRC" -eq 5 ]; then
    echo "[oracle-review] pre-retry probe hit the ChatGPT throttle — retry suppressed; cooldown started (salvage after the pause)." >&2
    THROTTLED=1
    pg_status throttled "interstitial during pre-retry probe"
    break
  fi
  # FAIL CLOSED: a non-0/5 probe is inconclusive unless the shared no-spend predicate succeeds.
  # Oracle browser-lifecycle lines OR an incomplete/unverifiable lifecycle transcript mean a send
  # may have reached ChatGPT, so they suppress a duplicate retry regardless of commit metadata.
  if ! pg_attempt_provably_unsubmitted "$PRC"; then
    echo "[oracle-review] pre-retry probe could not prove the prompt stayed unsubmitted; Oracle browser lifecycle evidence or incomplete log capture makes its fate ambiguous/spent, so retry is suppressed and CDP salvage gets the final chance." >&2
    LIVE_CONVERSATION=1
    pg_status live-detected "submission fate ambiguous/spent; retry suppressed"
    break
  fi
  echo "[oracle-review] pre-retry probe found no conversation AND no evidence Oracle reached its browser lifecycle (genuine pre-browser failure). Retrying once after ${BACKOFF}s + a health re-check..." >&2
  pg_status retry-wait "backoff ${BACKOFF}s"
  sleep "$BACKOFF"
done

# v0.21 (R4/R5): capture the model oracle resolved for THIS run from its "Model selection
# evidence: ...; resolved=<label>; status=<st>; ..." line in $RUNLOG, plus the selection status.
# BEST-EFFORT by design: dogfooding PR #20 showed oracle 0.15.2 emits this line at COMPLETION
# (right after it releases the browser slot), NOT early at model selection. So on the fresh
# in-progress/exit-9 path the watchdog kills oracle before the line is emitted and capture yields
# nothing (empty -> role-based fallback, and the reservation persists no model). On the fresh
# SUCCESS path the line is present; under `current` a model that was already selected reports
# resolved=(unavailable); status=already-selected (still healthy). resolved=(unavailable) or
# absence degrades to empty. Mirrors the $RUNLOG session-slug recovery grep above.
if [ -f "$RUNLOG" ]; then
  EVIDENCE_LINE="$(grep -a 'Model selection evidence:' "$RUNLOG" 2>/dev/null | tail -1)"
  if [ -n "$EVIDENCE_LINE" ] && [ "${EVIDENCE_LINE#*resolved=}" != "$EVIDENCE_LINE" ]; then
    RM="${EVIDENCE_LINE#*resolved=}"; RM="${RM%%;*}"; RM="${RM%.}"
    RM="$(printf '%s' "$RM" | tr -d '\t\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$RM" in ''|'(unavailable)') RESOLVED_MODEL="" ;; *) RESOLVED_MODEL="$RM" ;; esac
    if [ "${EVIDENCE_LINE#*status=}" != "$EVIDENCE_LINE" ]; then
      ST="${EVIDENCE_LINE#*status=}"; ST="${ST%%;*}"; ST="${ST%.}"
      MODEL_STATUS="$(printf '%s' "$ST" | tr -d '\t\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    fi
  fi
fi

# v0.21 (R6): soft, advisory downgrade warning (see pg_derive_model_warn). Fires on a weak-model
# denylist match or a genuinely unconfirmable model (killed before oracle reported, or none
# captured); it stays SILENT on the benign `current`+already-selected steady state so it does not
# cry wolf on healthy default runs. A WARN log line plus a status-file marker the composer shows;
# it NEVER changes the exit code.
MODEL_WARN="$(pg_derive_model_warn "$RESOLVED_MODEL" "$MODEL_STATUS")"
[ -n "$MODEL_WARN" ] && echo "[oracle-review] WARNING: ${MODEL_WARN}." >&2

# v0.13: last-resort CDP tab salvage. oracle (historically <=0.15.x; hardened upstream in
# 0.16.0; the 2026-07 GPT-5.6 UI re-broke it) can fail to DETECT thinking after ChatGPT UI
# drift even though the submission landed: the
# no-think watchdog then kills a LIVE run, and reattach harvests a stale tab
# target ("Assistant turns: 0") while the real conversation finishes in
# another tab. Before declaring failure, read the review straight off the
# conversation tab's DOM, matched by PR marker so concurrent review slots
# cannot cross-contaminate. First seen: pushbot PR #863, 2026-07-02. This is a first-class
# capture path, not a rare fallback: whenever oracle's detection lags the live UI it collects
# essentially every review (100% of clean runs 2026-07-22 → 08-03 landed via salvage/harvest).
# Skip salvage entirely on a Cloudflare challenge: the submission never landed (nothing to
# collect), and rendering conversation pages against a challenged account only deepens the block.
if ! pg_is_review "$CAPTURE_OUT" && [ "${CLOUDFLARE:-0}" != 1 ] && command -v node >/dev/null 2>&1; then
  # Live conversation (v0.14 probe hit): the review may still be thinking, so
  # wait with the full hard-cap budget; otherwise a short window suffices.
  # v0.30.1: the non-live window is its own knob. It used to ride PRO_GATE_STALL_SECS, so
  # tuning the stall watchdog DOWN (justified: healthy oracle prints every 30s, and the
  # 2026-08-03 timing analysis showed true silence only on hung runs) silently halved the
  # recovery window for stall/disconnect kills too. Default preserves the historical tie.
  SALVAGE_SECS="${PRO_GATE_SALVAGE_SECS:-$STALL_SECS}"; [ "$LIVE_CONVERSATION" = 1 ] && SALVAGE_SECS="$HARD_SECS"
  # v0.18: after a throttle hit, pause before the single polite salvage pass —
  # rendering the conversation immediately just re-triggers the limiter. The
  # salvage itself exits 5 fast if the account is still throttled.
  if [ "$THROTTLED" = 1 ]; then
    THROTTLE_PAUSE="${PRO_GATE_THROTTLE_PAUSE:-300}"
    echo "[oracle-review] throttled — pausing ${THROTTLE_PAUSE}s before one polite salvage attempt..." >&2
    pg_status throttled "pausing ${THROTTLE_PAUSE}s before salvage"
    sleep "$THROTTLE_PAUSE"
    SALVAGE_SECS="$HARD_SECS"
  fi
  echo "[oracle-review] last-resort CDP tab salvage (marker ${RUN_MARKER}, up to ${SALVAGE_SECS}s)..." >&2
  pg_status salvaging "cdp up to ${SALVAGE_SECS}s"
  SALVAGE_RC=0
  SALVAGE_RAN=1
  SALVAGE_TMP="$WORK/salvage.capture"
  node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "$SALVAGE_SECS" "$PORT" > "$SALVAGE_TMP" 2>>"$RUNLOG" || SALVAGE_RC=$?
  if [ "$SALVAGE_RC" -eq 0 ] && pg_is_review "$SALVAGE_TMP" \
     && mv "$SALVAGE_TMP" "$CAPTURE_OUT" 2>/dev/null; then
    # Checked install (gate #54 r10): SALVAGED is claimed only once the capture actually
    # reached CAPTURE_OUT; an install failure preserves instead of falling through to a
    # state-clearing exit 6 with the captured bytes lost.
    echo "[oracle-review] CDP salvage recovered a completed review." >&2
    SALVAGED=1
    CAPTURE_SOURCE=cdp   # this capture's source URL IS the marker's memo — invalidatable
  elif [ "$SALVAGE_RC" -eq 0 ] && [ -s "$SALVAGE_TMP" ] && pg_is_review "$SALVAGE_TMP"; then
    SALVAGE_PRESERVE=1
    echo "[oracle-review] salvage captured a review but could not install it; preserving the run." >&2
  else
    rm -f "$SALVAGE_TMP"
  fi
  # v0.25 (gate P1 x3): rc 4 is the ONLY salvage result that is evidence the review is absent —
  # "scanned the browser successfully and nothing carried this marker". Everything else is either
  # positive evidence the conversation exists or no evidence at all, so the default is to PRESERVE:
  #   3 still generating                        — the classic reserve-and-harvest case
  #   7 inconclusive                            — CDP down, or the remembered conversation
  #                                               would not render decisively
  #   5 ChatGPT throttle                        — literally means "do NOT resubmit"; the
  #                                               submission's fate is unknown
  #   0 but pg_is_review rejected the capture   — the conversation demonstrably EXISTS (the
  #                                               salvage read a VERDICT off it); only our
  #                                               stricter shape check failed, e.g. mid-render
  #   anything unexpected (helper crash, bug)   — proves nothing about the conversation
  # Preserving means persisting the reservation and exiting 9 (which also skips tab cleanup)
  # instead of falling through to exit 6, which both closes the conversation and leaves no
  # reservation to stop the next invocation spending a second Pro slot on a review that exists.
  case "$SALVAGE_RC" in
    4) : ;;
    10)
      if [ -n "${PR_NUM:-}" ] && [ -n "${PG_META_HOST:-}" ] && [ -n "${PG_META_OWNER:-}" ] && [ -n "${PG_META_REPO:-}" ] \
         && pg_attempt_terminal_transition "$PG_META_HOST" "$PG_META_OWNER" "$PG_META_REPO" "$PR_NUM" \
              "$ROUND_KEY" "$RUN_MARKER" "$RUN_SPEND_EPOCH" submitted-terminal exact-owned-infrastructure-terminal; then
        SALVAGE_TERMINAL_INFRA=1
        echo "[oracle-review] exact-owned ChatGPT terminal infrastructure error; recovery released, round retained." >&2
      else
        SALVAGE_PRESERVE=1
        echo "[oracle-review] terminal infrastructure evidence could not be persisted safely; preserving recovery state." >&2
      fi
      ;;
    0) [ "${SALVAGED:-0}" = 1 ] || SALVAGE_PRESERVE=1 ;;
    *) SALVAGE_PRESERVE=1 ;;
  esac
fi

# v0.28 (#48): provenance choke point for BROWSER-MATCHED captures — session reattach and CDP
# salvage. Those find "our" conversation by marker/URL heuristics and can bind the wrong one
# (seen live: a failed send salvaged a different PR's finished review, pushbot #1245). A
# structurally-complete capture citing none of this change's files is such a foreign answer:
# never return it as ours; route to the preserve path — the real review may still be
# generating, and preserving (reservation + exit 9) costs nothing while a foreign acceptance
# poisons the gate. Direct oracle output is EXEMPT: the process that submitted the prompt
# writes its own conversation's answer, and a legitimate review may cite a caller/context
# file outside the diff (the fixture suite does exactly that) — rejecting those would turn
# clean runs into phantom exit-9s.
# Snapshot-FIRST acceptance (gate #54 r7): every structural, nonce, and provenance check below
# runs on a process-private copy taken NOW. Shared $OUT can be swapped by a concurrent marker
# between a check and its use; under REQUIRE_NONCE, the snapshot's own nonce check is what
# binds the accepted bytes to this run, so a swapped-in foreign review can never pass. (Direct
# oracle captures keep the inherent instant between oracle's write and this copy — a caller
# sharing one --out across concurrent DIRECT runs is outside the engine's control.)
FINAL_SNAP=""
if pg_is_review "$CAPTURE_OUT" && cp "$CAPTURE_OUT" "$WORK/final.snap" 2>/dev/null && pg_is_review "$WORK/final.snap"; then
  FINAL_SNAP="$WORK/final.snap"
elif pg_is_review "$CAPTURE_OUT"; then
  # A VALID capture that could not be snapshotted (disk full, WORK trouble) must not fall
  # through to the state-clearing generic exit 6 with its bytes forgotten (gate #54 r11):
  # preserve the run — the capture stays at $CAPTURE_OUT and the tab/reservation survive.
  echo "[oracle-review] valid capture at $CAPTURE_OUT could not be snapshotted; preserving the run for --harvest." >&2
  SALVAGE_RAN=1; SALVAGE_PRESERVE=1
fi
# FAIL CLOSED for unbindable browser-matched captures (gate #54 r3): every v0.28 prompt
# promises the nonce echo; a capture without it whose path check cannot bind either (no
# manifest, or fewer than two citations — a foreign SHIP/single-file review looks identical)
# is preserved for --harvest/manual confirmation, never auto-accepted.
# PRO_GATE_REQUIRE_NONCE=0 restores best-effort acceptance.
if [ -n "$FINAL_SNAP" ] \
   && { [ "${SALVAGED:-0}" = 1 ] || [ "${REATTACHED:-0}" = 1 ]; } \
   && [ "$REQUIRE_NONCE" = 1 ] \
   && ! pg_capture_nonce_ok "$FINAL_SNAP" "$RUN_MARKER"; then
  # NONCE OR NOTHING for every browser-matched capture (gate #54 r4/r5 P1): reattach is
  # slug-scoped and CDP is page-wide marker-scoped — in both, a STALE answer for this very
  # PR naturally cites overlapping files, so path overlap can only reject (branch above),
  # never accept. PRO_GATE_REQUIRE_NONCE=0 restores best-effort acceptance.
  echo "[oracle-review] captured a complete review that cannot be bound to this run (no run-marker echo); NOT accepting it. Preserving for --harvest; inspect $OUT.unbound.$$ (PRO_GATE_REQUIRE_NONCE=0 accepts best-effort)." >&2
  mv "$FINAL_SNAP" "$OUT.unbound.$$" 2>/dev/null || rm -f "$FINAL_SNAP"
  FINAL_SNAP=""
  rm -f "$CAPTURE_OUT" 2>/dev/null
  SALVAGE_RAN=1; SALVAGE_PRESERVE=1
fi
if [ -n "$FINAL_SNAP" ] \
   && { [ "${SALVAGED:-0}" = 1 ] || [ "${REATTACHED:-0}" = 1 ]; } \
   && [ "$REQUIRE_NONCE" = 0 ] \
   && ! pg_capture_nonce_ok "$FINAL_SNAP" "$RUN_MARKER" \
   && ! pg_review_matches_change "$FINAL_SNAP" "$WORK/diff.paths"; then
  echo "[oracle-review] captured a complete review but it cites NONE of this change's files — foreign conversation suspected; NOT accepting it as ours. Preserving the run for --harvest. The rejected capture is at $OUT.foreign.$$." >&2
  mv "$FINAL_SNAP" "$OUT.foreign.$$" 2>/dev/null || rm -f "$FINAL_SNAP"
  FINAL_SNAP=""
  rm -f "$CAPTURE_OUT" 2>/dev/null
  # Invalidate the memoized candidate ONLY for CDP captures: the memo names the conversation
  # the salvage just read, so it identifies the rejected text's source. A REATTACH capture
  # carries no URL identity — its rejected text may be a stale oracle session while the memo
  # (possibly written by the early probe) points at the GENUINE current conversation;
  # blacklisting that would make the real review unrecoverable after a Chrome restart.
  # Discriminated by CAPTURE_SOURCE, not SALVAGED — reattach sets SALVAGED too (gate #54 r3).
  # The CDP child names its capture's exact source URL in the run log (gate #54 r5).
  # Blacklisting only in LEGACY mode (gate #54 r6): under REQUIRE_NONCE a mismatched capture
  # may be an older verdict from the conversation still generating THIS answer — condemned,
  # its eventual nonce-bearing result would be skipped. (This branch is unreachable under
  # REQUIRE_NONCE anyway: the nonce-or-nothing branch below captures everything nonce-less.)
  if [ "${CAPTURE_SOURCE:-}" = cdp ] && [ "$REQUIRE_NONCE" = 0 ]; then
    pg_provenance_reject "$RUN_MARKER" "$(sed -n 's/^matched-url //p' "$RUNLOG" 2>/dev/null | tail -1)"
  fi
  SALVAGE_RAN=1; SALVAGE_PRESERVE=1   # route to the reserve-and-harvest branch below
fi
if [ -n "$FINAL_SNAP" ]; then
  # CDP names the exact rendered conversation in RUNLOG. Promote it only after every acceptance
  # check above passed; direct and reattach captures deliberately leave this empty and bind by
  # durable byte identity instead.
  if [ "${CAPTURE_SOURCE:-}" = cdp ]; then
    PG_ACCEPTED_URL="$(sed -n 's/^matched-url //p' "$RUNLOG" 2>/dev/null | tail -1)"
  fi
  # v0.28 (#55): strip the echoed run-marker nonce before the review leaves the engine —
  # binding is an internal mechanism, not part of the caller-facing output. Everything from
  # here on — severity note, stdout, artifact, digest — sources the verified snapshot;
  # $OUT is publication only (gate #54 r6/r7).
  pg_strip_nonce "$FINAL_SNAP" "$RUN_MARKER"
  PG_FINAL_SRC="$FINAL_SNAP"
  # v0.22: remember this review's P0/P1 counts so a later round-capped refusal can flag an
  # unconfirmed open P0 to the human (advisory sidecar; see pg_round_note_severity).
  # Same spend-identity rule as the harvest path: stamp with the epoch pg_round_record CHARGED
  # this round at, not the minutes-to-an-hour-later moment the review finished, and not the
  # marker's pre-queue launch time — otherwise the row outlives (or predates) its own spend.
  pg_round_note_severity "$ROUND_KEY" "$PG_FINAL_SRC" "${RUN_SPEND_EPOCH:-}"
  # Verified publication (gate #54 r8/r9): "done" PROMISES a readable --out; a failed publish
  # must not report clean, and the durability of what WAS captured decides the message.
  pg_publish_out "$PG_FINAL_SRC" || pg_publish_fail "$PG_FINAL_SRC"
  # Canonical result BEFORE terminal done (gate #54 r11): pollers act on done immediately, so
  # the durable artifact must already exist and be named in the status record they read.
  pg_persist_result "$PG_FINAL_SRC"
  echo "RESULT_FILE=$RESULT_PATH"
  pg_status done "result: $RESULT_PATH"
  cat "$PG_FINAL_SRC"
  pg_finish 0
elif [ "${SALVAGE_RAN:-0}" = 1 ] && [ "${SALVAGE_PRESERVE:-0}" = 1 ]; then
  # The salvage budget ran out while the conversation was STILL GENERATING (or the outcome was
  # inconclusive / the capture failed validation — see the case above): the Pro slot is
  # spent and the answer may land any minute. Persist a durable reservation BEFORE this process
  # releases its flock slot, leave the tab open (pg_finish skips close for exit 9), and hand the
  # caller a no-respend collection path. Fresh runs reconcile/respect the reservation, so actual
  # account concurrency and same-PR serialization remain correct after this wrapper exits.
  # v0.28 (#48): persist the change's file manifest (its OWN directory — never inside
  # in-progress/, whose enumerators would misread it as a reservation) so a later --harvest
  # (a separate process with no diff) can provenance-check its capture. Written before the
  # reservation itself so a reader never sees a reservation without its manifest.
  mkdir -p "$(pg_manifest_dir)" 2>/dev/null || true
  if [ -s "$WORK/diff.paths" ]; then
    if ! cp "$WORK/diff.paths" "$(pg_manifest_dir)/${RUN_MARKER}" 2>/dev/null; then
      # Loud, not silent (gate #54 r2 P1): without the manifest a later harvest falls back
      # to nonce-only provenance — the operator should know the path check is off for this
      # run. Full fail-closed semantics is part of #56's completed-artifact design.
      echo "[oracle-review] WARNING: could not persist the change manifest to $(pg_manifest_dir); a later --harvest of this run can bind only via the run-marker echo." >&2
    fi
  fi
  # v0.28 (#55): this run's prompt asked for the nonce echo — record that expectation so a
  # harvest can NOTE when a capture arrives without one (accepted via path overlap instead).
  : > "$(pg_manifest_dir)/${RUN_MARKER}.nonce" 2>/dev/null || true
  if ! pg_reservation_write "$RUN_MARKER" "${ROUND_KEY:-diff}" "$OUT" "${SLOT_HELD:-}" "$RESOLVED_MODEL" "${RUN_SPEND_EPOCH:-}"; then
    # Fail closed: without the durable reservation, exit 9 would under-count a live Pro tab and
    # let the next invocation double-spend. Keep the process/locks alive rather than release
    # unreserved capacity; this should only happen on a broken/unwritable PRO_GATE_HOME.
    echo "ERROR: review still generating, but could not persist its capacity reservation; keeping the engine alive to preserve the slot." >&2
    pg_status salvaging "still generating; reservation write failed; slot held"
    while node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT" >/dev/null 2>&1; do sleep 60; done
    echo "ERROR: live conversation disappeared before it could be reserved; review lost." >&2
    pg_status failed "reservation write failed; conversation gone"
    pg_finish 6
  fi
  case "${SALVAGE_RC:-0}" in
    3) echo "ERROR: review still generating after the salvage budget: conversation LEFT OPEN and account capacity RESERVED." >&2 ;;
    7) echo "ERROR: the salvage could not determine this review's fate (browser unreachable, or the conversation would not render decisively). Treating it as LIVE and RESERVED rather than lost — the slot is spent and the review may well exist." >&2 ;;
    *) echo "ERROR: the salvage read this run's conversation but the capture failed validation (truncated or malformed). Conversation KEPT and account capacity RESERVED — re-collect rather than re-spend." >&2 ;;
  esac
  echo "  Collect it later WITHOUT spending another Pro slot:" >&2
  echo "    ${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh --harvest '${RUN_MARKER}' --out '${OUT}' --timeout 20m" >&2
  pg_status in-progress "slot spent, model still generating; harvest with --harvest"
  pg_finish 9
else
  RETRIES=$(( attempt > 0 ? attempt - 1 : 0 ))
  echo "ERROR: oracle produced no usable review after salvage + ${RETRIES} retr$([ "${RETRIES}" -eq 1 ] && echo y || echo ies) (reattach: oracle session ${SLUG_BASE})." >&2
  FAIL_DETAIL="no usable review after salvage"
  [ "${SALVAGE_TERMINAL_INFRA:-0}" != 1 ] \
    || FAIL_DETAIL="submitted review ended in an exact-owned ChatGPT infrastructure error; round retained, safe to retry with changed/current evidence"
  # v0.31 (#65): refund only through the same positive no-spend predicate used before a retry.
  # It requires a clean marker scan, no URL/live/throttle evidence, a stable browser, and complete,
  # digest-verified Oracle transcripts with no browser lifecycle. Missing capture and post-click DOM
  # timeouts stay charged because their delivery fate is ambiguous.
  _svc_up=""; _svc_restarted=0
  if _svc_up="$(pg_browser_restarted_midrun "$RUN_START")"; then _svc_restarted=1; fi
  if [ "${SALVAGE_RAN:-0}" = 1 ] \
     && pg_attempt_provably_unsubmitted "${SALVAGE_RC:-0}"; then
    echo "[oracle-review] Oracle's exact session metadata proves Send was never dispatched (browser scanned clean, no URL memoized, browser stable): refunding this round; zero Pro quota was spent." >&2
    pg_fresh_dispatch_refund \
      || { echo "[oracle-review] charged marker state could not be proven for refund; preserving it for recovery." >&2; FAIL_DETAIL="submission fate uncertain; charged state preserved for recovery"; }
    [ "${FAIL_DETAIL:-}" = "submission fate uncertain; charged state preserved for recovery" ] || FAIL_DETAIL="submission never landed (send/upload failure before the prompt reached ChatGPT); round refunded, safe to retry"
  fi
  # Attribute the failure when the review browser restarted mid-run — almost always memory pressure
  # on a small box (Chrome's subprocesses get reclaimed, oracle-chrome restarts, the CDP tab is
  # lost). Say so plainly so a non-technical user knows what happened, that quota was likely already
  # spent, and that the review may still exist server-side (no need to immediately re-run).
  # (FAIL_DETAIL was seeded above; the refund path may already carry its own detail.)
  if [ "$_svc_restarted" = 1 ]; then
    _mem="$(pg_mem_status)"; [ -n "$_mem" ] || _mem="memory usage unknown"
    echo "  LIKELY CAUSE: the review browser (Chrome) restarted ${_svc_up}s ago — mid-review — almost always because the machine ran low on memory (${_mem})." >&2
    # #35: when the early probe already memoized this run's conversation URL, the recovery is
    # a copy-paste no-spend command, not "free memory and hope". Say exactly that.
    _memo=""
    [ -n "${RUN_MARKER:-}" ] && [ -f "$PRO_GATE_HOME/conversation-urls/$RUN_MARKER" ] \
      && _memo="$(head -c 300 "$PRO_GATE_HOME/conversation-urls/$RUN_MARKER" 2>/dev/null | tr -d '\n')"
    if [ -n "$_memo" ]; then
      echo "  The conversation URL was captured before the crash: $_memo" >&2
      echo "  The review may be complete server-side. Recover it WITHOUT spending another Pro slot:" >&2
      echo "    ${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh --harvest '${RUN_MARKER}' --out '${OUT}' --timeout 20m" >&2
      echo "  Or inspect all state for this change first: ${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh --status '${PR_URL:-${PR_NUM:-}}'" >&2
      FAIL_DETAIL="review browser restarted mid-run (chrome up ${_svc_up}s); conversation URL remembered — recover FREE with --harvest '${RUN_MARKER}'"
    else
      echo "  The slot was likely already spent and the review may still exist in ChatGPT, so do NOT immediately re-run. Free memory (close other apps / browser tabs) and try again." >&2
      FAIL_DETAIL="review browser restarted mid-run (chrome up ${_svc_up}s); likely out of memory"
    fi
  fi
  pg_status failed "$FAIL_DETAIL"
  pg_finish 6
fi
