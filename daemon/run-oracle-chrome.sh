#!/usr/bin/env bash
# Durable Oracle browser session (WSL/Linux, remote-chrome mode only): Xvfb + headful Chrome
# with CDP on 127.0.0.1:PORT, against a persistent profile signed into ChatGPT. Launched by
# oracle-chrome.service. Chrome is the main PID; Xvfb is a tracked child.
# (On macOS this is not used — oracle drives signed-in Chrome natively.)
set -uo pipefail
PRO_GATE_HOME="${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"
. "$PRO_GATE_HOME/lib.sh" 2>/dev/null || true
type pg_augment_path >/dev/null 2>&1 && pg_augment_path
set -a; [ -f "$PRO_GATE_HOME/.env" ] && . "$PRO_GATE_HOME/.env"; set +a

DISPLAY_NUM="${ORACLE_DISPLAY:-:99}"
SCREEN="${ORACLE_XVFB_SCREEN:-1360x1000x24}"
PROFILE="${ORACLE_BROWSER_PROFILE_DIR:-$HOME/.oracle/browser-profile}"
PORT="${ORACLE_BROWSER_PORT:-9222}"
DNUM="${DISPLAY_NUM#:}"
CHROME="$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || command -v chromium-browser || true)"
[ -n "$CHROME" ] || { echo "ERROR: no Chrome/Chromium found on PATH" >&2; exit 1; }
command -v Xvfb >/dev/null 2>&1 || { echo "ERROR: Xvfb not installed (apt-get install xvfb)" >&2; exit 1; }

# Clear stale X server + Chrome singleton locks (safe: this is the only owner of the profile)
rm -f "/tmp/.X11-unix/X${DNUM}" "/tmp/.X${DNUM}-lock" 2>/dev/null || true
rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonCookie" "$PROFILE/SingletonSocket" 2>/dev/null || true

Xvfb "$DISPLAY_NUM" -screen 0 "$SCREEN" -nolisten tcp &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null || true' EXIT
sleep 2
export DISPLAY="$DISPLAY_NUM"

# Headful Chrome under the virtual display. WSL-required flags: --no-sandbox, --disable-gpu,
# --disable-dev-shm-usage. CDP bound to localhost only.
exec "$CHROME" \
  --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --no-first-run --no-default-browser-check \
  --disable-features=Translate,AutomationControlled \
  --remote-allow-origins='*' \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port="$PORT" \
  --user-data-dir="$PROFILE" \
  "https://chatgpt.com/"
