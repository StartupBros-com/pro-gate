# pro-gate

**GPT-5.5 Pro Extended as an automated final-tier PR reviewer.**

ChatGPT's strongest reasoning model — **GPT-5.5 Pro / Pro Extended** — is *web-UI only* (no API) and
draws on a **separate usage pool** from the Codex CLI. `pro-gate` drives a logged-in ChatGPT session
headlessly (via [`steipete/oracle`](https://github.com/steipete/oracle)) to run that hidden model as
the **last, deepest review gate** on a pull request — after your cheaper/faster tiers have run — then
routes its findings to a fixer that applies them.

> The hidden best ChatGPT model reviews your PR, the findings get fixed automatically, and it never
> touches your coding-agent usage limits.

## What it does

```
   your earlier tiers (CE review / cloud review)  → fixes applied
                          │
                          ▼
        ┌──────────────────────────────────────────────┐
        │  pro-gate (final tier)                        │
        │  1. assemble: gh pr diff + files + PR url      │
        │  2. usage + session + concurrency guardrails   │
        │  3. GPT-5.5 Pro Extended review (via oracle)   │   ← the hidden web-only model
        │  4. parse P0–P3 findings + VERDICT             │
        │  5. fix confirmed P0/P1 → push                 │   ← CE → codex → Claude Code (best available)
        │  6. post the review as a PR comment            │
        │     …stop before merge (you merge)             │
        └──────────────────────────────────────────────┘
```

Two surfaces, one engine:
- **Interactive** — `/pro-gate <pr>` in any Claude Code session.
- **Set-and-forget** — a daemon watches for PRs labeled `pro-review` and runs the pipeline unattended.

## Requirements

- A **ChatGPT Pro** account (for Pro Extended), signed into a browser the tool can drive
- [`oracle`](https://github.com/steipete/oracle) (`pnpm add -g @steipete/oracle`)
- A coding agent to apply fixes — Claude Code (always works); Codex CLI / Compound Engineering used
  automatically if present (cheaper)
- `gh` (authenticated), `git`, `jq`, `flock`

## Quickstart

```bash
git clone https://github.com/StartupBros-com/pro-gate && cd pro-gate
./install.sh                 # skill + engine (+ daemon on Linux; INSTALL_DAEMON=1 to add it on macOS)
~/.pro-review-daemon/pro-gate-doctor.sh   # verify setup
```

### macOS (oracle native — simplest)
Oracle reuses your **signed-in Chrome** (Keychain cookie sync) — no Xvfb, no background service for
interactive use.
1. `./install.sh`
2. Open Chrome → sign into `chatgpt.com` (ensure **GPT-5.5 Pro** is selectable and **Settings → Apps →
   GitHub** connector is enabled).
3. `pro-gate-doctor.sh` → then `/pro-gate <pr>`.
4. (optional) `INSTALL_DAEMON=1 ./install.sh` to add the launchd watcher.

### WSL2 / Linux (headless Chrome under Xvfb)
1. `./install.sh` (installs `oracle-chrome.service` + the daemon via systemd).
2. `~/.pro-review-daemon/login-view.sh` → open `http://localhost:6080/vnc.html`, sign into ChatGPT Pro.
3. `pro-gate-doctor.sh` → then `/pro-gate <pr>`.

Set **`PRO_REVIEW_OWNERS`** in `~/.pro-review-daemon/.env` before using the daemon. See
`docs/SETUP-NOTES.md` for mechanics + gotchas.

## Usage

```bash
/pro-gate <pr-number-or-url>            # interactive, any Claude Code session
gh pr edit <n> --add-label pro-review   # set-and-forget: daemon reviews → fixes → comments → stops before merge
```

**Controls:** `touch ~/.pro-review-daemon/PAUSE` to pause the daemon; logs in `~/.pro-review-daemon/logs/`.

## Components

| Path | What it is |
|---|---|
| `lib/pro-gate-lib.sh` | Platform detection (macOS/WSL/Linux), browser-mode, path/dep helpers |
| `bin/oracle-review.sh` | **The engine** — assembles context, runs Pro Extended via oracle, returns findings. `flock`-serialized. |
| `bin/pro-gate-doctor.sh` | One-command setup verification |
| `skills/pro-gate/SKILL.md` | The `/pro-gate` skill (interactive) |
| `agents/oracle-reviewer.md` | Soft-fail launcher agent |
| `daemon/daemon.sh` | The label-gated watcher (per-SHA idempotent, cost/failure caps) |
| `daemon/run-oracle-chrome.sh` | WSL/Linux durable Xvfb Chrome (CDP) |
| `daemon/*.service.tmpl`, `*.plist.tmpl` | systemd / launchd templates rendered by `install.sh` |
| `install.sh` | Cross-platform installer |
| `.env.example` | All tunables |

## Safety & scale

- **Concurrency:** oracle has no cross-process limit, so the engine holds a `flock` — many concurrent
  `/pro-gate` calls **queue and run one-at-a-time** against the single ChatGPT account. True
  parallelism needs more ChatGPT accounts (one Chrome profile each).
- **False positives:** every finding must cite `file:line`; an explicit "do not flag" list suppresses
  style/CI-enforced/generated/pre-existing/speculative noise.
- **Cost:** the daemon's headless `claude -p` runs carry `--max-budget-usd` + a fallback model; a
  per-PR failure cap prevents poison-PR retry loops.
- **Merge authority:** the daemon **never merges** — it stops after pushing fixes and commenting.

## Roadmap

- [ ] Guarded auto-merge (opt-in: CI-green + no unresolved P0/P1 + high-risk-diff escalation)
- [ ] Real-macOS validation of the native path (designed; needs a Mac to confirm)
- [ ] Optional: structured JSON findings, OTEL telemetry, push-blocking test hook

## License

MIT — see [LICENSE](LICENSE).
