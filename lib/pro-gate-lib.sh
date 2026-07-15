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

pg_version_matches() {
  local installed expected
  installed="$(pg_runtime_version)"; expected="$(pg_expected_version)"
  [ -n "$installed" ] && { [ -z "$expected" ] || [ "$installed" = "$expected" ]; }
}

pg_consent_version() { printf '%s\n' "${PRO_GATE_CONSENT_VERSION:-1}"; }
pg_consent_file() { printf '%s/dangerous-mode-consent\n' "${PRO_GATE_CONSENT_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/pro-gate}"; }
pg_dangerous_consent_ok() {
  local recorded
  recorded="$(tr -d '[:space:]' < "$(pg_consent_file)" 2>/dev/null || true)"
  [ "$recorded" = "$(pg_consent_version)" ]
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
        trap 'rm -rf "'"$lockdir"'" 2>/dev/null' EXIT
        PG_SLOT_ACQUIRED="$i"
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
#   $PRO_GATE_HOME/in-progress/<marker> = "pr<TAB>out<TAB>created_epoch<TAB>miss_streak"
# Fresh runs reconcile files via marker probes and subtract the count from effective semaphore
# capacity. Live resets the miss streak; throttle/inconclusive stays fail-closed; only several
# consecutive confirmed absences release the reservation before TTL.
# Harvest success/lost removes the file. Writes/removes serialize under one flock/mkdir lock.
pg_reservation_dir() { echo "${PRO_GATE_RESERVATION_DIR:-$PRO_GATE_HOME/in-progress}"; }
pg_reservation_lock() { echo "${PRO_GATE_RESERVATION_LOCK:-$PRO_GATE_HOME/in-progress.lock}"; }
# Markers become filenames under PRO_GATE_HOME and lock paths; every character must be from the
# safe class (in particular no "/" anywhere), not just the first one after the prefix.
pg_reservation_marker_ok() {
  case "${1:-}" in
    pg-run-?*) case "$1" in *[!A-Za-z0-9.-]*) return 1;; *) return 0;; esac;;
    *) return 1;;
  esac
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

pg_reservation_write() { # marker [pr] [out] [slot] [model] -- empty pr/slot/model preserve the record's
  local marker="$1" pr="${2:-}" out="${3:-}" slot="${4:-}" model="${5:-}" dir rc created prev_pr="" prev_slot="" prev_model=""
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
  [ -f "$dir/$marker" ] && { IFS=$'\t' read -r prev_pr _ created _ prev_slot prev_model < "$dir/$marker"; } 2>/dev/null
  case "$created" in ''|*[!0-9]*) created="$(date +%s)";; esac
  [ -n "$pr" ] || pr="${prev_pr:-diff}"
  case "$slot" in ''|*[!0-9]*) slot="$prev_slot";; esac
  case "$slot" in *[!0-9]*) slot="";; esac
  [ -n "$model" ] || model="$prev_model"
  model="$(printf '%s' "$model" | tr -d '\t\n')"   # keep the record single-line + 6-field
  printf '%s\t%s\t%s\t0\t%s\t%s\n' "$pr" "$out" "$created" "$slot" "$model" > "$dir/$marker.tmp" 2>/dev/null \
    && mv -f "$dir/$marker.tmp" "$dir/$marker"
  rc=$?; pg_reservation_guard_release; return "$rc"
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

pg_reservation_remove() { # marker
  local marker="$1" dir
  pg_reservation_marker_ok "$marker" || return 0
  dir="$(pg_reservation_dir)"; pg_reservation_guard_acquire || return 1
  rm -f "$dir/$marker" 2>/dev/null
  pg_reservation_guard_release
}

# pg_reservation_note_miss <marker>: one confirmed-absent observation. Echoes "released" when
# the miss limit is reached (reservation removed) or "retained miss/limit" otherwise. Shared by
# reconciliation and the harvest not-found path so both apply the same fail-closed policy.
pg_reservation_note_miss() {
  local marker="$1" dir f pr out created misses slot model miss_limit
  miss_limit="${PRO_GATE_RESERVATION_MISSES:-3}"
  case "$miss_limit" in ''|*[!0-9]*) miss_limit=3;; esac
  [ "$miss_limit" -ge 2 ] 2>/dev/null || miss_limit=2
  pg_reservation_marker_ok "$marker" || { echo released; return 0; }
  dir="$(pg_reservation_dir)"; f="$dir/$marker"
  pg_reservation_guard_acquire || { echo "retained 0/$miss_limit"; return 0; }
  if [ ! -f "$f" ]; then pg_reservation_guard_release; echo released; return 0; fi
  { IFS=$'\t' read -r pr out created misses slot model < "$f"; } 2>/dev/null
  case "$misses" in ''|*[!0-9]*) misses=0;; esac
  misses=$(( misses + 1 ))
  if [ "$misses" -ge "$miss_limit" ]; then
    rm -f "$f" 2>/dev/null
    pg_reservation_guard_release
    echo released
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${pr:-diff}" "${out:-}" "${created:-0}" "$misses" "${slot:-}" "${model:-}" > "$f.tmp" 2>/dev/null \
      && mv -f "$f.tmp" "$f"
    pg_reservation_guard_release
    echo "retained $misses/$miss_limit"
  fi
}

pg_reservation_find_pr() { # pr-key -> marker (oldest, best-effort; files are reconciled first)
  local pr="$1" dir f found_pr
  [ -n "$pr" ] || return 1
  dir="$(pg_reservation_dir)"; [ -d "$dir" ] || return 1
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    pg_reservation_marker_ok "$(basename "$f")" || continue
    { IFS=$'\t' read -r found_pr _ < "$f"; } 2>/dev/null || continue
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
  local eff="${1:-1}" dir f slot slots="" excl="" r legacy=0 s
  dir="$(pg_reservation_dir)"
  r="$eff"
  if [ -d "$dir" ]; then
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
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
  printf '%s|%s\n' "$r" "${excl# }"
}

# pg_reservation_reconcile <salvage-script> <port>: drop reservations older than TTL or only
# after N consecutive confirmed-absent probes. A single 10s miss is NOT proof of loss: suspended
# renderers, hydration delays, and temporary marker-read failures caused false releases in review.
# Live (0) resets misses; throttle (5) and other errors keep state fail-closed.
pg_reservation_reconcile() {
  local salvage="$1" port="$2" dir ttl miss_limit interval now f marker pr out created misses slot model age mt rc
  dir="$(pg_reservation_dir)"; [ -d "$dir" ] || return 0
  ttl="${PRO_GATE_RESERVATION_TTL:-21600}"; miss_limit="${PRO_GATE_RESERVATION_MISSES:-3}"
  interval="${PRO_GATE_RECONCILE_INTERVAL:-60}"; now="$(date +%s)"
  case "$miss_limit" in ''|*[!0-9]*) miss_limit=3;; esac
  [ "$miss_limit" -ge 2 ] 2>/dev/null || miss_limit=2
  for f in "$dir"/*; do
    [ -f "$f" ] || continue; marker="$(basename "$f")"
    pg_reservation_marker_ok "$marker" || continue
    { IFS=$'\t' read -r pr out created misses slot model < "$f"; } 2>/dev/null || created=0
    case "$created" in ''|*[!0-9]*) created=0;; esac
    case "$misses" in ''|*[!0-9]*) misses=0;; esac
    age=$(( now - created ))
    if [ "$created" -gt 0 ] && [ "$age" -ge "$ttl" ]; then
      echo "[pro-gate] releasing expired in-progress reservation $marker (${age}s >= ${ttl}s TTL)" >&2
      pg_reservation_remove "$marker"; continue
    fi
    # Rate-limit probes per marker by file mtime: N concurrent fresh runs must not turn one
    # real absence window into N miss increments, and back-to-back reconciles should not spam
    # conversation probes. Writes/updates touch mtime, so consecutive misses are spaced by at
    # least this interval of wall time.
    mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
    [ "$(( now - mt ))" -lt "$interval" ] 2>/dev/null && continue
    rc=2; node "$salvage" --probe "$marker" 10 "$port" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0)
        [ "$misses" -eq 0 ] || {
          pg_reservation_guard_acquire || continue
          # The harvest may have removed the file during the probe; rewriting would resurrect a
          # released reservation and block capacity until TTL, so re-check under the guard.
          if [ -f "$f" ]; then
            printf '%s\t%s\t%s\t0\t%s\t%s\n' "$pr" "$out" "$created" "${slot:-}" "${model:-}" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
          fi
          pg_reservation_guard_release
        }
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

# pg_is_review <file>: true only when <file> looks like a COMPLETE review, not a truncated or
# garbage capture. Our prompt mandates Pn severity blocks AND one final "VERDICT:" line, so
# require BOTH (v0.15, pro-gate PR#5 review P1: the old OR-grep accepted a capture truncated
# after its first finding, which then skipped salvage/retry and shipped an incomplete review).
# The VERDICT must sit near the end (last few non-empty lines): that rejects mid-file truncation
# while tolerating trailing footer lines from the capture (e.g. a "Sources" block). The VERDICT
# match tolerates GPT-5.6 formatting drift: leading bold/bullet/quote markers and whitespace, and
# markers/space between VERDICT and its colon (e.g. `**VERDICT:**`, `- VERDICT :`).
pg_is_review() {
  local f="$1"
  [ -s "$f" ] || return 1
  [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -ge 40 ] || return 1
  grep -qiE '\[P[0-3]\]|P[0-3][*_ ]*:[[:space:]]*(none|—|-)' "$f" 2>/dev/null || return 1
  grep -vE '^[[:space:]]*$' "$f" 2>/dev/null | tail -n 6 \
    | grep -qiE '^[[:space:]]*[*_>#-]*[[:space:]]*VERDICT[*_[:space:]]*:'
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
