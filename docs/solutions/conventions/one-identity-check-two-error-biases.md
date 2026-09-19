---
title: "One identity check, two error biases: fold where refusal destroys, stay strict where acceptance publishes"
module: "pro-gate"
date: "2026-09-11"
category: "conventions"
problem_type: "architecture_pattern"
component: "development_workflow"
severity: "high"
applies_when:
  - "one identity comparison feeds both an accept-as-ours and a convict-as-theirs decision"
  - "two changes argue opposite global policies for the same predicate and both cite real failures"
  - "loosening a comparison is proposed to fix a liveness stall"
tags:
  - "pro-gate"
  - "run-marker"
  - "nonce-binding"
  - "fail-closed"
  - "error-bias"
  - "review-gate"
---

# One identity check, two error biases

## Context

pro-gate asks "is this echoed run marker ours?" in two places that look like the same question and
are not.

- **Acceptance.** `pg_capture_nonce_ok` in `lib/pro-gate-lib.sh`. Returning 0 publishes a captured
  answer as this run's review.
- **Conviction.** `finalizerOwnership`, `organizerOwnership`, `foreignRunMarkerAfter` and
  `classifyEvidence` in `bin/cdp-salvage.mjs`. Returning "not ours" blacklists the conversation,
  discards the memo that records where it lives, and makes a finished answer unrecoverable.

Two pull requests argued opposite *global* policies for marker comparison, and each cited a real
failure. PR #166 kept the comparison strict and pinned it with a test. PR #169 proposed folding
ASCII case everywhere, because a model that lowercased its own echo was convicting its own run.
Both had merged-and-real evidence, so the disagreement could not be settled by finding the mistaken
party. There wasn't one.

## The rule

**Pick the error bias from the consequence of being wrong, not from the predicate.** When a single
identity comparison feeds decisions whose failures are asymmetric, the correct strictness differs
*per decision*, and a uniform answer is wrong in one direction by construction.

- A false **accept** publishes a possibly-foreign answer as an authoritative review. Fail closed.
  Case drift then costs a retry — a liveness cost, never a correctness one.
- A false **convict** destroys evidence that was already paid for and cannot be recreated. Fail
  open. A drifted self-echo is this run's answer.

This is the review-gate instance of the broader rule *fail closed on privileged actions, fail open
on ownership*. What shipped in PR #169 (v0.46.0) folds case in the conviction predicates and leaves
acceptance byte-exact.

## Diagnosing this shape

When two changes propose opposite global policies for one comparison and both cite real incidents,
stop looking for the wrong one and ask what each side's false positive *does*. If the two answers
differ in cost class — a retry versus destroyed evidence, a stall versus a wrong publication — the
disagreement is not about the comparison at all. It is two decisions wearing one predicate.

The asymmetry is worth stating in the code, because the next reader will see an inconsistency and
try to "fix" it. A comment naming the opposing call site and its cost is what stops that.

## Applicability and limits

The loosening half is safe only because the identifier carries uniqueness that case does not
contribute to: a marker ends in `-<launch epoch>-<pid>`, both digits, and one process has exactly
one of each — so folding case cannot make two distinct runs compare equal. Establish that property
before relaxing any identity comparison; without it this is a laundering hole, not a fix.

That same argument is why the acceptance side *could* also fold without admitting another run — the
reason it does not is the asymmetry of consequences, not a uniqueness gap. That question is
deliberately open and tracked in issue #192 rather than settled inside a merge.

One process note. PR #169 shipped three assertions requiring acceptance to fold, which contradicted
#166's `mis-cased own echo remains unbound without becoming a foreign claim`. Both cannot pass.
Removing assertions is normally gate self-weakening — but assertions for behaviour you have
deliberately chosen **not** to ship must go, because the alternatives are a red suite or shipping a
policy change by accident. The discipline is to name the removal in the commit and the pull request,
and to file the deferred decision as a tracked issue, never to delete quietly.

## Related

- [[extraction-and-comparison-must-share-one-normalization]] — the same bug from the extractor's
  side. Read together: that doc's "normalize once" rule governs how an identifier is *parsed*; this
  one governs how strictly the parsed value is *compared*, which is set per consequence.
- [[separate-review-lifecycle-applicability-capacity-and-input-trust]] — why "no evidence" and
  "positive evidence of foreign ownership" must not be spelled the same way.
