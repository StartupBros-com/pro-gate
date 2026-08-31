# Hypothesis ledger — 2026-08-31-ci-runner

| Hypothesis | Verdict | Evidence |
|---|---|---|
| GitHub runner queueing causes the 34-minute CI time | rejects | Queue p50/p95/max are all 3s or less across 20 runs; `ci-baseline-summary.json`. |
| Pinned tool downloads dominate startup | rejects | `Provision pinned CI tools` p95 is 2s; `ci-baseline-summary.json`. |
| JSON/YAML/shell validation is the main bottleneck | rejects | Validation p95 is 37s versus `Run tests` p95 2032s; `ci-baseline-summary.json`. |
| Engine test timeout orchestration dominates | supports | `engine.test.sh` is 78.15% of mean test wall among retained-log runs; 96.66% of representative wall lies in ≥1s silent intervals. Three 165.6s fixtures compose the 30s pre-retry probe with the 125s hard-cap salvage window. Evidence: `ci-baseline-summary.json`, `hosted-log-gap-analysis.json`, `bin/oracle-review.sh:3139-3147`, `bin/oracle-review.sh:3560-3582`, `bin/oracle-review.sh:3631-3654`. |
| CDP salvage polling/deadline tests are the second bottleneck | supports | The suite is 19.61% of mean test wall among retained-log runs and 98.01% silent in the representative run; seven ≥30s intervals total 215.344s. Evidence: `ci-baseline-summary.json`, `hosted-log-gap-analysis.json`, `bin/cdp-salvage.mjs:132-135`, `bin/cdp-salvage.mjs:1243-1266`, `bin/cdp-salvage.mjs:1468-1470`. |
| CPU or disk throughput is the primary cause of current wall time | rejects as primary | The two dominant scripts account for 97.75% of mean test wall among retained-log runs and their representative silent shares are 96.66% and 98.01%, agreeing with explicit source sleeps/deadlines. Direct hosted CPU/I/O counters are unavailable, so this does not claim CPU and I/O cost are zero. |
| Runner image/region variability invalidates hotspot ranking | rejects for ranking | End-to-end CV is 2.591%; engine CV is 2.351%; salvage CV is 0.775% across the operational cohort. The cohort is still unsuitable for a small A/B claim because it spans hosts and revisions. |
| A local profile can fill the hosted resource-metric gap now | rejects | Local preflight found load 39.70 on 28 logical CPUs, 30.66 GB swap used, active swap-in, and 82–84% disk utilization. Running would violate workload isolation; see `local-preflight-rejected.txt`. |

## Hand-off hypotheses for optimization scoring

These are candidates, not changes made by this profile:

1. Preserve lifecycle semantics while replacing wall-clock-duration fixtures with a controllable clock or timeout shim where the test is asserting state transitions rather than real elapsed time.
2. Parameterize CDP polling/render intervals under a test-only environment contract while retaining at least one real-time integration scenario per deadline class.
3. Separate long watchdog/process-group integration cases from fast deterministic engine contract tests, then decide whether CI can run independent groups concurrently without sharing ports, locks, or fixture homes.

Every candidate must retain the golden result and must be scored by Impact × Confidence / Effort before implementation.
