#!/usr/bin/env bash
# The resolver must work when invoked by path with no environment at all —
# the dominant real-world call shape (papercut telemetry, 2026-09-01) — and
# still refuse a location that is not a skill root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

OUT="$(env -u SKILL_ROOT -u PRO_GATE_SKILL_ROOT -u CLAUDE_PLUGIN_ROOT \
  bash "$ROOT/skills/pro-gate/scripts/resolve-identity.sh")" \
  || fail "by-path invocation with scrubbed env must self-locate"
[ "$(printf '%s' "$OUT" | awk -F'\t' '{print NF}')" -ge 5 ] \
  || fail "resolver output must carry the five identity fields"
pass "scrubbed-env by-path invocation self-locates"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts"
cp "$ROOT/skills/pro-gate/scripts/resolve-identity.sh" "$TMP/scripts/"
if env -u SKILL_ROOT -u PRO_GATE_SKILL_ROOT -u CLAUDE_PLUGIN_ROOT \
  bash "$TMP/scripts/resolve-identity.sh" >/dev/null 2>&1; then
  fail "a bare copy with no sibling identity must still refuse"
fi
pass "planted negative: no sibling identity file -> refused"

SR_OUT="$(SKILL_ROOT="$ROOT/skills/pro-gate" env -u CLAUDE_PLUGIN_ROOT \
  bash "$TMP/scripts/resolve-identity.sh")" \
  || fail "explicit SKILL_ROOT must still win from any location"
[ "$SR_OUT" = "$OUT" ] || fail "env-resolved identity must match self-located identity"
pass "explicit SKILL_ROOT precedence intact and identical"
printf 'resolve-identity: all checks pass\n'
