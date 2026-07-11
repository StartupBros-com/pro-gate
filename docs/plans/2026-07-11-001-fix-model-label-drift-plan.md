---
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
title: De-version pro-gate model labels - Plan
date: 2026-07-11
---

# De-version pro-gate model labels - Plan

## Goal Capsule

- **Objective:** Stop the pro-gate stack from asserting a stale model version ("GPT-5.5 Pro Extended") anywhere. The model that actually runs should follow the account automatically, and the only place a real version ever appears should be captured from the run itself, never hand-written.
- **Product authority:** Will, operator and maintainer of pro-gate.
- **Open blocker (feasibility):** Whether oracle emits its resolved model name in a greppable form under `PRO_GATE_MODEL_STRATEGY=current`. Confirmed for `select` mode (`resolved=Pro Extended` in `docs/SETUP-NOTES.md`); unverified for `current`. If `current` is silent, the runtime-truth layer degrades to role-based text and the downgrade warning cannot fire. This must be checked before building Layer 2.

## Product Contract

### Primary actor

The pro-gate operator and any human reading a pro-gate review (the PR-comment audit trail, the review header, the run ledger, the logs). They currently see a specific model version that may not be the one that answered.

### Problem

The literal string "GPT-5.5 Pro Extended" is copy-pasted across the whole pro-gate stack: the review prompt, log messages, the agent and skill descriptions, README, install help, daemon prompt, and setup notes. None of it can know the true model, and it drifts the moment the model changes or `strategy=current` lets the ChatGPT UI's selected model win. The installed `~/.claude` copies are plain `cp` duplicates of the repo files, which is why "most of the agents" repeat the same stale claim.

The string is not one thing. Three distinct tokens hide behind the same text and must be treated differently:

1. **The functional selector** (`-m gpt-5.5-pro`, `ORACLE_MODEL`, `bin/oracle-review.sh:44,321`): actually picks the model.
2. **The prompt role line** (`bin/oracle-review.sh:189`): instructs the model to act as "GPT-5.5 Pro Extended."
3. **Descriptive prose** (README, `skills/pro-gate/SKILL.md`, `agents/oracle-reviewer.md`, `docs/SETUP-NOTES.md`, `install.sh`, `daemon/*.sh`, and comments/log lines in `bin/oracle-review.sh`): describes the model to humans.

A blind find-replace across all three would corrupt the selector flag and flatten the prompt role. The fix must keep them separate.

### Desired outcome

No descriptive prose in the pro-gate stack names a model version. Runs follow the account's Pro model with no literal to bump. Where a specific model genuinely appears (the review header, the PR comment, the ledger), it is the model oracle actually resolved for that run, captured at runtime, or role-based fallback text if capture is unavailable. Reinstall propagates the change to the `~/.claude` copies with no residual stale strings.

### Scope

**In scope**

- **Layer 1, self-updating selector.** Make `PRO_GATE_MODEL_STRATEGY=current` the default (currently defaults to `select` at `bin/oracle-review.sh:411,413` and is commented in `.env.example:31`). Demote `ORACLE_MODEL=gpt-5.5-pro` to a fallback hint used only when strategy is `select`. Normal operation follows whatever Pro model the account has, so no version literal needs bumping when OpenAI ships the next Pro.
- **Layer 2, runtime truth.** Capture the model oracle resolved from `$RUNLOG` (reusing the grep pattern that already recovers the session slug at `bin/oracle-review.sh:441`) and render that real string into the review header, the PR-comment audit trail, the status lines, and the run ledger. On capture failure, fall back to role-based text, never a hardcoded version.
- **Layer 3, prose de-versioning.** Rewrite every descriptive occurrence to role-based language that names no version (for example, "OpenAI's frontier Pro reasoning model, web-UI-only, via the oracle bridge"). Targets: `README.md`, `skills/pro-gate/SKILL.md`, `agents/oracle-reviewer.md` (description and body, including the `## Pro Extended Review` header template), `docs/SETUP-NOTES.md`, `install.sh` help text, `daemon/daemon.sh` (comment and the dispatch prompt at line 145), `daemon/login-view.sh`, and the prompt role line plus log/comment lines in `bin/oracle-review.sh` (lines 2, 189, 410, 416, and surrounding comments).
- **Propagation.** Confirm `install.sh` reinstall overwrites the `~/.claude/skills/pro-gate/SKILL.md` and `~/.claude/agents/oracle-reviewer.md` copies so no stale string survives.
- **Recommended low-cost add: soft downgrade warning.** Since Layer 2 captures the resolved model, emit one WARN line and a visible marker in the PR-comment header when the resolved model does not look Pro-tier. Not a hard fail. This turns the accepted "weak model ran silently" risk into a caught one for a few lines of code.

**Out of scope**

- API-based model selection. The Pro tier is web-UI-only; the oracle browser bridge stays.
- Any change to the review pipeline, concurrency, ramp governor, or fixer routing.
- A hard downgrade guard that fails the run (explicitly declined; the soft warning is the chosen substitute).
- A recurrence lint (pre-commit/CI grep) and any sweep of `~/.claude` agents outside the pro-gate family (both considered and declined; scope is the pro-gate stack only).
- Keeping the functional `-m gpt-5.5-pro` selector as a hand-maintained pin. It becomes a fallback, not the primary path.

### Success criteria

- Grepping the pro-gate stack for model-version literals returns only the single functional selector default and dynamically-rendered runtime output. No descriptive prose matches.
- The PR comment and review header for a given run name the model oracle actually resolved for that run (verifiable against oracle's log), or role-based text when capture failed, never a stale literal.
- A new OpenAI Pro model release requires zero code or config changes for pro-gate to use it.
- After `install.sh` reinstall, `~/.claude/skills/pro-gate/SKILL.md` and `~/.claude/agents/oracle-reviewer.md` contain no model-version literal.
- (If the soft warning ships) A run whose resolved model is not Pro-tier produces a visible warning in the comment header.

### Assumptions

- Oracle reports the resolved model name in its log output under `strategy=current` (the load-bearing feasibility assumption; see Open blocker). If false, Layer 2 uses role-based fallback text and the soft warning is dropped.
- The `~/.claude` copies are always regenerated from the repo via `install.sh` (`cp`), so fixing the canonical repo files plus reinstalling is sufficient; there is no independent hand-edited copy to reconcile.
- Role-based prose that omits the version does not degrade review quality when it appears in the prompt role line at `bin/oracle-review.sh:189` (removing a possibly-wrong self-identification is expected to be neutral or better).

### Outstanding questions

- Under `strategy=current`, if oracle does not surface a resolved model name, is role-based text ("the terminal ChatGPT Pro model") acceptable in the header and comment, or is a lightweight secondary probe of the session's selected model warranted? Default assumption: role-based text is acceptable; no secondary probe.
- Exact role-based wording for the prompt role line versus the human-facing prose. They can differ (the prompt wants "you are the final, highest-tier reviewer"; the docs want a descriptive noun phrase). ce-plan to settle final strings.
