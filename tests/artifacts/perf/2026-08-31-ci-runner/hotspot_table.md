# Hotspot table — 2026-08-31-ci-runner

| Rank | Location | Metric | Value | Category | Evidence |
|---:|---|---|---:|---|---|
| 1 | `tests/engine.test.sh` | mean / p95 wall | 1560.969s / 1605.500s | Wait / timeout orchestration | `ci-baseline-summary.json` (`test_scripts.engine.test.sh`); `hosted-log-gap-analysis.json` (1551.742s silence, 96.66% of representative wall) |
| 2 | `tests/cdp-salvage.test.mjs` | mean / p95 wall | 391.626s / 403.568s | Wait / polling deadlines | `ci-baseline-summary.json` (`test_scripts.cdp-salvage.test.mjs`); `hosted-log-gap-analysis.json` (395.549s silence, 98.01%) |
| 3 | `Validate data and shell files` | mean / p95 wall | 29.950s / 37.000s | Static analysis / process startup; resource split unmeasured | `ci-baseline-summary.json` (`steps.Validate data and shell files`) |
| 4 | `tests/distribution.test.sh` | mean / p95 wall | 15.235s / 22.001s | Mixed; wait-heavy in representative run | `ci-baseline-summary.json`; `hosted-log-gap-analysis.json` (8.358s silence, 52.25%) |
| 5 | `tests/daemon-reload.test.sh` | mean / p95 wall | 15.000s / 18.855s | Wait / daemon polling | `ci-baseline-summary.json`; `hosted-log-gap-analysis.json` (9.807s silence, 58.02%) |

## Dominant sub-hotspots

1. Three engine fixtures each consume about **165.6s**: failed Oracle-log capture, post-click timeout, and partial commit metadata. Together they consume **496.8s**, about 31% of representative engine wall time. Their path composes a 30s pre-retry CDP probe with a 125s hard-cap salvage window (`5s` test timeout + default `120s` grace) plus orchestration overhead.
2. The nine engine silence intervals ≥30s total **773.599s**; 61 intervals ≥10s total **1402.553s**. This concentration makes timeout orchestration, not small-file CPU work, the attack surface for a later optimization pass.
3. Seven salvage-suite silence intervals ≥30s total **215.344s**. The helper uses a 20s poll interval, deadline-bounded retries, 2.5s render sampling, and multiple 30s scenarios.
4. `engine.test.sh` plus `cdp-salvage.test.mjs` account for **97.75%** of mean `Run tests` wall time among the 18 retained-log runs. Optimizing any lower-ranked step first cannot materially change the 34-minute outcome.

## Evidence limits

The hosted runner did not expose process CPU%, peak RSS/PSS, heap high-water, or per-process I/O. The wait classification is based on two agreeing angles—timestamped silence and explicit source deadlines—not a CPU flamegraph. The local resource run was rejected before execution because the host failed workload-isolation preflight.
