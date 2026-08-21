#!/usr/bin/env bash
# Read the LIVE hov-marketplace card for one plugin and hand back its typed
# distribution tuple. Sourced by both scripts/release-train.sh (which fails a
# published-but-stale release) and scripts/publish-runtime-release.sh (which
# refuses to publish a draft until the card is current). Extracted so those two
# can never disagree about what "the card says X" means; the FAILURE POLICY
# deliberately stays with each caller, because they differ:
#
#   release-train.sh          stale -> red (the release already shipped undistributed)
#   publish-runtime-release   stale -> stay draft, exit 0 (this is the normal
#                             pre-repin state, not a fault)
#
# Both, however, must fail closed on an unreadable/ill-typed card: "I could not
# check" is never evidence of currency. That is why this returns a distinct
# code for it rather than an empty tuple (issue #84's UNVERIFIED case).
#
# Exit codes:
#   0  tuple printed on stdout as TSV: version, tag, id, sha, source_kind, source_url
#   2  UNVERIFIED - fetch/parse/type failure; reason on stderr. Never treat as stale.

MARKETPLACE_REPO="${MARKETPLACE_REPO:-StartupBros-com/hov-marketplace}"
MARKETPLACE_MANIFEST_PATH="${MARKETPLACE_MANIFEST_PATH:-.claude-plugin/marketplace.json}"

# marketplace_card_tuple <plugin-name>
marketplace_card_tuple() {
  local name="$1" manifest tuple

  if [ -z "$name" ]; then
    printf 'marketplace_card_tuple: plugin name is required\n' >&2
    return 2
  fi

  # No ref pinned: always reads whatever a merged repin PR most recently
  # produced on the marketplace's default branch.
  if ! manifest="$(gh api -H 'Accept: application/vnd.github.raw+json' \
      "repos/$MARKETPLACE_REPO/contents/$MARKETPLACE_MANIFEST_PATH" 2>/dev/null)"; then
    printf 'gh api could not fetch repos/%s/%s\n' "$MARKETPLACE_REPO" "$MARKETPLACE_MANIFEST_PATH" >&2
    return 2
  fi

  # Fail closed on an ambiguous or ill-typed card in ONE jq -e validation pass.
  # Values are NOT compared here: a complete, typed card naming another release
  # is a caller-visible staleness decision, while duplicate/missing/type-invalid
  # metadata is UNVERIFIED and must not be mistaken for evidence about currency.
  if ! tuple="$(jq -er --arg name "$name" '
      def nonempty_string: type == "string" and length > 0;
      def positive_uint: type == "number" and . > 0 and floor == .;
      if type != "object" or (.plugins | type) != "array" then
        error("marketplace manifest has no plugins array")
      else
        [.plugins[] | select(type == "object" and (.name? == $name))] as $cards
        | if ($cards | length) != 1 then
            error("expected exactly one matching plugin card")
          else
            $cards[0]
            | if (
                (.name | nonempty_string)
                and (.metadata | type) == "object"
                and (.metadata.version | nonempty_string)
                and (.metadata.releaseTag | nonempty_string)
                and (.metadata.releaseId | positive_uint)
                and (.source | type) == "object"
                and (.source.sha | nonempty_string)
                and (.source.source | nonempty_string)
                and (.source.url | nonempty_string)
              ) then
                [
                  .metadata.version,
                  .metadata.releaseTag,
                  .metadata.releaseId,
                  .source.sha,
                  .source.source,
                  .source.url
                ] | @tsv
              else
                error("matching plugin card has an invalid tuple")
              end
          end
      end
    ' <<<"$manifest" 2>/dev/null)"; then
    printf 'marketplace manifest lacks exactly one typed "%s" distribution tuple\n' "$name" >&2
    return 2
  fi

  printf '%s\n' "$tuple"
}
