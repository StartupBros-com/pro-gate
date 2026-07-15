#!/usr/bin/env bash
set -euo pipefail

repository="${1:-${GITHUB_REPOSITORY:-}}"
[ -n "$repository" ] || { printf 'repository is required\n' >&2; exit 2; }

# --paginate emits one JSON array per page. Slurp all pages before sorting so
# an older page can still contain the globally newest stable release.
gh api --paginate "repos/${repository}/releases?per_page=100" \
  | jq -ser '[.[][] | select(.draft == false and .prerelease == false)] | sort_by(.created_at, .id) | last | .id // empty'
