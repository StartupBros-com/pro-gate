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
# Most legacy cases intentionally retain connector-capable behavior. Dedicated policy cases below
# remove or override this export to exercise the production-safe bundle-only default.
export PRO_GATE_INPUT_POLICY=connector-enabled
export PRO_GATE_MIN_AVAIL_MB=0 PRO_GATE_MAX_SWAP_PCT=101 PRO_GATE_TIMEOUT_BIN=/usr/bin/timeout
# v0.28: the early URL-capture probe is off by default in tests (its sleep would slow every
# fresh-run case); the dedicated early-capture test re-enables it explicitly.
export PRO_GATE_EARLY_PROBE_SECS=0

cat > "$TDIR/bin/oracle-preflight" <<'FAKE_PREFLIGHT'
#!/usr/bin/env bash
if [ -n "${PG_TEST_ORACLE_SENTINEL:-}" ]; then printf '%s\n' "$*" >> "$PG_TEST_ORACLE_SENTINEL"; fi
if [ "${PG_TEST_ORACLE_COMPLETE:-0}" = 1 ]; then
  prompt=""; output=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) prompt="$2"; shift 2 ;;
      --write-output) output="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "${PG_TEST_PROMPT_CAPTURE:-}" ]; then printf '%s' "$prompt" > "$PG_TEST_PROMPT_CAPTURE"; fi
  [[ "$prompt" =~ \(run\ marker:\ ([A-Za-z0-9.-]+) ]] || exit 99
  printf '[P1] policy/input.sh:1 - fixture finding\nP2: none\nVERDICT: SHIP - fixture complete. (run marker: %s)\n' "${BASH_REMATCH[1]}" > "$output"
  exit 0
fi
printf 'unexpected generic oracle invocation\n' >&2
exit 99
FAKE_PREFLIGHT
chmod +x "$TDIR/bin/oracle-preflight"

start_mock() { # $1 = source text; optional $2 = organizer/browser state; optional $3 = scratch text; optional $4 = scratch canonical URL
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
  node "$HERE/mock-cdp.mjs" "$1" "${2:-}" "${3:-}" "${4:-}" > "$TDIR/port" 2>"$TDIR/mock.log" &
  MOCK_PID=$!
  # A cold CI runner has taken >5s to get node to its first write here, and an empty PORT is
  # SILENT: every following test then points the engine at the default 9222, gets "CDP not
  # reachable", and reports a wall of unrelated failures until the next start_mock happens to
  # succeed (observed: 32 failures from one slow start, run 32450985579). Wait long enough for a
  # loaded runner, then abort loudly with the mock's own stderr rather than testing nothing.
  for _ in $(seq 1 300); do [ -s "$TDIR/port" ] && break; sleep 0.1; done
  PORT="$(tr -d '[:space:]' < "$TDIR/port")"; : > "$TDIR/port"
  if [ -z "$PORT" ]; then
    echo "FATAL - mock CDP server never reported a port within 30s; aborting rather than testing against :9222" >&2
    echo "--- mock stderr ---" >&2
    cat "$TDIR/mock.log" >&2 2>/dev/null
    exit 1
  fi
}

MARKER="pg-run-77-1700000000-11"
run_engine() { # args... ; captures RC
  PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
    PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
    bash "$ENGINE" "$@" >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
}

run_engine_policy() { # policy|__unset__ args... ; captures RC
  local policy="$1"; shift
  if [ "$policy" = __unset__ ]; then
    env -u PRO_GATE_INPUT_POLICY PRO_GATE_HOME="$TDIR/policy-home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
      PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
      bash "$ENGINE" "$@" >"$TDIR/stdout" 2>"$TDIR/stderr"
  else
    PRO_GATE_INPUT_POLICY="$policy" PRO_GATE_HOME="$TDIR/policy-home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
      PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
      bash "$ENGINE" "$@" >"$TDIR/stdout" 2>"$TDIR/stderr"
  fi
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

# Input policy is resolved immediately after parsing. Rejections must precede every state or output
# mutation, CDP request, and Oracle process; queries/effects use the same engine boundary.
echo '# input delivery policy'
printf 'diff --git a/policy b/policy\n--- a/policy\n+++ b/policy\n@@ -0,0 +1 @@\n+bundle\n' > "$TDIR/policy.diff"
POLICY_SENTINEL="$TDIR/policy-oracle-invocations"; export POLICY_SENTINEL
: > "$POLICY_SENTINEL"; : > "$TDIR/mock.log"
for policy_input in both connector; do
  run_engine_policy bundle-only --diff "$TDIR/policy.diff" --repo "$TDIR" --input "$policy_input" --out "$TDIR/policy-$policy_input.md" --timeout 5s
  check "bundle-only rejects explicit $policy_input with exit 2" "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
done
run_engine_policy invalid-policy --diff "$TDIR/policy.diff" --repo "$TDIR" --out "$TDIR/policy-invalid.md" --timeout 5s
check 'invalid input policy rejects fresh review with exit 2' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
run_engine_policy connector-enabled --diff "$TDIR/policy.diff" --repo "$TDIR" --input '' --out "$TDIR/policy-empty.md" --timeout 5s
check 'explicit empty input is rejected rather than treated as omission' \
  "$([ "$RC" -eq 2 ] && grep -Fq -- '--input must be one of: bundle, both, connector (got empty)' "$TDIR/stderr"; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/stderr")"
run_engine_policy bundle-only --review-decision --json --pr 77 --repo "$TDIR" --input both
check 'bundle-only policy rejects review-decision query before resolution' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
run_engine_policy bundle-only --review-decision --review-decision-effect "$TDIR/no-decision.json" --pr 77 --repo "$TDIR" --input connector
check 'bundle-only policy rejects guarded review-decision effect before resolution' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
check 'bundle-only policy rejection creates no PRO_GATE_HOME state' "$([ ! -e "$TDIR/policy-home" ]; echo $?)" 'policy home exists'
check 'bundle-only policy rejection creates no output or status sidecar' "$(! find "$TDIR" -maxdepth 1 -name 'policy-*.md*' | grep -q .; echo $?)" 'output created'
check 'bundle-only policy rejection creates no Oracle call' "$([ ! -s "$POLICY_SENTINEL" ]; echo $?)" "$(cat "$POLICY_SENTINEL")"
check 'bundle-only policy rejection creates no browser/mock call' "$([ ! -s "$TDIR/mock.log" ]; echo $?)" "$(cat "$TDIR/mock.log")"

# Omitted input follows the engine policy, while explicit bundle remains valid under the safe default.
# A preflight invocation proves the normalized mode reaches the real fresh-review path.
PG_TEST_ORACLE_SENTINEL="$POLICY_SENTINEL"; PG_TEST_ORACLE_COMPLETE=1
POLICY_PROMPT="$TDIR/policy.prompt"; PG_TEST_PROMPT_CAPTURE="$POLICY_PROMPT"
export PG_TEST_ORACLE_SENTINEL PG_TEST_ORACLE_COMPLETE PG_TEST_PROMPT_CAPTURE
: > "$POLICY_PROMPT"
run_engine_policy __unset__ --pr 'https://github.com/acme/policy/pull/77' --diff "$TDIR/policy.diff" --repo "$TDIR" --out "$TDIR/policy-omitted.md" --timeout 5s
check 'unset policy resolves omitted input to bundle with attachment and no connector directive' \
  "$([ "$RC" -ne 2 ] && grep -Fq -- "--file $TDIR/policy.diff" "$POLICY_SENTINEL" && ! grep -Fq '@GitHub' "$POLICY_PROMPT"; echo $?)" \
  "rc=$RC calls=$(cat "$POLICY_SENTINEL") prompt=$(cat "$POLICY_PROMPT")"
: > "$POLICY_SENTINEL"; : > "$POLICY_PROMPT"
run_engine_policy bundle-only --pr 'https://github.com/acme/policy/pull/77' --diff "$TDIR/policy.diff" --repo "$TDIR" --input bundle --out "$TDIR/policy-bundle.md" --timeout 5s
check 'bundle-only explicit bundle uses attachment and no connector directive' \
  "$([ "$RC" -ne 2 ] && grep -Fq -- "--file $TDIR/policy.diff" "$POLICY_SENTINEL" && ! grep -Fq '@GitHub' "$POLICY_PROMPT"; echo $?)" \
  "rc=$RC calls=$(cat "$POLICY_SENTINEL") prompt=$(cat "$POLICY_PROMPT")"
: > "$POLICY_SENTINEL"; : > "$POLICY_PROMPT"
run_engine_policy connector-enabled --pr 'https://github.com/acme/policy/pull/77' --diff "$TDIR/policy.diff" --repo "$TDIR" --out "$TDIR/policy-connector-default.md" --timeout 5s
check 'connector-enabled omitted input uses both connector directive and bundle attachment' \
  "$([ "$RC" -ne 2 ] && grep -Fq -- "--file $TDIR/policy.diff" "$POLICY_SENTINEL" && grep -Fq '@GitHub' "$POLICY_PROMPT"; echo $?)" \
  "rc=$RC calls=$(cat "$POLICY_SENTINEL") prompt=$(cat "$POLICY_PROMPT")"
: > "$POLICY_SENTINEL"; : > "$POLICY_PROMPT"
run_engine_policy connector-enabled --pr 'https://github.com/acme/policy/pull/77' --diff "$TDIR/policy.diff" --repo "$TDIR" --input connector --out "$TDIR/policy-connector.md" --timeout 5s
check 'connector-enabled explicit connector uses connector directive without bundle attachment' \
  "$([ "$RC" -ne 2 ] && ! grep -Fq -- "--file $TDIR/policy.diff" "$POLICY_SENTINEL" && grep -Fq '@GitHub' "$POLICY_PROMPT"; echo $?)" \
  "rc=$RC calls=$(cat "$POLICY_SENTINEL") prompt=$(cat "$POLICY_PROMPT")"
unset PG_TEST_ORACLE_SENTINEL PG_TEST_ORACLE_COMPLETE PG_TEST_PROMPT_CAPTURE

# Lifecycle-only modes remain usable under an invalid policy: the engine reaches their normal
# handler instead of rejecting an unrelated historical inspection or recovery action.
PRO_GATE_INPUT_POLICY=invalid-policy PRO_GATE_HOME="$TDIR/policy-lifecycle" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --status --json >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'status remains usable with invalid input policy' "$([ "$RC" -eq 0 ] && ! grep -Fq 'PRO_GATE_INPUT_POLICY' "$TDIR/stderr"; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
PRO_GATE_INPUT_POLICY=invalid-policy PRO_GATE_HOME="$TDIR/policy-lifecycle" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --recover 'pg-run-policy-77-1700000000-1' --repo "$TDIR" --out "$TDIR/policy-recover.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'exact recover remains usable with invalid input policy' "$([ "$RC" -ne 2 ] && ! grep -Fq 'PRO_GATE_INPUT_POLICY' "$TDIR/stderr"; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
printf 'still thinking, run marker: pg-run-policy-77-1700000000-1\n' > "$TDIR/tab.txt"
PRO_GATE_INPUT_POLICY=invalid-policy PRO_GATE_HOME="$TDIR/policy-lifecycle" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" \
  bash "$ENGINE" --harvest 'pg-run-policy-77-1700000000-1' --out "$TDIR/policy-harvest.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'harvest remains usable with invalid input policy' "$([ "$RC" -ne 2 ] && ! grep -Fq 'PRO_GATE_INPUT_POLICY' "$TDIR/stderr"; echo $?)" "rc=$RC $(cat "$TDIR/stderr")"
for lifecycle_mode in status recover harvest; do
  case "$lifecycle_mode" in
    status) lifecycle_args=(--status --json --input bundle) ;;
    recover) lifecycle_args=(--recover pg-run-policy-77-1700000000-1 --input bundle) ;;
    harvest) lifecycle_args=(--harvest pg-run-policy-77-1700000000-1 --input bundle) ;;
  esac
  run_engine_policy invalid-policy "${lifecycle_args[@]}"
  check "$lifecycle_mode rejects an explicit irrelevant input before lifecycle work" \
    "$([ "$RC" -eq 2 ] && grep -Fq -- '--input applies only to review queries and fresh reviews' "$TDIR/stderr"; echo $?)" \
    "rc=$RC stderr=$(cat "$TDIR/stderr")"
done
printf 'still thinking, run marker: %s\n' "$MARKER" > "$TDIR/tab.txt"
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
printf 'run marker: %s\nP0: none\n\nVERDICT: SHIP — looks good. (run marker: %s)\n' "$MARKER" "$MARKER" > "$TDIR/tab.txt"
PRO_GATE_HOME="$TDIR/home" PRO_GATE_RESERVATION_MISSES=3 PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_reconcile '$HERE/../bin/cdp-salvage.mjs' '$PORT'"
check 'complete probe marks the reservation complete' "$([ "$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_state '$MARKER'")" = complete ]; echo $?)" "$(cat "$TDIR/home/in-progress/$MARKER")"
check 'completed reservation survives as a harvest pointer' "$([ -f "$TDIR/home/in-progress/$MARKER" ]; echo $?)" 'record removed instead of released'
check 'completed reservation keeps its out path' "$(awk -F'\t' 'NR==1{exit !($2 != "")}' "$TDIR/home/in-progress/$MARKER"; echo $?)" "$(cat "$TDIR/home/in-progress/$MARKER")"
check 'completed reservation stops consuming a slot' "$([ "$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_slot_plan 1" | cut -d'|' -f3)" = 1 ]; echo $?)" "plan=$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_slot_plan 1")"

INFRA_HOME="$TDIR/home-probe-infrastructure"; INFRA_KEY=acme-infra-97
INFRA_MARKER='pg-run-acme-infra-97-1700000009-97'; INFRA_EPOCH=1700000009
mkdir -p "$INFRA_HOME/in-progress" "$INFRA_HOME/run-meta" "$INFRA_HOME/rounds"
printf '%s\n' "$INFRA_EPOCH" > "$INFRA_HOME/rounds/$INFRA_KEY"
printf 'github.com\tacme\tinfra\t%s\t97\t/tmp/infra.md\t%s\n' "$INFRA_KEY" "$INFRA_EPOCH" > "$INFRA_HOME/run-meta/$INFRA_MARKER"
printf '%s\t/tmp/infra.md\t%s\t0\t\t\t%s\n' "$INFRA_KEY" "$(date +%s)" "$INFRA_EPOCH" > "$INFRA_HOME/in-progress/$INFRA_MARKER"
printf 'run marker: %s\nA network error occurred\n' "$INFRA_MARKER" > "$TDIR/tab.txt"
INFRA_STATE="$TDIR/infra-state.json"; printf '{"infrastructureError":"A network error occurred"}\n' > "$INFRA_STATE"
start_mock "$TDIR/tab.txt" "$INFRA_STATE"
PRO_GATE_HOME="$INFRA_HOME" PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_reconcile '$HERE/../bin/cdp-salvage.mjs' '$PORT'"
check 'reservation probe terminalizes exact-owned infrastructure error' \
  "$([ ! -e "$INFRA_HOME/in-progress/$INFRA_MARKER" ] && [ ! -e "$INFRA_HOME/run-meta/$INFRA_MARKER" ] \
     && [ -s "$INFRA_HOME/rounds/$INFRA_KEY" ] && jq -e '.terminal_kind=="submitted-terminal"' "$INFRA_HOME/attempt-dispositions/$INFRA_MARKER" >/dev/null 2>&1; echo $?)" \
  "disposition=$(cat "$INFRA_HOME/attempt-dispositions/$INFRA_MARKER" 2>/dev/null)"
start_mock "$TDIR/tab.txt" "$ORGANIZER_STATE"

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

# U2 (R3–R6/R9): the readable source has our marker but a stale DOM. The canonical scratch
# target supplies the completed, nonce-bound server answer; harvest must take that evidence
# through the existing shell acceptance/persistence lifecycle without dispatching Oracle.
echo '# U2: readable stale source harvest lifecycle'
MSTALE="pg-run-stale-harvest-77-1700000700-701"
STALE_SOURCE="$TDIR/stale-source.txt"
STALE_SCRATCH="$TDIR/stale-scratch.txt"
STALE_EXPECTED="$TDIR/stale-expected.md"
STALE_STATE="$TDIR/stale-browser-state.json"
STALE_SENTINEL="$TDIR/stale-oracle-invocations"
printf 'run marker: %s\nReasoning about the diff in a stale renderer...\n' "$MSTALE" > "$STALE_SOURCE"
cat > "$STALE_SCRATCH" <<STALE_SCRATCH_TEXT
run marker: $MSTALE
[P1] src/stale-source.mjs:10 — recovered from canonical server render
  Why: the source DOM was stale.
P2: none
VERDICT: SHIP — canonical review complete. (run marker: $MSTALE)
STALE_SCRATCH_TEXT
cat > "$STALE_EXPECTED" <<'STALE_EXPECTED_TEXT'
[P1] src/stale-source.mjs:10 — recovered from canonical server render
  Why: the source DOM was stale.
P2: none
VERDICT: SHIP — canonical review complete.
STALE_EXPECTED_TEXT
printf '{"title":null,"archived":false,"events":[]}\n' > "$STALE_STATE"
cat > "$TDIR/bin/oracle-stale-sentinel" <<'STALE_ORACLE'
#!/usr/bin/env bash
: >> "${PG_TEST_ORACLE_SENTINEL:?}"
exit 99
STALE_ORACLE
chmod +x "$TDIR/bin/oracle-stale-sentinel"
printf 'stale-77\t%s\t%s\t0\t1\tGPT-X\t1700000700\tgenerating\n' "$TDIR/o-stale.md" "$(date +%s)" > "$TDIR/home/in-progress/$MSTALE"
start_mock "$STALE_SOURCE" "$STALE_STATE" "$STALE_SCRATCH"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-stale-sentinel" PG_TEST_ORACLE_SENTINEL="$STALE_SENTINEL" NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$MSTALE" --out "$TDIR/o-stale.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'readable stale harvest exits 0 from canonical scratch evidence' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'readable stale harvest publishes exact nonce-stripped review' "$(cmp -s "$TDIR/o-stale.md" "$STALE_EXPECTED"; echo $?)" "$(cat "$TDIR/o-stale.md" 2>/dev/null)"
check 'readable stale harvest persists the exact durable artifact' "$(cmp -s "$TDIR/home/completed/$MSTALE" "$STALE_EXPECTED"; echo $?)" "$(cat "$TDIR/home/completed/$MSTALE" 2>/dev/null)"
check 'readable stale harvest retires its reservation' "$([ ! -e "$TDIR/home/in-progress/$MSTALE" ]; echo $?)" "$(cat "$TDIR/home/in-progress/$MSTALE" 2>/dev/null)"
check 'readable stale harvest never dispatches Oracle' "$([ ! -s "$STALE_SENTINEL" ]; echo $?)" "$(cat "$STALE_SENTINEL" 2>/dev/null)"
check 'readable stale harvest leaves the source target untouched' \
  "$([ "$(jq -r '[.closed[]? | select(. == "tab1")] | length' "$STALE_STATE")" = 0 ]; echo $?)" "$(cat "$STALE_STATE")"
check 'readable stale harvest opens and closes exactly one scratch target' \
  "$([ "$(jq -r '.created | length' "$STALE_STATE")" = 1 ] && [ "$(jq -r '.closed | map(select(. == "scratch1")) | length' "$STALE_STATE")" = 1 ]; echo $?)" "$(cat "$STALE_STATE")"
check 'readable stale harvest requests the canonical conversation URL' \
  "$([ "$(jq -r '.created[0].url' "$STALE_STATE")" = 'https://chatgpt.com/c/mock-conversation' ]; echo $?)" "$(cat "$STALE_STATE")"
# A second harvest must see the immutable completed artifact rather than race the stale source,
# write another artifact, or ever reach the fresh-dispatch Oracle binary.
: > "$STALE_SENTINEL"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-stale-sentinel" PG_TEST_ORACLE_SENTINEL="$STALE_SENTINEL" NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$MSTALE" --out "$TDIR/o-stale-idempotent.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'stale harvest replays the completed artifact idempotently' \
  "$([ "$RC" -eq 0 ] && cmp -s "$TDIR/o-stale-idempotent.md" "$STALE_EXPECTED"; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'idempotent stale harvest does not dispatch Oracle' \
  "$([ ! -s "$STALE_SENTINEL" ]; echo $?)" "state=$(cat "$STALE_STATE") oracle=$(cat "$STALE_SENTINEL" 2>/dev/null)"
check 'idempotent stale harvest leaves the retired reservation absent' \
  "$([ ! -e "$TDIR/home/in-progress/$MSTALE" ] && [ "$(find "$TDIR/home/completed" -maxdepth 1 -name "$MSTALE" | wc -l)" = 1 ]; echo $?)" "$(find "$TDIR/home/completed" -maxdepth 1 -name "$MSTALE" -print)"

# Non-terminal stale scratch evidence retains the existing state. These remain direct harvest
# integrations so the CDP class-to-shell lifecycle boundary, rather than a duplicate shell
# classifier, owns the behavior.
run_stale_retention_case() { # <label> <marker> <scratch-file> <expected-rc> [scratch-canonical-url]
  local label marker scratch expected_rc scratch_canonical_url source state
  label="$1"; marker="$2"; scratch="$3"; expected_rc="$4"; scratch_canonical_url="${5:-}"
  source="$TDIR/${label}-source.txt"; state="$TDIR/${label}-state.json"
  printf 'run marker: %s\nstale readable source\n' "$marker" > "$source"
  printf '{"title":null,"archived":false,"events":[]}\n' > "$state"
  printf '%s\t%s\t%s\t0\t1\tGPT-X\t1700000701\tgenerating\n' "$label" "$TDIR/o-${label}.md" "$(date +%s)" > "$TDIR/home/in-progress/$marker"
  : > "$STALE_SENTINEL"
  start_mock "$source" "$state" "$scratch" "$scratch_canonical_url"
  PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
    PRO_GATE_RAMP=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-stale-sentinel" PG_TEST_ORACLE_SENTINEL="$STALE_SENTINEL" NODE_OPTIONS= \
    bash "$ENGINE" --harvest "$marker" --out "$TDIR/o-${label}.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
  check "${label} stale scratch retains reservation with its existing exit" \
    "$([ "$RC" -eq "$expected_rc" ] && [ -f "$TDIR/home/in-progress/$marker" ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
  check "${label} stale scratch accepts no artifact or Oracle dispatch" \
    "$([ ! -e "$TDIR/home/completed/$marker" ] && [ ! -s "$STALE_SENTINEL" ]; echo $?)" "artifact=$(ls "$TDIR/home/completed/$marker" 2>/dev/null) oracle=$(cat "$STALE_SENTINEL" 2>/dev/null)"
  check "${label} stale scratch closes only one scratch target" \
    "$([ "$(jq -r '.created | length' "$state")" = 1 ] && [ "$(jq -r '.closed | map(select(. == "scratch1")) | length' "$state")" = 1 ] && [ "$(jq -r '.closed | map(select(. == "tab1")) | length' "$state")" = 0 ]; echo $?)" "$(cat "$state")"
}

MSTALE_INCOMPLETE="pg-run-stale-incomplete-77-1700000701-702"
STALE_INCOMPLETE="$TDIR/stale-incomplete-scratch.txt"
printf 'run marker: %s\nStill thinking on the canonical page.\n' "$MSTALE_INCOMPLETE" > "$STALE_INCOMPLETE"
run_stale_retention_case stale-incomplete "$MSTALE_INCOMPLETE" "$STALE_INCOMPLETE" 9

MSTALE_INCONCLUSIVE="pg-run-stale-inconclusive-77-1700000702-703"
STALE_INCONCLUSIVE="$TDIR/stale-inconclusive-scratch.txt"
printf 'Loading ChatGPT…\n' > "$STALE_INCONCLUSIVE"
run_stale_retention_case stale-inconclusive "$MSTALE_INCONCLUSIVE" "$STALE_INCONCLUSIVE" 9

# Mock scratch content is URL-bound: a completed artifact attached to a different canonical URL
# must be inconclusive and never reach the harvest lifecycle.
MSTALE_WRONG_URL="pg-run-stale-wrong-url-77-1700000702-703"
STALE_WRONG_URL="$TDIR/stale-wrong-url-scratch.txt"
cat > "$STALE_WRONG_URL" <<STALE_WRONG_URL_TEXT
run marker: $MSTALE_WRONG_URL
[P1] src/wrong-url.mjs:1 — must not be accepted
P2: none
VERDICT: SHIP — wrong URL artifact. (run marker: $MSTALE_WRONG_URL)
STALE_WRONG_URL_TEXT
run_stale_retention_case stale-wrong-url "$MSTALE_WRONG_URL" "$STALE_WRONG_URL" 9 'https://chatgpt.com/c/not-the-source'

MSTALE_THROTTLE="pg-run-stale-throttle-77-1700000703-704"
STALE_THROTTLE="$TDIR/stale-throttle-scratch.txt"
printf "You're making requests too quickly. Temporarily limited access to your conversations.\n" > "$STALE_THROTTLE"
run_stale_retention_case stale-throttle "$MSTALE_THROTTLE" "$STALE_THROTTLE" 8
check 'throttled stale scratch keeps its reservation and writes the existing cooldown' \
  "$([ -f "$TDIR/home/in-progress/$MSTALE_THROTTLE" ] && [ -f "$TDIR/home/throttle.cooldown" ]; echo $?)" "$(cat "$TDIR/home/throttle.cooldown" 2>/dev/null)"
rm -f "$TDIR/home/throttle.cooldown"

MSTALE_CROSS="pg-run-stale-cross-77-1700000704-705"
MSTALE_FOREIGN="pg-run-stale-foreign-77-1700000704-706"
STALE_CROSS="$TDIR/stale-cross-scratch.txt"
cat > "$STALE_CROSS" <<STALE_CROSS_TEXT
run marker: $MSTALE_CROSS
run marker: $MSTALE_FOREIGN
[P1] src/foreign.mjs:4 — foreign result
P2: none
VERDICT: SHIP — foreign conversation. (run marker: $MSTALE_FOREIGN)
STALE_CROSS_TEXT
run_stale_retention_case stale-cross "$MSTALE_CROSS" "$STALE_CROSS" 9
# These cases intentionally retained their state; clear only their isolated fixture records before
# asserting the probe's single capacity transition.
rm -f "$TDIR/home/in-progress/$MSTALE_INCOMPLETE" "$TDIR/home/in-progress/$MSTALE_INCONCLUSIVE" \
  "$TDIR/home/in-progress/$MSTALE_WRONG_URL" "$TDIR/home/in-progress/$MSTALE_THROTTLE" \
  "$TDIR/home/in-progress/$MSTALE_CROSS"

# The same revalidated terminal evidence drives probe. Reconciliation changes only the existing
# state field from generating to complete: it preserves the collectable reservation and frees its
# capacity slot, without doing a harvest or starting Oracle.
MSTALE_PROBE="pg-run-stale-probe-77-1700000705-707"
STALE_PROBE_SOURCE="$TDIR/stale-probe-source.txt"
STALE_PROBE_SCRATCH="$TDIR/stale-probe-scratch.txt"
STALE_PROBE_STATE="$TDIR/stale-probe-state.json"
printf 'run marker: %s\nstale readable source\n' "$MSTALE_PROBE" > "$STALE_PROBE_SOURCE"
cat > "$STALE_PROBE_SCRATCH" <<STALE_PROBE_TEXT
run marker: $MSTALE_PROBE
[P1] src/probe.mjs:1 — completed server review
P2: none
VERDICT: SHIP — complete. (run marker: $MSTALE_PROBE)
STALE_PROBE_TEXT
printf '{"title":null,"archived":false,"events":[]}\n' > "$STALE_PROBE_STATE"
printf 'stale-probe-77\t%s\t%s\t0\t1\tGPT-X\t1700000705\tgenerating\n' "$TDIR/o-stale-probe.md" "$(date +%s)" > "$TDIR/home/in-progress/$MSTALE_PROBE"
start_mock "$STALE_PROBE_SOURCE" "$STALE_PROBE_STATE" "$STALE_PROBE_SCRATCH"
PRO_GATE_HOME="$TDIR/home" PRO_GATE_RESERVATION_MISSES=3 PRO_GATE_RECONCILE_INTERVAL=0 \
  bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_reconcile '$HERE/../bin/cdp-salvage.mjs' '$PORT'"
check 'stale readable probe marks only the existing reservation state complete' \
  "$([ -f "$TDIR/home/in-progress/$MSTALE_PROBE" ] && [ "$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_state '$MSTALE_PROBE'")" = complete ]; echo $?)" "$(cat "$TDIR/home/in-progress/$MSTALE_PROBE")"
check 'stale readable probe frees only the completed reservation capacity' \
  "$([ "$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_slot_plan 1" | cut -d'|' -f3)" = 1 ]; echo $?)" "plan=$(PRO_GATE_HOME="$TDIR/home" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_slot_plan 1")"
check 'stale readable probe closes scratch without mutating its source target' \
  "$([ "$(jq -r '.closed | map(select(. == "scratch1")) | length' "$STALE_PROBE_STATE")" = 1 ] && [ "$(jq -r '.closed | map(select(. == "tab1")) | length' "$STALE_PROBE_STATE")" = 0 ]; echo $?)" "$(cat "$STALE_PROBE_STATE")"

# Holding the existing per-marker lock models a concurrent collector. The contender must return
# the established busy outcome before CDP, artifact mutation, or any fresh Oracle path.
MSTALE_BUSY="pg-run-stale-busy-77-1700000706-708"
printf 'stale-busy-77\t%s\t%s\t0\t1\tGPT-X\t1700000706\tgenerating\n' "$TDIR/o-stale-busy.md" "$(date +%s)" > "$TDIR/home/in-progress/$MSTALE_BUSY"
printf 'run marker: %s\nstale readable source\n' "$MSTALE_BUSY" > "$TDIR/stale-busy-source.txt"
printf '{"title":null,"archived":false,"events":[]}\n' > "$TDIR/stale-busy-state.json"
start_mock "$TDIR/stale-busy-source.txt" "$TDIR/stale-busy-state.json" "$STALE_SCRATCH"
mkdir -p "$TDIR/home/harvest-locks"
exec {STALE_BUSY_FD}>>"$TDIR/home/harvest-locks/$MSTALE_BUSY"; flock -n "$STALE_BUSY_FD"
: > "$STALE_SENTINEL"
PRO_GATE_HOME="$TDIR/home" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_HARVEST_LOCK_WAIT=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-stale-sentinel" PG_TEST_ORACLE_SENTINEL="$STALE_SENTINEL" NODE_OPTIONS= \
  bash "$ENGINE" --harvest "$MSTALE_BUSY" --out "$TDIR/o-stale-busy.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
eval "exec ${STALE_BUSY_FD}>&-"
check 'concurrent stale harvest returns the established busy outcome' "$([ "$RC" -eq 7 ] && [ -f "$TDIR/home/in-progress/$MSTALE_BUSY" ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"
check 'concurrent stale harvest starts neither scratch nor Oracle' \
  "$([ "$(jq -r '.created | length' "$TDIR/stale-busy-state.json")" = 0 ] && [ ! -s "$STALE_SENTINEL" ]; echo $?)" "state=$(cat "$TDIR/stale-busy-state.json") oracle=$(cat "$STALE_SENTINEL" 2>/dev/null)"
# Keep the rest of the legacy engine suite independent from these intentionally retained records.
rm -f "$TDIR/home/in-progress/$MSTALE_INCOMPLETE" "$TDIR/home/in-progress/$MSTALE_INCONCLUSIVE" \
  "$TDIR/home/in-progress/$MSTALE_WRONG_URL" "$TDIR/home/in-progress/$MSTALE_THROTTLE" \
  "$TDIR/home/in-progress/$MSTALE_CROSS" \
  "$TDIR/home/in-progress/$MSTALE_PROBE" "$TDIR/home/in-progress/$MSTALE_BUSY"

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
# #143: a clean row carries reason/detail as EMPTY strings — present, never absent, never populated.
check '#143 clean ledger row carries empty reason and detail (present, not absent)' \
  "$(printf '%s' "$SLOTS2_ROW" | jq -e 'has("reason") and has("detail") and .reason == "" and .detail == ""' >/dev/null 2>&1; echo $?)" "$SLOTS2_ROW"
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
check 'miss limit without canonical run-meta stays fail-closed' "$([ "$RC" -eq 9 ] && [ -f "$TDIR/home/in-progress/$MARKER3" ]; echo $?)" "rc=$RC $(tail -2 "$TDIR/stderr")"

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
start_mock "$TDIR/tab.txt"
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
NOTE="$(PRO_GATE_HOME="$TDIR/home-fmt" PRO_GATE_RESERVATION_MISSES=3 PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$MKF'")"
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
genforce() { local key="$1"; shift; gguard "$key" PRO_GATE_ROUND_GUARD=1 "$@"; }
gscore() { # $1=key -> "earned<TAB>streak<TAB>elapsed_secs<TAB>scored" from pg_round_score
  env PRO_GATE_HOME="$GHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_score '$1'; printf '%s\t%s\t%s\t%s\n' \"\$PG_ROUND_EARNED\" \"\$PG_ROUND_STREAK\" \"\$PG_ROUND_ELAPSED_SECS\" \"\$PG_ROUND_SCORED\""
}
# No explicit policy: count, grant, and trajectory are advisory and never ration a safe review.
gseed nohist 3
GOUT="$(gguard nohist)"; GRC=$?
GPOLICY="$(env PRO_GATE_HOME="$GHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_policy_mode nohist")"
check 'default round policy is advisory after the computed grant is spent' "$([ "$GRC" -eq 0 ] && [ "$GPOLICY" = advisory ]; echo $?)" "rc=$GRC policy=$GPOLICY out=$GOUT"
# Explicit guard preserves the former trajectory-aware enforcement contract.
GOUT="$(genforce nohist)"; GRC=$?
check 'explicit governor: base grant refuses round 4 without earned rounds' "$([ "$GRC" -eq 1 ]; echo $?)" "rc=$GRC out=$GOUT"
check 'explicit governor: exhaustion reason names base + earned + ceiling' "$(printf '%s' "$GOUT" | grep -q 'base 3 + 0 earned'; echo $?)" "$GOUT"
gseed nohist 2
genforce nohist >/dev/null; GRC=$?
check 'explicit governor: round 3 of base 3 proceeds' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC"
# Shrinking trajectory earns extra enforced rounds: open 5 -> 3 -> 1 = +2 earned (grant 5).
gseed shrink 4; ghist shrink 5 3 1
genforce shrink >/dev/null; GRC=$?
check 'explicit governor: shrinking trajectory earns round 5' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC $(genforce shrink)"
gseed shrink 5
GOUT="$(genforce shrink)"; GRC=$?
check 'explicit governor: earned grant still exhausts (5/5)' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q '5/5 rounds'; echo $?)" "rc=$GRC out=$GOUT"
# Churn remains telemetry by default and a brake only under explicit enforcement.
gseed churn 3; ghist churn 5 7 8
gguard churn >/dev/null; GRC=$?
check 'default churn trajectory remains advisory' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC"
GOUT="$(genforce churn)"; GRC=$?
check 'explicit governor: churn brake refuses (not converging)' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q 'churning, not converging'; echo $?)" "rc=$GRC out=$GOUT"
check 'explicit governor: churn reason carries the trajectory arrow' "$(printf '%s' "$GOUT" | grep -q '5→7→8'; echo $?)" "$GOUT"
# A recovery round (shrink after churn) resets the streak: 5 -> 7 -> 8 -> 2 is earning again.
ghist churn 5 7 8 2
genforce churn >/dev/null; GRC=$?
check 'explicit governor: a shrinking round releases the brake' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC $(genforce churn)"
# Ceiling remains the explicit-enforcement backstop while advisory mode still reports it.
gseed marathon 8; ghist marathon 20 18 16 14 12 10 8 6 4 2 1
GOUT="$(genforce marathon)"; GRC=$?
check 'explicit governor: ceiling 8 caps any earned run' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q 'ceiling 8'; echo $?)" "rc=$GRC out=$GOUT"
# Explicitly-set flat cap pins legacy behavior: churn trajectory is ignored.
gseed flatkey 3; ghist flatkey 5 7 8
gguard flatkey PRO_GATE_MAX_ROUNDS_PER_PR=4 >/dev/null; GRC=$?
check 'flat mode: explicit cap ignores the trajectory' "$([ "$GRC" -eq 0 ]; echo $?)" "rc=$GRC"
GOUT="$(gguard flatkey PRO_GATE_MAX_ROUNDS_PER_PR=3)"; GRC=$?
check 'flat mode: explicit cap still enforces its number' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q '3/3 slot-spending'; echo $?)" "rc=$GRC out=$GOUT"
# Base 0 keeps the lockdown reading in governor mode.
GOUT="$(gguard nohist PRO_GATE_ROUNDS_BASE=0)"; GRC=$?
check 'governor: base 0 is a lockdown' "$([ "$GRC" -eq 1 ] && printf '%s' "$GOUT" | grep -q 'PRO_GATE_ROUNDS_BASE=0'; echo $?)" "rc=$GRC out=$GOUT"
GPOLICY="$(env PRO_GATE_HOME="$GHOME" PRO_GATE_ROUNDS_BASE=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_policy_mode nohist")"
check 'explicit zero base reports lockdown policy' "$([ "$GPOLICY" = lockdown ]; echo $?)" "policy=$GPOLICY"
GPOLICY="$(env PRO_GATE_HOME="$GHOME" PRO_GATE_MAX_ROUNDS_PER_PR=4 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_policy_mode nohist")"
check 'explicit flat cap reports enforced policy' "$([ "$GPOLICY" = enforced ]; echo $?)" "policy=$GPOLICY"
GPOLICY="$(env PRO_GATE_HOME="$GHOME" PRO_GATE_ROUND_GUARD=0 PRO_GATE_MAX_ROUNDS_PER_PR=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_round_policy_mode nohist")"
check 'explicit guard off outranks explicit lockdown knobs' "$([ "$GPOLICY" = off ]; echo $?)" "policy=$GPOLICY"
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
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 PRO_GATE_ROUND_GUARD=1 \
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
[ "${1:-}" = session ] && exit 1
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; *) shift;; esac; done
slug=fake-dead
mkdir -p "${ORACLE_HOME_DIR:?}/sessions/$slug"
jq -cn --arg id "$slug" --arg prompt "$prompt" '{id:$id,status:"error",options:{prompt:$prompt},browser:{runtime:{promptSubmitted:false}}}' \
  > "$ORACLE_HOME_DIR/sessions/$slug/meta.json"
printf 'Session: %s\n' "$slug"
exit 1
FAKE_DEAD
chmod +x "$TDIR/bin/oracle-dead"
RKEY_91="$(printf '%s-91' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$RHOME" ORACLE_HOME_DIR="$RHOME/oracle-dead" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 PRO_GATE_STALL_SECS=30 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-dead" NODE_OPTIONS= \
  bash "$ENGINE" --pr 91 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-refund.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'never-landed run fails (exit 6)' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'never-landed run announces the refund' "$(grep -q 'refunding this round' "$TDIR/stderr"; echo $?)" "$(tail -5 "$TDIR/stderr")"
# #143: the ledger row must say WHY it failed, from a closed enum, and carry the status detail.
REFUND_ROW="$(grep -F "\"out\":\"$RHOME/o-refund.md\"" "$RHOME/ledger.jsonl" | tail -1)"
check '#143 never-landed ledger row carries reason=refunded-unsubmitted' \
  "$([ "$(printf '%s' "$REFUND_ROW" | jq -r '.reason // "MISSING"')" = refunded-unsubmitted ]; echo $?)" "$REFUND_ROW"
check '#143 never-landed ledger row carries the status detail verbatim' \
  "$(printf '%s' "$REFUND_ROW" | jq -e '.detail | test("round refunded")' >/dev/null 2>&1; echo $?)" "$REFUND_ROW"
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
# #143: same exit code as the never-landed run above, DIFFERENT reason — this is the whole point.
LANDED_ROW="$(grep -F "\"out\":\"$RHOME/o-landed.md\"" "$RHOME/ledger.jsonl" | tail -1)"
check '#143 landed-but-lost ledger row carries reason=salvage-empty (not the refund reason)' \
  "$([ "$(printf '%s' "$LANDED_ROW" | jq -r '.reason // "MISSING"')" = salvage-empty ]; echo $?)" "$LANDED_ROW"
check '#143 two exit-6 rows with different fates carry different reasons' \
  "$([ "$(printf '%s' "$REFUND_ROW" | jq -r .reason)" != "$(printf '%s' "$LANDED_ROW" | jq -r .reason)" ]; echo $?)" \
  "refund=$(printf '%s' "$REFUND_ROW" | jq -r .reason) landed=$(printf '%s' "$LANDED_ROW" | jq -r .reason)"
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
count=0; prompt=""
[ -s "${PG_TEST_ATTEMPTS_FILE:?}" ] && count="$(cat "$PG_TEST_ATTEMPTS_FILE")"
count=$((count + 1)); printf '%s\n' "$count" > "$PG_TEST_ATTEMPTS_FILE"
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; *) shift;; esac; done
slug="fake-quiet-$count"
mkdir -p "${ORACLE_HOME_DIR:?}/sessions/$slug"
jq -cn --arg id "$slug" --arg prompt "$prompt" '{id:$id,status:"error",options:{prompt:$prompt},browser:{runtime:{promptSubmitted:false}}}' \
  > "$ORACLE_HOME_DIR/sessions/$slug/meta.json"
printf 'Session: %s\n' "$slug"
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
env PRO_GATE_HOME="$CTL_HOME" ORACLE_HOME_DIR="$CTL_HOME/oracle" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
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
env PRO_GATE_HOME="$LOSS_HOME" ORACLE_HOME_DIR="$LOSS_HOME/oracle" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=1 PRO_GATE_RETRY_BACKOFF=0 PRO_GATE_REATTACH_TIMEOUT=1 \
  PRO_GATE_TIMEOUT_GRACE=1 PRO_GATE_TEST_MODE=ci-fixture PRO_GATE_TEST_PRE_RETRY_PROBE_SECS=1 PRO_GATE_SALVAGE_SECS=2 PRO_GATE_RUN_LOGS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-quiet-fail" \
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
  PRO_GATE_MAX_RETRIES=0 PRO_GATE_STALL_SECS=1 PRO_GATE_TEST_MODE=ci-fixture PRO_GATE_TEST_WATCHDOG_SLEEP_SECS=1 PRO_GATE_REATTACH_TIMEOUT=1 \
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
  PRO_GATE_MAX_RETRIES=0 PRO_GATE_STALL_SECS=1 PRO_GATE_TEST_MODE=ci-fixture PRO_GATE_TEST_WATCHDOG_SLEEP_SECS=1 PRO_GATE_REATTACH_TIMEOUT=1 \
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
# CI wait optimization pass 4: a real (non-empty) TERM trap lets the fixture record its own
# TERM_RECEIVED/RESISTING_AFTER_TERM/DRAIN_TICK event stream to a private file BEFORE the read
# builtin is interrupted and re-armed with a short timeout — the process still never voluntarily
# exits (only SIGKILL reaps it), so it is exactly as TERM-resistant as the original empty-trap
# design, but now records ordered, non-time-based evidence of surviving inside the watchdog's
# bounded drain window. It also plants a false "provably unsubmitted" session record (the same
# shape v0.31's refund path trusts) so the charged/no-refund assertions below prove proof
# revocation defeats that landmine, not merely that nothing crashed.
# Both timing details below are load-bearing, verified by direct repro (not guessed):
#   1. `timeout --signal=TERM` relays ONE received TERM as TWO near-simultaneous deliveries to
#      the child process group (sub-millisecond apart) — the trap below must be reentrant-safe,
#      so RESISTING_AFTER_TERM is recorded synchronously inside the trap itself, one-shot guarded,
#      rather than from the main loop noticing a state flag on its next iteration.
#   2. A plain blocking `read` (no -t) that is interrupted by that back-to-back signal pair never
#      resumes in this bash — the builtin appears to wedge permanently once a second signal lands
#      while its trap for the first is still unwinding. The fixture therefore never blocks
#      indefinitely: it always polls the writer-less fifo with `read -t 1`, both before and after
#      TERM, so a re-armed 1-second read is the ONLY blocking primitive in play at any time. This
#      keeps the "no child to kill, no CPU burn, only KILL ends it" property (still no voluntary
#      exit path) while eliminating the wedge.
cat > "$TDIR/bin/oracle-term-ignoring" <<'FAKE_TERM_IGNORE'
#!/usr/bin/env bash
[ "${1:-}" = session ] && exit 1
event() { printf '%s\n' "$1" >> "${PG_TEST_TERM_EVENTS:?}"; }
term_seen=0
resisting=0
on_term() {
  term_seen=1
  event TERM_RECEIVED
  if [ "$resisting" -eq 0 ]; then
    resisting=1
    event RESISTING_AFTER_TERM
  fi
}
trap on_term TERM
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; *) shift;; esac; done
slug=fake-term-ignoring
mkdir -p "${ORACLE_HOME_DIR:?}/sessions/$slug"
# A false no-submit landmine: if proof revocation ever failed, this shape alone would earn a
# refund (see the v0.31 oracle-dead fixture above). Proving it does NOT is the point.
jq -cn --arg id "$slug" --arg prompt "$prompt" \
  '{id:$id,status:"error",options:{prompt:$prompt},browser:{runtime:{promptSubmitted:false}}}' \
  > "$ORACLE_HOME_DIR/sessions/$slug/meta.json"
printf '%s\n' "$$" > "${PG_TEST_PRODUCER_PID:?}"
ps -o pgid= -p "$$" | tr -d '[:space:]' > "${PG_TEST_PRODUCER_PGID:?}"
event READY
printf 'Session: %s\nLaunching browser mode\n' "$slug"
exec 3<> "${PG_TEST_BLOCK_FIFO:?}"
while :; do
  read -t 1 -u 3 -r _ || true
  if [ "$term_seen" -ge 1 ]; then
    event DRAIN_TICK
  fi
done
FAKE_TERM_IGNORE
chmod +x "$TDIR/bin/oracle-term-ignoring"
ORPHAN_HOME="$TDIR/home-orphan"; ORPHAN_ORACLE="$TDIR/oracle-term-ignoring"
ORPHAN_PID="$TDIR/orphan-producer.pid"; ORPHAN_PGID="$TDIR/orphan-producer.pgid"
ORPHAN_EVENTS="$TDIR/orphan-term.events"; ORPHAN_FIFO="$TDIR/orphan-block.fifo"
RKEY_924="$(printf '%s-924' "$(basename "$TDIR")" | tr -c 'A-Za-z0-9.\n-' '-')"
mkdir -p "$ORPHAN_HOME" "$ORPHAN_ORACLE"; : > "$ORPHAN_PID"; : > "$ORPHAN_PGID"; : > "$ORPHAN_EVENTS"
rm -f "$ORPHAN_FIFO"; mkfifo "$ORPHAN_FIFO"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
# The drain/settle windows are shortened here ONLY (pass 4's test-only helpers); production
# retains 30/5. Signal targets, trap grace, kill-after, wait/reap, and proof revocation order
# are untouched — see PASS-4.md's isomorphism proof.
env PRO_GATE_HOME="$ORPHAN_HOME" ORACLE_HOME_DIR="$ORPHAN_ORACLE" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=0 PRO_GATE_STALL_SECS=1 PRO_GATE_TEST_MODE=ci-fixture PRO_GATE_TEST_WATCHDOG_SLEEP_SECS=1 \
  PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS=3 PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS=1 PRO_GATE_REATTACH_TIMEOUT=1 \
  PRO_GATE_SALVAGE_SECS=2 PRO_GATE_RUN_LOGS=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-term-ignoring" \
  PG_TEST_PRODUCER_PID="$ORPHAN_PID" PG_TEST_PRODUCER_PGID="$ORPHAN_PGID" PG_TEST_TERM_EVENTS="$ORPHAN_EVENTS" \
  PG_TEST_BLOCK_FIFO="$ORPHAN_FIFO" NODE_OPTIONS= \
  bash "$ENGINE" --pr 924 --repo "$TDIR" --diff "$TDIR/small.diff" \
  --out "$ORPHAN_HOME/o-orphan.md" --timeout 5s >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
ORPHAN_SEEN="$(cat "$ORPHAN_PID" 2>/dev/null)"
ORPHAN_PGID_SEEN="$(cat "$ORPHAN_PGID" 2>/dev/null)"
ORPHAN_TERM_LINE="$(grep -n -x -F 'TERM_RECEIVED' "$ORPHAN_EVENTS" 2>/dev/null | head -1 | cut -d: -f1)"
ORPHAN_RESIST_LINE="$(grep -n -x -F 'RESISTING_AFTER_TERM' "$ORPHAN_EVENTS" 2>/dev/null | head -1 | cut -d: -f1)"
ORPHAN_TICK_LINE="$(grep -n -x -F 'DRAIN_TICK' "$ORPHAN_EVENTS" 2>/dev/null | head -1 | cut -d: -f1)"
ORPHAN_TICK_COUNT="$(grep -c -x -F 'DRAIN_TICK' "$ORPHAN_EVENTS" 2>/dev/null)"; ORPHAN_TICK_COUNT="${ORPHAN_TICK_COUNT:-0}"
ORPHAN_GROUP_SURVIVORS=""
[ -n "$ORPHAN_PGID_SEEN" ] && ORPHAN_GROUP_SURVIVORS="$(pgrep -g "$ORPHAN_PGID_SEEN" 2>/dev/null || true)"
ORPHAN_EVENTS_TEXT="$(tr '\n' ' ' < "$ORPHAN_EVENTS" 2>/dev/null)"
check 'TERM-ignoring Oracle still terminates the attempt' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'TERM-ignoring Oracle actually started (fixture sanity)' \
  "$([ -n "$ORPHAN_SEEN" ] && [ -n "$ORPHAN_PGID_SEEN" ]; echo $?)" "pid=$ORPHAN_SEEN pgid=$ORPHAN_PGID_SEEN"
# Ordering, not elapsed wall time, is the evidence: each event is a distinct line appended only
# from inside the fixture, so its line number is a strict happens-before witness.
check 'TERM-ignoring Oracle records TERM receipt before it can be reaped' \
  "$([ -n "$ORPHAN_TERM_LINE" ]; echo $?)" "events=$ORPHAN_EVENTS_TEXT"
check 'TERM-ignoring Oracle remains alive/resistant after TERM long enough to enter the bounded drain path' \
  "$([ -n "$ORPHAN_TERM_LINE" ] && [ -n "$ORPHAN_RESIST_LINE" ] && [ -n "$ORPHAN_TICK_LINE" ] \
     && [ "$ORPHAN_TERM_LINE" -lt "$ORPHAN_RESIST_LINE" ] && [ "$ORPHAN_RESIST_LINE" -lt "$ORPHAN_TICK_LINE" ] \
     && [ "$ORPHAN_TICK_COUNT" -ge 1 ]; echo $?)" \
  "events=$ORPHAN_EVENTS_TEXT ticks=$ORPHAN_TICK_COUNT"
check 'TERM-ignoring Oracle process group has no surviving descendant after engine exit' \
  "$([ -n "$ORPHAN_SEEN" ] && [ -n "$ORPHAN_PGID_SEEN" ] \
     && ! kill -0 "$ORPHAN_SEEN" 2>/dev/null && [ -z "$ORPHAN_GROUP_SURVIVORS" ]; echo $?)" \
  "pid=$ORPHAN_SEEN pgid=$ORPHAN_PGID_SEEN survivors=$ORPHAN_GROUP_SURVIVORS"
# Same run also covers the BLUNT-fallback branch: the producer never drains, so the attempt is
# force-killed. It planted a false no-submit session record above; proof revocation must defeat
# that landmine and stay charged no matter how clean the log or metadata looks.
check 'TERM-ignoring fixture planted a false no-submit proof candidate (landmine sanity)' \
  "$(jq -e '.browser.runtime.promptSubmitted == false' "$ORPHAN_ORACLE/sessions/fake-term-ignoring/meta.json" >/dev/null 2>&1; echo $?)" \
  "meta=$(tr -s '[:space:]' ' ' < "$ORPHAN_ORACLE/sessions/fake-term-ignoring/meta.json" 2>/dev/null)"
check 'force-killed attempt stays charged despite the false no-submit landmine (no certified proof)' \
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
submitted=true; [ "${PG_TEST_COMMIT_MODE:-complete}" != pre-submit ] || submitted=false
jq -n --arg id "$slug" --arg prompt "$prompt" --arg tabUrl "$tab_url" \
  --argjson promptLength "${#prompt}" --argjson submitted "$submitted" '
  {
    id: $id,
    status: "error",
    mode: "browser",
    options: {prompt: $prompt},
    browser: {runtime: {promptSubmitted: $submitted, tabUrl: $tabUrl}},
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
  PRO_GATE_REATTACH_TIMEOUT=1 PRO_GATE_TIMEOUT_GRACE=1 PRO_GATE_TEST_MODE=ci-fixture PRO_GATE_TEST_PRE_RETRY_PROBE_SECS=1 PRO_GATE_SALVAGE_SECS=2 \
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
  PRO_GATE_MAX_RETRIES=1 PRO_GATE_RETRY_BACKOFF=0 PRO_GATE_REATTACH_TIMEOUT=1 PRO_GATE_TIMEOUT_GRACE=1 PRO_GATE_TEST_MODE=ci-fixture PRO_GATE_TEST_PRE_RETRY_PROBE_SECS=1 PRO_GATE_SALVAGE_SECS=2 \
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

# CI wait optimization pass 2: source the real private library helper in a fresh Bash
# process for each boundary. The helper is used only by the three ambiguity fixtures above.
prsecs_for() { # $1 = timing value or UNSET; $2 = mode (defaults to the fixture token)
  local mode="${2:-ci-fixture}"
  if [ "$1" = UNSET ]; then
    if [ "$mode" = UNSET_MODE ]; then
      ( unset PRO_GATE_TEST_MODE PRO_GATE_TEST_PRE_RETRY_PROBE_SECS; bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_pre_retry_probe_secs" )
    else
      ( unset PRO_GATE_TEST_PRE_RETRY_PROBE_SECS; PRO_GATE_TEST_MODE="$mode" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_pre_retry_probe_secs" )
    fi
  elif [ "$mode" = UNSET_MODE ]; then
    ( unset PRO_GATE_TEST_MODE; PRO_GATE_TEST_PRE_RETRY_PROBE_SECS="$1" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_pre_retry_probe_secs" )
  else
    PRO_GATE_TEST_MODE="$mode" PRO_GATE_TEST_PRE_RETRY_PROBE_SECS="$1" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_pre_retry_probe_secs"
  fi
}
check 'pre-retry probe seconds: unset retains production default 30' \
  "$([ "$(prsecs_for UNSET)" = 30 ]; echo $?)" "got=$(prsecs_for UNSET)"
check 'pre-retry probe seconds: empty string retains production default 30' \
  "$([ "$(prsecs_for '')" = 30 ]; echo $?)" "got=$(prsecs_for '')"
check 'pre-retry probe seconds: zero retains production default 30' \
  "$([ "$(prsecs_for 0)" = 30 ]; echo $?)" "got=$(prsecs_for 0)"
check 'pre-retry probe seconds: negative retains production default 30' \
  "$([ "$(prsecs_for -1)" = 30 ]; echo $?)" "got=$(prsecs_for -1)"
check 'pre-retry probe seconds: non-numeric retains production default 30' \
  "$([ "$(prsecs_for abc)" = 30 ]; echo $?)" "got=$(prsecs_for abc)"
check 'pre-retry probe seconds: leading-zero form is rejected, retains default 30' \
  "$([ "$(prsecs_for 007)" = 30 ]; echo $?)" "got=$(prsecs_for 007)"
check 'pre-retry probe seconds: out-of-bounds above 30 retains production default 30' \
  "$([ "$(prsecs_for 31)" = 30 ]; echo $?)" "got=$(prsecs_for 31)"
check 'pre-retry probe seconds: three-digit value retains production default 30' \
  "$([ "$(prsecs_for 100)" = 30 ]; echo $?)" "got=$(prsecs_for 100)"
check 'pre-retry probe seconds: valid value without test mode retains production default 30' \
  "$([ "$(prsecs_for 1 UNSET_MODE)" = 30 ]; echo $?)" "got=$(prsecs_for 1 UNSET_MODE)"
check 'pre-retry probe seconds: valid value with wrong mode retains production default 30' \
  "$([ "$(prsecs_for 1 not-ci-fixture)" = 30 ]; echo $?)" "got=$(prsecs_for 1 not-ci-fixture)"
check 'pre-retry probe seconds: valid minimum bound 1 is honored only in exact ci-fixture mode' \
  "$([ "$(prsecs_for 1)" = 1 ]; echo $?)" "got=$(prsecs_for 1)"
check 'pre-retry probe seconds: valid mid-range value 15 is honored' \
  "$([ "$(prsecs_for 15)" = 15 ]; echo $?)" "got=$(prsecs_for 15)"
check 'pre-retry probe seconds: valid maximum bound 30 is honored' \
  "$([ "$(prsecs_for 30)" = 30 ]; echo $?)" "got=$(prsecs_for 30)"

# CI wait optimization pass 3: source the real private library helper in a fresh Bash
# process for each boundary. The helper is set only in the watchdog-kill fixtures below.
wdsecs_for() { # $1 = timing value or UNSET; $2 = mode (defaults to the fixture token)
  local mode="${2:-ci-fixture}"
  if [ "$1" = UNSET ]; then
    if [ "$mode" = UNSET_MODE ]; then
      ( unset PRO_GATE_TEST_MODE PRO_GATE_TEST_WATCHDOG_SLEEP_SECS; bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_sleep_secs" )
    else
      ( unset PRO_GATE_TEST_WATCHDOG_SLEEP_SECS; PRO_GATE_TEST_MODE="$mode" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_sleep_secs" )
    fi
  elif [ "$mode" = UNSET_MODE ]; then
    ( unset PRO_GATE_TEST_MODE; PRO_GATE_TEST_WATCHDOG_SLEEP_SECS="$1" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_sleep_secs" )
  else
    PRO_GATE_TEST_MODE="$mode" PRO_GATE_TEST_WATCHDOG_SLEEP_SECS="$1" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_sleep_secs"
  fi
}
check 'watchdog sleep seconds: unset retains production default 10' \
  "$([ "$(wdsecs_for UNSET)" = 10 ]; echo $?)" "got=$(wdsecs_for UNSET)"
check 'watchdog sleep seconds: empty string retains production default 10' \
  "$([ "$(wdsecs_for '')" = 10 ]; echo $?)" "got=$(wdsecs_for '')"
check 'watchdog sleep seconds: zero retains production default 10' \
  "$([ "$(wdsecs_for 0)" = 10 ]; echo $?)" "got=$(wdsecs_for 0)"
check 'watchdog sleep seconds: negative retains production default 10' \
  "$([ "$(wdsecs_for -1)" = 10 ]; echo $?)" "got=$(wdsecs_for -1)"
check 'watchdog sleep seconds: non-numeric retains production default 10' \
  "$([ "$(wdsecs_for abc)" = 10 ]; echo $?)" "got=$(wdsecs_for abc)"
check 'watchdog sleep seconds: leading-zero form is rejected, retains default 10' \
  "$([ "$(wdsecs_for 007)" = 10 ]; echo $?)" "got=$(wdsecs_for 007)"
check 'watchdog sleep seconds: above-bound 11 retains production default 10' \
  "$([ "$(wdsecs_for 11)" = 10 ]; echo $?)" "got=$(wdsecs_for 11)"
check 'watchdog sleep seconds: three-digit value retains production default 10' \
  "$([ "$(wdsecs_for 100)" = 10 ]; echo $?)" "got=$(wdsecs_for 100)"
check 'watchdog sleep seconds: valid value without test mode retains production default 10' \
  "$([ "$(wdsecs_for 1 UNSET_MODE)" = 10 ]; echo $?)" "got=$(wdsecs_for 1 UNSET_MODE)"
check 'watchdog sleep seconds: valid value with wrong mode retains production default 10' \
  "$([ "$(wdsecs_for 1 not-ci-fixture)" = 10 ]; echo $?)" "got=$(wdsecs_for 1 not-ci-fixture)"
check 'watchdog sleep seconds: valid minimum bound 1 is honored only in exact ci-fixture mode' \
  "$([ "$(wdsecs_for 1)" = 1 ]; echo $?)" "got=$(wdsecs_for 1)"
check 'watchdog sleep seconds: valid middle value 5 is honored' \
  "$([ "$(wdsecs_for 5)" = 5 ]; echo $?)" "got=$(wdsecs_for 5)"
check 'watchdog sleep seconds: valid maximum bound 10 is honored' \
  "$([ "$(wdsecs_for 10)" = 10 ]; echo $?)" "got=$(wdsecs_for 10)"

# CI wait optimization pass 4: source the real private library helpers in a fresh Bash
# process for each boundary. Both helpers are used only by the PR 924 TERM-ignoring fixture above.
tdsecs_for() { # $1 = timing value or UNSET; $2 = mode (defaults to the fixture token)
  local mode="${2:-ci-fixture}"
  if [ "$1" = UNSET ]; then
    if [ "$mode" = UNSET_MODE ]; then
      ( unset PRO_GATE_TEST_MODE PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS; bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_term_drain_secs" )
    else
      ( unset PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS; PRO_GATE_TEST_MODE="$mode" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_term_drain_secs" )
    fi
  elif [ "$mode" = UNSET_MODE ]; then
    ( unset PRO_GATE_TEST_MODE; PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS="$1" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_term_drain_secs" )
  else
    PRO_GATE_TEST_MODE="$mode" PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS="$1" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_term_drain_secs"
  fi
}
check 'watchdog TERM-drain seconds: unset retains production default 30' \
  "$([ "$(tdsecs_for UNSET)" = 30 ]; echo $?)" "got=$(tdsecs_for UNSET)"
check 'watchdog TERM-drain seconds: empty string retains production default 30' \
  "$([ "$(tdsecs_for '')" = 30 ]; echo $?)" "got=$(tdsecs_for '')"
check 'watchdog TERM-drain seconds: zero retains production default 30' \
  "$([ "$(tdsecs_for 0)" = 30 ]; echo $?)" "got=$(tdsecs_for 0)"
check 'watchdog TERM-drain seconds: negative retains production default 30' \
  "$([ "$(tdsecs_for -1)" = 30 ]; echo $?)" "got=$(tdsecs_for -1)"
check 'watchdog TERM-drain seconds: non-numeric retains production default 30' \
  "$([ "$(tdsecs_for abc)" = 30 ]; echo $?)" "got=$(tdsecs_for abc)"
check 'watchdog TERM-drain seconds: leading-zero form is rejected, retains default 30' \
  "$([ "$(tdsecs_for 007)" = 30 ]; echo $?)" "got=$(tdsecs_for 007)"
check 'watchdog TERM-drain seconds: above-bound 31 retains production default 30' \
  "$([ "$(tdsecs_for 31)" = 30 ]; echo $?)" "got=$(tdsecs_for 31)"
check 'watchdog TERM-drain seconds: three-digit value retains production default 30' \
  "$([ "$(tdsecs_for 100)" = 30 ]; echo $?)" "got=$(tdsecs_for 100)"
check 'watchdog TERM-drain seconds: valid value without test mode retains production default 30' \
  "$([ "$(tdsecs_for 1 UNSET_MODE)" = 30 ]; echo $?)" "got=$(tdsecs_for 1 UNSET_MODE)"
check 'watchdog TERM-drain seconds: valid value with wrong mode retains production default 30' \
  "$([ "$(tdsecs_for 1 not-ci-fixture)" = 30 ]; echo $?)" "got=$(tdsecs_for 1 not-ci-fixture)"
check 'watchdog TERM-drain seconds: valid minimum bound 1 is honored only in exact ci-fixture mode' \
  "$([ "$(tdsecs_for 1)" = 1 ]; echo $?)" "got=$(tdsecs_for 1)"
check 'watchdog TERM-drain seconds: valid mid-range value 15 is honored' \
  "$([ "$(tdsecs_for 15)" = 15 ]; echo $?)" "got=$(tdsecs_for 15)"
check 'watchdog TERM-drain seconds: valid maximum bound 30 is honored' \
  "$([ "$(tdsecs_for 30)" = 30 ]; echo $?)" "got=$(tdsecs_for 30)"

fssecs_for() { # $1 = timing value or UNSET; $2 = mode (defaults to the fixture token)
  local mode="${2:-ci-fixture}"
  if [ "$1" = UNSET ]; then
    if [ "$mode" = UNSET_MODE ]; then
      ( unset PRO_GATE_TEST_MODE PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS; bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_force_settle_secs" )
    else
      ( unset PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS; PRO_GATE_TEST_MODE="$mode" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_force_settle_secs" )
    fi
  elif [ "$mode" = UNSET_MODE ]; then
    ( unset PRO_GATE_TEST_MODE; PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS="$1" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_force_settle_secs" )
  else
    PRO_GATE_TEST_MODE="$mode" PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS="$1" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_test_watchdog_force_settle_secs"
  fi
}
check 'watchdog force-settle seconds: unset retains production default 5' \
  "$([ "$(fssecs_for UNSET)" = 5 ]; echo $?)" "got=$(fssecs_for UNSET)"
check 'watchdog force-settle seconds: empty string retains production default 5' \
  "$([ "$(fssecs_for '')" = 5 ]; echo $?)" "got=$(fssecs_for '')"
check 'watchdog force-settle seconds: zero retains production default 5' \
  "$([ "$(fssecs_for 0)" = 5 ]; echo $?)" "got=$(fssecs_for 0)"
check 'watchdog force-settle seconds: negative retains production default 5' \
  "$([ "$(fssecs_for -1)" = 5 ]; echo $?)" "got=$(fssecs_for -1)"
check 'watchdog force-settle seconds: non-numeric retains production default 5' \
  "$([ "$(fssecs_for abc)" = 5 ]; echo $?)" "got=$(fssecs_for abc)"
check 'watchdog force-settle seconds: leading-zero form is rejected, retains default 5' \
  "$([ "$(fssecs_for 007)" = 5 ]; echo $?)" "got=$(fssecs_for 007)"
check 'watchdog force-settle seconds: above-bound 6 retains production default 5' \
  "$([ "$(fssecs_for 6)" = 5 ]; echo $?)" "got=$(fssecs_for 6)"
check 'watchdog force-settle seconds: three-digit value retains production default 5' \
  "$([ "$(fssecs_for 100)" = 5 ]; echo $?)" "got=$(fssecs_for 100)"
check 'watchdog force-settle seconds: valid value without test mode retains production default 5' \
  "$([ "$(fssecs_for 1 UNSET_MODE)" = 5 ]; echo $?)" "got=$(fssecs_for 1 UNSET_MODE)"
check 'watchdog force-settle seconds: valid value with wrong mode retains production default 5' \
  "$([ "$(fssecs_for 1 not-ci-fixture)" = 5 ]; echo $?)" "got=$(fssecs_for 1 not-ci-fixture)"
check 'watchdog force-settle seconds: valid minimum bound 1 is honored only in exact ci-fixture mode' \
  "$([ "$(fssecs_for 1)" = 1 ]; echo $?)" "got=$(fssecs_for 1)"
check 'watchdog force-settle seconds: valid mid-range value 3 is honored' \
  "$([ "$(fssecs_for 3)" = 3 ]; echo $?)" "got=$(fssecs_for 3)"
check 'watchdog force-settle seconds: valid maximum bound 5 is honored' \
  "$([ "$(fssecs_for 5)" = 5 ]; echo $?)" "got=$(fssecs_for 5)"

# Oracle 0.18.0 records promptSubmitted=false before attachment completion and changes it only
# when Send is dispatched. Complete exact-session metadata plus the existing negative conversation
# proof is therefore positive no-submit evidence even though browser/upload lifecycle lines exist.
PRESUBMIT_HOME="$TDIR/home-prompt-presubmit"; PRESUBMIT_ORACLE="$TDIR/oracle-prompt-presubmit"
PRESUBMIT_REPO="$TDIR/presubmit-repo"; git init -q "$PRESUBMIT_REPO"; git -C "$PRESUBMIT_REPO" remote add origin https://github.com/acme/presubmit.git
PRESUBMIT_ATTEMPTS="$TDIR/prompt-presubmit-attempts"; mkdir -p "$PRESUBMIT_HOME" "$PRESUBMIT_ORACLE"; : > "$PRESUBMIT_ATTEMPTS"
RKEY_95='acme-presubmit.git-95'
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
env PRO_GATE_HOME="$PRESUBMIT_HOME" ORACLE_HOME_DIR="$PRESUBMIT_ORACLE" ORACLE_BROWSER_PORT="$PORT" \
  PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 \
  PRO_GATE_MAX_RETRIES=0 PRO_GATE_RETRY_BACKOFF=0 PRO_GATE_REATTACH_TIMEOUT=1 PRO_GATE_SALVAGE_SECS=2 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-commit-timeout" PG_TEST_ATTEMPTS_FILE="$PRESUBMIT_ATTEMPTS" \
  PG_TEST_COMMIT_MODE=pre-submit NODE_OPTIONS= bash "$ENGINE" --pr 95 --repo "$PRESUBMIT_REPO" \
  --diff "$TDIR/small.diff" --out "$PRESUBMIT_HOME/o-presubmit.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
PRESUBMIT_MARKER="$(jq -r .marker "$PRESUBMIT_HOME/o-presubmit.md.status" 2>/dev/null)"
check 'structured pre-submit failure exits 6 without a duplicate retry' \
  "$([ "$RC" -eq 6 ] && [ "$(cat "$PRESUBMIT_ATTEMPTS")" = 1 ]; echo $?)" "rc=$RC attempts=$(cat "$PRESUBMIT_ATTEMPTS")"
check 'structured promptSubmitted=false proof refunds the round exactly once' \
  "$([ ! -s "$PRESUBMIT_HOME/rounds/$RKEY_95" ] && [ -s "$PRESUBMIT_HOME/attempt-dispositions/$PRESUBMIT_MARKER" ] \
     && jq -e '.terminal_kind=="not-submitted" and .proof_kind=="proven-no-submit"' "$PRESUBMIT_HOME/attempt-dispositions/$PRESUBMIT_MARKER" >/dev/null 2>&1; echo $?)" \
  "marker=$PRESUBMIT_MARKER dispositions=$(find "$PRESUBMIT_HOME/attempt-dispositions" -type f -printf '%f ' 2>/dev/null) disposition=$(cat "$PRESUBMIT_HOME/attempt-dispositions/$PRESUBMIT_MARKER" 2>/dev/null) rounds=$(cat "$PRESUBMIT_HOME/rounds/$RKEY_95" 2>/dev/null) stderr=$(tail -8 "$TDIR/stderr")"
check 'structured pre-submit terminalization removes mutable recovery state' \
  "$([ ! -e "$PRESUBMIT_HOME/run-meta/$PRESUBMIT_MARKER" ] && [ ! -e "$PRESUBMIT_HOME/active/$RKEY_95" ]; echo $?)" \
  "run-meta=$(find "$PRESUBMIT_HOME/run-meta" -type f 2>/dev/null) active=$(find "$PRESUBMIT_HOME/active" -type f 2>/dev/null)"

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

# v0.39: --brief swaps the TASK BODY only; the contract footer stays engine-owned. The whole
# return path is review-shaped — pg_is_review accepts a capture only when it carries a [Pn]
# marker AND one of exactly three verdict tokens, and cdp-salvage bounds extraction at the
# VERDICT line — so a brief able to suppress that footer would leave a conversation that never
# reaches terminal state and pins its reservation (the #131/#109 zombie shape). Both halves are
# pinned below: the brief IS substituted, and the footer SURVIVES it.
echo '# v0.39: --brief custom task body with engine-owned contract footer'
printf 'UNIQUE_BRIEF_BODY_MARKER\nYou are a database migration risk analyst. Assess rollback safety and lock duration.\n' > "$TDIR/brief-src.md"
: > "$TDIR/argv-brief.txt"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
# --brief is diff-only by construction (it is refused with --pr, see below), so the round it
# spends lands on a diff-derived identity. A round is an APPENDED EPOCH LINE in a per-key file,
# so count lines across the rounds dir, not files: an earlier test in this same home already
# created the file for this diff identity, and a file-count assertion reported no change while
# the round was in fact charged.
BRIEF_ROUNDS_BEFORE="$(cat "$RHOME"/rounds/* 2>/dev/null | wc -l)"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-evidence" PG_TEST_ARGV_FILE="$TDIR/argv-brief.txt" \
  PG_TEST_EVIDENCE= NODE_OPTIONS= \
  bash "$ENGINE" --repo "$TDIR" --diff "$TDIR/small.diff" \
  --brief "$TDIR/brief-src.md" --out "$RHOME/o-brief.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'brief run exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
check 'brief body is substituted into the prompt' \
  "$(grep -qF 'UNIQUE_BRIEF_BODY_MARKER' "$TDIR/argv-brief.txt"; echo $?)" 'brief body missing from oracle argv'
check 'brief REPLACES the built-in reviewer persona' \
  "$(grep -qF 'You are the FINAL, highest-tier code reviewer' "$TDIR/argv-brief.txt" && echo 1 || echo 0)" \
  'default persona still present alongside the brief'
check 'brief keeps the engine OUTPUT FORMAT contract' \
  "$(grep -qF 'OUTPUT FORMAT' "$TDIR/argv-brief.txt"; echo $?)" 'contract footer lost under --brief'
check 'brief keeps the closed verdict vocabulary' \
  "$(grep -qF 'VERDICT: SHIP | FIX-FIRST | NEEDS-DISCUSSION' "$TDIR/argv-brief.txt"; echo $?)" \
  'verdict vocabulary lost under --brief'
check 'brief keeps the run-marker provenance footer' \
  "$(grep -qF 'run marker:' "$TDIR/argv-brief.txt"; echo $?)" 'run marker lost under --brief'
# A brief spends a real Pro slot, so it is budget-accounted like any other run: pg_round_guard is
# charged on the dispatch path, well before the prompt is assembled, so --brief cannot influence
# it. Pinned here rather than left to prose because it has a consequence — a brief composed onto a
# --pr target spends THAT PR's per-change round budget and feeds its trajectory governor. Callers
# who want an analysis to keep its own budget pass --diff without --pr, forking the identity.
check 'brief run is budget-accounted (spends a round on the change identity)' \
  "$([ "$(cat "$RHOME"/rounds/* 2>/dev/null | wc -l)" -gt "$BRIEF_ROUNDS_BEFORE" ]; echo $?)" \
  "before=$BRIEF_ROUNDS_BEFORE after=$(cat "$RHOME"/rounds/* 2>/dev/null | wc -l)"
# The footer instruction that keeps an ambiguous brief from ending the turn with a question and no
# verdict — a completed-but-unparseable answer holds its reservation until recovery (#138 r2).
check 'brief footer forbids a clarifying question and pins one turn' \
  "$(grep -qF 'do NOT ask a clarifying question' "$TDIR/argv-brief.txt"; echo $?)" \
  'one-turn / no-clarifying-question instruction missing under --brief'
# Every --brief rejection must land BEFORE a slot is committed, so each is an exit-2 usage error.
# Each guard asserts its OWN message, not just exit 2: --brief now has several exit-2 paths and
# the --pr refusal below fires before the file checks, so an rc-only assertion would pass
# vacuously for the wrong reason if a case were mis-specified.
run_engine --brief /nonexistent-brief.md --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-bbad.md" --timeout 5s
check 'missing --brief file is a usage error (exit 2)' \
  "$([ "$RC" -eq 2 ] && grep -qF 'brief file not found' "$TDIR/stderr"; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
: > "$TDIR/brief-empty.md"
run_engine --brief "$TDIR/brief-empty.md" --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-bempty.md" --timeout 5s
check 'empty --brief file is a usage error (exit 2)' \
  "$([ "$RC" -eq 2 ] && grep -qF 'brief file is empty' "$TDIR/stderr"; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
head -c 70000 /dev/zero | tr '\0' 'x' > "$TDIR/brief-big.md"
run_engine --brief "$TDIR/brief-big.md" --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-bbig.md" --timeout 5s
check 'oversized --brief refused before any slot work (exit 2)' \
  "$([ "$RC" -eq 2 ] && grep -q '65536' "$TDIR/stderr"; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
# #138 finding 3: a brief must never occupy a PR's change identity, or it would spend that PR's
# round budget, serialize against the real review, and be selectable by --recover <PR> in its
# place. Refused outright rather than documented as guidance.
run_engine --brief "$TDIR/brief-src.md" --pr 102 --repo "$TDIR" --diff "$TDIR/small.diff" --out "$RHOME/o-bpr.md" --timeout 5s
check '--brief with --pr is refused (cannot occupy the canonical review identity)' \
  "$([ "$RC" -eq 2 ] && grep -qF 'cannot be combined with --pr' "$TDIR/stderr"; echo $?)" "rc=$RC $(tail -1 "$TDIR/stderr")"
# Lifecycle commands replay a stored prompt, so a brief there would silently do nothing.
run_engine --status --brief "$TDIR/brief-src.md"
check '--brief on --status is a usage error (exit 2)' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC"
run_engine --harvest pg-run-brief-x --brief "$TDIR/brief-src.md"
check '--brief on --harvest is a usage error (exit 2)' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC"
run_engine --recover 123 --brief "$TDIR/brief-src.md"
check '--brief on --recover is a usage error (exit 2)' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC"

echo '# v0.22.1: Cloudflare (provably-unsubmitted) refunds its round'
CF_REPO="$TDIR/cloudflare-repo"; git init -q "$CF_REPO"
git -C "$CF_REPO" remote add origin https://github.com/acme/widgets.git
CF_PRIOR='pg-run-acme-widgets-103-1700008500-1'
mkdir -p "$RHOME/completed" "$RHOME/run-meta"
printf '[P1] src/prior.sh:1 - prior charged review\n  Why: recovery must keep it\nP2: none\nP3: none\nVERDICT: SHIP - prior.\n' > "$RHOME/completed/$CF_PRIOR"
printf 'github.com\tacme\twidgets\tacme-widgets-103\t103\t%s\t1700008500\n' "$RHOME/prior-103.md" > "$RHOME/run-meta/$CF_PRIOR"
cat > "$TDIR/bin/oracle-cf" <<'FAKE_CF'
#!/usr/bin/env bash
echo 'Cloudflare anti-bot page detected'
exit 1
FAKE_CF
chmod +x "$TDIR/bin/oracle-cf"
RKEY_103='acme-widgets-103'
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
: > "$TDIR/mock.log"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RAMP=0 PRO_GATE_RECONCILE_INTERVAL=3600 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-cf" NODE_OPTIONS= \
  PRO_GATE_TIMEOUT_BIN="$TIMEOUT_LOG_BIN" PG_TEST_NODE_ARGS="$TDIR/node-args-cloudflare.log" \
  bash "$ENGINE" --pr 103 --repo "$CF_REPO" --diff "$TDIR/small.diff" --out "$RHOME/o-cf.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'cloudflare run fails without a usable review' "$([ "$RC" -eq 6 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
# #143: cloudflare keeps its own `outcome`, so the reason field stays empty — reason is
# failed-only by construction, and this proves a non-`failed` exit-6 row does not get one.
CF_ROW="$(grep -F "\"out\":\"$RHOME/o-cf.md\"" "$RHOME/ledger.jsonl" | tail -1)"
check '#143 cloudflare row keeps outcome=cloudflare with an empty reason' \
  "$([ "$(printf '%s' "$CF_ROW" | jq -r .outcome)" = cloudflare ] && [ "$(printf '%s' "$CF_ROW" | jq -r '.reason // "MISSING"')" = "" ]; echo $?)" "$CF_ROW"
check 'cloudflare writes the account cooldown' "$([ -f "$RHOME/throttle.cooldown" ]; echo $?)" 'no cooldown file'
check 'cloudflare refunds the round (no spend, no budget charge)' "$([ ! -f "$RHOME/rounds/$RKEY_103" ]; echo $?)" "rounds file: $(cat "$RHOME/rounds/$RKEY_103" 2>/dev/null)"
CF_META_MATCHES="$(PRO_GATE_HOME="$RHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_run_meta_scan" \
  | awk -F'\t' '$2 == "github.com" && $3 == "acme" && $4 == "widgets" && $6 == "103" {print $1}')"
check 'cloudflare refund retires the unsubmitted run metadata' \
  "$([ "$CF_META_MATCHES" = "$CF_PRIOR" ] && [ -f "$RHOME/run-meta/$CF_PRIOR" ]; echo $?)" \
  "canonical metadata=$CF_META_MATCHES"
env PRO_GATE_HOME="$RHOME" ORACLE_BROWSER_PORT=65530 PRO_GATE_SELF_HEAL=0 NODE_OPTIONS= \
  bash "$ENGINE" --recover 'https://github.com/acme/widgets/pull/103' --out "$RHOME/recovered-prior-103.md" \
  >"$TDIR/stdout" 2>"$TDIR/recover.stderr"
RC=$?
check 'recover selects the newer refunded attempt instead of returning an older artifact' \
  "$([ "$RC" -eq 6 ] && [ ! -s "$TDIR/stdout" ] && grep -qx 'No review remains' "$TDIR/recover.stderr"; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
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
# Round scoring remains visible, but ordinary unset configuration is advisory.
check '--status reports spent rounds and advisory computed grant' \
  "$(grep -q '2 spent, policy=advisory (source default), computed grant 3 is advisory' "$TDIR/st.out"; echo $?)" "$(grep spent "$TDIR/st.out")"
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
check '--status warns against REQUIRE_NONCE=0 on a cross-bind' "$(grep -q 'PRO_GATE_REQUIRE_NONCE=0' "$TDIR/st-stuck.out" && grep -q 'Do NOT' "$TDIR/st-stuck.out"; echo $?)" "$(grep -i 'nonce' "$TDIR/st-stuck.out")"
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
PRO_GATE_HOME="$MHOME" PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$MMARK' >/dev/null"
check 'note_miss preserves the spend epoch (field 7)' \
  "$([ "$(PRO_GATE_HOME="$MHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_read_spend '$MMARK'")" = 1700005555 ]; echo $?)" \
  "record: $(tr '\t' '|' < "$MHOME/in-progress/$MMARK")"
check 'note_miss preserves the model too' \
  "$([ "$(PRO_GATE_HOME="$MHOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_read_model '$MMARK'")" = GPT-X ]; echo $?)" \
  "record: $(tr '\t' '|' < "$MHOME/in-progress/$MMARK")"
check 'note_miss still incremented the streak' \
  "$([ "$(awk -F'\t' 'NR==1{print $4}' "$MHOME/in-progress/$MMARK")" = 1 ]; echo $?)" \
  "record: $(tr '\t' '|' < "$MHOME/in-progress/$MMARK")"

# TTL is a precondition for bounded recovery exhaustion, never terminal proof by itself. Harvest
# and reconciliation retain past-TTL reservations until confirmed marker misses can bind a terminal
# disposition to canonical charged run metadata.
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
check 'harvest retains other past-TTL reservations without confirmed miss proof' \
  "$([ -f "$THOME/in-progress/$OTHER_STALE" ]; echo $?)" "$(ls "$THOME/in-progress" 2>/dev/null)"
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
  # Once the claim is released, elapsed time alone still cannot terminalize the attempt.
  CLAIMED_RC="$(PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_harvest_claimed '$CLAIMED' && echo held || echo free")"
  check 'a released lock reads as unclaimed' "$([ "$CLAIMED_RC" = free ]; echo $?)" "got=$CLAIMED_RC"
  PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; PG_RES_TTL_ONLY=1 pg_reservation_reconcile '' 9222" >/dev/null 2>&1
  check 'an unclaimed past-TTL reservation remains without confirmed miss proof' \
    "$([ -f "$THOME/in-progress/$CLAIMED" ]; echo $?)" "$(ls "$THOME/in-progress" 2>/dev/null)"
fi
# #68 gate r3 P1: the TARGET's own expiry. Reconcilers skip claimed markers, so the collector
# must decide its own target's fate post-capture — otherwise the one marker #67 exists for can
# never self-clear, and repeatedly following --status's advice loops forever.
EXPIRED_SELF="pg-run-selfkey-1700000007-93"
printf 'selfkey\t%s/o5.md\t%s\t0\t\t\t\n' "$THOME" "$(( $(date +%s) - 30000 ))" > "$THOME/in-progress/$EXPIRED_SELF"
check 'expire_if_stale reports past TTL without releasing the reservation' \
  "$([ "$(PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_expire_if_stale '$EXPIRED_SELF'")" = stale ] && [ -f "$THOME/in-progress/$EXPIRED_SELF" ]; echo $?)" \
  "$(ls "$THOME/in-progress" 2>/dev/null)"
FRESH_SELF="pg-run-selfkey-1700000008-94"
printf 'selfkey\t%s/o6.md\t%s\t0\t\t\t\n' "$THOME" "$(date +%s)" > "$THOME/in-progress/$FRESH_SELF"
check 'expire_if_stale keeps an unexpired reservation' \
  "$([ -z "$(PRO_GATE_HOME="$THOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_expire_if_stale '$FRESH_SELF'")" ] && [ -f "$THOME/in-progress/$FRESH_SELF" ]; echo $?)" \
  "$(ls "$THOME/in-progress" 2>/dev/null)"

EARLY_HOME="$TDIR/home-recovery-too-early"; EARLY_KEY=acme-early-95
EARLY_MARKER='pg-run-acme-early-95-1700000009-95'; EARLY_EPOCH=1700000009
mkdir -p "$EARLY_HOME/in-progress" "$EARLY_HOME/run-meta" "$EARLY_HOME/rounds"
printf '%s\n' "$EARLY_EPOCH" > "$EARLY_HOME/rounds/$EARLY_KEY"
printf 'github.com\tacme\tearly\t%s\t95\t/tmp/early.md\t%s\n' "$EARLY_KEY" "$EARLY_EPOCH" > "$EARLY_HOME/run-meta/$EARLY_MARKER"
printf '%s\t/tmp/early.md\t%s\t0\t\t\t%s\n' "$EARLY_KEY" "$(date +%s)" "$EARLY_EPOCH" > "$EARLY_HOME/in-progress/$EARLY_MARKER"
for _ in 1 2 3; do EARLY_RESULT="$(PRO_GATE_HOME="$EARLY_HOME" PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$EARLY_MARKER'")"; done
check 'confirmed miss threshold before TTL remains recoverable' \
  "$([ -f "$EARLY_HOME/in-progress/$EARLY_MARKER" ] && [ ! -e "$EARLY_HOME/attempt-dispositions/$EARLY_MARKER" ] && [ "$EARLY_RESULT" != released ]; echo $?)" \
  "result=$EARLY_RESULT record=$(cat "$EARLY_HOME/in-progress/$EARLY_MARKER" 2>/dev/null)"

EXHAUST_HOME="$TDIR/home-recovery-exhausted"; EXHAUST_KEY=acme-exhausted-96
EXHAUST_MARKER='pg-run-acme-exhausted-96-1700000010-96'; EXHAUST_EPOCH=1700000010
mkdir -p "$EXHAUST_HOME/in-progress" "$EXHAUST_HOME/run-meta" "$EXHAUST_HOME/rounds"
printf '%s\n' "$EXHAUST_EPOCH" > "$EXHAUST_HOME/rounds/$EXHAUST_KEY"
printf 'github.com\tacme\texhausted\t%s\t96\t/tmp/exhausted.md\t%s\n' "$EXHAUST_KEY" "$EXHAUST_EPOCH" > "$EXHAUST_HOME/run-meta/$EXHAUST_MARKER"
printf '%s\t/tmp/exhausted.md\t%s\t0\t\t\t%s\n' "$EXHAUST_KEY" "$(( $(date +%s) - 30000 ))" "$EXHAUST_EPOCH" > "$EXHAUST_HOME/in-progress/$EXHAUST_MARKER"
for _ in 1 2; do PRO_GATE_HOME="$EXHAUST_HOME" PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$EXHAUST_MARKER' >/dev/null"; done
EXHAUST_RESULT="$(PRO_GATE_HOME="$EXHAUST_HOME" PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$EXHAUST_MARKER'")"
check 'TTL plus confirmed miss threshold terminalizes recovery exhaustion' \
  "$([ "$EXHAUST_RESULT" = released ] && [ ! -e "$EXHAUST_HOME/in-progress/$EXHAUST_MARKER" ] \
     && [ ! -e "$EXHAUST_HOME/run-meta/$EXHAUST_MARKER" ] && [ -s "$EXHAUST_HOME/rounds/$EXHAUST_KEY" ] \
     && jq -e '.terminal_kind=="recovery-exhausted" and .proof_kind=="bounded-recovery-exhausted"' "$EXHAUST_HOME/attempt-dispositions/$EXHAUST_MARKER" >/dev/null 2>&1; echo $?)" \
  "result=$EXHAUST_RESULT disposition=$(cat "$EXHAUST_HOME/attempt-dispositions/$EXHAUST_MARKER" 2>/dev/null)"
EXHAUST_SNAPSHOT="$(PRO_GATE_HOME="$EXHAUST_HOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_attempt_snapshot github.com acme exhausted 96 '$EXHAUST_KEY'")"
check 'recovery-exhausted snapshot is fresh eligible without refund' \
  "$(jq -e '.source=="disposition" and .state=="recovery-exhausted" and .fresh_eligible and (.recoverable|not) and .charged_spend_epoch==1700000010' <<<"$EXHAUST_SNAPSHOT" >/dev/null 2>&1; echo $?)" \
  "$EXHAUST_SNAPSHOT"

PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 --json >"$TDIR/st.json" 2>/dev/null; RC=$?
check '--status --json exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC"
check '--status --json reservation marker' "$([ "$(jq -r '.reservations[0].marker' "$TDIR/st.json")" = "$SMARKER" ]; echo $?)" "$(cat "$TDIR/st.json")"
check '--status --json remembered url' "$([ "$(jq -r '.reservations[0].conversation_url' "$TDIR/st.json")" = "https://chatgpt.com/c/abc123" ]; echo $?)" "$(jq -c .reservations "$TDIR/st.json")"
check '--status --json rounds remaining' "$([ "$(jq -r '.rounds[0].remaining' "$TDIR/st.json")" = 1 ] && [ "$(jq -r '.rounds[0].cap' "$TDIR/st.json")" = 3 ]; echo $?)" "$(jq -c .rounds "$TDIR/st.json")"
check '--status --json reports default round policy as advisory' \
  "$([ "$(jq -r '.rounds[0].policy' "$TDIR/st.json")" = advisory ] && [ "$(jq -r '.rounds[0].policy_source' "$TDIR/st.json")" = default ] && [ "$(jq -r '.rounds[0].enforced' "$TDIR/st.json")" = false ]; echo $?)" \
  "$(jq -c .rounds "$TDIR/st.json")"
PRO_GATE_ROUND_GUARD=1 PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 --json >"$TDIR/st-enforced.json" 2>/dev/null
check '--status --json reports explicit round policy as enforced' \
  "$([ "$(jq -r '.rounds[0].policy' "$TDIR/st-enforced.json")" = enforced ] && [ "$(jq -r '.rounds[0].policy_source' "$TDIR/st-enforced.json")" = PRO_GATE_ROUND_GUARD ] && [ "$(jq -r '.rounds[0].enforced' "$TDIR/st-enforced.json")" = true ]; echo $?)" \
  "$(jq -c .rounds "$TDIR/st-enforced.json")"
# #66 gate P2: --status must expose the scored trajectory, not just the numbers.
printf '%s\tFIX-FIRST\t0\t5\t0\t0\n%s\tFIX-FIRST\t0\t7\t0\t0\n%s\tFIX-FIRST\t0\t8\t0\t0\n' \
  "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$SHOME/rounds/acme-widgets-42.hist"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 --json >"$TDIR/st2.json" 2>/dev/null
check '--status --json exposes the trajectory' "$([ "$(jq -r '.rounds[0].trajectory' "$TDIR/st2.json")" = '5→7→8' ]; echo $?)" "$(jq -c .rounds "$TDIR/st2.json")"
check '--status --json flags the churn brake' "$([ "$(jq -r '.rounds[0].churn_braked' "$TDIR/st2.json")" = true ]; echo $?)" "$(jq -c .rounds "$TDIR/st2.json")"
PRO_GATE_HOME="$SHOME" bash "$ENGINE" --status 42 >"$TDIR/st2.out" 2>/dev/null
check '--status text names advisory churn without calling it a hard brake' "$(grep -q 'CHURN: not converging' "$TDIR/st2.out" && ! grep -q 'CHURN BRAKE' "$TDIR/st2.out"; echo $?)" "$(grep -i 'spent' "$TDIR/st2.out")"
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
check 'native dead wrapper avoids the harvest loop' "$(grep -q 'no marker-addressed harvest path' "$TDIR/st11.out" && ! grep -q -- "--harvest '$SMARKER'" "$TDIR/st11.out"; echo $?)" "$(tail -2 "$TDIR/st11.out")"
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

# U3: --recover is a recovery-only resolver. Its public seam is the engine CLI: no fresh
# dispatch machinery may run before one marker is selected from durable, marker-addressed state.
echo '# U3: recovery-only resolver and no-spend control flow'
REC_HOME="$TDIR/home-recover"
REC_MARKER='pg-run-acme-widgets-42-1700001000-11'
REC_ART="$REC_HOME/completed/$REC_MARKER"
mkdir -p "$REC_HOME/completed" "$REC_HOME/run-meta"
printf '[P1] src/recover.sh:1 - recovered finding\n  Why: durable fixture\nP2: none\nP3: none\nVERDICT: SHIP - recovered.\n' > "$REC_ART"
printf 'github.com\tacme\twidgets\tacme-widgets-42\t42\t%s\t1700002000\n' "$TDIR/recover-original.md" > "$REC_HOME/run-meta/$REC_MARKER"
: > "$TDIR/recover-oracle-sentinel"
cat > "$TDIR/bin/oracle-recover-sentinel" <<'RECOVER_SENTINEL'
#!/usr/bin/env bash
printf 'invoked\n' >> "${PG_TEST_RECOVER_ORACLE_SENTINEL:?}"
printf 'RECOVER FRESH DISPATCH FORBIDDEN\n' >&2
exit 99
RECOVER_SENTINEL
chmod +x "$TDIR/bin/oracle-recover-sentinel"
recover_run() { # home, then engine args; CDP deliberately unavailable unless harvest is expected
  local home="$1"; shift
  env PRO_GATE_HOME="$home" ORACLE_BROWSER_PORT=65530 PRO_GATE_SELF_HEAL=0 \
    PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" \
    PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
    bash "$ENGINE" "$@" >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
  RC=$?
}
REC_BEFORE="$(find "$REC_HOME" -mindepth 1 -maxdepth 2 -type f -printf '%P:%s\n' | sort)"
recover_run "$REC_HOME" --recover "$REC_MARKER" --out "$TDIR/recover-out.md" --timeout 1s
REC_AFTER="$(find "$REC_HOME" -mindepth 1 -maxdepth 2 -type f -printf '%P:%s\n' | sort)"
check 'recover exact marker returns durable artifact with CDP and Oracle unavailable' \
  "$([ "$RC" -eq 0 ] && cmp -s "$REC_ART" "$TDIR/recover.stdout" && cmp -s "$REC_ART" "$TDIR/recover-out.md"; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(cat "$TDIR/recover.stderr")"
check 'recover exact artifact prints Review ready only on stderr' \
  "$(grep -qx 'Review ready' "$TDIR/recover.stderr"; echo $?)" "stderr=$(cat "$TDIR/recover.stderr")"
check 'recover artifact fast path has no fresh dispatch, status, ledger, round, reservation, or organizer effects' \
  "$([ ! -s "$TDIR/recover-oracle-sentinel" ] && [ "$REC_BEFORE" = "$REC_AFTER" ] && [ ! -e "$TDIR/recover-out.md.status" ]; echo $?)" \
  "oracle=$(cat "$TDIR/recover-oracle-sentinel") before=$REC_BEFORE after=$REC_AFTER"

# v0.37.1 upgrade: canonical run-meta from older runtimes may have no reservation, so no miss
# counter can advance. One no-spend recover call restores ownership from the original charge and
# consumes the existing TTL+confirmed-miss proof without launching Oracle or refunding the round.
LEGACY_HOME="$TDIR/home-legacy-runmeta"; LEGACY_KEY=acme-widgets-43
LEGACY_MARKER='pg-run-acme-widgets-43-1700001001-13'; LEGACY_EPOCH=1700001001
mkdir -p "$LEGACY_HOME/run-meta" "$LEGACY_HOME/rounds"
printf '%s\n' "$LEGACY_EPOCH" > "$LEGACY_HOME/rounds/$LEGACY_KEY"
printf 'github.com\tacme\twidgets\t%s\t43\t%s\t%s\n' "$LEGACY_KEY" "$TDIR/legacy-recover.md" "$LEGACY_EPOCH" > "$LEGACY_HOME/run-meta/$LEGACY_MARKER"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"; start_mock "$TDIR/tab.txt"
: > "$TDIR/recover-oracle-sentinel"
env PRO_GATE_HOME="$LEGACY_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_RESERVATION_MISSES=2 PRO_GATE_RECONCILE_INTERVAL=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" \
  PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  bash "$ENGINE" --recover "$LEGACY_MARKER" >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?
check 'legacy run-meta recovery terminalizes in one no-spend invocation after bounded misses' \
  "$([ "$RC" -eq 6 ] && grep -qx 'No review remains' "$TDIR/recover.stderr" && [ ! -s "$TDIR/recover-oracle-sentinel" ] \
     && [ ! -e "$LEGACY_HOME/in-progress/$LEGACY_MARKER" ] && [ ! -e "$LEGACY_HOME/run-meta/$LEGACY_MARKER" ] \
     && [ -s "$LEGACY_HOME/rounds/$LEGACY_KEY" ] && jq -e '.terminal_kind=="recovery-exhausted"' "$LEGACY_HOME/attempt-dispositions/$LEGACY_MARKER" >/dev/null 2>&1; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/recover.stderr") disposition=$(cat "$LEGACY_HOME/attempt-dispositions/$LEGACY_MARKER" 2>/dev/null)"

LEGACY_FUTURE_HOME="$TDIR/home-legacy-future"; LEGACY_FUTURE_KEY=acme-widgets-44
LEGACY_FUTURE_MARKER='pg-run-acme-widgets-44-9999999999-14'; LEGACY_FUTURE_EPOCH=9999999999
mkdir -p "$LEGACY_FUTURE_HOME/run-meta"
printf 'github.com\tacme\twidgets\t%s\t44\t%s\t%s\n' "$LEGACY_FUTURE_KEY" "$TDIR/future.md" "$LEGACY_FUTURE_EPOCH" > "$LEGACY_FUTURE_HOME/run-meta/$LEGACY_FUTURE_MARKER"
RESTORE_FUTURE="$(PRO_GATE_HOME="$LEGACY_FUTURE_HOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_restore_from_meta '$LEGACY_FUTURE_MARKER'")"
check 'legacy restore preserves a future recorded charge epoch as creation time' \
  "$([ "$RESTORE_FUTURE" = created ] && [ "$(awk -F'\t' 'NR==1{print $3" "$7}' "$LEGACY_FUTURE_HOME/in-progress/$LEGACY_FUTURE_MARKER")" = "$LEGACY_FUTURE_EPOCH $LEGACY_FUTURE_EPOCH" ]; echo $?)" \
  "record=$(cat "$LEGACY_FUTURE_HOME/in-progress/$LEGACY_FUTURE_MARKER" 2>/dev/null)"
FUTURE_MISS="$(PRO_GATE_HOME="$LEGACY_FUTURE_HOME" PRO_GATE_RECONCILE_INTERVAL=0 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$LEGACY_FUTURE_MARKER'")"
check 'future charge epoch cannot terminalize before local time catches up plus TTL' \
  "$([ "$FUTURE_MISS" != released ] && [ -f "$LEGACY_FUTURE_HOME/in-progress/$LEGACY_FUTURE_MARKER" ] && [ ! -e "$LEGACY_FUTURE_HOME/attempt-dispositions/$LEGACY_FUTURE_MARKER" ]; echo $?)" \
  "result=$FUTURE_MISS"

LEGACY_LINK_HOME="$TDIR/home-legacy-link"; LEGACY_LINK_KEY=acme-widgets-45
LEGACY_LINK_MARKER='pg-run-acme-widgets-45-1700001002-15'; LEGACY_LINK_TARGET="$TDIR/legacy-link-target"
mkdir -p "$LEGACY_LINK_HOME/run-meta" "$LEGACY_LINK_HOME/in-progress"; printf 'sentinel\n' > "$LEGACY_LINK_TARGET"
printf 'github.com\tacme\twidgets\t%s\t45\t%s\t1700001002\n' "$LEGACY_LINK_KEY" "$TDIR/link.md" > "$LEGACY_LINK_HOME/run-meta/$LEGACY_LINK_MARKER"
ln -s "$LEGACY_LINK_TARGET" "$LEGACY_LINK_HOME/in-progress/$LEGACY_LINK_MARKER"
PRO_GATE_HOME="$LEGACY_LINK_HOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_restore_from_meta '$LEGACY_LINK_MARKER'" >/dev/null 2>&1; LINK_RC=$?
check 'legacy restore refuses a symlinked reservation without touching its target' \
  "$([ "$LINK_RC" -ne 0 ] && [ "$(cat "$LEGACY_LINK_TARGET")" = sentinel ]; echo $?)" \
  "rc=$LINK_RC target=$(cat "$LEGACY_LINK_TARGET")"

LEGACY_RACE_HOME="$TDIR/home-legacy-race"; LEGACY_RACE_KEY=acme-widgets-46
LEGACY_RACE_MARKER='pg-run-acme-widgets-46-1700001003-16'; mkdir -p "$LEGACY_RACE_HOME/run-meta"
printf 'github.com\tacme\twidgets\t%s\t46\t%s\t1700001003\n' "$LEGACY_RACE_KEY" "$TDIR/race.md" > "$LEGACY_RACE_HOME/run-meta/$LEGACY_RACE_MARKER"
PRO_GATE_HOME="$LEGACY_RACE_HOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_restore_from_meta '$LEGACY_RACE_MARKER'" > "$TDIR/restore-a" & RPA=$!
PRO_GATE_HOME="$LEGACY_RACE_HOME" bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_restore_from_meta '$LEGACY_RACE_MARKER'" > "$TDIR/restore-b" & RPB=$!
wait "$RPA"; wait "$RPB"
check 'concurrent legacy restore has exactly one creator and one idempotent observer' \
  "$([ "$(sort "$TDIR/restore-a" "$TDIR/restore-b" | tr '\n' ' ')" = 'created existing ' ]; echo $?)" \
  "a=$(cat "$TDIR/restore-a") b=$(cat "$TDIR/restore-b")"
touch -t 202001010000 "$LEGACY_RACE_HOME/in-progress/$LEGACY_RACE_MARKER"
PRO_GATE_HOME="$LEGACY_RACE_HOME" PRO_GATE_RECONCILE_INTERVAL=60 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$LEGACY_RACE_MARKER'" > "$TDIR/miss-a" & MPA=$!
PRO_GATE_HOME="$LEGACY_RACE_HOME" PRO_GATE_RECONCILE_INTERVAL=60 bash -c ". '$HERE/../lib/pro-gate-lib.sh'; pg_reservation_note_miss '$LEGACY_RACE_MARKER'" > "$TDIR/miss-b" & MPB=$!
wait "$MPA"; wait "$MPB"
check 'concurrent miss calls increment at most once inside one reconcile interval' \
  "$([ "$(awk -F'\t' 'NR==1{print $4}' "$LEGACY_RACE_HOME/in-progress/$LEGACY_RACE_MARKER")" = 1 ]; echo $?)" \
  "record=$(cat "$LEGACY_RACE_HOME/in-progress/$LEGACY_RACE_MARKER") a=$(cat "$TDIR/miss-a") b=$(cat "$TDIR/miss-b")"

# Marker-addressed recovery never follows a completed/pending symlink, even when its target contains
# structurally valid review bytes. The lifecycle selector and exact recovery fast path must agree.
for REC_LINK_STORE in completed pending; do
  REC_LINK_HOME="$TDIR/home-recover-link-$REC_LINK_STORE"
  REC_LINK_MARKER="pg-run-acme-widgets-43-1700001001-${REC_LINK_STORE#?}"
  REC_LINK_TARGET="$TDIR/recover-link-$REC_LINK_STORE.md"
  mkdir -p "$REC_LINK_HOME/$REC_LINK_STORE" "$REC_LINK_HOME/run-meta"
  printf '[P1] src/link.sh:1 - symlink target\n  Why: unrelated bytes\nP2: none\nP3: none\nVERDICT: SHIP - linked.\n' > "$REC_LINK_TARGET"
  ln -s "$REC_LINK_TARGET" "$REC_LINK_HOME/$REC_LINK_STORE/$REC_LINK_MARKER"
  printf 'github.com\tacme\twidgets\tacme-widgets-43\t43\t%s\t1700002001\n' "$TDIR/recover-link-out.md" > "$REC_LINK_HOME/run-meta/$REC_LINK_MARKER"
  recover_run "$REC_LINK_HOME" --recover "$REC_LINK_MARKER" --timeout 1s
  check "recover exact marker refuses a $REC_LINK_STORE symlink instead of returning its target" \
    "$([ "$RC" -ne 0 ] && ! grep -qF 'symlink target' "$TDIR/recover.stdout" && ! grep -qF 'Review ready' "$TDIR/recover.stderr"; echo $?)" \
    "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(cat "$TDIR/recover.stderr")"
done

# Repo-qualified URL and a current-repo --repo bare PR both resolve one newest durable candidate.
REC_NEW='pg-run-acme-widgets-42-1700000001-12'
printf '[P1] src/new.sh:1 - newer finding\n  Why: newest fixture\nP2: none\nP3: none\nVERDICT: SHIP - newer.\n' > "$REC_HOME/completed/$REC_NEW"
printf 'github.com\tacme\twidgets\tacme-widgets-42\t42\t%s\t1700003000\n' "$TDIR/recover-new.md" > "$REC_HOME/run-meta/$REC_NEW"
recover_run "$REC_HOME" --recover 'https://github.com/acme/widgets/pull/42' --out "$TDIR/recover-url.md"
check 'recover repo-qualified URL selects newest charged run before artifact lookup' \
  "$([ "$RC" -eq 0 ] && cmp -s "$REC_HOME/completed/$REC_NEW" "$TDIR/recover.stdout"; echo $?)" "rc=$RC stdout=$(cat "$TDIR/recover.stdout")"
# A repository remote is the only acceptable proof for a bare PR. The temporary fixture remote
# deliberately uses the exact host/owner/repo identity written above.
REC_REPO="$TDIR/recover-repo"; git init -q "$REC_REPO"
git -C "$REC_REPO" remote add origin https://github.com/acme/widgets.git
recover_run "$REC_HOME" --recover 42 --repo "$REC_REPO" --out "$TDIR/recover-bare.md"
check 'recover bare PR with current repository proof selects newest charged run' \
  "$([ "$RC" -eq 0 ] && cmp -s "$REC_HOME/completed/$REC_NEW" "$TDIR/recover.stdout"; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"

# A queued marker can be older than an earlier marker despite being charged later. Persisted
# pg_round_record spend wins after reservation retirement; marker epochs are legacy-only fallback.
REC_ORDER_HOME="$TDIR/home-recover-order"; mkdir -p "$REC_ORDER_HOME/completed" "$REC_ORDER_HOME/run-meta"
REC_OLD='pg-run-acme-widgets-77-1700009000-1'; REC_LATE='pg-run-acme-widgets-77-1700001000-2'
printf '[P1] old\n  Why: old\nP2: none\nP3: none\nVERDICT: SHIP - old.\n' > "$REC_ORDER_HOME/completed/$REC_OLD"
printf '[P1] late\n  Why: late\nP2: none\nP3: none\nVERDICT: SHIP - late.\n' > "$REC_ORDER_HOME/completed/$REC_LATE"
printf 'github.com\tacme\twidgets\tacme-widgets-77\t77\t/tmp/old.md\t1700009100\n' > "$REC_ORDER_HOME/run-meta/$REC_OLD"
printf 'github.com\tacme\twidgets\tacme-widgets-77\t77\t/tmp/late.md\t1700010000\n' > "$REC_ORDER_HOME/run-meta/$REC_LATE"
recover_run "$REC_ORDER_HOME" --recover 'https://github.com/acme/widgets/pull/77'
check 'recover orders completed runs by durable charged spend, not inverted marker epoch' \
  "$([ "$RC" -eq 0 ] && cmp -s "$REC_ORDER_HOME/completed/$REC_LATE" "$TDIR/recover.stdout"; echo $?)" "rc=$RC stdout=$(cat "$TDIR/recover.stdout")"

# Lossy legacy slugs and mixed/tied evidence are not identity proof. Refuse with no browser,
# harvest lock, or state mutation rather than selecting a colliding artifact.
REC_AMBIG_HOME="$TDIR/home-recover-ambiguous"; mkdir -p "$REC_AMBIG_HOME/completed" "$REC_AMBIG_HOME/run-meta"
REC_COLLIDE='pg-run-a-b-c-9-1700004000-1'
printf '[P1] collision\n  Why: never return\nP2: none\nP3: none\nVERDICT: SHIP - collision.\n' > "$REC_AMBIG_HOME/completed/$REC_COLLIDE"
# No run-meta: this legacy marker could name a-b/c#9 or a/b-c#9.
recover_run "$REC_AMBIG_HOME" --recover 'https://github.com/a-b/c/pull/9'
check 'recover refuses lossy legacy slug collision without canonical metadata proof' \
  "$([ "$RC" -ne 0 ] && grep -qi 'disambigu' "$TDIR/recover.stderr" && [ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
REC_TIE_A='pg-run-acme-widgets-88-1700005000-1'; REC_TIE_B='pg-run-acme-widgets-88-1700005001-2'
for m in "$REC_TIE_A" "$REC_TIE_B"; do
  printf '[P1] tie\n  Why: never choose\nP2: none\nP3: none\nVERDICT: SHIP - tie.\n' > "$REC_AMBIG_HOME/completed/$m"
  printf 'github.com\tacme\twidgets\tacme-widgets-88\t88\t/tmp/tie.md\t1700006000\n' > "$REC_AMBIG_HOME/run-meta/$m"
done
recover_run "$REC_AMBIG_HOME" --recover 'https://github.com/acme/widgets/pull/88'
check 'recover refuses tied durable charged-spend candidates' \
  "$([ "$RC" -ne 0 ] && grep -qi 'disambigu' "$TDIR/recover.stderr"; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"

# Artifact absence is the only recovery path allowed to enter existing marker harvest behavior;
# it keeps the prior exit while mapping its novice state and never invokes Oracle.
REC_HARV_HOME="$TDIR/home-recover-harvest"; REC_HARV='pg-run-acme-widgets-99-1700007000-1'
mkdir -p "$REC_HARV_HOME/in-progress" "$REC_HARV_HOME/run-meta"
printf 'acme-widgets-99\t%s\t%s\t0\t1\t\t1700008000\tgenerating\n' "$TDIR/recover-harvest.md" "$(date +%s)" > "$REC_HARV_HOME/in-progress/$REC_HARV"
printf 'github.com\tacme\twidgets\tacme-widgets-99\t99\t%s\t1700008000\n' "$TDIR/recover-harvest.md" > "$REC_HARV_HOME/run-meta/$REC_HARV"
: > "$TDIR/recover-oracle-sentinel"
recover_run "$REC_HARV_HOME" --recover 'https://github.com/acme/widgets/pull/99' --timeout 1s
check 'recover artifact absence enters harvest only and retains its operational exit' \
  "$([ "$RC" -eq 3 ] && grep -qx 'Browser needs attention' "$TDIR/recover.stderr" && [ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/recover.stderr") oracle=$(cat "$TDIR/recover-oracle-sentinel")"

# Newer live work outranks an old completed artifact. Metadata and reservation spend must agree;
# the absent new artifact is harvested instead of silently serving the old bytes.
REC_LIVE_HOME="$TDIR/home-recover-live"; REC_LIVE_OLD='pg-run-acme-widgets-101-1700008100-1'; REC_LIVE_NEW='pg-run-acme-widgets-101-1700008000-2'
mkdir -p "$REC_LIVE_HOME/completed" "$REC_LIVE_HOME/in-progress" "$REC_LIVE_HOME/run-meta"
printf '[P1] old artifact\n  Why: stale\nP2: none\nP3: none\nVERDICT: SHIP - old.\n' > "$REC_LIVE_HOME/completed/$REC_LIVE_OLD"
printf 'github.com\tacme\twidgets\tacme-widgets-101\t101\t/tmp/old.md\t1700008100\n' > "$REC_LIVE_HOME/run-meta/$REC_LIVE_OLD"
printf 'github.com\tacme\twidgets\tacme-widgets-101\t101\t/tmp/new.md\t1700008200\n' > "$REC_LIVE_HOME/run-meta/$REC_LIVE_NEW"
printf 'acme-widgets-101\t/tmp/new.md\t%s\t0\t1\t\t1700008200\tgenerating\n' "$(date +%s)" > "$REC_LIVE_HOME/in-progress/$REC_LIVE_NEW"
: > "$TDIR/recover-oracle-sentinel"
recover_run "$REC_LIVE_HOME" --recover 'https://github.com/acme/widgets/pull/101' --timeout 1s
check 'recover targets newer live run before older completed artifact' \
  "$([ "$RC" -eq 3 ] && ! cmp -s "$REC_LIVE_HOME/completed/$REC_LIVE_OLD" "$TDIR/recover.stdout" && grep -qx 'Browser needs attention' "$TDIR/recover.stderr"; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(tail -2 "$TDIR/recover.stderr")"

# The resolver rejects every uncertainty shape before acquiring the harvest lock or touching CDP.
REC_MIX='pg-run-acme-widgets-102-1700008200-1'
printf '[P1] mixed\n  Why: refuse\nP2: none\nP3: none\nVERDICT: SHIP - mixed.\n' > "$REC_AMBIG_HOME/completed/$REC_MIX"
printf 'github.com\tacme\twidgets\tacme-widgets-102\t102\t/tmp/mix.md\t1700008300\n' > "$REC_AMBIG_HOME/run-meta/$REC_MIX"
printf '[P1] legacy mixed\n  Why: refuse\nP2: none\nP3: none\nVERDICT: SHIP - legacy.\n' > "$REC_AMBIG_HOME/completed/pg-run-acme-widgets-102-1700008201-2"
recover_run "$REC_AMBIG_HOME" --recover 'https://github.com/acme/widgets/pull/102'
check 'recover refuses mixed legacy and canonical candidate evidence' \
  "$([ "$RC" -eq 2 ] && grep -qi 'legacy candidate' "$TDIR/recover.stderr"; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
REC_CONFLICT='pg-run-acme-widgets-103-1700008300-1'
printf '[P1] conflict\n  Why: refuse\nP2: none\nP3: none\nVERDICT: SHIP - conflict.\n' > "$REC_AMBIG_HOME/completed/$REC_CONFLICT"
printf 'github.com\tacme\twidgets\tacme-widgets-103\t103\t/tmp/conflict.md\t1700008400\n' > "$REC_AMBIG_HOME/run-meta/$REC_CONFLICT"
mkdir -p "$REC_AMBIG_HOME/in-progress"
printf 'acme-widgets-103\t/tmp/conflict.md\t%s\t0\t1\t\t1700008401\tgenerating\n' "$(date +%s)" > "$REC_AMBIG_HOME/in-progress/$REC_CONFLICT"
recover_run "$REC_AMBIG_HOME" --recover 'https://github.com/acme/widgets/pull/103'
check 'recover refuses conflicting sidecar and reservation charge evidence' \
  "$([ "$RC" -eq 2 ] && grep -qi 'charge evidence conflicts' "$TDIR/recover.stderr"; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
: > "$TDIR/recover-oracle-sentinel"
REC_UNPROVEN_REPO="$TDIR/recover-unproven-repo"; git init -q "$REC_UNPROVEN_REPO"
recover_run "$REC_AMBIG_HOME" --recover 42 --repo "$REC_UNPROVEN_REPO"
check 'recover bare PR without current canonical repository proof refuses cross-repo ambiguity' \
  "$([ "$RC" -eq 2 ] && grep -qi 'canonical repository proof' "$TDIR/recover.stderr" && [ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/recover.stderr") oracle=$(cat "$TDIR/recover-oracle-sentinel")"

# A recover caller inherits the existing marker lock and reports the established busy exit/state.
REC_BUSY_HOME="$TDIR/home-recover-busy"; REC_BUSY='pg-run-acme-widgets-104-1700008400-1'
mkdir -p "$REC_BUSY_HOME/in-progress" "$REC_BUSY_HOME/run-meta" "$REC_BUSY_HOME/harvest-locks"
printf 'acme-widgets-104\t/tmp/busy.md\t%s\t0\t1\t\t1700008500\tgenerating\n' "$(date +%s)" > "$REC_BUSY_HOME/in-progress/$REC_BUSY"
printf 'github.com\tacme\twidgets\tacme-widgets-104\t104\t/tmp/busy.md\t1700008500\n' > "$REC_BUSY_HOME/run-meta/$REC_BUSY"
printf 'run marker: %s\nstale readable source\n' "$REC_BUSY" > "$TDIR/recover-busy-source.txt"
printf '{"title":null,"archived":false,"events":[]}\n' > "$TDIR/recover-busy-state.json"
start_mock "$TDIR/recover-busy-source.txt" "$TDIR/recover-busy-state.json"
exec {REC_BUSY_FD}>>"$REC_BUSY_HOME/harvest-locks/$REC_BUSY"; flock -n "$REC_BUSY_FD"
env PRO_GATE_HOME="$REC_BUSY_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_HARVEST_LOCK_WAIT=1 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" \
  PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  bash "$ENGINE" --recover 'https://github.com/acme/widgets/pull/104' --timeout 1s \
  >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?; eval "exec ${REC_BUSY_FD}>&-"
check 'concurrent recover inherits marker harvest lock and busy state without fresh dispatch' \
  "$([ "$RC" -eq 7 ] && grep -qx 'Checking for completed review' "$TDIR/recover.stderr" && [ ! -s "$TDIR/recover-oracle-sentinel" ] && [ "$(jq -r '.created | length' "$TDIR/recover-busy-state.json")" = 0 ]; echo $?)" \
  "rc=$RC stderr=$(tail -3 "$TDIR/recover.stderr") state=$(cat "$TDIR/recover-busy-state.json") oracle=$(cat "$TDIR/recover-oracle-sentinel")"

# Exact-marker recovery remains useful for a legacy run with neither run-meta nor a reservation
# output pointer. The recovery-owned fallback directory must exist before marker-only harvest starts.
REC_EXACT_LEGACY_HOME="$TDIR/home-recover-exact-legacy"
REC_EXACT_LEGACY='pg-run-legacy-exact-105-1700008600-1'
: > "$TDIR/recover-oracle-sentinel"
recover_run "$REC_EXACT_LEGACY_HOME" --recover "$REC_EXACT_LEGACY" --timeout 1s
check 'recover exact legacy marker creates a safe fallback output before harvest' \
  "$([ "$RC" -eq 3 ] && [ -d "$REC_EXACT_LEGACY_HOME/recovered" ] && grep -qx 'Browser needs attention' "$TDIR/recover.stderr" && [ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/recover.stderr") oracle=$(cat "$TDIR/recover-oracle-sentinel")"

# A real fresh run, not a hand-authored fixture, must publish canonical repository identity when
# its marker is minted and then persist pg_round_record's charged-spend epoch into the same sidecar.
REC_META_HOME="$TDIR/home-recover-meta"
REC_META_REPO="$TDIR/recover-meta-repo"; git init -q "$REC_META_REPO"
git -C "$REC_META_REPO" remote add origin https://github.com/acme/widgets.git
cat > "$TDIR/bin/oracle-recover-meta" <<'RECOVER_META_ORACLE'
#!/usr/bin/env bash
prompt=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in -p) prompt="$2"; shift 2;; --write-output) out="$2"; shift 2;; *) shift;; esac
done
marker="$(printf '%s' "$prompt" | grep -oE 'pg-run-[A-Za-z0-9.-]+' | tail -1)"
printf '[P1] src/meta.sh:1 - metadata fixture\n  Why: real fresh run\nP2: none\nP3: none\nVERDICT: SHIP - metadata recorded. (run marker: %s)\n' "$marker" > "$out"
RECOVER_META_ORACLE
chmod +x "$TDIR/bin/oracle-recover-meta"
env PRO_GATE_HOME="$REC_META_HOME" PRO_GATE_BROWSER_MODE=native PRO_GATE_MIN_UPTIME=0 \
  PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-meta" NODE_OPTIONS= \
  bash "$ENGINE" --pr 105 --repo "$REC_META_REPO" --diff "$TDIR/small.diff" \
  --out "$TDIR/recover-meta.md" --timeout 5s >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?
REC_META_MARKER="$(jq -r .marker "$TDIR/recover-meta.md.status" 2>/dev/null)"
REC_META_RECORD="$(cat "$REC_META_HOME/run-meta/$REC_META_MARKER" 2>/dev/null)"
check 'fresh run persists canonical repository identity and charged-spend ordering metadata' \
  "$([ "$RC" -eq 0 ] && [ -n "$REC_META_MARKER" ] && printf '%s\n' "$REC_META_RECORD" | awk -F'\t' 'NF == 7 && $1 == "github.com" && $2 == "acme" && $3 == "widgets" && $5 == "105" && $7 ~ /^[0-9]+$/ {ok=1} END{exit !ok}'; echo $?)" \
  "rc=$RC marker=$REC_META_MARKER meta=$REC_META_RECORD stderr=$(tail -3 "$TDIR/recover.stderr")"

# v0.35.x fix: the early (pre-charge) run-meta write was a no-op WARNING generator — it never
# supplied charged_spend_epoch, and pg_run_meta_write now REQUIRES it. Recovery metadata is
# published only together with the authoritative charge, so an uncharged terminal exit (here:
# round-capped, which mints RUN_MARKER before ever reaching pg_round_record) must mint no
# run-meta record and print no metadata WARNING, while a prior charged artifact for the same PR
# stays recoverable exactly as before.
echo '# fix: uncharged terminal exit no longer mints a false run-meta record'
UNCH_HOME="$TDIR/home-uncharged"
UNCH_REPO="$TDIR/uncharged-repo"; git init -q "$UNCH_REPO"
git -C "$UNCH_REPO" remote add origin https://github.com/acme/uncharged.git
mkdir -p "$UNCH_HOME/completed" "$UNCH_HOME/run-meta"
UNCH_PRIOR='pg-run-acme-uncharged-201-1700009000-1'
printf '[P1] src/prior.sh:1 - prior charged finding\n  Why: durable\nP2: none\nP3: none\nVERDICT: SHIP - prior.\n' > "$UNCH_HOME/completed/$UNCH_PRIOR"
printf 'github.com\tacme\tuncharged\tacme-uncharged-201\t201\t/tmp/prior.md\t1700009100\n' > "$UNCH_HOME/run-meta/$UNCH_PRIOR"
UNCH_BEFORE="$(find "$UNCH_HOME/run-meta" -type f | sort)"
printf 'foreign idle tab\n' > "$TDIR/tab.txt"
start_mock "$TDIR/tab.txt"
env PRO_GATE_HOME="$UNCH_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_MAX_ROUNDS_PER_PR=0 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-preflight" NODE_OPTIONS= \
  bash "$ENGINE" --pr 201 --repo "$UNCH_REPO" --diff "$TDIR/small.diff" --out "$TDIR/o-uncharged.md" --timeout 5s \
  >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check 'uncharged round-capped run exits 12' "$([ "$RC" -eq 12 ]; echo $?)" "rc=$RC $(tail -3 "$TDIR/stderr")"
UNCH_MARKER="$(jq -r .marker "$TDIR/o-uncharged.md.status" 2>/dev/null)"
UNCH_AFTER="$(find "$UNCH_HOME/run-meta" -type f | sort)"
check 'uncharged terminal exit mints no run-meta record for its own marker' \
  "$([ -n "$UNCH_MARKER" ] && [ ! -e "$UNCH_HOME/run-meta/$UNCH_MARKER" ] && [ "$UNCH_BEFORE" = "$UNCH_AFTER" ]; echo $?)" \
  "marker=$UNCH_MARKER before=$UNCH_BEFORE after=$UNCH_AFTER"
check 'uncharged terminal exit emits no metadata WARNING' \
  "$(! grep -q 'could not persist recovery' "$TDIR/stderr"; echo $?)" "$(cat "$TDIR/stderr")"
recover_run "$UNCH_HOME" --recover 'https://github.com/acme/uncharged/pull/201'
check 'recover after an uncharged attempt still returns the prior charged artifact' \
  "$([ "$RC" -eq 0 ] && cmp -s "$UNCH_HOME/completed/$UNCH_PRIOR" "$TDIR/recover.stdout"; echo $?)" "rc=$RC stdout=$(cat "$TDIR/recover.stdout")"

# fix: pg_run_meta_write's own publication temp ($f.tmp.$$) used to match the pg-run-* glob AND
# pg_reservation_marker_ok (dots are a legal marker character), so a concurrent scan mid-publish
# could surface a half-written record. The temp is now dot-prefixed (excluded by the glob) and
# the scanner also skips a lingering "<marker>.tmp.<pid>" basename left by a pre-fix version.
echo '# fix: publication temps are excluded from the run-meta recovery scan'
TMPSCAN_HOME="$TDIR/home-tmpscan"; mkdir -p "$TMPSCAN_HOME/run-meta"
TMPSCAN_GOOD='pg-run-acme-widgets-301-1700009900-1'
printf 'github.com\tacme\twidgets\tacme-widgets-301\t301\t/tmp/good.md\t1700010000\n' > "$TMPSCAN_HOME/run-meta/$TMPSCAN_GOOD"
printf 'github.com\tacme\twidgets\tacme-widgets-301\t301\t/tmp/bad.md\t1700010001\n' \
  > "$TMPSCAN_HOME/run-meta/pg-run-acme-widgets-301-1700009901-2.tmp.99"
# A repo or branch may legitimately contain the literal ".tmp." (GitHub allows dots in a repo
# name), and ROUND_KEY preserves dots, so a bare "*.tmp.*" substring skip would hide this
# CHARGED record from every future recovery scan forever. A real marker always ends
# "-<epoch>-<pid>", so anchoring on an all-digit tail after the LAST ".tmp." separates the two.
TMPSCAN_DOTTED='pg-run-acme-app.tmp.v2-302-1700009902-3'
printf 'github.com\tacme\tapp.tmp.v2\tacme-app.tmp.v2-302\t302\t/tmp/dotted.md\t1700010002\n' \
  > "$TMPSCAN_HOME/run-meta/$TMPSCAN_DOTTED"
SCAN_OUT="$(PRO_GATE_HOME="$TMPSCAN_HOME" bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; pg_run_meta_scan')"
check 'run-meta scan excludes a planted publication-temp record' \
  "$(! printf '%s\n' "$SCAN_OUT" | grep -qF 'tmp.99'; echo $?)" "scan: $SCAN_OUT"
check 'run-meta scan still returns the committed record beside it' \
  "$(printf '%s\n' "$SCAN_OUT" | grep -qF "$TMPSCAN_GOOD"; echo $?)" "scan: $SCAN_OUT"
check 'run-meta scan keeps a charged record whose repo name contains .tmp.' \
  "$(printf '%s\n' "$SCAN_OUT" | grep -qF "$TMPSCAN_DOTTED"; echo $?)" "scan: $SCAN_OUT"

# fix: --recover extracted the PR number from everything after the FINAL slash, so a canonical
# URL with one trailing slash (a spelling pg_repo_identity_from_url already accepts) yielded an
# empty number and forced a spurious disambiguation.
echo '# fix: --recover accepts one trailing slash on a canonical PR URL'
TRAILSLASH_HOME="$TDIR/home-trailslash"; mkdir -p "$TRAILSLASH_HOME/completed" "$TRAILSLASH_HOME/run-meta"
TRAILSLASH_MARKER='pg-run-acme-widgets-401-1700010100-1'
printf '[P1] src/ts.sh:1 - trailing slash fixture\n  Why: durable\nP2: none\nP3: none\nVERDICT: SHIP - ts.\n' \
  > "$TRAILSLASH_HOME/completed/$TRAILSLASH_MARKER"
printf 'github.com\tacme\twidgets\tacme-widgets-401\t401\t/tmp/ts.md\t1700010200\n' > "$TRAILSLASH_HOME/run-meta/$TRAILSLASH_MARKER"
recover_run "$TRAILSLASH_HOME" --recover 'https://github.com/acme/widgets/pull/401/'
check 'recover of a trailing-slash canonical PR URL returns the prior charged artifact' \
  "$([ "$RC" -eq 0 ] && cmp -s "$TRAILSLASH_HOME/completed/$TRAILSLASH_MARKER" "$TDIR/recover.stdout"; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(cat "$TDIR/recover.stderr")"

# fix: pg_repo_identity_from_url required a literal .git suffix on both SSH remote spellings;
# common remotes omit it, which refused bare-PR recovery despite a unique proven checkout.
echo '# fix: pg_repo_identity_from_url accepts SSH remotes without a .git suffix'
check 'git@host:owner/repo (no .git) parses to canonical identity' \
  "$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; [ "$(pg_repo_identity_from_url "git@github.com:acme/widgets")" = "$(printf "github.com\tacme\twidgets")" ]'; echo $?)" \
  "$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; pg_repo_identity_from_url "git@github.com:acme/widgets"')"
check 'ssh://git@host/owner/repo (no .git) parses to canonical identity' \
  "$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; [ "$(pg_repo_identity_from_url "ssh://git@github.com/acme/widgets")" = "$(printf "github.com\tacme\twidgets")" ]'; echo $?)" \
  "$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; pg_repo_identity_from_url "ssh://git@github.com/acme/widgets"')"
check 'git@host:owner/repo.git (with .git) still parses (existing strip preserved)' \
  "$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; [ "$(pg_repo_identity_from_url "git@github.com:acme/widgets.git")" = "$(printf "github.com\tacme\twidgets")" ]'; echo $?)" \
  "$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; pg_repo_identity_from_url "git@github.com:acme/widgets.git"')"
check 'ssh://git@host/owner/repo.git (with .git) still parses' \
  "$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; [ "$(pg_repo_identity_from_url "ssh://git@github.com/acme/widgets.git")" = "$(printf "github.com\tacme\twidgets")" ]'; echo $?)" \
  "$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; pg_repo_identity_from_url "ssh://git@github.com/acme/widgets.git"')"
check 'a malformed ssh-ish form (no colon, no ssh://) still refuses' \
  "$(! bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; pg_repo_identity_from_url "git@github.com/acme/widgets"' >/dev/null 2>&1; echo $?)" \
  "expected nonzero"

# Recovery parser negative table: --recover is exclusive with every dispatch/status flag, and
# with no query at all. Every case must refuse before any state mutation or fresh dispatch.
echo '# --recover negative parser table: exclusive with every other mode, and rejects no query'
NEG_HOME="$TDIR/home-recover-neg"; mkdir -p "$NEG_HOME/run-meta" "$NEG_HOME/completed"
neg_snapshot() {
  find "$NEG_HOME" -mindepth 1 -type f -printf '%P:%s\n' 2>/dev/null | sort
  find "$TDIR" -maxdepth 1 -name 'recover-oracle-sentinel' -printf '%s\n'
}
: > "$TDIR/recover-oracle-sentinel"
NEG_BEFORE="$(neg_snapshot)"
recover_run "$NEG_HOME" --recover 501 --pr 1
check 'recover + --pr exits 2' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
check 'recover + --pr names the misuse on stderr' "$(grep -qi 'recover' "$TDIR/recover.stderr"; echo $?)" "$(cat "$TDIR/recover.stderr")"
recover_run "$NEG_HOME" --recover 501 --diff "$TDIR/small.diff"
check 'recover + --diff exits 2' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
recover_run "$NEG_HOME" --recover 501 --harvest pg-run-x-1-1
check 'recover + --harvest exits 2' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
recover_run "$NEG_HOME" --recover 501 --status
check 'recover + --status exits 2' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
recover_run "$NEG_HOME" --recover 501 --json
check 'recover + --json exits 2' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
recover_run "$NEG_HOME" --recover ''
check 'recover with no query exits 2' "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
NEG_AFTER="$(neg_snapshot)"
check 'negative recover table creates no run-meta/recovered/reservation state and never dispatches oracle' \
  "$([ "$NEG_BEFORE" = "$NEG_AFTER" ]; echo $?)" "before=$NEG_BEFORE after=$NEG_AFTER"

# gate #91 P2 (:65): every two-argument flag left trailing with no operand must fail fast (exit 2,
# naming the flag), not silently misbehave. Pre-fix, raw "$2" (--pr and friends) tripped set -u's
# unbound-variable abort, while "${2:-}" (--harvest/--recover, which allow a deliberate no-op
# value) let "shift 2" fail on one remaining argument — shift is atomic, so nothing is consumed,
# $1 stays pinned on the flag, and the parser loop spins FOREVER. Each case runs under `timeout` so
# a regression hangs this one test instead of the whole CI job.
echo '# gate #91 P2 (:65): trailing two-arg flag with no operand fails fast, exit 2, not forever'
ARGP_HOME="$TDIR/home-argparse"; mkdir -p "$ARGP_HOME"
for f in --pr --repo --diff --input --out --timeout --extra-files --confirm --brief --harvest --recover; do
  timeout 10 env PRO_GATE_HOME="$ARGP_HOME" bash "$ENGINE" "$f" >"$TDIR/stdout" 2>"$TDIR/stderr"
  RC=$?
  check "trailing $f with no operand exits 2 promptly (not 124-timeout, not unbound-variable crash)" \
    "$([ "$RC" -eq 2 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/stderr")"
  check "trailing $f with no operand names the flag on stderr" \
    "$(grep -qF "ERROR: $f requires a value" "$TDIR/stderr"; echo $?)" "stderr=$(cat "$TDIR/stderr")"
done
# --status deliberately takes an OPTIONAL operand (a bare --status means "all state"): it must be
# excluded from the two-arg guard above and keep working with nothing following it.
timeout 10 env PRO_GATE_HOME="$ARGP_HOME" bash "$ENGINE" --status >"$TDIR/stdout" 2>"$TDIR/stderr"
RC=$?
check '--status with no trailing operand still works (excluded from the two-arg guard)' \
  "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC stdout=$(cat "$TDIR/stdout") stderr=$(cat "$TDIR/stderr")"

# U3 publication-failure mapping (documented in the --recover artifact-first block): OUT given,
# pg_completed_lookup fails to copy the durable artifact to --out -> "Browser needs attention" on
# stderr, exit 6, the durable artifact untouched, no browser/round/reservation side effects, and
# stdout carries no review claim.
echo '# U3 publication-failure mapping: --recover --out with an unwritable/nonexistent parent'
PUBF_HOME="$TDIR/home-recover-pubfail"
PUBF_MARKER='pg-run-acme-widgets-601-1700010500-1'
mkdir -p "$PUBF_HOME/completed"
printf '[P1] src/pub.sh:1 - pub fixture\n  Why: durable\nP2: none\nP3: none\nVERDICT: SHIP - pub.\n' > "$PUBF_HOME/completed/$PUBF_MARKER"
PUBF_BEFORE="$(cat "$PUBF_HOME/completed/$PUBF_MARKER")"
: > "$TDIR/recover-oracle-sentinel"
recover_run "$PUBF_HOME" --recover "$PUBF_MARKER" --out "$TDIR/no-such-parent-dir/out.md" --timeout 1s
check 'publication failure exits 6 with "Browser needs attention" on stderr' \
  "$([ "$RC" -eq 6 ] && grep -qx 'Browser needs attention' "$TDIR/recover.stderr"; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
check 'publication failure leaves the durable artifact byte-identical' \
  "$([ "$(cat "$PUBF_HOME/completed/$PUBF_MARKER")" = "$PUBF_BEFORE" ]; echo $?)" "artifact changed"
check 'publication failure creates no output file' \
  "$([ ! -e "$TDIR/no-such-parent-dir/out.md" ]; echo $?)" "out file exists"
check 'publication failure has no browser/round/reservation side effects' \
  "$([ ! -d "$PUBF_HOME/in-progress" ] && [ ! -d "$PUBF_HOME/rounds" ] && [ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" \
  "oracle=$(cat "$TDIR/recover-oracle-sentinel")"
check 'publication failure stdout carries no review claim' \
  "$([ ! -s "$TDIR/recover.stdout" ]; echo $?)" "stdout=$(cat "$TDIR/recover.stdout")"

# gate #91 P1 (:169): pg_persist_result's own durability ladder falls through to pending/<marker>
# BYTES whenever the completed store is unwritable, retiring the reservation there exactly like a
# completed write — pending/ is verified review content, not a lesser record. A review durable
# ONLY under pending/ must be just as recoverable as one under completed/, by exact marker AND by
# PR URL, byte-identical, with no fresh dispatch, and the pending file left untouched (--recover
# never promotes it into completed/).
echo '# gate #91 P1 (:169): --recover serves a pending-only durable artifact'
REC_PEND_HOME="$TDIR/home-recover-pending"
REC_PEND_MARKER='pg-run-acme-widgets-801-1700011500-1'
mkdir -p "$REC_PEND_HOME/pending" "$REC_PEND_HOME/run-meta"
printf '[P1] src/pending.sh:1 - pending fixture\n  Why: durable pending only\nP2: none\nP3: none\nVERDICT: SHIP - pending.\n' \
  > "$REC_PEND_HOME/pending/$REC_PEND_MARKER"
printf 'github.com\tacme\twidgets\tacme-widgets-801\t801\t/tmp/pending-orig.md\t1700011600\n' \
  > "$REC_PEND_HOME/run-meta/$REC_PEND_MARKER"
REC_PEND_BEFORE="$(cat "$REC_PEND_HOME/pending/$REC_PEND_MARKER")"
: > "$TDIR/recover-oracle-sentinel"
recover_run "$REC_PEND_HOME" --recover "$REC_PEND_MARKER" --out "$TDIR/recover-pending-out.md" --timeout 1s
check 'recover returns a pending-only artifact by exact marker' \
  "$([ "$RC" -eq 0 ] && cmp -s "$REC_PEND_HOME/pending/$REC_PEND_MARKER" "$TDIR/recover.stdout" \
     && cmp -s "$REC_PEND_HOME/pending/$REC_PEND_MARKER" "$TDIR/recover-pending-out.md"; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(cat "$TDIR/recover.stderr")"
check 'recover pending-only artifact prints Review ready only on stderr' \
  "$(grep -qx 'Review ready' "$TDIR/recover.stderr"; echo $?)" "stderr=$(cat "$TDIR/recover.stderr")"
check 'recover pending-only artifact never dispatches oracle' \
  "$([ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" "oracle=$(cat "$TDIR/recover-oracle-sentinel")"
check 'recover pending-only artifact leaves the pending file byte-identical and in place' \
  "$([ "$(cat "$REC_PEND_HOME/pending/$REC_PEND_MARKER")" = "$REC_PEND_BEFORE" ]; echo $?)" "pending artifact changed or removed"
recover_run "$REC_PEND_HOME" --recover 'https://github.com/acme/widgets/pull/801'
check 'recover returns a pending-only artifact by PR URL' \
  "$([ "$RC" -eq 0 ] && cmp -s "$REC_PEND_HOME/pending/$REC_PEND_MARKER" "$TDIR/recover.stdout"; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout")"

# gate #91 P1 (:192): a fresh run persists $OUT verbatim into run-meta, and a caller's relative
# --out is resolved against wherever the process itself started (before any `cd "$REPO"`).
# --recover runs from an unrelated cwd and never `cd`s anywhere, so a recorded relative path
# must never be replayed as a publish target, and a recorded absolute path is only trustworthy
# when its parent directory still exists and still accepts writes.
echo '# gate #91 P1 (:192): recorded --out is resolved absolute at charge time and validated at recovery'
RECABS_HOME="$TDIR/home-recover-absout"
RECABS_REPO="$TDIR/recover-absout-repo"; git init -q "$RECABS_REPO"
git -C "$RECABS_REPO" remote add origin https://github.com/acme/absout.git
( cd "$RECABS_REPO" && env PRO_GATE_HOME="$RECABS_HOME" PRO_GATE_BROWSER_MODE=native PRO_GATE_MIN_UPTIME=0 \
    PRO_GATE_SELF_HEAL=0 PRO_GATE_RAMP=0 PRO_GATE_MAX_RETRIES=0 \
    PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-meta" NODE_OPTIONS= \
    bash "$ENGINE" --pr 106 --repo "$RECABS_REPO" --diff "$TDIR/small.diff" \
    --out 'relative-out.md' --timeout 5s >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr" )
RC=$?
RECABS_MARKER="$(jq -r .marker "$RECABS_REPO/relative-out.md.status" 2>/dev/null)"
RECABS_EXPECT="$RECABS_REPO/relative-out.md"
RECABS_RECORDED="$(awk -F'\t' '{print $6}' "$RECABS_HOME/run-meta/$RECABS_MARKER" 2>/dev/null)"
check 'fresh run with a relative --out records an absolute path in run-meta' \
  "$([ "$RC" -eq 0 ] && [ -n "$RECABS_MARKER" ] && [ "$RECABS_RECORDED" = "$RECABS_EXPECT" ]; echo $?)" \
  "rc=$RC marker=$RECABS_MARKER recorded=$RECABS_RECORDED expect=$RECABS_EXPECT"

# A hand-authored legacy/foreign record can still carry a bare relative OUT (or none at all
# yet, from before this fix). Recovery must never treat it as an escape hatch into whatever
# directory --recover happens to run from.
RECFALLBACK_HOME="$TDIR/home-recover-relfallback"
RECFALLBACK_MARKER='pg-run-acme-widgets-802-1700011700-1'
mkdir -p "$RECFALLBACK_HOME/run-meta"
printf 'github.com\tacme\twidgets\tacme-widgets-802\t802\trelative-escape.md\t1700011800\n' \
  > "$RECFALLBACK_HOME/run-meta/$RECFALLBACK_MARKER"
: > "$TDIR/recover-oracle-sentinel"
( cd "$TDIR" && recover_run "$RECFALLBACK_HOME" --recover "$RECFALLBACK_MARKER" --timeout 1s )
check 'a recorded relative OUT does not publish outside PRO_GATE_HOME' \
  "$([ ! -e "$TDIR/relative-escape.md" ]; echo $?)" "escaped file: $(find "$TDIR" -maxdepth 1 -name 'relative-escape.md')"
check 'a recorded relative OUT falls back to the recovered/ directory instead' \
  "$([ -d "$RECFALLBACK_HOME/recovered" ]; echo $?)" "recovered=$(ls "$RECFALLBACK_HOME/recovered" 2>/dev/null)"

# A recorded absolute OUT whose parent directory has since been cleaned up (the common case:
# the default --out lived inside a per-run mktemp WORK dir the engine already deleted) must
# fall back exactly like "no metadata at all", not fail.
RECDEADPARENT_HOME="$TDIR/home-recover-deadparent"
RECDEADPARENT_MARKER='pg-run-acme-widgets-803-1700011900-1'
mkdir -p "$RECDEADPARENT_HOME/run-meta"
RECDEADPARENT_GONE="$TDIR/gone-parent-$$"; mkdir -p "$RECDEADPARENT_GONE"; rmdir "$RECDEADPARENT_GONE"
printf 'github.com\tacme\twidgets\tacme-widgets-803\t803\t%s/out.md\t1700012000\n' "$RECDEADPARENT_GONE" \
  > "$RECDEADPARENT_HOME/run-meta/$RECDEADPARENT_MARKER"
: > "$TDIR/recover-oracle-sentinel"
recover_run "$RECDEADPARENT_HOME" --recover "$RECDEADPARENT_MARKER" --timeout 1s
check 'a recorded absolute OUT with a dead parent falls back to the recovered/ directory instead of failing to establish an output path' \
  "$([ -d "$RECDEADPARENT_HOME/recovered" ]; echo $?)" \
  "recovered=$(ls "$RECDEADPARENT_HOME/recovered" 2>/dev/null) stderr=$(cat "$TDIR/recover.stderr")"
check 'a recorded absolute OUT with a dead parent never creates the dead parent directory' \
  "$([ ! -d "$RECDEADPARENT_GONE" ]; echo $?)" "revived: $RECDEADPARENT_GONE"

# A recorded absolute OUT whose parent is still writable is still used as-is. No completed/
# pending artifact here on purpose: the recorded-OUT reuse only matters on the marker-only
# harvest path (the artifact-first fast path above never reads REC_SELECTED_OUT).
RECVALID_HOME="$TDIR/home-recover-validout"
RECVALID_MARKER='pg-run-acme-widgets-804-1700012100-1'
mkdir -p "$RECVALID_HOME/run-meta"
printf 'github.com\tacme\twidgets\tacme-widgets-804\t804\t%s\t1700012200\n' "$TDIR/recover-validout-target.md" \
  > "$RECVALID_HOME/run-meta/$RECVALID_MARKER"
{ printf 'run marker: %s\n' "$RECVALID_MARKER"
  printf '[P1] src/valid.sh:1 - valid-out fixture\n  Why: durable\nP2: none\nP3: none\nVERDICT: SHIP - valid. (run marker: %s)\n' \
    "$RECVALID_MARKER" "$RECVALID_MARKER"
} > "$TDIR/recover-validout-tab.txt"
start_mock "$TDIR/recover-validout-tab.txt"
: > "$TDIR/recover-oracle-sentinel"
env PRO_GATE_HOME="$RECVALID_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  bash "$ENGINE" --recover "$RECVALID_MARKER" --timeout 5s \
  >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?
check 'a recorded valid absolute OUT is still used to publish the recovered artifact' \
  "$([ "$RC" -eq 0 ] && [ -s "$TDIR/recover-validout-target.md" ] && cmp -s "$TDIR/recover.stdout" "$TDIR/recover-validout-target.md"; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") target=$(cat "$TDIR/recover-validout-target.md" 2>/dev/null) stderr=$(cat "$TDIR/recover.stderr")"

# gate #91 P2 (:199): --recover's delegation to --harvest must surface exactly one plain novice
# state line, not the operational CDP/marker/RESULT_FILE= noise that --harvest itself prints —
# for the success path and for at least two distinct failure states. PRO_GATE_RECOVER_VERBOSE=1
# is the explicit opt-in that still surfaces the raw diagnostics for debugging a stuck recovery.
echo '# gate #91 P2 (:199): recover harvest-delegation exposes one plain state line, not raw --harvest noise'
RECNOISE_HOME="$TDIR/home-recover-noise"
RECNOISE_MARKER='pg-run-acme-widgets-701-1700010600-1'
{ printf 'run marker: %s\n' "$RECNOISE_MARKER"
  printf '[P1] src/noise.sh:1 - noisy finding\n  Why: leak check\nP2: none\nP3: none\nVERDICT: SHIP - noise. (run marker: %s)\n' \
    "$RECNOISE_MARKER" "$RECNOISE_MARKER"
} > "$TDIR/recover-noise-tab.txt"
start_mock "$TDIR/recover-noise-tab.txt"
: > "$TDIR/recover-oracle-sentinel"
env PRO_GATE_HOME="$RECNOISE_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  bash "$ENGINE" --recover "$RECNOISE_MARKER" --out "$TDIR/recover-noise-out.md" --timeout 30s \
  >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?
check 'recover harvest-delegation success exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
check 'recover harvest-delegation success stdout carries only review bytes' \
  "$(cmp -s "$TDIR/recover-noise-out.md" "$TDIR/recover.stdout"; echo $?)" "stdout=$(cat "$TDIR/recover.stdout")"
check 'recover harvest-delegation success stderr is exactly one plain state line' \
  "$([ "$(wc -l < "$TDIR/recover.stderr" | tr -d ' ')" = 1 ] && grep -qx 'Review ready' "$TDIR/recover.stderr"; echo $?)" \
  "stderr=$(cat "$TDIR/recover.stderr")"

# gate #91 P1 (:271): the harvest child publishes $OUT under its own process-lifetime output
# lock and then EXITS, releasing it — the window after that exit (including while the parent
# is still validating/reading) is wide open for another run reusing the same --out path to
# replace or truncate the file. A racer that continuously stomps --out for the ENTIRE recover
# invocation necessarily also lands inside that specific gap: if the parent ever re-reads $OUT
# instead of the child's own captured RESULT_FILE=/stdout bytes, this must observe the racer's
# garbage on stdout instead of the real review.
echo '# gate #91 P1 (:271): recover ignores a concurrently mutated --out, using the RESULT_FILE locator/captured body instead'
RECRACE_HOME="$TDIR/home-recover-race-out"
RECRACE_MARKER='pg-run-acme-widgets-705-1700011000-1'
{ printf 'run marker: %s\n' "$RECRACE_MARKER"
  printf '[P1] src/race.sh:1 - race fixture\n  Why: out-mutation race check\nP2: none\nP3: none\nVERDICT: SHIP - race. (run marker: %s)\n' \
    "$RECRACE_MARKER" "$RECRACE_MARKER"
} > "$TDIR/recover-race-tab.txt"
start_mock "$TDIR/recover-race-tab.txt"
: > "$TDIR/recover-oracle-sentinel"
RECRACE_OUT="$TDIR/recover-race-out.md"
RECRACE_STOP="$TDIR/recover-race.stop"; rm -f "$RECRACE_STOP"
( while [ ! -e "$RECRACE_STOP" ]; do printf 'GARBAGE-NOT-A-REVIEW\n' > "$RECRACE_OUT" 2>/dev/null; done ) &
RECRACE_RACER=$!
env PRO_GATE_HOME="$RECRACE_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  bash "$ENGINE" --recover "$RECRACE_MARKER" --out "$RECRACE_OUT" --timeout 30s \
  >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?
touch "$RECRACE_STOP"; wait "$RECRACE_RACER" 2>/dev/null
check 'recover under a continuous --out race still exits 0' "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
check 'recover under a continuous --out race prints the REAL review, not the racer garbage' \
  "$(grep -qF 'race fixture' "$TDIR/recover.stdout" && ! grep -qF 'GARBAGE-NOT-A-REVIEW' "$TDIR/recover.stdout"; echo $?)" \
  "stdout=$(cat "$TDIR/recover.stdout")"
check 'recover under a continuous --out race still reports the plain success state line' \
  "$([ "$(wc -l < "$TDIR/recover.stderr" | tr -d ' ')" = 1 ] && grep -qx 'Review ready' "$TDIR/recover.stderr"; echo $?)" \
  "stderr=$(cat "$TDIR/recover.stderr")"

# gate #91 P1 (:271) fallback leg: when the RESULT_FILE locator itself fails validation (here,
# forced by racing the completed artifact it names so pg_is_review sees garbage), recovery must
# fall back to the child's own captured stdout review bytes rather than failing outright or
# trusting --out. --out is raced TOO (same technique as the block above): with both the locator
# target and --out garbage for the run's whole duration, only the captured-stdout-body fallback
# (immune to both, since it was read from the child's own private temp file) can still be
# correct — a test that raced the artifact alone would pass even pre-fix, because pre-fix code
# never looks at the artifact at all and would coincidentally read a correct $OUT here.
echo '# gate #91 P1 (:271): a locator naming a non-review file falls back to the captured review body, still ignoring a raced --out'
RECRACE2_HOME="$TDIR/home-recover-race-artifact"
RECRACE2_MARKER='pg-run-acme-widgets-706-1700011100-1'
{ printf 'run marker: %s\n' "$RECRACE2_MARKER"
  printf '[P1] src/race2.sh:1 - locator fallback fixture\n  Why: locator-invalid race check\nP2: none\nP3: none\nVERDICT: SHIP - race2. (run marker: %s)\n' \
    "$RECRACE2_MARKER" "$RECRACE2_MARKER"
} > "$TDIR/recover-race2-tab.txt"
start_mock "$TDIR/recover-race2-tab.txt"
: > "$TDIR/recover-oracle-sentinel"
RECRACE2_ART="$RECRACE2_HOME/completed/$RECRACE2_MARKER"
RECRACE2_OUT="$TDIR/recover-race2-out.md"
RECRACE2_STOP="$TDIR/recover-race2.stop"; rm -f "$RECRACE2_STOP"
mkdir -p "$RECRACE2_HOME/completed"
( while [ ! -e "$RECRACE2_STOP" ]; do
    printf 'GARBAGE-NOT-A-REVIEW\n' > "$RECRACE2_ART" 2>/dev/null
    printf 'GARBAGE-NOT-A-REVIEW\n' > "$RECRACE2_OUT" 2>/dev/null
  done ) &
RECRACE2_RACER=$!
env PRO_GATE_HOME="$RECRACE2_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  bash "$ENGINE" --recover "$RECRACE2_MARKER" --out "$RECRACE2_OUT" --timeout 30s \
  >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?
touch "$RECRACE2_STOP"; wait "$RECRACE2_RACER" 2>/dev/null
check 'recover with a racing (locator-invalidating) completed artifact still exits 0 via captured-body fallback' \
  "$([ "$RC" -eq 0 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
check 'recover with a racing completed artifact and racing --out prints the REAL review, not the racer garbage' \
  "$(grep -qF 'locator fallback fixture' "$TDIR/recover.stdout" && ! grep -qF 'GARBAGE-NOT-A-REVIEW' "$TDIR/recover.stdout"; echo $?)" \
  "stdout=$(cat "$TDIR/recover.stdout")"

# gate #91 round3 P1 (:304): when BOTH race-free sources fail — the RESULT_FILE locator and the
# captured stdout body — recovery must fail closed rather than fall back to re-reading $OUT. The
# completed and pending stores are pre-blocked DETERMINISTICALLY (a pre-existing mismatched
# write-once artifact; pending replaced by a plain file so mkdir -p cannot recreate it as a
# directory), forcing pg_persist_result to its last-resort rung: RESULT_PATH is the child's own
# kept $WORK/harvest.capture — the --harvest path's HARVEST_TMP, and (via pg_persist_result's
# "$src" fallback) the SAME file RESULT_PATH ends up naming (PG_KEEP_FINAL=1).
#
# An earlier version of this test raced a background poller against the child instead of the
# line below: it busy-waited for pg_strip_nonce's token-removal (grep, forking on every
# iteration) as the "safe to corrupt" signal before hammering $WORK/harvest.capture with
# garbage. That lost the race every observed run — the production path from strip to the
# parent's own re-validation is a handful of shell builtins plus one mv/cp, which finishes
# faster than a loop that forks a grep per poll can even notice the signal, let alone land a
# write before the parent reads the file. The result was a FALSE negative on this exact
# regression (rc=0, the real review printed, the check reporting a working race that never
# actually raced). Corrupt the file as a synchronous SIDE EFFECT of the parent's own next
# instruction instead of trying to outrun it: `sed -n 's/^RESULT_FILE=//p'` at :398 is the
# unique, unambiguous call the parent makes to parse the child's locator line, immediately
# before validating it — nothing else in the codebase runs that exact script. A PATH shim on
# `sed` overwrites $WORK/harvest.capture the instant that call fires, then execs the real sed
# so REC_LOCATOR still resolves to the correct (now-corrupted) path. No timing window, no
# flakiness: the parent's very next read of $REC_LOCATOR is guaranteed post-corruption. The
# captured body is blocked independently: a second shim rule fails the mktemp call recovery
# uses to stage the child's own stdout into a private temp file. $OUT carries a DIFFERENT,
# structurally valid "foreign" review throughout — an old build that fell back to re-reading
# $OUT here would have announced it as this run's result.
#
# A SECOND false-negative sits one layer below the one above: a plain `PATH="$BIN:$PATH"`
# prefix does not survive pg_augment_path, which every oracle-review.sh invocation (parent AND
# the --harvest child it spawns) runs before touching mktemp/sed — it unconditionally rebuilds
# PATH as "$HOME/.local/bin:...mise/pnpm/homebrew...:/usr/local/bin:/usr/bin:/bin:$PATH",
# putting the real /usr/bin/mktemp and /usr/bin/sed AHEAD of whatever the caller prepended. A
# shim bin/ directory earlier in $PATH is silently shadowed and never runs (confirmed: `which
# mktemp` still resolves /usr/bin/mktemp under a prefixed PATH once pg_augment_path has fired) —
# this test passed even against a build with the $OUT fallback still in place, for the wrong
# reason (the "corruption" never happened, so both race-free rungs kept validating for real).
# $HOME/.local/bin is the one directory pg_augment_path itself puts FIRST, so pointing HOME at
# a private fixture directory containing only the two shims (not a repo/user directory — never
# touch the real $HOME) wins the lookup deterministically without relying on PATH ordering at
# all, and leaves every other tool (node, flock, git, ...) resolving from the real system dirs
# pg_augment_path lists after it.
echo '# gate #91 round3 P1 (:304): recover with locator AND captured body both invalid fails closed, never reading $OUT'
RECFINAL_HOME="$TDIR/home-recover-final-fallback"
RECFINAL_MARKER='pg-run-acme-widgets-708-1700011300-1'
{ printf 'run marker: %s\n' "$RECFINAL_MARKER"
  printf '[P1] src/final.sh:1 - third-rung fixture\n  Why: OUT-fallback removal check\nP2: none\nP3: none\nVERDICT: SHIP - final. (run marker: %s)\n' \
    "$RECFINAL_MARKER" "$RECFINAL_MARKER"
} > "$TDIR/recover-final-tab.txt"
mkdir -p "$RECFINAL_HOME/completed"
printf 'GARBAGE-NOT-A-REVIEW\n' > "$RECFINAL_HOME/completed/$RECFINAL_MARKER"
: > "$RECFINAL_HOME/pending"
RECFINAL_OUT="$TDIR/recover-final-out.md"
printf '[P2] src/foreign.sh:1 - unrelated concurrent review\n  Why: must never be returned by this recovery\nP1: none\nP3: none\nVERDICT: SHIP - foreign.\n' \
  > "$RECFINAL_OUT"
RECFINAL_WORK="$TDIR/recfinal-work"
RECFINAL_SNAP="$RECFINAL_WORK/harvest.capture"
RECFINAL_FAKEHOME="$TDIR/home-recfinal-fakehome"
RECFINAL_BIN="$RECFINAL_FAKEHOME/.local/bin"; mkdir -p "$RECFINAL_BIN"
cat > "$RECFINAL_BIN/mktemp" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    */pg-recover-hvbody.*) exit 1 ;;
  esac
done
case "\$*" in
  *pro-review.XXXXXX*)
    mkdir -p "$RECFINAL_WORK" 2>/dev/null && { printf '%s\n' "$RECFINAL_WORK"; exit 0; }
    exit 1
    ;;
esac
exec /usr/bin/mktemp "\$@"
SHIM
chmod +x "$RECFINAL_BIN/mktemp"
cat > "$RECFINAL_BIN/sed" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *'s/^RESULT_FILE=//p'*)
    printf 'CORRUPTED-BY-TEST-NOT-A-REVIEW\n' > "$RECFINAL_SNAP" 2>/dev/null
    ;;
esac
exec /usr/bin/sed "\$@"
SHIM
chmod +x "$RECFINAL_BIN/sed"
start_mock "$TDIR/recover-final-tab.txt"
: > "$TDIR/recover-oracle-sentinel"
env PRO_GATE_HOME="$RECFINAL_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  HOME="$RECFINAL_FAKEHOME" \
  bash "$ENGINE" --recover "$RECFINAL_MARKER" --out "$RECFINAL_OUT" --timeout 30s \
  >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?
check 'recover with locator AND captured body both invalid reports the trouble state' \
  "$([ "$RC" -eq 6 ] && grep -qx 'Browser needs attention' "$TDIR/recover.stderr"; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
check 'recover with locator AND captured body both invalid prints nothing on stdout' \
  "$([ ! -s "$TDIR/recover.stdout" ]; echo $?)" "stdout=$(cat "$TDIR/recover.stdout")"
check 'recover with locator AND captured body both invalid never surfaces the foreign $OUT review' \
  "$(! grep -qF 'unrelated concurrent review' "$TDIR/recover.stdout"; echo $?)" \
  "stdout=$(cat "$TDIR/recover.stdout")"

# gate #91 round3 P1 (:165): the charge site's run-meta write is best-effort (a failed sidecar
# write must never block a real review from running), so a NEWER run can be live right now with
# NO run-meta row at all while an OLDER completed sidecar for the same change still exists. The
# run-meta scan alone would see only the old row and silently serve it while the real answer is
# still generating. active/<key> is written unconditionally at charge time, so the resolver
# cross-checks it using the SAME liveness rule --status already applies to active records (pid
# alive, then a process-identity token match) rather than a second rule that could disagree.
REC_ACTIVE_HOME="$TDIR/home-recover-active"
mkdir -p "$REC_ACTIVE_HOME/completed" "$REC_ACTIVE_HOME/run-meta" "$REC_ACTIVE_HOME/active"
REC_ACTIVE_OLD='pg-run-acme-widgets-110-1700009000-1'
printf '[P1] old artifact\n  Why: stale\nP2: none\nP3: none\nVERDICT: SHIP - old.\n' > "$REC_ACTIVE_HOME/completed/$REC_ACTIVE_OLD"
printf 'github.com\tacme\twidgets\tacme-widgets-110\t110\t/tmp/old-110.md\t1700009100\n' > "$REC_ACTIVE_HOME/run-meta/$REC_ACTIVE_OLD"
REC_ACTIVE_NEW='pg-run-acme-widgets-110-1700009200-2'
REC_ACTIVE_TOK="$(bash -c '. "'"$HERE"'/../lib/pro-gate-lib.sh"; pg_pid_token '"$$"'')"
printf '%s\t/tmp/new-110.md\t%s\t%s\tremote-chrome\t%s\n' \
  "$REC_ACTIVE_NEW" "$$" "$(date +%s)" "$REC_ACTIVE_TOK" > "$REC_ACTIVE_HOME/active/acme-widgets-110"
: > "$TDIR/recover-oracle-sentinel"
recover_run "$REC_ACTIVE_HOME" --recover 'https://github.com/acme/widgets/pull/110'
check 'recover refuses a stale artifact while a newer metadata-less run is LIVE, naming that marker' \
  "$([ "$RC" -eq 2 ] && grep -qi 'disambiguation' "$TDIR/recover.stderr" && grep -qF "$REC_ACTIVE_NEW" "$TDIR/recover.stderr" \
     && [ ! -s "$TDIR/recover.stdout" ] && [ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" \
  "rc=$RC stderr=$(cat "$TDIR/recover.stderr") oracle=$(cat "$TDIR/recover-oracle-sentinel")"

# A DEAD (pid gone, or a live pid whose process-identity token no longer matches — pid reuse)
# active record carries no live evidence and must never block recovery of the durable older
# artifact: the failure direction for a stale active record is "recover normally", not refuse.
printf '%s\t/tmp/dead-110.md\t99999999\t%s\tremote-chrome\tBOGUS-TOKEN\n' \
  "$REC_ACTIVE_OLD" "$(date +%s)" > "$REC_ACTIVE_HOME/active/acme-widgets-110"
recover_run "$REC_ACTIVE_HOME" --recover 'https://github.com/acme/widgets/pull/110'
check 'recover ignores a dead active record and returns the durable older artifact' \
  "$([ "$RC" -eq 0 ] && cmp -s "$REC_ACTIVE_HOME/completed/$REC_ACTIVE_OLD" "$TDIR/recover.stdout"; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(cat "$TDIR/recover.stderr")"

# Exact-marker recovery never enters the candidate scan (it already names one marker), so a LIVE
# active record for the same round key must not affect it either way — the active/ cross-check
# lives entirely inside the ambiguous-query branch above.
printf '%s\t/tmp/new-110.md\t%s\t%s\tremote-chrome\t%s\n' \
  "$REC_ACTIVE_NEW" "$$" "$(date +%s)" "$REC_ACTIVE_TOK" > "$REC_ACTIVE_HOME/active/acme-widgets-110"
recover_run "$REC_ACTIVE_HOME" --recover "$REC_ACTIVE_OLD"
check 'exact-marker recovery is unaffected by a live active record for the same round key' \
  "$([ "$RC" -eq 0 ] && cmp -s "$REC_ACTIVE_HOME/completed/$REC_ACTIVE_OLD" "$TDIR/recover.stdout"; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(cat "$TDIR/recover.stderr")"

# gate #91 round3 P1 (:208): the artifact-first fast path used to publish straight to --out with
# no lock at all — a second recovery, or a fresh/harvest run, racing it could each replace the
# same file and each report success while the other's bytes vanished silently. It now takes the
# SAME process-lifetime guard the engine's own dispatch takes (pg_out_guard_acquire) before the
# first byte moves. Hold that guard here exactly the way a live run would (flock on $OUT.lock)
# and confirm the racing recovery reports the trouble state and never touches --out, rather than
# a "successful" publish nobody could trust.
REC_GUARD_HOME="$TDIR/home-recover-outguard"
mkdir -p "$REC_GUARD_HOME/completed" "$REC_GUARD_HOME/run-meta"
REC_GUARD_MARKER='pg-run-acme-widgets-111-1700009400-1'
printf '[P1] guarded artifact\n  Why: must not publish while guard held\nP2: none\nP3: none\nVERDICT: SHIP - guarded.\n' \
  > "$REC_GUARD_HOME/completed/$REC_GUARD_MARKER"
printf 'github.com\tacme\twidgets\tacme-widgets-111\t111\t/tmp/og-111.md\t1700009500\n' \
  > "$REC_GUARD_HOME/run-meta/$REC_GUARD_MARKER"
REC_GUARD_OUT="$TDIR/recover-outguard-out.md"
exec {REC_GUARD_FD}>>"$REC_GUARD_OUT.lock"; flock -n "$REC_GUARD_FD"
recover_run "$REC_GUARD_HOME" --recover "$REC_GUARD_MARKER" --out "$REC_GUARD_OUT"
check 'recover cannot publish over an --out whose guard another live run already holds' \
  "$([ "$RC" -eq 6 ] && grep -qx 'Browser needs attention' "$TDIR/recover.stderr" \
     && [ ! -s "$TDIR/recover.stdout" ] && [ ! -s "$REC_GUARD_OUT" ]; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(cat "$TDIR/recover.stderr")"
# The guard helper narrates its own "ERROR: another live run..." line, which is right for the
# engine's dispatch but not for --recover, which promises exactly ONE plain state line. A
# grep-only assertion cannot see that leak, so pin the line count the way the sibling state
# checks above already do.
check 'recover guard contention still prints exactly one plain state line' \
  "$([ "$(wc -l < "$TDIR/recover.stderr")" = 1 ]; echo $?)" \
  "stderr=$(cat "$TDIR/recover.stderr")"
eval "exec ${REC_GUARD_FD}>&-"
# Once the guard is released, the identical call recovers normally — the guard blocks a genuine
# race, not recovery itself.
recover_run "$REC_GUARD_HOME" --recover "$REC_GUARD_MARKER" --out "$REC_GUARD_OUT"
check 'recover publishes normally once the --out guard is released' \
  "$([ "$RC" -eq 0 ] && cmp -s "$REC_GUARD_HOME/completed/$REC_GUARD_MARKER" "$REC_GUARD_OUT"; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(cat "$TDIR/recover.stderr")"

# Failure state 1: the harvested conversation is still generating (--harvest -> exit 9) ->
# mapped novice state "Still working", nothing else on either stream.
RECSTILL_MARKER='pg-run-acme-widgets-702-1700010700-1'
printf 'still thinking, run marker: %s\n' "$RECSTILL_MARKER" > "$TDIR/recover-still-tab.txt"
start_mock "$TDIR/recover-still-tab.txt"
: > "$TDIR/recover-oracle-sentinel"
env PRO_GATE_HOME="$RECNOISE_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  bash "$ENGINE" --recover "$RECSTILL_MARKER" --out "$TDIR/recover-still-out.md" --timeout 5s \
  >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?
check 'recover harvest-delegation still-generating exits 9' "$([ "$RC" -eq 9 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
check 'recover harvest-delegation still-generating stdout is empty' \
  "$([ ! -s "$TDIR/recover.stdout" ]; echo $?)" "stdout=$(cat "$TDIR/recover.stdout")"
check 'recover harvest-delegation still-generating stderr is exactly one plain state line' \
  "$([ "$(wc -l < "$TDIR/recover.stderr" | tr -d ' ')" = 1 ] && grep -qx 'Still working' "$TDIR/recover.stderr"; echo $?)" \
  "stderr=$(cat "$TDIR/recover.stderr")"

# Failure state 2: a concurrent harvest already holds this marker's lock (--harvest -> exit 7)
# -> mapped novice state "Checking for completed review", nothing else on either stream.
RECBUSY_MARKER='pg-run-acme-widgets-703-1700010800-1'
mkdir -p "$RECNOISE_HOME/harvest-locks"
exec {RECBUSY_FD}>>"$RECNOISE_HOME/harvest-locks/$RECBUSY_MARKER"; flock -n "$RECBUSY_FD"
: > "$TDIR/recover-oracle-sentinel"
env PRO_GATE_HOME="$RECNOISE_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_HARVEST_LOCK_WAIT=1 PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" \
  PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  bash "$ENGINE" --recover "$RECBUSY_MARKER" --out "$TDIR/recover-busy-out.md" --timeout 1s \
  >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?; eval "exec ${RECBUSY_FD}>&-"
check 'recover harvest-delegation lock contention exits 7' "$([ "$RC" -eq 7 ]; echo $?)" "rc=$RC stderr=$(cat "$TDIR/recover.stderr")"
check 'recover harvest-delegation lock contention stdout is empty' \
  "$([ ! -s "$TDIR/recover.stdout" ]; echo $?)" "stdout=$(cat "$TDIR/recover.stdout")"
check 'recover harvest-delegation lock contention stderr is exactly one plain state line' \
  "$([ "$(wc -l < "$TDIR/recover.stderr" | tr -d ' ')" = 1 ] && grep -qx 'Checking for completed review' "$TDIR/recover.stderr"; echo $?)" \
  "stderr=$(cat "$TDIR/recover.stderr")"
check 'neither failure state dispatched oracle' "$([ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" "oracle=$(cat "$TDIR/recover-oracle-sentinel")"

# The opt-in: PRO_GATE_RECOVER_VERBOSE=1 still surfaces the raw --harvest diagnostics the
# default path just swallowed, for debugging a stuck recovery. A fresh marker/tab is required:
# RECNOISE_MARKER's review is already durable from the success case above, so reusing it here
# would take the artifact-first fast path (no harvest, no noise to gate at all).
RECVERBOSE_MARKER='pg-run-acme-widgets-704-1700010900-1'
{ printf 'run marker: %s\n' "$RECVERBOSE_MARKER"
  printf '[P1] src/verbose.sh:1 - verbose fixture\n  Why: opt-in check\nP2: none\nP3: none\nVERDICT: SHIP - verbose. (run marker: %s)\n' \
    "$RECVERBOSE_MARKER" "$RECVERBOSE_MARKER"
} > "$TDIR/recover-verbose-tab.txt"
start_mock "$TDIR/recover-verbose-tab.txt"
env PRO_GATE_HOME="$RECNOISE_HOME" ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 \
  PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
  PRO_GATE_RECOVER_VERBOSE=1 \
  bash "$ENGINE" --recover "$RECVERBOSE_MARKER" --out "$TDIR/recover-verbose-out.md" --timeout 30s \
  >"$TDIR/recover.stdout" 2>"$TDIR/recover.stderr"
RC=$?
check 'PRO_GATE_RECOVER_VERBOSE=1 surfaces the raw harvest RESULT_FILE= line' \
  "$(grep -q '^RESULT_FILE=' "$TDIR/recover.stdout"; echo $?)" "stdout=$(cat "$TDIR/recover.stdout")"
check 'PRO_GATE_RECOVER_VERBOSE=1 surfaces raw cdp-salvage diagnostics on stderr' \
  "$(grep -q '\[cdp-salvage\]' "$TDIR/recover.stderr"; echo $?)" "stderr=$(cat "$TDIR/recover.stderr")"

# U1: the pure review-decision seam consumes only a bounded normalized JSON snapshot. The
# fixture contract is the independent source of the closed action/effect/reason vocabulary;
# reducer output is compared with corpus literals rather than recomputed policy in this test.
echo '# U1: review-decision/v1 pure reducer, contract identity, and immutable bindings'
. "$HERE/../lib/pro-gate-lib.sh"
RD_CONTRACT="$HERE/fixtures/review-decision/v1/contract.json"
RD_CORPUS="$HERE/fixtures/review-decision/v1/corpus.json"
RD_CONTRACT_DIGEST="$(pg_sha256 "$RD_CONTRACT")"
RD_CORPUS_DIGEST="$(pg_sha256 "$RD_CORPUS")"
rd_facts() { # canonical merge of the corpus base and one patch, with runtime compatibility facts
  jq -cS --argjson patch "$1" --arg cd "$RD_CONTRACT_DIGEST" --arg xd "$RD_CORPUS_DIGEST" \
    '.base_facts * $patch | .contract={contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd}' "$RD_CORPUS"
}
rd_reduce() { pg_review_decision_reduce "$1"; }

check 'contract fixture is byte-canonical JSON with no trailing newline' \
  "$([ "$(jq -cS . "$RD_CONTRACT")" = "$(cat "$RD_CONTRACT")" ] && [ "$(tail -c 1 "$RD_CONTRACT" | od -An -tuC | tr -d ' ')" != 10 ]; echo $?)" \
  "tail=$(tail -c 1 "$RD_CONTRACT" | od -An -tuC)"
check 'corpus fixture is byte-canonical JSON with no trailing newline' \
  "$([ "$(jq -cS . "$RD_CORPUS")" = "$(cat "$RD_CORPUS")" ] && [ "$(tail -c 1 "$RD_CORPUS" | od -An -tuC | tr -d ' ')" != 10 ]; echo $?)" \
  "tail=$(tail -c 1 "$RD_CORPUS" | od -An -tuC)"
check 'runtime publishes the exact canonical contract and corpus digests' \
  "$([ "$(pg_review_decision_contract_digest)" = "$RD_CONTRACT_DIGEST" ] \
     && [ "$(pg_review_decision_corpus_digest)" = "$RD_CORPUS_DIGEST" ]; echo $?)" \
  "contract=$RD_CONTRACT_DIGEST corpus=$RD_CORPUS_DIGEST"

while IFS=$'\t' read -r name patch expected; do
  facts="$(rd_facts "$patch")"
  got="$(rd_reduce "$facts")"
  check "review decision action: $name" \
    "$(jq -e --argjson e "$expected" '.action == $e.action and .reason == $e.reason and .effect_request.execution_class == $e.execution_class and .effect_request.effect == $e.effect and .effect_request.action == .action' <<<"$got" >/dev/null 2>&1; echo $?)" \
    "expected=$expected got=$got"
  check "review decision envelope is closed and status/next_action-free: $name" \
    "$(jq -e 'keys == ["action","contract","effect_request","facts","observation","reason"] and has("status") == false and has("next_action") == false' <<<"$got" >/dev/null 2>&1; echo $?)" \
    "got=$got"
done < <(jq -r '.cases[] | [.name, (.patch|tojson), (.expected|tojson)] | @tsv' "$RD_CORPUS")

RD_REPEAT_FACTS="$(rd_facts '{}')"
RD_REPEAT_A="$(rd_reduce "$RD_REPEAT_FACTS")"
RD_REPEAT_B="$(rd_reduce "$RD_REPEAT_FACTS")"
check 'identical normalized snapshots emit byte-identical canonical decisions' \
  "$([ "$RD_REPEAT_A" = "$RD_REPEAT_B" ] && [ "$RD_REPEAT_A" = "$(jq -cS . <<<"$RD_REPEAT_A")" ]; echo $?)" "$RD_REPEAT_A"
check 'decision carries snapshot, contract, and corpus identity' \
  "$(jq -e --arg cd "$RD_CONTRACT_DIGEST" --arg xd "$RD_CORPUS_DIGEST" \
      '.contract.contract_digest == $cd and .contract.corpus_digest == $xd and (.effect_request.snapshot_digest | test("^[0-9a-f]{64}$"))' \
      <<<"$RD_REPEAT_A" >/dev/null 2>&1; echo $?)" "$RD_REPEAT_A"

rd_expect_stop() { # name, patch, reason
  local label="$1" patch="$2" reason="$3" got
  got="$(rd_reduce "$(rd_facts "$patch")")"
  check "$label" "$(jq -e --arg r "$reason" '.action == "stop-without-new-review" and .reason == $r and .effect_request.execution_class == "report-only"' <<<"$got" >/dev/null 2>&1; echo $?)" "$got"
}
rd_expect_stop 'undefined normalized state stops closed' '{"evidence":{"state":"undefined"}}' 'undefined-state'
rd_expect_stop 'invalid input binding stops closed' '{"input":{"binding_valid":false}}' 'invalid-binding'
rd_expect_stop 'blocking-wait transport collision stops closed' '{"transport":"blocking-wait/v1"}' 'transport-collision'
UNKNOWN_FACTS="$(rd_facts '{}')"; UNKNOWN_FACTS="$(jq -cS '.contract.contract_id="review-decision/v2"' <<<"$UNKNOWN_FACTS")"
UNKNOWN_OUT="$(rd_reduce "$UNKNOWN_FACTS")"
check 'unknown decision contract stops closed' \
  "$(jq -e '.action == "stop-without-new-review" and .reason == "unknown-contract"' <<<"$UNKNOWN_OUT" >/dev/null 2>&1; echo $?)" "$UNKNOWN_OUT"

LEGACY_COLLECT='{"completed_results":[{"applicable":false,"artifact_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","binding_valid":false,"canonical_identity":"legacy-a","charged_spend_epoch":1700000100,"collected":false,"legacy":true,"marker":"pg-run-legacy-1983-1700000100-1","provenance_valid":false,"verdict":"SHIP"}]}'
LEGACY_COLLECT_OUT="$(rd_reduce "$(rd_facts "$LEGACY_COLLECT")")"
check 'legacy completed artifact remains collectable' \
  "$(jq -e '.action == "collect-existing-result"' <<<"$LEGACY_COLLECT_OUT" >/dev/null 2>&1; echo $?)" "$LEGACY_COLLECT_OUT"
rd_expect_stop 'legacy SHIP cannot authorize merge eligibility or paid continuation' \
  '{"prior_review":{"applicable":true,"binding_valid":false,"code_identity":"input-current","evidence_identity":"evidence-current","legacy":true,"marker":"pg-run-legacy-1983-1-1","provenance_valid":false,"verdict":"SHIP"}}' 'legacy-not-authoritative'

SELECT_PATCH='{"completed_results":[{"applicable":true,"artifact_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","binding_valid":true,"canonical_identity":"result-a","charged_spend_epoch":1700000200,"collected":false,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000200-1","provenance_valid":true,"verdict":"SHIP"},{"applicable":true,"artifact_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","binding_valid":true,"canonical_identity":"result-b","charged_spend_epoch":1700000201,"collected":false,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000201-2","provenance_valid":true,"verdict":"FIX-FIRST"}]}'
SELECT_OUT="$(rd_reduce "$(rd_facts "$SELECT_PATCH")")"
check 'newest charged completed result and canonical identity are selected' \
  "$(jq -e '.action == "collect-existing-result" and .effect_request.applicable_ref == "result-b"' <<<"$SELECT_OUT" >/dev/null 2>&1; echo $?)" "$SELECT_OUT"
rd_expect_stop 'unresolved completed-result identity tie stops closed' \
  '{"completed_results":[{"applicable":true,"artifact_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","binding_valid":true,"canonical_identity":"same","charged_spend_epoch":1700000300,"collected":false,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000300-1","provenance_valid":true,"verdict":"SHIP"},{"applicable":true,"artifact_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","binding_valid":true,"canonical_identity":"same","charged_spend_epoch":1700000300,"collected":false,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000300-2","provenance_valid":true,"verdict":"SHIP"}]}' 'completed-result-tie'

rd_expect_stop 'identical verified code and evidence cannot authorize another review' \
  '{"prior_review":{"applicable":false,"binding_valid":true,"code_identity":"input-current","evidence_identity":"evidence-current","legacy":false,"marker":"pg-run-acme-widgets-1983-1700000400-1","provenance_valid":true,"verdict":"NONE"}}' 'identical-code-and-evidence'
rd_expect_stop 'no safe evidence action stops without caller inference' \
  '{"evidence":{"identity":"","safe_to_prepare":false,"state":"unsafe"}}' 'no-safe-action'
for crash_state in pre-charge round-recorded charged run-meta-written input-bound submitted unknown-fate; do
  crash_patch="$(jq -cn --arg s "$crash_state" '{active_index:{binding_valid:($s == "input-bound" or $s == "submitted"),charged_spend_epoch:1700000500,marker:"pg-run-acme-widgets-1983-1700000500-1",state:$s}}')"
  crash_out="$(rd_reduce "$(rd_facts "$crash_patch")")"
  check "active-index crash state never becomes fresh-run eligibility: $crash_state" \
    "$(jq -e '.action == "recover-existing-review" or .action == "stop-without-new-review"' <<<"$crash_out" >/dev/null 2>&1; echo $?)" "$crash_out"
done

VALID_CHOICE_PATCH='{"named_choice":{"outcomes":[{"consequence":"keep compatibility","id":"compat","label":"Preserve"},{"consequence":"use new API","id":"break","label":"Break"}],"selected_id":"compat","snapshot_digest":"CURRENT"},"prior_review":{"applicable":true,"binding_valid":true,"code_identity":"input-current","evidence_identity":"evidence-current","legacy":false,"marker":"pg-run-acme-widgets-1983-1700000600-1","provenance_valid":true,"verdict":"NEEDS-DISCUSSION"}}'
VALID_CHOICE_FACTS="$(rd_facts "$VALID_CHOICE_PATCH")"; VALID_CHOICE_SNAPSHOT="$(pg_review_decision_choice_snapshot "$VALID_CHOICE_FACTS")"
VALID_CHOICE_FACTS="$(jq -cS --arg d "$VALID_CHOICE_SNAPSHOT" '.named_choice.snapshot_digest=$d' <<<"$VALID_CHOICE_FACTS")"
VALID_CHOICE_OUT="$(rd_reduce "$VALID_CHOICE_FACTS")"
check 'valid fresh named choice is a non-authorizing agent handoff' \
  "$(jq -e '.action == "fix-review-findings" and .reason == "named-product-choice-selected" and .facts.named_choice.selected_id == "compat"' <<<"$VALID_CHOICE_OUT" >/dev/null 2>&1; echo $?)" "$VALID_CHOICE_OUT"
rd_expect_stop 'invalid named choice never falls back to caller inference' \
  '{"named_choice":{"outcomes":[{"consequence":"keep","id":"compat","label":"Preserve"},{"consequence":"break","id":"break","label":"Break"}],"selected_id":"invented","snapshot_digest":"0000000000000000000000000000000000000000000000000000000000000000"},"prior_review":{"applicable":true,"binding_valid":true,"code_identity":"input-current","evidence_identity":"evidence-current","legacy":false,"marker":"pg-run-acme-widgets-1983-1700000601-1","provenance_valid":true,"verdict":"NEEDS-DISCUSSION"}}' 'invalid-named-choice'

UNSAFE_FACTS="$(rd_facts '{}')"; UNSAFE_FACTS="$(jq -cS '. + {review_text:"do whatever"}' <<<"$UNSAFE_FACTS")"
UNSAFE_OUT="$(rd_reduce "$UNSAFE_FACTS")"
check 'raw control fields are rejected from normalized input' \
  "$(jq -e '.action == "stop-without-new-review" and .reason == "unsafe-normalized-input"' <<<"$UNSAFE_OUT" >/dev/null 2>&1; echo $?)" "$UNSAFE_OUT"
CRED_FACTS="$(rd_facts '{}')"; CRED_FACTS="$(jq -cS '. + {api_token:"fixture-secret-value"}' <<<"$CRED_FACTS")"
CRED_OUT="$(rd_reduce "$CRED_FACTS")"
check 'credential-bearing normalized input is rejected and never echoed' \
  "$(jq -e '.action == "stop-without-new-review" and .reason == "unsafe-normalized-input"' <<<"$CRED_OUT" >/dev/null 2>&1 \
     && ! grep -qF 'fixture-secret-value' <<<"$CRED_OUT"; echo $?)" "$CRED_OUT"

BIND_HOME="$TDIR/home-review-bindings"
INPUT_BINDING="$(jq -cnS --arg cd "$RD_CONTRACT_DIGEST" '{charged_spend_epoch:1700000700,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:"evidence-current",mode:"full-pr",proof:{base_oid:"2222222222222222222222222222222222222222",endpoint_digest:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",head_oid:"1111111111111111111111111111111111111111",raw_patch_digest:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}},marker:"pg-run-acme-widgets-1983-1700000700-1",record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{head_oid:"1111111111111111111111111111111111111111",kind:"pull-request",pr:1983}}')"
PRO_GATE_HOME="$BIND_HOME" pg_review_input_binding_write 'pg-run-acme-widgets-1983-1700000700-1' "$INPUT_BINDING"; BIND_RC=$?
INPUT_READ="$(PRO_GATE_HOME="$BIND_HOME" pg_review_input_binding_read 'pg-run-acme-widgets-1983-1700000700-1')"
check 'input binding is marker-addressed, validated, canonical, and readable' \
  "$([ "$BIND_RC" -eq 0 ] && [ "$INPUT_READ" = "$INPUT_BINDING" ]; echo $?)" "rc=$BIND_RC read=$INPUT_READ"
INPUT_OTHER="$(jq -cS '.evidence.identity="other"' <<<"$INPUT_BINDING")"
PRO_GATE_HOME="$BIND_HOME" pg_review_input_binding_write 'pg-run-acme-widgets-1983-1700000700-1' "$INPUT_OTHER" >/dev/null 2>&1; BIND_REPLACE_RC=$?
check 'input binding is immutable but byte-identical replay is idempotent' \
  "$([ "$BIND_REPLACE_RC" -ne 0 ] && PRO_GATE_HOME="$BIND_HOME" pg_review_input_binding_write 'pg-run-acme-widgets-1983-1700000700-1' "$INPUT_BINDING"; echo $?)" "replace_rc=$BIND_REPLACE_RC"
INPUT_DIGEST="$(printf '%s' "$INPUT_BINDING" | sha256sum | awk '{print $1}')"
RESULT_BINDING="$(jq -cnS --arg cd "$RD_CONTRACT_DIGEST" --arg ib "$INPUT_DIGEST" '{accepted_epoch:1700000800,artifact:{digest:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",path:"completed/pg-run-acme-widgets-1983-1700000700-1"},contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,input_binding_digest:$ib,input_binding_identity:"pg-run-acme-widgets-1983-1700000700-1",marker:"pg-run-acme-widgets-1983-1700000700-1",named_choice:null,provenance:{outcome:"accepted",validated_epoch:1700000800},record_type:"review-result-binding/v1",record_version:1,ship_proof:{base_oid:"2222222222222222222222222222222222222222",diff_digest:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",head_oid:"1111111111111111111111111111111111111111"},verdict:"SHIP"}')"
PRO_GATE_HOME="$BIND_HOME" pg_review_result_binding_write 'pg-run-acme-widgets-1983-1700000700-1' "$RESULT_BINDING"; RESULT_RC=$?
RESULT_READ="$(PRO_GATE_HOME="$BIND_HOME" pg_review_result_binding_read 'pg-run-acme-widgets-1983-1700000700-1')"
check 'result binding is the only marker-bound sibling and validates input/artifact identity' \
  "$([ "$RESULT_RC" -eq 0 ] && [ "$RESULT_READ" = "$RESULT_BINDING" ] \
     && [ "$(find "$BIND_HOME" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tr '\n' ' ')" = 'review-input-bindings review-result-bindings ' ]; echo $?)" \
  "rc=$RESULT_RC dirs=$(find "$BIND_HOME" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"

# U2: the typed resolution surface is advisory and strictly read-only. It must normalize a
# canonical local PR target and bare supplied diff without starting the existing engine path.
echo '# U2: review-decision CLI resolution is read-only and proof-bounded'
DECISION_HOME="$TDIR/home-review-decision"
DECISION_REPO="$TDIR/review-decision-repo"
mkdir -p "$DECISION_REPO"
git -C "$DECISION_REPO" init -q
git -C "$DECISION_REPO" config user.email test@example.invalid
git -C "$DECISION_REPO" config user.name 'Engine Test'
printf 'one\n' > "$DECISION_REPO/file.txt"
git -C "$DECISION_REPO" add file.txt && git -C "$DECISION_REPO" commit -qm initial
git -C "$DECISION_REPO" remote add origin https://github.com/acme/widgets.git
printf '%s\n' 'diff --git a/file.txt b/file.txt' '--- a/file.txt' '+++ b/file.txt' '@@ -1 +1 @@' '-one' '+two' > "$TDIR/review-decision.patch"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/review-decision.patch" --input bundle \
  >"$TDIR/review-decision.json" 2>"$TDIR/review-decision.err"
DECISION_RC=$?
check 'cold-start query without complete evidence asks to prepare matching evidence' \
  "$([ "$DECISION_RC" -eq 0 ] && jq -e '.action == "prepare-matching-review-evidence" and .reason == "matching-evidence-requires-preparation" and .effect_request.target.pr == 1983' "$TDIR/review-decision.json" >/dev/null 2>&1; echo $?)" \
  "rc=$DECISION_RC output=$(cat "$TDIR/review-decision.json") stderr=$(cat "$TDIR/review-decision.err")"
check 'review-decision query creates no durable state, lock, sidecar, cache, or binding' \
  "$([ ! -e "$DECISION_HOME" ]; echo $?)" \
  "state=$(find "$DECISION_HOME" -mindepth 1 -maxdepth 2 -print 2>/dev/null | tr '\n' ' ')"

# Git's working-tree proof must accept linked worktrees (.git is a file) while refusing a plain
# directory and a bare repository. These are real CLI calls, not a metadata-shape unit stub.
DECISION_LINKED="$TDIR/review-decision-linked"
git -C "$DECISION_REPO" worktree add -q -b review-decision-linked "$DECISION_LINKED"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_LINKED" --pr 1983 --input connector \
  >"$TDIR/review-decision-linked.json" 2>"$TDIR/review-decision-linked.err"
DECISION_LINKED_RC=$?
check 'review-decision accepts a linked working tree with a .git file' \
  "$([ "$DECISION_LINKED_RC" -eq 0 ] && [ -f "$DECISION_LINKED/.git" ] && jq -e '.action=="run-granted-review"' "$TDIR/review-decision-linked.json" >/dev/null 2>&1; echo $?)" \
  "rc=$DECISION_LINKED_RC output=$(cat "$TDIR/review-decision-linked.json") stderr=$(cat "$TDIR/review-decision-linked.err")"
mkdir -p "$TDIR/review-decision-nonrepo"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 \
  bash "$ENGINE" --review-decision --repo "$TDIR/review-decision-nonrepo" --pr 1983 --input connector \
  >"$TDIR/review-decision-nonrepo.out" 2>"$TDIR/review-decision-nonrepo.err"
DECISION_NONREPO_RC=$?
git clone -q --bare "$DECISION_REPO" "$TDIR/review-decision-bare.git"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 \
  bash "$ENGINE" --review-decision --repo "$TDIR/review-decision-bare.git" --pr 1983 --input connector \
  >"$TDIR/review-decision-bare.out" 2>"$TDIR/review-decision-bare.err"
DECISION_BARE_RC=$?
check 'review-decision rejects non-working-tree and bare repository paths' \
  "$([ "$DECISION_NONREPO_RC" -eq 2 ] && [ "$DECISION_BARE_RC" -eq 2 ] && grep -qF 'local git working tree' "$TDIR/review-decision-nonrepo.err" && grep -qF 'local git working tree' "$TDIR/review-decision-bare.err"; echo $?)" \
  "nonrepo_rc=$DECISION_NONREPO_RC bare_rc=$DECISION_BARE_RC"

# A canonical connector target plus the exact current head is sufficient cold-start proof. The
# advisory template is in-memory only; moving HEAD must invalidate the saved effect request.
DECISION_HEAD="$(git -C "$DECISION_REPO" rev-parse HEAD)"
DECISION_MARKER='pg-run-prospective-acme-widgets-1983'
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 \
  bash "$ENGINE" --review-decision --repo "$DECISION_REPO" --pr 1983 --input connector \
  >"$TDIR/review-decision-run.json" 2>"$TDIR/review-decision-run.err"
DECISION_RUN_RC=$?
check 'cold-start connector proof grants review without a seeded binding' \
  "$([ "$DECISION_RUN_RC" -eq 0 ] && jq -e --arg head "$DECISION_HEAD" '.action == "run-granted-review" and .facts.input.proven and .facts.input.binding_valid and (.facts.evidence.identity | startswith("relation:"))' "$TDIR/review-decision-run.json" >/dev/null 2>&1; echo $?)" \
  "rc=$DECISION_RUN_RC output=$(cat "$TDIR/review-decision-run.json") stderr=$(cat "$TDIR/review-decision-run.err")"
printf 'two\n' > "$DECISION_REPO/file.txt"
git -C "$DECISION_REPO" add file.txt && git -C "$DECISION_REPO" commit -qm moved-head
DECISION_STATE_BEFORE="$(find "$DECISION_HOME" -mindepth 1 -maxdepth 2 -printf '%P\n' | sort)"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 \
  bash "$ENGINE" --review-decision --review-decision-effect "$TDIR/review-decision-run.json" --repo "$DECISION_REPO" --pr 1983 --input connector \
  >"$TDIR/review-decision-replacement.json" 2>"$TDIR/review-decision-replacement.err"
DECISION_REPLACEMENT_RC=$?
DECISION_STATE_AFTER="$(find "$DECISION_HOME" -mindepth 1 -maxdepth 2 -printf '%P\n' | sort)"
check 'stale connector head suppresses the saved effect and returns a new advisory only' \
  "$([ "$DECISION_REPLACEMENT_RC" -eq 0 ] && jq -e --arg old_head "$DECISION_HEAD" '.action == "run-granted-review" and .effect_request.target.head_oid != $old_head' "$TDIR/review-decision-replacement.json" >/dev/null 2>&1 && ! cmp -s "$TDIR/review-decision-run.json" "$TDIR/review-decision-replacement.json"; echo $?)" \
  "rc=$DECISION_REPLACEMENT_RC output=$(cat "$TDIR/review-decision-replacement.json") stderr=$(cat "$TDIR/review-decision-replacement.err")"
check 'effect re-resolution creates no lock, cache, sidecar, or binding mutation' \
  "$([ "$DECISION_STATE_BEFORE" = "$DECISION_STATE_AFTER" ]; echo $?)" \
  "before=$DECISION_STATE_BEFORE after=$DECISION_STATE_AFTER"

# U2 proof modes must validate every relation recorded in U1's immutable input binding; a
# similarly-shaped local patch is never endpoint proof. Scoped evidence additionally needs its
# independent filtering and confirmation lineage to remain byte-identical at re-resolution.
printf 'base\n' > "$DECISION_REPO/proof.txt"
git -C "$DECISION_REPO" add proof.txt && git -C "$DECISION_REPO" commit -qm proof-base
PROOF_BASE="$(git -C "$DECISION_REPO" rev-parse HEAD)"
printf 'head\n' > "$DECISION_REPO/proof.txt"
git -C "$DECISION_REPO" add proof.txt && git -C "$DECISION_REPO" commit -qm proof-head
PROOF_HEAD="$(git -C "$DECISION_REPO" rev-parse HEAD)"
git -C "$DECISION_REPO" diff "$PROOF_BASE" "$PROOF_HEAD" > "$TDIR/proof-endpoint.patch"
cp "$TDIR/proof-endpoint.patch" "$TDIR/proof-raw.patch"
PROOF_ENDPOINT_DIGEST="$(sha256sum "$TDIR/proof-endpoint.patch" | awk '{print $1}')"
PROOF_RAW_DIGEST="$(sha256sum "$TDIR/proof-raw.patch" | awk '{print $1}')"
FULL_MARKER='pg-run-acme-widgets-1983-1700013000-1'
FULL_BINDING="$(jq -cnS --arg cd "$RD_CONTRACT_DIGEST" --arg base "$PROOF_BASE" --arg head "$PROOF_HEAD" --arg endpoint "$PROOF_ENDPOINT_DIGEST" --arg raw "$PROOF_RAW_DIGEST" '{charged_spend_epoch:1700013000,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("full-pr:"+$base+":"+$head),mode:"full-pr",proof:{base_oid:$base,endpoint_digest:$endpoint,head_oid:$head,raw_patch_digest:$raw}},marker:"pg-run-acme-widgets-1983-1700013000-1",record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{head_oid:$head,kind:"pull-request",pr:1983}}')"
PRO_GATE_HOME="$DECISION_HOME" pg_review_input_binding_write "$FULL_MARKER" "$FULL_BINDING"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/proof-endpoint.patch" \
  bash "$ENGINE" --review-decision --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --input bundle \
  >"$TDIR/full-proof.json" 2>"$TDIR/full-proof.err"
FULL_PROOF_RC=$?
check 'full-PR proof requires current base head endpoint and raw patch digests' \
  "$([ "$FULL_PROOF_RC" -eq 0 ] && jq -e '.action == "run-granted-review" and .facts.input.proven and (.facts.evidence.identity | startswith("relation:"))' "$TDIR/full-proof.json" >/dev/null 2>&1; echo $?)" \
  "rc=$FULL_PROOF_RC output=$(cat "$TDIR/full-proof.json") stderr=$(cat "$TDIR/full-proof.err")"
printf 'altered endpoint bytes\n' >> "$TDIR/proof-endpoint.patch"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/proof-endpoint.patch" \
  bash "$ENGINE" --review-decision --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --input bundle \
  >"$TDIR/full-proof-moved.json" 2>"$TDIR/full-proof-moved.err"
FULL_MOVED_RC=$?
check 'changed full-PR endpoint bytes create a new cold-start advisory, not a stale binding match' \
  "$([ "$FULL_MOVED_RC" -eq 0 ] && jq -e '.action == "run-granted-review" and (.facts.evidence.identity | startswith("relation:"))' "$TDIR/full-proof-moved.json" >/dev/null 2>&1; echo $?)" \
  "rc=$FULL_MOVED_RC output=$(cat "$TDIR/full-proof-moved.json") stderr=$(cat "$TDIR/full-proof-moved.err")"

printf '%s\n' 'P0: none' 'P1: none' 'VERDICT: SHIP — prior review accepted' > "$TDIR/scoped-confirmation.md"
printf 'proof.txt\n' > "$TDIR/scoped-manifest"
cp "$TDIR/proof-raw.patch" "$TDIR/scoped-raw-endpoint.patch"
printf 'unreviewed endpoint context\n' >> "$TDIR/scoped-raw-endpoint.patch"
SCOPED_RAW_DIGEST="$(sha256sum "$TDIR/scoped-raw-endpoint.patch" | awk '{print $1}')"
SCOPED_MANIFEST_DIGEST="$(sha256sum "$TDIR/scoped-manifest" | awk '{print $1}')"
SCOPED_CONFIRM_DIGEST="$(sha256sum "$TDIR/scoped-confirmation.md" | awk '{print $1}')"
SCOPED_MARKER='pg-run-acme-widgets-1983-1700013001-2'
SCOPED_BINDING="$(jq -cnS --arg cd "$RD_CONTRACT_DIGEST" --arg base "$PROOF_BASE" --arg head "$PROOF_HEAD" --arg raw "$SCOPED_RAW_DIGEST" --arg reviewed "$PROOF_RAW_DIGEST" --arg manifest "$SCOPED_MANIFEST_DIGEST" --arg lineage "confirmation:$SCOPED_CONFIRM_DIGEST" '{charged_spend_epoch:1700013001,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("scoped-delta:"+$base+":"+$head+":"+$reviewed),mode:"scoped-delta",proof:{base_oid:$base,end_oid:$head,filtering_manifest_digest:$manifest,lineage_identity:$lineage,raw_digest:$raw,reviewed_payload_digest:$reviewed,scope_algorithm:"unified-diff-v1"}},marker:"pg-run-acme-widgets-1983-1700013001-2",record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{head_oid:$head,kind:"pull-request",pr:1983}}')"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/scoped-proof.json" 2>"$TDIR/scoped-proof.err"
SCOPED_PROOF_RC=$?
check 'cold-start scoped delta binds distinct raw/reviewed payload bytes and lineage' \
  "$([ "$SCOPED_PROOF_RC" -eq 0 ] && jq -e '(.action == "run-granted-review") and (.facts.evidence.identity | startswith("relation:"))' "$TDIR/scoped-proof.json" >/dev/null 2>&1; echo $?)" \
  "rc=$SCOPED_PROOF_RC output=$(cat "$TDIR/scoped-proof.json") stderr=$(cat "$TDIR/scoped-proof.err")"
printf 'different scope\n' > "$TDIR/scoped-manifest"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/scoped-proof-stale.json" 2>"$TDIR/scoped-proof-stale.err"
SCOPED_STALE_RC=$?
check 'changed scoped manifest becomes a new cold-start advisory rather than a stale binding match' \
  "$([ "$SCOPED_STALE_RC" -eq 0 ] && jq -e '.action == "run-granted-review"' "$TDIR/scoped-proof-stale.json" >/dev/null 2>&1; echo $?)" \
  "rc=$SCOPED_STALE_RC output=$(cat "$TDIR/scoped-proof-stale.json") stderr=$(cat "$TDIR/scoped-proof-stale.err")"

# Saved scoped effects must reassemble all four independently bound sources. A changed manifest,
# confirmation, or raw endpoint can yield a new advisory, but never dispatches the saved effect.
for scoped_stale in manifest confirmation raw; do
  case "$scoped_stale" in
    manifest) printf 'different scope\n' > "$TDIR/scoped-manifest" ;;
    confirmation) printf '%s\n' 'P0: none' 'P1: none' 'P2: changed' 'VERDICT: SHIP — prior review accepted' > "$TDIR/scoped-confirmation.md" ;;
    raw) printf 'changed raw endpoint bytes\n' >> "$TDIR/scoped-raw-endpoint.patch" ;;
  esac
  SCOPED_STATE_BEFORE="$(find "$DECISION_HOME" -mindepth 1 -maxdepth 2 -printf '%P\n' | sort)"
  env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
    bash "$ENGINE" --review-decision --review-decision-effect "$TDIR/scoped-proof.json" --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
    >"$TDIR/scoped-$scoped_stale-effect.json" 2>"$TDIR/scoped-$scoped_stale-effect.err"
  SCOPED_EFFECT_RC=$?
  SCOPED_STATE_AFTER="$(find "$DECISION_HOME" -mindepth 1 -maxdepth 2 -printf '%P\n' | sort)"
  check "stale scoped $scoped_stale bytes suppress saved-effect dispatch" \
    "$( [ "$SCOPED_EFFECT_RC" -eq 0 ] && jq -e '.action == "run-granted-review"' "$TDIR/scoped-$scoped_stale-effect.json" >/dev/null 2>&1 && ! cmp -s "$TDIR/scoped-proof.json" "$TDIR/scoped-$scoped_stale-effect.json" && [ "$SCOPED_STATE_BEFORE" = "$SCOPED_STATE_AFTER" ]; echo $?)" \
    "rc=$SCOPED_EFFECT_RC output=$(cat "$TDIR/scoped-$scoped_stale-effect.json") stderr=$(cat "$TDIR/scoped-$scoped_stale-effect.err")"
  printf 'proof.txt\n' > "$TDIR/scoped-manifest"
  printf '%s\n' 'P0: none' 'P1: none' 'VERDICT: SHIP — prior review accepted' > "$TDIR/scoped-confirmation.md"
  cp "$TDIR/proof-raw.patch" "$TDIR/scoped-raw-endpoint.patch"
  printf 'unreviewed endpoint context\n' >> "$TDIR/scoped-raw-endpoint.patch"
done

# Canonical bytes without a result binding are recoverable but never a SHIP handoff. A matching
# collect effect repairs the exact marker binding under its own marker lock; replay is idempotent.
cp "$TDIR/proof-raw.patch" "$TDIR/proof-endpoint.patch"
mkdir -p "$DECISION_HOME/completed"
printf '%s\n' 'P0: none' 'P1: none' 'VERDICT: SHIP — canonical review accepted with current proof' > "$DECISION_HOME/completed/$FULL_MARKER"
# A newer equivalent binding with no artifact must not prevent repair of the older artifact selected
# by its own canonical marker.
FULL_REPAIR_NEW_MARKER='pg-run-acme-widgets-1983-1700013002-9'
FULL_REPAIR_NEW_BINDING="$(jq -cS --arg marker "$FULL_REPAIR_NEW_MARKER" '.marker=$marker | .charged_spend_epoch=1700013002' <<<"$FULL_BINDING")"
PRO_GATE_HOME="$DECISION_HOME" pg_review_input_binding_write "$FULL_REPAIR_NEW_MARKER" "$FULL_REPAIR_NEW_BINDING"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/proof-endpoint.patch" \
  bash "$ENGINE" --review-decision --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --input bundle \
  >"$TDIR/repair-before.json" 2>"$TDIR/repair-before.err"
REPAIR_BEFORE_RC=$?
check 'canonical SHIP without result binding is collect-only, never merge eligible' \
  "$([ "$REPAIR_BEFORE_RC" -eq 0 ] && jq -e --arg marker "$FULL_MARKER" '.action == "collect-existing-result" and .effect_request.applicable_ref == $marker and .action != "allow-existing-merge-workflow"' "$TDIR/repair-before.json" >/dev/null 2>&1; echo $?)" \
  "rc=$REPAIR_BEFORE_RC output=$(cat "$TDIR/repair-before.json") stderr=$(cat "$TDIR/repair-before.err")"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/proof-endpoint.patch" \
  bash "$ENGINE" --review-decision --review-decision-effect "$TDIR/repair-before.json" --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --input bundle \
  >"$TDIR/repair-effect.json" 2>"$TDIR/repair-effect.err"
REPAIR_EFFECT_RC=$?
REPAIR_BINDING="$(PRO_GATE_HOME="$DECISION_HOME" pg_review_result_binding_read "$FULL_MARKER" 2>/dev/null || true)"
check 'matching collect effect repairs one validated marker-bound result binding' \
  "$([ "$REPAIR_EFFECT_RC" -eq 0 ] && jq -e --arg marker "$FULL_MARKER" '.marker == $marker and .verdict == "SHIP"' <<<"$REPAIR_BINDING" >/dev/null 2>&1; echo $?)" \
  "rc=$REPAIR_EFFECT_RC binding=$REPAIR_BINDING output=$(cat "$TDIR/repair-effect.json") stderr=$(cat "$TDIR/repair-effect.err")"
REPAIR_BINDING_DIGEST="$(printf '%s' "$REPAIR_BINDING" | sha256sum | awk '{print $1}')"
env PRO_GATE_HOME="$DECISION_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/proof-endpoint.patch" \
  bash "$ENGINE" --review-decision --review-decision-effect "$TDIR/repair-before.json" --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --input bundle \
  >"$TDIR/repair-replay.json" 2>"$TDIR/repair-replay.err"
REPAIR_REPLAY_RC=$?
check 'result-binding repair is idempotent and does not mutate canonical bytes' \
  "$([ "$REPAIR_REPLAY_RC" -eq 0 ] && [ "$(PRO_GATE_HOME="$DECISION_HOME" pg_review_result_binding_digest "$FULL_MARKER")" = "$REPAIR_BINDING_DIGEST" ] && cmp -s "$DECISION_HOME/completed/$FULL_MARKER" "$DECISION_HOME/completed/$FULL_MARKER"; echo $?)" \
  "rc=$REPAIR_REPLAY_RC binding=$(PRO_GATE_HOME="$DECISION_HOME" pg_review_result_binding_read "$FULL_MARKER" 2>/dev/null)"

# U2 precedence is exercised through the real CLI rather than only reducer snapshots. These
# records deliberately share canonical code while their marker, spend epoch, and evidence differ.
echo '# U2: CLI current-evidence and result precedence'
PRECEDENCE_HOME="$TDIR/home-review-precedence"
PC_CONNECTOR_MARKER='pg-run-acme-widgets-1983-1700015000-1'
PC_SCOPED_MARKER='pg-run-acme-widgets-1983-1700015001-2'
PC_CONNECTOR="$(jq -cnS --arg cd "$RD_CONTRACT_DIGEST" --arg head "$PROOF_HEAD" '{charged_spend_epoch:1700015000,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("connector:github.com/acme/widgets:"+$head),mode:"connector",proof:{commit_target:$head,endpoint_digest:null,raw_diff_digest:null,repository_target:"github.com/acme/widgets"}},marker:"pg-run-acme-widgets-1983-1700015000-1",record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{head_oid:$head,kind:"pull-request",pr:1983}}')"
PC_SCOPED="$(jq -cnS --arg cd "$RD_CONTRACT_DIGEST" --arg base "$PROOF_BASE" --arg head "$PROOF_HEAD" --arg raw "$SCOPED_RAW_DIGEST" --arg reviewed "$PROOF_RAW_DIGEST" --arg manifest "$SCOPED_MANIFEST_DIGEST" --arg lineage "confirmation:$SCOPED_CONFIRM_DIGEST" '{charged_spend_epoch:1700015001,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("scoped-delta:"+$base+":"+$head+":"+$reviewed),mode:"scoped-delta",proof:{base_oid:$base,end_oid:$head,filtering_manifest_digest:$manifest,lineage_identity:$lineage,raw_digest:$raw,reviewed_payload_digest:$reviewed,scope_algorithm:"unified-diff-v1"}},marker:"pg-run-acme-widgets-1983-1700015001-2",record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"widgets"},target:{head_oid:$head,kind:"pull-request",pr:1983}}')"
precedence_result() { # marker input verdict accepted artifact
  local marker="$1" input="$2" verdict="$3" accepted="$4" artifact="$5" digest input_digest proof
  input_digest="$(printf '%s' "$input" | sha256sum | awk '{print $1}')"
  proof=null
  printf '%s\n' 'P0: none' "VERDICT: $verdict — fixture." > "$artifact"
  digest="$(sha256sum "$artifact" | awk '{print $1}')"
  jq -cnS --arg cd "$RD_CONTRACT_DIGEST" --arg marker "$marker" --arg digest "$digest" --arg ib "$input_digest" --arg verdict "$verdict" --argjson accepted "$accepted" --argjson proof "$proof" \
    '{accepted_epoch:$accepted,artifact:{digest:$digest,path:("completed/"+$marker)},contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,input_binding_digest:$ib,input_binding_identity:$marker,marker:$marker,named_choice:null,provenance:{outcome:"accepted",validated_epoch:$accepted},record_type:"review-result-binding/v1",record_version:1,ship_proof:$proof,verdict:$verdict}'
}
mkdir -p "$PRECEDENCE_HOME/completed"
PRO_GATE_HOME="$PRECEDENCE_HOME" pg_review_input_binding_write "$PC_CONNECTOR_MARKER" "$PC_CONNECTOR"
PC_CONNECTOR_RESULT="$(precedence_result "$PC_CONNECTOR_MARKER" "$PC_CONNECTOR" NEEDS-DISCUSSION 1700015999 "$PRECEDENCE_HOME/completed/$PC_CONNECTOR_MARKER")"
PRO_GATE_HOME="$PRECEDENCE_HOME" pg_review_result_binding_write "$PC_CONNECTOR_MARKER" "$PC_CONNECTOR_RESULT"

# Default INPUT=both must not downgrade from the absent bundle relation to this valid connector.
env PRO_GATE_HOME="$PRECEDENCE_HOME" PRO_GATE_RUN_LOGS=0 \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" \
  >"$TDIR/precedence-no-bundle.json" 2>"$TDIR/precedence-no-bundle.err"
PC_NO_BUNDLE_RC=$?
check 'default both prepares bundle evidence instead of selecting a current connector result' \
  "$([ "$PC_NO_BUNDLE_RC" -eq 0 ] && jq -e '.action == "prepare-matching-review-evidence" and .facts.completed_results == []' "$TDIR/precedence-no-bundle.json" >/dev/null 2>&1; echo $?)" \
  "rc=$PC_NO_BUNDLE_RC output=$(cat "$TDIR/precedence-no-bundle.json") stderr=$(cat "$TDIR/precedence-no-bundle.err")"

env PRO_GATE_HOME="$PRECEDENCE_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input both \
  >"$TDIR/precedence-scoped-grant.json" 2>"$TDIR/precedence-scoped-grant.err"
PC_SCOPED_GRANT_RC=$?
PC_CODE_ID="github.com:acme/widgets:1983:$PROOF_HEAD"
check 'connector NEEDS-DISCUSSION plus same-head scoped proof grants review without a prompt' \
  "$([ "$PC_SCOPED_GRANT_RC" -eq 0 ] && jq -e --arg code "$PC_CODE_ID" '.action == "run-granted-review" and .facts.input.identity == $code and .facts.prior_review.applicable == false and .facts.prior_review.verdict == "NEEDS-DISCUSSION"' "$TDIR/precedence-scoped-grant.json" >/dev/null 2>&1; echo $?)" \
  "rc=$PC_SCOPED_GRANT_RC output=$(cat "$TDIR/precedence-scoped-grant.json") stderr=$(cat "$TDIR/precedence-scoped-grant.err")"

# The first grant above came only from prepared files; persist equivalent charged history now for
# stable-identity, replay, and result-ordering cases.
PRO_GATE_HOME="$PRECEDENCE_HOME" pg_review_input_binding_write "$PC_SCOPED_MARKER" "$PC_SCOPED"
# The same relation remains stable as marker/epoch history changes, then its completed result is
# terminal rather than another grant.
PC_SCOPED_REPLAY_MARKER='pg-run-acme-widgets-1983-1700015002-3'
PC_SCOPED_REPLAY="$(jq -cS --arg marker "$PC_SCOPED_REPLAY_MARKER" '.marker=$marker | .charged_spend_epoch=1700015002' <<<"$PC_SCOPED")"
PRO_GATE_HOME="$PRECEDENCE_HOME" pg_review_input_binding_write "$PC_SCOPED_REPLAY_MARKER" "$PC_SCOPED_REPLAY"
env PRO_GATE_HOME="$PRECEDENCE_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input both \
  >"$TDIR/precedence-identity.json" 2>"$TDIR/precedence-identity.err"
PC_IDENTITY_RC=$?
check 'current code identity is stable across equivalent marker and charged-epoch changes' \
  "$([ "$PC_IDENTITY_RC" -eq 0 ] && jq -e --arg code "$PC_CODE_ID" '.facts.input.identity == $code' "$TDIR/precedence-identity.json" >/dev/null 2>&1; echo $?)" \
  "rc=$PC_IDENTITY_RC output=$(cat "$TDIR/precedence-identity.json")"
PC_SCOPED_RESULT="$(precedence_result "$PC_SCOPED_MARKER" "$PC_SCOPED" FIX-FIRST 1700015998 "$PRECEDENCE_HOME/completed/$PC_SCOPED_MARKER")"
PRO_GATE_HOME="$PRECEDENCE_HOME" pg_review_result_binding_write "$PC_SCOPED_MARKER" "$PC_SCOPED_RESULT"
env PRO_GATE_HOME="$PRECEDENCE_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input both \
  >"$TDIR/precedence-repeat.json" 2>"$TDIR/precedence-repeat.err"
PC_REPEAT_RC=$?
check 'repeated scoped evidence with its completed result cannot grant another review' \
  "$([ "$PC_REPEAT_RC" -eq 0 ] && jq -e '.action == "fix-review-findings" and .action != "run-granted-review"' "$TDIR/precedence-repeat.json" >/dev/null 2>&1; echo $?)" \
  "rc=$PC_REPEAT_RC output=$(cat "$TDIR/precedence-repeat.json") stderr=$(cat "$TDIR/precedence-repeat.err")"

# Changed scoped evidence retains the previous same-code result as non-applicable progress, not a
# terminal FIX-FIRST route.
printf 'changed scope\n' > "$TDIR/precedence-manifest"
env PRO_GATE_HOME="$PRECEDENCE_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/precedence-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input both \
  >"$TDIR/precedence-changed.json" 2>"$TDIR/precedence-changed.err"
PC_CHANGED_RC=$?
check 'changed evidence is non-applicable prior progress and does not terminal-block continuation' \
  "$([ "$PC_CHANGED_RC" -eq 0 ] && jq -e '.action == "run-granted-review" and .facts.prior_review.applicable == false and .facts.prior_review.verdict == "FIX-FIRST" and .facts.prior_review.evidence_identity != .facts.evidence.identity' "$TDIR/precedence-changed.json" >/dev/null 2>&1; echo $?)" \
  "rc=$PC_CHANGED_RC output=$(cat "$TDIR/precedence-changed.json") stderr=$(cat "$TDIR/precedence-changed.err")"

# Exact-current results use their input binding's charged epoch, not acceptance time or directory
# order. Equal charged epochs retain canonical-result-identity tie-breaking.
PC_ORDER_HOME="$TDIR/home-review-precedence-order"
mkdir -p "$PC_ORDER_HOME/completed"
PC_ORDER_A_MARKER='pg-run-acme-widgets-1983-1700015100-4'
PC_ORDER_Z_MARKER='pg-run-acme-widgets-1983-1700015101-5'
PC_ORDER_A="$(jq -cS --arg marker "$PC_ORDER_A_MARKER" '.marker=$marker | .charged_spend_epoch=1700015100' <<<"$PC_SCOPED")"
PC_ORDER_Z="$(jq -cS --arg marker "$PC_ORDER_Z_MARKER" '.marker=$marker | .charged_spend_epoch=1700015101' <<<"$PC_SCOPED")"
PRO_GATE_HOME="$PC_ORDER_HOME" pg_review_input_binding_write "$PC_ORDER_A_MARKER" "$PC_ORDER_A"
PRO_GATE_HOME="$PC_ORDER_HOME" pg_review_input_binding_write "$PC_ORDER_Z_MARKER" "$PC_ORDER_Z"
PC_ORDER_A_RESULT="$(precedence_result "$PC_ORDER_A_MARKER" "$PC_ORDER_A" FIX-FIRST 1700015999 "$PC_ORDER_HOME/completed/$PC_ORDER_A_MARKER")"
PC_ORDER_Z_RESULT="$(precedence_result "$PC_ORDER_Z_MARKER" "$PC_ORDER_Z" FIX-FIRST 1700015001 "$PC_ORDER_HOME/completed/$PC_ORDER_Z_MARKER")"
PRO_GATE_HOME="$PC_ORDER_HOME" pg_review_result_binding_write "$PC_ORDER_A_MARKER" "$PC_ORDER_A_RESULT"
PRO_GATE_HOME="$PC_ORDER_HOME" pg_review_result_binding_write "$PC_ORDER_Z_MARKER" "$PC_ORDER_Z_RESULT"
PC_ORDER_Z_DIGEST="$(PRO_GATE_HOME="$PC_ORDER_HOME" pg_review_result_binding_digest "$PC_ORDER_Z_MARKER")"
env PRO_GATE_HOME="$PC_ORDER_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input both \
  >"$TDIR/precedence-order.json" 2>"$TDIR/precedence-order.err"
PC_ORDER_RC=$?
check 'exact completed results select newest input charged epoch despite older result acceptance' \
  "$([ "$PC_ORDER_RC" -eq 0 ] && jq -e --arg digest "$PC_ORDER_Z_DIGEST" '.effect_request.applicable_ref == $digest and .action == "fix-review-findings"' "$TDIR/precedence-order.json" >/dev/null 2>&1; echo $?)" \
  "rc=$PC_ORDER_RC output=$(cat "$TDIR/precedence-order.json") stderr=$(cat "$TDIR/precedence-order.err")"

# U2 fresh-dispatch effects are re-reduced at every existing handoff boundary. This cold-start
# fixture proves its full-PR relation in-memory; the effect must create its FIRST durable marker
# binding only after charge and before Oracle submission.
echo '# U2: fresh dispatch charge-to-input-binding guards'
FRESH_HOME="$TDIR/home-fresh-dispatch"
FRESH_REPO="$TDIR/fresh-dispatch-repo"
mkdir -p "$FRESH_REPO"
git -C "$FRESH_REPO" init -q
git -C "$FRESH_REPO" config user.email test@example.invalid
git -C "$FRESH_REPO" config user.name 'Engine Test'
printf 'base\n' > "$FRESH_REPO/fresh.txt"
git -C "$FRESH_REPO" add fresh.txt && git -C "$FRESH_REPO" commit -qm fresh-base
FRESH_BASE="$(git -C "$FRESH_REPO" rev-parse HEAD)"
printf 'head\n' > "$FRESH_REPO/fresh.txt"
git -C "$FRESH_REPO" add fresh.txt && git -C "$FRESH_REPO" commit -qm fresh-head
FRESH_HEAD="$(git -C "$FRESH_REPO" rev-parse HEAD)"
git -C "$FRESH_REPO" remote add origin https://github.com/acme/fresh.git
git -C "$FRESH_REPO" diff "$FRESH_BASE" "$FRESH_HEAD" > "$TDIR/fresh-effect.patch"
cp "$TDIR/fresh-effect.patch" "$TDIR/fresh-endpoint.patch"
FRESH_DIGEST="$(sha256sum "$TDIR/fresh-effect.patch" | awk '{print $1}')"
FRESH_KEY='acme-fresh.git-77'
FRESH_TEMPLATE='pg-run-acme-fresh.git-77-1700014000-1'
FRESH_BINDING="$(jq -cnS --arg cd "$RD_CONTRACT_DIGEST" --arg base "$FRESH_BASE" --arg head "$FRESH_HEAD" --arg digest "$FRESH_DIGEST" --arg marker "$FRESH_TEMPLATE" '{charged_spend_epoch:1700014000,contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,evidence:{identity:("full-pr:"+$base+":"+$head),mode:"full-pr",proof:{base_oid:$base,endpoint_digest:$digest,head_oid:$head,raw_patch_digest:$digest}},marker:$marker,record_type:"review-input-binding/v1",record_version:1,repository:{host:"github.com",owner:"acme",repo:"fresh"},target:{head_oid:$head,kind:"pull-request",pr:77}}')"
mkdir -p "$TDIR/fresh-bin"
cat > "$TDIR/fresh-bin/oracle" <<'FRESH_ORACLE'
#!/usr/bin/env bash
find "${PG_TEST_FRESH_HOME:?}/review-input-bindings" -type f -name 'pg-run-*' -print -quit | grep -q . || exit 99
printf 'submitted\n' >> "${PG_TEST_FRESH_ORACLE:?}"
out=""
while [ $# -gt 0 ]; do
  case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac
done
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP - fixture.\n' > "$out"
FRESH_ORACLE
chmod +x "$TDIR/fresh-bin/oracle"
fresh_reset_state() {
  rm -rf "$FRESH_HOME"
}
fresh_query() {
  local target="${1:-77}"
  env PRO_GATE_HOME="$FRESH_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/fresh-endpoint.patch" \
    bash "$ENGINE" --review-decision --repo "$FRESH_REPO" --pr "$target" --diff "$TDIR/fresh-effect.patch" --input bundle
}
fresh_effect() {
  local target="${3:-77}"
  env PATH="$TDIR/fresh-bin:$PATH" PRO_GATE_HOME="$FRESH_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/fresh-endpoint.patch" \
    ORACLE_BROWSER_PORT="$PORT" PRO_GATE_MIN_UPTIME=0 PRO_GATE_SELF_HEAL=0 PRO_GATE_ORACLE_BIN="$TDIR/fresh-bin/oracle" \
    PG_TEST_FRESH_HOME="$FRESH_HOME" PG_TEST_FRESH_ORACLE="$TDIR/fresh-oracle.calls" PRO_GATE_EARLY_PROBE_SECS=0 \
    bash "$ENGINE" --review-decision --review-decision-effect "$1" --repo "$FRESH_REPO" --pr "$target" --diff "$TDIR/fresh-effect.patch" --input bundle --out "$2" --timeout 5s \
    >"$TDIR/fresh.stdout" 2>"$TDIR/fresh.stderr"
  FRESH_RC=$?
}
fresh_reset_state
FRESH_ADVISORY="$(fresh_query)"
check 'cold-start full-PR fixture resolves to advisory run-granted-review without a binding' \
  "$(jq -e '.action == "run-granted-review"' <<<"$FRESH_ADVISORY" >/dev/null 2>&1 && [ ! -e "$FRESH_HOME" ]; echo $?)" "$FRESH_ADVISORY"
printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
: > "$TDIR/fresh-oracle.calls"
start_mock "$TDIR/tab.txt" "$ORGANIZER_STATE"
fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-success.md"
FRESH_NEW_MARKER="$(find "$FRESH_HOME/review-input-bindings" -type f -name 'pg-run-*' ! -name "$FRESH_TEMPLATE" -printf '%f\n' | head -1)"
FRESH_NEW_BINDING="$(PRO_GATE_HOME="$FRESH_HOME" pg_review_input_binding_read "$FRESH_NEW_MARKER" 2>/dev/null || true)"
check 'matching fresh effect charges only after marker-bound input binding persists before Oracle submission' \
  "$([ "$FRESH_RC" -eq 0 ] && [ -s "$TDIR/fresh-oracle.calls" ] && jq -e --arg m "$FRESH_NEW_MARKER" '.marker==$m and .charged_spend_epoch > 0' <<<"$FRESH_NEW_BINDING" >/dev/null 2>&1; echo $?)" \
  "rc=$FRESH_RC marker=$FRESH_NEW_MARKER binding=$FRESH_NEW_BINDING stderr=$(cat "$TDIR/fresh.stderr")"
check 'successful fresh charge records the exact binding epoch before submission' \
  "$(jq -e --argjson epoch "$(awk -F'\t' 'NR==1{print $7}' "$FRESH_HOME/run-meta/$FRESH_NEW_MARKER" 2>/dev/null || echo 0)" '.charged_spend_epoch == $epoch' <<<"$FRESH_NEW_BINDING" >/dev/null 2>&1; echo $?)" \
  "meta=$(cat "$FRESH_HOME/run-meta/$FRESH_NEW_MARKER" 2>/dev/null) binding=$FRESH_NEW_BINDING"

# Each durable predecessor supersedes the saved advisory request before pre-lock dispatch; none
# may reach the browser. The unknown-fate fixture intentionally has run-meta only.
for fresh_kind in completed active reserved unknown-fate; do
  fresh_reset_state
  FRESH_ADVISORY="$(fresh_query)"; printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
  : > "$TDIR/fresh-oracle.calls"
  case "$fresh_kind" in
    completed)
      mkdir -p "$FRESH_HOME/completed"
      PRO_GATE_HOME="$FRESH_HOME" pg_review_input_binding_write "$FRESH_TEMPLATE" "$FRESH_BINDING"
      printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP - existing.\n' > "$FRESH_HOME/completed/$FRESH_TEMPLATE" ;;
    active)
      mkdir -p "$FRESH_HOME/active"
      printf 'pg-run-acme-fresh.git-77-1700014001-2\t%s\t%s\t%s\tremote-chrome\ttoken\tcharged\t1700014001\n' "$TDIR/x" "$$" "$(date +%s)" > "$FRESH_HOME/active/$FRESH_KEY" ;;
    reserved)
      mkdir -p "$FRESH_HOME/in-progress"
      printf '%s\t%s\t%s\t0\t\n' "$FRESH_KEY" "$TDIR/x" "$(date +%s)" > "$FRESH_HOME/in-progress/pg-run-acme-fresh.git-77-1700014002-3" ;;
    unknown-fate)
      FRESH_UNKNOWN_MARKER='pg-run-acme-fresh.git-77-1700014003-4'
      mkdir -p "$FRESH_HOME/run-meta"
      printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700014003\n' "$FRESH_KEY" "$TDIR/x" > "$FRESH_HOME/run-meta/$FRESH_UNKNOWN_MARKER" ;;
  esac
  fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-$fresh_kind.md"
  check "fresh pre-lock guard supersedes advisory for $fresh_kind without Oracle dispatch" \
    "$([ ! -s "$TDIR/fresh-oracle.calls" ]; echo $?)" \
    "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"
  [ "$fresh_kind" != unknown-fate ] || check 'effect freshness exposes run-meta without terminal bytes as recoverable unknown-fate work' \
    "$([ "$FRESH_RC" -eq 0 ] && jq -e --arg marker "$FRESH_UNKNOWN_MARKER" '.action=="recover-existing-review" and .effect_request.applicable_ref==$marker' "$TDIR/fresh.stdout" >/dev/null 2>&1; echo $?)" \
    "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"
done

# Run-meta-only recovery must be visible to the public query that issues effect requests, not
# discovered for the first time after a run-granted effect enters pre-lock dispatch. Replaying the
# exact recovery effect must preserve its marker and spend nothing instead of oscillating back to
# run-granted-review.
fresh_reset_state
FRESH_UNKNOWN_MARKER='pg-run-acme-fresh.git-77-1700014003-4'
mkdir -p "$FRESH_HOME/run-meta" "$FRESH_HOME/rounds"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700014003\n' "$FRESH_KEY" "$TDIR/x" > "$FRESH_HOME/run-meta/$FRESH_UNKNOWN_MARKER"
printf '%s\n' "$(date +%s)" > "$FRESH_HOME/rounds/$FRESH_KEY"
FRESH_RECOVERY="$(fresh_query)"
check 'public decision query exposes run-meta-only recovery with its exact marker' \
  "$(jq -e --arg marker "$FRESH_UNKNOWN_MARKER" '.action=="recover-existing-review" and .effect_request.applicable_ref==$marker' <<<"$FRESH_RECOVERY" >/dev/null 2>&1; echo $?)" \
  "$FRESH_RECOVERY"
printf '%s\n' "$FRESH_RECOVERY" > "$TDIR/fresh-recovery.json"
: > "$TDIR/fresh-oracle.calls"
fresh_effect "$TDIR/fresh-recovery.json" "$TDIR/fresh-recovery.md"
check 'run-meta-only recovery effect stays stable without Oracle dispatch or another spend' \
  "$([ "$FRESH_RC" -eq 0 ] && [ ! -s "$TDIR/fresh-oracle.calls" ] && [ "$(wc -l < "$FRESH_HOME/rounds/$FRESH_KEY")" -eq 1 ] && jq -e --arg marker "$FRESH_UNKNOWN_MARKER" '.action=="recover-existing-review" and .effect_request.applicable_ref==$marker' "$TDIR/fresh.stdout" >/dev/null 2>&1; echo $?)" \
  "rc=$FRESH_RC rounds=$(wc -l < "$FRESH_HOME/rounds/$FRESH_KEY") stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"
FRESH_SNAPSHOT="$(PRO_GATE_HOME="$FRESH_HOME" pg_attempt_snapshot github.com acme fresh 77 "$FRESH_KEY")"
check 'attempt snapshot reports the same run-meta-only recovery marker and charge' \
  "$(jq -e --arg marker "$FRESH_UNKNOWN_MARKER" '.marker==$marker and .state=="unknown-fate" and .source=="run-meta" and .recoverable and (.fresh_eligible|not) and .charged_spend_epoch==1700014003' <<<"$FRESH_SNAPSHOT" >/dev/null 2>&1; echo $?)" \
  "$FRESH_SNAPSHOT"
FRESH_LEADING_ZERO="$(fresh_query 077)"
check 'leading-zero PR spelling normalizes to the same run-meta recovery identity' \
  "$(jq -e --arg marker "$FRESH_UNKNOWN_MARKER" '.action=="recover-existing-review" and .effect_request.target.pr==77 and .effect_request.applicable_ref==$marker' <<<"$FRESH_LEADING_ZERO" >/dev/null 2>&1; echo $?)" \
  "$FRESH_LEADING_ZERO"
printf '%s\n' "$FRESH_LEADING_ZERO" > "$TDIR/fresh-leading-zero.json"
fresh_effect "$TDIR/fresh-leading-zero.json" "$TDIR/fresh-leading-zero.md" 077
check 'leading-zero recovery effect remains stable without a duplicate spend' \
  "$([ "$FRESH_RC" -eq 0 ] && [ "$(wc -l < "$FRESH_HOME/rounds/$FRESH_KEY")" -eq 1 ] && jq -e --arg marker "$FRESH_UNKNOWN_MARKER" '.action=="recover-existing-review" and .effect_request.applicable_ref==$marker' "$TDIR/fresh.stdout" >/dev/null 2>&1; echo $?)" \
  "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"

# A review bound to an older head, or to a PR GitHub proves merged/closed, is obsolete rather than
# unsubmitted. Exact recovery moves only its reservation to the monotonic non-capacity state; the
# charge, immutable binding, marker-addressed audit path, and optional harvest all remain durable.
echo '# v0.37.2: proof-backed superseded review capacity release'
SUPER_KEY='acme-fresh-77'
SUPER_GH="$TDIR/bin/gh-superseded"
SUPER_GH_CALLS="$TDIR/superseded-gh.calls"
cat > "$SUPER_GH" <<'SUPER_GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PG_TEST_GH_CALLS:?}"
case "${PG_TEST_GH_MODE:-ok}" in
  fail) exit 1 ;;
  malformed) printf '%s\n' '{not-json'; exit 0 ;;
  semantic) jq -nc --arg head "${PG_TEST_GH_HEAD:-}" '{state:"UNKNOWN",headRefOid:$head}'; exit 0 ;;
esac
jq -nc --arg state "${PG_TEST_GH_STATE:-OPEN}" --arg head "${PG_TEST_GH_HEAD:-}" \
  '{state:$state,headRefOid:$head}'
SUPER_GH_STUB
chmod +x "$SUPER_GH"
super_seed() { # home marker epoch bound-head
  local home="$1" marker="$2" epoch="$3" bound_head="$4" binding
  mkdir -p "$home/in-progress" "$home/run-meta" "$home/rounds"
  printf '%s\n' "$epoch" > "$home/rounds/$SUPER_KEY"
  printf 'github.com\tacme\tfresh\t%s\t77\t%s\t%s\n' "$SUPER_KEY" "$TDIR/superseded-audit.md" "$epoch" > "$home/run-meta/$marker"
  printf '%s\t%s\t%s\t0\t1\tGPT-X\t%s\tgenerating\n' "$SUPER_KEY" "$TDIR/superseded-audit.md" "$(date +%s)" "$epoch" > "$home/in-progress/$marker"
  binding="$(jq -cS --arg marker "$marker" --arg head "$bound_head" --argjson epoch "$epoch" \
    '.marker=$marker | .charged_spend_epoch=$epoch | .target.head_oid=$head | .evidence.proof.head_oid=$head | .evidence.identity=("full-pr:" + .evidence.proof.base_oid + ":" + $head)' <<<"$FRESH_BINDING")"
  PRO_GATE_HOME="$home" pg_review_input_binding_write "$marker" "$binding"
}
super_replace_binding() { # home marker jq-filter -- preserve immutable binding's canonical bytes
  local home="$1" marker="$2" filter="$3" current replacement f
  current="$(PRO_GATE_HOME="$home" pg_review_input_binding_read "$marker")" || return 1
  replacement="$(jq -cS "$filter" <<<"$current")" || return 1
  f="$home/review-input-bindings/$marker"
  printf '%s' "$replacement" > "$f.cross" && mv "$f.cross" "$f"
}
super_recover() { # home marker mode state current-head
  local home="$1" marker="$2" mode="$3" state="$4" head="$5"
  env PRO_GATE_HOME="$home" ORACLE_BROWSER_PORT=65530 PRO_GATE_SELF_HEAL=0 \
    PRO_GATE_GH_BIN="$SUPER_GH" PG_TEST_GH_CALLS="$SUPER_GH_CALLS" PG_TEST_GH_MODE="$mode" \
    PG_TEST_GH_STATE="$state" PG_TEST_GH_HEAD="$head" \
    PRO_GATE_ORACLE_BIN="$TDIR/bin/oracle-recover-sentinel" PG_TEST_RECOVER_ORACLE_SENTINEL="$TDIR/recover-oracle-sentinel" NODE_OPTIONS= \
    bash "$ENGINE" --recover "$marker" --timeout 1s >"$TDIR/super.stdout" 2>"$TDIR/super.stderr"
  RC=$?
}

SUPER_HEAD_HOME="$TDIR/home-superseded-head"
SUPER_HEAD_MARKER='pg-run-acme-fresh-77-1700014100-1'
super_seed "$SUPER_HEAD_HOME" "$SUPER_HEAD_MARKER" 1700014100 "$FRESH_BASE"
# Pre-v0.31 harvest fallback used literal `diff` with no model or spend. Exact immutable binding +
# canonical run-meta prove the missing spend before the atomic supersession transition fills it.
printf 'diff\t%s\t1700014000\t2\t1\t\t\tgenerating\n' "$TDIR/superseded-audit.md" > "$SUPER_HEAD_HOME/in-progress/$SUPER_HEAD_MARKER"
: > "$SUPER_GH_CALLS"; : > "$TDIR/recover-oracle-sentinel"
super_recover "$SUPER_HEAD_HOME" "$SUPER_HEAD_MARKER" ok OPEN "$FRESH_HEAD"
check 'exact recovery atomically canonicalizes and supersedes a legacy diff reservation' \
  "$([ "$RC" -eq 6 ] && grep -qx 'Review superseded' "$TDIR/super.stderr" \
     && grep -qF 'pr view 77 --repo github.com/acme/fresh --json state,headRefOid' "$SUPER_GH_CALLS" \
     && [ "$(awk -F'\t' 'NR==1{print $1" "$2" "$3" "$4" "$5" "$6" "$7" "$8}' "$SUPER_HEAD_HOME/in-progress/$SUPER_HEAD_MARKER")" = "$SUPER_KEY $TDIR/superseded-audit.md 1700014000 2 1  1700014100 superseded" ] \
     && [ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" \
  "rc=$RC state=$(cat "$SUPER_HEAD_HOME/in-progress/$SUPER_HEAD_MARKER") stderr=$(cat "$TDIR/super.stderr")"
SUPER_LEGACY_RECORD="$(cat "$SUPER_HEAD_HOME/in-progress/$SUPER_HEAD_MARKER")"
PRO_GATE_HOME="$SUPER_HEAD_HOME" pg_reservation_supersede "$SUPER_HEAD_MARKER" "$SUPER_KEY" 1700014100 "$FRESH_BASE"
SUPER_REPLAY_RC=$?
check 'canonical supersession replay returns success and is byte-idempotent' \
  "$([ "$SUPER_REPLAY_RC" -eq 0 ] \
     && [ "$(cat "$SUPER_HEAD_HOME/in-progress/$SUPER_HEAD_MARKER")" = "$SUPER_LEGACY_RECORD" ]; echo $?)" \
  "rc=$SUPER_REPLAY_RC before=$SUPER_LEGACY_RECORD after=$(cat "$SUPER_HEAD_HOME/in-progress/$SUPER_HEAD_MARKER")"
check 'supersession retains the charged round and durable proof event' \
  "$([ "$(wc -l < "$SUPER_HEAD_HOME/rounds/$SUPER_KEY")" -eq 1 ] \
     && jq -e --arg marker "$SUPER_HEAD_MARKER" --arg old "$FRESH_BASE" --arg new "$FRESH_HEAD" \
       'select(.outcome=="superseded" and .marker==$marker and .charge_retained and (.holds_capacity|not) and .proof==("head-moved:"+$old+":"+$new))' \
       "$SUPER_HEAD_HOME/ledger.jsonl" >/dev/null 2>&1; echo $?)" \
  "rounds=$(cat "$SUPER_HEAD_HOME/rounds/$SUPER_KEY") ledger=$(cat "$SUPER_HEAD_HOME/ledger.jsonl" 2>/dev/null)"
SUPER_SNAPSHOT="$(PRO_GATE_HOME="$SUPER_HEAD_HOME" pg_attempt_snapshot github.com acme fresh 77 "$SUPER_KEY")"
SUPER_PLAN="$(PRO_GATE_HOME="$SUPER_HEAD_HOME" pg_reservation_slot_plan 1)"
check 'superseded snapshot is fresh-eligible and holds zero capacity while remaining collectable' \
  "$(jq -e --arg marker "$SUPER_HEAD_MARKER" '.marker==$marker and .source=="reservation" and .state=="superseded" and (.recoverable|not) and .fresh_eligible' <<<"$SUPER_SNAPSHOT" >/dev/null 2>&1 \
     && [ "$(PRO_GATE_HOME="$SUPER_HEAD_HOME" pg_reservation_holding_count)" -eq 0 ] \
     && [ "$(PRO_GATE_HOME="$SUPER_HEAD_HOME" pg_reservation_count)" -eq 1 ] \
     && [ "$SUPER_PLAN" = '1||1' ]; echo $?)" \
  "snapshot=$SUPER_SNAPSHOT plan=$SUPER_PLAN"
PRO_GATE_HOME="$SUPER_HEAD_HOME" bash "$ENGINE" --status "$SUPER_HEAD_MARKER" --json > "$TDIR/superseded-empty-model-status.json" 2>/dev/null
check 'status preserves empty model and positional fields after legacy canonicalization' \
  "$(jq -e --arg key "$SUPER_KEY" '.reservations[0].pr==$key and .reservations[0].model=="" and .reservations[0].miss_streak==2 and .reservations[0].state=="superseded-awaiting-optional-harvest"' "$TDIR/superseded-empty-model-status.json" >/dev/null 2>&1; echo $?)" \
  "$(jq -c '.reservations[0]' "$TDIR/superseded-empty-model-status.json" 2>/dev/null)"
SUPER_LIVE_MARKER='pg-run-acme-fresh-77-1700014101-9'
printf '%s\t%s\t%s\t0\t2\tGPT-X\t1700014101\tgenerating\n' "$SUPER_KEY" "$TDIR/superseded-live.md" "$(date +%s)" > "$SUPER_HEAD_HOME/in-progress/$SUPER_LIVE_MARKER"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700014101\n' "$SUPER_KEY" "$TDIR/superseded-live.md" > "$SUPER_HEAD_HOME/run-meta/$SUPER_LIVE_MARKER"
SUPER_LIVE_SNAPSHOT="$(PRO_GATE_HOME="$SUPER_HEAD_HOME" pg_attempt_snapshot github.com acme fresh 77 "$SUPER_KEY")"
check 'a capacity-holding reservation outranks an older audit-only superseded marker' \
  "$(jq -e --arg marker "$SUPER_LIVE_MARKER" '.marker==$marker and .source=="reservation" and .state=="recoverable" and .recoverable and (.fresh_eligible|not)' <<<"$SUPER_LIVE_SNAPSHOT" >/dev/null 2>&1; echo $?)" \
  "$SUPER_LIVE_SNAPSHOT"
rm -f "$SUPER_HEAD_HOME/in-progress/$SUPER_LIVE_MARKER" "$SUPER_HEAD_HOME/run-meta/$SUPER_LIVE_MARKER"

# Every generic mutation seam is monotonic: a still-rendering optional harvest may refresh output,
# state, or miss bookkeeping, but none can turn obsolete work back into account occupancy.
PRO_GATE_HOME="$SUPER_HEAD_HOME" pg_reservation_write "$SUPER_HEAD_MARKER" "$SUPER_KEY" "$TDIR/superseded-refreshed.md" 1 GPT-Y 1700014100
PRO_GATE_HOME="$SUPER_HEAD_HOME" pg_reservation_set_state "$SUPER_HEAD_MARKER" generating
SUPER_MISS="$(PRO_GATE_HOME="$SUPER_HEAD_HOME" PRO_GATE_RECONCILE_INTERVAL=0 pg_reservation_note_miss "$SUPER_HEAD_MARKER")"
check 'write, state refresh, and confirmed miss cannot re-arm or delete superseded work' \
  "$([ "$SUPER_MISS" = 'retained superseded' ] \
     && [ "$(awk -F'\t' 'NR==1{print $2" "$4" "$8}' "$SUPER_HEAD_HOME/in-progress/$SUPER_HEAD_MARKER")" = "$TDIR/superseded-refreshed.md 0 superseded" ]; echo $?)" \
  "miss=$SUPER_MISS record=$(cat "$SUPER_HEAD_HOME/in-progress/$SUPER_HEAD_MARKER")"

# Supersession outranks stale cross-bind/unbound sidecars on status and is ignored by current-head
# typed admission, which can use otherwise-idle ChatGPT capacity for the replacement evidence.
mkdir -p "$SUPER_HEAD_HOME/crossbound"
printf 'old cross-bind\n' > "$SUPER_HEAD_HOME/crossbound/$SUPER_HEAD_MARKER"
: > "$TDIR/superseded-refreshed.md.unbound.1"
PRO_GATE_HOME="$SUPER_HEAD_HOME" bash "$ENGINE" --status "$SUPER_HEAD_MARKER" --json > "$TDIR/superseded-status.json" 2>/dev/null
check 'status reports superseded as non-recoverable non-capacity despite stale sidecars' \
  "$(jq -e --arg marker "$SUPER_HEAD_MARKER" '.recoverable==false and .attempt.marker==$marker and .attempt.state=="superseded" and .attempt.fresh_eligible and .reservations[0].marker==$marker and .reservations[0].state=="superseded-awaiting-optional-harvest" and (.reservations[0].holds_capacity|not) and (.next_step|contains("superseded"))' "$TDIR/superseded-status.json" >/dev/null 2>&1; echo $?)" \
  "$(cat "$TDIR/superseded-status.json")"
mkdir -p "$SUPER_HEAD_HOME/active"
printf '%s\t%s\t99999999\t%s\tremote-chrome\ttoken\tsubmitted\t1700014100\n' \
  "$SUPER_HEAD_MARKER" "$TDIR/superseded-refreshed.md" "$(date +%s)" > "$SUPER_HEAD_HOME/active/$SUPER_KEY"
env PRO_GATE_HOME="$SUPER_HEAD_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/fresh-endpoint.patch" \
  bash "$ENGINE" --review-decision --json --repo "$FRESH_REPO" --pr 77 --diff "$TDIR/fresh-effect.patch" --input bundle \
  > "$TDIR/superseded-decision.json" 2> "$TDIR/superseded-decision.err"
SUPER_DECISION_RC=$?
check 'typed current-head admission ignores superseded ownership and same-marker stale active state' \
  "$([ "$SUPER_DECISION_RC" -eq 0 ] && jq -e '.action=="run-granted-review" and .facts.reservation.state=="none" and .facts.active_index.state=="none"' "$TDIR/superseded-decision.json" >/dev/null 2>&1; echo $?)" \
  "rc=$SUPER_DECISION_RC output=$(cat "$TDIR/superseded-decision.json") stderr=$(cat "$TDIR/superseded-decision.err")"

# MERGED and CLOSED are independently sufficient even when the head has not moved.
for SUPER_TERMINAL_STATE in MERGED CLOSED; do
  SUPER_TERM_HOME="$TDIR/home-superseded-${SUPER_TERMINAL_STATE,,}"
  SUPER_TERM_MARKER="pg-run-acme-fresh-77-1700014101-${SUPER_TERMINAL_STATE:0:1}"
  super_seed "$SUPER_TERM_HOME" "$SUPER_TERM_MARKER" 1700014101 "$FRESH_BASE"
  super_recover "$SUPER_TERM_HOME" "$SUPER_TERM_MARKER" ok "$SUPER_TERMINAL_STATE" "$FRESH_BASE"
  # #134: the proof now carries the bound head the caller validated against GitHub, so the ledger
  # records WHICH head was superseded and the caller has a head to feed the compare-and-swap.
  # Asserting the fuller string keeps this check strictly stronger than before.
  check "GitHub $SUPER_TERMINAL_STATE proof supersedes a same-head review" \
    "$([ "$RC" -eq 6 ] && [ "$(awk -F'\t' 'NR==1{print $8}' "$SUPER_TERM_HOME/in-progress/$SUPER_TERM_MARKER")" = superseded ] \
       && jq -e --arg proof "pr-${SUPER_TERMINAL_STATE,,}:$FRESH_BASE" 'select(.proof==$proof)' "$SUPER_TERM_HOME/ledger.jsonl" >/dev/null 2>&1; echo $?)" \
    "rc=$RC state=$(cat "$SUPER_TERM_HOME/in-progress/$SUPER_TERM_MARKER") ledger=$(cat "$SUPER_TERM_HOME/ledger.jsonl" 2>/dev/null)"
done

# Unavailable GitHub or unavailable immutable binding is inconclusive. Both remain generating and
# enter ordinary fail-closed browser recovery; the missing-binding case never calls GitHub at all.
SUPER_FAIL_HOME="$TDIR/home-superseded-gh-fail"
SUPER_FAIL_MARKER='pg-run-acme-fresh-77-1700014102-2'
super_seed "$SUPER_FAIL_HOME" "$SUPER_FAIL_MARKER" 1700014102 "$FRESH_BASE"
: > "$SUPER_GH_CALLS"
super_recover "$SUPER_FAIL_HOME" "$SUPER_FAIL_MARKER" fail OPEN "$FRESH_HEAD"
check 'GitHub proof failure stays generating and fail-closed' \
  "$([ "$RC" -eq 3 ] && [ -s "$SUPER_GH_CALLS" ] \
     && [ "$(awk -F'\t' 'NR==1{print $8}' "$SUPER_FAIL_HOME/in-progress/$SUPER_FAIL_MARKER")" = generating ]; echo $?)" \
  "rc=$RC state=$(cat "$SUPER_FAIL_HOME/in-progress/$SUPER_FAIL_MARKER") stderr=$(cat "$TDIR/super.stderr")"
: > "$SUPER_GH_CALLS"
super_recover "$SUPER_FAIL_HOME" "$SUPER_FAIL_MARKER" malformed OPEN "$FRESH_HEAD"
check 'malformed GitHub response stays generating and fail-closed' \
  "$([ "$RC" -eq 3 ] && [ -s "$SUPER_GH_CALLS" ] \
     && [ "$(awk -F'\t' 'NR==1{print $8}' "$SUPER_FAIL_HOME/in-progress/$SUPER_FAIL_MARKER")" = generating ]; echo $?)" \
  "rc=$RC state=$(cat "$SUPER_FAIL_HOME/in-progress/$SUPER_FAIL_MARKER") stderr=$(cat "$TDIR/super.stderr")"
: > "$SUPER_GH_CALLS"
super_recover "$SUPER_FAIL_HOME" "$SUPER_FAIL_MARKER" semantic OPEN "$FRESH_HEAD"
check 'unknown GitHub state with a valid different head cannot supersede' \
  "$([ "$RC" -eq 3 ] && [ -s "$SUPER_GH_CALLS" ] \
     && [ "$(awk -F'\t' 'NR==1{print $8}' "$SUPER_FAIL_HOME/in-progress/$SUPER_FAIL_MARKER")" = generating ]; echo $?)" \
  "rc=$RC state=$(cat "$SUPER_FAIL_HOME/in-progress/$SUPER_FAIL_MARKER") stderr=$(cat "$TDIR/super.stderr")"
: > "$SUPER_GH_CALLS"
super_recover "$SUPER_FAIL_HOME" "$SUPER_FAIL_MARKER" ok OPEN a
check 'short hex GitHub head is malformed and cannot supersede' \
  "$([ "$RC" -eq 3 ] && [ -s "$SUPER_GH_CALLS" ] \
     && [ "$(awk -F'\t' 'NR==1{print $8}' "$SUPER_FAIL_HOME/in-progress/$SUPER_FAIL_MARKER")" = generating ]; echo $?)" \
  "rc=$RC state=$(cat "$SUPER_FAIL_HOME/in-progress/$SUPER_FAIL_MARKER") stderr=$(cat "$TDIR/super.stderr")"
SUPER_SAME_HOME="$TDIR/home-superseded-same-head"
SUPER_SAME_MARKER='pg-run-acme-fresh-77-1700014105-5'
super_seed "$SUPER_SAME_HOME" "$SUPER_SAME_MARKER" 1700014105 "$FRESH_BASE"
super_recover "$SUPER_SAME_HOME" "$SUPER_SAME_MARKER" ok OPEN "$FRESH_BASE"
check 'open PR at the exact bound head remains generating' \
  "$([ "$RC" -eq 3 ] \
     && [ "$(awk -F'\t' 'NR==1{print $8}' "$SUPER_SAME_HOME/in-progress/$SUPER_SAME_MARKER")" = generating ]; echo $?)" \
  "rc=$RC state=$(cat "$SUPER_SAME_HOME/in-progress/$SUPER_SAME_MARKER") stderr=$(cat "$TDIR/super.stderr")"
SUPER_NOBIND_HOME="$TDIR/home-superseded-no-binding"
SUPER_NOBIND_MARKER='pg-run-acme-fresh-77-1700014103-3'
super_seed "$SUPER_NOBIND_HOME" "$SUPER_NOBIND_MARKER" 1700014103 "$FRESH_BASE"
rm -f "$SUPER_NOBIND_HOME/review-input-bindings/$SUPER_NOBIND_MARKER"
: > "$SUPER_GH_CALLS"
super_recover "$SUPER_NOBIND_HOME" "$SUPER_NOBIND_MARKER" ok MERGED "$FRESH_HEAD"
check 'missing immutable binding stays generating without consulting GitHub' \
  "$([ "$RC" -eq 3 ] && [ ! -s "$SUPER_GH_CALLS" ] \
     && [ "$(awk -F'\t' 'NR==1{print $8}' "$SUPER_NOBIND_HOME/in-progress/$SUPER_NOBIND_MARKER")" = generating ]; echo $?)" \
  "rc=$RC calls=$(cat "$SUPER_GH_CALLS") state=$(cat "$SUPER_NOBIND_HOME/in-progress/$SUPER_NOBIND_MARKER")"
SUPER_CROSS_HOME="$TDIR/home-superseded-cross-binding"
SUPER_CROSS_MARKER='pg-run-acme-fresh-77-1700014104-4'
super_seed "$SUPER_CROSS_HOME" "$SUPER_CROSS_MARKER" 1700014104 "$FRESH_BASE"
super_replace_binding "$SUPER_CROSS_HOME" "$SUPER_CROSS_MARKER" '.repository.repo="other"'
SUPER_CROSS_BINDING="$(PRO_GATE_HOME="$SUPER_CROSS_HOME" pg_review_input_binding_read "$SUPER_CROSS_MARKER" 2>/dev/null || true)"
: > "$SUPER_GH_CALLS"
super_recover "$SUPER_CROSS_HOME" "$SUPER_CROSS_MARKER" ok MERGED "$FRESH_HEAD"
check 'valid-but-crossed repository binding cannot supersede another canonical attempt' \
  "$([ "$RC" -eq 3 ] && [ -n "$SUPER_CROSS_BINDING" ] && [ ! -s "$SUPER_GH_CALLS" ] \
     && [ "$(awk -F'\t' 'NR==1{print $8}' "$SUPER_CROSS_HOME/in-progress/$SUPER_CROSS_MARKER")" = generating ]; echo $?)" \
  "rc=$RC calls=$(cat "$SUPER_GH_CALLS") binding=$SUPER_CROSS_BINDING"
SUPER_BADKEY_HOME="$TDIR/home-superseded-bad-key"
SUPER_BADKEY_MARKER='pg-run-acme-fresh-77-1700014106-6'
super_seed "$SUPER_BADKEY_HOME" "$SUPER_BADKEY_MARKER" 1700014106 "$FRESH_BASE"
printf 'other-77\t%s\t1700014106\t0\t1\tGPT-X\t1700014106\tgenerating\n' "$TDIR/superseded-audit.md" > "$SUPER_BADKEY_HOME/in-progress/$SUPER_BADKEY_MARKER"
: > "$SUPER_GH_CALLS"
super_recover "$SUPER_BADKEY_HOME" "$SUPER_BADKEY_MARKER" ok MERGED "$FRESH_HEAD"
check 'arbitrary reservation key mismatch remains generating without consulting GitHub' \
  "$([ "$RC" -eq 3 ] && [ ! -s "$SUPER_GH_CALLS" ] \
     && [ "$(awk -F'\t' 'NR==1{print $1" "$8}' "$SUPER_BADKEY_HOME/in-progress/$SUPER_BADKEY_MARKER")" = 'other-77 generating' ]; echo $?)" \
  "rc=$RC calls=$(cat "$SUPER_GH_CALLS") record=$(cat "$SUPER_BADKEY_HOME/in-progress/$SUPER_BADKEY_MARKER")"
SUPER_CANON_EMPTY_HOME="$TDIR/home-superseded-canonical-empty-spend"
SUPER_CANON_EMPTY_MARKER='pg-run-acme-fresh-77-1700014107-7'
super_seed "$SUPER_CANON_EMPTY_HOME" "$SUPER_CANON_EMPTY_MARKER" 1700014107 "$FRESH_BASE"
printf '%s\t%s\t1700014107\t0\t1\t\t\tgenerating\n' "$SUPER_KEY" "$TDIR/superseded-audit.md" > "$SUPER_CANON_EMPTY_HOME/in-progress/$SUPER_CANON_EMPTY_MARKER"
: > "$SUPER_GH_CALLS"
super_recover "$SUPER_CANON_EMPTY_HOME" "$SUPER_CANON_EMPTY_MARKER" ok MERGED "$FRESH_HEAD"
check 'canonical key with missing spend remains fail-closed before GitHub' \
  "$([ "$RC" -eq 3 ] && [ ! -s "$SUPER_GH_CALLS" ] \
     && [ "$(awk -F'\t' 'NR==1{print $7" "$8}' "$SUPER_CANON_EMPTY_HOME/in-progress/$SUPER_CANON_EMPTY_MARKER")" = ' generating' ]; echo $?)" \
  "rc=$RC calls=$(cat "$SUPER_GH_CALLS") record=$(cat "$SUPER_CANON_EMPTY_HOME/in-progress/$SUPER_CANON_EMPTY_MARKER")"
SUPER_QUEUED_HOME="$TDIR/home-superseded-diff-queued"
SUPER_QUEUED_MARKER='pg-run-acme-fresh-77-1700014106-8'
super_seed "$SUPER_QUEUED_HOME" "$SUPER_QUEUED_MARKER" 1700014107 "$FRESH_BASE"
printf 'diff\t%s\t1700014107\t0\t1\t\t\tgenerating\n' "$TDIR/superseded-audit.md" > "$SUPER_QUEUED_HOME/in-progress/$SUPER_QUEUED_MARKER"
: > "$SUPER_GH_CALLS"
super_recover "$SUPER_QUEUED_HOME" "$SUPER_QUEUED_MARKER" ok MERGED "$FRESH_HEAD"
check 'queued legacy diff supersedes when marker mint precedes the exact proven charge' \
  "$([ "$RC" -eq 6 ] && [ -s "$SUPER_GH_CALLS" ] \
     && [ "$(awk -F'\t' 'NR==1{print $1" "$7" "$8}' "$SUPER_QUEUED_HOME/in-progress/$SUPER_QUEUED_MARKER")" = "$SUPER_KEY 1700014107 superseded" ]; echo $?)" \
  "rc=$RC calls=$(cat "$SUPER_GH_CALLS") record=$(cat "$SUPER_QUEUED_HOME/in-progress/$SUPER_QUEUED_MARKER")"

# The mutation helper independently repeats every exact identity and charge comparison under its lock.
# Each fixture keeps both sidecars valid so rejection cannot silently fall through malformed-input.
super_locked_reject() { # scenario suffix
  local scenario="$1" suffix="$2" home marker epoch binding meta before call_key call_spend rc
  home="$TDIR/home-superseded-atomic-$scenario"
  epoch=$(( 1700014200 + suffix ))
  marker="pg-run-acme-fresh-77-${epoch}-${suffix}"
  super_seed "$home" "$marker" "$epoch" "$FRESH_BASE"
  printf 'diff\t%s\t%s\t0\t1\t\t\tgenerating\n' "$TDIR/superseded-audit.md" "$epoch" > "$home/in-progress/$marker"
  call_key="$SUPER_KEY"; call_spend="$epoch"
  case "$scenario" in
    key) call_key="${SUPER_KEY%77}78" ;;
    expected-spend) call_spend=$(( epoch + 1 )) ;;
    host) super_replace_binding "$home" "$marker" '.repository.host="git.example.com"' ;;
    owner) super_replace_binding "$home" "$marker" '.repository.owner="other"' ;;
    repo) super_replace_binding "$home" "$marker" '.repository.repo="other"' ;;
    pr) super_replace_binding "$home" "$marker" '.target.pr=78' ;;
    binding-charge) super_replace_binding "$home" "$marker" ".charged_spend_epoch=$(( epoch + 1 ))" ;;
    # #134 planted negative: the caller validated $FRESH_BASE against GitHub, then the binding was
    # removed and rewritten pointing at a different head (reachable because
    # pg_attempt_disposition_cleanup unlinked bindings outside the reservation guard). Every other
    # field still matches, so this passes the pre-#134 comparison and wrongly supersedes
    # current-head work. The transition must refuse.
    # The evidence proof's own oid must equal .target.head_oid (pg_review_input_binding_validate),
    # so a naive target-only tamper yields an INVALID binding and would be rejected for being
    # unreadable rather than for the head — proving nothing. Rewrite both so the binding stays
    # fully valid and differs from the caller's validated head in exactly one dimension.
    head) super_replace_binding "$home" "$marker" \
      '.target.head_oid="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
       | (if (.evidence.proof|has("head_oid")) then .evidence.proof.head_oid="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" else . end)
       | (if (.evidence.proof|has("end_oid")) then .evidence.proof.end_oid="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" else . end)' ;;
  esac
  binding="$(PRO_GATE_HOME="$home" pg_review_input_binding_read "$marker" 2>/dev/null || true)"
  meta="$(PRO_GATE_HOME="$home" pg_run_meta_read "$marker" 2>/dev/null || true)"
  before="$(cat "$home/in-progress/$marker")"
  PRO_GATE_HOME="$home" pg_reservation_supersede "$marker" "$call_key" "$call_spend" "$FRESH_BASE"
  rc=$?
  check "locked supersession rejects $scenario mismatch with valid sidecars" \
    "$([ "$rc" -ne 0 ] && [ -n "$binding" ] && [ -n "$meta" ] \
       && [ "$(cat "$home/in-progress/$marker")" = "$before" ]; echo $?)" \
    "rc=$rc binding=$binding meta=$meta before=$before after=$(cat "$home/in-progress/$marker")"
}
SUPER_ATOMIC_N=0
for SUPER_ATOMIC_CASE in key expected-spend host owner repo pr binding-charge head; do
  SUPER_ATOMIC_N=$(( SUPER_ATOMIC_N + 1 ))
  super_locked_reject "$SUPER_ATOMIC_CASE" "$SUPER_ATOMIC_N"
done

# #134 review follow-up: the expected-head SHAPE gate is a fail-closed check on a shared helper.
# Both present callers pre-validate the head before it ever reaches here, so no production path can
# arrive malformed. Every input below would also fail the equality check against the seeded binding
# head, so this does not detect a loosened gate on its own; it pins the contract that a malformed
# head is refused with the record untouched, as documented behaviour rather than a side effect.
super_shape_reject() { # label bad-head
  local label="$1" bad_head="$2" home marker epoch before rc
  home="$TDIR/home-superseded-shape-$label"
  epoch=1700014300
  marker="pg-run-acme-fresh-77-${epoch}-${label}"
  super_seed "$home" "$marker" "$epoch" "$FRESH_BASE"
  printf 'diff\t%s\t%s\t0\t1\t\t\tgenerating\n' "$TDIR/superseded-audit.md" "$epoch" > "$home/in-progress/$marker"
  before="$(cat "$home/in-progress/$marker")"
  PRO_GATE_HOME="$home" pg_reservation_supersede "$marker" "$SUPER_KEY" "$epoch" "$bad_head"
  rc=$?
  check "supersession fails closed on $label expected-head" \
    "$([ "$rc" -ne 0 ] && [ "$(cat "$home/in-progress/$marker")" = "$before" ]; echo $?)" \
    "rc=$rc before=$before after=$(cat "$home/in-progress/$marker")"
}
super_shape_reject empty ''
super_shape_reject nonhex 'zzzzbeefdeadbeefdeadbeefdeadbeefdeadbeef'
super_shape_reject short 'deadbeef'
super_shape_reject uppercase 'DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF'

# The 40/64 length gate has a second arm for SHA-256 object ids. Every other fixture is a 40-char
# SHA-1, so without this the 64-char branch is never executed and could regress silently.
SUPER_SHA256_HOME="$TDIR/home-superseded-sha256"
SUPER_SHA256_MARKER='pg-run-acme-fresh-77-1700014301-X'
SUPER_SHA256_HEAD='c3a46ae3e16a6ecbe7ce01c3a1675ed2d2abd18bc3a46ae3e16a6ecbe7ce01c3'
super_seed "$SUPER_SHA256_HOME" "$SUPER_SHA256_MARKER" 1700014301 "$FRESH_BASE"
printf 'diff\t%s\t1700014301\t0\t1\t\t\tgenerating\n' "$TDIR/superseded-audit.md" > "$SUPER_SHA256_HOME/in-progress/$SUPER_SHA256_MARKER"
super_replace_binding "$SUPER_SHA256_HOME" "$SUPER_SHA256_MARKER" \
  ".target.head_oid=\"$SUPER_SHA256_HEAD\"
   | (if (.evidence.proof|has(\"head_oid\")) then .evidence.proof.head_oid=\"$SUPER_SHA256_HEAD\" else . end)
   | (if (.evidence.proof|has(\"end_oid\")) then .evidence.proof.end_oid=\"$SUPER_SHA256_HEAD\" else . end)"
PRO_GATE_HOME="$SUPER_SHA256_HOME" pg_reservation_supersede "$SUPER_SHA256_MARKER" "$SUPER_KEY" 1700014301 "$SUPER_SHA256_HEAD"
SUPER_SHA256_RC=$?
check 'supersession accepts a 64-character SHA-256 head that matches the binding' \
  "$([ "$SUPER_SHA256_RC" -eq 0 ] \
     && [ "$(awk -F'\t' 'NR==1{print $8}' "$SUPER_SHA256_HOME/in-progress/$SUPER_SHA256_MARKER")" = superseded ]; echo $?)" \
  "rc=$SUPER_SHA256_RC record=$(cat "$SUPER_SHA256_HOME/in-progress/$SUPER_SHA256_MARKER")"

# #134 review follow-up: the guard added around the disposition-cleanup unlink must be RELEASED when
# the unlink fails, not leaked. A leak is the self-deadlock the adjacent comment warns about, and it
# is deterministically testable without concurrency — make the binding directory unwritable so the
# rm fails, then prove a fresh acquire still succeeds.
# The disposition MUST come from the real writer: pg_attempt_disposition_cleanup validates the exact
# canonical schema first, and a hand-built subset fails that validation and returns before the guard
# is ever taken — the check then passes without exercising the release path at all (caught in
# review). The preconditions are asserted explicitly so the test cannot regress into that vacuity.
SUPER_LEAK_HOME="$TDIR/home-cleanup-guard-leak"
SUPER_LEAK_MARKER='pg-run-acme-fresh-77-1700014302-L'
super_seed "$SUPER_LEAK_HOME" "$SUPER_LEAK_MARKER" 1700014302 "$FRESH_BASE"
printf 'diff\t%s\t1700014302\t0\t1\t\t\tgenerating\n' "$TDIR/superseded-audit.md" > "$SUPER_LEAK_HOME/in-progress/$SUPER_LEAK_MARKER"
PRO_GATE_HOME="$SUPER_LEAK_HOME" pg_attempt_disposition_write github.com acme fresh 77 "$SUPER_KEY" \
  "$SUPER_LEAK_MARKER" 1700014302 not-submitted proven-no-submit >/dev/null 2>&1
SUPER_LEAK_DISP="$(PRO_GATE_HOME="$SUPER_LEAK_HOME" pg_attempt_disposition_read "$SUPER_LEAK_MARKER" 2>/dev/null || true)"
SUPER_LEAK_BINDING="$SUPER_LEAK_HOME/review-input-bindings/$SUPER_LEAK_MARKER"
# Root ignores directory modes, so there the unlink succeeds and only the success-path release is
# exercised; the unlink-failed assertions apply to the non-root runs CI and development use.
SUPER_LEAK_EXPECT_FAIL=1; [ "$(id -u)" -eq 0 ] && SUPER_LEAK_EXPECT_FAIL=0
chmod 500 "$SUPER_LEAK_HOME/review-input-bindings" 2>/dev/null
PRO_GATE_HOME="$SUPER_LEAK_HOME" pg_attempt_disposition_cleanup "$SUPER_LEAK_DISP" >/dev/null 2>&1
SUPER_LEAK_RC=$?
chmod 700 "$SUPER_LEAK_HOME/review-input-bindings" 2>/dev/null
SUPER_LEAK_BINDING_PRESENT=no; [ -f "$SUPER_LEAK_BINDING" ] && SUPER_LEAK_BINDING_PRESENT=yes
# If the guard leaked, this acquire blocks for the full flock timeout and then fails.
PRO_GATE_HOME="$SUPER_LEAK_HOME" pg_reservation_guard_acquire
SUPER_LEAK_REACQUIRE=$?
[ "$SUPER_LEAK_REACQUIRE" -eq 0 ] && PRO_GATE_HOME="$SUPER_LEAK_HOME" pg_reservation_guard_release
check 'disposition cleanup releases the reservation guard when the binding unlink fails' \
  "$([ -n "$SUPER_LEAK_DISP" ] && [ "$SUPER_LEAK_REACQUIRE" -eq 0 ] \
     && { [ "$SUPER_LEAK_EXPECT_FAIL" -eq 0 ] \
          || { [ "$SUPER_LEAK_RC" -ne 0 ] && [ "$SUPER_LEAK_BINDING_PRESENT" = yes ]; }; }; echo $?)" \
  "disposition_valid=$([ -n "$SUPER_LEAK_DISP" ] && echo yes || echo no) cleanup_rc=$SUPER_LEAK_RC binding_present=$SUPER_LEAK_BINDING_PRESENT reacquire_rc=$SUPER_LEAK_REACQUIRE"

# A terminal disposition is durable proof, not another mutable progress flag. It must outrank stale
# active/run-meta state after a crash, complete exact cleanup/refund once, and let late review bytes
# win without changing the disposition.
fresh_reset_state
FRESH_TERMINAL_MARKER='pg-run-acme-fresh.git-77-1700014004-5'
FRESH_TERMINAL_EPOCH=1700014004
FRESH_TERMINAL_BINDING="$(jq -cS --arg marker "$FRESH_TERMINAL_MARKER" --argjson epoch "$FRESH_TERMINAL_EPOCH" '.marker=$marker | .charged_spend_epoch=$epoch' <<<"$FRESH_BINDING")"
mkdir -p "$FRESH_HOME/run-meta" "$FRESH_HOME/rounds" "$FRESH_HOME/active"
printf '%s\n' "$FRESH_TERMINAL_EPOCH" > "$FRESH_HOME/rounds/$FRESH_KEY"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t%s\n' "$FRESH_KEY" "$TDIR/terminal.md" "$FRESH_TERMINAL_EPOCH" > "$FRESH_HOME/run-meta/$FRESH_TERMINAL_MARKER"
PRO_GATE_HOME="$FRESH_HOME" pg_review_input_binding_write "$FRESH_TERMINAL_MARKER" "$FRESH_TERMINAL_BINDING"
printf '%s\t%s\t%s\t%s\tremote-chrome\ttoken\tcharged\t%s\n' "$FRESH_TERMINAL_MARKER" "$TDIR/terminal.md" "$$" "$(date +%s)" "$FRESH_TERMINAL_EPOCH" > "$FRESH_HOME/active/$FRESH_KEY"
PRO_GATE_HOME="$FRESH_HOME" pg_attempt_disposition_write github.com acme fresh 77 "$FRESH_KEY" "$FRESH_TERMINAL_MARKER" "$FRESH_TERMINAL_EPOCH" not-submitted proven-no-submit
FRESH_TERMINAL_PENDING="$(PRO_GATE_HOME="$FRESH_HOME" pg_attempt_snapshot github.com acme fresh 77 "$FRESH_KEY")"
check 'terminal disposition outranks stale mutable attempt state and reports cleanup pending' \
  "$(jq -e --arg marker "$FRESH_TERMINAL_MARKER" '.marker==$marker and .source=="disposition" and .state=="cleanup-pending" and .cleanup_pending and (.fresh_eligible|not) and (.terminal.terminal_kind=="not-submitted")' <<<"$FRESH_TERMINAL_PENDING" >/dev/null 2>&1; echo $?)" \
  "$FRESH_TERMINAL_PENDING"
PRO_GATE_HOME="$FRESH_HOME" pg_attempt_terminal_transition github.com acme fresh 77 "$FRESH_KEY" "$FRESH_TERMINAL_MARKER" "$FRESH_TERMINAL_EPOCH" not-submitted proven-no-submit
FRESH_TERMINAL_DONE="$(PRO_GATE_HOME="$FRESH_HOME" pg_attempt_snapshot github.com acme fresh 77 "$FRESH_KEY")"
check 'not-submitted transition refunds and cleans exact mutable state before fresh eligibility' \
  "$(jq -e --arg marker "$FRESH_TERMINAL_MARKER" '.marker==$marker and .source=="disposition" and .state=="not-submitted" and (.cleanup_pending|not) and .fresh_eligible and (.recoverable|not)' <<<"$FRESH_TERMINAL_DONE" >/dev/null 2>&1 \
     && [ ! -e "$FRESH_HOME/rounds/$FRESH_KEY" ] && [ ! -e "$FRESH_HOME/run-meta/$FRESH_TERMINAL_MARKER" ] \
     && [ ! -e "$FRESH_HOME/active/$FRESH_KEY" ] && [ ! -e "$FRESH_HOME/review-input-bindings/$FRESH_TERMINAL_MARKER" ]; echo $?)" \
  "snapshot=$FRESH_TERMINAL_DONE"
PRO_GATE_HOME="$FRESH_HOME" bash "$ENGINE" --status 77 --json > "$TDIR/fresh-terminal-status.json" 2>/dev/null
check 'status exposes canonical terminal attempt and fresh eligible next step without contradiction' \
  "$(jq -e --arg marker "$FRESH_TERMINAL_MARKER" '.recoverable==false and .attempt.marker==$marker and .attempt.state=="not-submitted" and .attempt.fresh_eligible and (.next_step|contains("fresh typed pro-gate review is eligible"))' "$TDIR/fresh-terminal-status.json" >/dev/null 2>&1; echo $?)" \
  "$(cat "$TDIR/fresh-terminal-status.json")"
: > "$TDIR/recover-oracle-sentinel"
recover_run "$FRESH_HOME" --recover 77 --repo "$FRESH_REPO"
check 'direct PR recovery reports terminal no-review state without browser or fresh dispatch' \
  "$([ "$RC" -eq 6 ] && [ ! -s "$TDIR/recover.stdout" ] && grep -qx 'No review remains' "$TDIR/recover.stderr" && [ ! -s "$TDIR/recover-oracle-sentinel" ]; echo $?)" \
  "rc=$RC stdout=$(cat "$TDIR/recover.stdout") stderr=$(cat "$TDIR/recover.stderr")"
PRO_GATE_HOME="$FRESH_HOME" pg_attempt_terminal_transition github.com acme fresh 77 "$FRESH_KEY" "$FRESH_TERMINAL_MARKER" "$FRESH_TERMINAL_EPOCH" not-submitted proven-no-submit
check 'terminal transition replay is idempotent and never recreates a refunded round' \
  "$([ ! -e "$FRESH_HOME/rounds/$FRESH_KEY" ] && [ -s "$FRESH_HOME/attempt-dispositions/$FRESH_TERMINAL_MARKER" ]; echo $?)" \
  "round=$(cat "$FRESH_HOME/rounds/$FRESH_KEY" 2>/dev/null)"
mkdir -p "$FRESH_HOME/completed"
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP - late exact artifact.\n' > "$FRESH_HOME/completed/$FRESH_TERMINAL_MARKER"
FRESH_TERMINAL_LATE="$(PRO_GATE_HOME="$FRESH_HOME" pg_attempt_snapshot github.com acme fresh 77 "$FRESH_KEY")"
check 'late valid review bytes outrank the terminal disposition' \
  "$(jq -e --arg marker "$FRESH_TERMINAL_MARKER" '.marker==$marker and .source=="artifact" and .state=="review-ready" and .artifact.kind=="completed" and (.fresh_eligible|not)' <<<"$FRESH_TERMINAL_LATE" >/dev/null 2>&1; echo $?)" \
  "$FRESH_TERMINAL_LATE"

fresh_reset_state
FRESH_NEW_TERMINAL='pg-run-acme-fresh.git-77-1700014006-7'
FRESH_STALE_ACTIVE='pg-run-acme-fresh.git-77-1700014004-5'
FRESH_STALE_RESERVATION='pg-run-acme-fresh.git-77-1700014005-6'
PRO_GATE_HOME="$FRESH_HOME" pg_attempt_disposition_write github.com acme fresh 77 "$FRESH_KEY" "$FRESH_NEW_TERMINAL" 1700014006 submitted-terminal exact-owned-infrastructure-terminal
mkdir -p "$FRESH_HOME/active" "$FRESH_HOME/in-progress"
printf '%s\t%s\t99999999\t%s\tremote-chrome\ttoken\tsubmitted\t1700014004\n' "$FRESH_STALE_ACTIVE" "$TDIR/stale-active.md" "$(date +%s)" > "$FRESH_HOME/active/$FRESH_KEY"
printf '%s\t%s\t%s\t0\t\t\t1700014005\n' "$FRESH_KEY" "$TDIR/stale-reservation.md" "$(date +%s)" > "$FRESH_HOME/in-progress/$FRESH_STALE_RESERVATION"
FRESH_STALE_SNAPSHOT="$(PRO_GATE_HOME="$FRESH_HOME" pg_attempt_snapshot github.com acme fresh 77 "$FRESH_KEY")"
check 'older stale active and reservation sidecars cannot override newer terminal disposition' \
  "$(jq -e --arg marker "$FRESH_NEW_TERMINAL" '.marker==$marker and .source=="disposition" and .state=="submitted-terminal" and .fresh_eligible' <<<"$FRESH_STALE_SNAPSHOT" >/dev/null 2>&1; echo $?)" \
  "$FRESH_STALE_SNAPSHOT"

fresh_reset_state
FRESH_OLD_TERMINAL='pg-run-acme-fresh.git-77-1700014005-6'
FRESH_NEW_ACTIVE='pg-run-acme-fresh.git-77-1700014006-7'
PRO_GATE_HOME="$FRESH_HOME" pg_attempt_disposition_write github.com acme fresh 77 "$FRESH_KEY" "$FRESH_OLD_TERMINAL" 1700014005 submitted-terminal exact-owned-infrastructure-terminal
mkdir -p "$FRESH_HOME/active" "$FRESH_HOME/run-meta"
printf '%s\t%s\t%s\t%s\tremote-chrome\ttoken\tsubmitted\t1700014006\n' "$FRESH_NEW_ACTIVE" "$TDIR/new-active.md" "$$" "$(date +%s)" > "$FRESH_HOME/active/$FRESH_KEY"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700014006\n' "$FRESH_KEY" "$TDIR/new-active.md" > "$FRESH_HOME/run-meta/$FRESH_NEW_ACTIVE"
FRESH_NEW_ACTIVE_SNAPSHOT="$(PRO_GATE_HOME="$FRESH_HOME" pg_attempt_snapshot github.com acme fresh 77 "$FRESH_KEY")"
check 'older terminal disposition never hides a distinct newer active attempt' \
  "$(jq -e --arg marker "$FRESH_NEW_ACTIVE" '.marker==$marker and .source=="active" and .state=="submitted" and .recoverable and (.fresh_eligible|not)' <<<"$FRESH_NEW_ACTIVE_SNAPSHOT" >/dev/null 2>&1; echo $?)" \
  "$FRESH_NEW_ACTIVE_SNAPSHOT"

fresh_reset_state
FRESH_OLD_TERMINAL='pg-run-acme-fresh.git-77-1700014005-6'
FRESH_NEW_REVIEW='pg-run-acme-fresh.git-77-1700014007-8'
PRO_GATE_HOME="$FRESH_HOME" pg_attempt_disposition_write github.com acme fresh 77 "$FRESH_KEY" "$FRESH_OLD_TERMINAL" 1700014005 submitted-terminal exact-owned-infrastructure-terminal
mkdir -p "$FRESH_HOME/run-meta" "$FRESH_HOME/completed"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700014007\n' "$FRESH_KEY" "$TDIR/new-review.md" > "$FRESH_HOME/run-meta/$FRESH_NEW_REVIEW"
printf 'P0: none\nP1: none\nP2: none\nP3: none\nVERDICT: SHIP - newer durable artifact.\n' > "$FRESH_HOME/completed/$FRESH_NEW_REVIEW"
FRESH_NEW_REVIEW_SNAPSHOT="$(PRO_GATE_HOME="$FRESH_HOME" pg_attempt_snapshot github.com acme fresh 77 "$FRESH_KEY")"
check 'newer valid review artifact outranks an older different-marker disposition' \
  "$(jq -e --arg marker "$FRESH_NEW_REVIEW" '.marker==$marker and .source=="artifact" and .state=="review-ready" and .artifact.kind=="completed" and (.fresh_eligible|not)' <<<"$FRESH_NEW_REVIEW_SNAPSHOT" >/dev/null 2>&1; echo $?)" \
  "$FRESH_NEW_REVIEW_SNAPSHOT"

SWEEP_HOME="$TDIR/home-disposition-sweep"; SWEEP_KEY=acme-sweep-78
SWEEP_CLEAN='pg-run-acme-sweep-78-1700014010-1'; SWEEP_PENDING='pg-run-acme-sweep-78-1700014011-2'
mkdir -p "$SWEEP_HOME/run-meta"
PRO_GATE_HOME="$SWEEP_HOME" pg_attempt_disposition_write github.com acme sweep 78 "$SWEEP_KEY" "$SWEEP_CLEAN" 1700014010 submitted-terminal exact-owned-infrastructure-terminal
PRO_GATE_HOME="$SWEEP_HOME" pg_attempt_disposition_write github.com acme sweep 78 "$SWEEP_KEY" "$SWEEP_PENDING" 1700014011 recovery-exhausted bounded-recovery-exhausted
printf 'github.com\tacme\tsweep\t%s\t78\t%s\t1700014011\n' "$SWEEP_KEY" "$TDIR/sweep-pending.md" > "$SWEEP_HOME/run-meta/$SWEEP_PENDING"
touch -t 202001010000 "$SWEEP_HOME/attempt-dispositions/$SWEEP_CLEAN" "$SWEEP_HOME/attempt-dispositions/$SWEEP_PENDING"
PRO_GATE_HOME="$SWEEP_HOME" PRO_GATE_ROUNDS_WINDOW=1m PRO_GATE_RESERVATION_TTL=60 pg_attempt_disposition_sweep
check 'disposition sweep deletes old clean proof but retains cleanup-pending proof' \
  "$([ ! -e "$SWEEP_HOME/attempt-dispositions/$SWEEP_CLEAN" ] && [ -s "$SWEEP_HOME/attempt-dispositions/$SWEEP_PENDING" ]; echo $?)" \
  "remaining=$(find "$SWEEP_HOME/attempt-dispositions" -type f -printf '%f ' 2>/dev/null)"

# A repository-qualified PR URL owns canonical recovery identity even when the checkout belongs to
# a fork with the same PR number. Both public query and effect freshness must select upstream work.
fresh_reset_state
FRESH_FORK_MARKER='pg-run-acme-fresh.git-77-1700014004-5'
FRESH_UPSTREAM_MARKER='pg-run-upstream-project-77-1700014005-6'
mkdir -p "$FRESH_HOME/run-meta"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700014004\n' "$FRESH_KEY" "$TDIR/fork" > "$FRESH_HOME/run-meta/$FRESH_FORK_MARKER"
printf 'github.com\tupstream\tproject\tupstream-project-77\t77\t%s\t1700014005\n' "$TDIR/upstream" > "$FRESH_HOME/run-meta/$FRESH_UPSTREAM_MARKER"
FRESH_URL_RECOVERY="$(fresh_query 'https://github.com/upstream/project/pull/77')"
check 'repository-qualified decision query selects upstream run-meta instead of fork origin' \
  "$(jq -e --arg marker "$FRESH_UPSTREAM_MARKER" '.action=="recover-existing-review" and .effect_request.target.owner=="upstream" and .effect_request.target.repo=="project" and .effect_request.applicable_ref==$marker' <<<"$FRESH_URL_RECOVERY" >/dev/null 2>&1; echo $?)" \
  "$FRESH_URL_RECOVERY"
printf '%s\n' "$FRESH_URL_RECOVERY" > "$TDIR/fresh-url-recovery.json"
fresh_effect "$TDIR/fresh-url-recovery.json" "$TDIR/fresh-url-recovery.md" 'https://github.com/upstream/project/pull/77'
check 'repository-qualified recovery effect preserves the upstream marker without Oracle dispatch' \
  "$([ "$FRESH_RC" -eq 0 ] && [ ! -s "$TDIR/fresh-oracle.calls" ] && jq -e --arg marker "$FRESH_UPSTREAM_MARKER" '.action=="recover-existing-review" and .effect_request.applicable_ref==$marker' "$TDIR/fresh.stdout" >/dev/null 2>&1; echo $?)" \
  "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"

# Charge epoch, then canonical marker order, selects one stable unresolved attempt. A copied row
# whose marker/key/PR disagree is invalid state and cannot redirect recovery across changes.
fresh_reset_state
FRESH_OLDER_MARKER='pg-run-acme-fresh.git-77-1700014006-1'
FRESH_TIED_A='pg-run-acme-fresh.git-77-1700014010-7'
FRESH_TIED_B='pg-run-acme-fresh.git-77-1700014010-8'
FRESH_CORRUPT_MARKER='pg-run-acme-other-88-1700014011-9'
mkdir -p "$FRESH_HOME/run-meta"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700014006\n' "$FRESH_KEY" "$TDIR/older" > "$FRESH_HOME/run-meta/$FRESH_OLDER_MARKER"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700014020\n' "$FRESH_KEY" "$TDIR/tied-a" > "$FRESH_HOME/run-meta/$FRESH_TIED_A"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700014020\n' "$FRESH_KEY" "$TDIR/tied-b" > "$FRESH_HOME/run-meta/$FRESH_TIED_B"
printf 'github.com\tacme\tfresh\tacme-other-88\t77\t%s\t1700014030\n' "$TDIR/corrupt" > "$FRESH_HOME/run-meta/$FRESH_CORRUPT_MARKER"
FRESH_NEWEST_RECOVERY="$(fresh_query)"
check 'unresolved selector uses newest charge and canonical tie-break while rejecting mismatched rows' \
  "$(jq -e --arg marker "$FRESH_TIED_B" '.action=="recover-existing-review" and .effect_request.applicable_ref==$marker' <<<"$FRESH_NEWEST_RECOVERY" >/dev/null 2>&1; echo $?)" \
  "$FRESH_NEWEST_RECOVERY"
check 'run-meta scan excludes a marker/key/PR mismatch' \
  "$(! PRO_GATE_HOME="$FRESH_HOME" pg_run_meta_read "$FRESH_CORRUPT_MARKER" >/dev/null 2>&1; echo $?)" \
  "unexpectedly accepted $FRESH_CORRUPT_MARKER"

# Exact marker-bound pending bytes are durable recovery work after active/reservation state has
# cleared: dispatch must not spend again. A pending SHIP remains uncollected data, never merge
# authority. Old-head and changed-evidence completions prove the inverse: they must not suppress
# the fresh grant merely because their filenames share this PR's round key.
fresh_reset_state
FRESH_ADVISORY="$(fresh_query)"; printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
mkdir -p "$FRESH_HOME/pending"
PRO_GATE_HOME="$FRESH_HOME" pg_review_input_binding_write "$FRESH_TEMPLATE" "$FRESH_BINDING"
printf 'P0: none\nP1: none\nVERDICT: SHIP - pending only.\n' > "$FRESH_HOME/pending/$FRESH_TEMPLATE"
: > "$TDIR/fresh-oracle.calls"
fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-pending.md"
check 'exact current pending review suppresses spend and routes only to collection/recovery' \
  "$([ ! -s "$TDIR/fresh-oracle.calls" ] && jq -e '.action=="collect-existing-result" and .action!="allow-existing-merge-workflow"' "$TDIR/fresh.stdout" >/dev/null 2>&1; echo $?)" \
  "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"

fresh_reset_state
FRESH_ADVISORY="$(fresh_query)"; printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
FRESH_OLD_MARKER='pg-run-acme-fresh.git-77-1700013999-0'
FRESH_OLD_BINDING="$(jq -cS --arg marker "$FRESH_OLD_MARKER" --arg head "$FRESH_BASE" '.marker=$marker | .charged_spend_epoch=1700013999 | .target.head_oid=$head | .evidence.identity=("full-pr:" + .evidence.proof.base_oid + ":" + $head) | .evidence.proof.head_oid=$head' <<<"$FRESH_BINDING")"
mkdir -p "$FRESH_HOME/completed"
PRO_GATE_HOME="$FRESH_HOME" pg_review_input_binding_write "$FRESH_OLD_MARKER" "$FRESH_OLD_BINDING"
printf 'P0: none\nP1: none\nVERDICT: SHIP - old head.\n' > "$FRESH_HOME/completed/$FRESH_OLD_MARKER"
: > "$TDIR/fresh-oracle.calls"
fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-old-head.md"
check 'old-head completed bytes do not suppress the current fresh dispatch' \
  "$([ -s "$TDIR/fresh-oracle.calls" ]; echo $?)" \
  "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"

fresh_reset_state
printf 'changed endpoint evidence\n' >> "$TDIR/fresh-endpoint.patch"
FRESH_ADVISORY="$(fresh_query)"; printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
mkdir -p "$FRESH_HOME/completed"
PRO_GATE_HOME="$FRESH_HOME" pg_review_input_binding_write "$FRESH_TEMPLATE" "$FRESH_BINDING"
printf 'P0: none\nP1: none\nVERDICT: SHIP - changed evidence.\n' > "$FRESH_HOME/completed/$FRESH_TEMPLATE"
: > "$TDIR/fresh-oracle.calls"
fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-changed-evidence.md"
check 'changed-evidence completed bytes do not suppress the current fresh dispatch' \
  "$([ -s "$TDIR/fresh-oracle.calls" ]; echo $?)" \
  "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"
git -C "$FRESH_REPO" diff "$FRESH_BASE" "$FRESH_HEAD" > "$TDIR/fresh-effect.patch"
cp "$TDIR/fresh-effect.patch" "$TDIR/fresh-endpoint.patch"

# A historical terminal artifact resolves only its own charged marker. It stays inapplicable to
# the current relation, but its permanent run-meta sidecar must not turn it back into unknown-fate.
for terminal_store in completed pending; do
  fresh_reset_state
  FRESH_ADVISORY="$(fresh_query)"; printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
  FRESH_TERMINAL_MARKER='pg-run-acme-fresh.git-77-1700013998-8'
  mkdir -p "$FRESH_HOME/$terminal_store" "$FRESH_HOME/run-meta"
  printf 'P0: none\nP1: none\nVERDICT: FIX-FIRST - historical.\n' > "$FRESH_HOME/$terminal_store/$FRESH_TERMINAL_MARKER"
  printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700013998\n' "$FRESH_KEY" "$TDIR/x" > "$FRESH_HOME/run-meta/$FRESH_TERMINAL_MARKER"
  FRESH_TERMINAL_ADVISORY="$(fresh_query)"
  check "public query treats historical $terminal_store bytes as terminal for their own run-meta marker" \
    "$(jq -e '.action=="run-granted-review"' <<<"$FRESH_TERMINAL_ADVISORY" >/dev/null 2>&1; echo $?)" \
    "$FRESH_TERMINAL_ADVISORY"
  printf '%s\n' "$FRESH_TERMINAL_ADVISORY" > "$TDIR/fresh-advisory.json"
  : > "$TDIR/fresh-oracle.calls"
  fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-terminal-$terminal_store.md"
  check "historical $terminal_store bytes retire same-marker run-meta without gaining applicability" \
    "$([ "$FRESH_RC" -eq 0 ] && [ -s "$TDIR/fresh-oracle.calls" ]; echo $?)" \
    "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"
done

# Skipping a resolved marker must continue the scan: a separate charged marker with no terminal
# bytes still wins as recovery work and prevents a new Oracle call.
fresh_reset_state
FRESH_ADVISORY="$(fresh_query)"; printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
FRESH_RESOLVED_MARKER='pg-run-acme-fresh.git-77-1700013996-6'
FRESH_UNRESOLVED_MARKER='pg-run-acme-fresh.git-77-1700013997-7'
mkdir -p "$FRESH_HOME/completed" "$FRESH_HOME/run-meta"
printf 'P0: none\nP1: none\nVERDICT: SHIP - historical.\n' > "$FRESH_HOME/completed/$FRESH_RESOLVED_MARKER"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700013996\n' "$FRESH_KEY" "$TDIR/x" > "$FRESH_HOME/run-meta/$FRESH_RESOLVED_MARKER"
printf 'github.com\tacme\tfresh\t%s\t77\t%s\t1700013997\n' "$FRESH_KEY" "$TDIR/x" > "$FRESH_HOME/run-meta/$FRESH_UNRESOLVED_MARKER"
FRESH_UNRESOLVED_RECOVERY="$(fresh_query)"
check 'public query skips resolved run-meta and selects a later unresolved charged marker' \
  "$(jq -e --arg marker "$FRESH_UNRESOLVED_MARKER" '.action=="recover-existing-review" and .effect_request.applicable_ref==$marker' <<<"$FRESH_UNRESOLVED_RECOVERY" >/dev/null 2>&1; echo $?)" \
  "$FRESH_UNRESOLVED_RECOVERY"
printf '%s\n' "$FRESH_UNRESOLVED_RECOVERY" > "$TDIR/fresh-advisory.json"
: > "$TDIR/fresh-oracle.calls"
fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-terminal-before-unresolved.md"
check 'resolved run-meta does not hide a later unresolved charged marker' \
  "$([ "$FRESH_RC" -eq 0 ] && [ ! -s "$TDIR/fresh-oracle.calls" ] && jq -e --arg marker "$FRESH_UNRESOLVED_MARKER" '.action=="recover-existing-review" and .effect_request.applicable_ref==$marker' "$TDIR/fresh.stdout" >/dev/null 2>&1; echo $?)" \
  "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"

# Default round history is advisory even when its computed grant is exhausted.
fresh_reset_state
mkdir -p "$FRESH_HOME/rounds"
for _ in $(seq 1 3); do date +%s; done > "$FRESH_HOME/rounds/$FRESH_KEY"
FRESH_ADVISORY_ROUNDS="$(fresh_query)"
check 'default exhausted round history still grants changed proven evidence' \
  "$(jq -e '.action=="run-granted-review" and .facts.governor.granted' <<<"$FRESH_ADVISORY_ROUNDS" >/dev/null 2>&1; echo $?)" \
  "$FRESH_ADVISORY_ROUNDS"

# Effect-time proof or explicitly-enforced governor movement returns a replacement before it reaches
# the charge protocol. These are deliberately changes AFTER the advisory JSON was saved.
for fresh_change in evidence governor; do
  fresh_reset_state
  FRESH_ADVISORY="$(fresh_query)"; printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
  : > "$TDIR/fresh-oracle.calls"
  case "$fresh_change" in
    head)
      printf 'moved\n' > "$FRESH_REPO/fresh.txt"
      git -C "$FRESH_REPO" add fresh.txt && git -C "$FRESH_REPO" commit -qm fresh-moved ;;
    evidence) printf 'changed endpoint\n' >> "$TDIR/fresh-endpoint.patch" ;;
    governor)
      mkdir -p "$FRESH_HOME/rounds"
      for _ in $(seq 1 3); do date +%s; done > "$FRESH_HOME/rounds/$FRESH_KEY"
      export PRO_GATE_ROUND_GUARD=1 ;;
  esac
  fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-$fresh_change.md"
  [ "$fresh_change" != governor ] || unset PRO_GATE_ROUND_GUARD
  check "stale run-granted advisory re-reduces after $fresh_change without charge or Oracle" \
    "$([ ! -s "$TDIR/fresh-oracle.calls" ] && [ ! -d "$FRESH_HOME/active" ] && [ ! -d "$FRESH_HOME/run-meta" ]; echo $?)" \
    "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"
  [ "$fresh_change" != evidence ] || { git -C "$FRESH_REPO" diff "$FRESH_BASE" "$FRESH_HEAD" > "$TDIR/fresh-effect.patch"; cp "$TDIR/fresh-effect.patch" "$TDIR/fresh-endpoint.patch"; }
done

# Persistence failures are pre-submission failures: the marker remains active/recoverable, but
# the fake browser is never called. Each fixture fails a different charge-to-binding step.
for fresh_failure in round run-meta binding; do
  fresh_reset_state
  FRESH_ADVISORY="$(fresh_query)"; printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
  : > "$TDIR/fresh-oracle.calls"
  case "$fresh_failure" in
    round) mkdir -p "$FRESH_HOME"; printf 'not-a-rounds-directory\n' > "$FRESH_HOME/rounds" ;;
    run-meta) mkdir -p "$FRESH_HOME"; printf 'not-a-meta-directory\n' > "$FRESH_HOME/run-meta" ;;
    binding) mkdir -p "$FRESH_HOME/review-input-bindings"; chmod 500 "$FRESH_HOME/review-input-bindings" ;;
  esac
  fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-$fresh_failure.md"
  check "failed $fresh_failure persistence preserves charged recovery state before Oracle" \
    "$([ "$FRESH_RC" -ne 0 ] && [ ! -s "$TDIR/fresh-oracle.calls" ]; echo $?)" \
    "rc=$FRESH_RC active=$(find "$FRESH_HOME/active" -type f -printf '%f=' -exec cat {} \; 2>/dev/null) stderr=$(cat "$TDIR/fresh.stderr")"
  [ "$fresh_failure" != binding ] || chmod 700 "$FRESH_HOME/review-input-bindings"
done

fresh_reset_state
FRESH_ADVISORY="$(fresh_query)"; printf '%s\n' "$FRESH_ADVISORY" > "$TDIR/fresh-advisory.json"
printf 'moved\n' > "$FRESH_REPO/fresh.txt"
git -C "$FRESH_REPO" add fresh.txt && git -C "$FRESH_REPO" commit -qm fresh-moved
: > "$TDIR/fresh-oracle.calls"
fresh_effect "$TDIR/fresh-advisory.json" "$TDIR/fresh-head.md"
check 'stale run-granted advisory re-reduces a moved head without charge or Oracle' \
  "$([ ! -s "$TDIR/fresh-oracle.calls" ] && [ ! -d "$FRESH_HOME/active" ] && [ ! -d "$FRESH_HOME/run-meta" ]; echo $?)" \
  "rc=$FRESH_RC stdout=$(cat "$TDIR/fresh.stdout") stderr=$(cat "$TDIR/fresh.stderr")"

# U3 extends the reducer table with precedence cases that U1's original epoch-different
# selection case did not cover. These remain pure snapshots: race/restart fixture setup belongs
# to U2's guarded-effect tests above.
echo '# U3: review-decision precedence and recovery-state conformance'
SAME_EPOCH_ORDER_PATCH='{"completed_results":[{"applicable":true,"artifact_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","binding_valid":true,"canonical_identity":"canonical-a","charged_spend_epoch":1700000900,"collected":false,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000900-1","provenance_valid":true,"verdict":"SHIP"},{"applicable":true,"artifact_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","binding_valid":true,"canonical_identity":"canonical-z","charged_spend_epoch":1700000900,"collected":false,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000900-2","provenance_valid":true,"verdict":"FIX-FIRST"}]}'
SAME_EPOCH_ORDER_OUT="$(rd_reduce "$(rd_facts "$SAME_EPOCH_ORDER_PATCH")")"
check 'same charged epoch deterministically selects canonical identity before collection' \
  "$(jq -e '.action == "collect-existing-result" and .effect_request.applicable_ref == "canonical-z"' <<<"$SAME_EPOCH_ORDER_OUT" >/dev/null 2>&1; echo $?)" "$SAME_EPOCH_ORDER_OUT"

COMPLETED_BEATS_ACTIVE_PATCH='{"active_index":{"binding_valid":true,"charged_spend_epoch":1700000902,"marker":"pg-run-acme-widgets-1983-1700000902-2","state":"charged"},"completed_results":[{"applicable":true,"artifact_digest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","binding_valid":true,"canonical_identity":"completed-first","charged_spend_epoch":1700000901,"collected":false,"legacy":false,"marker":"pg-run-acme-widgets-1983-1700000901-1","provenance_valid":true,"verdict":"SHIP"}]}'
COMPLETED_BEATS_ACTIVE_OUT="$(rd_reduce "$(rd_facts "$COMPLETED_BEATS_ACTIVE_PATCH")")"
check 'uncollected current result wins over newer active work without a fresh review' \
  "$(jq -e '.action == "collect-existing-result" and .effect_request.applicable_ref == "completed-first"' <<<"$COMPLETED_BEATS_ACTIVE_OUT" >/dev/null 2>&1; echo $?)" "$COMPLETED_BEATS_ACTIVE_OUT"

for reservation_state in live recoverable unknown-fate; do
  reservation_patch="$(jq -cn --arg state "$reservation_state" '{reservation:{binding_valid:true,legacy:false,marker:"pg-run-acme-widgets-1983-1700000903-3",state:$state}}')"
  reservation_out="$(rd_reduce "$(rd_facts "$reservation_patch")")"
  check "reservation state is recovery-only: $reservation_state" \
    "$(jq -e '.action == "recover-existing-review" and .effect_request.applicable_ref == "pg-run-acme-widgets-1983-1700000903-3"' <<<"$reservation_out" >/dev/null 2>&1; echo $?)" "$reservation_out"
done

# A stale/expired reservation must not be upgraded to a caller-selected continuation. The CLI's
# current read-only lookup drops it, therefore an absent binding still fails closed rather than
# launching or granting merge eligibility.
EXPIRED_RESERVATION_FACTS="$(rd_facts '{"reservation":{"binding_valid":false,"legacy":false,"marker":"","state":"none"},"input":{"binding_valid":false,"identity":"","proven":false}}')"
EXPIRED_RESERVATION_OUT="$(rd_reduce "$EXPIRED_RESERVATION_FACTS")"
check 'expired reservation with no current binding stops rather than creating new spend' \
  "$(jq -e '.action == "stop-without-new-review" and .reason == "unproven-input"' <<<"$EXPIRED_RESERVATION_OUT" >/dev/null 2>&1; echo $?)" "$EXPIRED_RESERVATION_OUT"

# Reopened U2: a NEEDS-DISCUSSION artifact admits only a small terminal data grammar. These are
# deliberately red-before-green parser cases: no raw review prose is ever surfaced by the helper.
echo '# U2 reopened: bounded named-product choice artifacts'
CHOICE_ART="$TDIR/named-choice-review.md"
choice_artifact() { # outcome lines supplied on stdin
  { printf '%s\n' 'P0: none' 'P1: none'; cat; printf '%s\n' 'VERDICT: NEEDS-DISCUSSION — choose intentionally.'; } > "$CHOICE_ART"
}
printf '%s\n' 'CHOICE: keep | Keep compatibility | Existing users need no migration.' 'CHOICE: replace | Replace API | Users migrate to the new contract.' | choice_artifact
CHOICE_PARSED="$(pg_review_decision_named_choices "$CHOICE_ART" 2>/dev/null)"; CHOICE_PARSE_RC=$?
check 'well-formed NEEDS-DISCUSSION artifact yields bounded machine choice outcomes' \
  "$([ "$CHOICE_PARSE_RC" -eq 0 ] && jq -e 'length==2 and .[0].id=="keep" and .[1].id=="replace"' <<<"$CHOICE_PARSED" >/dev/null 2>&1; echo $?)" "$CHOICE_PARSED"
CHOICE_SHELL_SENTINEL="$TDIR/choice-shell-sentinel"
printf '%s\n' "CHOICE: keep | Keep \$(touch $CHOICE_SHELL_SENTINEL) | Treat this as printable data only." 'CHOICE: replace | Replace | Migrate safely.' | choice_artifact
CHOICE_SHELL_PARSED="$(pg_review_decision_named_choices "$CHOICE_ART" 2>/dev/null)"; CHOICE_SHELL_RC=$?
check 'printable shell metacharacters remain inert normalized choice data' \
  "$([ "$CHOICE_SHELL_RC" -eq 0 ] && [ ! -e "$CHOICE_SHELL_SENTINEL" ] && jq -e '.[0].label | contains("$(touch ")' <<<"$CHOICE_SHELL_PARSED" >/dev/null 2>&1; echo $?)" "$CHOICE_SHELL_PARSED"
for choice_case in one duplicate oversized oversized-id control malformed extra-pipe; do
  case "$choice_case" in
    one) printf '%s\n' 'CHOICE: keep | Keep compatibility | Existing users need no migration.' | choice_artifact ;;
    duplicate) printf '%s\n' 'CHOICE: keep | Keep compatibility | Existing users need no migration.' 'CHOICE: keep | Replace API | Users migrate.' | choice_artifact ;;
    oversized) { printf 'CHOICE: keep | '; python3 -c 'print("x" * 121, end="")'; printf ' | consequence\nCHOICE: replace | Replace | migrate\n'; } | choice_artifact ;;
    oversized-id) { printf 'CHOICE: '; python3 -c 'print("x" * 257, end="")'; printf ' | Keep | consequence\nCHOICE: replace | Replace | migrate\n'; } | choice_artifact ;;
    control) { printf 'CHOICE: keep | Keep\001 | consequence\nCHOICE: replace | Replace | migrate\n'; } | choice_artifact ;;
    malformed) printf '%s\n' 'CHOICE: keep | Only two fields' 'CHOICE: replace | Replace | migrate' | choice_artifact ;;
    extra-pipe) printf '%s\n' 'CHOICE: keep | Keep | consequence | extra' 'CHOICE: replace | Replace | migrate' | choice_artifact ;;
  esac
  pg_review_decision_named_choices "$CHOICE_ART" >/dev/null 2>&1; CHOICE_CASE_RC=$?
  check "invalid named choice artifact stops closed: $choice_case" "$([ "$CHOICE_CASE_RC" -ne 0 ]; echo $?)" "rc=$CHOICE_CASE_RC"
done

# The public CLI reads choices only from the exact immutable artifact. Selection is a canonical,
# read-only input which can route only through the existing reducer's non-authorizing fixer action.
echo '# U2 reopened: real CLI named-product selection'
CHOICE_HOME="$TDIR/home-cli-choice"; CHOICE_MARKER='pg-run-acme-widgets-1983-1700017000-1'
CHOICE_BINDING="$(jq -cS --arg marker "$CHOICE_MARKER" '.marker=$marker | .charged_spend_epoch=1700017000' <<<"$PC_SCOPED")"
mkdir -p "$CHOICE_HOME/completed"
printf '%s\n' 'P0: none' 'P1: none' 'CHOICE: keep | Keep compatibility | Existing users need no migration.' 'CHOICE: replace | Replace API | Users migrate to the new contract.' 'VERDICT: NEEDS-DISCUSSION — choose intentionally.' > "$CHOICE_HOME/completed/$CHOICE_MARKER"
CHOICE_INPUT_DIGEST="$(printf '%s' "$CHOICE_BINDING" | sha256sum | awk '{print $1}')"
CHOICE_ART_DIGEST="$(sha256sum "$CHOICE_HOME/completed/$CHOICE_MARKER" | awk '{print $1}')"
CHOICE_RESULT="$(jq -cnS --arg cd "$RD_CONTRACT_DIGEST" --arg marker "$CHOICE_MARKER" --arg ib "$CHOICE_INPUT_DIGEST" --arg digest "$CHOICE_ART_DIGEST" '{accepted_epoch:1700017001,artifact:{digest:$digest,path:("completed/"+$marker)},contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,input_binding_digest:$ib,input_binding_identity:$marker,marker:$marker,named_choice:null,provenance:{outcome:"accepted",validated_epoch:1700017001},record_type:"review-result-binding/v1",record_version:1,ship_proof:null,verdict:"NEEDS-DISCUSSION"}')"
PRO_GATE_HOME="$CHOICE_HOME" pg_review_input_binding_write "$CHOICE_MARKER" "$CHOICE_BINDING"
PRO_GATE_HOME="$CHOICE_HOME" pg_review_result_binding_write "$CHOICE_MARKER" "$CHOICE_RESULT"
env PRO_GATE_HOME="$CHOICE_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/choice-ask.json" 2>"$TDIR/choice-ask.err"
CHOICE_ASK_RC=$?
CHOICE_SNAPSHOT="$(jq -r .effect_request.snapshot_digest "$TDIR/choice-ask.json")"
check 'exact NEEDS-DISCUSSION CLI result exposes only validated outcomes and asks once' \
  "$([ "$CHOICE_ASK_RC" -eq 0 ] && jq -e '.action=="ask-named-product-choice" and (.facts.named_choice.outcomes|length)==2 and .facts.named_choice.selected_id==null' "$TDIR/choice-ask.json" >/dev/null 2>&1; echo $?)" \
  "rc=$CHOICE_ASK_RC output=$(cat "$TDIR/choice-ask.json")"
check 'initial named-choice effect snapshot is the reducer choice context' \
  "$(jq -e --arg snap "$CHOICE_SNAPSHOT" '.facts as $facts | (.effect_request.snapshot_digest==$snap) and ($snap|test("^[0-9a-f]{64}$"))' "$TDIR/choice-ask.json" >/dev/null 2>&1; echo $?)" \
  "snapshot=$CHOICE_SNAPSHOT"
printf '%s' "$(jq -cnS --arg id keep --arg snap "$CHOICE_SNAPSHOT" '{selected_id:$id,snapshot_digest:$snap}')" > "$TDIR/choice-selection.json"
CHOICE_STATE_BEFORE="$(find "$CHOICE_HOME" -mindepth 1 -maxdepth 2 -printf '%P\n' | sort)"
env PRO_GATE_HOME="$CHOICE_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --review-choice-selection "$TDIR/choice-selection.json" --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/choice-selected.json" 2>"$TDIR/choice-selected.err"
CHOICE_SELECTED_RC=$?; CHOICE_STATE_AFTER="$(find "$CHOICE_HOME" -mindepth 1 -maxdepth 2 -printf '%P\n' | sort)"
check 'exact canonical selection returns the existing non-authorizing named-choice fixer handoff without mutation' \
  "$([ "$CHOICE_SELECTED_RC" -eq 0 ] && jq -e '.action=="fix-review-findings" and .reason=="named-product-choice-selected" and .facts.named_choice.selected_id=="keep"' "$TDIR/choice-selected.json" >/dev/null 2>&1 && [ "$CHOICE_STATE_BEFORE" = "$CHOICE_STATE_AFTER" ]; echo $?)" \
  "rc=$CHOICE_SELECTED_RC output=$(cat "$TDIR/choice-selected.json")"
for choice_selection_case in malformed unknown stale oversized symlink; do
  rm -f "$TDIR/choice-bad.json"
  case "$choice_selection_case" in
    malformed) printf '%s\n' '{"selected_id":"keep"}' > "$TDIR/choice-bad.json" ;;
    unknown) printf '%s' "$(jq -cnS --arg snap "$CHOICE_SNAPSHOT" '{selected_id:"unknown",snapshot_digest:$snap}')" > "$TDIR/choice-bad.json" ;;
    stale) printf '%s' "$(jq -cnS '{selected_id:"keep",snapshot_digest:"0000000000000000000000000000000000000000000000000000000000000000"}')" > "$TDIR/choice-bad.json" ;;
    oversized) python3 -c 'print("x" * 65537, end="")' > "$TDIR/choice-bad.json" ;;
    symlink) ln -s "$TDIR/choice-selection.json" "$TDIR/choice-bad.json" ;;
  esac
  env PRO_GATE_HOME="$CHOICE_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
    bash "$ENGINE" --review-decision --json --review-choice-selection "$TDIR/choice-bad.json" --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
    >"$TDIR/choice-$choice_selection_case.json" 2>"$TDIR/choice-$choice_selection_case.err"
  CHOICE_BAD_RC=$?
  check "malformed, unknown, or stale choice selection stops without a review: $choice_selection_case" \
    "$([ "$CHOICE_BAD_RC" -eq 0 ] && jq -e '.action=="stop-without-new-review" and (.action!="run-granted-review")' "$TDIR/choice-$choice_selection_case.json" >/dev/null 2>&1; echo $?)" \
    "rc=$CHOICE_BAD_RC output=$(cat "$TDIR/choice-$choice_selection_case.json")"
done
# Moving endpoint evidence invalidates the saved choice context; no previously selected outcome
# is carried across to the newly reduced relation.
printf 'moved endpoint\n' >> "$TDIR/scoped-raw-endpoint.patch"
env PRO_GATE_HOME="$CHOICE_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --review-choice-selection "$TDIR/choice-selection.json" --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/choice-evidence-moved.json" 2>"$TDIR/choice-evidence-moved.err"
CHOICE_MOVED_RC=$?
check 'moved scoped evidence invalidates a named selection without reusing it' \
  "$([ "$CHOICE_MOVED_RC" -eq 0 ] && jq -e '.action!="fix-review-findings" and .action!="allow-existing-merge-workflow"' "$TDIR/choice-evidence-moved.json" >/dev/null 2>&1; echo $?)" \
  "rc=$CHOICE_MOVED_RC output=$(cat "$TDIR/choice-evidence-moved.json")"
cp "$TDIR/proof-raw.patch" "$TDIR/scoped-raw-endpoint.patch"; printf 'unreviewed endpoint context\n' >> "$TDIR/scoped-raw-endpoint.patch"

# A provenance-valid scoped SHIP is current merge-handoff evidence only while all independently
# bound sources remain current. Connector SHIP remains explicitly non-authoritative.
echo '# U2 reopened: scoped SHIP merge handoff'
SCOPED_SHIP_HOME="$TDIR/home-scoped-ship"; SCOPED_SHIP_MARKER='pg-run-acme-widgets-1983-1700018000-1'
SCOPED_SHIP_INPUT="$(jq -cS --arg marker "$SCOPED_SHIP_MARKER" '.marker=$marker | .charged_spend_epoch=1700018000' <<<"$PC_SCOPED")"
mkdir -p "$SCOPED_SHIP_HOME/completed"
printf '%s\n' 'P0: none' 'P1: none' 'P2: none' 'P3: none' 'VERDICT: SHIP — scoped endpoint reviewed.' > "$SCOPED_SHIP_HOME/completed/$SCOPED_SHIP_MARKER"
PRO_GATE_HOME="$SCOPED_SHIP_HOME" pg_review_input_binding_write "$SCOPED_SHIP_MARKER" "$SCOPED_SHIP_INPUT"
env PRO_GATE_HOME="$SCOPED_SHIP_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/scoped-ship-collect.json" 2>"$TDIR/scoped-ship-collect.err"
SCOPED_COLLECT_RC=$?
env PRO_GATE_HOME="$SCOPED_SHIP_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --review-decision-effect "$TDIR/scoped-ship-collect.json" --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/scoped-ship-repair.json" 2>"$TDIR/scoped-ship-repair.err"
env PRO_GATE_HOME="$SCOPED_SHIP_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/scoped-ship-current.json" 2>"$TDIR/scoped-ship-current.err"
SCOPED_CURRENT_RC=$?
check 'unchanged provenance-valid scoped SHIP reaches report-only merge handoff, never another review' \
  "$([ "$SCOPED_COLLECT_RC" -eq 0 ] && [ "$SCOPED_CURRENT_RC" -eq 0 ] && jq -e '.action=="allow-existing-merge-workflow" and .effect_request.execution_class=="report-only"' "$TDIR/scoped-ship-current.json" >/dev/null 2>&1; echo $?)" \
  "collect=$(cat "$TDIR/scoped-ship-collect.json") current=$(cat "$TDIR/scoped-ship-current.json")"
for scoped_move in raw reviewed manifest confirmation; do
  case "$scoped_move" in
    raw) printf 'different raw endpoint\n' >> "$TDIR/scoped-raw-endpoint.patch" ;;
    reviewed) printf 'different reviewed payload\n' >> "$TDIR/proof-raw.patch" ;;
    manifest) printf 'different manifest\n' >> "$TDIR/scoped-manifest" ;;
    confirmation) printf '%s\n' 'P0: none' 'P1: none' 'P2: changed confirmation' 'P3: none' 'VERDICT: SHIP — changed.' > "$TDIR/scoped-confirmation.md" ;;
  esac
  env PRO_GATE_HOME="$SCOPED_SHIP_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
    bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
    >"$TDIR/scoped-ship-$scoped_move.json" 2>"$TDIR/scoped-ship-$scoped_move.err"
  SCOPED_MOVE_RC=$?
  check "scoped SHIP with moved $scoped_move cannot reach merge handoff" \
    "$([ "$SCOPED_MOVE_RC" -eq 0 ] && jq -e '.action!="allow-existing-merge-workflow"' "$TDIR/scoped-ship-$scoped_move.json" >/dev/null 2>&1; echo $?)" \
    "rc=$SCOPED_MOVE_RC output=$(cat "$TDIR/scoped-ship-$scoped_move.json")"
  cp "$TDIR/proof-raw.patch" "$TDIR/scoped-raw-endpoint.patch"; printf 'unreviewed endpoint context\n' >> "$TDIR/scoped-raw-endpoint.patch"
  git -C "$DECISION_REPO" diff "$PROOF_BASE" "$PROOF_HEAD" > "$TDIR/proof-raw.patch"
  printf 'proof.txt\n' > "$TDIR/scoped-manifest"
  printf '%s\n' 'P0: none' 'P1: none' 'VERDICT: SHIP — prior review accepted' > "$TDIR/scoped-confirmation.md"
done
# Base movement is independently fail-closed even while the reviewed head stays fixed.
git -C "$DECISION_REPO" branch scoped-base-alt "${PROOF_BASE}^"
git -C "$DECISION_REPO" branch --set-upstream-to=scoped-base-alt >/dev/null 2>&1
env PRO_GATE_HOME="$SCOPED_SHIP_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/scoped-ship-base.json" 2>"$TDIR/scoped-ship-base.err"
SCOPED_BASE_RC=$?
check 'scoped SHIP with moved base cannot reach merge handoff' \
  "$([ "$SCOPED_BASE_RC" -eq 0 ] && jq -e '.action!="allow-existing-merge-workflow"' "$TDIR/scoped-ship-base.json" >/dev/null 2>&1; echo $?)" \
  "rc=$SCOPED_BASE_RC output=$(cat "$TDIR/scoped-ship-base.json")"
git -C "$DECISION_REPO" branch --unset-upstream
# Moving the repository head changes both the effect target and the scoped base/head proof. A
# saved exact selection must become a fresh safe replacement, never a fixer or another review.
printf 'head moved after choice\n' > "$DECISION_REPO/proof.txt"
git -C "$DECISION_REPO" add proof.txt && git -C "$DECISION_REPO" commit -qm choice-head-moved
env PRO_GATE_HOME="$CHOICE_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --review-choice-selection "$TDIR/choice-selection.json" --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/choice-head-moved.json" 2>"$TDIR/choice-head-moved.err"
CHOICE_HEAD_MOVED_RC=$?
check 'moved head invalidates a named selection without granting review or merge' \
  "$([ "$CHOICE_HEAD_MOVED_RC" -eq 0 ] && jq -e '.action!="fix-review-findings" and .action!="run-granted-review" and .action!="allow-existing-merge-workflow"' "$TDIR/choice-head-moved.json" >/dev/null 2>&1; echo $?)" \
  "rc=$CHOICE_HEAD_MOVED_RC output=$(cat "$TDIR/choice-head-moved.json")"
env PRO_GATE_HOME="$SCOPED_SHIP_HOME" PRO_GATE_RUN_LOGS=0 PRO_GATE_REVIEW_ENDPOINT_PATCH="$TDIR/scoped-raw-endpoint.patch" PRO_GATE_REVIEW_FILTER_MANIFEST="$TDIR/scoped-manifest" \
  bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --diff "$TDIR/proof-raw.patch" --confirm "$TDIR/scoped-confirmation.md" --input bundle \
  >"$TDIR/scoped-ship-head.json" 2>"$TDIR/scoped-ship-head.err"
SCOPED_HEAD_RC=$?
check 'scoped SHIP with moved head cannot reach merge handoff' \
  "$([ "$SCOPED_HEAD_RC" -eq 0 ] && jq -e '.action!="allow-existing-merge-workflow"' "$TDIR/scoped-ship-head.json" >/dev/null 2>&1; echo $?)" \
  "rc=$SCOPED_HEAD_RC output=$(cat "$TDIR/scoped-ship-head.json")"
CONNECTOR_SHIP_HOME="$TDIR/home-connector-ship"; CONNECTOR_SHIP_MARKER='pg-run-acme-widgets-1983-1700018001-2'
CONNECTOR_SHIP_INPUT="$(jq -cS --arg marker "$CONNECTOR_SHIP_MARKER" '.marker=$marker | .charged_spend_epoch=1700018001' <<<"$PC_CONNECTOR")"
mkdir -p "$CONNECTOR_SHIP_HOME/completed"; printf '%s\n' 'P0: none' 'P1: none' 'VERDICT: SHIP — connector observation.' > "$CONNECTOR_SHIP_HOME/completed/$CONNECTOR_SHIP_MARKER"
CONNECTOR_INPUT_DIGEST="$(printf '%s' "$CONNECTOR_SHIP_INPUT" | sha256sum | awk '{print $1}')"; CONNECTOR_ART_DIGEST="$(sha256sum "$CONNECTOR_SHIP_HOME/completed/$CONNECTOR_SHIP_MARKER" | awk '{print $1}')"
CONNECTOR_SHIP_RESULT="$(jq -cnS --arg cd "$RD_CONTRACT_DIGEST" --arg marker "$CONNECTOR_SHIP_MARKER" --arg ib "$CONNECTOR_INPUT_DIGEST" --arg digest "$CONNECTOR_ART_DIGEST" --arg base "$PROOF_BASE" --arg head "$PROOF_HEAD" --arg raw "$SCOPED_RAW_DIGEST" '{accepted_epoch:1700018002,artifact:{digest:$digest,path:("completed/"+$marker)},contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,input_binding_digest:$ib,input_binding_identity:$marker,marker:$marker,named_choice:null,provenance:{outcome:"accepted",validated_epoch:1700018002},record_type:"review-result-binding/v1",record_version:1,ship_proof:{base_oid:$base,diff_digest:$raw,head_oid:$head},verdict:"SHIP"}')"
PRO_GATE_HOME="$CONNECTOR_SHIP_HOME" pg_review_input_binding_write "$CONNECTOR_SHIP_MARKER" "$CONNECTOR_SHIP_INPUT"; PRO_GATE_HOME="$CONNECTOR_SHIP_HOME" pg_review_result_binding_write "$CONNECTOR_SHIP_MARKER" "$CONNECTOR_SHIP_RESULT"
env PRO_GATE_HOME="$CONNECTOR_SHIP_HOME" PRO_GATE_RUN_LOGS=0 bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --input connector >"$TDIR/connector-ship.json" 2>"$TDIR/connector-ship.err"
CONNECTOR_SHIP_RC=$?
check 'connector SHIP never becomes merge eligibility' \
  "$([ "$CONNECTOR_SHIP_RC" -eq 0 ] && jq -e '.action!="allow-existing-merge-workflow"' "$TDIR/connector-ship.json" >/dev/null 2>&1; echo $?)" \
  "rc=$CONNECTOR_SHIP_RC output=$(cat "$TDIR/connector-ship.json")"

# pending/ deliberately has no result-binding store. Even exact-current connector bytes therefore
# remain uncollected recovery data and cannot inherit the completed SHIP handoff route.
CONNECTOR_PENDING_HOME="$TDIR/home-connector-pending"; CONNECTOR_PENDING_MARKER='pg-run-acme-widgets-1983-1700018002-3'
CONNECTOR_PENDING_HEAD="$(git -C "$DECISION_REPO" rev-parse HEAD)"
CONNECTOR_PENDING_INPUT="$(jq -cS --arg marker "$CONNECTOR_PENDING_MARKER" --arg head "$CONNECTOR_PENDING_HEAD" '.marker=$marker | .charged_spend_epoch=1700018002 | .target.head_oid=$head | .evidence.identity=("connector:github.com/acme/widgets:" + $head) | .evidence.proof.commit_target=$head' <<<"$PC_CONNECTOR")"
mkdir -p "$CONNECTOR_PENDING_HOME/pending"
PRO_GATE_HOME="$CONNECTOR_PENDING_HOME" pg_review_input_binding_write "$CONNECTOR_PENDING_MARKER" "$CONNECTOR_PENDING_INPUT"
printf '%s\n' 'P0: none' 'P1: none' 'VERDICT: SHIP — pending connector observation.' > "$CONNECTOR_PENDING_HOME/pending/$CONNECTOR_PENDING_MARKER"
env PRO_GATE_HOME="$CONNECTOR_PENDING_HOME" PRO_GATE_RUN_LOGS=0 bash "$ENGINE" --review-decision --json --repo "$DECISION_REPO" --pr 1983 --input connector >"$TDIR/connector-pending.json" 2>"$TDIR/connector-pending.err"
CONNECTOR_PENDING_RC=$?
check 'exact pending connector SHIP is collect-only and never merge eligible' \
  "$([ "$CONNECTOR_PENDING_RC" -eq 0 ] && jq -e '.action=="collect-existing-result" and .action!="allow-existing-merge-workflow"' "$TDIR/connector-pending.json" >/dev/null 2>&1; echo $?)" \
  "rc=$CONNECTOR_PENDING_RC output=$(cat "$TDIR/connector-pending.json") stderr=$(cat "$TDIR/connector-pending.err")"

[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILURES"; exit 1; }
