# CI wait optimization — Pass 5: CDP main poll seam, test-only override

## Baseline evidence

- Source: this pass's own clean same-host foreground run of the untouched pre-pass-5 code
  (commit `438ed7f`, the tip of prior passes), captured before any edit in this pass — see
  `PASS-5-VERIFICATION.txt` for full command/output detail.
- `bin/cdp-salvage.mjs`'s main wait loop slept a hardcoded `const POLL_MS = 20_000;` between scans
  (single production call site, `await sleep(Math.min(probe ? 5_000 : POLL_MS, Math.max(0,
  deadline - Date.now())));`, inside the `while (Date.now() < deadline)` loop). No test-only way
  existed to shorten that cadence, so any fixture wanting to observe **multiple** main-loop scans
  inside a short test deadline could not do so cheaply: the loop's own sleep is clamped to the
  *remaining* deadline, so a 2-second test deadline yields at most one ~2-second sleep before the
  loop exits, regardless of `POLL_MS`, when there is no way to make individual sleeps shorter than
  the deadline itself.
- Prerequisite opportunity score: Impact 5 × Confidence 4 / Effort 2 = **10** (per mission),
  where impact is the ability to shorten and repeatedly observe the ~247s deadline-bound class in
  pass 7 without collapsing multi-scan behavior. The measured immediate suite-wall impact of this
  seam alone is **neutral** (400.82s before, 404.61s after with 21 added assertions), so retention is
  conditional: if pass 7 does not deliver a separately scored ≥2 wall-time improvement, revert this
  pass rather than keep preparatory machinery that did not itself make CI faster.

## Profiling: why this pass does NOT reduce the existing suite's wall time (and correctly so)

Before writing this artifact, I timestamped every `ok -` line of the pristine baseline run
(`/tmp/pg-pass5-verify` timeline capture, wrapper script that pipes the child's stdout without
touching the test file) to find the dominant cost in the 400.82s baseline. Nine existing test
blocks each show a gap of almost exactly their own `runSalvage(..., timeoutSecs)` argument:

```
[+30041ms] server-side liveness survives later empty scans (exit 3)        (timeoutSecs='30')
[+30023ms] an undecided remembered conversation exits 7, not 4              (timeoutSecs='30')
[+30044ms] a stale memo pointing at another run still exits 4               (timeoutSecs='30')
[+30041ms] cross-bound memo is not accepted as our review                   (timeoutSecs='30')
[+20024ms] an open tab with our marker but another run's answer is refused  (timeoutSecs='20')
[+12022ms] still-generating stays exit 3 under the new check
[+30041ms] a conviction is recorded in crossbound/<marker>                  (timeoutSecs='30')
[+35096ms] a later CDP outage is not masked by an early successful scan     (timeoutSecs='30'+drain)
[+30043ms] a dead remembered tab proven foreign still exits 4               (timeoutSecs='30')
```

These nine gaps alone sum to **~247s of the 400.82s baseline (~62%)**. It is tempting to conclude
the new `POLL_MS` override could shrink them — it cannot, and the mission's own scope boundary
(`Do not change ... timeout arguments`) is precisely why: `cdp-salvage.mjs`'s loop bound is
`const deadline = Date.now() + Number(timeoutSecs) * 1000;` — a **wall-clock** deadline set by the
caller-supplied `timeoutSecs` argument. `POLL_MS` only controls how often the loop re-scans
*within* that already-fixed window; it never changes when the window itself closes. These nine
tests are deliberately proving deadline-arrival behavior (still-generating/inconclusive/miss *at*
the deadline), so they must wait the real deadline out regardless of poll granularity.

This pass's own new comparison test proves the same point directly: a 2-second-deadline scenario
takes essentially identical wall time (~2s) whether polled at `POLL_MS=50` (fast override, ~40
scans) or `POLL_MS=20_000` (production, effectively 1 scan, deadline-clamped) — see `jsonListCalls`
evidence below. The override changes poll **granularity**, never the **deadline**. Retrofitting the
nine slow tests above to use the override would save nothing and was correctly not attempted;
shortening their `timeoutSecs` arguments is the actual lever for that cost and is explicitly out of
this pass's scope (`Do not change ... timeout arguments`).

This pass's value is therefore capability, not suite-wall-time reduction: it lets a **future**
fixture cheaply assert multi-scan behavior (e.g. "rapid re-polling never flips a classification")
inside a short deadline, something structurally impossible to test cheaply before this pass because
each scan attempt used to cost a real 20-second sleep once the deadline exceeded a few seconds.

## Exact single lever

New file `bin/cdp-poll-ms.mjs` (24 lines, sibling to the existing `cdp-organizer-expressions.mjs`
helper-module pattern already used by this binary):

```js
export const TEST_POLL_MS_MIN = 50;
export const TEST_POLL_MS_MAX = 20_000;

const CANONICAL_POSITIVE_DECIMAL_RE = /^[1-9][0-9]*$/;

export function parseTestPollMs(raw) {
  if (typeof raw !== 'string' || !CANONICAL_POSITIVE_DECIMAL_RE.test(raw)) return null;
  const value = Number(raw);
  return value >= TEST_POLL_MS_MIN && value <= TEST_POLL_MS_MAX ? value : null;
}
```

`bin/cdp-salvage.mjs` (line 91 import, line 141 the only changed production statement):

```js
import { parseTestPollMs } from './cdp-poll-ms.mjs';
...
const POLL_MS = parseTestPollMs(process.env.PRO_GATE_TEST_POLL_MS) ?? 20_000;
```

This is the **only** production statement changed. The sole call site (line 1476, inside the main
`while (Date.now() < deadline)` loop at line 1257) is untouched — it still reads `POLL_MS`, just
now a `const` resolved once at module load instead of a bare literal:

```js
await sleep(Math.min(probe ? 5_000 : POLL_MS, Math.max(0, deadline - Date.now())));
```

`parseTestPollMs` is called exactly once, at module top level (line 141) — not inside the loop —
so there is no repeated-parsing cost per iteration.

## Production-default proof

`PRO_GATE_TEST_POLL_MS` appears nowhere in production workflow/config: confirmed by grepping
`bin/`, `lib/`, `install.sh`, `scripts/`, `.github/`, and every `*.json`/`*.env*` file in the repo —
it exists only in `bin/cdp-poll-ms.mjs` (definition + comments), `bin/cdp-salvage.mjs` (the
fallback expression + comments), and `tests/cdp-salvage.test.mjs` (test-only `extraEnv`, never a
global `process.env` mutation). A deployed run therefore always evaluates
`parseTestPollMs(undefined) ?? 20_000` → `20_000`, byte-identical to the pre-pass-5 literal.

I independently re-verified every boundary case directly against the real parser (not just the
values embedded in the suite), via a standalone script importing the actual
`bin/cdp-poll-ms.mjs`:

```
unset            -> null   empty            -> null   "0"              -> null
"-1"             -> null   "-20000"         -> null   "abc"            -> null
"123abc"         -> null   "0100"           -> null   "050" (0+min)    -> null
"100.5"          -> null   " 100 "          -> null   "+100"           -> null
"49" (min-1)     -> null   "50" (min)       -> 50     "20000" (max)    -> 20000
"20001" (max+1)  -> null   "999999"         -> null   100 (non-string) -> null
null             -> null   "NaN"            -> null   "Infinity"       -> null
MIN=50 MAX=20000 MAX===20000: true
```

Every unset/empty/zero/negative/malformed/leading-zero/below-minimum/above-bound input rejected
(→ `null` → production falls back to `20_000`); only a canonical positive decimal in `[50, 20000]`
is honored, and `20000` is the literal production default itself — an accepted override can only
ever shorten the cadence, never extend it.

## Test additions (`tests/cdp-salvage.test.mjs`, purely additive — zero existing lines changed)

`git diff tests/cdp-salvage.test.mjs` shows **zero removed lines** (only the diff header); every
pre-existing assertion, fixture, and its request-count/temporal-ordering evidence is byte-identical
to before this pass. Two additions:

1. **Direct parser boundary coverage** (in-process, no spawn) — 15 `check()` calls exercising every
   case the mission lists (unset, empty, `"0"`, negative, malformed, fractional, whitespace,
   leading-zero, leading-zero-at-minimum, non-string type, below-minimum, above-maximum, plus the
   exact minimum/maximum bounds and that the maximum equals the production `20_000`).
2. **Behavior proof that rapid polling never changes classification** — a new
   `jsonListCalls` counter on the mock CDP server (its own `/json` tab-list hit count, distinct
   from the pre-existing per-tab `pollsByTab` render counter) plus a new test block:
   - A stable still-generating conversation polled at `PRO_GATE_TEST_POLL_MS=50` (the minimum valid
     override) over a 2-second deadline still classifies exit 3, with `jsonListCalls >= 5` (proving
     many real re-scans happened).
   - The identical scenario with **no** override (production `20_000` cadence) also classifies
     exit 3, with `jsonListCalls === 2` deterministically (one main-loop scan, deadline-clamped,
     plus the pre-existing unrelated post-loop deadline-revalidation fetch) — the contrast with
     `>=5` is the proof, not a literal single-scan claim.
3. A third existing test (the P1 "URL learned this invocation" recovery race, gate P1) gained only
   explanatory **comments** (no logic change) documenting why it intentionally carries no override:
   its decisive exit is reached inside the first scan via the pre-existing
   `revalidateReadableStaleSource()` scratch-render path, before the main loop's `POLL_MS` sleep is
   ever reached, so the override has nothing to speed up there.

21 new `check()` calls total (232 → 253 `ok -` lines; see below), all passing.

## Isomorphism proof

### Change: resolve `POLL_MS` through `parseTestPollMs(process.env.PRO_GATE_TEST_POLL_MS) ?? 20_000` instead of the bare literal `20_000`

- Ordering preserved: **yes** — resolved once at module load (line 141), strictly before the main
  loop (line 1257) begins; the loop body, its single `POLL_MS` read (line 1476), the `probe ?
  5_000 : POLL_MS` branch, and the `Math.max(0, deadline - Date.now())` deadline clamp are
  byte-identical to before this pass.
- Tie-breaking unchanged: **yes** — no comparison, ranking, or selection logic added or reordered;
  the change only supplies an alternate numeric source for one existing `const`.
- Floating-point: **N/A** — integer milliseconds throughout (`Number(raw)` on a
  `^[1-9][0-9]*$`-validated string can never produce a fraction).
- RNG seeds: **unchanged / N/A** — no random source introduced.
- Production-default proof: see above — every unset/invalid input yields exactly `20_000`.
- Golden outputs: `golden_checksums.txt` covers only `engine-all-pass.txt`
  (`tests/engine.test.sh`'s terminal output); this pass touches neither that file nor
  `tests/engine.test.sh`, so the checksum is unaffected (re-verified below).

## Scope check

- `parseTestPollMs` is defined exactly once (`bin/cdp-poll-ms.mjs`) and called exactly once, at
  `bin/cdp-salvage.mjs` module load (line 141) — not inside any loop.
- `POLL_MS` has exactly one production read site, unchanged (`bin/cdp-salvage.mjs:1476`, inside the
  pre-existing main loop at line 1257).
- No other timing constant was touched — confirmed both by the diff (2 hunks total: the import line
  and the `POLL_MS` assignment) and by direct grep: `RENDER_INTERVAL_MS = 90_000` (line 473),
  `CONSUME_GRACE_MS = 2_000` (line 556, the 2s consume/cleanup grace), the two `25_000`-based
  scratch render budgets (lines 597, 820), and the `2_500` scratch sampling floor (lines 600-601)
  are byte-identical to before this pass.
- CDP retry backoff, exit-code logic (0/3/4/5/7), and scan ordering are untouched — the diff never
  touches any branch, comparison, or `process.exit(...)` call.
- `PRO_GATE_TEST_POLL_MS` is read only by the new fallback expression at line 141 and set only by
  the two new test blocks' `extraEnv`; no other fixture, CI workflow, or install/config path
  references it (grep evidence above).
- No CLI flag or generic "fast mode" was added; the override is env-only and test-child-scoped
  (`runSalvage`'s pre-existing `extraEnv` parameter merges into the **spawned child's** `env` only,
  never `process.env` globally — `tests/cdp-salvage.test.mjs:306`).

## Rollback

Delete `bin/cdp-poll-ms.mjs`; in `bin/cdp-salvage.mjs`, remove the `import { parseTestPollMs } from
'./cdp-poll-ms.mjs';` line and restore `const POLL_MS = 20_000;`; in `tests/cdp-salvage.test.mjs`,
remove the `parseTestPollMs`/`TEST_POLL_MS_MIN`/`TEST_POLL_MS_MAX` import, the `jsonListCalls`
counter/getter on the mock CDP server, the 15-check parser-boundary block, the new rapid-polling
behavior-proof block, and the explanatory-only comment block on the P1 recovery-race test —
equivalent to restoring all three paths to commit `438ed7f`.

## Deterministic deadline budget

This pass does not shorten any production wait: `POLL_MS` remains exactly `20_000` for every real
invocation (unset `PRO_GATE_TEST_POLL_MS`), and the loop's true bound — the caller-supplied
`timeoutSecs` deadline — is untouched, per the mission's explicit scope boundary. Unlike passes 1-4,
this pass's lever cannot reduce the *existing* suite's wall time (see the profiling section above
for why) and does not claim to; its budget is enabling a **future** fixture to assert multi-scan
behavior inside a short deadline for the cost of a `PRO_GATE_TEST_POLL_MS=50` env var, instead of
needing a real ~20-second sleep per scan to do so (structurally unaffordable inside a fast fixture
before this pass).

Actual wall acceptance (same-revision hosted A/B comparison) remains **deferred to pass 10**, per
the mission's fixed acceptance protocol.

## Verification status

See `PASS-5-VERIFICATION.txt` for full command transcripts. Summary:

- `node --check bin/cdp-salvage.mjs`, `node --check bin/cdp-poll-ms.mjs`,
  `node --check tests/cdp-salvage.test.mjs`: all PASS (exit 0, no output).
- `git diff --check`: PASS (no whitespace errors).
- Baseline (pristine `438ed7f`, `node tests/cdp-salvage.test.mjs`, foreground, `/usr/bin/time`):
  **exit 0, 232/232 `ok -`, 0 `FAIL -`, elapsed 6:40.82 (400.82s)**, first attempt, no rerun needed.
- Post-change, same invocation the file's own header documents (`node tests/cdp-salvage.test.mjs`):
  **exit 0, 253/253 `ok -`, 0 `FAIL -`, elapsed 6:44.61 (404.61s)**, first attempt, no rerun needed.
- Post-change, the actual CI invocation (`node --test tests/cdp-salvage.test.mjs`, per
  `.github/workflows/ci.yml:55` and `release.yml:45`): **exit 0, `tests 1 / pass 1 / fail 0`,
  elapsed 6:45.05 (405.05s)**, first attempt, no rerun needed.
- Delta: +21 assertions, +3.79s (+0.9%, plain invocation) / +4.23s (+1.05%, CI invocation) — within
  normal host-load noise (pass 4's own two same-code reruns spread by ~1%, 1171.47s vs 1183.13s).
- `sha256sum -c tests/artifacts/perf/2026-08-31-ci-optimization/golden_checksums.txt`: OK
  (`engine-all-pass.txt` unchanged; this pass does not touch `tests/engine.test.sh` or its shared
  library, so the full engine check was not required and was not run, per the mission's own
  conditional).
- `PASS-1.md` through `PASS-4.md`, `PASS-2-VERIFICATION.txt` through `PASS-4-VERIFICATION.txt`,
  `VERIFICATION.txt`, `engine-all-pass.txt`, and `golden_checksums.txt` were not modified by this
  pass. `.skill-loop-progress.md` was not read, edited, staged, reverted, or overwritten by this
  pass (its pre-existing modified state from prior passes is left exactly as found).

## Pass 5 result

`bin/cdp-poll-ms.mjs` (new, 24 lines) adds one strictly-parsed, bounded, positive-decimal
test-only override for `cdp-salvage.mjs`'s main-loop `POLL_MS`, honored only through a spawned Node
test child's own `env` (never globally, never in production workflow/config). Production default
(`20_000`) is preserved byte-for-byte for every unset/empty/zero/negative/malformed/leading-zero/
below-minimum/above-bound input — independently re-verified against the real parser. `parseTestPollMs`
is called exactly once, at module load, not inside any loop. CDP retry backoff, `RENDER_INTERVAL_MS`,
the 2.5s scratch sampling floor, the 25s render budgets, the 2s consume/cleanup grace, every
`timeout` argument, all exit-code logic (0/3/4/5/7), and scan ordering are byte-identical to before
this pass (2-hunk diff on `bin/cdp-salvage.mjs`: one import, one assignment). `tests/cdp-salvage.test.mjs`'s
diff is purely additive (zero removed lines) — 21 new assertions (15 direct parser-boundary cases +
6 behavior/contrast checks for the new rapid-polling proof), every pre-existing assertion including
the later-CDP-outage-after-success exit-7 case and every memo/blacklist/cross-bind/source-tab
assertion unchanged and still passing. Full suite: 232/232 → 253/253, both clean first-attempt runs,
zero failures, time-neutral within noise (+0.9-1.05%). Profiling the baseline additionally
established, and this pass's own new comparison test directly confirms, that `POLL_MS` cannot
reduce this suite's ~247s (~62%) of deadline-bound wall time — that cost is set by each test's
`timeoutSecs` argument, explicitly out of this pass's scope — so this pass's value is the enabling
capability itself, not a suite-time reduction, and the artifact records that honestly rather than
overclaiming a speedup that did not occur. This pass is therefore a **conditional prerequisite**,
not a standalone wall-time win: pass 7 must use it to deliver a separately scored ≥2 improvement,
or this seam should be reverted.
