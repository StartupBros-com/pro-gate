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

# Counting semaphore — acquire one of $maxn slots ("<base>.slotN"), so up to N reviews share the
# single ChatGPT account concurrently (the account tolerates several parallel chats; this just
# bounds it). Returns 0 with a slot HELD until the process exits, 1 on timeout. flock-based on Linux
# (the winning fd is kept open and auto-released on exit); mkdir-spinlock fallback on macOS scans N
# slot dirs and self-heals stale ones via the dead-pid check. maxn<=1 is plain mutual exclusion.
pg_lock_n() {
  local base="$1" maxn="${2:-1}" wait_s="${3:-2400}" start i fd lockdir opid
  [ "${maxn:-1}" -ge 1 ] 2>/dev/null || maxn=1
  start=$(date +%s)
  if pg_have flock; then
    while :; do
      i=1
      while [ "$i" -le "$maxn" ]; do
        if exec {fd}>>"${base}.slot${i}" 2>/dev/null && flock -n "$fd"; then
          return 0   # keep $fd OPEN (do not close) -> slot held until this process exits
        fi
        [ -n "${fd:-}" ] && eval "exec ${fd}>&-" 2>/dev/null
        i=$((i + 1))
      done
      [ $(( $(date +%s) - start )) -ge "$wait_s" ] && return 1
      sleep 3
    done
  fi
  # macOS / no flock: atomic mkdir over N slot dirs (self-heals dirs left by dead pids)
  while :; do
    i=1
    while [ "$i" -le "$maxn" ]; do
      lockdir="${base}.slot${i}.d"
      if mkdir "$lockdir" 2>/dev/null; then
        echo "$$" > "$lockdir/pid" 2>/dev/null || true
        trap 'rm -rf "'"$lockdir"'" 2>/dev/null' EXIT
        return 0
      fi
      opid=$(cat "$lockdir/pid" 2>/dev/null || true)
      [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null && rm -rf "$lockdir" 2>/dev/null
      i=$((i + 1))
    done
    [ $(( $(date +%s) - start )) -ge "$wait_s" ] && return 1
    sleep 3
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Reliability (v0.1.1): don't burn a precious Pro Extended slot into a broken box,
# salvage a review whose connection dropped, and gate before retrying.
# ─────────────────────────────────────────────────────────────────────────────

# Seconds the oracle-chrome service has been continuously active (systemd only).
# Echoes 0 when the service is down, and 999999 when uptime isn't applicable/knowable
# (macOS native, no systemd, or unparseable) so callers don't gate on it spuriously.
pg_service_uptime() {
  [ "$(pg_service_mgr)" = systemd ] || { echo 999999; return; }
  systemctl is-active --quiet oracle-chrome.service 2>/dev/null || { echo 0; return; }
  local t act now
  t=$(systemctl show oracle-chrome.service -p ActiveEnterTimestamp --value 2>/dev/null)
  [ -n "$t" ] || { echo 999999; return; }
  act=$(date -d "$t" +%s 2>/dev/null) || { echo 999999; return; }
  now=$(date +%s)
  echo $(( now - act ))
}

# Memory/swap headroom. Returns 0 with enough room to run a heavy browser review;
# 1 + a one-line reason on stdout when the box is genuinely starved. Deliberately
# conservative (low false-positive): a full swap with ample free RAM does NOT block.
# Thresholds: PRO_GATE_MIN_AVAIL_MB (default 1024), PRO_GATE_MAX_SWAP_PCT (default 97).
pg_mem_headroom_ok() {
  pg_have free || return 0   # can't measure (e.g. macOS) -> never block
  local avail swap_total swap_used min_avail max_swap_pct pct
  min_avail="${PRO_GATE_MIN_AVAIL_MB:-1024}"
  max_swap_pct="${PRO_GATE_MAX_SWAP_PCT:-97}"
  avail=$(free -m | awk '/^Mem:/{print $7}')
  swap_total=$(free -m | awk '/^Swap:/{print $2}')
  swap_used=$(free -m | awk '/^Swap:/{print $3}')
  if [ "${avail:-0}" -lt "$min_avail" ]; then
    echo "available memory ${avail:-0}MB < ${min_avail}MB"; return 1
  fi
  if [ "${swap_total:-0}" -gt 0 ]; then
    pct=$(( swap_used * 100 / swap_total ))
    if [ "$pct" -ge "$max_swap_pct" ] && [ "${avail:-0}" -lt $(( min_avail * 2 )) ]; then
      echo "swap ${pct}% used with only ${avail}MB free RAM — box is thrashing"; return 1
    fi
  fi
  return 0
}

# pg_health_gate: call right before spending a Pro Extended slot (and before each retry).
# Returns 0 when the box is fit to spend a slot; 1 + a one-line reason on stdout otherwise.
# Only blocks on signals that actually cause wasted slots (unreachable/just-restarted Chrome,
# genuine memory starvation) — not on transient noise.
pg_health_gate() {
  local mode port min_uptime up reason
  mode="$(pg_browser_mode)"; port="${ORACLE_BROWSER_PORT:-9222}"
  min_uptime="${PRO_GATE_MIN_UPTIME:-60}"
  if [ "$mode" = remote-chrome ]; then
    curl -sf "localhost:${port}/json/version" >/dev/null 2>&1 \
      || { echo "Chrome CDP unreachable on :${port}"; return 1; }
    up="$(pg_service_uptime)"
    if [ "${up:-999999}" -lt "$min_uptime" ]; then
      echo "oracle-chrome only ${up}s up (<${min_uptime}s) — just restarted/flapping"; return 1
    fi
  fi
  if ! reason="$(pg_mem_headroom_ok)"; then echo "$reason"; return 1; fi
  return 0
}

# pg_filter_diff <in> <out>: strip diff sections for noise paths (lockfiles, generated,
# vendored, minified, snapshots) so Pro Extended spends its thinking budget on real code and
# its review window stays short. Writes the filtered unified diff to <out>; prints each
# excluded path to STDERR (the caller surfaces them — no silent truncation). Override the
# match with PRO_GATE_DIFF_EXCLUDE.
pg_filter_diff() {
  local in="$1" out="$2" exclude
  # Literal dots are written [.] (a char class) rather than \. so awk's dynamic-regex lexer
  # doesn't warn + downgrade the escape. Override wholesale with PRO_GATE_DIFF_EXCLUDE.
  exclude="${PRO_GATE_DIFF_EXCLUDE:-(^|/)([^/]*[.]lock|pnpm-lock[.]yaml|package-lock[.]json|yarn[.]lock|bun[.]lockb|Cargo[.]lock|poetry[.]lock|Gemfile[.]lock|composer[.]lock|go[.]sum)$|(^|/)(node_modules|vendor|dist|build|out|[.]next|coverage|__snapshots__)/|[.](min[.](js|css)|map|snap)$|[.]generated[.]|_pb2[.]py$}"
  awk -v ex="$exclude" '
    /^diff --git / { path=$0; sub(/^diff --git a\/.* b\//,"",path); skip=(path ~ ex)?1:0; if (skip) print path > "/dev/stderr" }
    !skip { print }
  ' "$in" > "$out"
}

# pg_is_review <file>: true only when <file> looks like a REAL review, not a truncated/garbage
# capture (e.g. a stray "A"). Our prompt mandates a trailing "VERDICT:" line and Pn severity
# blocks, so require a sane size AND at least one of those markers. Used by the main run path and
# the salvage path so a corrupted capture is rejected -> salvage -> one retry, instead of being
# accepted as success.
pg_is_review() {
  local f="$1"
  [ -s "$f" ] || return 1
  [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -ge 40 ] || return 1
  grep -qiE 'VERDICT:|\[P[0-3]\]|P[0-3]:[[:space:]]*(none|—|-)' "$f" 2>/dev/null
}

# pg_reattach_render <slug> <out> [timeout_s]: bounded attempt to SALVAGE a review whose
# generation may have completed server-side after the live oracle call lost its Chrome
# connection. Hard-timeout-wrapped so a missing tab can never hang the caller. Accepts the
# salvage ONLY when it is a COMPLETE review (ends with a VERDICT: line) — a partial snapshot
# is rejected so the caller falls through to a clean retry. Returns 0 on a usable salvage.
pg_reattach_render() {
  local slug="$1" out="$2" t="${3:-150}" tmp="${2}.salvage"
  pg_have oracle || return 1
  [ -n "$slug" ] || return 1
  rm -f "$tmp"
  if pg_have timeout; then
    timeout "${t}s" oracle session "$slug" --harvest --write-output "$tmp" >/dev/null 2>&1 || true
  else
    oracle session "$slug" --harvest --write-output "$tmp" >/dev/null 2>&1 || true
  fi
  if pg_is_review "$tmp"; then
    mv "$tmp" "$out"; return 0
  fi
  rm -f "$tmp"; return 1
}
