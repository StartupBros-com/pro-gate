#!/usr/bin/env bash
# pro-gate-autoupdate: make the installed RUNTIME follow the installed PLUGIN version.
#
# The marketplace updates the plugin (skill + agent) automatically; the privileged runtime
# under $PRO_GATE_HOME deliberately does not auto-update from marketplace events (that would
# turn the marketplace into a remote-code channel to a credentialed daemon). This script is
# the OPT-IN middle ground: it reads the version of the ACTIVE locally installed plugin from
# Claude Code's installed_plugins.json and, when the runtime differs, downloads that exact
# release's checksum-verified archive and runs THAT archive's installer with service
# reconciliation skipped. Following the local plugin (never "latest") means the runtime can
# never race ahead of what the release train promoted, and the version-skew fail-closed
# checks in the skill and daemon clear themselves as soon as this lands.
#
# Enable per box with: install.sh --auto-update   (systemd timer, hourly)
# Disable with:        install.sh --no-auto-update
# A plain install leaves the timer untouched.
#
# Unattended-safety properties:
#   - source of truth is installed_plugins.json (the ACTIVE plugin), never the highest
#     version directory in the cache (stale copies survive marketplace rollbacks) and never
#     a path glob an unrelated file drop could satisfy
#   - the update itself never touches systemd/launchd (INSTALL_SKIP_SERVICES=1): no sudo,
#     no TTY needed, daemon and timer enablement are untouched by construction
#   - the archive's sha256 is verified BEFORE its installer is extracted and executed; no
#     script is piped from a mutable raw URL
#   - a version that is not strict semver is never followed (it is spliced into paths)
#   - an enabled daemon with stale dangerous-mode consent refuses the update (a human must
#     re-accept the disclosure first)
#   - downgrades follow the plugin (a marketplace rollback is deliberate), loudly logged
#   - consecutive failures are counted; three in a row escalates in the log and in
#     pro-gate-doctor.sh instead of retrying silently forever
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in "$SELF/lib.sh" "$SELF/../lib/pro-gate-lib.sh" "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/lib.sh"; do
  [ -f "$c" ] && { . "$c"; break; }
done
type pg_os >/dev/null 2>&1 || { echo "ERROR: pro-gate lib not found (lib.sh)" >&2; exit 10; }
pg_augment_path
pg_load_env

PGAU_STATE="$PRO_GATE_HOME/autoupdate.state"   # "<fail-streak><TAB><last-rc><TAB><ts>"

pgau_log() {
  local line
  line="$(date '+%F %T') $*"
  printf '%s\n' "$line" >&2
  { mkdir -p "$PRO_GATE_HOME/logs" && printf '%s\n' "$line" >> "$PRO_GATE_HOME/logs/autoupdate.log"; } 2>/dev/null || true
}

pgau_semver_ok() { printf '%s' "${1:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

pgau_max_semver() {  # stdin: candidate versions, one per line; echoes the highest valid one
  local v best=""
  while IFS= read -r v; do
    pgau_semver_ok "$v" || continue
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best" "$v" | sort -V | tail -1)" = "$v" ]; then
      best="$v"
    fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

# The ACTIVE pro-gate plugin version. Source of truth is installed_plugins.json: entries are
# keyed "<plugin>@<marketplace>" and carry the active version; the cache directories are NOT
# authoritative (Claude Code leaves stale higher-versioned copies behind, which would invert
# a deliberate marketplace rollback, and a bare path glob could be satisfied by an unrelated
# file drop; both were adversarial-review findings). The cache-layout glob remains only as a
# no-jq/no-manifest fallback, matched against the real <marketplace>/pro-gate/<version>/
# shape. Several active entries (scopes/marketplaces) resolve to the highest version.
pgau_plugin_version() {
  local dir="${PRO_GATE_PLUGIN_SEARCH_DIR:-$HOME/.claude/plugins}" manifest f v best=""
  manifest="$dir/installed_plugins.json"
  if [ -s "$manifest" ] && pg_have jq && jq -e . "$manifest" >/dev/null 2>&1; then
    # A readable manifest is AUTHORITATIVE, including its silence: no pro-gate entry means
    # the plugin is not installed (perhaps uninstalled), and falling through to the cache
    # glob would follow a leftover copy of something the operator removed.
    best="$(jq -r '.plugins | to_entries[] | select(.key | startswith("pro-gate@")) | .value[]?.version // empty' "$manifest" 2>/dev/null | pgau_max_semver || true)"
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
    return 0
  fi
  best="$(
    while IFS= read -r f; do
      if pg_have jq; then
        jq -er .version "$f" 2>/dev/null || true
      else
        sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -1
      fi
    done < <(find "$dir" -path '*/pro-gate/*/.claude-plugin/plugin.json' -type f 2>/dev/null) \
    | pgau_max_semver || true
  )"
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# Is the privileged daemon currently enabled on this box? Used ONLY for the consent gate:
# the update itself never touches service enablement (INSTALL_SKIP_SERVICES=1).
pgau_daemon_enabled() {
  local sysctl="${PRO_GATE_AUTOUPDATE_SYSTEMCTL:-systemctl}"
  case "$(pg_service_mgr)" in
    systemd) "$sysctl" is-enabled pro-review-daemon.service >/dev/null 2>&1 ;;
    launchd) [ -f "$HOME/Library/LaunchAgents/com.pro-gate.review-daemon.plist" ] ;;
    *) return 1 ;;
  esac
}

pgau_sha256_check() {  # $1 = checksum file (in cwd)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$1" >/dev/null
  elif command -v shasum >/dev/null 2>&1; then
    local digest file
    digest="$(cut -d' ' -f1 "$1")"; file="$(awk '{print $2}' "$1")"
    [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$digest" ]
  else return 1; fi
}

# Download the exact release's archive + checksum with gh (authenticated API, no mutable raw
# URL), verify the checksum LOCALLY, then run the VERIFIED archive's own installer against
# the same verified archive. The executed installer therefore always matches the target
# version (new releases can add files an old installer would not deploy) and no unverified
# script is ever piped to bash.
pgau_run_installer() {  # $1 = target version
  local v="$1" repo stage rc=0
  if [ -n "${PRO_GATE_AUTOUPDATE_INSTALLER:-}" ]; then
    INSTALL_SKIP_SERVICES=1 "$PRO_GATE_AUTOUPDATE_INSTALLER" "$v"
    return $?
  fi
  pg_have gh || { pgau_log "gh CLI is required to download release assets"; return 6; }
  repo="${PRO_GATE_RELEASE_REPO:-StartupBros-com/pro-gate}"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/pg-autoupdate.XXXXXX")" || return 6
  (
    set -e
    cd "$stage"
    gh release download "v$v" --repo "$repo" \
      --pattern "pro-gate-runtime-$v.tar.gz" --pattern "pro-gate-runtime-$v.tar.gz.sha256"
    pgau_sha256_check "pro-gate-runtime-$v.tar.gz.sha256"
    tar -xzf "pro-gate-runtime-$v.tar.gz" "pro-gate-runtime-$v/install.sh"
    INSTALL_SKIP_SERVICES=1 bash "pro-gate-runtime-$v/install.sh" --version "$v" \
      --archive "pro-gate-runtime-$v.tar.gz" --checksum "pro-gate-runtime-$v.tar.gz.sha256"
  ) || rc=$?
  rm -rf "$stage"
  return "$rc"
}

pgau_fail_streak() { awk -F'\t' 'NR==1{print $1}' "$PGAU_STATE" 2>/dev/null || true; }

pgau_note_result() {  # $1 = rc; tracks the consecutive-failure streak and escalates at 3
  local rc="$1" streak
  if [ "$rc" -eq 0 ]; then rm -f "$PGAU_STATE" 2>/dev/null; return 0; fi
  streak="$(pgau_fail_streak)"
  case "$streak" in ''|*[!0-9]*) streak=0;; esac
  streak=$(( streak + 1 ))
  { printf '%s\t%s\t%s\n' "$streak" "$rc" "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$PGAU_STATE.tmp" \
      && mv -f "$PGAU_STATE.tmp" "$PGAU_STATE"; } 2>/dev/null || true
  if [ "$streak" -ge 3 ]; then
    pgau_log "ESCALATION: ${streak} consecutive auto-update failures (last rc=${rc}); pro-gate-doctor.sh now flags this. Fix the cause or disable the timer (install.sh --no-auto-update)."
  fi
}

pgau_main() {
  local lock="$PRO_GATE_HOME/autoupdate.lock" lfd plugin_v runtime_v rc
  mkdir -p "$PRO_GATE_HOME" 2>/dev/null || true
  if pg_have flock; then
    if ! { { exec {lfd}>>"$lock"; } 2>/dev/null && flock -n "$lfd" 2>/dev/null; }; then
      pgau_log "another auto-update run is active; skipping"
      return 0
    fi
  fi

  if ! plugin_v="$(pgau_plugin_version)"; then
    pgau_log "no active pro-gate plugin found via ${PRO_GATE_PLUGIN_SEARCH_DIR:-$HOME/.claude/plugins}/installed_plugins.json; nothing to follow"
    return 0
  fi
  if ! pgau_semver_ok "$plugin_v"; then
    pgau_log "REFUSING: plugin version '$plugin_v' is not strict semver"
    return 4
  fi
  runtime_v="$(pg_runtime_version)"
  if [ "$plugin_v" = "$runtime_v" ]; then
    rm -f "$PGAU_STATE" 2>/dev/null
    return 0
  fi

  if pgau_daemon_enabled && ! pg_dangerous_consent_ok; then
    pgau_log "REFUSING update ${runtime_v:-none} -> ${plugin_v}: the daemon is enabled but dangerous-mode consent v$(pg_consent_version) is not recorded. Re-accept the disclosure (install.sh --daemon --accept-dangerous-mode), then this timer will proceed."
    pgau_note_result 3
    return 3
  fi

  if [ -n "$runtime_v" ] && [ "$(printf '%s\n%s\n' "$runtime_v" "$plugin_v" | sort -V | tail -1)" = "$runtime_v" ]; then
    pgau_log "DOWNGRADE: following the plugin DOWN from ${runtime_v} to ${plugin_v} (marketplace rollback)"
  fi

  pgau_log "updating runtime ${runtime_v:-none} -> ${plugin_v} (verified archive, services untouched, following the installed plugin)"
  pgau_run_installer "$plugin_v"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pgau_log "runtime updated to ${plugin_v} (daemon self-reloads at its next idle poll)"
    pgau_note_result 0
    return 0
  fi
  pgau_log "installer FAILED for ${plugin_v} (rc=${rc}); runtime left at ${runtime_v:-none} (install.sh restores on failure); will retry on the next timer run"
  pgau_note_result "$rc"
  return 5
}

# Test seam: sourcing with PRO_GATE_AUTOUPDATE_LIB=1 defines the functions without running.
if [ "${PRO_GATE_AUTOUPDATE_LIB:-0}" != 1 ]; then
  pgau_main
  exit $?
fi
