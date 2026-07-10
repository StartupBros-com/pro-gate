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
# active. It redirects to harvest (exit 9) before acquiring/spending a slot. The reservation is
# keyed by repo-scoped PR_KEY (repo slug + number), so seed it exactly as a fresh run computes
# it for this checkout (no git remote here, so the slug falls back to the repo basename).
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n+small\n' > "$TDIR/small.diff"
PR_KEY_77="$(printf '%s-77' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf '%s\t%s\t%s\t0\t\n' "$PR_KEY_77" "$TDIR/o-h1.md" "$(date +%s)" > "$TDIR/home/in-progress/$MARKER"
run_engine --pr 77 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$TDIR/o-redirect.md" --timeout 5m
check 'same-PR reservation blocks fresh spend' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'same-PR redirect exposes original marker' "$(grep -qF "$MARKER" "$TDIR/stderr"; echo $?)" "$(cat "$TDIR/stderr")"
check 'redirect status publishes RESERVED marker' "$(grep -qF "\"marker\":\"$MARKER\"" "$TDIR/o-redirect.md.status"; echo $?)" "$(cat "$TDIR/o-redirect.md.status" 2>/dev/null)"

# Cross-repo isolation: the same PR NUMBER in a different checkout must not be redirected to
# this repository's reserved conversation (dogfood review P1: bare numbers collide).
mkdir -p "$TDIR/other-repo"
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n+small\n' > "$TDIR/other-repo/small.diff"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_LOCK_WAIT=4 PRO_GATE_ORACLE_BIN=/nonexistent-oracle NODE_OPTIONS= \
  bash "$ENGINE" --pr 77 --repo "$TDIR/other-repo" --diff "$TDIR/other-repo/small.diff" \
  --out "$TDIR/o-crossrepo.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'different repo same number is NOT redirected' "$([ "$RC" -ne 9 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"

# A single confirmed-absent reconciliation probe must retain the reservation. Three consecutive
# misses release it. A positive live probe resets the streak to zero.
echo '# reservation reconciliation miss threshold'
printf 'run marker: pg-run-999-1700000001-99\nforeign conversation\n' > "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home" PRO_GATE_RESERVATION_MISSES=3 PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_reconcile '$HERE/../bin/cdp-salvage.mjs' '$PORT'"
check 'first marker miss retains reservation' "$([ -f "$TDIR/home/in-progress/$MARKER" ]; echo $?)" 'reservation released on one miss'
check 'first marker miss records streak one' "$(awk -F'\t' 'NR==1{exit !($4==1)}' "$TDIR/home/in-progress/$MARKER"; echo $?)" "$(cat "$TDIR/home/in-progress/$MARKER")"
printf 'still thinking, run marker: %s\n' "$MARKER" > "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home" PRO_GATE_RESERVATION_MISSES=3 PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_reconcile '$HERE/../bin/cdp-salvage.mjs' '$PORT'"
check 'positive probe resets miss streak' "$(awk -F'\t' 'NR==1{exit !($4==0)}' "$TDIR/home/in-progress/$MARKER"; echo $?)" "$(cat "$TDIR/home/in-progress/$MARKER")"

echo '# marker validation'
run_engine --harvest 'pg-run-../../../etc/passwd' --out "$TDIR/o-trav.md" --timeout 5s
check 'traversal marker rejected with exit 2' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC"
check 'traversal marker creates no reservation state' "$(! find "$TDIR/home" -path '*etc*' | grep -q .; echo $?)" "$(find "$TDIR/home" -path '*etc*' 2>/dev/null)"

echo '# harvest lock serializes same marker'
# Hold the exact flock file used by --harvest; the second collector must exit 7 without touching
# the conversation or reservation.
mkdir -p "$TDIR/home/harvest-locks"
exec {HLFD}>>"$TDIR/home/harvest-locks/$MARKER"; flock -n "$HLFD"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_HARVEST_LOCK_WAIT=0 bash "$ENGINE" \
  --harvest "$MARKER" --out "$TDIR/o-hlock.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'concurrent same-marker harvest exits 7' "$([ "$RC" -eq 7 ]; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
check 'harvest lock status is terminal failed' "$([ "$(phase_of "$TDIR/o-hlock.md.status")" = failed ]; echo $?)" "$(cat "$TDIR/o-hlock.md.status")"
eval "exec ${HLFD}>&-"

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

echo '# slot plan: reservations exclude their slot instead of shrinking the range'
mkdir -p "$TDIR/home2/in-progress"
plan(){ PRO_GATE_HOME="$TDIR/home2" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_slot_plan $1"; }
printf 'k1\to1\t100\t0\t1\n' > "$TDIR/home2/in-progress/pg-run-a-1-1"
check 'tagged slot 1 at eff 2 excludes slot 1' "$([ "$(plan 2)" = '2|1' ]; echo $?)" "plan=$(plan 2)"
printf 'k2\to2\t100\t0\t\n' > "$TDIR/home2/in-progress/pg-run-b-2-2"
check 'legacy reservation shrinks the range' "$([ "$(plan 2)" = '1|1' ]; echo $?)" "plan=$(plan 2)"
rm -f "$TDIR/home2/in-progress/pg-run-a-1-1"
printf 'k3\to3\t100\t0\t5\n' > "$TDIR/home2/in-progress/pg-run-c-3-3"
check 'out-of-range tagged slot shrinks the range' "$([ "$(plan 2)" = '0|' ]; echo $?)" "plan=$(plan 2)"
rm -rf "$TDIR/home2"

echo '# slot exclusion prevents overbooking through a freed lower slot'
mkdir -p "$TDIR/home3/in-progress" "$TDIR/bin"
cat > "$TDIR/bin/oracle-ok" <<'FAKE_OK'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
printf '[P1] a.sh:1 - finding\n  Why: test\nP2: none\nP3: none\nVERDICT: SHIP - fixture.\n' > "$out"
FAKE_OK
chmod +x "$TDIR/bin/oracle-ok"
printf 'kA\toA\t%s\t0\t1\n' "$(date +%s)" > "$TDIR/home3/in-progress/pg-run-slotted-1700000003-44"
exec {S2FD}>>"$TDIR/home3/oracle.lock.slot2"; flock -n "$S2FD"
printf 'still thinking foreign\n' > "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home3" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_MAX_CONCURRENCY=2 PRO_GATE_RAMP=0 PRO_GATE_LOCK_WAIT=4 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-ok" NODE_OPTIONS= \
  bash "$ENGINE" --diff "$TDIR/small.diff" --repo "$TDIR" --out "$TDIR/o-slots.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'reserved slot 1 not reacquired while slot 2 held' "$([ "$RC" -eq 7 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
eval "exec ${S2FD}>&-"
PRO_GATE_HOME="$TDIR/home3" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_MAX_CONCURRENCY=2 PRO_GATE_RAMP=0 PRO_GATE_LOCK_WAIT=10 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-ok" NODE_OPTIONS= \
  bash "$ENGINE" --diff "$TDIR/small.diff" --repo "$TDIR" --out "$TDIR/o-slots2.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'non-reserved slot still acquirable' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'slotted reservation untouched by foreign run' "$([ -f "$TDIR/home3/in-progress/pg-run-slotted-1700000003-44" ]; echo $?)" 'reservation lost'
rm -rf "$TDIR/home3"

echo '# harvest miss policy: absent passes retain, limit releases'
MARKER3="pg-run-miss-1700000002-33"
printf 'kM\t%s\t%s\t0\t\n' "$TDIR/o-miss.md" "$(date +%s)" > "$TDIR/home/in-progress/$MARKER3"
printf 'foreign only\n' > "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RESERVATION_MISSES=2 bash "$ENGINE" --harvest "$MARKER3" --out "$TDIR/o-miss.md" --timeout 4s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'first harvest miss retains reservation (exit 9)' "$([ "$RC" -eq 9 ] && [ -f "$TDIR/home/in-progress/$MARKER3" ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RESERVATION_MISSES=2 bash "$ENGINE" --harvest "$MARKER3" --out "$TDIR/o-miss.md" --timeout 4s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'miss limit releases reservation (exit 6)' "$([ "$RC" -eq 6 ] && [ ! -f "$TDIR/home/in-progress/$MARKER3" ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"

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
