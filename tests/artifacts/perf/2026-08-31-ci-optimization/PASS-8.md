# Pass 8/10 — ZERO-CHANGE

**Date:** 2026-09-01
**Verdict:** ZERO-CHANGE — no implementation reached the required `Impact × Confidence / Effort >= 2.0` score.

## Scope and final tree

- Inspected only the current uncommitted `tests/engine.test.sh` diff; no prior-agent transcript was read.
- Restored `tests/engine.test.sh` exactly to `HEAD` after rejecting the partial design and its smaller replacement attempt.
- Did not edit, revert, or stage `.skill-loop-progress.md`.
- No production files or production hooks changed.

## Scoring ledger

| Candidate | Impact | Confidence | Effort | Score | Decision |
|---|---:|---:|---:|---:|---|
| Current partial PATH-wrapper diff | 3 | 1 | 5 | **0.6** | Reject |
| Fixture PID/process-event replacement attempt | 4 | 2 | 5 | **1.6** | Reject |
| Final delivered change | 0 | n/a | 0 | **0.0** | ZERO-CHANGE |

The current partial had 201 additions and 12 deletions (213 changed lines). It interposed `sleep`, `node`, `mkdir`, and optionally `flock`. The attempted narrower replacement still needed 196 additions and 27 deletions (223 changed lines), so it did not materially reduce maintenance burden.

## Deterministic wait budget

| Fixture wait | Original fixed duration | Assessment |
|---|---:|---|
| Delayed organizer post-run wait | 6 s | Direct fixture synchronization candidate |
| Organizer join holder, rename-disabled case | 3 s | Direct fixture synchronization candidate |
| Organizer join holder, missing-title case | 3 s | Direct fixture synchronization candidate |
| No-flock owner pre-publication hold | 2 s | Requires observing an engine retry before publication |
| No-flock owner post-publication hold | 2 s | Requires preserving the fallback retry behavior |

- Raw fixed-delay ceiling: **16 seconds** (`6 + 3 + 3 + 2 + 2`).
- The partial diff only targeted the first three waits: **12 seconds** theoretical savings.
- A behavior-preserving no-flock barrier must retain at least one production `sleep 1` retry after its failed `mkdir`; its best-case wall-clock saving is therefore about **3 seconds**, for a theoretical fully-safe ceiling of **15 seconds**.
- Delivered deterministic savings: **0 seconds**. No unproven optimization remains in the tree.

## Concrete rejections

1. **Partial delayed-organizer wrapper:** matching a generic `sleep 15` can release the timer after terminal finalization, but proving the parent helper subsequently completed requires PID lifetime assumptions. The partial added a `node` wrapper as a second indirect observation rather than using a fixture-owned event. It also expands `PATH` for all engine subprocesses.
2. **Partial organizer-join wrappers:** `JOIN_BIN` is never prepended to `PATH`, and `run_join_only_case` does not pass the new `PG_TEST_JOIN_*` release/timeout variables. The wrapper implementation is therefore both unexercised and unable to complete the intended barrier.
3. **Process-observation replacement:** observing direct engine children with `pgrep -P` and matching `ps` command strings (`flock -w` or `sleep 1`) removes command interposition but depends on shell `exec` topology, command rendering, and host tooling. It is not a robust fixture contract across supported environments.
4. **No-flock publication barrier:** the only external proof that the contender saw the empty directory is the engine's private fallback retry. Releasing immediately after process observation weakens the metadata-publication overlap; retaining a second observed retry restores a duration-based synchronization step. A production hook would make this deterministic, but production hooks are out of scope.

## Proof and rollback

- `git diff --exit-code -- tests/engine.test.sh` passed: the test file is identical to `HEAD`.
- `bash -n tests/engine.test.sh`, ShellCheck error severity, the captured golden checksum, and `git diff --check` all passed; details are in `PASS-8-VERIFICATION.txt`.
- Rollback is intrinsic: there is no source-code change to revert. Removing only this pass's two artifact files restores the artifact directory to its prior contents.
