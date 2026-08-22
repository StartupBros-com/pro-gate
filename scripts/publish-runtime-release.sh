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

# Draft-first (hov-marketplace docs/plugin-release-recipe.md). Publishing here
# unconditionally is the whole auto-release defect: the publish event fires the
# announce immediately, but the marketplace card cannot possibly name this
# release yet — the repin PR needs the releaseId that was only just minted
# above. So every release went out, failed its own distribution guard, and
# needed a manual repin plus an announce re-fire. Staying draft until the card
# is current dissolves that: the single publish-event announce then finds the
# card already correct, exactly as the recipe intends.
#
# Failure policy differs from release-train.sh on purpose (see
# scripts/lib/marketplace-card.sh): there, a stale card means an already-shipped
# release is undistributed and must go red. Here, a stale card is the NORMAL
# pre-repin state and must stay green — the release is packaged, verified and
# staged, just not distributed yet. An UNVERIFIED card still fails closed:
# "I could not read the card" is never grounds to publish.
if [ "$state" = draft ]; then
  # shellcheck source=scripts/lib/marketplace-card.sh
  . "$(dirname "$0")/lib/marketplace-card.sh"

  # SOURCE_SHA is overridable exactly as in scripts/release-train.sh, so tests
  # can drive this path without a git checkout. Production leaves it unset and
  # resolves the tag itself.
  release_id="$(gh release view "$tag" --json databaseId --jq .databaseId)"
  source_sha="${SOURCE_SHA:-$(git rev-list -n 1 "refs/tags/$tag")}"
  [ -n "$release_id" ] || fail "could not resolve the release id for $tag"
  [ -n "$source_sha" ] || fail "could not resolve the commit for $tag"

  card_rc=0
  card_tuple="$(marketplace_card_tuple 'pro-gate')" || card_rc=$?
  if [ "$card_rc" -ne 0 ]; then
    fail "refusing to publish $tag: could not verify the marketplace card (see above). This is an outage or parse failure, NOT evidence the card is stale; re-run once the read succeeds."
  fi
  IFS=$'\t' read -r card_version card_tag card_id card_sha card_kind card_url <<<"$card_tuple"

  if [ "$card_version" = "$version" ] && [ "$card_tag" = "$tag" ] \
     && [ "$card_id" = "$release_id" ] && [ "$card_sha" = "$source_sha" ] \
     && [ "$card_kind" = 'url' ] \
     && [ "$card_url" = 'https://github.com/StartupBros-com/pro-gate.git' ]; then
    printf 'marketplace card already lists %s (releaseId %s): publishing\n' "$tag" "$release_id"
    gh release edit "$tag" --draft=false
  else
    printf '\n=== staged as a draft: marketplace repin needed before publish ===\n'
    printf '  plugin      pro-gate\n'
    printf '  version     %s\n' "$version"
    printf '  sha         %s\n' "$source_sha"
    printf '  releaseId   %s\n' "$release_id"
    printf '  releaseTag  %s\n' "$tag"
    printf '\nCard currently lists %s (releaseId %s, sha %s).\n' "$card_tag" "$card_id" "$card_sha"
    printf 'Open the repin PR against %s with the tuple above and merge it, then run\n' "${MARKETPLACE_REPO}"
    printf 'the "Publish staged release" workflow (or: gh release edit %s --draft=false).\n' "$tag"
    printf 'Recipe: hov-marketplace/docs/plugin-release-recipe.md\n\n'
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        printf '### Release %s is staged, not published\n\n' "$tag"
        printf 'Assets are packaged and checksum-verified. Repin the marketplace card, then publish.\n\n'
        printf '| field | value |\n|---|---|\n'
        printf '| plugin | pro-gate |\n'
        printf '| version | %s |\n' "$version"
        printf '| sha | `%s` |\n' "$source_sha"
        printf '| releaseId | %s |\n' "$release_id"
        printf '| releaseTag | %s |\n' "$tag"
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    printf '::notice title=Release staged, not published::%s is a draft until the marketplace card names it. Merge the repin PR, then run the "Publish staged release" workflow.\n' "$tag"
  fi
fi
