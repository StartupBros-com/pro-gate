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
mkdir -p "$TDIR/home" "$TDIR/bin"
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
[ -n "${PG_TEST_EVIDENCE:-}" ] && printf '%s\n' "$PG_TEST_EVIDENCE"
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
check 'select still passes -m requested hint' "$(grep -q -- '-m gpt-5.5-pro' "$TDIR/argv-sel.txt"; echo $?)" "argv=$(head -1 "$TDIR/argv-sel.txt")"

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
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean.\n'
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
prompt=""; out=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; --write-output) out="$2"; shift 2;; *) shift;; esac; done
marker="$(printf '%s' "$prompt" | sed -nE 's/.*run marker: (pg-run-[A-Za-z0-9.-]+).*/\1/p' | tail -1)"
printf 'run marker: %s\nReasoning continuously; no verdict yet.\n' "$marker" > "$PG_TEST_TAB_FILE"
echo 'Launching browser mode'
echo 'Acquired ChatGPT browser slot'
echo 'Session: fake-lateev'
sleep 30
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

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILURES"; exit 1; }
