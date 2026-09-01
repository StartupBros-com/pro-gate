# CI wait optimization — Pass 2: test-only pre-retry probe deadline override

## Baseline evidence

- Source: pass 1's own completed-run evidence (`PASS-1.md`, `VERIFICATION.txt`) plus the
  original hosted profile in `../2026-08-31-ci-runner/`.
- `bin/oracle-review.sh`'s retry loop probes CDP for a live conversation immediately before
  every retry with a hard-coded `30` seconds passed to `cdp-salvage.mjs --probe`. This call
  site is distinct from the timeout-grace hard cap pass 1 already shortened.
- The same three fail-closed ambiguity fixtures pass 1 identified (PR 921 failed Oracle log
  capture, PR 93 complete post-click timeout metadata, PR 94 partial commit metadata) each
  reach this pre-retry probe once, so each fixture was still paying the full 30s wait on top
  of pass 1's grace reduction.
- Opportunity score: Impact 5 × Confidence 5 / Effort 2 = **12.5**. Effort is 2 (not 1, as in
  pass 1) because this lever requires a new private library helper plus a real-helper test
  migration, not a single fixture-local environment assignment.

## Exact single lever

`bin/oracle-review.sh` already sources `lib/pro-gate-lib.sh` at startup (see `SELF`/lib-lookup
block near the top of the file). A new private helper, `pg_test_pre_retry_probe_secs`, is added
to `lib/pro-gate-lib.sh`:

```sh
pg_test_pre_retry_probe_secs() {
  case "${PRO_GATE_TEST_PRE_RETRY_PROBE_SECS:-}" in
    [1-9]|[12][0-9]|30) printf '%s\n' "$PRO_GATE_TEST_PRE_RETRY_PROBE_SECS" ;;
    *) printf '30\n' ;;
  esac
}
```

`bin/oracle-review.sh`'s pre-retry probe site now reads:

```sh
PRE_RETRY_PROBE_SECS="$(pg_test_pre_retry_probe_secs)"
...
node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" "$PRE_RETRY_PROBE_SECS" "$PORT" >/dev/null 2>>"$RUNLOG"; PRC=$?
```

The helper is called **only** at this one pre-retry probe call site. The two other
`cdp-salvage.mjs --probe` invocations in `bin/oracle-review.sh` (the no-think watchdog probe
and the reservation-write-failure salvage-wait loop) remain the literal `30` they always were —
verified by direct grep below.

No other production behavior changed. Before this pass, the pre-retry call used the literal
`30`; the helper returns that same literal for the normal unset environment and for every invalid
input. Its only different result is an explicitly valid test-only value from decimal 1..30.

## Assertion surface retained

The three fixture blocks (PR 921, PR 93, PR 94) are unchanged except for their local
`PRO_GATE_TEST_PRE_RETRY_PROBE_SECS=1` environment assignment (already present from the prior
incomplete pass-2 draft; preserved here). Their existing checks continue to require:

1. exit status 6;
2. exactly one Oracle invocation where asserted;
3. a retained charged round;
4. suppressed retry; and
5. no refund announcement.

`tests/engine.test.sh` no longer extracts the validation block from `bin/oracle-review.sh` via
`awk`. Instead it sources the real library (`lib/pro-gate-lib.sh`) in a fresh `bash -c`
subprocess per the repository's existing pattern (used throughout the suite, e.g. lines 156,
707, 1043 for other `pg_*` helpers) and calls `pg_test_pre_retry_probe_secs` directly — the
actual production function, not a copy or extracted fragment. All eleven boundary cases from
the prior draft are preserved: unset, empty, zero, negative, non-numeric, leading-zero, >30,
three-digit, minimum bound 1, mid-range 15, maximum bound 30.

## Isomorphism proof

### Change: extract the pre-retry probe deadline parse into a private library helper, called only at the pre-retry probe site

- Ordering preserved: **yes** — the retry loop's control flow, probe call, and branch decisions
  (live/throttled/inconclusive) are unchanged. With the test-only variable unset, the helper emits
  the same literal `30` previously passed at this call site.
- Tie-breaking unchanged: **yes** — no comparison, ranking, or selection logic was added. The
  helper only selects a bounded test deadline; the two other probe call sites' untouched literal
  `30` proves the override did not broaden to other paths.
- Floating-point: **N/A** — integer-seconds string handling in shell case matching.
- RNG seeds: **unchanged / N/A** — no random source introduced.
- Production-default proof: for every unset/empty/zero/negative/malformed/leading-zero/>30
  input, `pg_test_pre_retry_probe_secs` prints literal `30` — identical to what production sees
  today with `PRO_GATE_TEST_PRE_RETRY_PROBE_SECS` never set. Verified directly (see
  PASS-2-VERIFICATION.txt) and via all 11 suite assertions ("ok" for each case).
- Golden outputs: the stable suite terminal golden remains `ALL PASS` (`engine-all-pass.txt`,
  unchanged, still verified by `sha256sum -c golden_checksums.txt` against the pass-1 golden —
  pass 2 does not touch that file).

## Rollback

Revert the `pg_test_pre_retry_probe_secs` helper addition in `lib/pro-gate-lib.sh`, restore the
literal `30` at the pre-retry probe site in `bin/oracle-review.sh`, and remove the direct helper
boundary checks plus the three fixture-local `PRO_GATE_TEST_PRE_RETRY_PROBE_SECS=1` assignments
from `tests/engine.test.sh` (equivalent to restoring these three files to commit `8ee53de`). No
production default changes as part of this rollback because none changed in this pass.

## Additional deterministic deadline budget

Each of the three ambiguity fixtures (PR 921, PR 93, PR 94) reaches the pre-retry probe exactly
once under `PRO_GATE_MAX_RETRIES=1`. Each fixture-local `PRO_GATE_TEST_PRE_RETRY_PROBE_SECS=1`
reduces that single probe's deadline argument to `cdp-salvage.mjs --probe` from the production
literal 30 seconds to 1 second: a deterministic 29-second reduction per fixture, **87 seconds
across the three fixtures** (29 × 3 = 87), on top of pass 1's separate 357-second grace-window
reduction. This is a code-level budget reduction only — actual wall-clock savings depend on how
long `cdp-salvage.mjs` itself takes to determine "no live conversation" within that window, and
are not asserted here.

Actual wall acceptance (same-revision hosted A/B comparison) is **deferred to pass 10**, per the
mission's fixed acceptance protocol. This pass reports only the deterministic code-level budget
and the local full-suite completed-run result below.

## Verification status

- `bash -n lib/pro-gate-lib.sh`, `bash -n bin/oracle-review.sh`, `bash -n tests/engine.test.sh`: all PASS (exit 0).
- Direct boundary checks against `pg_test_pre_retry_probe_secs` sourced from the real library
  (11 cases: unset, empty, 0, -1, abc, 007, 31, 100, 1, 15, 30): all PASS. Ran from
  `/tmp/pro-gate-pass2-boundary-114-20260831/boundary-checks.sh`.
- `sha256sum -c tests/artifacts/perf/2026-08-31-ci-optimization/golden_checksums.txt`: OK
  (`engine-all-pass.txt` unchanged from pass 1).
- `git diff --check`: PASS (no whitespace errors).
- Complete local post-change behavior run, `bash tests/engine.test.sh`, run in the foreground
  (not backgrounded): **PASS — exit 0, terminal `ALL PASS`, 789/789 `ok -` assertions, zero
  `not ok`/`FAIL`/`FAILURES` lines, 1345.98 seconds (22m25.98s)**, measured by
  `/usr/bin/time -f 'ELAPSED_SECONDS=%e'`. Full evidence in `PASS-2-VERIFICATION.txt`.
- Scope check: `pg_test_pre_retry_probe_secs` is called at exactly one site in
  `bin/oracle-review.sh` (the pre-retry probe). The no-think watchdog probe
  (`node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT"`) and the reservation-write
  salvage-wait loop (`while node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT" ...`)
  both retain the literal `30` untouched.
- `PASS-1.md`, `VERIFICATION.txt`, `engine-all-pass.txt`, and `golden_checksums.txt` were not
  modified by this pass.
