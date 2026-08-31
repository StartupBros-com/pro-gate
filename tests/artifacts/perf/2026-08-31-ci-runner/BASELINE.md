# Baseline — trusted CI runner — 2026-08-31 — 967a4eb

## End-to-end operational baseline

| Metric | Value | Notes |
|---|---:|---|
| p50 | 2048s (34m08s) | nearest-rank |
| p95 | 2080s (34m40s) | under the 2100s baseline budget |
| p99 | 2109s (35m09s) | conservative; 20 samples |
| p99.9 | 2109s (35m09s) | conservative; 20 samples |
| p99.99 | 2109s (35m09s) | conservative; 20 samples |
| max | 2109s (35m09s) | |
| mean | 2030.5s (33m50.5s) | |
| population CV | 2.591% | multi-host, multi-revision operational cohort |
| max drift from median | 5.533% | within the nominal 10% envelope, but not same-host |
| samples | 20 | 19 SHAs; 18 retained detailed logs |
| throughput | 1.772962 successful jobs/hour | derived from mean workflow wall time |
| queue p95 | 3s | not a material contributor |
| peak RSS | unavailable | hosted logs expose no process RSS; local run rejected |
| heap high-water | not applicable / unavailable | shell and Node correctness suites |
| process CPU avg | unavailable | no hosted telemetry; do not infer a percentage from log silence |
| per-process I/O | unavailable | no hosted telemetry; local preflight rejected |
| golden result | 20/20 PASS | every sampled trusted job concluded success |

## `Run tests` baseline

| Metric | Value |
|---|---:|
| p50 | 2007s (33m27s) |
| p95 | 2032s (33m52s) |
| p99 / max | 2057s (34m17s) |
| mean | 1990.4s (33m10.4s) |
| population CV | 2.270% |

## Mean test-script attribution

| Rank | Command | Mean | p95 | Share of mean `Run tests` |
|---:|---|---:|---:|---:|
| 1 | `bash tests/engine.test.sh` | 1560.969s | 1605.500s | 78.15% |
| 2 | `node --test tests/cdp-salvage.test.mjs` | 391.626s | 403.568s | 19.61% |
| 3 | `bash tests/distribution.test.sh` | 15.235s | 22.001s | 0.77% |
| 4 | `bash tests/daemon-reload.test.sh` | 15.000s | 18.855s | 0.75% |
| 5 | `bash tests/browser-launch.test.sh` | 10.950s | 12.131s | 0.55% |
| 6 | `bash tests/autoupdate.test.sh` | 3.063s | 3.385s | 0.15% |
| 7 | `bash tests/release-train.test.sh` | 0.981s | 1.508s | 0.05% |
| 8 | `bash tests/release-assets.test.sh` | 0.240s | 0.270s | 0.01% |

The top two scripts account for **97.75%** of mean test wall time among the 18 retained-log runs.

## Hosted wait signal

The representative hosted run attributes 1551.742s of `engine.test.sh`'s 1605.408s wall time (96.66%) and 395.549s of `cdp-salvage.test.mjs`'s 403.568s wall time (98.01%) to output-silence intervals of at least one second. Silence alone is not proof of sleep; `hosted-log-gap-analysis.json` is triangulated with explicit deadlines, sleeps, poll intervals, and timeout grace in the source in `hypothesis.md`.

## Run commands

```bash
python tests/artifacts/perf/2026-08-31-ci-runner/collect_baseline.py
python tests/artifacts/perf/2026-08-31-ci-runner/analyze_test_gaps.py
```

## Comparability limits

GitHub-hosted runners are ephemeral. The cohort spans 19 SHAs, two runner image versions, multiple Azure regions, and two runner versions. Use these numbers to rank service-level wall-clock cost, not to accept or reject a small optimization. A later A/B optimization must run the same revision/workload on the same host class with at least 20 observations per side.

## Rejected local resource run

The local WSL2 host failed preflight: load average 39.70 on 28 logical CPUs, 30.66 GB swap used, sustained swap-in, and sampled `/dev/sdd` utilization of 82–84%. No local CPU/RSS/I/O profile was run. Evidence: `local-fingerprint-rejected.json` and `local-preflight-rejected.txt`.
