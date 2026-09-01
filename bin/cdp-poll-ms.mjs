// Test-only override parser for cdp-salvage.mjs's main polling cadence (production POLL_MS).
//
// Production always uses the literal 20_000ms default in cdp-salvage.mjs; nothing in production
// workflow/config ever sets PRO_GATE_TEST_POLL_MS. This module exists only so the Node test
// harness can shorten that cadence for its own spawned children (via extraEnv, not a global
// export) and so its parsing can be exercised directly, without spawning a process per case.
//
// Accepted input: a canonical positive decimal string only — no sign, no leading zero, no
// fractional/exponential/whitespace form — whose numeric value falls within
// [TEST_POLL_MS_MIN, TEST_POLL_MS_MAX]. TEST_POLL_MS_MAX equals the production POLL_MS default,
// so a valid override can only ever shorten the cadence, never extend it. Every other input —
// unset, empty, "0", negative, malformed, leading-zero, below-minimum, or above-bound — is
// rejected (returns null); callers must fall back to their own production literal.

export const TEST_POLL_MS_MIN = 50;
export const TEST_POLL_MS_MAX = 20_000;

const CANONICAL_POSITIVE_DECIMAL_RE = /^[1-9][0-9]*$/;

export function parseTestPollMs(raw) {
  if (typeof raw !== 'string' || !CANONICAL_POSITIVE_DECIMAL_RE.test(raw)) return null;
  const value = Number(raw);
  return value >= TEST_POLL_MS_MIN && value <= TEST_POLL_MS_MAX ? value : null;
}
