# CI runner serial optimization — final summary (10/10)

Historical tracking: issue #114, draft PR #115; shipped by replacement PR #121. Target: `.github/workflows/ci.yml`'s `check` job (`bash
tests/engine.test.sh`, `tests/daemon-reload.test.sh`, `tests/autoupdate.test.sh`,
`tests/browser-launch.test.sh`, `node --test tests/cdp-salvage.test.mjs`,
`tests/distribution.test.sh`, `tests/release-train.test.sh`, `tests/release-assets.test.sh`).
Baseline: `tests/artifacts/perf/2026-08-31-ci-runner/` at merge `83fc083`.

## 10-pass table and commits

| Pass | Mission | Verdict | Commit |
| ---: | --- | --- | --- |
| 1 | Existing hard-cap override | PRODUCTIVE | `8ee53de` |
| 2 | Pre-retry probe seam | PRODUCTIVE | `eb11e66` |
| 3 | Watchdog observation cadence | PRODUCTIVE | `201fd69` |
| 4 | TERM-drain/force-settle waits | PRODUCTIVE | `438ed7f` |
| 5 | CDP main poll seam | PRODUCTIVE-ENABLER, CONDITIONAL | `327da27` |
| 6 | Scratch-render sampling seam | PRODUCTIVE | `6f5d1cd` |
| 7 | Classified CDP deadlines | PRODUCTIVE | `31c8262` |
| 8 | Event-confirmed engine waits | ZERO-CHANGE | `e71d1a2` |
| 9 | Re-profile and re-rank | PRODUCTIVE-MEASUREMENT | `8a695fd` |
| 10 | Golden + hosted convergence gate | CONVERGED | *(measurement/verification only, no commit)* |

Two consecutive non-code-changing passes (8: ZERO-CHANGE, 9: PRODUCTIVE-MEASUREMENT) preceded
pass 10, and pass 10 itself makes no code change — the loop's cap (pass 10) is reached with the
tree already stable and converged, consistent with the documented stop conditions.

## Deterministic code-level budgets (sum across productive passes)

| Pass | Lever | Deterministic reduction |
| ---: | --- | ---: |
| 1 | Timeout-grace hard cap, 3 ambiguity fixtures | 357s (119s × 3) |
| 2 | Pre-retry probe deadline, same 3 fixtures | 87s (29s × 3) |
| 3 | Watchdog observation cadence, 3 kill fixtures | 27s (9s × 3) |
| 4 | TERM-drain/force-settle waits, PR 924 fixture | 31s (35s → 4s worst case) |
| 5 | CDP main poll seam | 0s standalone (enabler for pass 7) |
| 6 | Scratch-render sampling seam | 19.6s (source-derived) |
| 7 | Classified CDP deadlines, 9 scenarios | 217.566s (source-derived); measured p50 −234.93s |
| 8 | Event-confirmed engine waits | 0s (rejected below score 2.0) |
| **Total** | | **739.166s** |

This is a sum of code-level deadline/sleep budget reductions, not an hosted-runner-equivalent A/B
claim — pass 9's directional local capture (below) is the closest available corroboration.

## Pass 9 — measured current profile (most recent full local capture before this pass)

- Serial wall / CPU: **1,385.52s / 84.47s** (6.10% CPU-to-wall), all 8 commands exit 0.
- 1,463 internal `ok -` assertions, zero `not ok`.
- Directional delta vs. the original 20-sample hosted baseline (mean 1,990.400s, p50 2,007.0s,
  p95 2,032.0s): **−604.88s (−30.39%)**, GitHub-hosted-vs-local-WSL2, so directional only.
- Top mover: `engine` at 1,143.22s (82.51% of serial wall); `cdp-salvage` second at 151.09s
  (10.90%).

## Pass 8 — rejection

ZERO-CHANGE. Both candidate designs for event-confirming the remaining engine fixture waits
(a generic PATH-interposition wrapper, score 0.6; a narrower process-observation replacement,
score 1.6) fell below the 2.0 implementation threshold. Raw fixed-delay ceiling was 16s;
behavior-preserving ceiling ~15s; delivered 0s. `tests/engine.test.sh` was restored
byte-identical to `HEAD` before this pass ended.

## Pass 10 — exact final local golden

One clean, uninterrupted, foreground, serial run of the exact CI validation block plus all eight
exact CI test commands, all exit 0, all six shell suites terminal `ALL PASS`, Node suite
**1 pass / 0 fail** (298 assertions, 0 `not ok`). Total wall (validation + 8 tests):
**1,394.09 seconds**. No rerun was needed (the one-allowed stale-throttle `--harvest` rerun
was not triggered). Full detail: `PASS-10.md`, `PASS-10-VERIFICATION.txt`.

## Review finding count

**Zero.** The prior adversarial diff review of the full passes 1–9 diff found zero correctness
findings and verified every production default (120s timeout grace, 30s pre-retry probe, 10s
watchdog cadence, 30s/5s/2s TERM-drain/force-settle with `--kill-after=30`, 20,000ms CDP main
poll, 2,500ms scratch sample interval) is unchanged outside its narrowly-scoped, strictly-parsed,
fixture-only test overrides. Pass 10 did not re-run that review and did not re-implement anything,
per its scope.

## Historical hosted PR acceptance plan (completed by PR #121)

- At the time of this pass, PR #115 (draft, tracking issue #114) targeted `main` from
  `worktree-ci-wait-optimization-114` and was `OPEN`/`isDraft=true`/`mergeable=UNKNOWN` in the
  read-only `gh pr view` capture. It was later superseded by merged PR #121; see Shipped closeout.
- Plan: mark the PR ready for review, let the hosted `check` job (`ubuntu-24.04`,
  `timeout-minutes: 45`) run once against this final tree, and record its wall time as one more
  directional data point beside the existing 20-sample original hosted baseline
  (mean 1,990.400s / p50 2,007.0s / p95 2,032.0s).
- **One hosted run is not p95.** A single hosted pass after these changes only confirms the suite
  still completes inside the 45-minute budget on real GitHub infrastructure — it does not, by
  itself, establish a new steady-state hosted p95. A percentile claim needs multiple hosted
  samples collected the same way the original baseline was; until then, only the pass-9 local
  directional delta and this pass's exact-final local golden are load-bearing evidence.
- No merge, push, stash, or commit was performed by this pass.

## Artifacts in this directory

`PASS-1.md` … `PASS-9.md` plus their `*-VERIFICATION.txt` companions, `PASS-9-current-profile.json`,
`PASS-9-checksums.txt`, `golden_checksums.txt`, `engine-all-pass.txt`, `VERIFICATION.txt`
(pass 1's), and this pass's `PASS-10.md`, `PASS-10-VERIFICATION.txt`, `FINAL-SUMMARY.md`, and
`PASS-10-checksums.txt`.

---

## Post-rebase terminal golden — `ef99b8f` base / `84981c7` checkpoint

The preceding final summary and measurements are retained as historical pre-rebase checkpoint
evidence. The terminal post-rebase verification proves `HEAD` `84981c7` descends from required
origin/main base `ef99b8f`: `git merge-base ef99b8f HEAD` resolved to `ef99b8f`, and the
`--is-ancestor` check exited 0.

The exact current CI workflow adds `bash tests/resolve-identity.test.sh`, so its current test block
has **nine**, not the historical eight, commands. One compact foreground driver ran the exact CI
validation block and all nine commands serially under the requested 3,600,000ms timeout. Results:

- **10/10** process steps (validation plus nine tests) exited 0; total serial wall:
  **1,791.12s** (29m 51.12s), below the CI job's 45-minute timeout.
- Seven conventional shell suites printed `ALL PASS`; the current resolver uses its documented
  terminal `resolve-identity: all checks pass`. All eight shell suites exited 0 with zero `not ok`.
- Node `cdp-salvage`: **1 pass / 0 fail**, 298 `ok -`, zero `not ok`.
- Aggregate: **1,488** internal `ok -`, zero `not ok`; every command had one actual attempt and
  the permitted stale-throttle `--harvest` rerun was not used.
- `PASS-10-POST-REBASE.txt` contains the manifest, per-step walls/assertions, stdout checksums,
  driver-continuation accounting, and post-write validation evidence.

### Rebased current pass table

| Pass | Historical commit | Rebased current commit |
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

Every current row is based on `ef99b8f` (v0.37.2). The post-rebase closeout adds only the requested
artifacts: staged and unstaged diffs for `bin`, `lib`, `.github`, and `tests` excluding
`tests/artifacts` are required to be empty. This does not erase the intentional branch delta from
`ef99b8f`; it proves no source/test/workflow diff was introduced by the terminal golden itself.

The post-rebase checksum manifest now covers `PASS-10.md`, `PASS-10-VERIFICATION.txt`,
`FINAL-SUMMARY.md`, and `PASS-10-POST-REBASE.txt`, while excluding itself.

---

## Review-fix closeout

The historical measurements above remain unchanged. Final review fixes the high-severity timing
mode boundary: valid test timing values require exact `PRO_GATE_TEST_MODE=ci-fixture`, and accepted
engine evidence with that mode unset proves production defaults prevail. PR-924 hard-cap P2 is
refuted (`HARD_SECS=125` versus an approximately 6-second watchdog path). Outage child-ack P2 is
fixed by a primary `Runtime.evaluate` DOM poll before stop.

Focused evidence: engine exit 0, 855 `ok -`, `ALL PASS`; Node tests=1, pass=1, fail=0, 302 `ok -`,
159.88833346s. Fresh unaffected validation and seven-suite results are all exit 0 in serial walls of
24s (validation), 13s, 6s, 0s, 11s, 53s, 0s, and 0s. `PASS-10-REVIEW-FIXES.md` preserves the detailed
closeout record. The regenerated manifest covers the four historical final artifacts plus that
review-fixes record, excluding itself.

---

## Shipped closeout

The hosted acceptance plan above is complete. Historical draft PR #115 closed unmerged after the
required rebase; replacement PR #121 carried exact final head `dc6b78a`, passed the required
`trusted check`, and squash-merged on 2026-09-01. Issue #114 closed with that merge. The hosted run
confirms the final tree on GitHub infrastructure but remains one observation, not a replacement p95
for the original 20-sample baseline.
