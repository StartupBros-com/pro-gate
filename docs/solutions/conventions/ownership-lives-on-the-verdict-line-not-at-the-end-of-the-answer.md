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

Both are readings of _position_, and position is only a proxy for ownership while a conversation
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

## The replacement policy

**Validate the complete response before accepting any of it.** An owned verdict does not make
another task's authoritative result safe to publish. Reject mixed cross-task results in either
order, including a single verdict line claiming both run markers. Preserve the captured evidence;
do not slice out one block and silently discard the rest.

Ownership claims are top-level review verdicts. A finding that mentions another run marker, or
quotes an old verdict in prose, a blockquote, a fenced code block, or an indented example, is not
claiming to return that run's review. Those references remain part of the owned answer. No rule
should infer ownership from P-section numbering or which findings header happens to come first.

The browser and shell paths enforce the same distinction. Browser collection must preserve DOM
quote and code context: `innerText` alone can flatten `<blockquote>` and `<pre>` into apparent
top-level verdict lines. Collection is scoped to this run's response after its prompt, so a
foreign answer earlier in the conversation is not a new mixed result. Foreign-only, nonce-less,
and chronology checks remain independent constraints.

Legacy plain-text captures or artifacts that already lost quote and code boundaries cannot
recover that formatting. A top-level `VERDICT:` ownership claim without quote or code markup is
treated as authoritative; P-section order does not establish that it was an example.

Apply this validation at the shared acceptance paths for direct Oracle output, reattach, browser
harvest, and completed or pending artifact replay. The predicate leaves a clean owned capture
untouched; existing nonce removal remains a separate collection step. Replay preserves stored
artifact bytes. A mixed legacy artifact remains intact on disk and is refused through the existing
provenance-failure path. A stored result binding or digest proves which bytes were saved, not
that those bytes meet the replacement ownership policy.

Rejection is not lifecycle proof. It does not release a reservation, refund a charge, delete
state, or make a fresh paid review eligible after a timeout. An absent spinner or verdict and
repeated refusal do not establish that the review is gone. Existing authoritative lifecycle
proofs continue to govern release. A shared mixed conversation also remains outside either run's
rename, archive, and close authority; the organizer and finalizer keep their independent checks.

## Session names

The Oracle session name was scoped to the PR, so every round and retry competed for one name.
Oracle could disambiguate with a numeric suffix another invocation could also mint. The replacement
name includes the run's launch epoch and process id and survives Oracle's normalization unchanged.

That normalization matters: a custom slug is shortened to five ten-character words. A long run
marker such as `pg-run-StartupBros-com-pro-gate-166-1788719459-1312546` becomes
`pg-run-startupbro-com-pro`, losing the unique suffix. Keep session names outside the run-marker
namespace, test that normalization is idempotent, and test that distinct invocations remain
distinct after normalization.

## Verification boundary

Fixtures should exercise both clean and rejected captures through direct Oracle capture and
browser harvest, plus clean and mixed artifact replay. Assert exact output bytes, retained
evidence and lifecycle state, and absence of publication or false SHIP authority on rejection.
Include both mixed orderings, dual claims, quoted examples with DOM context, and old scrollback
before the prompt. These fixtures prove classification and publication behavior; they do not
prove live ChatGPT reliability, review completeness, unattended delivery, or model correctness.

## Related

- `docs/release-notes/v0.44.0.md`
- Issue #164; gate lineage #48 (provenance), #54 (nonce-or-nothing), #55 (positive run-binding),
  #67/#68 (cross-bound memos, verdict-line-only conviction).
