#!/usr/bin/env bash
# pro-gate shared library — platform detection, path/dep resolution.
# Sourced by oracle-review.sh, daemon.sh, and pro-gate-doctor.sh. No side effects on source
# except defining functions + PRO_GATE_HOME.

PRO_GATE_HOME="${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"

# os: macos | wsl | linux | other
pg_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    *)      echo other ;;
  esac
}

# How oracle reaches Chrome:
#   native        — macOS: oracle drives the user's signed-in Chrome itself (no Xvfb/CDP)
#   remote-chrome — WSL/Linux: attach to the durable Xvfb Chrome over CDP (127.0.0.1:PORT)
# Override with PRO_GATE_BROWSER_MODE.
pg_browser_mode() {
  if [ -n "${PRO_GATE_BROWSER_MODE:-}" ]; then echo "$PRO_GATE_BROWSER_MODE"; return; fi
  case "$(pg_os)" in macos) echo native ;; *) echo remote-chrome ;; esac
}

# service manager for the daemon: launchd (macOS) | systemd (linux/wsl with systemctl) | none
pg_service_mgr() {
  case "$(pg_os)" in
    macos) echo launchd ;;
    *)     command -v systemctl >/dev/null 2>&1 && echo systemd || echo none ;;
  esac
}

pg_have() { command -v "$1" >/dev/null 2>&1; }

# Prepend likely locations of node/oracle/gh/jq so scripts work under a minimal
# systemd/launchd PATH without hardcoding any version.
pg_augment_path() {
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.local/share/pnpm:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
}

# Source the user's config if present.
pg_load_env() {
  set -a; [ -f "$PRO_GATE_HOME/.env" ] && . "$PRO_GATE_HOME/.env"; set +a
}

# Cross-process lock — waits up to $2 seconds; returns 0 acquired / 1 timeout. Uses flock when
# present (Linux); else an atomic mkdir spinlock (macOS has no flock). Held until the shell exits.
pg_lock() {
  local lockfile="$1" wait_s="${2:-2400}"
  if pg_have flock; then
    exec 9>"$lockfile" 2>/dev/null || return 0
    flock -w "$wait_s" 9; return $?
  fi
  local lockdir="${lockfile}.d" start opid
  start=$(date +%s)
  while ! mkdir "$lockdir" 2>/dev/null; do
    opid=$(cat "$lockdir/pid" 2>/dev/null || true)
    if [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null; then rm -rf "$lockdir" 2>/dev/null; continue; fi
    [ $(( $(date +%s) - start )) -ge "$wait_s" ] && return 1
    sleep 2
  done
  echo "$$" > "$lockdir/pid" 2>/dev/null || true
  trap 'rm -rf "'"$lockdir"'" 2>/dev/null' EXIT
  return 0
}
