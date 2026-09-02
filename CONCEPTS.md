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

## Review authority

### Review Decision

The engine-issued typed continuation chosen from normalized lifecycle, evidence, and policy facts. Callers execute this decision; they do not infer actions from verdict prose, exit codes, status messages, or local round history.

### Input Policy

The deployment-level rule that controls whether Pro-Gate supplies only the reviewed bundle or may request connector-capable delivery. It governs Pro-Gate's request surface, not permissions independently granted to the browser identity.

## Relationships

- A Review Attempt may own one Reservation; Exact Recovery resumes that same attempt.
- A Terminal Disposition or Supersession can release a Reservation's capacity without deleting the attempt's audit history.
- Applicability is an input to the Review Decision, not a synonym for completion.
- Input Policy constrains evidence delivery before a Review Attempt can be submitted.
