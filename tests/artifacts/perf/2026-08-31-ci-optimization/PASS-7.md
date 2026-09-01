# PASS 7 — classified CDP deadline reductions

## Pre-edit profile and opportunity matrix

This document was started before editing `tests/cdp-salvage.test.mjs`. The current foreground
profile used the actual CI invocation through a line-timestamping wrapper that left the child
stdout/stderr byte stream unchanged:

```text
PG_TIMESTAMP_LOG=/tmp/pro-gate-pass7-20260901-cdp-deadlines/baseline.timeline.tsv \
  /usr/bin/time -f 'real=%e user=%U sys=%S maxrss_kb=%M exit=%x' \
  -o /tmp/pro-gate-pass7-20260901-cdp-deadlines/baseline.time \
  node /tmp/pro-gate-pass7-20260901-cdp-deadlines/timestamped-node-test.mjs \
  node --test tests/cdp-salvage.test.mjs
```

It passed with 274 internal `ok -` assertions, zero `not ok -` lines, zero stderr bytes, and
`real=386.31s`; node:test reported `duration_ms=384601.355587`. This is consistent with the
pass-6 run of record (386.39s) and keeps pass 5/6's seams as the only timing levers.

The current profile's nine candidate gaps total **246.566s** (the timestamp differences in
`baseline.timeline.tsv`), so they remain the dominant wall-time class after pass 6 removed the
scratch hydration/sample waits.

| Semantic sub-batch | Hotspot | Impact | Confidence | Effort | Score |
| --- | --- | ---: | ---: | ---: | ---: |
| Overall pass 7 | Classified CDP deadline class (mission score) | 4 | 3 | 4 | 3.00 |
| A | Stable deadline arrival: owned live and remembered inconclusive | 5 | 4 | 3 | 6.67 |
| B | Decisive remembered foreign/cross-bound evidence followed by deadline semantics | 5 | 4 | 3 | 6.67 |
| C | Open-tab cross-bind plus later CDP outage transition proof | 4 | 4 | 3 | 5.33 |
| D | Owned-incomplete scratch sampling through deadline | 4 | 4 | 3 | 5.33 |
| E | Dead remembered renderer proven foreign | 4 | 4 | 3 | 5.33 |

The mission-level score is 3.00 and every implementation sub-batch exceeds the 2.0 threshold.
The rejected watchdog-ceiling sub-batch is documented below: those ceilings are safety guards,
not on-path waits, and are intentionally left unchanged.

## Pre-edit classified scenario table

`fast poll` means the selected child gets `PRO_GATE_TEST_POLL_MS=50`; `fast render` means it also
gets `PRO_GATE_TEST_RENDER_SAMPLE_MS=50`. Both values are the existing strictly bounded pass-5/6
minimums, passed only through `runSalvage(..., extraEnv)` to that spawned child. The 3-second
minimum leaves a 500ms elapsed lower-bound slack while still allowing many 50ms polls/samples; no
shell deadline is sub-second.

| Scenario (profile gap) | Original timeout / fixture mutation / child watchdog | Required transition ordering | Safe minimum and child seam | Expected exit and retained/added state proof |
| --- | --- | --- | --- | --- |
| Server-side liveness later empty scans (29.632s) | `30s` / none / default `90s` | remembered scratch returns owned-incomplete -> server-side liveness is recorded -> later empty main lists -> deadline | `3s`; fast poll + fast render | `3`; existing `proven server-side` stderr plus elapsed >=2.5s, multiple list calls after the scratch phase |
| Undecided remembered shell (30.038s) | `30s` / none / default `90s` | shell samples remain non-decisive -> no absence is inferred -> deadline | `3s`; fast poll + fast render | `7`; repeated scratch samples and elapsed >=2.5s prove an inconclusive deadline, not an early absence |
| Stale foreign remembered memo (30.041s) | `30s` / none / default `90s` | decisive foreign scratch sample -> memo marked stale but retained -> later empty lists -> deadline | `3s`; fast poll + fast render | `4`; one decisive sample, retained memo, no blacklist/cross-bind mutation, multiple later lists |
| Cross-bound remembered memo (30.043s) | `30s` / none / default `90s` | decisive cross-bound sample -> forget memo -> marker-scoped blacklist + cross-bind sidecar -> later lists -> deadline | `3s`; fast poll + fast render | `4`; existing no-stdout/memo-delete assertions plus explicit blacklist and cross-bind state |
| Open-tab cross-bind (20.034s) | `20s` / none / default `90s` | open tab is classified cross-bound -> blacklist + sidecar -> later lists skip blacklisted tab -> deadline | `3s`; fast poll | `4`; no foreign stdout, source remains open, marker-scoped blacklist and cross-bind state, multiple lists |
| Still-generating under ownership check (11.601s) | `12s` / none / default `90s` | primary owned-incomplete -> canonical scratch repeatedly samples incomplete -> deadline | `3s`; fast poll + fast render | `3`; repeated scratch samples/list calls and elapsed >=2.5s prove live-but-incomplete deadline semantics |
| Conviction sidecar recording (30.039s) | `30s` / none / default `90s` | decisive cross-bound scratch -> forget memo + blacklist -> record sidecar -> deadline | `3s`; fast poll + fast render | `4`; sidecar, deletion, blacklist, no stdout, and deadline/list evidence |
| Later CDP outage after success (35.085s) | `30s` / stop mock after `3,000ms` / default `90s` | successful `/json` list -> mock stop -> failed `/json` list -> retry/backoff -> inconclusive result | `3s`; fast poll; replace blind 3s timer with event-driven stop after observed successful list | `7`; fixture records successful lists before stop and stderr records a later failed list; no fake early-outage path |
| Dead remembered tab proven foreign (30.053s) | `30s` / none / default `90s` | listed renderer is empty -> scratch foreign sample -> remembered memo is stale but remains exempt from blacklist -> later lists -> deadline | `3s`; fast poll + fast render | `4`; scratch source URL, one foreign sample, retained memo/no blacklist/no sidecar, multiple lists |

## Explicit non-change: hang open/list/close safety fixtures

The six hang cases stay at their established `3s` invocation deadline. Scratch-open/list retain
`6,000ms` child watchdogs with `<5,500ms` ceilings; scratch-close retains its `9,000ms` watchdog
and `<7,000ms` ceiling because it additionally needs the independent 2,000ms cleanup grace.
The current profile shows they already return in about 3.0s / 2.1s, respectively, rather than
waiting for their watchdogs. Reducing a watchdog or ceiling would not improve wall time and would
weaken the proof that the child aborts before the kill fallback and that open -> list -> close
cleanup ordering survives an unresponsive close peer. This sub-batch is rejected.

## Planned isomorphism conditions

- Only test fixture deadlines, selected child environment values, fixture observations, and the
  event-driven outage stop are eligible for change.
- Production parser defaults, CDP retry backoff, classifiers, exit branches, CLI behavior,
  source selection, memo/blacklist/cross-bind writes, and scratch open/list/close behavior remain
  untouched.
- Each stable case will assert both elapsed lower bound and multiple real observations before the
  same terminal state.
- Every decisive scratch case will record the first decisive sample before the shortened deadline.
- The outage case will prove both sides of the transition rather than assuming a 3-second timer
  happened after the child started.

## Implementation and proof instrumentation

Only `tests/cdp-salvage.test.mjs` changed. `runFastPollSalvage()` gives selected children the
existing pass-5 `PRO_GATE_TEST_POLL_MS=50` minimum. `runFastCdpDeadlineSalvage()` adds the existing
pass-6 `PRO_GATE_TEST_RENDER_SAMPLE_MS=50` minimum. Neither mutates the parent environment, every
other child, production defaults, the parser, or CLI arguments.

The mock now records deadline-fixture-private successful `/json` events only when the fixture
passes `trackCdpDeadlineEvents: true`: outer versus scratch lists, event order/tab IDs, and the
successful-list count that triggers the later-outage close. It keeps pass 5's pre-existing raw
`jsonListCalls` counter unchanged for its production-versus-fast-poll contrast. Ordered scratch
samples are independently recorded by the relevant fixture's `renderText(_, n)` callback.

The nine classified deadline edits are deliberately separate semantic batches:

1. **A — stable deadline arrival:** server-side liveness and the undecided remembered shell now
   invoke a 3s child with both fast seams. The former proves one owned scratch sample followed by
   at least three later empty outer scans; the latter proves at least five consecutive scratch
   samples before its inconclusive deadline.
2. **B — decisive remembered evidence:** stale foreign memo, cross-bound memo, conviction
   sidecar, and dead remembered renderer now invoke a 3s child with both seams. Each decisive
   case records first scratch sample `1`; the cross-bound cases retain deletion, marker-scoped
   blacklist, sidecar, no-stdout, later-empty-list, and exit-4 proof, while foreign remembered
   cases retain their memo and no blacklist/cross-bind mutation.
3. **C — open-tab and outage transitions:** open-tab cross-bind invokes a 3s fast-poll child and
   proves source-tab preservation, marker-scoped blacklist/cross-bind state, repeated later
   lists, and exit 4. The outage fixture replaces its blind 3,000ms stop timer with a mock stop
   after the first *served successful* outer `/json`; it then requires at least one later
   `CDP list failed` stderr record and exit 7. The production 5s first-failure backoff remains
   untouched, so this case's real minimum is about 5s even with a 3s invocation deadline.
4. **D — owned incomplete:** still-generating invokes a 3s child with both seams and proves at
   least five consecutive owned-incomplete scratch samples, a final outer revalidation, source
   tab/memo preservation, no rejection state, and exit 3 at deadline.
5. **E — static short-scratch stabilization:** four initial post-edit full runs exposed the
   pre-existing 3s canonical-scratch fixtures' 2,500ms sample / 500ms post-sample-slack race.
   Different unmodified fixtures flaked (`probe-state: complete`, terminal remembered A, and
   cross-bound canonical scratch), showing no classified deadline batch was causal. Thirteen
   selected static decisive 3s seeded canonical revalidations now use existing
   `runScratchSalvage()` only. Their timeout literals do not change, they have no required
   first/second sample transition, and their existing terminal/foreign/cross-bound/memo
   assertions remain intact. This is not a global environment override.

## Repeated foreground result

The three acceptance runs were foreground `node --test tests/cdp-salvage.test.mjs`, each run with
a 900,000ms tool timeout. Every run exited 0 with **298/298 internal `ok -` assertions**, no
`FAIL -` lines, `tests=1`, `pass=1`, `fail=0`, and zero stderr bytes.

| Run | `/usr/bin/time` real | node:test duration | User / sys CPU | Max RSS | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 151.18s | 147.146791s | 7.33s / 1.95s | 84,028 KiB | 298/298, pass |
| 2 | 151.38s | 147.467556s | 7.21s / 2.03s | 83,552 KiB | 298/298, pass |
| 3 | 153.69s | 149.643750s | 7.44s / 1.92s | 86,232 KiB | 298/298, pass |

The raw `final-run-{1,2,3}.time` files are authoritative. Wall statistics are: **p50 151.38s,
max 153.69s, mean 152.083333s, population standard deviation 1.139015s, and CV 0.7489%**. The baseline immediately before this pass was 386.31s (and the pass-6 record was
386.39s), so the p50 improvement is **234.93s / 60.81%** against the local pass-7 baseline and
**235.01s / 60.82%** against the pass-6 record.

The source-derived deadline-only budget independently predicts at least `246.566s - 29s =
217.566s` saved: eight 3s cases plus the unmodified first 5s failure backoff in the outage case.
The measured p50 exceeds the 2s retention threshold by more than two orders of magnitude; static
short-scratch stabilization supplies additional measured savings but is not needed to clear it.

## Behavior / isomorphism proof

### Change: selected test-child deadlines and existing bounded timing seams

- **Ordering preserved:** yes. Stable cases assert their sample/list ordering; decisive scratch
  cases record their first decisive sample; the outage asserts successful list before mock close
  and failed list after it. Hung scratch open/list/close fixtures retain their original 3s
  deadlines, 6,000ms/9,000ms child watchdogs, elapsed ceilings, and explicit open -> list ->
  close cleanup checks.
- **Tie-breaking and classification unchanged:** yes. No production branch, classifier, parser,
  retry backoff, exit-code mapping, memo/blacklist/cross-bind implementation, CLI behavior, or
  CDP request ordering changed. The new test assertions retain every previous status/stdout/stderr
  assertion and add state evidence rather than weakening it.
- **Floating point:** N/A. All selected durations are existing canonical integer-millisecond
  overrides; shell deadlines remain integer seconds.
- **RNG seeds:** N/A. No randomness was added or changed.
- **Golden outputs:** `sha256sum -c tests/artifacts/perf/2026-08-31-ci-optimization/golden_checksums.txt`
  passed; `engine-all-pass.txt` remains unchanged.

## Rejected sub-batches

1. **Hung scratch open/list/close watchdog ceilings:** rejected. They already abort before their
   6,000ms/9,000ms watchdogs; lowering guards or elapsed ceilings would weaken the safety proof
   without reducing on-path wall time.
2. **Sub-3s shell deadlines:** rejected. A 3s deadline provides 500ms scheduler slack while the
   50ms seams still produce multiple observations. No repeated evidence supports a sub-second or
   tighter shell deadline.
3. **Global literal/default replacement:** rejected. Each affected invocation names its own helper;
   production 20,000ms main polling, 2,500ms render sampling, retry backoff, 25s render budgets,
   and child watchdog defaults remain untouched.

## Pass-5 conditional resolution and rollback

Pass 5 is retained. Pass 7's independently scored overall opportunity is 3.00 and its
source-derived deadline-only reduction is 217.566s; the measured p50 reduction is 234.93s.
Either proof clears the required >=2s wall-time gain independently of pass 5's preparatory seam.

To roll back after the pass-7 commit, revert that single commit. It changes only the Node test
fixture and these pass-7 artifacts; do not revert pass 5 or pass 6, whose bounded parsers/defaults
remain separately tested.

## Raw evidence

- Baseline: `/tmp/pro-gate-pass7-20260901-cdp-deadlines/baseline.time`,
  `/tmp/pro-gate-pass7-20260901-cdp-deadlines/baseline.tap`,
  `/tmp/pro-gate-pass7-20260901-cdp-deadlines/baseline.stderr`, and
  `/tmp/pro-gate-pass7-20260901-cdp-deadlines/baseline.timeline.tsv`.
- Final acceptance: `/tmp/pro-gate-pass7-20260901-cdp-deadlines/postchange/final-run-{1,2,3}.{time,tap,stderr}`.
- Non-acceptance diagnostics retained for the static-scratch race:
  `/tmp/pro-gate-pass7-20260901-cdp-deadlines/postchange/{run-1,diagnostic-run-2,diagnostic-run-3,diagnostic-run-4}.{time,tap,stderr}`.
- Command/check transcript: `PASS-7-VERIFICATION.txt` in this artifact directory.
