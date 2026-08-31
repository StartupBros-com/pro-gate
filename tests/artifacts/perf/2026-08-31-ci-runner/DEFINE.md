# DEFINE — GitHub Actions trusted CI runner

## Scenario

Profile `.github/workflows/ci.yml` → `trusted check` on the GitHub-hosted `ubuntu-24.04` runner. The profiled content revision is `967a4eb00e64b2c75764c17c52ad508982fb9bd4`. The operational baseline uses the 20 most recent successful runs available on 2026-08-31; those samples span 19 head SHAs from 2026-08-27 through 2026-08-31, so they are a service-level baseline rather than a controlled same-revision microbenchmark.

## Metric

- Primary: end-to-end workflow and `Run tests` wall-clock p95.
- Secondary: p50, p99, p99.9, p99.99, max, successful jobs/hour, queue time, per-step wall time, per-test-script wall time, and timestamped output-silence intervals.
- Resource metrics: hosted process CPU%, peak RSS, PSS, heap high-water, and per-process I/O were requested but are unavailable in retained GitHub logs. A local resource run was rejected at preflight rather than measured under invalid conditions.

## Budget

- Operational p95 target: **≤ 35 minutes (2100s)** end to end.
- Safety ceiling: the workflow's existing **45-minute** timeout.
- This is a baseline budget, not an optimization result.

## Golden output

The `trusted check` job concludes `success` after all validation and all eight test commands complete successfully. The representative run is [33443036305](https://github.com/StartupBros-com/pro-gate/actions/runs/33443036305); its log contains the expected seven shell-suite `ALL PASS` markers plus a successful Node TAP completion.

## Scope boundary

Out of scope: optimization changes, kernel/governor/cache tuning, changing CI concurrency, and asserting same-host comparability for ephemeral GitHub-hosted runners. This profile ranks current wall-clock hotspots only.

## Variance envelope

- ≤10% same-host p95 drift: noise.
- >10%: investigate.
- >20%, or 3 consecutive >10%: escalate.
- The 20-run operational cohort has 2.591% CV and 5.533% maximum drift from its median, but it is **not** a same-host or same-revision cohort.

## Stakeholder / requester

Requested as `profiling-software-performance ci runner`; the result is the evidence hand-off for any later CI optimization work.
