# Scaling law — 2026-08-31-ci-runner

## Verdict

No defensible 1/10/50/100/500/1000 scaling axis exists for this CI scenario. The workload is a fixed correctness suite, and the profile did not alter test counts, timeout values, concurrency, or fixture semantics merely to manufacture a scaling curve.

## What was measured instead

- 20 successful end-to-end operational observations.
- 18 runs with retained per-script boundaries.
- One representative hosted run with timestamp-level output-gap attribution.

## Constraint for the next phase

Before claiming a scaling law, an optimization experiment must define one real independent variable—such as number of deadline fixtures, number of CDP scenarios, or safe shard count—and hold revision, runner class, golden output, and timeout semantics constant. Until then, any extrapolation is speculative.
