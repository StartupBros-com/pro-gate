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

Six concrete consequences, each of which was a separate live defect — the last three found by the
gate reviewing the fix for the first three:

1. **Cut at the owned verdict, and floor the cut at the previous block-terminating verdict.** The
   published block runs from the earliest `Pn` start *after the verdict that closed the block before
   it* through the verdict echoing this run's marker. Without the floor, a backward scan reaches into whatever came
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

4. **A claim is a claim wherever it sits on the line, and "no claim of ours" is not "no claim".**
   The first reader parsed only the FIRST echo per verdict line, so `(run marker: THEIRS)
   (run marker: OURS)` reported *no owned verdict* and fell through to the branch that hands the
   bytes back — where a tail-only nonce check then accepted them on the second token, and a direct
   capture, exempt from that check, accepted a foreign-ONLY answer outright. Reject an explicit
   foreign claim on the unowned path too, at the one chokepoint every source passes through
   (`pg_capture_bind`), so marker order on a line cannot decide ownership (#166 gate r1 P1).

5. **The same text can be a boundary or an example, and a review writes both.** Flooring the cut at
   "the previous verdict" treats a verdict a finding QUOTES — `> VERDICT: SHIP — example` — as the
   end of a block, deletes the finding that wrote it, and publishes the remainder, which still
   passes every structural, binding and nonce check. Only an unquoted, unindented, unfenced verdict
   may bound a block; a quoted one stays an ownership candidate, because the model may format its
   real verdict that way. When a floor leaves a window with no `Pn` header it did not open a block
   at all, so widen back — but never past a verdict claiming another run (#166 gate r1 P1).

6. **A name you derive is not the name the other system stores.** Pinning the Oracle session to the
   run marker looked like the fix for the shared-name route, but Oracle normalizes a custom slug to
   five ten-character words: `pg-run-StartupBros-com-pro-gate-166-1788719459-1312546` is stored as
   `pg-run-startupbro-com-pro` — one name for every run in the repository, worse than the PR-scoped
   name it replaced, and not the name the reattach fallback then asks for. Make the derived name a
   FIXED POINT of the consumer's own normalization, and check it against that rule in a test
   (#166 gate r1 P2). Keep it out of the token namespace it lives beside, too: a session name that
   parses as a run marker is a second thing claiming to be one.

## Applying it

- Bind at the line that carries the claim, then **cut to it**; never infer ownership from "last".
- When one guard is duplicated across languages, say so in both comments — divergence is silent and
  surfaces as a byte-comparison failure somewhere unrelated.
- Ask what a rejection costs on a *correct* input before choosing rejection over trimming. Here a
  false rejection and a lost round are the same outcome.
- Fix the route as well as the symptom: the Oracle session name was scoped to the PR, so every round
  and retry competed for one name and Oracle disambiguated with a numeric suffix another invocation
  could also mint. It now carries the run's launch epoch and pid, and survives Oracle's own slug
  normalization unchanged.
- Read the downstream normalizer before trusting a derived identifier, and pin the derivation to it
  with a test. "Unique when we send it" says nothing about what the other side stores.

## Related

- `docs/release-notes/v0.44.0.md`
- Issue #164; gate lineage #48 (provenance), #54 (nonce-or-nothing), #55 (positive run-binding),
  #67/#68 (cross-bound memos, verdict-line-only conviction).
