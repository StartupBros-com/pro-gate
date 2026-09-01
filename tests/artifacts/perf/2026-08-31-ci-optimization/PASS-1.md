# CI wait optimization — Pass 1: fixture-local hard-cap grace

## Baseline evidence

- Source: `../2026-08-31-ci-runner/BASELINE.md` and `hosted-log-gap-analysis.json`.
- `bash tests/engine.test.sh` mean: **1560.969s**; p95: **1605.500s** (78.15% of mean `Run tests` wall time).
- The profile identified three `engine.test.sh` silent gaps of **165.624304s**, **165.608998s**, and **165.593755s**. They correspond to the fail-closed ambiguity fixtures for failed Oracle log capture (PR 921), complete post-click timeout metadata (PR 93), and partial commit metadata (PR 94).
- Opportunity score: **Impact 5 × Confidence 5 / Effort 1 = 25**.
- Baseline data integrity check: `sha256sum -c tests/artifacts/perf/2026-08-31-ci-runner/evidence-checksums.txt` verified all five recorded inputs.

## Exact single lever

Each of the three identified `env ... bash "$ENGINE"` invocations in `tests/engine.test.sh` now supplies the already-supported, per-process `PRO_GATE_TIMEOUT_GRACE=1`.

No production code changed. In particular, `bin/oracle-review.sh` retains the production default `PRO_GATE_TIMEOUT_GRACE:-120`, coreutils `--kill-after=30`, the pre-retry 30-second probe, and every other fixture is unchanged. The existing PR 926 hard-cap fixture already uses `PRO_GATE_TIMEOUT_GRACE=1`, providing direct test-suite evidence that one second is adequate; no extra scheduler slack was added.

## Assertion surface retained

The three fixture blocks are unchanged except for their local environment assignment. Their existing checks continue to require:

1. exit status 6;
2. exactly one Oracle invocation where asserted;
3. a retained charged round;
4. suppressed retry; and
5. no refund announcement.

## Isomorphism proof

### Change: reduce only the test hard-cap grace from the production fallback to one second in three known ambiguity fixtures

- Ordering preserved: **yes** — `engine.test.sh` remains serial and the three commands remain in their original positions; only the deadline passed to each child process changes.
- Tie-breaking unchanged: **yes** — no collection, comparison, ranking, selection, or fallback branch was added or reordered. The same existing ambiguity classification and assertions decide each outcome.
- Floating-point: **N/A** — the lever is an integer-seconds environment value in shell arithmetic; no floating-point values are evaluated.
- RNG seeds: **unchanged / N/A** — this shell suite introduces no random source or seed in the changed invocations.
- Golden outputs: the stable suite terminal golden is `ALL PASS` (emitted only when `FAILS=0` at `tests/engine.test.sh:5055`). The completed-run verification record and its checksum are stored alongside this artifact after the suite finishes.

## Rollback

Remove only the three `PRO_GATE_TIMEOUT_GRACE=1` fixture-local assignments from `tests/engine.test.sh` (or restore that file if no other changes are present). Do not alter `bin/oracle-review.sh` or production timeout defaults.

## Verification status

- `bash -n tests/engine.test.sh`: PASS.
- `git diff --check`: PASS.
- Complete local post-change behavior run, `bash tests/engine.test.sh`: PASS (exit 0, `ALL PASS`, 1465.03s / 24m25.03s). This is an observed local full-suite run, not a controlled same-host A/B comparison against the hosted multi-SHA baseline; exact command/result evidence is in `VERIFICATION.txt`.
- Code-level deadline budget: each target path changes from `HARD_SECS=125` (5s timeout plus the default 120s grace) to 6 (5s plus fixture-local 1s grace): a deterministic 119s reduction per path and 357s across the three fixtures. Actual wall-time savings require controlled measurement.
- Authoritative performance acceptance is deferred to pass 10, using a same-revision hosted comparison.
- Terminal golden: `engine-all-pass.txt` matches the captured terminal marker and `sha256sum -c golden_checksums.txt` passes.
