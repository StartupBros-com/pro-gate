---
title: "A stale branch's premise can be half-fixed underneath it, so neither rebase nor close is right"
module: "pro-gate"
date: "2026-09-11"
category: "conventions"
problem_type: "architecture_pattern"
component: "development_workflow"
severity: "medium"
applies_when:
  - "triaging a branch that has sat long enough for its target files to move"
  - "a conflict count is about to be used as the cost estimate for reviving a branch"
  - "deciding between rebasing a stale branch and closing it as superseded"
tags:
  - "pro-gate"
  - "stale-branch"
  - "triage"
  - "merge-conflict"
  - "review-workflow"
---

# A stale branch's premise can be half-fixed underneath it

## Context

Three pull requests had sat for five days or more. The obvious question was whether to close them:
their claims were old, their branches were behind, and their conflicts looked expensive.

That framing offers two answers, and for one of the three both were wrong. In the window it sat,
another pull request had landed on the same files and:

1. fixed **one of the roughly eight sites** the stale branch targeted,
2. **restructured** the file it patched — new helpers, a removed block, different call shapes, and
3. added a **test that contradicted** one of its hunks and the three assertions supporting it.

Rebasing would have silently reverted a deliberate, test-locked decision. Closing would have
discarded a real defect that was still live in the other seven sites. The correct move was neither:
re-derive the still-valid intent onto the new structure, and split the contested part out to its own
issue.

## The diagnostic

Before deciding a stale branch's fate, answer three separate questions. Age answers none of them.

**1. Is the defect still present?** Grep current default-branch state for the fix's distinguishing
symbols, not for the issue title. Absence of the symbol is evidence the fix never landed; presence
in *some* call sites is the interesting case, because it means someone fixed part of it.

**2. How expensive is the revival, in hunks?** `git merge-tree --write-tree <main> <head>` produces
a conflicted tree; count conflict markers per file rather than counting conflicting files. A file
count badly understates a restructure — one file can carry five independent hunks — and badly
overstates pure churn, where a "conflicting" file is one changelog line.

**3. Did the intervening work restructure the target, or merely move around it?** This is the
question that actually decides rebase-versus-re-derive. If the functions the branch patches still
exist in the same shape, a rebase is mechanical. If they were rewritten, the branch's diff is
expressed against a structure that no longer exists, and the diff is now a description of intent
rather than a patch.

## What the answers imply

- Defect present, structure intact, conflicts mechanical → **rebase and land**.
- Defect present, structure rewritten → **re-derive the intent onto the new structure**. Take the
  new code's shape and reapply the old change's *meaning*; do not replay its hunks.
- Defect present but the branch also carries a contested policy change → land the uncontested part,
  and **split** the contested part to an issue. A merge commit is the wrong place to settle a
  disagreement between two authors.
- Defect already fixed, or the branch's surface has been rewritten out from under it by several
  intervening changes → **close, keep the issue open, re-drive from current state**. Re-deriving
  from a clean base beats reconciling several sessions' edits to the same functions, especially when
  the branch touches contract schemas or digests that must be regenerated anyway.

## Applicability

The expensive case to recognise is the third question answering "restructured". Two branches in the
same batch as the example above got the opposite verdict for exactly that reason — the default
branch had been rewritten *around* them, including a file that had roughly tripled in size and a
contract schema whose digests and fixtures would need regenerating. Same age, same apparent
staleness, opposite correct action.

Claim expiry is worth checking in the same pass: a branch whose owning session's claim has lapsed is
unowned work, not someone else's work in progress, and can be taken over rather than coordinated
around.

## Related

- [[one-identity-check-two-error-biases]] — the contested policy that had to be split out of the
  branch in this example, rather than settled while resolving its conflicts.
