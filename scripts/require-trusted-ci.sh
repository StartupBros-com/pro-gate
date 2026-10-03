#!/usr/bin/env bash
# Release gate (#254): a tag may be packaged only after the CI run that the push to the default
# branch started for that exact commit has passed. release.yml used to rerun the slowest suites
# itself, about 30 minutes, on the same commit that run had just tested; it now reads that run's
# result instead. The run must be a `push` run of ci.yml on the default branch for the full commit
# id: a pull_request run, another branch, another commit, or a run still in progress never counts.
#
# Usage: require-trusted-ci.sh <owner/repo> <full-commit-sha> <default-branch>
# Waits while the run is queued or in progress (auto-release tags the same push CI is testing).
#   PRO_GATE_RELEASE_CI_POLL_SECS  seconds between reads (default 30)
#   PRO_GATE_RELEASE_CI_FIND_SECS  how long a missing run may take to appear (default 600)
#   PRO_GATE_RELEASE_CI_WAIT_SECS  how long to wait for the run to finish (default 3300; legs cap at 45m)
set -euo pipefail

repository="${1:-}"; sha="${2:-}"; branch="${3:-}"
[ -n "$repository" ] && [ -n "$branch" ] || { printf 'usage: %s <owner/repo> <sha> <branch>\n' "$0" >&2; exit 2; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { printf 'error: not a full commit id: %s\n' "$sha" >&2; exit 2; }
poll="${PRO_GATE_RELEASE_CI_POLL_SECS:-30}"
find_secs="${PRO_GATE_RELEASE_CI_FIND_SECS:-600}"
wait_secs="${PRO_GATE_RELEASE_CI_WAIT_SECS:-3300}"

start=$SECONDS
seen=0
while :; do
  elapsed=$(( SECONDS - start ))
  # A failed read is not evidence either way: keep polling until the deadline.
  if runs="$(gh api "repos/${repository}/actions/workflows/ci.yml/runs?head_sha=${sha}&event=push&branch=${branch}&per_page=20")"; then
    latest="$(jq -c --arg sha "$sha" --arg branch "$branch" '
      [.workflow_runs[]? | select(.head_sha == $sha and .event == "push" and .head_branch == $branch)]
      | max_by(.id) // empty' <<<"$runs")"
  else
    latest=""
  fi
  if [ -z "$latest" ]; then
    # Before any run appeared, only the short find window applies. Once one has been seen, an
    # unreadable answer is judged against the full wait, never as a missing run.
    limit="$find_secs"; [ "$seen" = 1 ] && limit="$wait_secs"
    if [ "$elapsed" -ge "$limit" ]; then
      printf 'error: no readable push CI run of ci.yml on %s for %s after %ss; a release needs that run to pass\n' \
        "$branch" "$sha" "$elapsed" >&2
      exit 1
    fi
  else
    seen=1
    status="$(jq -r .status <<<"$latest")"
    conclusion="$(jq -r '.conclusion // ""' <<<"$latest")"
    url="$(jq -r '.html_url // ""' <<<"$latest")"
    if [ "$status" = completed ]; then
      if [ "$conclusion" = success ]; then
        printf 'CI passed for %s on %s: %s\n' "$sha" "$branch" "$url"
        exit 0
      fi
      printf 'error: CI for %s on %s concluded %s: %s\n' "$sha" "$branch" "${conclusion:-none}" "$url" >&2
      exit 1
    fi
    if [ "$elapsed" -ge "$wait_secs" ]; then
      printf 'error: CI for %s on %s is still %s after %ss: %s\n' "$sha" "$branch" "$status" "$elapsed" "$url" >&2
      exit 1
    fi
    printf 'waiting for CI on %s (%s): %s\n' "$sha" "$status" "$url"
  fi
  sleep "$poll"
done
