---
title: "Separate review lifecycle, applicability, capacity, and input trust"
date: "2026-09-02"
category: "conventions"
module: "pro-gate"
problem_type: "architecture_pattern"
component: "development_workflow"
severity: "medium"
applies_when:
  - "a gate spends a scarce subscription-backed browser session instead of a metered API"
  - "recovery must collect an existing external attempt without resubmitting it"
  - "an external connector can read more context than the caller supplied"
tags:
  - "pro-gate"
  - "review-decision"
  - "reservation-lifecycle"
  - "capacity-release"
  - "input-policy"
  - "exact-marker-recovery"
---

# Separate review lifecycle, applicability, capacity, and input trust

## Context

A browser-driven ChatGPT Pro review spends a scarce subscription-backed conversation slot, but the
provider exposes no trustworthy quota meter to the local engine. A local round count can describe
history; it cannot answer how much ChatGPT allowance remains. The engine instead has to answer four
smaller questions with evidence:

1. Which exact attempt owns the review?
2. Does that attempt still own recovery and account capacity?
3. Does its evidence still apply to the current target?
4. What review context is Pro-Gate allowed to request or attach?

Earlier work let callers infer too much from prose, exit codes, or surviving sidecars. One concrete
regression treated completed or pending review bytes as unresolved run metadata and sent callers back
into recovery (session history, August 28-29). Other adapter tests went green while exercising archive
or missing-path fixtures rather than installed recovery behavior (session history, August 26-28). These
failures established the core rule: observation and state assembly can evolve, but action authority
and proof ownership must stay centralized.

The shipped architecture was completed through PRs #118, #120, #123, and #124. This learning treats the closed historical ideation and alternative wait/input branches as context,
not parallel supported designs. Issue #109 remains an open residual for this architecture: a
current-head, exact-owned conversation can remain verdict-less without positive generic terminal-UI
proof.

## Guidance

### Resolve one canonical attempt before choosing an action

`pg_attempt_snapshot` gives every caller the same precedence over dispositions, durable artifacts,
active state, reservations, and run metadata (`lib/pro-gate-lib.sh:944-1084`). A newer distinct
attempt can outrank old proof; stale mutable sidecars from the same superseded attempt cannot.
Callers must not recreate this precedence from status prose.

`review-decision/v1` is a pure continuation policy over normalized facts. Its contract explicitly
excludes filesystem, lock, browser, round, and publication work (`lib/pro-gate-lib.sh:2476-2484`),
and the reducer implements that policy at `lib/pro-gate-lib.sh:2616-2805`. The skill,
relay, and daemon dispatch its typed action and re-resolve at the effect boundary; they do not infer a
continuation from a `VERDICT`, exit code, recoverability flag, or round count.

### Make capacity a query over proof-backed attempt state

A durable reservation can exist without consuming capacity. Completed and superseded reservations
are excluded by `pg_reservation_holding_count` (`lib/pro-gate-lib.sh:1493-1502`). This avoids a second
manually synchronized “active count.”

Supersession is monotonic. The transition rechecks the exact marker, canonical key, charged epoch,
legacy proof, **and the head OID the caller validated against GitHub** under the reservation lock
before writing the canonical record (`lib/pro-gate-lib.sh:1399-1453`). It preserves the charge and
audit/recovery pointers while releasing capacity and current applicability. It is not a refund and
does not accept review bytes.

The head belongs in that list for the same reason the others do (#134). The decision is taken in
`recover_superseded_reason` against a binding read before the GitHub query; without the head in the
compare-and-swap, the commit could land against a *different* binding substituted afterwards —
reachable because `pg_attempt_disposition_cleanup` unlinked the binding outside the guard, and
bindings are otherwise write-once. The failure it prevents is releasing a slot still held by
current-head work. Review of that change found no current production caller that writes a binding
for a marker which already exists (every run mints a fresh marker), so the head clause is defense in
depth for that invariant rather than a fix for an observed release. Note what the control is: a
serialization guarantee between cooperating callers, not an authorization boundary. `flock` is advisory, so a process writing `$PRO_GATE_HOME` directly
bypasses this API entirely — that trust boundary is the single-user-owned state directory, unchanged.

Terminal dispositions are also proof records, not guesses. Their immutable payload binds repository,
target, marker, round key, charged epoch, terminal kind, and proof kind
(`lib/pro-gate-lib.sh:713-746`). Only positively proven non-submission can remove the recorded round;
post-submission terminal outcomes retain the charge (`lib/pro-gate-lib.sh:849-881`).

### Recover the exact attempt; never “try again” as diagnosis

Recovery selects an exact marker or a canonically identified charged attempt and collects it without
a new submission. Ambiguous state stays fail-closed. This prevents retries from turning a browser
hydration failure, crashed wrapper, or long-running answer into duplicate paid work.

The same principle applies to legacy compatibility: each added compatibility path narrowed a positive
proof predicate rather than making missing evidence acceptable. PR #120 admitted only a literal
legacy `diff` key after exact identity agreement; PR #123 initially admitted an empty legacy spend
when marker time equaled the immutable charged epoch. Queued runs later disproved marker time as charge
evidence, so v0.38.1 instead revalidates exact immutable binding and canonical run metadata under the
reservation lock before filling the proven charge.

### Treat local round history as advisory, not quota

By default, `pg_round_policy_mode` returns `advisory` unless an operator explicitly configures an
enforced cap or lockdown (`lib/pro-gate-lib.sh:2143-2159`). History and convergence signals remain
useful diagnostics, but they do not impersonate ChatGPT subscription allowance or block changed,
proven evidence.

### Default to the narrowest input surface

Input delivery is resolved before state, output, locks, browser, repository, or Oracle work
(`bin/oracle-review.sh:151-188`). The default `bundle-only` policy attaches the reviewed change and
rejects connector-capable input. `connector-enabled` is a deliberate compatibility opt-in.

This is a local request boundary, not an external permission attestation. Pro-Gate can prove whether
it emitted the connector directive and attached a diff. Input Policy does not itself attest to,
inspect, or revoke connector grants independently attached to the browser identity or ChatGPT
project. Those grants remain an operator trust boundary.

### Leave evidence-gated residuals open

Do not force a new failure into an existing state because a timeout feels plausible. Issue #109's
current-head, exact-owned, verdict-less conversation is real, but elapsed time, repeated missing
`VERDICT`, or an absent spinner is not positive terminal proof. The issue body retains an earlier
timeout hypothesis as historical context; the latest issue guidance is evidence-gated instead. A
future evidence-gated implementation should require a turn-scoped rendered terminal affordance after
the latest exact marker, no active-generation control, no newer or foreign marker, and bounded
fresh-render confirmation. Until that DOM contract is proven, the reservation correctly stays
recoverable and charged.

## Why This Matters

The architecture maximizes useful subscription capacity without inventing a quota API. It releases a
slot only when evidence says the review is complete or no longer applicable, and it resubmits only
when the canonical lifecycle says no recoverable attempt remains. This protects both directions:
starvation from obsolete reservations and double-spend from premature release.

Centralizing action in the typed reducer also keeps safety fixes accretive. Capacity proof, legacy
recovery, and input trust changed across several releases without creating a second caller protocol or
rewriting the decision contract. The alternative wait/heartbeat/`next_action` design was closed
because it added observation machinery but no new submit, collect, or recovery capability.

## When to Apply

- A browser automation or human-in-the-loop gate consumes a scarce resource whose real allowance is
  not exposed through an API.
- A long-running external operation must survive process crashes and be collected without duplicate
  submission.
- Completion and applicability can diverge: a result may be finished but stale, or unfinished but no
  longer relevant.
- An external agent or connector has broader authority than the payload the local caller intends to
  provide.
- A proposed wait loop, dashboard, or retry protocol duplicates an existing typed action surface.

## Examples

### Do not conflate existence, capacity, and applicability

```text
Bad:
  reservation_exists => slot_busy => answer_current

Good:
  attempt = canonical_snapshot(target)
  holds_capacity = attempt is recoverable and not complete/superseded
  applicable = immutable evidence still matches the current target
  next_action = review_decision(attempt, applicable, current_evidence)
```

### Do not use local attempts as provider quota

```text
Bad:
  three local rounds happened => ChatGPT quota exhausted

Good:
  local history is advisory
  active exact-owned work, browser health, throttle, concurrency, and provenance remain hard gates
```

### Default narrow; opt into connector delivery once

```bash
# Safe default: Pro-Gate attaches the reviewed bundle and emits no connector request.
PRO_GATE_INPUT_POLICY=bundle-only

# Deliberate deployment-level compatibility opt-in.
PRO_GATE_INPUT_POLICY=connector-enabled
```

The second setting does not prove the browser connector is repository-scoped; it only permits
Pro-Gate to request connector-capable delivery.

## Related

- [Ship the legible core; let the terminal gate decline fragile automation](./ship-the-legible-core-let-the-gate-decline-fragile-automation.md)
- [Issue #109: prove current-head terminal-without-verdict UI state](https://github.com/StartupBros-com/pro-gate/issues/109)
- PRs [#118](https://github.com/StartupBros-com/pro-gate/pull/118), [#120](https://github.com/StartupBros-com/pro-gate/pull/120), [#123](https://github.com/StartupBros-com/pro-gate/pull/123), and [#124](https://github.com/StartupBros-com/pro-gate/pull/124)
