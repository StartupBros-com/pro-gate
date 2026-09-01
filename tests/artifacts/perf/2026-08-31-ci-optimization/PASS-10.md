# Pass 10/10 — Golden + hosted convergence gate

**Verdict:** CONVERGED — cap reached (mission 10, stop condition "Pass 10 completes"). No new
source, test, or workflow change. This pass re-runs the exact eight `.github/workflows/ci.yml`
"Run tests" commands plus its "Validate data and shell files" block once, serially, in the
foreground; verifies every prior pass's checksum/behavior proof is still intact; and records the
hosted-PR acceptance plan. It does **not** re-review the full diff — the prior adversarial diff
review already found zero correctness findings and verified all production defaults, and that
finding is carried forward, not repeated.

## 10-pass table

| Pass | Mission | Verdict | Commit | Deterministic budget delivered |
| ---: | --- | --- | --- | ---: |
| 1 | Existing hard-cap override | PRODUCTIVE | `8ee53de` | 357s (119s × 3 ambiguity fixtures) |
| 2 | Pre-retry probe seam | PRODUCTIVE | `eb11e66` | 87s (29s × 3) |
| 3 | Watchdog observation cadence | PRODUCTIVE | `201fd69` | 27s (9s × 3) |
| 4 | TERM-drain/force-settle waits | PRODUCTIVE | `438ed7f` | 31s (PR 924 worst case) |
| 5 | CDP main poll seam | PRODUCTIVE-ENABLER, CONDITIONAL | `327da27` | 0s standalone; prerequisite for pass 7 |
| 6 | Scratch-render sampling seam | PRODUCTIVE | `6f5d1cd` | 19.6s (source-derived) |
| 7 | Classified CDP deadlines | PRODUCTIVE | `31c8262` | 217.566s (source-derived); measured p50 −234.93s |
| 8 | Event-confirmed engine waits | ZERO-CHANGE | `e71d1a2` | 0s (16s raw ceiling rejected; best-case 15s not delivered) |
| 9 | Re-profile and re-rank | PRODUCTIVE-MEASUREMENT | `8a695fd` | 0s (measurement only) |
| 10 | Golden + hosted convergence gate | CONVERGED | *(none — measurement/verification only)* | 0s (closure only) |

**Sum of deterministic code-level budget reductions across passes 1–7 (excluding pass 5's
standalone-zero enabler credit, which is folded into pass 7's total):**
357 + 87 + 27 + 31 + 19.6 + 217.566 = **739.166 seconds**. This is a code-level deadline/sleep
budget sum, not a claim that hosted wall time falls by exactly this amount — it is corroborated,
not proven, by the directional local deltas below.

## Pass 9 — measured current profile (carried forward, not re-run as new data)

| Field | Value |
| --- | --- |
| Serial wall / CPU | 1,385.52s / 84.47s (6.10% CPU-to-wall) |
| Command count | 8, all exit 0 |
| Assertion total | 1,463 internal `ok -` checks, zero `not ok` |
| Directional delta vs. original 20-sample hosted mean | −604.88s (−30.39%) |
| Top mover | engine 1,143.22s (82.51% of serial wall) |
| Source revision captured | `e71d1a2ad7c3df3b0cb140b36f41dac1dc52d25e` |

Full detail: `PASS-9.md`, `PASS-9-current-profile.json`.

## Pass 8 — rejection (carried forward)

ZERO-CHANGE. Scoring ledger: current partial PATH-wrapper diff scored 0.6, the narrower
process-observation replacement scored 1.6 — both below the 2.0 implementation threshold. Raw
fixed-delay ceiling was 16s; a behavior-preserving no-flock barrier caps the safe ceiling at ~15s;
delivered savings were 0s. `tests/engine.test.sh` was restored byte-identical to `HEAD`. Full
detail: `PASS-8.md`.

## Pass 10 — exact final local golden (this pass's capture)

Foreground, serial, single-tool-call execution from a fresh `/tmp/pro-gate-pass10.*` scratch
directory. One clean rerun was permitted only for the documented stale-throttle `--harvest` flake
(pass 3's precedent); it was **not needed** this run — every step passed on its first attempt.

| Step | Command | Exit | Wall (s) | Terminal marker | Assertions |
| ---: | --- | ---: | ---: | --- | ---: |
| 0 | Validate data and shell files (`jq`/`yq`/`shellcheck --severity=error`, exact CI block) | 0 | 21.91 | VALIDATION PASS | n/a |
| 1 | `bash tests/engine.test.sh` | 0 | 1131.50 | ALL PASS | 825 ok, 0 not-ok |
| 2 | `bash tests/daemon-reload.test.sh` | 0 | 13.58 | ALL PASS | 74 ok, 0 not-ok |
| 3 | `bash tests/autoupdate.test.sh` | 0 | 5.69 | ALL PASS | 35 ok, 0 not-ok |
| 4 | `bash tests/browser-launch.test.sh` | 0 | 11.06 | ALL PASS | 17 ok, 0 not-ok |
| 5 | `node --test tests/cdp-salvage.test.mjs` | 0 | 151.78 | node:test tests=1 pass=1 fail=0 | 298 ok, 0 not-ok |
| 6 | `bash tests/distribution.test.sh` | 0 | 57.88 | ALL PASS | 133 ok, 0 not-ok |
| 7 | `bash tests/release-train.test.sh` | 0 | 0.55 | ALL PASS | 58 ok, 0 not-ok |
| 8 | `bash tests/release-assets.test.sh` | 0 | 0.14 | ALL PASS | 23 ok, 0 not-ok |

- Every step exit status: **0**.
- Every shell suite terminal marker: **ALL PASS** (6 of 6 shell suites).
- Node suite: **1 pass / 0 fail** (`node:test` summary), 298 internal `ok -` assertions, 0 `not ok`.
- Attempts per step: **1** (no rerun consumed).
- Total wall (validation + all 8 test commands): **1,394.09 seconds**.
- Shell-suite stdout SHA-256 for `01-engine`, `02-daemon-reload`, `03-autoupdate`,
  `04-browser-launch`, `06-distribution`, `07-release-train`, and `08-release-assets` are
  byte-identical to pass 9's captured stdout SHA-256 (`PASS-9-current-profile.json`), because
  these suites emit no embedded timestamps in stdout — this is corroborating determinism
  evidence, not a new golden claim. `05-cdp-salvage` stdout differs only because Node's spec
  reporter embeds a non-deterministic `duration_ms` line; its assertion count (298) and
  `tests=1/pass=1/fail=0` summary are identical.
- `engine-all-pass.txt` (pass 1's golden artifact, 789-assertion pre-pass-2/3/4 baseline) still
  passes its own `sha256sum -c` self-integrity check (`golden_checksums.txt`); it is intentionally
  a fixed pass-1 snapshot and is not expected to byte-match later passes' higher assertion counts
  (825 by pass 3 onward). This was already the documented behavior in passes 3, 4, and 9.

Full capture manifest: `PASS-10-VERIFICATION.txt`. Raw stdout/stderr/time files remain in the
ephemeral `/tmp/pro-gate-pass10.hRASi2/` scratch directory (ephemeral by design; not a repository
artifact).

## Review finding count

Zero. The prior adversarial diff review of the full passes 1–9 diff (`bin/cdp-poll-ms.mjs` folded
into `bin/cdp-test-timing.mjs`, `bin/cdp-salvage.mjs`, `lib/pro-gate-lib.sh`, `bin/oracle-review.sh`,
`tests/engine.test.sh`, `tests/cdp-salvage.test.mjs`) found **zero correctness findings** and
verified all production defaults (120s timeout grace, 30s pre-retry probe, 10s watchdog cadence,
30s/5s/2s TERM-drain/force-settle plus `--kill-after=30`, 20,000ms CDP main poll, 2,500ms scratch
sample interval) remain unchanged outside their narrowly-scoped, strictly-parsed, fixture-only test
overrides. Pass 10 does not re-run that review per instruction.

## Hosted PR acceptance plan

- Tracking: issue #114, draft PR #115 (`worktree-ci-wait-optimization-114` → `main`), currently
  `OPEN`/`isDraft=true`/`mergeable=UNKNOWN`.
- The trusted `check` job (`ubuntu-24.04`, `timeout-minutes: 45`) has not yet produced a hosted
  sample against this branch's final state. The acceptance plan is: mark the PR ready, let the
  hosted `check` job run to completion once, and record its wall time as one additional directional
  data point next to the existing 20-sample original hosted baseline (mean 1,990.400s, p50 2,007.0s,
  p95 2,032.0s, from `PASS-9-current-profile.json`).
- **One hosted run is not p95.** A single post-change hosted run only confirms the suite still
  passes inside the 45-minute budget on real GitHub infrastructure; it cannot itself establish a new
  steady-state p95. Treat any single hosted number as directional, exactly as pass 9 treated its one
  local serial capture against the original hosted baseline. If a hosted percentile claim is ever
  needed, it requires multiple hosted samples collected the same way the original 20-sample baseline
  was, not a single confirmation run.
- No merge, push, stash, or commit was performed by this pass. The next human/agent action is to
  mark PR #115 ready for review once the hosted `check` run is triggered and green.

---

## Post-rebase terminal golden — current rebased checkpoint

**Verdict: PASS.** The historical capture above remains checkpoint evidence. This clearly separated
post-rebase capture verifies the exact current branch at `84981c7`, which descends from required
base `ef99b8f` (`git merge-base ef99b8f HEAD` returned that base and
`git merge-base --is-ancestor ef99b8f HEAD` exited 0).

The current `.github/workflows/ci.yml` has **nine** `Run tests` commands, rather than the historical
eight: it now includes `bash tests/resolve-identity.test.sh` between autoupdate and browser launch.
The foreground driver ran its exact validation block and all nine current commands serially. All ten
process steps exited 0 in **1,791.12s** (29m 51.12s), inside the job's 45-minute limit; every step
had one attempt and the permitted stale-throttle `--harvest` rerun was unused.

- Seven conventional shell suites ended `ALL PASS`; the eighth, `resolve-identity`, intentionally
  ended `resolve-identity: all checks pass`. All eight shell suites had zero `not ok` records.
- Node: `tests=1`, `pass=1`, `fail=0`, with 298 internal `ok -` assertions and zero `not ok`.
- Aggregate across nine tests: **1,488** `ok -`, zero `not ok`.
- Full compact manifest, individual wall times, assertion counts, stdout SHA-256 values, and the
  manifest-recognizer correction record: `PASS-10-POST-REBASE.txt`.

### Current rebased pass table and historical-to-current map

| Pass | Historical pre-rebase commit | Current rebased commit |
| ---: | --- | --- |
| 1 | `8ee53de` | `45e2384` |
| 2 | `eb11e66` | `aaf2293` |
| 3 | `201fd69` | `d6efb96` |
| 4 | `438ed7f` | `31da6b7` |
| 5 | `327da27` | `926c66e` |
| 6 | `6f5d1cd` | `d97a798` |
| 7 | `31c8262` | `9afe24b` |
| 8 | `e71d1a2` | `66c91e5` |
| 9 | `8a695fd` | `d0f0a86` |
| 10 | verification-only historical checkpoint | `84981c7` checkpoint |

All current mappings are based on `ef99b8f` (v0.37.2). The terminal verification introduced no
source, test-code, or workflow edit: both staged and unstaged comparisons for `bin`, `lib`,
`.github`, and `tests` excluding `tests/artifacts` exit 0. This does not claim the branch has no
intentional pass changes relative to `ef99b8f`; it proves the rebase/golden closeout added only its
requested artifacts.

---

## Review-fix closeout

**Verdict: PASS.** Final review resolves the high-severity timing mode boundary: valid timing
values are honored only with exact `PRO_GATE_TEST_MODE=ci-fixture`; the accepted inherited-variable
engine run unsets that mode and keeps production defaults. PR-924's hard-cap P2 is refuted because
`HARD_SECS=125` does not match the approximately 6-second watchdog path. The outage child-ack P2 is
fixed by performing the primary `Runtime.evaluate` DOM poll before stop.

Accepted focused evidence: engine exit 0, 855 `ok -`, `ALL PASS`; Node `tests=1`, `pass=1`,
`fail=0`, 302 `ok -`, duration 159.88833346s. A fresh compact 900,000ms foreground driver also ran
the exact CI validation block and the seven unaffected suites serially: every step exited 0; walls
were validation 24s, daemon-reload 13s, autoupdate 6s, resolve-identity 0s, browser-launch 11s,
distribution 53s, release-train 0s, and release-assets 0s. Detailed evidence:
`PASS-10-REVIEW-FIXES.md`. This supplements, and does not replace, historical measurements above.
