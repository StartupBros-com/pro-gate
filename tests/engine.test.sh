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

start_mock() { # $1 = tab text file; optional $2 = organizer state file; sets MOCK_PID + PORT
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
  node "$HERE/mock-cdp.mjs" "$1" "${2:-}" > "$TDIR/port" 2>"$TDIR/mock.log" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do [ -s "$TDIR/port" ] && break; sleep 0.1; done
  PORT="$(tr -d '[:space:]' < "$TDIR/port")"; : > "$TDIR/port"
}

# v0.35 (#88): a PATH that resolves every already-installed external tool this suite needs
# EXCEPT jq, built once and reused by every printf-fallback/no-jq scenario. A merely-narrowed
# PATH (e.g. /usr/bin:/bin) is not enough on hosts where jq is ALSO installed system-wide
# (not just via a user PATH entry) — this symlinks every executable regular file found under
# the standard bin directories, skipping jq by name, so `command -v jq` genuinely fails while
# every other tool oracle-review.sh needs still resolves.
NOJQ_DIR="$TDIR/nojq-bin"
build_nojq_path() {
  [ -d "$NOJQ_DIR" ] && return 0
  mkdir -p "$NOJQ_DIR"
  for d in /usr/bin /bin /usr/local/bin /opt/homebrew/bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b="$(basename "$f")"
      [ "$b" = jq ] && continue
      [ -f "$f" ] && [ -x "$f" ] || continue
      ln -sf "$f" "$NOJQ_DIR/$b" 2>/dev/null || true
    done
  done
}

MARKER="pg-run-77-1700000000-11"
run_engine() { # args... ; captures RC
  PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
    PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
    bash "$ENGINE" "$@" >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
}

# Opt-in timeout shim for lifecycle assertions. Set PRO_GATE_TIMEOUT_BIN to this wrapper and
# PG_TEST_NODE_ARGS to a log file; it records only organizer subprocesses, then preserves timeout.
REAL_TIMEOUT=/usr/bin/timeout
TIMEOUT_LOG_BIN="$TDIR/timeout-log"
cat > "$TIMEOUT_LOG_BIN" <<TIMEOUT_LOG
#!/usr/bin/env bash
: >> "\${PG_TEST_NODE_ARGS:?}"
case " \$* " in
  *' --organize '*) printf '%s\n' "\$*" >> "\$PG_TEST_NODE_ARGS" ;;
esac
exec "$REAL_TIMEOUT" "\$@"
TIMEOUT_LOG
chmod +x "$TIMEOUT_LOG_BIN"

echo '# hard-ceiling refusal (exit 11): only diffs past PRO_GATE_DIFF_HARD_MAX are refused'
printf 'still thinking, run marker: %s\n' "$MARKER" > "$TDIR/tab.txt"
ORGANIZER_STATE="$TDIR/organizer-state.json"
ORGANIZER_TITLE='pro-gate review: PR #77 r1 [engine-fixture]'
printf '{"title":null,"archived":false,"events":[]}\n' > "$ORGANIZER_STATE"
mkdir -p "$TDIR/home/conversation-titles"
printf '%s\n' "$ORGANIZER_TITLE" > "$TDIR/home/conversation-titles/$MARKER"
start_mock "$TDIR/tab.txt" "$ORGANIZER_STATE"
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
check 'exit-9 organizer exact-renames the owned conversation' "$([ "$(jq -r .title "$ORGANIZER_STATE")" = "$ORGANIZER_TITLE" ]; echo $?)" "$(cat "$ORGANIZER_STATE")"
check 'exit-9 organizer never archives' "$([ "$(jq -r .archived "$ORGANIZER_STATE")" = false ]; echo $?)" "$(cat "$ORGANIZER_STATE")"
check 'exit-9 organizer performs rename only' "$([ "$(jq -r '[.events[].action] | join(",")' "$ORGANIZER_STATE")" = rename ]; echo $?)" "$(cat "$ORGANIZER_STATE")"
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
check 'still-generating probe keeps the reservation occupying capacity' "$([ "$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_state '$MARKER'")" = generating ]; echo $?)" "$(cat "$TDIR/home/in-progress/$MARKER")"

# ChatGPT keeps conversations server-side forever, so a FINISHED review probes as present on
# every sweep and used to hold its slot for the whole 6h TTL — at effective concurrency 1 a
# single uncollected review starved every other run (#82). Completion must release the capacity
# while KEEPING the record collectable.
echo '# reservation releases capacity once its review is complete'
printf 'run marker: %s\nP0: none\n\nVERDICT: SHIP — looks good.\n' "$MARKER" > "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home" PRO_GATE_RESERVATION_MISSES=3 PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_reconcile '$HERE/../bin/cdp-salvage.mjs' '$PORT'"
check 'complete probe marks the reservation complete' "$([ "$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_state '$MARKER'")" = complete ]; echo $?)" "$(cat "$TDIR/home/in-progress/$MARKER")"
check 'completed reservation survives as a harvest pointer' "$([ -f "$TDIR/home/in-progress/$MARKER" ]; echo $?)" 'record removed instead of released'
check 'completed reservation keeps its out path' "$(awk -F'\t' 'NR==1{exit !($2 != "")}' "$TDIR/home/in-progress/$MARKER"; echo $?)" "$(cat "$TDIR/home/in-progress/$MARKER")"
check 'completed reservation stops consuming a slot' "$([ "$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_slot_plan 1" | cut -d'|' -f3)" = 1 ]; echo $?)" "plan=$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_slot_plan 1")"

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
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean enough. (run marker: %s)\n' "$MARKER"
} > "$TDIR/tab.txt"
run_engine --harvest "$MARKER" --out "$TDIR/o-h2.md" --timeout 30s
check 'harvest done exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'harvest done phase' "$([ "$(phase_of "$TDIR/o-h2.md.status")" = done ]; echo $?)" "$(cat "$TDIR/o-h2.md.status" 2>/dev/null)"
check 'harvest writes the review' "$(grep -q 'VERDICT: SHIP' "$TDIR/o-h2.md"; echo $?)" "$(head -c 200 "$TDIR/o-h2.md" 2>/dev/null)"
check 'harvest closes the tab' "$(grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "$(cat "$TDIR/mock.log")"
check 'durable harvest archives the server conversation' "$([ "$(jq -r .archived "$ORGANIZER_STATE")" = true ]; echo $?)" "$(cat "$ORGANIZER_STATE")"
check 'durable harvest organizes rename before archive' "$([ "$(jq -r '[.events[].action] | join(",")' "$ORGANIZER_STATE")" = 'rename,archive' ]; echo $?)" "$(cat "$ORGANIZER_STATE")"
check 'durable harvest has marker-addressed completed bytes before cleanup' "$([ -s "$TDIR/home/completed/$MARKER" ] && cmp -s "$TDIR/home/completed/$MARKER" "$TDIR/o-h2.md"; echo $?)" "completed=$(ls "$TDIR/home/completed" 2>/dev/null)"
check 'successful harvest releases reservation' "$([ ! -f "$TDIR/home/in-progress/$MARKER" ]; echo $?)" "reservation leaked"
# U1 (R1/R3): a harvest never queues for a slot — it reads an existing/in-progress conversation
# over CDP — so its ledger row must carry pre_slot_secs=0 and post_slot_secs equal to the row's own secs
# (the harvest's own short wall time), never reconstructed from a generation epoch it has none of.
H2_ROW="$(grep -F "\"out\":\"$TDIR/o-h2.md\"" "$TDIR/home/ledger.jsonl" | tail -1)"
check 'harvest ledger row is valid JSON' "$(printf '%s' "$H2_ROW" | jq empty >/dev/null 2>&1; echo $?)" "$H2_ROW"
check 'harvest ledger row records pre_slot_secs=0' "$([ "$(printf '%s' "$H2_ROW" | jq -r '.pre_slot_secs // "MISSING"')" = 0 ]; echo $?)" "$H2_ROW"
check 'harvest ledger row records post_slot_secs == secs' "$([ "$(printf '%s' "$H2_ROW" | jq -r '.post_slot_secs // "MISSING"')" = "$(printf '%s' "$H2_ROW" | jq -r .secs)" ]; echo $?)" "$H2_ROW"

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
check 'tagged slot 1 at eff 2 excludes slot 1' "$([ "$(plan 2)" = '2|1|1' ]; echo $?)" "plan=$(plan 2)"
printf 'k2\to2\t100\t0\t\n' > "$TDIR/home2/in-progress/pg-run-b-2-2"
check 'legacy reservation shrinks the range' "$([ "$(plan 2)" = '1|1|0' ]; echo $?)" "plan=$(plan 2)"
rm -f "$TDIR/home2/in-progress/pg-run-a-1-1"
printf 'k3\to3\t100\t0\t5\n' > "$TDIR/home2/in-progress/pg-run-c-3-3"
check 'out-of-range tagged slot shrinks the range' "$([ "$(plan 2)" = '0||0' ]; echo $?)" "plan=$(plan 2)"
rm -rf "$TDIR/home2"

# The scan upper bound is NOT the available count: at effective 1 a slot-1 reservation leaves an
# EMPTY scannable set, yet the legacy two-field encoding reported "1|1". Callers gating on that
# first field believed they had capacity, called pg_lock_n against an impossible plan every wait
# slice, and reported "all N review slots are busy" while the locks were provably free
# (incident #82: five runs starved 40m against an idle account). Field 3 is the true count.
echo '# slot plan: available count is explicit and state-aware'
mkdir -p "$TDIR/home2/in-progress"
avail(){ PRO_GATE_HOME="$TDIR/home2" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_slot_plan $1" | cut -d'|' -f3; }
printf 'k1\to1\t100\t0\t1\t\t\tgenerating\n' > "$TDIR/home2/in-progress/pg-run-a-1-1"
check 'generating reservation at eff 1 leaves zero available' "$([ "$(avail 1)" = '0' ]; echo $?)" "available=$(avail 1)"
check 'generating reservation at eff 2 leaves one available' "$([ "$(avail 2)" = '1' ]; echo $?)" "available=$(avail 2)"
# A finished review is a harvest pointer, not account occupancy: it must not hold a slot.
printf 'k1\to1\t100\t0\t1\t\t\tcomplete\n' > "$TDIR/home2/in-progress/pg-run-a-1-1"
check 'complete reservation frees its slot at eff 1' "$([ "$(avail 1)" = '1' ]; echo $?)" "available=$(avail 1)"
# Legacy records predate the state field and must fail CLOSED (occupying), never open.
printf 'k1\to1\t100\t0\t1\n' > "$TDIR/home2/in-progress/pg-run-a-1-1"
check 'legacy record without state still holds capacity' "$([ "$(avail 1)" = '0' ]; echo $?)" "available=$(avail 1)"
# "A reservation exists" and "capacity is reserved" stopped being the same question. A slot
# timeout caused by genuinely busy runs must not be blamed on a completed record holding nothing.
holding(){ PRO_GATE_HOME="$TDIR/home2" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_holding_count"; }
counted(){ PRO_GATE_HOME="$TDIR/home2" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_count"; }
check 'legacy record counts as holding capacity' "$([ "$(holding)" = '1' ]; echo $?)" "holding=$(holding)"
printf 'k1\to1\t100\t0\t1\t\t\tcomplete\n' > "$TDIR/home2/in-progress/pg-run-a-1-1"
check 'complete record is collectable but holds nothing' "$([ "$(counted)" = '1' ] && [ "$(holding)" = '0' ]; echo $?)" "counted=$(counted) holding=$(holding)"
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
# U1 (R1/R3): a completed fresh run's ledger row carries pre_slot_secs/post_slot_secs BY NAME alongside
# the unchanged secs field, and the two parts sum back to secs exactly (shared "now" epoch).
SLOTS2_ROW="$(grep -F "\"out\":\"$TDIR/o-slots2.md\"" "$TDIR/home3/ledger.jsonl" | tail -1)"
check 'happy-path ledger row is valid JSON' "$(printf '%s' "$SLOTS2_ROW" | jq empty >/dev/null 2>&1; echo $?)" "$SLOTS2_ROW"
check 'happy-path ledger row carries pre_slot_secs + post_slot_secs' "$(printf '%s' "$SLOTS2_ROW" | jq -e 'has("pre_slot_secs") and has("post_slot_secs") and has("secs")' >/dev/null 2>&1; echo $?)" "$SLOTS2_ROW"
check 'happy-path pre_slot_secs + post_slot_secs equals secs' "$([ "$(printf '%s' "$SLOTS2_ROW" | jq -r '(.pre_slot_secs // "MISSING") as $q | (.post_slot_secs // "MISSING") as $r | if ($q == "MISSING" or $r == "MISSING") then "MISSING" else ($q + $r) end')" = "$(printf '%s' "$SLOTS2_ROW" | jq -r .secs)" ]; echo $?)" "$SLOTS2_ROW"
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

freshrun() { # $1=home $2=argv-file $3=evidence $4=out [strategy] [legacy browser archive]
  rm -rf "$1"; mkdir -p "$1/in-progress"; : > "$2"; printf 'foreign idle tab\n' > "$TDIR/tab.txt"
  PRO_GATE_HOME="$1" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
    PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
    PRO_GATE_MODEL_STRATEGY="${5:-current}" PRO_GATE_BROWSER_ARCHIVE="${6:-never}" \
    PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-evidence" \
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
freshrun "$TDIR/home-u1c" "$TDIR/argv-archive.txt" "$EV_PRO" "$TDIR/o-u1c.md" current always
check 'explicit PRO_GATE_BROWSER_ARCHIVE passes through unchanged' "$(grep -q -- '--browser-archive always' "$TDIR/argv-archive.txt"; echo $?)" "argv=$(head -1 "$TDIR/argv-archive.txt")"

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
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean. (run marker: %s)\n' "$MKL"
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
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean. (run marker: %s)\n' "$MKW"
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
# v0.31 (#65): the same completion appends a trajectory-history row the governor scores.
check 'completed review appends hist row (verdict + open counts)' \
  "$([ "$(awk -F'\t' 'NR==1{print $2" "$3" "$4" "$5" "$6}' "$RHOME/rounds/$RKEY_88.hist" 2>/dev/null)" = 'SHIP 0 1 0 0' ]; echo $?)" \
  "hist: $(cat "$RHOME/rounds/$RKEY_88.hist" 2>/dev/null)"
check 'completed review hist row has a seventh wall-clock field' \
  "$(awk -F'\t' 'NR==1{exit !(NF == 7 && $7 >= 0 && $7 < 86400)}' "$RHOME/rounds/$RKEY_88.hist" 2>/dev/null; echo $?)" \
  "hist: $(cat "$RHOME/rounds/$RKEY_88.hist" 2>/dev/null)"
# The history parser shares pg_is_review's hardened terminal matcher (bold/bullet formatting).
printf '[P1] a.sh:1 - finding\n  Why: test\nP2: none\nP3: none\n**VERDICT:** FIX-FIRST - formatted.\n' > "$RHOME/formatted-review.md"
PRO_GATE_HOME="$RHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_note_severity '$RKEY_88' '$RHOME/formatted-review.md'"
check 'formatted verdict records FIX-FIRST (shared hardened parser)' \
  "$([ "$(awk -F'\t' 'END{print $2}' "$RHOME/rounds/$RKEY_88.hist")" = FIX-FIRST ]; echo $?)" \
  "hist: $(tail -1 "$RHOME/rounds/$RKEY_88.hist")"
# Remove the synthetic parser-only row so the live round sequence below stays 1:1.
head -n 1 "$RHOME/rounds/$RKEY_88.hist" > "$RHOME/rounds/$RKEY_88.hist.tmp" && mv "$RHOME/rounds/$RKEY_88.hist.tmp" "$RHOME/rounds/$RKEY_88.hist"
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
# U1 (R1/R3): a run that never reaches launch (this lock-timeout never even gets to the slot
# wait) records its FULL wait as pre_slot_secs with post_slot_secs 0 — LAUNCH_EPOCH is never set.
DLOCK_ROW="$(grep -F "\"out\":\"$RHOME/o-dlock.md\"" "$RHOME/ledger.jsonl" | tail -1)"
check 'lock-timeout ledger row records post_slot_secs=0' "$([ "$(printf '%s' "$DLOCK_ROW" | jq -r '.post_slot_secs // "MISSING"')" = 0 ]; echo $?)" "$DLOCK_ROW"
check 'lock-timeout ledger row records its full wait as pre_slot_secs (>= 2s of the 3s PRO_GATE_LOCK_WAIT)' "$(printf '%s' "$DLOCK_ROW" | jq -e '(.pre_slot_secs // -1) >= 2' >/dev/null 2>&1; echo $?)" "$DLOCK_ROW"
check 'lock-timeout pre_slot_secs + post_slot_secs equals secs' "$([ "$(printf '%s' "$DLOCK_ROW" | jq -r '(.pre_slot_secs // "MISSING") as $q | (.post_slot_secs // "MISSING") as $r | if ($q == "MISSING" or $r == "MISSING") then "MISSING" else ($q + $r) end')" = "$(printf '%s' "$DLOCK_ROW" | jq -r .secs)" ]; echo $?)" "$DLOCK_ROW"
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

echo '# v0.30.1 hygiene close-out: legacy-named logs, daemon/service logs, title-seq, blacklist'
mkdir -p "$RHOME/logs" "$RHOME/title-seq"
touch "$RHOME/logs/pg-run-fresh.log"
printf 'x\n' > "$RHOME/logs/legacy-owner-repo-4-1782771272.log"
printf 'x\n' > "$RHOME/logs/autoupdate.log"
printf 'x\n' > "$RHOME/logs/daemon.err.log"
printf '7' > "$RHOME/title-seq/idle-key"
touch -d '20 days ago' "$RHOME/logs/legacy-owner-repo-4-1782771272.log" "$RHOME/logs/autoupdate.log" "$RHOME/logs/daemon.err.log" "$RHOME/title-seq/idle-key" 2>/dev/null \
  || touch -t 202001010000 "$RHOME/logs/legacy-owner-repo-4-1782771272.log" "$RHOME/logs/autoupdate.log" "$RHOME/logs/daemon.err.log" "$RHOME/title-seq/idle-key"
seq 1 1200 > "$RHOME/salvage-nonmatching.txt"
roundrun 89 "$RHOME/o-hyg.md"
check 'hygiene run exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'legacy epoch-named run log is swept' "$([ ! -f "$RHOME/logs/legacy-owner-repo-4-1782771272.log" ]; echo $?)" "logs: $(ls "$RHOME/logs" 2>/dev/null)"
check 'autoupdate.log survives the log sweep' "$([ -f "$RHOME/logs/autoupdate.log" ]; echo $?)" 'autoupdate.log deleted'
check 'launchd daemon log survives the log sweep (gate P1)' "$([ -f "$RHOME/logs/daemon.err.log" ]; echo $?)" 'daemon.err.log deleted'
check 'fresh pg-run log survives the sweep' "$([ -f "$RHOME/logs/pg-run-fresh.log" ]; echo $?)" 'fresh log deleted'
check 'idle title-seq counter is NEVER swept (gate P2: monotonic ordinal)' "$([ -f "$RHOME/title-seq/idle-key" ] && [ "$(cat "$RHOME/title-seq/idle-key")" = '7' ]; echo $?)" "title-seq: $(ls "$RHOME/title-seq" 2>/dev/null)"
# gate r2 P1: the multi-writer blacklist is append-only BY DESIGN — housekeeping must not
# compact it (a read->rename trim can drop a concurrent append; see the engine comment).
check 'salvage blacklist is NEVER compacted by housekeeping' "$([ "$(wc -l < "$RHOME/salvage-nonmatching.txt")" -eq 1200 ]; echo $?)" "lines=$(wc -l < "$RHOME/salvage-nonmatching.txt" 2>/dev/null)"

echo '# v0.31 (#65): trajectory-aware round governor'
GHOME="$TDIR/home-governor"; mkdir -p "$GHOME/rounds"
GEPOCH="$(date +%s)"
gseed() { # $1=key $2=spends; rows all in-window
  : > "$GHOME/rounds/$1"
  local i=0; while [ "$i" -lt "$2" ]; do printf '%s\n' "$GEPOCH" >> "$GHOME/rounds/$1"; i=$(( i + 1 )); done
}
ghist() { # $1=key, rest = open-P1 counts per completed round (P0 held at 0)
  local key="$1" n; shift
  : > "$GHOME/rounds/$key.hist"
  for n in "$@"; do printf '%s\tFIX-FIRST\t0\t%s\t0\t0\n' "$GEPOCH" "$n" >> "$GHOME/rounds/$key.hist"; done
}
gguard() { # $1=key, rest = env overrides; stdout = reason, rc = guard rc
  local key="$1"; shift
  env PRO_GATE_HOME="$GHOME" "$@" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_guard '$key'"
}
gscore() { # $1=key -> "earned<TAB>streak<TAB>elapsed_secs<TAB>scored" from pg_round_score
  env PRO_GATE_HOME="$GHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_score '$1'; printf '%s\t%s\t%s\t%s\n' \"\$PG_ROUND_EARNED\" \"\$PG_ROUND_STREAK\" \"\$PG_ROUND_ELAPSED_SECS\" \"\$PG_ROUND_SCORED\""
}
# No history: the base grant (3) is the whole budget.
gseed nohist 3
GOUT="$(gguard nohist)"; GRC=$?
check 'governor: base grant refuses round 4 without earned rounds' "$([ "$GRC" -eq 1 ]; echo $?)" "rc=$GRC out=$GOUT"
check 'governor: exhaustion reason names base + earned + ceiling' "$(printf '%s' "$GOUT" | grep -q 'base 3 + 0 earned'; echo $?)" "$GOUT"
gseed nohist 2
gguard nohist >/dev/null; GRC=$?
check 'governor: round 3 of base 3 proceeds' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC"
# Shrinking trajectory earns extra rounds: open 5 -> 3 -> 1 = +2 earned (grant 5).
gseed shrink 4; ghist shrink 5 3 1
gguard shrink >/dev/null; GRC=$?
check 'governor: shrinking trajectory earns round 5' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC $(gguard shrink)"
gseed shrink 5
GOUT="$(gguard shrink)"; GRC=$?
check 'governor: earned grant still exhausts (5/5)' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q '5/5 rounds'; echo $?)" "rc=$GRC out=$GOUT"
# Churn brake: two consecutive non-shrinking re-reviews stop the loop EARLY (before base).
gseed churn 3; ghist churn 5 7 8
GOUT="$(gguard churn)"; GRC=$?
check 'governor: churn brake refuses (not converging)' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q 'churning, not converging'; echo $?)" "rc=$GRC out=$GOUT"
check 'governor: churn reason carries the trajectory arrow' "$(printf '%s' "$GOUT" | grep -q '5→7→8'; echo $?)" "$GOUT"
# A recovery round (shrink after churn) resets the streak: 5 -> 7 -> 8 -> 2 is earning again.
ghist churn 5 7 8 2
gguard churn >/dev/null; GRC=$?
check 'governor: a shrinking round releases the brake' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC $(gguard churn)"
# Ceiling is immovable: 10 shrinking rounds cannot out-earn it.
gseed marathon 8; ghist marathon 20 18 16 14 12 10 8 6 4 2 1
GOUT="$(gguard marathon)"; GRC=$?
check 'governor: ceiling 8 caps any earned run' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q 'ceiling 8'; echo $?)" "rc=$GRC out=$GOUT"
# Explicitly-set flat cap pins legacy behavior: churn trajectory is ignored.
gseed flatkey 3; ghist flatkey 5 7 8
gguard flatkey PRO_GATE_MAX_ROUNDS_PER_PR=4 >/dev/null; GRC=$?
check 'flat mode: explicit cap ignores the trajectory' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC"
GOUT="$(gguard flatkey PRO_GATE_MAX_ROUNDS_PER_PR=3)"; GRC=$?
check 'flat mode: explicit cap still enforces its number' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q '3/3 slot-spending'; echo $?)" "rc=$GRC out=$GOUT"
# Base 0 keeps the lockdown reading in governor mode.
GOUT="$(gguard nohist PRO_GATE_ROUNDS_BASE=0)"; GRC=$?
check 'governor: base 0 is a lockdown' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q 'PRO_GATE_ROUNDS_BASE=0'; echo $?)" "rc=$GRC out=$GOUT"
# #66 gate P1: a base above the ceiling clamps the BASE DOWN — the ceiling never moves.
gseed clampkey 8
GOUT="$(gguard clampkey PRO_GATE_ROUNDS_BASE=10 PRO_GATE_ROUNDS_CEILING=8 2>/dev/null)"; GRC=$?
check 'governor: base above ceiling cannot raise the ceiling' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q '8/8 rounds'; echo $?)" "rc=$GRC out=$GOUT"
GERR="$(gguard clampkey PRO_GATE_ROUNDS_BASE=10 PRO_GATE_ROUNDS_CEILING=8 2>&1 >/dev/null)"
check 'governor: base clamp warns loudly' "$(printf '%s' "$GERR" | grep -q 'clamping the base to the ceiling'; echo $?)" "$GERR"
# pg_round_grant mirrors the guard for --status: churn collapses remaining to 0.
gseed churn2 3; ghist churn2 5 7 8
GOUT="$(env PRO_GATE_HOME="$GHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_grant churn2")"
check 'grant: churn brake collapses the grant to spent' "$([ "$GOUT" = 3 ]; echo $?)" "grant=$GOUT"

echo '# ledger-timing-split R4: MIXED 6-field (pre-upgrade) and 7-field (post-upgrade) .hist rows'
# pg_round_note_severity copies existing .hist lines through VERBATIM and appends only the new
# row as 7 fields, so every change with pre-existing rounds has a MIXED-width file on first
# upgrade to the ledger-timing-split fields. That real state was previously untested: every
# existing fixture in this suite is uniformly 6-field (ghist above) or uniformly 7-field
# (RKEY_90 below). Same open-count sequence as the 'shrink' fixture (5 -> 3 -> 1) so trajectory
# scoring is directly comparable; only the row WIDTH differs.
gseed mixedhist 3
{
  printf '%s\tFIX-FIRST\t0\t5\t0\t0\n' "$GEPOCH"          # legacy 6-field row: no field 7 at all
  printf '%s\tFIX-FIRST\t0\t3\t0\t0\t1800\n' "$GEPOCH"    # 7-field row: dur=1800s
  printf '%s\tFIX-FIRST\t0\t1\t0\t0\t3600\n' "$GEPOCH"    # 7-field row: dur=3600s
} > "$GHOME/rounds/mixedhist.hist"
MIXROW="$(gscore mixedhist)"
MIX_EARNED="$(printf '%s' "$MIXROW" | cut -f1)"
MIX_STREAK="$(printf '%s' "$MIXROW" | cut -f2)"
MIX_ELAPSED="$(printf '%s' "$MIXROW" | cut -f3)"
MIX_SCORED="$(printf '%s' "$MIXROW" | cut -f4)"
# (a) trajectory scoring (earned/streak) is unaffected by row width — same 5->3->1 sequence as
# the 'shrink' fixture earns 2 rounds with a reset (non-churning) streak, exactly as it does
# when every row is uniformly 7-field.
check 'mixed-width .hist: trajectory scoring matches the pure 7-field sequence (2 earned, streak 0)' \
  "$([ "$MIX_EARNED" = 2 ] && [ "$MIX_STREAK" = 0 ]; echo $?)" "earned=$MIX_EARNED streak=$MIX_STREAK"
# (b) PG_ROUND_ELAPSED_SECS sums only the two 7-field durations (1800+3600=5400); the legacy
# 6-field row contributes 0 rather than breaking the scan. PG_ROUND_SCORED counts all THREE
# in-window rows regardless of width — the distinction FIX 1 exists to make visible.
check 'mixed-width .hist: elapsed sums only the 7-field durations, legacy row as 0' \
  "$([ "$MIX_ELAPSED" = 5400 ]; echo $?)" "elapsed=$MIX_ELAPSED"
check 'mixed-width .hist: scored count includes every in-window row (legacy + 7-field)' \
  "$([ "$MIX_SCORED" = 3 ]; echo $?)" "scored=$MIX_SCORED"
gguard mixedhist >/dev/null; GRC=$?
check 'mixed-width .hist: governor still proceeds normally (earned round available)' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC"

echo '# v0.31 (#65): governor integration — engine exit 12 carries the trajectory'
RKEY_90="$(printf '%s-90' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
mkdir -p "$RHOME/rounds"
: > "$RHOME/rounds/$RKEY_90"; for _ in 1 2 3; do printf '%s\n' "$(date +%s)" >> "$RHOME/rounds/$RKEY_90"; done
printf '%s\tFIX-FIRST\t0\t5\t0\t0\t3600\n%s\tFIX-FIRST\t0\t7\t0\t0\t3600\n%s\tFIX-FIRST\t0\t8\t0\t0\t3600\n' \
  "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$RHOME/rounds/$RKEY_90.hist"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-ok" NODE_OPTIONS= \
  bash "$ENGINE" --pr 90 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-gov.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'governor engine run: churn exits 12' "$([ "$RC" -eq 12 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'governor engine run: phase round-capped' "$([ "$(phase_of "$RHOME/o-gov.md.status")" = round-capped ]; echo $?)" "$(cat "$RHOME/o-gov.md.status" 2>/dev/null)"
check 'governor engine run: status detail carries the trajectory arrow' "$(grep -q '5→7→8' "$RHOME/o-gov.md.status"; echo $?)" "$(cat "$RHOME/o-gov.md.status" 2>/dev/null)"
check 'governor engine refusal names rounds used and wall clock' \
  "$(grep -q '3 rounds; ~3.0h recorded across 3 scored round(s)' "$TDIR/stderr"; echo $?)" "$(tail -5 "$TDIR/stderr")"

echo '# v0.31 (#65): a provably-never-landed submission refunds its round'
cat > "$TDIR/bin/oracle-dead" <<'FAKE_DEAD'
#!/usr/bin/env bash
exit 1
FAKE_DEAD
chmod +x "$TDIR/bin/oracle-dead"
RKEY_91="$(printf '%s-91' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 PRO_GATE_STALL_SECS=30 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-dead" NODE_OPTIONS= \
  bash "$ENGINE" --pr 91 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-refund.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'never-landed run fails (exit 6)' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'never-landed run announces the refund' "$(grep -q 'refunding this round' "$TDIR/stderr"; echo $?)" "$(tail -5 "$TDIR/stderr")"
check 'never-landed round is refunded (no in-window spend remains)' \
  "$([ ! -s "$RHOME/rounds/$RKEY_91" ]; echo $?)" "rounds: $(cat "$RHOME/rounds/$RKEY_91" 2>/dev/null)"
check 'refund is named in the status detail' "$(grep -q 'round refunded' "$RHOME/o-refund.md.status"; echo $?)" "$(cat "$RHOME/o-refund.md.status" 2>/dev/null)"

# #66 gate P1: a run whose LOG shows the prompt reached ChatGPT must NOT be refunded, even
# when the tab is gone and salvage scans clean (the quota was spent server-side).
cat > "$TDIR/bin/oracle-landed" <<'FAKE_LANDED'
#!/usr/bin/env bash
echo "Acquired ChatGPT browser slot" >&2
exit 1
FAKE_LANDED
chmod +x "$TDIR/bin/oracle-landed"
RKEY_92="$(printf '%s-92' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 PRO_GATE_STALL_SECS=30 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-landed" NODE_OPTIONS= \
  bash "$ENGINE" --pr 92 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-landed.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'landed-but-lost run fails (exit 6)' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'landed-but-lost run does NOT announce a refund' "$(grep -qv 'refunding this round' "$TDIR/stderr" && ! grep -q 'refunding this round' "$TDIR/stderr"; echo $?)" "$(tail -5 "$TDIR/stderr")"
check 'landed-but-lost round STAYS charged' \
  "$([ -s "$RHOME/rounds/$RKEY_92" ]; echo $?)" "rounds: $(cat "$RHOME/rounds/$RKEY_92" 2>/dev/null)"

# Gate #72 r8 P1: lifecycle ABSENCE is proof only in a complete, immutable transcript whose tee
# drained successfully. Pin the helper's fail-closed contract before exercising the full pipeline.
LOG_PROOF_DIR="$TDIR/log-proof"; mkdir -p "$LOG_PROOF_DIR"
LOG_TRANSCRIPT="$LOG_PROOF_DIR/oracle.log"; LOG_PROOF="$LOG_PROOF_DIR/oracle.sha256"
printf 'pre-browser failure\n' > "$LOG_TRANSCRIPT"
printf '%s\n' "$(bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_sha256 '$LOG_TRANSCRIPT'")" > "$LOG_PROOF"
verified_log_rc() {
  bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_verified_log_lacks \"\$1\" \"\$2\" \"\$3\"" \
    _ "$1" "$2" 'Launching browser mode|Acquired ChatGPT browser slot'
}
verified_log_rc "$LOG_TRANSCRIPT" "$LOG_PROOF"; LOG_RC=$?
check 'verified lifecycle-free transcript is accepted' "$([ "$LOG_RC" -eq 0 ]; echo $?)" "rc=$LOG_RC"
rm -f "$LOG_PROOF"; verified_log_rc "$LOG_TRANSCRIPT" "$LOG_PROOF"; LOG_RC=$?
check 'missing transcript proof fails closed' "$([ "$LOG_RC" -ne 0 ]; echo $?)" "rc=$LOG_RC"
printf '%s\n' "$(bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_sha256 '$LOG_TRANSCRIPT'")" > "$LOG_PROOF"
printf 'late truncation\n' >> "$LOG_TRANSCRIPT"; verified_log_rc "$LOG_TRANSCRIPT" "$LOG_PROOF"; LOG_RC=$?
check 'transcript changed after proof fails closed' "$([ "$LOG_RC" -ne 0 ]; echo $?)" "rc=$LOG_RC"
printf 'Launching browser mode\n' > "$LOG_TRANSCRIPT"
printf '%s\n' "$(bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_sha256 '$LOG_TRANSCRIPT'")" > "$LOG_PROOF"
verified_log_rc "$LOG_TRANSCRIPT" "$LOG_PROOF"; LOG_RC=$?
check 'verified lifecycle evidence remains charged' "$([ "$LOG_RC" -ne 0 ]; echo $?)" "rc=$LOG_RC"
ln -s "$LOG_TRANSCRIPT" "$LOG_PROOF_DIR/symlink.log"
verified_log_rc "$LOG_PROOF_DIR/symlink.log" "$LOG_PROOF"; LOG_RC=$?
check 'symlinked transcript fails closed' "$([ "$LOG_RC" -ne 0 ]; echo $?)" "rc=$LOG_RC"

# Gate #72 r8 P1 end-to-end. These two runs are IDENTICAL except for the tee binary, which is the
# only way to attribute the outcome to log capture alone: a pre-browser oracle failure that would
# otherwise refund and retry must become charged and single-shot when its capture fails.
# The tee is injected via PRO_GATE_TEE_BIN, NOT PATH — pg_augment_path re-prepends /usr/bin before
# the pipeline runs, so a PATH-injected fake tee never wins and the assertions below would pass
# with the fix reverted (exactly how the first version of this regression fooled a green CI).
cat > "$TDIR/bin/oracle-quiet-fail" <<'FAKE_QUIET_FAIL'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
count=0
[ -s "${PG_TEST_ATTEMPTS_FILE:?}" ] && count="$(cat "$PG_TEST_ATTEMPTS_FILE")"
printf '%s\n' "$((count + 1))" > "$PG_TEST_ATTEMPTS_FILE"
exit 1
FAKE_QUIET_FAIL
chmod +x "$TDIR/bin/oracle-quiet-fail"
mkdir -p "$TDIR/tee-fail-bin"
cat > "$TDIR/tee-fail-bin/tee" <<'FAKE_TEE_FAIL'
#!/usr/bin/env bash
cat
exit 1
FAKE_TEE_FAIL
chmod +x "$TDIR/tee-fail-bin/tee"
# CONTROL: real tee. Capture is complete, no lifecycle was ever printed -> provably unsubmitted,
# so the engine both RETRIES and refunds. Without this run, "charged" below proves nothing.
CTL_HOME="$TDIR/home-tee-ok"; CTL_ATTEMPTS="$TDIR/tee-ok-attempts"
mkdir -p "$CTL_HOME"; : > "$CTL_ATTEMPTS"
RKEY_920="$(printf '%s-920' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$CTL_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=1 PRO_GATE_RETRY_BACKOFF=0 PRO_GATE_REATTACH_TIMEOUT=1 \
  PRO_GATE_SALVAGE_SECS=2 PRO_GATE_RUN_LOGS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-quiet-fail" \
  PG_TEST_ATTEMPTS_FILE="$CTL_ATTEMPTS" NODE_OPTIONS= \
  bash "$ENGINE" --pr 920 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$CTL_HOME/o-tee-ok.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'intact log capture still refunds the pre-browser failure' \
  "$(grep -q 'refunding this round' "$TDIR/stderr"; echo $?)" "rc=$RC $(tail -6 "$TDIR/stderr")"
check 'intact log capture leaves no in-window spend' \
  "$([ ! -s "$CTL_HOME/rounds/$RKEY_920" ]; echo $?)" "rounds=$(cat "$CTL_HOME/rounds/$RKEY_920" 2>/dev/null)"
check 'intact log capture permits the guarded retry' \
  "$([ "$(cat "$CTL_ATTEMPTS")" = 2 ]; echo $?)" "attempts=$(cat "$CTL_ATTEMPTS")"
# TEST: same oracle, failing tee. The proof is never published, so the identical evidence must now
# fail closed — one invocation, charged, no refund.
LOSS_HOME="$TDIR/home-log-loss"; LOSS_ATTEMPTS="$TDIR/log-loss-attempts"
mkdir -p "$LOSS_HOME"; : > "$LOSS_ATTEMPTS"
RKEY_921="$(printf '%s-921' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$LOSS_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=1 PRO_GATE_RETRY_BACKOFF=0 PRO_GATE_REATTACH_TIMEOUT=1 \
  PRO_GATE_SALVAGE_SECS=2 PRO_GATE_RUN_LOGS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-quiet-fail" \
  PRO_GATE_TEE_BIN="$TDIR/tee-fail-bin/tee" \
  PG_TEST_ATTEMPTS_FILE="$LOSS_ATTEMPTS" NODE_OPTIONS= \
  bash "$ENGINE" --pr 921 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$LOSS_HOME/o-log-loss.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'failed Oracle log capture exits 6' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -5 "$TDIR/stderr")"
check 'failed Oracle log capture suppresses retry' \
  "$(grep -q 'incomplete log capture makes its fate ambiguous/spent' "$TDIR/stderr"; echo $?)" "$(tail -8 "$TDIR/stderr")"
check 'failed Oracle log capture invokes Oracle exactly once' \
  "$([ "$(cat "$LOSS_ATTEMPTS")" = 1 ]; echo $?)" "attempts=$(cat "$LOSS_ATTEMPTS")"
check 'failed Oracle log capture stays charged' \
  "$([ -s "$LOSS_HOME/rounds/$RKEY_921" ]; echo $?)" "rounds=$(cat "$LOSS_HOME/rounds/$RKEY_921" 2>/dev/null)"
check 'failed Oracle log capture never announces a refund' \
  "$(! grep -q 'refunding this round' "$TDIR/stderr" && ! grep -q 'round refunded' "$LOSS_HOME/o-log-loss.md.status"; echo $?)" \
  "stderr=$(tail -6 "$TDIR/stderr") status=$(cat "$LOSS_HOME/o-log-loss.md.status")"

# Gate #72 r9: the watchdog kills the run_oracle SUBSHELL, which therefore never reaches its own
# proof publication. The parent must publish after reaping, or every watchdog-killed stall would
# silently lose the pre-browser refund it had before v0.32 — the exact scenario the stall
# watchdog exists to catch.
cat > "$TDIR/bin/oracle-stall" <<'FAKE_STALL'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
count=0
[ -s "${PG_TEST_ATTEMPTS_FILE:?}" ] && count="$(cat "$PG_TEST_ATTEMPTS_FILE")"
printf '%s\n' "$((count + 1))" > "$PG_TEST_ATTEMPTS_FILE"
sleep 120
FAKE_STALL
chmod +x "$TDIR/bin/oracle-stall"
STALL_HOME="$TDIR/home-stall"; STALL_ATTEMPTS="$TDIR/stall-attempts"
mkdir -p "$STALL_HOME"; : > "$STALL_ATTEMPTS"
RKEY_922="$(printf '%s-922' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$STALL_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=0 PRO_GATE_STALL_SECS=1 PRO_GATE_REATTACH_TIMEOUT=1 \
  PRO_GATE_SALVAGE_SECS=2 PRO_GATE_RUN_LOGS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-stall" \
  PG_TEST_ATTEMPTS_FILE="$STALL_ATTEMPTS" NODE_OPTIONS= \
  bash "$ENGINE" --pr 922 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$STALL_HOME/o-stall.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'watchdog-killed pre-browser stall exits 6' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -5 "$TDIR/stderr")"
check 'watchdog-killed stall stays charged even with a lifecycle-free log' \
  "$([ -s "$STALL_HOME/rounds/$RKEY_922" ]; echo $?)" "rounds=$(cat "$STALL_HOME/rounds/$RKEY_922" 2>/dev/null)"
check 'watchdog-killed stall never announces a refund' \
  "$(! grep -q 'refunding this round' "$TDIR/stderr"; echo $?)" "$(tail -8 "$TDIR/stderr")"

# The converse, and the one that matters: a stall that ALREADY printed browser lifecycle must stay
# charged. That line is only in the transcript because tee drained to EOF after the producer died;
# killing tee with the pipeline would drop it and turn a spent send into a refunded duplicate.
cat > "$TDIR/bin/oracle-stall-landed" <<'FAKE_STALL_LANDED'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
printf 'Launching browser mode\nAcquired ChatGPT browser slot\n'
sleep 120
FAKE_STALL_LANDED
chmod +x "$TDIR/bin/oracle-stall-landed"
SLANDED_HOME="$TDIR/home-stall-landed"; mkdir -p "$SLANDED_HOME"
RKEY_923="$(printf '%s-923' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$SLANDED_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=0 PRO_GATE_STALL_SECS=1 PRO_GATE_REATTACH_TIMEOUT=1 \
  PRO_GATE_SALVAGE_SECS=2 PRO_GATE_RUN_LOGS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-stall-landed" \
  NODE_OPTIONS= \
  bash "$ENGINE" --pr 923 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$SLANDED_HOME/o-stall-landed.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'watchdog-killed stall after lifecycle exits 6' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -4 "$TDIR/stderr")"
check 'watchdog-killed stall after lifecycle stays charged' \
  "$([ -s "$SLANDED_HOME/rounds/$RKEY_923" ]; echo $?)" "rounds=$(cat "$SLANDED_HOME/rounds/$RKEY_923" 2>/dev/null)"
check 'watchdog-killed stall after lifecycle never announces a refund' \
  "$(! grep -q 'refunding this round' "$TDIR/stderr"; echo $?)" "$(tail -6 "$TDIR/stderr")"

# Gate #72 r13 P1: the inner `timeout` can kill Oracle at HARD_SECS while output keeps flowing, so
# the stall watchdog never fires and the run exits through the NORMAL wait path. tee still returns 0
# there, so only the producer's own status can reveal that the stream was cut off. Thresholds are
# set above HARD_SECS deliberately: this must be the timeout's kill, not the watchdog's.
cat > "$TDIR/bin/oracle-hardcap" <<'FAKE_HARDCAP'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
count=0
[ -s "${PG_TEST_ATTEMPTS_FILE:?}" ] && count="$(cat "$PG_TEST_ATTEMPTS_FILE")"
printf '%s\n' "$((count + 1))" > "$PG_TEST_ATTEMPTS_FILE"
while :; do printf 'still working\n'; sleep 1; done
FAKE_HARDCAP
chmod +x "$TDIR/bin/oracle-hardcap"
HARDCAP_HOME="$TDIR/home-hardcap"; HARDCAP_ATTEMPTS="$TDIR/hardcap-attempts"
mkdir -p "$HARDCAP_HOME"; : > "$HARDCAP_ATTEMPTS"
RKEY_926="$(printf '%s-926' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$HARDCAP_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=1 PRO_GATE_RETRY_BACKOFF=0 PRO_GATE_STALL_SECS=600 \
  PRO_GATE_NOTHINK_SECS=600 PRO_GATE_TIMEOUT_GRACE=1 PRO_GATE_REATTACH_TIMEOUT=1 \
  PRO_GATE_SALVAGE_SECS=2 PRO_GATE_RUN_LOGS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-hardcap" \
  PG_TEST_ATTEMPTS_FILE="$HARDCAP_ATTEMPTS" NODE_OPTIONS= \
  bash "$ENGINE" --pr 926 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$HARDCAP_HOME/o-hardcap.md" --timeout 2s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'hard-cap timeout kill exits 6' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -4 "$TDIR/stderr")"
check 'hard-cap timeout kill invokes Oracle exactly once' \
  "$([ "$(cat "$HARDCAP_ATTEMPTS")" = 1 ]; echo $?)" "attempts=$(cat "$HARDCAP_ATTEMPTS")"
check 'hard-cap timeout kill stays charged' \
  "$([ -s "$HARDCAP_HOME/rounds/$RKEY_926" ]; echo $?)" "rounds=$(cat "$HARDCAP_HOME/rounds/$RKEY_926" 2>/dev/null)"
check 'hard-cap timeout kill never announces a refund' \
  "$(! grep -q 'refunding this round' "$TDIR/stderr"; echo $?)" "$(tail -5 "$TDIR/stderr")"

# Gate #72 r11 P1: Oracle is a GRANDCHILD of the watchdog's job, so killing the wrappers would
# reparent it and let it keep driving the browser after this run's slot and locks are released.
# A TERM-ignoring Oracle is the honest test: only a process-group kill reaches it.
# NOTE: `trap '' TERM; sleep N` is NOT TERM-proof — the group signal kills the sleep CHILD, the
# script falls through, and the pipeline drains as if nothing were wrong, so the assertions below
# would pass without testing anything. Block on a builtin read against a writer-less fifo instead:
# no child to kill, no CPU burn, and only KILL ends it (verified: `timeout 3` cannot kill it).
cat > "$TDIR/bin/oracle-term-ignoring" <<'FAKE_TERM_IGNORE'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
trap '' TERM
printf '%s\n' "$$" > "${PG_TEST_PRODUCER_PID:?}"
printf 'Launching browser mode\n'
exec 3<> "${PG_TEST_BLOCK_FIFO:?}"
read -u 3 -r _
FAKE_TERM_IGNORE
chmod +x "$TDIR/bin/oracle-term-ignoring"
ORPHAN_HOME="$TDIR/home-orphan"; ORPHAN_PID="$TDIR/orphan-producer.pid"
ORPHAN_FIFO="$TDIR/orphan-block.fifo"
RKEY_924="$(printf '%s-924' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
mkdir -p "$ORPHAN_HOME"; : > "$ORPHAN_PID"; rm -f "$ORPHAN_FIFO"; mkfifo "$ORPHAN_FIFO"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$ORPHAN_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=0 PRO_GATE_STALL_SECS=1 PRO_GATE_REATTACH_TIMEOUT=1 \
  PRO_GATE_SALVAGE_SECS=2 PRO_GATE_RUN_LOGS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-term-ignoring" \
  PG_TEST_PRODUCER_PID="$ORPHAN_PID" PG_TEST_BLOCK_FIFO="$ORPHAN_FIFO" NODE_OPTIONS= \
  bash "$ENGINE" --pr 924 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$ORPHAN_HOME/o-orphan.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
ORPHAN_SEEN="$(cat "$ORPHAN_PID" 2>/dev/null)"
check 'TERM-ignoring Oracle still terminates the attempt' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'TERM-ignoring Oracle actually started (fixture sanity)' \
  "$([ -n "$ORPHAN_SEEN" ]; echo $?)" "pid=$ORPHAN_SEEN"
check 'TERM-ignoring Oracle leaves no surviving descendant' \
  "$([ -n "$ORPHAN_SEEN" ] && ! kill -0 "$ORPHAN_SEEN" 2>/dev/null; echo $?)" "pid=$ORPHAN_SEEN"
# Same run also covers the BLUNT-fallback branch: the producer never drains, so the attempt is
# force-killed. Its proof is revoked, so it must stay charged no matter how clean the log looks.
check 'force-killed attempt stays charged' \
  "$([ -s "$ORPHAN_HOME/rounds/$RKEY_924" ]; echo $?)" "rounds=$(cat "$ORPHAN_HOME/rounds/$RKEY_924" 2>/dev/null)"
check 'force-killed attempt never announces a refund' \
  "$(! grep -q 'refunding this round' "$TDIR/stderr"; echo $?)" "$(tail -5 "$TDIR/stderr")"

# v0.32: Oracle 0.17+ stores prompt-commit state only after dispatching Send/Enter. Even a complete
# all-negative DOM probe cannot prove ChatGPT rejected that request, so browser-lifecycle evidence
# must suppress retries and retain the round regardless of metadata completeness or landing URL.
cat > "$TDIR/bin/oracle-commit-timeout" <<'FAKE_COMMIT_TIMEOUT'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
prompt=""; chatgpt_url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --chatgpt-url) chatgpt_url="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -z "${PG_TEST_CHATGPT_URL_FILE:-}" ] || printf '%s\n' "$chatgpt_url" > "$PG_TEST_CHATGPT_URL_FILE"
tab_url="${PG_TEST_TAB_URL:-https://chatgpt.com/}"
count=0
[ -s "${PG_TEST_ATTEMPTS_FILE:?}" ] && count="$(cat "$PG_TEST_ATTEMPTS_FILE")"
count=$((count + 1)); printf '%s\n' "$count" > "$PG_TEST_ATTEMPTS_FILE"
slug="fake-prompt-commit-$count"
mkdir -p "${ORACLE_HOME_DIR:?}/sessions/$slug"
jq -n --arg id "$slug" --arg prompt "$prompt" --arg tabUrl "$tab_url" \
  --argjson promptLength "${#prompt}" '
  {
    id: $id,
    status: "error",
    mode: "browser",
    options: {prompt: $prompt},
    browser: {runtime: {promptSubmitted: true, tabUrl: $tabUrl}},
    error: {
      category: "browser-automation",
      details: {
        stage: "submit-prompt",
        code: "prompt-commit-timeout",
        promptLength: $promptLength,
        timeoutMs: 60000,
        commitProbe: {
          baseline: 0,
          turnsCount: 0,
          userMatched: false,
          prefixMatched: false,
          lastMatched: false,
          hasNewTurn: false,
          stopVisible: false,
          assistantVisible: false,
          composerCleared: true,
          inConversation: false,
          editorLength: 0,
          lastTurnLength: 0
        }
      }
    }
  }
' > "$ORACLE_HOME_DIR/sessions/$slug/meta.json"
if [ "${PG_TEST_COMMIT_MODE:-complete}" = partial ]; then
  jq 'del(.error.details.commitProbe.prefixMatched)' \
    "$ORACLE_HOME_DIR/sessions/$slug/meta.json" > "$ORACLE_HOME_DIR/sessions/$slug/meta.tmp"
  mv "$ORACLE_HOME_DIR/sessions/$slug/meta.tmp" "$ORACLE_HOME_DIR/sessions/$slug/meta.json"
fi
printf 'Session: %s\n' "$slug"
printf 'Reattach: oracle session %s\n' "$slug"
printf 'Launching browser mode\nAcquired ChatGPT browser slot\n'
printf 'ERROR: Prompt did not appear in conversation before timeout (send may have failed)\n'
exit 1
FAKE_COMMIT_TIMEOUT
chmod +x "$TDIR/bin/oracle-commit-timeout"

PROOF_HOME="$TDIR/home-prompt-proof"; PROOF_ORACLE="$TDIR/oracle-prompt-proof"
PROOF_ATTEMPTS="$TDIR/prompt-proof-attempts"; PROOF_URL="$TDIR/prompt-proof-url"
mkdir -p "$PROOF_HOME" "$PROOF_ORACLE"; : > "$PROOF_ATTEMPTS"
RKEY_93="$(printf '%s-93' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
PROJECT_URL="https://chatgpt.com/g/g-test/project/project-test"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$PROOF_HOME" ORACLE_HOME_DIR="$PROOF_ORACLE" ORACLE_BROWSER_PORT="$PORT" \
  ORACLE_CHATGPT_URL="$PROJECT_URL" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 \
  PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=1 PRO_GATE_RETRY_BACKOFF=0 \
  PRO_GATE_REATTACH_TIMEOUT=1 PRO_GATE_SALVAGE_SECS=2 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-commit-timeout" PG_TEST_ATTEMPTS_FILE="$PROOF_ATTEMPTS" \
  PG_TEST_CHATGPT_URL_FILE="$PROOF_URL" PG_TEST_TAB_URL="$PROJECT_URL" \
  NODE_OPTIONS= bash "$ENGINE" --pr 93 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$PROOF_HOME/o-proof.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'post-click timeout fails without a duplicate retry' \
  "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -4 "$TDIR/stderr")"
check 'Project URL is forwarded unchanged to Oracle' \
  "$([ "$(cat "$PROOF_URL" 2>/dev/null)" = "$PROJECT_URL" ]; echo $?)" "url=$(cat "$PROOF_URL" 2>/dev/null)"
check 'complete post-click metadata remains ambiguous and suppresses retry' \
  "$(grep -q 'lifecycle evidence or incomplete log capture makes its fate ambiguous/spent' "$TDIR/stderr"; echo $?)" \
  "$(tail -8 "$TDIR/stderr")"
check 'post-click timeout invokes Oracle exactly once' \
  "$([ "$(cat "$PROOF_ATTEMPTS")" = 1 ]; echo $?)" "attempts=$(cat "$PROOF_ATTEMPTS")"
check 'post-click timeout stays charged' \
  "$([ -s "$PROOF_HOME/rounds/$RKEY_93" ]; echo $?)" "rounds=$(cat "$PROOF_HOME/rounds/$RKEY_93" 2>/dev/null)"
check 'post-click timeout never announces a refund' \
  "$(! grep -q 'refunding this round' "$TDIR/stderr" && ! grep -q 'round refunded' "$PROOF_HOME/o-proof.md.status"; echo $?)" \
  "stderr=$(tail -6 "$TDIR/stderr") status=$(cat "$PROOF_HOME/o-proof.md.status")"

# Partial metadata has the same fail-closed result: once browser lifecycle exists, metadata shape
# has no authority to enable a duplicate retry or refund.
PARTIAL_HOME="$TDIR/home-prompt-partial"; PARTIAL_ORACLE="$TDIR/oracle-prompt-partial"
PARTIAL_ATTEMPTS="$TDIR/prompt-partial-attempts"; mkdir -p "$PARTIAL_HOME" "$PARTIAL_ORACLE"; : > "$PARTIAL_ATTEMPTS"
RKEY_94="$(printf '%s-94' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$PARTIAL_HOME" ORACLE_HOME_DIR="$PARTIAL_ORACLE" ORACLE_BROWSER_PORT="$PORT" \
  PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=1 PRO_GATE_RETRY_BACKOFF=0 PRO_GATE_REATTACH_TIMEOUT=1 PRO_GATE_SALVAGE_SECS=2 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-commit-timeout" PG_TEST_ATTEMPTS_FILE="$PARTIAL_ATTEMPTS" \
  PG_TEST_COMMIT_MODE=partial NODE_OPTIONS= bash "$ENGINE" --pr 94 --repo "$TDIR" \
  --diff "$TDIR/small.diff" --out "$PARTIAL_HOME/o-partial.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'partial commit metadata fails without a duplicate retry' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -4 "$TDIR/stderr")"
check 'partial commit metadata suppresses retry' \
  "$([ "$(cat "$PARTIAL_ATTEMPTS")" = 1 ]; echo $?)" "attempts=$(cat "$PARTIAL_ATTEMPTS")"
check 'partial commit metadata remains charged' \
  "$([ -s "$PARTIAL_HOME/rounds/$RKEY_94" ]; echo $?)" "rounds=$(cat "$PARTIAL_HOME/rounds/$RKEY_94" 2>/dev/null)"
check 'partial commit metadata never announces a refund' \
  "$(! grep -q 'refunding this round' "$TDIR/stderr"; echo $?)" "$(tail -6 "$TDIR/stderr")"

# #66 gate r2/r3 P1: the spend epoch is the one pg_round_record CHARGED at — not the
# reservation's `created` field (written at exit-9 time, 35 min later on the live run that
# exposed this) and not the marker's launch time (minted before two lock waits of up to
# PRO_GATE_LOCK_WAIT each, so a queued run could be charged ~80 min after its marker).
EHOME="$TDIR/home-spendepoch"; mkdir -p "$EHOME/rounds"
SPEND_OUT="$(PRO_GATE_HOME="$EHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_record spendkey; printf '%s|%s' \"\$PG_ROUND_SPEND_EPOCH\" \"\$(cat '$EHOME/rounds/spendkey')\"")"
check 'pg_round_record exports the epoch it charged' \
  "$([ -n "${SPEND_OUT%%|*}" ] && [ "${SPEND_OUT%%|*}" = "${SPEND_OUT##*|}" ]; echo $?)" "got=$SPEND_OUT"
# The reservation carries that epoch (field 7) into a later harvest process.
RHOME_S="$TDIR/home-resspend"; mkdir -p "$RHOME_S/in-progress"
PRO_GATE_HOME="$RHOME_S" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_write 'pg-run-k-1700000000-1' 'k' '/tmp/o.md' '' 'GPT-X' '1700009999'"
RSPEND="$(PRO_GATE_HOME="$RHOME_S" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_read_spend 'pg-run-k-1700000000-1'")"
check 'reservation persists the charged-round epoch' "$([ "$RSPEND" = 1700009999 ]; echo $?)" "got=$RSPEND"
# A rewrite with no explicit spend (the harvest-path rewrite) must PRESERVE it.
PRO_GATE_HOME="$RHOME_S" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_write 'pg-run-k-1700000000-1' 'k' '/tmp/o.md'"
RSPEND="$(PRO_GATE_HOME="$RHOME_S" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_read_spend 'pg-run-k-1700000000-1'")"
check 'reservation rewrite preserves the spend epoch' "$([ "$RSPEND" = 1700009999 ]; echo $?)" "got=$RSPEND"
RMODEL="$(PRO_GATE_HOME="$RHOME_S" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_read_model 'pg-run-k-1700000000-1'")"
check 'reservation rewrite still preserves the model (7-field record)' "$([ "$RMODEL" = GPT-X ]; echo $?)" "got=$RMODEL"
MEPOCH="$(bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_marker_epoch 'pg-run-acme-widgets-42-1700000123-99'")"
check 'pg_marker_epoch (fallback) extracts the launch epoch' "$([ "$MEPOCH" = 1700000123 ]; echo $?)" "got=$MEPOCH"
MEPOCH="$(bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_marker_epoch 'legacy-marker' 2>/dev/null" || true)"
check 'pg_marker_epoch rejects a legacy marker' "$([ -z "$MEPOCH" ]; echo $?)" "got=$MEPOCH"

# ledger-timing-split R3 audit: a round's charge (and hence its budget window) must key off
# the moment pg_round_record actually runs (post-lock, post-slot — the phase transition), never
# off a marker's mint time. A marker minted well outside the round window simulates the queued
# run this whole family of bugs (#66) was about: if pg_round_record ever used the marker's
# epoch instead of its own call-time "now", this round would already be stale on arrival and
# pg_round_count would read 0, not 1.
R3_HOME="$TDIR/home-r3audit"; mkdir -p "$R3_HOME/rounds"
R3_KEY="r3auditkey"
R3_OLD_MARKER="pg-run-${R3_KEY}-$(( $(date +%s) - 172800 ))-42"   # minted 48h ago (2x the 24h window)
R3_STALE_EPOCH="$(bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_marker_epoch '$R3_OLD_MARKER'")"
check 'R3 audit: the marker mint epoch really is outside the round window' \
  "$([ $(( $(date +%s) - R3_STALE_EPOCH )) -ge 86400 ]; echo $?)" "marker_epoch=$R3_STALE_EPOCH"
PRO_GATE_HOME="$R3_HOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_record '$R3_KEY'"
R3_COUNT="$(PRO_GATE_HOME="$R3_HOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_count '$R3_KEY'")"
check 'R3 audit: a round charged now counts in-window despite an out-of-window marker mint' \
  "$([ "$R3_COUNT" -eq 1 ]; echo $?)" "count=$R3_COUNT rounds file=$(cat "$R3_HOME/rounds/$R3_KEY" 2>/dev/null)"

# #66 gate P1: a harvested review is stamped with its SPEND epoch, not the collection time —
# otherwise an hours-later harvest outlives its own spend in the scored window.
HHOME="$TDIR/home-histstamp"; mkdir -p "$HHOME/rounds"
HKEY=histstamp
OLD_EPOCH=$(( $(date +%s) - 7200 ))
printf '%s\n' "$OLD_EPOCH" > "$HHOME/rounds/$HKEY"
printf '[P1] a.sh:1 - finding\n  Why: test\nP2: none\nP3: none\nVERDICT: SHIP - fixture.\n' > "$HHOME/review.md"
PRO_GATE_HOME="$HHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_note_severity '$HKEY' '$HHOME/review.md' '$OLD_EPOCH'"
check 'harvested hist row carries the SPEND epoch' \
  "$([ "$(awk -F'\t' 'NR==1{print $1}' "$HHOME/rounds/$HKEY.hist")" = "$OLD_EPOCH" ]; echo $?)" \
  "hist: $(cat "$HHOME/rounds/$HKEY.hist")"
check 'harvested hist row carries plausible positive wall-clock seconds' \
  "$(awk -F'\t' 'NR==1{exit !(NF == 7 && $7 > 0 && $7 < 86400)}' "$HHOME/rounds/$HKEY.hist"; echo $?)" \
  "hist: $(cat "$HHOME/rounds/$HKEY.hist")"
# Rows sharing one second must keep WRITE order (the re-sort is stable): an unstable sort
# would reorder the very trajectory the governor scores.
SHOME2="$TDIR/home-histstable"; mkdir -p "$SHOME2/rounds"; date +%s > "$SHOME2/rounds/k"
printf '[P1] a.sh:1 - f\n  Why: t\nP2: none\nP3: none\nVERDICT: SHIP - x.\n' > "$SHOME2/a.md"
printf '[P1] a.sh:1 - f\n  Why: t\nP2: none\nP3: none\n**VERDICT:** FIX-FIRST - y.\n' > "$SHOME2/b.md"
PRO_GATE_HOME="$SHOME2" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_note_severity k '$SHOME2/a.md'; pg_round_note_severity k '$SHOME2/b.md'"
check 'same-second hist rows keep write order (stable sort)' \
  "$([ "$(awk -F'\t' 'NR==1{print $2}' "$SHOME2/rounds/k.hist")" = SHIP ]; echo $?)" \
  "hist: $(cat "$SHOME2/rounds/k.hist")"
# A future/garbage epoch degrades to now rather than parking a row beyond the window.
PRO_GATE_HOME="$HHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_note_severity '$HKEY' '$HHOME/review.md' '99999999999'"
check 'implausible spend epoch falls back to now' \
  "$([ "$(awk -F'\t' 'END{print ($1 <= '"$(date +%s)"') ? "ok" : "bad"}' "$HHOME/rounds/$HKEY.hist")" = ok ]; echo $?)" \
  "hist: $(cat "$HHOME/rounds/$HKEY.hist")"

# Harvests spend no slot and must never consume a round.
NROUND_FILES="$(ls "$RHOME/rounds" 2>/dev/null | wc -l)"
MKR="pg-run-roundharvest-1700000030-22"
printf 'kR\t%s\t%s\t0\t\n' "$RHOME/o-rh.md" "$(date +%s)" > "$RHOME/in-progress/$MKR"
{ printf 'run marker: %s\n' "$MKR"
  printf '[P1] src/x.sh:10 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean. (run marker: %s)\n' "$MKR"
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
: > "$TDIR/mock.log"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-cf" NODE_OPTIONS= \
  PRO_GATE_TIMEOUT_BIN="$TIMEOUT_LOG_BIN" PG_TEST_NODE_ARGS="$TDIR/node-args-cloudflare.log" \
  bash "$ENGINE" --pr 103 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-cf.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'cloudflare run fails without a usable review' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'cloudflare writes the account cooldown' "$([ -f "$RHOME/throttle.cooldown" ]; echo $?)" 'no cooldown file'
check 'cloudflare refunds the round (no spend, no budget charge)' "$([ ! -f "$RHOME/rounds/$RKEY_103" ]; echo $?)" "rounds file: $(cat "$RHOME/rounds/$RKEY_103" 2>/dev/null)"
check 'cloudflare failure never invokes organizer mode' "$(! grep -q -- '--organize' "$TDIR/node-args-cloudflare.log"; echo $?)" "$(cat "$TDIR/node-args-cloudflare.log" 2>/dev/null)"
rm -f "$RHOME/throttle.cooldown"

echo '# v0.32: throttle evidence suppresses exit-9 organization'
cat > "$TDIR/bin/oracle-throttle" <<'FAKE_THROTTLE'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
echo 'Launching browser mode'
echo 'Acquired ChatGPT browser slot'
exit 1
FAKE_THROTTLE
chmod +x "$TDIR/bin/oracle-throttle"
THOME="$TDIR/home-throttle-organizer"
TSTATE="$TDIR/state-throttle-organizer.json"
mkdir -p "$THOME"
printf '{"title":null,"archived":false,"events":[]}\n' > "$TSTATE"
printf "You're making requests too quickly. Temporarily limited access to your conversations.\n" > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt" "$TSTATE"
: > "$TDIR/node-args-throttle.log"
env PRO_GATE_HOME="$THOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_REATTACH_TIMEOUT=1 PRO_GATE_SALVAGE_SECS=2 PRO_GATE_THROTTLE_PAUSE=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-throttle" NODE_OPTIONS= \
  PRO_GATE_TIMEOUT_BIN="$TIMEOUT_LOG_BIN" PG_TEST_NODE_ARGS="$TDIR/node-args-throttle.log" \
  bash "$ENGINE" --pr 104 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$THOME/o-throttle.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'throttle salvage preserves the spent run as exit 9' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'throttle evidence writes the account cooldown' "$([ -f "$THOME/throttle.cooldown" ]; echo $?)" 'no cooldown file'
check 'exit-9 under active throttle never invokes organizer mode' "$(! grep -q -- '--organize' "$TDIR/node-args-throttle.log"; echo $?)" "$(cat "$TDIR/node-args-throttle.log")"

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
# Flat (non-shrinking) open counts so this fixture earns no extra round and leaves the
# base-grant assertion below ('2 spent, 1 remaining') undisturbed — it exists only to give
# the elapsed-wall-clock assertion two real hist rows (2h total) to sum.
printf '%s\tFIX-FIRST\t0\t5\t0\t0\t3600\n%s\tFIX-FIRST\t0\t5\t0\t0\t3600\n' "$(date +%s)" "$(date +%s)" > "$SHOME/rounds/acme-widgets-42.hist"
printf 'https://chatgpt.com/c/abc123\n' > "$SHOME/conversation-urls/$SMARKER"
printf '{"ts":"2026-01-01T00:00:00+0000","pr":"42","repo":"/tmp/acme","exit":9,"outcome":"in-progress","secs":100,"attempts":0,"conc":1,"ceiling":1,"live":1,"salvaged":0,"diff_lines":10,"out":"/tmp/pg-st-42.md","model":"m","marker":"%s","round_key":"acme-widgets-42"}\n' "$SMARKER" > "$SHOME/ledger.jsonl"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st.out" 2>"$TDIR/st.err"; RC=$?
check '--status exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(cat "$TDIR/st.err")"
check '--status names the reservation marker' "$(grep -q "$SMARKER" "$TDIR/st.out"; echo $?)" "$(cat "$TDIR/st.out")"
check '--status leads to a free harvest' "$(grep -q "FREE" "$TDIR/st.out" && grep -q -- "--harvest '$SMARKER'" "$TDIR/st.out"; echo $?)" "$(grep -i harvest "$TDIR/st.out")"
# v0.31: governor default — base grant 3 with no trajectory history, so 2 spent leaves 1.
check '--status reports rounds spent/remaining' "$(grep -q '2 spent, 1 remaining' "$TDIR/st.out"; echo $?)" "$(grep spent "$TDIR/st.out")"
check '--status reports rounds used and total wall clock' \
  "$(grep -q '2 rounds; ~2.0h recorded across 2 scored round(s)' "$TDIR/st.out"; echo $?)" "$(grep spent "$TDIR/st.out")"
check '--status writes nothing' "$([ ! -f "$SHOME/ledger.jsonl.tmp" ] && [ "$(wc -l < "$SHOME/ledger.jsonl")" -eq 1 ]; echo $?)" 'state mutated'
# #67/#68 P2: THREE states. Bare .unbound captures are AMBIGUOUS and retryable (strict nonce
# mode makes one when an older answer is visible while ours generates); only a positively
# convicted cross-bind is terminally stuck. Reporting the first as STUCK would tell an operator
# to delete a live reservation.
: > /tmp/pg-st-42.md.unbound.111; : > /tmp/pg-st-42.md.unbound.222
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st-amb.out" 2>/dev/null
check '--status calls bare unbound captures AMBIGUOUS, not stuck' \
  "$(grep -q 'ambiguous, still retryable' "$TDIR/st-amb.out" && ! grep -q 'STUCK' "$TDIR/st-amb.out"; echo $?)" "$(cat "$TDIR/st-amb.out")"
if command -v jq >/dev/null 2>&1; then
  PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 --json >"$TDIR/st-amb.json" 2>/dev/null
  check '--status --json: unbindable-ambiguous with a count' \
    "$([ "$(jq -r '.reservations[0].state' "$TDIR/st-amb.json")" = 'unbindable-ambiguous' ] && [ "$(jq -r '.reservations[0].unbound_captures' "$TDIR/st-amb.json")" = 2 ]; echo $?)" \
    "$(jq -c '.reservations[0]' "$TDIR/st-amb.json" 2>/dev/null)"
fi
# Now convict it: cdp-salvage recorded a cross-bind for this marker.
mkdir -p "$SHOME/crossbound"; printf '2026-01-01T00:00:00Z\thttps://chatgpt.com/c/x\tpg-run-other-9-1-1\n' > "$SHOME/crossbound/$SMARKER"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st-stuck.out" 2>/dev/null
check '--status flags a convicted cross-bind as STUCK' "$(grep -q 'STUCK' "$TDIR/st-stuck.out"; echo $?)" "$(cat "$TDIR/st-stuck.out")"
check '--status warns against REQUIRE_NONCE=0 on a cross-bind' "$(grep -q 'Do NOT set PRO_GATE_REQUIRE_NONCE=0' "$TDIR/st-stuck.out"; echo $?)" "$(grep -i 'nonce' "$TDIR/st-stuck.out")"
if command -v jq >/dev/null 2>&1; then
  PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 --json >"$TDIR/st-stuck.json" 2>/dev/null
  check '--status --json: cross-bound state' \
    "$([ "$(jq -r '.reservations[0].state' "$TDIR/st-stuck.json")" = 'cross-bound' ]; echo $?)" \
    "$(jq -c '.reservations[0]' "$TDIR/st-stuck.json" 2>/dev/null)"
fi
rm -rf "$SHOME/crossbound"; rm -f /tmp/pg-st-42.md.unbound.111 /tmp/pg-st-42.md.unbound.222

# #68 gate P1: a confirmed miss must NOT erase the v0.31 spend epoch (field 7).
MHOME="$TDIR/home-missfields"; mkdir -p "$MHOME/in-progress"
MMARK="pg-run-mk-1700000009-7"
printf 'mk\t/tmp/o.md\t1700000000\t0\t\tGPT-X\t1700005555\n' > "$MHOME/in-progress/$MMARK"
PRO_GATE_HOME="$MHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$MMARK' >/dev/null"
check 'note_miss preserves the spend epoch (field 7)' \
  "$([ "$(PRO_GATE_HOME="$MHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_read_spend '$MMARK'")" = 1700005555 ]; echo $?)" \
  "record: $(tr '\t' '|' < "$MHOME/in-progress/$MMARK")"
check 'note_miss preserves the model too' \
  "$([ "$(PRO_GATE_HOME="$MHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_read_model '$MMARK'")" = GPT-X ]; echo $?)" \
  "record: $(tr '\t' '|' < "$MHOME/in-progress/$MMARK")"
check 'note_miss still incremented the streak' \
  "$([ "$(awk -F'\t' 'NR==1{print $4}' "$MHOME/in-progress/$MMARK")" = 1 ]; echo $?)" \
  "record: $(tr '\t' '|' < "$MHOME/in-progress/$MMARK")"

# #67: --harvest must apply reservation TTL, so a stranded change is not blocked forever (the
# fresh-run path is redirected to the reservation before it can submit, so if the harvest path
# cannot expire it either, both exits are closed — pushbot#1334 lost its review that way).
THOME="$TDIR/home-harvestttl"; mkdir -p "$THOME/in-progress"
# A past-TTL reservation for a DIFFERENT marker is swept while harvesting this one — that is
# the point of the sweep: a change stranded by an unbindable reservation frees itself instead
# of blocking every fresh run forever. (The target marker itself is deliberately exempt; see
# the skip-marker assertion below.)
TMARK="pg-run-ttlkey-1700000002-88"
OTHER_STALE="pg-run-otherkey-1700000005-91"
printf 'ttlkey\t%s/o.md\t%s\t0\t\t\t\n' "$THOME" "$(( $(date +%s) - 30000 ))" > "$THOME/in-progress/$TMARK"
printf 'otherkey\t%s/oX.md\t%s\t0\t\t\t\n' "$THOME" "$(( $(date +%s) - 30000 ))" > "$THOME/in-progress/$OTHER_STALE"
printf 'no tabs\n' > "$TDIR/tab.txt"; start_mock "$TDIR/tab.txt"
env PRO_GATE_HOME="$THOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$TMARK" --out "$THOME/o.md" --timeout 15s >"$TDIR/stdout" 2>"$TDIR/stderr" || true
check 'harvest expires OTHER past-TTL reservations (frees stranded changes)' \
  "$([ ! -f "$THOME/in-progress/$OTHER_STALE" ]; echo $?)" "$(ls "$THOME/in-progress" 2>/dev/null)"
# An UNEXPIRED reservation must survive the same sweep untouched.
UMARK="pg-run-ttlkey-1700000003-89"
printf 'ttlkey\t%s/o2.md\t%s\t0\t\t\t\n' "$THOME" "$(date +%s)" > "$THOME/in-progress/$UMARK"
env PRO_GATE_HOME="$THOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$UMARK" --out "$THOME/o2.md" --timeout 15s >"$TDIR/stdout" 2>"$TDIR/stderr" || true
check 'harvest keeps a fresh reservation' "$([ -f "$THOME/in-progress/$UMARK" ]; echo $?)" "$(ls "$THOME/in-progress" 2>/dev/null)"
# #68 gate P1: the sweep must NEVER reap the marker being harvested, even when it is past TTL —
# removing it mid-collection admits a duplicate same-change submission, and a still-generating
# result would recreate the record with a fresh timestamp under a fallback key.
SMARK="pg-run-ttlkey-1700000004-90"
printf 'ttlkey\t%s/o3.md\t%s\t0\t\t\t\n' "$THOME" "$(( $(date +%s) - 30000 ))" > "$THOME/in-progress/$SMARK"
env PRO_GATE_HOME="$THOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$SMARK" --out "$THOME/o3.md" --timeout 15s >"$TDIR/stdout" 2>"$TDIR/stderr" || true
check 'harvest never reaps its OWN target reservation mid-collection' \
  "$([ -f "$THOME/in-progress/$SMARK" ]; echo $?)" "$(ls "$THOME/in-progress" 2>/dev/null)"
# #68 gate r2 P1: the claim is the harvest LOCK, so ANY reconciler (a concurrent harvest, or
# fresh dispatch) skips an actively-collected marker — not just the collecting process.
CLAIMED="pg-run-claimkey-1700000006-92"
mkdir -p "$THOME/harvest-locks"
printf 'claimkey\t%s/o4.md\t%s\t0\t\t\t\n' "$THOME" "$(( $(date +%s) - 30000 ))" > "$THOME/in-progress/$CLAIMED"
if command -v flock >/dev/null 2>&1; then
  ( exec 9>>"$THOME/harvest-locks/$CLAIMED"; flock 9; sleep 6 ) &
  CLAIM_PID=$!
  sleep 0.5
  CLAIMED_RC="$(PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_harvest_claimed '$CLAIMED' && echo held || echo free")"
  check 'pg_harvest_claimed sees a held harvest lock' "$([ "$CLAIMED_RC" = held ]; echo $?)" "got=$CLAIMED_RC"
  PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; PG_RES_TTL_ONLY=1 pg_reservation_reconcile '' 9222" >/dev/null 2>&1
  check 'a foreign reconciler skips an actively-harvested marker' \
    "$([ -f "$THOME/in-progress/$CLAIMED" ]; echo $?)" "$(ls "$THOME/in-progress" 2>/dev/null)"
  wait "$CLAIM_PID" 2>/dev/null
  # Once the claim is released, the same past-TTL reservation IS reaped.
  CLAIMED_RC="$(PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_harvest_claimed '$CLAIMED' && echo held || echo free")"
  check 'a released lock reads as unclaimed' "$([ "$CLAIMED_RC" = free ]; echo $?)" "got=$CLAIMED_RC"
  PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; PG_RES_TTL_ONLY=1 pg_reservation_reconcile '' 9222" >/dev/null 2>&1
  check 'an unclaimed past-TTL reservation is still reaped' \
    "$([ ! -f "$THOME/in-progress/$CLAIMED" ]; echo $?)" "$(ls "$THOME/in-progress" 2>/dev/null)"
fi
# #68 gate r3 P1: the TARGET's own expiry. Reconcilers skip claimed markers, so the collector
# must decide its own target's fate post-capture — otherwise the one marker #67 exists for can
# never self-clear, and repeatedly following --status's advice loops forever.
EXPIRED_SELF="pg-run-selfkey-1700000007-93"
printf 'selfkey\t%s/o5.md\t%s\t0\t\t\t\n' "$THOME" "$(( $(date +%s) - 30000 ))" > "$THOME/in-progress/$EXPIRED_SELF"
check 'expire_if_stale releases a past-TTL reservation' \
  "$([ "$(PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_expire_if_stale '$EXPIRED_SELF'")" = expired ]; echo $?)" \
  "$(ls "$THOME/in-progress" 2>/dev/null)"
FRESH_SELF="pg-run-selfkey-1700000008-94"
printf 'selfkey\t%s/o6.md\t%s\t0\t\t\t\n' "$THOME" "$(date +%s)" > "$THOME/in-progress/$FRESH_SELF"
check 'expire_if_stale keeps an unexpired reservation' \
  "$([ -z "$(PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_expire_if_stale '$FRESH_SELF'")" ] && [ -f "$THOME/in-progress/$FRESH_SELF" ]; echo $?)" \
  "$(ls "$THOME/in-progress" 2>/dev/null)"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 --json >"$TDIR/st.json" 2>/dev/null; RC=$?
check '--status --json exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
check '--status --json reservation marker' "$([ "$(jq -r '.reservations[0].marker' "$TDIR/st.json")" = "$SMARKER" ]; echo $?)" "$(cat "$TDIR/st.json")"
check '--status --json remembered url' "$([ "$(jq -r '.reservations[0].conversation_url' "$TDIR/st.json")" = "https://chatgpt.com/c/abc123" ]; echo $?)" "$(jq -c .reservations "$TDIR/st.json")"
check '--status --json rounds remaining' "$([ "$(jq -r '.rounds[0].remaining' "$TDIR/st.json")" = 1 ] && [ "$(jq -r '.rounds[0].cap' "$TDIR/st.json")" = 3 ]; echo $?)" "$(jq -c .rounds "$TDIR/st.json")"
# #66 gate P2: --status must expose the scored trajectory, not just the numbers.
printf '%s\tFIX-FIRST\t0\t5\t0\t0\n%s\tFIX-FIRST\t0\t7\t0\t0\n%s\tFIX-FIRST\t0\t8\t0\t0\n' \
  "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$SHOME/rounds/acme-widgets-42.hist"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 --json >"$TDIR/st2.json" 2>/dev/null
check '--status --json exposes the trajectory' "$([ "$(jq -r '.rounds[0].trajectory' "$TDIR/st2.json")" = '5→7→8' ]; echo $?)" "$(jq -c .rounds "$TDIR/st2.json")"
check '--status --json flags the churn brake' "$([ "$(jq -r '.rounds[0].churn_braked' "$TDIR/st2.json")" = true ]; echo $?)" "$(jq -c .rounds "$TDIR/st2.json")"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st2.out" 2>/dev/null
check '--status text names the churn brake' "$(grep -q 'CHURN BRAKE' "$TDIR/st2.out"; echo $?)" "$(grep -i 'spent' "$TDIR/st2.out")"
rm -f "$SHOME/rounds/acme-widgets-42.hist"
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

echo '# U1: pro-gate-stats.sh queue/run percentiles on a MIXED ledger (old rows without the new'
echo '# fields alongside new rows that carry them) — old .secs percentiles unchanged, new'
echo '# percentiles computed from new-field rows only, no error, existing fields byte-compatible.'
mkdir -p "$TDIR/home-mixed"
MIXHOME="$TDIR/home-mixed"
{
  printf '{"ts":"2026-01-01T00:00:00+0000","pr":"1","outcome":"clean","secs":10,"conc":1}\n'
  printf '{"ts":"2026-01-01T00:01:00+0000","pr":"2","outcome":"clean","secs":20,"conc":1}\n'
  printf '{"ts":"2026-01-01T00:02:00+0000","pr":"3","outcome":"clean","secs":30,"pre_slot_secs":5,"post_slot_secs":25,"conc":1}\n'
  printf '{"ts":"2026-01-01T00:03:00+0000","pr":"4","outcome":"clean","secs":40,"pre_slot_secs":8,"post_slot_secs":32,"conc":1}\n'
  printf '{"ts":"2026-01-01T00:04:00+0000","pr":"5","outcome":"clean","secs":50,"pre_slot_secs":10,"post_slot_secs":40,"conc":1}\n'
} > "$MIXHOME/ledger.jsonl"
MIX_JSON="$(PRO_GATE_HOME="$MIXHOME" bash "$STATS" 2>/dev/null | awk '/^\{$/{f=1} f')"
check 'stats on mixed ledger emits valid JSON' "$(printf '%s' "$MIX_JSON" | jq empty >/dev/null 2>&1; echo $?)" "$MIX_JSON"
check 'stats mixed-ledger runs count is 5' "$([ "$(printf '%s' "$MIX_JSON" | jq -r .runs)" = 5 ]; echo $?)" "$MIX_JSON"
check 'stats duration_p50_s/p95_s unchanged by rows lacking queue/run fields' \
  "$([ "$(printf '%s' "$MIX_JSON" | jq -r .duration_p50_s)" = 30 ] && [ "$(printf '%s' "$MIX_JSON" | jq -r .duration_p95_s)" = 50 ]; echo $?)" "$MIX_JSON"
check 'stats new pre_slot_p50_s/p95_s computed from new-field rows only' \
  "$([ "$(printf '%s' "$MIX_JSON" | jq -r .pre_slot_p50_s)" = 8 ] && [ "$(printf '%s' "$MIX_JSON" | jq -r .pre_slot_p95_s)" = 10 ]; echo $?)" "$MIX_JSON"
check 'stats new post_slot_p50_s/p95_s computed from new-field rows only' \
  "$([ "$(printf '%s' "$MIX_JSON" | jq -r .post_slot_p50_s)" = 32 ] && [ "$(printf '%s' "$MIX_JSON" | jq -r .post_slot_p95_s)" = 40 ]; echo $?)" "$MIX_JSON"
check 'stats mixed ledger keeps existing fields present (byte-compatible for old consumers)' \
  "$(printf '%s' "$MIX_JSON" | jq -e 'has("runs") and has("by_outcome") and has("success_rate_pct") and has("throttles") and has("salvage_rate_pct") and has("duration_p50_s") and has("duration_p95_s") and has("by_concurrency")' >/dev/null 2>&1; echo $?)" "$MIX_JSON"

echo '# ledger-timing-split Fix 3: lock-timeout rows join the pre-slot population; harvest rows'
echo '# are excluded from both — kind names the invocation explicitly instead of guessing from'
echo '# outcome.'
mkdir -p "$TDIR/home-kind"
KINDHOME="$TDIR/home-kind"
{
  printf '{"ts":"2026-01-01T00:00:00+0000","pr":"1","outcome":"clean","secs":30,"pre_slot_secs":5,"post_slot_secs":25,"kind":"fresh","conc":1}\n'
  printf '{"ts":"2026-01-01T00:01:00+0000","pr":"2","outcome":"clean","secs":40,"pre_slot_secs":8,"post_slot_secs":32,"kind":"fresh","conc":1}\n'
  # A lock-timeout row never launches (LAUNCH_EPOCH unset): its full wait is pre_slot_secs, with
  # post_slot_secs 0. It must join the pre-slot population (it genuinely queued, and the longest
  # waits live here) but not distort post-slot (which stays clean-only, fresh-only).
  printf '{"ts":"2026-01-01T00:02:00+0000","pr":"3","outcome":"lock-timeout","secs":50,"pre_slot_secs":50,"post_slot_secs":0,"kind":"fresh","conc":1}\n'
  # A harvest row never queues (pre_slot_secs 0) and its post_slot_secs is collection time, not
  # generation time. It must be excluded from BOTH percentile populations even though its
  # outcome is "clean".
  printf '{"ts":"2026-01-01T00:03:00+0000","pr":"4","outcome":"clean","secs":1,"pre_slot_secs":0,"post_slot_secs":1000,"kind":"harvest","conc":0}\n'
} > "$KINDHOME/ledger.jsonl"
KIND_JSON="$(PRO_GATE_HOME="$KINDHOME" bash "$STATS" 2>/dev/null | awk '/^\{$/{f=1} f')"
check 'stats kind ledger emits valid JSON' "$(printf '%s' "$KIND_JSON" | jq empty >/dev/null 2>&1; echo $?)" "$KIND_JSON"
# Population sorted by pre_slot_secs: [5, 8, 50] (harvest's 0 excluded) — p50 idx1=8, p95 idx2=50.
check 'lock-timeout row included in pre_slot percentile population' \
  "$([ "$(printf '%s' "$KIND_JSON" | jq -r .pre_slot_p50_s)" = 8 ] && [ "$(printf '%s' "$KIND_JSON" | jq -r .pre_slot_p95_s)" = 50 ]; echo $?)" "$KIND_JSON"
# Post-slot stays clean+fresh only: [25, 32] (lock-timeout's 0 and harvest's 1000 both excluded)
# — p50 idx1=32, p95 idx1=32.
check 'harvest row excluded from pre_slot and post_slot percentile populations' \
  "$([ "$(printf '%s' "$KIND_JSON" | jq -r .post_slot_p50_s)" = 32 ] && [ "$(printf '%s' "$KIND_JSON" | jq -r .post_slot_p95_s)" = 32 ]; echo $?)" "$KIND_JSON"
# Historical rows with no kind at all must still count as fresh (v0.19-era ledger rows predate
# the field entirely).
printf '{"ts":"2026-01-01T00:04:00+0000","pr":"5","outcome":"clean","secs":20,"pre_slot_secs":2,"post_slot_secs":18,"conc":1}\n' >> "$KINDHOME/ledger.jsonl"
KIND_JSON2="$(PRO_GATE_HOME="$KINDHOME" bash "$STATS" 2>/dev/null | awk '/^\{$/{f=1} f')"
check 'missing kind field treated as fresh (historical rows still count)' \
  "$(printf '%s' "$KIND_JSON2" | jq -e '.pre_slot_p50_s != null and .post_slot_p50_s != null' >/dev/null 2>&1; echo $?)" "$KIND_JSON2"
rm -rf "$KINDHOME"

echo '# v0.28: severity sidecar counts only OPEN findings (RESOLVED verification blocks excluded)'
mkdir -p "$SHOME/rounds"
printf '1000\n' > "$SHOME/rounds/sev-key-1"
cat > "$TDIR/sevreview.md" <<'SEV'
P0: none of the priors remain

[P0] a.sh:1 — RESOLVED — fixed earlier
[P0] b.sh:2 — a new unresolved problem
[P0] f.sh:6 — the RESOLVED_MODEL capture is clobbered mid-run
[P0] g.sh:7 — the RESOLVED state can be forged by any writer
[P1] c.sh:3 — RESOLVED — fixed
[P1] d.sh:4 — STILL-PRESENT — not fixed
[P1] e.sh:5 — another new finding

VERDICT: FIX-FIRST — x
SEV
PRO_GATE_HOME="$SHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_note_severity sev-key-1 '$TDIR/sevreview.md'"
SEV_LINE="$(cat "$SHOME/rounds/sev-key-1.last" 2>/dev/null)"
# 3 open P0 (RESOLVED_MODEL identifier and a description WORD are not status tokens —
# gate #54 r3+r4 P2), 2 open P1.
check 'severity sidecar excludes only status-position RESOLVED' "$([ "$(printf '%s' "$SEV_LINE" | cut -f2)" = 3 ] && [ "$(printf '%s' "$SEV_LINE" | cut -f3)" = 2 ]; echo $?)" "sidecar: $SEV_LINE"

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
check 'nonce-less capture preserved as unbound (exit 9)' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'unbound harvest keeps the reservation' "$([ -f "$TDIR/home/in-progress/$M3" ]; echo $?)" 'reservation destroyed'
check 'unbound capture set aside for inspection' "$(ls "$TDIR/o-prov.md.unbound."* >/dev/null 2>&1; echo $?)" 'no .unbound file'
check 'unbound capture not returned as the review' "$([ ! -s "$TDIR/o-prov.md" ]; echo $?)" 'out file written'
# Under REQUIRE_NONCE the candidate is NOT condemned (gate #54 r6): a mismatched capture may
# be an OLDER verdict from the conversation still generating this run's answer — the memo
# stays so the eventual nonce-bearing result remains reachable, and nothing is blacklisted.
check 'nonce mode keeps the URL memo (older-verdict theory)' "$([ -f "$TDIR/home/conversation-urls/$M3" ]; echo $?)" "$(ls "$TDIR/home/conversation-urls" 2>/dev/null)"
check 'nonce mode blacklists nothing' "$(grep -q "^$M3	" "$TDIR/home/salvage-nonmatching.txt" 2>/dev/null; [ $? -ne 0 ]; echo $?)" "$(cat "$TDIR/home/salvage-nonmatching.txt" 2>/dev/null)"
# LEGACY mode (REQUIRE_NONCE=0): path overlap is authoritative — a zero-overlap capture IS
# foreign, blacklisted by its EXACT matched URL, memo removed via claim-and-verify.
env PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_REQUIRE_NONCE=0 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$M3" --out "$TDIR/o-prov.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'legacy foreign harvest exits 9 with .foreign set-aside' "$([ "$RC" -eq 9 ] && ls "$TDIR/o-prov.md.foreign."* >/dev/null 2>&1; echo $?)" "rc=$RC"
check 'legacy rejection removes the URL memo' "$([ ! -f "$TDIR/home/conversation-urls/$M3" ]; echo $?)" "$(cat "$TDIR/home/conversation-urls/$M3" 2>/dev/null)"
check 'legacy rejection blacklists the EXACT matched URL' "$(grep -q "^$M3	https://chatgpt.com/c/mock-conversation" "$TDIR/home/salvage-nonmatching.txt" 2>/dev/null; echo $?)" "$(cat "$TDIR/home/salvage-nonmatching.txt" 2>/dev/null)"
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
# Nonce-or-nothing (gate r5): path overlap alone no longer ACCEPTS under the default; the
# best-effort path acceptance survives only behind PRO_GATE_REQUIRE_NONCE=0. (The blacklist
# from the rejection above is cleared: this fixture reuses the same mock URL, which a real
# recovered-from-foreign flow would reach via a different conversation.)
rm -f "$TDIR/home/salvage-nonmatching.txt"
printf 'apps/blog-writer/collect.ts\n' > "$TDIR/home/manifests/$M3"
run_engine --harvest "$M3" --out "$TDIR/o-prov.md" --timeout 5s
check 'path overlap alone no longer accepts (nonce-or-nothing)' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
env PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_REQUIRE_NONCE=0 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$M3" --out "$TDIR/o-prov.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'REQUIRE_NONCE=0 accepts on matching path overlap' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
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
check 'RESULT_FILE names the canonical artifact' "$(grep -q "RESULT_FILE=$TDIR/home/completed/$M8" "$TDIR/stdout"; echo $?)" "$(grep RESULT_FILE "$TDIR/stdout")"
# Garbage PRO_GATE_REQUIRE_NONCE values fail CLOSED (gate #54 r10): 'true' is not legacy mode.
M13="pg-run-noncegarbage-6-1700000060-15"
printf '6\t%s\t%s\t0\t1\tGPT-X\n' "$TDIR/o-garbage.md" "$(date +%s)" > "$TDIR/home/in-progress/$M13"
printf 'src/real.sh\n' > "$TDIR/home/manifests/$M13"
cat > "$TDIR/tab.txt" <<TAB
conversation for run marker: $M13
P0: none

[P1] src/real.sh:2 — matching citation but no echo

VERDICT: SHIP — no echo though
TAB
start_mock "$TDIR/tab.txt"
env PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_REQUIRE_NONCE=true NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$M13" --out "$TDIR/o-garbage.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'non-boolean REQUIRE_NONCE enforces (fails closed, exit 9)' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
rm -f "$TDIR/home/in-progress/$M13" "$TDIR/home/manifests/$M13"

echo '# v0.28: artifact-first recovery — no ledger row needed'
M9="pg-run-artifact-4-1700000035-99"
mkdir -p "$TDIR/home/completed"
cp "$TDIR/prov-ours.md" "$TDIR/home/completed/$M9"
printf 'idle tab with no markers at all\n' > "$TDIR/tab.txt"
# Artifact recovery needs no browser and must precede the cooldown gate (gate #54 r3 P2):
# retrievable even while the account is cooling.
printf '%s test-cooldown\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$TDIR/home/throttle.cooldown"
: > "$TDIR/mock.log"
: > "$TDIR/node-args-artifact-cooldown.log"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  PRO_GATE_TIMEOUT_BIN="$TIMEOUT_LOG_BIN" PG_TEST_NODE_ARGS="$TDIR/node-args-artifact-cooldown.log" \
  bash "$ENGINE" --harvest "$M9" --out "$TDIR/o-artifact.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
rm -f "$TDIR/home/throttle.cooldown"
check 'artifact-first recovery exits 0 (even under cooldown, no ledger row)' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
check 'artifact content returned verbatim' "$(cmp -s "$TDIR/o-artifact.md" "$TDIR/prov-ours.md"; echo $?)" "$(head -2 "$TDIR/o-artifact.md" 2>/dev/null)"
check 'artifact retrieval under active cooldown never invokes organizer mode' "$(! grep -q -- '--organize' "$TDIR/node-args-artifact-cooldown.log"; echo $?)" "$(cat "$TDIR/node-args-artifact-cooldown.log")"

# A peer can write the shared account cooldown while this process is queued behind the marker's
# organizer lock. The cooldown check must happen again AFTER lock acquisition; otherwise this
# process launches stale browser traffic as soon as the peer releases serialization.
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$TDIR/home/organizer-locks"
  : > "$TDIR/node-args-artifact-peer-cooldown.log"
  (
    exec 8>>"$TDIR/home/organizer-locks/$M9"
    flock 8
    : > "$TDIR/peer-organizer-locked"
    # Wait until the engine has opened its own descriptor for this flock file. That proves it
    # reached pg_organizer_lock_acquire and is queued behind fd 8 before the peer writes cooldown.
    for _ in $(seq 1 100); do
      waiters=0
      for fd in /proc/[0-9]*/fd/*; do
        [ "$(readlink "$fd" 2>/dev/null || true)" = "$TDIR/home/organizer-locks/$M9" ] \
          && waiters=$((waiters + 1))
      done
      [ "$waiters" -ge 2 ] && break
      sleep 0.05
    done
    printf '%s peer-cooldown\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$TDIR/home/throttle.cooldown"
    sleep 1
  ) &
  PEER_LOCK_PID=$!
  for _ in $(seq 1 50); do [ -f "$TDIR/peer-organizer-locked" ] && break; sleep 0.1; done
  PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
    PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
    PRO_GATE_TIMEOUT_BIN="$TIMEOUT_LOG_BIN" \
    PG_TEST_NODE_ARGS="$TDIR/node-args-artifact-peer-cooldown.log" \
    bash "$ENGINE" --harvest "$M9" --out "$TDIR/o-artifact-peer-cooldown.md" --timeout 5s \
    >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
  wait "$PEER_LOCK_PID"
  rm -f "$TDIR/home/throttle.cooldown"
  check 'artifact recovery still exits 0 when a peer starts cooldown during lock wait' \
    "$([ "$RC" -eq 0 ] && cmp -s "$TDIR/o-artifact-peer-cooldown.md" "$TDIR/prov-ours.md"; echo $?)" \
    "rc=$RC $(tail -2 "$TDIR/stderr")"
  check 'post-lock cooldown recheck suppresses stale organizer traffic' \
    "$(! grep -q -- '--organize' "$TDIR/node-args-artifact-peer-cooldown.log"; echo $?)" \
    "$(cat "$TDIR/node-args-artifact-peer-cooldown.log")"
else
  echo 'ok - post-lock cooldown recheck fixture skipped without flock'
fi
# ...and with the browser fully DOWN (gate #54 r4 P2): the fast path precedes the CDP
# preflight, so a dead port must not turn an on-disk artifact into exit 3.
env PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT=1 PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$M9" --out "$TDIR/o-artifact2.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'artifact returns with the browser down' "$([ "$RC" -eq 0 ] && cmp -s "$TDIR/o-artifact2.md" "$TDIR/prov-ours.md"; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
# The fast path carries full run identity (gate r5 P2): its ledger row is rediscoverable.
FLINE="$(tail -1 "$TDIR/home/ledger.jsonl")"
# v0.30 (#50 item 3): pr is the key's trailing NUMBER; round_key keeps the scoped key.
check 'fast-path ledger row carries pr + round_key' "$([ "$(printf '%s' "$FLINE" | jq -r .pr)" = "4" ] && [ "$(printf '%s' "$FLINE" | jq -r .round_key)" = "artifact-4" ]; echo $?)" "$FLINE"
check 'fast-path ledger row records the artifact digest' "$([ "$(printf '%s' "$FLINE" | jq -r '.sha256 // ""')" = "$(sha256sum "$TDIR/home/completed/$M9" | awk '{print $1}')" ]; echo $?)" "$FLINE"
check 'organizer CDP failure preserves artifact-first exit 0 + output' "$([ "$RC" -eq 0 ] && cmp -s "$TDIR/o-artifact2.md" "$TDIR/prov-ours.md" && grep -q 'reason=cdp-list-failed' "$TDIR/stderr"; echo $?)" "rc=$RC stderr=$(tail -2 "$TDIR/stderr")"

run_artifact_organizer_case() { # <case-id> <marker> [NAME=VALUE ...]
  local case_id="$1" marker="$2"; shift 2
  CASE_HOME="$TDIR/home-$case_id"
  CASE_STATE="$TDIR/state-$case_id.json"
  CASE_OUT="$TDIR/out-$case_id.md"
  CASE_TITLE="pro-gate review: PR #${marker##*-} r1 [$case_id]"
  mkdir -p "$CASE_HOME/completed" "$CASE_HOME/conversation-titles"
  cp "$TDIR/prov-ours.md" "$CASE_HOME/completed/$marker"
  printf '%s\n' "$CASE_TITLE" > "$CASE_HOME/conversation-titles/$marker"
  printf '{"title":null,"archived":false,"events":[]}\n' > "$CASE_STATE"
  {
    printf 'run marker: %s\n' "$marker"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        VERDICT:*) printf '%s (run marker: %s)\n' "$line" "$marker" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$CASE_HOME/completed/$marker"
  } > "$TDIR/tab.txt"
  start_mock "$TDIR/tab.txt" "$CASE_STATE"
  env PRO_GATE_HOME="$CASE_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
    PRO_GATE_SELF_HEAL=0 NODE_OPTIONS= PRO_GATE_TIMEOUT_BIN="$TIMEOUT_LOG_BIN" \
    PG_TEST_NODE_ARGS="$TDIR/node-args-$case_id.log" "$@" bash "$ENGINE" --harvest "$marker" \
    --out "$CASE_OUT" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
  CASE_RC=$?
}

echo '# v0.32: successful organizer controls preserve independent semantics'
MCFG1='pg-run-config-201-1700000201-21'
run_artifact_organizer_case archive-off "$MCFG1" PRO_GATE_CHAT_ARCHIVE=0
check 'CHAT_ARCHIVE=0 keeps exit 0 and exact rename' "$([ "$CASE_RC" -eq 0 ] && [ "$(jq -r .title "$CASE_STATE")" = "$CASE_TITLE" ] && [ "$(jq -r .archived "$CASE_STATE")" = false ]; echo $?)" "rc=$CASE_RC state=$(cat "$CASE_STATE")"
check 'CHAT_ARCHIVE=0 still closes the verified local tab' "$(grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "$(cat "$TDIR/mock.log")"
check 'artifact finalization has no accepted URL without a validated CDP capture source' "$(! grep -q -- '--accepted-url' "$TDIR/node-args-archive-off.log"; echo $?)" "$(cat "$TDIR/node-args-archive-off.log" 2>/dev/null)"
check 'finalizer timeout keeps the organizer lock beyond both mutation windows' "$(awk '$1 + 0 >= 75 && /--finalize/ { found=1 } END { exit !found }' "$TDIR/node-args-archive-off.log"; echo $?)" "$(cat "$TDIR/node-args-archive-off.log" 2>/dev/null)"

MCFG2='pg-run-config-202-1700000202-22'
run_artifact_organizer_case rename-off "$MCFG2" PRO_GATE_CHAT_RENAME=0
check 'CHAT_RENAME=0 still archives durable success' "$([ "$CASE_RC" -eq 0 ] && [ "$(jq -r .title "$CASE_STATE")" = null ] && [ "$(jq -r .archived "$CASE_STATE")" = true ]; echo $?)" "rc=$CASE_RC state=$(cat "$CASE_STATE")"
check 'CHAT_RENAME=0 performs archive only, then closes' "$([ "$(jq -r '[.events[].action] | join(",")' "$CASE_STATE")" = archive ] && grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "state=$(cat "$CASE_STATE") log=$(cat "$TDIR/mock.log")"

MCFG3='pg-run-config-203-1700000203-23'
run_artifact_organizer_case keep-tabs "$MCFG3" PRO_GATE_KEEP_TABS=1
check 'KEEP_TABS=1 permits exact rename but suppresses archive' "$([ "$CASE_RC" -eq 0 ] && [ "$(jq -r .title "$CASE_STATE")" = "$CASE_TITLE" ] && [ "$(jq -r .archived "$CASE_STATE")" = false ]; echo $?)" "rc=$CASE_RC state=$(cat "$CASE_STATE")"
check 'KEEP_TABS=1 leaves the local tab open' "$(! grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "$(cat "$TDIR/mock.log")"
check 'rename-only timeout keeps the organizer lock beyond its mutation lease' "$(awk '$1 + 0 >= 50 && /--organize/ && !/--finalize/ { found=1 } END { exit !found }' "$TDIR/node-args-keep-tabs.log"; echo $?)" "$(cat "$TDIR/node-args-keep-tabs.log" 2>/dev/null)"

MCFG4='pg-run-config-204-1700000204-24'
run_artifact_organizer_case invalid-bools "$MCFG4" PRO_GATE_CHAT_RENAME=yes PRO_GATE_CHAT_ARCHIVE=yes
check 'invalid mutation booleans warn and disable both UI mutations' "$([ "$CASE_RC" -eq 0 ] && [ "$(jq -r '.events | length' "$CASE_STATE")" = 0 ] && grep -q 'invalid PRO_GATE_CHAT_RENAME' "$TDIR/stderr" && grep -q 'invalid PRO_GATE_CHAT_ARCHIVE' "$TDIR/stderr"; echo $?)" "rc=$CASE_RC state=$(cat "$CASE_STATE") stderr=$(grep 'invalid PRO_GATE_CHAT' "$TDIR/stderr")"
check 'invalid mutation booleans still permit verified local cleanup' "$(grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "$(cat "$TDIR/mock.log")"

MCFG5='pg-run-config-205-1700000205-25'
run_artifact_organizer_case native "$MCFG5" PRO_GATE_BROWSER_MODE=native
check 'native artifact recovery performs no CDP organization' "$([ "$CASE_RC" -eq 0 ] && [ "$(jq -r '.events | length' "$CASE_STATE")" = 0 ] && ! grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "rc=$CASE_RC state=$(cat "$CASE_STATE") log=$(cat "$TDIR/mock.log")"

echo '# v0.32: pending durability archives; volatile-only success stays recoverable'
run_harvest_durability_case() { # <case-id> <marker> <block-pending:0|1>
  local case_id="$1" marker="$2" block_pending="$3"
  CASE_HOME="$TDIR/home-$case_id"
  CASE_STATE="$TDIR/state-$case_id.json"
  CASE_OUT="$TDIR/out-$case_id.md"
  CASE_TITLE="pro-gate review: PR #206 r1 [$case_id]"
  mkdir -p "$CASE_HOME/in-progress" "$CASE_HOME/manifests" "$CASE_HOME/conversation-titles"
  printf 'config-206\t%s\t%s\t0\t1\tGPT-X\n' "$CASE_OUT" "$(date +%s)" > "$CASE_HOME/in-progress/$marker"
  printf 'src/real.sh\n' > "$CASE_HOME/manifests/$marker"
  printf '%s\n' "$CASE_TITLE" > "$CASE_HOME/conversation-titles/$marker"
  [ "$block_pending" = 1 ] && printf 'not-a-directory\n' > "$CASE_HOME/pending"
  printf '{"title":null,"archived":false,"events":[]}\n' > "$CASE_STATE"
  {
    printf 'run marker: %s\n' "$marker"
    printf '[P1] src/real.sh:1 - finding\n  Why: test\nP2: none\nP3: none\nVERDICT: SHIP - fixture. (run marker: %s)\n' "$marker"
  } > "$TDIR/tab.txt"
  start_mock "$TDIR/tab.txt" "$CASE_STATE"
  env PRO_GATE_HOME="$CASE_HOME" PRO_GATE_COMPLETED_DIR="$TDIR/completed-block-$case_id" \
    ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 NODE_OPTIONS= \
    PRO_GATE_TIMEOUT_BIN="$TIMEOUT_LOG_BIN" PG_TEST_NODE_ARGS="$TDIR/node-args-$case_id.log" \
    bash "$ENGINE" --harvest "$marker" --out "$CASE_OUT" --timeout 5s \
    >"$TDIR/stdout" 2>"$TDIR/stderr"
  CASE_RC=$?
}

printf 'not-a-directory\n' > "$TDIR/completed-block-pending"
MPEND='pg-run-config-206-1700000206-26'
run_harvest_durability_case pending "$MPEND" 0
check 'pending fallback is a durable exit-0 result' "$([ "$CASE_RC" -eq 0 ] && [ -s "$CASE_HOME/pending/$MPEND" ] && grep -q "RESULT_FILE=$CASE_HOME/pending/$MPEND" "$TDIR/stdout"; echo $?)" "rc=$CASE_RC stdout=$(grep RESULT_FILE "$TDIR/stdout")"
check 'pending fallback still archives and closes' "$([ "$(jq -r .archived "$CASE_STATE")" = true ] && grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "state=$(cat "$CASE_STATE") log=$(cat "$TDIR/mock.log")"
check 'validated harvest forwards its exact CDP capture URL to finalization' "$(grep -q -- '--accepted-url https://chatgpt.com/c/mock-conversation' "$TDIR/node-args-pending.log"; echo $?)" "$(cat "$TDIR/node-args-pending.log" 2>/dev/null)"

printf 'not-a-directory\n' > "$TDIR/completed-block-volatile"
MVOL='pg-run-config-207-1700000207-27'
run_harvest_durability_case volatile "$MVOL" 1
check 'volatile-only persistence still returns exit 0 with explicit warning' "$([ "$CASE_RC" -eq 0 ] && grep -q 'no durable store writable' "$TDIR/stderr"; echo $?)" "rc=$CASE_RC stderr=$(grep 'no durable store' "$TDIR/stderr")"
check 'volatile-only success exact-renames but never archives' "$([ "$(jq -r .title "$CASE_STATE")" = "$CASE_TITLE" ] && [ "$(jq -r .archived "$CASE_STATE")" = false ]; echo $?)" "state=$(cat "$CASE_STATE")"
check 'volatile-only success leaves the local tab open and reservation held' "$(! grep -q 'closed tab1' "$TDIR/mock.log" && [ -f "$CASE_HOME/in-progress/$MVOL" ]; echo $?)" "log=$(cat "$TDIR/mock.log") reservation=$(ls "$CASE_HOME/in-progress" 2>/dev/null)"

echo '# v0.28: provenance rejection blacklists precisely (compare-and-delete memo)'
mkdir -p "$SHOME/conversation-urls"
MPR="pg-run-rejtest-1-1700000050-10"
printf 'https://chatgpt.com/c/genuine-conv\n' > "$SHOME/conversation-urls/$MPR"
PRO_GATE_HOME="$SHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_provenance_reject '$MPR' 'https://chatgpt.com/c/foreign-conv'"
check 'explicit-URL rejection blacklists the foreign URL' "$(grep -q "^$MPR	https://chatgpt.com/c/foreign-conv" "$SHOME/salvage-nonmatching.txt" 2>/dev/null; echo $?)" "$(cat "$SHOME/salvage-nonmatching.txt" 2>/dev/null)"
check 'memo naming a DIFFERENT (genuine) URL survives' "$([ -f "$SHOME/conversation-urls/$MPR" ]; echo $?)" 'memo deleted despite mismatch'
PRO_GATE_HOME="$SHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_provenance_reject '$MPR' 'https://chatgpt.com/c/genuine-conv'"
check 'memo naming the rejected URL is removed' "$([ ! -f "$SHOME/conversation-urls/$MPR" ]; echo $?)" 'memo survived its own rejection'


echo '# v0.28: unbindable captures fail closed when the nonce was promised'
M11="pg-run-unbound-1-1700000041-33"
printf '1\t%s\t%s\t0\t1\tGPT-X\n' "$TDIR/o-unbound.md" "$(date +%s)" > "$TDIR/home/in-progress/$M11"
printf 'src/real.sh\n' > "$TDIR/home/manifests/$M11"
# Deliberately NO .nonce flag: fail-closed must not depend on the sidecar's existence
# (gate #54 r4 P1 — killed wrappers / failed writes / pre-v0.28 must not fail open).
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

echo '# v0.28 r9: publication is verified; artifacts are rediscoverable'
run_engine --pr 55 --repo "$TDIR" --out "$TDIR" --timeout 5s
check 'directory --out rejected up front (exit 2)' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
mkdir -p "$TDIR/ro"; chmod 555 "$TDIR/ro"
run_engine --harvest "$M9" --out "$TDIR/ro/o.md" --timeout 5s
chmod 755 "$TDIR/ro"
# r12: the --out ownership guard fails CLOSED on an unwritable directory (exit 2, before any
# spend or state change) — earlier and more honest than discovering it at publication time.
check 'unwritable --out dir refused up front (exit 2, ownership guard)' "$([ "$RC" -eq 2 ] && grep -q 'ownership' "$TDIR/stderr"; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
PRO_GATE_HOME="$TDIR/home" bash "$ENGINE" --status "$M9" >"$TDIR/st-art.out" 2>/dev/null
check '--status surfaces the completed artifact' "$(grep -q 'collected artifacts' "$TDIR/st-art.out" && grep -q "$M9" "$TDIR/st-art.out"; echo $?)" "$(cat "$TDIR/st-art.out")"

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
EARLY_STATE="$TDIR/early-organizer-state.json"
printf '{"title":null,"archived":false,"events":[]}\n' > "$EARLY_STATE"
start_mock "$TDIR/tab.txt" "$EARLY_STATE"
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
check 'early organizer applies the marker memo title exactly' "$([ -n "$EARLY_MARKER" ] && [ "$(jq -r .title "$EARLY_STATE")" = "$(cat "$TDIR/home/conversation-titles/$EARLY_MARKER" 2>/dev/null)" ]; echo $?)" "state=$(cat "$EARLY_STATE") memo=$(cat "$TDIR/home/conversation-titles/$EARLY_MARKER" 2>/dev/null)"
check 'early organizer leaves in-progress conversation unarchived' "$([ "$(jq -r .archived "$EARLY_STATE")" = false ] && ! grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "state=$(cat "$EARLY_STATE") log=$(cat "$TDIR/mock.log")"
check 'early organizer diagnostic is persisted in the run log' "$(grep -Rqs '^\[oracle-review\] organizer source=' "$TDIR/home/logs"; echo $?)" "$(find "$TDIR/home/logs" -maxdepth 1 -type f -print 2>/dev/null)"
check 'change manifest written beside the reservation' "$([ -n "$EARLY_MARKER" ] && [ -s "$TDIR/home/manifests/$EARLY_MARKER" ]; echo $?)" "manifests: $(ls "$TDIR/home/manifests" 2>/dev/null)"
check 'nonce expectation flag recorded' "$([ -n "$EARLY_MARKER" ] && [ -f "$TDIR/home/manifests/$EARLY_MARKER.nonce" ]; echo $?)" "manifests: $(ls "$TDIR/home/manifests" 2>/dev/null)"

echo '# v0.32: a failed owned run stays named, unarchived, and locally untouched'
cat > "$TDIR/bin/oracle-early-failed" <<'EARLY_FAIL'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
marker=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) marker="$(printf '%s' "$2" | grep -oE 'pg-run-[A-Za-z0-9.-]+' | head -1)"; shift 2;;
    *) shift;;
  esac
done
printf 'still thinking, run marker: %s\n' "$marker" > "${PG_TEST_TAB_FILE:?}"
printf 'Acquired ChatGPT browser slot\n' >&2
# Wait until the early organizer has positively owned and named the chat, then model a browser-
# local loss that final salvage can prove absent. Removing the remembered URL is intentional:
# without that decisive loss signal the engine correctly preserves as in-progress (exit 9).
for _ in $(seq 1 60); do
  grep -q '"title":"pro-gate review:' "${PG_TEST_STATE_FILE:?}" 2>/dev/null && break
  sleep 0.1
done
rm -f "${PRO_GATE_HOME:?}/conversation-urls/$marker"
printf '__NO_TABS__' > "$PG_TEST_TAB_FILE"
exit 1
EARLY_FAIL
chmod +x "$TDIR/bin/oracle-early-failed"
FAIL_HOME="$TDIR/home-organizer-failed"
FAIL_STATE="$TDIR/state-organizer-failed.json"
mkdir -p "$FAIL_HOME"
printf '{"title":null,"archived":false,"events":[]}\n' > "$FAIL_STATE"
printf 'no marker yet\n' > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt" "$FAIL_STATE"
env PRO_GATE_HOME="$FAIL_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_EARLY_PROBE_SECS=1 PRO_GATE_REATTACH_TIMEOUT=1 PRO_GATE_SALVAGE_SECS=2 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-early-failed" PG_TEST_TAB_FILE="$TDIR/tab.txt" \
  PG_TEST_STATE_FILE="$FAIL_STATE" NODE_OPTIONS= \
  bash "$ENGINE" --pr 121 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$TDIR/o-organizer-failed.md" --timeout 8s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
FAIL_MARKER="$(jq -r .marker "$TDIR/o-organizer-failed.md.status" 2>/dev/null)"
check 'owned failed run exits 6 after decisive loss' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC stderr=$(tail -3 "$TDIR/stderr")"
check 'owned failed run keeps its exact early title' "$([ -n "$FAIL_MARKER" ] && [ "$(jq -r .title "$FAIL_STATE")" = "$(cat "$FAIL_HOME/conversation-titles/$FAIL_MARKER" 2>/dev/null)" ]; echo $?)" "state=$(cat "$FAIL_STATE") marker=$FAIL_MARKER"
check 'owned failed run is never archived or locally closed' "$([ "$(jq -r .archived "$FAIL_STATE")" = false ] && [ "$(jq -r '[.events[].action] | join(",")' "$FAIL_STATE")" = rename ] && ! grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "state=$(cat "$FAIL_STATE") log=$(cat "$TDIR/mock.log")"

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
: > "$TDIR/node-args-directnonce.log"
env PRO_GATE_HOME="$TDIR/home-nonce" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-nonce" NODE_OPTIONS= \
  PRO_GATE_TIMEOUT_BIN="$TIMEOUT_LOG_BIN" PG_TEST_NODE_ARGS="$TDIR/node-args-directnonce.log" \
  bash "$ENGINE" --pr 131 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$TDIR/o-directnonce.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'direct nonce capture exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'direct capture nonce stripped' "$(grep -q 'run marker' "$TDIR/o-directnonce.md"; [ $? -ne 0 ]; echo $?)" "$(tail -1 "$TDIR/o-directnonce.md" 2>/dev/null)"
check 'direct capture finalization never invents accepted URL authority' "$(! grep -q -- '--accepted-url' "$TDIR/node-args-directnonce.log"; echo $?)" "$(cat "$TDIR/node-args-directnonce.log")"

echo '# v0.32: a delayed early organizer cannot wake after terminal archive/close'
cat > "$TDIR/bin/oracle-organizer-race" <<'RACE'
#!/usr/bin/env bash
out=""; marker=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) marker="$(printf '%s' "$2" | grep -oE 'pg-run-[A-Za-z0-9.-]+' | head -1)"; shift 2;;
    --write-output) out="$2"; shift 2;;
    *) shift;;
  esac
done
printf '[P1] a.sh:1 - finding\n  Why: test\nP2: none\nP3: none\nVERDICT: SHIP - fixture. (run marker: %s)\n' "$marker" > "$out"
{ printf 'run marker: %s\n' "$marker"; cat "$out"; } > "${PG_TEST_TAB_FILE:?}"
RACE
chmod +x "$TDIR/bin/oracle-organizer-race"
RACE_HOME="$TDIR/home-organizer-race"
RACE_STATE="$TDIR/state-organizer-race.json"
mkdir -p "$RACE_HOME"
printf '{"title":null,"archived":false,"events":[]}\n' > "$RACE_STATE"
printf 'no marker yet\n' > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt" "$RACE_STATE"
RACE_START="$(date +%s)"
env PRO_GATE_HOME="$RACE_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_EARLY_PROBE_SECS=15 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-organizer-race" \
  PG_TEST_TAB_FILE="$TDIR/tab.txt" NODE_OPTIONS= \
  bash "$ENGINE" --pr 132 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$TDIR/o-organizer-race.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
RACE_ELAPSED=$(( $(date +%s) - RACE_START ))
check 'terminal success beats the delayed organizer timer' "$([ "$RC" -eq 0 ] && [ "$RACE_ELAPSED" -lt 15 ] && grep -q 'closed tab1' "$TDIR/mock.log"; echo $?)" "rc=$RC elapsed=$RACE_ELAPSED log=$(cat "$TDIR/mock.log")"
sleep 6
check 'revoked early organizer performs no post-finalization render or mutation' "$([ "$(jq -r '[.events[].action] | join(",")' "$RACE_STATE")" = 'rename,archive' ] && ! grep -q '^opened scratch' "$TDIR/mock.log"; echo $?)" "state=$(cat "$RACE_STATE") log=$(cat "$TDIR/mock.log")"

# A helper that already passed lease validation owns the marker lock until its browser work ends.
# Terminal paths that elect no mutation must still join it: otherwise the helper survives the
# parent and can render through a cooldown written after the parent already ledgered its outcome.
cat > "$TDIR/bin/oracle-organizer-join" <<'JOIN'
#!/usr/bin/env bash
out=""; marker=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) marker="$(printf '%s' "$2" | grep -oE 'pg-run-[A-Za-z0-9.-]+' | head -1)"; shift 2;;
    --write-output) out="$2"; shift 2;;
    *) shift;;
  esac
done
mkdir -p "${PRO_GATE_HOME:?}/organizer-locks"
if command -v flock >/dev/null 2>&1; then
  (
    exec 8>>"$PRO_GATE_HOME/organizer-locks/$marker"
    flock 8
    : > "${PG_TEST_JOIN_LOCKED:?}"
    sleep 3
    : > "${PG_TEST_JOIN_RELEASED:?}"
  ) </dev/null >/dev/null 2>&1 &
else
  (
    mkdir "$PRO_GATE_HOME/organizer-locks/$marker.d"
    : > "${PG_TEST_JOIN_LOCKED:?}"
    sleep 3
    rmdir "$PRO_GATE_HOME/organizer-locks/$marker.d"
    : > "${PG_TEST_JOIN_RELEASED:?}"
  ) </dev/null >/dev/null 2>&1 &
fi
for _ in $(seq 1 50); do [ -f "${PG_TEST_JOIN_LOCKED:?}" ] && break; sleep 0.1; done
printf '[P1] a.sh:1 - finding\n  Why: test\nP2: none\nP3: none\nVERDICT: SHIP - fixture. (run marker: %s)\n' "$marker" > "$out"
JOIN
chmod +x "$TDIR/bin/oracle-organizer-join"

run_join_only_case() { # <id> [NAME=VALUE ...]
  local id="$1"; shift
  JOIN_HOME="$TDIR/home-join-$id"
  JOIN_OUT="$TDIR/o-join-$id.md"
  JOIN_LOCKED="$TDIR/join-$id.locked"
  JOIN_RELEASED="$TDIR/join-$id.released"
  mkdir -p "$JOIN_HOME"
  printf 'foreign idle tab\n' > "$TDIR/tab.txt"
  start_mock "$TDIR/tab.txt"
  env PRO_GATE_HOME="$JOIN_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
    PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 PRO_GATE_KEEP_TABS=1 \
    PRO_GATE_EARLY_PROBE_SECS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-organizer-join" \
    PG_TEST_JOIN_LOCKED="$JOIN_LOCKED" PG_TEST_JOIN_RELEASED="$JOIN_RELEASED" \
    NODE_OPTIONS= "$@" bash "$ENGINE" --pr 133 --repo "$TDIR" \
      --diff "$TDIR/small.diff" --out "$JOIN_OUT" --timeout 5s \
      >"$TDIR/stdout" 2>"$TDIR/stderr"
  JOIN_RC=$?
}

echo '# v0.32 gate: every terminal path joins an already-running early organizer'
run_join_only_case rename-off PRO_GATE_CHAT_RENAME=0
check 'rename-disabled KEEP_TABS success waits for the marker organizer' \
  "$([ "$JOIN_RC" -eq 0 ] && [ -f "$JOIN_RELEASED" ]; echo $?)" \
  "rc=$JOIN_RC released=$(test -f "$JOIN_RELEASED"; echo $?) stderr=$(tail -2 "$TDIR/stderr")"

mkdir -p "$TDIR/home-join-title-missing"
printf 'blocks-title-directory\n' > "$TDIR/home-join-title-missing/conversation-titles"
run_join_only_case title-missing
check 'missing title memo still waits for the marker organizer' \
  "$([ "$JOIN_RC" -eq 0 ] && [ -f "$JOIN_RELEASED" ]; echo $?)" \
  "rc=$JOIN_RC released=$(test -f "$JOIN_RELEASED"; echo $?) stderr=$(tail -2 "$TDIR/stderr")"

# A successful model capture can encounter a throttle only during terminal organization. The child
# writes shared cooldown state; the parent must join it before one ramp update and one ledger append.
echo '# v0.32 gate: organizer throttle precedes ramp and ledger settlement'
THROTTLE_HOME="$TDIR/home-organizer-throttle"
mkdir -p "$THROTTLE_HOME"
printf '2\t4\tseed\n' > "$THROTTLE_HOME/ramp.state"
printf "%s\n" "You're making requests too quickly. Temporarily limited access to your conversations." > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
env PRO_GATE_HOME="$THROTTLE_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=1 PRO_GATE_RAMP_STREAK=5 PRO_GATE_MAX_CONCURRENCY=3 \
  PRO_GATE_MAX_RETRIES=0 PRO_GATE_EARLY_PROBE_SECS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-nonce" \
  NODE_OPTIONS= bash "$ENGINE" --pr 134 --repo "$TDIR" --diff "$TDIR/small.diff" \
    --out "$TDIR/o-organizer-throttle.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
THROTTLE_ROW="$(tail -1 "$THROTTLE_HOME/ledger.jsonl" 2>/dev/null)"
check 'organizer-detected throttle preserves collected exit 0' \
  "$([ "$RC" -eq 0 ] && [ -f "$THROTTLE_HOME/throttle.cooldown" ]; echo $?)" \
  "rc=$RC cooldown=$(cat "$THROTTLE_HOME/throttle.cooldown" 2>/dev/null)"
check 'organizer throttle is ledgered instead of clean' \
  "$([ "$(printf '%s' "$THROTTLE_ROW" | jq -r .outcome 2>/dev/null)" = throttle ]; echo $?)" \
  "$THROTTLE_ROW"
check 'organizer throttle applies exactly one ramp reset' \
  "$([ "$(grep -c '^\[pro-gate ramp\]' "$TDIR/stderr")" -eq 1 ] \
      && grep -q 'throttle observed' "$TDIR/stderr" \
      && awk -F'\t' 'NR==1{exit !($1==1 && $2==0)}' "$THROTTLE_HOME/ramp.state"; echo $?)" \
  "state=$(cat "$THROTTLE_HOME/ramp.state" 2>/dev/null) ramp-log=$(grep '^\[pro-gate ramp\]' "$TDIR/stderr")"

# A cooldown that predates artifact-only recovery suppresses browser traffic, but it is not evidence
# that this invocation hit a throttle. Preserve the existing clean ledger semantics.
ARTIFACT_COOLDOWN_ROW="$(grep -F '"out":"'$TDIR'/o-artifact.md"' "$TDIR/home/ledger.jsonl" | tail -1)"
check 'pre-existing cooldown does not relabel artifact recovery as throttle' \
  "$([ "$(printf '%s' "$ARTIFACT_COOLDOWN_ROW" | jq -r .outcome 2>/dev/null)" = clean ]; echo $?)" \
  "$ARTIFACT_COOLDOWN_ROW"

# Stock macOS lacks flock. Model a winner paused after mkdir but before metadata publication; a
# contender must treat that empty directory as busy rather than deleting a live lock after one second.
echo '# v0.32 gate: no-flock organizer lock never steals a publication-in-progress'
NOFLOCK_HOME="$TDIR/home-organizer-noflock"
NOFLOCK_MARKER='pg-run-config-208-1700000208-28'
NOFLOCK_DIR="$NOFLOCK_HOME/organizer-locks/$NOFLOCK_MARKER.d"
mkdir -p "$NOFLOCK_HOME/completed" "$NOFLOCK_HOME/conversation-titles" "$NOFLOCK_DIR"
cp "$TDIR/prov-ours.md" "$NOFLOCK_HOME/completed/$NOFLOCK_MARKER"
printf 'pro-gate review: PR #208 r1 [noflock]\n' > "$NOFLOCK_HOME/conversation-titles/$NOFLOCK_MARKER"
inode_of() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }
NOFLOCK_INODE="$(inode_of "$NOFLOCK_DIR")"
(
  sleep 2
  [ -d "$NOFLOCK_DIR" ] && [ "$(inode_of "$NOFLOCK_DIR")" = "$NOFLOCK_INODE" ] \
    || { : > "$TDIR/noflock-stolen"; exit 0; }
  owner="${BASHPID:-$$}"
  token="$(bash -c '. "'$HERE'/../lib/pro-gate-lib.sh"; pg_pid_token '"$owner" 2>/dev/null || true)"
  printf '%s\n' "$owner" > "$NOFLOCK_DIR/pid"
  printf '%s\n' "$token" > "$NOFLOCK_DIR/token"
  : > "$TDIR/noflock-published"
  sleep 2
  rm -rf "$NOFLOCK_DIR"
) &
NOFLOCK_OWNER_PID=$!
printf 'idle tab with no markers\n' > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
env PRO_GATE_HOME="$NOFLOCK_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_TEST_ORGANIZER_NO_FLOCK=1 \
  PRO_GATE_TEST_ORGANIZER_LOCK_WAIT=8 PRO_GATE_TIMEOUT_BIN="$TIMEOUT_LOG_BIN" \
  PG_TEST_NODE_ARGS="$TDIR/node-args-noflock.log" NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$NOFLOCK_MARKER" --out "$TDIR/o-noflock.md" --timeout 5s \
    >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
wait "$NOFLOCK_OWNER_PID"
check 'no-flock contender preserves the live unpublished lock' \
  "$([ "$RC" -eq 0 ] && [ -f "$TDIR/noflock-published" ] && [ ! -f "$TDIR/noflock-stolen" ]; echo $?)" \
  "rc=$RC published=$(test -f "$TDIR/noflock-published"; echo $?) stolen=$(test -f "$TDIR/noflock-stolen"; echo $?) stderr=$(tail -2 "$TDIR/stderr")"
check 'no-flock lock metadata and directory are retired after the join' \
  "$([ ! -e "$NOFLOCK_DIR" ]; echo $?)" "lock remains: $(find "$NOFLOCK_HOME/organizer-locks" -maxdepth 2 -print 2>/dev/null)"

# Housekeeping must run on artifact-only harvests, not only fresh reviews. A day-old crash-left
# directory should be removed before the no-flock join, while a fresh sibling remains untouched.
echo '# v0.32 gate: harvest-only recovery sweeps stale organizer locks'
STALE_HOME="$TDIR/home-organizer-stale"
STALE_LOCK_ROOT="$TDIR/custom-organizer-locks"
STALE_MARKER='pg-run-config-2081-1700000281-281'
STALE_DIR="$STALE_LOCK_ROOT/$STALE_MARKER.d"
FRESH_DIR="$STALE_LOCK_ROOT/pg-run-config-fresh-1700000282-282.d"
mkdir -p "$STALE_HOME/completed" "$STALE_DIR" "$FRESH_DIR"
cp "$TDIR/prov-ours.md" "$STALE_HOME/completed/$STALE_MARKER"
touch -d '3 days ago' "$STALE_DIR" 2>/dev/null || touch -t 202001010000 "$STALE_DIR"
env PRO_GATE_HOME="$STALE_HOME" PRO_GATE_ORGANIZER_LOCK_DIR="$STALE_LOCK_ROOT" \
  ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_KEEP_TABS=1 PRO_GATE_CHAT_RENAME=0 \
  PRO_GATE_TEST_ORGANIZER_NO_FLOCK=1 PRO_GATE_TEST_ORGANIZER_LOCK_WAIT=1 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$STALE_MARKER" --out "$TDIR/o-noflock-stale.md" --timeout 5s \
    >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'artifact-only harvest removes its stale no-flock lock before joining' \
  "$([ "$RC" -eq 0 ] && [ ! -e "$STALE_DIR" ] \
      && ! grep -q 'organizer-lock-timeout' "$TDIR/stderr"; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/stderr") locks=$(find "$STALE_LOCK_ROOT" -maxdepth 2 -print 2>/dev/null)"
check 'organizer housekeeping honors the custom directory and preserves fresh locks' \
  "$([ -d "$FRESH_DIR" ]; echo $?)" \
  "locks=$(find "$STALE_LOCK_ROOT" -maxdepth 2 -print 2>/dev/null)"
check 'stale-lock recovery returns the exact durable artifact' \
  "$(cmp -s "$TDIR/o-noflock-stale.md" "$STALE_HOME/completed/$STALE_MARKER"; echo $?)" \
  "stdout=$(grep RESULT_FILE "$TDIR/stdout" 2>/dev/null)"

# --status is inspection-only even when it sees organizer housekeeping candidates.
STATUS_STALE_DIR="$STALE_LOCK_ROOT/pg-run-status-stale-1700000283-283.d"
mkdir -p "$STATUS_STALE_DIR"
touch -d '3 days ago' "$STATUS_STALE_DIR" 2>/dev/null || touch -t 202001010000 "$STATUS_STALE_DIR"
env PRO_GATE_HOME="$STALE_HOME" PRO_GATE_ORGANIZER_LOCK_DIR="$STALE_LOCK_ROOT" \
  bash "$ENGINE" --status >"$TDIR/status-organizer-lock.out" 2>"$TDIR/status-organizer-lock.err"
RC=$?
check '--status does not sweep stale organizer locks' \
  "$([ "$RC" -eq 0 ] && [ -d "$STATUS_STALE_DIR" ]; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/status-organizer-lock.err")"

# An empty crash-left directory has no trustworthy owner record. It stays busy for this bounded
# call rather than being deleted from under a winner that may still be publishing metadata.
BUSY_HOME="$TDIR/home-organizer-busy"
BUSY_MARKER='pg-run-config-209-1700000209-29'
mkdir -p "$BUSY_HOME/completed" "$BUSY_HOME/organizer-locks/$BUSY_MARKER.d"
cp "$TDIR/prov-ours.md" "$BUSY_HOME/completed/$BUSY_MARKER"
env PRO_GATE_HOME="$BUSY_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_KEEP_TABS=1 PRO_GATE_CHAT_RENAME=0 \
  PRO_GATE_TEST_ORGANIZER_NO_FLOCK=1 PRO_GATE_TEST_ORGANIZER_LOCK_WAIT=1 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$BUSY_MARKER" --out "$TDIR/o-noflock-busy.md" --timeout 5s \
    >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'no-flock missing metadata stays busy instead of being stolen' \
  "$([ "$RC" -eq 0 ] && [ -d "$BUSY_HOME/organizer-locks/$BUSY_MARKER.d" ] \
      && grep -q 'organizer-lock-timeout' "$TDIR/stderr"; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/stderr")"

# Selectively fail the ownership-record install after mkdir. Acquisition must fail and remove its
# partial directory; browser work must never start under unpublished ownership.
PUB_HOME="$TDIR/home-organizer-publish-fail"
PUB_MARKER='pg-run-config-210-1700000210-30'
PUB_OS_HOME="$TDIR/os-home-organizer-publish-fail"
PUB_INTERCEPT="$TDIR/organizer-publish-intercepted"
mkdir -p "$PUB_HOME/completed" "$PUB_OS_HOME/.local/bin"
cp "$TDIR/prov-ours.md" "$PUB_HOME/completed/$PUB_MARKER"
cat > "$PUB_OS_HOME/.local/bin/mv" <<'PUB_MV'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="$arg"; done
case "$last" in
  */organizer-locks/*.d/pid)
    : > "${PG_TEST_PUB_INTERCEPT:?}"
    exit 1
    ;;
esac
exec /bin/mv "$@"
PUB_MV
chmod +x "$PUB_OS_HOME/.local/bin/mv"
env HOME="$PUB_OS_HOME" PG_TEST_PUB_INTERCEPT="$PUB_INTERCEPT" \
  PRO_GATE_HOME="$PUB_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_KEEP_TABS=1 PRO_GATE_CHAT_RENAME=0 \
  PRO_GATE_TEST_ORGANIZER_NO_FLOCK=1 PRO_GATE_TEST_ORGANIZER_LOCK_WAIT=1 NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$PUB_MARKER" --out "$TDIR/o-noflock-publish.md" --timeout 5s \
    >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'no-flock acquisition fails when ownership publication fails' \
  "$([ "$RC" -eq 0 ] && [ -f "$PUB_INTERCEPT" ] \
      && [ ! -e "$PUB_HOME/organizer-locks/$PUB_MARKER.d" ] \
      && grep -q 'organizer-lock-timeout' "$TDIR/stderr"; echo $?)" \
  "rc=$RC intercepted=$(test -f "$PUB_INTERCEPT"; echo $?) stderr=$(cat "$TDIR/stderr") locks=$(find "$PUB_HOME/organizer-locks" -maxdepth 2 -print 2>/dev/null)"

# Replace ownership while the organizer helper runs. Release must compare both fields and preserve
# the replacement directory instead of deleting a lock it no longer owns.
RELEASE_HOME="$TDIR/home-organizer-release"
RELEASE_MARKER='pg-run-config-211-1700000211-31'
RELEASE_TIMEOUT="$TDIR/timeout-organizer-release"
mkdir -p "$RELEASE_HOME/completed" "$RELEASE_HOME/conversation-titles"
cp "$TDIR/prov-ours.md" "$RELEASE_HOME/completed/$RELEASE_MARKER"
printf 'pro-gate review: PR #211 r1 [release]\n' > "$RELEASE_HOME/conversation-titles/$RELEASE_MARKER"
cat > "$RELEASE_TIMEOUT" <<'RELEASE_TIMEOUT_SH'
#!/usr/bin/env bash
case " $* " in
  *' --organize '*)
    for dir in "${PRO_GATE_HOME:?}"/organizer-locks/*.d; do
      [ -d "$dir" ] || continue
      printf 'replacement-owner\n' > "$dir/pid"
    done ;;
esac
exec /usr/bin/timeout "$@"
RELEASE_TIMEOUT_SH
chmod +x "$RELEASE_TIMEOUT"
printf 'idle tab with no markers\n' > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
env PRO_GATE_HOME="$RELEASE_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_TEST_ORGANIZER_NO_FLOCK=1 \
  PRO_GATE_TIMEOUT_BIN="$RELEASE_TIMEOUT" NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$RELEASE_MARKER" --out "$TDIR/o-noflock-release.md" --timeout 5s \
    >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
REPLACEMENT_DIR="$RELEASE_HOME/organizer-locks/$RELEASE_MARKER.d"
check 'no-flock release cannot remove replacement ownership' \
  "$([ "$RC" -eq 0 ] && [ -d "$REPLACEMENT_DIR" ] \
      && grep -q '^replacement-owner$' "$REPLACEMENT_DIR/pid"; echo $?)" \
  "rc=$RC stderr=$(tail -2 "$TDIR/stderr") locks=$(find "$RELEASE_HOME/organizer-locks" -maxdepth 2 -print 2>/dev/null)"

echo '# v0.29: the prompt leads with the run-naming title line (#49 phase 1)'
cat > "$TDIR/bin/oracle-dump" <<'DUMP'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in
  -p) printf '%s' "$2" > "${PG_TEST_PROMPT_DUMP:-/dev/null}"; shift 2;;
  --write-output) out="$2"; shift 2;;
  *) shift;;
esac; done
printf '[P1] a.sh:1 - f\n  Why: t\nP2: none\nP3: none\nVERDICT: SHIP - ok. (run marker: %s)\n' \
  "$(grep -oE 'pg-run-[A-Za-z0-9.-]+' "${PG_TEST_PROMPT_DUMP:-/dev/null}" | head -1)" > "$out"
DUMP
chmod +x "$TDIR/bin/oracle-dump"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
mkdir -p "$TDIR/home-title"
env PRO_GATE_HOME="$TDIR/home-title" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 PG_TEST_PROMPT_DUMP="$TDIR/prompt-dump.txt" \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-dump" NODE_OPTIONS= \
  bash "$ENGINE" --pr 132 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$TDIR/o-title.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'title-line run exits 0 (nonce echoed back from the dumped prompt)' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'prompt first line names the run + round' "$(head -1 "$TDIR/prompt-dump.txt" 2>/dev/null | grep -q '^pro-gate review: PR #132 r1 \['; echo $?)" "first line: $(head -1 "$TDIR/prompt-dump.txt" 2>/dev/null)"
TITLE_MARKER="$(jq -r .marker "$TDIR/o-title.md.status" 2>/dev/null)"
check 'marker-scoped title memo equals the prompt title exactly' "$([ -n "$TITLE_MARKER" ] && [ "$(cat "$TDIR/home-title/conversation-titles/$TITLE_MARKER" 2>/dev/null)" = "$(head -1 "$TDIR/prompt-dump.txt" 2>/dev/null)" ]; echo $?)" "marker=$TITLE_MARKER memo=$(cat "$TDIR/home-title/conversation-titles/$TITLE_MARKER" 2>/dev/null)"
check 'title memo publication leaves no partial temp file' "$(! find "$TDIR/home-title/conversation-titles" -maxdepth 1 -name '*.tmp.*' -print -quit | grep -q .; echo $?)" "$(find "$TDIR/home-title/conversation-titles" -maxdepth 1 -type f 2>/dev/null)"
# A second round of the SAME PR carries a distinct discriminator (gate #57 P1).
env PRO_GATE_HOME="$TDIR/home-title" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 PG_TEST_PROMPT_DUMP="$TDIR/prompt-dump2.txt" \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-dump" NODE_OPTIONS= \
  bash "$ENGINE" --pr 132 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$TDIR/o-title2.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'second same-PR round exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'second round titles r2' "$(head -1 "$TDIR/prompt-dump2.txt" 2>/dev/null | grep -q '^pro-gate review: PR #132 r2 \['; echo $?)" "first line: $(head -1 "$TDIR/prompt-dump2.txt" 2>/dev/null)"
# The ordinal is monotonic and window-INDEPENDENT (gate #57 r3): a seeded sequence advances
# even when every in-window round timestamp has expired.
TKEY="$(ls "$TDIR/home-title/rounds" 2>/dev/null | grep -vE '\.(seq|last)$|\.tmp' | head -1)"
mkdir -p "$TDIR/home-title/title-seq"
printf '7' > "$TDIR/home-title/title-seq/$TKEY"
printf '100\n' > "$TDIR/home-title/rounds/$TKEY"
env PRO_GATE_HOME="$TDIR/home-title" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 PG_TEST_PROMPT_DUMP="$TDIR/prompt-dump3.txt" \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-dump" NODE_OPTIONS= \
  bash "$ENGINE" --pr 132 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$TDIR/o-title3.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
check 'ordinal advances past expired windows (r8)' "$(head -1 "$TDIR/prompt-dump3.txt" 2>/dev/null | grep -q ' r8 \['; echo $?)" "first line: $(head -1 "$TDIR/prompt-dump3.txt" 2>/dev/null)"

echo '# v0.30 (#50 item 1): scratch dirs are cleaned on exit; a default --out inside WORK survives'
SCRATCH_TMP="$TDIR/scratch-tmp"; mkdir -p "$SCRATCH_TMP"
printf 'run marker: none\n' > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
# exit-11 path (oversized): WORK is created, run terminates via pg_finish — dir must be gone.
env TMPDIR="$SCRATCH_TMP" PRO_GATE_HOME="$TDIR/home-scratch" ORACLE_BROWSER_PORT="$PORT" \
  PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --diff "$TDIR/huge.diff" --repo "$TDIR" --out "$TDIR/o-scratch.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'scratch test still refuses oversized (rc=11)' "$([ "$RC" -eq 11 ]; echo $?)" "rc=$RC"
LEFT="$(find "$SCRATCH_TMP" -maxdepth 1 -type d -name 'pro-review.*' | wc -l | tr -d ' ')"
check 'external --out: WORK removed on exit' "$([ "$LEFT" = 0 ]; echo $?)" "leftover=$LEFT"
# Default --out (no --out flag) lands INSIDE WORK: siblings sweep, findings + status survive.
env TMPDIR="$SCRATCH_TMP" PRO_GATE_HOME="$TDIR/home-scratch" ORACLE_BROWSER_PORT="$PORT" \
  PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --diff "$TDIR/huge.diff" --repo "$TDIR" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
DWORK="$(find "$SCRATCH_TMP" -maxdepth 1 -type d -name 'pro-review.*' | head -1)"
check 'default --out: WORK dir kept for the caller' "$([ -n "$DWORK" ]; echo $?)" "no surviving WORK"
if [ -n "$DWORK" ]; then
  SIBLINGS="$(find "$DWORK" -mindepth 1 ! -name 'findings.md' ! -name 'findings.md.status' | wc -l | tr -d ' ')"
  check 'default --out: status sidecar survives, siblings swept' \
    "$([ -f "$DWORK/findings.md.status" ] && [ "$SIBLINGS" = 0 ]; echo $?)" \
    "siblings=$SIBLINGS status=$(ls "$DWORK" 2>/dev/null | tr '\n' ' ')"
  rm -rf "$DWORK"
fi

echo '# v0.30 (#50 item 3): harvest ledger rows carry pr=NUMBER and round_key=full key'
MHID="pg-run-acme-widgets-424-1700000000-55"
env PRO_GATE_HOME="$TDIR/home-scratch" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --harvest "$MHID" --out "$TDIR/o-hid.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
HROW="$(grep "$MHID" "$TDIR/home-scratch/ledger.jsonl" 2>/dev/null | tail -1)"
check 'harvest row pr field is the trailing number' \
  "$(printf '%s' "$HROW" | jq -e '.pr == "424"' >/dev/null 2>&1; echo $?)" "row: $HROW"
check 'harvest row round_key keeps the scoped key' \
  "$(printf '%s' "$HROW" | jq -e '.round_key == "acme-widgets-424"' >/dev/null 2>&1; echo $?)" "row: $HROW"

echo '# v0.30 (#50 item 4): conversation-urls memos older than 14d are swept, fresh ones stay'
SWHOME="$TDIR/home-sweep"; mkdir -p "$SWHOME/conversation-urls"
printf 'https://chatgpt.com/c/old' > "$SWHOME/conversation-urls/pg-run-old-1600000000-1"
printf 'https://chatgpt.com/c/new' > "$SWHOME/conversation-urls/pg-run-new-1700000000-1"
touch -d '20 days ago' "$SWHOME/conversation-urls/pg-run-old-1600000000-1" 2>/dev/null \
  || touch -t "$(date -v-20d +%Y%m%d%H%M 2>/dev/null || echo 202601010000)" "$SWHOME/conversation-urls/pg-run-old-1600000000-1"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
env PRO_GATE_HOME="$SWHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 PG_TEST_PROMPT_DUMP="$TDIR/prompt-sweep.txt" \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-dump" NODE_OPTIONS= \
  bash "$ENGINE" --pr 909 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$TDIR/o-sweep.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
check 'old memo swept' "$([ ! -f "$SWHOME/conversation-urls/pg-run-old-1600000000-1" ]; echo $?)" "still present"
check 'fresh memo kept' "$([ -f "$SWHOME/conversation-urls/pg-run-new-1700000000-1" ]; echo $?)" "missing"

echo '# v0.30 (#50 item 5): native-mode hard-max clamp is announced, not silent'
# The NOTE fires before the oversized refusal, so the fast exit-11 path exercises it.
env PRO_GATE_HOME="$TDIR/home-native" PRO_GATE_BROWSER_MODE=native PRO_GATE_DIFF_HARD_MAX=30000 \
  PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --diff "$TDIR/huge.diff" --repo "$TDIR" --out "$TDIR/o-clamp.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
check 'clamp NOTE printed when operator value is cut' \
  "$(grep -q 'capped to the cook threshold' "$TDIR/stderr"; echo $?)" "$(grep NOTE "$TDIR/stderr" | head -1)"
env PRO_GATE_HOME="$TDIR/home-native" PRO_GATE_BROWSER_MODE=native \
  PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --diff "$TDIR/huge.diff" --repo "$TDIR" --out "$TDIR/o-clamp2.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
check 'no NOTE when nothing was configured' \
  "$(grep -q 'capped to the cook threshold' "$TDIR/stderr"; [ $? -ne 0 ]; echo $?)" "$(grep NOTE "$TDIR/stderr" | head -1)"

echo '# v0.30 (#35): --status surfaces a FREE harvest for a failed run with a remembered URL'
STHOME="$TDIR/home-stfail"; mkdir -p "$STHOME/conversation-urls"
MFAIL="pg-run-acme-widgets-777-1700000000-88"
printf 'https://chatgpt.com/c/abc123' > "$STHOME/conversation-urls/$MFAIL"
printf '%s\n' \
  "{\"ts\":\"2026-08-03T00:00:00+0000\",\"pr\":\"777\",\"repo\":\"\",\"exit\":6,\"outcome\":\"failed\",\"secs\":100,\"attempts\":1,\"conc\":1,\"ceiling\":1,\"live\":0,\"salvaged\":0,\"diff_lines\":10,\"out\":\"/tmp/o777.md\",\"model\":\"m\",\"marker\":\"$MFAIL\",\"round_key\":\"acme-widgets-777\",\"sha256\":\"\"}" \
  > "$STHOME/ledger.jsonl"
env PRO_GATE_HOME="$STHOME" bash "$ENGINE" --status 777 --json >"$TDIR/st.json" 2>"$TDIR/stderr"
check 'failed+memo status recommends FREE harvest' \
  "$(jq -e '.next_step | test("FAILED but its conversation URL is remembered") and test("--harvest")' "$TDIR/st.json" >/dev/null 2>&1; echo $?)" \
  "next_step: $(jq -r .next_step "$TDIR/st.json" 2>/dev/null)"
rm -f "$STHOME/conversation-urls/$MFAIL"
env PRO_GATE_HOME="$STHOME" bash "$ENGINE" --status 777 --json >"$TDIR/st2.json" 2>"$TDIR/stderr"
check 'failed without memo keeps the spend warning' \
  "$(jq -e '.next_step | test("fresh run will SPEND")' "$TDIR/st2.json" >/dev/null 2>&1; echo $?)" \
  "next_step: $(jq -r .next_step "$TDIR/st2.json" 2>/dev/null)"

echo '# v0.30 (#50 item 8): run diagnostics persist to logs/<marker>.log'
check 'harvest run persisted a per-run log' \
  "$([ -s "$TDIR/home-scratch/logs/$MHID.log" ]; echo $?)" \
  "logs: $(ls "$TDIR/home-scratch/logs" 2>/dev/null | tr '\n' ' ')"

echo '# v0.30 gate r1: --status recoverable field is freshness-checked, and the daemon guard consumes it end-to-end'
GHOME="$TDIR/home-guard"; mkdir -p "$GHOME/in-progress"
cp "$HERE/../bin/oracle-review.sh" "$GHOME/oracle-review.sh"
cp "$HERE/../lib/pro-gate-lib.sh" "$GHOME/lib.sh"
chmod +x "$GHOME/oracle-review.sh"
MRES="pg-run-acme-widgets-555-1700000000-77"
printf '555\t/tmp/o555.md\t%s\t0\t1\tgpt\n' "$(date +%s)" > "$GHOME/in-progress/$MRES"
env PRO_GATE_HOME="$GHOME" bash "$ENGINE" --status 555 --json >"$TDIR/grec.json" 2>"$TDIR/stderr"
check 'unexpired reservation: recoverable=true' \
  "$(jq -e '.recoverable == true' "$TDIR/grec.json" >/dev/null 2>&1; echo $?)" "$(jq -c '{recoverable,recoverable_reason}' "$TDIR/grec.json" 2>/dev/null)"
# Same reservation, created 30000s ago (past the 21600s TTL): NOT recoverable.
printf '555\t/tmp/o555.md\t%s\t0\t1\tgpt\n' "$(( $(date +%s) - 30000 ))" > "$GHOME/in-progress/$MRES"
env PRO_GATE_HOME="$GHOME" bash "$ENGINE" --status 555 --json >"$TDIR/grec2.json" 2>"$TDIR/stderr"
check 'expired reservation: recoverable=false' \
  "$(jq -e '.recoverable == false' "$TDIR/grec2.json" >/dev/null 2>&1; echo $?)" "$(jq -c '{recoverable,recoverable_reason}' "$TDIR/grec2.json" 2>/dev/null)"
# The daemon's guard, through the EXACT subprocess call it ships with (a broken --status
# argument order shipped once because nothing exercised this path).
printf '555\t/tmp/o555.md\t%s\t0\t1\tgpt\n' "$(date +%s)" > "$GHOME/in-progress/$MRES"
( export PRO_GATE_HOME="$GHOME" PRO_GATE_DAEMON_LIB_ONLY=1
  . "$HERE/../daemon/daemon.sh"
  engine_state_recoverable "https://github.com/acme/widgets/pull/555" )
check 'daemon guard sees the unexpired reservation (rc 0)' "$([ $? -eq 0 ]; echo $?)" ""
rm -f "$GHOME/in-progress/$MRES"
( export PRO_GATE_HOME="$GHOME" PRO_GATE_DAEMON_LIB_ONLY=1
  . "$HERE/../daemon/daemon.sh"
  engine_state_recoverable "https://github.com/acme/widgets/pull/555" )
check 'daemon guard: no state means NOT recoverable (rc 1)' "$([ $? -ne 0 ]; echo $?)" ""

echo '# v0.30 gate r1: pre-marker failures persist a provisional run log'
PLHOME="$TDIR/home-prelog"; mkdir -p "$PLHOME"
# ORACLE_BROWSER_PORT must point at the mock: without it the engine probes the default CDP
# port, which exists on a dev box with a live Chrome (reaching the repo check, exit 4) but
# not on CI (exit 3 at browser preflight) — the exact leak that failed the v0.30.0 release.
env PRO_GATE_HOME="$PLHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --pr 5 --repo "$TDIR/does-not-exist" --out "$TDIR/o-prelog.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'bad-repo run still exits 4' "$([ "$RC" -eq 4 ]; echo $?)" "rc=$RC"
PLOG="$(find "$PLHOME/logs" -name 'pg-run-unidentified-*.log' -size +0c 2>/dev/null | head -1)"
check 'provisional run log persisted for the pre-marker failure' "$([ -n "$PLOG" ]; echo $?)" "logs: $(ls "$PLHOME/logs" 2>/dev/null | tr '\n' ' ')"

echo '# v0.30 gate r2: EXIT handlers chain instead of clobbering (no-flock lock cleanup vs scratch cleanup)'
( cd "$TDIR" && bash -c '
  . "'"$HERE"'/../lib/pro-gate-lib.sh"
  pg_on_exit "touch \"'"$TDIR"'/exit-a\""
  pg_on_exit "touch \"'"$TDIR"'/exit-b\""
  exit 0' )
check 'both chained EXIT handlers ran' \
  "$([ -f "$TDIR/exit-a" ] && [ -f "$TDIR/exit-b" ]; echo $?)" "$(ls "$TDIR"/exit-* 2>/dev/null | tr '\n' ' ')"

echo '# v0.30 gate r2: pid reuse cannot resurrect a dead run (token-verified liveness)'
TOKHOME="$TDIR/home-token"; mkdir -p "$TOKHOME/active"
NOWEP="$(date +%s)"
# A recycled pid: pid 1 is alive but its token cannot match the recorded garbage token.
printf 'pg-run-acme-widgets-888-1700000000-1\t/tmp/o888.md\t1\t%s\tremote-chrome\tBOGUS-TOKEN\n' "$NOWEP" \
  > "$TOKHOME/active/acme-widgets-888"
env PRO_GATE_HOME="$TOKHOME" bash "$ENGINE" --status 888 --json >"$TDIR/tok1.json" 2>"$TDIR/stderr"
check 'token mismatch: pid-1 record is NOT a live run' \
  "$(jq -e '(.next_step // "") | test("RUNNING right now") | not' "$TDIR/tok1.json" >/dev/null 2>&1; echo $?)" \
  "next_step: $(jq -r .next_step "$TDIR/tok1.json" 2>/dev/null)"
# Our own live pid with its real token: genuinely live, recoverable.
MYTOK="$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; pg_pid_token '"$$"'')"
printf 'pg-run-acme-widgets-888-1700000000-1\t/tmp/o888.md\t%s\t%s\tremote-chrome\t%s\n' "$$" "$NOWEP" "$MYTOK" \
  > "$TOKHOME/active/acme-widgets-888"
env PRO_GATE_HOME="$TOKHOME" bash "$ENGINE" --status 888 --json >"$TDIR/tok2.json" 2>"$TDIR/stderr"
check 'matching token: live run is recoverable' \
  "$(jq -e '.recoverable == true' "$TDIR/tok2.json" >/dev/null 2>&1; echo $?)" \
  "$(jq -c '{recoverable,recoverable_reason}' "$TDIR/tok2.json" 2>/dev/null)"
# Stale token-less record (legacy 5-field) whose epoch is PAST the TTL: not recoverable even
# when the recorded pid is alive (pid 1 again — reuse with no token to disprove it).
printf 'pg-run-acme-widgets-888-1700000000-1\t/tmp/o888.md\t1\t%s\tremote-chrome\n' "$(( NOWEP - 30000 ))" \
  > "$TOKHOME/active/acme-widgets-888"
env PRO_GATE_HOME="$TOKHOME" bash "$ENGINE" --status 888 --json >"$TDIR/tok3.json" 2>"$TDIR/stderr"
check 'legacy stale record past TTL: not recoverable' \
  "$(jq -e '.recoverable == false' "$TDIR/tok3.json" >/dev/null 2>&1; echo $?)" \
  "$(jq -c '{recoverable,recoverable_reason}' "$TDIR/tok3.json" 2>/dev/null)"

echo '# v0.30 gate r2: a harvest never clobbers the original run log'
LOGN1="$(find "$TDIR/home-scratch/logs" -name "$MHID*" 2>/dev/null | wc -l | tr -d ' ')"
env PRO_GATE_HOME="$TDIR/home-scratch" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --harvest "$MHID" --out "$TDIR/o-hid2.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
LOGN2="$(find "$TDIR/home-scratch/logs" -name "$MHID*" 2>/dev/null | wc -l | tr -d ' ')"
check 'second invocation adds a log instead of overwriting' \
  "$([ "$LOGN2" -gt "$LOGN1" ]; echo $?)" "before=$LOGN1 after=$LOGN2"

####################################################################################################
# v0.35 (#88) U3: pg_status's terminal/next_action/wait_class schema, across all 16 known phases,
# both the jq branch and the printf-fallback branch (extraction technique: pull the function body
# out of the engine verbatim and source it alongside the library in an isolated subshell — this
# exercises the REAL implementation, not a reimplementation of its logic).
####################################################################################################
echo '# v0.35 U3: pg_status terminal/next_action/wait_class across all 16 phases'
while IFS='=' read -r name _; do
  case "$name" in PRO_GATE_*|ORACLE_*) unset "$name" ;; esac
done < <(env)
export PRO_GATE_MIN_AVAIL_MB=0 PRO_GATE_MAX_SWAP_PCT=101 PRO_GATE_TIMEOUT_BIN=/usr/bin/timeout
export PRO_GATE_EARLY_PROBE_SECS=0

sed -n '/^pg_status() {/,/^}$/p' "$ENGINE" > "$TDIR/pg_status_fn.sh"
check 'pg_status extraction found the function body' \
  "$(grep -q 'next_action' "$TDIR/pg_status_fn.sh"; echo $?)" "$(wc -l < "$TDIR/pg_status_fn.sh") lines extracted"

PSHOME="$TDIR/home-pgstatus"; mkdir -p "$PSHOME"
PS_OUT="$TDIR/ps-out.md"
PS_MARKER="pg-run-psfix-1700000000-1"
run_pg_status() { # $1 phase; $2 optional PATH override (for the no-jq branch)
  rm -f "$PS_OUT.status"
  PATH="${2:-$PATH}" PRO_GATE_HOME="$PSHOME" bash -c '
    set -uo pipefail
    . "'"$HERE"'/../lib/pro-gate-lib.sh"
    . "'"$TDIR"'/pg_status_fn.sh"
    OUT="'"$PS_OUT"'"; STATUS_FILE="$OUT.status"
    PR_NUM=42; RUN_MARKER="'"$PS_MARKER"'"; RESOLVED_MODEL=""; MODEL_WARN=""; RESULT_PATH=""; attempt=1
    pg_status "'"$1"'"
  '
}

PS_PHASES="cloudflare deferred done failed in-progress launching live-detected oversized preflight retry-wait round-capped salvaging throttled waiting-pr-lock waiting-slot watchdog-killed"
PS_COUNT=0
for phase in $PS_PHASES; do
  PS_COUNT=$((PS_COUNT + 1))
  case "$phase" in
    done|failed) EXP_TERM=true; EXP_WC=verdict ;;
    deferred|oversized|round-capped) EXP_TERM=true; EXP_WC=recover ;;
    in-progress) EXP_TERM=true; EXP_WC=collect ;;
    *) EXP_TERM=false; EXP_WC=null ;;
  esac

  run_pg_status "$phase"
  SF="$PS_OUT.status"
  check "pg_status($phase) jq: valid JSON" "$(jq empty "$SF" >/dev/null 2>&1; echo $?)" "$(cat "$SF" 2>/dev/null)"
  check "pg_status($phase) jq: phase echoed" "$([ "$(jq -r .phase "$SF" 2>/dev/null)" = "$phase" ]; echo $?)" "$(cat "$SF" 2>/dev/null)"
  check "pg_status($phase) jq: terminal=$EXP_TERM (top-level + next_action mirror)" \
    "$(jq -e --argjson t "$EXP_TERM" '.terminal == $t and .next_action.terminal == $t' "$SF" >/dev/null 2>&1; echo $?)" \
    "$(jq -c '{terminal,next_action}' "$SF" 2>/dev/null)"
  if [ "$EXP_WC" = null ]; then
    check "pg_status($phase) jq: wait_class=null" \
      "$(jq -e '.next_action.wait_class == null' "$SF" >/dev/null 2>&1; echo $?)" "$(jq -c .next_action "$SF" 2>/dev/null)"
  else
    check "pg_status($phase) jq: wait_class=$EXP_WC" \
      "$(jq -e --arg wc "$EXP_WC" '.next_action.wait_class == $wc' "$SF" >/dev/null 2>&1; echo $?)" "$(jq -c .next_action "$SF" 2>/dev/null)"
  fi
done
check 'pg_status covered all 16 R8/staleness-table phases' "$([ "$PS_COUNT" -eq 16 ]; echo $?)" "covered $PS_COUNT"

# in-progress carries the EXACT harvest command a caller should run next, marker and out included.
run_pg_status in-progress
check 'pg_status(in-progress) next_action.cmd is the exact harvest command' \
  "$(jq -r '.next_action.cmd' "$PS_OUT.status" 2>/dev/null | grep -qF -- "--harvest '$PS_MARKER' --out '$PS_OUT' --timeout 20m"; echo $?)" \
  "$(jq -r '.next_action.cmd' "$PS_OUT.status" 2>/dev/null)"

echo '# v0.35 U3: pg_status printf-fallback branch (jq removed from PATH) matches the jq branch field-for-field'
build_nojq_path
check 'nojq PATH genuinely hides jq' "$(PATH="$NOJQ_DIR" command -v jq >/dev/null 2>&1; [ $? -ne 0 ]; echo $?)" "jq still resolves on \$NOJQ_DIR"
for phase in $PS_PHASES; do
  case "$phase" in
    done|failed) EXP_TERM_LIT=true; EXP_WC_LIT='"verdict"' ;;
    deferred|oversized|round-capped) EXP_TERM_LIT=true; EXP_WC_LIT='"recover"' ;;
    in-progress) EXP_TERM_LIT=true; EXP_WC_LIT='"collect"' ;;
    *) EXP_TERM_LIT=false; EXP_WC_LIT=null ;;
  esac
  run_pg_status "$phase" "$NOJQ_DIR"
  SF="$PS_OUT.status"
  check "pg_status($phase) printf-fallback: phase echoed" "$(grep -q "\"phase\":\"$phase\"" "$SF"; echo $?)" "$(cat "$SF" 2>/dev/null)"
  # Two DISTINCT occurrences per the real field order (phase..result,terminal,next_action{cmd,terminal,wait_class}):
  # the top-level terminal sits between "result" and "next_action"; the mirrored one sits between
  # next_action's "cmd" and "wait_class". Matching a bare "\"terminal\":$X}" (assuming terminal is
  # the LAST field before a closing brace) never fires -- wait_class always follows it -- and false-failed
  # every phase here until fixed.
  check "pg_status($phase) printf-fallback: terminal=$EXP_TERM_LIT (top-level + next_action mirror)" \
    "$(grep -qF "\"terminal\":$EXP_TERM_LIT,\"next_action\"" "$SF" && grep -qF "\"terminal\":$EXP_TERM_LIT,\"wait_class\"" "$SF"; echo $?)" "$(cat "$SF" 2>/dev/null)"
  check "pg_status($phase) printf-fallback: wait_class=$EXP_WC_LIT" \
    "$(grep -qF "\"wait_class\":$EXP_WC_LIT}" "$SF"; echo $?)" "$(cat "$SF" 2>/dev/null)"
done
run_pg_status in-progress "$NOJQ_DIR"
check 'pg_status(in-progress) printf-fallback: next_action.cmd is the exact harvest command' \
  "$(grep -qF -- "--harvest '$PS_MARKER' --out '$PS_OUT' --timeout 20m" "$PS_OUT.status"; echo $?)" "$(cat "$PS_OUT.status" 2>/dev/null)"

####################################################################################################
# v0.35 (#88) U3: heartbeat integration — the slot-wait loop and the watchdog loop must each
# re-write the status file at most every PRO_GATE_HEARTBEAT_SECS, with a fresh ts and the SAME
# phase (never a regression), while genuinely blocked.
####################################################################################################
echo '# v0.35 U3: slot-wait loop heartbeats while blocked on a busy slot'
HBHOME="$TDIR/home-hb-slot"; mkdir -p "$HBHOME"
exec {HBSLOTFD}>>"$HBHOME/oracle.lock.slot1"; flock -n "$HBSLOTFD"
PRO_GATE_HOME="$HBHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_MAX_CONCURRENCY=1 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_LOCK_WAIT=9 PRO_GATE_HEARTBEAT_SECS=1 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" NODE_OPTIONS= \
  bash "$ENGINE" --diff "$TDIR/small.diff" --repo "$TDIR" --out "$TDIR/o-hbslot.md" --timeout 5s \
  >"$TDIR/hbslot.stdout" 2>"$TDIR/hbslot.stderr" &
HB_ENGPID=$!
# Poll for the waiting-slot phase specifically (not merely "a status file exists") -- an early
# preflight write can otherwise race HB_T0 into the wrong phase and false-fail the no-regression
# check below.
for _ in $(seq 1 50); do [ "$(phase_of "$TDIR/o-hbslot.md.status")" = waiting-slot ] && break; sleep 0.2; done
HB_T0="$(phase_of "$TDIR/o-hbslot.md.status")"
HB_TS0="$(jq -r .ts "$TDIR/o-hbslot.md.status" 2>/dev/null)"
sleep 4
HB_T1="$(phase_of "$TDIR/o-hbslot.md.status")"
HB_TS1="$(jq -r .ts "$TDIR/o-hbslot.md.status" 2>/dev/null)"
sleep 3
HB_T2="$(phase_of "$TDIR/o-hbslot.md.status")"
HB_TS2="$(jq -r .ts "$TDIR/o-hbslot.md.status" 2>/dev/null)"
wait "$HB_ENGPID" 2>/dev/null; HB_RC=$?
eval "exec ${HBSLOTFD}>&-"
check 'slot-wait heartbeat: phase never regresses off waiting-slot while blocked' \
  "$([ "$HB_T0" = waiting-slot ] && [ "$HB_T1" = waiting-slot ] && [ "$HB_T2" = waiting-slot ]; echo $?)" \
  "phases: $HB_T0 / $HB_T1 / $HB_T2"
check 'slot-wait heartbeat: ts advances tick over tick' \
  "$([ -n "$HB_TS0" ] && [ -n "$HB_TS1" ] && [ -n "$HB_TS2" ] && [ "$HB_TS1" '>' "$HB_TS0" ] && [ "$HB_TS2" '>' "$HB_TS1" ]; echo $?)" \
  "ts: $HB_TS0 / $HB_TS1 / $HB_TS2"
check 'slot-wait heartbeat: run eventually times out on the busy slot' \
  "$([ "$HB_RC" -eq 7 ]; echo $?)" "rc=$HB_RC $(tail -3 "$TDIR/hbslot.stderr")"

echo '# v0.35 U3: watchdog loop heartbeats while a launch is silently generating, then legitimately transitions to watchdog-killed'
mkdir -p "$TDIR/bin"
cat > "$TDIR/bin/oracle-slowsilent" <<'FAKE_SLOWSILENT'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
echo "[oracle] starting up"
sleep 60
printf '[P1] a.sh:1 - finding\n  Why: test\nP2: none\nP3: none\nVERDICT: SHIP - fixture.\n' > "$out"
FAKE_SLOWSILENT
chmod +x "$TDIR/bin/oracle-slowsilent"
HBWDHOME="$TDIR/home-hb-wd"; mkdir -p "$HBWDHOME"
PRO_GATE_HOME="$HBWDHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_STALL_SECS=15 PRO_GATE_NOTHINK_SECS=999 PRO_GATE_HEARTBEAT_SECS=1 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-slowsilent" NODE_OPTIONS= \
  bash "$ENGINE" --diff "$TDIR/small.diff" --repo "$TDIR" --out "$TDIR/o-hbwd.md" --timeout 5m \
  >"$TDIR/hbwd.stdout" 2>"$TDIR/hbwd.stderr" &
HBWD_ENGPID=$!
for _ in $(seq 1 100); do [ "$(phase_of "$TDIR/o-hbwd.md.status" 2>/dev/null)" = launching ] && break; sleep 0.3; done
HBWD_TS0="$(jq -r .ts "$TDIR/o-hbwd.md.status" 2>/dev/null)"
sleep 11
HBWD_T1="$(phase_of "$TDIR/o-hbwd.md.status")"
HBWD_TS1="$(jq -r .ts "$TDIR/o-hbwd.md.status" 2>/dev/null)"
sleep 10
HBWD_T2="$(phase_of "$TDIR/o-hbwd.md.status")"
HBWD_TS2="$(jq -r .ts "$TDIR/o-hbwd.md.status" 2>/dev/null)"
# Past STALL_SECS=15 from the first size sample: the run must transition to watchdog-killed —
# a legitimate phase change, not a heartbeat regression.
for _ in $(seq 1 40); do [ "$(phase_of "$TDIR/o-hbwd.md.status" 2>/dev/null)" = watchdog-killed ] && break; sleep 0.5; done
HBWD_T3="$(phase_of "$TDIR/o-hbwd.md.status")"
wait "$HBWD_ENGPID" 2>/dev/null; HBWD_RC=$?
check 'watchdog heartbeat: phase stays launching across two ticks while silently generating' \
  "$([ "$HBWD_T1" = launching ] && [ "$HBWD_T2" = launching ]; echo $?)" "phases: $HBWD_T1 / $HBWD_T2"
check 'watchdog heartbeat: ts advances tick over tick' \
  "$([ -n "$HBWD_TS0" ] && [ -n "$HBWD_TS1" ] && [ -n "$HBWD_TS2" ] && [ "$HBWD_TS1" '>' "$HBWD_TS0" ] && [ "$HBWD_TS2" '>' "$HBWD_TS1" ]; echo $?)" \
  "ts: $HBWD_TS0 / $HBWD_TS1 / $HBWD_TS2"
check 'watchdog heartbeat: eventually transitions to watchdog-killed (legitimate, not a regression)' \
  "$([ "$HBWD_T3" = watchdog-killed ]; echo $?)" "final phase: $HBWD_T3"
kill "$HBWD_ENGPID" 2>/dev/null; wait "$HBWD_ENGPID" 2>/dev/null || true

####################################################################################################
# v0.35 (#88) U4: the --wait verb (R4-R7, R6a, R10 consumer side; AE1, AE2, AE5, AE6, AE7, AE8, AE9;
# KTD5 legacy detection; terminal-exit ordering). Scenarios 1-9 and 10(R6a) hand-construct raw
# status-file / reservation / artifact / ledger fixtures matching pg_status's real emitted shape
# (validated byte-for-byte against the real implementation by U3, above) so each staleness/branch
# decision can be tested in isolation without a live browser. Scenario 11 and the duplicate-numbered
# end-to-end scenario drive the REAL engine over mock CDP. Scenario 12 (long-wait notification
# survival, hours-scale) is MANUAL per the plan and is skipped here — see the note near the bottom.
####################################################################################################
echo '# v0.35 U4: --wait verb'
while IFS='=' read -r name _; do
  case "$name" in PRO_GATE_*|ORACLE_*) unset "$name" ;; esac
done < <(env)
export PRO_GATE_MIN_AVAIL_MB=0 PRO_GATE_MAX_SWAP_PCT=101 PRO_GATE_TIMEOUT_BIN=/usr/bin/timeout
export PRO_GATE_EARLY_PROBE_SECS=0

WHOME="$TDIR/home-wait"; mkdir -p "$WHOME"

echo '# scenario 1 (AE5): a status file flipping to terminal mid-poll unblocks --wait within one poll interval'
W1OUT="$TDIR/w1.md"
NOWTS="$(date +%Y-%m-%dT%H:%M:%S%z)"
printf '{"phase":"waiting-slot","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"pg-run-w1-1700000100-1","model":"","model_warn":"","result":"","terminal":false,"next_action":{"cmd":"","terminal":false,"wait_class":null}}\n' \
  "$W1OUT" "$NOWTS" > "$W1OUT.status"
PRO_GATE_HOME="$WHOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$W1OUT" --timeout 10 >"$TDIR/w1.out" 2>"$TDIR/w1.err" &
W1PID=$!
sleep 0.4
printf '{"phase":"done","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"pg-run-w1-1700000100-1","model":"gpt-5","model_warn":"","result":"%s","terminal":true,"next_action":{"cmd":"","terminal":true,"wait_class":"verdict"}}\n' \
  "$W1OUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$W1OUT" > "$W1OUT.status"
W1_T0=$(date +%s)
wait "$W1PID"; W1RC=$?
W1_T1=$(date +%s)
check 'AE5: blocked --wait exits 0 once the fixture flips to terminal' "$([ "$W1RC" -eq 0 ]; echo $?)" "rc=$W1RC $(cat "$TDIR/w1.err")"
check 'AE5: exits within one poll interval of the flip' "$([ $(( W1_T1 - W1_T0 )) -le 3 ]; echo $?)" "elapsed=$(( W1_T1 - W1_T0 ))s"
check 'AE5: prints the final terminal JSON on stdout' "$(jq -e '.terminal == true and .phase == "done"' "$TDIR/w1.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/w1.out")"

echo '# scenario 2 (AE2): marker resolving straight to the completed store returns immediately'
W2HOME="$TDIR/home-wait2"; mkdir -p "$W2HOME/completed"
W2MARKER="pg-run-w2-1700000200-2"
printf 'run marker: %s\n[P1] a.sh:1 - x\n  Why: y\nP2: none\nP3: none\nVERDICT: SHIP - clean. (run marker: %s)\n' \
  "$W2MARKER" "$W2MARKER" > "$W2HOME/completed/$W2MARKER"
W2_T0=$(date +%s)
PRO_GATE_HOME="$W2HOME" "$ENGINE" --wait "$W2MARKER" --timeout 30 >"$TDIR/w2.out" 2>"$TDIR/w2.err"
W2RC=$?
W2_T1=$(date +%s)
check 'AE2: completed-store marker returns immediately with exit 0' "$([ "$W2RC" -eq 0 ]; echo $?)" "rc=$W2RC $(cat "$TDIR/w2.err")"
check 'AE2: returns fast, no poll-interval wait spent' "$([ $(( W2_T1 - W2_T0 )) -le 3 ]; echo $?)" "elapsed=$(( W2_T1 - W2_T0 ))s"
check 'AE2: synthesized JSON carries the marker and wait_class=verdict (already collected, nothing to harvest)' \
  "$(jq -e --arg m "$W2MARKER" '.terminal==true and .marker==$m and .next_action.wait_class=="verdict"' "$TDIR/w2.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/w2.out")"
# regression (gate finding P2, FIX 5): a completed-artifact next_action.cmd used to be a literal
# "--harvest '...' --out <file>" string — not executable as-is (the "<file>" placeholder is not
# a real path). result already names the artifact directly, so cmd must now be EMPTY (a caller
# acting on next_action.cmd verbatim has nothing to run, by design, and reads result instead).
check 'FIX5: completed-artifact next_action.cmd is directly executable — empty, never a "<...>" placeholder' \
  "$(jq -e '(.next_action.cmd == "") and ((.next_action.cmd | contains("<")) | not)' "$TDIR/w2.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/w2.out")"
check 'FIX5: result names the artifact path directly' \
  "$(jq -e '.result | length > 0' "$TDIR/w2.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/w2.out")"

echo '# scenario 3 (AE9): no status file yet is non-terminal, never a false verdict; proceeds once it appears'
W3HOME="$TDIR/home-wait3"; mkdir -p "$W3HOME/in-progress"
W3MARKER="pg-run-w3-1700000300-3"
W3OUT="$TDIR/w3.md"
printf 'w3\t%s\t%s\t0\t1\tgpt-5\n' "$W3OUT" "$(date +%s)" > "$W3HOME/in-progress/$W3MARKER"
PRO_GATE_HOME="$W3HOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$W3MARKER" --timeout 10 >"$TDIR/w3.out" 2>"$TDIR/w3.err" &
W3PID=$!
sleep 1.5
kill -0 "$W3PID" 2>/dev/null; W3_STILL_RUNNING=$?
printf '{"phase":"done","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"%s","model":"gpt-5","model_warn":"","result":"%s","terminal":true,"next_action":{"cmd":"","terminal":true,"wait_class":"verdict"}}\n' \
  "$W3OUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$W3MARKER" "$W3OUT" > "$W3OUT.status"
wait "$W3PID"; W3RC=$?
check 'AE9: still polling (no false exit) before the status file exists' "$([ "$W3_STILL_RUNNING" -eq 0 ]; echo $?)" "wait exited before the file appeared"
check 'AE9: proceeds normally once the file appears, exit 0' "$([ "$W3RC" -eq 0 ]; echo $?)" "rc=$W3RC $(cat "$TDIR/w3.err")"
check 'AE9: final JSON is the newly-appeared terminal status' "$(jq -e --arg m "$W3MARKER" '.terminal==true and .marker==$m' "$TDIR/w3.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/w3.out")"

echo '# scenario 4 (AE6/AE7): --timeout on a healthy non-terminal run exits 20, never a false lost-observability'
W4OUT="$TDIR/w4.md"
NOWTS="$(date +%Y-%m-%dT%H:%M:%S%z)"
printf '{"phase":"waiting-slot","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"pg-run-w4-1700000400-4","model":"","model_warn":"","result":"","terminal":false,"next_action":{"cmd":"","terminal":false,"wait_class":null}}\n' \
  "$W4OUT" "$NOWTS" > "$W4OUT.status"
# Deviation: the plan's AE6 example uses --timeout 60; scaled to 3s here (identical exit-20 code
# path, identical healthy/non-terminal classification) to keep the suite's wall time bounded — the
# mechanism under test is timeout-vs-staleness classification, not the literal duration.
W4_T0=$(date +%s)
PRO_GATE_HOME="$WHOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$W4OUT" --timeout 3 >"$TDIR/w4.out" 2>"$TDIR/w4.err"
W4RC=$?
W4_T1=$(date +%s)
check 'AE6: healthy non-terminal run times out through exit 20 (not 21)' "$([ "$W4RC" -eq 20 ]; echo $?)" "rc=$W4RC $(cat "$TDIR/w4.err")"
check 'AE6: times out at roughly the requested duration' "$([ $(( W4_T1 - W4_T0 )) -ge 3 ] && [ $(( W4_T1 - W4_T0 )) -le 6 ]; echo $?)" "elapsed=$(( W4_T1 - W4_T0 ))s"
check 'AE6: the run itself is unaffected (fixture untouched)' "$(grep -q '\"phase\":\"waiting-slot\"' "$W4OUT.status"; echo $?)" "$(cat "$W4OUT.status")"

echo '# scenario 4b (AE7): --timeout 0 is an immediate single classification probe'
W4B_T0=$(date +%s)
PRO_GATE_HOME="$WHOME" "$ENGINE" --wait "$W4OUT" --timeout 0 >"$TDIR/w4b.out" 2>"$TDIR/w4b.err"
W4BRC=$?
W4B_T1=$(date +%s)
check 'AE7: --timeout 0 exits through the timeout code immediately' "$([ "$W4BRC" -eq 20 ]; echo $?)" "rc=$W4BRC $(cat "$TDIR/w4b.err")"
check 'AE7: --timeout 0 returns in well under one poll interval' "$([ $(( W4B_T1 - W4B_T0 )) -le 2 ]; echo $?)" "elapsed=$(( W4B_T1 - W4B_T0 ))s"
check 'AE7: --timeout 0 still prints the current status JSON' "$(jq -e '.phase == "waiting-slot"' "$TDIR/w4b.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/w4b.out")"

echo '# scenario 5 (AE1): heartbeated-phase staleness — fresh ts keeps waiting, stale ts is lost observability'
W5OUT="$TDIR/w5.md"
FRESHTS="$(date +%Y-%m-%dT%H:%M:%S%z)"
printf '{"phase":"launching","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"pg-run-w5-1700000500-5","model":"","model_warn":"","result":"","terminal":false,"next_action":{"cmd":"","terminal":false,"wait_class":null}}\n' \
  "$W5OUT" "$FRESHTS" > "$W5OUT.status"
PRO_GATE_HOME="$WHOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$W5OUT" --timeout 2 >"$TDIR/w5.out" 2>"$TDIR/w5.err"
W5RC=$?
check 'AE1: fresh ts in a heartbeated phase keeps waiting (times out, not lost)' "$([ "$W5RC" -eq 20 ]; echo $?)" "rc=$W5RC $(cat "$TDIR/w5.err")"

STALETS="$(date -d '-10 minutes' +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -v-10M +%Y-%m-%dT%H:%M:%S%z)"
printf '{"phase":"launching","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"pg-run-w5b-1700000501-5","model":"","model_warn":"","result":"","terminal":false,"next_action":{"cmd":"","terminal":false,"wait_class":null}}\n' \
  "$W5OUT" "$STALETS" > "$W5OUT.status"
PRO_GATE_HOME="$WHOME" "$ENGINE" --wait "$W5OUT" --timeout 30 >"$TDIR/w5b.out" 2>"$TDIR/w5b.err"
W5BRC=$?
check 'AE1: stale ts (10min old, default 4x30s=120s bound) in launching exits 21 (lost observability)' "$([ "$W5BRC" -eq 21 ]; echo $?)" "rc=$W5BRC $(cat "$TDIR/w5b.err")"
check 'AE1: lost-observability still prints the last-known JSON' "$(jq -e '.phase == "launching"' "$TDIR/w5b.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/w5b.out")"

echo '# scenario 6 (AE8): salvaging (loopless phase) — within its 1.5x window bound keeps waiting, beyond it is lost'
W6OUT="$TDIR/w6.md"
TS_10MIN="$(date -d '-10 minutes' +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -v-10M +%Y-%m-%dT%H:%M:%S%z)"
printf '{"phase":"salvaging","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"pg-run-w6-1700000600-6","model":"","model_warn":"","result":"","terminal":false,"next_action":{"cmd":"","terminal":false,"wait_class":null}}\n' \
  "$W6OUT" "$TS_10MIN" > "$W6OUT.status"
PRO_GATE_HOME="$WHOME" "$ENGINE" --wait "$W6OUT" --timeout 2 >"$TDIR/w6.out" 2>"$TDIR/w6.err"
W6RC=$?
check 'AE8: 10-minute-old salvaging ts is within the (>=1800s floor * 1.5) salvage bound — keeps waiting' "$([ "$W6RC" -eq 20 ]; echo $?)" "rc=$W6RC $(cat "$TDIR/w6.err")"

TS_46MIN="$(date -d '-46 minutes' +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -v-46M +%Y-%m-%dT%H:%M:%S%z)"
printf '{"phase":"salvaging","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"pg-run-w6b-1700000601-6","model":"","model_warn":"","result":"","terminal":false,"next_action":{"cmd":"","terminal":false,"wait_class":null}}\n' \
  "$W6OUT" "$TS_46MIN" > "$W6OUT.status"
PRO_GATE_HOME="$WHOME" "$ENGINE" --wait "$W6OUT" --timeout 5 >"$TDIR/w6b.out" 2>"$TDIR/w6b.err"
W6BRC=$?
check 'AE8: beyond the salvage bound (46min > 2700s) exits 21 (lost observability)' "$([ "$W6BRC" -eq 21 ]; echo $?)" "rc=$W6BRC $(cat "$TDIR/w6b.err")"

echo '# scenario 7 (KTD5): legacy status JSON without a terminal field — widest bound, exactly one warning'
W7OUT="$TDIR/w7.md"
NOWTS="$(date +%Y-%m-%dT%H:%M:%S%z)"
printf '{"phase":"launching","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"pg-run-w7-1700000700-7","model":"","model_warn":"","result":""}\n' \
  "$W7OUT" "$NOWTS" > "$W7OUT.status"
PRO_GATE_HOME="$WHOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$W7OUT" --timeout 3 >"$TDIR/w7.out" 2>"$TDIR/w7.err"
W7RC=$?
check 'KTD5: legacy fixture (no terminal field) keeps waiting within the widest bound, no false lost-observability' "$([ "$W7RC" -eq 20 ]; echo $?)" "rc=$W7RC $(cat "$TDIR/w7.err")"
check 'KTD5: legacy fixture triggers exactly one stderr warning across the whole wait' "$([ "$(grep -c "has no 'terminal' field" "$TDIR/w7.err")" -eq 1 ]; echo $?)" "$(cat "$TDIR/w7.err")"

echo '# scenario 8: an unknown marker (no state anywhere) fails fast with exit 2'
W8_T0=$(date +%s)
PRO_GATE_HOME="$WHOME" "$ENGINE" --wait pg-run-nonexistent-1700000800-8 --timeout 300 >"$TDIR/w8.out" 2>"$TDIR/w8.err"
W8RC=$?
W8_T1=$(date +%s)
check 'unknown marker exits 2' "$([ "$W8RC" -eq 2 ]; echo $?)" "rc=$W8RC $(cat "$TDIR/w8.err")"
check 'unknown marker fails fast, never blocks toward --timeout' "$([ $(( W8_T1 - W8_T0 )) -le 3 ]; echo $?)" "elapsed=$(( W8_T1 - W8_T0 ))s"
check 'unknown marker message names the marker' "$(grep -qF 'pg-run-nonexistent-1700000800-8' "$TDIR/w8.err"; echo $?)" "$(cat "$TDIR/w8.err")"

echo '# scenario 9: --wait combined with another mode flag is a usage error (exit 2)'
PRO_GATE_HOME="$WHOME" "$ENGINE" --wait pg-run-w9-1700000900-9 --pr 5 >"$TDIR/w9.out" 2>"$TDIR/w9.err"
W9RC=$?
check 'usage: --wait + --pr exits 2' "$([ "$W9RC" -eq 2 ]; echo $?)" "rc=$W9RC $(cat "$TDIR/w9.err")"
check 'usage error names the exclusivity rule' "$(grep -qF 'exclusive with' "$TDIR/w9.err"; echo $?)" "$(cat "$TDIR/w9.err")"

echo '# scenario 10 (R6a): a status file at the resolved out-path carrying a DIFFERENT marker is never trusted'
W10HOME="$TDIR/home-wait10"; mkdir -p "$W10HOME/in-progress"
W10MARKER="pg-run-w10-1700001000-10"
W10OUT="$TDIR/w10.md"
printf 'w10\t%s\t%s\t0\t1\tgpt-5\n' "$W10OUT" "$(date +%s)" > "$W10HOME/in-progress/$W10MARKER"
# A stale/reused --out carries ANOTHER run's terminal status at the exact path this marker's own
# reservation resolves to.
printf '{"phase":"done","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"pg-run-DIFFERENT-9999999999-1","model":"gpt-5","model_warn":"","result":"%s","terminal":true,"next_action":{"cmd":"","terminal":true,"wait_class":"verdict"}}\n' \
  "$W10OUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$W10OUT" > "$W10OUT.status"
PRO_GATE_HOME="$W10HOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$W10MARKER" --timeout 3 >"$TDIR/w10.out" 2>"$TDIR/w10.err"
W10RC=$?
check 'R6a: a marker-mismatched status file at the resolved out-path is never trusted (no false exit 0)' "$([ "$W10RC" -ne 0 ]; echo $?)" "rc=$W10RC $(cat "$TDIR/w10.out")"
check 'R6a: falls back to the state join and times out healthy rather than reporting the wrong verdict' "$([ "$W10RC" -eq 20 ]; echo $?)" "rc=$W10RC $(cat "$TDIR/w10.err")"

echo '# scenario 11, part A (terminal-exit ordering): --wait settles the active-run index before exiting'
# pg_finish keeps its original, v0.32-gated order: the organizer case dispatch (which can
# discover a same-call throttle) runs BEFORE ledger append and active-index clear. That
# means pg_status's terminal:true write can be observed by a poller well before pg_finish's
# bookkeeping (organizer dispatch, ledger append, active-index clear) actually completes.
# The fix is local to --wait (wait_settle_terminal): it re-checks the active-run index via
# pg_state_resolve before printing+exiting. This exercises that behavior directly: a
# terminal status file plus a LIVE active-index record for the same round key must block
# --wait until the record clears (never a false-early exit), and once it clears, --wait
# exits 0 promptly with the terminal JSON.
W11AHOME="$TDIR/home-wait11a"; mkdir -p "$W11AHOME/active"
W11AMARKER="pg-run-w11settle-1700001150-11"
W11AOUT="$TDIR/o-w11a.md"
sleep 30 & W11A_LIVEPID=$!
# Token-less record (legacy shape, 4 tab-separated fields): pg_state_resolve treats an alive
# pid with no token as live, same as a genuine in-flight run (see pg_state_resolve's a_token
# handling). Keyed by "w11settle" — the round key embedded in W11AMARKER (strip "pg-run-"
# and the trailing "-epoch-pid").
printf '%s\t%s\t%s\t%s\n' "$W11AMARKER" "$W11AOUT" "$W11A_LIVEPID" "$(date +%s)" \
  > "$W11AHOME/active/w11settle"
printf '{"phase":"done","attempt":1,"detail":"","pr":"","out":"%s","ts":"%s","marker":"%s","model":"gpt-5","model_warn":"","result":"%s","terminal":true,"next_action":{"cmd":"","terminal":true,"wait_class":"verdict"}}\n' \
  "$W11AOUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$W11AMARKER" "$W11AOUT" > "$W11AOUT.status"
PRO_GATE_HOME="$W11AHOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$W11AOUT" --timeout 30 \
  >"$TDIR/w11a.out" 2>"$TDIR/w11a.err" &
W11A_WAITPID=$!
sleep 2
kill -0 "$W11A_WAITPID" 2>/dev/null
check 'part A: --wait does not exit while the active index still reports the change live' \
  "$?" "wait pid=$W11A_WAITPID (expected still running)"
kill "$W11A_LIVEPID" 2>/dev/null; wait "$W11A_LIVEPID" 2>/dev/null
rm -f "$W11AHOME/active/w11settle"
wait "$W11A_WAITPID"; W11ARC=$?
check 'part A: --wait exits 0 once the active index clears' "$([ "$W11ARC" -eq 0 ]; echo $?)" "rc=$W11ARC $(cat "$TDIR/w11a.err")"
check 'part A: --wait prints the terminal JSON after settling' \
  "$(jq -e --arg m "$W11AMARKER" '.terminal==true and .marker==$m' "$TDIR/w11a.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/w11a.out")"
check 'part A: the active index no longer reports the change live once --wait has exited' \
  "$([ ! -f "$W11AHOME/active/w11settle" ]; echo $?)" "$(cat "$W11AHOME/active/w11settle" 2>/dev/null)"

echo '# scenario 11, part B (terminal-exit ordering): pg_active_clear genuinely fires on a real harvest completion'
mkdir -p "$TDIR/home/active"
W11MARKER="pg-run-w11-1700001100-11"
W11OUT="$TDIR/o-w11.md"
( exit 0 ) & W11_DEADPID=$!; wait "$W11_DEADPID" 2>/dev/null
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$W11MARKER" "$W11OUT" "$W11_DEADPID" "$(date +%s)" remote-chrome tok \
  > "$TDIR/home/active/w11"
{ printf 'run marker: %s\n' "$W11MARKER"
  printf '[P1] src/z.sh:1 - bug\n  Why: y\nP2: none\nP3: none\nVERDICT: SHIP - clean. (run marker: %s)\n' "$W11MARKER" "$W11MARKER"
} > "$TDIR/tab-w11.txt"
start_mock "$TDIR/tab-w11.txt"
run_engine --harvest "$W11MARKER" --out "$W11OUT" --timeout 30s
check 'part B: harvest completing over a dead-pid-owned active record still exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'part B: pg_active_clear removes the dead-owner active record on harvest completion' "$([ ! -f "$TDIR/home/active/w11" ]; echo $?)" "$(cat "$TDIR/home/active/w11" 2>/dev/null)"

echo '# scenario 11, part C (terminal-exit ordering): the settle cap cannot hang forever'
# If the active-run index never clears (a stuck/orphaned record), wait_settle_terminal must
# still print the verdict and exit 0 once PRO_GATE_WAIT_SETTLE_CAP elapses, with a one-line
# stderr note — a settle timeout is a bookkeeping delay, never a reason to fail the verdict.
W11CHOME="$TDIR/home-wait11c"; mkdir -p "$W11CHOME/active"
W11CMARKER="pg-run-w11cap-1700001160-11"
W11COUT="$TDIR/o-w11c.md"
sleep 30 & W11C_LIVEPID=$!
printf '%s\t%s\t%s\t%s\n' "$W11CMARKER" "$W11COUT" "$W11C_LIVEPID" "$(date +%s)" \
  > "$W11CHOME/active/w11cap"
printf '{"phase":"done","attempt":1,"detail":"","pr":"","out":"%s","ts":"%s","marker":"%s","model":"gpt-5","model_warn":"","result":"%s","terminal":true,"next_action":{"cmd":"","terminal":true,"wait_class":"verdict"}}\n' \
  "$W11COUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$W11CMARKER" "$W11COUT" > "$W11COUT.status"
W11C_T0=$(date +%s)
PRO_GATE_HOME="$W11CHOME" PRO_GATE_WAIT_POLL_SECS=1 PRO_GATE_WAIT_SETTLE_CAP=2 \
  "$ENGINE" --wait "$W11COUT" --timeout 30 >"$TDIR/w11c.out" 2>"$TDIR/w11c.err"
W11CRC=$?
W11C_T1=$(date +%s)
kill "$W11C_LIVEPID" 2>/dev/null; wait "$W11C_LIVEPID" 2>/dev/null
check 'part C: --wait exits 0 once the settle cap elapses, even with the active record still live' \
  "$([ "$W11CRC" -eq 0 ]; echo $?)" "rc=$W11CRC $(cat "$TDIR/w11c.err")"
check 'part C: settling never hangs past the cap (bounded elapsed time)' \
  "$([ $(( W11C_T1 - W11C_T0 )) -le 8 ]; echo $?)" "elapsed=$(( W11C_T1 - W11C_T0 ))s"
check 'part C: cap expiry emits the documented one-line stderr note' \
  "$(grep -q 'had not settled within 2s' "$TDIR/w11c.err"; echo $?)" "$(cat "$TDIR/w11c.err")"
check 'part C: --wait still prints the terminal JSON on cap expiry' \
  "$(jq -e --arg m "$W11CMARKER" '.terminal==true and .marker==$m' "$TDIR/w11c.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/w11c.out")"

echo '# scenario 10 (duplicate plan numbering), end-to-end: --wait against a REAL engine run (mock CDP), from launch through verdict'
E2E_MARKER="pg-run-w12-1700001200-12"
E2E_OUT="$TDIR/o-w12.md"
{ printf 'run marker: %s\n' "$E2E_MARKER"
  printf '[P1] src/y.sh:5 - real bug\n  Why: demonstrated\nP2: none\nP3: none\nVERDICT: SHIP - clean enough. (run marker: %s)\n' "$E2E_MARKER" "$E2E_MARKER"
} > "$TDIR/tab-w12.txt"
start_mock "$TDIR/tab-w12.txt"
PRO_GATE_HOME="$TDIR/home" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$E2E_OUT" --timeout 30 >"$TDIR/w12-wait.out" 2>"$TDIR/w12-wait.err" &
E2E_WAITPID=$!
sleep 1.2
run_engine --harvest "$E2E_MARKER" --out "$E2E_OUT" --timeout 30s
check 'end-to-end: the real engine harvest itself still completes normally' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
wait "$E2E_WAITPID"; E2E_WAITRC=$?
check 'end-to-end: a concurrently-blocked --wait exits 0 once the real run reaches a verdict' "$([ "$E2E_WAITRC" -eq 0 ]; echo $?)" "rc=$E2E_WAITRC $(cat "$TDIR/w12-wait.err")"
check "end-to-end: --wait reports exactly the engine's own final status JSON" "$(cmp -s "$TDIR/w12-wait.out" "$E2E_OUT.status"; echo $?)" "wait=$(cat "$TDIR/w12-wait.out" 2>/dev/null) status=$(cat "$E2E_OUT.status" 2>/dev/null)"

echo '# scenario 12 (long-wait notification survival) is MANUAL per the plan — hours-scale, requires an actual'
echo '# terminal/session restart mid-wait to exercise. Not automatable in this suite; skipped by design.'

echo '# supplementary: wait_resolve_marker reservation-branch coverage not exercised by scenarios 1-11'
echo '# res_complete -> collect'
RC_HOME="$TDIR/home-rescomplete"; mkdir -p "$RC_HOME/in-progress"
RC_MARKER="pg-run-rc-1700002000-20"
RC_OUT="$TDIR/rc.md"
printf '5\t%s\t%s\t0\t1\tgpt-5\t\tcomplete\n' "$RC_OUT" "$(date +%s)" > "$RC_HOME/in-progress/$RC_MARKER"
PRO_GATE_HOME="$RC_HOME" "$ENGINE" --wait "$RC_MARKER" --timeout 5 >"$TDIR/rc.out" 2>"$TDIR/rc.err"
RCRC=$?
check 'res_complete: a completed-but-uncollected reservation returns immediately, exit 0' "$([ "$RCRC" -eq 0 ]; echo $?)" "rc=$RCRC $(cat "$TDIR/rc.err")"
check 'res_complete: synthesized JSON carries the collect harvest command' "$(jq -e '.next_action.wait_class == "collect"' "$TDIR/rc.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/rc.out")"

echo '# res_crossbound -> recover'
RX_HOME="$TDIR/home-rescross"; mkdir -p "$RX_HOME/in-progress" "$RX_HOME/crossbound"
RX_MARKER="pg-run-rx-1700002100-21"
RX_OUT="$TDIR/rx.md"
printf '5\t%s\t%s\t0\t1\tgpt-5\n' "$RX_OUT" "$(date +%s)" > "$RX_HOME/in-progress/$RX_MARKER"
printf 'foreign completed answer detected below our prompt\n' > "$RX_HOME/crossbound/$RX_MARKER"
PRO_GATE_HOME="$RX_HOME" "$ENGINE" --wait "$RX_MARKER" --timeout 5 >"$TDIR/rx.out" 2>"$TDIR/rx.err"
RXRC=$?
check 'res_crossbound: a cross-bound reservation returns immediately, exit 0' "$([ "$RXRC" -eq 0 ]; echo $?)" "rc=$RXRC $(cat "$TDIR/rx.err")"
check 'res_crossbound: wait_class is recover, never collect' "$(jq -e '.next_action.wait_class == "recover"' "$TDIR/rx.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/rx.out")"

echo '# res_ambiguous -> retryable, keeps polling rather than an instant verdict'
RA_HOME="$TDIR/home-resambig"; mkdir -p "$RA_HOME/in-progress"
RA_MARKER="pg-run-ra-1700002200-22"
RA_OUT="$TDIR/ra.md"
printf '5\t%s\t%s\t0\t1\tgpt-5\n' "$RA_OUT" "$(date +%s)" > "$RA_HOME/in-progress/$RA_MARKER"
: > "$RA_OUT.unbound.1"
PRO_GATE_HOME="$RA_HOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$RA_MARKER" --timeout 2 >"$TDIR/ra.out" 2>"$TDIR/ra.err"
RARC=$?
check 'res_ambiguous: an unbound-but-retryable capture keeps polling rather than an instant verdict' "$([ "$RARC" -eq 20 ]; echo $?)" "rc=$RARC $(cat "$TDIR/ra.err")"

echo '# artifact_pending -> recover (manual)'
AP_HOME="$TDIR/home-artpending"; mkdir -p "$AP_HOME/pending"
AP_MARKER="pg-run-ap-1700002300-23"
printf 'run marker: %s\n[P1] a.sh:1 - x\n  Why: y\nP2: none\nP3: none\nVERDICT: SHIP - clean. (run marker: %s)\n' \
  "$AP_MARKER" "$AP_MARKER" > "$AP_HOME/pending/$AP_MARKER"
PRO_GATE_HOME="$AP_HOME" "$ENGINE" --wait "$AP_MARKER" --timeout 5 >"$TDIR/ap.out" 2>"$TDIR/ap.err"
APRC=$?
check 'artifact_pending: a captured-but-uninstalled review returns immediately, exit 0' "$([ "$APRC" -eq 0 ]; echo $?)" "rc=$APRC $(cat "$TDIR/ap.err")"
check 'artifact_pending: wait_class is recover (manual), not collect' "$(jq -e '.next_action.wait_class == "recover"' "$TDIR/ap.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/ap.out")"

echo '# ledger_hit outcome sub-branches -> outcome-mapped exits'
LH_HOME="$TDIR/home-ledgerhit"; mkdir -p "$LH_HOME"
lh_case() { # $1 marker $2 outcome $3 expected_rc $4 expected_wait_class(or empty) $5 label
  local m="$1" oc="$2" exp_rc="$3" exp_wc="$4" label="$5" out="$TDIR/lh-$1.md"
  jq -nc --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg pr "9" --arg outcome "$oc" \
    --arg out "$out" --arg marker "$m" \
    '{ts:$ts,pr:$pr,exit:0,outcome:$outcome,secs:1,pre_slot_secs:0,post_slot_secs:1,kind:"diff",attempts:1,conc:1,ceiling:1,live:0,salvaged:0,out:$out,model:"gpt-5",marker:$marker,round_key:"lh",sha256:""}' \
    >> "$LH_HOME/ledger.jsonl"
  PRO_GATE_HOME="$LH_HOME" "$ENGINE" --wait "$m" --timeout 5 >"$TDIR/lh-$m.out" 2>"$TDIR/lh-$m.err"
  LHRC=$?
  check "ledger_hit ($label): exit code" "$([ "$LHRC" -eq "$exp_rc" ]; echo $?)" "rc=$LHRC $(cat "$TDIR/lh-$m.err")"
  if [ -n "$exp_wc" ]; then
    check "ledger_hit ($label): wait_class" "$(jq -e --arg wc "$exp_wc" '.next_action.wait_class == $wc' "$TDIR/lh-$m.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/lh-$m.out")"
  fi
}
lh_case "pg-run-lh1-1700002400-1" clean 0 verdict "clean"
lh_case "pg-run-lh2-1700002400-2" in-progress 0 collect "in-progress"
lh_case "pg-run-lh3-1700002400-3" deferred 0 recover "deferred"
lh_case "pg-run-lh4-1700002400-4" round-capped 0 recover "round-capped"
lh_case "pg-run-lh5-1700002400-5" bad-repo 0 verdict "other/failed"

####################################################################################################
# Terminal ChatGPT-Pro gate findings (2026-08-17/18), regression coverage. Six confirmed P1/P2
# bugs in the --wait implementation above; each check here is written to FAIL against the
# pre-fix code (verified by running this same file against a read-only git-show extraction of
# HEAD's bin/oracle-review.sh, i.e. the state before this session's fixes — see the session
# REPORT for the exact pass/fail counts of that run) and PASS against the fixed working tree.
####################################################################################################
echo '# gate P1 regression 1 (wait_resolve_marker / FIX 1): a marker with ONLY an active-index record'
echo '# (no reservation, no ledger row, no completed artifact yet) must keep polling, never a false exit 2'
RT1_HOME="$TDIR/home-rt1"; mkdir -p "$RT1_HOME/active"
RT1_KEY="rt1fix"
RT1_MARKER="pg-run-${RT1_KEY}-1700003000-31"
RT1_OUT="$TDIR/rt1.md"
sleep 30 & RT1_LIVEPID=$!
printf '%s\t%s\t%s\t%s\n' "$RT1_MARKER" "$RT1_OUT" "$RT1_LIVEPID" "$(date +%s)" > "$RT1_HOME/active/$RT1_KEY"
PRO_GATE_HOME="$RT1_HOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$RT1_MARKER" --timeout 10 \
  >"$TDIR/rt1.out" 2>"$TDIR/rt1.err" &
RT1_WAITPID=$!
sleep 1.5
kill -0 "$RT1_WAITPID" 2>/dev/null
check 'FIX1: active-index-only marker (no reservation/ledger/artifact anywhere) keeps polling, never a false exit 2' \
  "$?" "wait pid=$RT1_WAITPID (expected still running; pre-fix this exits 2 almost instantly)"
# Let the run actually reach a verdict: write its terminal status at the active record's own out
# path, then clear the active record the way pg_finish would.
printf '{"phase":"done","attempt":1,"detail":"","pr":"","out":"%s","ts":"%s","marker":"%s","model":"gpt-5","model_warn":"","result":"%s","terminal":true,"next_action":{"cmd":"","terminal":true,"wait_class":"verdict"}}\n' \
  "$RT1_OUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$RT1_MARKER" "$RT1_OUT" > "$RT1_OUT.status"
kill "$RT1_LIVEPID" 2>/dev/null; wait "$RT1_LIVEPID" 2>/dev/null
rm -f "$RT1_HOME/active/$RT1_KEY"
wait "$RT1_WAITPID"; RT1RC=$?
check 'FIX1: once the active-only run reaches a status file and the record clears, --wait exits 0 with the verdict' \
  "$([ "$RT1RC" -eq 0 ]; echo $?)" "rc=$RT1RC $(cat "$TDIR/rt1.err")"
check 'FIX1: prints the correct marker' \
  "$(jq -e --arg m "$RT1_MARKER" '.marker==$m' "$TDIR/rt1.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/rt1.out")"
echo '# (exit 2 remains correct when NOTHING exists anywhere — already covered by the "unknown marker exits 2" scenario above)'

echo '# gate P1 regression 2 (pg_state_resolve dynamic scoping / FIX 2): a settle-loop target key must'
echo '# not be clobbered when MULTIPLE active-run keys exist and a non-target key sorts last'
RT2_HOME="$TDIR/home-rt2"; mkdir -p "$RT2_HOME/active"
RT2_MARKER="pg-run-aaaclobber-1700003200-33"
RT2_OUT="$TDIR/rt2.md"
sleep 30 & RT2_LIVEPID=$!
# Target key "aaaclobber" sorts FIRST; a decoy key "zzzclobber" sorts LAST in the active/* glob
# (and therefore last in pg_state_resolve's own $ST_KEYS iteration). Pre-fix, pg_state_resolve's
# unlocalized `k` loop variable clobbers wait_settle_terminal's caller-side `k` (the parsed
# target round key, via bash dynamic scoping) to whatever key that loop visited LAST — even
# though only the TARGET key's own active record is actually live, corrupting the comparison.
printf '%s\t%s\t%s\t%s\n' "$RT2_MARKER" "$RT2_OUT" "$RT2_LIVEPID" "$(date +%s)" \
  > "$RT2_HOME/active/aaaclobber"
printf 'pg-run-zzzclobber-1699999000-9\t%s\t1\t%s\n' "$TDIR/rt2-decoy.md" "$(date +%s)" \
  > "$RT2_HOME/active/zzzclobber"
printf '{"phase":"done","attempt":1,"detail":"","pr":"","out":"%s","ts":"%s","marker":"%s","model":"gpt-5","model_warn":"","result":"%s","terminal":true,"next_action":{"cmd":"","terminal":true,"wait_class":"verdict"}}\n' \
  "$RT2_OUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$RT2_MARKER" "$RT2_OUT" > "$RT2_OUT.status"
PRO_GATE_HOME="$RT2_HOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$RT2_OUT" --timeout 30 \
  >"$TDIR/rt2.out" 2>"$TDIR/rt2.err" &
RT2_WAITPID=$!
sleep 2
kill -0 "$RT2_WAITPID" 2>/dev/null
check 'FIX2: settle keeps waiting on the TARGET key with a differently-keyed decoy active record present (no dynamic-scoping clobber)' \
  "$?" "wait pid=$RT2_WAITPID (expected still running; a clobbered target key exits immediately instead of waiting)"
kill "$RT2_LIVEPID" 2>/dev/null; wait "$RT2_LIVEPID" 2>/dev/null
rm -f "$RT2_HOME/active/aaaclobber"
wait "$RT2_WAITPID"; RT2RC=$?
check 'FIX2: --wait exits 0 once the target active record actually clears' "$([ "$RT2RC" -eq 0 ]; echo $?)" "rc=$RT2RC $(cat "$TDIR/rt2.err")"
check 'FIX2: prints the terminal JSON for the correct target marker' \
  "$(jq -e --arg m "$RT2_MARKER" '.terminal==true and .marker==$m' "$TDIR/rt2.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/rt2.out")"

echo '# gate P1 regression 3 (out-path snapshot+bind / FIX 3a/3b): a bound --out path must not silently'
echo '# hand back a REPLACEMENT round'"'"'s verdict as if it were the bound round'"'"'s own'
RT3_HOME="$TDIR/home-rt3"; mkdir -p "$RT3_HOME"
RT3_OUT="$TDIR/rt3.md"
RT3_ORIG_MARKER="pg-run-rt3orig-1700003400-34"
RT3_NEW_MARKER="pg-run-rt3new-1700003401-35"
# Round ORIG is still generating (non-terminal) when --wait first polls and binds to it.
printf '{"phase":"waiting-slot","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"%s","model":"","model_warn":"","result":"","terminal":false,"next_action":{"cmd":"","terminal":false,"wait_class":null}}\n' \
  "$RT3_OUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$RT3_ORIG_MARKER" > "$RT3_OUT.status"
PRO_GATE_HOME="$RT3_HOME" PRO_GATE_WAIT_POLL_SECS=1 "$ENGINE" --wait "$RT3_OUT" --timeout 4 \
  >"$TDIR/rt3.out" 2>"$TDIR/rt3.err" &
RT3_WAITPID=$!
sleep 1.3
# Round ORIG never reaches terminal — a totally different round (rt3new) replaces it at the
# SAME shared --out path, landing its OWN terminal verdict there instead.
printf '{"phase":"done","attempt":1,"detail":"","pr":"5","out":"%s","ts":"%s","marker":"%s","model":"gpt-5","model_warn":"","result":"%s","terminal":true,"next_action":{"cmd":"","terminal":true,"wait_class":"verdict"}}\n' \
  "$RT3_OUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$RT3_NEW_MARKER" "$RT3_OUT" > "$RT3_OUT.status"
wait "$RT3_WAITPID"; RT3RC=$?
check 'FIX3: a bound out-path wait never silently reports a REPLACEMENT round'"'"'s verdict (no false exit 0)' \
  "$([ "$RT3RC" -ne 0 ]; echo $?)" "rc=$RT3RC $(cat "$TDIR/rt3.out")"
check 'FIX3: falls through to the timeout instead of fabricating a verdict' "$([ "$RT3RC" -eq 20 ]; echo $?)" "rc=$RT3RC $(cat "$TDIR/rt3.err")"
check 'FIX3: --timeout print still shows the last-known bytes, not silence, after the bind mismatch' \
  "$([ -s "$TDIR/rt3.out" ]; echo $?)" "stdout was empty at timeout"

echo '# gate P1 regression 4 (wait_json_valid / FIX 4): corrupt/truncated/non-JSON status must exit 21'
echo '# (lost observability), never mistaken for a healthy pre-v0.35 (KTD5) legacy run'
RT4_OUT="$TDIR/rt4.md"
printf '{"phase":"launching","ts":"%s","marker":"pg-run-rt4-1700003500-36"' "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > "$RT4_OUT.status"  # truncated mid-write: no closing brace, no "terminal" field
PRO_GATE_HOME="$WHOME" "$ENGINE" --wait "$RT4_OUT" --timeout 2 >"$TDIR/rt4.out" 2>"$TDIR/rt4.err"
RT4RC=$?
check 'FIX4 (jq path): truncated/corrupt status exits 21, not 20 (never a false healthy-legacy classification)' \
  "$([ "$RT4RC" -eq 21 ]; echo $?)" "rc=$RT4RC $(cat "$TDIR/rt4.err")"
check 'FIX4 (jq path): still prints whatever bytes are on disk' "$([ -s "$TDIR/rt4.out" ]; echo $?)" "stdout was empty"

build_nojq_path
RT4B_OUT="$TDIR/rt4b.md"
printf '{"phase":"launching","ts":"%s","marker":"pg-run-rt4b-1700003501-36"' "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > "$RT4B_OUT.status"
PATH="$NOJQ_DIR" PRO_GATE_HOME="$WHOME" "$ENGINE" --wait "$RT4B_OUT" --timeout 2 >"$TDIR/rt4b.out" 2>"$TDIR/rt4b.err"
RT4BRC=$?
check 'FIX4 (no-jq path): truncated/corrupt status exits 21, not 20 (never a false healthy-legacy classification)' \
  "$([ "$RT4BRC" -eq 21 ]; echo $?)" "rc=$RT4BRC $(cat "$TDIR/rt4b.err")"

echo '# gate P2 regression 5 (completed-artifact handoff / FIX 5): covered above as part of scenario 2 (AE2)'
echo '# — dual-purposed there since it is the exact same code path (wait_resolve_marker artifact_completed).'

echo '# gate P2 regression 6 (settle cap vs. overall deadline / FIX 6): --timeout 0 must not block for the'
echo '# settle cap even with a stuck (never-clearing) active-index record for the same key'
RT6_HOME="$TDIR/home-rt6"; mkdir -p "$RT6_HOME/active"
RT6_MARKER="pg-run-rt6cap-1700003300-33"
RT6_OUT="$TDIR/rt6.md"
sleep 30 & RT6_LIVEPID=$!
printf '%s\t%s\t%s\t%s\n' "$RT6_MARKER" "$RT6_OUT" "$RT6_LIVEPID" "$(date +%s)" > "$RT6_HOME/active/rt6cap"
printf '{"phase":"done","attempt":1,"detail":"","pr":"","out":"%s","ts":"%s","marker":"%s","model":"gpt-5","model_warn":"","result":"%s","terminal":true,"next_action":{"cmd":"","terminal":true,"wait_class":"verdict"}}\n' \
  "$RT6_OUT" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$RT6_MARKER" "$RT6_OUT" > "$RT6_OUT.status"
RT6_T0=$(date +%s)
PRO_GATE_HOME="$RT6_HOME" PRO_GATE_WAIT_POLL_SECS=1 PRO_GATE_WAIT_SETTLE_CAP=5 \
  "$ENGINE" --wait "$RT6_OUT" --timeout 0 >"$TDIR/rt6.out" 2>"$TDIR/rt6.err"
RT6RC=$?
RT6_T1=$(date +%s)
kill "$RT6_LIVEPID" 2>/dev/null; wait "$RT6_LIVEPID" 2>/dev/null
check 'FIX6: --timeout 0 exits 0 with the terminal verdict even though the active index is stuck live' \
  "$([ "$RT6RC" -eq 0 ]; echo $?)" "rc=$RT6RC $(cat "$TDIR/rt6.err")"
check 'FIX6: --timeout 0 returns near-instantly, never blocking for the (5s) settle cap' \
  "$([ $(( RT6_T1 - RT6_T0 )) -le 2 ]; echo $?)" "elapsed=$(( RT6_T1 - RT6_T0 ))s (settle cap=5s)"
check 'FIX6: still prints the terminal JSON' \
  "$(jq -e --arg m "$RT6_MARKER" '.terminal==true and .marker==$m' "$TDIR/rt6.out" >/dev/null 2>&1; echo $?)" "$(cat "$TDIR/rt6.out")"

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILURES"; exit 1; }
