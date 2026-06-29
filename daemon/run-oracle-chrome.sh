#!/usr/bin/env bash
# Durable Oracle browser session: virtual display (Xvfb) + headful Chrome with CDP
# on 127.0.0.1:9222, against a persistent profile that stays signed into ChatGPT.
# Launched by oracle-chrome.service. Chrome is the main PID; Xvfb is a tracked child
# (KillMode=control-group reaps both on stop).
set -uo pipefail

export HOME=/home/will
export USER=will
export PATH=/home/will/.local/bin:/home/will/.local/share/mise/installs/node/24.13.1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

set -a
[ -f /home/will/.pro-review-daemon/.env ] && source /home/will/.pro-review-daemon/.env
set +a

DISPLAY_NUM="${ORACLE_DISPLAY:-:99}"
SCREEN="${ORACLE_XVFB_SCREEN:-1360x1000x24}"
PROFILE="${ORACLE_BROWSER_PROFILE_DIR:-/home/will/.oracle/browser-profile}"
PORT="${ORACLE_BROWSER_PORT:-9222}"
DNUM="${DISPLAY_NUM#:}"

# Clear stale X server + Chrome singleton locks (safe: this is the only owner of the profile)
rm -f "/tmp/.X11-unix/X${DNUM}" "/tmp/.X${DNUM}-lock" 2>/dev/null || true
rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonCookie" "$PROFILE/SingletonSocket" 2>/dev/null || true

# Virtual display
Xvfb "$DISPLAY_NUM" -screen 0 "$SCREEN" -nolisten tcp &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null || true' EXIT
sleep 2
export DISPLAY="$DISPLAY_NUM"

# Headful Chrome under the virtual display. WSL-required flags: --no-sandbox,
# --disable-gpu, --disable-dev-shm-usage. CDP bound to localhost only.
exec google-chrome \
  --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --no-first-run --no-default-browser-check \
  --disable-features=Translate,AutomationControlled \
  --remote-allow-origins='*' \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port="$PORT" \
  --user-data-dir="$PROFILE" \
  "https://chatgpt.com/"
