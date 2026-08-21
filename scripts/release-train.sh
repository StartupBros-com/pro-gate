#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_SOURCE_KIND='url'
CANONICAL_SOURCE_URL='https://github.com/StartupBros-com/pro-gate.git'

# Shared with scripts/publish-runtime-release.sh so the publish gate and this
# post-publish guard can never disagree about what the card says. The failure
# POLICY stays here (stale -> red); the helper only reads and types the tuple.
# shellcheck source=scripts/lib/marketplace-card.sh
. "$SCRIPT_DIR/lib/marketplace-card.sh"

# The verify job maps this step output to the reusable announce job. Write the
# fail-closed value before even validating inputs so early no-ops and failures
# can never inherit a stale truthy output from a prior command in the step.
write_announce_output() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  printf 'announce=%s\n' "$1" >> "$GITHUB_OUTPUT"
}

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
#
# That posture is unchanged by issue #84 below: this job still NEVER writes
# the marketplace, in any of the three outcomes verify_marketplace_promotion
# decides between. What changed is that a printed notice is no longer treated
# as sufficient on its own — see that function for why.
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

# Where the marketplace card that actually reaches installed clients lives.
# Overridable only so tests never touch the network; production always reads
# the one canonical marketplace.
MARKETPLACE_REPO="${MARKETPLACE_REPO:-StartupBros-com/hov-marketplace}"
MARKETPLACE_MANIFEST_PATH='.claude-plugin/marketplace.json'

# distribution UNVERIFIED: could not prove either way whether the release was
# promoted. Printing a warning and then failing (not passing) is the point of
# this function existing at all (issue #84): a release train that cannot
# prove distribution must not report success — that is the exact bug this
# fixes. The wording is kept deliberately distinct from the STALE failure
# message below it in verify_marketplace_promotion, so a log reader (or a
# grep) can tell an unrelated outage apart from genuine staleness.
fail_distribution_unverified() {
  printf 'warning: could not verify marketplace distribution state: %s\n' "$1" >&2
  printf 'this is an outage or a read/parse failure, NOT evidence the marketplace card is stale — do not conclude promotion happened OR failed from this alone\n' >&2
  fail "distribution UNVERIFIED for $RELEASE_TAG: $1 (re-run once the underlying read succeeds; this is a distinct failure mode from a stale card)"
}

# Read the LIVE marketplace manifest and decide whether this release was
# actually promoted (issue #84). Before this function existed, main() called
# emit_repin_request() unconditionally and returned 0 regardless of what the
# marketplace said — so a stale card printed a notice nobody reads in a job
# that goes green (v0.32.0, v0.33.0, v0.34.0 all shipped undistributed this
# way), AND an already-current card printed the exact same notice, because
# nothing ever read the card to tell the two cases apart (run 31875537361).
#
# This function is READ-ONLY, same posture as emit_repin_request above: it
# never writes hov-marketplace, holds no deploy credential, and the decision
# below is the only thing that changes which of that function's already-
# existing output paths fires.
#
# Three outcomes:
#   CURRENT    - card matches this release exactly on its version, release
#                identity, commit SHA, and canonical source kind/URL -> confirm,
#                do NOT print the repin notice, succeed.
#   STALE      - a complete, typed card names a different tuple field -> print the
#                existing repin notice (kept verbatim; the recipe references
#                its exact fields) AND fail. A red release train is the
#                correct signal that the release is not distributed yet
#                (issue #84 option 2 — self-repin was rejected: see the
#                comment above emit_repin_request).
#   UNVERIFIED - network/API/parse failure -> fail_distribution_unverified
#                (see above); never silently pass, never conflate with STALE.
verify_marketplace_promotion() {
  require REPOSITORY
  require RELEASE_VERSION
  require RELEASE_TAG
  require RELEASE_ID
  require SOURCE_SHA
  local card_tuple card_version card_tag card_id card_sha card_source_kind card_source_url

  # Read + type the live card via the shared helper (one gh api call against the
  # marketplace's default branch, so this always sees whatever a merged repin PR
  # most recently produced). The helper fails closed on fetch/parse/type errors
  # and NEVER decides staleness — that comparison stays below, because STALE and
  # UNVERIFIED must not be conflated (issue #84).
  local card_rc=0
  card_tuple="$(marketplace_card_tuple "$REPOSITORY")" || card_rc=$?
  if [ "$card_rc" -ne 0 ]; then
    fail_distribution_unverified "could not read exactly one typed \"$REPOSITORY\" distribution tuple from $MARKETPLACE_REPO/$MARKETPLACE_MANIFEST_PATH"
  fi
  IFS=$'\t' read -r card_version card_tag card_id card_sha card_source_kind card_source_url <<<"$card_tuple"

  if [[ "$card_version" == "$RELEASE_VERSION" && "$card_tag" == "$RELEASE_TAG" \
        && "$card_id" == "$RELEASE_ID" && "$card_sha" == "$SOURCE_SHA" \
        && "$card_source_kind" == "$CANONICAL_SOURCE_KIND" \
        && "$card_source_url" == "$CANONICAL_SOURCE_URL" ]]; then
    printf 'marketplace card already lists %s (releaseId %s, sha %s): distribution is current\n' \
      "$RELEASE_TAG" "$RELEASE_ID" "$SOURCE_SHA"
    return 0
  fi

  emit_repin_request
  fail "release $RELEASE_TAG (releaseId $RELEASE_ID) is published but NOT distributed: marketplace card still lists $card_tag (releaseId $card_id, sha $card_sha, source $card_source_kind $card_source_url) - open the repin PR reported above against $MARKETPLACE_REPO, merge it, then re-fire announce"
}

# Re-resolve only AFTER proving the exact marketplace tuple. The first stable
# lookup gates work before asset verification; this second lookup closes changes
# that happen while that work runs. If it moved, the release remains a successful
# no-op but cannot announce. The only remaining race is a newer stable release
# published after this final API response; that later release has its own event.
final_release_is_still_latest() {
  require RELEASE_REPOSITORY
  local final_latest_id
  if ! final_latest_id="$("$SCRIPT_DIR/latest-stable-release.sh" "$RELEASE_REPOSITORY")"; then
    fail "could not re-resolve latest stable release before announce"
  fi
  is_uint "$final_latest_id" || fail "final latest stable release id must be an unsigned integer"
  if [[ "$final_latest_id" != "$RELEASE_ID" ]]; then
    printf 'release %s ceased to be latest stable (%s); announce remains disabled\n' \
      "$RELEASE_ID" "$final_latest_id"
    return 1
  fi
  return 0
}

main() {
  write_announce_output false
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
  verify_marketplace_promotion
  if final_release_is_still_latest; then
    write_announce_output true
  fi
}

main "$@"
