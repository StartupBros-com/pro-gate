#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PLUGIN="pro-gate"
trap 'rm -rf "$TMP"' EXIT

HARDENED_SHA='08f7d22f3a5b59b1658ab2e96a20d0d3c352869c'
RETIRED_SHA='c981b872ebf650805200ad72c8b7142232f8b3f6'
ANNOUNCE_WORKFLOW='StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml'
HARDENED_USES="$ANNOUNCE_WORKFLOW@$HARDENED_SHA"
ANNOUNCE_IF="github.event.release.draft == false && github.event.release.prerelease == false && needs.verify.result == 'success'"

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
    printf 'marketplace deploy key must stay retired
' >&2
    return 1
  fi
  if grep -Eq 'git push .*(marketplace|HEAD:)' "$script"; then
    printf 'release train must never push to the marketplace
' >&2
    return 1
  fi
  jq -e --arg uses "$HARDENED_USES" '.jobs.announce.uses == $uses' <<<"$json" >/dev/null || {
    printf 'announce job must use the hardened immutable workflow\n' >&2
    return 1
  }
  jq -e --arg condition "$ANNOUNCE_IF" '.jobs.announce.if == $condition' <<<"$json" >/dev/null || {
    printf 'announce job must retain the stable release gate\n' >&2
    return 1
  }
  jq -e '.jobs.announce.permissions == {"contents": "read", "id-token": "write"}' <<<"$json" >/dev/null || {
    printf 'announce permissions must be exactly contents read and id-token write\n' >&2
    return 1
  }
  jq -e '(.jobs.announce | keys | sort) == ["if", "name", "needs", "permissions", "uses"]' <<<"$json" >/dev/null || {
    printf 'announce job may not add inputs, secrets, or unrelated behavior\n' >&2
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

mkdir -p "$TMP/source/.claude-plugin" "$TMP/assets"
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
  EVENT_ACTION=published REPOSITORY="$PLUGIN" RELEASE_ID=201 RELEASE_TAG=v0.1.0
  RELEASE_NAME="fixture 0.1.0" RELEASE_URL="https://example.test/r/v0.1.0"
  RELEASE_PRERELEASE=false RELEASE_DRAFT=false LATEST_STABLE_ID=201
  SOURCE_ROOT="$TMP/source" ASSET_DIR="$TMP/assets" SOURCE_SHA="$SOURCE_SHA"
)

# The run must hand over every value the repin PR needs. That is the point of
# retiring the push: the follow-up step becomes mechanical instead of recalled.
out="$(env "${common[@]}" "$ROOT/scripts/release-train.sh")"
for field in "$PLUGIN" 0.1.0 "$SOURCE_SHA" 201 v0.1.0; do
  [[ "$out" == *"$field"* ]] || fail "repin report omits $field"
done
pass 'run reports every value the marketplace repin PR needs'
[[ "$out" == *repin* ]] || fail 'run does not name the repin step'
pass 'run names the repin step explicitly'

# Nothing in this repo may retain the ability to write the marketplace.
grep -Fq 'HOV_MARKETPLACE_DEPLOY_KEY' "$ROOT/.github/workflows/release-train.yml" \
  && fail 'workflow still references the retired deploy key'
pass 'workflow carries no marketplace deploy key'
grep -Eq 'git push' "$ROOT/scripts/release-train.sh" \
  && fail 'release script still pushes'
pass 'release script never pushes'

out="$(env "${common[@]}" RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh")"
[[ "$out" != *"repin needed"* ]] || fail 'prerelease must not request a repin'
pass 'prerelease remains a no-op'

out="$(env "${common[@]}" RELEASE_ID=200 LATEST_STABLE_ID=201 "$ROOT/scripts/release-train.sh")"
[[ "$out" != *"repin needed"* ]] || fail 'superseded release must not request a repin'
pass 'a release that is not latest stable is a no-op'

# Release VERIFICATION is the half deliberately kept: a tag disagreeing with
# VERSION must still fail loudly. A missing VERSION file defeating exactly this
# guard is what silently killed twelve design-rails announcements.
if env "${common[@]}" RELEASE_TAG=v9.9.9 "$ROOT/scripts/release-train.sh" >/dev/null 2>&1; then
  fail 'tag/VERSION mismatch must fail the run'
fi
pass 'tag that disagrees with VERSION still fails the run'

# Both customer feeds derive from the release body. The canonical marketplace
# announcer owns summary generation; this repo owns the earlier authoring gate
# that keeps developer shorthand out of that renderer.
CHK="$ROOT/scripts/check-release-notes.sh"
chk() { printf '%s' "$1" | bash "$CHK" - >/dev/null 2>&1; }

WF="$ROOT/.github/workflows/release-train.yml"
ANCESTRY_LINE="$(grep -n 'merge-base --is-ancestor' "$WF" | cut -d: -f1)"
CHECKER_LINE="$(grep -n 'check-release-notes.sh' "$WF" | head -1 | cut -d: -f1)"
PROVISION_LINE="$(grep -n 'provision-ci-tools.sh' "$WF" | head -1 | cut -d: -f1)"
[ -n "$ANCESTRY_LINE" ] && [ -n "$CHECKER_LINE" ] && [ "$CHECKER_LINE" -gt "$ANCESTRY_LINE" ] \
  && pass 'the notes checker runs AFTER the protected-branch ancestry check' \
  || fail "tag-sourced checker runs before ancestry proof (checker=$CHECKER_LINE ancestry=$ANCESTRY_LINE)"
[ -n "$PROVISION_LINE" ] && [ "$PROVISION_LINE" -gt "$ANCESTRY_LINE" ] \
  && pass 'tool provisioning also runs after the ancestry check' \
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
pass 'checked-in release train uses the hardened OIDC policy'

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

direct_script = script + "\nANNOUNCE_URL=https://attacker.example\nANNOUNCE_SECRET=forbidden-test-fixture\ncurl \"$ANNOUNCE_URL\"\n"
assert direct_script != script and "ANNOUNCE_URL" in direct_script and "ANNOUNCE_SECRET" in direct_script and "curl \"$ANNOUNCE_URL\"" in direct_script
(out / "direct-script.sh").write_text(direct_script)
PY
then
  fail 'policy fixture generation failed'
fi
for fixture in retired.yml decoy.yml shadowed.yml direct-script.sh; do
  [[ -s "$TMP/policy/$fixture" ]] || fail "missing generated fixture: $fixture"
done

assert_policy_failure 'retired workflow pin is rejected' \
  'announce job must use the hardened immutable workflow' "$TMP/policy/retired.yml" "$SCRIPT"
assert_policy_failure 'blessed-SHA decoy cannot hide an attacker announce target' \
  'announce job must use the hardened immutable workflow' "$TMP/policy/decoy.yml" "$SCRIPT"
assert_policy_failure 'job-level permission shadowing is rejected' \
  'announce permissions must be exactly contents read and id-token write' "$TMP/policy/shadowed.yml" "$SCRIPT"
assert_policy_failure 'direct secret or URL delivery cannot return in the release script' \
  'direct Tool Drop delivery surface is forbidden' "$WF" "$TMP/policy/direct-script.sh"

echo 'ALL PASS'
