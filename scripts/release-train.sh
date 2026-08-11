#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

is_uint() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

verify_release() {
  require SOURCE_ROOT
  require SOURCE_SHA
  require ASSET_DIR
  local version manifest_version expected_tag runtime checksum checksum_name checksum_hash actual_hash
  version="$(tr -d '[:space:]' < "$SOURCE_ROOT/VERSION")"
  manifest_version="$(jq -er '.version' "$SOURCE_ROOT/.claude-plugin/plugin.json")"
  expected_tag="v$version"
  [[ "$RELEASE_TAG" == "$expected_tag" ]] || fail "release tag $RELEASE_TAG does not match VERSION $version"
  [[ "$manifest_version" == "$version" ]] || fail "plugin manifest version $manifest_version does not match VERSION $version"
  [[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" == "$SOURCE_SHA" ]] || fail "checked-out source does not match release commit"
  [[ "$(git -C "$SOURCE_ROOT" rev-list -n 1 "$RELEASE_TAG")" == "$SOURCE_SHA" ]] || fail "release tag does not resolve to the exact release commit"

  runtime="$ASSET_DIR/pro-gate-runtime-$version.tar.gz"
  checksum="$runtime.sha256"
  [[ -f "$runtime" ]] || fail "runtime release asset is missing: $(basename "$runtime")"
  [[ -f "$checksum" ]] || fail "runtime checksum asset is missing: $(basename "$checksum")"
  [[ "$(wc -l < "$checksum" | tr -d '[:space:]')" == 1 ]] || fail "checksum asset must contain exactly one line"
  read -r checksum_hash checksum_name < "$checksum"
  checksum_name="${checksum_name#\*}"
  [[ "$checksum_name" == "$(basename "$runtime")" ]] || fail "checksum asset names the wrong runtime asset"
  [[ "$checksum_hash" =~ ^[0-9a-f]{64}$ ]] || fail "checksum asset does not contain a lowercase SHA-256 digest"
  actual_hash="$(sha256sum "$runtime" | cut -d' ' -f1)"
  [[ "$checksum_hash" == "$actual_hash" ]] || fail "runtime asset checksum does not match"
  printf '%s\n' "$version"
}

# The marketplace card is updated by a REVIEWED repin PR, never by a push from
# this job. Print the exact values that PR needs; a human or agent opens it.
# Rationale: a standing deploy key able to write the distribution manifest is
# the one credential whose compromise reaches every installed client, and a
# direct bot push cannot satisfy required status checks anyway (proved when
# hov-marketplace gained require-ci: pro-gate v0.31.2 had to be promoted by
# hand as hov-marketplace PR #70).
emit_repin_request() {
  printf '\n=== marketplace repin needed ===\n'
  printf '  plugin      %s\n' "$REPOSITORY"
  printf '  version     %s\n' "$RELEASE_VERSION"
  printf '  sha         %s\n' "$SOURCE_SHA"
  printf '  releaseId   %s\n' "$RELEASE_ID"
  printf '  releaseTag  %s\n' "$RELEASE_TAG"
  printf '\nOpen the repin PR against StartupBros-com/hov-marketplace, then\n'
  printf 'edit this release to re-fire the announce once the card is merged.\n'
  printf 'Recipe: hov-marketplace/docs/plugin-release-recipe.md\n\n'
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '### Marketplace repin needed\n\n'
      printf '| field | value |\n|---|---|\n'
      printf '| plugin | `%s` |\n' "$REPOSITORY"
      printf '| version | `%s` |\n' "$RELEASE_VERSION"
      printf '| sha | `%s` |\n' "$SOURCE_SHA"
      printf '| releaseId | `%s` |\n' "$RELEASE_ID"
      printf '| releaseTag | `%s` |\n' "$RELEASE_TAG"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

main() {
  require EVENT_ACTION
  require REPOSITORY
  require RELEASE_ID
  require RELEASE_TAG
  is_uint "$RELEASE_ID" || fail "RELEASE_ID must be an unsigned integer"
  [[ "$REPOSITORY" == pro-gate ]] || fail "this release train only promotes pro-gate"

  if [[ "${RELEASE_PRERELEASE:-false}" == true || "${RELEASE_DRAFT:-false}" == true ]]; then
    printf 'prerelease or draft release ignored\n'
    return
  fi
  [[ "$EVENT_ACTION" == published || "$EVENT_ACTION" == edited ]] || fail "unsupported release action: $EVENT_ACTION"

  require LATEST_STABLE_ID
  is_uint "$LATEST_STABLE_ID" || fail "LATEST_STABLE_ID must be an unsigned integer"
  if [[ "$RELEASE_ID" != "$LATEST_STABLE_ID" ]]; then
    printf 'release %s is not latest stable %s; no-op\n' "$RELEASE_ID" "$LATEST_STABLE_ID"
    return
  fi

  RELEASE_VERSION="$(verify_release)"
  emit_repin_request
}

main "$@"
