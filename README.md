# pro-gate

**GPT-5.5 Pro Extended as an automated final-tier PR reviewer.**

ChatGPT's strongest reasoning model — **GPT-5.5 Pro / Pro Extended** — is *web-UI only* (no API) and
draws on a **separate usage pool** from the Codex CLI. `pro-gate` drives a logged-in ChatGPT session
headlessly (via [`steipete/oracle`](https://github.com/steipete/oracle)) to run that hidden model as the
**last, deepest review gate** on a pull request — after your cheaper/faster tiers (CE review, cloud
review) have already run — then routes its findings to a fixer that applies them.

> The hidden best ChatGPT model reviews your PR, the findings get fixed automatically, and it never
> touches your coding-agent usage limits.

## What it does

```
  /ce-code-review  +  /code-review (cloud)   → fixes applied      ← your existing tiers
                          │
                          ▼
        ┌──────────────────────────────────────────────┐
        │  pro-gate (final tier)                        │
        │  1. assemble: gh pr diff + files + PR url      │
        │  2. usage + session + concurrency guardrails   │
        │  3. GPT-5.5 Pro Extended review (via oracle)   │   ← the hidden web-only model
        │  4. parse P0–P3 findings + VERDICT             │
        │  5. fix confirmed P0/P1 (codex) → push         │
        │  6. post the review as a PR comment            │
        │     …stop before merge (you merge)             │
        └──────────────────────────────────────────────┘
```

Two surfaces, one engine:
- **Interactive** — `/pro-gate <pr>` in any Claude Code session.
- **Set-and-forget** — a daemon watches for PRs labeled `pro-review` and runs the pipeline unattended.

## Components

| Path | What it is |
|---|---|
| `skills/pro-gate/SKILL.md` | The `/pro-gate` Claude Code skill (interactive entry point) |
| `agents/oracle-reviewer.md` | Thin, soft-fail launcher agent that runs the review |
| `bin/oracle-review.sh` | **The engine** — assembles context, runs GPT-5.5 Pro Extended via oracle, returns findings. Single source of truth for the oracle call. Serializes concurrent runs via `flock`. |
| `daemon/daemon.sh` | The set-and-forget watcher (label-gated, per-SHA idempotent, cost/failure caps) |
| `daemon/run-oracle-chrome.sh` + `oracle-chrome.service` | Durable logged-in headless Chrome (Xvfb + CDP on `127.0.0.1:9222`) |
| `daemon/run-daemon.sh` + `pro-review-daemon.service` | systemd wrapper + unit for the daemon |
| `daemon/login-view.sh` | One-time noVNC view to sign into ChatGPT |
| `oracle/config.json` | Oracle browser defaults |
| `.env.example` | All tunables (copy to `~/.pro-review-daemon/.env`) |
| `docs/SETUP-NOTES.md` | Hard-won setup notes + gotchas |

## Requirements

- A **ChatGPT Pro** account (for Pro Extended) signed into a browser the tool can drive
- [`oracle`](https://github.com/steipete/oracle) (`pnpm add -g @steipete/oracle`)
- A coding agent to apply fixes — Claude Code and/or Codex CLI
- `gh` (authenticated), `git`, `jq`, `flock`
- **Platform:** this snapshot targets **WSL2** (headless Chrome under Xvfb). On **macOS** oracle's
  browser mode is native (it reuses your logged-in Chrome) — no Xvfb/systemd needed; a Mac-native
  install path is a planned follow-on (see Roadmap).

## Setup (WSL2)

```bash
./install.sh            # deploys files, installs oracle, sets up the durable Chrome session
# then sign in once:
~/.pro-review-daemon/login-view.sh   # open http://localhost:6080/vnc.html, log into ChatGPT Pro
```

See `docs/SETUP-NOTES.md` for the exact mechanics and the gotchas (why `--remote-chrome` not
`--browser-attach-running`, the WSL Chrome flags, cookie-error tolerance, etc.).

## Usage

```bash
# Interactive — in any Claude Code session:
/pro-gate <pr-number-or-url>

# Set-and-forget — label any watched PR:
gh pr edit <n> --add-label pro-review     # the daemon reviews → fixes → comments → stops before merge
```

**Controls:** `touch ~/.pro-review-daemon/PAUSE` to pause the daemon; logs in `~/.pro-review-daemon/logs/`.

## Safety & scale

- **Concurrency:** oracle has no cross-process limit in `--remote-chrome` mode, so the engine holds a
  `flock` — many concurrent `/pro-gate` calls **queue and run one-at-a-time** against the single
  ChatGPT account. Safe; serialized. True parallelism needs more ChatGPT accounts (one Chrome
  profile/port each).
- **False positives:** every finding must cite `file:line`; an explicit "do not flag" list suppresses
  style/CI-enforced/generated/pre-existing/speculative noise.
- **Cost:** headless `claude -p` runs carry `--max-budget-usd` + a fallback model; a per-PR failure cap
  prevents poison-PR retry loops.
- **Merge authority:** the daemon **never merges** — it stops after pushing fixes and commenting.

## Roadmap

- [ ] Mac-native install path (oracle browser mode, no Xvfb/systemd)
- [ ] Generalize hardcoded paths/owners for portability (distributable to others)
- [ ] M3: guarded auto-merge (opt-in: CI-green + no unresolved P0/P1 + high-risk-diff escalation)
- [ ] Optional: structured JSON findings, OTEL telemetry, push-blocking test hook

## Status

Working and validated end-to-end on real PRs. This snapshot is **environment-specific to the author's
WSL setup** (hardcoded paths/owner) — versioned as the source of truth before generalization.
