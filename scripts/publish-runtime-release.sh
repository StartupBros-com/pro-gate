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
  # Prefer hand-written customer copy over GitHub's auto-generated PR titles (#69 gate P1).
  # --generate-notes is what shipped "governor-rounds" and "memo-crossbind" as the What's New
  # bullets on v0.31.0/v0.31.1: the announcement feeds read this body, so auto-notes put
  # branch names in front of customers. docs/release-notes/v<version>.md is the source of
  # truth when present; auto-notes remain the fallback so a release is never BLOCKED on
  # prose (shipping must not depend on copy — see release-train's warn-only check).
  notes_file="docs/release-notes/v$version.md"
  if [ -s "$notes_file" ] && ./scripts/check-release-notes.sh "$notes_file" >/dev/null 2>&1; then
    gh release create "$tag" --draft --title "$tag" --notes-file "$notes_file"
  else
    if [ -s "$notes_file" ]; then
      printf 'warning: %s exists but is not customer-ready; falling back to auto-notes\n' "$notes_file" >&2
      ./scripts/check-release-notes.sh "$notes_file" >&2 || true
    else
      printf 'warning: no %s — announcing auto-generated PR titles; see docs/RELEASE-NOTES-TEMPLATE.md\n' "$notes_file" >&2
    fi
    gh release create "$tag" --draft --title "$tag" --generate-notes
  fi
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
