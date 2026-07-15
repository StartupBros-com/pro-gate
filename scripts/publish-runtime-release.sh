#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

version="$(tr -d '[:space:]' < VERSION)"
tag="v$version"
runtime="dist/pro-gate-runtime-$version.tar.gz"
checksum="$runtime.sha256"

[ -s "$runtime" ] || fail "runtime asset is missing: $runtime"
[ -s "$checksum" ] || fail "checksum asset is missing: $checksum"
(cd "$(dirname "$runtime")" && sha256sum -c "$(basename "$checksum")")

state=""
if release_json="$(gh release view "$tag" --json isDraft,isPrerelease 2>/dev/null)"; then
  state="$(jq -er 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end' <<<"$release_json")"
else
  gh release create "$tag" --draft --title "$tag" --generate-notes
  state=draft
fi

# Uploading with --clobber makes interrupted and repeated runs converge on the
# exact locally verified assets, including the checksum file.
gh release upload "$tag" "$runtime" "$checksum" --clobber
verify_dir="$(mktemp -d)"
trap 'rm -rf "$verify_dir"' EXIT
gh release download "$tag" --dir "$verify_dir" \
  --pattern "$(basename "$runtime")" --pattern "$(basename "$checksum")" --clobber
(
  cd "$verify_dir"
  [ -s "$(basename "$runtime")" ] || fail "uploaded runtime could not be downloaded"
  [ -s "$(basename "$checksum")" ] || fail "uploaded checksum could not be downloaded"
  sha256sum -c "$(basename "$checksum")"
)

if [ "$state" = draft ]; then
  gh release edit "$tag" --draft=false
fi
