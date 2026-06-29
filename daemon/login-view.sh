#!/usr/bin/env bash
# One-time / occasional: open a browser view of the Oracle Chrome session so you can
# sign into ChatGPT Pro. Brings up x11vnc + noVNC on localhost only. WSL forwards
# localhost to Windows, so you open the URL in your normal Windows browser.
set -uo pipefail
source /home/will/.pro-review-daemon/.env 2>/dev/null || true
DISPLAY_NUM="${ORACLE_DISPLAY:-:99}"
VNC_PORT="${ORACLE_VNC_PORT:-5999}"
NOVNC_PORT="${ORACLE_NOVNC_PORT:-6080}"
BIND="${ORACLE_VNC_BIND:-127.0.0.1}"

if ! systemctl is-active --quiet oracle-chrome.service 2>/dev/null; then
  echo "WARNING: oracle-chrome.service is not active — start it first:  sudo systemctl start oracle-chrome"
fi

echo "Starting x11vnc on $DISPLAY_NUM (localhost:$VNC_PORT)..."
pkill -x x11vnc 2>/dev/null || true
x11vnc -display "$DISPLAY_NUM" -localhost -rfbport "$VNC_PORT" -nopw -forever -shared -bg -quiet >/tmp/x11vnc.log 2>&1

echo "Starting noVNC bridge..."
pkill -f "websockify.*${NOVNC_PORT}" 2>/dev/null || true
nohup websockify --web=/usr/share/novnc "${BIND}:${NOVNC_PORT}" "localhost:${VNC_PORT}" >/tmp/novnc.log 2>&1 &
sleep 1

cat <<EOF

  ────────────────────────────────────────────────────────────────────
  ►  Open in your Windows browser:   http://localhost:${NOVNC_PORT}/vnc.html
       (click Connect — no password)
  ►  You'll see Chrome on chatgpt.com. Sign in to your ChatGPT Pro account.
  ►  While there, confirm:
        • GPT-5.5 Pro is selectable (your Pro plan)
        • Settings → Apps → GitHub connector is enabled for your repos
  ►  The login persists in ${ORACLE_BROWSER_PROFILE_DIR:-~/.oracle/browser-profile}
     and survives reboots (oracle-chrome.service).
  ►  When finished, close the view:   pkill x11vnc; pkill -f websockify
  ────────────────────────────────────────────────────────────────────

EOF
