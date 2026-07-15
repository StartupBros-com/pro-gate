#!/usr/bin/env bash
# Durable Oracle browser session (WSL/Linux, remote-chrome mode only): Xvfb + headful Chrome
# with CDP on 127.0.0.1:PORT, against a persistent profile signed into ChatGPT. Launched by
# oracle-chrome.service. The wrapper remains the main PID so it can clean up both child processes.
# (On macOS this is not used; oracle drives signed-in Chrome natively.)
set -euo pipefail
PRO_GATE_HOME="${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"
. "$PRO_GATE_HOME/lib.sh" 2>/dev/null || true
type pg_augment_path >/dev/null 2>&1 && pg_augment_path
set -a; [ -f "$PRO_GATE_HOME/.env" ] && . "$PRO_GATE_HOME/.env"; set +a

DISPLAY_NUM="${ORACLE_DISPLAY:-:99}"
SCREEN="${ORACLE_XVFB_SCREEN:-1360x1000x24}"
PROFILE="${ORACLE_BROWSER_PROFILE_DIR:-$HOME/.oracle/browser-profile}"
PORT="${ORACLE_BROWSER_PORT:-9222}"
DNUM="${DISPLAY_NUM#:}"
CDP_READY_TIMEOUT="${ORACLE_CDP_READY_TIMEOUT:-30}"
CHROME="$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || command -v chromium-browser || true)"
SS="${ORACLE_SS_BIN:-$(command -v ss || true)}"
[ -n "$CHROME" ] || { echo "ERROR: no Chrome/Chromium found on PATH" >&2; exit 1; }
command -v Xvfb >/dev/null 2>&1 || { echo "ERROR: Xvfb not installed (apt-get install xvfb)" >&2; exit 1; }
[ -n "$SS" ] || { echo "ERROR: ss not installed (iproute2 is required)" >&2; exit 1; }
case "$PORT" in ''|*[!0-9]*) echo "ERROR: invalid browser port: $PORT" >&2; exit 1 ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] \
  || { echo "ERROR: invalid browser port: $PORT" >&2; exit 1; }
case "$CDP_READY_TIMEOUT" in ''|*[!0-9]*) echo "ERROR: invalid CDP ready timeout: $CDP_READY_TIMEOUT" >&2; exit 1 ;; esac
[ "$CDP_READY_TIMEOUT" -ge 1 ] \
  || { echo "ERROR: invalid CDP ready timeout: $CDP_READY_TIMEOUT" >&2; exit 1; }

XVFB_PID=""; CHROME_PID=""
cleanup() {
  [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null || true
  [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
  [ -n "$CHROME_PID" ] && wait "$CHROME_PID" 2>/dev/null || true
  [ -n "$XVFB_PID" ] && wait "$XVFB_PID" 2>/dev/null || true
}
on_signal() {
  local status="$1"
  trap - EXIT INT TERM
  cleanup
  exit "$status"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

"$SS" -H -ltn "sport = :${PORT}" | grep -q . \
  && { echo "ERROR: browser port ${PORT} is already owned by another listener" >&2; exit 1; }

LOCK="$PROFILE/SingletonLock"
if [ -L "$LOCK" ]; then
  OWNER="$(readlink "$LOCK" 2>/dev/null || true)"
  OWNER_PID="${OWNER##*-}"
  case "$OWNER_PID" in
    ''|*[!0-9]*) ;;
    *) kill -0 "$OWNER_PID" 2>/dev/null \
      && { echo "ERROR: browser profile is already owned by PID $OWNER_PID" >&2; exit 1; } ;;
  esac
fi

XLOCK="/tmp/.X${DNUM}-lock"
if [ -f "$XLOCK" ]; then
  XOWNER="$(tr -d '[:space:]' < "$XLOCK" 2>/dev/null || true)"
  case "$XOWNER" in
    ''|*[!0-9]*) ;;
    *) kill -0 "$XOWNER" 2>/dev/null \
      && { echo "ERROR: X display $DISPLAY_NUM is already owned by PID $XOWNER" >&2; exit 1; } ;;
  esac
fi

# Remove only locks whose recorded owner is absent. Live owners fail closed above.
rm -f "/tmp/.X11-unix/X${DNUM}" "$XLOCK" 2>/dev/null || true
rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonCookie" "$PROFILE/SingletonSocket" 2>/dev/null || true

Xvfb "$DISPLAY_NUM" -screen 0 "$SCREEN" -nolisten tcp &
XVFB_PID=$!
sleep 2
kill -0 "$XVFB_PID" 2>/dev/null \
  || { echo "ERROR: Xvfb failed to start on $DISPLAY_NUM" >&2; wait "$XVFB_PID"; exit 1; }
export DISPLAY="$DISPLAY_NUM"

# Chrome 144 can still launch and repeatedly crash a software GPU subprocess under Xvfb when only
# --disable-gpu is set. This browser needs ordinary page rendering and CDP, not WebGL.
"$CHROME" \
  --no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage \
  --keep-alive-for-test --no-first-run --no-default-browser-check \
  --disable-features=Translate,AutomationControlled \
  --remote-allow-origins='*' \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port="$PORT" \
  --user-data-dir="$PROFILE" \
  "https://chatgpt.com/" &
CHROME_PID=$!

CDP_READY=0
for ((attempt = 0; attempt < CDP_READY_TIMEOUT; attempt++)); do
  if ! kill -0 "$CHROME_PID" 2>/dev/null; then
    wait "$CHROME_PID"
    exit 1
  fi
  if curl --connect-timeout 1 --max-time 2 -sf "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; then
    CDP_READY=1
    break
  fi
  sleep 1
done
[ "$CDP_READY" -eq 1 ] \
  || { echo "ERROR: CDP did not become ready on 127.0.0.1:${PORT} within ${CDP_READY_TIMEOUT}s" >&2; exit 1; }

wait "$CHROME_PID"
