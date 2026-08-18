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
printf '#!/usr/bin/env bash\nset -e\nprintf "%%s\\n" "$*" >> "$GH_LOG"\ncmd="$1 $2"\ncase "$cmd" in\n  "release view") [ -f "$GH_STATE" ] || exit 1; printf "{\\"isDraft\\":%%s,\\"isPrerelease\\":false}\\n" "$(cat "$GH_STATE")" ;;\n  "release create") printf true > "$GH_STATE" ;;\n  "release upload") shift 3; for f in "$@"; do [ "$f" = --clobber ] || cp "$f" "$GH_RELEASE/"; done ;;\n  "release download") shift 3; dest=""; while [ $# -gt 0 ]; do case "$1" in --dir) dest="$2"; shift 2;; --pattern) cp "$GH_RELEASE/$2" "$dest/"; shift 2;; *) shift;; esac; done ;;\n  "release edit") printf false > "$GH_STATE" ;;\nesac\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
(
  cd "$WORK"
  PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" GH_STATE="$TMP/state" GH_RELEASE="$TMP/release" "$ROOT/scripts/publish-runtime-release.sh"
  PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" GH_STATE="$TMP/state" GH_RELEASE="$TMP/release" "$ROOT/scripts/publish-runtime-release.sh"
)
assert_eq "$(cat "$TMP/state")" false 'release helper publishes only after verification'
assert_eq "$(grep -c '^release edit ' "$TMP/gh.log")" 1 'published rerun is idempotent'
assert_eq "$(grep -c '^release upload ' "$TMP/gh.log")" 2 'rerun refreshes exact assets'

grep -q 'runs-on: ubuntu-24.04' "$ROOT/.github/workflows/ci.yml" || fail 'CI uses GitHub-hosted runner'; pass 'CI uses GitHub-hosted runner'
grep -q 'runs-on: \[self-hosted' "$ROOT/.github/workflows/ci.yml" && fail 'PR CI retains persistent runner'; pass 'PR CI never executes persistent runner'
# The bot git identity existed only to author marketplace promotion commits.
# That push is retired, so the identity must be gone too — its presence would
# mean a write path came back.
! grep -q 'github-actions\[bot\]' "$ROOT/.github/workflows/release-train.yml" || fail 'marketplace commit identity must stay retired'; pass 'no marketplace commit identity remains'
grep -q 'publish-runtime-release.sh' "$ROOT/.github/workflows/release.yml" || fail 'release workflow uses extracted helper'; pass 'release workflow uses extracted helper'

echo 'ALL PASS'
