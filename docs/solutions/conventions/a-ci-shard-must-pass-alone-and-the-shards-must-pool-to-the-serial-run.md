---
title: "A CI shard must pass alone, and the shards must pool to the serial run's results"
module: "pro-gate"
date: "2026-10-03"
category: "conventions"
problem_type: "design_pattern"
component: "development_workflow"
severity: "high"
applies_when:
  - "a serial CI test job is dominated by one long suite and trimming individual waits no longer buys enough headroom under the job's timeout"
  - "splitting a bash test suite whose early sections build fixtures, fakes or home-directory state into regions that CI runs as separate jobs"
  - "validating a shard, leg or selector value read from the environment before a suite runs"
  - "replacing one required CI job with parallel jobs while branch protection and auto-merge still wait on the old job's status name"
  - "proving that a split, sharded or rebalanced test run still executes exactly the checks the serial run did"
symptoms:
  - "trimming idle waits took the serial job from about 44 to about 33 minutes, still close to its 45-minute cap"
  - "the third engine shard run alone failed 21 checks because fixtures it read were built by tests in an earlier region"
  - "a shard printed No such file or directory for a missing fixture directory and still passed every check"
  - "an invalid shard value such as . passed a regex grep guard, selected no region and exited 1 instead of 2"
  - "a refusing shard ended the whole ci-assurance harness with exit 143 from the suite's own EXIT trap"
tags:
  - "pro-gate"
  - "ci"
  - "test-sharding"
  - "parallel-ci"
  - "ci-wall-clock"
  - "ci-assurance"
  - "bash-testing"
  - "coverage-equivalence"
---

# A CI shard must pass alone, and the shards must pool to the serial run's results

## Context

pro-gate's required `trusted check` ran all 17 test suites one after another in one job capped at 45 minutes. The baseline run for PR #253 (CI run 37149310962) took 36m19s. Its `Run tests` step took 2112s, of which `tests/engine.test.sh` took 1551s and `tests/cdp-salvage.test.mjs` 370s. Most of that time was waiting, not computing: this work's reading of an earlier run's log found about 80 engine tests that each sat idle for 5s or more.

Trimming waits had already run out of road. The fix for issue #233 (2026-09-27) stopped a watchdog sleeping out its full poll after Oracle exited, which took the job from about 44 minutes to about 33 to 34 (session history). New fixtures kept adding seconds against the same cap.

Issue #254 cut the check to 6m24s in two PRs:

- **#255** split the suites into three parallel legs (`engine`, `cdp-salvage`, `rest`) behind one aggregating job that keeps the required name. It also gave eleven engine tests the existing test overrides for production timers they do not test, which took those tests from 541s in the baseline CI run to 33s locally. CI took 16m16s, and the engine leg alone took 16m08s of it.
- **#256** sharded the engine suite into three regions that CI runs as `engine-1`, `engine-2` and `engine-3`. CI run 37164991363 took 6m24s: the engine legs 5m34s to 5m45s, `cdp-salvage` 6m15s, `rest` 3m17s.

The speed-up is arithmetic. The work was making the split safe. The first lone run of shard 3 failed 21 checks. Shard 2 passed every check while missing a fixture directory. The guard meant to refuse bad shard values accepted `.`. Each of those would have left CI green.

## Guidance

### 1. Split independent suites first, behind an aggregator that keeps the required name

Branch protection and auto-merge wait on a status name. Keep that name on a small job that depends on every leg and fails unless all of them passed (`.github/workflows/ci.yml:88-101`):

```yaml
check:
  name: trusted check
  needs: tests
  if: always() && (<the legs' own if: condition, repeated exactly>)
  steps:
    - name: Require every test leg to pass
      env:
        LEGS_RESULT: ${{ needs.tests.result }}
      run: test "$LEGS_RESULT" = success
```

A matrix job's `needs.tests.result` is `success` only when every leg succeeded. `always()` makes the aggregator run and fail when a leg failed, timed out or was cancelled, instead of being skipped. Repeating the legs' fork guard after `always()` makes it skip exactly where the legs skip. Renaming the required job instead would leave branch protection and auto-merge waiting on a check that never reports.

### 2. Shard only the critical path, and only down to the next-longest leg

After #255 only the engine leg mattered. In #255's first CI run (37153872851) its test step took 1034s, against 6m17s for `cdp-salvage` in the same run. Three shards of about 345s each put every engine leg under `cdp-salvage`. A fourth shard would gain nothing, because `cdp-salvage` now sets the wall-clock.

The cut points came from this work's cumulative per-section timing of that CI log, read at existing section headers: about 347s and 707s into the leg. Each region is an unindented `if in_shard k; then … fi` block (`tests/engine.test.sh:1228`, `:2625`, `:5276`), so wrapping them re-indented no test line.

Do not balance from local timings. The same regions ran 402s, 432s and 353s locally with four suites running at once, and 5m24s to 5m50s across #256's two CI runs.

### 3. Every shard must pass alone: hoist what later regions read

CI runs each region in a fresh process with only the shared prelude, so a region may rely on the prelude and its own setup, never on state an earlier region left behind (`tests/engine.test.sh:16-20`). A serial suite breaks that rule quietly: a fixture is built by the first test that needs it and read hundreds of lines later.

Find these by running every shard alone, not the whole suite. Shard 3 alone failed 21 checks:

- `prov-ours.md` and the `oracle-commit-timeout` fake were built in region 2 and read in region 3. They moved into one block before the regions (`tests/engine.test.sh:1092`), with the other fixtures later regions read.
- One region-3 check asserted a ledger row that a region-2 run wrote. It moved into region 2, directly after that run.
- Region 2 starts its own browser mock, so it sees the same state whether or not region 1 ran.

Exit status alone is not enough to call a shard clean. Run as shard 2 alone, the v0.28 provenance test wrote its reservation into `home/in-progress` before creating that directory. The write failed, the harvest ran with no reservation, and every check still passed. Only a stderr scan caught it, and a `mkdir -p` now comes first. Scan each lone shard's stderr for `No such file`, `unbound variable`, `command not found` and `FATAL`. Then compare its stderr with the serial run's, after normalizing temp paths, line numbers and epoch timestamps.

To find dependencies at a candidate cut, this work snapshotted variables, functions and files at each cut point. `declare -p` prints the value of every exported variable, credentials included, so snapshot names only (`compgen -v`, `declare -F`) and keep the snapshots out of logs and transcripts.

### 4. Match the selector literally, and refuse a run where no check ran

```bash
PG_TEST_SHARDS=3
if [ -n "${PG_TEST_SHARD:-}" ] && ! seq 1 "$PG_TEST_SHARDS" | grep -qxF -- "$PG_TEST_SHARD"; then
  echo "FATAL - PG_TEST_SHARD must be empty or 1-$PG_TEST_SHARDS, got '$PG_TEST_SHARD'" >&2
  exit 2
fi
in_shard() { [ -z "${PG_TEST_SHARD:-}" ] || [ "$PG_TEST_SHARD" = "$1" ]; }
```

(`tests/engine.test.sh:21-26`.) The first version used `grep -qx`, a regex match. `.`, `[1-3]` and `1\|9` passed validation, selected no region and ended with exit 1 instead of the documented 2. `-F` makes the match literal; `4`, `0`, `01`, `.`, `[1-3]`, `1\|9` and ` 1` now each exit 2.

Separately, the suite exits 1 when no check ran (`tests/engine.test.sh:10441`), so a selector that matches nothing can never print ALL PASS.

### 5. Pin the split with checks that each reject a planted failure

`tests/ci-assurance.test.sh` checks both the workflow and the suite. Each check rejects a deliberately broken copy:

- **Coverage** (`:15-45`). Every `tests/*.test.sh` and `tests/*.test.mjs` file runs in exactly one leg. A file that declares `PG_TEST_SHARDS=N` runs once per shard, as `PG_TEST_SHARD=1..N`. Planted copies with a dropped suite, a doubled suite, a dropped shard and a doubled shard are each rejected.
- **Selection** (`:47-70`). Regions are numbered 1..N in file order. For every shard/region pair, `in_shard` selects only its own region, and it selects every region when unsharded. Shard N+1 and `.` must refuse with the range message.
- **Routing** (`:72-87`). Source validation and the release-notes gate run only in the single `rest` leg. A renamed leg or a misrouted step condition would skip them on every leg while the aggregator stayed green, so both are planted and rejected.
- **Aggregation** (`:94-103`). The aggregator keeps its name, needs the legs, runs under `always()` and fails unless they succeeded.

The pair check exists because an `in_shard` that returned true everywhere would keep full coverage while silently undoing the split. Code review on #256 found that nothing checked for it.

### 6. Prove equivalence on result lines, not on exit codes or counts

Equal pass counts do not prove the same checks ran. Collect every `ok - ` and `FAIL - ` line (printed by `check()`, `tests/engine.test.sh:30-33`) from the serial run and from the pooled shards. Compare them as multisets: ignore order, because regions run separately, but keep duplicates.

For #256 the three shards gave 318 + 538 + 638 = 1494 result lines. That matched each of these, with none missing, none extra and none failing:

- the unsharded run on the same tree;
- the unsharded suite at `origin/main`;
- the engine leg of the baseline CI run.

The pooled CI legs of the PR's own run matched too. Fetch per-job logs with `gh run view <run> --log --job <id>`.

Cut a baseline taken from a combined log exactly at the suite's own `ALL PASS` line. During this work an inclusive end boundary pulled 11 lines of the next suite into the baseline.

### 7. Check what the EXIT trap kills when the helper never started

`kill "${MOCK_PID:-0}"` in an EXIT trap becomes `kill 0` when the run exits before starting its helper, and `kill 0` signals the whole process group. A shard that refused early killed the `ci-assurance` harness that launched it (exit 143), which was first misread as memory pressure. Kill only a helper the run started: `[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID"` (`tests/engine.test.sh:39`).

### 8. Expect concurrent shard runs to expose load-sensitive tests

Running three shards and the serial suite at once on one machine made two tests that the split never touched fail once each:

- **#234's test.** A background holder took a lock with `flock -n` and exited when it landed inside a readiness probe's momentary hold. It now waits with `flock -w 10`, and the test first checks that the slot is held.
- **#189's test.** It gave `pg_lock` a 1s budget, which a whole-second clock could spend before the first sleep. The budget is now 2s against the same 2s grace.

Fix such tests where they stand; they were flaky before the split.

## Why This Matters

The `trusted check` gates merges and releases. A split that drops a suite, doubles one, or runs a shard that passes for the wrong reason makes CI faster and weaker at the same time, and a green run looks the same either way. Every failure above was silent at the level CI reports. A missing fixture still printed ALL PASS. A bad selector failed for the wrong reason. An `in_shard` that selected everything would have kept every check green while undoing the speed-up.

## When to Apply

- Before splitting or rebalancing any CI test job, including adding a fourth engine shard or splitting `cdp-salvage`.
- When adding a test to `tests/engine.test.sh`. Build what it reads in its own region or in the shared fixture block, and run its shard alone.
- When adding a suite to `ci.yml`. It must go in exactly one leg (`rest` unless there is a reason otherwise), or `ci-assurance` fails.

Known limits that still hold:

- A negative assertion that passes because a fixture is missing still passes. The coverage and selection checks catch only a missing positive fixture.
- A `check` placed outside every region runs once per shard: tripled, not dropped. None exists today.
- `cdp-salvage` (about 6 minutes) is now the critical path, so more engine shards gain nothing until it changes.

## Examples

Run one shard alone and look for the missing-state noise that exit status hides:

```bash
PG_TEST_SHARD=3 bash tests/engine.test.sh > shard3.out 2> shard3.err; echo "rc=$?"
grep -E 'No such file|unbound variable|command not found|FATAL' shard3.err
```

Compare the pooled shards with the serial run as multisets. Sorting keeps duplicates, so `diff` on the sorted lists is a multiset comparison:

```bash
for k in 1 2 3; do PG_TEST_SHARD="$k" bash tests/engine.test.sh; done | grep -E '^(ok|FAIL) - ' | sort > pooled.txt
bash tests/engine.test.sh | grep -E '^(ok|FAIL) - ' | sort > serial.txt
diff pooled.txt serial.txt && echo EQUAL
```

Check the selector refusals directly. Each should exit 2 with the range message:

```bash
for v in 4 0 01 . '[1-3]'; do PG_TEST_SHARD="$v" bash tests/engine.test.sh > /dev/null 2>&1; echo "$v rc=$?"; done
```

## Related

- Issue #254, PRs #255 and #256: the work this records. Issue #233: the earlier watchdog fix.
- `docs/solutions/conventions/a-staged-release-tag-can-predate-a-later-fix-on-the-same-version.md`: the release gate that replaced the release-time rerun of these suites. It requires the tagged commit's push CI run and its `trusted check` job to have passed.
- Issue #249 (open): the `trusted check` runs the PR's own validators.
