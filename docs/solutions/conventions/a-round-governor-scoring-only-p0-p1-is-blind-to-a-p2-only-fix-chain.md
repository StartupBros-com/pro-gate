---
title: "A round governor scoring only P0+P1 is blind to a P2-only fix chain"
module: "pro-gate"
date: "2026-09-21"
category: "conventions"
problem_type: "workflow_issue"
component: "development_workflow"
severity: "high"
applies_when:
  - "a paid-review round governor's convergence and stop logic scores only blocking severities (open P0+P1) and ignores lower-severity findings entirely"
  - "a fix-review loop keeps surfacing new low-severity findings in the same function or mechanism across many rounds with no P0 or P1 ever open"
  - "deciding whether an automated round budget alone can be trusted to bound a review loop, versus posting an explicit numbered stop rule on the PR"
  - "a mechanism under active rework is grinding rounds inside a chain the governor scores as clean"
  - "triaging whether a governor's blind spot should become a scoring change (score P2 streaks too) versus an operator-side process rule"
symptoms:
  - "the governor's trajectory shows a flat run of zeros (for example arrow 1,0,0,0,0,0,0,0,2,0,0) with streak 0 and the grant unchanged after eight or more scored rounds"
  - "every FIX-FIRST verdict in a long streak carries only P2 findings, never a P0 or P1 line, and the rounds-not-converging stop never fires"
  - "a review chain accumulates far more paid rounds than the base grant would suggest, with no engine-level signal that it should stop"
  - "each round's fix opens the next real defect in the same function, and the reviewer, not the engineer, is choosing where the next round goes"
tags:
  - "pro-gate"
  - "round-governor"
  - "review-loop"
  - "p2-only-chain"
  - "convergence-signal"
  - "stop-rule"
  - "review-budget"
  - "fix-review-cycle"
---

# A round governor scoring only P0+P1 is blind to a P2-only fix chain

## Context

The v0.31 round governor (design comment at `lib/pro-gate-lib.sh:2331-2360`) grants a per-change budget for paid review rounds and grows or shrinks it by trajectory: a base grant `PRO_GATE_ROUNDS_BASE` (default 3), "+1 per completed re-review whose OPEN P0+P1 count... is strictly below its predecessor's," clamped to an immovable ceiling `PRO_GATE_ROUNDS_CEILING` (default 8), with "two consecutive non-shrinking re-reviews collapse[ing] the grant" (`lib/pro-gate-lib.sh:2337-2340`).

Each completed review is recorded by `pg_round_note_severity` (`lib/pro-gate-lib.sh:2512-2553`) into a `.hist` trajectory file, one line per round: epoch, verdict, open P0, open P1, resolved, still-present. The open count that line carries is filtered to "P0+P1 lines only — the governor scores blocking severities" (`lib/pro-gate-lib.sh:2546`). A round whose only findings are P2 therefore records an open count of 0 — indistinguishable, to the scorer, from a clean SHIP.

`pg_round_score` (`lib/pro-gate-lib.sh:2636-2687`) walks that trajectory. A step from a nonzero open count to zero always resets the streak and earns a round; a step that stays at zero also resets the streak, because "a clean round converges the chain. Zero cannot shrink further, so zero-to-zero is not churn" (`lib/pro-gate-lib.sh:2662`). Only a step that fails to shrink while nonzero increments the streak. The typed `rounds-not-converging` stop, shipped in v0.53.0 to close issue #174, fires purely off `governor.streak >= 2`, independent of the round-policy mode (`lib/pro-gate-lib.sh:3530-3538`; per `docs/release-notes/v0.53.0.md`: "When two consecutive scored rounds fail to shrink the open P0+P1 count, the next query... returns `stop-without-new-review` with reason `rounds-not-converging`"). The governor's facts object, `{arrow, continue_override, earned, grant, granted, policy_mode, scored, streak}` (`lib/pro-gate-lib.sh:2772`), is what a caller or an operator actually reads to see this trajectory.

The plan that shipped the stop (`docs/plans/2026-09-13-1910-feat-rounds-not-converging-typed-stop-plan.md`) built it from two chains that never shrank their open P0/P1 count for two rounds running (PR #159: 1,1,1; PR #166: 2,2,4) and deliberately scoped the signal to that count: "The churn streak is the first convergence signal; finding-identity comparison is not built... Every round in both chains put its findings at new file locations." Nothing in that design scores P2, and neither the plan nor the v0.53.0 release notes mention P2 at all; the exclusion exists only as the inline comment quoted above. The P0+P1 filter was inherited from the pre-existing churn brake as a reuse decision rather than argued as a severity cutoff, and no P2-only chain had been observed or replayed when the stop was designed; the same session did name a related gap in the count logic, that a chain whose open count happens to shrink is exactly what a shrink-detection streak cannot see (session history).

The consequence, observed directly on PR #215: a chain that keeps returning FIX-FIRST with a single P2 each round never moves the scored open count off zero, so the streak never reaches 2 and the typed stop never fires, no matter how many such rounds run, as long as the earned-round grant keeps pace with usage. Round 12's own disposition names this exactly: "the round governor scores P0 and P1 only, so a chain of single P2s never trips it" (PR #215 comment).

Replaying PR #215's own posted per-round P0/P1 counts (round 1: one P1; rounds 2-8: P2-only; round 9: two P1; rounds 10-11: P2-only) through the governor's scoring logic above reproduces the exact state the PR's round-12 review ran against: arrow `1,0,0,0,0,0,0,0,2,0,0`, earned 2 (the 1→0 step after round 1, and the 2→0 step after round 9), streak 0 (every nonzero reading is immediately followed by a zero, which always resets the streak rather than accumulating it), grant 5 (base 3 + earned 2). Twelve paid rounds ran on that PR — roughly 10-13 minutes of Pro time apiece — and every finding was real.

## Guidance

When the engine's convergence signal cannot see the severity class a chain is producing, the stop has to come from a rule the reviewer posts on the PR itself, in advance of the round it governs, not from the engine. Two rule shapes were used on PR #215 and PR #216, and both held:

**Mechanism-scoped rule** — names a sub-piece of the PR, not the whole PR, and pulls just that piece:
> "Round 5 is the last round spent on this mechanism: if it produces further P2s inside it, the mechanism is pulled out of this PR into its own issue... The stale-sighting dedupe itself, which #208 is about, is not in question." (PR #215, posted after round 4)

**PR-scoped rule** — names the whole PR and states the terminal consequence:
> "Round 11 is the last paid round on this PR whatever it says: SHIP merges; anything else is recorded in the body and the PR is handed to the operator with a needs-human issue." (PR #215, posted after round 10)

Both shapes share three parts: a round number the rule takes effect at, the scope it binds (a named mechanism, or the whole PR), and the consequence spelled out in advance (pull the mechanism to a follow-up issue; or hand the PR to the operator with a needs-human issue).

**Honouring it** means that when the declared round arrives and still finds something, the loop does not spend another round deciding what to do about it — it executes the consequence already on record. On PR #215, round 5's two P2s were still inside the pulled mechanism, so the six commits that built it were reverted as one commit and the whole attempt filed to issue #217 in the same disposition comment. On PR #216, the same pattern ran twice: a tab-close mechanism pulled after round 3 (rule posted after round 2) and a `--close --url` primitive pulled after round 5 (rule posted after round 4), both filed to issue #218 alongside a daemon-side alternative.

**An exception is allowed, but only stated before the round it modifies, with its reason.** After round 10's "round 11 is the last paid round" rule, round 11 found a P2 that the PR body had already named with the same fix. The agent posted, in round 11's own disposition — before round 12 ran — that it was exceeding its own limit by one round and why: "the finding and its fix were already named on this PR before the round ran, so round 12 reviews a change this PR chose, not a new direction," and simultaneously posted a stronger terminal rule for the round it was granting: "Round 12 is final in the stronger sense that the code freezes after it." That is the shape an exception takes: declared in advance, reasoned, and it tightens the next constraint rather than loosening it.

**What to file when pulling a mechanism**: a follow-up issue carrying every finding from every round spent on it, the exact commits reverted, and the constraints a dedicated design must meet — not just a deleted branch. Issue #217 (retire-on-healthy, PR #215 rounds 2-5) and issue #218 (durable recovery handle, PR #213/#216 rounds, eleven paid rounds total across #209, #213 and #216) are both built this way; the reverted commits stay in the PR's own history as the record, per both PR bodies.

**What the hand-over looks like** when the terminal rule is hit instead: the finding and its fix are written into the PR body as a residual with its cost and trigger conditions spelled out (PR #215's "Known residuals, declined with reasoning" section), and the decision of what to do about it — merge as-is, apply the fix without a paid re-review, or spend one more round — is left to the operator, explicitly: "Merging with this residual, applying the one-line fix first, or spending a thirteenth round is the operator's decision, not the gate's and not mine." (PR #215, round 12 disposition)

## Why This Matters

The governor is a deliberate P0/P1 trajectory brake, not a general round limiter — the plan that built the typed stop scoped it to the count signal that matched the two chains it was designed against, and explicitly deferred any per-finding severity or identity grading until a replay experiment justified it (`docs/plans/2026-09-13-1910-feat-rounds-not-converging-typed-stop-plan.md`, Key Decisions). That is a sound, narrow design — but it means a P2-only chain is not a gap someone forgot to close; it is a case the shipped signal was never meant to cover, and the code and the PR record both say so in the same words ("the round governor scores P0 and P1 only, so a chain of single P2s never trips it"). Whether the governor should also score P2 streaks, or expose a P2-only-chain fact, is an open product question for a successor of issue #174; this doc records the practice that works until that is decided.

P2 chains are not free just because they don't trip the brake. Each of PR #215's twelve rounds cost real Pro-model time and real wall clock, and every finding across the chain was a genuine defect in concurrent filesystem state — this was not the loop manufacturing busywork, it was a reviewer correctly finding the next real edge in an admission function each time the previous edge was closed.

A rule posted after the round it was meant to govern is not a rule; it is a rationalization. The value of "round 11 is the last paid round" only exists because it was on the record before round 11 ran, so that when round 11 still found something, the choice being made (exceed the limit, or don't) was constrained by a commitment made without knowing the answer in advance. Posting it after the fact would let any outcome be justified after seeing it.

There is an honest-credit angle worth naming plainly: a chain that keeps finding real defects is still a loop the reviewer is steering, not the engineer building the mechanism. Each round in the retire-on-healthy chain and the P2-only tail of PR #215 was the reviewer choosing where the next round went; the engineer's job in that situation is not to keep feeding it, but to notice the shape (real findings, flat severity, no sign of terminating) and impose an external stop rather than let the loop run until the grant runs out on its own.

## When to Apply

- A review chain is returning FIX-FIRST round after round but every finding is P2 (or otherwise below whatever severities the round governor scores) — the trajectory the engine watches will read as flat/converged even though the loop is not settling.
- The findings keep landing inside one sub-mechanism that is not the PR's stated goal (an optimization or hardening layer added on top of the actual change) — post a mechanism-scoped rule before continuing, so a pull decision is pre-committed rather than negotiated after another round's cost is sunk.
- The chain is not confined to one mechanism, or has already survived a mechanism-scoped pull and is still not settling — post a PR-scoped rule with a hard round number and the terminal consequence (SHIP merges; anything else goes to the operator).
- A declared limit is about to be crossed because the finding is a residual the PR already named with the same fix, not a new direction — state the exception and its reason in the same comment that grants the next round, before that round is dispatched, and tighten (not loosen) the constraint that follows it.
- A mechanism is pulled — always open (or point to) a follow-up issue that carries every finding and reverted commit from the attempt and the constraints a future design must satisfy; never just drop the branch history.
- The terminal rule is reached with an unresolved residual — write the finding and its fix into the PR body with its cost and trigger conditions, and hand the merge/fix/re-round decision to the operator rather than deciding it unilaterally.

## Examples

**PR #215** ("dedupe stale throttle-modal sightings," rebuilt from PR #208/#211 on v0.53.0): twelve paid rounds.
- Round 1: FIX-FIRST, one P1 (fixed).
- Rounds 2-4: FIX-FIRST, P2-only (one, two, then three findings), all inside a retire-on-healthy mechanism the round-2 fix introduced. After round 4: mechanism-scoped rule — "Round 5 is the last round spent on this mechanism."
- Round 5: FIX-FIRST, two more P2s in the same mechanism → rule executed: six commits reverted as one commit, the attempt filed to issue #217.
- Round 6: NEEDS-DISCUSSION with two named CHOICE lines (the first live use of the v0.53.0 design-question route) — agent selected `bounded-dedupe` under standing instruction, recorded on the PR.
- Rounds 7-8: FIX-FIRST, one P2 each (concurrent prune races), fixed. After round 7: PR-scoped rule — "Round 8 is the last paid round on this PR"; round 8's finding was recorded as a bounded residual instead of triggering another round.
- (Main merged in mid-chain via PR #216; conflict resolved, decision unchanged.)
- Round 9: FIX-FIRST, two P1 and one P2 (the only round after round 1 to score nonzero) — all fixed; one more round declared allowed if the dedupe core produced anything new.
- Round 10: FIX-FIRST, two P2s (lock-reclaim races) — fixed with a redesign to a stable-file `flock` (see the sibling doc on pathname locks). New PR-scoped rule — "Round 11 is the last paid round on this PR whatever it says: SHIP merges; anything else... handed to the operator with a needs-human issue."
- Round 11: FIX-FIRST, one P2 (a residual the PR body had already named) — exceeded the round-10 rule by one round, with the exception and its reason posted in the same comment, alongside a stronger terminal rule: "Round 12 is final... the code freezes after it."
- Round 12: FIX-FIRST, one P2 (a one-line ENOENT-handling race) — the freeze was honoured; the agent did not commit the fix, recorded it in the PR body, and handed the decision to the operator. The operator chose fix-then-merge over merge-as-is or a thirteenth round; the fix landed unreviewed by a further paid round, backed by a red-before-green pairing plus the full local suite and CI.
- Governor facts observed going into round 12 (independently reproduced from the PR's own posted per-round P0/P1 counts against the scoring logic at `lib/pro-gate-lib.sh:2636-2687`): arrow `1,0,0,0,0,0,0,0,2,0,0`, earned 2, streak 0, grant 5 — the streak never left 0 because every nonzero reading (round 1's single P1, round 9's two P1s) was immediately followed by a shrink back to zero, so the typed stop had no trajectory to fire on despite eleven scored rounds behind it.

**PR #216** ("protect a retained reservation's recovery memo," rebuilt from PR #213 on v0.53.0): six rounds, two mechanism-scoped pulls (a tab-close-on-supersession mechanism pulled after round 3 under a rule posted after round 2; a `--close --url` primitive pulled after round 5 under a rule posted after round 4), both filed to issue #218 together with eleven paid rounds' worth of findings spanning PR #209 (rounds 7-8), PR #213 and this PR. Round 6, on the reduced tree, returned SHIP with zero findings.

## Related

- `./ship-the-legible-core-let-the-gate-decline-fragile-automation.md` — the earlier precedent for the same underlying practice (pull a fragile addition after the gate repeatedly finds new, deeper problems; ship the legible core), from before the round governor existed to formalize any of this as a stop signal.
- `./separate-review-lifecycle-applicability-capacity-and-input-trust.md` — the design stance the governor sits inside: local round history is advisory, never quota; the typed stop is the one engine-enforced backstop layered on that default.
- `./a-pathname-locks-reclaim-cannot-be-fenced-lock-a-stable-files-open-descriptor-instead.md` — the lock finding from the same PR's rounds 9-12, a different failure class.
- PR #215 — StartupBros-com/pro-gate, the twelve-round P2-only-tail chain this learning is drawn from.
- PR #216 — StartupBros-com/pro-gate, the sibling chain with two mechanism-scoped pulls.
- Issue #174 — the typed-stop design (closed; shipped in v0.53.0).
- Issue #217 — the pulled retire-on-healthy mechanism's findings and constraints (open).
- Issue #218 — the pulled durable-recovery-handle mechanism's findings and constraints (open).
- `docs/plans/2026-09-13-1910-feat-rounds-not-converging-typed-stop-plan.md` — the plan that scoped the typed stop to the P0/P1 count signal and deferred severity/identity grading.
- `docs/release-notes/v0.53.0.md` — the shipped `rounds-not-converging` stop entry.
