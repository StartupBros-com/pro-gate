---
title: "Ownership lives on the verdict line, not at the end of the answer"
module: "pro-gate"
date: "2026-09-06"
category: "conventions"
problem_type: "architecture_pattern"
component: "development_workflow"
severity: "high"
applies_when:
  - "a shared, long-lived channel returns one party's answer to a request identified by a token"
  - "a producer can append a second complete answer to the same channel"
  - "a consumer reads the FIRST match of a pattern out of text a producer wrote"
tags:
  - "pro-gate"
  - "run-marker"
  - "provenance"
  - "collector"
  - "cross-bind"
---

# Ownership lives on the verdict line, not at the end of the answer

## Context

pro-gate binds a collected review to the run that asked for it by having the model echo
`(run marker: <marker>)` on its terminal `VERDICT:` line. From v0.28 the collector checked for that
echo in the last six lines of the capture (`pg_capture_nonce_ok`), and `extractReview` in
`bin/cdp-salvage.mjs` bounded the published block at the LAST verdict on the page.

Both are readings of *position*, and position is only a proxy for ownership while a conversation
holds exactly one answer.

On ai-hedge-fund PR #176 round 4 (2026-09-05) one ChatGPT conversation received two runs' prompts and
the model answered both. The page then held, in order: a full pushbot finding block ending in
`VERDICT: FIX-FIRST … (run marker: pg-run-…-pushbot-2619-…)`, then `P0..P3: none` and
`VERDICT: SHIP … (run marker: pg-run-…-ai-hedge-fund-176-…)`.

Every check passed. Our echo was in the tail, so the binding accepted. `extractReview`'s backward
scan for the first `Pn` block start ran past the foreign verdict line to the earliest `Pn` on the
page, so the published block spanned both answers. The caller's loop then read the **first**
`VERDICT:` line, counted the round FIX-FIRST, and dispatched a fixer at
`apps/blog-writer/.../hazards.claims.ts` — a path in a different repository. The round and its Pro
spend were consumed, and the SHIP this repository actually earned was never counted.

## The lesson

**A token proves ownership of the line it sits on, not of the bytes around it.** Once the channel can
carry two answers, "the last verdict" and "our verdict" are different lines, and every check written
against the first one is checking the wrong thing.

Three concrete consequences, each of which was a separate live defect:

1. **Cut at the owned verdict, and floor the cut at the previous verdict.** The published block runs
   from the earliest `Pn` start *after the verdict that closed the previous block* through the
   verdict echoing this run's marker. Without the floor, a backward scan reaches into whatever came
   before. (`pg_capture_own_segment`, `lib/pro-gate-lib.sh`; `extractReview`/`verdictIndex`,
   `bin/cdp-salvage.mjs` — two implementations of one rule, and they must agree byte-for-byte or the
   organizer's `--finalize` comparison fails with `result-mismatch`.)

2. **The mirror layout is a different bug with the same cause.** With our block first and a foreign
   block after it, the old code convicted the whole page as cross-bound, blacklisted the URL, and
   discarded a finished review — losing the round outright. A page carrying a verdict line that
   echoes our marker demonstrably answered our prompt, whatever else landed in it.

3. **A guard's scope decides whether it strands its own users.** The obvious hardening — reject any
   `(run marker: …)` token anywhere in the answer — reintroduces exactly the false positive #68 gate
   r2 P1 was written to prevent: this repo's own reviews quote incident markers verbatim, and a
   rejection retries into the same text until the reservation ages out. Scope the hard rejection to
   VERDICT lines, where a token is an ownership *claim*; report a token in finding prose and publish.

## Applying it

- Bind at the line that carries the claim, then **cut to it**; never infer ownership from "last".
- When one guard is duplicated across languages, say so in both comments — divergence is silent and
  surfaces as a byte-comparison failure somewhere unrelated.
- Ask what a rejection costs on a *correct* input before choosing rejection over trimming. Here a
  false rejection and a lost round are the same outcome.
- Fix the route as well as the symptom: the Oracle session name was scoped to the PR, so every round
  and retry competed for one name and Oracle disambiguated with a numeric suffix another invocation
  could also mint. It is now pinned to the run marker, which is unique per invocation.

## Related

- `docs/release-notes/v0.44.0.md`
- Issue #164; gate lineage #48 (provenance), #54 (nonce-or-nothing), #55 (positive run-binding),
  #67/#68 (cross-bound memos, verdict-line-only conviction).
