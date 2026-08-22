#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass(){ printf 'ok - %s\n' "$1"; }
fail(){ printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq(){ [ "$1" = "$2" ] || fail "$3: expected $2, got $1"; pass "$3"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 3 && "$1" == api && "$2" == --paginate && "$3" == 'repos/owner/repo/releases?per_page=100' ]]; then
  printf '%s\n' "$GH_PAGES"
  exit 0
fi
exit 64
EOF
chmod +x "$TMP/bin/gh"
resolve_stable() {
  PATH="$TMP/bin:$PATH" GH_PAGES="$1" "$ROOT/scripts/latest-stable-release.sh" owner/repo
}
assert_resolver_failure() {
  local pages="$1" label="$2" output
  if output="$(resolve_stable "$pages" 2>&1)"; then
    fail "$label must fail closed"
  fi
  [[ "$output" == *'stable release has invalid published_at or id'* ]] || fail "$label does not report invalid stable publication metadata"
  pass "$label fails closed"
}

# Publication time, rather than creation time, decides which release is current.
# Equal publication times break only on numeric release ID. Draft/prerelease
# records are ignored even if their publication data is absent or newer.
GH_PAGES='[{"id":9,"created_at":"2026-12-01T00:00:00Z","published_at":"2026-02-01T00:00:00Z","draft":false,"prerelease":false},{"id":12,"draft":true,"prerelease":false}]
[{"id":10,"created_at":"2020-01-01T00:00:00Z","published_at":"2026-03-01T00:00:00Z","draft":false,"prerelease":false},{"id":13,"created_at":"2019-01-01T00:00:00Z","published_at":"2026-03-01T00:00:00Z","draft":false,"prerelease":false},{"id":99,"published_at":"2099-01-01T00:00:00Z","draft":false,"prerelease":true}]'
assert_eq "$(resolve_stable "$GH_PAGES")" 13 'latest stable uses published_at globally with numeric ID tie-breaker'

assert_resolver_failure '[{"id":17,"draft":false,"prerelease":false}]' 'missing published_at on a stable release'
assert_resolver_failure '[{"id":17,"published_at":"not-a-date","draft":false,"prerelease":false}]' 'malformed published_at on a stable release'
assert_resolver_failure '[{"id":17.5,"published_at":"2026-03-01T00:00:00Z","draft":false,"prerelease":false}]' 'non-integer ID on a stable release'
if output="$(resolve_stable '[{"id":17,"draft":true,"prerelease":false}]' 2>&1)"; then
  fail 'an all-draft release list must fail closed'
fi
[[ "$output" == *'no published stable releases'* ]] || fail 'all-draft list does not report missing stable release'
pass 'all-draft release list fails closed'

if PATH="$TMP/bin:$PATH" "$TMP/bin/gh" api --paginate 'repos/owner/repo/releases?per_page=100' --method GET >/dev/null 2>&1; then
  fail 'latest-release fixture accepts method/body drift'
fi
pass 'latest-release fixture accepts only the modeled paginated API request'

WORK="$TMP/work"; mkdir -p "$WORK/dist" "$TMP/release"; cp "$ROOT/VERSION" "$WORK/VERSION"
VERSION="$(tr -d '[:space:]' < "$WORK/VERSION")"
printf 'runtime\n' > "$WORK/dist/pro-gate-runtime-$VERSION.tar.gz"
(cd "$WORK/dist" && sha256sum "pro-gate-runtime-$VERSION.tar.gz" > "pro-gate-runtime-$VERSION.tar.gz.sha256")

FAKE_SHA=1111111111111111111111111111111111111111
FAKE_ID=4242

# Mock gh: models release state in $GH_STATE and serves the marketplace manifest
# from $MKT_FIXTURE so the draft-first publish gate can be driven without network.
cat > "$TMP/bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -e
printf "%s\n" "$*" >> "$GH_LOG"
if [ "$1" = api ]; then
  [ -f "$MKT_FIXTURE" ] || exit 1
  cat "$MKT_FIXTURE"
  exit 0
fi
cmd="$1 $2"
case "$cmd" in
  "release view")
    [ -f "$GH_STATE" ] || exit 1
    case "$*" in
      *databaseId*) printf "%s\n" "$FAKE_ID" ;;
      *) printf "{\"isDraft\":%s,\"isPrerelease\":false}\n" "$(cat "$GH_STATE")" ;;
    esac ;;
  "release create") printf true > "$GH_STATE" ;;
  "release upload") shift 3; for f in "$@"; do [ "$f" = --clobber ] || cp "$f" "$GH_RELEASE/"; done ;;
  "release download") shift 3; dest=""; while [ $# -gt 0 ]; do case "$1" in --dir) dest="$2"; shift 2;; --pattern) cp "$GH_RELEASE/$2" "$dest/"; shift 2;; *) shift;; esac; done ;;
  "release edit") printf false > "$GH_STATE" ;;
esac
MOCKGH
chmod +x "$TMP/bin/gh"

write_card() { # $1 = version, $2 = tag, $3 = id, $4 = sha
  printf '{"plugins":[{"name":"pro-gate","source":{"source":"url","url":"https://github.com/StartupBros-com/pro-gate.git","sha":"%s"},"metadata":{"version":"%s","releaseId":%s,"releaseTag":"%s"}}]}\n' \
    "$4" "$1" "$3" "$2" > "$TMP/marketplace.json"
}

run_publish() {
  (
    cd "$WORK"
    PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" GH_STATE="$TMP/state" GH_RELEASE="$TMP/release" \
      MKT_FIXTURE="$TMP/marketplace.json" FAKE_ID="$FAKE_ID" SOURCE_SHA="$FAKE_SHA" \
      "$ROOT/scripts/publish-runtime-release.sh"
  )
}

# STALE card: the normal pre-repin state. Assets must still be uploaded and
# verified, the release must stay a DRAFT, and the run must stay green.
write_card '0.0.1' 'v0.0.1' 1 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
run_publish > "$TMP/stale.out" 2>&1 || fail 'a stale card must not fail the publish helper'
assert_eq "$(cat "$TMP/state")" true 'stale marketplace card leaves the release a draft'
assert_eq "$(grep -c '^release edit ' "$TMP/gh.log")" 0 'stale card never publishes'
grep -q 'repin needed before publish' "$TMP/stale.out" || fail 'stale card does not report the repin tuple'
grep -q "releaseId   $FAKE_ID" "$TMP/stale.out" || fail 'repin report omits the releaseId the card needs'

# CURRENT card: the repin merged, so this run publishes exactly once.
write_card "$VERSION" "v$VERSION" "$FAKE_ID" "$FAKE_SHA"
run_publish > "$TMP/current.out" 2>&1 || fail 'a current card must allow publish'
assert_eq "$(cat "$TMP/state")" false 'current marketplace card publishes the release'
assert_eq "$(grep -c '^release edit ' "$TMP/gh.log")" 1 'publish happens exactly once'

# Rerun after publish stays idempotent and still refreshes the exact assets.
run_publish > /dev/null 2>&1 || fail 'rerun after publish must stay green'
assert_eq "$(grep -c '^release edit ' "$TMP/gh.log")" 1 'published rerun is idempotent'
assert_eq "$(grep -c '^release upload ' "$TMP/gh.log")" 3 'rerun refreshes exact assets'

# UNVERIFIED card: a read failure is never grounds to publish.
printf true > "$TMP/state"
rm -f "$TMP/marketplace.json"
if run_publish > "$TMP/unverified.out" 2>&1; then
  fail 'an unreadable marketplace card must not pass silently'
fi
assert_eq "$(cat "$TMP/state")" true 'unreadable card leaves the release a draft'
grep -q 'refusing to publish' "$TMP/unverified.out" || fail 'unreadable card does not explain the refusal'

grep -q 'runs-on: ubuntu-24.04' "$ROOT/.github/workflows/ci.yml" || fail 'CI uses GitHub-hosted runner'; pass 'CI uses GitHub-hosted runner'
grep -q 'runs-on: \[self-hosted' "$ROOT/.github/workflows/ci.yml" && fail 'PR CI retains persistent runner'; pass 'PR CI never executes persistent runner'
# The bot git identity existed only to author marketplace promotion commits.
# That push is retired, so the identity must be gone too — its presence would
# mean a write path came back.
! grep -q 'github-actions\[bot\]' "$ROOT/.github/workflows/release-train.yml" || fail 'marketplace commit identity must stay retired'; pass 'no marketplace commit identity remains'
grep -q 'publish-runtime-release.sh' "$ROOT/.github/workflows/release.yml" || fail 'release workflow uses extracted helper'; pass 'release workflow uses extracted helper'

# Draft-first contracts. The publish gate and the post-publish distribution guard
# must keep reading the card through ONE helper: two copies of this check drifting
# apart is how a release ships undistributed while a green run says otherwise.
grep -q 'lib/marketplace-card.sh' "$ROOT/scripts/publish-runtime-release.sh" \
  || fail 'publish helper must read the card through the shared library'
pass 'publish helper reads the card through the shared library'
grep -q 'lib/marketplace-card.sh' "$ROOT/scripts/release-train.sh" \
  || fail 'release train must read the card through the shared library'
pass 'release train reads the card through the shared library'
grep -q 'jq -er --arg name' "$ROOT/scripts/lib/marketplace-card.sh" \
  || fail 'shared library must retain the typed exact-one card validation'
pass 'shared library retains typed exact-one card validation'
[ -f "$ROOT/.github/workflows/publish-staged-release.yml" ] \
  || fail 'a staged release needs a publish path'
pass 'staged releases have a publish workflow'
grep -q 'marketplace_card_tuple' "$ROOT/.github/workflows/publish-staged-release.yml" \
  || fail 'the publish workflow must re-verify the card before publishing'
pass 'publish workflow re-verifies the card before publishing'
# A staged draft is the expected pre-repin state; reporting it as breakage every
# release is how a warning channel gets tuned out.
grep -q 'staged as a draft with complete assets' "$ROOT/.github/workflows/auto-release.yml" \
  || fail 'auto-release must report a staged draft as expected, not incomplete'
pass 'auto-release reports a staged draft as expected state'

echo 'ALL PASS'
