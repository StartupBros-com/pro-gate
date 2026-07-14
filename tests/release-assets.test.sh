#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass(){ printf 'ok - %s\n' "$1"; }
fail(){ printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq(){ [ "$1" = "$2" ] || fail "$3: expected $2, got $1"; pass "$3"; }

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nif [ "$1" = api ]; then printf "%%s\\n" "$GH_PAGES"; exit; fi\nexit 2\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
GH_PAGES='[{"id":9,"created_at":"2026-01-01T00:00:00Z","draft":false,"prerelease":false},{"id":12,"created_at":"2026-03-01T00:00:00Z","draft":true,"prerelease":false}]
[{"id":10,"created_at":"2026-02-01T00:00:00Z","draft":false,"prerelease":false},{"id":11,"created_at":"2026-04-01T00:00:00Z","draft":false,"prerelease":true}]'
assert_eq "$(PATH="$TMP/bin:$PATH" GH_PAGES="$GH_PAGES" "$ROOT/scripts/latest-stable-release.sh" owner/repo)" 10 'latest stable resolves globally across pages'

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
grep -q 'github-actions\[bot\]' "$ROOT/.github/workflows/release-train.yml" || fail 'marketplace identity is configured'; pass 'marketplace identity is configured'
grep -q 'publish-runtime-release.sh' "$ROOT/.github/workflows/release.yml" || fail 'release workflow uses extracted helper'; pass 'release workflow uses extracted helper'

echo 'ALL PASS'
