#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
MANIFEST_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"
TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:-v$VERSION}}"
TAG_VERSION="${TAG#v}"
OUT="${1:-$ROOT/dist}"

case "$VERSION" in ''|*[!0-9A-Za-z.-]*) echo "invalid VERSION: $VERSION" >&2; exit 1;; esac
if [ "$VERSION" != "$MANIFEST_VERSION" ] || [ "$VERSION" != "$TAG_VERSION" ]; then
  echo "release version mismatch: tag=$TAG_VERSION VERSION=$VERSION manifest=$MANIFEST_VERSION" >&2
  exit 1
fi

mkdir -p "$OUT"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pro-gate-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/pro-gate-runtime-$VERSION"
mkdir -p "$PKG/bin" "$PKG/daemon" "$PKG/lib"
cp "$ROOT/VERSION" "$ROOT/install.sh" "$ROOT/.env.example" "$PKG/"
cp "$ROOT/bin/"* "$PKG/bin/"
cp "$ROOT/daemon/"* "$PKG/daemon/"
cp "$ROOT/lib/pro-gate-lib.sh" "$PKG/lib/"

# The plugin-owned copy is the adapter expectation. Package a byte-identical runtime copy,
# generated from the compiled library constants, so the installer can prove both sides before
# touching a live runtime. It is compatibility metadata, never reducer input.
. "$ROOT/lib/pro-gate-lib.sh"
EXPECTED_IDENTITY="$(pg_review_decision_identity_json)"
printf '%s' "$EXPECTED_IDENTITY" > "$PKG/review-decision-v1.json"
cmp -s "$ROOT/skills/pro-gate/review-decision-v1.json" "$PKG/review-decision-v1.json" || {
  echo "plugin review-decision identity does not match library constants" >&2
  exit 1
}
[ ! -e "$PKG/skills" ] && [ ! -e "$PKG/agents" ] && [ ! -e "$PKG/.claude-plugin" ] || {
  echo "runtime package must not contain plugin-owned skill, agent, or manifest" >&2
  exit 1
}
ARCHIVE="$OUT/pro-gate-runtime-$VERSION.tar.gz"
tar -C "$STAGE" --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -czf "$ARCHIVE" "pro-gate-runtime-$VERSION"
ARCHIVE_LIST="$STAGE/archive.list"
tar -tzf "$ARCHIVE" > "$ARCHIVE_LIST"
grep -Fxq "pro-gate-runtime-$VERSION/review-decision-v1.json" "$ARCHIVE_LIST" || {
  echo "runtime archive is missing review-decision identity metadata" >&2
  exit 1
}
[ "$(grep -Fc "pro-gate-runtime-$VERSION/review-decision-v1.json" "$ARCHIVE_LIST")" = 1 ] || {
  echo "runtime archive contains duplicate review-decision identity metadata" >&2
  exit 1
}
if grep -Eq '/(skills|agents|\.claude-plugin)(/|$)' "$ARCHIVE_LIST"; then
  echo "runtime archive contains plugin-owned skill, agent, or manifest" >&2
  exit 1
fi
EXTRACTED_IDENTITY="$STAGE/extracted-identity.json"
tar -xOf "$ARCHIVE" "pro-gate-runtime-$VERSION/review-decision-v1.json" > "$EXTRACTED_IDENTITY"
cmp -s "$PKG/review-decision-v1.json" "$EXTRACTED_IDENTITY" || {
  echo "runtime archive identity metadata differs from staged metadata" >&2
  exit 1
}
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUT" && sha256sum "$(basename "$ARCHIVE")") > "$ARCHIVE.sha256"
elif command -v shasum >/dev/null 2>&1; then
  digest="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
  printf '%s  %s\n' "$digest" "$(basename "$ARCHIVE")" > "$ARCHIVE.sha256"
else
  echo "SHA256 tool required" >&2
  exit 1
fi
printf '%s\n' "$ARCHIVE"
