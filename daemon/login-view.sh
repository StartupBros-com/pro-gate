#!/usr/bin/env bash
# One-time / occasional (WSL/Linux remote-chrome mode): open a browser view of the Oracle Chrome
# session so you can sign into ChatGPT Pro. Brings up x11vnc + noVNC on localhost only. WSL
# forwards localhost to Windows, so you open the URL in your normal browser.
# (On macOS this is not needed — just sign into ChatGPT in your normal Chrome.)
set -uo pipefail
PRO_GATE_HOME="${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"
. "$PRO_GATE_HOME/lib.sh" 2>/dev/null || true
set -a; [ -f "$PRO_GATE_HOME/.env" ] && . "$PRO_GATE_HOME/.env"; set +a
DISPLAY_NUM="${ORACLE_DISPLAY:-:99}"
VNC_PORT="${ORACLE_VNC_PORT:-5999}"
NOVNC_PORT="${ORACLE_NOVNC_PORT:-6080}"
BIND="${ORACLE_VNC_BIND:-127.0.0.1}"

command -v x11vnc >/dev/null 2>&1 || { echo "ERROR: x11vnc not installed (apt-get install x11vnc novnc websockify)" >&2; exit 1; }
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet oracle-chrome.service 2>/dev/null; then
  echo "WARNING: oracle-chrome.service is not active — start it first:  sudo systemctl start oracle-chrome"
fi

NOVNC_WEB="/usr/share/novnc"; [ -d "$NOVNC_WEB" ] || NOVNC_WEB="/usr/share/webapps/novnc"
echo "Starting x11vnc on $DISPLAY_NUM (localhost:$VNC_PORT)..."
pkill -x x11vnc 2>/dev/null || true
x11vnc -display "$DISPLAY_NUM" -localhost -rfbport "$VNC_PORT" -nopw -forever -shared -bg -quiet >/tmp/x11vnc.log 2>&1

echo "Starting noVNC bridge..."
nohup websockify --web="$NOVNC_WEB" "${BIND}:${NOVNC_PORT}" "localhost:${VNC_PORT}" >/tmp/novnc.log 2>&1 &
sleep 1

cat <<EOF

  ────────────────────────────────────────────────────────────────────
  ►  Open in your browser:   http://localhost:${NOVNC_PORT}/vnc.html
       (click Connect — no password; WSL forwards localhost to Windows)
  ►  You'll see Chrome on chatgpt.com. Sign in to your ChatGPT Pro account.
  ►  While there, confirm:
        • GPT-5.5 Pro is selectable (your Pro plan)
        • Settings → Apps → GitHub connector is enabled for your repos
  ►  The login persists in ${ORACLE_BROWSER_PROFILE_DIR:-\$HOME/.oracle/browser-profile}
     and survives reboots (oracle-chrome.service).
  ►  When finished, close the view:   pkill x11vnc; pkill -f websockify
  ────────────────────────────────────────────────────────────────────

EOF
