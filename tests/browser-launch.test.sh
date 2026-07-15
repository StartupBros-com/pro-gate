#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pro-gate-browser-launch.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT
FAILS=0
TEST_DISPLAY=:199
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; "$@" && pass "$name" || fail "$name"; }

make_fixture() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/home/.oracle/browser-profile" "$dir/runtime"
  printf 'pg_augment_path() { :; }\n' > "$dir/runtime/lib.sh"
  printf '#!/usr/bin/env bash\nexit "${CURL_STATUS:-1}"\n' > "$dir/bin/curl"
  printf '#!/usr/bin/env bash\n[ -n "${SS_READY_FILE:-}" ] && : > "$SS_READY_FILE"\n[ -n "${SS_SLEEP:-}" ] && sleep "$SS_SLEEP"\n[ -n "${SS_LISTENER:-}" ] && printf "LISTEN 0 128 127.0.0.1:9222 0.0.0.0:*\\n"\n' > "$dir/bin/ss"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$$" > "$XVFB_PID_FILE"\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' > "$dir/bin/Xvfb"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$CHROME_ARGS_FILE"\n[ -n "${CHROME_SLEEP:-}" ] && sleep "$CHROME_SLEEP"\nexit 0\n' > "$dir/bin/google-chrome"
  chmod +x "$dir/bin/"*
}

BASE="$TDIR/base"
make_fixture "$BASE"
if HOME="$BASE/home" PRO_GATE_HOME="$BASE/runtime" ORACLE_DISPLAY="$TEST_DISPLAY" PATH="$BASE/bin:/usr/bin:/bin" \
  SS_LISTENER=1 CURL_STATUS=0 XVFB_PID_FILE="$BASE/xvfb.pid" CHROME_ARGS_FILE="$BASE/chrome.args" \
  bash "$ROOT/daemon/run-oracle-chrome.sh" >"$BASE/occupied.log" 2>&1; then
  fail 'occupied CDP port is rejected'
else
  check 'occupied CDP port is rejected' grep -q 'browser port 9222 is already owned' "$BASE/occupied.log"
fi
check 'occupied CDP never starts Xvfb' test ! -e "$BASE/xvfb.pid"

NON_HTTP="$TDIR/non-http"
make_fixture "$NON_HTTP"
if HOME="$NON_HTTP/home" PRO_GATE_HOME="$NON_HTTP/runtime" ORACLE_DISPLAY="$TEST_DISPLAY" PATH="$NON_HTTP/bin:/usr/bin:/bin" \
  SS_LISTENER=1 CURL_STATUS=1 XVFB_PID_FILE="$NON_HTTP/xvfb.pid" CHROME_ARGS_FILE="$NON_HTTP/chrome.args" \
  bash "$ROOT/daemon/run-oracle-chrome.sh" >"$NON_HTTP/occupied.log" 2>&1; then
  fail 'non-CDP listener is rejected'
else
  check 'non-CDP listener is rejected' grep -q 'browser port 9222 is already owned' "$NON_HTTP/occupied.log"
fi
check 'non-CDP listener never starts Xvfb' test ! -e "$NON_HTTP/xvfb.pid"

SIGNAL="$TDIR/signal"
make_fixture "$SIGNAL"
HOME="$SIGNAL/home" PRO_GATE_HOME="$SIGNAL/runtime" ORACLE_DISPLAY="$TEST_DISPLAY" PATH="$SIGNAL/bin:/usr/bin:/bin" \
  SS_SLEEP=2 SS_READY_FILE="$SIGNAL/ss.ready" CURL_STATUS=1 XVFB_PID_FILE="$SIGNAL/xvfb.pid" CHROME_ARGS_FILE="$SIGNAL/chrome.args" \
  bash "$ROOT/daemon/run-oracle-chrome.sh" >"$SIGNAL/signal.log" 2>&1 & SIGNAL_PID=$!
for _ in $(seq 1 50); do [ -e "$SIGNAL/ss.ready" ] && break; sleep 0.1; done
kill -TERM "$SIGNAL_PID"
SIGNAL_STATUS=0
wait "$SIGNAL_PID" || SIGNAL_STATUS=$?
check 'TERM during preflight exits with signal status' test "$SIGNAL_STATUS" -eq 143
check 'TERM during preflight never starts Xvfb' test ! -e "$SIGNAL/xvfb.pid"

PROFILE="$TDIR/profile"
make_fixture "$PROFILE"
sleep 30 & OWNER_PID=$!
ln -s "wm-$OWNER_PID" "$PROFILE/home/.oracle/browser-profile/SingletonLock"
if HOME="$PROFILE/home" PRO_GATE_HOME="$PROFILE/runtime" ORACLE_DISPLAY="$TEST_DISPLAY" PATH="$PROFILE/bin:/usr/bin:/bin" \
  CURL_STATUS=1 XVFB_PID_FILE="$PROFILE/xvfb.pid" CHROME_ARGS_FILE="$PROFILE/chrome.args" \
  bash "$ROOT/daemon/run-oracle-chrome.sh" >"$PROFILE/owned.log" 2>&1; then
  fail 'live profile owner is rejected'
else
  check 'live profile owner is rejected' grep -q "profile is already owned by PID $OWNER_PID" "$PROFILE/owned.log"
fi
kill "$OWNER_PID" 2>/dev/null || true
wait "$OWNER_PID" 2>/dev/null || true
check 'live profile owner never starts Xvfb' test ! -e "$PROFILE/xvfb.pid"

XVFB_FAIL="$TDIR/xvfb-fail"
make_fixture "$XVFB_FAIL"
printf '#!/usr/bin/env bash\nexit 23\n' > "$XVFB_FAIL/bin/Xvfb"
chmod +x "$XVFB_FAIL/bin/Xvfb"
if HOME="$XVFB_FAIL/home" PRO_GATE_HOME="$XVFB_FAIL/runtime" ORACLE_DISPLAY="$TEST_DISPLAY" PATH="$XVFB_FAIL/bin:/usr/bin:/bin" \
  CURL_STATUS=1 XVFB_PID_FILE="$XVFB_FAIL/xvfb.pid" CHROME_ARGS_FILE="$XVFB_FAIL/chrome.args" \
  bash "$ROOT/daemon/run-oracle-chrome.sh" >"$XVFB_FAIL/fail.log" 2>&1; then
  fail 'failed Xvfb blocks Chrome launch'
else
  check 'failed Xvfb blocks Chrome launch' grep -q 'Xvfb failed to start' "$XVFB_FAIL/fail.log"
fi
check 'failed Xvfb never starts Chrome' test ! -e "$XVFB_FAIL/chrome.args"

CDP_FAIL="$TDIR/cdp-fail"
make_fixture "$CDP_FAIL"
if HOME="$CDP_FAIL/home" PRO_GATE_HOME="$CDP_FAIL/runtime" ORACLE_DISPLAY="$TEST_DISPLAY" PATH="$CDP_FAIL/bin:/usr/bin:/bin" \
  ORACLE_CDP_READY_TIMEOUT=1 CURL_STATUS=1 CHROME_SLEEP=30 XVFB_PID_FILE="$CDP_FAIL/xvfb.pid" CHROME_ARGS_FILE="$CDP_FAIL/chrome.args" \
  bash "$ROOT/daemon/run-oracle-chrome.sh" >"$CDP_FAIL/fail.log" 2>&1; then
  fail 'missing CDP readiness fails startup'
else
  check 'missing CDP readiness fails startup' grep -q 'CDP did not become ready' "$CDP_FAIL/fail.log"
fi
CDP_XVFB_PID="$(cat "$CDP_FAIL/xvfb.pid")"
check 'CDP readiness failure cleans up Xvfb' sh -c '! kill -0 "$1" 2>/dev/null' sh "$CDP_XVFB_PID"

OK="$TDIR/ok"
make_fixture "$OK"
HOME="$OK/home" PRO_GATE_HOME="$OK/runtime" ORACLE_DISPLAY="$TEST_DISPLAY" PATH="$OK/bin:/usr/bin:/bin" \
  CURL_STATUS=1 XVFB_PID_FILE="$OK/xvfb.pid" CHROME_ARGS_FILE="$OK/chrome.args" \
  bash "$ROOT/daemon/run-oracle-chrome.sh" >"$OK/ok.log" 2>&1
check 'Chrome receives software rasterizer guard' grep -q -- '--disable-software-rasterizer' "$OK/chrome.args"
check 'Chrome remains alive after Oracle closes the last target' grep -q -- '--keep-alive-for-test' "$OK/chrome.args"
XVFB_PID="$(cat "$OK/xvfb.pid")"
if kill -0 "$XVFB_PID" 2>/dev/null; then
  fail 'wrapper cleans up Xvfb after Chrome exits'
else
  pass 'wrapper cleans up Xvfb after Chrome exits'
fi

[ "$FAILS" -eq 0 ] && { echo 'ALL PASS'; exit 0; }
printf '%s FAILURES\n' "$FAILS" >&2
exit 1
