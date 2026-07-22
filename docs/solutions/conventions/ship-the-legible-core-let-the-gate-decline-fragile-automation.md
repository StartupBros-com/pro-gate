---
title: "Ship the legible core; let the terminal gate decline fragile automation"
module: "pro-gate"
date: "2026-07-22"
problem_type: "convention"
component: "development_workflow"
severity: "medium"
tags:
  - "pro-gate"
  - "terminal-review-gate"
  - "dogfooding"
  - "distributable"
  - "ship-vs-defer"
  - "engineering-judgment"
---

# Ship the legible core; let the terminal gate decline fragile automation

## Context

During the v0.24.x pro-gate releases, three "nice-to-have" *automation* additions were each
built, run through the terminal Pro-model review gate (`/pro-gate` on its own PRs), and then
**dropped** after the gate repeatedly returned `FIX-FIRST`, each round surfacing *new, deeper*
real problems:

- **OOM auto-recovery self-heal** (PR #36): two rounds. Round 1 found capture-too-late,
  exit-3-destroys-a-live-review, harvest-truncates-URL, and a finalization bypass. Round 2 (after
  a rework) found the URL must live in the marker-keyed reservation, a non-monotonic salvage state
  machine that could lose a live review or double-spend, and per-attempt detection gaps.
- **macOS launchd auto-update timer** (PR #38): two rounds, six findings: opt-out persistence,
  GNU-only `sort -V`, non-atomic plist swap, then cross-version rollback survival, fail-open
  reconciliation, and concurrency-unsafe temp files. This one was even validated on real macOS via
  a `ssh mac-mini` harness, and *still* got `FIX-FIRST` on the deeper class the harness can't reach.
- **A Claude-Code-plugin-bug remediation hint** (PR #42): three rounds. The gate caught that a
  well-intentioned "help" message misdiagnosed the cause and recommended a **broken, destructive
  command** (`/plugin uninstall && /plugin install` chained with shell `&&` between slash commands,
  hitting CC uninstall defects), then wrong reinstall/relaunch ordering, then a verification step
  that could *falsely report success*.

Meanwhile the **legible core** of each release (clear failure messaging, up-front memory defers,
and the direction-aware version-mismatch precheck) passed the gate and shipped cleanly as v0.24.0
and v0.24.1.

## Guidance

1. **Treat repeated `FIX-FIRST` on one feature as a convergence signal, not a to-do list.** When a
   terminal review keeps finding *new* real problems across 2+ rounds, that is evidence the feature
   is inherently hard to get right: drop it and ship the legible core. The pro-gate skill itself
   documents that review, fix, re-review loops do not converge (10-16 rounds observed on one
   change). Do not grind the loop.

2. **For a distributable or credentialed tool serving non-technical users, prefer manual + legible
   guidance over fragile automation.** "Tell the user clearly what happened and the one action to
   take" beats "silently do something clever", especially for anything touching credentials, the
   user's quota, or their environment. A background job that reinstalls a credentialed runtime, or
   a message that pastes a destructive command, is a liability a missing feature is not.

3. **Dogfood the terminal gate on its own PRs.** Running `/pro-gate` on pro-gate's own changes
   repeatedly caught real bugs before they reached customers, and caught a "help" message that
   would have sent users to a destructive command. The gate reviewing the gate is the compounding
   loop working.

4. **Dropping is not abandoning: bank the findings.** Each declined feature became a scoped
   follow-up issue with the gate's findings as the *spec* (self-heal to #35, launchd timer to #39
   with the mac-mini harness noted, hint folded into the architectural fix #41). The review rounds
   are durable leverage for whoever builds it correctly later.

## Why This Matters

Shipping fragile automation into a distributable erodes user trust worse than shipping without the
feature. The gate's persistence is a signal about a feature's *inherent difficulty* (cross-version
rollback, failure modes, concurrency, interacting upstream bugs), not pedantry. Grinding a
non-converging review loop burns review budget and risks shipping subtly-broken customer-facing
code, which is exactly what the gate exists to prevent. The net of the v0.24.x arc: two clean
releases shipped, three fragile additions declined *because the gate found real problems*, and
every decline left a spec'd follow-up.

## When to Apply

- Any distributable, plugin, or credentialed tool where correctness and simplicity outrank feature
  breadth for the target (non-technical) users.
- Any time a terminal review (or an equivalently rigorous check) keeps finding *new* real issues in
  a single addition across 2 or more rounds.
- Deciding ship-vs-defer on a "nice-to-have" that is proving disproportionately hard relative to its
  benefit, especially automation that acts on the user's behalf.

## Examples

| Declined (gate found real problems) | Shipped (legible core, gate-clean) |
| --- | --- |
| OOM self-heal auto-recovery (PR #36, issue #35) | v0.24.0: cook-and-harvest + low-memory OOM *messaging* |
| macOS launchd auto-update timer (PR #38, issue #39) | v0.24.1: direction-aware version-mismatch precheck |
| CC-plugin-bug remediation *hint* (PR #42, folded into #41) | (the v0.24.1 precheck already gives the correct core guidance) |

The recurring shape: build the automation, let the gate stress it, and when it keeps failing, ship
the *message* that tells the user what to do and defer the *machine* that tries to do it for them.
