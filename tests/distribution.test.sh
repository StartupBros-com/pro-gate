#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
check() { local name="$1"; shift; if "$@"; then echo "ok - $name"; else echo "FAIL - $name"; FAILS=$((FAILS + 1)); fi; }
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pro-gate-distribution.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

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
HOME="$HOME3" PRO_GATE_HOME="$RUNTIME3" PRO_GATE_CONSENT_HOME="$CONSENT3" PRO_GATE_BROWSER_MODE=native \
  bash "$ROOT/daemon/daemon.sh" >"$TDIR/daemon-ok.log" 2>&1 & DPID=$!
sleep 0.3
check "valid consent passes daemon guard" kill -0 "$DPID"
kill "$DPID" 2>/dev/null || true
if HOME="$HOME3" PRO_GATE_HOME="$RUNTIME3" PRO_GATE_CONSENT_HOME="$CONSENT3" PRO_GATE_CONSENT_VERSION=2 \
  PRO_GATE_BROWSER_MODE=native bash "$ROOT/daemon/daemon.sh" >"$TDIR/stale.log" 2>&1; then
  echo "FAIL - stale consent blocks daemon"; FAILS=$((FAILS + 1))
else echo "ok - stale consent blocks daemon"; fi
printf '0.0.0\n' > "$RUNTIME3/EXPECTED_VERSION"
if HOME="$HOME3" PRO_GATE_HOME="$RUNTIME3" PRO_GATE_CONSENT_HOME="$CONSENT3" PRO_GATE_BROWSER_MODE=native \
  bash "$ROOT/daemon/daemon.sh" >"$TDIR/mismatch.log" 2>&1; then
  echo "FAIL - runtime mismatch blocks daemon"; FAILS=$((FAILS + 1))
else echo "ok - runtime mismatch blocks daemon"; fi
check "mismatch route names exact release" grep -q 'exact plugin release' "$TDIR/mismatch.log"

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
