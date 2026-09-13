---
title: Typed Stop for a Non-Converging Review Loop - Plan
type: feat
date: 2026-09-13
topic: rounds-not-converging-typed-stop
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Typed Stop for a Non-Converging Review Loop - Plan

## Goal Capsule

- **Objective:** When a fix loop keeps buying paid Pro rounds that will not settle the question, the loop stops on a typed reason a human can act on, at the point a human reading the findings would have stopped it, and the operator can see why and choose to continue.
- **Means:** Turn the round governor's existing churn streak into a typed stop with its trajectory published as facts, and route design-shaped findings through the NEEDS-DISCUSSION verdict the contract already carries; finding-identity grading waits for confirming-pass data.
- **Product authority:** This Product Contract owns when the stop fires, what it publishes, how it is overridden, and how a design question is raised. It does not change merge authority, the numeric round grant's advisory default, or the loop's own round cap.
- **Open blockers:** None.

---

## Product Contract

### Summary

Add a `rounds-not-converging` stop to `review-decision/v1`, fired from the churn streak the round governor already computes and published with the trajectory behind it. Tell the reviewer to raise a finding whose fix is a policy choice as NEEDS-DISCUSSION rather than FIX-FIRST, and replay the two cited chains before building any per-finding grading.

### Problem Frame

Between 2026-09-04 and 2026-09-07 the wrapper loop drove thirty gated merges. Two chains never converged: PR #159 returned one new P1 in each of three rounds, each created by the previous round's fix, and PR #166 returned two, two, then four P1s in the same region. Both were stopped by a human who read the artifacts and decided the code needed a rule, not another patch. The runtime already held the signal: its round governor scores every charged round from the per-round open P0 plus P1 count and trips a churn brake when that count fails to shrink for two consecutive rounds. Replayed from the stored round histories, the brake tripped before round 4 of both chains, exactly where the human stopped them. It enforced nothing, because the governor's policy mode defaults to advisory and the guard returns "proceed" without consulting the streak, and the decision carries only a collapsed `granted` boolean, so no caller could see the trajectory either. The wrapper's flat cap of four rounds was the only limit that bound, so each chain cost one more paid round than a human would have spent and the human's judgment had to be rediscovered by hand. The second stop on #166, two rounds of two P1s at new locations after the rule was declared, is not a count signal at all; it is the design-question case, and none of the eight replayed rounds ever used the NEEDS-DISCUSSION verdict that exists for it.

### Key Decisions

- **The churn streak is the first convergence signal; finding-identity comparison is not built.** Every round in both chains put its findings at new file locations and no reviewer emitted a RESOLVED tag, so a text-identity "repeat" would never have fired where the human stopped, and "consequence of the previous fix" needs the fix diff the runtime never sees. The streak matched both first stops. Governs R1, R3, R6.
- **The stop fires in the default configuration, is report-only, and is reversible; the numeric round grant stays advisory.** Issue #174 asks the reducer to own this decision and callers to dispatch it; the repo's own learning says repeated FIX-FIRST across two rounds is a convergence signal, not a to-do list; and the loop's cap already bounds the cost, so the value is a legible reason, not a bigger saving. Governs R2, R4, R11.
- **Design questions route through NEEDS-DISCUSSION and its named choice, and a replay experiment precedes any per-finding tag.** The verdict grammar, the reducer route and the caller prose for a human-decided choice already exist and are conformance-tested; what is missing is the reviewer using them. A per-finding kind tag would be the same cooperative signal with more machinery. Governs R7, R8.
- **No text of the review is re-parsed for these facts.** The trajectory comes from the round history the engine already writes; the design route comes from the verdict line it already extracts. Governs R6, R9.

<!-- ce-section: work-relationships -->
### How This Work Fits Together

This plan covers the typed stop and the design-question route. The surrounding work is the current understanding, not a committed roadmap.

- Issue #175's typed facts (PR #197) — Shares the contract-change discipline: every reason or facts addition regenerates both digests and the plugin mirror in one commit, and whichever lands second rebases. Can proceed independently of it.
- Confirming passes as the convergence instrument — Enables a later `repeat` and `consequence-of-previous-fix` grading from the RESOLVED and STILL-PRESENT counts the round history already records, once the loop passes the prior review on every round after the first. Still to decide: whether the loop adopts confirming passes at all, and whether the reviewer honours the tags in practice. Not active scope.
- Per-finding kind grading — Depends on the replay experiment in R8 failing. Not active scope.

### Actors

- A1. Operator: the issue author, who reads a stop, decides a rule, and chooses whether to continue a chain.
- A2. Callers that dispatch decisions unattended: the dotfiles wrapper loop and the daemon; they already end a run on any `stop-without-new-review` reason they do not special-case.
- A3. The reviewer model, a cooperative party: it follows the verdict grammar when asked and cannot be forced to.
- A4. The engine and library: score rounds, reduce decisions, and publish facts.

### Requirements

**Convergence stop**

- R1. When the round governor's churn streak reaches two, the next review query for that change reduces to `stop-without-new-review` with the reason `rounds-not-converging`, in place of a new round grant or a fix dispatch.
- R2. The stop is reversible without editing state: an operator setting lets the next round run on the same change, and the streak resets on its own when a scored round shrinks the open count.
- R3. A first scored round never trips the stop, and a chain whose open count shrinks on every round never trips it.
- R4. The stop fires with no policy setting present, while the numeric round grant keeps its advisory default and its own enforcement knob.

**Trajectory facts**

- R5. The decision's governor facts carry the trajectory the stop was derived from beside the existing `granted` value: rounds scored, the per-round open counts in order, rounds earned, the streak, the grant, and the policy mode.
- R6. Every trajectory value is read from the round history the engine already writes per charged round; no review text is parsed for it.

**Design-question route**

- R7. The review prompt instructs the reviewer that a finding whose fix is a policy the owner must set is raised as NEEDS-DISCUSSION with CHOICE lines rather than as a FIX-FIRST finding; the runtime's routing of NEEDS-DISCUSSION to a named product choice is unchanged.
- R8. Before any per-finding kind tag or parser is planned, the round-3 prompts of PR #159 and PR #166 are replayed with the R7 instruction and the outcome is recorded: whether the reviewer emitted NEEDS-DISCUSSION with usable choices; a per-finding tag is planned only if the replay fails.

**Contract and callers**

- R9. The reason and the trajectory facts land additively: both digests and the plugin mirror regenerate in the same commit, the contract version is unchanged, and the pins on the fail-closed SHIP binding rule are untouched.
- R10. Callers dispatch the stop as they dispatch any other `stop-without-new-review`: the wrapper's existing reason handling ends the run and posts the reason, and the skill and relay prose name the reason and the operator's continue setting.
- R11. The wrapper's flat round cap remains as it is.

### Key Flows

- F1. A chain stops converging
  - **Trigger:** A charged round completes and the governor scores it.
  - **Actors:** A4, A2, A1
  - **Steps:** The engine records the round's open count; the streak reaches two; the caller's next query reduces to the stop with the trajectory in its facts; the caller ends the run and posts the reason; the operator reads the arrow of open counts and either declares a rule or sets the continue knob and re-queries.
  - **Outcome:** No further paid round runs until a human acts.
  - **Covered by:** R1, R2, R5, R10
- F2. A finding is a policy question
  - **Trigger:** The reviewer judges that a finding's fix is a rule the owner must set.
  - **Actors:** A3, A4, A1
  - **Steps:** The reviewer returns NEEDS-DISCUSSION with CHOICE lines; the reducer asks the named product choice; the operator selects one; the runtime re-enters with the selection and dispatches one implementation round.
  - **Outcome:** A design question costs one decision and one round, not a chain.
  - **Covered by:** R7

### Acceptance Examples

- AE1. PR #159 replayed.
  - **Covers R1, R3, R5.**
  - **Given:** the stored round history for the change: three scored rounds with open counts 1, 1, 1.
  - **When:** the query after round 3 runs with no policy setting.
  - **Then:** it reduces to `stop-without-new-review` with reason `rounds-not-converging`, the facts show the arrow 1, 1, 1 with a streak of 2, and no round 4 is granted.
- AE2. PR #166 replayed, first sub-chain.
  - **Covers R1, R5.**
  - **Given:** three scored rounds with open counts 2, 2, 4.
  - **When:** the query after round 3 runs.
  - **Then:** the same stop, with the arrow 2, 2, 4 and a streak of 2.
- AE3. PR #166 second sub-chain is not a count signal.
  - **Covers R1, R7.**
  - **Given:** after the operator's rule, two scored rounds with open counts 2, 2.
  - **When:** the query after the second of them runs.
  - **Then:** no `rounds-not-converging` stop fires, because the streak is 1; this is the case R7 and the replay in R8 address, and the plan records it as not covered by the count signal.
- AE4. First round never stops.
  - **Covers R3.**
  - **Given:** one scored round with any open count.
  - **When:** the next query runs.
  - **Then:** the stop does not fire.
- AE5. A shrinking chain never stops.
  - **Covers R3.**
  - **Given:** open counts 3, 1, 1.
  - **When:** the query after the third round runs.
  - **Then:** the streak is 1 and no stop fires.
- AE6. Operator continues.
  - **Covers R2, R4.**
  - **Given:** the stop from AE1 and the operator's continue setting for that change.
  - **When:** the query runs again.
  - **Then:** a round is granted, the facts still show the trajectory, and the stop can fire again if the streak reaches two after the reset rule.
- AE7. Design question route unchanged.
  - **Covers R7.**
  - **Given:** a completed review whose verdict is NEEDS-DISCUSSION with three CHOICE lines.
  - **When:** the query runs.
  - **Then:** the reducer asks the named product choice exactly as before this plan.
- AE8. Replay experiment recorded.
  - **Covers R8.**
  - **Given:** the round-3 prompts of PR #159 and PR #166 with the R7 instruction appended.
  - **When:** each is sent once and its answer collected with the runtime's own verdict extraction.
  - **Then:** the result, NEEDS-DISCUSSION with usable choices or not, is recorded on issue #174 before any per-finding grading is planned.

### Success Criteria

- Replayed from stored round histories, both cited chains stop before their fourth round, where the human first stopped them, and the stop names `rounds-not-converging` with the arrow of open counts.
- The wrapper ends a run on the new reason with no wrapper change beyond prose, because it already ends on any reason it does not special-case.

### Scope Boundaries

- No finding-identity comparison across rounds, and no reviewer-emitted per-finding kind tag, until the R8 replay reports.
- No change to merge authority, to the connector-SHIP refusal, or to the acceptance predicate that binds an artifact to its run.
- The numeric round grant, its base, ceiling and earned rounds, keeps its advisory default; this plan enforces only the streak stop.
- The wrapper's flat round cap is not removed or retuned.

#### Deferred for later

- Confirming passes on every round after the first, so the round history's RESOLVED and STILL-PRESENT counts become live and a `repeat` or `consequence-of-previous-fix` grade can be read from them.
- A per-finding kind grade, only if the R8 replay fails.

### Dependencies and Assumptions

- The round history is pruned by a time window; a replay test reads the stored artifacts or a fixture reconstructed from them, not live history.
- The #166 artifacts contain more than one VERDICT line because that chain's subject was quoted verdicts; a replay uses the runtime's own verdict extraction, never a first-match grep.
- The reviewer honours the R7 instruction often enough to be useful; the R8 replay is the test of that assumption, and a failed replay routes to the per-finding tag rather than to abandoning the design route.
- Issue #175's contract changes may land first; the second lander regenerates digests over the union.

### Outstanding Questions

**Deferred to Planning**

- The name and shape of the operator's continue setting for R2: a per-change setting the wrapper and skill can pass, or the existing policy knob with a new value.
- Where the wrapper posts the trajectory when it ends a run on the new reason, and whether the daemon needs a distinct message.
- Whether the R8 replay can run on a cheaper model first or must spend two live Pro rounds, and who records the outcome on the issue.
- Whether the trajectory facts share the governor object or sit beside it, and how the corpus fixtures express a scored history.

### Sources

- Issue #174, work-spec, 2026-09-07; PR #159 and PR #166 gate-round comments, including the human's stopping notes.
- `lib/pro-gate-lib.sh`: the round scorer with its earned and streak computation and churn brake, the policy-mode function and the guard's advisory short-circuit, the round-history row with its resolved and still-present counts, and the reducer's `round-governor-denied` and NEEDS-DISCUSSION branches.
- `bin/oracle-review.sh`: the review prompt's VERDICT and CHOICE grammar and the confirming-pass instruction; the two facts builders that set `governor.granted`.
- `tests/fixtures/review-decision/v1/contract.json` and `corpus.json`; `skills/pro-gate/review-decision-v1.json`; the v0.48.0 cooldown commit as the precedent for an additive reason and fact.
- dotfiles `claude/scripts/pro-gate-loop.sh`: the flat round cap, the stop-reason handling, and the absence of any confirming-pass argument.
- Stored round artifacts under the runtime's completed store for the two chains, which supplied the per-round open counts.
- `docs/solutions/conventions/ship-the-legible-core-let-the-gate-decline-fragile-automation.md` and `an-appended-prompt-contract-is-cooperative-not-enforced.md`.
- `skills/pro-gate/SKILL.md` and `agents/oracle-reviewer.md`: the named-product-choice prose.
