#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected $2, got $1"; pass "$3"; }

mkdir -p "$TMP/bin" "$TMP/source/.claude-plugin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CURL_LOG"\n' > "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
printf '{"name":"pro-gate","version":"0.1.0"}\n' > "$TMP/source/.claude-plugin/plugin.json"
git -C "$TMP/source" init -q
git -C "$TMP/source" config user.email test@example.com
git -C "$TMP/source" config user.name Test
git -C "$TMP/source" add .
git -C "$TMP/source" commit -qm source
printf '0.1.0\n' > "$TMP/source/VERSION"
git -C "$TMP/source" add VERSION
git -C "$TMP/source" commit -qm version
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
common=(
  EVENT_ACTION=published REPOSITORY=pro-gate RELEASE_ID=201 RELEASE_TAG=v0.1.0
  RELEASE_NAME='Pro Gate 0.1.0' RELEASE_URL='https://github.com/StartupBros-com/pro-gate/releases/tag/v0.1.0'
  RELEASE_PRERELEASE=false RELEASE_DRAFT=false LATEST_STABLE_ID=201 SOURCE_ROOT="$TMP/source" ASSET_DIR="$TMP/assets"
  SOURCE_SHA="$SOURCE_SHA" MARKETPLACE_DIR="$TMP/marketplace" ANNOUNCE_URL=https://example.test/tool-releases
  ANNOUNCE_SECRET=test-secret
)
env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
fresh="$TMP/fresh"
git clone -q "$TMP/marketplace.git" "$fresh"
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$fresh/.claude-plugin/marketplace.json")" 201 'stable latest release promotes'
assert_eq "$(wc -l < "$TMP/curl.log")" 1 'promotion announces once'

env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'rerun calls idempotent announce operation'

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
assert_eq "$(wc -l < "$TMP/retry-curl.log")" 1 'retry announces only after remote promotion'

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
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'older release no-op does not announce'

env "${common[@]}" RELEASE_ID=202 LATEST_STABLE_ID=202 RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'prerelease is ignored'

env "${common[@]}" EVENT_ACTION=edited "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 3 'edited release announces when marketplace exactly matches'

env "${common[@]}" EVENT_ACTION=edited RELEASE_ID=202 LATEST_STABLE_ID=202 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 4 'newly stable edited release promotes and announces once'
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$TMP/marketplace/.claude-plugin/marketplace.json")" 202 'newly stable edited release advances marketplace'

env "${common[@]}" EVENT_ACTION=edited RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 4 'edited prerelease remains production no-op'

# --- notes_summary: card-ready bullets for the What's-new announcement section ---
ns() { RELEASE_NOTES="$1" bash -c "source <(sed -n '/^notes_summary()/,/^}/p' '$ROOT/scripts/release-train.sh'); notes_summary"; }
AUTO=$'## What\'s Changed\n* feat(pro-gate): capture provenance (v0.28.0) by @StartupBros in https://github.com/x/y/pull/54\n* fix(pro-gate): idempotent harvests by @StartupBros in https://github.com/x/y/pull/55\n\n**Full Changelog**: https://github.com/x/y/compare/a...b'
assert_eq "$(ns "$AUTO")" $'capture provenance\nidempotent harvests' 'auto-notes bullets are cleaned (prefix, author, link, version stripped)'
HL=$'## Highlights\n* Hand-picked line one\n* Hand-picked line two\n\n## What\'s Changed\n* feat: noise by @u in https://x'
assert_eq "$(ns "$HL")" $'Hand-picked line one\nHand-picked line two' 'an author-written Highlights section wins over auto-notes'
PROSE=$'A prose lead paragraph.\nStill the lead.\n\nSecond paragraph never announced.'
assert_eq "$(ns "$PROSE")" 'A prose lead paragraph. Still the lead. ' 'prose bodies fall back to the flattened first paragraph'
MANY=$'* one\n* two\n* three\n* four'
assert_eq "$(ns "$MANY")" $'one\ntwo\nthree' 'bullets cap at three'
assert_eq "$(ns '')" '' 'empty notes stay empty'
CONTRIB="$(printf '%s\n' "## What's Changed" '* feat: real change by @u in https://x/pull/1' '' '## New Contributors' '* @newbie made their first contribution in https://x/pull/1')"
assert_eq "$(ns "$CONTRIB")" 'real change' 'contributor-section bullets never become highlights'
PROSEB="$(printf '%s\n' 'A prose lead.' '' 'Install steps:' '* run the installer' '* sign in')"
assert_eq "$(ns "$PROSEB")" 'A prose lead. ' 'later install bullets do not hijack a prose body'
CJK="$(printf '* %s' "$(python3 -c "print('测' * 200)")")"
CJK_OUT="$(ns "$CJK")"
assert_eq "$(printf '%s' "$CJK_OUT" | python3 -c 'import sys; print(len(sys.stdin.read()))')" '180' 'multibyte bullets slice at 180 CHARACTERS'
printf '%s' "$CJK_OUT" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' && pass 'sliced multibyte output is valid UTF-8'

# ── customer-readiness gate (scripts/check-release-notes.sh) ─────────────────────────────
# Both customer feeds derive from the release body, so a missing/lazy Highlights section
# ships developer shorthand to House of Vibe customers. v0.31.0 and v0.31.1 announced
# "governor-rounds" and "memo-crossbind" exactly this way; these cases lock that out.
CHK="$ROOT/scripts/check-release-notes.sh"
chk() { printf '%s' "$1" | bash "$CHK" - >/dev/null 2>&1; }

# The REAL v0.31.0 body that shipped: the regression this gate exists for.
SHIPPED=$'## What\'s Changed\n* governor-rounds by @StartupBros in https://github.com/StartupBros-com/pro-gate/pull/66\n\n**Full Changelog**: https://x/y'
chk "$SHIPPED" && fail 'the shipped v0.31.0 body must be rejected' || pass 'the auto-generated body that shipped is rejected'

GOOD=$'## Highlights\n\n- Reviews that keep making progress now earn extra rounds automatically, instead of stopping at a flat limit.\n- Reviews going in circles stop early rather than burning your remaining quota.\n\n## Upgrade\n\nNothing to do.'
chk "$GOOD" && pass 'well-written customer notes pass' || fail 'good notes were rejected'

chk $'## Highlights\n\n## Upgrade\n\nNothing.' && fail 'empty Highlights must be rejected' || pass 'an empty Highlights section is rejected'
chk $'## Highlights\n\n- feat(pro-gate): trajectory-aware round governor with churn brake' && fail 'raw commit subject must be rejected' || pass 'a raw conventional-commit subject is rejected'
chk $'## Highlights\n\n- memo-crossbind' && fail 'branch name must be rejected' || pass 'a bare branch-name bullet is rejected'
chk $'## Highlights\n\n- Fixed the stuck-review problem reported in #67 by users last week.' && fail 'issue ref must be rejected' || pass 'an issue/PR reference in Highlights is rejected'
chk "$(printf '## Highlights\n\n- %s' "$(python3 -c "print('x' * 200)")")" && fail 'over-long bullet must be rejected' || pass 'a bullet past the 180-char feed limit is rejected'
chk $'## Highlights\n\n- Faster now.' && fail 'stub bullet must be rejected' || pass 'a too-short stub bullet is rejected'

# The gate must agree with the announcer: what passes the check is what customers receive.
assert_eq "$(ns "$GOOD")" $'Reviews that keep making progress now earn extra rounds automatically, instead of stopping at a flat limit.\nReviews going in circles stop early rather than burning your remaining quota.' \
  'notes that pass the gate produce exactly those announcement bullets'

# #69 gate P2: the checker must validate the NORMALIZED bytes the announcer sends. A
# breaking-change prefix (feat!:) passed the raw-line check, then notes_summary stripped it and
# shipped the bare branch name — the exact failure this gate exists to prevent.
chk $'## Highlights\n\n- feat!: memo-crossbind' && fail 'feat!: prefix must be rejected' || pass 'a scope-less breaking-change prefix is rejected after normalization'
chk $'## Highlights\n\n- fix(pro-gate)!: governor-rounds' && fail 'scoped feat!: must be rejected' || pass 'a scoped breaking-change prefix is rejected after normalization'
chk $'## Highlights\n\n- governor-rounds   ' && fail 'trailing-space branch name must be rejected' || pass 'a trailing-whitespace branch name is rejected'
# The normalization must MATCH notes_summary exactly, or the gate inspects different bytes
# than customers receive. Anything the checker accepts must survive the announcer unchanged.
assert_eq "$(ns $'## Highlights\n- Reviews that keep making progress now earn extra rounds automatically, instead of a flat limit.')" \
  'Reviews that keep making progress now earn extra rounds automatically, instead of a flat limit.' \
  'checker-normalized text and announcer output agree'

# #69 gate P1: the release is CREATED with real copy when an archived notes file exists, so
# bad copy is not the default. Guard the wiring rather than re-running gh.
grep -q 'notes-file' "$ROOT/scripts/publish-runtime-release.sh" \
  && pass 'publish-runtime-release prefers a hand-written notes file' \
  || fail 'publish-runtime-release still only auto-generates notes'
grep -q 'docs/release-notes/v\$version.md' "$ROOT/scripts/publish-runtime-release.sh" \
  && pass 'the notes file is resolved per version' \
  || fail 'no per-version notes file lookup'

# #69 gate P0: nothing executed from the CHECKED-OUT TAG may run before the ancestry check
# that proves the tag descends from protected main — that job later holds the marketplace
# deploy key and the announcement secret.
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

echo 'ALL PASS'
