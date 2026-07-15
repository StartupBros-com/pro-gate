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
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$$" > "$XVFB_PID_FILE"\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' > "$dir/bin/Xvfb"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$CHROME_ARGS_FILE"\nexit 0\n' > "$dir/bin/google-chrome"
  chmod +x "$dir/bin/"*
}

BASE="$TDIR/base"
make_fixture "$BASE"
if HOME="$BASE/home" PRO_GATE_HOME="$BASE/runtime" ORACLE_DISPLAY="$TEST_DISPLAY" PATH="$BASE/bin:/usr/bin:/bin" \
  CURL_STATUS=0 XVFB_PID_FILE="$BASE/xvfb.pid" CHROME_ARGS_FILE="$BASE/chrome.args" \
  bash "$ROOT/daemon/run-oracle-chrome.sh" >"$BASE/occupied.log" 2>&1; then
  fail 'occupied CDP port is rejected'
else
  check 'occupied CDP port is rejected' grep -q 'CDP port 9222 is already owned' "$BASE/occupied.log"
fi
check 'occupied CDP never starts Xvfb' test ! -e "$BASE/xvfb.pid"

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

OK="$TDIR/ok"
make_fixture "$OK"
HOME="$OK/home" PRO_GATE_HOME="$OK/runtime" ORACLE_DISPLAY="$TEST_DISPLAY" PATH="$OK/bin:/usr/bin:/bin" \
  CURL_STATUS=1 XVFB_PID_FILE="$OK/xvfb.pid" CHROME_ARGS_FILE="$OK/chrome.args" \
  bash "$ROOT/daemon/run-oracle-chrome.sh" >"$OK/ok.log" 2>&1
check 'Chrome receives software rasterizer guard' grep -q -- '--disable-software-rasterizer' "$OK/chrome.args"
XVFB_PID="$(cat "$OK/xvfb.pid")"
if kill -0 "$XVFB_PID" 2>/dev/null; then
  fail 'wrapper cleans up Xvfb after Chrome exits'
else
  pass 'wrapper cleans up Xvfb after Chrome exits'
fi

[ "$FAILS" -eq 0 ] && { echo 'ALL PASS'; exit 0; }
printf '%s FAILURES\n' "$FAILS" >&2
exit 1
