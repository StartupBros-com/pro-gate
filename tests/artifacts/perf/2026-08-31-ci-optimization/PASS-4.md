# CI wait optimization — Pass 4: TERM-drain and force-settle waits, test-configurable

## Baseline evidence

- Source: pass 1/2/3's own completed-run evidence (`PASS-1.md`, `PASS-2.md`, `PASS-3.md`,
  `PASS-3-VERIFICATION.txt`) plus the original hosted profile in `../2026-08-31-ci-runner/`.
- `run_oracle`'s watchdog kill path (`bin/oracle-review.sh`), once the observation loop (pass 3's
  lever) decides to intervene, runs a distinct two-stage wait sequence at a separate call site:
  1. `pg_signal_producer TERM "$producer"`, then a bounded drain loop:
     `while [ "$drained" -lt 30 ] && kill -0 "$job" 2>/dev/null; do sleep 1; drained=$((drained+1)); done`
     — up to 30 one-second polls waiting for the producer's process group to exit on its own.
  2. If still alive after the drain: `pg_signal_producer KILL`, `pkill -TERM -P`/`kill -TERM` the
     job, `sleep 5` (force-settle), then unconditional `pg_signal_producer KILL` +
     `pkill -KILL -P`/`kill -KILL`.
  The PR 924 TERM-ignoring producer fixture is the only one of the three watchdog fixtures that
  exercises this path end-to-end through force-settle and forced KILL. PR 922/923 enter the same
  TERM/drain site but their producers exit during the bounded drain, before force-settle — before
  this pass PR 924 proved survival only by asserting
  `kill -0` failed on the orphan **after the whole run completed**, with no evidence that the
  fixture was ever actually inside the bounded drain window rather than, say, killed instantly by
  an unrelated path and coincidentally still exiting nonzero.
- Opportunity score: Impact 4 × Confidence 3 / Effort 4 = **3** (per mission). The mission's own
  fallback clause governed this pass: "If stronger signal-order/no-orphan evidence cannot be made
  robustly, make ZERO code changes and report the three-plus concrete checks that block the lever."
  This pass **did** reach a robust fixture (see Signal-order proof below) after diagnosing and
  fixing a real bash blocking-read hazard the original fixture design was silently exposed to; the
  fallback was not invoked.

## Exact single lever

`lib/pro-gate-lib.sh` gains two new private helpers, directly beside pass 2/3's
`pg_test_pre_retry_probe_secs` / `pg_test_watchdog_sleep_secs` (same file, same pattern):

```sh
# Test-only watchdog TERM-drain duration. Invalid input deliberately falls back
# to the production 30-second bound and can never extend it.
pg_test_watchdog_term_drain_secs() {
  case "${PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS:-}" in
    [1-9]|[12][0-9]|30) printf '%s\n' "$PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS" ;;
    *) printf '30\n' ;;
  esac
}

# Test-only watchdog post-drain force-settle wait. Invalid input deliberately
# falls back to the production 5-second bound and can never extend it.
pg_test_watchdog_force_settle_secs() {
  case "${PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS:-}" in
    [1-5]) printf '%s\n' "$PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS" ;;
    *) printf '5\n' ;;
  esac
}
```

`bin/oracle-review.sh` resolves both once per `run_oracle` invocation, alongside pass 3's cadence
resolution, before the producer/watchdog loop begins (line 3151 declares the locals, lines
3156-3157 resolve them):

```sh
local watchdog_term_drain_secs watchdog_force_settle_secs
...
watchdog_term_drain_secs="$(pg_test_watchdog_term_drain_secs)"
watchdog_force_settle_secs="$(pg_test_watchdog_force_settle_secs)"
```

The drain loop and the force-settle sleep read those locals instead of the literals `30` and `5`:

```sh
while [ "$drained" -lt "$watchdog_term_drain_secs" ] && kill -0 "$job" 2>/dev/null; do sleep 1; drained=$((drained + 1)); done
...
sleep "$watchdog_force_settle_secs"
```

These are the **only** two call sites (one each). `bin/oracle-review.sh` sources
`lib/pro-gate-lib.sh` at startup (unchanged), so both helpers are available to `run_oracle` without
any other wiring.

No other production behavior changed. Before this pass, the drain loop always bounded at the
literal `30` and the force-settle always slept the literal `5`; each helper returns that same
literal for the normal unset environment and for every invalid input in its checked range. The
only different result is an explicitly valid test-only value (`1..30` for drain, `1..5` for
force-settle).

## Signal-order proof

The strengthened PR 924 fixture (`tests/engine.test.sh`) now records an ordered, non-time-based
event stream to a fixture-private file (`PG_TEST_TERM_EVENTS`, never the production `$RUNLOG` or
transcript) and proves, per run:

1. `TERM_RECEIVED` is recorded (at least once) before `RESISTING_AFTER_TERM`.
2. `RESISTING_AFTER_TERM` is recorded before the first `DRAIN_TICK`.
3. At least one `DRAIN_TICK` is recorded — direct proof the fixture was still alive and looping
   *inside* the bounded drain window, not merely proof that elapsed wall time passed.
4. After the whole run exits, `pgrep -g "$ORPHAN_PGID"` (a fixture-private pgid captured by the
   fixture itself, distinct from the wrapper's job PID) returns no matches — direct proof no
   descendant of the TERM-ignoring producer's own process group survives, not merely that the
   wrapper's `kill -0` failed.
5. The pre-existing landmine (a false `promptSubmitted:false` session record) is still planted and
   still defeated: the attempt stays charged (no certified proof) and never announces a refund.

Assertions (`tests/engine.test.sh`, all passing in the clean-rerun capture below):

```
ok - TERM-ignoring Oracle still terminates the attempt
ok - TERM-ignoring Oracle actually started (fixture sanity)
ok - TERM-ignoring Oracle records TERM receipt before it can be reaped
ok - TERM-ignoring Oracle remains alive/resistant after TERM long enough to enter the bounded drain path
ok - TERM-ignoring Oracle process group has no surviving descendant after engine exit
ok - TERM-ignoring fixture planted a false no-submit proof candidate (landmine sanity)
ok - force-killed attempt stays charged despite the false no-submit landmine (no certified proof)
ok - force-killed attempt never announces a refund
```

### The bug this pass found and fixed in the fixture (not in production code)

The fixture's first (pre-fix) design blocked on a plain `read -u 3 -r _` (no `-t`) against a
writer-less private FIFO before `TERM` arrived, and only switched to a timed `read -t 1` poll loop
*after* a state flag was set from the main loop body. Direct, repeated repro (isolated from the
full test suite, `/tmp/pro-gate-pass4-114-20260901-0029/repro-diag2.sh` and `repro-diag3.sh`)
established two things empirically, not by inference:

- `timeout --signal=TERM --kill-after=30` relays a single externally-received `TERM` as **two**
  near-simultaneous deliveries (sub-millisecond apart) to the monitored child's process group —
  consistently, every trial, not a rare race.
- A plain blocking `read` (no `-t`) that is interrupted while a second `TERM` lands before the
  first trap invocation has fully unwound **never resumes** in this bash — confirmed by adding a
  `LOOP_TOP_N` diagnostic event on every loop iteration and observing it stop incrementing forever
  (5+ real seconds, well past the fixture's 1-3 second test-only drain/settle bounds) after the
  double-delivery, even with only a *single* external `kill -TERM` call.

The fix — entirely inside the fixture, no production code touched — has two parts:
1. `RESISTING_AFTER_TERM` is now recorded synchronously inside the trap handler itself, one-shot
   guarded by a `resisting` flag, so it no longer depends on the main loop resuming between signal
   deliveries to observe a state transition.
2. The fixture's main loop now *always* uses `read -t 1 -u 3 -r _ || true` (both before and after
   `TERM`), never a plain blocking `read`. A re-armed 1-second timed read is the only blocking
   primitive in play at any time, so there is never a moment where an interruptible-but-unresumable
   blocking read is outstanding. This preserves the fixture's core property — "no child to kill, no
   CPU burn, only KILL ends it" (verified: still no voluntary exit path; only `SIGKILL` reaps it) —
   while eliminating the wedge.

Verified against the real production `run_oracle` code path (not just the minimal simulation): 12
consecutive standalone iterations through the actual engine
(`/tmp/pro-gate-pass4-114-20260901-0029/repro-fixture.sh 12`), each showing
`READY, TERM_RECEIVED(+), RESISTING_AFTER_TERM, DRAIN_TICK(x3)` in the required order, `rc=6` every
time, and zero surviving descendants (`pgrep -g <captured pgid>` empty) checked directly for three
of the twelve iterations.

## Assertion surface retained

Every pre-existing PR 924 fixture assertion is unchanged in intent and still present: exit 6
(`TERM-ignoring Oracle still terminates the attempt`), fixture-sanity (actually started), the
landmine-defeat pair (charged/no-refund, no certified proof), and no-refund-announced. Nothing was
weakened or removed — two check names were tightened (`force-killed attempt stays charged` →
`force-killed attempt stays charged despite the false no-submit landmine (no certified proof)`;
`TERM-ignoring Oracle leaves no surviving descendant` → `TERM-ignoring Oracle process group has no
surviving descendant after engine exit`) to match the fixture-private-pgid evidence now backing
them, not to change what they assert.

Direct unit coverage was added for both new helpers (`tests/engine.test.sh`, `tdsecs_for`/
`fssecs_for` drivers sourcing the real library fresh per case via `bash -c`), 11 cases each,
covering unset/empty/zero/negative/non-numeric/leading-zero/above-bound/three-digit/min/mid/max:

```
ok - watchdog TERM-drain seconds: unset retains production default 30
ok - watchdog TERM-drain seconds: empty string retains production default 30
ok - watchdog TERM-drain seconds: zero retains production default 30
ok - watchdog TERM-drain seconds: negative retains production default 30
ok - watchdog TERM-drain seconds: non-numeric retains production default 30
ok - watchdog TERM-drain seconds: leading-zero form is rejected, retains default 30
ok - watchdog TERM-drain seconds: above-bound 31 retains production default 30
ok - watchdog TERM-drain seconds: three-digit value retains production default 30
ok - watchdog TERM-drain seconds: valid minimum bound 1 is honored
ok - watchdog TERM-drain seconds: valid mid-range value 15 is honored
ok - watchdog TERM-drain seconds: valid maximum bound 30 is honored
ok - watchdog force-settle seconds: unset retains production default 5
ok - watchdog force-settle seconds: empty string retains production default 5
ok - watchdog force-settle seconds: zero retains production default 5
ok - watchdog force-settle seconds: negative retains production default 5
ok - watchdog force-settle seconds: non-numeric retains production default 5
ok - watchdog force-settle seconds: leading-zero form is rejected, retains default 5
ok - watchdog force-settle seconds: above-bound 6 retains production default 5
ok - watchdog force-settle seconds: three-digit value retains production default 5
ok - watchdog force-settle seconds: valid minimum bound 1 is honored
ok - watchdog force-settle seconds: valid mid-range value 3 is honored
ok - watchdog force-settle seconds: valid maximum bound 5 is honored
```

## Isomorphism proof

### Change: resolve the TERM-drain bound and force-settle wait once per `run_oracle` invocation through two private library helpers

- Ordering preserved: **yes** — both are resolved before the producer/watchdog loop begins
  (line 3156-3157), and the kill-path operation sequence is byte-identical: TERM the producer, drain
  loop (now bounded by the local instead of the literal `30`), KILL fallback, `pkill -TERM -P`/
  `kill -TERM` the job, force-settle sleep (now the local instead of literal `5`), unconditional
  `pg_signal_producer KILL` + `pkill -KILL -P`/`kill -KILL`, `wait "$job"`, the final unconditional
  `pg_signal_producer KILL "$producer"`, then proof revocation (`rm -f "$proof" "$proof.tmp"`).
  Confirmed unchanged by direct grep of the current file (line numbers below).
- Tie-breaking unchanged: **yes** — no comparison, ranking, or selection logic was added or
  reordered; the helpers only supply bounded test-only durations for an existing loop bound and an
  existing sleep. The inner producer subshell's own trap
  (`trap 'pg_signal_producer TERM "$_producer"; sleep 2; pg_signal_producer KILL "$_producer"' TERM HUP INT`,
  line 3187), `--kill-after=30` (line 3174), and every signal target (`pg_signal_producer`,
  unchanged at its own definition) are byte-identical to before this pass.
- Floating-point: **N/A** — integer-seconds string handling in shell `case` matching, identical
  pattern to pass 2/3's helpers.
- RNG seeds: **unchanged / N/A** — no random source introduced.
- Production-default proof: for every unset/empty/zero/negative/malformed/leading-zero/above-bound
  input, `pg_test_watchdog_term_drain_secs` prints literal `30` and
  `pg_test_watchdog_force_settle_secs` prints literal `5` — identical to what production sees today
  with the corresponding env vars never set. Verified directly (see `PASS-4-VERIFICATION.txt`) and
  via all 22 new direct suite assertions ("ok" for each case).
- Golden outputs: the stable suite terminal golden remains `ALL PASS` (`engine-all-pass.txt`,
  unchanged since pass 1; pass 4 does not touch that file or its checksum).

## Scope check

`pg_test_watchdog_term_drain_secs` and `pg_test_watchdog_force_settle_secs` are each called at
exactly one site in `bin/oracle-review.sh` (lines 3156 and 3157), resolved into the locals
`watchdog_term_drain_secs`/`watchdog_force_settle_secs` once before the producer/watchdog loop
begins; the drain loop (line 3260) and the force-settle sleep (line 3270) read those locals. Each
helper is defined exactly once in `lib/pro-gate-lib.sh` (lines 62 and 71). Every other timing
constant in and around the kill path is untouched:

- The inner producer subshell's TERM trap grace (`sleep 2` inside the trap, line 3187) — unchanged.
- `stdbuf -oL -eL "$TIMEOUT_BIN" --signal=TERM --kill-after=30 "$HARD_SECS" ...` (line 3174) —
  unchanged; `--kill-after=30` is still the literal `30`.
- `pg_signal_producer()` (group-kill-then-fallback logic) — unchanged.
- The final unconditional `pg_signal_producer KILL "$producer"` (line 3278) and proof revocation
  (`rm -f "$proof" "$proof.tmp"`, immediately following) — unchanged.
- Pass 3's watchdog observation cadence (`pg_test_watchdog_sleep_secs`, a distinct call site) —
  untouched by this pass.
- `PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS=3` and `PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS=1` are
  set only in the PR 924 fixture (the only one of the three watchdog fixtures that exercises this
  drain/force-settle path); PR 922/923 gained no override here, and no generic "fast mode" was
  introduced.

## Rollback

Remove `pg_test_watchdog_term_drain_secs` and `pg_test_watchdog_force_settle_secs` from
`lib/pro-gate-lib.sh`, restore the literals `30` and `5` at the `run_oracle` drain-loop and
force-settle-sleep sites in `bin/oracle-review.sh`, and in `tests/engine.test.sh`: remove the 22
direct helper boundary checks (`tdsecs_for`/`fssecs_for` drivers), the two fixture-local env
assignments, and revert the PR 924 fixture body to its actual pre-pass-4 shape (`trap '' TERM`,
a single blocking `read -u 3 -r _`, PID-only no-survivor evidence, and no event/meta/PGID files) —
equivalent to restoring these three files to the pass 3 commit (`201fd69`). No production default
changes as part of this rollback because none changed in this pass.

## Deterministic deadline budget

This pass does not shorten any production bound (unlike passes 1-3): the drain loop's cap and the
force-settle sleep remain 30 and 5 seconds respectively for every real invocation. The lever is
test-only observability and test-only shortened bounds inside exactly one fixture
(`PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS=3`, `PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS=1`), which
cuts that one fixture's own worst-case drain/settle wait from up to 35 seconds (30 + 5) to at most
4 seconds (3 + 1) — a deterministic 31-second reduction confined to the PR 924 fixture's kill path,
on top of pass 1's 357-second timeout-grace reduction, pass 2's 87-second pre-retry-probe
reduction, and pass 3's 27-second watchdog-cadence reduction (9 seconds x 3 fixtures).

Actual wall acceptance (same-revision hosted A/B comparison) remains **deferred to pass 10**, per
the mission's fixed acceptance protocol. This pass reports only the deterministic code-level budget
and the local full-suite completed-run result below.

## Verification status

- `bash -n lib/pro-gate-lib.sh`, `bash -n bin/oracle-review.sh`, `bash -n tests/engine.test.sh`:
  all PASS (exit 0). Re-confirmed after the full-suite run.
- `shellcheck --severity=error lib/pro-gate-lib.sh bin/oracle-review.sh tests/engine.test.sh`
  (shellcheck installed in this environment): PASS (no output, no errors).
- Direct boundary checks against both real library helpers, sourced fresh per case
  (`bash -c ". lib/pro-gate-lib.sh; pg_test_watchdog_term_drain_secs"` /
  `..._force_settle_secs`, matching the repository's existing bash -c source-lib pattern): all 22
  cases PASS, embedded directly in `tests/engine.test.sh` (`tdsecs_for`/`fssecs_for`), not a
  separate scratch script this pass.
- `sha256sum -c tests/artifacts/perf/2026-08-31-ci-optimization/golden_checksums.txt`: OK
  (`engine-all-pass.txt` unchanged from pass 1).
- `git diff --check`: PASS (no whitespace errors).
- Complete local post-change behavior run, `bash tests/engine.test.sh`, run in the foreground (not
  backgrounded, via `/usr/bin/time`, waited to process exit): **exit 0, terminal `ALL PASS`,
  825/825 `ok -` lines, zero `not ok`/`FAIL`/`FAILURES` lines, elapsed 1183.13 seconds
  (19m43.13s)**, captured under
  `/tmp/pro-gate-pass4-114-20260901-0029/full-suite-3.{stdout,stderr,time}`. A prior same-pass
  foreground run (`full-suite-2.*`, elapsed 1171.47s, exit 1) hit exactly the same two unrelated
  `--harvest` stale-throttle timing failures documented in `PASS-3-VERIFICATION.txt`
  (`stale-throttle stale scratch retains reservation with its existing exit` and `throttled stale
  scratch keeps its reservation and writes the existing cooldown`, both a fixed 5-second CDP-probe
  window timing out under host load) and zero PR-924-related failures; this immediate clean rerun
  reproduced neither and is the evidence of record for this pass, per the mission's one-clean-rerun
  allowance for a diagnosed unrelated flake. See `PASS-4-VERIFICATION.txt` for full detail,
  including the assertion-count reconciliation against pass 3's 800 and the fixture-bug diagnosis.
- Scope check: both helpers are called at exactly one site each in `bin/oracle-review.sh` (lines
  3156, 3157), read into locals consumed at lines 3260 and 3270; defined exactly once each in
  `lib/pro-gate-lib.sh` (lines 62, 71). `PRO_GATE_TEST_WATCHDOG_TERM_DRAIN_SECS`/
  `PRO_GATE_TEST_WATCHDOG_FORCE_SETTLE_SECS` appear only in the PR 924 fixture plus the suite's own
  `tdsecs_for`/`fssecs_for` boundary-check drivers; no other fixture gained an override.
- `PASS-1.md`, `PASS-2.md`, `PASS-2-VERIFICATION.txt`, `PASS-3.md`, `PASS-3-VERIFICATION.txt`,
  `VERIFICATION.txt`, `engine-all-pass.txt`, and `golden_checksums.txt` were not modified by this
  pass.

## Pass 4 result

The completed foreground run is fully green: exit 0, `ALL PASS`, 825 assertions (800 carried
forward, 27 added, 2 renamed for evidence-accuracy rather than removed, net +25), zero failures,
1183.13 seconds elapsed. No production bound changed: both helpers still return their exact
production defaults (30, 5) for every unset/invalid input, and their only observable difference
from the prior literals is an explicitly valid test-only value, never set outside the PR 924
fixture and the suite's own boundary-check cases. Both are resolved once into local values per
`run_oracle` invocation before the kill path runs; the inner trap's 2-second TERM grace,
`--kill-after=30`, every signal target, the wait/reap sequence, and proof-revocation ordering are
byte-identical to before this pass. This pass also diagnosed and fixed a genuine bash
blocking-read-under-signal-storm hazard in the fixture itself (not production code): a plain
untimed `read`, once interrupted by `timeout`'s empirically-confirmed double-TERM relay, never
resumed in this bash, which would have made the fixture's drain-window evidence structurally
unobtainable without the fix. Fixing it — always polling with a re-armed 1-second timed read,
recording the resistance transition synchronously inside the trap — closes that gap while
preserving every existing exit-6, charged/no-refund, no-certified-proof, and no-survivor assertion.
