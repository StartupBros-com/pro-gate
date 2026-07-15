#!/usr/bin/env bash
# Exact-release runtime installer. The Claude plugin owns the skill and agent.
# Remote use:
#   curl -fsSL "https://raw.githubusercontent.com/StartupBros-com/pro-gate/v0.21.0/install.sh?$(date +%s)" | bash -s -- --version 0.21.0
set -euo pipefail
umask 022

OWNER="StartupBros-com"
REPO_NAME="pro-gate"
PRO_GATE_HOME="${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"
ORACLE_DIR="${ORACLE_DIR:-$HOME/.oracle}"
INSTALL_DAEMON="${INSTALL_DAEMON:-0}"
LOCAL_SOURCE=0
REQUESTED_VERSION=""
ARCHIVE=""
CHECKSUM_FILE=""
ACCEPT_CONSENT=0
CONSENT_VERSION="${PRO_GATE_CONSENT_VERSION:-1}"
CONSENT_HOME="${PRO_GATE_CONSENT_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/pro-gate}"
CONSENT_FILE="$CONSENT_HOME/dangerous-mode-consent"
LOCKDIR=""
LOCK_ACQUIRED=0
LOCK_OWNER_FILE=""
REAPER_LOCKDIR=""
REAPER_LOCK_ACQUIRED=0
PROXY_ARGS=()
[ -n "${HTTPS_PROXY:-}" ] && PROXY_ARGS=(--proxy "$HTTPS_PROXY")
[ -z "${HTTPS_PROXY:-}" ] && [ -n "${HTTP_PROXY:-}" ] && PROXY_ARGS=(--proxy "$HTTP_PROXY")
TMP=""
BACKUP=""
DEPLOYING=0

usage() {
  cat <<'EOF'
Usage: install.sh --version VERSION [options]

Options:
  --version VERSION          Install this exact release
  --archive FILE             Install a local release archive
  --checksum FILE            Verify --archive against this checksum file
  --local-source             Install from the on-disk source tree containing this installer
  --daemon                   Install and enable the automatic review daemon
  --accept-dangerous-mode    Record versioned operator consent for the daemon
  --help                     Show this help

INSTALL_DAEMON=1 is equivalent to --daemon. The daemon is off by default.
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --version) REQUESTED_VERSION="${2:-}"; shift 2;;
    --archive) ARCHIVE="${2:-}"; shift 2;;
    --checksum) CHECKSUM_FILE="${2:-}"; shift 2;;
    --local-source) LOCAL_SOURCE=1; shift;;
    --daemon) INSTALL_DAEMON=1; shift;;
    --accept-dangerous-mode) ACCEPT_CONSENT=1; shift;;
    --help|-h) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2;;
  esac
done

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$DEPLOYING" = 1 ] && [ -n "$BACKUP" ]; then
    for f in lib.sh oracle-review.sh pro-gate-doctor.sh pro-gate-stats.sh cdp-salvage.mjs daemon.sh run-daemon.sh run-oracle-chrome.sh login-view.sh VERSION EXPECTED_VERSION .deploy-stamp; do
      if [ -e "$BACKUP/$f" ]; then mv -f "$BACKUP/$f" "$PRO_GATE_HOME/$f"; else rm -f "$PRO_GATE_HOME/$f"; fi
    done
  fi
  [ "$LOCK_ACQUIRED" = 1 ] && rm -rf "$LOCKDIR"
  if [ "$REAPER_LOCK_ACQUIRED" = 1 ]; then
    rmdir "$REAPER_LOCKDIR" 2>/dev/null || true
  fi
  [ -n "$TMP" ] && rm -rf "$TMP"
  trap - EXIT
  exit "$rc"
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pro-gate-install.XXXXXX")"
trap cleanup EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo "SHA256 tool required" >&2; return 1
  fi
}

if [ "$LOCAL_SOURCE" = 1 ]; then
  [ -z "$ARCHIVE" ] || { echo "--local-source cannot be combined with --archive" >&2; exit 2; }
  INSTALLER_SOURCE="${BASH_SOURCE[0]:-}"
  [ -n "$INSTALLER_SOURCE" ] && [ -f "$INSTALLER_SOURCE" ] && [ ! -d "$INSTALLER_SOURCE" ] || {
    echo "--local-source requires install.sh to be a real regular on-disk file" >&2
    exit 2
  }
  INSTALLER_SOURCE="$(cd "$(dirname "$INSTALLER_SOURCE")" && pwd -P)/$(basename "$INSTALLER_SOURCE")"
  SOURCE_ROOT="$(dirname "$INSTALLER_SOURCE")"
  [ "$INSTALLER_SOURCE" = "$SOURCE_ROOT/install.sh" ] \
    && [ -f "$SOURCE_ROOT/VERSION" ] \
    && [ -f "$SOURCE_ROOT/lib/pro-gate-lib.sh" ] || {
      echo "--local-source installer must be install.sh inside a complete source tree" >&2
      exit 2
    }
  LOCAL_VERSION="$(tr -d '[:space:]' < "$SOURCE_ROOT/VERSION")"
  [ -n "$REQUESTED_VERSION" ] || REQUESTED_VERSION="$LOCAL_VERSION"
  [ "$REQUESTED_VERSION" = "$LOCAL_VERSION" ] || { echo "requested $REQUESTED_VERSION but source is $LOCAL_VERSION" >&2; exit 1; }
else
  [ -n "$REQUESTED_VERSION" ] || { echo "--version is required for an exact release install" >&2; exit 2; }
  if [ -z "$ARCHIVE" ]; then
    BASE="${PRO_GATE_RELEASE_BASE_URL:-https://github.com/$OWNER/$REPO_NAME/releases/download/v$REQUESTED_VERSION}"
    ARCHIVE="$TMP/pro-gate-runtime-$REQUESTED_VERSION.tar.gz"
    CHECKSUM_FILE="$TMP/pro-gate-runtime-$REQUESTED_VERSION.tar.gz.sha256"
    curl -fsSL "${PROXY_ARGS[@]}" "$BASE/pro-gate-runtime-$REQUESTED_VERSION.tar.gz" -o "$ARCHIVE"
    curl -fsSL "${PROXY_ARGS[@]}" "$BASE/pro-gate-runtime-$REQUESTED_VERSION.tar.gz.sha256" -o "$CHECKSUM_FILE"
  fi
  [ -f "$ARCHIVE" ] || { echo "release archive not found: $ARCHIVE" >&2; exit 1; }
  [ -n "$CHECKSUM_FILE" ] && [ -f "$CHECKSUM_FILE" ] || { echo "checksum file is required" >&2; exit 1; }
  EXPECTED="$(grep -E '^[0-9a-fA-F]{64}([[:space:]]|$)' "$CHECKSUM_FILE" | head -1 | cut -d' ' -f1 | tr 'A-F' 'a-f')"
  ACTUAL="$(sha256 "$ARCHIVE")"
  [ -n "$EXPECTED" ] && [ "$ACTUAL" = "$EXPECTED" ] || { echo "checksum mismatch for release $REQUESTED_VERSION" >&2; exit 1; }
  if tar -tzf "$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "release archive contains an unsafe path" >&2
    exit 1
  fi
  tar -xzf "$ARCHIVE" -C "$TMP"
  SOURCE_ROOT="$TMP/pro-gate-runtime-$REQUESTED_VERSION"
  [ -f "$SOURCE_ROOT/VERSION" ] || { echo "archive is missing VERSION" >&2; exit 1; }
  LOCAL_VERSION="$(tr -d '[:space:]' < "$SOURCE_ROOT/VERSION")"
  [ "$LOCAL_VERSION" = "$REQUESTED_VERSION" ] || { echo "archive version $LOCAL_VERSION does not match requested $REQUESTED_VERSION" >&2; exit 1; }
fi

# Do not create or alter the install destination until the complete release has
# passed checksum, extraction-path, and version validation above.
mkdir -p "$PRO_GATE_HOME"
if [ "${PRO_GATE_FORCE_PORTABLE_LOCK:-0}" != 1 ] && command -v flock >/dev/null 2>&1; then
  exec 9>>"$PRO_GATE_HOME/.install.lock"
  flock -w 60 9 || { echo "another pro-gate install is in progress" >&2; exit 1; }
else
  LOCKDIR="$PRO_GATE_HOME/.install.lock.d"
  LOCK_OWNER_FILE="$LOCKDIR/owner"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    REAPER_LOCKDIR="$PRO_GATE_HOME/.install.lock.reaper"
    if ! mkdir "$REAPER_LOCKDIR" 2>/dev/null; then
      echo "another pro-gate install is in progress" >&2
      exit 1
    fi
    REAPER_LOCK_ACQUIRED=1

    LOCK_OWNER="$(cat "$LOCK_OWNER_FILE" 2>/dev/null || true)"
    LOCK_PID="${LOCK_OWNER%% *}"
    LOCK_START="${LOCK_OWNER#* }"
    LIVE_START=""
    case "$LOCK_PID" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "$LOCK_PID" 2>/dev/null; then
          LIVE_START="$(ps -o lstart= -p "$LOCK_PID" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//' || true)"
        fi
        ;;
    esac
    if [ -z "$LOCK_START" ] || [ "$LOCK_START" = "$LOCK_OWNER" ] || [ "$LIVE_START" = "$LOCK_START" ]; then
      echo "another pro-gate install is in progress" >&2
      exit 1
    fi

    STALE_LOCK="$PRO_GATE_HOME/.install.lock.stale.$$"
    if ! mv "$LOCKDIR" "$STALE_LOCK" 2>/dev/null || ! mkdir "$LOCKDIR" 2>/dev/null; then
      [ -d "$STALE_LOCK" ] && mv "$STALE_LOCK" "$LOCKDIR" 2>/dev/null || true
      echo "another pro-gate install is in progress" >&2
      exit 1
    fi
    rm -rf "$STALE_LOCK"
    rmdir "$REAPER_LOCKDIR"
    REAPER_LOCK_ACQUIRED=0
  fi
  LOCK_ACQUIRED=1
  LOCK_START="$(ps -o lstart= -p "$$" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
  [ -n "$LOCK_START" ] || { echo "could not record portable lock owner" >&2; exit 1; }
  printf '%s %s\n' "$$" "$LOCK_START" > "$LOCK_OWNER_FILE"
fi

. "$SOURCE_ROOT/lib/pro-gate-lib.sh"
OS="$(pg_os)"; MODE="$(pg_browser_mode)"; SVC="$(pg_service_mgr)"
if [ "$ACCEPT_CONSENT" = 1 ]; then
  echo "Consent v$CONSENT_VERSION: automatic fixers may modify target repositories by running Claude Code with --dangerously-skip-permissions." >&2
  mkdir -p "$CONSENT_HOME"
  printf '%s\n' "$CONSENT_VERSION" > "$CONSENT_FILE.tmp"
  mv -f "$CONSENT_FILE.tmp" "$CONSENT_FILE"
fi
if [ "$INSTALL_DAEMON" = 1 ]; then
  RECORDED="$(tr -d '[:space:]' < "$CONSENT_FILE" 2>/dev/null || true)"
  if [ "$RECORDED" != "$CONSENT_VERSION" ]; then
    echo "daemon consent required: it runs an automatic fixer against target repositories with --dangerously-skip-permissions" >&2
    echo "review the disclosure, then rerun with --daemon --accept-dangerous-mode" >&2
    exit 1
  fi
fi

mkdir -p "$PRO_GATE_HOME/logs" "$ORACLE_DIR"
BACKUP="$TMP/backup"; mkdir -p "$BACKUP"
for f in lib.sh oracle-review.sh pro-gate-doctor.sh pro-gate-stats.sh cdp-salvage.mjs daemon.sh run-daemon.sh run-oracle-chrome.sh login-view.sh VERSION EXPECTED_VERSION .deploy-stamp; do
  [ -e "$PRO_GATE_HOME/$f" ] && cp -p "$PRO_GATE_HOME/$f" "$BACKUP/$f"
done
DEPLOYING=1
put() { local src="$1" dst="$2" tmp="$2.deploy.$$"; install -m 0755 "$src" "$tmp"; mv -f "$tmp" "$dst"; }
put "$SOURCE_ROOT/lib/pro-gate-lib.sh" "$PRO_GATE_HOME/lib.sh"
put "$SOURCE_ROOT/bin/oracle-review.sh" "$PRO_GATE_HOME/oracle-review.sh"
put "$SOURCE_ROOT/bin/pro-gate-doctor.sh" "$PRO_GATE_HOME/pro-gate-doctor.sh"
put "$SOURCE_ROOT/bin/pro-gate-stats.sh" "$PRO_GATE_HOME/pro-gate-stats.sh"
put "$SOURCE_ROOT/bin/cdp-salvage.mjs" "$PRO_GATE_HOME/cdp-salvage.mjs"
for f in daemon.sh run-daemon.sh run-oracle-chrome.sh login-view.sh; do put "$SOURCE_ROOT/daemon/$f" "$PRO_GATE_HOME/$f"; done
[ -f "$PRO_GATE_HOME/.env" ] || cp "$SOURCE_ROOT/.env.example" "$PRO_GATE_HOME/.env"
printf '%s\n' "$REQUESTED_VERSION" > "$PRO_GATE_HOME/VERSION.deploy.$$"
mv -f "$PRO_GATE_HOME/VERSION.deploy.$$" "$PRO_GATE_HOME/VERSION"
printf '%s\n' "$REQUESTED_VERSION" > "$PRO_GATE_HOME/EXPECTED_VERSION.deploy.$$"
mv -f "$PRO_GATE_HOME/EXPECTED_VERSION.deploy.$$" "$PRO_GATE_HOME/EXPECTED_VERSION"
{ pg_file_sig "$PRO_GATE_HOME/daemon.sh" "$PRO_GATE_HOME/lib.sh" "$PRO_GATE_HOME/run-daemon.sh" > "$PRO_GATE_HOME/.deploy-stamp.tmp" && mv -f "$PRO_GATE_HOME/.deploy-stamp.tmp" "$PRO_GATE_HOME/.deploy-stamp"; } 2>/dev/null || true
render(){ sed -e "s#@HOME@#${HOME}#g" -e "s#@USER@#$(id -un)#g" "$1"; }
case "$OS" in
  macos)
    PL="$HOME/Library/LaunchAgents/com.pro-gate.review-daemon.plist"
    if [ "$INSTALL_DAEMON" = 1 ]; then
      mkdir -p "$(dirname "$PL")"
      render "$SOURCE_ROOT/daemon/com.pro-gate.review-daemon.plist.tmpl" > "$PL"
      launchctl unload "$PL" 2>/dev/null || true
      launchctl load "$PL"
    else
      launchctl unload "$PL" 2>/dev/null || true
    fi
    ;;
  wsl|linux)
    if [ "$SVC" = systemd ]; then
      render "$SOURCE_ROOT/daemon/oracle-chrome.service.tmpl" | sudo tee /etc/systemd/system/oracle-chrome.service >/dev/null
      if [ "$INSTALL_DAEMON" = 1 ]; then
        render "$SOURCE_ROOT/daemon/pro-review-daemon.service.tmpl" | sudo tee /etc/systemd/system/pro-review-daemon.service >/dev/null
      fi
      sudo systemctl daemon-reload
      sudo systemctl enable --now oracle-chrome.service
      if [ "$INSTALL_DAEMON" = 1 ]; then
        sudo systemctl enable --now pro-review-daemon.service
      else
        sudo systemctl disable --now pro-review-daemon.service 2>/dev/null || true
      fi
    fi
    ;;
esac
DEPLOYING=0
printf 'pro-gate runtime %s installed in %s (daemon: %s)\n' "$REQUESTED_VERSION" "$PRO_GATE_HOME" "$INSTALL_DAEMON"
