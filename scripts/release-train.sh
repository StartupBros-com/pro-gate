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

notes_summary() {
  printf '%s' "${RELEASE_NOTES:-}" | tr '\r\n' '  ' | cut -c1-600
}

announce() {
  require ANNOUNCE_URL
  require ANNOUNCE_SECRET
  local payload
  payload="$(jq -cn \
    --arg operation announce \
    --arg repository "$REPOSITORY" \
    --arg releaseId "$RELEASE_ID" \
    --arg tag "$RELEASE_TAG" \
    --arg releaseName "$RELEASE_NAME" \
    --arg releaseUrl "$RELEASE_URL" \
    --arg notesSummary "$(notes_summary)" \
    '{operation: $operation, repository: $repository, releaseId: $releaseId, tag: $tag, releaseName: $releaseName, releaseUrl: $releaseUrl} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)')"
  curl --fail-with-body --silent --show-error \
    -X POST \
    -H 'content-type: application/json' \
    -H "x-tool-release-announce-secret: $ANNOUNCE_SECRET" \
    --data "$payload" \
    "$ANNOUNCE_URL"
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

current_release_id() {
  jq -er --arg name "$REPOSITORY" '.plugins[] | select(.name == $name) | (.metadata.releaseId // 0)' "$MARKETPLACE_MANIFEST"
}

apply_marketplace_entry() {
  local output
  output="$(mktemp)"
  jq \
    --arg name "$REPOSITORY" \
    --arg sha "$SOURCE_SHA" \
    --arg version "$RELEASE_VERSION" \
    --argjson release_id "$RELEASE_ID" \
    --arg release_tag "$RELEASE_TAG" \
    '(.plugins[] | select(.name == $name)) |= (.source.sha = $sha | .metadata = {version: $version, releaseId: $release_id, releaseTag: $release_tag})' \
    "$MARKETPLACE_MANIFEST" > "$output"
  mv "$output" "$MARKETPLACE_MANIFEST"
}

validate_marketplace() {
  BASE_REF="origin/$MARKETPLACE_BRANCH" \
  EXPECTED_PLUGIN_NAME="$REPOSITORY" \
  EXPECTED_PLUGIN_VERSION="$RELEASE_VERSION" \
  EXPECTED_RELEASE_ID="$RELEASE_ID" \
  EXPECTED_RELEASE_TAG="$RELEASE_TAG" \
  EXPECTED_SHA="$SOURCE_SHA" \
  "$MARKETPLACE_VALIDATOR" "${MARKETPLACE_VALIDATION_MODE:-syntax}"
}

promote() {
  require MARKETPLACE_DIR
  MARKETPLACE_BRANCH="${MARKETPLACE_BRANCH:-main}"
  MARKETPLACE_MANIFEST="${MARKETPLACE_MANIFEST:-.claude-plugin/marketplace.json}"
  MARKETPLACE_VALIDATOR="${MARKETPLACE_VALIDATOR:-./scripts/validate-marketplace.sh}"
  cd "$MARKETPLACE_DIR"

  local attempt current
  for attempt in 1 2 3; do
    git fetch origin "$MARKETPLACE_BRANCH" || fail 'could not fetch marketplace branch'
    if ! git rebase "origin/$MARKETPLACE_BRANCH"; then
      git rebase --abort || fail 'could not abort conflicted marketplace rebase'
      git switch --detach "origin/$MARKETPLACE_BRANCH" || fail 'could not restore fresh marketplace tip'
    fi
    current="$(current_release_id)"
    is_uint "$current" || fail "marketplace release marker is not numeric"
    if (( RELEASE_ID < current )); then
      printf 'stale release %s is older than marketplace marker %s; no-op\n' "$RELEASE_ID" "$current"
      return 2
    fi
    if (( RELEASE_ID == current )); then
      if git diff --quiet "origin/$MARKETPLACE_BRANCH" -- "$MARKETPLACE_MANIFEST"; then
        printf 'release %s is already promoted\n' "$RELEASE_ID"
        return 0
      fi
      validate_marketplace
      if git push origin "HEAD:$MARKETPLACE_BRANCH"; then
        return 0
      fi
      printf 'promotion push attempt %s of 3 lost a race; retrying\n' "$attempt" >&2
      continue
    fi

    apply_marketplace_entry
    validate_marketplace
    git add "$MARKETPLACE_MANIFEST"
    git commit -m "chore: promote $REPOSITORY $RELEASE_TAG"
    if git push origin "HEAD:$MARKETPLACE_BRANCH"; then
      return 0
    fi
    printf 'promotion push attempt %s of 3 lost a race; retrying\n' "$attempt" >&2
  done
  fail 'marketplace promotion failed after exactly 3 attempts'
}

main() {
  require EVENT_ACTION
  require REPOSITORY
  require RELEASE_ID
  require RELEASE_TAG
  require RELEASE_NAME
  require RELEASE_URL
  is_uint "$RELEASE_ID" || fail "RELEASE_ID must be an unsigned integer"
  [[ "$REPOSITORY" == pro-gate ]] || fail "this release train only promotes pro-gate"

  if [[ "${RELEASE_PRERELEASE:-false}" == true || "${RELEASE_DRAFT:-false}" == true ]]; then
    printf 'prerelease or draft release ignored\n'
    return
  fi
  if [[ "$EVENT_ACTION" == edited ]]; then
    announce
    return
  fi
  [[ "$EVENT_ACTION" == published ]] || fail "unsupported release action: $EVENT_ACTION"

  require LATEST_STABLE_ID
  is_uint "$LATEST_STABLE_ID" || fail "LATEST_STABLE_ID must be an unsigned integer"
  if [[ "$RELEASE_ID" != "$LATEST_STABLE_ID" ]]; then
    printf 'release %s is not latest stable %s; no-op\n' "$RELEASE_ID" "$LATEST_STABLE_ID"
    return
  fi

  RELEASE_VERSION="$(verify_release)"
  if promote; then
    announce
  else
    local status=$?
    [[ "$status" == 2 ]] || return "$status"
  fi
}

main "$@"
