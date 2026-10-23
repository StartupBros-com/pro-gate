#!/usr/bin/env bash
# Exercise the real three callers, including the workflow's actual run block.
# Every gh/git operation is an exact offline double; unexpected commands fail.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
mkdir -p "$TMP/bin" "$TMP/work/dist" "$TMP/work/.claude-plugin" "$TMP/download"
printf '0.1.0\n' > "$TMP/work/VERSION"
printf '{"version":"0.1.0"}\n' > "$TMP/work/.claude-plugin/plugin.json"
printf 'runtime\n' > "$TMP/work/dist/pro-gate-runtime-0.1.0.tar.gz"
(cd "$TMP/work/dist" && sha256sum pro-gate-runtime-0.1.0.tar.gz > pro-gate-runtime-0.1.0.tar.gz.sha256)
# Extract instead of reimplementing the manual publish gate. Stop at the next
# YAML step/key, so a future workflow edit cannot silently extend the fixture.
awk '
  /- name: Publish only when the marketplace card names this release/ { step=1; next }
  step && /^        run: \|$/ { block=1; next }
  block && /^          / { print substr($0,11); next }
  block && /^$/ { print; next }
  block { exit }
' "$ROOT/.github/workflows/publish-staged-release.yml" > "$TMP/manual.sh"
[ -s "$TMP/manual.sh" ] || fail 'manual workflow run block was not found'
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$CALLS"
case "$*" in
  'release view v0.1.0 --json isDraft,isPrerelease')
    printf '{"isDraft":%s,"isPrerelease":false}\n' "$([[ "$STATE" = draft ]] && echo true || echo false)" ;;
  'release view v0.1.0 --json isDraft,isPrerelease --jq if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end') printf '%s\n' "$STATE" ;;
  'release view v0.1.0 --json databaseId --jq .databaseId') echo 201 ;;
  'release upload v0.1.0 dist/pro-gate-runtime-0.1.0.tar.gz dist/pro-gate-runtime-0.1.0.tar.gz.sha256 --clobber') : ;;
  'release download v0.1.0 --dir '* )
    [[ $# = 10 && "$4" = --dir && "$6" = --pattern && "$7" = pro-gate-runtime-0.1.0.tar.gz && "$8" = --pattern && "$9" = pro-gate-runtime-0.1.0.tar.gz.sha256 && "${10}" = --clobber ]] || exit 64
    cp "$WORK"/dist/* "$5/" ;;
  'api -H Accept: application/vnd.github.raw+json repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json')
    [[ "$CASE" != fetch-failure ]] || exit 1
    cat "$CARD" ;;
  'api --paginate repos/StartupBros-com/pro-gate/releases?per_page=100')
    echo '[{"id":201,"published_at":"2026-01-01T00:00:00Z","draft":false,"prerelease":false}]' ;;
  'release edit v0.1.0 --draft=false'|'release edit v0.1.0 --draft=false --latest') : ;;
  *) printf 'unexpected gh command: %s\n' "$*" >&2; exit 64 ;;
esac
GH
cat > "$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "$CALLS"
if [[ "$*" = 'rev-list -n 1 refs/tags/v0.1.0' || "$*" = "-C $WORK rev-parse HEAD" || "$*" = "-C $WORK rev-list -n 1 v0.1.0" ]]; then
  printf '%s\n' "$SOURCE_SHA"
else
  printf 'unexpected git command: %s\n' "$*" >&2
  exit 64
fi
GIT
chmod +x "$TMP/bin/gh" "$TMP/bin/git"
export PATH="$TMP/bin:$PATH" WORK="$TMP/work" CARD="$TMP/card.json" CALLS="$TMP/calls" SOURCE_SHA=1111111111111111111111111111111111111111
export STATE=draft
CURRENT='{"plugins":[{"name":"pro-gate","source":{"source":"url","url":"https://github.com/StartupBros-com/pro-gate.git","sha":"1111111111111111111111111111111111111111"},"metadata":{"version":"0.1.0","releaseTag":"v0.1.0","releaseId":201}}]}'
MANIFEST='gh api -H Accept: application/vnd.github.raw+json repos/StartupBros-com/hov-marketplace/contents/.claude-plugin/marketplace.json'
for caller in package train manual; do
  for CASE in current version tag id sha kind url glob-version duplicate missing type-invalid zero-id empty-kind malformed fetch-failure; do
    export CASE
    case "$CASE" in
      current|fetch-failure) filter='.' ;;
      version) filter='.plugins[0].metadata.version="0.1.1"' ;;
      tag) filter='.plugins[0].metadata.releaseTag="v0.1.1"' ;;
      id) filter='.plugins[0].metadata.releaseId=202' ;;
      sha) filter='.plugins[0].source.sha="2222222222222222222222222222222222222222"' ;;
      kind) filter='.plugins[0].source.source="git"' ;;
      url) filter='.plugins[0].source.url="https://example.test/pro-gate.git"' ;;
      glob-version) filter='.plugins[0].metadata.version="*"' ;;
      duplicate) filter='.plugins += .plugins' ;;
      missing) filter='del(.plugins[0].source)' ;;
      type-invalid) filter='.plugins[0].source.url=7' ;;
      zero-id) filter='.plugins[0].metadata.releaseId=0' ;;
      empty-kind) filter='.plugins[0].source.source=""' ;;
      malformed) filter='.' ;;
    esac
    jq "$filter" <<< "$CURRENT" > "$CARD"
    [[ "$CASE" != malformed ]] || printf 'not-json\n' > "$CARD"
    : > "$CALLS"; : > "$TMP/announce"; : > "$TMP/summary"
    rc=0
    case "$caller" in
      package) (cd "$WORK"; GITHUB_STEP_SUMMARY="$TMP/summary" bash "$ROOT/scripts/publish-runtime-release.sh") > "$TMP/out" 2>&1 || rc=$? ;;
      train) env EVENT_ACTION=published REPOSITORY=pro-gate RELEASE_REPOSITORY=StartupBros-com/pro-gate RELEASE_ID=201 RELEASE_TAG=v0.1.0 LATEST_STABLE_ID=201 SOURCE_ROOT="$WORK" ASSET_DIR="$WORK/dist" GITHUB_OUTPUT="$TMP/announce" GITHUB_STEP_SUMMARY="$TMP/summary" bash "$ROOT/scripts/release-train.sh" > "$TMP/out" 2>&1 || rc=$? ;;
      manual) (cd "$ROOT"; RELEASE_TAG=v0.1.0 bash "$TMP/manual.sh") > "$TMP/out" 2>&1 || rc=$? ;;
    esac
    invalid=false
    case "$CASE" in duplicate|missing|type-invalid|zero-id|empty-kind|malformed|fetch-failure) invalid=true ;; esac
    expected_rc=1
    if [[ "$CASE" = current || ( "$caller" = package && "$invalid" = false ) ]]; then expected_rc=0; fi
    [[ "$rc" = "$expected_rc" ]] || { cat "$TMP/out" >&2; fail "$caller/$CASE exit $rc, expected $expected_rc"; }
    # Check every command, its order, and flags; normalize only the generated
    # download directory. --latest belongs to the manual workflow alone.
    case "$caller" in
      package)
        cat > "$TMP/expected" <<EOF
gh release view v0.1.0 --json isDraft,isPrerelease
gh release upload v0.1.0 dist/pro-gate-runtime-0.1.0.tar.gz dist/pro-gate-runtime-0.1.0.tar.gz.sha256 --clobber
gh release download v0.1.0 --dir <download> --pattern pro-gate-runtime-0.1.0.tar.gz --pattern pro-gate-runtime-0.1.0.tar.gz.sha256 --clobber
gh release view v0.1.0 --json databaseId --jq .databaseId
$MANIFEST
EOF
        [[ "$CASE" != current ]] || echo 'gh release edit v0.1.0 --draft=false' >> "$TMP/expected"
        ;;
      train)
        printf 'git -C %s rev-parse HEAD\ngit -C %s rev-list -n 1 v0.1.0\n%s\n' "$WORK" "$WORK" "$MANIFEST" > "$TMP/expected"
        [[ "$CASE" != current ]] || echo 'gh api --paginate repos/StartupBros-com/pro-gate/releases?per_page=100' >> "$TMP/expected"
        expected_announce='announce=false'
        [[ "$CASE" != current ]] || expected_announce=$'announce=false\nannounce=true'
        [[ "$(cat "$TMP/announce")" = "$expected_announce" ]] || fail "$caller/$CASE announce output"
        ;;
      manual)
        cat > "$TMP/expected" <<EOF
gh release view v0.1.0 --json isDraft,isPrerelease --jq if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end
gh release view v0.1.0 --json databaseId --jq .databaseId
git rev-list -n 1 refs/tags/v0.1.0
$MANIFEST
EOF
        [[ "$CASE" != current ]] || echo 'gh release edit v0.1.0 --draft=false --latest' >> "$TMP/expected"
        ;;
    esac
    sed -E 's@(--dir )[^ ]+@\1<download>@' "$CALLS" > "$TMP/actual"
    diff -u "$TMP/expected" "$TMP/actual" || fail "$caller/$CASE command sequence changed"
    if [[ "$invalid" = true ]]; then
      grep -Eq 'UNVERIFIED|outage or parse failure' "$TMP/out" || fail "$caller/$CASE loses unverified diagnostic"
      ! grep -q '===.*repin needed' "$TMP/out" || fail "$caller/$CASE conflates invalid with stale"
    elif [[ "$CASE" != current ]]; then
      case "$caller" in
        package) grep -q 'staged as a draft: marketplace repin needed before publish' "$TMP/out" || fail 'package stale diagnostic' ;;
        train) grep -q 'NOT distributed' "$TMP/out" || fail 'train stale diagnostic' ;;
        manual) grep -q 'Merge the repin PR' "$TMP/out" || fail 'manual stale diagnostic' ;;
      esac
    fi
    printf 'ok - marketplace release contract %s/%s\n' "$caller" "$CASE"
  done
done
