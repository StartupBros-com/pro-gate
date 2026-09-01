// Test-only bounded timing override parsers for cdp-salvage.mjs.
//
// Production keeps its own fallback literals in cdp-salvage.mjs. Nothing in production
// workflow/config sets either test variable; this module lets the Node test harness shorten only
// selected spawned children and test both parsers directly without spawning a process per case.
//
// Accepted input is a canonical positive decimal string only: no sign, leading zero,
// fractional/exponential, or whitespace form. Invalid or out-of-bound input returns null, so the
// caller retains its production literal.

export const TEST_POLL_MS_MIN = 50;
export const TEST_POLL_MS_MAX = 20_000;
export const TEST_RENDER_SAMPLE_MS_MIN = 50;
export const TEST_RENDER_SAMPLE_MS_MAX = 2_500;

const CANONICAL_POSITIVE_DECIMAL_RE = /^[1-9][0-9]*$/;

function parseBoundedTestMs(raw, min, max) {
  if (typeof raw !== 'string' || !CANONICAL_POSITIVE_DECIMAL_RE.test(raw)) return null;
  const value = Number(raw);
  return value >= min && value <= max ? value : null;
}

// TEST_POLL_MS_MAX equals cdp-salvage.mjs's production POLL_MS literal, so a valid override can
// only shorten its main polling cadence.
export function parseTestPollMs(raw) {
  return parseBoundedTestMs(raw, TEST_POLL_MS_MIN, TEST_POLL_MS_MAX);
}

// TEST_RENDER_SAMPLE_MS_MAX equals cdp-salvage.mjs's production fresh-render sample literal, so
// a valid override can only shorten its sampling cadence.
export function parseTestRenderSampleMs(raw) {
  return parseBoundedTestMs(raw, TEST_RENDER_SAMPLE_MS_MIN, TEST_RENDER_SAMPLE_MS_MAX);
}
