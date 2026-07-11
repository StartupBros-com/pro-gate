#!/usr/bin/env bash
# Tests for the daemon self-reload: pick up a redeploy at the idle top of the poll loop by
# re-execing in place, instead of a control-group-killing `systemctl restart`. The trigger is an
# atomic deploy stamp ($PRO_GATE_HOME/.deploy-stamp) that install.sh writes LAST, after every
# runtime file has landed (so the daemon never re-execs onto a half-deployed file set).
#   - pg_file_sig: stable + change-sensitive content signature (the stamp content)
#   - install.sh writes .deploy-stamp last, = sig of the deployed daemon code
#   - integration: a running daemon re-execs itself when the stamp changes, keeps its PID (proving
#     exec, not a fresh spawn), reloads exactly once, and stays put when self-reload is disabled
# No ChatGPT/gh/network: gh is stubbed, sudo is a no-op, browser mode is forced native.
# Run: bash tests/daemon-reload.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/pro-gate-lib.sh"
FAILS=0
check() { if [ "$2" = 0 ]; then echo "ok - $1"; else echo "FAIL - $1: ${3:-}"; FAILS=$((FAILS + 1)); fi; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-daemon-test.XXXXXX")"
DPID=""
cleanup() {
  [ -n "$DPID" ] && { kill "$DPID" 2>/dev/null; pkill -P "$DPID" 2>/dev/null; }
  pkill -f "$TDIR/daemon.sh" 2>/dev/null
  rm -rf "$TDIR"
}
trap cleanup EXIT

echo '# pg_file_sig: stable + change-sensitive'
mkdir -p "$TDIR/sig"
printf 'alpha\n' > "$TDIR/sig/a"; printf 'beta\n' > "$TDIR/sig/b"
S1="$(bash -c ". '$LIB'; pg_file_sig '$TDIR/sig/a' '$TDIR/sig/b'")"
S2="$(bash -c ". '$LIB'; pg_file_sig '$TDIR/sig/a' '$TDIR/sig/b'")"
check 'sig is non-empty' "$([ -n "$S1" ]; echo $?)" "s1=$S1"
check 'sig is stable across calls' "$([ "$S1" = "$S2" ]; echo $?)" "s1=$S1 s2=$S2"
printf 'beta-CHANGED\n' > "$TDIR/sig/b"
S3="$(bash -c ". '$LIB'; pg_file_sig '$TDIR/sig/a' '$TDIR/sig/b'")"
check 'sig changes when a file changes' "$([ "$S1" != "$S3" ]; echo $?)" "s1=$S1 s3=$S3"
rm -f "$TDIR/sig/b"
S4="$(bash -c ". '$LIB'; pg_file_sig '$TDIR/sig/a' '$TDIR/sig/b'")"
check 'sig changes when a file disappears' "$([ "$S3" != "$S4" ]; echo $?)" "s3=$S3 s4=$S4"

echo '# install.sh writes an atomic deploy stamp (= sig of the deployed daemon code) as its last deploy step'
SBI="$TDIR/inst"; mkdir -p "$SBI/shim" "$SBI/claude" "$SBI/home" "$SBI/oracle"
printf '#!/bin/sh\nexit 0\n' > "$SBI/shim/sudo"; chmod +x "$SBI/shim/sudo"   # neutralize systemd steps
INSTALL_DAEMON=0 CLAUDE_DIR="$SBI/claude" PRO_GATE_HOME="$SBI/home" ORACLE_DIR="$SBI/oracle" \
  PATH="$SBI/shim:$PATH" bash "$HERE/../install.sh" > "$SBI/install.log" 2>&1 || true
check 'install wrote .deploy-stamp' "$([ -s "$SBI/home/.deploy-stamp" ]; echo $?)" "$(ls -1 "$SBI/home" 2>/dev/null | tr '\n' ' ')"
EXP="$(bash -c ". '$LIB'; pg_file_sig '$SBI/home/daemon.sh' '$SBI/home/lib.sh' '$SBI/home/run-daemon.sh'")"
GOT="$(cat "$SBI/home/.deploy-stamp" 2>/dev/null || true)"
check 'stamp == sig of deployed daemon code' "$([ -n "$GOT" ] && [ "$GOT" = "$EXP" ]; echo $?)" "got=$GOT exp=$EXP"
check 'no leftover .deploy-stamp.tmp (atomic rename)' "$([ ! -e "$SBI/home/.deploy-stamp.tmp" ]; echo $?)" 'tmp left behind'

echo '# integration: daemon re-execs itself in place when the deploy stamp changes'
cp "$HERE/../daemon/daemon.sh"      "$TDIR/daemon.sh"
cp "$HERE/../lib/pro-gate-lib.sh"   "$TDIR/lib.sh"
cp "$HERE/../daemon/run-daemon.sh"  "$TDIR/run-daemon.sh"
chmod +x "$TDIR/daemon.sh" "$TDIR/run-daemon.sh"
mkdir -p "$TDIR/.local/bin" "$TDIR/logs"
# Stub gh so the daemon finds no PRs and just idles through its poll loop (wins in PATH because
# pg_augment_path prepends $HOME/.local/bin first, and HOME is pinned to $TDIR below).
printf '#!/bin/sh\nexit 0\n' > "$TDIR/.local/bin/gh"; chmod +x "$TDIR/.local/bin/gh"

DLOG="$TDIR/daemon.log"
HOME="$TDIR" PRO_GATE_HOME="$TDIR" PRO_REVIEW_OWNERS=fakeowner PRO_REVIEW_POLL_SECONDS=1 \
  PRO_GATE_BROWSER_MODE=native PRO_GATE_DAEMON_SELF_RELOAD=1 PATH="/usr/bin:/bin" \
  bash "$TDIR/run-daemon.sh" > "$DLOG" 2>&1 &
DPID=$!

for _ in $(seq 1 50); do grep -q 'pro-review-daemon starting' "$DLOG" 2>/dev/null && break; sleep 0.2; done
check 'daemon started' "$(grep -q 'pro-review-daemon starting' "$DLOG"; echo $?)" "$(tail -3 "$DLOG" 2>/dev/null)"
check 'daemon process alive before reload' "$(kill -0 "$DPID" 2>/dev/null; echo $?)" "pid=$DPID"

# Simulate install.sh finishing a deploy: write the stamp atomically (this is the ONLY trigger now,
# so merely editing daemon.sh on disk would NOT reload -- the stamp is the deploy-complete signal).
printf 'deploy-v2-%s\n' "$(date +%s)" > "$TDIR/.deploy-stamp.tmp" && mv -f "$TDIR/.deploy-stamp.tmp" "$TDIR/.deploy-stamp"

for _ in $(seq 1 60); do grep -q 'detected a new daemon deploy' "$DLOG" 2>/dev/null && break; sleep 0.2; done
check 'daemon detected the new deploy stamp' "$(grep -q 'detected a new daemon deploy' "$DLOG"; echo $?)" "$(tail -5 "$DLOG" 2>/dev/null)"
for _ in $(seq 1 40); do [ "$(grep -c 'pro-review-daemon starting' "$DLOG" 2>/dev/null)" -ge 2 ] && break; sleep 0.2; done
check 'daemon re-started after reload (2 startup lines)' "$([ "$(grep -c 'pro-review-daemon starting' "$DLOG")" -ge 2 ]; echo $?)" "starts=$(grep -c 'pro-review-daemon starting' "$DLOG")"
check 'PID unchanged across reload (exec, not a fresh spawn)' "$(kill -0 "$DPID" 2>/dev/null; echo $?)" "pid=$DPID"

# No reload-loop: several more polls, and re-writing the SAME stamp content, must not reload again.
sleep 2
cp "$TDIR/.deploy-stamp" "$TDIR/.deploy-stamp.tmp" && mv -f "$TDIR/.deploy-stamp.tmp" "$TDIR/.deploy-stamp"
sleep 2
check 'reloaded exactly once (no reload-loop; identical stamp is inert)' "$([ "$(grep -c 'detected a new daemon deploy' "$DLOG")" -eq 1 ]; echo $?)" "reloads=$(grep -c 'detected a new daemon deploy' "$DLOG")"
check 'started exactly twice (no reload-loop)' "$([ "$(grep -c 'pro-review-daemon starting' "$DLOG")" -eq 2 ]; echo $?)" "starts=$(grep -c 'pro-review-daemon starting' "$DLOG")"

echo '# integration: self-reload disabled -> no re-exec on a new stamp'
kill "$DPID" 2>/dev/null; pkill -P "$DPID" 2>/dev/null; DPID=""
sleep 0.5
rm -f "$TDIR/.deploy-stamp"
DLOG2="$TDIR/daemon2.log"
HOME="$TDIR" PRO_GATE_HOME="$TDIR" PRO_REVIEW_OWNERS=fakeowner PRO_REVIEW_POLL_SECONDS=1 \
  PRO_GATE_BROWSER_MODE=native PRO_GATE_DAEMON_SELF_RELOAD=0 PATH="/usr/bin:/bin" \
  bash "$TDIR/run-daemon.sh" > "$DLOG2" 2>&1 &
DPID=$!
for _ in $(seq 1 50); do grep -q 'pro-review-daemon starting' "$DLOG2" 2>/dev/null && break; sleep 0.2; done
printf 'deploy-v3-%s\n' "$(date +%s)" > "$TDIR/.deploy-stamp.tmp" && mv -f "$TDIR/.deploy-stamp.tmp" "$TDIR/.deploy-stamp"
sleep 3
check 'self-reload=0 does not detect/reload' "$([ "$(grep -c 'detected a new daemon deploy' "$DLOG2")" -eq 0 ]; echo $?)" "reloads=$(grep -c 'detected a new daemon deploy' "$DLOG2")"
check 'self-reload=0 keeps a single startup line' "$([ "$(grep -c 'pro-review-daemon starting' "$DLOG2")" -eq 1 ]; echo $?)" "starts=$(grep -c 'pro-review-daemon starting' "$DLOG2")"

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILURES"; exit 1; }
