# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Review lifecycle

### Review Attempt

One invocation bound to an immutable review target and evidence identity. An attempt may be uncharged, charged, recoverable, terminal, or associated with durable review bytes; those facts are not inferred from wrapper survival alone.

### Reservation

Durable ownership of review-account capacity for a submitted attempt that may outlive its invoking process. A reservation can remain collectable without holding capacity after proof-backed completion or supersession.

### Applicability

Whether review evidence still describes the current target. Applicability is independent of whether the attempt completed: finished evidence may be stale, while unfinished evidence may stop applying after the target moves or closes.

### Terminal Disposition

Immutable positive proof that an attempt no longer owns recovery. Its proof determines whether the recorded charge is refunded or retained; elapsed time and missing output are not dispositions by themselves.

### Supersession

Proof that a charged attempt no longer applies to the current target. Supersession preserves charge and auditability while releasing capacity, and cannot be reversed by later mutable observations.

### Exact Recovery

Collection or reconciliation of one canonically identified attempt without a new submission. Ambiguous ownership fails closed rather than selecting a plausible conversation or spending again.

### Conversation Memo

The conversation URL remembered for a marker so later passes can find the same conversation without rescanning. A memo is authoritative only while its conversation id has the shape of a real conversation id; a memo that fails that check, or that proves to carry foreign content, is revoked so the next pass rescans every candidate. A blank render of a real-id memo is a transient, not a miss, and does not revoke it.

### Salvage classification

What the latest salvage pass concluded about a reservation's conversation: `owned-incomplete` (the model was still writing), `inconclusive` (rendered without a decisive result), `browser-down` (the browser was unreachable), `absent` (no conversation carried the marker), `cross-bound` (another run's completed answer was found instead), `throttle` (ChatGPT throttled the account), `terminal` (a completed answer was seen), or `terminal-infrastructure` (the conversation ended in a terminal infrastructure state). Status surfaces it as `classification`; it is observation only — never a release, a refund, or an admission input.

## Review authority

### Review Decision

The engine-issued typed continuation chosen from normalized lifecycle, evidence, and policy facts. Callers execute this decision; they do not infer actions from verdict prose, exit codes, status messages, or local round history.

### Input Policy

The deployment-level rule that controls whether Pro-Gate supplies only the reviewed bundle or may request connector-capable delivery. It governs Pro-Gate's request surface, not permissions independently granted to the browser identity.

### Brief

A caller-supplied task body that replaces the built-in final-tier reviewer persona, so a review slot can be spent on a different question — an architecture critique, a migration-risk read — while the answer is still collected the usual way. Where Input Policy governs what context is attached, a Brief governs what is asked.

The engine appends its own output contract after a brief, so a brief chooses the question but inherits the severity-ranked findings-and-verdict shape the collector requires. That appended contract is cooperative, not enforced: brief text and appended contract carry equal authority, so a brief can dictate its own verdict rather than reason to one. The boundary that holds instead is who supplies and who consumes — briefs are operator-authored, and no Review Decision consumes a brief run's verdict. A brief never shares a pull request's change identity, so it cannot spend that review's capacity, serialize against it, or be returned by Exact Recovery in its place.

## Relationships

- A Review Attempt may own one Reservation; Exact Recovery resumes that same attempt.
- A Terminal Disposition or Supersession can release a Reservation's capacity without deleting the attempt's audit history.
- Applicability is an input to the Review Decision, not a synonym for completion.
- Input Policy constrains evidence delivery before a Review Attempt can be submitted.
- A Brief redirects what a Review Attempt asks; it never widens who may act on the answer.
