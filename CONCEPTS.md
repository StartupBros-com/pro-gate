# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Review lifecycle

### Review Attempt

One invocation bound to an immutable review target and evidence identity. An attempt may be uncharged, charged, recoverable, terminal, or associated with durable review bytes; those facts are not inferred from wrapper survival alone.

### Reservation

Durable ownership of review-account capacity for a submitted attempt that may outlive its invoking process. A reservation can remain collectable without holding capacity after proof-backed completion or supersession.

### Reservation Guard

The serialization that makes recording a Reservation and deciding review capacity one indivisible step. Without it a waiter can read capacity as free in the window after a slot is released but before the Reservation recording that spend exists, and spend the same capacity twice. The guard is mutual exclusion only: holding it is not itself a claim on capacity, and releasing it asserts nothing about whether an attempt finished.

Where the host offers no kernel-level file lock, the guard falls back to a directory it creates and removes. That fallback needs its own answer to a question the kernel otherwise settles — whether a directory left behind belongs to a process that is still running — and answering it wrongly is how two holders end up inside a guard whose entire purpose is that there is only ever one.

### Orphan Grace

The waiting period that separates "nobody has claimed this yet" from "the claimant is gone". Taking a directory-based lock and recording who holds it are two steps, so between them the lock exists while naming no owner — a state a live winner passes through and an interrupted one stays in forever. The grace is the age past which the second reading is the only one left: long enough that a running claimant always finishes recording itself within it, short enough that an abandoned lock clears on its own.

It answers a different question from the liveness check a Reservation Guard's fallback performs, and the two are easy to conflate. Liveness asks whether a *named* owner still exists; the grace applies precisely when there is no name to ask about. Treating an unnamed lock as abandoned on sight deletes the winner's lock while it is still being written, and a replacement then admits a second holder — so whatever decides that a lock counts as claimed governs this rule, and any new way of recording a holder re-decides it.

### Applicability

Whether review evidence still describes the current target. Applicability is independent of whether the attempt completed: finished evidence may be stale, while unfinished evidence may stop applying after the target moves or closes.

### Terminal Disposition

Immutable positive proof that an attempt no longer owns recovery. Its proof determines whether the recorded charge is refunded or retained; elapsed time and missing output are not dispositions by themselves.

### Supersession

Proof that a charged attempt no longer applies to the current target. Supersession preserves charge and auditability while releasing capacity, and cannot be reversed by later mutable observations.

The proof is external to the attempt's own execution: it comes from the repository target moving on, not from anything the attempt itself reports. So an attempt whose own work never reaches a terminal signal can still be superseded, and waiting on that attempt to conclude is not a precondition. Where an attempt carries no immutable record of the input it was bound to, supersession cannot be proven for it at all and the lifecycle fails closed rather than guessing.

### Exact Recovery

Collection or reconciliation of one canonically identified attempt without a new submission. Ambiguous ownership fails closed rather than selecting a plausible conversation or spending again.

### Acceptance Predicate / Conviction Predicate

The two classes of answer to "is this captured answer ours?", distinguished by what being wrong costs rather than by what they compare.

An **acceptance** predicate publishes a capture as this run's review, so a false positive presents a possibly-foreign answer as authoritative; it fails closed, and a near-miss costs a retry. A **conviction** predicate declares a conversation to be another run's, so a false positive blacklists it, discards the memo locating it, and destroys a finished answer the account already paid for; it fails open.

The same identifier can therefore be compared at different strictness in the two classes without inconsistency. Treating them as one question and picking a single global strictness is wrong in one direction by construction.

What the acceptance predicate concluded about a published artifact is its **ownership**: `exact` (the authoritative verdict line named this run's marker) or `nonce-less` (an artifact accepted under the pre-marker rules). These are conceptual terms, not a persisted `ownership` field in binding records. A capture carrying a foreign authoritative claim has no ownership because it is never published. Final nonce acceptance is case-sensitive; browser-side foreign conviction folds case so a near-match is not destructively misclassified.

### Conversation Memo

The conversation URL remembered for a marker so later passes can find the same conversation without rescanning. A memo is authoritative only while its conversation id has the shape of a real conversation id; a memo that fails that check, or that proves to carry foreign content, is revoked so the next pass rescans every candidate. A blank render of a real-id memo is a transient, not a miss, and does not revoke it.

Revocation claims a unique generation before reading it, with a fingerprint of the rejected URL's digest in its bounded filename. That conviction applies to every claim for the marker, survives a failed blacklist append, and prevents ordinary recall from restoring rejected bytes; a claim naming it is kept until the blacklist records it: as the URL when the memo or a claim holds it, otherwise as the claim's fingerprint, so a copy another writer publishes later stays rejected. Recall never returns a memo that the blacklist or a pending claim rejects: it revokes that memo as it does a placeholder, while an unreadable blacklist or claim listing leaves the memo unresolved rather than trusted or recovered. An uncertain read or restore retains the claim as a recovery handle; recall preserves a different concurrent memo and resolves a duplicate once identical bytes or the same inode prove restoration. Unresolved claims prevent confirmed absence and retirement based on misses. Reservations and legacy bindings, including a binding that exists but cannot be read, protect their recovery claims from pruning; unowned claims follow the memo count cap and original 14-day age horizon. Resolved legacy receipts retain the original memo's 14-day clock.

### Salvage classification

What the latest salvage pass concluded about a reservation's conversation: `owned-incomplete` (the model was still writing), `inconclusive` (rendered without a decisive result), `browser-down` (the browser was unreachable), `absent` (no conversation carried the marker), `cross-bound` (another run's completed answer was found instead), `throttle` (ChatGPT throttled the account), `terminal` (a completed answer was seen), or `terminal-infrastructure` (the conversation ended in a terminal infrastructure state). Status surfaces it as `classification`; it is observation only — never a release, a refund, or an admission input.

### Submit-Failure Class

A planned taxonomy, not a currently emitted classifier: `upload-stalled` (an attachment never finished uploading), `send-unconfirmed` (the prompt did not appear before the send timeout), `cloudflare-challenge` (a challenge page preceded submission), `other`, or `none`. Current code does not persist this enum or classify it once from transcript prose. Refund authority comes from the Terminal Disposition's proven-no-submit evidence; delivery-condition snapshots record the circumstances of that no-send, and Cloudflare follows its separate Account Cooldown path.

## Review authority

### Review Decision

The engine-issued typed continuation chosen from normalized lifecycle, evidence, and policy facts. Callers execute this decision; they do not infer actions from verdict prose, exit codes, status messages, or local round history.

### Round Convergence

Whether successive charged rounds on one change are settling. The round governor scores each round by its open P0 plus P1 count and keeps a churn streak: the count of consecutive rounds that failed to shrink it. A streak of two produces the typed report-only stop `rounds-not-converging`, including in advisory mode. The operator's `PRO_GATE_ROUNDS_CONTINUE=1` removes the shared scorer/guard's churn collapse and the reducer's churn stop for the configured invocation. It exposes the uncollapsed numeric grant without enlarging it: enforced exhaustion and zero-budget lockdown still deny a fresh round. CONTINUE is stateless, with no durable one-use counter, and does not bypass cooldown, provenance or ownership. FORCE alone retains the reducer's separate churn stop. Convergence is judged from the round history the engine writes, never from re-reading review text.

A round whose findings are all below the blocking severities scores zero, exactly like a clean round, so a chain of such rounds never raises the streak and is never reported as non-converging; the governor bounds blocking-severity churn only.

### Input Policy

The deployment-level rule that controls whether Pro-Gate supplies only the reviewed bundle or may request connector-capable delivery. It governs Pro-Gate's request surface, not permissions independently granted to the browser identity.

### Account Cooldown

The engine-wide back-off that follows any proof that ChatGPT is rate-limiting the review account: the short interstitial page, the "Too many requests" modal painted over a live conversation, or a Cloudflare challenge. While it runs, no fresh review is submitted, reservation probes and organizer traffic stay off the account, harvest defers, and the Review Decision reports `account-cooldown-active` with the seconds remaining instead of a grant. A probe that finds a conversation under the modal reports `throttled`: the conversation exists, is not progressing, and is not evidence of absence.

### Delivery Condition

The circumstances a fresh review's Send was attempted under: the exact evidence relation, input mode, attachment policy and Oracle build, captured before charge. When Oracle's session record proves Send was never dispatched, the required v2 Terminal Disposition retains those components and a known consecutive count or explicit unavailable state before refund/cleanup. The optional v1 sidecar is a compatibility mirror. Its failure cannot discard the new disposition's evidence or keep an otherwise proven no-send charged. Failure to publish the disposition itself preserves the existing conservative charge/ownership behavior. The snapshot records no-send proof, not an observed delivery success.

Two consecutive known no-sends under unchanged conditions produce `delivery-failed-unchanged`. Unknown history or build identity instead produces `delivery-state-unavailable`, with a null count. A sent attempt or review breaks the chain, and a proven relation/input/policy/known-build change can permit a new grant. Unknown-to-known build identity alone is not a proven change. The operator's `PRO_GATE_FORCE_ROUND=1` can bypass a known repeated-failure count, but not unavailable evidence, churn, cooldown, provenance or ownership. New Cloudflare dispositions explicitly record `not-applicable` and remain Account Cooldown events.

Existing v1 dispositions and delivery sidecars remain readable. A v1 disposition with no sidecar is explicitly `legacy-untracked` and retains legacy admission behavior, without claiming a zero count or a changed condition. v0.58 and earlier cannot distinguish a failed/missing sidecar publication from genuinely untracked history or a Cloudflare refund. New dispositions preserve that uncertainty when it affects their own no-send history.

### Throttle Sighting

An observation of a rate-limit surface, the "Too many requests" modal or the short interstitial, over a conversation tab during a salvage scan. A sighting is owned when the conversation under the surface carries this run's own marker, foreign when it provably carries another run's marker, and unowned otherwise.

An owned sighting always re-arms the Account Cooldown, because it is this run's own positive proof that its conversation exists. An unowned sighting re-arms it only through its Seen Record. A sighting not proven foreign leaves the scan inconclusive rather than confirmed absent, so a rate limit never spends a recovery miss.

### Seen Record

The memory that an unowned Throttle Sighting with a given fingerprint, its conversation URL together with the surface's text, has already charged the Account Cooldown inside the current suppression horizon. While a fingerprint's record is live, further unowned sightings of it are ignored; when it expires, the next sighting charges once more and starts a new horizon, so a stale surface nobody closes re-arms the cooldown once per horizon rather than forever.

A whole scan charges at most one cooldown, however many sightings it batches. Records are bounded by age and by count, but a record for a fingerprint the current scan is still observing is never evicted for capacity, only for age.

### Brief

A caller-supplied task body that replaces the built-in final-tier reviewer persona, so a review slot can be spent on a different question — an architecture critique, a migration-risk read — while the answer is still collected the usual way. Where Input Policy governs what context is attached, a Brief governs what is asked.

The engine appends its own output contract after a brief, so a brief chooses the question but inherits the severity-ranked findings-and-verdict shape the collector requires. That appended contract is cooperative, not enforced: brief text and appended contract carry equal authority, so a brief can dictate its own verdict rather than reason to one. The boundary that holds instead is who supplies and who consumes — briefs are operator-authored, and no Review Decision consumes a brief run's verdict. A brief never shares a pull request's change identity, so it cannot spend that review's capacity, serialize against it, or be returned by Exact Recovery in its place.

## Relationships

- A Review Attempt may own one Reservation; Exact Recovery resumes that same attempt.
- A Reservation Guard serializes the recording of a Reservation against the capacity decision that reads it; it is not itself capacity, and it is held for far less time than a Reservation.
- The Orphan Grace governs a Reservation Guard's lockless fallback only, and covers the window before an owner is recorded; the liveness check covers every moment after.
- A Terminal Disposition or Supersession can release a Reservation's capacity without deleting the attempt's audit history.
- Applicability is an input to the Review Decision, not a synonym for completion.
- Input Policy constrains evidence delivery before a Review Attempt can be submitted.
- A Brief redirects what a Review Attempt asks; it never widens who may act on the answer.
- An Account Cooldown pauses fresh spend and browser traffic; it neither releases a Reservation nor advances its miss count.
- A Seen Record bounds how often an unowned Throttle Sighting can re-arm the Account Cooldown; an owned sighting always re-arms it.
