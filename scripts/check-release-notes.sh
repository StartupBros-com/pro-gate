#!/usr/bin/env bash
# Fail a release whose notes would announce developer shorthand to customers.
#
# Both customer feeds (members site + Discord tool drops) read a "## Highlights" section from
# the release body and fall back to GitHub's auto-generated PR titles when it is absent — which
# is exactly how v0.31.0 and v0.31.1 announced "governor-rounds" and "memo-crossbind". This
# check makes that failure loud at release time instead of silent in front of customers.
#
# Usage: check-release-notes.sh <notes-file>     (or pipe the body on stdin with "-")
# Conventions in docs/RELEASE-NOTES-TEMPLATE.md.
set -euo pipefail

src="${1:-}"
[ -n "$src" ] || { echo "usage: check-release-notes.sh <notes-file|->" >&2; exit 2; }
if [ "$src" = "-" ]; then notes="$(cat)"; else
  [ -f "$src" ] || { echo "error: no such file: $src" >&2; exit 2; }
  notes="$(cat "$src")"
fi
notes="$(printf '%s' "$notes" | tr -d '\r')"

fails=0
problem() { printf '  ✗ %s\n' "$*" >&2; fails=$((fails + 1)); }

# Same extraction the announcer uses (scripts/release-train.sh notes_summary), so this checks
# the bytes customers actually receive rather than a lookalike.
highlights="$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*Highlights/,/^## /p' | grep -E '^[*•-][[:space:]]' || true)"

if ! printf '%s\n' "$notes" | grep -qE '^##[[:space:]]*Highlights'; then
  problem "no '## Highlights' section — customers would receive auto-generated PR titles instead of release notes"
elif [ -z "$highlights" ]; then
  problem "'## Highlights' section has no bullets"
fi

if [ -n "$highlights" ]; then
  n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    text="$(printf '%s' "$line" | sed -E 's/^[*•-][[:space:]]+//')"
    case "$text" in
      # An un-edited PR title or commit subject: the exact shapes the fallback produced.
      feat:*|fix:*|perf:*|chore:*|docs:*|refactor:*|test:*|ci:*|build:*) problem "bullet $n is a raw commit subject: ${text:0:60}" ;;
      feat\(*|fix\(*|perf\(*|chore\(*|docs\(*|refactor\(*|test\(*|ci\(*|build\(*) problem "bullet $n is a raw commit subject: ${text:0:60}" ;;
    esac
    printf '%s' "$text" | grep -qE ' by @[A-Za-z0-9_-]+ in http' \
      && problem "bullet $n still carries a 'by @user in <url>' tail: ${text:0:60}"
    printf '%s' "$text" | grep -qE '(^|[[:space:]])#[0-9]+([[:space:]]|$|\))' \
      && problem "bullet $n references an issue/PR number — link it under Details instead: ${text:0:60}"
    # A bare branch-name bullet: no spaces, dash/slash separated. "governor-rounds" exactly.
    printf '%s' "$text" | grep -qE '^[A-Za-z0-9]+([-/][A-Za-z0-9]+)+$' \
      && problem "bullet $n looks like a branch name, not a sentence: ${text:0:60}"
    [ "${#text}" -gt 180 ] && problem "bullet $n is ${#text} chars; the feed truncates at 180"
    [ "${#text}" -lt 15 ] && problem "bullet $n is too short to say anything useful: ${text:0:60}"
  done <<EOF
$highlights
EOF
  [ "$n" -gt 3 ] && printf '  ! %s\n' "note: $n bullets; only the first 3 reach the announcement feed" >&2
fi

if [ "$fails" -gt 0 ]; then
  printf '\nrelease notes are not customer-ready (%d problem(s)). See docs/RELEASE-NOTES-TEMPLATE.md\n' "$fails" >&2
  exit 1
fi
echo "release notes OK"
