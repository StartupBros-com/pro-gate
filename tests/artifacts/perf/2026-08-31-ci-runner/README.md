# CI runner profiling artifacts

Measurement-only profile for issue #110 and draft PR #111.

## Conclusions

- End-to-end workflow p50/p95: **2048s / 2080s**.
- `Run tests` p50/p95: **2007s / 2032s**.
- `engine.test.sh`: **78.15%** of mean test wall among the 18 retained-log runs.
- `cdp-salvage.test.mjs`: **19.61%** of the same cohort.
- The top two scripts account for **97.75%** of test time and are dominated by explicit wait/deadline behavior.

## Artifact map

- `DEFINE.md` — scenario, metric, budget, golden output, scope.
- `fingerprint.json` — representative hosted runner fingerprint.
- `ci-baseline-samples.json` / `.csv` — raw 20-run service observations.
- `ci-baseline-summary.json` — percentiles, variance, step and script aggregation.
- `representative-run-33443036305-test.log` — raw timestamped hosted test log.
- `hosted-log-gap-analysis.json` — per-script silent-interval attribution.
- `BASELINE.md` — human-readable baseline card and limitations.
- `hotspot_table.md` — ranked hand-off table.
- `hypothesis.md` — supports/rejects ledger and next-phase candidates.
- `scaling_law.md` — why no honest scaling axis was available.
- `local-fingerprint-rejected.json` / `local-preflight-rejected.txt` — evidence for rejecting a contaminated local resource run.
- `collect_baseline.py` / `analyze_test_gaps.py` — reproducibility scripts.

No optimization was implemented.
