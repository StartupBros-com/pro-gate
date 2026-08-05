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

# NEVER `printf ... | grep -q` here (#69 gate r2 P2). `grep -q` exits the moment it matches,
# so printf takes SIGPIPE and, under `set -o pipefail`, the pipeline reports 141 — the
# "Highlights missing" branch then fires on notes that DO have the section. Verified: a body
# with a long Details section failed 20/20 runs, which would have published auto-generated
# branch-name copy for a perfectly good release. Match against the variable instead, which
# consumes nothing and cannot break.
case "$notes" in
  '##'*Highlights*|*$'\n##'*Highlights*) has_highlights=1 ;;
  *) has_highlights=0 ;;
esac
if [ "$has_highlights" = 0 ]; then
  problem "no '## Highlights' section — customers would receive auto-generated PR titles instead of release notes"
elif [ -z "$highlights" ]; then
  problem "'## Highlights' section has no bullets"
fi

# Wrapped bullets are a silent truncation (#69 gate r2 P2): notes_summary keeps only physical
# lines starting with a marker, so a bullet continued on an indented next line reaches
# customers as its first clause alone — grammatical, plausible, and missing the point. Reject
# rather than join, because joining would change what the ANNOUNCER sends and the two must
# agree. Authors write one bullet per line.
while IFS= read -r hl; do
  case "$hl" in
    '  '*|$'\t'*) problem "a Highlights bullet is wrapped onto a continuation line; the announcement keeps only the first line — put each bullet on ONE line: ${hl#"${hl%%[![:space:]]*}"}" ;;
  esac
done <<EOF
$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*Highlights/,/^## /p' | grep -vE '^[[:space:]]*$' | grep -vE '^##')
EOF

if [ -n "$highlights" ]; then
  n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    # TWO views of each bullet (#69 gate P2):
    #   raw  — the marker stripped only, so a conventional-commit prefix is still visible and
    #          can be reported as "this is a commit subject, not customer copy";
    #   text — normalized exactly as notes_summary will normalize it, so every OTHER rule
    #          inspects the bytes customers actually receive. Checking only the raw line let
    #          "feat!: memo-crossbind" pass and still ship as bare "memo-crossbind"; checking
    #          only the normalized text would hide raw subjects entirely.
    # Keep this transform identical to notes_summary's sed in scripts/release-train.sh.
    raw="$(printf '%s' "$line" | sed -E 's/^[*•-][[:space:]]+//')"
    text="$(printf '%s' "$raw" | sed -E '
      s/[[:space:]]+by @[A-Za-z0-9_[:punct:]]+ in http[^[:space:]]*[[:space:]]*$//
      s/^(feat|fix|perf|chore|docs|refactor|test|ci|build)(\([^)]*\))?!?:[[:space:]]*//
      s/[[:space:]]*\(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$//
      s/[[:space:]]+$//
    ')"
    # Prefix check on the RAW line (normalization already stripped the known types).
    # GENERIC, not an allowlist (#69 gate r2 P2): Conventional Commit types are open-ended, so
    # `revert:`, `deps:` or any project-specific type sailed through a fixed nine-type list and
    # reached customers verbatim. Match the SHAPE instead — a lowercase token, optional
    # (scope), optional !, then ": " — which is what a commit subject looks like and what
    # customer prose never does.
    # All matches use grep <<< (here-string): the producer is bash itself, so an early -q exit
    # cannot SIGPIPE a printf and poison $? under pipefail (same class of bug as the Highlights
    # detection above).
    if grep -qE '^[a-z][a-z0-9_-]*(\([^)]*\))?!?:[[:space:]]' <<<"$raw"; then
      problem "bullet $n is a raw commit subject: ${raw:0:60}"
    fi
    if grep -qE ' by @[A-Za-z0-9_-]+ in http' <<<"$text"; then
      problem "bullet $n still carries a 'by @user in <url>' tail: ${text:0:60}"
    fi
    if grep -qE '(^|[[:space:]])#[0-9]+([[:space:]]|$|\))' <<<"$text"; then
      problem "bullet $n references an issue/PR number — link it under Details instead: ${text:0:60}"
    fi
    # A bare branch-name bullet: no spaces, dash/slash separated. "governor-rounds" exactly.
    if grep -qE '^[A-Za-z0-9]+([-/][A-Za-z0-9]+)+$' <<<"$text"; then
      problem "bullet $n looks like a branch name, not a sentence: ${text:0:60}"
    fi
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
