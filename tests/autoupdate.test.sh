#!/usr/bin/env bash
# Tests for bin/pro-gate-autoupdate.sh: the runtime follows the ACTIVE installed marketplace
# plugin version (installed_plugins.json, real Claude Code layout) through the exact-version
# installer, fail-closed on consent and identity problems, services never touched.
# Run: bash tests/autoupdate.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../bin/pro-gate-autoupdate.sh"
FAILS=0
check() { if [ "$2" = 0 ]; then echo "ok - $1"; else echo "FAIL - $1: ${3:-}"; FAILS=$((FAILS + 1)); fi; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-autoupdate-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT

# Inherited operator config must not leak into fixture runs.
while IFS='=' read -r name _; do
  case "$name" in PRO_GATE_*|ORACLE_*|INSTALL_*) unset "$name" ;; esac
done < <(env)

mkdir -p "$TDIR/home" "$TDIR/plugins/cache" "$TDIR/bin"

# Fake installer: records "version INSTALL_SKIP_SERVICES" and succeeds (or fails via marker).
cat > "$TDIR/bin/fake-installer" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${INSTALL_SKIP_SERVICES:-unset}" >> "${FAKE_INSTALL_LOG:?}"
[ ! -f "${FAKE_INSTALL_FAIL:-/nonexistent}" ]
FAKE
chmod +x "$TDIR/bin/fake-installer"

# Fake systemctl: is-enabled succeeds iff the marker file exists.
cat > "$TDIR/bin/fake-systemctl" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = is-enabled ] && [ -f "${FAKE_DAEMON_ENABLED:-/nonexistent}" ]
FAKE
chmod +x "$TDIR/bin/fake-systemctl"

# Fixtures mirror the REAL Claude Code layout (adversarial review P0: an invented layout let
# 16 tests pass on an inert feature): installed_plugins.json is the source of truth, and the
# cache keeps stale higher-versioned directories that must NOT win.
write_manifest() { # $1 = active pro-gate version ('' = no pro-gate entry)
  if [ -n "$1" ]; then
    cat > "$TDIR/plugins/installed_plugins.json" <<EOF
{"version": 2, "plugins": {
  "other-plugin@some-marketplace": [{"scope": "user", "installPath": "$TDIR/plugins/cache/some-marketplace/other-plugin/9.9.9", "version": "9.9.9"}],
  "pro-gate@hov": [{"scope": "user", "installPath": "$TDIR/plugins/cache/hov/pro-gate/$1", "version": "$1"}]
}}
EOF
  else
    printf '{"version": 2, "plugins": {"other-plugin@m": [{"version": "9.9.9"}]}}\n' > "$TDIR/plugins/installed_plugins.json"
  fi
}
seed_cache() { # $1 = version: a cache directory in the real <marketplace>/pro-gate/<version>/ shape
  mkdir -p "$TDIR/plugins/cache/hov/pro-gate/$1/.claude-plugin"
  printf '{"name":"pro-gate","version":"%s"}\n' "$1" > "$TDIR/plugins/cache/hov/pro-gate/$1/.claude-plugin/plugin.json"
}

run_updater() { # extra env pairs as args; RC captured
  : > "$TDIR/install.log"
  env PRO_GATE_HOME="$TDIR/home" PRO_GATE_PLUGIN_SEARCH_DIR="$TDIR/plugins" \
    PRO_GATE_AUTOUPDATE_INSTALLER="$TDIR/bin/fake-installer" \
    PRO_GATE_AUTOUPDATE_SYSTEMCTL="$TDIR/bin/fake-systemctl" \
    PRO_GATE_SERVICE_MANAGER=systemd \
    FAKE_INSTALL_LOG="$TDIR/install.log" "$@" \
    bash "$SCRIPT" >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
}

echo '# follow: manifest skew triggers the installer with services skipped'
printf '0.22.0\n' > "$TDIR/home/VERSION"
write_manifest 0.23.0
seed_cache 0.23.0
run_updater
check 'skew updates via installer (exit 0)' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
check 'installer got the plugin version and INSTALL_SKIP_SERVICES=1' "$([ "$(cat "$TDIR/install.log")" = '0.23.0 1' ]; echo $?)" "log=$(cat "$TDIR/install.log")"

echo '# no-op: versions equal'
printf '0.23.0\n' > "$TDIR/home/VERSION"
run_updater
check 'equal versions do nothing' "$([ "$RC" -eq 0 ] && [ ! -s "$TDIR/install.log" ]; echo $?)" "rc=$RC log=$(cat "$TDIR/install.log")"

echo '# the ACTIVE manifest version wins over stale higher-versioned cache copies'
seed_cache 0.31.0   # stale leftover: NOT in installed_plugins.json
printf '0.22.0\n' > "$TDIR/home/VERSION"
run_updater
check 'manifest (0.23.0) beats stale cache (0.31.0)' "$([ "$(cat "$TDIR/install.log")" = '0.23.0 1' ]; echo $?)" "log=$(cat "$TDIR/install.log")"

echo '# fallback without a manifest: real cache layout is matched'
rm -f "$TDIR/plugins/installed_plugins.json"
run_updater
check 'cache-layout fallback finds versions (<mkt>/pro-gate/<ver>/)' "$([ "$(cat "$TDIR/install.log")" = '0.31.0 1' ]; echo $?)" "log=$(cat "$TDIR/install.log")"
rm -rf "$TDIR/plugins/cache/hov/pro-gate/0.31.0"
write_manifest 0.23.0

echo '# fail closed: enabled daemon without recorded consent refuses the update'
printf '0.22.0\n' > "$TDIR/home/VERSION"
touch "$TDIR/daemon-enabled"
run_updater FAKE_DAEMON_ENABLED="$TDIR/daemon-enabled" PRO_GATE_CONSENT_HOME="$TDIR/no-consent"
check 'missing consent refuses (exit 3)' "$([ "$RC" -eq 3 ]; echo $?)" "rc=$RC"
check 'missing consent runs NO installer' "$([ ! -s "$TDIR/install.log" ]; echo $?)" "log=$(cat "$TDIR/install.log")"
check 'refusal names the disclosure' "$(grep -q 'accept the disclosure' "$TDIR/stderr"; echo $?)" "$(cat "$TDIR/stderr")"

echo '# consent recorded: enabled daemon does not block, services still skipped'
mkdir -p "$TDIR/consent"; printf '1\n' > "$TDIR/consent/dangerous-mode-consent"
run_updater FAKE_DAEMON_ENABLED="$TDIR/daemon-enabled" PRO_GATE_CONSENT_HOME="$TDIR/consent"
check 'consented daemon box updates (services skipped)' "$([ "$(cat "$TDIR/install.log")" = '0.23.0 1' ]; echo $?)" "log=$(cat "$TDIR/install.log")"
rm -f "$TDIR/daemon-enabled"

echo '# fail closed: non-semver plugin versions are never followed'
write_manifest '0.23.0-$(rm -rf /)'
printf '0.22.0\n' > "$TDIR/home/VERSION"
run_updater
check 'non-semver manifest version is ignored' "$([ "$RC" -eq 0 ] && [ ! -s "$TDIR/install.log" ]; echo $?)" "rc=$RC log=$(cat "$TDIR/install.log")"
write_manifest 0.23.0

echo '# downgrade follows the plugin and says so'
printf '0.25.0\n' > "$TDIR/home/VERSION"
run_updater
check 'downgrade runs the installer' "$([ "$(cat "$TDIR/install.log")" = '0.23.0 1' ]; echo $?)" "log=$(cat "$TDIR/install.log")"
check 'downgrade is loudly logged' "$(grep -q 'DOWNGRADE' "$TDIR/stderr"; echo $?)" "$(cat "$TDIR/stderr")"

echo '# failure streak: three consecutive failures escalate; success clears'
printf '0.22.0\n' > "$TDIR/home/VERSION"
touch "$TDIR/fail-marker"
run_updater FAKE_INSTALL_FAIL="$TDIR/fail-marker"
check 'installer failure exits 5' "$([ "$RC" -eq 5 ]; echo $?)" "rc=$RC"
run_updater FAKE_INSTALL_FAIL="$TDIR/fail-marker"
run_updater FAKE_INSTALL_FAIL="$TDIR/fail-marker"
check 'third failure escalates' "$(grep -q 'ESCALATION: 3 consecutive' "$TDIR/stderr"; echo $?)" "$(cat "$TDIR/stderr")"
check 'streak recorded in state file' "$([ "$(awk -F'\t' 'NR==1{print $1}' "$TDIR/home/autoupdate.state")" = 3 ]; echo $?)" "$(cat "$TDIR/home/autoupdate.state" 2>/dev/null)"
DOCTOR_OUT="$(timeout 90 env PRO_GATE_HOME="$TDIR/home" PRO_GATE_SERVICE_MANAGER=none PRO_GATE_SELF_HEAL=0 bash "$HERE/../bin/pro-gate-doctor.sh" 2>/dev/null || true)"
check 'doctor flags the failure streak' "$(printf '%s' "$DOCTOR_OUT" | grep -q 'auto-update has failed 3 times'; echo $?)" "$DOCTOR_OUT"
rm -f "$TDIR/fail-marker"
run_updater
check 'success clears the failure streak' "$([ "$RC" -eq 0 ] && [ ! -f "$TDIR/home/autoupdate.state" ]; echo $?)" "rc=$RC"

echo '# no plugin installed: nothing to follow'
write_manifest ''
run_updater
check 'no pro-gate entry -> no-op exit 0' "$([ "$RC" -eq 0 ] && [ ! -s "$TDIR/install.log" ]; echo $?)" "rc=$RC"

echo '# identity pinning: other marketplaces and project scopes never move the runtime'
cat > "$TDIR/plugins/installed_plugins.json" <<'EOF'
{"version": 2, "plugins": {
  "pro-gate@other-marketplace": [{"scope": "user", "version": "0.30.0"}],
  "pro-gate@hov": [
    {"scope": "project", "projectPath": "/x", "version": "0.29.0"},
    {"scope": "user", "version": "0.23.0"}
  ]
}}
EOF
printf '0.22.0\n' > "$TDIR/home/VERSION"
run_updater
check 'pinned key + user scope wins (0.23.0, not 0.30.0 or 0.29.0)' "$([ "$(cat "$TDIR/install.log")" = '0.23.0 1' ]; echo $?)" "log=$(cat "$TDIR/install.log")"

echo '# a project-only install is NOT globally installed: never moves the machine-wide runtime'
cat > "$TDIR/plugins/installed_plugins.json" <<'EOF'
{"version": 2, "plugins": {
  "pro-gate@hov": [{"scope": "project", "projectPath": "/x", "version": "0.29.0"}]
}}
EOF
run_updater
check 'project-only entry -> nothing to follow (exit 0, no installer)' "$([ "$RC" -eq 0 ] && [ ! -s "$TDIR/install.log" ]; echo $?)" "rc=$RC log=$(cat "$TDIR/install.log")"

echo '# service template renders the actual PRO_GATE_HOME (custom-home installs)'
RENDERED="$(sed -e "s#@PRO_GATE_HOME@#/custom/rt-home#g" -e "s#@HOME@#/h#g" -e "s#@USER@#u#g" "$HERE/../daemon/pro-gate-autoupdate.service.tmpl")"
check 'unit ExecStart/Environment use the rendered runtime home' \
  "$(printf '%s' "$RENDERED" | grep -q 'ExecStart=/custom/rt-home/pro-gate-autoupdate.sh' \
     && printf '%s' "$RENDERED" | grep -q 'Environment=PRO_GATE_HOME=/custom/rt-home' \
     && ! printf '%s' "$RENDERED" | grep -q '@'; echo $?)" "$RENDERED"

echo '# fail closed: a corrupt manifest never falls back to the cache glob'
printf '{not json' > "$TDIR/plugins/installed_plugins.json"
run_updater
check 'corrupt manifest refuses (exit 4)' "$([ "$RC" -eq 4 ]; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
check 'corrupt manifest runs NO installer' "$([ ! -s "$TDIR/install.log" ]; echo $?)" "log=$(cat "$TDIR/install.log")"
write_manifest 0.23.0

echo '# legacy target installers (pre --skip-services) are refused, current ones accepted'
printf '#!/usr/bin/env bash\nINSTALL_DAEMON="${INSTALL_DAEMON:-0}"\n' > "$TDIR/legacy-install.sh"
LEGACY_RC="$(PRO_GATE_HOME="$TDIR/home" PRO_GATE_AUTOUPDATE_LIB=1 bash -c ". '$SCRIPT'; pgau_installer_supports_unattended '$TDIR/legacy-install.sh'"; echo $?)"
check 'probe rejects a pre-v0.23 installer' "$([ "$LEGACY_RC" -ne 0 ]; echo $?)" "rc=$LEGACY_RC"
CURRENT_RC="$(PRO_GATE_HOME="$TDIR/home" PRO_GATE_AUTOUPDATE_LIB=1 bash -c ". '$SCRIPT'; pgau_installer_supports_unattended '$HERE/../install.sh'"; echo $?)"
check 'probe accepts the current installer' "$([ "$CURRENT_RC" -eq 0 ]; echo $?)" "rc=$CURRENT_RC"

echo '# concurrency: a held lock skips the run'
if command -v flock >/dev/null 2>&1; then
  exec {ALFD}>>"$TDIR/home/autoupdate.lock"; flock -n "$ALFD"
  printf '0.22.0\n' > "$TDIR/home/VERSION"
  run_updater
  check 'held lock skips (exit 0, no installer)' "$([ "$RC" -eq 0 ] && [ ! -s "$TDIR/install.log" ]; echo $?)" "rc=$RC log=$(cat "$TDIR/install.log")"
  eval "exec ${ALFD}>&-"
else
  echo 'ok - held lock skips (exit 0, no installer) # SKIP no flock'
fi

echo '# activity lands in the audit log'
check 'autoupdate.log written' "$([ -s "$TDIR/home/logs/autoupdate.log" ]; echo $?)" "$(ls "$TDIR/home/logs" 2>/dev/null)"

echo '# install.sh --skip-services never reaches sudo/systemctl (deploy-only)'
SRC="$(cd "$HERE/.." && pwd)"
SS_HOME="$TDIR/ss-home"
env -i HOME="$TDIR" PATH="$TDIR/no-sudo-bin:/usr/bin:/bin" PRO_GATE_HOME="$SS_HOME" \
  bash "$SRC/install.sh" --local-source --skip-services >"$TDIR/ss.log" 2>&1
check 'skip-services install succeeds without sudo on PATH' "$([ $? -eq 0 ]; echo $?)" "$(tail -3 "$TDIR/ss.log")"
check 'skip-services deploys the runtime' "$([ -x "$SS_HOME/oracle-review.sh" ] && [ -x "$SS_HOME/pro-gate-autoupdate.sh" ]; echo $?)" "$(ls "$SS_HOME" 2>/dev/null | head -5)"

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILURES"; exit 1; }
