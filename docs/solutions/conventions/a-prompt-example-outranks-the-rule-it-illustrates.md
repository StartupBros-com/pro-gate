---
title: "A prompt's example outranks its rule: make each example a filled-in instance and run it through the real parser"
module: "pro-gate"
date: "2026-10-17"
category: "conventions"
problem_type: "design_pattern"
component: "development_workflow"
severity: "high"
applies_when:
  - "a prompt states an output format in prose and also shows an example of it"
  - "a strict parser decides whether a model's answer is accepted, bound to a run, or published"
  - "model answers are refused in one consistent shape and the first explanation offered is that the model does not comply"
  - "widening a parser to accept a shape the model keeps producing is being considered"
tags:
  - "pro-gate"
  - "prompt-contract"
  - "run-marker"
  - "verdict-line"
  - "acceptance-predicate"
  - "rejected-capture"
---

# A prompt's example outranks its rule: make each example a filled-in instance and run it through the real parser

## Context

From v0.28.0 (2026-08-02) until v0.65.1, the review prompt in `bin/oracle-review.sh` gave two instructions for the same final line, and they disagreed.

- The format rule said: `End with one final line:  VERDICT: SHIP | FIX-FIRST | NEEDS-DISCUSSION  — <=15 word reason.`
- A few lines later, the run-marker example said: `... append it verbatim to the end of your final VERDICT line, i.e.: VERDICT: <your verdict> (run marker: X)`. It had no reason.

GPT-5.5 Pro did not pick one of the two. It merged them and put the reason inside the marker's parentheses: `VERDICT: SHIP (<reason>; run marker: X)`. The terminal parser (`pg_capture_verdict_claims <file> terminal` in `lib/pro-gate-lib.sh`) binds only a standalone `(run marker: X)` token, written exactly that way, on the last verdict line. The merged shape names this run's own marker but never binds, so the capture gets no exact ownership and is refused.

From 2026-10-13 to 2026-10-17, six distinct finished reviews were refused this way: mathfleet#540, better-ccflare#486 and #488, dotfiles#1788, pushbot#4574 and pro-gate#285. Every one was a SHIP, and every one carried its own run's exact marker.

The cause was found late. The first two responses treated the symptom:

1. #271 was filed as "Terminal answer with embedded run marker strands PR owner in repeated collection". It read the refusal as Pro echoing the marker in the wrong place, which is model non-compliance. The issue title still frames it that way.
2. #285 (version 0.64.0, released as v0.64.1) turned the refusal into a typed `rejected-capture` stop instead of a loop that kept collecting the same answer. That ended the loop but not the refusals. #285's own Pro review then hit the defect #285 was handling, and the PR had to move to a new head before it could merge (session history).
3. Widening the parser to accept the merged shape was considered and rejected. The marker grammar is repeated across bash and JS: `lib/pro-gate-lib.sh`, `bin/cdp-salvage.mjs` and `bin/cdp-organizer-expressions.mjs`. The #299 PR counted nine byte-identical sites that would all need the change. It would also loosen an acceptance check that is meant to fail closed.
4. Only an audit of the prompt itself found the contradiction. #299 (v0.65.1) changed one prompt line.

## Guidance

### 1. An example is a stronger instruction than the prose around it

When an example and a rule disagree, the model does not reliably choose the rule. It merges the two, and the merged shape can fit neither the rule nor the parser. So:

- Make every example a literal instance of the rule, with every required field present and in order. Here that means the verdict, then the reason, then the marker.
- Where one field could plausibly be folded into another, say what must not happen. The fixed line adds "Never put the reason inside the marker's parentheses".
- When a format rule gains a field, update every example of that format in the same change.

### 2. Test the example from the prompt actually sent, using the real parser

`tests/template-verdict.test.sh` saves the prompt the stubbed oracle received. It takes the example text after `i.e.: `, fills in `SHIP` and a reason, and checks two things:

- The example puts `— <reason>` before `(run marker: <sent marker>)`.
- The filled-in example, passed through `pg_capture_verdict_claims ... terminal`, returns the marker of the run that sent the prompt.

Both checks fail against the old prompt (143 checks, 2 failures) and pass with the fix (143/143).

This check sits between two others that already existed. The prompt digest proves which bytes were sent (`an-appended-prompt-contract-is-cooperative-not-enforced.md`). Live reviews show what a model actually does. Neither tells you whether the prompt's own example would be accepted. Filling in the example and parsing it does, and it costs no review.

### 3. Read the prompt before you blame the model or widen the parser

A refusal that keeps the same shape across different PRs and repositories points at an input they share. Every refused answer here was a SHIP carrying its own marker. That pattern shows a model following an instruction, not ignoring one. Read the prompt that was sent before you file the refusal as non-compliance, build machinery around it, or loosen the parser to fit it.

### 4. A prompt example can also be a parse anchor: change its shape, not its anchors

The example line has readers besides the model:

- `bin/cdp-organizer-expressions.mjs` finds the marker line by its prefix, `(run marker: X — internal correlation id`.
- The test finds the example by the literal text `i.e.: `.

#299 rewrote the middle of the line and kept both anchors. Before editing a prompt line that other code reads, search for the literal text it starts with.

### Pending verification

Whether Pro now follows the new example is unverified. Only real reviews will show it.

The #299 PR body notes that since the v0.64.1 install, counted when the fix was written, 18 runs gave 0 refusals and 16 accepted reviews. The base rate was already low, so a few clean runs after the fix prove little.

A refusal for a different reason is a separate check and says nothing about this fix. One example is a template verdict: a generic SHIP that names nothing from the diff.

## Why This Matters

Each refused SHIP was a finished Pro review that had already been paid for, and the system threw it away. Before #285, a refusal also trapped the PR's owner in collecting the same answer again and again.

The misdiagnosis cost more than the refusals did. It produced a typed stop, which is useful but treats the symptom. It came close to producing a parser change across the nine sites #299 counted, and that change would have loosened a fail-closed acceptance check. The whole cause was one prompt line.

The code comment at the fixed line in `bin/oracle-review.sh` records what the example must look like. It does not record two things:

- that the cause was found in the prompt only after the model and the parser had been blamed;
- the fill-in-the-example test that would have caught the contradiction when v0.28.0 shipped.

## When to Apply

- Writing or editing a prompt line that shows an example of an output format, especially one a parser reads.
- Adding a field to a format rule. Change every example in the same change, and run the fill-in-the-example test.
- Investigating model output that is refused in a consistent shape. Read the prompt that was actually sent first.
- Not for free-form prose that no code parses.

## Examples

Before (v0.28.0 to v0.65.0):

```text
End with one final line:  VERDICT: SHIP | FIX-FIRST | NEEDS-DISCUSSION  — <=15 word reason.
(run marker: X — internal correlation id. Do not discuss it, but append it verbatim to the end of your final VERDICT line, i.e.: VERDICT: <your verdict> (run marker: X))
```

Pro answered `VERDICT: SHIP (<reason>; run marker: X)`, and the answer was refused.

After (v0.65.1). The format rule is unchanged, and only the example line moved:

```text
(run marker: X — internal correlation id. Do not discuss it, but append it verbatim, in its own parentheses after your reason, to the end of your final VERDICT line. Never put the reason inside the marker's parentheses, i.e.: VERDICT: <SHIP|FIX-FIRST|NEEDS-DISCUSSION> — <reason> (run marker: X))
```

The test fills it in as `VERDICT: SHIP — no defects in review.diff (run marker: X)`, which binds to the run.

## Related

- `an-appended-prompt-contract-is-cooperative-not-enforced.md` (the same footer. A prompt rule is a request, not enforcement. Its digest check proves what was sent, not that the example would be accepted.)
- `ownership-lives-on-the-verdict-line-not-at-the-end-of-the-answer.md` (why the marker has to be on the verdict line)
- `extraction-and-comparison-must-share-one-normalization.md` (the same class of failure: the model reshaped its marker echo)
- `one-identity-check-two-error-biases.md` (why the acceptance check fails closed, which is why the parser was not widened)
- #271 (symptom), #285 (typed `rejected-capture` stop, released in v0.64.1), #299 (this fix, v0.65.1)
