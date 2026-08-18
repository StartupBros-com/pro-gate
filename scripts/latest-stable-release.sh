#!/usr/bin/env bash
set -euo pipefail

repository="${1:-${GITHUB_REPOSITORY:-}}"
[ -n "$repository" ] || { printf 'repository is required\n' >&2; exit 2; }

# --paginate emits one JSON array per page. Slurp all pages before sorting so
# an older page can still contain the globally newest stable release. `created_at`
# is deliberately NOT the ordering key: GitHub lets a historical release be
# published later. The release event and customer announcement instead follow
# its publication time; equal publication times use the numeric release id.
#
# A stable record without trustworthy publication metadata is an API/data error,
# not a candidate to silently ignore: otherwise a malformed newest release could
# make an older one look current and announce the wrong artifact.
gh api --paginate "repos/${repository}/releases?per_page=100" \
  | jq -ser -e '
      def valid_published_at:
        type == "string" and ((try fromdateiso8601 catch null) != null);
      def valid_id:
        type == "number" and . >= 0 and floor == .;
      [.[][] | select(.draft == false and .prerelease == false)] as $stable
      | if ($stable | length) == 0 then
          error("no published stable releases")
        elif any($stable[]; ((.published_at | valid_published_at | not) or (.id | valid_id | not))) then
          error("stable release has invalid published_at or id")
        else
          ($stable
           | sort_by([(.published_at | fromdateiso8601), .id])
           | last
           | .id)
        end
    '
