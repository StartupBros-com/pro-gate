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
mkdir -p "$TDIR/home" "$TDIR/bin" "$TDIR/user/.local/bin"

# Self-hosted runners may export operator overrides. The fixture supplies every setting it needs,
# so inherited runtime configuration must not redirect state, browser probes, or timing behavior.
while IFS='=' read -r name _; do
  case "$name" in PRO_GATE_*|ORACLE_*) unset "$name" ;; esac
done < <(env)
export PRO_GATE_MIN_AVAIL_MB=0 PRO_GATE_MAX_SWAP_PCT=101 PRO_GATE_TIMEOUT_BIN=/usr/bin/timeout
# v0.28: the early URL-capture probe is off by default in tests (its sleep would slow every
# fresh-run case); the dedicated early-capture test re-enables it explicitly.
export PRO_GATE_EARLY_PROBE_SECS=0

cat > "$TDIR/bin/oracle-preflight" <<'FAKE_PREFLIGHT'
#!/usr/bin/env bash
printf 'unexpected generic oracle invocation\n' >&2
exit 99
FAKE_PREFLIGHT
chmod +x "$TDIR/bin/oracle-preflight"

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
    PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
    bash "$ENGINE" "$@" >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
}

echo '# hard-ceiling refusal (exit 11): only diffs past PRO_GATE_DIFF_HARD_MAX are refused'
printf 'still thinking, run marker: %s\n' "$MARKER" > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
# > default hard ceiling (25000): still refused up front, no slot spent.
seq 1 26000 | sed 's/^/+/' > "$TDIR/huge.diff"
run_engine --diff "$TDIR/huge.diff" --repo "$TDIR" --out "$TDIR/o-big.md" --timeout 5m
check 'past-hard-ceiling diff exits 11' "$([ "$RC" -eq 11 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
check 'past-hard-ceiling status phase oversized' "$([ "$(phase_of "$TDIR/o-big.md.status")" = oversized ]; echo $?)" "$(cat "$TDIR/o-big.md.status" 2>/dev/null)"
check 'past-hard-ceiling spends nothing' "$([ ! -s "$TDIR/o-big.md" ]; echo $?)" 'out file exists'

# Pro-gate #33 [P1]: native browser mode has no marker-addressable harvest, so a diff over the cook
# threshold must be REFUSED (not cooked into an uncollectable exit-6 spend). No cook band on native.
seq 1 9000 | sed 's/^/+/' > "$TDIR/native-big.diff"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" PRO_GATE_BROWSER_MODE=native \
  bash "$ENGINE" --diff "$TDIR/native-big.diff" --repo "$TDIR" --out "$TDIR/o-native.md" --timeout 5m \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'native mode refuses over-cook diff (exit 11, no cook band)' "$([ "$RC" -eq 11 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
check 'native-mode refusal phase oversized' "$([ "$(phase_of "$TDIR/o-native.md.status")" = oversized ]; echo $?)" "$(cat "$TDIR/o-native.md.status" 2>/dev/null)"

# Pro-gate #33 [P2]: a nonnumeric PRO_GATE_MAX_DIFF_LINES must NOT silently disable the hard ceiling
# (it used to propagate the bad value into DIFF_HARD_MAX and let any size through). huge.diff is 26k
# lines (> default 25k ceiling): the ceiling must still fire despite the garbage cook threshold.
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" PRO_GATE_MAX_DIFF_LINES=oops \
  bash "$ENGINE" --diff "$TDIR/huge.diff" --repo "$TDIR" --out "$TDIR/o-nan.md" --timeout 5m \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'nonnumeric cook threshold still enforces hard ceiling (exit 11)' "$([ "$RC" -eq 11 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"

echo '# harvest: still generating'
run_engine --harvest '' --out "$TDIR/o-empty.md" --timeout 5s
check 'empty harvest marker exits 2' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
check 'empty harvest marker cannot start a fresh review' "$([ ! -e "$TDIR/o-empty.md.status" ]; echo $?)" 'status file created'
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

echo '# harvest: already collected (v0.28) vs genuinely gone'
printf 'run marker: pg-run-999-1700000001-99\nforeign conversation\n' > "$TDIR/tab.txt"
# This marker WAS collected above (o-h2.md, ledgered clean): v0.28 returns it idempotently
# instead of the old exit-6 "lost" — the exact double-spend trap #52 item 2 closed.
run_engine --harvest "$MARKER" --out "$TDIR/o-h3.md" --timeout 5s
check 'already-collected re-harvest exits 0 (was exit 6 pre-v0.28)' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
check 'already-collected re-harvest returns the same review' "$(cmp -s "$TDIR/o-h3.md" "$TDIR/o-h2.md"; echo $?)" "$(head -c 120 "$TDIR/o-h3.md" 2>/dev/null)"
# A marker never collected anywhere is still a genuine loss: exit 6, phase failed.
MGONE="pg-run-77-1700000099-12"
run_engine --harvest "$MGONE" --out "$TDIR/o-h3b.md" --timeout 5s
check 'harvest lost exits 6' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC"
check 'harvest lost phase failed' "$([ "$(phase_of "$TDIR/o-h3b.md.status")" = failed ]; echo $?)" "$(cat "$TDIR/o-h3b.md.status" 2>/dev/null)"

echo '# harvest: deferred under cooldown (v0.28: only when no completed artifact short-circuits)'
# $MARKER was collected above, so its artifact now (correctly) returns BEFORE the cooldown
# gate; the deferral applies to a marker with nothing collected yet.
MCOOL="pg-run-77-1700000098-13"
touch "$TDIR/home/throttle.cooldown"
run_engine --harvest "$MCOOL" --out "$TDIR/o-h4.md" --timeout 5s
check 'harvest cooldown exits 8' "$([ "$RC" -eq 8 ]; echo $?)" "rc=$RC"
check 'harvest cooldown phase deferred' "$([ "$(phase_of "$TDIR/o-h4.md.status")" = deferred ]; echo $?)" "$(cat "$TDIR/o-h4.md.status" 2>/dev/null)"
run_engine --harvest "$MARKER" --out "$TDIR/o-h4b.md" --timeout 5s
check 'collected artifact returns even under cooldown' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
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
[ "${1:-}" = session ] && exit 1
prompt=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in -p) prompt="$2"; shift 2;; --write-output) out="$2"; shift 2;; *) shift;; esac
done
marker="$(printf '%s' "$prompt" | sed -nE 's/.*run marker: (pg-run-[A-Za-z0-9.-]+).*/\1/p' | tail -1)"
printf 'run marker: %s\nReasoning continuously; no verdict yet.\n' "$marker" > "$PG_TEST_TAB_FILE"
[ -n "${PG_TEST_EVIDENCE:-}" ] && printf '%s\n' "$PG_TEST_EVIDENCE"
echo 'Launching browser mode'
echo 'Acquired ChatGPT browser slot'
echo 'Session: fake-primary-run'
exec sleep 30
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

echo '# v0.24: a large diff (> cook threshold, < hard ceiling) COOKS to in-progress, not refused'
# The whole point of the deep gate is to spend the compute: a 9000-line diff (over the 6000 cook
# threshold, under the 25000 hard ceiling) must reach the fresh-run path and land in-progress
# (exit 9, harvestable), NEVER exit 11.
seq 1 9000 | sed 's/^/+/' > "$TDIR/cook.diff"
printf 'waiting for fake submission\n' > "$TDIR/tab.txt"
rm -rf "$TDIR/home/in-progress"; : > "$TDIR/mock.log"
start_mock "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_TIMEOUT_GRACE=0 PRO_GATE_STALL_SECS=5 PRO_GATE_NOTHINK_SECS=5 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle" PG_TEST_TAB_FILE="$TDIR/tab.txt" PATH="$PRIMARY_PATH" NODE_OPTIONS= \
  bash "$ENGINE" --pr 91 --repo "$TDIR" --diff "$TDIR/cook.diff" \
    --out "$TDIR/o-cook.md" --timeout 2s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'large diff cooks to in-progress (exit 9, not 11)' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'large diff lands in-progress phase, never oversized' "$([ "$(phase_of "$TDIR/o-cook.md.status")" = in-progress ]; echo $?)" "$(cat "$TDIR/o-cook.md.status" 2>/dev/null)"
COOK_MARKER="$(jq -r .marker "$TDIR/o-cook.md.status" 2>/dev/null)"
rm -f "$TDIR/home/in-progress/$COOK_MARKER"

echo '# ledger outcomes'
check 'ledger has oversized + in-progress rows' \
  "$(grep -q '"outcome":"oversized"' "$TDIR/home/ledger.jsonl" && grep -q '"outcome":"in-progress"' "$TDIR/home/ledger.jsonl"; echo $?)" \
  "$(cat "$TDIR/home/ledger.jsonl" 2>/dev/null)"

# ─────────────────────────────────────────────────────────────────────────────
# v0.21: model-label capture (U1/U2), machine-surface threading (U3), soft warning (U5)
# ─────────────────────────────────────────────────────────────────────────────
model_of() { jq -r '.model // ""'      "$1" 2>/dev/null || sed -nE 's/.*"model":"([^"]*)".*/\1/p'      "$1"; }
warn_of()  { jq -r '.model_warn // ""' "$1" 2>/dev/null || sed -nE 's/.*"model_warn":"([^"]*)".*/\1/p' "$1"; }

EV_PRO='[browser] Model selection evidence: requested=gpt-5.5-pro; resolved=GPT-5.6 Pro; status=ok; strategy=current; verified=yes.'
EV_UNAVAIL='[browser] Model selection evidence: requested=gpt-5.5-pro; resolved=(unavailable); status=unknown; strategy=current; verified=no.'
# The real dogfood (PR #20) shape: current strategy, model already selected -> resolved unavailable
# but status=already-selected. This is a HEALTHY run and must NOT warn (false-alarm fix).
EV_BENIGN='[browser] Model selection evidence: requested=Pro; resolved=(unavailable); status=already-selected; strategy=current; verified=no.'
EV_WEAK='[browser] Model selection evidence: requested=gpt-5.5-pro; resolved=GPT-4o mini; status=ok; strategy=current; verified=yes.'
EV_ULTRA='[browser] Model selection evidence: requested=gpt-5.5-pro; resolved=GPT-5.6 Sol Ultra; status=ok; strategy=current; verified=yes.'

# A fake oracle that records its argv, optionally emits a "Model selection evidence:" line
# ($PG_TEST_EVIDENCE, echoed to stdout -> $RUNLOG), and writes a complete review (fresh-success).
cat > "$TDIR/bin/oracle-evidence" <<'FAKE_EV'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PG_TEST_ARGV_FILE:-/dev/null}"
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
[ -n "${PG_TEST_EVIDENCE:-}" ] && printf '%s\n' "$PG_TEST_EVIDENCE"
printf '[P1] a.sh:1 - finding\n  Why: test\nP2: none\nP3: none\nVERDICT: SHIP - fixture.\n' > "$out"
FAKE_EV
chmod +x "$TDIR/bin/oracle-evidence"

freshrun() { # $1=home $2=argv-file $3=evidence $4=out [extra STRATEGY via $5]
  rm -rf "$1"; mkdir -p "$1/in-progress"; : > "$2"; printf 'foreign idle tab\n' > "$TDIR/tab.txt"
  PRO_GATE_HOME="$1" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
    PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
    PRO_GATE_MODEL_STRATEGY="${5:-current}" PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-evidence" \
    PG_TEST_ARGV_FILE="$2" PG_TEST_EVIDENCE="$3" NODE_OPTIONS= \
    bash "$ENGINE" --diff "$TDIR/small.diff" --repo "$TDIR" --out "$4" --timeout 5s \
    >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
}

echo '# U1: selector default is current; select still reachable (R1/R2)'
freshrun "$TDIR/home-u1" "$TDIR/argv-def.txt" "$EV_PRO" "$TDIR/o-u1.md"
check 'default run exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'default run requests strategy current' "$(grep -q -- '--browser-model-strategy current' "$TDIR/argv-def.txt"; echo $?)" "argv=$(head -1 "$TDIR/argv-def.txt")"
freshrun "$TDIR/home-u1b" "$TDIR/argv-sel.txt" "$EV_PRO" "$TDIR/o-u1b.md" select
check 'PRO_GATE_MODEL_STRATEGY=select passes select' "$(grep -q -- '--browser-model-strategy select' "$TDIR/argv-sel.txt"; echo $?)" "argv=$(head -1 "$TDIR/argv-sel.txt")"
check 'select still passes -m requested hint' "$(grep -q -- '-m gpt-5.6' "$TDIR/argv-sel.txt"; echo $?)" "argv=$(head -1 "$TDIR/argv-sel.txt")"

# Fallback: a `select` run whose requested model is not selectable (oracle emits "... in the model
# switcher") must auto-fall-back to `current` and still produce a review, not fail the whole run
# (dogfood 2026-07-17, PR #32: `select` + gpt-5.6 -> "Unable to find model option matching
# 'GPT-5.6 Sol' in the model switcher"). Fake oracle: error out under select, succeed under current.
cat > "$TDIR/bin/oracle-switcher-fail" <<'FAKE_SW'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PG_TEST_ARGV_FILE:-/dev/null}"
out=""; strat=""; args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --write-output) out="${args[$((i+1))]}";;
    --browser-model-strategy) strat="${args[$((i+1))]}";;
  esac; i=$((i+1))
done
if [ "$strat" = select ]; then
  echo 'ERROR: Unable to find model option matching "GPT-5.6 Sol" in the model switcher. Available: Instant5.5, Medium, High, Extra High, Pro, GPT-5.6 Sol.'
  exit 1
fi
printf '[P1] a.sh:1 - finding\n  Why: test\nP2: none\nP3: none\nVERDICT: SHIP - fallback.\n' > "$out"
FAKE_SW
chmod +x "$TDIR/bin/oracle-switcher-fail"
rm -rf "$TDIR/home-fb"; mkdir -p "$TDIR/home-fb/in-progress"; : > "$TDIR/argv-fb.txt"
PRO_GATE_HOME="$TDIR/home-fb" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_MODEL_STRATEGY=select PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-switcher-fail" \
  PG_TEST_ARGV_FILE="$TDIR/argv-fb.txt" NODE_OPTIONS= \
  bash "$ENGINE" --diff "$TDIR/small.diff" --repo "$TDIR" --out "$TDIR/o-fb.md" --timeout 5s \
  >"$TDIR/stdout-fb" 2>"$TDIR/stderr-fb"
FB_RC=$?
check 'select switcher-error falls back to current and exits 0' "$([ "$FB_RC" -eq 0 ]; echo $?)" "rc=$FB_RC $(tail -2 "$TDIR/stderr-fb")"
check 'fallback re-invoked oracle with strategy current' "$(grep -q -- '--browser-model-strategy current' "$TDIR/argv-fb.txt"; echo $?)" "argv=$(cat "$TDIR/argv-fb.txt")"
check 'fallback produced a usable review' "$(grep -q 'VERDICT: SHIP' "$TDIR/o-fb.md"; echo $?)" "$(cat "$TDIR/o-fb.md" 2>/dev/null)"

echo '# U2/U3: fresh run captures the resolved model into status + ledger (R4)'
freshrun "$TDIR/home-cap" "$TDIR/argv-cap.txt" "$EV_PRO" "$TDIR/o-cap.md"
check 'fresh capture run exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'status model equals resolved GPT-5.6 Pro' "$([ "$(model_of "$TDIR/o-cap.md.status")" = 'GPT-5.6 Pro' ]; echo $?)" "model=$(model_of "$TDIR/o-cap.md.status")"
check 'ledger model equals resolved GPT-5.6 Pro' "$(grep -q '"model":"GPT-5.6 Pro"' "$TDIR/home-cap/ledger.jsonl"; echo $?)" "$(cat "$TDIR/home-cap/ledger.jsonl" 2>/dev/null)"

echo '# U2/U3: unavailable resolved model degrades to role-based text (R5)'
freshrun "$TDIR/home-unav" "$TDIR/argv-unav.txt" "$EV_UNAVAIL" "$TDIR/o-unav.md"
UNAV_MODEL="$(model_of "$TDIR/o-unav.md.status")"
check 'unavailable status model is role-based (no version)' "$(printf '%s' "$UNAV_MODEL" | grep -q 'reasoning model' && ! printf '%s' "$UNAV_MODEL" | grep -qE 'GPT-|Pro Extended'; echo $?)" "model=$UNAV_MODEL"
check 'unavailable ledger model is role-based (no version)' "$(grep -q 'reasoning model' "$TDIR/home-unav/ledger.jsonl" && ! grep -qE '"model":"GPT-|Pro Extended' "$TDIR/home-unav/ledger.jsonl"; echo $?)" "$(cat "$TDIR/home-unav/ledger.jsonl" 2>/dev/null)"

echo '# U5: soft downgrade warning is advisory, never changes exit status (R6)'
freshrun "$TDIR/home-weak" "$TDIR/argv-weak.txt" "$EV_WEAK" "$TDIR/o-weak.md"
check 'weak model run still exits 0 (advisory)' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
check 'weak model emits WARNING line' "$(grep -q 'weak-model denylist' "$TDIR/stderr"; echo $?)" "$(tail -3 "$TDIR/stderr")"
check 'weak model sets status model_warn' "$([ -n "$(warn_of "$TDIR/o-weak.md.status")" ]; echo $?)" "warn=$(warn_of "$TDIR/o-weak.md.status")"
freshrun "$TDIR/home-ultra" "$TDIR/argv-ultra.txt" "$EV_ULTRA" "$TDIR/o-ultra.md"
check 'strong non-Pro name run exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
check 'strong non-Pro name does NOT warn (no allowlist false-positive)' "$([ -z "$(warn_of "$TDIR/o-ultra.md.status")" ]; echo $?)" "warn=$(warn_of "$TDIR/o-ultra.md.status")"
freshrun "$TDIR/home-unav2" "$TDIR/argv-unav2.txt" "$EV_UNAVAIL" "$TDIR/o-unav2.md"
check 'unconfirmable model (non-benign status) warns' "$([ -n "$(warn_of "$TDIR/o-unav2.md.status")" ]; echo $?)" "warn=$(warn_of "$TDIR/o-unav2.md.status")"
check 'unconfirmable model run still exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
# False-alarm fix (dogfood PR #20): current+already-selected reports (unavailable) but is HEALTHY.
freshrun "$TDIR/home-benign" "$TDIR/argv-benign.txt" "$EV_BENIGN" "$TDIR/o-benign.md"
check 'benign already-selected run exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
check 'benign already-selected does NOT warn' "$([ -z "$(warn_of "$TDIR/o-benign.md.status")" ]; echo $?)" "warn=$(warn_of "$TDIR/o-benign.md.status")"
check 'benign already-selected model is role-based (no version)' "$(printf '%s' "$(model_of "$TDIR/o-benign.md.status")" | grep -q 'reasoning model'; echo $?)" "model=$(model_of "$TDIR/o-benign.md.status")"
check 'benign already-selected emits no model WARNING line' "$(! grep -qE 'weak-model denylist|could not confirm the resolved model' "$TDIR/stderr"; echo $?)" "$(grep -i warning "$TDIR/stderr" | head -2)"

echo '# U2: pg_model_label renders captured value or role-based fallback (R5)'
LBL_CAP="$(bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_model_label 'GPT-5.6 Pro'")"
check 'pg_model_label echoes captured model' "$([ "$LBL_CAP" = 'GPT-5.6 Pro' ]; echo $?)" "lbl=$LBL_CAP"
LBL_EMPTY="$(bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_model_label ''")"
check 'pg_model_label empty -> role-based, no version' "$(printf '%s' "$LBL_EMPTY" | grep -q 'reasoning model' && ! printf '%s' "$LBL_EMPTY" | grep -qE 'GPT-|Pro Extended'; echo $?)" "lbl=$LBL_EMPTY"
LBL_UNAV="$(bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_model_label '(unavailable)'")"
check 'pg_model_label (unavailable) -> role-based' "$(printf '%s' "$LBL_UNAV" | grep -q 'reasoning model'; echo $?)" "lbl=$LBL_UNAV"

echo '# U5: pg_derive_model_warn gates the warning (weak / cannot-confirm / benign) (R6)'
dwarn() { bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_derive_model_warn \"\$1\" \"\$2\"" _ "$1" "$2"; }
check 'weak captured model -> weak warning'      "$([ -n "$(dwarn 'GPT-4o mini' 'ok')" ] && printf '%s' "$(dwarn 'GPT-4o mini' 'ok')" | grep -q denylist; echo $?)" "w=$(dwarn 'GPT-4o mini' 'ok')"
check 'strong captured model -> no warning'      "$([ -z "$(dwarn 'GPT-5.6 Pro' 'ok')" ]; echo $?)" "w=$(dwarn 'GPT-5.6 Pro' 'ok')"
check 'empty model + already-selected -> silent (benign)' "$([ -z "$(dwarn '' 'already-selected')" ]; echo $?)" "w=$(dwarn '' 'already-selected')"
check 'empty model + other status -> cannot-confirm warning' "$([ -n "$(dwarn '' 'unknown')" ]; echo $?)" "w=$(dwarn '' 'unknown')"
check 'empty model + empty status -> cannot-confirm warning' "$([ -n "$(dwarn '' '')" ]; echo $?)" "w=$(dwarn '' '')"

echo '# Portable semver compare for the oracle version floor (no sort -V; dogfood PR #32 P2)'
svlt() { bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_semver_lt \"\$1\" \"\$2\"; echo \$?" _ "$1" "$2"; }
check 'pg_semver_lt 0.15.2 < 0.16.0'          "$([ "$(svlt 0.15.2 0.16.0)" = 0 ]; echo $?)" "rc=$(svlt 0.15.2 0.16.0)"
check 'pg_semver_lt 0.9.0 < 0.16.0 (numeric)' "$([ "$(svlt 0.9.0 0.16.0)" = 0 ]; echo $?)" "rc=$(svlt 0.9.0 0.16.0)"
check 'pg_semver_lt 0.10.0 NOT < 0.9.0'       "$([ "$(svlt 0.10.0 0.9.0)" = 1 ]; echo $?)" "rc=$(svlt 0.10.0 0.9.0)"
check 'pg_semver_lt equal -> not lt'          "$([ "$(svlt 0.16.0 0.16.0)" = 1 ]; echo $?)" "rc=$(svlt 0.16.0 0.16.0)"
check 'pg_semver_lt 0.16.1 NOT < 0.16.0'      "$([ "$(svlt 0.16.1 0.16.0)" = 1 ]; echo $?)" "rc=$(svlt 0.16.1 0.16.0)"
check 'pg_semver_lt non-semver -> rc 2'       "$([ "$(svlt 0.16 0.16.0)" = 2 ]; echo $?)" "rc=$(svlt 0.16 0.16.0)"
# The finding's suggested regression: a BSD-style `sort` that rejects -V must not break the
# floor compare (pg_semver_lt never shells out to sort).
mkdir -p "$TDIR/nosortV"
cat > "$TDIR/nosortV/sort" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in -V|--version-sort) echo "sort: invalid option -- V" >&2; exit 2;; esac; done
exec /usr/bin/sort "$@"
STUB
chmod +x "$TDIR/nosortV/sort"
SVLT_BSD="$(PATH="$TDIR/nosortV:$PATH" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_semver_lt 0.15.2 0.16.0; echo \$?")"
check 'floor compare works under a BSD sort that rejects -V' "$([ "$SVLT_BSD" = 0 ]; echo $?)" "rc=$SVLT_BSD"

echo '# U2: reservation 6-field format keeps positional readers correct'
mkdir -p "$TDIR/home-fmt/in-progress"
MKF="pg-run-fmt-1700000010-88"
printf 'kF\toF\t%s\t0\t2\tGPT-5.6 Pro\n' "$(date +%s)" > "$TDIR/home-fmt/in-progress/$MKF"
NOTE="$(PRO_GATE_HOME="$TDIR/home-fmt" PRO_GATE_RESERVATION_MISSES=3 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$MKF'")"
check 'note_miss on 6-field record retains it' "$([ "$NOTE" = 'retained 1/3' ]; echo $?)" "note=$NOTE"
check 'note_miss increments field 4 (misses)' "$(awk -F'\t' 'NR==1{exit !($4==1)}' "$TDIR/home-fmt/in-progress/$MKF"; echo $?)" "rec=$(cat "$TDIR/home-fmt/in-progress/$MKF")"
check 'note_miss preserves field 5 (slot)' "$(awk -F'\t' 'NR==1{exit !($5==2)}' "$TDIR/home-fmt/in-progress/$MKF"; echo $?)" "rec=$(cat "$TDIR/home-fmt/in-progress/$MKF")"
check 'note_miss preserves field 6 (model)' "$(awk -F'\t' 'NR==1{exit !($6=="GPT-5.6 Pro")}' "$TDIR/home-fmt/in-progress/$MKF"; echo $?)" "rec=$(cat "$TDIR/home-fmt/in-progress/$MKF")"
RMF="$(PRO_GATE_HOME="$TDIR/home-fmt" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_read_model '$MKF'")"
check 'read_model returns field 6' "$([ "$RMF" = 'GPT-5.6 Pro' ]; echo $?)" "rm=$RMF"
# read_model must survive an empty MIDDLE field (empty slot + present model): awk keeps empty
# fields where IFS=$'\t' read would collapse the consecutive tabs and lose the model.
MKE="pg-run-emptyslot-1700000013-66"
printf 'kE\toE\t100\t0\t\tGPT-5.6 Pro\n' > "$TDIR/home-fmt/in-progress/$MKE"
RME="$(PRO_GATE_HOME="$TDIR/home-fmt" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_read_model '$MKE'")"
check 'read_model survives empty slot (no tab collapse)' "$([ "$RME" = 'GPT-5.6 Pro' ]; echo $?)" "rm=$RME"
rm -rf "$TDIR/home-fmt"

echo '# U2: in-progress persists the model; --harvest reads it back (R4) [best case: oracle emitted evidence before the kill]'
rm -rf "$TDIR/home-persist"; mkdir -p "$TDIR/home-persist/in-progress"; : > "$TDIR/mock.log"
printf 'waiting for fake submission\n' > "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home-persist" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_MAX_DIFF_LINES=6000 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_TIMEOUT_GRACE=0 PRO_GATE_STALL_SECS=5 PRO_GATE_NOTHINK_SECS=5 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle" PG_TEST_TAB_FILE="$TDIR/tab.txt" \
  PG_TEST_EVIDENCE="$EV_PRO" PATH="$TDIR/bin:$PATH" NODE_OPTIONS= \
  bash "$ENGINE" --pr 91 --repo "$TDIR" --diff "$TDIR/small.diff" \
    --out "$TDIR/o-persist.md" --timeout 2s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
PERSIST_MARKER="$(jq -r .marker "$TDIR/o-persist.md.status" 2>/dev/null)"
check 'in-progress run exits 9' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'reservation persists the resolved model (field 6)' "$(awk -F'\t' 'NR==1{exit !($6=="GPT-5.6 Pro")}' "$TDIR/home-persist/in-progress/$PERSIST_MARKER" 2>/dev/null; echo $?)" "rec=$(cat "$TDIR/home-persist/in-progress/$PERSIST_MARKER" 2>/dev/null)"
{ printf 'run marker: %s\n' "$PERSIST_MARKER"
  # v0.28 fixtures echo the nonce: this run's prompt promised it (.nonce flag written), and a
  # sub-2-citation capture without it now correctly fails closed.
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean. (run marker: %s)\n' "$PERSIST_MARKER"
} > "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home-persist" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  NODE_OPTIONS= bash "$ENGINE" --harvest "$PERSIST_MARKER" --out "$TDIR/o-harv.md" --timeout 30s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'harvest of persisted run exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'harvest status names the persisted model' "$([ "$(model_of "$TDIR/o-harv.md.status")" = 'GPT-5.6 Pro' ]; echo $?)" "model=$(model_of "$TDIR/o-harv.md.status")"
check 'harvest of a real persisted model does NOT warn' "$([ -z "$(warn_of "$TDIR/o-harv.md.status")" ]; echo $?)" "warn=$(warn_of "$TDIR/o-harv.md.status")"

echo '# U2/P1: realistic exit-9: oracle emits evidence ONLY at completion, so a killed run captures nothing'
# This is the production timing (dogfood PR #20): the fake emits the evidence line AFTER its sleep,
# which the watchdog never reaches. RESOLVED_MODEL stays empty, the reservation persists no model,
# and the run warns "cannot confirm" (this is what the earlier persist test's pre-sleep evidence masks).
cat > "$TDIR/bin/oracle-lateev" <<'FAKE_LATE'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
prompt=""; out=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --write-output) out="$2"; shift 2;; *) shift;; esac; done
marker="$(printf '%s' "$prompt" | sed -nE 's/.*run marker: (pg-run-[A-Za-z0-9.-]+).*/\1/p' | tail -1)"
printf 'run marker: %s\nReasoning continuously; no verdict yet.\n' "$marker" > "$PG_TEST_TAB_FILE"
echo 'Launching browser mode'
echo 'Acquired ChatGPT browser slot'
echo 'Session: fake-lateev'
exec sleep 30
# evidence only at completion (the watchdog kills the process long before this line):
printf 'Model selection evidence: requested=Pro; resolved=GPT-5.6 Pro; status=already-selected; strategy=current; verified=no.\n'
FAKE_LATE
chmod +x "$TDIR/bin/oracle-lateev"
rm -rf "$TDIR/home-late"; mkdir -p "$TDIR/home-late/in-progress"; : > "$TDIR/mock.log"
printf 'waiting for fake submission\n' > "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home-late" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_MAX_DIFF_LINES=6000 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_TIMEOUT_GRACE=0 PRO_GATE_STALL_SECS=5 PRO_GATE_NOTHINK_SECS=5 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-lateev" PG_TEST_TAB_FILE="$TDIR/tab.txt" PATH="$TDIR/bin:$PATH" NODE_OPTIONS= \
  bash "$ENGINE" --pr 92 --repo "$TDIR" --diff "$TDIR/small.diff" \
    --out "$TDIR/o-late.md" --timeout 2s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
LATE_MARKER="$(jq -r .marker "$TDIR/o-late.md.status" 2>/dev/null)"
check 'late-evidence exit-9 run exits 9' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'late-evidence run captures NO model (reservation field 6 empty)' "$(awk -F'\t' 'NR==1{exit !($6=="")}' "$TDIR/home-late/in-progress/$LATE_MARKER" 2>/dev/null; echo $?)" "rec=$(cat "$TDIR/home-late/in-progress/$LATE_MARKER" 2>/dev/null)"
check 'late-evidence status model is role-based (no version)' "$(printf '%s' "$(model_of "$TDIR/o-late.md.status")" | grep -q 'reasoning model'; echo $?)" "model=$(model_of "$TDIR/o-late.md.status")"
check 'late-evidence run warns (cannot confirm)' "$([ -n "$(warn_of "$TDIR/o-late.md.status")" ]; echo $?)" "warn=$(warn_of "$TDIR/o-late.md.status")"

echo '# U2/U5/P2: harvest derives the downgrade warning too (harvest branch no longer drops it)'
# legacy (no-model) reservation: harvest cannot confirm the model -> role-based text AND a warning.
MKL="pg-run-legacy-1700000009-77"
printf 'kL\t%s\t%s\t0\t\n' "$TDIR/o-legacy.md" "$(date +%s)" > "$TDIR/home/in-progress/$MKL"
{ printf 'run marker: %s\n' "$MKL"
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean.\n'
} > "$TDIR/tab.txt"
run_engine --harvest "$MKL" --out "$TDIR/o-legacy.md" --timeout 30s
LEG_MODEL="$(model_of "$TDIR/o-legacy.md.status")"
check 'legacy-record harvest exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'legacy-record harvest model is role-based (no version)' "$(printf '%s' "$LEG_MODEL" | grep -q 'reasoning model' && ! printf '%s' "$LEG_MODEL" | grep -qE 'GPT-|Pro Extended'; echo $?)" "model=$LEG_MODEL"
check 'legacy-record harvest WARNS (cannot confirm; P2 fix)' "$([ -n "$(warn_of "$TDIR/o-legacy.md.status")" ]; echo $?)" "warn=$(warn_of "$TDIR/o-legacy.md.status")"
# weak persisted model: harvest must surface the weak-model warning too. Realistic record shape:
# a real exit-9 always holds a slot, so field 5 (slot) is non-empty alongside the model field 6.
MKW="pg-run-weakres-1700000012-55"
printf 'kW\t%s\t%s\t0\t1\tGPT-4o mini\n' "$TDIR/o-weakres.md" "$(date +%s)" > "$TDIR/home/in-progress/$MKW"
{ printf 'run marker: %s\n' "$MKW"
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean.\n'
} > "$TDIR/tab.txt"
run_engine --harvest "$MKW" --out "$TDIR/o-weakres.md" --timeout 30s
check 'weak persisted model harvest exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'weak persisted model harvest names it' "$([ "$(model_of "$TDIR/o-weakres.md.status")" = 'GPT-4o mini' ]; echo $?)" "model=$(model_of "$TDIR/o-weakres.md.status")"
check 'weak persisted model harvest WARNS (weak denylist)' "$(printf '%s' "$(warn_of "$TDIR/o-weakres.md.status")" | grep -q denylist; echo $?)" "warn=$(warn_of "$TDIR/o-weakres.md.status")"

echo '# v0.22: per-PR review round budget (exit 12, no spend)'
RHOME="$TDIR/home-rounds"
rm -rf "$RHOME"; mkdir -p "$RHOME/in-progress"
RKEY_88="$(printf '%s-88' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
roundrun() { # $1 = pr, $2 = out, rest = extra VAR=val env overrides
  local pr="$1" out="$2"; shift 2
  printf 'foreign idle tab\n' > "$TDIR/tab.txt"
  env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
    PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
    PRO_GATE_MAX_ROUNDS_PER_PR=2 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-ok" NODE_OPTIONS= "$@" \
    bash "$ENGINE" --pr "$pr" --repo "$TDIR" --diff "$TDIR/small.diff" --out "$out" --timeout 5s \
    >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
}
rounds_of() { wc -l < "$RHOME/rounds/$RKEY_88" 2>/dev/null || echo 0; }

roundrun 88 "$RHOME/o-r1.md"
check 'round 1 proceeds (exit 0)' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'round 1 recorded' "$([ "$(rounds_of)" -eq 1 ]; echo $?)" "rounds=$(rounds_of)"
check 'completed review writes severity sidecar (0 P0 / 1 P1)' \
  "$([ "$(awk -F'\t' 'NR==1{print $2" "$3}' "$RHOME/rounds/$RKEY_88.last" 2>/dev/null)" = '0 1' ]; echo $?)" \
  "sidecar: $(cat "$RHOME/rounds/$RKEY_88.last" 2>/dev/null)"
roundrun 88 "$RHOME/o-r2.md"
check 'round 2 proceeds (exit 0)' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'round 2 recorded' "$([ "$(rounds_of)" -eq 2 ]; echo $?)" "rounds=$(rounds_of)"
roundrun 88 "$RHOME/o-r3.md"
check 'round 3 refused with exit 12' "$([ "$RC" -eq 12 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'round-capped status phase' "$([ "$(phase_of "$RHOME/o-r3.md.status")" = round-capped ]; echo $?)" "$(cat "$RHOME/o-r3.md.status" 2>/dev/null)"
check 'capped run spends nothing (no review written)' "$([ ! -s "$RHOME/o-r3.md" ]; echo $?)" 'out file has content'
check 'capped run records no extra round' "$([ "$(rounds_of)" -eq 2 ]; echo $?)" "rounds=$(rounds_of)"
check 'capped run lands in ledger as round-capped' "$(grep -q '"outcome":"round-capped"' "$RHOME/ledger.jsonl"; echo $?)" "$(tail -2 "$RHOME/ledger.jsonl" 2>/dev/null)"
check 'capped run names the override on stderr' "$(grep -q 'PRO_GATE_FORCE_ROUND=1' "$TDIR/stderr"; echo $?)" "$(tail -3 "$TDIR/stderr")"
check 'capped status detail reports last review severity' "$(grep -q '0 P0 / 1 P1 unconfirmed by a re-review' "$RHOME/o-r3.md.status"; echo $?)" "$(cat "$RHOME/o-r3.md.status" 2>/dev/null)"
check 'no open P0 -> no ATTENTION line' "$(! grep -q 'OPEN P0' "$TDIR/stderr"; echo $?)" "$(grep 'OPEN P0' "$TDIR/stderr")"

# A cap hit while the change's last completed review reported P0s flags it loudly: the one
# case the human may want to grant PRO_GATE_FORCE_ROUND=1 for.
printf '1700000000\t2\t1\n' > "$RHOME/rounds/$RKEY_88.last"
roundrun 88 "$RHOME/o-r3b.md"
check 'capped with open P0 still exits 12' "$([ "$RC" -eq 12 ]; echo $?)" "rc=$RC $(tail -4 "$TDIR/stderr")"
check 'open P0 raises the ATTENTION line' "$(grep -q 'ATTENTION: OPEN P0' "$TDIR/stderr"; echo $?)" "$(tail -5 "$TDIR/stderr")"
check 'open P0 counts land in status detail' "$(grep -q '2 P0 / 1 P1 unconfirmed by a re-review' "$RHOME/o-r3b.md.status"; echo $?)" "$(cat "$RHOME/o-r3b.md.status" 2>/dev/null)"

# A different PR in the same repo has its own budget.
roundrun 99 "$RHOME/o-r99.md"
check 'different PR is not capped by PR 88' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"

# One deliberate override runs past the cap and STILL records its round.
roundrun 88 "$RHOME/o-r4.md" PRO_GATE_FORCE_ROUND=1
check 'FORCE_ROUND runs past the cap' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'forced run is still recorded' "$([ "$(rounds_of)" -eq 3 ]; echo $?)" "rounds=$(rounds_of)"

# Entries older than the rolling window neither count nor survive the next record's prune.
printf '100\n200\n300\n' > "$RHOME/rounds/$RKEY_88"
roundrun 88 "$RHOME/o-r5.md"
check 'stale rounds outside the window do not cap' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'record prunes stale entries' "$([ "$(rounds_of)" -eq 1 ]; echo $?)" "rounds file: $(cat "$RHOME/rounds/$RKEY_88" 2>/dev/null)"

# ROUND_GUARD=0 disables the budget entirely.
printf '%s\n%s\n%s\n%s\n' "$(date +%s)" "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$RHOME/rounds/$RKEY_88"
roundrun 88 "$RHOME/o-r6.md" PRO_GATE_ROUND_GUARD=0
check 'ROUND_GUARD=0 disables the budget' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"

# --diff runs (no PR number) budget on repo+branch: they loop just as hard in practice.
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_MAX_ROUNDS_PER_PR=2 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-ok" NODE_OPTIONS= \
  bash "$ENGINE" --diff "$TDIR/small.diff" --repo "$TDIR" --out "$RHOME/o-rdiff.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'pure --diff run proceeds under budget' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
DIFF_ROUND_FILE="$(find "$RHOME/rounds" -name '*-diff' -type f 2>/dev/null | head -1)"
check 'pure --diff run records under a repo+branch diff key' "$([ -n "$DIFF_ROUND_FILE" ]; echo $?)" "rounds dir: $(ls "$RHOME/rounds" 2>/dev/null)"

# Cap 0 is a lockdown: ZERO fresh runs allowed, even on a change with no history.
roundrun 101 "$RHOME/o-r0.md" PRO_GATE_MAX_ROUNDS_PER_PR=0
check 'cap 0 blocks a fresh change (exit 12)' "$([ "$RC" -eq 12 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'cap 0 status phase round-capped' "$([ "$(phase_of "$RHOME/o-r0.md.status")" = round-capped ]; echo $?)" "$(cat "$RHOME/o-r0.md.status" 2>/dev/null)"

# --diff runs serialize on the per-change lock (review P0: without it, concurrent same-branch
# diff gates race the budget's check-then-record window and overshoot the cap). The key
# carries a cksum of the raw UNSANITIZED identity: remote URL (or checkout path) + branch.
DCK="$(printf '%s:%s' "$TDIR" detached | cksum | awk '{print $1}')"
DKEY="$(printf '%s-detached-%s-diff' "$(basename "$TDIR")" "$DCK" | tr -c 'A-Za-z0-9.\n-' '-')"
exec {DLFD}>>"$RHOME/oracle.lock.pr-${DKEY}"; flock -n "$DLFD"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 PRO_GATE_LOCK_WAIT=3 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-ok" NODE_OPTIONS= \
  bash "$ENGINE" --diff "$TDIR/small.diff" --repo "$TDIR" --out "$RHOME/o-dlock.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'concurrent same-branch --diff run waits on the per-change lock (exit 7)' "$([ "$RC" -eq 7 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
eval "exec ${DLFD}>&-"

# Detached-HEAD checkouts key per-commit (literal branch name "HEAD" would cross-cap
# unrelated diffs through one shared per-repo bucket).
GD="$TDIR/detached-repo"
mkdir -p "$GD"; git -C "$GD" init -q 2>/dev/null
printf 'x\n' > "$GD/f"; git -C "$GD" add f
git -C "$GD" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
git -C "$GD" checkout -q --detach 2>/dev/null
GSHA="$(git -C "$GD" rev-parse --short HEAD)"
printf 'diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-x\n+y\n' > "$GD/d.diff"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-ok" NODE_OPTIONS= \
  bash "$ENGINE" --diff "$GD/d.diff" --repo "$GD" --out "$RHOME/o-det.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'detached-HEAD --diff run proceeds' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
GCK="$(printf '%s:%s' "$GD" "$GSHA" | cksum | awk '{print $1}')"
check 'detached-HEAD key is per-commit (short SHA + cksum, not HEAD)' "$([ -f "$RHOME/rounds/detached-repo-${GSHA}-${GCK}-diff" ]; echo $?)" "rounds dir: $(ls "$RHOME/rounds" 2>/dev/null)"

# A same-change reservation redirects --diff runs to harvest too (dogfood gate P1: reservation
# identity is ROUND_KEY for all runs, no longer the shared literal "diff" for diff mode).
RMK="pg-run-${DKEY}-1700000040-77"
printf '%s\t%s\t%s\t0\t\n' "$DKEY" "$RHOME/o-rres.md" "$(date +%s)" > "$RHOME/in-progress/$RMK"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-ok" NODE_OPTIONS= \
  bash "$ENGINE" --diff "$TDIR/small.diff" --repo "$TDIR" --out "$RHOME/o-rres.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'same-branch --diff reservation redirects to harvest (exit 9)' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check '--diff redirect publishes the RESERVED marker' "$(grep -qF "\"marker\":\"$RMK\"" "$RHOME/o-rres.md.status"; echo $?)" "$(cat "$RHOME/o-rres.md.status" 2>/dev/null)"
rm -f "$RHOME/in-progress/$RMK"

# A window typo must fail LARGE (24h), never shrink to pg_dur_secs's 30-min fallback.
WIN_TYPO="$(PRO_GATE_ROUNDS_WINDOW=1d bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_window_secs" 2>/dev/null)"
check 'window typo (1d) falls back to 24h, not 30 min' "$([ "$WIN_TYPO" = 86400 ]; echo $?)" "win=$WIN_TYPO"

# Housekeeping sweeps round files (and their .lock artifacts) untouched longer than the window.
touch -d '3 days ago' "$RHOME/rounds/stale-key-1" "$RHOME/rounds/stale-key-1.lock" 2>/dev/null \
  || { touch "$RHOME/rounds/stale-key-1" "$RHOME/rounds/stale-key-1.lock"; touch -t 202001010000 "$RHOME/rounds/stale-key-1" "$RHOME/rounds/stale-key-1.lock"; }
roundrun 88 "$RHOME/o-r7.md" PRO_GATE_ROUND_GUARD=0
check 'stale round state is swept by housekeeping' "$([ ! -f "$RHOME/rounds/stale-key-1" ] && [ ! -f "$RHOME/rounds/stale-key-1.lock" ]; echo $?)" "rounds dir: $(ls "$RHOME/rounds" 2>/dev/null)"

# Harvests spend no slot and must never consume a round.
NROUND_FILES="$(ls "$RHOME/rounds" 2>/dev/null | wc -l)"
MKR="pg-run-roundharvest-1700000030-22"
printf 'kR\t%s\t%s\t0\t\n' "$RHOME/o-rh.md" "$(date +%s)" > "$RHOME/in-progress/$MKR"
{ printf 'run marker: %s\n' "$MKR"
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean.\n'
} > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$MKR" --out "$RHOME/o-rh.md" --timeout 30s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'harvest in round-test home exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'harvest consumes no round' "$([ "$(ls "$RHOME/rounds" 2>/dev/null | wc -l)" -eq "$NROUND_FILES" ]; echo $?)" "rounds dir: $(ls "$RHOME/rounds" 2>/dev/null)"

echo '# v0.22.1: --confirm mode (budget-accounted confirming pass)'
printf 'P0: none\n[P1] x.sh:1 - prior finding\nP2: none\nP3: none\nVERDICT: FIX-FIRST - prior.\n' > "$TDIR/prior-review-src.md"
: > "$TDIR/argv-confirm.txt"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-evidence" PG_TEST_ARGV_FILE="$TDIR/argv-confirm.txt" \
  PG_TEST_EVIDENCE= NODE_OPTIONS= \
  bash "$ENGINE" --pr 102 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --confirm "$TDIR/prior-review-src.md" --out "$RHOME/o-confirm.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'confirm pass runs and exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'confirm prompt carries the confirming instructions' "$(grep -q 'THIS IS A CONFIRMING PASS' "$TDIR/argv-confirm.txt"; echo $?)" "$(head -c 200 "$TDIR/argv-confirm.txt")"
check 'confirm attaches prior-review.md' "$(grep -q 'prior-review.md' "$TDIR/argv-confirm.txt"; echo $?)" 'no prior-review.md in oracle argv'
check 'confirm pass consumes a round (budget-accounted)' "$([ -f "$RHOME/rounds/$(printf '%s-102' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')" ]; echo $?)" "rounds dir: $(ls "$RHOME/rounds" 2>/dev/null)"
run_engine --confirm /nonexistent-prior.md --pr 102 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-cbad.md" --timeout 5s
check 'missing --confirm file is a usage error (exit 2)' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC"

echo '# v0.22.1: Cloudflare (provably-unsubmitted) refunds its round'
cat > "$TDIR/bin/oracle-cf" <<'FAKE_CF'
#!/usr/bin/env bash
echo 'Cloudflare anti-bot page detected'
exit 1
FAKE_CF
chmod +x "$TDIR/bin/oracle-cf"
RKEY_103="$(printf '%s-103' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-cf" NODE_OPTIONS= \
  bash "$ENGINE" --pr 103 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-cf.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'cloudflare run fails without a usable review' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'cloudflare writes the account cooldown' "$([ -f "$RHOME/throttle.cooldown" ]; echo $?)" 'no cooldown file'
check 'cloudflare refunds the round (no spend, no budget charge)' "$([ ! -f "$RHOME/rounds/$RKEY_103" ]; echo $?)" "rounds file: $(cat "$RHOME/rounds/$RKEY_103" 2>/dev/null)"
rm -f "$RHOME/throttle.cooldown"

echo '# v0.22.1: pg_round_unrecord drops only the newest entry'
printf '100\n200\n300\n' > "$RHOME/rounds/unrec-key-1"
PRO_GATE_HOME="$RHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_unrecord unrec-key-1"
check 'unrecord drops one entry' "$([ "$(wc -l < "$RHOME/rounds/unrec-key-1")" -eq 2 ]; echo $?)" "$(cat "$RHOME/rounds/unrec-key-1" 2>/dev/null)"
printf '100\n' > "$RHOME/rounds/unrec-key-1"
PRO_GATE_HOME="$RHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_unrecord unrec-key-1"
check 'unrecord removes an emptied file' "$([ ! -f "$RHOME/rounds/unrec-key-1" ]; echo $?)" 'file survived'

echo '# memory-pressure messaging helpers (low-memory robustness)'
LIB="$HERE/../lib/pro-gate-lib.sh"
# pg_mem_status: human snapshot naming free RAM (where free(1) exists, i.e. Linux CI)
MSTAT="$(bash -c ". '$LIB'; pg_mem_status")"
check 'pg_mem_status reports free RAM' "$(printf '%s' "$MSTAT" | grep -q 'free RAM'; echo $?)" "got: $MSTAT"
# pg_mem_pressure_note: silent (rc 1) above threshold
bash -c ". '$LIB'; PRO_GATE_SWAP_WARN_PCT=101 pg_mem_pressure_note" >/dev/null 2>&1; RC=$?
check 'mem pressure note silent above threshold' "$([ "$RC" -ne 0 ]; echo $?)" "rc=$RC (fired at 101%)"
# ...and fires (rc 0 + text) below threshold when the host actually has swap
if [ "$(free -m | awk '/^Swap:/{print $2}')" -gt 0 ] 2>/dev/null; then
  NOTE_LO="$(bash -c ". '$LIB'; PRO_GATE_SWAP_WARN_PCT=0 pg_mem_pressure_note")"
  check 'mem pressure note fires below threshold (swap present)' "$([ -n "$NOTE_LO" ]; echo $?)" "got: $NOTE_LO"
else
  echo 'ok - mem pressure note fire-case skipped (no swap on this host)'
fi
# pg_browser_restarted_midrun: fires when service uptime < run duration (stubbed), silent otherwise
R_FIRED="$(bash -c ". '$LIB'; pg_service_uptime(){ echo 5; }; pg_browser_mode(){ echo remote-chrome; }; pg_browser_restarted_midrun \$(( \$(date +%s) - 100 ))")"
check 'browser-restart detector fires (uptime<run)' "$([ "$R_FIRED" = 5 ]; echo $?)" "got: $R_FIRED"
bash -c ". '$LIB'; pg_service_uptime(){ echo 999999; }; pg_browser_mode(){ echo remote-chrome; }; pg_browser_restarted_midrun \$(( \$(date +%s) - 100 ))" >/dev/null 2>&1; RC=$?
check 'browser-restart detector silent (stable uptime)' "$([ "$RC" -ne 0 ]; echo $?)" "rc=$RC (fired on stable uptime)"
bash -c ". '$LIB'; pg_service_uptime(){ echo 5; }; pg_browser_mode(){ echo native; }; pg_browser_restarted_midrun \$(( \$(date +%s) - 100 ))" >/dev/null 2>&1; RC=$?
check 'browser-restart detector native-safe' "$([ "$RC" -ne 0 ]; echo $?)" "rc=$RC (fired in native mode)"
# gate #34 P2: a DOWN service (uptime 0) must NOT be misreported as a mid-run restart
bash -c ". '$LIB'; pg_service_uptime(){ echo 0; }; pg_browser_mode(){ echo remote-chrome; }; pg_browser_restarted_midrun \$(( \$(date +%s) - 100 ))" >/dev/null 2>&1; RC=$?
check 'browser-restart detector silent when service down (uptime 0)' "$([ "$RC" -ne 0 ]; echo $?)" "rc=$RC (down misread as OOM restart)"

echo '# v0.27: --status run rediscovery (read-only, no browser needed)'
SHOME="$TDIR/sthome"; mkdir -p "$SHOME/in-progress" "$SHOME/rounds" "$SHOME/conversation-urls"
SMARKER="pg-run-acme-widgets-42-1700000001-77"
printf '42\t/tmp/pg-st-42.md\t%s\t0\t1\tGPT-X\n' "$(date +%s)" > "$SHOME/in-progress/$SMARKER"
printf '%s\n%s\n' "$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 120 ))" > "$SHOME/rounds/acme-widgets-42"
printf 'https://chatgpt.com/c/abc123\n' > "$SHOME/conversation-urls/$SMARKER"
printf '{"ts":"2026-01-01T00:00:00+0000","pr":"42","repo":"/tmp/acme","exit":9,"outcome":"in-progress","secs":100,"attempts":0,"conc":1,"ceiling":1,"live":1,"salvaged":0,"diff_lines":10,"out":"/tmp/pg-st-42.md","model":"m","marker":"%s","round_key":"acme-widgets-42"}\n' "$SMARKER" > "$SHOME/ledger.jsonl"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st.out" 2>"$TDIR/st.err"; RC=$?
check '--status exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(cat "$TDIR/st.err")"
check '--status names the reservation marker' "$(grep -q "$SMARKER" "$TDIR/st.out"; echo $?)" "$(cat "$TDIR/st.out")"
check '--status leads to a free harvest' "$(grep -q "FREE" "$TDIR/st.out" && grep -q -- "--harvest '$SMARKER'" "$TDIR/st.out"; echo $?)" "$(grep -i harvest "$TDIR/st.out")"
check '--status reports rounds spent/remaining' "$(grep -q '2 spent, 2 remaining' "$TDIR/st.out"; echo $?)" "$(grep spent "$TDIR/st.out")"
check '--status writes nothing' "$([ ! -f "$SHOME/ledger.jsonl.tmp" ] && [ "$(wc -l < "$SHOME/ledger.jsonl")" -eq 1 ]; echo $?)" 'state mutated'
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 --json >"$TDIR/st.json" 2>/dev/null; RC=$?
check '--status --json exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
check '--status --json reservation marker' "$([ "$(jq -r '.reservations[0].marker' "$TDIR/st.json")" = "$SMARKER" ]; echo $?)" "$(cat "$TDIR/st.json")"
check '--status --json remembered url' "$([ "$(jq -r '.reservations[0].conversation_url' "$TDIR/st.json")" = "https://chatgpt.com/c/abc123" ]; echo $?)" "$(jq -c .reservations "$TDIR/st.json")"
check '--status --json rounds remaining' "$([ "$(jq -r '.rounds[0].remaining' "$TDIR/st.json")" = 2 ]; echo $?)" "$(jq -c .rounds "$TDIR/st.json")"
check '--status --json recent runs' "$([ "$(jq -r '.recent_runs | length' "$TDIR/st.json")" = 1 ]; echo $?)" "$(jq -c .recent_runs "$TDIR/st.json")"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status "$SMARKER" --json >"$TDIR/st2.json" 2>/dev/null
check '--status by marker finds the reservation' "$([ "$(jq -r '.reservations | length' "$TDIR/st2.json")" = 1 ]; echo $?)" "$(cat "$TDIR/st2.json")"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 999 >"$TDIR/st3.out" 2>/dev/null; RC=$?
check '--status unknown pr exits 0 with a spend warning' "$([ "$RC" -eq 0 ] && grep -q 'SPEND a slot' "$TDIR/st3.out"; echo $?)" "rc=$RC $(tail -1 "$TDIR/st3.out")"
# In-flight: a held per-change lock (live run, no reservation/ledger yet) must be reported —
# NOT "no state found", which would invite the duplicate launch --status exists to prevent.
rm -f "$SHOME/in-progress/$SMARKER"
( exec 9>>"$SHOME/oracle.lock.pr-acme-widgets-42"; flock 9; sleep 4 ) &
LOCK_BG=$!; sleep 0.5
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st4.out" 2>/dev/null; RC=$?
check '--status flags a live same-change run' "$([ "$RC" -eq 0 ] && grep -q 'RUNNING' "$TDIR/st4.out"; echo $?)" "rc=$RC $(cat "$TDIR/st4.out")"
check '--status live-run hint says do not launch' "$(grep -qi 'do NOT launch' "$TDIR/st4.out"; echo $?)" "$(tail -1 "$TDIR/st4.out")"
wait "$LOCK_BG" 2>/dev/null
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st5.out" 2>/dev/null
check '--status released lock no longer flagged live' "$(grep -q 'RUNNING' "$TDIR/st5.out"; [ $? -ne 0 ]; echo $?)" "$(cat "$TDIR/st5.out")"
# Active-run index (gate #53 P1): a live-pid record flags RUNNING with no lock, reservation,
# or ledger row; a dead-pid record (wrapper died, browser may still generate) leads to
# harvest-by-marker — never a fresh-run recommendation.
mkdir -p "$SHOME/active"
sleep 30 & LIVE_PID=$!
printf '%s\t/tmp/pg-live-42.md\t%s\t%s\n' "$SMARKER" "$LIVE_PID" "$(date +%s)" > "$SHOME/active/acme-widgets-42"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st6.out" 2>/dev/null
check '--status active live pid flags RUNNING' "$(grep -q 'RUNNING' "$TDIR/st6.out"; echo $?)" "$(cat "$TDIR/st6.out")"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
printf '%s\t/tmp/pg-dead-42.md\t99999999\t%s\n' "$SMARKER" "$(date +%s)" > "$SHOME/active/acme-widgets-42"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st7.out" 2>/dev/null
check '--status dead wrapper leads to harvest, not fresh run' "$(grep -q 'wrapper DIED' "$TDIR/st7.out" && grep -q -- "--harvest '$SMARKER'" "$TDIR/st7.out"; echo $?)" "$(tail -2 "$TDIR/st7.out")"
rm -rf "$SHOME/active"
printf '42\t/tmp/pg-st-42.md\t%s\t0\t1\tGPT-X\n' "$(date +%s)" > "$SHOME/in-progress/$SMARKER"
# URL queries repo-scope the ledger (gate #53 P1): a foreign repo's identical PR number must
# not drive next_step or appear in recent runs.
printf '{"ts":"2026-01-03T00:00:00+0000","pr":"42","repo":"/tmp/other","exit":0,"outcome":"clean","secs":50,"attempts":0,"conc":1,"ceiling":1,"live":0,"salvaged":0,"diff_lines":5,"out":"/tmp/FOREIGN-42.md","model":"m","marker":"pg-run-other-repo-42-1700000009-88","round_key":"other-repo-42"}\n' >> "$SHOME/ledger.jsonl"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status "https://github.com/acme/widgets/pull/42" --json >"$TDIR/st8.json" 2>/dev/null
check 'URL --status excludes foreign-repo rows' "$(jq -e '[.recent_runs[].out] | inside(["/tmp/pg-st-42.md"])' "$TDIR/st8.json" >/dev/null 2>&1; echo $?)" "$(jq -c .recent_runs "$TDIR/st8.json")"
check 'URL --status still finds its own repo' "$([ "$(jq -r '.recent_runs | length' "$TDIR/st8.json")" = 1 ]; echo $?)" "$(jq -c .recent_runs "$TDIR/st8.json")"
# Round keys are not prefix-free (gate #53 r2 P1): a row whose key merely EXTENDS the queried
# slug-num (acme-widgets-42-tools-7) must not match a URL query for acme/widgets#42.
printf '{"ts":"2026-01-04T00:00:00+0000","pr":"7","repo":"/tmp/tools","exit":0,"outcome":"clean","secs":40,"attempts":0,"conc":1,"ceiling":1,"live":0,"salvaged":0,"diff_lines":3,"out":"/tmp/PREFIX-COLLIDE.md","model":"m","marker":"pg-run-acme-widgets-42-tools-7-1700000010-99","round_key":"acme-widgets-42-tools-7"}\n' >> "$SHOME/ledger.jsonl"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status "https://github.com/acme/widgets/pull/42" --json >"$TDIR/st9.json" 2>/dev/null
check 'URL --status rejects prefix-colliding keys' "$(jq -e '[.recent_runs[].out] | inside(["/tmp/pg-st-42.md"])' "$TDIR/st9.json" >/dev/null 2>&1; echo $?)" "$(jq -c .recent_runs "$TDIR/st9.json")"
# First-ever run waiting for the account slot (gate #53 r2 P1): per-change lock held, but no
# rounds/ or active/ file yet — --status must still see it, not report "no state".
( exec 9>>"$SHOME/oracle.lock.pr-fresh-repo-90"; flock 9; sleep 4 ) &
LOCK_BG2=$!; sleep 0.5
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 90 >"$TDIR/st10.out" 2>/dev/null; RC=$?
check '--status sees a first-run lock with no rounds file' "$([ "$RC" -eq 0 ] && grep -q 'RUNNING' "$TDIR/st10.out"; echo $?)" "rc=$RC $(cat "$TDIR/st10.out")"
wait "$LOCK_BG2" 2>/dev/null; rm -f "$SHOME/oracle.lock.pr-fresh-repo-90"
# Native-mode dead wrapper (gate #53 r2 P1): no harvest loop — manual recovery guidance.
# (No reservation in this fixture: native runs never create one, and a present reservation
# would legitimately outrank the active record in the hint cascade.)
rm -f "$SHOME/in-progress/$SMARKER"
mkdir -p "$SHOME/active"
printf '%s\t/tmp/pg-native-42.md\t99999999\t%s\tnative\n' "$SMARKER" "$(date +%s)" > "$SHOME/active/acme-widgets-42"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st11.out" 2>/dev/null
check 'native dead wrapper avoids the harvest loop' "$(grep -q 'no harvest path' "$TDIR/st11.out" && ! grep -q -- "--harvest '$SMARKER'" "$TDIR/st11.out"; echo $?)" "$(tail -2 "$TDIR/st11.out")"
rm -rf "$SHOME/active"
printf '42\t/tmp/pg-st-42.md\t%s\t0\t1\tGPT-X\n' "$(date +%s)" > "$SHOME/in-progress/$SMARKER"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status not.a.query >/dev/null 2>&1; RC=$?
check '--status rejects a malformed query (exit 2)' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --json >/dev/null 2>&1; RC=$?
check '--json without --status is a usage error (exit 2)' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC"

echo '# v0.27: exit 4/5 land in the ledger; ledger rows carry marker+round_key'
printf 'idle tab, no marker\n' > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
run_engine --pr 55 --repo "$TDIR/does-not-exist" --out "$TDIR/o-badrepo.md" --timeout 5s
check 'missing repo exits 4' "$([ "$RC" -eq 4 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
LLINE="$(tail -n 1 "$TDIR/home/ledger.jsonl" 2>/dev/null)"
check 'exit 4 writes a ledger line (outcome bad-repo)' "$([ "$(printf '%s' "$LLINE" | jq -r .outcome 2>/dev/null)" = bad-repo ]; echo $?)" "$LLINE"
check 'ledger lines carry marker+round_key fields' "$(printf '%s' "$LLINE" | jq -e 'has("marker") and has("round_key")' >/dev/null 2>&1; echo $?)" "$LLINE"
if command -v gh >/dev/null 2>&1; then
  # Seed a dead predecessor's active record for the same change: a non-owning invocation that
  # exits BEFORE pg_active_write (diff-fetch failure here) must NOT erase it (gate #53 r3 P1).
  RKEY_66="$(git -C "$TDIR" rev-parse --git-dir >/dev/null 2>&1; printf '%s-66' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
  mkdir -p "$TDIR/home/active"
  printf 'pg-run-%s-1700000020-11\t/tmp/pg-pred-66.md\t99999999\t%s\tremote-chrome\n' "$RKEY_66" "$(date +%s)" > "$TDIR/home/active/$RKEY_66"
  run_engine --pr 66 --repo "$TDIR" --out "$TDIR/o-nodiff.md" --timeout 5s
  check 'diff fetch failure exits 5' "$([ "$RC" -eq 5 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
  LLINE="$(tail -n 1 "$TDIR/home/ledger.jsonl" 2>/dev/null)"
  check 'exit 5 ledger outcome diff-fetch-failed' "$([ "$(printf '%s' "$LLINE" | jq -r .outcome 2>/dev/null)" = diff-fetch-failed ]; echo $?)" "$LLINE"
  check 'exit 5 ledger carries a round_key' "$([ -n "$(printf '%s' "$LLINE" | jq -r '.round_key // ""' 2>/dev/null)" ]; echo $?)" "$LLINE"
  check 'non-owning exit preserves predecessor active record' "$([ -f "$TDIR/home/active/$RKEY_66" ]; echo $?)" 'record erased by a run that never wrote it'
  rm -rf "$TDIR/home/active"
else
  echo 'ok - exit-5 ledger case skipped (gh not installed)'
fi
# Reservation matching is key-exact (gate #53 r3 P1): a prefix-colliding foreign reservation
# (acme-widgets-42-tools-7 vs acme/widgets#42) must not surface for the URL query — reservations
# outrank every other status source, so a substring leak would emit a foreign harvest command.
FMARKER="pg-run-acme-widgets-42-tools-7-1700000021-33"
printf '7\t/tmp/FOREIGN-RES.md\t%s\t0\t1\tGPT-X\n' "$(date +%s)" > "$SHOME/in-progress/$FMARKER"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status "https://github.com/acme/widgets/pull/42" --json >"$TDIR/st12.json" 2>/dev/null
check 'URL --status rejects prefix-colliding reservation' "$(jq -e '[.reservations[].marker] | inside(["'"$SMARKER"'"])' "$TDIR/st12.json" >/dev/null 2>&1; echo $?)" "$(jq -c .reservations "$TDIR/st12.json")"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 7 --json >"$TDIR/st13.json" 2>/dev/null
check 'bare-number --status still finds the -7 key' "$(jq -e '[.reservations[].marker] | index("'"$FMARKER"'") != null' "$TDIR/st13.json" >/dev/null 2>&1; echo $?)" "$(jq -c .reservations "$TDIR/st13.json")"
rm -f "$SHOME/in-progress/$FMARKER"
# Stale mkdir-fallback lock dirs (gate #53 r3 P1): a .d dir with a dead owner pid is NOT live.
mkdir -p "$SHOME/oracle.lock.pr-acme-widgets-42.d"; echo 99999999 > "$SHOME/oracle.lock.pr-acme-widgets-42.d/pid"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st14.out" 2>/dev/null
check 'stale .d lock (dead owner) not reported RUNNING' "$(grep -q 'RUNNING' "$TDIR/st14.out"; [ $? -ne 0 ]; echo $?)" "$(grep -i running "$TDIR/st14.out")"
echo "$$" > "$SHOME/oracle.lock.pr-acme-widgets-42.d/pid"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st15.out" 2>/dev/null
check 'live .d lock (live owner) reported RUNNING' "$(grep -q 'RUNNING' "$TDIR/st15.out"; echo $?)" "$(cat "$TDIR/st15.out")"
rm -rf "$SHOME/oracle.lock.pr-acme-widgets-42.d"

echo '# v0.27: pro-gate-stats.sh --pr filters every view'
STATS="$HERE/../bin/pro-gate-stats.sh"
printf '{"ts":"2026-01-01T00:00:00+0000","pr":"7","outcome":"clean","secs":10,"conc":1,"salvaged":0}\n{"ts":"2026-01-02T00:00:00+0000","pr":"8","outcome":"failed","secs":20,"conc":1,"salvaged":1}\n' > "$SHOME/ledger.jsonl"
SP_RUNS="$(PRO_GATE_HOME="$SHOME" bash "$STATS" --pr 7 --json 2>/dev/null | jq -r '.runs | length')"
check 'stats --pr --json filters runs' "$([ "$SP_RUNS" = 1 ]; echo $?)" "runs=$SP_RUNS"
SP_TAIL="$(PRO_GATE_HOME="$SHOME" bash "$STATS" --pr 8 --tail 5 2>/dev/null | grep -c $'\t8\t')"
check 'stats --pr filters --tail' "$([ "$SP_TAIL" = 1 ]; echo $?)" "tail matches=$SP_TAIL"
# Harvest rows ledger the stripped repo-scoped key as .pr (gate #53 P2): --pr N must match them.
printf '{"ts":"2026-01-03T00:00:00+0000","pr":"acme-widgets-7","outcome":"clean","secs":30,"conc":0,"salvaged":1,"round_key":"acme-widgets-7"}\n' >> "$SHOME/ledger.jsonl"
SP_HARV="$(PRO_GATE_HOME="$SHOME" bash "$STATS" --pr 7 --json 2>/dev/null | jq -r '.runs | length')"
check 'stats --pr matches harvest rows by round key' "$([ "$SP_HARV" = 2 ]; echo $?)" "runs=$SP_HARV"
PRO_GATE_HOME="$SHOME" bash "$STATS" --pr not-a-number >/dev/null 2>&1; RC=$?
check 'stats --pr rejects non-numeric (exit 2)' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC"

echo '# v0.28: severity sidecar counts only OPEN findings (RESOLVED verification blocks excluded)'
mkdir -p "$SHOME/rounds"
printf '1000\n' > "$SHOME/rounds/sev-key-1"
cat > "$TDIR/sevreview.md" <<'SEV'
P0: none of the priors remain

[P0] a.sh:1 — RESOLVED — fixed earlier
[P0] b.sh:2 — a new unresolved problem
[P0] f.sh:6 — the RESOLVED_MODEL capture is clobbered mid-run
[P1] c.sh:3 — RESOLVED — fixed
[P1] d.sh:4 — STILL-PRESENT — not fixed
[P1] e.sh:5 — another new finding

VERDICT: FIX-FIRST — x
SEV
PRO_GATE_HOME="$SHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_note_severity sev-key-1 '$TDIR/sevreview.md'"
SEV_LINE="$(cat "$SHOME/rounds/sev-key-1.last" 2>/dev/null)"
# 2 open P0 (the RESOLVED_MODEL identifier is NOT a status token — gate #54 r3 P2), 2 open P1.
check 'severity sidecar excludes only RESOLVED status tokens' "$([ "$(printf '%s' "$SEV_LINE" | cut -f2)" = 2 ] && [ "$(printf '%s' "$SEV_LINE" | cut -f3)" = 2 ]; echo $?)" "sidecar: $SEV_LINE"

echo '# v0.28: provenance helpers (lib)'
printf 'src/real.sh\nlib/other.sh\n' > "$TDIR/manifest.txt"
cat > "$TDIR/prov-foreign.md" <<'PF'
P0: none

[P1] apps/blog-writer/collect.ts:12 — foreign finding
[P1] apps/blog-writer/schema.ts:44 — second foreign finding

VERDICT: FIX-FIRST — foreign
PF
cat > "$TDIR/prov-single.md" <<'PS'
P0: none

[P1] callers/context-only.ts:5 — single citation outside the diff

VERDICT: FIX-FIRST — ambiguous
PS
cat > "$TDIR/prov-ours.md" <<'PO'
P0: none

[P1] src/real.sh:7 — real finding

VERDICT: FIX-FIRST — ours
PO
bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_review_matches_change '$TDIR/prov-foreign.md' '$TDIR/manifest.txt'"; RC=$?
check 'provenance rejects zero-overlap citations' "$([ "$RC" -ne 0 ]; echo $?)" "rc=$RC"
bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_review_matches_change '$TDIR/prov-ours.md' '$TDIR/manifest.txt'"; RC=$?
check 'provenance accepts a cited change file' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_review_matches_change '$TDIR/prov-ours.md' /nonexistent-manifest"; RC=$?
check 'provenance accepts when no manifest exists (legacy)' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_review_matches_change '$TDIR/prov-single.md' '$TDIR/manifest.txt'"; RC=$?
check 'provenance accepts a single ambiguous citation' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
# Basename equality is NOT overlap (gate #54 r2 P1): monorepo twins like index.ts must not
# let a foreign review pass.
cat > "$TDIR/prov-basename.md" <<'PB'
P0: none

[P1] apps/foo/index.ts:3 — foreign finding
[P1] apps/foo/route.ts:9 — second foreign finding

VERDICT: FIX-FIRST — foreign
PB
printf 'lib/index.ts\npackages/api/route.ts\n' > "$TDIR/manifest-twins.txt"
bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_review_matches_change '$TDIR/prov-basename.md' '$TDIR/manifest-twins.txt'"; RC=$?
check 'provenance rejects basename-only twins' "$([ "$RC" -ne 0 ]; echo $?)" "rc=$RC"

echo '# v0.28: harvest provenance — foreign capture preserved, never returned as ours'
M3="pg-run-provtest-9-1700000030-44"
printf '9\t%s\t%s\t0\t1\tGPT-X\n' "$TDIR/o-prov.md" "$(date +%s)" > "$TDIR/home/in-progress/$M3"
mkdir -p "$TDIR/home/manifests"
printf 'src/real.sh\n' > "$TDIR/home/manifests/$M3"
cat > "$TDIR/tab.txt" <<TAB
conversation for run marker: $M3
P0: none

[P1] apps/blog-writer/collect.ts:12 — foreign finding
[P1] apps/blog-writer/schema.ts:44 — second foreign finding

VERDICT: FIX-FIRST — foreign
TAB
start_mock "$TDIR/tab.txt"
run_engine --harvest "$M3" --out "$TDIR/o-prov.md" --timeout 5s
check 'foreign harvest capture exits 9 (preserved)' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'foreign harvest keeps the reservation' "$([ -f "$TDIR/home/in-progress/$M3" ]; echo $?)" 'reservation destroyed'
check 'foreign capture set aside for inspection' "$(ls "$TDIR/o-prov.md.foreign."* >/dev/null 2>&1; echo $?)" 'no .foreign file'
check 'foreign capture not returned as the review' "$([ ! -s "$TDIR/o-prov.md" ]; echo $?)" 'out file written'
# Rejection invalidates the memoized candidate: memo gone, URL on the per-marker blacklist —
# without this the next harvest replays the same foreign conversation forever (gate #54 P1).
check 'rejection removes the URL memo' "$([ ! -f "$TDIR/home/conversation-urls/$M3" ]; echo $?)" "$(cat "$TDIR/home/conversation-urls/$M3" 2>/dev/null)"
check 'rejection blacklists the URL for this marker' "$(grep -q "^$M3	" "$TDIR/home/salvage-nonmatching.txt" 2>/dev/null; echo $?)" "$(cat "$TDIR/home/salvage-nonmatching.txt" 2>/dev/null)"
# A manifest in its own directory must NOT read as a reservation (gate #54 P1): exactly one
# reservation is visible for this change.
PRO_GATE_HOME="$TDIR/home" bash "$ENGINE" --status "$M3" --json >"$TDIR/st-m3.json" 2>/dev/null
check 'manifest not counted as a reservation' "$([ "$(jq -r '.reservations | length' "$TDIR/st-m3.json")" = 1 ]; echo $?)" "$(jq -c .reservations "$TDIR/st-m3.json")"
# The gate-prescribed replay test (gate #54 r2 P1): a SECOND harvest WITHOUT clearing the
# blacklist must skip the rejected OPEN tab (live-tab scans now consult the per-marker
# blacklist) instead of replaying the same foreign review.
run_engine --harvest "$M3" --out "$TDIR/o-prov.md" --timeout 5s
check 'replay harvest does not return the foreign review' "$([ "$RC" -ne 0 ] && [ ! -s "$TDIR/o-prov.md" ]; echo $?)" "rc=$RC $(head -2 "$TDIR/o-prov.md" 2>/dev/null)"
check 'replay harvest preserves the reservation (exit 9)' "$([ "$RC" -eq 9 ] && [ -f "$TDIR/home/in-progress/$M3" ]; echo $?)" "rc=$RC"
# Positive control: a manifest that matches the citation accepts the same capture. (The
# blacklist from the rejection above is cleared: this fixture reuses the same mock URL, which
# a real recovered-from-foreign flow would reach via a different conversation.)
rm -f "$TDIR/home/salvage-nonmatching.txt"
printf 'apps/blog-writer/collect.ts\n' > "$TDIR/home/manifests/$M3"
run_engine --harvest "$M3" --out "$TDIR/o-prov.md" --timeout 5s
check 'matching harvest capture exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'matching harvest removes reservation + manifest' "$([ ! -f "$TDIR/home/in-progress/$M3" ] && [ ! -f "$TDIR/home/manifests/$M3" ]; echo $?)" "$(ls "$TDIR/home/in-progress" "$TDIR/home/manifests" 2>/dev/null)"

echo '# v0.28: positive run-binding — a nonce-bearing capture is accepted and stripped'
M8="pg-run-noncetest-3-1700000034-88"
printf '3\t%s\t%s\t0\t1\tGPT-X\n' "$TDIR/o-nonce.md" "$(date +%s)" > "$TDIR/home/in-progress/$M8"
printf 'src/real.sh\n' > "$TDIR/home/manifests/$M8"
cat > "$TDIR/tab.txt" <<TAB
conversation for run marker: $M8
P0: none

[P1] apps/blog-writer/collect.ts:12 — cites nothing from the diff
[P1] apps/blog-writer/schema.ts:44 — second non-diff citation

VERDICT: FIX-FIRST — but positively bound (run marker: $M8)
TAB
start_mock "$TDIR/tab.txt"
run_engine --harvest "$M8" --out "$TDIR/o-nonce.md" --timeout 5s
check 'nonce-bearing capture accepted despite path mismatch' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'nonce stripped from the returned review' "$(grep -q 'run marker' "$TDIR/o-nonce.md"; [ $? -ne 0 ]; echo $?)" "$(tail -1 "$TDIR/o-nonce.md" 2>/dev/null)"
check 'VERDICT line survives the strip' "$(grep -q 'VERDICT: FIX-FIRST' "$TDIR/o-nonce.md"; echo $?)" "$(tail -1 "$TDIR/o-nonce.md" 2>/dev/null)"
check 'clean collection writes the completed artifact' "$([ -s "$TDIR/home/completed/$M8" ]; echo $?)" "$(ls "$TDIR/home/completed" 2>/dev/null)"
check 'clean ledger row records the digest' "$([ -n "$(tail -1 "$TDIR/home/ledger.jsonl" | jq -r '.sha256 // ""')" ]; echo $?)" "$(tail -1 "$TDIR/home/ledger.jsonl")"

echo '# v0.28: artifact-first recovery — no ledger row needed'
M9="pg-run-artifact-4-1700000035-99"
mkdir -p "$TDIR/home/completed"
cp "$TDIR/prov-ours.md" "$TDIR/home/completed/$M9"
printf 'idle tab with no markers at all\n' > "$TDIR/tab.txt"
# Artifact recovery needs no browser and must precede the cooldown gate (gate #54 r3 P2):
# retrievable even while the account is cooling.
printf '%s test-cooldown\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$TDIR/home/throttle.cooldown"
run_engine --harvest "$M9" --out "$TDIR/o-artifact.md" --timeout 5s
rm -f "$TDIR/home/throttle.cooldown"
check 'artifact-first recovery exits 0 (even under cooldown, no ledger row)' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
check 'artifact content returned verbatim' "$(cmp -s "$TDIR/o-artifact.md" "$TDIR/prov-ours.md"; echo $?)" "$(head -2 "$TDIR/o-artifact.md" 2>/dev/null)"

echo '# v0.28: unbindable captures fail closed when the nonce was promised'
M11="pg-run-unbound-1-1700000041-33"
printf '1\t%s\t%s\t0\t1\tGPT-X\n' "$TDIR/o-unbound.md" "$(date +%s)" > "$TDIR/home/in-progress/$M11"
printf 'src/real.sh\n' > "$TDIR/home/manifests/$M11"
: > "$TDIR/home/manifests/$M11.nonce"
cat > "$TDIR/tab.txt" <<TAB
conversation for run marker: $M11
P0: none

[P1] callers/context-only.ts:5 — single citation, no echo

VERDICT: FIX-FIRST — ambiguous
TAB
start_mock "$TDIR/tab.txt"
run_engine --harvest "$M11" --out "$TDIR/o-unbound.md" --timeout 5s
check 'promised-nonce absent + 1 citation fails closed (exit 9)' "$([ "$RC" -eq 9 ] && grep -q 'unbind\|cannot be bound' "$TDIR/stderr"; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
check 'unbindable capture set aside, reservation kept' "$(ls "$TDIR/o-unbound.md.unbound."* >/dev/null 2>&1 && [ -f "$TDIR/home/in-progress/$M11" ]; echo $?)" "$(ls "$TDIR" 2>/dev/null | grep unbound)"
env PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_REQUIRE_NONCE=0 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$M11" --out "$TDIR/o-unbound.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'PRO_GATE_REQUIRE_NONCE=0 restores best-effort acceptance' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"

echo '# v0.28: digest mismatch rejects an overwritten ledgered source'
M10="pg-run-digest-2-1700000036-11"
cp "$TDIR/prior-collected.md" "$TDIR/overwritten-prior.md"
printf '{"ts":"2026-01-07T00:00:00+0000","pr":"2","repo":"/tmp/x","exit":0,"outcome":"clean","secs":10,"attempts":0,"conc":0,"ceiling":1,"live":1,"salvaged":1,"diff_lines":4,"out":"%s","model":"m","marker":"%s","round_key":"digest-2","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}\n' "$TDIR/overwritten-prior.md" "$M10" >> "$TDIR/home/ledger.jsonl"
run_engine --harvest "$M10" --out "$TDIR/o-digest.md" --timeout 5s
check 'overwritten ledgered source rejected by digest (exit 6)' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"

echo '# v0.28: already-collected harvest returns the ledgered review idempotently'
M4="pg-run-collected-5-1700000031-55"
cat > "$TDIR/prior-collected.md" <<'PC'
P0: none

[P1] x.sh:1 — finding

VERDICT: SHIP — fine
PC
M4SHA="$(sha256sum "$TDIR/prior-collected.md" | awk '{print $1}')"
printf '{"ts":"2026-01-05T00:00:00+0000","pr":"5","repo":"/tmp/x","exit":0,"outcome":"clean","secs":10,"attempts":0,"conc":0,"ceiling":1,"live":1,"salvaged":1,"diff_lines":4,"out":"%s","model":"m","marker":"%s","round_key":"collected-5","sha256":"%s"}\n' "$TDIR/prior-collected.md" "$M4" "$M4SHA" >> "$TDIR/home/ledger.jsonl"
printf 'idle tab with no markers at all\n' > "$TDIR/tab.txt"
run_engine --harvest "$M4" --out "$TDIR/o-already.md" --timeout 5s
check 'digest-verified already-collected harvest exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'already-collected returns the prior review' "$(cmp -s "$TDIR/o-already.md" "$TDIR/prior-collected.md"; echo $?)" "$(head -2 "$TDIR/o-already.md" 2>/dev/null)"
# A pre-v0.28 row WITHOUT a digest cannot prove the mutable path still holds the collected
# review (gate #54 r3): report for manual recovery (exit 6, never respend), never copy it.
M4L="pg-run-legacyrow-5-1700000040-22"
printf '{"ts":"2026-01-05T01:00:00+0000","pr":"5","repo":"/tmp/x","exit":0,"outcome":"clean","secs":10,"attempts":0,"conc":0,"ceiling":1,"live":1,"salvaged":1,"diff_lines":4,"out":"%s","model":"m","marker":"%s","round_key":"legacyrow-5"}\n' "$TDIR/prior-collected.md" "$M4L" >> "$TDIR/home/ledger.jsonl"
run_engine --harvest "$M4L" --out "$TDIR/o-legacy.md" --timeout 5s
check 'digest-less legacy row routes to manual recovery (exit 6)' "$([ "$RC" -eq 6 ] && grep -q 'MANUAL' "$TDIR/stderr"; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
# Pre-existing $OUT content must never pass as proof of collection (gate #54 P1): with the
# ledgered source gone, a stale review already sitting at --out stays rejected (exit 6).
M6="pg-run-staleout-8-1700000033-77"
printf '{"ts":"2026-01-06T00:00:00+0000","pr":"8","repo":"/tmp/x","exit":0,"outcome":"clean","secs":10,"attempts":0,"conc":0,"ceiling":1,"live":1,"salvaged":1,"diff_lines":4,"out":"%s","model":"m","marker":"%s","round_key":"staleout-8"}\n' "$TDIR/deleted-prior.md" "$M6" >> "$TDIR/home/ledger.jsonl"
cp "$TDIR/prior-collected.md" "$TDIR/o-stale.md"
run_engine --harvest "$M6" --out "$TDIR/o-stale.md" --timeout 5s
check 'stale OUT content never passes as collected (exit 6)' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
# Without a ledgered copy the same state is still a loss (exit 6), as before.
M5="pg-run-lostcase-6-1700000032-66"
run_engine --harvest "$M5" --out "$TDIR/o-lost.md" --timeout 5s
check 'absent reservation without ledger row still exits 6' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"

echo '# v0.28: early URL capture + change manifest on a fresh run'
cat > "$TDIR/bin/oracle-early" <<EARLY
#!/usr/bin/env bash
M="\$(printf '%s\n' "\$@" | grep -oE 'pg-run-[A-Za-z0-9.-]+' | head -1)"
printf 'still thinking, run marker: %s\n' "\$M" > "$TDIR/tab.txt"
sleep 6
exit 1
EARLY
chmod +x "$TDIR/bin/oracle-early"
printf 'no marker yet\n' > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
rm -rf "$TDIR/home/conversation-urls"; mkdir -p "$TDIR/home/in-progress"
env PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 PRO_GATE_EARLY_PROBE_SECS=1 \
  PRO_GATE_STALL_SECS=5 PRO_GATE_NOTHINK_SECS=30 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-early" NODE_OPTIONS= \
  bash "$ENGINE" --pr 120 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$TDIR/o-early.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'early-capture run preserves as in-progress (exit 9)' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'conversation URL memo written DURING generation' "$(ls "$TDIR/home/conversation-urls/" 2>/dev/null | grep -q 'pg-run-'; echo $?)" "$(ls "$TDIR/home/conversation-urls/" 2>/dev/null)"
EARLY_MARKER="$(ls "$TDIR/home/in-progress/" 2>/dev/null | grep -m1 -E 'pg-run-.*-120-')"
check 'change manifest written beside the reservation' "$([ -n "$EARLY_MARKER" ] && [ -s "$TDIR/home/manifests/$EARLY_MARKER" ]; echo $?)" "manifests: $(ls "$TDIR/home/manifests" 2>/dev/null)"
check 'nonce expectation flag recorded' "$([ -n "$EARLY_MARKER" ] && [ -f "$TDIR/home/manifests/$EARLY_MARKER.nonce" ]; echo $?)" "manifests: $(ls "$TDIR/home/manifests" 2>/dev/null)"

echo '# v0.28: direct capture with an echoed nonce is stripped before output'
cat > "$TDIR/bin/oracle-nonce" <<'NONCE'
#!/usr/bin/env bash
out=""; m=""
while [ $# -gt 0 ]; do
  case "$1" in
    --write-output) out="$2"; shift 2;;
    *) m2="$(printf '%s\n' "$1" | grep -oE 'pg-run-[A-Za-z0-9.-]+' | head -1)"; [ -n "$m2" ] && m="$m2"; shift;;
  esac
done
printf '[P1] a.sh:1 - finding\n  Why: test\nP2: none\nP3: none\nVERDICT: SHIP - fixture. (run marker: %s)\n' "$m" > "$out"
NONCE
chmod +x "$TDIR/bin/oracle-nonce"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
# Own home: $TDIR/home carries the early-capture test's live exit-9 reservation, whose
# recorded slot would (correctly) exclude this fresh run and park it in the account-slot
# queue for the whole lock wait.
mkdir -p "$TDIR/home-nonce"
env PRO_GATE_HOME="$TDIR/home-nonce" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-nonce" NODE_OPTIONS= \
  bash "$ENGINE" --pr 131 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$TDIR/o-directnonce.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'direct nonce capture exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'direct capture nonce stripped' "$(grep -q 'run marker' "$TDIR/o-directnonce.md"; [ $? -ne 0 ]; echo $?)" "$(tail -1 "$TDIR/o-directnonce.md" 2>/dev/null)"

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILURES"; exit 1; }
