#!/usr/bin/env bash
# pro-gate installer — deploys this repo into the live locations and (optionally) sets up the
# daemon. Cross-platform: macOS (oracle native) and WSL/Linux (Xvfb Chrome + systemd). Idempotent.
#
#   INSTALL_DAEMON=1  ./install.sh   # also install + start the set-and-forget daemon
#   INSTALL_DAEMON=0  ./install.sh   # skill + engine only (interactive /pro-gate)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO/lib/pro-gate-lib.sh"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
DAEMON_DIR="$PRO_GATE_HOME"
ORACLE_DIR="${ORACLE_DIR:-$HOME/.oracle}"
OS="$(pg_os)"; MODE="$(pg_browser_mode)"; SVC="$(pg_service_mgr)"
# daemon defaults: on for Linux/systemd, opt-in for macOS (native browser is fragile unattended)
case "$OS" in macos) INSTALL_DAEMON="${INSTALL_DAEMON:-0}";; *) INSTALL_DAEMON="${INSTALL_DAEMON:-1}";; esac

say(){ printf '\033[36m▸ %s\033[0m\n' "$*"; }
render(){ sed -e "s#@HOME@#${HOME}#g" -e "s#@USER@#$(id -un)#g" "$1"; }
# put <src> <dst>: ATOMIC deploy of one runtime file. cp truncates the destination inode in
# place, which corrupts any bash engine mid-read of that script (bash reads scripts
# incrementally); deploys therefore used to require a fully quiet account. Writing a temp file
# and rename(2)-ing it in gives running readers their old inode untouched while new invocations
# see the new file, so installs are safe during live reviews.
put(){
  local src="$1" dst="$2" tmp
  tmp="$dst.deploy.$$"
  cp "$src" "$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$dst"
}

say "platform: $OS  (browser mode: $MODE, service: $SVC, daemon: $INSTALL_DAEMON)"

# 0. prereqs
if ! pg_have oracle; then
  say "installing @steipete/oracle"
  pg_have pnpm && pnpm add -g @steipete/oracle || npm i -g @steipete/oracle
fi
for dep in gh git jq flock; do pg_have "$dep" || echo "  ⚠ missing dependency: $dep"; done

# 1. skill + agent
say "deploying skill + agent → $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/skills/pro-gate" "$CLAUDE_DIR/agents"
put "$REPO/skills/pro-gate/SKILL.md" "$CLAUDE_DIR/skills/pro-gate/SKILL.md"
put "$REPO/agents/oracle-reviewer.md" "$CLAUDE_DIR/agents/oracle-reviewer.md"

# 2. lib + engine + daemon + oracle config
say "deploying engine + daemon + lib → $DAEMON_DIR"
mkdir -p "$DAEMON_DIR/logs" "$ORACLE_DIR"
put "$REPO/lib/pro-gate-lib.sh"   "$DAEMON_DIR/lib.sh"
put "$REPO/bin/oracle-review.sh"  "$DAEMON_DIR/oracle-review.sh"
put "$REPO/bin/pro-gate-doctor.sh" "$DAEMON_DIR/pro-gate-doctor.sh"
put "$REPO/bin/pro-gate-stats.sh"  "$DAEMON_DIR/pro-gate-stats.sh"
put "$REPO/bin/cdp-salvage.mjs"   "$DAEMON_DIR/cdp-salvage.mjs"
for f in daemon.sh run-daemon.sh run-oracle-chrome.sh login-view.sh; do
  put "$REPO/daemon/$f" "$DAEMON_DIR/$f"
done
[ -f "$DAEMON_DIR/.env" ] || { cp "$REPO/.env.example" "$DAEMON_DIR/.env"; say "wrote $DAEMON_DIR/.env — set PRO_REVIEW_OWNERS"; }

# 3. browser session + service (per platform)
case "$OS" in
  macos)
    say "macOS native — no Xvfb/oracle-chrome service; sign into ChatGPT in Chrome."
    if [ "$INSTALL_DAEMON" = 1 ]; then
      PL="$HOME/Library/LaunchAgents/com.pro-gate.review-daemon.plist"
      render "$REPO/daemon/com.pro-gate.review-daemon.plist.tmpl" > "$PL"
      launchctl unload "$PL" 2>/dev/null || true; launchctl load "$PL"
      say "loaded launchd daemon ($PL). Stop: launchctl unload $PL"
    fi
    ;;
  wsl|linux)
    if [ "$SVC" = systemd ]; then
      say "installing systemd units"
      render "$REPO/daemon/oracle-chrome.service.tmpl"     | sudo tee /etc/systemd/system/oracle-chrome.service >/dev/null
      render "$REPO/daemon/pro-review-daemon.service.tmpl" | sudo tee /etc/systemd/system/pro-review-daemon.service >/dev/null
      sudo systemctl daemon-reload
      sudo systemctl enable --now oracle-chrome.service
      [ "$INSTALL_DAEMON" = 1 ] && sudo systemctl enable --now pro-review-daemon.service
    else
      say "no systemd — start the browser session manually: $DAEMON_DIR/run-oracle-chrome.sh &"
    fi
    ;;
  *) echo "  ⚠ unsupported OS for the browser session; interactive skill may still work if oracle does." ;;
esac

# 4. verify + next steps
"$DAEMON_DIR/pro-gate-doctor.sh" 2>/dev/null || true
cat <<EOF

✓ pro-gate installed ($OS).
  1) set PRO_REVIEW_OWNERS in $DAEMON_DIR/.env
  2) sign in to ChatGPT Pro:
       macOS:     open Chrome → chatgpt.com (ensure your Pro model + the GitHub connector are on)
       WSL/Linux: $DAEMON_DIR/login-view.sh  → open http://localhost:6080/vnc.html
  3) verify:  $DAEMON_DIR/pro-gate-doctor.sh
  Use:  /pro-gate <pr>            (interactive)
        gh pr edit <n> --add-label pro-review   (set-and-forget, if daemon installed)
EOF
