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
  if [ -n "${PRO_GATE_SERVICE_MANAGER:-}" ]; then
    case "$PRO_GATE_SERVICE_MANAGER" in
      launchd|systemd|none) echo "$PRO_GATE_SERVICE_MANAGER"; return ;;
      *) echo "invalid PRO_GATE_SERVICE_MANAGER: $PRO_GATE_SERVICE_MANAGER" >&2; return 1 ;;
    esac
  fi
  case "$(pg_os)" in
    macos) echo launchd ;;
    *)     command -v systemctl >/dev/null 2>&1 && echo systemd || echo none ;;
  esac
}

pg_have() { command -v "$1" >/dev/null 2>&1; }

# Timing overrides are an internal fixture seam, not production configuration. Every
# timing helper requires this exact test-private token before it reads a PRO_GATE_TEST_* value.
pg_test_timing_enabled() {
  [ "${PRO_GATE_TEST_MODE:-}" = 'ci-fixture' ]
}

# Test-only override for the pre-retry CDP probe. Invalid input deliberately
# falls back to the production 30-second deadline and can never extend it.
pg_test_pre_retry_probe_secs() {
  pg_test_timing_enabled || { printf '30\n'; return; }
  case "${PRO_GATE_TEST_PRE_RETRY_PROBE_SECS:-}" in
    [1-9]|[12][0-9]|30) printf '%s\n' "$PRO_GATE_TEST_PRE_RETRY_PROBE_SECS" ;;
    *) printf '30\n' ;;
  esac
}

# Test-only watchdog observation cadence. Invalid input deliberately falls back
# to the production 10-second cadence and can never extend it.
pg_test_watchdog_sleep_secs() {
  pg_test_timing_enabled || { printf '10\n'; return; }
  case "${PRO_GATE_TEST_WATCHDOG_SLEEP_SECS:-}" in
    [1-9]|10) printf '%s\n' "$PRO_GATE_TEST_WATCHDOG_SLEEP_SECS" ;;
    *) printf '10\n' ;;
  esac
}

# Test-only watchdog TERM-drain duration. Invalid input deliberately falls back
# to the production 30-second bound and can never extend it.
pg_test_watchdog_term_drain_secs() {
  pg_test_timing_enabled || { printf '30\n'; return; }
  case "${PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS:-}" in
    [1-9]|[12][0-9]|30) printf '%s\n' "$PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS" ;;
    *) printf '30\n' ;;
  esac
}

# Test-only watchdog post-drain force-settle wait. Invalid input deliberately
# falls back to the production 5-second bound and can never extend it.
pg_test_watchdog_force_settle_secs() {
  pg_test_timing_enabled || { printf '5\n'; return; }
  case "${PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS:-}" in
    [1-5]) printf '%s\n' "$PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS" ;;
    *) printf '5\n' ;;
  esac
}

pg_runtime_version() {
  tr -d '[:space:]' < "$PRO_GATE_HOME/VERSION" 2>/dev/null || true
}

pg_expected_version() {
  if [ -n "${PRO_GATE_EXPECTED_VERSION:-}" ]; then
    printf '%s\n' "$PRO_GATE_EXPECTED_VERSION"
  elif [ -f "$PRO_GATE_HOME/EXPECTED_VERSION" ]; then
    tr -d '[:space:]' < "$PRO_GATE_HOME/EXPECTED_VERSION"
  fi
}

pg_consent_version() { printf '%s\n' "${PRO_GATE_CONSENT_VERSION:-1}"; }
pg_consent_file() { printf '%s/dangerous-mode-consent\n' "${PRO_GATE_CONSENT_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/pro-gate}"; }
pg_dangerous_consent_ok() {
  local recorded
  # The braces matter: on a bare `< file 2>/dev/null` bash reports a failed open to the OLD
  # stderr (redirections apply left to right, so 2> is not yet in effect when `<` fails),
  # leaking a raw "No such file or directory" into every doctor/daemon run on a consent-less
  # box. The group redirect catches the open failure too.
  recorded="$( { tr -d '[:space:]' < "$(pg_consent_file)"; } 2>/dev/null || true)"
  [ "$recorded" = "$(pg_consent_version)" ]
}

# ── active marketplace plugin discovery (v0.23) ──────────────────────────────
# Shared by pro-gate-autoupdate.sh (what version should the runtime follow) and daemon.sh
# (defer dispatch while the runtime lags the plugin a headless /pro-gate child would load).
pg_semver3_ok() { printf '%s' "${1:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

# pg_semver_lt <a> <b>: 0 when a < b, 1 when a >= b (both strict X.Y.Z), 2 when either is not
# strict semver. Portable component-wise numeric compare via parameter expansion only: `sort -V`
# is a GNU extension that BSD sort (the default on macOS, a supported platform) rejects, so a
# sort-based compare errors and silently mis-orders there (dogfood Pro review, PR #32 P2).
pg_semver_lt() {
  pg_semver3_ok "${1:-}" && pg_semver3_ok "${2:-}" || return 2
  local a="$1" b="$2" a1 a2 a3 b1 b2 b3
  a1="${a%%.*}"; a="${a#*.}"; a2="${a%%.*}"; a3="${a#*.}"
  b1="${b%%.*}"; b="${b#*.}"; b2="${b%%.*}"; b3="${b#*.}"
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -lt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -lt "$b2" ]; return; fi
  [ "$a3" -lt "$b3" ]
}

pg_max_semver() {  # stdin: candidate versions; echoes the highest strict-semver one
  local v best=""
  while IFS= read -r v; do
    pg_semver3_ok "$v" || continue
    if [ -z "$best" ] || pg_semver_lt "$best" "$v"; then
      best="$v"
    fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

# pg_active_plugin_version: the version of the ACTIVE installed pro-gate plugin.
#   0 + version  -> found
#   1            -> no active install of the expected plugin identity
#   2            -> manifest exists but is UNUSABLE (unparseable, or no jq/python3):
#                   callers that would change code unattended must fail closed on this
# Source of truth is installed_plugins.json, pinned to ONE plugin identity
# (PRO_GATE_PLUGIN_KEY, default pro-gate@hov, the marketplace's DECLARED name, not its repo name: an entry from another marketplace
# or a project-local scope must not move a machine-wide runtime; dogfood gate P1), preferring
# user-scope entries. A readable manifest is authoritative INCLUDING its silence; the
# cache-layout glob (real <marketplace>/<name>/<version>/ shape) is only for older Claude
# Code versions that have no manifest at all, because cache directories retain stale
# higher-versioned copies that would invert a deliberate rollback.
pg_active_plugin_version() {
  local dir="${PRO_GATE_PLUGIN_SEARCH_DIR:-$HOME/.claude/plugins}" key="${PRO_GATE_PLUGIN_KEY:-pro-gate@hov}"
  local manifest out="" name f
  manifest="$dir/installed_plugins.json"
  if [ -f "$manifest" ]; then
    # USER scope only (dogfood gate round-2 P1): a project-scoped install applies to one
    # repository's sessions, and letting it move the MACHINE-WIDE runtime would gate every
    # other repository on it. No user-scope entry means "not globally installed": rc 1.
    if pg_have jq; then
      jq -e . "$manifest" >/dev/null 2>&1 || return 2
      out="$(jq -r --arg k "$key" '.plugins[$k][]? | select((.scope // "user") == "user") | .version // empty' "$manifest" 2>/dev/null | pg_max_semver || true)"
    elif pg_have python3; then
      out="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
entries = d.get("plugins", {}).get(sys.argv[2], []) or []
print("\n".join(e.get("version", "") for e in entries if e.get("scope", "user") == "user"))' "$manifest" "$key" 2>/dev/null)" || return 2
      out="$(printf '%s\n' "$out" | pg_max_semver || true)"
    else
      return 2
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
  fi
  name="${key%@*}"
  out="$(
    while IFS= read -r f; do
      if pg_have jq; then
        jq -er .version "$f" 2>/dev/null || true
      else
        sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -1
      fi
    done < <(find "$dir" -path "*/$name/*/.claude-plugin/plugin.json" -type f 2>/dev/null) \
    | pg_max_semver || true
  )"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Prepend likely locations of node/oracle/gh/jq so scripts work under a minimal
# systemd/launchd PATH without hardcoding any version.
pg_augment_path() {
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.local/share/pnpm:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
}

# Source the user's config if present. The .env provides DEFAULTS: any variable ALREADY set in
# the environment (e.g. an inline one-shot override like `PRO_GATE_MAX_CONCURRENCY=1 oracle-review.sh`)
# must WIN over the file. Plain `set -a; . .env` inverts that (the file clobbers the caller), so
# a documented inline override was silently ignored. Snapshot the pre-existing exported env,
# source .env for anything unset, then re-apply the snapshot so caller/inline values override the
# file. Sourcing is left intact, so comments and quoting in .env keep working.
pg_load_env() {
  [ -f "$PRO_GATE_HOME/.env" ] || return 0
  local __pg_env_snapshot
  # `export -p` emits `declare -x NAME=VALUE`; rewrite to `declare -gx` so the re-apply below
  # sets GLOBALS (a bare `declare` inside a function scopes to the function and would not
  # propagate the caller's values back out).
  __pg_env_snapshot="$(export -p | sed 's/^declare -x /declare -gx /; s/^export /declare -gx /')"
  set -a; . "$PRO_GATE_HOME/.env"; set +a
  eval "$__pg_env_snapshot" 2>/dev/null || true
}

# pg_dur_secs <dur>: "90", "90s", "30m", "2h" -> seconds (bare number = seconds).
# Unparseable input falls back to 1800 so a typo can never mean "no timeout".
pg_dur_secs() {
  local d="${1:-}" n
  n="${d%[smhSMH]}"
  case "$n" in ''|*[!0-9]*) echo 1800; return;; esac
  case "$d" in
    *m|*M) echo $(( n * 60 ));;
    *h|*H) echo $(( n * 3600 ));;
    *)     echo "$n";;
  esac
}

# pg_hours_1dp <secs>: seconds -> one-decimal hour string ("3.5"), for human-facing round-budget
# totals (ledger-timing-split R2). Bash has no float arithmetic, so this is the one shared spot —
# every caller that needs "~X.Yh" text uses this rather than re-deriving its own rounding.
# Garbage/negative input reads as 0.0 (a display helper never errors out a refusal message).
pg_hours_1dp() {
  local s="${1:-0}"
  case "$s" in ''|*[!0-9]*) s=0;; esac
  awk -v s="$s" 'BEGIN{printf "%.1f", s/3600}'
}

# pg_file_sig <file...>: a stable content signature over the given files, used to detect that
# on-disk code was redeployed (the daemon's self-reload). cksum is POSIX and always present; the
# per-file content checksum plus its path is folded into one final checksum, so a change in ANY
# file's content, or a file appearing/disappearing, changes the signature. Order-stable. Echoes a
# single token, or nothing if cksum is unavailable (callers treat empty as "cannot determine" and
# do not act, so a missing tool degrades to "never reload" rather than "reload constantly").
pg_file_sig() {
  pg_have cksum || return 0
  local f line acc=""
  for f in "$@"; do
    if [ -f "$f" ]; then line="$(cksum < "$f" 2>/dev/null)"; else line="absent"; fi
    acc="${acc}${f}=${line}|"
  done
  printf '%s' "$acc" | cksum 2>/dev/null | awk '{print $1"-"$2}'
}

# Cross-process lock — waits up to $2 seconds; returns 0 acquired / 1 timeout. Uses flock when
# present (Linux); else an atomic mkdir spinlock (macOS has no flock). Held until the shell exits.
# Chained EXIT handlers (gate #61 r2 P1): bash `trap ... EXIT` REPLACES the previous handler,
# so the no-flock lock-cleanup traps used to silently disable the engine's scratch-cleanup
# trap on macOS (leaking WORK and dropping run logs). Every EXIT registration in engine+lib
# goes through here; handlers run in registration order, each isolated by `;` so one failing
# handler cannot skip the rest.
pg_on_exit() {
  PG_EXIT_HANDLERS="${PG_EXIT_HANDLERS:-}${PG_EXIT_HANDLERS:+; }$1"
  # shellcheck disable=SC2064
  trap 'eval "${PG_EXIT_HANDLERS:-:}"' EXIT
}

# Process-identity token: pid start time, so a RECYCLED pid can never impersonate a live run
# (gate #61 r2 P1: kill -0 alone made a stale active record/lock "live" forever once an
# unrelated long-lived process inherited the pid). Empty output = no such process.
pg_pid_token() {
  local p="${1:-}" st=""
  [ -n "$p" ] || return 1
  if [ -r "/proc/$p/stat" ]; then
    # Field 22 counted AFTER the comm field, which may itself contain spaces/parens:
    # strip through the last ')' first, then starttime is field 20 of the remainder.
    st="$(sed 's/^.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $20}')"
  else
    st="$(ps -o lstart= -p "$p" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//' | tr ' ' '_')"
  fi
  [ -n "$st" ] || return 1
  printf '%s' "$st"
}

pg_lock() {
  local lockfile="$1" wait_s="${2:-2400}"
  if pg_have flock; then
    # Braces scope 2>/dev/null to the exec itself — a bare `exec 9>f 2>/dev/null`
    # permanently redirects the CALLER's stderr to /dev/null (v0.11 bug: every engine
    # log line after the first pg_lock call was silently discarded).
    if { exec 9>>"$lockfile"; } 2>/dev/null; then
      flock -w "$wait_s" 9; return $?
    fi
    return 0   # unwritable lock path -> proceed unlocked (preserves prior behavior)
  fi
  local lockdir="${lockfile}.d" start opid
  start=$(date +%s)
  while ! mkdir "$lockdir" 2>/dev/null; do
    opid=$(cat "$lockdir/pid" 2>/dev/null || true)
    # Reclamation goes through pg_stale_dirlock_reap (#152, the same defect the gate found in the
    # reservation guard as #148 r1 P1): a bare `rm -rf` here let two waiters that read the SAME
    # dead pid both enter this section — A removed the directory, re-created it and proceeded; B's
    # removal then landed on A's LIVE directory and B proceeded too. A failed reclaim (another
    # reclaimer holds the sibling reclaim lock) is no longer an instant retry either: it counts
    # against the wait budget instead of spinning without ever reaching the timeout check.
    if [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null \
       && pg_stale_dirlock_reap "$lockdir" "$opid"; then continue; fi
    [ $(( $(date +%s) - start )) -ge "$wait_s" ] && return 1
    sleep 2
  done
  echo "$$" > "$lockdir/pid" 2>/dev/null || true
  pg_pid_token "$$" > "$lockdir/token" 2>/dev/null || true
  pg_on_exit 'rm -rf "'"$lockdir"'" 2>/dev/null'
  return 0
}

# Counting semaphore — acquire one of $maxn slots ("<base>.slotN"), so up to N reviews share the
# single ChatGPT account concurrently (the account tolerates several parallel chats; this just
# bounds it). Returns 0 with a slot HELD until the process exits, 1 on timeout. flock-based on Linux
# (the winning fd is kept open and auto-released on exit); mkdir-spinlock fallback on macOS scans N
# slot dirs and self-heals stale ones via the dead-pid check, serialized through
# pg_stale_dirlock_reap. maxn<=1 is plain mutual exclusion.
pg_lock_n() {
  local base="$1" maxn="${2:-1}" wait_s="${3:-2400}" exclude="${4:-}" start i fd lockdir opid
  [ "${maxn:-1}" -ge 1 ] 2>/dev/null || maxn=1
  # v0.20.3: report WHICH slot was won (durable reservations must remember their slot so fresh
  # runs exclude it instead of shrinking the scan range, which overbooked real capacity), and
  # optionally skip reserved slot numbers ($4, space-separated).
  PG_SLOT_ACQUIRED=""
  start=$(date +%s)
  if pg_have flock; then
    while :; do
      i=1
      while [ "$i" -le "$maxn" ]; do
        case " $exclude " in *" $i "*) i=$((i + 1)); continue;; esac
        # Braces scope 2>/dev/null to the exec (same stderr-nuking bug class as pg_lock).
        if { exec {fd}>>"${base}.slot${i}"; } 2>/dev/null && flock -n "$fd"; then
          PG_SLOT_ACQUIRED="$i"
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
      case " $exclude " in *" $i "*) i=$((i + 1)); continue;; esac
      lockdir="${base}.slot${i}.d"
      if mkdir "$lockdir" 2>/dev/null; then
        echo "$$" > "$lockdir/pid" 2>/dev/null || true
        pg_pid_token "$$" > "$lockdir/token" 2>/dev/null || true
        pg_on_exit 'rm -rf "'"$lockdir"'" 2>/dev/null'
        PG_SLOT_ACQUIRED="$i"
        return 0
      fi
      opid=$(cat "$lockdir/pid" 2>/dev/null || true)
      # Serialized reclamation, exactly as in pg_lock (#152): an unserialized `rm -rf` let two
      # scanners that read one dead slot owner both take the slot — the second deleted the
      # first's live directory on its cached pid — which OVERBOOKS the account (two live reviews
      # inside one slot of the capacity plan). The scan still moves on to the next slot after a
      # reclaim, successful or not: the outer pass re-tries this slot after its usual tick, and
      # returning early here would skip slots this pass had not looked at yet.
      [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null && pg_stale_dirlock_reap "$lockdir" "$opid"
      i=$((i + 1))
    done
    [ $(( $(date +%s) - start )) -ge "$wait_s" ] && return 1
    sleep 3
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Reliability (v0.1.1): don't burn a precious Pro review slot into a broken box,
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

# pg_mem_status: one-line human memory snapshot for user-facing messages (e.g. "1234MB free RAM,
# swap 94% used"). Empty when free(1) is unavailable (e.g. macOS). Never blocks anything.
pg_mem_status() {
  pg_have free || return 0
  local avail swap_total swap_used tail=""
  avail=$(free -m | awk '/^Mem:/{print $7}')
  swap_total=$(free -m | awk '/^Swap:/{print $2}')
  swap_used=$(free -m | awk '/^Swap:/{print $3}')
  [ "${swap_total:-0}" -gt 0 ] && tail=", swap $(( swap_used * 100 / swap_total ))% used"
  echo "${avail:-?}MB free RAM${tail}"
}

# pg_mem_pressure_note: 0 + a one-line advisory on stdout when the box is under memory pressure but
# NOT starved enough for pg_mem_headroom_ok to block — a heavy browser review may still destabilize
# on a small machine. Returns 1 (no output) with ample headroom, no swap, or no measurement.
# Soft threshold: PRO_GATE_SWAP_WARN_PCT (default 80). Advisory only; never blocks a run.
pg_mem_pressure_note() {
  pg_have free || return 1
  local avail swap_total swap_used warn pct
  warn="${PRO_GATE_SWAP_WARN_PCT:-80}"
  avail=$(free -m | awk '/^Mem:/{print $7}')
  swap_total=$(free -m | awk '/^Swap:/{print $2}')
  swap_used=$(free -m | awk '/^Swap:/{print $3}')
  [ "${swap_total:-0}" -gt 0 ] || return 1
  pct=$(( swap_used * 100 / swap_total ))
  [ "$pct" -ge "$warn" ] || return 1
  echo "memory is tight (${avail:-?}MB free RAM, swap ${pct}% used); a long Pro review may destabilize the browser on a low-memory machine"
}

# pg_browser_restarted_midrun <run_start_epoch>: 0 (+ the service uptime on stdout) when the
# remote-chrome service (re)started AFTER this run began — i.e. it restarted mid-review, which
# loses the CDP tab and is almost always memory pressure on a small box. Returns 1 otherwise, and
# for native mode (no managed service). Diagnosis only: the run has already failed by the time this
# is consulted.
pg_browser_restarted_midrun() {
  local run_start="$1" up dur
  [ "$(pg_browser_mode)" = remote-chrome ] || return 1
  case "$run_start" in ''|*[!0-9]*) return 1 ;; esac
  dur=$(( $(date +%s) - run_start ))
  up="$(pg_service_uptime)"
  case "$up" in ''|*[!0-9]*) return 1 ;; esac
  # up==0 means the service is DOWN right now (pg_service_uptime's inactive sentinel), a different
  # failure than a mid-run restart — don't misreport a down/looping service as an OOM restart.
  { [ "$up" -gt 0 ] && [ "$up" -lt "$dur" ]; } || return 1
  echo "$up"
}

# pg_cooldown_active: 0 + a one-line reason on stdout while the account back-off cooldown is
# live (v0.18: written by cdp-salvage on the "requests too quickly / temporarily limited"
# throttle interstitial, and by oracle-review.sh on a Cloudflare anti-bot challenge).
# Submitting (or even salvage-rendering) during the cooldown deepens the block. Age-based: the
# file expires by mtime, no cleanup needed. GNU stat || BSD stat. Checked alone by --harvest
# (which spends nothing, so box-fitness gates don't apply) and inside pg_health_gate.
pg_cooldown_active() {
  local cdf cds mt age
  cdf="${PRO_GATE_COOLDOWN_FILE:-$PRO_GATE_HOME/throttle.cooldown}"
  cds="${PRO_GATE_THROTTLE_COOLDOWN:-900}"
  [ -f "$cdf" ] || return 1
  mt="$(stat -c %Y "$cdf" 2>/dev/null || stat -f %m "$cdf" 2>/dev/null || echo 0)"
  age=$(( $(date +%s) - mt ))
  if [ "$age" -ge 0 ] && [ "$age" -lt "$cds" ]; then
    echo "ChatGPT account back-off cooldown active ($(( cds - age ))s left; throttle/cloudflare; rm $cdf to override)"; return 0
  fi
  return 1
}

# pg_health_gate: call right before spending a Pro review slot (and before each retry).
# Returns 0 when the box is fit to spend a slot; 1 + a one-line reason on stdout otherwise.
# Only blocks on signals that actually cause wasted slots (unreachable/just-restarted Chrome,
# genuine memory starvation, an account-level ChatGPT throttle) — not on transient noise.
pg_health_gate() {
  local mode port min_uptime up reason
  mode="$(pg_browser_mode)"; port="${ORACLE_BROWSER_PORT:-9222}"
  min_uptime="${PRO_GATE_MIN_UPTIME:-60}"
  if reason="$(pg_cooldown_active)"; then echo "$reason"; return 1; fi
  if [ "$mode" = remote-chrome ]; then
    pg_cdp_heal || { echo "Chrome CDP unreachable on :${port} (self-heal failed or disabled)"; return 1; }
    up="$(pg_service_uptime)"
    if [ "${up:-999999}" -lt "$min_uptime" ]; then
      echo "oracle-chrome only ${up}s up (<${min_uptime}s) — just restarted/flapping"; return 1
    fi
  fi
  if ! reason="$(pg_mem_headroom_ok)"; then echo "$reason"; return 1; fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.19: self-healing + run ledger + adaptive concurrency ("ramp")
# ─────────────────────────────────────────────────────────────────────────────

# pg_cdp_heal: return 0 when Chrome CDP is reachable, attempting ONE non-interactive
# service start first if it is not (passwordless sudo only — silently a no-op without it,
# and never on macOS/native where oracle drives the user's own Chrome). A healed Chrome
# still trips the min-uptime gate above by design: don't submit into a cold browser; the
# caller (daemon next cycle, or the engine's defer/retry) comes back a minute later.
# Disable with PRO_GATE_SELF_HEAL=0.
pg_cdp_heal() {
  local port="${ORACLE_BROWSER_PORT:-9222}"
  curl -sf "localhost:${port}/json/version" >/dev/null 2>&1 && return 0
  [ "${PRO_GATE_SELF_HEAL:-1}" = 1 ] || return 1
  [ "$(pg_service_mgr)" = systemd ] || return 1
  echo "[pro-gate] Chrome CDP down on :${port} — self-heal: sudo -n systemctl start oracle-chrome" >&2
  sudo -n systemctl start oracle-chrome.service >/dev/null 2>&1 || true
  sleep "${PRO_GATE_SELF_HEAL_WAIT:-10}"
  curl -sf "localhost:${port}/json/version" >/dev/null 2>&1
}

# v0.20: durable reservations for reviews whose wrapper budget ended while ChatGPT is still
# generating. Process-owned flock slots disappear when exit 9 releases the engine; without a
# durable reservation, a second run immediately under-counts real live Pro tabs and can double-
# spend the same PR. One file per marker survives the process:
#   $PRO_GATE_HOME/in-progress/<marker> = "pr<TAB>out<TAB>created_epoch<TAB>miss_streak<TAB>slot<TAB>model"
# Fresh runs reconcile files via marker probes and subtract the count from effective semaphore
# capacity. Live resets the miss streak; throttle/inconclusive stays fail-closed; only several
# consecutive confirmed absences release the reservation before TTL.
# Harvest success/lost removes the file. Writes/removes serialize under one flock/mkdir lock.
pg_reservation_dir() { echo "${PRO_GATE_RESERVATION_DIR:-$PRO_GATE_HOME/in-progress}"; }
# v0.28: change-manifest sidecars (the diff's file list, for provenance checks) live in their
# OWN directory — NOT inside in-progress/. Every reservation enumerator globs that directory
# and the marker validator accepts dots, so a "<marker>.paths" file there read as a legacy
# reservation: slot planning counted it, and reconciliation probed it and rewrote it as a miss
# record, destroying the manifest (gate #54 P1).
pg_manifest_dir() { echo "${PRO_GATE_MANIFEST_DIR:-$PRO_GATE_HOME/manifests}"; }
pg_reservation_lock() { echo "${PRO_GATE_RESERVATION_LOCK:-$PRO_GATE_HOME/in-progress.lock}"; }
# Markers become filenames under PRO_GATE_HOME and lock paths; every character must be from the
# safe class (in particular no "/" anywhere), not just the first one after the prefix.
pg_reservation_marker_ok() {
  case "${1:-}" in
    pg-run-?*) case "$1" in *[!A-Za-z0-9.-]*) return 1;; *) return 0;; esac;;
    *) return 1;;
  esac
}

# Recovery identity must retain the canonical host/owner/repo triple. ROUND_KEY's historic
# owner-repo slug is deliberately NOT reversible: a-b/c and a/b-c both become a-b-c.
pg_run_meta_dir() { echo "${PRO_GATE_RUN_META_DIR:-$PRO_GATE_HOME/run-meta}"; }
pg_active_dir() { echo "${PRO_GATE_ACTIVE_DIR:-$PRO_GATE_HOME/active}"; }
pg_canonical_repo_ok() { # host owner repo
  local host="${1:-}" owner="${2:-}" repo="${3:-}"
  case "$host" in ''|*[!A-Za-z0-9.-]*) return 1;; esac
  case "$owner" in ''|*[!A-Za-z0-9._-]*) return 1;; esac
  case "$repo" in ''|*[!A-Za-z0-9._-]*) return 1;; esac
  return 0
}
pg_pr_number_normalize() { # digit-only spelling -> canonical positive decimal
  local pr="${1:-}"
  case "$pr" in ''|*[!0-9]*) return 1;; esac
  while [ "${pr#0}" != "$pr" ]; do pr="${pr#0}"; done
  [ -n "$pr" ] || return 1
  printf '%s\n' "$pr"
}
pg_repo_identity_from_url() { # GitHub/Git remote URL -> host<TAB>owner<TAB>repo
  local url="${1:-}" host owner repo
  if [[ "$url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)(/pull/[0-9]+)?/?$ ]]; then
    host="${BASH_REMATCH[1]}"; owner="${BASH_REMATCH[2]}"; repo="${BASH_REMATCH[3]}"
  # .git is common but optional on both SSH forms. The repo capture is greedy, so it swallows a
  # trailing ".git" when present; the repo="${repo%.git}" strip below normalizes it either way.
  elif [[ "$url" =~ ^git@([^:]+):([^/]+)/([^/]+)$ ]] || [[ "$url" =~ ^ssh://git@([^/]+)/([^/]+)/([^/]+)$ ]]; then
    host="${BASH_REMATCH[1]}"; owner="${BASH_REMATCH[2]}"; repo="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  repo="${repo%.git}"
  pg_canonical_repo_ok "$host" "$owner" "$repo" || return 1
  printf '%s\t%s\t%s\n' "$host" "$owner" "$repo"
}
# A compact, marker-addressed sidecar survives reservation retirement and completion:
# host<TAB>owner<TAB>repo<TAB>round_key<TAB>pr<TAB>out<TAB>charged_spend_epoch
# charged_spend_epoch is REQUIRED (no caller may write an uncharged/empty-spend record): the
# only writer is the charged call site adjacent to pg_round_record, so a run-meta record's mere
# existence proves a round was actually spent. An attempt that never reaches that charge must
# never mint a sidecar for recovery to find.
pg_run_meta_write() { # marker host owner repo round_key pr out charged_spend_epoch
  local marker="$1" host="$2" owner="$3" repo="$4" key="$5" pr="$6" out="$7" spend="${8:-}" dir f
  pg_reservation_marker_ok "$marker" || return 1
  pg_canonical_repo_ok "$host" "$owner" "$repo" || return 1
  pg_round_key_ok "$key" || return 1
  pr="$(pg_pr_number_normalize "$pr")" || return 1
  case "$key" in *-"$pr") ;; *) return 1;; esac
  case "$marker" in "pg-run-${key}-"*) ;; *) return 1;; esac
  case "$out" in *$'\t'*|*$'\n'*) return 1;; esac
  case "$spend" in ''|*[!0-9]*) return 1;; esac
  dir="$(pg_run_meta_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/$marker"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$owner" "$repo" "$key" "$pr" "$out" "$spend" > "$dir/.$marker.tmp.$$" 2>/dev/null \
    && mv -f "$dir/.$marker.tmp.$$" "$f" 2>/dev/null
  local rc=$?
  rm -f "$dir/.$marker.tmp.$$" 2>/dev/null
  return "$rc"
}
pg_run_meta_remove() { # marker -- retire an attempt proven never submitted/spent
  local marker="$1"
  pg_reservation_marker_ok "$marker" || return 0
  rm -f "$(pg_run_meta_dir)/$marker" 2>/dev/null || true
}

pg_run_meta_read() { # marker -> one validated compact record
  local marker="$1" f host owner repo key pr out spend
  pg_reservation_marker_ok "$marker" || return 1
  f="$(pg_run_meta_dir)/$marker"; [ -f "$f" ] && [ ! -L "$f" ] || return 1
  IFS=$'\t' read -r host owner repo key pr out spend < "$f" 2>/dev/null || return 1
  pg_canonical_repo_ok "$host" "$owner" "$repo" || return 1
  pg_round_key_ok "$key" || return 1
  pr="$(pg_pr_number_normalize "$pr")" || return 1
  case "$key" in *-"$pr") ;; *) return 1;; esac
  case "$marker" in "pg-run-${key}-"*) ;; *) return 1;; esac
  case "$out" in *$'\t'*|*$'\n'*) return 1;; esac
  case "$spend" in ''|*[!0-9]*) return 1;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$owner" "$repo" "$key" "$pr" "$out" "$spend"
}
# Shared read-only marker enumerator. Status uses it to discover sidecar-only keys; recovery
# uses the same records rather than scraping status's human or JSON renderings.
pg_run_meta_scan() {
  local dir f marker rec tail
  dir="$(pg_run_meta_dir)"; [ -d "$dir" ] || return 0
  for f in "$dir"/pg-run-*; do
    [ -f "$f" ] || continue
    marker="$(basename "$f")"
    # Belt-and-suspenders: pg_run_meta_write's own publication temp is dot-prefixed (excluded by
    # the glob above), but LEGACY temps written by pre-fix versions were not — they land as
    # "<valid-marker>.tmp.<pid>", which DOES match the pg-run-* glob, so skip those leftovers too
    # rather than trust the glob alone. The check is anchored to the LAST ".tmp." and requires an
    # all-digit tail (the pid) rather than a bare substring test: a bare `*.tmp.*` match hides any
    # charged record whose repo/branch legitimately contains the literal ".tmp." (e.g. a repo
    # named app.tmp.v2) from every future recovery scan forever. A real marker always ends
    # "-<epoch>-<pid>", which can never take that "digits after the last .tmp." shape.
    case "$marker" in
      *.tmp.*)
        tail="${marker##*.tmp.}"
        case "$tail" in ''|*[!0-9]*) ;; *) continue;; esac
        ;;
    esac
    pg_reservation_marker_ok "$marker" || continue
    rec="$(pg_run_meta_read "$marker" 2>/dev/null)" || continue
    printf '%s\t%s\n' "$marker" "$rec"
  done
}

# A charged run-meta row is unresolved until that exact marker has durable review bytes. This is
# lifecycle only: a terminal artifact can be stale for the caller's current code/evidence, but it
# still proves its own attempt is no longer unknown-fate. Keep this predicate shared so public
# decision queries and guarded dispatch rechecks cannot disagree about the same sidecar.
pg_run_meta_has_terminal_review() { # marker
  local marker="$1" artifact
  pg_reservation_marker_ok "$marker" || return 1
  artifact="$(pg_completed_dir)/$marker"
  if [ -f "$artifact" ] && [ ! -L "$artifact" ] && pg_is_review "$artifact"; then return 0; fi
  artifact="$PRO_GATE_HOME/pending/$marker"
  [ -f "$artifact" ] && [ ! -L "$artifact" ] && pg_is_review "$artifact"
}

pg_run_meta_find_latest() { # host owner repo pr terminal-filter -> newest exact marker
  local want_host="$1" want_owner="$2" want_repo="$3" want_pr="$4" filter="${5:-any}"
  local marker host owner repo key pr out spend best_marker="" best_spend="" terminal LC_ALL=C
  pg_canonical_repo_ok "$want_host" "$want_owner" "$want_repo" || return 1
  want_pr="$(pg_pr_number_normalize "$want_pr")" || return 1
  case "$filter" in any|review|unresolved) ;; *) return 1;; esac
  while IFS=$'\t' read -r marker host owner repo key pr out spend; do
    [ "$host" = "$want_host" ] && [ "$owner" = "$want_owner" ] && [ "$repo" = "$want_repo" ] \
      && [ "$pr" = "$want_pr" ] || continue
    terminal=false; pg_run_meta_has_terminal_review "$marker" && terminal=true
    case "$filter:$terminal" in review:false|unresolved:true) continue;; esac
    if [ -z "$best_spend" ] || [ "$spend" -gt "$best_spend" ] \
      || { [ "$spend" = "$best_spend" ] && [[ "$marker" > "$best_marker" ]]; }; then
      best_marker="$marker"; best_spend="$spend"
    fi
  done < <(pg_run_meta_scan)
  [ -n "$best_marker" ] || return 1
  printf '%s\n' "$best_marker"
}

pg_run_meta_find_unresolved() { pg_run_meta_find_latest "$1" "$2" "$3" "$4" unresolved; }

pg_attempt_disposition_dir() { printf '%s\n' "${PRO_GATE_ATTEMPT_DISPOSITION_DIR:-$PRO_GATE_HOME/attempt-dispositions}"; }

pg_attempt_disposition_validate() { # canonical JSON [expected marker]
  local json="${1-}" marker="${2:-}" canonical
  canonical="$(printf '%s' "$json" | jq -cS . 2>/dev/null)" || return 1
  jq -e --arg marker "$marker" '. as $d |
    ($d|keys) == ["charged_spend_epoch","marker","observed_at","proof_kind","record_type","record_version","repository","round_key","target","terminal_kind"] and
    $d.record_type=="review-attempt-disposition/v1" and $d.record_version==1 and
    ($d.marker|type=="string" and test("^pg-run-[A-Za-z0-9.-]+$")) and ($marker=="" or $d.marker==$marker) and
    ($d.round_key|type=="string" and test("^[A-Za-z0-9.-]+$")) and ($d.marker|startswith("pg-run-" + $d.round_key + "-")) and
    ($d.charged_spend_epoch|type=="number" and floor==. and .>0) and
    ($d.observed_at|type=="number" and floor==. and .>=$d.charged_spend_epoch) and
    ($d.terminal_kind|IN("not-submitted","submitted-terminal","recovery-exhausted")) and
    ($d.proof_kind|IN("proven-no-submit","exact-owned-infrastructure-terminal","bounded-recovery-exhausted")) and
    (($d.terminal_kind=="not-submitted" and $d.proof_kind=="proven-no-submit") or
     ($d.terminal_kind=="submitted-terminal" and $d.proof_kind=="exact-owned-infrastructure-terminal") or
     ($d.terminal_kind=="recovery-exhausted" and $d.proof_kind=="bounded-recovery-exhausted")) and
    ($d.repository|keys)==["host","owner","repo"] and
    ($d.repository.host|test("^[A-Za-z0-9.-]+$")) and ($d.repository.owner|test("^[A-Za-z0-9._-]+$")) and ($d.repository.repo|test("^[A-Za-z0-9._-]+$")) and
    ($d.target|keys)==["kind","pr"] and $d.target.kind=="pull-request" and ($d.target.pr|type=="number" and floor==. and .>0) and
    ($d.round_key|endswith("-" + ($d.target.pr|tostring)))
  ' <<<"$canonical" >/dev/null 2>&1 || return 1
  printf '%s' "$canonical"
}

pg_attempt_disposition_read() { # marker -> canonical disposition
  local marker="$1" f json
  pg_reservation_marker_ok "$marker" || return 1
  f="$(pg_attempt_disposition_dir)/$marker"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  json="$(cat "$f" 2>/dev/null)" || return 1
  pg_attempt_disposition_validate "$json" "$marker"
}

pg_attempt_disposition_write() { # host owner repo pr round-key marker charged-epoch terminal-kind proof-kind
  local host="$1" owner="$2" repo="$3" pr="$4" key="$5" marker="$6" epoch="$7" kind="$8" proof="$9"
  local dir f tmp canonical now rc=1
  pg_canonical_repo_ok "$host" "$owner" "$repo" || return 1
  pr="$(pg_pr_number_normalize "$pr")" || return 1
  pg_round_key_ok "$key" || return 1
  pg_reservation_marker_ok "$marker" || return 1
  case "$epoch" in ''|*[!0-9]*) return 1;; esac
  now="$(date +%s)"
  canonical="$(jq -cnS --arg host "$host" --arg owner "$owner" --arg repo "$repo" --argjson pr "$pr" \
    --arg key "$key" --arg marker "$marker" --argjson epoch "$epoch" --argjson now "$now" --arg kind "$kind" --arg proof "$proof" \
    '{charged_spend_epoch:$epoch,marker:$marker,observed_at:$now,proof_kind:$proof,record_type:"review-attempt-disposition/v1",record_version:1,repository:{host:$host,owner:$owner,repo:$repo},round_key:$key,target:{kind:"pull-request",pr:$pr},terminal_kind:$kind}')" || return 1
  canonical="$(pg_attempt_disposition_validate "$canonical" "$marker")" || return 1
  dir="$(pg_attempt_disposition_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/$marker"; tmp="$dir/.$marker.tmp.$$"
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    local existing
    existing="$(pg_attempt_disposition_read "$marker" 2>/dev/null || true)"
    [ -n "$existing" ] || return 1
    if jq -e --argjson candidate "$canonical" '
      .charged_spend_epoch==$candidate.charged_spend_epoch and .marker==$candidate.marker and
      .proof_kind==$candidate.proof_kind and .repository==$candidate.repository and
      .round_key==$candidate.round_key and .target==$candidate.target and .terminal_kind==$candidate.terminal_kind
    ' <<<"$existing" >/dev/null 2>&1; then return 0; fi
    return 1
  fi
  if printf '%s' "$canonical" > "$tmp" 2>/dev/null && ln "$tmp" "$f" 2>/dev/null; then
    rc=0
  elif [ -f "$f" ] && [ ! -L "$f" ] && cmp -s "$tmp" "$f" 2>/dev/null; then
    rc=0
  fi
  rm -f "$tmp" 2>/dev/null
  return "$rc"
}

pg_attempt_disposition_scan() { # one canonical disposition JSON object per line
  local dir f marker json
  dir="$(pg_attempt_disposition_dir)"; [ -d "$dir" ] || return 0
  for f in "$dir"/pg-run-*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    marker="${f##*/}"; json="$(pg_attempt_disposition_read "$marker" 2>/dev/null || true)"
    [ -z "$json" ] || printf '%s\n' "$json"
  done
}

pg_attempt_disposition_sweep() { # delete only old dispositions whose cleanup is complete
  local dir now round_secs ttl retain f marker json mt age
  dir="$(pg_attempt_disposition_dir)"; [ -d "$dir" ] || return 0
  now="$(date +%s)"; round_secs="$(pg_round_window_secs)"; ttl="${PRO_GATE_RESERVATION_TTL:-21600}"
  case "$ttl" in ''|*[!0-9]*) ttl=21600;; esac
  retain="$round_secs"; [ "$ttl" -gt "$retain" ] && retain="$ttl"
  for f in "$dir"/pg-run-*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    marker="${f##*/}"; json="$(pg_attempt_disposition_read "$marker" 2>/dev/null || true)"; [ -n "$json" ] || continue
    pg_attempt_disposition_cleanup_pending "$json" && continue
    mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")"
    case "$mt" in ''|*[!0-9]*) continue;; esac
    age=$(( now - mt )); [ "$age" -ge "$retain" ] || continue
    rm -f "$f" 2>/dev/null || true
  done
}

pg_attempt_disposition_find() { # host owner repo pr -> newest exact disposition
  local host="$1" owner="$2" repo="$3" pr="$4" dir f marker json epoch best="" best_epoch="" LC_ALL=C
  pg_canonical_repo_ok "$host" "$owner" "$repo" || return 1
  pr="$(pg_pr_number_normalize "$pr")" || return 1
  dir="$(pg_attempt_disposition_dir)"; [ -d "$dir" ] || return 1
  for f in "$dir"/pg-run-*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    marker="${f##*/}"; json="$(pg_attempt_disposition_read "$marker" 2>/dev/null || true)"; [ -n "$json" ] || continue
    jq -e --arg h "$host" --arg o "$owner" --arg r "$repo" --argjson p "$pr" \
      '.repository.host==$h and .repository.owner==$o and .repository.repo==$r and .target.pr==$p' <<<"$json" >/dev/null 2>&1 || continue
    epoch="$(jq -r .charged_spend_epoch <<<"$json")"
    if [ -z "$best_epoch" ] || [ "$epoch" -gt "$best_epoch" ] || { [ "$epoch" = "$best_epoch" ] && [[ "$marker" > "$best" ]]; }; then
      best="$marker"; best_epoch="$epoch"
    fi
  done
  [ -n "$best" ] || return 1
  pg_attempt_disposition_read "$best"
}

pg_round_has_epoch() { # round-key epoch
  local key="$1" epoch="$2" value
  pg_round_key_ok "$key" || return 1
  [ -f "$(pg_rounds_dir)/$key" ] || return 1
  while IFS= read -r value; do [ "$value" = "$epoch" ] && return 0; done < "$(pg_rounds_dir)/$key"
  return 1
}

pg_round_unrecord_epoch() { # round-key exact epoch; remove exactly one matching entry
  local key="$1" epoch="$2" f rfd lockdir="" waited=0 value removed=0 rc=0
  pg_round_key_ok "$key" || return 1
  case "$epoch" in ''|*[!0-9]*) return 1;; esac
  f="$(pg_rounds_dir)/$key"; [ -f "$f" ] || return 0
  if pg_have flock; then
    { exec {rfd}>>"$f.lock"; } 2>/dev/null && flock -w 10 "$rfd" 2>/dev/null || return 1
  else
    lockdir="$f.lock.d"
    while ! mkdir "$lockdir" 2>/dev/null; do waited=$((waited + 1)); [ "$waited" -ge 10 ] && return 1; sleep 1; done
  fi
  if ! : > "$f.tmp" 2>/dev/null; then
    rc=1
  else
    while IFS= read -r value; do
      if [ "$removed" -eq 0 ] && [ "$value" = "$epoch" ]; then removed=1; continue; fi
      printf '%s\n' "$value" >> "$f.tmp" 2>/dev/null || { rc=1; break; }
    done < "$f"
  fi
  if [ "$rc" -eq 0 ] && [ "$removed" -eq 1 ]; then
    if [ -s "$f.tmp" ]; then mv -f "$f.tmp" "$f" || rc=1; else rm -f "$f" "$f.tmp" || rc=1; fi
  else
    rm -f "$f.tmp" 2>/dev/null || true
  fi
  [ -n "${rfd:-}" ] && eval "exec ${rfd}>&-" 2>/dev/null
  [ -n "$lockdir" ] && rmdir "$lockdir" 2>/dev/null
  return "$rc"
}

pg_attempt_disposition_cleanup_pending() { # canonical disposition
  local json="$1" marker key epoch kind active_file active_marker
  marker="$(jq -r .marker <<<"$json")"; key="$(jq -r .round_key <<<"$json")"
  epoch="$(jq -r .charged_spend_epoch <<<"$json")"; kind="$(jq -r .terminal_kind <<<"$json")"
  [ -f "$(pg_run_meta_dir)/$marker" ] && return 0
  [ -f "$(pg_reservation_dir)/$marker" ] && return 0
  active_file="$(pg_active_dir)/$key"
  if [ -f "$active_file" ] && [ ! -L "$active_file" ]; then
    IFS=$'\t' read -r active_marker _ < "$active_file" 2>/dev/null || true
    [ "$active_marker" = "$marker" ] && return 0
  fi
  if [ "$kind" = not-submitted ]; then
    pg_round_has_epoch "$key" "$epoch" && return 0
    [ -f "$(pg_review_input_binding_dir)/$marker" ] && return 0
  fi
  return 1
}

pg_attempt_disposition_cleanup() { # canonical disposition; idempotent after proof is durable
  local json="$1" marker key epoch kind active_file active_marker
  json="$(pg_attempt_disposition_validate "$json")" || return 1
  marker="$(jq -r .marker <<<"$json")"; key="$(jq -r .round_key <<<"$json")"
  epoch="$(jq -r .charged_spend_epoch <<<"$json")"; kind="$(jq -r .terminal_kind <<<"$json")"
  if [ "$kind" = not-submitted ]; then
    pg_round_unrecord_epoch "$key" "$epoch" || return 1
    # #134: this unlink was the reservation-adjacent mutation outside the guard on the supersession
    # path (pg_fresh_dispatch_refund's legacy no-PR branch has another, but nothing without a PR
    # number can reach pg_reservation_supersede). Bindings are otherwise write-once
    # (pg_review_binding_write_immutable uses `ln`), so an unguarded removal is what made
    # remove-then-rewrite-with-a-different-head reachable against a concurrent supersede.
    # Scope is the unlink ONLY: pg_reservation_remove below acquires the guard itself and the flock
    # here is not reentrant, so widening this would self-deadlock for the full 10s timeout.
    # Acquire can fail (10s flock timeout) AFTER pg_round_unrecord_epoch above already succeeded —
    # the same partial-state exit a failing bare `rm -f` already produced, now with a second trigger.
    # Safe to retry rather than unwind: the terminal disposition is written durably before any caller
    # reaches cleanup, pg_round_unrecord_epoch is a no-op once the epoch is gone, and the
    # TTL/miss sweep in pg_reservation_note_miss reclaims capacity regardless.
    pg_reservation_guard_acquire || return 1
    rm -f "$(pg_review_input_binding_dir)/$marker" 2>/dev/null \
      || { pg_reservation_guard_release; return 1; }
    pg_reservation_guard_release
  fi
  pg_reservation_remove "$marker" 2>/dev/null || return 1
  pg_run_meta_remove "$marker"
  active_file="$(pg_active_dir)/$key"
  if [ -f "$active_file" ] && [ ! -L "$active_file" ]; then
    IFS=$'\t' read -r active_marker _ < "$active_file" 2>/dev/null || true
    [ "$active_marker" != "$marker" ] || rm -f "$active_file" 2>/dev/null || return 1
  fi
  ! pg_attempt_disposition_cleanup_pending "$json"
}

pg_attempt_reconcile_terminal() { # marker; caller holds the per-change lock
  local marker="$1" disposition
  disposition="$(pg_attempt_disposition_read "$marker" 2>/dev/null || true)"
  [ -n "$disposition" ] || return 1
  pg_attempt_disposition_cleanup "$disposition"
}

pg_attempt_terminal_from_meta() { # marker terminal-kind proof-kind -> persist proof without cleanup
  local marker="$1" kind="$2" proof="$3" meta host owner repo key pr _out epoch
  meta="$(pg_run_meta_read "$marker" 2>/dev/null || true)"; [ -n "$meta" ] || return 1
  IFS=$'\t' read -r host owner repo key pr _out epoch <<<"$meta"
  pg_attempt_disposition_write "$host" "$owner" "$repo" "$pr" "$key" "$marker" "$epoch" "$kind" "$proof"
}

pg_attempt_terminal_transition() { # host owner repo pr key marker epoch kind proof
  local host="$1" owner="$2" repo="$3" pr="$4" key="$5" marker="$6" epoch="$7" kind="$8" proof="$9"
  local disposition meta active_file active_marker active_epoch latest="" binding normalized_pr
  normalized_pr="$(pg_pr_number_normalize "$pr")" || return 1
  disposition="$(pg_attempt_disposition_read "$marker" 2>/dev/null || true)"
  if [ -n "$disposition" ]; then
    jq -e --arg h "$host" --arg o "$owner" --arg r "$repo" --arg key "$key" --argjson p "$normalized_pr" --argjson epoch "$epoch" --arg kind "$kind" --arg proof "$proof" \
      '.repository.host==$h and .repository.owner==$o and .repository.repo==$r and .round_key==$key and .target.pr==$p and .charged_spend_epoch==$epoch and .terminal_kind==$kind and .proof_kind==$proof' \
      <<<"$disposition" >/dev/null 2>&1 || return 1
  else
    meta="$(pg_run_meta_read "$marker" 2>/dev/null || true)"; [ -n "$meta" ] || return 1
    IFS=$'\t' read -r _h _o _r _key _pr _out _epoch <<<"$meta"
    [ "$_h" = "$host" ] && [ "$_o" = "$owner" ] && [ "$_r" = "$repo" ] && [ "$_key" = "$key" ] \
      && [ "$_pr" = "$normalized_pr" ] && [ "$_epoch" = "$epoch" ] || return 1
    if [ "$kind" = not-submitted ]; then
      active_file="$(pg_active_dir)/$key"; [ -f "$active_file" ] && [ ! -L "$active_file" ] || return 1
      IFS=$'\t' read -r active_marker _ _ _ _ _ _ active_epoch < "$active_file" 2>/dev/null || return 1
      [ "$active_marker" = "$marker" ] && [ "$active_epoch" = "$epoch" ] || return 1
      latest="$(tail -n 1 "$(pg_rounds_dir)/$key" 2>/dev/null)"
      [ "$latest" = "$epoch" ] || return 1
      binding="$(pg_review_input_binding_read "$marker" 2>/dev/null || true)"
      if [ "${REVIEW_DECISION_EXECUTE:-0}" = 1 ]; then [ -n "$binding" ] || return 1; fi
      if [ -n "$binding" ]; then [ "$(jq -r .charged_spend_epoch <<<"$binding")" = "$epoch" ] || return 1; fi
    fi
    pg_attempt_disposition_write "$host" "$owner" "$repo" "$pr" "$key" "$marker" "$epoch" "$kind" "$proof" || return 1
    disposition="$(pg_attempt_disposition_read "$marker" 2>/dev/null || true)"; [ -n "$disposition" ] || return 1
  fi
  pg_attempt_disposition_cleanup "$disposition"
}

pg_attempt_artifact() { # marker -> kind<TAB>path for a validated canonical review
  local marker="$1" path
  pg_reservation_marker_ok "$marker" || return 1
  path="$(pg_completed_dir)/$marker"
  if [ -f "$path" ] && [ ! -L "$path" ] && pg_is_review "$path"; then
    printf 'completed\t%s\n' "$path"; return 0
  fi
  path="$PRO_GATE_HOME/pending/$marker"
  if [ -f "$path" ] && [ ! -L "$path" ] && pg_is_review "$path"; then
    printf 'pending\t%s\n' "$path"; return 0
  fi
  return 1
}

# Canonical read-only attempt ownership for one PR. Every caller gets the same precedence and
# marker rather than independently interpreting active, reservation, run-meta, and artifacts.
# A later terminal-disposition layer augments this snapshot without changing its interface.
pg_attempt_snapshot() { # host owner repo pr round-key [exclude-marker] -> canonical JSON
  local host="$1" owner="$2" repo="$3" pr="$4" key="$5" exclude="${6:-}"
  local marker="" source=none state=none active_state=none epoch=0 out="" rec artifact="" artifact_kind="" artifact_path=""
  local active_file reservation latest_unresolved latest_review="" latest_review_epoch=0 disposition="" disposition_artifact="" cleanup=false terminal_json=null recoverable=false fresh=true
  local disposition_marker="" disposition_epoch=0 competing_marker="" competing_epoch=0 competing_pid="" competing_token="" ignore_disposition=false
  pg_have jq || return 1
  pg_canonical_repo_ok "$host" "$owner" "$repo" || return 1
  pr="$(pg_pr_number_normalize "$pr")" || return 1
  pg_round_key_ok "$key" || return 1

  latest_review="$(pg_run_meta_find_latest "$host" "$owner" "$repo" "$pr" review 2>/dev/null || true)"
  if [ -n "$latest_review" ]; then
    rec="$(pg_run_meta_read "$latest_review" 2>/dev/null || true)"
    [ -z "$rec" ] || IFS=$'\t' read -r _ _ _ _ _ _ latest_review_epoch <<<"$rec"
    case "$latest_review_epoch" in ''|*[!0-9]*) latest_review_epoch=0;; esac
  fi
  disposition="$(pg_attempt_disposition_find "$host" "$owner" "$repo" "$pr" 2>/dev/null || true)"
  if [ -n "$disposition" ]; then
    disposition_marker="$(jq -r .marker <<<"$disposition")"; disposition_epoch="$(jq -r .charged_spend_epoch <<<"$disposition")"
    active_file="$(pg_active_dir)/$key"
    if [ -f "$active_file" ] && [ ! -L "$active_file" ]; then
      IFS=$'\t' read -r competing_marker _ competing_pid _ _ competing_token _ competing_epoch < "$active_file" 2>/dev/null || true
      if pg_reservation_marker_ok "$competing_marker" && [ "$competing_marker" != "$disposition_marker" ] && [ "$competing_marker" != "$exclude" ]; then
        case "$competing_epoch" in
          ''|*[!0-9]*)
            case "$competing_pid" in ''|*[!0-9]*) ;; *)
              if kill -0 "$competing_pid" 2>/dev/null \
                 && { [ -z "$competing_token" ] || [ "$(pg_pid_token "$competing_pid" 2>/dev/null || true)" = "$competing_token" ]; }; then ignore_disposition=true; fi
              ;;
            esac
            ;;
          *) if [ "$competing_epoch" -gt "$disposition_epoch" ] || { [ "$competing_epoch" = "$disposition_epoch" ] && [[ "$competing_marker" > "$disposition_marker" ]]; }; then ignore_disposition=true; fi;;
        esac
      fi
    fi
    if [ "$ignore_disposition" = false ]; then
      competing_marker="$(pg_reservation_find_pr "$key" 2>/dev/null || true)"
      if pg_reservation_marker_ok "$competing_marker" && [ "$competing_marker" != "$disposition_marker" ] && [ "$competing_marker" != "$exclude" ]; then
        competing_epoch="$(pg_reservation_read_spend "$competing_marker" 2>/dev/null || pg_marker_epoch "$competing_marker" 2>/dev/null || true)"
        case "$competing_epoch" in
          ''|*[!0-9]*) ignore_disposition=true;;
          *) if [ "$competing_epoch" -gt "$disposition_epoch" ] || { [ "$competing_epoch" = "$disposition_epoch" ] && [[ "$competing_marker" > "$disposition_marker" ]]; }; then ignore_disposition=true; fi;;
        esac
      fi
    fi
    if [ "$ignore_disposition" = false ] && [ -n "$latest_review" ] && [ "$latest_review" != "$disposition_marker" ]; then
      if [ "$latest_review_epoch" -gt "$disposition_epoch" ] || { [ "$latest_review_epoch" = "$disposition_epoch" ] && [[ "$latest_review" > "$disposition_marker" ]]; }; then ignore_disposition=true; fi
    fi
    if [ "$ignore_disposition" = false ]; then
      competing_marker="$(pg_run_meta_find_latest "$host" "$owner" "$repo" "$pr" unresolved 2>/dev/null || true)"
      if [ -n "$competing_marker" ] && [ "$competing_marker" != "$disposition_marker" ] && [ "$competing_marker" != "$exclude" ]; then
        rec="$(pg_run_meta_read "$competing_marker" 2>/dev/null || true)"
        [ -z "$rec" ] || IFS=$'\t' read -r _ _ _ _ _ _ competing_epoch <<<"$rec"
        case "$competing_epoch" in ''|*[!0-9]*) competing_epoch=0;; esac
        if [ "$competing_epoch" -gt "$disposition_epoch" ] || { [ "$competing_epoch" = "$disposition_epoch" ] && [[ "$competing_marker" > "$disposition_marker" ]]; }; then ignore_disposition=true; fi
      fi
    fi
    if [ "$ignore_disposition" = true ]; then disposition=""; else
      marker="$disposition_marker"; epoch="$disposition_epoch"
      if [ "$marker" = "$exclude" ]; then marker=""; disposition=""; else
      disposition_artifact="$(pg_attempt_artifact "$marker" 2>/dev/null || true)"
      if [ -n "$disposition_artifact" ]; then
        IFS=$'\t' read -r artifact_kind artifact_path <<<"$disposition_artifact"
        source=artifact; state=review-ready; fresh=false; terminal_json=null
      else
        cleanup=false; pg_attempt_disposition_cleanup_pending "$disposition" && cleanup=true
        source=disposition; recoverable=false; terminal_json="$disposition"
        if [ "$cleanup" = true ]; then state=cleanup-pending; fresh=false; else state="$(jq -r .terminal_kind <<<"$disposition")"; fresh=true; fi
      fi
      rec="$(pg_run_meta_read "$marker" 2>/dev/null || true)"
      if [ -n "$rec" ]; then IFS=$'\t' read -r _ _ _ _ _ out _ <<<"$rec"; fi
    fi
  fi
  fi

  if [ -z "$marker" ]; then
    active_file="$(pg_active_dir)/$key"
    if [ -f "$active_file" ] && [ ! -L "$active_file" ]; then
      IFS=$'\t' read -r marker out _ _ _ _ active_state epoch < "$active_file" 2>/dev/null || true
      if ! pg_reservation_marker_ok "$marker" || [ "$marker" = "$exclude" ]; then marker=""; fi
      # Supersession is exact-marker proof and outranks mutable sidecars left by that same attempt.
      # A distinct active marker still wins below as newer applicable work.
      if [ -n "$marker" ] && [ "$(pg_reservation_state "$marker" 2>/dev/null || true)" = superseded ]; then
        marker=""; active_state=none
      fi
      if [ -n "$marker" ]; then
        case "$active_state" in pre-charge|round-recorded|charged|run-meta-written|input-bound|submitted|unknown-fate|live) ;; *) active_state=unknown-fate;; esac
        source=active; state="$active_state"; recoverable=true; fresh=false
      fi
    fi
  fi

  if [ -z "$marker" ]; then
    # Applicable work always outranks audit-only superseded records for the same change. Only fall
    # back to superseded when no capacity-holding reservation exists.
    reservation="$(pg_reservation_find_pr "$key" 2>/dev/null || true)"
    [ -n "$reservation" ] || reservation="$(pg_reservation_find_pr "$key" include-superseded 2>/dev/null || true)"
    if pg_reservation_marker_ok "$reservation" && [ "$reservation" != "$exclude" ]; then
      marker="$reservation"; source=reservation
      if [ "$(pg_reservation_state "$marker" 2>/dev/null || echo generating)" = superseded ]; then
        state=superseded; recoverable=false; fresh=true
      else
        state=recoverable; recoverable=true; fresh=false
      fi
      rec="$(pg_run_meta_read "$marker" 2>/dev/null || true)"
      if [ -n "$rec" ]; then IFS=$'\t' read -r _ _ _ _ _ out epoch <<<"$rec"; fi
    fi
  fi

  if [ -z "$marker" ]; then
    latest_unresolved="$(pg_run_meta_find_latest "$host" "$owner" "$repo" "$pr" unresolved 2>/dev/null || true)"
    if [ -n "$latest_unresolved" ] && [ "$latest_unresolved" != "$exclude" ]; then
      marker="$latest_unresolved"; source=run-meta; state=unknown-fate; recoverable=true; fresh=false
      rec="$(pg_run_meta_read "$marker" 2>/dev/null || true)"
      if [ -n "$rec" ]; then IFS=$'\t' read -r _ _ _ _ _ out epoch <<<"$rec"; fi
    fi
  fi

  if [ -z "$marker" ] && [ -n "$latest_review" ] && [ "$latest_review" != "$exclude" ]; then
    marker="$latest_review"; epoch="$latest_review_epoch"; source=artifact; state=review-ready; recoverable=false; fresh=false
  fi

  if [ -n "$marker" ]; then
    artifact="$(pg_attempt_artifact "$marker" 2>/dev/null || true)"
    if [ -n "$artifact" ]; then
      IFS=$'\t' read -r artifact_kind artifact_path <<<"$artifact"
      source=artifact; state=review-ready; recoverable=false; fresh=false
    fi
    if [ "$epoch" = 0 ] || [ -z "$epoch" ]; then
      rec="$(pg_run_meta_read "$marker" 2>/dev/null || true)"
      if [ -n "$rec" ]; then IFS=$'\t' read -r _ _ _ _ _ out epoch <<<"$rec"; fi
    fi
  fi
  case "$epoch" in ''|*[!0-9]*) epoch=0;; esac

  jq -cnS --arg host "$host" --arg owner "$owner" --arg repo "$repo" --argjson pr "$pr" \
    --arg key "$key" --arg marker "$marker" --arg source "$source" --arg state "$state" \
    --arg out "$out" --arg kind "$artifact_kind" --arg path "$artifact_path" --argjson epoch "$epoch" \
    --argjson recoverable "$recoverable" --argjson fresh "$fresh" --argjson cleanup "$cleanup" --argjson terminal "$terminal_json" \
    '{artifact:{kind:$kind,path:$path},charged_spend_epoch:$epoch,cleanup_pending:$cleanup,fresh_eligible:$fresh,marker:$marker,out:$out,recoverable:$recoverable,source:$source,state:$state,target:{host:$host,owner:$owner,pr:$pr,repo:$repo,round_key:$key},terminal:$terminal}'
}

# pg_stale_dirlock_reap <lockdir> <observed-dead-pid>: remove a mkdir-spinlock directory whose
# recorded owner is dead, serialized so two reclaimers can never act on one observation. Without
# the serialization A and B both read the same dead pid; A removes the directory, re-creates it and
# enters its critical section; B then removes A's LIVE directory on its cached pid and enters too
# (gate #148 r1 P1: two reservation-guard holders at once let a fresh run plan its slots before an
# exiting review published its reservation, and acquire capacity that review had just reserved).
# The reclaim lock is a sibling directory; under it the owner is re-read and the directory removed
# only while it is still that same dead owner, so a replacement (a fresh directory, pid written or
# not yet) is never touched. Returns 0 when the observed stale directory is gone, removed here or
# already replaced, so the caller retries mkdir at once; 1 when another reclaimer holds the reclaim
# lock or the removal failed, so the caller waits its usual tick and counts it against its budget.
pg_stale_dirlock_reap() {
  local lockdir="$1" dead="$2" reclaim="${1}.reclaim" cur rc=0
  # Never reclaim this serialization lock: a delayed healer could rename a replacement LIVE
  # lock away, admitting a second reclaimer before it restores the first one's directory.
  # An orphan here therefore fails closed within the caller's wait budget; operator cleanup
  # requires all contenders to be stopped. Ordinary dead-owner guard recovery remains automatic.
  mkdir "$reclaim" 2>/dev/null || return 1
  echo "$$" > "$reclaim/pid" 2>/dev/null || true
  cur="$(cat "$lockdir/pid" 2>/dev/null || true)"
  if [ -d "$lockdir" ] && [ "$cur" = "$dead" ] && ! kill -0 "$cur" 2>/dev/null; then
    rm -rf "$lockdir" 2>/dev/null
  fi
  # Still there under the same dead owner (removal failed): report it so the caller waits instead
  # of spinning. A replacement, or nothing, means the observed stale directory is gone.
  [ -d "$lockdir" ] && [ "$(cat "$lockdir/pid" 2>/dev/null || true)" = "$dead" ] && rc=1
  [ "$(cat "$reclaim/pid" 2>/dev/null || true)" = "$$" ] && rm -rf "$reclaim" 2>/dev/null
  return "$rc"
}

# pg_stale_reclaim_sweep <dir>...: remove ORPHANED reclaim locks (#152) — the sibling directories
# pg_stale_dirlock_reap holds for the length of one `rm -rf`. A reclaim lock is never reclaimed on
# demand, because a healer that moved a LIVE one aside would admit a second reclaimer and destroy
# the exclusion the lock exists for. One left behind by a process killed inside that window would
# otherwise wedge dead-owner recovery for its section or slot forever on a no-flock host: the stale
# lock directory beside it could never be reclaimed again, so the section refuses every later run
# and a semaphore slot silently drops out of capacity.
# Removal is authorized by PROVEN absence, never by ambiguity, and both conditions are required:
#   - the directory records a numeric owner and that process is gone. A merely slow or SUSPENDED
#     reclaimer (a laptop asleep mid-reap) still answers kill -0 and is never touched: removing its
#     lock would let a second reclaimer in while the first still has an already-decided `rm -rf` to
#     run, which is this very double-reclaim one level up. A MISSING or torn record is BUSY for the
#     same reason, not an orphan — a reclaimer one statement past its mkdir has not written its pid
#     yet, and no sweep can tell that apart from a process that died in the same gap (the organizer
#     lock reads torn ownership the same way). A recycled pid reads as live and simply keeps its
#     lock: every ambiguity here fails closed, at the price of operator cleanup in the rare case.
#   - the directory is older than the engine's 24h lock-sweep horizon, so a reclaim in flight is
#     never judged on a pid that was simply read at an unlucky moment.
pg_stale_reclaim_sweep() {
  local dir d owner
  for dir in "$@"; do
    [ -d "$dir" ] || continue
    for d in "$dir"/*.d.reclaim; do
      [ -d "$d" ] || continue      # no match: the glob stays literal
      [ -L "$d" ] && continue      # never follow a planted link into another lock's namespace
      owner="$(cat "$d/pid" 2>/dev/null || true)"
      case "$owner" in ''|*[!0-9]*) continue ;; esac
      kill -0 "$owner" 2>/dev/null && continue
      [ -n "$(find "$d" -maxdepth 0 -mmin +1440 2>/dev/null)" ] || continue
      rm -rf "$d" 2>/dev/null || true
    done
  done
}

# Shared guard for reservation writes/removes AND the fresh-run count+slot-acquire decision.
# This makes the handoff atomic: an exit-9 run writes its durable reservation while it still
# owns the process slot; no waiter can observe "slot released, reservation not counted" (or
# compute capacity before the write and acquire the just-released slot on stale information).
pg_reservation_guard_acquire() {
  local lock; lock="$(pg_reservation_lock)"
  if pg_have flock; then
    { exec {PG_RESERVATION_GUARD_FD}>>"$lock"; } 2>/dev/null \
      && flock -w 10 "$PG_RESERVATION_GUARD_FD" 2>/dev/null
    return $?
  fi
  PG_RESERVATION_GUARD_DIR="${lock}.d"
  local waited=0
  while ! mkdir "$PG_RESERVATION_GUARD_DIR" 2>/dev/null; do
    waited=$(( waited + 1 )); [ "$waited" -ge 10 ] && return 1; sleep 1
  done
}
pg_reservation_guard_release() {
  if [ -n "${PG_RESERVATION_GUARD_FD:-}" ]; then
    eval "exec ${PG_RESERVATION_GUARD_FD}>&-" 2>/dev/null
    PG_RESERVATION_GUARD_FD=""
  fi
  if [ -n "${PG_RESERVATION_GUARD_DIR:-}" ]; then
    rmdir "$PG_RESERVATION_GUARD_DIR" 2>/dev/null; PG_RESERVATION_GUARD_DIR=""
  fi
}

pg_reservation_write() { # marker [pr] [out] [slot] [model] [spend_epoch] -- empty fields preserve the record's
  local marker="$1" pr="${2:-}" out="${3:-}" slot="${4:-}" model="${5:-}" spend="${6:-}" dir rc created state tmp prev_pr="" prev_slot="" prev_model="" prev_spend="" prev_state=""
  pg_reservation_marker_ok "$marker" || return 1
  dir="$(pg_reservation_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  pg_reservation_guard_acquire || return 1
  # Preserve the original creation time (repeated exit-9 harvests must not extend the TTL
  # forever), the pr key, the recorded slot, and the captured model (a harvest rewrite has none
  # of its own); reset the reconciliation miss streak, since this write IS a positive live
  # observation. The trailing `model` field (v0.21) records the model oracle resolved for the run
  # so the later --harvest process can name it without re-deriving; legacy 5-field records read it
  # back as empty.
  created=""
  # awk (NOT `read`): tab is IFS-whitespace, so consecutive tabs from an empty slot/model
  # collapse and shift later fields — the same trap pg_reservation_read_model documents.
  if [ -L "$dir/$marker" ]; then pg_reservation_guard_release; return 1; fi
  if [ -f "$dir/$marker" ]; then
    prev_pr="$(awk -F'\t' 'NR==1{print $1}' "$dir/$marker" 2>/dev/null)"
    created="$(awk -F'\t' 'NR==1{print $3}' "$dir/$marker" 2>/dev/null)"
    prev_slot="$(awk -F'\t' 'NR==1{print $5}' "$dir/$marker" 2>/dev/null)"
    prev_model="$(awk -F'\t' 'NR==1{print $6}' "$dir/$marker" 2>/dev/null)"
    prev_spend="$(awk -F'\t' 'NR==1{print $7}' "$dir/$marker" 2>/dev/null)"
    prev_state="$(awk -F'\t' 'NR==1{print $8}' "$dir/$marker" 2>/dev/null)"
  fi
  case "$created" in ''|*[!0-9]*) created="$(date +%s)";; esac
  [ -n "$pr" ] || pr="${prev_pr:-diff}"
  case "$slot" in ''|*[!0-9]*) slot="$prev_slot";; esac
  case "$slot" in *[!0-9]*) slot="";; esac
  [ -n "$model" ] || model="$prev_model"
  model="$(printf '%s' "$model" | tr -d '\t\n')"   # keep the record single-line + 7-field
  # v0.31 (#66 gate r3): field 7 is the epoch pg_round_record CHARGED this run's round at, so a
  # later harvest process stamps trajectory history with the charge time rather than the
  # marker's pre-queue launch time. Empty on legacy records; readers fall back accordingly.
  [ -n "$spend" ] || spend="$prev_spend"
  case "$spend" in *[!0-9]*) spend="";; esac
  # v0.33 (#82): field 8 is the lifecycle state. Positive live evidence re-arms an ordinary
  # complete/generating record, but never a proof-backed superseded one: an old-head review stays
  # collectable without regaining capacity merely because its conversation is still rendering.
  case "$prev_state" in superseded) state=superseded;; *) state=generating;; esac
  tmp="$(mktemp "$dir/.${marker}.write.XXXXXX" 2>/dev/null)" \
    || { pg_reservation_guard_release; return 1; }
  printf '%s\t%s\t%s\t0\t%s\t%s\t%s\t%s\n' "$pr" "$out" "$created" "$slot" "$model" "$spend" "$state" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$dir/$marker"
  rc=$?; [ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null
  pg_reservation_guard_release; return "$rc"
}

# pg_reservation_read_model <marker>: echo the model field (6th) recorded for an in-progress
# reservation, or nothing (legacy 5-field records, or none recorded). The --harvest path reads
# the model straight back from here rather than re-deriving it (KTD3: harvest has no $RUNLOG).
pg_reservation_read_model() {
  local marker="$1" dir f
  pg_reservation_marker_ok "$marker" || return 1
  dir="$(pg_reservation_dir)"; f="$dir/$marker"
  [ -f "$f" ] || return 1
  # awk -F'\t' (NOT `read`): tab is an IFS-whitespace char, so `IFS=$'\t' read` collapses
  # consecutive tabs and an empty middle field (empty slot + present model) would shift the model
  # out of reach. awk keeps empty fields, and prints "" for a legacy 5-field record.
  awk -F'\t' 'NR==1{print $6}' "$f" 2>/dev/null
}

# pg_model_label <captured-model>: render the model for any human/machine surface. Echoes the
# captured model when it is present and not oracle's "(unavailable)" sentinel; otherwise a
# role-based, version-free fallback so no surface ever hardcodes a model version (R5). Override
# the fallback wording with PRO_GATE_MODEL_ROLE_LABEL.
pg_model_label() {
  local m="${1:-}"
  case "$m" in
    ''|'(unavailable)') printf '%s\n' "${PRO_GATE_MODEL_ROLE_LABEL:-the frontier OpenAI Pro reasoning model (web-UI-only, via the oracle bridge)}" ;;
    *) printf '%s\n' "$m" ;;
  esac
}

# pg_derive_model_warn <resolved-model> <selection-status>: compute the advisory downgrade
# warning (R6), or echo nothing. Advisory only; the caller logs it and stores it in the status
# file, and it never changes the exit code.
#   - a captured model matching the weak-model denylist (cheap markers) -> weak-model warning
#   - a captured non-weak model -> no warning
#   - NO captured model but oracle reported status=already-selected -> BENIGN, no warning: under
#     the default `current` strategy oracle 0.15.2 reports resolved=(unavailable) whenever the
#     account's model was already selected (the steady state), so this is a healthy run whose
#     exact label just was not re-read; warning here would cry wolf on nearly every default run
#     (found by dogfooding PR #20). pg_model_label still renders role-based text.
#   - NO captured model and NO benign status (the run was killed before oracle emitted the
#     evidence line, e.g. an exit-9/harvest, or a genuine read failure) -> cannot-confirm warning.
# The denylist (not a Pro-tier allowlist) is deliberate: an allowlist would false-warn on a
# legitimate future top model whose name lacks "Pro" (e.g. a hypothetical "Sol Ultra").
pg_derive_model_warn() {
  local m="${1:-}" st="${2:-}" weak
  weak="${PRO_GATE_MODEL_WEAK_PATTERN:-mini|nano|instant}"
  if [ -n "$m" ]; then
    printf '%s' "$m" | grep -qiE "$weak" 2>/dev/null \
      && printf "resolved model '%s' matches the weak-model denylist; not the top Pro tier\n" "$m"
    return 0
  fi
  case "$st" in
    already-selected) : ;;  # benign steady state under `current`: no warning
    *) printf '%s\n' "could not confirm the resolved model (the run ended before oracle reported it, or none was captured); showing role-based text" ;;
  esac
}

pg_reservation_restore_from_meta() { # marker -> restore legacy recovery ownership without spending
  local marker="$1" meta host owner repo key pr out spend dir f tmp created existing_pr existing_spend
  meta="$(pg_run_meta_read "$marker" 2>/dev/null || true)"; [ -n "$meta" ] || return 1
  IFS=$'\t' read -r host owner repo key pr out spend <<<"$meta"
  pg_canonical_repo_ok "$host" "$owner" "$repo" || return 1
  pg_round_key_ok "$key" || return 1
  pr="$(pg_pr_number_normalize "$pr")" || return 1
  case "$spend" in ''|*[!0-9]*) return 1;; esac
  dir="$(pg_reservation_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/$marker"; pg_reservation_guard_acquire || return 1
  if [ -e "$f" ] || [ -L "$f" ]; then
    if [ -f "$f" ] && [ ! -L "$f" ]; then
      existing_pr="$(awk -F'\t' 'NR==1{print $1}' "$f" 2>/dev/null)"
      existing_spend="$(awk -F'\t' 'NR==1{print $7}' "$f" 2>/dev/null)"
      pg_reservation_guard_release
      if [ "$existing_pr" = "$key" ] && [ "$existing_spend" = "$spend" ]; then echo existing; return 0; fi
      return 1
    fi
    pg_reservation_guard_release
    return 1
  fi
  created="$spend"
  tmp="$(mktemp "$dir/.${marker}.restore.XXXXXX" 2>/dev/null || true)"
  if [ -n "$tmp" ] && [ -f "$tmp" ] && [ ! -L "$tmp" ] \
     && printf '%s\t%s\t%s\t0\t\t\t%s\tgenerating\n' "$key" "$out" "$created" "$spend" > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$f" 2>/dev/null; then
    pg_reservation_guard_release
    echo created
    return 0
  fi
  [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null || true
  pg_reservation_guard_release
  return 1
}

pg_reservation_remove() { # marker
  local marker="$1" dir
  pg_reservation_marker_ok "$marker" || return 0
  dir="$(pg_reservation_dir)"; pg_reservation_guard_acquire || return 1
  # v0.28: the manifest sidecar (the change's file list for provenance checks) lives and dies
  # with its reservation.
  rm -f "$dir/$marker" "$(pg_manifest_dir)/$marker" "$(pg_manifest_dir)/$marker.nonce" 2>/dev/null
  pg_reservation_guard_release
}

# pg_reservation_note_miss <marker>: one confirmed-absent observation. Echoes "released" when
# the miss limit is reached (reservation removed) or "retained miss/limit" otherwise. Shared by
# reconciliation and the harvest not-found path so both apply the same fail-closed policy.
pg_reservation_note_miss() {
  local marker="$1" dir f pr out created misses slot model spend miss_limit ttl now age
  miss_limit="${PRO_GATE_RESERVATION_MISSES:-3}"
  case "$miss_limit" in ''|*[!0-9]*) miss_limit=3;; esac
  [ "$miss_limit" -ge 2 ] 2>/dev/null || miss_limit=2
  pg_reservation_marker_ok "$marker" || { echo released; return 0; }
  dir="$(pg_reservation_dir)"; f="$dir/$marker"
  pg_reservation_guard_acquire || { echo "retained 0/$miss_limit"; return 0; }
  if [ ! -f "$f" ]; then pg_reservation_guard_release; echo released; return 0; fi
  # Superseded work is intentionally retained for optional audit harvest and already holds no
  # capacity. Absence cannot improve that proof, so it must not rewrite or terminalize the record.
  if [ "$(awk -F'\t' 'NR==1{print $8}' "$f" 2>/dev/null)" = superseded ]; then
    pg_reservation_guard_release; echo "retained superseded"; return 0
  fi
  # Every miss source shares the same wall-clock spacing. This check runs under the reservation
  # guard so concurrent harvest/recover/reconcile callers cannot compress one absence window into
  # the full terminal threshold.
  local interval mt now
  interval="${PRO_GATE_RECONCILE_INTERVAL:-60}"; case "$interval" in ''|*[!0-9]*) interval=60;; esac
  mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"; now="$(date +%s)"
  if [ "$(( now - mt ))" -lt "$interval" ] 2>/dev/null; then
    pg_reservation_guard_release; echo "retained interval/$miss_limit"; return 0
  fi
  # Per-field awk, and ALL SEVEN fields (#68 gate P1): `read` collapses consecutive tabs, and
  # a 6-field rewrite silently erased the v0.31 spend epoch on the first confirmed miss —
  # which then forced a later harvest onto the marker-time fallback and corrupted round
  # ordering. Every reservation mutation must round-trip the whole record.
  pr="$(awk -F'\t' 'NR==1{print $1}' "$f" 2>/dev/null)"
  out="$(awk -F'\t' 'NR==1{print $2}' "$f" 2>/dev/null)"
  created="$(awk -F'\t' 'NR==1{print $3}' "$f" 2>/dev/null)"
  misses="$(awk -F'\t' 'NR==1{print $4}' "$f" 2>/dev/null)"
  slot="$(awk -F'\t' 'NR==1{print $5}' "$f" 2>/dev/null)"
  model="$(awk -F'\t' 'NR==1{print $6}' "$f" 2>/dev/null)"
  spend="$(awk -F'\t' 'NR==1{print $7}' "$f" 2>/dev/null)"
  case "$misses" in ''|*[!0-9]*) misses=0;; esac
  case "$created" in ''|*[!0-9]*) created=0;; esac
  ttl="${PRO_GATE_RESERVATION_TTL:-21600}"; case "$ttl" in ''|*[!0-9]*) ttl=21600;; esac
  now="$(date +%s)"; age=$(( now - created )); [ "$age" -lt 0 ] && age=0
  misses=$(( misses + 1 ))
  if [ "$misses" -ge "$miss_limit" ] && [ "$created" -gt 0 ] && [ "$age" -ge "$ttl" ]; then
    # The miss threshold is terminal only when durable run-meta can bind the proof to one charged
    # attempt. Publish disposition BEFORE releasing the reservation so no fresh caller sees a gap.
    if pg_attempt_terminal_from_meta "$marker" recovery-exhausted bounded-recovery-exhausted; then
      rm -f "$f" "$(pg_manifest_dir)/$marker" "$(pg_manifest_dir)/$marker.nonce" 2>/dev/null
      pg_reservation_guard_release
      pg_attempt_reconcile_terminal "$marker" 2>/dev/null || true
      echo released
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${pr:-diff}" "${out:-}" "${created:-0}" "$misses" "${slot:-}" "${model:-}" "${spend:-}" > "$f.tmp" 2>/dev/null \
        && mv -f "$f.tmp" "$f"
      pg_reservation_guard_release
      echo "retained $misses/$miss_limit"
    fi
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${pr:-diff}" "${out:-}" "${created:-0}" "$misses" "${slot:-}" "${model:-}" "${spend:-}" > "$f.tmp" 2>/dev/null \
      && mv -f "$f.tmp" "$f"
    pg_reservation_guard_release
    echo "retained $misses/$miss_limit"
  fi
}

pg_reservation_find_pr() { # pr-key [include-superseded] -> marker (oldest, best-effort)
  local pr="$1" include="${2:-}" dir f found_pr state
  [ -n "$pr" ] || return 1
  dir="$(pg_reservation_dir)"; [ -d "$dir" ] || return 1
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    pg_reservation_marker_ok "$(basename "$f")" || continue
    found_pr="$(awk -F'\t' 'NR==1{print $1}' "$f" 2>/dev/null)"
    state="$(awk -F'\t' 'NR==1{print $8}' "$f" 2>/dev/null)"
    [ "$state" = superseded ] && [ "$include" != include-superseded ] && continue
    [ "$found_pr" = "$pr" ] && { basename "$f"; return 0; }
  done
  return 1
}

pg_reservation_count() {
  local dir f n=0; dir="$(pg_reservation_dir)"; [ -d "$dir" ] || { echo 0; return; }
  for f in "$dir"/*; do [ -f "$f" ] && n=$((n + 1)); done
  echo "$n"
}

# pg_reservation_slot_plan <effective-concurrency>: compute the slot-acquisition plan under the
# reservation guard. Echoes "R|excluded slots": scan slots 1..R skipping the excluded ones.
# Slot-tagged reservations exclude their exact slot (the tab still occupies that account
# capacity); reservations without a slot (legacy) and tagged slots outside the current range
# shrink the range instead. Processed descending so range shrink cascades correctly.
pg_reservation_slot_plan() {
  local eff="${1:-1}" dir f slot state slots="" excl="" r legacy=0 s avail
  dir="$(pg_reservation_dir)"
  r="$eff"
  if [ -d "$dir" ]; then
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      # A COMPLETE reservation is a harvest pointer, not account occupancy (#82): its review
      # stopped generating, so it holds no slot even though it stays collectable until TTL.
      # Empty/legacy state reads as generating, so pre-state records keep their hold — an
      # unknown state must never free capacity (overbooking the account is the worse error).
      state="$(awk -F'\t' 'NR==1{print $8}' "$f" 2>/dev/null)"
      case "$state" in complete|superseded) continue;; esac
      slot="$(awk -F'\t' 'NR==1{print $5}' "$f" 2>/dev/null)"
      case "$slot" in
        ''|*[!0-9]*) legacy=$(( legacy + 1 ));;
        *) slots="$slots $slot";;
      esac
    done
  fi
  r=$(( r - legacy ))
  for s in $(printf '%s\n' $slots | sort -rn); do
    if [ "$s" -le "$r" ] 2>/dev/null; then excl="$excl $s"; else r=$(( r - 1 )); fi
  done
  # Field 3 is the TRUE availability: the scan bound MINUS its in-range exclusions. Callers must
  # gate on this and never on the bound — "1|1" is a bound of 1 whose only slot is excluded, i.e.
  # an EMPTY scannable set. Gating on the bound made runs call pg_lock_n against an impossible
  # plan every wait slice and report "all N slots busy" while the locks were free (#82).
  avail="$r"
  for s in $excl; do [ "$s" -le "$r" ] 2>/dev/null && avail=$(( avail - 1 )); done
  [ "$avail" -ge 0 ] 2>/dev/null || avail=0
  printf '%s|%s|%s\n' "$r" "${excl# }" "$avail"
}

# pg_reservation_set_state <marker> <generating|complete|superseded>: flip ONLY the lifecycle field,
# preserving every other field verbatim. Deliberately not pg_reservation_write: that helper takes
# `out` as an argument and would blank the harvest pointer when called without it, and it resets
# the miss counter. Marking completion must change exactly one thing — whether this review still
# occupies account capacity — and nothing about how it is later collected (#82).
# pg_reservation_supersede <marker> <canonical-key> <spend> <expected-head>: exact transition for
# current and legacy `diff` records. The caller has already proved GitHub supersession; this helper
# revalidates immutable input + canonical run-meta under the reservation guard before its final
# compare-and-swap. Arbitrary key, identity, and charge mismatches remain fail-closed.
#
# <expected-head> (#134) is the head OID the CALLER read from the binding and then validated against
# GitHub. Without it the CAS compared repository, PR and charge but never the head, so a decision
# taken against one binding could commit against another: bindings are write-once via `ln`, but
# pg_attempt_disposition_cleanup unlinks one outside this guard, making remove-then-rewrite with a
# different head reachable. That releases capacity for CURRENT-head work and permits a second paid
# review of the same change. Required and fail-closed: an empty or malformed head is a refusal, never
# a fall-through to the old unchecked behaviour.
pg_reservation_supersede() {
  local marker="$1" key="$2" expected_spend="$3" expected_head="${4:-}"
  local dir f rc pr out created misses slot model spend tmp
  local meta mh mo mr mkey mpr mout mspend binding bh bo br bpr bepoch bhead
  pg_reservation_marker_ok "$marker" || return 1
  pg_round_key_ok "$key" || return 1
  case "$expected_spend" in ''|*[!0-9]*) return 1;; esac
  # Same shape gate the caller applies to a binding head before trusting it (oracle-review.sh).
  case "$expected_head" in ''|*[!0-9a-f]*) return 1;; esac
  { [ "${#expected_head}" -eq 40 ] || [ "${#expected_head}" -eq 64 ]; } || return 1
  dir="$(pg_reservation_dir)"; f="$dir/$marker"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  pg_reservation_guard_acquire || return 1
  if [ ! -f "$f" ] || [ -L "$f" ]; then pg_reservation_guard_release; return 1; fi

  # Re-read both marker-addressed immutable identities inside the mutation critical section. Marker
  # mint time can precede charge while a run waits for locks, so it is not charge evidence.
  meta="$(pg_run_meta_read "$marker" 2>/dev/null || true)"
  binding="$(pg_review_input_binding_read "$marker" 2>/dev/null || true)"
  if [ -z "$meta" ] || [ -z "$binding" ]; then pg_reservation_guard_release; return 1; fi
  IFS=$'\t' read -r mh mo mr mkey mpr mout mspend <<<"$meta"
  bh="$(jq -r .repository.host <<<"$binding")"; bo="$(jq -r .repository.owner <<<"$binding")"
  br="$(jq -r .repository.repo <<<"$binding")"; bpr="$(jq -r .target.pr <<<"$binding")"
  bepoch="$(jq -r .charged_spend_epoch <<<"$binding")"
  bhead="$(jq -r '.target.head_oid // ""' <<<"$binding")"
  # #134: the head is part of the compare-and-swap, not just the caller's private reasoning. The
  # binding under this guard must still carry the exact head the caller validated against GitHub.
  if [ "$mkey" != "$key" ] || [ "$mspend" != "$expected_spend" ] \
     || [ "$bh" != "$mh" ] || [ "$bo" != "$mo" ] || [ "$br" != "$mr" ] \
     || [ "$bpr" != "$mpr" ] || [ "$bepoch" != "$mspend" ] \
     || [ "$bhead" != "$expected_head" ]; then
    pg_reservation_guard_release; return 1
  fi

  pr="$(awk -F'\t' 'NR==1{print $1}' "$f" 2>/dev/null)"
  out="$(awk -F'\t' 'NR==1{print $2}' "$f" 2>/dev/null)"
  created="$(awk -F'\t' 'NR==1{print $3}' "$f" 2>/dev/null)"
  misses="$(awk -F'\t' 'NR==1{print $4}' "$f" 2>/dev/null)"
  slot="$(awk -F'\t' 'NR==1{print $5}' "$f" 2>/dev/null)"
  model="$(awk -F'\t' 'NR==1{print $6}' "$f" 2>/dev/null)"
  spend="$(awk -F'\t' 'NR==1{print $7}' "$f" 2>/dev/null)"
  case "$pr" in "$key"|diff) ;; *) pg_reservation_guard_release; return 1;; esac
  if [ "$spend" != "$expected_spend" ]; then
    if [ "$pr" != diff ] || [ -n "$spend" ]; then pg_reservation_guard_release; return 1; fi
    spend="$expected_spend"
  fi
  case "$misses" in ''|*[!0-9]*) misses=0;; esac
  tmp="$(mktemp "$dir/.${marker}.supersede.XXXXXX" 2>/dev/null)" \
    || { pg_reservation_guard_release; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tsuperseded\n' \
    "$key" "$out" "$created" "$misses" "$slot" "$model" "$spend" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f"
  rc=$?; [ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null
  pg_reservation_guard_release; return "$rc"
}

pg_reservation_set_state() {
  local marker="$1" state="$2" dir f rc pr out created misses slot model spend current tmp
  case "$state" in generating|complete|superseded) ;; *) return 1;; esac
  pg_reservation_marker_ok "$marker" || return 1
  dir="$(pg_reservation_dir)"; f="$dir/$marker"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  pg_reservation_guard_acquire || return 1
  # Re-check under the guard: a concurrent harvest may have released the record while we probed,
  # and rewriting here would resurrect a collected reservation and re-block capacity until TTL.
  if [ ! -f "$f" ] || [ -L "$f" ]; then pg_reservation_guard_release; return 1; fi
  # Supersession is monotonic. Later recovery/harvest bookkeeping may refresh the record, but no
  # generic state write can make obsolete evidence occupy account capacity again.
  current="$(awk -F'\t' 'NR==1{print $8}' "$f" 2>/dev/null)"
  [ "$current" = superseded ] && state=superseded
  # awk per field, NOT `read`: tab is IFS-whitespace, so consecutive tabs from an empty
  # slot/model collapse and shift every later field.
  pr="$(awk -F'\t' 'NR==1{print $1}' "$f" 2>/dev/null)"
  out="$(awk -F'\t' 'NR==1{print $2}' "$f" 2>/dev/null)"
  created="$(awk -F'\t' 'NR==1{print $3}' "$f" 2>/dev/null)"
  misses="$(awk -F'\t' 'NR==1{print $4}' "$f" 2>/dev/null)"
  slot="$(awk -F'\t' 'NR==1{print $5}' "$f" 2>/dev/null)"
  model="$(awk -F'\t' 'NR==1{print $6}' "$f" 2>/dev/null)"
  spend="$(awk -F'\t' 'NR==1{print $7}' "$f" 2>/dev/null)"
  case "$misses" in ''|*[!0-9]*) misses=0;; esac
  tmp="$(mktemp "$dir/.${marker}.state.XXXXXX" 2>/dev/null)" \
    || { pg_reservation_guard_release; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pr" "$out" "$created" "$misses" "$slot" "$model" "$spend" "$state" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f"
  rc=$?; [ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null
  pg_reservation_guard_release; return "$rc"
}

# pg_reservation_holding_count: how many reservations actually OCCUPY account capacity, i.e.
# everything except the ones proven complete or superseded. Distinct from pg_reservation_count, which counts
# collectable records: once a finished review stops holding its slot, "a reservation exists" and
# "capacity is reserved" stop being the same question, and a timeout caused by genuinely busy
# runs must not be blamed on an uncollected review that is holding nothing (#82).
pg_reservation_holding_count() {
  local dir f n=0
  dir="$(pg_reservation_dir)"; [ -d "$dir" ] || { echo 0; return 0; }
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$(awk -F'\t' 'NR==1{print $8}' "$f" 2>/dev/null)" in complete|superseded) continue;; esac
    n=$(( n + 1 ))
  done
  echo "$n"
}

# pg_report_capacity_holders [effective]: explain, on stderr, why no slot is free. The wait loop
# and the exit-7 path both use it because "all N review slots are busy" is the one thing an
# operator can already see is false — the locks are free and the browser is idle. What they cannot
# see is that a FINISHED review still holds its slot until someone collects it (#82). Naming the
# marker and the exact free-it command turns a 40-minute mystery into one command.
pg_report_capacity_holders() {
  local eff="${1:-}" dir f marker state pr held=0
  dir="$(pg_reservation_dir)"; [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$(awk -F'\t' 'NR==1{print $8}' "$f" 2>/dev/null)" in complete|superseded) continue;; esac
    held=$(( held + 1 ))
  done
  [ "$held" -gt 0 ] || return 0
  echo "[pro-gate] 0 of ${eff:-?} effective slot(s) free — ${held} held by in-progress reservation(s):" >&2
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    marker="$(basename "$f")"
    pr="$(awk -F'\t' 'NR==1{print $1}' "$f" 2>/dev/null)"
    state="$(pg_reservation_state "$marker" 2>/dev/null || echo generating)"
    case "$state" in
      complete|superseded) continue ;;
      *) echo "  $marker  [$pr] generating — still using the account" >&2 ;;
    esac
  done
  echo "  collect a finished one for FREE (no new spend, never re-run):" >&2
  echo "    oracle-review.sh --harvest <marker> --out <path> --timeout 20m" >&2
}

# pg_reservation_state <marker>: echo the lifecycle state (8th field) of a reservation —
# "complete" once its review is provably finished, "superseded" once immutable target proof shows
# it cannot apply to the current/merged PR, and "generating" otherwise. Legacy/unknown states keep
# occupying capacity (fail closed).
pg_reservation_state() {
  local marker="$1" f state
  pg_reservation_marker_ok "$marker" || return 1
  f="$(pg_reservation_dir)/$marker"
  [ -f "$f" ] || return 1
  state="$(awk -F'\t' 'NR==1{print $8}' "$f" 2>/dev/null)"
  case "$state" in complete) echo complete;; superseded) echo superseded;; *) echo generating;; esac
}

# pg_reservation_expire_if_stale <marker>: report THIS marker past TTL without releasing it.
# TTL is a precondition for recovery exhaustion, never terminal proof by itself. The caller must
# combine it with confirmed marker misses through pg_reservation_note_miss; only that bounded proof
# publishes a disposition before releasing capacity.
# Echoes "stale" when past TTL, nothing otherwise.
pg_reservation_expire_if_stale() {
  local marker="$1" f created ttl now
  pg_reservation_marker_ok "$marker" || return 0
  f="$(pg_reservation_dir)/$marker"
  [ -f "$f" ] || return 0
  created="$(awk -F'\t' 'NR==1{print $3}' "$f" 2>/dev/null)"
  case "$created" in ''|*[!0-9]*) return 0;; esac
  ttl="${PRO_GATE_RESERVATION_TTL:-21600}"; case "$ttl" in ''|*[!0-9]*) ttl=21600;; esac
  now="$(date +%s)"
  [ $(( now - created )) -ge "$ttl" ] || return 0
  echo stale
}

# pg_harvest_claimed <marker>: 0 when some process is COLLECTING this marker right now, i.e.
# holds its harvest lock (#68 gate r2 P1). Every reconciler consults this before reaping, so a
# reservation cannot be removed out from under an in-flight collection by ANY process — the
# collector's own sweep, a concurrent harvest, or a fresh dispatch. Non-blocking probe: we test
# whether the lock is takeable and immediately release, never queueing behind the holder.
# A stale lock FILE with no holder reads as unclaimed (flock is inode-scoped, not path-scoped),
# which is what the housekeeping sweep of harvest-locks/ already relies on.
pg_harvest_claimed() {
  local marker="$1" f pfd rc=1
  pg_reservation_marker_ok "$marker" || return 1
  f="${PRO_GATE_HARVEST_LOCK_DIR:-$PRO_GATE_HOME/harvest-locks}/$marker"
  if pg_have flock; then
    [ -f "$f" ] || return 1
    if { exec {pfd}>>"$f"; } 2>/dev/null; then
      flock -n "$pfd" 2>/dev/null || rc=0     # could NOT take it => someone holds it
      eval "exec ${pfd}>&-" 2>/dev/null
    fi
    return "$rc"
  fi
  # mkdir-lock platforms (stock macOS): the directory exists only while held. Owner metadata
  # must PROVE a live holder (#68 gate r3 P2) — a crash between mkdir and the pid write, or a
  # recycled pid, would otherwise mark the reservation claimed forever and freeze reconciliation
  # (pg_lock cannot reap an empty-pid directory either). Require a live pid AND, when the lock
  # recorded a process-identity token, a matching one.
  [ -d "$f.d" ] || return 1
  local opid otok
  opid="$(cat "$f.d/pid" 2>/dev/null || true)"
  case "$opid" in ''|*[!0-9]*) return 1;; esac        # torn/missing owner record: not a claim
  kill -0 "$opid" 2>/dev/null || return 1             # dead holder: stale directory
  otok="$(cat "$f.d/token" 2>/dev/null || true)"
  if [ -n "$otok" ] && [ "$otok" != "$(pg_pid_token "$opid" 2>/dev/null)" ]; then
    return 1                                          # pid reused by an unrelated process
  fi
  return 0
}

# pg_reservation_reconcile <salvage-script> <port>: drop reservations older than TTL or only
# after N consecutive confirmed-absent probes. A single 10s miss is NOT proof of loss: suspended
# renderers, hydration delays, and temporary marker-read failures caused false releases in review.
# Live (0) resets misses; throttle (5) and other errors keep state fail-closed.
pg_reservation_reconcile() {
  local salvage="$1" port="$2" dir ttl miss_limit interval now f marker pr out created misses slot model spend age mt rc probe_out
  dir="$(pg_reservation_dir)"; [ -d "$dir" ] || return 0
  ttl="${PRO_GATE_RESERVATION_TTL:-21600}"; miss_limit="${PRO_GATE_RESERVATION_MISSES:-3}"
  interval="${PRO_GATE_RECONCILE_INTERVAL:-60}"; now="$(date +%s)"
  case "$miss_limit" in ''|*[!0-9]*) miss_limit=3;; esac
  [ "$miss_limit" -ge 2 ] 2>/dev/null || miss_limit=2
  for f in "$dir"/*; do
    [ -f "$f" ] || continue; marker="$(basename "$f")"
    pg_reservation_marker_ok "$marker" || continue
    [ "$(pg_reservation_state "$marker" 2>/dev/null || echo generating)" = superseded ] && continue
    # Never reap a marker that is being COLLECTED RIGHT NOW (#68 gate P1, r2 P1). Removing it
    # mid-harvest lets a concurrent same-change run submit a duplicate, and a still-generating
    # result would then recreate the record from scratch — fresh `created` (defeating TTL
    # self-clear) under a fallback "diff" key (defeating same-change redirection). The harvest
    # LOCK FILE is that claim, so this holds for EVERY reconciler (fresh dispatch and other
    # harvests), not just the collecting process: a per-invocation skip variable would only
    # have protected the one sweep that already knew.
    if pg_harvest_claimed "$marker"; then continue; fi
    # awk per field, NOT `read`: tab is IFS-whitespace, so consecutive tabs from an empty
    # slot/model collapse and shift every later field (the trap pg_reservation_read_model
    # documents). That would silently drop the v0.31 spend epoch on the rewrite below.
    pr="$(awk -F'\t' 'NR==1{print $1}' "$f" 2>/dev/null)"
    out="$(awk -F'\t' 'NR==1{print $2}' "$f" 2>/dev/null)"
    created="$(awk -F'\t' 'NR==1{print $3}' "$f" 2>/dev/null)"
    misses="$(awk -F'\t' 'NR==1{print $4}' "$f" 2>/dev/null)"
    slot="$(awk -F'\t' 'NR==1{print $5}' "$f" 2>/dev/null)"
    model="$(awk -F'\t' 'NR==1{print $6}' "$f" 2>/dev/null)"
    spend="$(awk -F'\t' 'NR==1{print $7}' "$f" 2>/dev/null)"
    case "$created" in ''|*[!0-9]*) created=0;; esac
    case "$misses" in ''|*[!0-9]*) misses=0;; esac
    age=$(( now - created ))
    if [ "$created" -gt 0 ] && [ "$age" -ge "$ttl" ]; then
      echo "[pro-gate] reservation $marker is past TTL (${age}s >= ${ttl}s); retaining until bounded marker-miss proof terminalizes it" >&2
    fi
    # TTL-only mode: harvest performs its own observation. It never releases on elapsed time alone;
    # misses remain explicit proof and are counted by that caller when its capture is absent.
    [ "${PG_RES_TTL_ONLY:-0}" = 1 ] && continue
    # Rate-limit probes per marker by file mtime: N concurrent fresh runs must not turn one
    # real absence window into N miss increments, and back-to-back reconciles should not spam
    # conversation probes. Writes/updates touch mtime, so consecutive misses are spaced by at
    # least this interval of wall time.
    mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
    [ "$(( now - mt ))" -lt "$interval" ] 2>/dev/null && continue
    rc=2; probe_out="$(node "$salvage" --probe "$marker" 10 "$port" 2>&1 >/dev/null)"; rc=$?
    case "$rc" in
      0)
        # A found conversation is not automatically an OCCUPIED one. ChatGPT keeps conversations
        # server-side forever, so a finished review probes as present on every sweep, resets its
        # miss streak, and used to hold its slot for the full 6h TTL — one uncollected review
        # could starve the whole machine at effective concurrency 1 (#82). Release the capacity
        # the moment completion is proven, while KEEPING the record so the review stays
        # collectable for free. Anything short of proof stays generating.
        if printf '%s' "$probe_out" | grep -q '^probe-state: complete$'; then
          if [ "$(pg_reservation_state "$marker" 2>/dev/null)" != complete ] \
             && pg_reservation_set_state "$marker" complete; then
            echo "[pro-gate] reservation $marker is complete — releasing its slot; collect it with --harvest (no new spend)" >&2
          fi
        elif printf '%s' "$probe_out" | grep -q '^probe-state: terminal-infrastructure$'; then
          if pg_attempt_terminal_from_meta "$marker" submitted-terminal exact-owned-infrastructure-terminal \
             && pg_attempt_reconcile_terminal "$marker"; then
            echo "[pro-gate] reservation $marker ended in an exact-owned ChatGPT infrastructure error — recovery released, round retained" >&2
          else
            echo "[pro-gate] terminal infrastructure proof for $marker could not be persisted safely — reservation retained" >&2
          fi
        else
          [ "$misses" -eq 0 ] || {
            pg_reservation_guard_acquire || continue
            # The harvest may have removed the file during the probe; rewriting would resurrect a
            # released reservation and block capacity until TTL, so re-check under the guard.
            if [ -f "$f" ]; then
              printf '%s\t%s\t%s\t0\t%s\t%s\t%s\t%s\n' "$pr" "$out" "$created" "${slot:-}" "${model:-}" "${spend:-}" "generating" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
            fi
            pg_reservation_guard_release
          }
        fi
        ;;
      4)
        echo "[pro-gate] reservation $marker probe miss -> $(pg_reservation_note_miss "$marker")" >&2
        ;;
      *) : ;; # throttle/CDP error/inconclusive: retain without incrementing misses
    esac
  done
}

# pg_ledger_append <json-line>: flock-guarded append to the run ledger
# ($PRO_GATE_HOME/ledger.jsonl) — one line per finished/deferred run. Best-effort:
# observability must never fail a review.
pg_ledger_append() {
  local ledger="${PRO_GATE_LEDGER:-$PRO_GATE_HOME/ledger.jsonl}" line="$1" lfd
  [ -n "$line" ] || return 0
  if pg_have flock; then
    if { exec {lfd}>>"$ledger"; } 2>/dev/null; then
      flock -w 5 "$lfd" 2>/dev/null || true
      { printf '%s\n' "$line" >&"$lfd"; } 2>/dev/null || true
      eval "exec ${lfd}>&-" 2>/dev/null
      return 0
    fi
  fi
  { printf '%s\n' "$line" >> "$ledger"; } 2>/dev/null || true
}

# Adaptive concurrency governor: effective review slots EARN their way up to the ceiling
# (PRO_GATE_MAX_CONCURRENCY) and drop instantly on trouble, so raising the ceiling is safe
# to try without babysitting. State: $PRO_GATE_HOME/ramp.state = "level<TAB>streak<TAB>ts".
# Rules (pg_ramp_update, serialized under flock):
#   clean run (exit 0, no throttle) -> streak+1; level+1 when streak >= PRO_GATE_RAMP_STREAK
#                                      (default 5), streak resets
#   throttle observed               -> level=1, streak=0 (the engine cooldown also defers)
#   failed run (exit 6)             -> streak=0, level held
#   deferred / lock-timeout (7, 8)  -> no change (nothing was spent, nothing learned)
# PRO_GATE_RAMP=0 pins effective = ceiling (pre-v0.19 behavior).
pg_ramp_level() {  # $1 = ceiling; echoes the effective concurrency
  local ceiling="${1:-1}" state level
  [ "${PRO_GATE_RAMP:-1}" = 1 ] || { echo "$ceiling"; return 0; }
  state="${PRO_GATE_RAMP_STATE:-$PRO_GATE_HOME/ramp.state}"
  level="$(awk -F'\t' 'NR==1{print $1}' "$state" 2>/dev/null)"
  case "$level" in ''|*[!0-9]*) level=1 ;; esac
  [ "$level" -lt 1 ] && level=1
  [ "$level" -gt "$ceiling" ] && level="$ceiling"
  echo "$level"
}

pg_ramp_update() {  # $1 = clean|throttle|failed, $2 = ceiling
  [ "${PRO_GATE_RAMP:-1}" = 1 ] || return 0
  local outcome="$1" ceiling="${2:-1}" state need level streak rfd lockdir="" waited
  state="${PRO_GATE_RAMP_STATE:-$PRO_GATE_HOME/ramp.state}"
  need="${PRO_GATE_RAMP_STREAK:-5}"
  # Serialize the read-modify-write (v0.19.1, pro-gate self-review P1): flock where
  # available, else a mkdir spinlock (macOS). If NO lock can be obtained, skip the update
  # rather than racing — a lost 'clean' credit is harmless, and a lost 'throttle' drop is
  # still covered by the independent cooldown file, which blocks all new spends regardless
  # of the ramp level.
  if pg_have flock; then
    if ! { { exec {rfd}>>"$state.lock"; } 2>/dev/null && flock -w 10 "$rfd" 2>/dev/null; }; then
      echo "[pro-gate ramp] could not lock ramp state — skipping this update" >&2
      [ -n "${rfd:-}" ] && eval "exec ${rfd}>&-" 2>/dev/null
      return 0
    fi
  else
    lockdir="$state.lock.d"; waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      waited=$(( waited + 1 ))
      if [ "$waited" -ge 10 ]; then
        echo "[pro-gate ramp] could not lock ramp state — skipping this update" >&2
        return 0
      fi
      sleep 1
    done
  fi
  level="$(awk -F'\t' 'NR==1{print $1}' "$state" 2>/dev/null)"
  streak="$(awk -F'\t' 'NR==1{print $2}' "$state" 2>/dev/null)"
  case "$level" in ''|*[!0-9]*) level=1 ;; esac
  case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
  case "$outcome" in
    clean)
      streak=$(( streak + 1 ))
      if [ "$streak" -ge "$need" ] && [ "$level" -lt "$ceiling" ]; then
        level=$(( level + 1 )); streak=0
        echo "[pro-gate ramp] ${need} clean runs at level $(( level - 1 )) — raising concurrency to ${level} (ceiling ${ceiling})" >&2
      fi
      ;;
    throttle)
      level=1; streak=0
      echo "[pro-gate ramp] throttle observed — concurrency dropped to 1 (re-earns via clean streaks)" >&2
      ;;
    failed) streak=0 ;;
    *) : ;;
  esac
  { printf '%s\t%s\t%s\n' "$level" "$streak" "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$state.tmp" && mv -f "$state.tmp" "$state"; } 2>/dev/null || true
  [ -n "${rfd:-}" ] && eval "exec ${rfd}>&-" 2>/dev/null
  [ -n "$lockdir" ] && rmdir "$lockdir" 2>/dev/null
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.22: per-PR review round budget. Ledger evidence (2026-07-08..16): unbounded
# review->fix->re-review loops spent 10-16 Pro slots on a SINGLE PR in one day (each slot
# 10-60+ min, serialized against one account), 8h+ of wall clock per PR plus queue starvation
# for every other PR. Each slot-spending engine invocation records one "round" against a
# repo-scoped key (PR_KEY for PR runs; repo+branch for --diff runs); a fresh run whose key has
# exhausted its budget inside the rolling PRO_GATE_ROUNDS_WINDOW (default 24h) is refused
# BEFORE any lock or slot is taken (exit 12, NO quota spent). Harvests and no-spend exits
# (7 lock timeout, 8 deferred, 11 oversized, 12 round-capped) never record a round.
#
# v0.31 (#65): the budget is a trajectory-aware GOVERNOR, same shape as the concurrency ramp
# (pg_ramp_*): adaptive within a hard ceiling, earned by demonstrated progress, collapsed on
# churn. Fleet evidence (254 gated changes, 737 spends, 28 audit trails): a flat cap of 4 was
# wrong in BOTH directions — converging gates (open P0/P1 shrinking every round, e.g.
# 6→5→3→2→0-SHIP at round 5) needed per-run human forcing past it, while whack-a-mole gates
# (5→7→8→10) burned all four slots on churn. Governor: base grant PRO_GATE_ROUNDS_BASE
# (default 3); each completed re-review whose OPEN P0+P1 count (RESOLVED-filtered, from the
# rounds/<key>.hist trajectory) is strictly below its predecessor's earns +1, clamped to the
# immovable ceiling PRO_GATE_ROUNDS_CEILING (default 8); two consecutive non-shrinking
# re-reviews collapse the grant (early exit 12 — churn stops BEFORE the base is spent, not
# after). An explicitly SET PRO_GATE_MAX_ROUNDS_PER_PR pins the legacy flat cap instead
# (trajectory ignored; =0 stays the operator lockdown). PRO_GATE_ROUND_GUARD=0 disables the
# budget; PRO_GATE_FORCE_ROUND=1 lets ONE deliberate invocation past it (its round still
# records, so the next unforced run stays governed). State: $PRO_GATE_HOME/rounds/<key>
# (one epoch-seconds line per slot-spending run) + rounds/<key>.hist (one line per COMPLETED
# review: epoch, verdict, open P0, open P1, resolved, still-present), both pruned to the
# window. The caller-side converge policy (SKILL.md §6) remains the stricter first line;
# this governor is the engine-enforced backstop that catches EVERY caller.
# ─────────────────────────────────────────────────────────────────────────────
pg_rounds_dir() { echo "${PRO_GATE_ROUNDS_DIR:-$PRO_GATE_HOME/rounds}"; }

pg_round_window_secs() {
  # pg_dur_secs falls back to 1800s on garbage, the right direction for timeouts ("a typo can
  # never mean no timeout") but the WRONG one here: "1d" or "24hr" would silently shrink the
  # 24h window to 30 min and un-cap the loop. Validate first and fail LARGE (24h) instead.
  local w="${PRO_GATE_ROUNDS_WINDOW:-24h}" n
  n="${w%[smhSMH]}"
  case "$n" in ''|*[!0-9]*)
    echo "[pro-gate rounds] unparseable PRO_GATE_ROUNDS_WINDOW='${w}' (use 90 / 45m / 24h); defaulting to 24h" >&2
    echo 86400; return;;
  esac
  pg_dur_secs "$w"
}

# Keys become filenames under PRO_GATE_HOME: enforce the same safe charset as reservation
# markers (every character, no "/" anywhere).
pg_round_key_ok() {
  case "${1:-}" in '') return 1;; *[!A-Za-z0-9.-]*) return 1;; *) return 0;; esac
}

# pg_title_seq_next <key>: monotonic per-change ordinal for the sidebar title label — NEVER
# window-pruned. Lives in its OWN directory (gate #57 r4): rounds/ is swept whole by engines
# <v0.29, so a supported >24h rollback would delete a rounds/-resident sequence and restart
# labels at r1. Single writer (called only under the per-change lock); gaps are fine. Returns
# NONZERO when the ordinal could not be persisted (r4 P2) — the caller must then use a unique
# fallback label rather than risk duplicate ordinals from a broken store.
pg_title_seq_dir() { echo "${PRO_GATE_TITLE_SEQ_DIR:-$PRO_GATE_HOME/title-seq}"; }
pg_title_seq_next() {
  local f n
  pg_round_key_ok "$1" || return 1
  f="$(pg_title_seq_dir)/$1"
  mkdir -p "$(pg_title_seq_dir)" 2>/dev/null || return 1
  # One-time migration from the short-lived rounds/<key>.seq location (v0.29 pre-release).
  [ -f "$f" ] || { [ -f "$(pg_rounds_dir)/$1.seq" ] && mv "$(pg_rounds_dir)/$1.seq" "$f" 2>/dev/null; } || true
  n="$(cat "$f" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0;; esac
  n=$((n + 1))
  { printf '%s' "$n" > "$f.tmp" && mv -f "$f.tmp" "$f"; } 2>/dev/null || { rm -f "$f.tmp" 2>/dev/null; return 1; }
  echo "$n"
}

# v0.32: marker-addressed canonical conversation title. The engine publishes this before the
# browser run starts; later harvest/fast-path processes can therefore organize the same server-
# side conversation without reconstructing PR or round state. Atomic replacement prevents the
# CDP organizer from reading a partial title while a fresh run is publishing it.
pg_conversation_title_dir() { echo "$PRO_GATE_HOME/conversation-titles"; }
pg_conversation_title_write() {  # <marker> <one-line-title>
  local marker="$1" title="$2" dir f tmp
  pg_reservation_marker_ok "$marker" || return 1
  [ -n "$title" ] && [ "${#title}" -le 200 ] || return 1
  case "$title" in *$'\n'*|*$'\r'*) return 1;; esac
  dir="$(pg_conversation_title_dir)"; f="$dir/$marker"; tmp="$f.tmp.$$"
  mkdir -p "$dir" 2>/dev/null || return 1
  if printf '%s\n' "$title" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

pg_round_count() {  # $1 = key; echoes the rounds recorded inside the rolling window
  local key="$1" f now win t n=0
  pg_round_key_ok "$key" || { echo 0; return; }
  f="$(pg_rounds_dir)/$key"
  [ -f "$f" ] || { echo 0; return; }
  win="$(pg_round_window_secs)"; now="$(date +%s)"
  while IFS= read -r t; do
    case "$t" in ''|*[!0-9]*) continue;; esac
    [ $(( now - t )) -lt "$win" ] && n=$(( n + 1 ))
  done < "$f"
  echo "$n"
}

pg_round_record() {  # $1 = key; prune entries older than the window, append now. Sets
  # PG_ROUND_SPEND_EPOCH to the epoch actually appended — the round's charge time, which is
  # what trajectory history must be stamped with (#66 gate r3 P1). The marker's epoch is NOT
  # that moment: it is minted before the per-change lock AND the account-slot wait (each up to
  # PRO_GATE_LOCK_WAIT, 2400s by default), so a queued run's history row could expire ~80 min
  # before its own spend, or order concurrent runs by process start rather than charge order.
  # Best-effort
  # bookkeeping (same posture as pg_ledger_append): it must never fail a review, but every
  # fail-open path WARNS on stderr, because a silently unrecordable round means the budget
  # under-counts and the guard quietly stops guarding. Same-key engine runs are already
  # serialized by the per-change lock; this file lock just keeps the rewrite atomic against
  # out-of-band readers/writers.
  local key="$1" dir f now win t rfd lockdir="" waited=0
  PG_ROUND_SPEND_EPOCH=""
  pg_round_key_ok "$key" || return 0
  dir="$(pg_rounds_dir)"
  mkdir -p "$dir" 2>/dev/null || {
    echo "[pro-gate rounds] cannot create ${dir}; round NOT recorded (budget will under-count)" >&2
    return 0
  }
  f="$dir/$key"; win="$(pg_round_window_secs)"; now="$(date +%s)"
  if pg_have flock; then
    if ! { { exec {rfd}>>"$f.lock"; } 2>/dev/null && flock -w 10 "$rfd" 2>/dev/null; }; then
      echo "[pro-gate rounds] could not lock ${f}; round NOT recorded (budget will under-count)" >&2
      [ -n "${rfd:-}" ] && eval "exec ${rfd}>&-" 2>/dev/null
      return 0
    fi
  else
    lockdir="$f.lock.d"
    while ! mkdir "$lockdir" 2>/dev/null; do
      waited=$(( waited + 1 ))
      if [ "$waited" -ge 10 ]; then
        echo "[pro-gate rounds] could not lock ${f}; round NOT recorded (budget will under-count)" >&2
        return 0
      fi
      sleep 1
    done
  fi
  {
    if [ -f "$f" ]; then
      while IFS= read -r t; do
        case "$t" in ''|*[!0-9]*) continue;; esac
        [ $(( now - t )) -lt "$win" ] && printf '%s\n' "$t"
      done < "$f"
    fi
    printf '%s\n' "$now"
  } > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" && PG_ROUND_SPEND_EPOCH="$now" \
    || echo "[pro-gate rounds] could not write ${f}; round NOT recorded (budget will under-count)" >&2
  [ -n "${rfd:-}" ] && eval "exec ${rfd}>&-" 2>/dev/null
  [ -n "$lockdir" ] && rmdir "$lockdir" 2>/dev/null
  return 0
}

# pg_round_unrecord <key>: refund ONE round (drop the newest entry). Called ONLY on outcomes
# that PROVE the submission never landed (the Cloudflare challenge path: oracle detects the
# interstitial before any prompt reaches the model). Without the refund, a few challenge
# responses inside the window would exit-12-block a change for a day despite zero Pro spend
# (dogfood gate round-2 P1). Outcomes with an UNKNOWN fate (throttle, watchdog kills, failed
# salvage) must NOT refund: over-counting wastes one retry, under-counting resurrects the
# unbounded loop.
pg_round_unrecord() {
  local key="$1" f rfd lockdir="" waited=0 n
  pg_round_key_ok "$key" || return 0
  f="$(pg_rounds_dir)/$key"
  [ -f "$f" ] || return 0
  if pg_have flock; then
    if ! { { exec {rfd}>>"$f.lock"; } 2>/dev/null && flock -w 10 "$rfd" 2>/dev/null; }; then
      [ -n "${rfd:-}" ] && eval "exec ${rfd}>&-" 2>/dev/null
      return 0
    fi
  else
    lockdir="$f.lock.d"
    while ! mkdir "$lockdir" 2>/dev/null; do
      waited=$(( waited + 1 )); [ "$waited" -ge 10 ] && return 0; sleep 1
    done
  fi
  n="$(grep -c . "$f" 2>/dev/null)"; [ -n "$n" ] || n=0
  if [ "$n" -le 1 ] 2>/dev/null; then
    rm -f "$f" 2>/dev/null
  else
    head -n $(( n - 1 )) "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  fi
  [ -n "${rfd:-}" ] && eval "exec ${rfd}>&-" 2>/dev/null
  [ -n "$lockdir" ] && rmdir "$lockdir" 2>/dev/null
  return 0
}

# pg_round_note_severity <key> <review-file>: record the P0/P1 counts of a change's most
# recent COMPLETED review in a sidecar ($rounds/<key>.last), and append the full per-round
# line (epoch, verdict word, open P0, open P1, resolved, still-present, wall-clock secs) to
# the trajectory history ($rounds/<key>.hist) the v0.31 round governor scores. .last is read
# back at round-cap time so a capped gate can say "you are stopping WITH an open P0" (the one
# case a human may want PRO_GATE_FORCE_ROUND=1 for). Best-effort: only keys that have recorded
# rounds get sidecars (this also skips legacy "diff" markers on the harvest path). A lost
# hist line (concurrent harvest completions race the rewrite) only UNDER-counts earned
# rounds — the governor degrades toward the base grant, never past the ceiling.
pg_round_note_severity() {
  local key="$1" out="$2" spend_epoch="${3:-}" dir p0 p1 verdict res sp now win t rest stamp dur
  pg_round_key_ok "$key" || return 0
  dir="$(pg_rounds_dir)"
  [ -f "$dir/$key" ] || return 0
  [ -s "$out" ] || return 0
  # v0.28 (#52 item 3): count only OPEN findings. Confirming reviews are REQUIRED to carry
  # every prior P0/P1 forward as a "[Pn] … RESOLVED …" verification block; grep-counting every
  # severity tag reported resolved P0s as "OPEN P0" at round-cap time and prompted false
  # force-round escalations. The RESOLVED filter is case-SENSITIVE on purpose: reviews upcase
  # the verification token, while prose like "unresolved"/"Unresolved" must not exclude a line.
  # STILL-PRESENT and new-finding lines carry no RESOLVED token and stay counted.
  # (grep -c prints 0 AND exits 1 on no match: capture, then default only when empty.)
  # Anchored to the STATUS POSITION (gate #54 r3+r4 P2): exclude only when RESOLVED is the
  # first token after the delimiter that follows the [Pn] citation — headline shape
  # "[P1] path:line — RESOLVED — …". A finding whose DESCRIPTION merely contains the word
  # ("the RESOLVED state can be forged") or an identifier (RESOLVED_MODEL) stays counted.
  p0="$(grep -iE '^[[:space:]]*\[P0\]' "$out" 2>/dev/null \
    | grep -Evc '^[[:space:]]*\[[Pp]0\][[:space:]]+[^[:space:]]+[[:space:]]+(—|--|-)[[:space:]]+RESOLVED([^_[:alnum:]]|$)')"; [ -n "$p0" ] || p0=0
  p1="$(grep -iE '^[[:space:]]*\[P1\]' "$out" 2>/dev/null \
    | grep -Evc '^[[:space:]]*\[[Pp]1\][[:space:]]+[^[:space:]]+[[:space:]]+(—|--|-)[[:space:]]+RESOLVED([^_[:alnum:]]|$)')"; [ -n "$p1" ] || p1=0
  { printf '%s\t%s\t%s\n' "$(date +%s)" "$p0" "$p1" > "$dir/$key.last.tmp" \
      && mv -f "$dir/$key.last.tmp" "$dir/$key.last"; } 2>/dev/null || true
  # v0.31 trajectory history for the round governor. Verdict word from the review's own
  # terminal line; RESOLVED/STILL-PRESENT tallies use the same status-position anchor as the
  # open-count filter above (P0+P1 lines only — the governor scores blocking severities).
  verdict="$(pg_extract_verdict "$out")"; [ -n "$verdict" ] || verdict=UNKNOWN
  res="$(grep -icE '^[[:space:]]*\[P[01]\][[:space:]]+[^[:space:]]+[[:space:]]+(—|--|-)[[:space:]]+RESOLVED([^_[:alnum:]]|$)' "$out" 2>/dev/null)"; [ -n "$res" ] || res=0
  sp="$(grep -icE '^[[:space:]]*\[P[01]\][[:space:]]+[^[:space:]]+[[:space:]]+(—|--|-)[[:space:]]+STILL-PRESENT([^_[:alnum:]]|$)' "$out" 2>/dev/null)"; [ -n "$sp" ] || sp=0
  now="$(date +%s)"; win="$(pg_round_window_secs)"
  # A hist row is stamped with the epoch of the SPEND it describes, not the moment it was
  # collected (#66 gate P1/r2 P1): a review collected long after its charge — an exit-9
  # harvest, or just a slow fresh run — would otherwise stay in the scored trajectory after
  # its spend aged out of pg_round_count's window, earning rounds, faking a churn brake, or
  # landing out of order after newer rounds. Both engine paths pass the marker's launch epoch
  # (pg_marker_epoch), which is when pg_round_record charged the round. Rows are pruned on the
  # same window as the spends, so history and budget expire together.
  # The re-sort is STABLE (-s): rounds inside one second are common in tests and fast gates,
  # and an unstable sort would silently reorder the trajectory it exists to keep honest.
  stamp="$spend_epoch"; case "$stamp" in ''|*[!0-9]*) stamp="$now";; esac
  [ "$stamp" -gt "$now" ] 2>/dev/null && stamp="$now"
  # Field 7 (ledger-timing-split R2): wall-clock seconds from $stamp (the round's recorded
  # spend epoch, stamped above) to this row being written — NOT pure generation time. On the
  # harvest path that span includes however long the finished review sat uncollected before
  # someone ran --harvest (bounded only by the reservation TTL); when no spend epoch was
  # available, $stamp fell back to the marker's mint time (pg_marker_epoch), which can precede
  # the real charge by up to two PRO_GATE_LOCK_WAIT periods. Clamped at 0 as a defensive floor;
  # $stamp is already clamped to never exceed $now so this should never go negative.
  dur=$(( now - stamp )); [ "$dur" -lt 0 ] 2>/dev/null && dur=0
  {
    if [ -f "$dir/$key.hist" ]; then
      while IFS= read -r t; do
        rest="${t%%$'\t'*}"
        case "$rest" in ''|*[!0-9]*) continue;; esac
        [ $(( now - rest )) -lt "$win" ] && printf '%s\n' "$t"
      done < "$dir/$key.hist"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$stamp" "$verdict" "$p0" "$p1" "$res" "$sp" "$dur"
  } > "$dir/$key.hist.tmp" 2>/dev/null \
    && sort -s -n -k1,1 -o "$dir/$key.hist.tmp" "$dir/$key.hist.tmp" 2>/dev/null \
    && mv -f "$dir/$key.hist.tmp" "$dir/$key.hist" 2>/dev/null \
    || rm -f "$dir/$key.hist.tmp" 2>/dev/null
  return 0
}

# pg_reservation_read_spend <marker>: echo the charged-round epoch (field 7), or nothing on a
# legacy record. This is the AUTHORITATIVE spend time for trajectory stamping on the harvest
# path; pg_marker_epoch is only the last-resort fallback below.
pg_reservation_read_spend() {
  local marker="$1" f
  pg_reservation_marker_ok "$marker" || return 1
  f="$(pg_reservation_dir)/$marker"
  [ -f "$f" ] || return 1
  awk -F'\t' 'NR==1{print $7}' "$f" 2>/dev/null
}

# pg_marker_epoch <marker>: the launch epoch embedded in "pg-run-<key>-<epoch>-<pid>". This is
# a FALLBACK only (#66 gate r3 P1): the marker is minted before the per-change lock and the
# account-slot wait, so on a queued run it can precede the actual charge by up to two
# PRO_GATE_LOCK_WAIT periods. Prefer pg_round_record's PG_ROUND_SPEND_EPOCH (fresh completions)
# or pg_reservation_read_spend (harvests); use this only when neither is recorded, and never
# for a value that must line up exactly with the budget window.
pg_marker_epoch() {
  local m="${1:-}" rest e
  case "$m" in pg-run-*) rest="${m#pg-run-}";; *) return 1;; esac
  rest="${rest%-*}"          # strip -<pid>
  e="${rest##*-}"            # take <epoch>
  case "$e" in ''|*[!0-9]*) return 1;; esac
  printf '%s\n' "$e"
}

# pg_round_last_severity <key>: echo "p0 p1" from the sidecar, or fail when none/unparseable.
pg_round_last_severity() {
  local key="$1" f e p0 p1
  pg_round_key_ok "$key" || return 1
  f="$(pg_rounds_dir)/$key.last"
  [ -f "$f" ] || return 1
  { IFS=$'\t' read -r e p0 p1 < "$f"; } 2>/dev/null
  case "$p0" in ''|*[!0-9]*) return 1;; esac
  case "$p1" in ''|*[!0-9]*) p1=0;; esac
  echo "$p0 $p1"
}

# pg_round_score <key>: score the in-window trajectory and resolve the governor's tunables in
# ONE place so --status and enforcement cannot drift. Sets process globals PG_ROUND_EARNED,
# PG_ROUND_STREAK, PG_ROUND_ARROW, PG_ROUND_BASE, PG_ROUND_CEILING, PG_ROUND_GRANT,
# PG_ROUND_ELAPSED_SECS (ledger-timing-split R2: sum of field-7 wall-clock durations across the
# in-window trajectory — a legacy 6-field row has no field 7 and contributes 0, never breaking
# the scan), PG_ROUND_SCORED (ledger-timing-split R2: count of in-window .hist rows folded into
# that sum — legacy and 7-field rows alike — distinct from pg_round_count's "rounds charged",
# since a charged-but-lost round writes no .hist row at all and so is never scored here).
# Missing history scores 0/0/""/0/0. In flat mode, GRANT is the explicit legacy cap and
# the trajectory remains available for human-facing notes even though it does not affect
# enforcement. Called IN-SHELL (never via command substitution) by every caller that needs these
# globals afterward — a subshell would compute them and then drop them on exit.
pg_round_score() {
  local key="$1" f now win e verdict p0 p1 res sp dur open prev="" used
  PG_ROUND_EARNED=0; PG_ROUND_STREAK=0; PG_ROUND_ARROW=""; PG_ROUND_ELAPSED_SECS=0; PG_ROUND_SCORED=0
  PG_ROUND_BASE="${PRO_GATE_ROUNDS_BASE:-3}"; case "$PG_ROUND_BASE" in ''|*[!0-9]*) PG_ROUND_BASE=3;; esac
  PG_ROUND_CEILING="${PRO_GATE_ROUNDS_CEILING:-8}"; case "$PG_ROUND_CEILING" in ''|*[!0-9]*) PG_ROUND_CEILING=8;; esac
  # The ceiling is the IMMOVABLE backstop: an inconsistent config clamps the BASE DOWN to it,
  # never the ceiling up (#66 gate P1 — raising it let BASE=10/CEILING=8 grant 10 rounds and
  # defeat the one limit that exists to contain optimistic callers and config mistakes).
  if [ "$PG_ROUND_BASE" -gt "$PG_ROUND_CEILING" ]; then
    echo "[pro-gate rounds] PRO_GATE_ROUNDS_BASE=${PG_ROUND_BASE} exceeds PRO_GATE_ROUNDS_CEILING=${PG_ROUND_CEILING}; clamping the base to the ceiling (the ceiling never moves)" >&2
    PG_ROUND_BASE="$PG_ROUND_CEILING"
  fi
  if pg_round_key_ok "$key"; then
    f="$(pg_rounds_dir)/$key.hist"
    if [ -f "$f" ]; then
      now="$(date +%s)"; win="$(pg_round_window_secs)"
      while IFS=$'\t' read -r e verdict p0 p1 res sp dur; do
        case "$e" in ''|*[!0-9]*) continue;; esac
        [ $(( now - e )) -lt "$win" ] || continue
        case "$p0" in ''|*[!0-9]*) p0=0;; esac
        case "$p1" in ''|*[!0-9]*) p1=0;; esac
        case "$dur" in ''|*[!0-9]*) dur=0;; esac
        PG_ROUND_ELAPSED_SECS=$(( PG_ROUND_ELAPSED_SECS + dur ))
        PG_ROUND_SCORED=$(( PG_ROUND_SCORED + 1 ))
        open=$(( p0 + p1 ))
        if [ -n "$prev" ]; then
          if [ "$open" -lt "$prev" ]; then PG_ROUND_EARNED=$(( PG_ROUND_EARNED + 1 )); PG_ROUND_STREAK=0
          else PG_ROUND_STREAK=$(( PG_ROUND_STREAK + 1 )); fi
        fi
        PG_ROUND_ARROW="${PG_ROUND_ARROW:+${PG_ROUND_ARROW}→}${open}"
        prev="$open"
      done < "$f"
    fi
  fi
  if [ -n "${PRO_GATE_MAX_ROUNDS_PER_PR:-}" ]; then
    case "$PRO_GATE_MAX_ROUNDS_PER_PR" in *[!0-9]*|'') PG_ROUND_GRANT=4;; *) PG_ROUND_GRANT="$PRO_GATE_MAX_ROUNDS_PER_PR";; esac
    return 0
  fi
  PG_ROUND_GRANT=$(( PG_ROUND_BASE + PG_ROUND_EARNED ))
  [ "$PG_ROUND_GRANT" -gt "$PG_ROUND_CEILING" ] && PG_ROUND_GRANT="$PG_ROUND_CEILING"
  if [ "$PG_ROUND_STREAK" -ge 2 ]; then
    used="$(pg_round_count "$key")"
    [ "$used" -lt "$PG_ROUND_GRANT" ] && PG_ROUND_GRANT="$used"
  fi
}

# Compatibility/read-only accessors. pg_round_trajectory stays useful to shell callers and
# tests; pg_round_grant is the status helper. Both delegate to the single scorer above.
pg_round_trajectory() { pg_round_score "$1"; printf '%s\t%s\t%s\n' "$PG_ROUND_EARNED" "$PG_ROUND_STREAK" "$PG_ROUND_ARROW"; }
pg_round_grant() { pg_round_score "$1"; echo "$PG_ROUND_GRANT"; }

pg_round_policy_mode() { # advisory|enforced|lockdown|off
  local guard_set=false guard="${PRO_GATE_ROUND_GUARD:-}"
  [ -z "${PRO_GATE_ROUND_GUARD+x}" ] || guard_set=true
  if [ "$guard_set" = true ]; then
    [ "$guard" = 0 ] && { echo off; return; }
    [ "$guard" = 1 ] || { echo advisory; return; }
  elif [ -z "${PRO_GATE_MAX_ROUNDS_PER_PR+x}${PRO_GATE_ROUNDS_BASE+x}${PRO_GATE_ROUNDS_CEILING+x}" ]; then
    echo advisory; return
  fi
  pg_round_score "${1:-}"
  if { [ -n "${PRO_GATE_MAX_ROUNDS_PER_PR:-}" ] && [ "$PG_ROUND_GRANT" -eq 0 ]; } \
     || { [ -z "${PRO_GATE_MAX_ROUNDS_PER_PR:-}" ] && [ "$PG_ROUND_BASE" -eq 0 ]; }; then
    echo lockdown
  else
    echo enforced
  fi
}

pg_round_policy_source() {
  if [ -n "${PRO_GATE_ROUND_GUARD+x}" ]; then echo PRO_GATE_ROUND_GUARD
  elif [ -n "${PRO_GATE_MAX_ROUNDS_PER_PR+x}" ]; then echo PRO_GATE_MAX_ROUNDS_PER_PR
  elif [ -n "${PRO_GATE_ROUNDS_BASE+x}" ]; then echo PRO_GATE_ROUNDS_BASE
  elif [ -n "${PRO_GATE_ROUNDS_CEILING+x}" ]; then echo PRO_GATE_ROUNDS_CEILING
  else echo default
  fi
}

pg_round_guard() {  # $1 = key. 0 = proceed; 1 + a one-line reason on stdout = explicitly denied.
  local key="$1" used policy
  policy="$(pg_round_policy_mode "$key")"
  case "$policy" in advisory|off) return 0;; enforced|lockdown) ;; *) return 0;; esac
  [ "${PRO_GATE_FORCE_ROUND:-0}" = 1 ] && return 0   # deliberate one-invocation override
  pg_round_key_ok "$key" || return 0
  pg_round_score "$key"
  # Legacy flat mode: an EXPLICITLY set PRO_GATE_MAX_ROUNDS_PER_PR pins the v0.22 behavior
  # (trajectory ignored). Unset = the v0.31 governor below.
  if [ -n "${PRO_GATE_MAX_ROUNDS_PER_PR:-}" ]; then
    # cap 0 takes its natural reading: ZERO fresh runs allowed (an operator lockdown of a
    # runaway change). "Unlimited" is PRO_GATE_ROUND_GUARD=0, never a magic cap value.
    if [ "$PG_ROUND_GRANT" -eq 0 ]; then
      echo "review round budget for ${key} is 0: fresh Pro runs are disabled (PRO_GATE_MAX_ROUNDS_PER_PR=0)"
      return 1
    fi
    used="$(pg_round_count "$key")"
    if [ "$used" -ge "$PG_ROUND_GRANT" ]; then
      echo "review round budget exhausted for ${key}: ${used}/${PG_ROUND_GRANT} slot-spending runs in the last ${PRO_GATE_ROUNDS_WINDOW:-24h}${PG_ROUND_ARROW:+; open P0/P1 by round: ${PG_ROUND_ARROW}}"
      return 1
    fi
    return 0
  fi
  # Governor mode (#65): base grant, +1 earned per strictly-shrinking re-review, immovable
  # ceiling, early stop on churn. base 0 keeps the lockdown reading.
  if [ "$PG_ROUND_BASE" -eq 0 ]; then
    echo "review round budget for ${key} is 0: fresh Pro runs are disabled (PRO_GATE_ROUNDS_BASE=0)"
    return 1
  fi
  used="$(pg_round_count "$key")"
  if [ "$PG_ROUND_STREAK" -ge 2 ]; then
    echo "review rounds stopped early for ${key}: the open-P0/P1 trajectory (${PG_ROUND_ARROW:-none}) has not shrunk for ${PG_ROUND_STREAK} consecutive re-reviews — this loop is churning, not converging (${used} slot-spending runs in the last ${PRO_GATE_ROUNDS_WINDOW:-24h})"
    return 1
  fi
  if [ "$used" -ge "$PG_ROUND_GRANT" ]; then
    echo "review round budget exhausted for ${key}: ${used}/${PG_ROUND_GRANT} rounds (base ${PG_ROUND_BASE} + ${PG_ROUND_EARNED} earned by a shrinking open-P0/P1 trajectory${PG_ROUND_ARROW:+ ${PG_ROUND_ARROW}}, ceiling ${PG_ROUND_CEILING}) in the last ${PRO_GATE_ROUNDS_WINDOW:-24h}"
    return 1
  fi
  return 0
}

# pg_filter_diff <in> <out>: strip diff sections for noise paths (lockfiles, generated,
# vendored, minified, snapshots) so the Pro model spends its thinking budget on real code and
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

# pg_extract_verdict <file>: echo SHIP/FIX-FIRST/NEEDS-DISCUSSION from the terminal verdict
# line. Shared with pg_is_review and trajectory history so formatting drift cannot make a
# structurally-accepted review record UNKNOWN. The matcher tolerates leading bold/bullet/quote
# markers and whitespace, and markers/space before the colon (`**VERDICT:**`, `- VERDICT :`).
pg_extract_verdict() {
  grep -vE '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 6 \
    | grep -iE '^[[:space:]]*[*_>#-]*[[:space:]]*VERDICT[*_[:space:]]*:' \
    | grep -oiE 'SHIP|FIX-FIRST|NEEDS-DISCUSSION' | head -1 | tr '[:lower:]' '[:upper:]'
}

# pg_is_review <file>: true only when <file> looks like a COMPLETE review, not a truncated or
# garbage capture. Our prompt mandates Pn severity blocks AND one final verdict line, so require
# BOTH (v0.15, pro-gate PR#5 review P1: the old OR-grep accepted a capture truncated after its
# first finding, which then skipped salvage/retry and shipped an incomplete review). The verdict
# must sit near the end (last few non-empty lines): that rejects mid-file truncation while
# tolerating trailing footer lines from the capture (e.g. a "Sources" block).
pg_is_review() {
  local f="$1"
  [ -s "$f" ] || return 1
  [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -ge 40 ] || return 1
  grep -qiE '\[P[0-3]\]|P[0-3][*_ ]*:[[:space:]]*(none|—|-)' "$f" 2>/dev/null || return 1
  [ -n "$(pg_extract_verdict "$f")" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.28 (#48): review provenance. A structurally-complete review can still be the WRONG
# conversation's answer — a failed send once salvaged a different PR's finished review with no
# indication it was foreign (pushbot #1245), sending its caller off to fix phantom findings.
# The check is deliberately lenient to make false rejections vanishingly rare: it fires only
# when the review cites at least one file AND none of those citations overlap the change's
# path manifest, matching exact paths or component-anchored suffixes (never basenames).
# ─────────────────────────────────────────────────────────────────────────────
# pg_diff_paths <unified-diff>: the change's file manifest, one path per line.
pg_diff_paths() {
  sed -nE 's#^\+\+\+ b/(.+)#\1#p; s#^--- a/(.+)#\1#p' "$1" 2>/dev/null \
    | grep -v '^/dev/null$' | sort -u
}
# pg_review_cited_paths <review>: paths cited in [Pn] headline lines ("[P1] path:line — ...").
pg_review_cited_paths() {
  sed -nE 's/^[[:space:]]*\[P[0-3]\][[:space:]]+([^[:space:]:]+):[0-9].*/\1/p' "$1" 2>/dev/null | sort -u
}
# pg_review_matches_change <review> <paths-file>: rc 0 = accept (no manifest, fewer than two
# distinct citations, or any overlap); rc 1 = REJECT (≥2 cited paths, manifest exists, zero
# overlap → foreign). The two-citation floor keeps single-finding reviews that legitimately
# cite one caller/context file outside the diff from being misread as foreign — the observed
# foreign captures are whole other PRs' reviews, which cite several of their own files.
pg_review_matches_change() {
  local review="$1" pathsf="$2" cited c p
  [ -s "$pathsf" ] || return 0
  cited="$(pg_review_cited_paths "$review")"
  [ -n "$cited" ] || return 0
  [ "$(printf '%s\n' "$cited" | grep -c .)" -ge 2 ] 2>/dev/null || return 0
  # Overlap = exact path equality, or one path being a component-anchored SUFFIX of the other
  # (a review may cite repo-relative paths while the diff carries a prefix, or vice versa) —
  # but ONLY when the shorter side itself carries >=2 components (contains a slash). A bare
  # single-component citation matching via the suffix rule IS basename matching by another
  # door (index.ts vs lib/index.ts — gate #54 r6): bare names require exact equality.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in "$c") return 0;; esac
      case "$c" in */*) case "$p" in */"$c") return 0;; esac;; esac
      case "$p" in */*) case "$c" in */"$p") return 0;; esac;; esac
    done < "$pathsf"
  done <<PG_EOF
$cited
PG_EOF
  return 1
}

# pg_provenance_reject <marker>: invalidate a marker's memoized conversation candidate after
# its capture failed the provenance check. Without this, cdp-salvage's URL memo (written the
# moment the capture matched) makes the next harvest PREFER the same foreign conversation and
# starve the real one indefinitely (gate #54 P1). The URL goes on the per-marker blacklist —
# deliberately bypassing cdp-salvage's own "never blacklist ourUrls" guard: marker match said
# "ours", but the CONTENT proved the answer is not this change's review, which is the stronger
# signal — and the memo is removed so the next pass rescans all candidates.
pg_provenance_reject() {  # <marker> [matched-url]
  # Prefer the EXPLICIT matched URL the CDP child reported for this very capture: reading the
  # shared memo afterwards races concurrent probes/retries, which can re-learn the GENUINE
  # conversation in the interim — condemning it while the foreign source stays eligible
  # (gate #54 r5). Memo removal is CLAIM-then-verify (gate #54 r6): the memo is atomically
  # renamed aside first, its content checked against the rejected URL, and restored when it
  # names a DIFFERENT (newer, possibly genuine) conversation — a read-append-remove sequence
  # left a window where a concurrently refreshed genuine memo was deleted by a stale compare.
  local m="$1" url="${2:-}" memo claim snap
  memo="$PRO_GATE_HOME/conversation-urls/$m"
  claim="$memo.rej.$$"
  if mv "$memo" "$claim" 2>/dev/null; then
    snap="$(head -c 300 "$claim" 2>/dev/null | tr -d '\n')"
    [ -n "$url" ] || url="$snap"
    if [ "$snap" = "$url" ] || [ -z "$snap" ]; then
      rm -f "$claim" 2>/dev/null
    else
      # Restore via hard link — link(2) FAILS atomically when the memo already exists, so a
      # genuine URL the Node writer republished between our claim and this restore is never
      # overwritten (gate #54 r8: an existence check followed by mv raced exactly there).
      ln "$claim" "$memo" 2>/dev/null || true
      rm -f "$claim" 2>/dev/null
    fi
  fi
  [ -n "$url" ] || return 0
  { printf '%s\t%s\n' "$m" "$url" >> "$PRO_GATE_HOME/salvage-nonmatching.txt"; } 2>/dev/null || true
  return 0
}

# pg_trim_file <file> <max-lines> <keep-lines>: bound an append-only file by keeping only
# the newest <keep-lines> once it exceeds <max-lines>. The rewrite lands via mv (atomic), so
# readers never see a partial file — but a line APPENDED between the tail and the mv is
# LOST, so this is for SINGLE-WRITER files whose writer calls it while holding that file's
# own serialization (e.g. autoupdate.log under the updater's singleton lock). Multi-writer
# files (the salvage blacklist: bash engines + Node salvage children) are deliberately NOT
# compacted — a correct compaction there needs one cross-platform lock shared by every
# appender in both languages (#63 gate r2), machinery a ~16KB/week diagnostic doesn't earn.
pg_trim_file() {
  local f="$1" max="$2" keep="$3" n tmp
  [ -f "$f" ] || return 0
  n="$(wc -l < "$f" 2>/dev/null)" || return 0
  [ "$n" -gt "$max" ] 2>/dev/null || return 0
  tmp="$(mktemp "${f}.trim.XXXXXX" 2>/dev/null)" || return 0
  if tail -n "$keep" "$f" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"; else rm -f "$tmp"; fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.28 (#55): positive run-binding. The review prompt instructs the model to append
# "(run marker: <marker>)" to its VERDICT line; a browser-matched capture carrying that token
# was provably written for THIS prompt — content heuristics can't be fooled into accepting a
# foreign or stale conversation's answer. The engine strips the token before returning output.
# ─────────────────────────────────────────────────────────────────────────────
# pg_capture_nonce_ok <file> <marker>: rc 0 when the capture's tail carries this run's token.
pg_capture_nonce_ok() {
  local f="$1" marker="$2"
  [ -s "$f" ] || return 1
  tail -n 6 "$f" 2>/dev/null | grep -qF "(run marker: $marker)"
}
# pg_strip_nonce <file> <marker>: remove the echoed token (harmless when absent).
pg_strip_nonce() {
  local f="$1" marker="$2" tmp="$1.nonce.$$"
  [ -s "$f" ] || return 0
  # Fixed-string removal via awk (the marker is regex-safe by charset, but the parentheses
  # around it are not; index/substr avoids regex entirely).
  awk -v tok="(run marker: $marker)" '{
    i = index($0, tok)
    if (i > 0) { $0 = substr($0, 1, i - 1) substr($0, i + length(tok)) ; sub(/[ \t]+$/, "") }
    print
  }' "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.28 (#56): immutable completed-artifact store — $PRO_GATE_HOME/completed/<marker>,
# written ONCE at collection time. Recovery paths previously trusted mutable, path-addressed
# files (a reused/overwritten --out could impersonate a collection); the artifact store is
# marker-addressed, write-once, and digest-recorded in the ledger row. Deliberately NOT under
# the 24h sweeps: these are the durable record (bounded by review volume, a few KB each).
# ─────────────────────────────────────────────────────────────────────────────
pg_completed_dir() { echo "${PRO_GATE_COMPLETED_DIR:-$PRO_GATE_HOME/completed}"; }
pg_sha256() {  # <file>: echo the hex digest, or nothing when no tool is available
  if pg_have sha256sum; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif pg_have shasum; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif pg_have openssl; then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
  fi
}
# pg_signal_producer <signal> <pid>: signal Oracle's whole PROCESS GROUP, falling back to the pid
# plus its direct children when it does not lead one. Oracle sits under `timeout` and itself drives
# a browser client, so signalling the bare pid can leave grandchildren running after the engine has
# released the account slot and its locks — an orphan that keeps using the browser we just freed.
pg_signal_producer() {
  local sig="$1" pid="$2"
  [ -n "$pid" ] || return 0
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -"$sig" -- "-$pid" 2>/dev/null && return 0
  pkill -"$sig" -P "$pid" 2>/dev/null
  kill -"$sig" "$pid" 2>/dev/null
  return 0
}

# pg_publish_log_proof <transcript> <digest-proof>: publish the digest that makes <transcript>
# trustworthy evidence. Call this ONLY once no writer remains (the tee drained to EOF, or the
# pipeline was killed AND reaped) — the proof asserts the transcript is final, so publishing it
# over a live stream would let a half-written log pass as complete. Atomic: a partial temp file
# is removed rather than left where pg_verified_log_lacks would read it.
pg_publish_log_proof() {
  local transcript="$1" proof="$2" sha
  [ -f "$transcript" ] && [ ! -L "$transcript" ] || return 1
  sha="$(pg_sha256 "$transcript")"
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha" > "$proof.tmp" 2>/dev/null \
    && mv -f "$proof.tmp" "$proof" 2>/dev/null \
    || { rm -f "$proof.tmp" 2>/dev/null; return 1; }
}
# pg_verified_log_lacks <transcript> <digest-proof> <extended-regex>: true only when the
# immutable transcript still matches the digest published after its tee drained successfully
# AND grep completed with the exact no-match status. Missing/truncated/unreadable logs fail closed.
pg_verified_log_lacks() {
  local transcript="$1" proof="$2" pattern="$3" expected actual grep_rc
  [ -f "$transcript" ] && [ ! -L "$transcript" ] || return 1
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 1
  IFS= read -r expected < "$proof" || return 1
  case "$expected" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  [ "${#expected}" -eq 64 ] || return 1
  actual="$(pg_sha256 "$transcript")"
  [ -n "$actual" ] && [ "$actual" = "$expected" ] || return 1
  grep -qE "$pattern" "$transcript" 2>/dev/null
  grep_rc=$?
  [ "$grep_rc" -eq 1 ]
}
pg_completed_write() {  # <marker> <file>: write-once; an existing artifact is never replaced
  local marker="$1" f="$2" dir rc
  pg_reservation_marker_ok "$marker" || return 1
  [ -s "$f" ] || return 1
  dir="$(pg_completed_dir)"
  mkdir -p "$dir" 2>/dev/null || return 1
  # Atomic NO-CLOBBER install (gate #54 r14): link(2) fails when the artifact exists, so
  # concurrent writers cannot replace each other. On EEXIST the existing artifact must be
  # byte-identical to what we hold — write-once means one review per marker, and accepting
  # different bytes would let callers drop recovery state while RESULT_FILE names the wrong
  # review. Fail closed otherwise.
  if cp "$f" "$dir/$marker.tmp.$$" 2>/dev/null && ln "$dir/$marker.tmp.$$" "$dir/$marker" 2>/dev/null; then
    rc=0
  elif [ -f "$dir/$marker" ] && cmp -s "$f" "$dir/$marker" 2>/dev/null; then
    rc=0
  else
    rc=1
  fi
  # Never leave a pg-run-*-globbable temp behind (r11 P2).
  rm -f "$dir/$marker.tmp.$$" 2>/dev/null
  [ "$rc" = 0 ] || return 1
  # An installed artifact supersedes any pending-recovery copy for the marker (r11 P2).
  rm -f "$PRO_GATE_HOME/pending/$marker" 2>/dev/null
  return 0
}
pg_completed_lookup() {  # <marker> <out>: place the artifact at <out>; rc 0 on success
  local marker="$1" out="$2" src rc
  pg_reservation_marker_ok "$marker" || return 1
  src="$(pg_completed_dir)/$marker"
  { [ -s "$src" ] && [ ! -L "$src" ] && pg_is_review "$src"; } || return 1
  [ "$src" = "$out" ] && return 0
  # Copy-then-rename only — never pre-delete the destination (gate #54 r4 P2): a copy/rename
  # failure must leave any existing valid output intact, not destroy it and then fail.
  cp "$src" "$out.already.$$" 2>/dev/null && mv -f "$out.already.$$" "$out" 2>/dev/null
  rc=$?
  rm -f "$out.already.$$" 2>/dev/null
  return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# review-decision/v1: pure continuation policy and immutable marker bindings.
#
# The reducer below deliberately receives one already-normalized JSON value. It performs no
# filesystem reads, writes, locking, allocation, browser work, round work, or publication. The
# fixture digests are compiled into the runtime so resolving an answer never makes metadata files
# an ambient policy input. Fixture validation is a packaging/test concern exposed by the digest
# accessors; callers supply their claimed compatibility identity in the normalized snapshot.
# ─────────────────────────────────────────────────────────────────────────────
PG_REVIEW_DECISION_CONTRACT_ID='review-decision/v1'
PG_REVIEW_DECISION_CONTRACT_VERSION=1
PG_REVIEW_DECISION_CONTRACT_DIGEST='7f5ece9bfa5aa19f858431da23302a9bc02a4a8f5770830d529f22484e5982ee'
PG_REVIEW_DECISION_CORPUS_DIGEST='2a1e347e4c15766ab9c530074ae75aead7397349f5e13328c40183ced8b70b69'

pg_review_decision_contract_id() { printf '%s\n' "$PG_REVIEW_DECISION_CONTRACT_ID"; }
pg_review_decision_contract_version() { printf '%s\n' "$PG_REVIEW_DECISION_CONTRACT_VERSION"; }
pg_review_decision_contract_digest() { printf '%s\n' "$PG_REVIEW_DECISION_CONTRACT_DIGEST"; }
pg_review_decision_corpus_digest() { printf '%s\n' "$PG_REVIEW_DECISION_CORPUS_DIGEST"; }

# Compatibility metadata only: reducers continue to use the compiled constants above.
pg_review_decision_identity_json() {
  jq -cnS --arg contract_id "$PG_REVIEW_DECISION_CONTRACT_ID" \
    --argjson contract_version "$PG_REVIEW_DECISION_CONTRACT_VERSION" \
    --arg contract_digest "$PG_REVIEW_DECISION_CONTRACT_DIGEST" \
    --arg corpus_digest "$PG_REVIEW_DECISION_CORPUS_DIGEST" \
    '{contract_digest:$contract_digest,contract_id:$contract_id,contract_version:$contract_version,corpus_digest:$corpus_digest}'
}

pg_review_decision_identity_file_valid() { # path; exact compact canonical metadata from these constants
  local path="$1" canonical expected
  [ -f "$path" ] && [ ! -L "$path" ] && pg_have jq || return 1
  canonical="$(LC_ALL=C jq -ceS '
    if type == "object" and
       keys == ["contract_digest","contract_id","contract_version","corpus_digest"] and
       (.contract_id | type == "string" and length > 0) and
       (.contract_version | type == "number" and floor == . and . > 0) and
       (.contract_digest | type == "string" and test("^[0-9a-f]{64}$")) and
       (.corpus_digest | type == "string" and test("^[0-9a-f]{64}$"))
    then . else error("invalid review-decision identity") end
  ' "$path" 2>/dev/null)" || return 1
  expected="$(pg_review_decision_identity_json)" || return 1
  [ "$canonical" = "$expected" ] && printf '%s' "$expected" | cmp -s - "$path"
}

# Canonical JSON is intentionally a small, shared primitive: jq -S recursively sorts object
# keys, -c removes insignificant whitespace, and command substitution removes jq's one LF. Arrays
# retain their source order. The C locale avoids locale-dependent diagnostics/character classes.
pg_review_json_canonical() { # [json]; with no argument, read stdin
  local json canonical
  if [ "$#" -gt 0 ]; then json="$1"; else json="$(cat)"; fi
  canonical="$(LC_ALL=C printf '%s' "$json" | jq -ceS . 2>/dev/null)" || return 1
  printf '%s' "$canonical"
}

pg_review_sha256_text() { # text: digest bytes exactly, without adding a newline
  local text="${1-}"
  if pg_have sha256sum; then LC_ALL=C printf '%s' "$text" | sha256sum | awk '{print $1}'
  elif pg_have shasum; then LC_ALL=C printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
  elif pg_have openssl; then LC_ALL=C printf '%s' "$text" | openssl dgst -sha256 | awk '{print $NF}'
  else return 1
  fi
}

# A choice is fresh only for the prompt context that named it. The selected value and its proof
# are excluded from that context; otherwise the proof would be self-referential.
pg_review_decision_choice_snapshot() { # normalized facts JSON -> sha256
  local canonical
  canonical="$(printf '%s' "${1-}" | jq -ceS '.named_choice.selected_id=null | .named_choice.snapshot_digest=""' 2>/dev/null)" || return 1
  pg_review_sha256_text "$canonical"
}

# Parse the deliberately tiny NEEDS-DISCUSSION choice grammar from a canonical review artifact.
# This is a data extractor, not a prose relay: it emits only schema-bounded JSON fields after the
# complete artifact and terminal verdict are independently validated.
pg_review_decision_named_choices() { # review artifact -> canonical outcomes JSON
  local f="$1" line id label consequence choices='[]' count=0 verdict_seen=false choices_started=false
  [ -f "$f" ] && [ ! -L "$f" ] && pg_is_review "$f" || return 1
  [ "$(pg_extract_verdict "$f")" = NEEDS-DISCUSSION ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*[*_\>#-]*[[:space:]]*VERDICT[*_[:space:]]*: ]]; then
      verdict_seen=true
      continue
    fi
    if [[ "$line" != CHOICE:* ]]; then
      # Choice lines form one terminal block; prose after that block is not a machine grammar.
      [ "$choices_started" = false ] || return 1
      continue
    fi
    [ "$verdict_seen" = false ] || return 1
    choices_started=true
    [[ "$line" =~ ^CHOICE:[[:space:]]+([A-Za-z0-9._:/+-]+)[[:space:]]\|[[:space:]]([^\|[:cntrl:]]{1,120})[[:space:]]\|[[:space:]]([^\|[:cntrl:]]{1,240})[[:space:]]*$ ]] || return 1
    id="${BASH_REMATCH[1]}"; label="${BASH_REMATCH[2]}"; consequence="${BASH_REMATCH[3]}"
    [ "${#id}" -le 256 ] || return 1
    # The grammar's separators consume one optional display space; trim only separator-adjacent
    # whitespace so stored values never contain formatting padding.
    label="${label#"${label%%[![:space:]]*}"}"; label="${label%"${label##*[![:space:]]}"}"
    consequence="${consequence#"${consequence%%[![:space:]]*}"}"; consequence="${consequence%"${consequence##*[![:space:]]}"}"
    [ -n "$label" ] && [ -n "$consequence" ] || return 1
    [ "${#label}" -le 120 ] && [ "${#consequence}" -le 240 ] || return 1
    jq -e --arg id "$id" --arg label "$label" --arg consequence "$consequence" \
      'all(.[]; .id != $id)' <<<"$choices" >/dev/null 2>&1 || return 1
    choices="$(jq -cS --arg id "$id" --arg label "$label" --arg consequence "$consequence" \
      '. + [{consequence:$consequence,id:$id,label:$label}]' <<<"$choices")" || return 1
    count=$((count + 1))
    [ "$count" -le 8 ] || return 1
  done < "$f"
  [ "$verdict_seen" = true ] && [ "$count" -ge 2 ] || return 1
  printf '%s' "$choices"
}

pg_review_decision_emit() { # action reason facts snapshot-digest applicable-ref
  local action="$1" reason="$2" facts="$3" snapshot="$4" ref="${5:-}" class out
  # The ask payload supplies the exact selection context, not the surrounding decision envelope.
  [ "$action" != ask-named-product-choice ] || snapshot="$(pg_review_decision_choice_snapshot "$facts")" || return 1
  case "$action" in
    collect-existing-result|recover-existing-review|run-granted-review) class='runtime-guarded-effect' ;;
    fix-review-findings|prepare-matching-review-evidence) class='agent-task' ;;
    stop-without-new-review|allow-existing-merge-workflow) class='report-only' ;;
    ask-named-product-choice) class='named-product-choice' ;;
    *) return 1 ;;
  esac
  out="$(jq -cnS \
    --arg action "$action" --arg reason "$reason" --arg class "$class" --arg snapshot "$snapshot" \
    --arg ref "$ref" --arg cid "$PG_REVIEW_DECISION_CONTRACT_ID" \
    --argjson cv "$PG_REVIEW_DECISION_CONTRACT_VERSION" \
    --arg cd "$PG_REVIEW_DECISION_CONTRACT_DIGEST" --arg xd "$PG_REVIEW_DECISION_CORPUS_DIGEST" \
    --argjson facts "$facts" '
      {action:$action,
       contract:{contract_digest:$cd,contract_id:$cid,contract_version:$cv,corpus_digest:$xd},
       effect_request:{action:$action,applicable_ref:(if $ref=="" then null else $ref end),
         contract_digest:$cd,effect:$action,execution_class:$class,snapshot_digest:$snapshot,
         target:($facts.target // null)},
       facts:$facts,observation:($facts.observation // {kind:"rejected"}),reason:$reason}' 2>/dev/null)" || return 1
  printf '%s' "$out"
}

pg_review_decision_reject() { # reason snapshot; never reflect rejected untrusted data
  pg_review_decision_emit stop-without-new-review "$1" '{}' "$2" ''
}

pg_review_decision_reduce() { # [normalized-facts-json]; with no argument, read stdin
  local supplied canonical snapshot unsafe valid reason selected selected_ref selected_count
  local action prior prior_applicable verdict choice_snapshot
  pg_have jq || return 1
  if [ "$#" -gt 0 ]; then supplied="$1"; else supplied="$(cat)"; fi
  canonical="$(pg_review_json_canonical "$supplied")" || return 1
  snapshot="$(pg_review_sha256_text "$canonical")" || return 1

  # Raw/caller control fields, credentials, control characters, and unbounded structures are not
  # normalized facts. Reject them before any response can reflect their values.
  unsafe="$(printf '%s' "$canonical" | jq -r '
    if (type != "object") then "yes"
    elif ([.. | objects | keys[] |
      test("^(raw|.*_text|prose|prompt|caller.*|status|next_action|approval.*|.*ledger.*|.*password.*|.*secret.*|.*credential.*|authorization|api[_-]?key|api[_-]?token|access[_-]?token|private[_-]?key)$";"i")] | any) then "yes"
    elif ([.. | strings | (length > 1024 or test("[\u0000-\u001f\u007f]"))] | any) then "yes"
    elif ([.. | arrays | length > 32] | any) then "yes"
    else "no" end' 2>/dev/null)" || unsafe=yes
  if [ "$unsafe" != no ]; then
    pg_review_decision_reject unsafe-normalized-input "$snapshot"; return
  fi

  # Compatibility and transport are checked before the domain shape so skew and collision have
  # stable directional reasons, even when a newer producer also carries unfamiliar fields.
  if ! jq -e --arg id "$PG_REVIEW_DECISION_CONTRACT_ID" --argjson v "$PG_REVIEW_DECISION_CONTRACT_VERSION" \
      --arg cd "$PG_REVIEW_DECISION_CONTRACT_DIGEST" --arg xd "$PG_REVIEW_DECISION_CORPUS_DIGEST" \
      '.contract.contract_id==$id and .contract.contract_version==$v and .contract.contract_digest==$cd and .contract.corpus_digest==$xd' \
      <<<"$canonical" >/dev/null 2>&1; then
    pg_review_decision_reject unknown-contract "$snapshot"; return
  fi
  if [ "$(jq -r '.transport // ""' <<<"$canonical")" != "$PG_REVIEW_DECISION_CONTRACT_ID" ]; then
    pg_review_decision_reject transport-collision "$snapshot"; return
  fi

  # Closed normalized-facts grammar. No repository/review prose is admitted, marker references
  # use the existing filename-safe grammar, and each nested object has an exact key set.
  valid="$(printf '%s' "$canonical" | jq -r '
    def keys_are($x): keys == ($x|sort);
    def marker: type=="string" and (length==0 or test("^pg-run-[A-Za-z0-9.-]+$"));
    def ident: type=="string" and length<=256 and test("^[A-Za-z0-9._:/+-]*$");
    def hex: type=="string" and test("^[0-9a-f]{64}$");
    def oid: type=="string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
    def result:
      keys_are(["applicable","artifact_digest","binding_valid","canonical_identity","charged_spend_epoch","collected","legacy","marker","provenance_valid","verdict"])
      and (.applicable|type=="boolean") and (.artifact_digest|hex) and (.binding_valid|type=="boolean")
      and (.canonical_identity|ident and length>0) and (.charged_spend_epoch|type=="number" and floor==.)
      and (.collected|type=="boolean") and (.legacy|type=="boolean") and (.marker|marker and length>0)
      and (.provenance_valid|type=="boolean") and (.verdict|IN("SHIP","FIX-FIRST","NEEDS-DISCUSSION","NONE"));
    (keys_are(["active_index","completed_results","contract","evidence","governor","input","named_choice","observation","prior_review","reservation","target","transport"]))
    and (.contract|keys_are(["contract_digest","contract_id","contract_version","corpus_digest"]))
    and (.active_index|keys_are(["binding_valid","charged_spend_epoch","marker","state"]))
    and (.active_index.binding_valid|type=="boolean") and (.active_index.charged_spend_epoch|type=="number" and floor==.)
    and (.active_index.marker|marker)
    and (.active_index.state|IN("none","live","pre-charge","round-recorded","charged","run-meta-written","input-bound","submitted","unknown-fate"))
    and (.completed_results|type=="array" and all(.[];result))
    and (.evidence|keys_are(["identity","safe_to_prepare","state"])) and (.evidence.identity|ident)
    and (.evidence.safe_to_prepare|type=="boolean") and (.evidence.state|IN("matching","missing","unsafe","invalid","undefined"))
    and (.governor|keys_are(["granted"])) and (.governor.granted|type=="boolean")
    and (.input|keys_are(["binding_valid","identity","proven"])) and (.input.binding_valid|type=="boolean")
    and (.input.identity|ident) and (.input.proven|type=="boolean")
    and (.named_choice|keys_are(["outcomes","selected_id","snapshot_digest"]))
    and (.named_choice.outcomes|type=="array" and length<=8 and all(.[];
      keys_are(["consequence","id","label"]) and (.id|ident and length>0) and
      (.label|type=="string" and length>0 and length<=120) and (.consequence|type=="string" and length>0 and length<=240)))
    and (([.named_choice.outcomes[].id]|length)==([.named_choice.outcomes[].id]|unique|length))
    and (.named_choice.selected_id==null or (.named_choice.selected_id|ident and length>0))
    and (.named_choice.snapshot_digest|type=="string" and (length==0 or .=="CURRENT" or hex))
    and (.observation|keys_are(["kind"])) and (.observation.kind|IN("idle","queued","running","waiting","observed"))
    and (.prior_review|keys_are(["applicable","binding_valid","code_identity","evidence_identity","legacy","marker","provenance_valid","verdict"]))
    and (.prior_review.applicable|type=="boolean") and (.prior_review.binding_valid|type=="boolean")
    and (.prior_review.code_identity|ident) and (.prior_review.evidence_identity|ident) and (.prior_review.legacy|type=="boolean")
    and (.prior_review.marker|marker) and (.prior_review.provenance_valid|type=="boolean")
    and (.prior_review.verdict|IN("SHIP","FIX-FIRST","NEEDS-DISCUSSION","NONE"))
    and (.reservation|keys_are(["binding_valid","legacy","marker","state"]))
    and (.reservation.binding_valid|type=="boolean") and (.reservation.legacy|type=="boolean")
    and (.reservation.marker|marker) and (.reservation.state|IN("none","live","recoverable","unknown-fate"))
    and (.target|keys_are(["head_oid","host","owner","pr","repo"])) and (.target.head_oid|oid)
    and (.target.host|test("^[A-Za-z0-9.-]+$") and length<=253)
    and (.target.owner|test("^[A-Za-z0-9._-]+$") and length<=100)
    and (.target.repo|test("^[A-Za-z0-9._-]+$") and length<=100)
    and (.target.pr|type=="number" and floor==. and .>0)
    and (.transport=="review-decision/v1")' 2>/dev/null)" || valid=false
  if [ "$valid" != true ]; then
    pg_review_decision_reject undefined-state "$snapshot"; return
  fi

  # Existing completed work wins. Selection is newest charged epoch, then canonical identity;
  # duplicate rows still tied on both fields are unresolved and stop closed.
  selected="$(jq -cS '[.completed_results[] | select(.applicable or .legacy)] | sort_by(.charged_spend_epoch,.canonical_identity) | last // empty' <<<"$canonical")"
  if [ -n "$selected" ]; then
    selected_count="$(jq -r --argjson s "$selected" '[.completed_results[] | select(.charged_spend_epoch==$s.charged_spend_epoch and .canonical_identity==$s.canonical_identity)] | length' <<<"$canonical")"
    if [ "$selected_count" -gt 1 ]; then
      pg_review_decision_emit stop-without-new-review completed-result-tie "$canonical" "$snapshot"; return
    fi
    selected_ref="$(jq -r .canonical_identity <<<"$selected")"
    if [ "$(jq -r .collected <<<"$selected")" = false ]; then
      pg_review_decision_emit collect-existing-result completed-result-awaits-collection "$canonical" "$snapshot" "$selected_ref"; return
    fi
  fi

  # Active and reserved facts are authority even when a crash happened between charge protocol
  # steps. None of these states can become fresh eligibility by absence of a later sidecar.
  if [ "$(jq -r .active_index.state <<<"$canonical")" != none ]; then
    pg_review_decision_emit recover-existing-review active-work-requires-recovery "$canonical" "$snapshot" \
      "$(jq -r .active_index.marker <<<"$canonical")"; return
  fi
  if [ "$(jq -r .reservation.state <<<"$canonical")" != none ]; then
    pg_review_decision_emit recover-existing-review active-work-requires-recovery "$canonical" "$snapshot" \
      "$(jq -r .reservation.marker <<<"$canonical")"; return
  fi

  # A missing but safely preparable evidence relation must reach the preparer before the absent
  # input binding can stop it. Unsafe/invalid/undefined evidence is still terminal, while a
  # matching relation remains unable to authorize a run until its input binding is proven.
  case "$(jq -r .evidence.state <<<"$canonical")" in
    missing)
      if [ "$(jq -r .evidence.safe_to_prepare <<<"$canonical")" = true ]; then
        pg_review_decision_emit prepare-matching-review-evidence matching-evidence-requires-preparation "$canonical" "$snapshot"
      else
        pg_review_decision_emit stop-without-new-review evidence-preparation-unsafe "$canonical" "$snapshot"
      fi
      return ;;
    unsafe|invalid)
      pg_review_decision_emit stop-without-new-review no-safe-action "$canonical" "$snapshot"; return ;;
    undefined)
      pg_review_decision_emit stop-without-new-review undefined-state "$canonical" "$snapshot"; return ;;
  esac
  if [ "$(jq -r '.input.proven' <<<"$canonical")" != true ]; then
    pg_review_decision_emit stop-without-new-review unproven-input "$canonical" "$snapshot"; return
  fi
  if [ "$(jq -r '.input.binding_valid' <<<"$canonical")" != true ]; then
    pg_review_decision_emit stop-without-new-review invalid-binding "$canonical" "$snapshot"; return
  fi

  # A collected exact-evidence result is terminal. A same-code prior with different evidence is
  # progress context only: it participates in the identical-evidence check below, but its verdict
  # cannot route this continuation.
  if [ -n "$selected" ]; then
    prior="$selected"; prior_applicable=true
  else
    prior="$(jq -cS .prior_review <<<"$canonical")"
    prior_applicable="$(jq -r .applicable <<<"$prior")"
  fi
  if [ "$prior_applicable" = true ]; then
    if [ "$(jq -r '.legacy // false' <<<"$prior")" = true ]; then
      pg_review_decision_emit stop-without-new-review legacy-not-authoritative "$canonical" "$snapshot"; return
    fi
    if [ "$(jq -r '.marker // ""' <<<"$prior")" != "" ] && \
       { [ "$(jq -r '.binding_valid // false' <<<"$prior")" != true ] || [ "$(jq -r '.provenance_valid // false' <<<"$prior")" != true ]; }; then
      if [ "$(jq -r '.binding_valid // false' <<<"$prior")" != true ]; then reason=invalid-binding; else reason=invalid-result-provenance; fi
      pg_review_decision_emit stop-without-new-review "$reason" "$canonical" "$snapshot"; return
    fi

    verdict="$(jq -r '.verdict // "NONE"' <<<"$prior")"
    selected_ref="$(jq -r '.canonical_identity // .marker // ""' <<<"$prior")"
    case "$verdict" in
      FIX-FIRST)
        pg_review_decision_emit fix-review-findings review-findings-require-fix "$canonical" "$snapshot" "$selected_ref"; return ;;
      SHIP)
        pg_review_decision_emit allow-existing-merge-workflow current-ship-is-merge-eligible "$canonical" "$snapshot" "$selected_ref"; return ;;
      NEEDS-DISCUSSION)
        if [ "$(jq -r '.named_choice.outcomes|length' <<<"$canonical")" -lt 2 ]; then
          pg_review_decision_emit stop-without-new-review invalid-named-choice "$canonical" "$snapshot" "$selected_ref"; return
        fi
        if [ "$(jq -r '.named_choice.selected_id // ""' <<<"$canonical")" = "" ]; then
          pg_review_decision_emit ask-named-product-choice named-product-choice-required "$canonical" "$snapshot" "$selected_ref"; return
        fi
        if ! jq -e '.named_choice as $c | any($c.outcomes[]; .id==$c.selected_id)' <<<"$canonical" >/dev/null 2>&1; then
          pg_review_decision_emit stop-without-new-review invalid-named-choice "$canonical" "$snapshot" "$selected_ref"; return
        fi
        choice_snapshot="$(pg_review_decision_choice_snapshot "$canonical")" || return 1
        if [ "$(jq -r .named_choice.snapshot_digest <<<"$canonical")" != "$choice_snapshot" ]; then
          pg_review_decision_emit stop-without-new-review stale-named-choice "$canonical" "$snapshot" "$selected_ref"; return
        fi
        pg_review_decision_emit fix-review-findings named-product-choice-selected "$canonical" "$snapshot" "$selected_ref"; return ;;
    esac
  fi

  if jq -e '.prior_review.binding_valid and .prior_review.provenance_valid and
      .prior_review.code_identity==.input.identity and .prior_review.evidence_identity==.evidence.identity' \
      <<<"$canonical" >/dev/null 2>&1; then
    pg_review_decision_emit stop-without-new-review identical-code-and-evidence "$canonical" "$snapshot"; return
  fi
  if [ "$(jq -r .governor.granted <<<"$canonical")" != true ]; then
    pg_review_decision_emit stop-without-new-review round-governor-denied "$canonical" "$snapshot"; return
  fi
  if [ "$(jq -r .evidence.state <<<"$canonical")" = matching ]; then
    pg_review_decision_emit run-granted-review round-granted-for-changed-input "$canonical" "$snapshot"; return
  fi
  pg_review_decision_emit stop-without-new-review no-safe-action "$canonical" "$snapshot"
}

# Exactly two marker-addressed immutable sibling record stores. Existing run-meta, reservation,
# active-index, completed-artifact, and round layouts are intentionally untouched.
pg_review_input_binding_dir() { printf '%s\n' "${PRO_GATE_REVIEW_INPUT_BINDING_DIR:-$PRO_GATE_HOME/review-input-bindings}"; }
pg_review_result_binding_dir() { printf '%s\n' "${PRO_GATE_REVIEW_RESULT_BINDING_DIR:-$PRO_GATE_HOME/review-result-bindings}"; }

pg_review_input_binding_validate() { # canonical record JSON [expected marker]
  local json="${1-}" marker="${2:-}" canonical
  canonical="$(pg_review_json_canonical "$json")" || return 1
  jq -e --arg marker "$marker" --arg cid "$PG_REVIEW_DECISION_CONTRACT_ID" \
    --argjson cv "$PG_REVIEW_DECISION_CONTRACT_VERSION" --arg cd "$PG_REVIEW_DECISION_CONTRACT_DIGEST" '
    def keys_are($x): keys == ($x|sort);
    def hex: type=="string" and test("^[0-9a-f]{64}$");
    def oid: type=="string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
    ([.. | strings | (length>1024 or test("[\u0000-\u001f\u007f]"))] | any | not)
    and keys_are(["charged_spend_epoch","contract_digest","contract_id","contract_version","evidence","marker","record_type","record_version","repository","target"])
    and .record_type=="review-input-binding/v1" and .record_version==1
    and .contract_id==$cid and .contract_version==$cv and .contract_digest==$cd
    and (.marker|test("^pg-run-[A-Za-z0-9.-]+$")) and ($marker=="" or .marker==$marker)
    and (.charged_spend_epoch|type=="number" and floor==. and .>0)
    and (.repository|keys_are(["host","owner","repo"]))
    and (.repository.host|test("^[A-Za-z0-9.-]+$")) and (.repository.owner|test("^[A-Za-z0-9._-]+$")) and (.repository.repo|test("^[A-Za-z0-9._-]+$"))
    and (.target|keys_are(["head_oid","kind","pr"])) and .target.kind=="pull-request"
    and (.target.pr|type=="number" and floor==. and .>0) and (.target.head_oid|oid)
    and (.evidence|keys_are(["identity","mode","proof"])) and (.evidence.identity|type=="string" and test("^[A-Za-z0-9._:/+-]+$") and length<=256)
    and (.evidence.mode|IN("full-pr","scoped-delta","connector"))
    and (if .evidence.mode=="full-pr" then
      (.evidence.proof|keys_are(["base_oid","endpoint_digest","head_oid","raw_patch_digest"]))
      and (.evidence.proof.base_oid|oid) and (.evidence.proof.head_oid|oid) and .evidence.proof.head_oid==.target.head_oid
      and (.evidence.proof.endpoint_digest|hex) and (.evidence.proof.raw_patch_digest|hex)
    elif .evidence.mode=="scoped-delta" then
      (.evidence.proof|keys_are(["base_oid","end_oid","filtering_manifest_digest","lineage_identity","raw_digest","reviewed_payload_digest","scope_algorithm"]))
      and (.evidence.proof.base_oid|oid) and (.evidence.proof.end_oid|oid) and .evidence.proof.end_oid==.target.head_oid
      and (.evidence.proof.filtering_manifest_digest|hex) and (.evidence.proof.raw_digest|hex) and (.evidence.proof.reviewed_payload_digest|hex)
      and (.evidence.proof.lineage_identity|type=="string" and length>0 and length<=256)
      and (.evidence.proof.scope_algorithm|type=="string" and length>0 and length<=64)
    else
      (.evidence.proof|keys_are(["commit_target","endpoint_digest","raw_diff_digest","repository_target"]))
      and (.evidence.proof.commit_target|oid) and .evidence.proof.commit_target==.target.head_oid
      and (.evidence.proof.repository_target|type=="string" and length>0 and length<=256)
      and ((.evidence.proof.endpoint_digest==null) or (.evidence.proof.endpoint_digest|hex))
      and ((.evidence.proof.raw_diff_digest==null) or (.evidence.proof.raw_diff_digest|hex))
    end)' <<<"$canonical" >/dev/null 2>&1
}

pg_review_result_binding_validate() { # canonical record JSON [expected marker]
  local json="${1-}" marker="${2:-}" canonical
  canonical="$(pg_review_json_canonical "$json")" || return 1
  jq -e --arg marker "$marker" --arg cid "$PG_REVIEW_DECISION_CONTRACT_ID" \
    --argjson cv "$PG_REVIEW_DECISION_CONTRACT_VERSION" --arg cd "$PG_REVIEW_DECISION_CONTRACT_DIGEST" '
    def keys_are($x): keys == ($x|sort);
    def hex: type=="string" and test("^[0-9a-f]{64}$");
    def oid: type=="string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
    ([.. | strings | (length>1024 or test("[\u0000-\u001f\u007f]"))] | any | not)
    and keys_are(["accepted_epoch","artifact","contract_digest","contract_id","contract_version","input_binding_digest","input_binding_identity","marker","named_choice","provenance","record_type","record_version","ship_proof","verdict"])
    and .record_type=="review-result-binding/v1" and .record_version==1
    and .contract_id==$cid and .contract_version==$cv and .contract_digest==$cd
    and (.marker|test("^pg-run-[A-Za-z0-9.-]+$")) and ($marker=="" or .marker==$marker)
    and (.accepted_epoch|type=="number" and floor==. and .>0)
    and (.input_binding_digest|hex) and .input_binding_identity==.marker
    and (.artifact|keys_are(["digest","path"])) and (.artifact.digest|hex)
    and .artifact.path==( "completed/" + .marker )
    and (.provenance|keys_are(["outcome","validated_epoch"])) and .provenance.outcome=="accepted"
    and (.provenance.validated_epoch|type=="number" and floor==. and .>0)
    and (.verdict|IN("SHIP","FIX-FIRST","NEEDS-DISCUSSION"))
    and (.named_choice==null or ((.named_choice|keys_are(["consequence","id","label"])) and (.named_choice.id|type=="string" and length>0 and length<=256) and (.named_choice.label|type=="string" and length>0 and length<=120) and (.named_choice.consequence|type=="string" and length>0 and length<=240)))
    and (if .verdict=="SHIP" then
      (.ship_proof|keys_are(["base_oid","diff_digest","head_oid"])) and (.ship_proof.base_oid|oid) and (.ship_proof.head_oid|oid) and (.ship_proof.diff_digest|hex)
    else .ship_proof==null end)' <<<"$canonical" >/dev/null 2>&1
}

pg_review_binding_write_immutable() { # type marker json
  local type="$1" marker="$2" json="$3" canonical dir f tmp rc
  pg_reservation_marker_ok "$marker" || return 1
  canonical="$(pg_review_json_canonical "$json")" || return 1
  case "$type" in
    input) pg_review_input_binding_validate "$canonical" "$marker" || return 1; dir="$(pg_review_input_binding_dir)" ;;
    result) pg_review_result_binding_validate "$canonical" "$marker" || return 1; dir="$(pg_review_result_binding_dir)" ;;
    *) return 1 ;;
  esac
  mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/$marker"; tmp="$dir/.$marker.tmp.$$"
  if LC_ALL=C printf '%s' "$canonical" > "$tmp" 2>/dev/null && ln "$tmp" "$f" 2>/dev/null; then
    rc=0
  elif [ -f "$f" ] && [ ! -L "$f" ] && cmp -s "$tmp" "$f" 2>/dev/null; then
    rc=0
  else
    rc=1
  fi
  rm -f "$tmp" 2>/dev/null
  return "$rc"
}

pg_review_input_binding_write() { pg_review_binding_write_immutable input "$1" "$2"; }
pg_review_result_binding_write() { pg_review_binding_write_immutable result "$1" "$2"; }

pg_review_binding_read() { # type marker
  local type="$1" marker="$2" dir f json canonical
  pg_reservation_marker_ok "$marker" || return 1
  case "$type" in input) dir="$(pg_review_input_binding_dir)";; result) dir="$(pg_review_result_binding_dir)";; *) return 1;; esac
  f="$dir/$marker"; [ -f "$f" ] && [ ! -L "$f" ] || return 1
  json="$(cat "$f" 2>/dev/null)" || return 1
  canonical="$(pg_review_json_canonical "$json")" || return 1
  [ "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" = "${#canonical}" ] || return 1
  case "$type" in input) pg_review_input_binding_validate "$canonical" "$marker";; result) pg_review_result_binding_validate "$canonical" "$marker";; esac || return 1
  printf '%s' "$canonical"
}

pg_review_input_binding_read() { pg_review_binding_read input "$1"; }
pg_review_result_binding_read() { pg_review_binding_read result "$1"; }
pg_review_input_binding_digest() { local r; r="$(pg_review_input_binding_read "$1")" || return 1; pg_review_sha256_text "$r"; }
pg_review_result_binding_digest() { local r; r="$(pg_review_result_binding_read "$1")" || return 1; pg_review_sha256_text "$r"; }

# pg_ledger_lookup_clean <marker>: echo "out<TAB>sha256" from the newest CLEAN ledger row for
# a marker, or nothing. Fallback for pre-artifact collections (#52 item 2): lets a harvest
# whose reservation is already absent return an ALREADY-COLLECTED review instead of declaring
# it lost. Scans the WHOLE ledger (append-only, ~KBs per hundred runs) — a fixed tail window
# forgot completions older than N newer rows (gate #54 r2 P2). Markers land in the ledger
# from v0.27 on; legacy rows never match (callers fall back to the old behavior).
pg_ledger_lookup_clean() {
  local marker="$1" ledger="${PRO_GATE_LEDGER:-$PRO_GATE_HOME/ledger.jsonl}"
  pg_reservation_marker_ok "$marker" || return 1
  [ -s "$ledger" ] || return 1
  pg_have jq || return 1
  jq -r --arg m "$marker" 'select((.marker // "") == $m and .outcome == "clean") | [.out, (.sha256 // "")] | @tsv' \
    "$ledger" 2>/dev/null | tail -n 1
}

# pg_reattach_render <slug> <out> [timeout_s]: bounded attempt to SALVAGE a review whose
# generation may have completed server-side after the live oracle call lost its Chrome
# connection. Hard-timeout-wrapped so a missing tab can never hang the caller. Accepts the
# salvage ONLY when it is a COMPLETE review (ends with a VERDICT: line) — a partial snapshot
# is rejected so the caller falls through to a clean retry. Returns 0 on a usable salvage.
pg_reattach_render() {
  local slug="$1" out="$2" t="${3:-150}" tmp="${2}.salvage"
  local oracle_bin="${PRO_GATE_ORACLE_BIN:-oracle}" timeout_bin="${PRO_GATE_TIMEOUT_BIN:-timeout}"
  if [[ "$oracle_bin" == */* ]]; then
    [ -x "$oracle_bin" ] || return 1
  else
    pg_have "$oracle_bin" || return 1
  fi
  [ -n "$slug" ] || return 1
  rm -f "$tmp"
  if { [[ "$timeout_bin" == */* ]] && [ -x "$timeout_bin" ]; } || pg_have "$timeout_bin"; then
    "$timeout_bin" "${t}s" "$oracle_bin" session "$slug" --harvest --write-output "$tmp" >/dev/null 2>&1 || true
  else
    "$oracle_bin" session "$slug" --harvest --write-output "$tmp" >/dev/null 2>&1 || true
  fi
  if pg_is_review "$tmp"; then
    mv "$tmp" "$out"; return 0
  fi
  rm -f "$tmp"; return 1
}
