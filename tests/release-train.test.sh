#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PLUGIN="pro-gate"
CANONICAL_SOURCE_KIND='url'
CANONICAL_SOURCE_URL='https://github.com/StartupBros-com/pro-gate.git'
trap 'rm -rf "$TMP"' EXIT

HARDENED_SHA='08f7d22f3a5b59b1658ab2e96a20d0d3c352869c'
RETIRED_SHA='c981b872ebf650805200ad72c8b7142232f8b3f6'
ANNOUNCE_WORKFLOW='StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml'
HARDENED_USES="$ANNOUNCE_WORKFLOW@$HARDENED_SHA"
ANNOUNCE_IF="github.event.release.draft == false && github.event.release.prerelease == false && needs.verify.result == 'success' && needs.verify.outputs.announce == 'true'"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected $2, got $1"; pass "$3"; }

validate_release_policy() {
  local workflow="$1" script="$2" json
  if grep -Eq 'TOOL_RELEASE_ANNOUNCE_(SECRET|URL)|ANNOUNCE_(SECRET|URL)|x-tool-release-announce-secret|/api/internal/ops/tool-releases|(^|[[:space:]])curl([[:space:]]|$)' "$workflow" "$script"; then
    printf 'direct Tool Drop delivery surface is forbidden\n' >&2
    return 1
  fi
  if ! json="$(yq -o=json '.' "$workflow" 2>/dev/null)"; then
    printf 'release workflow must parse as YAML\n' >&2
    return 1
  fi
  jq -e '.on.release.types == ["published", "edited"]' <<<"$json" >/dev/null || {
    printf 'release events must be exactly published and edited\n' >&2
    return 1
  }
  jq -e '.permissions == {"contents": "read"}' <<<"$json" >/dev/null || {
    printf 'workflow permissions must be exactly contents read\n' >&2
    return 1
  }
  # The marketplace deploy key is RETIRED. A standing credential that can write
  # the distribution manifest is the one whose compromise reaches every
  # installed client, and a direct bot push cannot satisfy required status
  # checks anyway (hov-marketplace require-ci, 2026-08-11). Promotion is a
  # reviewed repin PR; this job only verifies and reports.
  if grep -Fq 'HOV_MARKETPLACE_DEPLOY_KEY' "$workflow" "$script"; then
    printf 'marketplace deploy key must stay retired\n' >&2
    return 1
  fi
  if grep -Eq 'git push .*(marketplace|HEAD:)' "$script"; then
    printf 'release train must never push to the marketplace\n' >&2
    return 1
  fi
  jq -e --arg uses "$HARDENED_USES" --arg condition "$ANNOUNCE_IF" '
    ([.jobs.verify.steps[] | select((.uses // "") | startswith("actions/checkout@"))]) as $checkout
    | ([.jobs.verify.steps[] | select(.id == "release-source")]) as $source
    | ([.jobs.verify.steps[] | select(.id == "release-train")]) as $train
    | ([.jobs.verify.steps[] | select(.id == "stable")]) as $stable
    | ($checkout | length) == 1
      and $checkout[0].with.ref == "${{ github.event.repository.default_branch }}"
      and $checkout[0].with["fetch-depth"] == 0
      and $checkout[0].with["persist-credentials"] == false
      and ($source | length) == 1
      and ($source[0].run | contains("refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"))
      and ($source[0].run | contains("git merge-base --is-ancestor"))
      and ($source[0].run | contains("git worktree add --detach"))
      and ($source[0].run | contains("$RUNNER_TEMP/release-source"))
      and ($train | length) == 1
      and $train[0].run == "./scripts/release-train.sh"
      and $train[0].env.SOURCE_ROOT == "${{ runner.temp }}/release-source"
      and $train[0].env.SOURCE_SHA == "${{ steps.release-source.outputs.sha }}"
      and $train[0].env.RELEASE_REPOSITORY == "${{ github.repository }}"
      and ($stable | length) == 1
      and ($stable[0].run | contains("./scripts/latest-stable-release.sh"))
      and ([.jobs.verify.steps[] | select(.name == "Check release notes are customer-ready")][0].run | contains("./scripts/check-release-notes.sh"))
      and ([.jobs.verify.steps[] | select(.name == "Provision pinned CI tools")][0].run == "./scripts/provision-ci-tools.sh")
      and .jobs.verify.outputs.announce == "${{ steps.release-train.outputs.announce }}"
      and .jobs.announce.uses == $uses
      and .jobs.announce.if == $condition
      and .jobs.announce.permissions == {"contents": "read", "id-token": "write"}
      and ((.jobs.announce | keys | sort) == ["if", "name", "needs", "permissions", "uses"])
  ' <<<"$json" >/dev/null || {
    printf 'trusted default-branch verifier and explicit announce output are required\n' >&2
    return 1
  }
}

assert_policy_failure() {
  local label="$1" diagnostic="$2" workflow="$3" script="$4" output status
  if output="$(validate_release_policy "$workflow" "$script" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -eq 1 && "$output" == *"$diagnostic"* ]]; then
    pass "$label"
  else
    fail "$label: expected exit 1 with [$diagnostic], got exit $status and [$output]"
  fi
}

mkdir -p "$TMP/source/.claude-plugin" "$TMP/assets" "$TMP/bin" "$TMP/gh-fixtures"
printf '{"name":"%s","version":"0.1.0"}\n' "$PLUGIN" > "$TMP/source/.claude-plugin/plugin.json"
printf '0.1.0\n' > "$TMP/source/VERSION"
git -C "$TMP/source" init -q
git -C "$TMP/source" config user.email test@example.com
git -C "$TMP/source" config user.name Test
git -C "$TMP/source" add .
git -C "$TMP/source" commit -qm source
git -C "$TMP/source" tag v0.1.0
SOURCE_SHA="$(git -C "$TMP/source" rev-parse HEAD)"
printf 'runtime\n' > "$TMP/assets/pro-gate-runtime-0.1.0.tar.gz"
(cd "$TMP/assets" && sha256sum pro-gate-runtime-0.1.0.tar.gz > pro-gate-runtime-0.1.0.tar.gz.sha256)

common=(
  EVENT_ACTION=published REPOSITORY="$PLUGIN" RELEASE_REPOSITORY=StartupBros-com/pro-gate
  RELEASE_ID=201 RELEASE_TAG=v0.1.0 RELEASE_PRERELEASE=false RELEASE_DRAFT=false
  SOURCE_ROOT="$TMP/source" ASSET_DIR="$TMP/assets" SOURCE_SHA="$SOURCE_SHA"
)

# This double accepts only the two API requests the train is allowed to make:
# the raw, default-branch marketplace GET and the paginated release resolver.
# Any header/path/repo/ref/method/body drift is an immediate test failure rather
# than a permissive fixture accidentally masking a changed security boundary.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_CALL_LOG:?}"

if [[ "${1:-}" == auth && "${2:-}" == status && "$#" -eq 2 ]]; then
  exit 0
fi
[[ "${1:-}" == api ]] || exit 64
shift

if [[ "$#" -eq 3 && "${1:-}" == -H \
      && "${2:-}" == 'Accept: application/vnd.github.raw+json' \
      && "${3:-}" == 'repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json' ]]; then
  case "${GH_MANIFEST_MODE:-ok}" in
    fail) exit 1 ;;
    malformed) printf 'not-json-at-all\n' ;;
    *) cat "${GH_FIXTURE_DIR:?}/marketplace.json" ;;
  esac
  exit 0
fi

if [[ "$#" -eq 2 && "${1:-}" == --paginate \
      && "${2:-}" == 'repos/StartupBros-com/pro-gate/releases?per_page=100' ]]; then
  state="${GH_LATEST_STATE_FILE:?}"
  index="$(cat "$state")"
  index=$((index + 1))
  printf '%s\n' "$index" > "$state"
  page="${GH_FIXTURE_DIR:?}/latest-$index.json"
  [[ -f "$page" ]] || exit 65
  cat "$page"
  exit 0
fi

exit 64
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

marketplace_json() {
  local version="$1" tag="$2" id="$3" sha="$4" source_kind="${5:-$CANONICAL_SOURCE_KIND}" source_url="${6:-$CANONICAL_SOURCE_URL}"
  printf '{"plugins":[{"name":"%s","source":{"source":"%s","url":"%s","sha":"%s"},"metadata":{"version":"%s","releaseTag":"%s","releaseId":%s}}]}\n' \
    "$PLUGIN" "$source_kind" "$source_url" "$sha" "$version" "$tag" "$id"
}

stable_page() {
  local id="$1" published_at="${2:-2026-01-01T00:00:00Z}"
  printf '[{"id":%s,"published_at":"%s","draft":false,"prerelease":false}]\n' "$id" "$published_at"
}

reset_gh() {
  local manifest="$1" index=1 page
  shift
  printf '%s\n' "$manifest" > "$TMP/gh-fixtures/marketplace.json"
  for page in "$@"; do
    printf '%s\n' "$page" > "$TMP/gh-fixtures/latest-$index.json"
    index=$((index + 1))
  done
  printf '0\n' > "$TMP/latest-state"
  : > "$TMP/gh.log"
}

run_train() {
  local output="$1" latest_id="$2" manifest_mode="${3:-ok}"
  env "${common[@]}" LATEST_STABLE_ID="$latest_id" GITHUB_OUTPUT="$output" \
    GH_FIXTURE_DIR="$TMP/gh-fixtures" GH_LATEST_STATE_FILE="$TMP/latest-state" \
    GH_CALL_LOG="$TMP/gh.log" GH_MANIFEST_MODE="$manifest_mode" \
    "$ROOT/scripts/release-train.sh"
}

assert_announce_false_only() {
  local output="$1" label="$2"
  [[ "$(head -n1 "$output")" == 'announce=false' ]] || fail "$label does not write announce=false first"
  ! grep -Fxq 'announce=true' "$output" || fail "$label must not enable announce"
  pass "$label leaves announce false"
}

reject_gh_call() {
  if GH_FIXTURE_DIR="$TMP/gh-fixtures" GH_LATEST_STATE_FILE="$TMP/latest-state" GH_CALL_LOG="$TMP/gh.log" \
    "$TMP/bin/gh" "$@" >/dev/null 2>&1; then
    fail "strict gh double accepted an invalid request: $*"
  fi
}

CURRENT_CARD="$(marketplace_json 0.1.0 v0.1.0 201 "$SOURCE_SHA")"
STALE_CARD="$(marketplace_json 0.0.9 v0.0.9 99 0000000000000000000000000000000000000a)"
LATEST_201="$(stable_page 201)"

# The API double is deliberately exact: no branch ref, method/body option, or
# unrelated repository may broaden this read under future maintenance.
reset_gh "$CURRENT_CARD" "$LATEST_201"
reject_gh_call api 'repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json'
reject_gh_call api -H 'Accept: application/json' 'repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json'
reject_gh_call api -H 'Accept: application/vnd.github.raw+json' 'repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/other.json'
reject_gh_call api -H 'Accept: application/vnd.github.raw+json' 'repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json?ref=main'
reject_gh_call api -H 'Accept: application/vnd.github.raw+json' 'repos/attacker/hov-marketplace/contents/.claude-plugin/marketplace.json'
reject_gh_call api -H 'Accept: application/vnd.github.raw+json' --method GET 'repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json'
reject_gh_call api -H 'Accept: application/vnd.github.raw+json' --raw-field evil=body 'repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json'
pass 'strict gh double rejects wrong manifest header, path, repo, ref, method, and body'

# Planted negative 1: a stale card cannot report distribution success. It keeps
# the verbatim repin hand-off, then fails before the final release recheck.
reset_gh "$STALE_CARD" "$LATEST_201"
STALE_OUTPUT="$TMP/stale-output"
if out="$(run_train "$STALE_OUTPUT" 201 2>&1)"; then
  fail 'a stale marketplace card must not let the run conclude success'
fi
pass 'a stale marketplace card fails the run (planted negative 1)'
for field in "$PLUGIN" 0.1.0 "$SOURCE_SHA" 201 v0.1.0; do
  [[ "$out" == *"$field"* ]] || fail "repin report omits $field"
done
pass 'run reports every value the marketplace repin PR needs'
[[ "$out" == *'=== marketplace repin needed ==='* ]] || fail 'run does not print the repin notice'
pass 'run names the repin step explicitly'
[[ "$out" == *'NOT distributed'* ]] || fail 'stale failure does not say the release was not distributed'
pass 'stale failure names the actual consequence: published but not distributed'
assert_announce_false_only "$STALE_OUTPUT" 'stale card'
assert_eq "$(cat "$TMP/gh.log")" "api -H Accept: application/vnd.github.raw+json repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json" 'stale card never reaches final latest-release recheck'

# A fully typed source kind/URL mismatch is evidence of a stale promotion, not
# a parse outage. Both fields are part of the client-facing distribution tuple.
for tuple in kind url; do
  case "$tuple" in
    kind) CARD="$(marketplace_json 0.1.0 v0.1.0 201 "$SOURCE_SHA" git "$CANONICAL_SOURCE_URL")" ;;
    url) CARD="$(marketplace_json 0.1.0 v0.1.0 201 "$SOURCE_SHA" url https://example.test/pro-gate.git)" ;;
  esac
  reset_gh "$CARD" "$LATEST_201"
  TUPLE_OUTPUT="$TMP/$tuple-output"
  if out="$(run_train "$TUPLE_OUTPUT" 201 2>&1)"; then
    fail "wrong canonical source $tuple must be stale"
  fi
  [[ "$out" == *'NOT distributed'* && "$out" != *UNVERIFIED* ]] || fail "wrong source $tuple is not a stale tuple"
  assert_announce_false_only "$TUPLE_OUTPUT" "wrong source $tuple"
done
pass 'canonical source kind and URL are required for a current card'

# Ambiguous/malformed data is UNVERIFIED rather than STALE: no fabricated repin
# request can safely act on a duplicate, missing, or type-invalid card.
DUPLICATE_CARD="$(jq '.plugins += .plugins' <<<"$CURRENT_CARD")"
MISSING_SOURCE_CARD="$(jq 'del(.plugins[0].source)' <<<"$CURRENT_CARD")"
TYPE_INVALID_CARD="$(jq '.plugins[0].source.url = 7' <<<"$CURRENT_CARD")"
EMPTY_SOURCE_CARD="$(jq '.plugins[0].source.url = ""' <<<"$CURRENT_CARD")"
EMPTY_KIND_CARD="$(jq '.plugins[0].source.source = ""' <<<"$CURRENT_CARD")"
ZERO_ID_CARD="$(jq '.plugins[0].metadata.releaseId = 0' <<<"$CURRENT_CARD")"
for invalid in duplicate missing-source type-invalid empty-source empty-kind zero-id; do
  case "$invalid" in
    duplicate) CARD="$DUPLICATE_CARD"; MODE=ok ;;
    missing-source) CARD="$MISSING_SOURCE_CARD"; MODE=ok ;;
    type-invalid) CARD="$TYPE_INVALID_CARD"; MODE=ok ;;
    empty-source) CARD="$EMPTY_SOURCE_CARD"; MODE=ok ;;
    empty-kind) CARD="$EMPTY_KIND_CARD"; MODE=ok ;;
    zero-id) CARD="$ZERO_ID_CARD"; MODE=ok ;;
  esac
  reset_gh "$CARD" "$LATEST_201"
  INVALID_OUTPUT="$TMP/$invalid-output"
  if out="$(run_train "$INVALID_OUTPUT" 201 "$MODE" 2>&1)"; then
    fail "$invalid marketplace tuple must not let the run conclude success"
  fi
  [[ "$out" == *UNVERIFIED* && "$out" != *'=== marketplace repin needed ==='* ]] || fail "$invalid marketplace tuple is not a distinct UNVERIFIED outcome"
  assert_announce_false_only "$INVALID_OUTPUT" "$invalid marketplace tuple"
done
pass 'duplicate, missing, empty, zero-id, and type-invalid cards fail closed as UNVERIFIED'

for unreadable in fail malformed; do
  reset_gh "$CURRENT_CARD" "$LATEST_201"
  UNREADABLE_OUTPUT="$TMP/$unreadable-output"
  if out="$(run_train "$UNREADABLE_OUTPUT" 201 "$unreadable" 2>&1)"; then
    fail "$unreadable marketplace ($unreadable) must not let the run conclude success"
  fi
  [[ "$out" == *UNVERIFIED* && "$out" != *'=== marketplace repin needed ==='* ]] || fail "$unreadable marketplace ($unreadable) lacks distinct UNVERIFIED output"
  assert_announce_false_only "$UNREADABLE_OUTPUT" "unreadable marketplace ($unreadable)"
done
pass 'API and JSON failures stay distinct from a stale card'

# Planted negative 2: exact tuple match prints confirmation, never a repin, and
# only then runs the final latest-release recheck that enables announcement.
reset_gh "$CURRENT_CARD" "$LATEST_201"
CURRENT_OUTPUT="$TMP/current-output"
out="$(run_train "$CURRENT_OUTPUT" 201)"
[[ "$out" != *'=== marketplace repin needed ==='* ]] || fail 'repin notice fires even though the card already matches (planted negative 2)'
pass 'repin notice is absent when the marketplace card already matches (planted negative 2)'
[[ "$out" == *'distribution is current'* ]] || fail 'a current card does not print a confirmation'
pass 'a current card prints a confirmation instead of a repin notice'
assert_eq "$(head -n1 "$CURRENT_OUTPUT")" 'announce=false' 'current card writes announce=false before validation'
assert_eq "$(tail -n1 "$CURRENT_OUTPUT")" 'announce=true' 'current card plus final latest release enables announce'
assert_eq "$(cat "$TMP/gh.log")" $'api -H Accept: application/vnd.github.raw+json repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json\napi --paginate repos/StartupBros-com/pro-gate/releases?per_page=100' 'current train makes only the exact marketplace and final latest-release reads'

# A stateful resolver models a newer release published while this train was
# verifying. The first response makes this release eligible; the final response
# suppresses announce without failing the already-valid historical release.
LATEST_202="$(stable_page 202 2026-02-01T00:00:00Z)"
reset_gh "$CURRENT_CARD" "$LATEST_201" "$LATEST_202"
INITIAL_ID="$(GH_FIXTURE_DIR="$TMP/gh-fixtures" GH_LATEST_STATE_FILE="$TMP/latest-state" GH_CALL_LOG="$TMP/gh.log" "$ROOT/scripts/latest-stable-release.sh" StartupBros-com/pro-gate)"
assert_eq "$INITIAL_ID" 201 'initial latest-release resolution selects this release'
STATEFUL_OUTPUT="$TMP/stateful-output"
out="$(run_train "$STATEFUL_OUTPUT" "$INITIAL_ID")"
[[ "$out" == *'ceased to be latest stable (202)'* ]] || fail 'final latest-release change is not reported'
pass 'final latest-release recheck reports a state change'
assert_announce_false_only "$STATEFUL_OUTPUT" 'stateful final latest-release change'
assert_eq "$(cat "$TMP/gh.log")" $'api --paginate repos/StartupBros-com/pro-gate/releases?per_page=100\napi -H Accept: application/vnd.github.raw+json repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json\napi --paginate repos/StartupBros-com/pro-gate/releases?per_page=100' 'stateful resolver makes initial and final exact latest-release reads'

# Pre-release and superseded events are successful no-ops, but cannot inherit a
# positive announce output. They also must not touch the marketplace.
reset_gh "$CURRENT_CARD" "$LATEST_201"
PRERELEASE_OUTPUT="$TMP/prerelease-output"
out="$(env "${common[@]}" LATEST_STABLE_ID=201 RELEASE_PRERELEASE=true GITHUB_OUTPUT="$PRERELEASE_OUTPUT" GH_FIXTURE_DIR="$TMP/gh-fixtures" GH_LATEST_STATE_FILE="$TMP/latest-state" GH_CALL_LOG="$TMP/gh.log" "$ROOT/scripts/release-train.sh")"
[[ "$out" != *'repin needed'* ]] || fail 'prerelease must not request a repin'
pass 'prerelease remains a no-op'
assert_announce_false_only "$PRERELEASE_OUTPUT" 'prerelease'
assert_eq "$(cat "$TMP/gh.log")" '' 'prerelease skips all GitHub API reads'

reset_gh "$CURRENT_CARD" "$LATEST_201"
SUPERSEDED_OUTPUT="$TMP/superseded-output"
out="$(env "${common[@]}" LATEST_STABLE_ID=202 GITHUB_OUTPUT="$SUPERSEDED_OUTPUT" GH_FIXTURE_DIR="$TMP/gh-fixtures" GH_LATEST_STATE_FILE="$TMP/latest-state" GH_CALL_LOG="$TMP/gh.log" "$ROOT/scripts/release-train.sh")"
[[ "$out" != *'repin needed'* ]] || fail 'superseded release must not request a repin'
pass 'a release that is not latest stable is a no-op'
assert_announce_false_only "$SUPERSEDED_OUTPUT" 'superseded release'
assert_eq "$(cat "$TMP/gh.log")" '' 'superseded release skips all GitHub API reads'

reset_gh "$CURRENT_CARD" "$LATEST_201"
MISMATCH_OUTPUT="$TMP/mismatch-output"
if env "${common[@]}" LATEST_STABLE_ID=201 RELEASE_TAG=v9.9.9 GITHUB_OUTPUT="$MISMATCH_OUTPUT" GH_FIXTURE_DIR="$TMP/gh-fixtures" GH_LATEST_STATE_FILE="$TMP/latest-state" GH_CALL_LOG="$TMP/gh.log" "$ROOT/scripts/release-train.sh" >/dev/null 2>&1; then
  fail 'tag/VERSION mismatch must fail the run'
fi
pass 'tag that disagrees with VERSION still fails the run'
assert_announce_false_only "$MISMATCH_OUTPUT" 'tag/VERSION mismatch'

# Nothing in this repository may regain marketplace write authority.
grep -Fq 'HOV_MARKETPLACE_DEPLOY_KEY' "$ROOT/.github/workflows/release-train.yml" \
  && fail 'workflow still references the retired deploy key'
pass 'workflow carries no marketplace deploy key'
grep -Eq 'git push' "$ROOT/scripts/release-train.sh" \
  && fail 'release script still pushes'
pass 'release script never pushes'

CHK="$ROOT/scripts/check-release-notes.sh"
chk() { printf '%s' "$1" | bash "$CHK" - >/dev/null 2>&1; }
WF="$ROOT/.github/workflows/release-train.yml"
ANCESTRY_LINE="$(grep -n 'merge-base --is-ancestor' "$WF" | cut -d: -f1)"
CHECKER_LINE="$(grep -n 'check-release-notes.sh' "$WF" | head -1 | cut -d: -f1)"
PROVISION_LINE="$(grep -n 'provision-ci-tools.sh' "$WF" | head -1 | cut -d: -f1)"
[ -n "$ANCESTRY_LINE" ] && [ -n "$CHECKER_LINE" ] && [ "$CHECKER_LINE" -gt "$ANCESTRY_LINE" ] \
  && pass 'the notes checker runs after protected-branch ancestry proof' \
  || fail "tag-sourced checker runs before ancestry proof (checker=$CHECKER_LINE ancestry=$ANCESTRY_LINE)"
[ -n "$PROVISION_LINE" ] && [ "$PROVISION_LINE" -gt "$ANCESTRY_LINE" ] \
  && pass 'tool provisioning also runs after ancestry proof' \
  || fail 'provisioning runs before ancestry proof'

BIG="$(printf '## Highlights\n\n- %s\n\n## Details\n\n%s' \
  'Reviews now earn extra rounds when they are converging, instead of stopping at a flat limit.' \
  "$(for _ in $(seq 1 4000); do echo 'filler line for a long details section'; done)")"
chk "$BIG" && pass 'a long Details section does not break Highlights detection (no SIGPIPE)' \
  || fail 'large body still trips the SIGPIPE/pipefail path'
grep -q 'printf .%s. "\$notes" | grep -q' "$CHK" && fail 'a SIGPIPE-prone pipeline remains' \
  || pass 'no printf|grep -q pipelines remain in the checker'

chk $'## Highlights\n\n- revert: memo-crossbind changes' && fail 'revert: must be rejected' || pass 'revert: is rejected by generic subject detection'
chk $'## Highlights\n\n- deps: bump the oracle bridge to 0.17.0' && fail 'deps: must be rejected' || pass 'deps: is rejected by generic subject detection'
chk $'## Highlights\n\n- chore(release): cut v0.32.0' && fail 'arbitrary scoped type must be rejected' || pass 'an arbitrary scoped commit type is rejected'
chk $'## Highlights\n\n- Reviews stop early when they stop converging: no more burning quota on repeats.' \
  && pass 'prose containing a colon is NOT mistaken for a commit subject' || fail 'false positive on prose with a colon'
chk "$(printf '## Highlights\n\n- Reviews now earn extra rounds automatically,\n  which keeps a converging PR from being cut off.')" \
  && fail 'wrapped bullet must be rejected' || pass 'a wrapped Highlights bullet is rejected'

grep -q 'Require customer-ready notes for a version bump' "$ROOT/.github/workflows/ci.yml" \
  && pass 'PR CI requires notes for a version bump' || fail 'no PR-level version-bump notes gate'
grep -q 'docs/release-notes/v\$version.md' "$ROOT/.github/workflows/ci.yml" \
  && pass 'the version-bump gate resolves the per-version notes file' || fail 'version-bump gate does not resolve the notes file'

SCRIPT="$ROOT/scripts/release-train.sh"
validate_release_policy "$WF" "$SCRIPT"
pass 'historical tag source is data-only while trusted main runs every verifier'
pass 'checked-in release train uses explicit output-gated hardened OIDC policy'

mkdir -p "$TMP/policy"
if ! python3 - "$WF" "$SCRIPT" "$TMP/policy" "$HARDENED_USES" "$RETIRED_SHA" <<'PY'
import sys
from pathlib import Path

workflow_path, script_path, output_dir, hardened_uses, retired_sha = sys.argv[1:]
workflow = Path(workflow_path).read_text()
script = Path(script_path).read_text()
out = Path(output_dir)
uses_line = f"    uses: {hardened_uses}"
assert workflow.count(uses_line) == 1

retired = workflow.replace(uses_line, uses_line.replace(hardened_uses.rsplit("@", 1)[1], retired_sha), 1)
assert retired != workflow and retired_sha in retired
(out / "retired.yml").write_text(retired)

decoy = workflow.replace(
    uses_line,
    f"    uses: attacker/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@{hardened_uses.rsplit('@', 1)[1]}\n"
    f"\n  decoy:\n    uses: {hardened_uses}",
    1,
)
assert decoy != workflow and decoy.count(hardened_uses) == 1 and "\n  decoy:\n" in decoy
(out / "decoy.yml").write_text(decoy)

shadowed = workflow.replace("      id-token: write", "      id-token: read", 1)
assert shadowed != workflow
(out / "shadowed.yml").write_text(shadowed)

no_output = workflow.replace(" && needs.verify.outputs.announce == 'true'", "", 1)
assert no_output != workflow
(out / "no-output.yml").write_text(no_output)

tag_checkout = workflow.replace("ref: ${{ github.event.repository.default_branch }}", "ref: ${{ github.event.release.tag_name }}", 1)
assert tag_checkout != workflow
(out / "tag-checkout.yml").write_text(tag_checkout)

direct_script = script + "\nANNOUNCE_URL=https://attacker.example\nANNOUNCE_SECRET=forbidden-test-fixture\ncurl \"$ANNOUNCE_URL\"\n"
assert direct_script != script and "ANNOUNCE_URL" in direct_script and "ANNOUNCE_SECRET" in direct_script and "curl \"$ANNOUNCE_URL\"" in direct_script
(out / "direct-script.sh").write_text(direct_script)
PY
then
  fail 'policy fixture generation failed'
fi
for fixture in retired.yml decoy.yml shadowed.yml no-output.yml tag-checkout.yml direct-script.sh; do
  [[ -s "$TMP/policy/$fixture" ]] || fail "missing generated fixture: $fixture"
done

assert_policy_failure 'retired workflow pin is rejected' \
  'trusted default-branch verifier and explicit announce output are required' "$TMP/policy/retired.yml" "$SCRIPT"
assert_policy_failure 'blessed-SHA decoy cannot hide an attacker announce target' \
  'trusted default-branch verifier and explicit announce output are required' "$TMP/policy/decoy.yml" "$SCRIPT"
assert_policy_failure 'job-level permission shadowing is rejected' \
  'trusted default-branch verifier and explicit announce output are required' "$TMP/policy/shadowed.yml" "$SCRIPT"
assert_policy_failure 'announce cannot run on verify success without explicit output true' \
  'trusted default-branch verifier and explicit announce output are required' "$TMP/policy/no-output.yml" "$SCRIPT"
assert_policy_failure 'tag checkout cannot replace the trusted default-branch verifier' \
  'trusted default-branch verifier and explicit announce output are required' "$TMP/policy/tag-checkout.yml" "$SCRIPT"
assert_policy_failure 'direct secret or URL delivery cannot return in the release script' \
  'direct Tool Drop delivery surface is forbidden' "$WF" "$TMP/policy/direct-script.sh"

echo 'ALL PASS'
