---
title: "An appended prompt contract is cooperative, not enforced"
module: "pro-gate"
date: "2026-09-04"
category: "conventions"
problem_type: "architecture_pattern"
component: "development_workflow"
severity: "medium"
applies_when:
  - "a caller supplies prompt text and the engine appends rules after it"
  - "an answer's shape is a precondition for accepting or releasing scarce capacity"
  - "a verdict extracted from model prose feeds a typed decision that gates a merge"
tags:
  - "pro-gate"
  - "prompt-contract"
  - "brief"
  - "trust-boundary"
  - "review-decision"
  - "capacity-release"
---

# An appended prompt contract is cooperative, not enforced

## Context

`--brief <task-file>` (v0.39.0/v0.39.1) lets a caller replace the engine's built-in final-tier
reviewer persona with an arbitrary task body, so a Pro slot can buy an architecture critique or a
migration-risk read instead of only a code review. The engine always appends its own contract footer
afterwards — the findings format, the terminal `VERDICT:` line, and the run marker.

That footer is not decoration. The return path is review-shaped at four independent layers, and an
answer that misses any of them is discarded while its reservation stays held until recovery:

- `bin/cdp-salvage.mjs:666` defines `VERDICT_RE` and bounds extraction by scanning backwards for that
  terminal line (`:671`, `:696`), which is why the run marker rides on it.
- `pg_is_review` (`lib/pro-gate-lib.sh:2243`) accepts a capture only when it is at least 40 bytes,
  carries a `[Pn]` or `Pn: none` marker, **and** yields a verdict.
- `pg_extract_verdict` (`lib/pro-gate-lib.sh:2231`) recognises only `SHIP`, `FIX-FIRST`, and
  `NEEDS-DISCUSSION`.
- Three JSON validators (`lib/pro-gate-lib.sh:2662`, `:2687`, `:2870`) and the round governor branch
  on that same closed vocabulary.

The first version of this feature documented the boundary as *"the brief chooses the question, never
the answer's shape."* That claim was **false**, and it shipped into the README, a commit message, a PR
body, and a message to a peer session before a live pre-release run refuted it. Every test that
guarded the feature used a stub oracle; all passed; none could catch it.

## Guidance

### Appending rules after caller text buys cooperation, not control

The brief body and the appended footer are instructions at the same authority level. A brief can
request an incompatible format, instruct the model to disregard what follows, or simply dictate its
own verdict — and `pg_extract_verdict` greps the terminal line, unable to distinguish a reasoned
verdict from a dictated one. Appending changes what a *cooperative* model does. It cannot constrain an
uncooperative or merely careless one.

The engine now says so in the code that does the appending (`bin/oracle-review.sh:2966`), because the
comment that previously claimed enforcement was the artefact that made the wrong claim credible.

### State the boundary as who supplies and who consumes

The safety argument that actually holds is narrower than "the engine controls the shape":

1. Briefs are operator-authored — no untrusted party supplies one.
2. No typed decision path consumes a brief run's verdict, because `--brief` is deliberately **not**
   exposed through the `pro-gate` skill or the relay agent, both of which are bound to
   `review-decision/v1` and documented never to decide review policy.

That non-exposure is a **security boundary, not a scoping preference**. Wiring `--brief` into any
surface that feeds `review-decision/v1` would make a caller-authored `SHIP` reachable by the merge
gate. Record it as a boundary wherever the decision is revisited.

### Size validation is not answerability validation

The 64 KiB cap on a brief bounds bytes, not answerability. A brief that invites a clarifying question
produces a *completed* turn carrying no findings and no verdict: it fails `pg_is_review`, is
discarded, drives retry, and holds its reservation until recovery — ordinary ambiguity becoming a
shared-capacity denial path. The footer therefore pins the run to a single turn and directs the model
to state assumptions rather than ask (`bin/oracle-review.sh:2988`), emitted **after** the brief so a
cooperative brief cannot drop it.

### Do not let a new task share the canonical work's identity

Round budget, the per-change guard, supersession, and recovery are all keyed on change identity, and
the round is charged on the dispatch path (`bin/oracle-review.sh:1915`) well before the prompt is
assembled — so no prompt-level flag can opt out of it. A brief combined with `--pr` would therefore
spend that PR's rounds, serialise against its real review, share supersession state, and be
selectable by `--recover <PR>` in place of the canonical review.

The combination is refused outright (`bin/oracle-review.sh:195`) rather than discouraged in prose, so
brief runs always take a diff-derived identity. Refusing the combination replaced a planned
per-persona round-governor mechanism: the same intent, with no new governor state to keep correct.

Trade-off worth stating rather than discovering: `pg_run_meta_write` requires a PR number, so any
`--diff`-only run — brief or not, unchanged from v0.38.2 — cannot write run metadata and has degraded
repository-qualified recovery. Harvest by exact marker still works.

## Applicability

This generalises past pro-gate to any harness that concatenates caller-supplied text with trailing
rules and then parses the result: an appended contract is a request, and the enforceable boundary is
who may supply the text and who consumes the parsed output. Where the parsed output releases scarce
capacity or feeds an automated decision, write the boundary down and keep the caller-controlled lane
away from the consuming surface.

The corroborating practice is cheap and worth reusing: because `PRO_GATE_ORACLE_BIN` substitutes the
oracle binary and the engine passes the assembled prompt as its `-p` argument, a stub can capture the
exact prompt. Normalising the volatile identity (run marker, repo hash) makes a byte-exact pre/post
diff possible at zero slot cost — matching sha256 digests over the normalised prompt — which is how
the default review path was proven unchanged across both PR #137 and PR #139. That proof is real but
bounded: it shows the
prompt did not drift, and says nothing about how a model answers it. Only a live run does that: one
slot, spent on a deliberately non-review brief, returned FIX-FIRST and produced the three corrections
above (issue #138, PR #139).
