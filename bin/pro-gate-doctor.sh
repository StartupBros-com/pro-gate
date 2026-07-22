#!/usr/bin/env bash
# pro-gate doctor — verify the setup. Exit 0 if ready to run a review, 1 if something blocks it.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in "$SELF/lib.sh" "$SELF/../lib/pro-gate-lib.sh" "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/lib.sh"; do
  [ -f "$c" ] && { . "$c"; break; }
done
type pg_os >/dev/null 2>&1 || { echo "ERROR: lib.sh not found"; exit 1; }
pg_augment_path; pg_load_env
OS="$(pg_os)"; MODE="$(pg_browser_mode)"; SVC="$(pg_service_mgr)"
PORT="${ORACLE_BROWSER_PORT:-9222}"
ORACLE_BIN="${PRO_GATE_ORACLE_BIN:-oracle}"
TIMEOUT_BIN="${PRO_GATE_TIMEOUT_BIN:-timeout}"

have_bin() {
  case "$1" in
    */*) [ -x "$1" ] ;;
    *) pg_have "$1" ;;
  esac
}
run_bounded() {
  if have_bin "$TIMEOUT_BIN"; then "$TIMEOUT_BIN" "$@"; else return 127; fi
}

ok=0; warn=0; bad=0
P(){ printf '  \033[32m✓\033[0m %s\n' "$*"; ok=$((ok+1)); }
W(){ printf '  \033[33m!\033[0m %s\n' "$*"; warn=$((warn+1)); }
X(){ printf '  \033[31m✗\033[0m %s\n' "$*"; bad=$((bad+1)); }

echo "pro-gate doctor — $OS (browser mode: $MODE, service: $SVC)"

INSTALLED_VERSION="$(pg_runtime_version)"
EXPECTED_VERSION="$(pg_expected_version)"
if [ -z "$INSTALLED_VERSION" ]; then
  X "runtime version record missing; install the exact plugin release with install.sh --version <plugin-version>"
elif [ -n "$EXPECTED_VERSION" ] && [ "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ]; then
  # Direction-aware (issue #37): the routed installer always targets the PLUGIN version, so when the
  # runtime is AHEAD, blindly running it DOWNGRADES the runtime. Say which side is ahead and warn on
  # the downgrade case, using the same pg_semver_lt the timer path already relies on.
  if pg_semver_lt "$INSTALLED_VERSION" "$EXPECTED_VERSION"; then
    X "runtime $INSTALLED_VERSION is BEHIND plugin $EXPECTED_VERSION — upgrade it: install.sh --version $EXPECTED_VERSION"
  elif pg_semver_lt "$EXPECTED_VERSION" "$INSTALLED_VERSION"; then
    X "runtime $INSTALLED_VERSION is AHEAD of plugin $EXPECTED_VERSION (local auto-update, a dogfood build, or a stale/rolled-back active plugin). Running 'install.sh --version $EXPECTED_VERSION' would DOWNGRADE the runtime — update the active plugin to $INSTALLED_VERSION instead, unless the downgrade is intended."
  else
    X "runtime $INSTALLED_VERSION does not match plugin $EXPECTED_VERSION (non-semver); exact-release setup required"
  fi
else
  P "runtime version ${INSTALLED_VERSION}${EXPECTED_VERSION:+ matches plugin}"
fi
if pg_dangerous_consent_ok; then
  P "dangerous automatic-fixer disclosure accepted (consent v$(pg_consent_version))"
else
  W "daemon/dangerous mode disabled until operator consent v$(pg_consent_version) is recorded"
fi

# core deps
if ! have_bin "$TIMEOUT_BIN"; then
  X "configured timeout command missing: $TIMEOUT_BIN"
fi
if have_bin "$ORACLE_BIN"; then
  ORACLE_VERSION="$(run_bounded 5 "$ORACLE_BIN" --version 2>/dev/null | head -1 || true)"
  P "oracle installed${ORACLE_VERSION:+ ($ORACLE_VERSION)}"
else
  X "configured oracle command missing: $ORACLE_BIN"
fi
# oracle is NOT pinned: install.sh runs `pnpm add -g @steipete/oracle` (unpinned), so it
# floats to npm latest at install time and is then never auto-upgraded. Two warn-only,
# offline-tolerant signals below: a version FLOOR (releases below it are known-broken for
# pro-gate) and a skew nudge (a newer release than installed often fixes ChatGPT UI drift).
ORACLE_MIN="${PRO_GATE_ORACLE_MIN_VERSION:-0.16.0}"
if have_bin "$ORACLE_BIN" && have_bin "$TIMEOUT_BIN"; then
  ORACLE_LOCAL="$(run_bounded 5 "$ORACLE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  # Version floor (no network needed): below 0.16.0 oracle can capture a settled preamble as
  # the final answer and flag healthy ChatGPT pages as Cloudflare challenges; pro-gate's round
  # budget and Cloudflare backoff then amplify those into spurious exit-12 blocks and account
  # cooldowns. 0.16.0 also lands the GPT-5.6/Work-tab picker handling. Tune with
  # PRO_GATE_ORACLE_MIN_VERSION.
  # pg_semver_lt is portable (no `sort -V`, which BSD/macOS sort rejects) and returns non-zero
  # for a non-semver ORACLE_LOCAL or ORACLE_MIN, so a bad value degrades to "no warning".
  if [ -n "$ORACLE_LOCAL" ] && pg_semver_lt "$ORACLE_LOCAL" "$ORACLE_MIN"; then
    W "oracle $ORACLE_LOCAL is below the $ORACLE_MIN floor: 0.16.0 fixes preamble-capture double-spends, false Cloudflare detection, and the GPT-5.6/Work-tab picker. Upgrade: pnpm add -g @steipete/oracle"
  fi
  # Skew nudge (needs npm): a newer published release than installed often means upstream
  # fixed ChatGPT UI drift. Upgrade DELIBERATELY when reviews misbehave, never automatically.
  if pg_have npm; then
    ORACLE_LATEST="$(run_bounded 10 npm view @steipete/oracle version 2>/dev/null || true)"
    if [ -n "$ORACLE_LATEST" ] && [ -n "$ORACLE_LOCAL" ] && [ "$ORACLE_LATEST" != "$ORACLE_LOCAL" ]; then
      W "oracle $ORACLE_LOCAL installed, $ORACLE_LATEST published — upgrade deliberately (pnpm add -g @steipete/oracle) if reviews misbehave"
    elif [ -n "$ORACLE_LATEST" ]; then
      P "oracle up to date ($ORACLE_LOCAL = npm latest)"
    fi
  fi
fi
# cdp-salvage helper (v0.15): without it the no-think probe cannot distinguish
# a live run from a dead submission — live runs get killed AND retried
# (double-spend risk), and the last-resort tab salvage is disabled.
CDP_HELPER=""
for c in "$SELF/cdp-salvage.mjs" "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/cdp-salvage.mjs"; do
  [ -f "$c" ] && { CDP_HELPER="$c"; break; }
done
if [ -n "$CDP_HELPER" ]; then
  NODE_MAJ="$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')"
  if [ "${NODE_MAJ:-0}" -ge 21 ] 2>/dev/null; then
    P "cdp-salvage helper present (node v${NODE_MAJ} >= 21)"
  else
    W "cdp-salvage present but node ${NODE_MAJ:-missing} < 21 — probe/tab-salvage disabled (needs built-in WebSocket)"
  fi
else
  W "cdp-salvage.mjs missing — no-think probe + tab salvage DISABLED; live runs can be misclassified as dead and retried (double-spend risk)"
fi
pg_have gh && { gh auth status >/dev/null 2>&1 && P "gh authenticated" || X "gh not authenticated — gh auth login"; } || X "gh (GitHub CLI) missing"
pg_have git && P "git present" || X "git missing"
pg_have claude && P "claude CLI present" || W "claude CLI missing (needed for the daemon's fixer)"
pg_have jq && P "jq present" || W "jq missing (usage guardrail degraded)"
pg_have flock && P "concurrency serialized (flock)" || P "concurrency serialized (portable mkdir lock; flock absent — normal on macOS)"

# fixer tier available?
if [ -f "$HOME/.claude/skills/ce-work-beta/SKILL.md" ] || ls "$HOME/.claude/plugins"/**/ce-work-beta* >/dev/null 2>&1; then
  P "fixer: Compound Engineering (ce-work-beta) available"
elif pg_have codex; then P "fixer: codex available"
else W "fixer: will fall back to plain Claude Code edits (fine; no codex/CE detected)"; fi

# browser reachability
if [ "$MODE" = remote-chrome ]; then
  if curl -sf "localhost:${PORT}/json/version" >/dev/null 2>&1; then
    title=$(curl -s "localhost:${PORT}/json" 2>/dev/null | jq -r '[.[]|select(.type=="page")][0].url // ""' 2>/dev/null)
    P "browser session up on :${PORT} (${title:-chatgpt})"
    TABS=$(curl -s "localhost:${PORT}/json" 2>/dev/null | jq -r '[.[]|select(.type=="page")]|length' 2>/dev/null)
    case "$TABS" in ''|*[!0-9]*) : ;; *)
      if [ "$TABS" -le 10 ]; then P "browser tabs: ${TABS} open"
      else W "browser tabs: ${TABS} open (leaked root tabs eat memory headroom; the engine sweeps them pre-run, or: node \$PRO_GATE_HOME/cdp-salvage.mjs --sweep-root - 25 ${PORT})"; fi ;;
    esac
    [ "$SVC" = systemd ] && { systemctl is-active --quiet oracle-chrome.service 2>/dev/null && P "oracle-chrome.service active" || W "oracle-chrome.service not active"; }
  else
    X "browser session not reachable on :${PORT} — start it (sudo systemctl start oracle-chrome) and sign in (login-view.sh)"
  fi
else
  W "macOS native mode — cannot pre-check ChatGPT login; ensure Chrome is signed into ChatGPT Pro"
fi

# environment fitness (mirrors the engine's pre-slot health gate, so the doctor predicts a defer)
if [ "$MODE" = remote-chrome ]; then
  up="$(pg_service_uptime)"
  if [ "${up:-999999}" -ge "${PRO_GATE_MIN_UPTIME:-60}" ]; then P "oracle-chrome stable (${up}s uptime)"; else W "oracle-chrome only ${up}s uptime — engine will defer until it stabilizes"; fi
fi
if memreason="$(pg_mem_headroom_ok)"; then
  if memnote="$(pg_mem_pressure_note)"; then W "memory tight: ${memnote} — the engine still runs, but a long review may be unstable; free memory (close apps/tabs) for best results";
  else P "memory headroom ok for a review ($(pg_mem_status))"; fi
else W "memory pressure: ${memreason} — the engine will DEFER the slot (no quota spent); free memory and retry"; fi

# config
[ -n "${PRO_REVIEW_OWNERS:-}" ] && P "PRO_REVIEW_OWNERS='${PRO_REVIEW_OWNERS}'" || W "PRO_REVIEW_OWNERS unset (daemon needs it; interactive /pro-gate does not)"
P "concurrency: up to ${PRO_GATE_MAX_CONCURRENCY:-3} review slot(s) (per-PR serialized; health-governed)"

# Auto-update health (v0.23): three consecutive failed unattended updates escalate here
# instead of retrying silently forever into an unread log.
AUS="$PRO_GATE_HOME/autoupdate.state"
if [ -f "$AUS" ]; then
  AUS_STREAK="$(awk -F'\t' 'NR==1{print $1}' "$AUS" 2>/dev/null)"
  case "$AUS_STREAK" in ''|*[!0-9]*) AUS_STREAK=0;; esac
  if [ "$AUS_STREAK" -ge 3 ]; then
    W "runtime auto-update has failed $AUS_STREAK times in a row (see $PRO_GATE_HOME/logs/autoupdate.log; disable with install.sh --no-auto-update)"
  fi
fi

echo "  ── $ok ok, $warn warnings, $bad blocking ──"
[ "$bad" -eq 0 ]
