---
title: "Extraction and comparison must share one normalization"
module: "pro-gate"
date: "2026-09-07"
category: "conventions"
problem_type: "architecture_pattern"
component: "development_workflow"
severity: "high"
applies_when:
  - "a model is asked to echo an identifier and the echo is later matched against the original"
  - "the same identity question is answered by more than one reader, in more than one language"
  - "a mismatch is treated as positive evidence of foreign ownership rather than as no evidence"
tags:
  - "pro-gate"
  - "run-marker"
  - "nonce-binding"
  - "cross-bind"
  - "normalization"
  - "locale"
---

# Extraction and comparison must share one normalization

## Context

pro-gate binds a captured review to the run that paid for it with a per-attempt run marker —
`pg-run-<ROUND_KEY>-<launch epoch>-<pid>` — that the prompt asks the model to repeat on its final
`VERDICT:` line. `ROUND_KEY` preserves letter case from repository text, so a real marker looks like
`pg-run-StartupBros-com-pro-gate-166-1788719459-1312546`.

Four readers answered "is this echo ours?": `foreignAnswerMarker`, `lastExactMarkerAt`/
`hasExactMarker`, the browser-side `validateTarget` twin, and the shell's `pg_capture_nonce_ok`.
Every one of them **extracted** the echo case-insensitively — `/(pg-run-[A-Za-z0-9.-]+)/i`, a
character class spanning both cases — and then **compared** it case-sensitively, with `===`,
`String.includes`, or `grep -qF`.

## The failure

A model that lowercased its own echo produced an answer that every reader classified as another
run's, and the two halves of the system reacted independently and expensively:

- The browser side convicted the conversation **cross-bound**: it blacklisted the URL and discarded
  the memo recording where the review lived. Because a memo is the only handle on a conversation
  whose tab is gone, the run's own finished, paid answer became unrecoverable.
- The engine side refused to bind the capture, set it aside `.unbound`, and re-read the same
  unchanged bytes on every retry until the reservation aged out.

Neither side was wrong on its own terms. The defect was that the *extractor* and the *comparator*
disagreed about what the identifier is — and the loose end was on the side that fails destructively.

## The rule

**Normalize once, at the boundary, and let every reader share it.** Where a value crosses a trust
boundary and comes back reshaped, define exactly one predicate for "is this the same value" and
route every reader through it — including readers in another language, another process, and readers
that only look like existence checks (`text.includes(id)`, `grep -qF`, a regex without `/i`).

Two corollaries this bug taught:

1. **A guard and the check that gates it must move together.** `FOREIGN_MARKER_RE` decides that a
   page belongs to someone else, but it only runs when the ownership check has already said "not
   ours". Widening one without the other turns a previously harmless case into a fresh false
   conviction. The right unit of change is the pair, never one side of it.
2. **Case folding in shell tools is locale-dependent; in JS it need not be.** `grep -i` and gawk's
   `tolower()` consult `LC_CTYPE`, and under a Turkish locale `I` does not fold to `i` — which would
   reinstate this exact bug on those hosts for any repository whose name contains an I. Pin
   `LC_ALL=C` on the shell side. On the JS side prefer an explicit ASCII fold over
   `String.toLowerCase()`, which is **not length-preserving** (`'İ'.toLowerCase()` is two code
   units) and would silently shift every index in code that compares positions within one string.

## Why loosening the comparison was safe here

Only because the identifier carries its own uniqueness that letter case does not contribute to: a
marker ends in `-<launch epoch>-<pid>`, and one process has exactly one of each. Two genuinely
different runs therefore cannot differ *only* in case, so folding case cannot launder another run's
claim. Establish that property before loosening a comparison — without it, this change would be a
security regression rather than a fix. The regression tests pin both directions: a self-echo in
either case binds, and a foreign marker, an all-caps foreign marker, and a sibling attempt of the
same round differing only in its pid are all still refused.

## Related

- [[an-appended-prompt-contract-is-cooperative-not-enforced]] — the same trust boundary from the
  other side: the model's cooperation with the echo contract is requested, never guaranteed.
- `docs/solutions/conventions/separate-review-lifecycle-applicability-capacity-and-input-trust.md`
  — why a mismatch that means "no evidence" must not be spelled the same way as one that means
  "positive evidence of foreign ownership".
