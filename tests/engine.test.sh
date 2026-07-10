#!/usr/bin/env bash
# Engine-level regression tests for oracle-review.sh paths that need no ChatGPT account:
#   - oversized-diff guard (exit 11, phase oversized, no slot spent)
#   - --harvest against a still-generating conversation (exit 9, phase in-progress, tab kept)
#   - --harvest against a completed conversation (exit 0, phase done, review written)
#   - --harvest with no matching conversation (exit 6, phase failed)
# Uses tests/mock-cdp.mjs as the browser. Run: bash tests/engine.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/../bin/oracle-review.sh"
FAILS=0
check() { # name condition-result detail
  if [ "$2" = 0 ]; then echo "ok - $1"; else echo "FAIL - $1: ${3:-}"; FAILS=$((FAILS + 1)); fi
}
phase_of() { jq -r .phase "$1" 2>/dev/null || sed -nE 's/.*"phase":"([^"]+)".*/\1/p' "$1"; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-engine-test.XXXXXX")"
trap 'kill "${MOCK_PID:-0}" 2>/dev/null; rm -rf "$TDIR"' EXIT
mkdir -p "$TDIR/home"

start_mock() { # $1 = tab text file; sets MOCK_PID + PORT
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
  node "$HERE/mock-cdp.mjs" "$1" > "$TDIR/port" 2>"$TDIR/mock.log" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do [ -s "$TDIR/port" ] && break; sleep 0.1; done
  PORT="$(tr -d '[:space:]' < "$TDIR/port")"; : > "$TDIR/port"
}

MARKER="pg-run-77-1700000000-11"
run_engine() { # args... ; captures RC
  PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
    PRO_GATE_SELF_HEAL=0 bash "$ENGINE" "$@" >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
}

echo '# oversized diff guard'
printf 'still thinking, run marker: %s\n' "$MARKER" > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
seq 1 6500 | sed 's/^/+/' > "$TDIR/huge.diff"
run_engine --diff "$TDIR/huge.diff" --repo "$TDIR" --out "$TDIR/o-big.md" --timeout 5m
check 'oversized diff exits 11' "$([ "$RC" -eq 11 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
check 'oversized status phase' "$([ "$(phase_of "$TDIR/o-big.md.status")" = oversized ]; echo $?)" "$(cat "$TDIR/o-big.md.status" 2>/dev/null)"
check 'oversized spends nothing' "$([ ! -s "$TDIR/o-big.md" ]; echo $?)" 'out file exists'

echo '# harvest: still generating'
run_engine --harvest "$MARKER" --out "$TDIR/o-h1.md" --timeout 5s
check 'harvest in-progress exits 9' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'harvest in-progress phase' "$([ "$(phase_of "$TDIR/o-h1.md.status")" = in-progress ]; echo $?)" "$(cat "$TDIR/o-h1.md.status" 2>/dev/null)"
check 'harvest keeps the tab' "$(! grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "$(cat "$TDIR/mock.log")"
check 'status carries the marker' "$(grep -qF "\"marker\":\"$MARKER\"" "$TDIR/o-h1.md.status"; echo $?)" "$(cat "$TDIR/o-h1.md.status" 2>/dev/null)"
check 'in-progress writes durable reservation' "$([ -f "$TDIR/home/in-progress/$MARKER" ]; echo $?)" "reservation missing"

# A fresh same-PR invocation must NOT launch a second oracle request while the reserved tab is
# active. It redirects to harvest (exit 9) before acquiring/spending a slot.
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n+small\n' > "$TDIR/small.diff"
run_engine --pr 77 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$TDIR/o-redirect.md" --timeout 5m
check 'same-PR reservation blocks fresh spend' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'same-PR redirect exposes original marker' "$(grep -qF "$MARKER" "$TDIR/stderr"; echo $?)" "$(cat "$TDIR/stderr")"

echo '# harvest: review completed'
{ printf 'run marker: %s\n' "$MARKER"
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean enough.\n'
} > "$TDIR/tab.txt"
run_engine --harvest "$MARKER" --out "$TDIR/o-h2.md" --timeout 30s
check 'harvest done exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'harvest done phase' "$([ "$(phase_of "$TDIR/o-h2.md.status")" = done ]; echo $?)" "$(cat "$TDIR/o-h2.md.status" 2>/dev/null)"
check 'harvest writes the review' "$(grep -q 'VERDICT: SHIP' "$TDIR/o-h2.md"; echo $?)" "$(head -c 200 "$TDIR/o-h2.md" 2>/dev/null)"
check 'harvest closes the tab' "$(grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "$(cat "$TDIR/mock.log")"
check 'successful harvest releases reservation' "$([ ! -f "$TDIR/home/in-progress/$MARKER" ]; echo $?)" "reservation leaked"

echo '# harvest: conversation gone'
printf 'run marker: pg-run-999-1700000001-99\nforeign conversation\n' > "$TDIR/tab.txt"
run_engine --harvest "$MARKER" --out "$TDIR/o-h3.md" --timeout 5s
check 'harvest lost exits 6' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC"
check 'harvest lost phase failed' "$([ "$(phase_of "$TDIR/o-h3.md.status")" = failed ]; echo $?)" "$(cat "$TDIR/o-h3.md.status" 2>/dev/null)"

echo '# harvest: deferred under cooldown'
touch "$TDIR/home/throttle.cooldown"
run_engine --harvest "$MARKER" --out "$TDIR/o-h4.md" --timeout 5s
check 'harvest cooldown exits 8' "$([ "$RC" -eq 8 ]; echo $?)" "rc=$RC"
check 'harvest cooldown phase deferred' "$([ "$(phase_of "$TDIR/o-h4.md.status")" = deferred ]; echo $?)" "$(cat "$TDIR/o-h4.md.status" 2>/dev/null)"
rm -f "$TDIR/home/throttle.cooldown"

echo '# primary run: hard cap -> live probe -> final salvage -> exit 9'
# Fake oracle emits the submission evidence, updates the mock tab to carry the engine-generated
# marker from its prompt, then sleeps until coreutils timeout kills it. This drives the actual
# fresh-run path (not just --harvest) without touching ChatGPT.
mkdir -p "$TDIR/bin"
cat > "$TDIR/bin/oracle" <<'FAKE_ORACLE'
#!/usr/bin/env bash
prompt=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in -p) prompt="$2"; shift 2;; --write-output) out="$2"; shift 2;; *) shift;; esac
done
marker="$(printf '%s' "$prompt" | sed -nE 's/.*run marker: (pg-run-[A-Za-z0-9.-]+).*/\1/p' | tail -1)"
printf 'run marker: %s\nReasoning continuously; no verdict yet.\n' "$marker" > "$PG_TEST_TAB_FILE"
echo 'Launching browser mode'
echo 'Acquired ChatGPT browser slot'
echo 'Session: fake-primary-run'
sleep 30
FAKE_ORACLE
chmod +x "$TDIR/bin/oracle"
printf 'waiting for fake submission\n' > "$TDIR/tab.txt"
rm -rf "$TDIR/home/in-progress"; : > "$TDIR/mock.log"
PRIMARY_PATH="$TDIR/bin:$PATH"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_MAX_DIFF_LINES=6000 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_TIMEOUT_GRACE=0 PRO_GATE_STALL_SECS=5 PRO_GATE_NOTHINK_SECS=5 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle" PG_TEST_TAB_FILE="$TDIR/tab.txt" PATH="$PRIMARY_PATH" NODE_OPTIONS= \
  bash "$ENGINE" --pr 88 --repo "$TDIR" --diff "$TDIR/small.diff" \
    --out "$TDIR/o-primary.md" --timeout 2s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
PRIMARY_MARKER="$(jq -r .marker "$TDIR/o-primary.md.status" 2>/dev/null)"
check 'primary run exits 9' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -4 "$TDIR/stderr")"
check 'primary run status in-progress' "$([ "$(phase_of "$TDIR/o-primary.md.status")" = in-progress ]; echo $?)" "$(cat "$TDIR/o-primary.md.status")"
check 'primary run carries generated marker' "$([ -n "$PRIMARY_MARKER" ] && [ "$PRIMARY_MARKER" != null ]; echo $?)" "marker=$PRIMARY_MARKER"
check 'primary run reserves capacity' "$([ -f "$TDIR/home/in-progress/$PRIMARY_MARKER" ]; echo $?)" "reservation missing"
check 'primary run keeps its tab' "$(! grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "$(cat "$TDIR/mock.log")"

# Clean the primary reservation/tab fixture before the ledger assertion.
rm -f "$TDIR/home/in-progress/$PRIMARY_MARKER"

echo '# ledger outcomes'
check 'ledger has oversized + in-progress rows' \
  "$(grep -q '"outcome":"oversized"' "$TDIR/home/ledger.jsonl" && grep -q '"outcome":"in-progress"' "$TDIR/home/ledger.jsonl"; echo $?)" \
  "$(cat "$TDIR/home/ledger.jsonl" 2>/dev/null)"

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILURES"; exit 1; }
