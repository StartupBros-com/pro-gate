# CI wait optimization — Pass 3: test-only watchdog observation cadence override

## Baseline evidence

- Source: pass 1's and pass 2's own completed-run evidence (`PASS-1.md`, `PASS-2.md`,
  `PASS-2-VERIFICATION.txt`) plus the original hosted profile in `../2026-08-31-ci-runner/`.
- `run_oracle`'s watchdog loop (`bin/oracle-review.sh`) polls the background producer job on a
  fixed `sleep 10` cadence: `while kill -0 "$job" 2>/dev/null; do sleep 10; ...; done`. This is a
  distinct call site from both levers pass 1 (`PRO_GATE_TIMEOUT_GRACE`, the coreutils hard-cap
  grace) and pass 2 (`pg_test_pre_retry_probe_secs`, the pre-retry CDP probe deadline) already
  shortened.
- Three watchdog-driven engine.test.sh fixtures each keep the observation loop alive across
  multiple 10-second polls before the loop's own threshold check (the pre-existing fixture-local
  `STALL_SECS=1`) fires and the kill path runs:
  - pre-browser stall (`oracle-stall`, PR 922): a lifecycle-free stall kill, exit 6 charged/no-refund.
  - post-lifecycle stall (`oracle-stall-landed`, PR 923): a stall kill AFTER browser lifecycle
    lines landed, exit 6 charged/no-refund (the converse case that proves the charge persists once
    lifecycle evidence exists).
  - TERM-ignoring producer (`oracle-term-ignoring`, PR 924): the watchdog's TERM->30x1s
    drain->KILL fallback path, proving no surviving descendant.
  Each of these previously paid at least one full unshortened `sleep 10` per watchdog iteration
  before its 1-second stall/no-think threshold could even be evaluated, because the loop always
  sleeps first and checks second.
- Opportunity score: Impact 4 × Confidence 4 / Effort 2 = **8** (per mission).

## Exact single lever

`lib/pro-gate-lib.sh` gains one new private helper, directly beside pass 2's
`pg_test_pre_retry_probe_secs` (same file, same pattern):

```sh
# Test-only watchdog observation cadence. Invalid input deliberately falls back
# to the production 10-second cadence and can never extend it.
pg_test_watchdog_sleep_secs() {
  case "${PRO_GATE_TEST_WATCHDOG_SLEEP_SECS:-}" in
    [1-9]|10) printf '%s\n' "$PRO_GATE_TEST_WATCHDOG_SLEEP_SECS" ;;
    *) printf '10\n' ;;
  esac
}
```

`bin/oracle-review.sh` resolves the cadence once per `run_oracle` invocation before it starts the
producer/watchdog loop, then the loop reads that local value:

```sh
local strategy="$1" job started size last_size last_change now last_line prc watchdog_sleep_secs
...
watchdog_sleep_secs="$(pg_test_watchdog_sleep_secs)"
...
while kill -0 "$job" 2>/dev/null; do
  sleep "$watchdog_sleep_secs"
  [ -s "$CAPTURE_OUT" ] && continue   # findings are landing — let the run finish undisturbed
  ...
```

This is the **only** helper call site. `bin/oracle-review.sh` sources `lib/pro-gate-lib.sh` at
startup (unchanged), so the helper is available to `run_oracle` without any other wiring. Hoisting
that resolution avoids a production-loop command substitution on every watchdog poll.

No other production behavior changed. Before this pass, the loop always slept the literal `10`;
the helper returns that same literal for the normal unset environment and for every invalid
input in the range checked. Its only different result is an explicitly valid test-only value from
decimal `1..10`.

## Assertion surface retained

The three watchdog fixtures (PR 922 pre-browser stall, PR 923 post-lifecycle stall, PR 924
TERM-ignoring producer) are unchanged except for their local
`PRO_GATE_TEST_WATCHDOG_SLEEP_SECS=1` environment assignment. Their existing checks continue to
require:

1. exit status 6 (all three);
2. a retained charged round (all three, keyed to their respective `RKEY_92x`);
3. no refund announcement (all three);
4. for PR 923 specifically: the charge survives even though browser lifecycle lines had already
   landed before the kill — the converse proof pass 1/2's notes describe;
5. for PR 924 specifically: the TERM-ignoring producer leaves no surviving descendant
   (`kill -0 "$ORPHAN_SEEN"` fails after the run), proving the blunt KILL fallback still reaches a
   process that refuses to drain, and the force-killed attempt stays charged.

No fixture's stall/no-think threshold, signal order, drain-wait duration, force-settle wait, or
coreutils `--kill-after` value was touched. Only the loop's own polling cadence changed, and only
in these three fixtures.

## Isomorphism proof

### Change: resolve the watchdog observation cadence once per `run_oracle` invocation through a private library helper

- Ordering preserved: **yes** — cadence resolution is completed before the producer/watchdog loop begins, and the watchdog loop's operation sequence is untouched: sleep/observe,
  check `$CAPTURE_OUT`, measure `$RUNLOG` growth, compare against `STALL_SECS`, probe no-think via
  `cdp-salvage.mjs --probe ... 30 ...` when applicable (still the literal `30`, unchanged), signal
  the producer TERM, bounded 30×1s drain loop (unchanged), KILL fallback (unchanged), `wait`/reap
  (unchanged), revoke the transcript proof (unchanged). Only the bounded test-only interval passed
  to the loop's own `sleep` changed; helper resolution is hoisted once per `run_oracle` invocation,
  avoiding a command substitution on every production-loop iteration.
- Tie-breaking unchanged: **yes** — no comparison, ranking, or selection logic was added or
  reordered; the helper only supplies a bounded test-only sleep duration. `STALL_SECS`,
  `NOTHINK_SECS`, `HARD_SECS`, the 30-second no-think probe, the 30×1s drain loop, the 5-second
  post-TERM sleep before the blunt KILL fallback, and `--kill-after=30` are all byte-identical to
  before this pass (verified by grep below).
- Floating-point: **N/A** — integer-seconds string handling in shell case matching, identical
  pattern to pass 2's helper.
- RNG seeds: **unchanged / N/A** — no random source introduced.
- Production-default proof: for every unset/empty/zero/negative/malformed/leading-zero/above-bound
  input, `pg_test_watchdog_sleep_secs` prints literal `10` — identical to what production sees
  today with `PRO_GATE_TEST_WATCHDOG_SLEEP_SECS` never set. Verified directly (see
  `PASS-3-VERIFICATION.txt`) and via all 11 new suite assertions ("ok" for each case).
- Golden outputs: the stable suite terminal golden remains `ALL PASS` (`engine-all-pass.txt`,
  unchanged since pass 1; pass 3 does not touch that file or its checksum).

## Scope check

`pg_test_watchdog_sleep_secs` is called at exactly one site in `bin/oracle-review.sh`, where
`run_oracle` resolves it into a local variable once before starting its producer/watchdog loop. The
loop then reads that local variable; every other timing constant in and around the loop is untouched:

- `STALL_SECS="${PRO_GATE_STALL_SECS:-600}"` and `NOTHINK_SECS="${PRO_GATE_NOTHINK_SECS:-600}"` —
  unchanged production defaults (only fixture-local env overrides existed before this pass and
  still exist, untouched by this pass).
- `HARD_SECS` / `PRO_GATE_TIMEOUT_GRACE` — untouched (pass 1's lever).
- The no-think probe (`cdp-salvage.mjs --probe "$RUN_MARKER" 30 "$PORT"`, inside the loop) —
  still the literal `30`.
- The pre-retry probe (`pg_test_pre_retry_probe_secs`) — untouched (pass 2's lever, a different
  call site entirely).
- The 30-iteration, 1-second-each drain wait (`while [ "$drained" -lt 30 ] ...; do sleep 1; ...`)
  — unchanged.
- The 5-second sleep before the blunt KILL fallback (`sleep 5`) — unchanged.
- coreutils `timeout --signal=TERM --kill-after=30 "$HARD_SECS"` — unchanged.
- `PRO_GATE_TEST_WATCHDOG_SLEEP_SECS=1` is set only in the three named fixtures (PR 922 near
  line 1328, PR 923 near line 1355, PR 924 near line 1425); no other fixture gained the override,
  and no generic "fast mode" was introduced.

## Rollback

Remove the `pg_test_watchdog_sleep_secs` helper from `lib/pro-gate-lib.sh`, restore the literal
`sleep 10` at the `run_oracle` watchdog loop site in `bin/oracle-review.sh`, and remove the direct
helper boundary checks plus the three fixture-local `PRO_GATE_TEST_WATCHDOG_SLEEP_SECS=1`
assignments from `tests/engine.test.sh` (equivalent to restoring these three files to the pass 2
commit). No production default changes as part of this rollback because none changed in this
pass.

## Deterministic deadline budget

The watchdog loop always sleeps before it checks, so any kill path pays at least one full
interval per poll before its threshold trips. With the pre-existing fixture-local `STALL_SECS=1`
and the unmodified production `sleep 10`, each poll iteration in these three
fixtures previously spent 10 seconds asleep before evaluating a 1-second stall threshold that had
already elapsed — a full order of magnitude of dead wait per iteration. Reducing the sleep
interval to `1` second in exactly these three fixtures cuts that per-iteration floor from 10
seconds to 1 second: a deterministic 9-second reduction on the loop's first poll in each of the
three fixtures (27 seconds across the three), on top of pass 1's 357-second grace-window
reduction and pass 2's 87-second pre-retry-probe reduction on the separate ambiguity-fixture set.
This is a code-level budget reduction only — actual wall-clock savings depend on how quickly the
producer/tee pipeline drains within the loop's kill path, and are not asserted here.

Actual wall acceptance (same-revision hosted A/B comparison) is **deferred to pass 10**, per the
mission's fixed acceptance protocol. This pass reports only the deterministic code-level budget
and the local full-suite completed-run result below.

## Verification status

- `bash -n lib/pro-gate-lib.sh`, `bash -n bin/oracle-review.sh`, `bash -n tests/engine.test.sh`:
  all PASS (exit 0). Re-confirmed after the full-suite run.
- `shellcheck --severity=error lib/pro-gate-lib.sh bin/oracle-review.sh tests/engine.test.sh`
  (shellcheck 0.11.0): PASS (no output, no errors).
- Direct boundary checks against `pg_test_watchdog_sleep_secs` sourced from the real library (11
  cases: unset, empty, 0, -1, abc, 007, 11, 100, 1, 5, 10): all PASS. Ran from
  `/tmp/pro-gate-pass3-boundary-114-20260901-0000/boundary-checks.sh`.
- `sha256sum -c tests/artifacts/perf/2026-08-31-ci-optimization/golden_checksums.txt`: OK
  (`engine-all-pass.txt` unchanged from pass 1).
- `git diff --check`: PASS (no whitespace errors).
- Complete local post-change behavior run, `bash tests/engine.test.sh`, run in the foreground
  (not backgrounded, via `/usr/bin/time`, waited to process exit) under a fresh unique
  `/tmp/pro-gate-pass3-reverify-114-20260831-2350` capture directory: **exit 0, terminal `ALL PASS`,
  800/800 `ok -` lines, zero `not ok`/`FAIL`/`FAILURES` lines, elapsed 1189.53 seconds
  (19m49.53s)**. This is the completed foreground run for this pass (a prior same-pass attempt hit
  two unrelated `--harvest` stale-throttle timing failures under host CPU contention and is
  superseded by this clean run; see `PASS-3-VERIFICATION.txt` for the flake analysis). The run
  completed inside a single foreground tool call — the 35-minute no-progress checkpoint and
  45-minute tool ceiling were never approached. Full detail, including the 11 new watchdog-cadence
  assertions and the assertion-count reconciliation against pass 2's 789, is in
  `PASS-3-VERIFICATION.txt`.
- Scope check: `pg_test_watchdog_sleep_secs` is called at exactly one site in
  `bin/oracle-review.sh` — `run_oracle` resolves it once into the local variable
  `watchdog_sleep_secs` at line 3154, before the producer/watchdog loop begins; the loop's own
  `sleep` at line 3207 reads that local variable — and is defined exactly once in
  `lib/pro-gate-lib.sh` (line 53). `PRO_GATE_TEST_WATCHDOG_SLEEP_SECS=1` remains set only in the
  three fixture blocks named above (confirmed at lines 1328, 1355, 1425) plus the suite's own
  `wdsecs_for` boundary-check driver (lines 1598-1602); no other fixture gained the override, and
  no generic fast-mode flag was introduced.
- `PASS-1.md`, `PASS-2.md`, `PASS-2-VERIFICATION.txt`, `VERIFICATION.txt`, `engine-all-pass.txt`,
  and `golden_checksums.txt` were not modified by this pass.

## Pass 3 result

The completed foreground run is fully green: exit 0, `ALL PASS`, 800 assertions (789 carried
forward + 11 new), zero failures, 1189.53 seconds elapsed. No production behavior changed: the
helper still returns `10` by default, and its only observable difference from the prior literal
`sleep 10` is an explicitly valid test-only value in `1..10`, never set outside the three named
fixtures and the suite's own boundary-check cases. The cadence is resolved once into a local value
(`watchdog_sleep_secs`) per `run_oracle` invocation before the watchdog loop, avoiding repeated
production-loop command substitutions; all watchdog thresholds, probes, signals, drains, KILL/reap,
and proof revocation remain unchanged.
