#!/usr/bin/env bash
# pro-gate installer — deploys this repo into the live locations and sets up the durable
# ChatGPT browser session + daemon. Idempotent. WSL2-focused; macOS path is a TODO (oracle's
# browser mode is native there — no Xvfb/systemd needed).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
DAEMON_DIR="${DAEMON_DIR:-$HOME/.pro-review-daemon}"
ORACLE_DIR="${ORACLE_DIR:-$HOME/.oracle}"

say(){ printf '\033[36m▸ %s\033[0m\n' "$*"; }

# --- platform guard ---------------------------------------------------------
case "$(uname -s)" in
  Darwin)
    cat <<'EOF'
macOS detected. Oracle's browser mode is native on macOS (it reuses your logged-in Chrome —
no Xvfb, no systemd, no daemon needed for the interactive skill). The Mac-native install path
is not yet automated. For now, manually:
  1) pnpm add -g @steipete/oracle   &&   log into ChatGPT in Chrome
  2) cp -r skills/pro-gate "$HOME/.claude/skills/" ; cp agents/oracle-reviewer.md "$HOME/.claude/agents/"
  3) mkdir -p ~/.pro-review-daemon && cp bin/oracle-review.sh ~/.pro-review-daemon/ && cp .env.example ~/.pro-review-daemon/.env
  4) In ~/.pro-review-daemon/.env, the --remote-chrome flow is WSL-specific; on macOS drop it
     and let oracle launch/attach Chrome itself (see docs/SETUP-NOTES.md).
Then use:  /pro-gate <pr>
EOF
    exit 0 ;;
esac

# --- oracle ----------------------------------------------------------------
if ! command -v oracle >/dev/null 2>&1; then
  say "installing @steipete/oracle"; pnpm add -g @steipete/oracle
fi

# --- skill + agent ---------------------------------------------------------
say "deploying skill + agent into $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/skills/pro-gate" "$CLAUDE_DIR/agents"
cp "$REPO/skills/pro-gate/SKILL.md" "$CLAUDE_DIR/skills/pro-gate/SKILL.md"
cp "$REPO/agents/oracle-reviewer.md" "$CLAUDE_DIR/agents/oracle-reviewer.md"

# --- engine + daemon -------------------------------------------------------
say "deploying engine + daemon into $DAEMON_DIR"
mkdir -p "$DAEMON_DIR" "$ORACLE_DIR"
cp "$REPO/bin/oracle-review.sh" "$DAEMON_DIR/"
cp "$REPO"/daemon/{daemon.sh,run-daemon.sh,run-oracle-chrome.sh,login-view.sh} "$DAEMON_DIR/"
cp "$REPO/oracle/config.json" "$ORACLE_DIR/config.json"
chmod +x "$DAEMON_DIR"/*.sh
[ -f "$DAEMON_DIR/.env" ] || { cp "$REPO/.env.example" "$DAEMON_DIR/.env"; say "wrote $DAEMON_DIR/.env (review it)"; }

# --- systemd units (WSL2 with systemd) -------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  say "installing systemd units (oracle-chrome, pro-review-daemon)"
  sudo cp "$REPO/daemon/oracle-chrome.service" "$REPO/daemon/pro-review-daemon.service" /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now oracle-chrome.service
  sudo systemctl enable --now pro-review-daemon.service
fi

cat <<EOF

✓ pro-gate installed.
  Next: sign into ChatGPT Pro once →  $DAEMON_DIR/login-view.sh
        then open http://localhost:6080/vnc.html and log in.
  Use:  /pro-gate <pr>          (interactive)
        gh pr edit <n> --add-label pro-review   (set-and-forget)
EOF
