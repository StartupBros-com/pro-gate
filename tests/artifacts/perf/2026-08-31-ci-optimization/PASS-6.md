# PASS 6 — scratch-render sampling seam

## Opportunity

| Hotspot | Impact | Confidence | Effort | Score |
| --- | ---: | ---: | ---: | ---: |
| `freshRenderText()` hydration/sample sleep | 4 | 4 | 2 | 8.0 |

The full Node suite spends real wall time waiting for mock scratch pages to move from an intentionally incomplete first DOM sample to a later decisive sample. The production 2,500ms cadence is safety-significant and remains the default. This pass adds a narrowly bounded test-only seam rather than changing production scheduling.

## Lever

The shared `bin/cdp-test-timing.mjs` exports the preserved internal APIs `parseTestPollMs`, `TEST_POLL_MS_MIN`, `TEST_POLL_MS_MAX`, `parseTestRenderSampleMs`, `TEST_RENDER_SAMPLE_MS_MIN`, and `TEST_RENDER_SAMPLE_MS_MAX`. Both parsers accept only canonical positive decimal values in their established bounded ranges; `cdp-salvage.mjs` resolves each once at module load. The former `bin/cdp-poll-ms.mjs` and pass-6-only `bin/cdp-render-sample-ms.mjs` modules are removed, so the canonical bounded-decimal logic has one implementation.

```js
const RENDER_SAMPLE_MS = parseTestRenderSampleMs(process.env.PRO_GATE_TEST_RENDER_SAMPLE_MS) ?? 2_500;
```

Only `runScratchSalvage()` supplies `PRO_GATE_TEST_RENDER_SAMPLE_MS=50`, and only for the three hydration/order fixtures plus both hung-close variants. The test parent and all ordinary spawned salvage fixtures retain their inherited environment. No CLI flag, production config, workflow setting, or generic fast mode was added.

## Measured result

Same host, same Node command (`node --test tests/cdp-salvage.test.mjs`), foreground `/usr/bin/time`:

| Measurement | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Wall time | 405.65s | 386.44s | -19.21s (-4.74%) |
| User CPU | 8.42s | 7.92s | -0.50s |
| System CPU | 2.75s | 2.25s | -0.50s |
| Max RSS | 86,092 KiB | 82,912 KiB | -3,180 KiB |
| Internal assertions | 253/253 | 274/274 | +21 focused checks |
| node:test | 1 pass, 0 fail | 1 pass, 0 fail | unchanged |

The source-derived causal budget is 19.6s: three hydration fixtures each take exactly two samples, so `3 × 2 × (2500 - 50)ms = 14.7s`; two hung-close variants each take one sample, so `2 × (2500 - 50)ms = 4.9s`. That expected 19.6s closely matches the 19.21s observed reduction. The 4.74% alone is within a broad noise envelope, but the source-derived 19.6s budget plus exact sample counts triangulate causality.

The direct wall-time result clears the separately scored `>=2s` retention threshold. This seam is retained; the pass-7 conditional-revert rule does not apply because pass 6 itself improved wall time by 19.21 seconds.

## Isomorphism proof

- **Ordering preserved:** Yes. `freshRenderText()` keeps the existing open → bounded list → DOM sample → cleanup-close sequence. The hung-close fixture now records and passes that request order explicitly.
- **First sample safety:** Yes. The marker-only, stale-terminal, and shell/sidebar fixtures each record exactly samples `1,2`; all assert that only the later nonce-bearing review is emitted. The first readable DOM observation remains non-terminal.
- **Tie-breaking unchanged:** Yes. The override changes only selected test-child delays; classifier branches, retry backoff, source/memo/blacklist/cross-bind handling, and every exit code are unchanged.
- **Floating-point:** N/A. Intervals are canonical decimal integer milliseconds.
- **RNG seeds:** N/A. No randomness was introduced or changed.
- **Golden outputs:** `sha256sum -c tests/artifacts/perf/2026-08-31-ci-optimization/golden_checksums.txt` passed.

## Protected production behavior

The shared parser rejects unset, empty, zero, negative, malformed, leading-zero, below-minimum, and above-bound inputs with `null`; the module-load fallback therefore remains exactly `2_500`. Its render maximum is exactly 2,500, so a valid test override cannot lengthen the interval. The focused production-scope search found no `PRO_GATE_TEST_RENDER_SAMPLE_MS` use in `.github/`, `lib/`, `scripts/`, or `install.sh`.

The 25-second render budgets, 2-second consume/cleanup grace, 90-second re-render interval, pass-5 main-poll behavior, retry backoff, classification, scratch open/list/close ordering, and scenario timeout arguments remain unchanged.

## Durable revert or removal

After pass 6 is committed, revert that commit to undo the seam durably. To remove only the render seam in a follow-up while preserving pass 5, restore `bin/cdp-poll-ms.mjs` from `327da27`, import the poll parser/constants from that file again, restore only the render sample literal `2_500` in `bin/cdp-salvage.mjs`, and remove only the render parser/helper/assertions and scratch-sample fixture overrides. The poll override and its tests remain. Do not alter `PASS-5.md` or `PASS-5-VERIFICATION.txt`: they are historical evidence for commit `327da27`.

Do not retain the seam if a later independent review shows that it changes production default timing or fails the focused first-sample/order assertions.
