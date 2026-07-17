# pro-gate

**The frontier ChatGPT Pro reasoning model as an automated final-tier PR reviewer.**

ChatGPT's strongest reasoning model, its **web-only Pro tier**, is *web-UI only* (no API) and
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
        │  3. final-tier Pro review (via oracle)         │   ← the hidden web-only model
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

- A **ChatGPT Pro** account (for the Pro reasoning tier), signed into a browser the tool can drive
- [`oracle`](https://github.com/steipete/oracle) (`pnpm add -g @steipete/oracle`)
- A coding agent to apply fixes — Claude Code (always works); Codex CLI / Compound Engineering used
  automatically if present (cheaper)
- `gh` (authenticated), `git`, `jq`, `flock`

## Quickstart

Install the `pro-gate` marketplace plugin first. The plugin is the sole owner of the skill and
agent. Then install the runtime from the same exact promoted release:

```bash
VERSION=<plugin-version>
curl -fsSL "https://raw.githubusercontent.com/StartupBros-com/pro-gate/v${VERSION}/install.sh?$(date +%s)" \
  | bash -s -- --version "$VERSION"
PRO_GATE_EXPECTED_VERSION="$VERSION" ~/.pro-review-daemon/pro-gate-doctor.sh
```

The runtime installer never copies skill or agent files. It verifies the exact release archive and
checksum, records the installed version, and leaves the daemon off on every platform.

### Staying current (opt-in auto-update)

The plugin updates itself through the marketplace; the privileged runtime deliberately does not.
By default a version skew fail-closes (the skill and daemon refuse to run and print the exact
installer command). To automate that last step on a box you control:

```bash
VERSION=<plugin-version>
curl -fsSL "https://raw.githubusercontent.com/StartupBros-com/pro-gate/v${VERSION}/install.sh?$(date +%s)" \
  | bash -s -- --version "$VERSION" --auto-update
# NOTE: every non---skip-services install reconciles daemon enablement; if the daemon is
# enabled on this box, include --daemon too or it will be disabled.
```

This enables an hourly systemd timer that reads the ACTIVE plugin version from Claude Code's
`installed_plugins.json` and, on skew, downloads that exact release's checksum-verified archive
and runs the verified archive's own installer with `--skip-services` (no sudo, no service
changes: daemon and timer enablement are untouched by construction; the daemon adopts new code
at its next idle self-reload). The runtime follows the marketplace promotion, never `latest`,
so it cannot race ahead of what the release train validated. An enabled daemon with stale
dangerous-mode consent blocks the auto-update loudly instead of proceeding. Three consecutive
failures are flagged by `pro-gate-doctor.sh`. Disable any time with `--no-auto-update`. Audit
trail: `~/.pro-review-daemon/logs/autoupdate.log`.

Rollbacks below v0.23 are a deliberate manual act: the updater refuses them (their installers
predate `--skip-services`), and you must run `install.sh --no-auto-update` FIRST, since a
pre-v0.23 runtime cannot run this updater and the leftover timer would fail hourly.

### Release flow (maintainers)

Merging a PR that bumps `VERSION` + `plugin.json` ships it: `auto-release.yml` pushes the tag,
`release.yml` re-tests and publishes checksummed assets, and the release train promotes the
marketplace manifest. Requires a fine-grained `RELEASE_PAT` repo secret (contents: read/write);
without it the workflows fall back to the manual tag-push flow.

### macOS (oracle native, simplest)
Oracle reuses your **signed-in Chrome** (Keychain cookie sync), with no Xvfb or background service for
interactive use.
1. Install the plugin and exact matching runtime as above.
2. Open Chrome and sign into `chatgpt.com` (ensure your **Pro model** is selectable and **Settings → Apps →
   GitHub** connector is enabled).
3. Run the doctor, then `/pro-gate <pr>`.

### WSL2 / Linux (headless Chrome under Xvfb)
1. Install the plugin and exact matching runtime as above.
2. To opt into the daemon, review the disclosure and rerun the exact installer with
   `--daemon --accept-dangerous-mode`.
3. `~/.pro-review-daemon/login-view.sh` → open `http://localhost:6080/vnc.html`, sign into ChatGPT Pro.
4. Run the doctor, then `/pro-gate <pr>`.

Daemon activation and dangerous automatic-fixer mode require versioned operator consent stored under
`${XDG_CONFIG_HOME:-$HOME/.config}/pro-gate`, outside every target repository. The disclosure covers
automatic fixer execution with `--dangerously-skip-permissions`. A consent-version change requires
fresh acceptance. Remove legacy global copies under `~/.claude/skills/pro-gate` and
`~/.claude/agents/oracle-reviewer.md` so marketplace discovery exposes exactly one copy.

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
| `bin/oracle-review.sh` | **The engine**: assembles context, runs the Pro review via oracle, returns findings. `flock`-serialized. |
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
- **Convergence:** review→fix→re-review loops are bounded by default. The skill runs at most one
  confirming re-review per gate (`pro_gate_max_rounds: 2`), and the engine refuses to spend more
  than `PRO_GATE_MAX_ROUNDS_PER_PR` (default 4) Pro slots on one PR per rolling 24h (exit 12,
  no spend). Unresolved findings escalate to the human instead of looping for 8+ hours.
- **Merge authority:** the daemon **never merges** — it stops after pushing fixes and commenting.

## Roadmap

- [ ] Guarded auto-merge (opt-in: CI-green + no unresolved P0/P1 + high-risk-diff escalation)
- [ ] Real-macOS validation of the native path (designed; needs a Mac to confirm)
- [ ] Optional: structured JSON findings, OTEL telemetry, push-blocking test hook

## License

MIT — see [LICENSE](LICENSE).
