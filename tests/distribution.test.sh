#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
check() { local name="$1"; shift; if "$@"; then echo "ok - $name"; else echo "FAIL - $name"; FAILS=$((FAILS + 1)); fi; }
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pro-gate-distribution.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
export PRO_GATE_SERVICE_MANAGER=none

check "plugin owns one skill" test "$(find "$ROOT/skills" -name SKILL.md -type f | wc -l)" -eq 1
check "plugin owns one agent" test "$(find "$ROOT/agents" -name oracle-reviewer.md -type f | wc -l)" -eq 1

OUT="$TDIR/dist"
RELEASE_TAG="v$VERSION" bash "$ROOT/scripts/package-runtime.sh" "$OUT" >/dev/null
ARCHIVE="$OUT/pro-gate-runtime-$VERSION.tar.gz"
CHECKSUM="$ARCHIVE.sha256"
check "package creates archive" test -s "$ARCHIVE"
check "package creates checksum" test -s "$CHECKSUM"
LIST="$TDIR/archive.list"; tar -tzf "$ARCHIVE" > "$LIST"
check "runtime package excludes skill" sh -c "! grep -q '/skills/' '$LIST'"
check "runtime package excludes agent" sh -c "! grep -q '/agents/' '$LIST'"
check "runtime package excludes plugin manifest" sh -c "! grep -q '/.claude-plugin/' '$LIST'"

HOME1="$TDIR/default-home"; RUNTIME1="$TDIR/default-runtime"; CLAUDE1="$HOME1/.claude"
mkdir -p "$HOME1" "$CLAUDE1"
HOME="$HOME1" CLAUDE_DIR="$CLAUDE1" PRO_GATE_HOME="$RUNTIME1" \
  bash "$ROOT/install.sh" --version "$VERSION" --archive "$ARCHIVE" --checksum "$CHECKSUM" >"$TDIR/default.log" 2>&1
check "runtime records installed version" test "$(cat "$RUNTIME1/VERSION")" = "$VERSION"
check "runtime records expected version" test "$(cat "$RUNTIME1/EXPECTED_VERSION")" = "$VERSION"
check "runtime install does not duplicate skill" test ! -e "$CLAUDE1/skills/pro-gate/SKILL.md"
check "runtime install does not duplicate agent" test ! -e "$CLAUDE1/agents/oracle-reviewer.md"
check "daemon defaults off" grep -q 'daemon: 0' "$TDIR/default.log"

LOCK_HOME="$TDIR/lock-home"; LOCK_RUNTIME="$TDIR/lock-runtime"
mkdir -p "$LOCK_HOME" "$LOCK_RUNTIME/.install.lock.d"
if HOME="$LOCK_HOME" PRO_GATE_HOME="$LOCK_RUNTIME" PRO_GATE_BROWSER_MODE=native PRO_GATE_FORCE_PORTABLE_LOCK=1 \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/lock-loser.log" 2>&1; then
  echo "FAIL - concurrent installer loses the portable lock"; FAILS=$((FAILS + 1))
else echo "ok - concurrent installer loses the portable lock"; fi
check "losing installer preserves winning lock" test -d "$LOCK_RUNTIME/.install.lock.d"

LIVE_LOCK_RUNTIME="$TDIR/live-lock-runtime"; mkdir -p "$LIVE_LOCK_RUNTIME/.install.lock.d"
LIVE_START="$(ps -o lstart= -p "$$" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
printf '%s %s\n' "$$" "$LIVE_START" > "$LIVE_LOCK_RUNTIME/.install.lock.d/owner"
if HOME="$LOCK_HOME" PRO_GATE_HOME="$LIVE_LOCK_RUNTIME" PRO_GATE_BROWSER_MODE=native PRO_GATE_FORCE_PORTABLE_LOCK=1 \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/live-lock.log" 2>&1; then
  echo "FAIL - live portable lock blocks concurrent installer"; FAILS=$((FAILS + 1))
else echo "ok - live portable lock blocks concurrent installer"; fi
check "loser preserves live lock owner" grep -q "^$$ " "$LIVE_LOCK_RUNTIME/.install.lock.d/owner"

STALE_LOCK_RUNTIME="$TDIR/stale-lock-runtime"; mkdir -p "$STALE_LOCK_RUNTIME/.install.lock.d"
printf '999999 Mon Jan 1 00:00:00 2001\n' > "$STALE_LOCK_RUNTIME/.install.lock.d/owner"
HOME="$LOCK_HOME" PRO_GATE_HOME="$STALE_LOCK_RUNTIME" PRO_GATE_BROWSER_MODE=native PRO_GATE_FORCE_PORTABLE_LOCK=1 \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/stale-lock.log" 2>&1
check "stale portable lock is reclaimed" test "$(cat "$STALE_LOCK_RUNTIME/VERSION")" = "$VERSION"
check "successful install releases reclaimed lock" test ! -e "$STALE_LOCK_RUNTIME/.install.lock.d"

RACE_RUNTIME="$TDIR/race-lock-runtime"; RACE_BIN="$TDIR/race-bin"
mkdir -p "$RACE_RUNTIME/.install.lock.d" "$RACE_BIN"
printf '999999 Mon Jan 1 00:00:00 2001\n' > "$RACE_RUNTIME/.install.lock.d/owner"
REAL_MV="$(command -v mv)"
cat > "$RACE_BIN/mv" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "$RACE_LOCKDIR" ] && [ ! -e "$RACE_RELEASE" ]; then
  : > "$RACE_READY"
  while [ ! -e "$RACE_RELEASE" ]; do sleep 0.01; done
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$RACE_BIN/mv"
RACE_LOCKDIR="$RACE_RUNTIME/.install.lock.d" RACE_READY="$TDIR/race.ready" RACE_RELEASE="$TDIR/race.release" REAL_MV="$REAL_MV" \
  HOME="$LOCK_HOME" PRO_GATE_HOME="$RACE_RUNTIME" PRO_GATE_BROWSER_MODE=native PRO_GATE_FORCE_PORTABLE_LOCK=1 PATH="$RACE_BIN:$PATH" \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/race-winner.log" 2>&1 & RACE_WINNER_PID=$!
for _ in $(seq 1 500); do [ -e "$TDIR/race.ready" ] && break; sleep 0.01; done
check "first stale-lock reclaimer reaches serialized section" test -e "$TDIR/race.ready"
if RACE_LOCKDIR="$RACE_RUNTIME/.install.lock.d" RACE_READY="$TDIR/race-loser.ready" RACE_RELEASE="$TDIR/race.release" REAL_MV="$REAL_MV" \
  HOME="$LOCK_HOME" PRO_GATE_HOME="$RACE_RUNTIME" PRO_GATE_BROWSER_MODE=native PRO_GATE_FORCE_PORTABLE_LOCK=1 PATH="$RACE_BIN:$PATH" \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/race-loser.log" 2>&1; then
  echo "FAIL - concurrent stale-lock reclaimer is rejected"; FAILS=$((FAILS + 1))
else echo "ok - concurrent stale-lock reclaimer is rejected"; fi
: > "$TDIR/race.release"
RACE_WINNER_STATUS=0
wait "$RACE_WINNER_PID" || RACE_WINNER_STATUS=$?
check "exactly one stale-lock reclaimer installs" test "$RACE_WINNER_STATUS" -eq 0
check "stale-lock race leaves no portable lock" test ! -e "$RACE_RUNTIME/.install.lock.d"
check "stale-lock race leaves no reaper lock" test ! -e "$RACE_RUNTIME/.install.lock.reaper"

KILL_RUNTIME="$TDIR/killed-reaper-runtime"; KILL_BIN="$TDIR/killed-reaper-bin"
mkdir -p "$KILL_RUNTIME/.install.lock.d" "$KILL_BIN"
printf '999999 Mon Jan 1 00:00:00 2001\n' > "$KILL_RUNTIME/.install.lock.d/owner"
cat > "$KILL_BIN/mv" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "$KILL_LOCKDIR" ]; then
  parent="$PPID"
  : > "$KILL_READY"
  while kill -0 "$parent" 2>/dev/null; do sleep 0.1; done
  exit 137
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$KILL_BIN/mv"
KILL_LOCKDIR="$KILL_RUNTIME/.install.lock.d" KILL_READY="$TDIR/killed-reaper.ready" REAL_MV="$REAL_MV" \
  HOME="$LOCK_HOME" PRO_GATE_HOME="$KILL_RUNTIME" PRO_GATE_BROWSER_MODE=native PRO_GATE_FORCE_PORTABLE_LOCK=1 PATH="$KILL_BIN:$PATH" \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/killed-reaper.log" 2>&1 & KILL_PID=$!
for _ in $(seq 1 500); do [ -e "$TDIR/killed-reaper.ready" ] && break; sleep 0.01; done
check "reclaimer reaches crash window" test -e "$TDIR/killed-reaper.ready"
kill -KILL "$KILL_PID"
wait "$KILL_PID" 2>/dev/null || true
HOME="$LOCK_HOME" PRO_GATE_HOME="$KILL_RUNTIME" PRO_GATE_BROWSER_MODE=native PRO_GATE_FORCE_PORTABLE_LOCK=1 \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/killed-reaper-recovery.log" 2>&1
check "dead reaper owner is recovered" test "$(cat "$KILL_RUNTIME/VERSION")" = "$VERSION"
check "dead reaper recovery leaves no locks" sh -c "! find '$KILL_RUNTIME' -maxdepth 1 -name '.install.lock.*' -type d | grep -q ."

OWNERLESS_RUNTIME="$TDIR/ownerless-reaper-runtime"; mkdir -p "$OWNERLESS_RUNTIME/.install.lock.d" "$OWNERLESS_RUNTIME/.install.lock.reaper"
printf '999999 Mon Jan 1 00:00:00 2001\n' > "$OWNERLESS_RUNTIME/.install.lock.d/owner"
HOME="$LOCK_HOME" PRO_GATE_HOME="$OWNERLESS_RUNTIME" PRO_GATE_BROWSER_MODE=native PRO_GATE_FORCE_PORTABLE_LOCK=1 \
  PRO_GATE_PORTABLE_LOCK_GRACE_SECONDS=0 bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/ownerless-reaper.log" 2>&1
check "aged ownerless reaper is recovered" test "$(cat "$OWNERLESS_RUNTIME/VERSION")" = "$VERSION"

check "reviewer agent enforces exact runtime" grep -q 'PRO_GATE_EXPECTED_VERSION=' "$ROOT/agents/oracle-reviewer.md"
check "reviewer agent rejects invalid plugin versions" grep -q 'could not resolve a valid plugin version' "$ROOT/agents/oracle-reviewer.md"
check "reviewer commands resolve runtime independently" test "$(grep -c '\${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh' "$ROOT/agents/oracle-reviewer.md")" -ge 2
check "reviewer agent has no cross-shell runtime dependency" sh -c "! grep -q '\$RUNTIME_HOME/oracle-review.sh' '$ROOT/agents/oracle-reviewer.md'"
check "reviewer agent has no hardcoded engine home" sh -c "! grep -q '~/.pro-review-daemon/oracle-review.sh' '$ROOT/agents/oracle-reviewer.md'"

REVIEW_RUNTIME="$TDIR/reviewer-runtime"; mkdir -p "$REVIEW_RUNTIME"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$REVIEW_LOG"\n' > "$REVIEW_RUNTIME/oracle-review.sh"
chmod +x "$REVIEW_RUNTIME/oracle-review.sh"
PRO_GATE_HOME="$REVIEW_RUNTIME" REVIEW_LOG="$TDIR/reviewer.log" bash -c '"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/oracle-review.sh" --pr 22'
REVIEW_OUT="$TDIR/oracle-reviewer-pr-22.md"
printf '{"marker":"pg-run-22-1700000000-1"}\n' > "$REVIEW_OUT.status"
PRO_GATE_HOME="$REVIEW_RUNTIME" REVIEW_LOG="$TDIR/reviewer.log" OUT="$REVIEW_OUT" bash -c '
  OUT="${OUT}"
  MARKER="$(jq -r '\''.marker // empty'\'' "$OUT.status" 2>/dev/null || sed -nE '\''s/.*"marker":"([^"]+)".*/\1/p'\'' "$OUT.status")"
  case "$MARKER" in pg-run-[A-Za-z0-9.-]*) ;; *) exit 1;; esac
  "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/oracle-review.sh" --harvest "$MARKER" --out "$OUT" --timeout 20m
'
check "separate reviewer shells use configured runtime" test "$(wc -l < "$TDIR/reviewer.log")" -eq 2
check "harvest shell reconstructs marker and output" grep -q -- '--harvest pg-run-22-1700000000-1.*--out .*oracle-reviewer-pr-22.md' "$TDIR/reviewer.log"

HOSTILE="$TDIR/hostile-cwd"; mkdir -p "$HOSTILE/lib"
printf 'hostile\n' > "$HOSTILE/VERSION"
printf 'exit 99\n' > "$HOSTILE/lib/pro-gate-lib.sh"
# A permanently unpublished version keeps this hermetic: the piped installer
# must resolve only the published runtime release, so once "$VERSION" is
# actually released the download would succeed and invert the assertion.
if (cd "$HOSTILE" && PRO_GATE_HOME="$TDIR/piped-runtime" bash -s -- --version 0.0.0 < "$ROOT/install.sh") >"$TDIR/piped.log" 2>&1; then
  echo "FAIL - piped installer does not infer hostile cwd source"; FAILS=$((FAILS + 1))
else echo "ok - piped installer does not infer hostile cwd source"; fi
check "piped installer did not execute hostile source" test ! -e "$TDIR/piped-runtime/VERSION"

HOME_LOCAL="$TDIR/local-home"; RUNTIME_LOCAL="$TDIR/local-runtime"; mkdir -p "$HOME_LOCAL"
HOME="$HOME_LOCAL" PRO_GATE_HOME="$RUNTIME_LOCAL" PRO_GATE_BROWSER_MODE=native \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/local.log" 2>&1
check "explicit local source installs source tree" test "$(cat "$RUNTIME_LOCAL/VERSION")" = "$VERSION"
if bash -s -- --local-source --version "$VERSION" < "$ROOT/install.sh" >"$TDIR/piped-local.log" 2>&1; then
  echo "FAIL - piped local source is rejected"; FAILS=$((FAILS + 1))
else echo "ok - piped local source is rejected"; fi
check "piped local source names real file requirement" grep -q 'real regular on-disk file' "$TDIR/piped-local.log"

SVC_BIN="$TDIR/service-bin"; SVC_LOG="$TDIR/service.log"; mkdir -p "$SVC_BIN"
printf '#!/usr/bin/env bash\nprintf "sudo %%s\\n" "$*" >> "$SVC_LOG"\nif [ "$1" = tee ]; then cat >/dev/null; fi\n' > "$SVC_BIN/sudo"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SVC_BIN/systemctl"
chmod +x "$SVC_BIN/sudo" "$SVC_BIN/systemctl"
HOME="$TDIR/service-home" PRO_GATE_HOME="$TDIR/service-runtime" PRO_GATE_SERVICE_MANAGER=systemd \
  SVC_LOG="$SVC_LOG" PATH="$SVC_BIN:$PATH" \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/service-install.log" 2>&1
check "normal systemd install enables Chrome" grep -q 'systemctl enable --now oracle-chrome.service' "$SVC_LOG"
check "normal systemd install disables daemon" grep -q 'systemctl disable --now pro-review-daemon.service' "$SVC_LOG"
: > "$SVC_LOG"
HOME="$TDIR/service-home" PRO_GATE_HOME="$TDIR/service-runtime" PRO_GATE_CONSENT_HOME="$TDIR/service-consent" \
  PRO_GATE_SERVICE_MANAGER=systemd SVC_LOG="$SVC_LOG" PATH="$SVC_BIN:$PATH" \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" \
  --daemon --accept-dangerous-mode >"$TDIR/service-daemon.log" 2>&1
check "daemon install independently enables Chrome" grep -q 'systemctl enable --now oracle-chrome.service' "$SVC_LOG"
check "daemon install enables daemon service" grep -q 'systemctl enable --now pro-review-daemon.service' "$SVC_LOG"

MAC_BIN="$TDIR/mac-bin"; MAC_LOG="$TDIR/mac.log"; mkdir -p "$MAC_BIN"
printf '#!/usr/bin/env bash\nprintf "Darwin\\n"\n' > "$MAC_BIN/uname"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$MAC_LOG"\n' > "$MAC_BIN/launchctl"
chmod +x "$MAC_BIN/uname" "$MAC_BIN/launchctl"
HOME="$TDIR/mac-home" PRO_GATE_HOME="$TDIR/mac-runtime" PRO_GATE_SERVICE_MANAGER=launchd \
  MAC_LOG="$MAC_LOG" PATH="$MAC_BIN:$PATH" \
  bash "$ROOT/install.sh" --local-source --version "$VERSION" >"$TDIR/mac-install.log" 2>&1
check "macOS normal install unloads daemon" grep -q '^unload ' "$MAC_LOG"
check "macOS has no separate Chrome service" sh -c "! grep -q oracle-chrome '$MAC_LOG'"

printf 'sentinel\n' > "$RUNTIME1/oracle-review.sh"
cp "$ARCHIVE" "$TDIR/tampered.tar.gz"; printf 'tampered\n' >> "$TDIR/tampered.tar.gz"
if HOME="$HOME1" PRO_GATE_HOME="$RUNTIME1" bash "$ROOT/install.sh" --version "$VERSION" \
  --archive "$TDIR/tampered.tar.gz" --checksum "$CHECKSUM" >"$TDIR/tampered.log" 2>&1; then
  echo "FAIL - tampered checksum rejected"; FAILS=$((FAILS + 1))
else echo "ok - tampered checksum rejected"; fi
check "tampered archive leaves install untouched" grep -q '^sentinel$' "$RUNTIME1/oracle-review.sh"

HOME2="$TDIR/consent-home"; RUNTIME2="$TDIR/consent-runtime"; mkdir -p "$HOME2"
if HOME="$HOME2" PRO_GATE_HOME="$RUNTIME2" PRO_GATE_BROWSER_MODE=native \
  bash "$ROOT/install.sh" --version "$VERSION" --archive "$ARCHIVE" --checksum "$CHECKSUM" --daemon >"$TDIR/no-consent.log" 2>&1; then
  echo "FAIL - daemon refuses without consent"; FAILS=$((FAILS + 1))
else echo "ok - daemon refuses without consent"; fi
check "failed daemon enable leaves no runtime" test ! -e "$RUNTIME2/VERSION"

HOME3="$TDIR/guard-home"; RUNTIME3="$TDIR/guard-runtime"; CONSENT3="$TDIR/operator-state"; mkdir -p "$HOME3"
HOME="$HOME3" PRO_GATE_HOME="$RUNTIME3" PRO_GATE_CONSENT_HOME="$CONSENT3" \
  bash "$ROOT/install.sh" --version "$VERSION" --archive "$ARCHIVE" --checksum "$CHECKSUM" --accept-dangerous-mode >"$TDIR/consent.log" 2>&1
check "operator-global consent recorded" test "$(cat "$CONSENT3/dangerous-mode-consent")" = 1
PRO_GATE_HOME="$RUNTIME3" PRO_GATE_EXPECTED_VERSION="$VERSION" PRO_GATE_CONSENT_HOME="$CONSENT3" \
  PRO_GATE_BROWSER_MODE=native bash "$ROOT/bin/pro-gate-doctor.sh" >"$TDIR/doctor-consent.log" 2>&1 || true
check "doctor reports matching exact release" grep -q "runtime version $VERSION matches plugin" "$TDIR/doctor-consent.log"
check "doctor reports accepted disclosure" grep -q 'dangerous automatic-fixer disclosure accepted (consent v1)' "$TDIR/doctor-consent.log"
# issue #37: the version-mismatch message is DIRECTION-AWARE (runtime VERSION is $VERSION)
PRO_GATE_HOME="$RUNTIME3" PRO_GATE_EXPECTED_VERSION="99.99.99" PRO_GATE_CONSENT_HOME="$CONSENT3" \
  PRO_GATE_BROWSER_MODE=native bash "$ROOT/bin/pro-gate-doctor.sh" >"$TDIR/doctor-behind.log" 2>&1 || true
check "doctor names a BEHIND runtime (upgrade path)" grep -q "is BEHIND plugin 99.99.99" "$TDIR/doctor-behind.log"
PRO_GATE_HOME="$RUNTIME3" PRO_GATE_EXPECTED_VERSION="0.0.1" PRO_GATE_CONSENT_HOME="$CONSENT3" \
  PRO_GATE_BROWSER_MODE=native bash "$ROOT/bin/pro-gate-doctor.sh" >"$TDIR/doctor-ahead.log" 2>&1 || true
check "doctor flags an AHEAD runtime as a DOWNGRADE" grep -q "AHEAD of plugin 0.0.1" "$TDIR/doctor-ahead.log"
check "doctor AHEAD message warns DOWNGRADE" grep -q "DOWNGRADE the runtime" "$TDIR/doctor-ahead.log"
check "doctor AHEAD message gives safe relaunch guidance (#40)" grep -qi "RELAUNCH Claude Code" "$TDIR/doctor-ahead.log"
check "doctor AHEAD hint avoids chained slash commands" bash -c '! grep -q "/plugin uninstall" "$1"' _ "$TDIR/doctor-ahead.log"
printf '#!/usr/bin/env bash\nprintf "oracle-custom 7.8.9\\n"\n' > "$TDIR/oracle-custom"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$TIMEOUT_LOG"\nshift\n"$@"\n' > "$TDIR/timeout-custom"
chmod +x "$TDIR/oracle-custom" "$TDIR/timeout-custom"
TIMEOUT_LOG="$TDIR/timeout.log" PRO_GATE_ORACLE_BIN="$TDIR/oracle-custom" PRO_GATE_TIMEOUT_BIN="$TDIR/timeout-custom" \
  PRO_GATE_HOME="$RUNTIME3" PRO_GATE_EXPECTED_VERSION="$VERSION" PRO_GATE_CONSENT_HOME="$CONSENT3" \
  PRO_GATE_BROWSER_MODE=native bash "$ROOT/bin/pro-gate-doctor.sh" >"$TDIR/doctor-custom.log" 2>&1 || true
check "doctor uses configured oracle for version" grep -q 'oracle installed (oracle-custom 7.8.9)' "$TDIR/doctor-custom.log"
check "doctor uses configured timeout" grep -q "$TDIR/oracle-custom --version" "$TDIR/timeout.log"
PRO_GATE_ORACLE_BIN="$TDIR/missing-oracle" PRO_GATE_TIMEOUT_BIN="$TDIR/missing-timeout" \
  PRO_GATE_HOME="$RUNTIME3" PRO_GATE_BROWSER_MODE=native bash "$ROOT/bin/pro-gate-doctor.sh" >"$TDIR/doctor-missing-bin.log" 2>&1 || true
check "doctor reports configured oracle missing" grep -q "configured oracle command missing: $TDIR/missing-oracle" "$TDIR/doctor-missing-bin.log"
check "doctor reports configured timeout missing" grep -q "configured timeout command missing: $TDIR/missing-timeout" "$TDIR/doctor-missing-bin.log"
HOME="$HOME3" PRO_GATE_HOME="$RUNTIME3" PRO_GATE_CONSENT_HOME="$CONSENT3" PRO_GATE_BROWSER_MODE=native \
  bash "$ROOT/daemon/daemon.sh" >"$TDIR/daemon-ok.log" 2>&1 & DPID=$!
sleep 0.3
check "valid consent passes daemon guard" kill -0 "$DPID"
kill "$DPID" 2>/dev/null || true
HOME="$HOME3" PRO_GATE_HOME="$RUNTIME3" PRO_GATE_CONSENT_HOME="$CONSENT3" PRO_GATE_CONSENT_VERSION=2 \
  PRO_REVIEW_OWNERS=fake PRO_REVIEW_POLL_SECONDS=1 PRO_GATE_BROWSER_MODE=native \
  bash "$ROOT/daemon/daemon.sh" >"$TDIR/stale.log" 2>&1 & DPID=$!
sleep 0.3
check "stale consent globally defers without exiting" kill -0 "$DPID"
check "stale consent does not charge per-PR failure" test ! -s "$RUNTIME3/failcount.tsv"
kill "$DPID" 2>/dev/null || true
printf '0.0.0\n' > "$RUNTIME3/EXPECTED_VERSION"
HOME="$HOME3" PRO_GATE_HOME="$RUNTIME3" PRO_GATE_CONSENT_HOME="$CONSENT3" PRO_REVIEW_OWNERS=fake \
  PRO_REVIEW_POLL_SECONDS=1 PRO_GATE_BROWSER_MODE=native bash "$ROOT/daemon/daemon.sh" >"$TDIR/mismatch.log" 2>&1 & DPID=$!
sleep 0.3
check "runtime mismatch globally defers without exiting" kill -0 "$DPID"
kill "$DPID" 2>/dev/null || true
check "mismatch route names exact release" grep -q 'exact plugin release' "$TDIR/mismatch.log"
check "runtime mismatch is global deferred state" grep -q 'globally deferring PR processing' "$TDIR/mismatch.log"

MISSING="$TDIR/missing-runtime"; mkdir -p "$MISSING"
if PRO_GATE_HOME="$MISSING" PRO_GATE_EXPECTED_VERSION="$VERSION" bash "$ROOT/bin/pro-gate-doctor.sh" >"$TDIR/missing.log" 2>&1; then
  echo "FAIL - doctor blocks missing runtime"; FAILS=$((FAILS + 1))
else echo "ok - doctor blocks missing runtime"; fi
check "missing route names exact release setup" grep -q 'exact plugin release' "$TDIR/missing.log"

for mismatch in tag manifest runtime; do
  COPY="$TDIR/mismatch-$mismatch"; cp -a "$ROOT" "$COPY"
  TAG="v$VERSION"
  case "$mismatch" in
    tag) TAG=v9.9.9 ;;
    manifest) python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["version"]="9.9.9"; open(p,"w").write(json.dumps(d))' "$COPY/.claude-plugin/plugin.json" ;;
    runtime) printf '9.9.9\n' > "$COPY/VERSION" ;;
  esac
  if RELEASE_TAG="$TAG" bash "$COPY/scripts/package-runtime.sh" "$TDIR/bad-$mismatch" >"$TDIR/package-$mismatch.log" 2>&1; then
    echo "FAIL - packaging rejects $mismatch mismatch"; FAILS=$((FAILS + 1))
  else echo "ok - packaging rejects $mismatch mismatch"; fi
  check "packaging reports $mismatch mismatch" grep -q 'release version mismatch' "$TDIR/package-$mismatch.log"
done

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "$FAILS FAILURES"; exit 1
