# pro-gate

[![CI](https://github.com/StartupBros-com/pro-gate/actions/workflows/ci.yml/badge.svg)](https://github.com/StartupBros-com/pro-gate/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

ChatGPT's strongest reasoning tier, the web-only Pro model, as an automated final review
gate on your pull requests.

```bash
claude plugin marketplace add StartupBros-com/hov-marketplace
claude plugin install pro-gate@hov
```

Then install the matching runtime (details in [Installation](#installation)):

```bash
VERSION=<plugin-version>
curl -fsSL "https://raw.githubusercontent.com/StartupBros-com/pro-gate/v${VERSION}/install.sh?$(date +%s)" \
  | bash -s -- --version "$VERSION"
PRO_GATE_EXPECTED_VERSION="$VERSION" ~/.pro-review-daemon/pro-gate-doctor.sh
```

## TL;DR

**The problem**: the deepest ChatGPT reasoning model, the Pro tier, exists only in the
chatgpt.com web UI. There is no API. It also draws on a usage pool separate from every coding agent
you run, so that capacity reviews nothing while you pay for it, and pasting diffs into a
browser by hand doesn't scale.

**The solution**: `pro-gate` drives a logged-in ChatGPT Pro browser session headlessly (via
[`steipete/oracle`](https://github.com/steipete/oracle)), sends it your PR as the last review
tier after your cheaper tiers have run, parses its P0–P3 findings, routes confirmed problems
to the best available fixer, and posts the review on the PR. It stops before merge. You merge.

### Why use pro-gate?

| Feature | What it does |
|---|---|
| Frontier-model reviewer | The web-only Pro reasoning tier, which no API exposes, reviews every gated PR |
| Separate usage pool | Reviews never touch Claude Code or Codex limits; daemon fixer runs carry a hard `--max-budget-usd` cap (default $5/PR) |
| Spend protection | Deferrals, oversized refusals, and round caps exit without spending a Pro slot; an interrupted run leaves a harvestable reservation instead of a wasted slot |
| Crash recovery | `--status` rediscovers any run from a bare PR number; `--harvest` collects a review the model was still writing when your session died |
| Verified provenance | Every run embeds a nonce the model echoes back on its verdict line; a capture that doesn't match the run is rejected, never silently accepted |
| Bounded loops | The review, fix, re-review loop continues only while findings strictly shrink; the engine's trajectory governor grants 3 rounds per change per rolling 24 h, earns +1 per shrinking re-review up to a hard ceiling of 8, and cuts a non-converging loop early |

### Quick example

```bash
# In any Claude Code session: review, fix, comment, stop before merge
/pro-gate 1292

# Or drive the engine directly
~/.pro-review-daemon/oracle-review.sh --pr 1292 --repo ~/SITES/myrepo --out /tmp/review.md

# Lost your terminal mid-review? Rediscover the run from nothing but the PR number
~/.pro-review-daemon/oracle-review.sh --status 1292

# The model was still thinking when your run timed out (exit 9)? Collect it; no new slot spent
~/.pro-review-daemon/oracle-review.sh --harvest pg-run-myrepo-1292-... --out /tmp/review.md

# Set-and-forget: the daemon reviews every PR you label
gh pr edit 1292 --add-label pro-review
```

## How a review runs

```
   your earlier tiers (CE review / cloud review)  → fixes applied
                          │
                          ▼
        ┌──────────────────────────────────────────────┐
        │  pro-gate (final tier)                        │
        │  1. assemble: gh pr diff + files + PR url     │
        │  2. usage + session + concurrency guardrails  │
        │  3. Pro review via oracle (nonce-bound run)   │  ← the web-only model
        │  4. capture / salvage / harvest the verdict   │  ← survives crashes + timeouts
        │  5. parse P0–P3 findings + VERDICT            │
        │  6. fix confirmed P0/P1 → push                │  ← CE → codex → Claude Code
        │  7. post the review as a PR comment           │
        │     …stop before merge (you merge)            │
        └──────────────────────────────────────────────┘
```

Two surfaces, one engine:

- **Interactive**: `/pro-gate <pr>` in any Claude Code session.
- **Set-and-forget**: a daemon watches for PRs labeled `pro-review` and runs the pipeline unattended.

Expect real wall time: p50 ≈ 23 min, p90 ≈ 47 min per review (measured over 723 runs,
July 2026). The Pro model spends that long reasoning; the engine is built around it.

## Design philosophy

- **Protect the spend.** A Pro slot is scarce: every exit either produced a review, spent
  nothing, or left a recoverable reservation. A run that dies mid-generation keeps its
  conversation reachable for 6 h so `--harvest` can collect it.
- **Fail closed, recover explicitly.** A plugin/runtime version skew blocks the run.
  Captures must echo the run's nonce. Unverifiable results are surfaced for manual
  recovery, never guessed at.
- **Review-only authority.** The gate never merges, and committed work stays on the branch
  at any stop; unresolved findings escalate to a human instead of triggering a revert.
- **One engine, thin surfaces.** The skill, the relay agent, and the daemon all call
  `oracle-review.sh`; caller contracts change in the same PR as the engine.

## Requirements

- A **ChatGPT Pro** account, signed into a browser the tool can drive
- [`oracle`](https://github.com/steipete/oracle): `pnpm add -g @steipete/oracle`
- A coding agent to apply fixes: Claude Code (always works); Codex CLI / Compound
  Engineering used automatically if present
- `gh` (authenticated), `git`, `jq`, `flock`

## Installation

### 1. Plugin (skill + agent)

```bash
claude plugin marketplace add StartupBros-com/hov-marketplace
claude plugin install pro-gate@hov
```

The plugin is the sole owner of the skill and agent. Remove any legacy copies under
`~/.claude/skills/pro-gate` and `~/.claude/agents/oracle-reviewer.md` so discovery exposes
exactly one.

### 2. Runtime (engine + doctor + daemon files)

Install from the same promoted release as the plugin:

```bash
VERSION=<plugin-version>
curl -fsSL "https://raw.githubusercontent.com/StartupBros-com/pro-gate/v${VERSION}/install.sh?$(date +%s)" \
  | bash -s -- --version "$VERSION"
PRO_GATE_EXPECTED_VERSION="$VERSION" ~/.pro-review-daemon/pro-gate-doctor.sh
```

The installer verifies the exact release archive and checksum, records the installed
version, never copies skill or agent files, and leaves the daemon off on every platform.
A plugin/runtime version skew fail-closes: the skill and daemon refuse to run and print the
exact installer command.

### 3. Browser session

**macOS (oracle native).** Oracle reuses your signed-in Chrome (Keychain cookie sync); no
Xvfb, no background service for interactive use. Open Chrome, sign into `chatgpt.com`,
confirm your Pro model is selectable and **Settings → Apps → GitHub** connector is enabled,
then run the doctor and `/pro-gate <pr>`.

**WSL2 / Linux (headless Chrome under Xvfb).** Run
`~/.pro-review-daemon/login-view.sh`, open `http://localhost:6080/vnc.html`, sign into
ChatGPT Pro once, then run the doctor and `/pro-gate <pr>`.

### Staying current (opt-in auto-update)

The plugin updates itself through the marketplace; the privileged runtime deliberately does
not. To automate that last step on a box you control:

```bash
VERSION=<plugin-version>
curl -fsSL "https://raw.githubusercontent.com/StartupBros-com/pro-gate/v${VERSION}/install.sh?$(date +%s)" \
  | bash -s -- --version "$VERSION" --auto-update
# Every non---skip-services install reconciles daemon enablement; if the daemon is enabled
# on this box, include --daemon too or it will be disabled.
```

This enables an hourly systemd timer that reads the active plugin version from Claude Code's
`installed_plugins.json` and, on skew, downloads that exact release's checksum-verified
archive and runs the verified archive's own installer with `--skip-services` (no sudo, no
service changes; the daemon adopts new code at its next idle self-reload). The runtime
follows the marketplace promotion, never `latest`, so it cannot race ahead of what the
release train validated. Three consecutive failures are flagged by `pro-gate-doctor.sh`.
Disable any time with `--no-auto-update`. Audit trail:
`~/.pro-review-daemon/logs/autoupdate.log`.

Rollbacks below v0.23 are a deliberate manual act: the updater refuses them (their
installers predate `--skip-services`), and you must run `install.sh --no-auto-update` FIRST:
a pre-v0.23 runtime cannot run this updater, and the leftover timer would fail hourly.

### Daemon (optional, consent-gated)

To opt into the unattended watcher, review the disclosure and rerun the exact installer with
`--daemon --accept-dangerous-mode`. Daemon activation and the automatic fixer's
`--dangerously-skip-permissions` mode require versioned operator consent stored under
`${XDG_CONFIG_HOME:-$HOME/.config}/pro-gate`, outside every target repository; a
consent-version change requires fresh acceptance. Set **`PRO_REVIEW_OWNERS`** in
`~/.pro-review-daemon/.env` before first use. Mechanics and gotchas:
[`docs/SETUP-NOTES.md`](docs/SETUP-NOTES.md).

## Usage

```bash
/pro-gate <pr-number-or-url>            # interactive, any Claude Code session
gh pr edit <n> --add-label pro-review   # daemon: review → fix → comment → stop before merge
touch ~/.pro-review-daemon/PAUSE        # pause the daemon; logs in ~/.pro-review-daemon/logs/
```

### Engine commands

`oracle-review.sh` is the single source of truth for "how we call oracle for a review":
the skill, the relay agent, and the daemon all go through it.

```bash
oracle-review.sh --pr <url|number> [--repo <dir>] [--input both|bundle|connector]
                 [--out <file>] [--timeout <dur>] [--extra-files <glob>]
oracle-review.sh --diff <patchfile> --repo <dir> [--pr <n>] ...   # review a local diff; pass --pr
                                                                  # too so budget/locks stay the PR's
oracle-review.sh --confirm <prior-review-file> ...                # confirming pass: verify every prior
                                                                  # P0/P1 RESOLVED or STILL-PRESENT first
oracle-review.sh --harvest <run-marker> --out <file>              # collect an exit-9 run; no new slot
oracle-review.sh --status [<pr|url|marker>] [--json]              # read-only run rediscovery: what runs
                                                                  # exist, what to harvest, rounds left
```

### Exit codes

| Code | Meaning | Slot spent? |
|---|---|---|
| 0 | Review ready (P0–P3 findings + `VERDICT:` line) | yes |
| 2 | Bad usage | no |
| 3 | Oracle/browser/CDP failure; run state kept | no |
| 4 | Repo not found | no |
| 5 | Diff fetch failed | no |
| 6 | Ran but captured no usable review. Check the status `detail`: an already-collected review must not be resubmitted; a genuine loss is safe to re-run | maybe |
| 7 | Per-change lock timeout (another run holds this change) | no |
| 8 | Deferred: box unfit, low memory, or throttle cooldown; retry later | no |
| 9 | In-progress: the model was still generating and the tab stays open. `--harvest` by marker; never submit a new review for it | yes |
| 11 | Oversized diff, past `PRO_GATE_DIFF_HARD_MAX` (default 25,000 lines): scope the payload | no |
| 12 | Round budget exhausted for this change's window: escalate to a human or set `PRO_GATE_FORCE_ROUND=1` for one deliberate extra run | no |

## Configuration

All tunables live in [`.env.example`](.env.example) with inline docs; the engine reads
`~/.pro-review-daemon/.env`. The ones most worth knowing:

| Variable | Default | What it controls |
|---|---|---|
| `PRO_REVIEW_OWNERS` | *(required for daemon)* | GitHub owners the daemon may watch |
| `PRO_REVIEW_MAX_BUDGET_USD` | `5` | Hard $ ceiling per PR for headless fixer runs |
| `PRO_GATE_ROUNDS_BASE` | `3` | Governor base grant of slot-spending reviews per change per window |
| `PRO_GATE_ROUNDS_CEILING` | `8` | Hard ceiling a shrinking-findings trajectory can earn up to (+1 per shrinking re-review) |
| `PRO_GATE_MAX_ROUNDS_PER_PR` | *(unset)* | Set to pin the legacy flat cap instead of the governor |
| `PRO_GATE_ROUNDS_WINDOW` | `24h` | The rolling window for that budget |
| `PRO_GATE_MAX_DIFF_LINES` | `6000` | Above this a run proceeds but usually lands in-progress → harvest |
| `PRO_GATE_DIFF_HARD_MAX` | `25000` | Above this the engine refuses (exit 11, no spend) |
| `PRO_GATE_MAX_CONCURRENCY` | `1` | Ceiling for parallel Pro chats; a ramp governor earns up to it on clean streaks |
| `PRO_GATE_RESERVATION_TTL` | `21600` | Seconds an in-progress run's capacity stays reserved (6 h) |
| `PRO_GATE_REQUIRE_NONCE` | `1` | Reject any capture that doesn't echo this run's nonce (`0` restores path-overlap matching) |
| `PRO_GATE_MODEL_STRATEGY` | `current` | Review with whatever Pro model the account has selected; the run reports the one it used |

## Repo map

| Path | What it is |
|---|---|
| `bin/oracle-review.sh` | **The engine**: assembles context, runs the review, captures/salvages/harvests the verdict |
| `bin/cdp-salvage.mjs` | CDP salvage: recovers a finished review straight from the browser when oracle's own capture fails |
| `bin/pro-gate-doctor.sh` | One-command setup verification (deps, versions, browser, consent) |
| `bin/pro-gate-stats.sh` | Ledger stats: clean rate, exits, per-PR history |
| `bin/pro-gate-autoupdate.sh` | The opt-in hourly skew-follower |
| `lib/pro-gate-lib.sh` | Platform detection, browser mode, locks, reservations, round budget |
| `skills/pro-gate/SKILL.md` | The `/pro-gate` skill, the authoritative caller guide |
| `agents/oracle-reviewer.md` | Thin relay agent for other pipelines |
| `daemon/daemon.sh` | Label-gated watcher (per-SHA idempotent, cost/failure caps) |
| `daemon/run-oracle-chrome.sh` | WSL/Linux durable Xvfb Chrome (CDP) |
| `install.sh` | Cross-platform installer (see flags in [Installation](#installation)) |

## Safety and scale

- **Concurrency**: oracle has no cross-process limit, so the engine holds a `flock`:
  concurrent calls queue one-at-a-time against the single ChatGPT account by default. An
  adaptive ramp can earn limited parallelism on clean streaks; true parallelism needs more
  ChatGPT accounts (one Chrome profile each).
- **False positives**: every finding must cite `file:line`; an explicit "do not flag" list
  suppresses style/CI-enforced/generated/pre-existing/speculative noise.
- **Convergence**: review→fix→re-review loops are governed by trajectory, not hope. The
  skill's default `converge` policy continues only while each round strictly narrows the
  findings (all prior P0/P1 resolved, fewer new ones) and stops on oscillation;
  `pro_gate_rounds_policy: bounded` restores a fixed ceiling. The engine independently
  enforces the per-change round budget (exit 12, no spend) — since v0.31 a trajectory-aware
  governor that earns rounds while open findings shrink and brakes early on churn.
- **Merge authority**: the daemon never merges; it stops after pushing fixes and commenting.

## Troubleshooting

### Doctor reports a plugin/runtime version skew

Run the installer line the error printed (it targets the plugin's exact version). If the
doctor says the *runtime* is ahead, update the plugin instead; the installer would
downgrade the runtime.

### Exit 9 (`in-progress`)

Not a failure. The slot is spent and the model is still writing; the run printed the exact
`--harvest` command. Collect with that (or find it later via `--status <pr>`). Never submit
a new review for the same change while the reservation lives; that would spend a second slot
on the same question.

### Exit 6 (`no usable review`)

This exit covers two different situations, so read the status `detail` before acting. `already-collected`
means the review exists (find it with `--status`; do not resubmit). A genuine loss is safe
to retry: re-running the identical `--pr` command is engine-enforced safe (a live
reservation redirects instead of double-spending). On a low-memory box this exit often means
the review browser restarted mid-run, so free memory first.

### Exit 3 / CDP unreachable (WSL2/Linux)

The durable Chrome is down. `systemctl --user start oracle-chrome` (or rerun
`login-view.sh` if the session was signed out), then retry; run state was kept.

### Exit 12 (`round-capped`)

The change used its review rounds for the window. Post the unresolved findings for a human
decision; a deliberate extra round is `PRO_GATE_FORCE_ROUND=1` on one invocation. Committed
fixes stay on the branch either way.

## Limitations

- **One account, one review at a time** by default: runs queue behind a lock, and a busy
  gate is latency-bound by the Pro model itself (p50 ≈ 23 min, p90 ≈ 47 min).
- **Coupled to the ChatGPT web UI.** UI changes have broken capture before; the salvage,
  harvest, and nonce layers exist to recover from exactly that, but a redesign can still
  require an engine update.
- **The macOS native path is designed but not yet validated on real hardware.** WSL2/Linux
  is where all production use has run.
- **No auto-merge**, by design. An opt-in guarded version (CI-green + no unresolved P0/P1)
  is on the roadmap.

## FAQ

### Does it consume my Claude Code or Codex budget?

No. Reviews spend ChatGPT Pro capacity, a separate pool. The daemon's headless fixer runs
bill API credits, capped by `PRO_REVIEW_MAX_BUDGET_USD` (default $5/PR).

### My session died mid-review. Is the slot wasted?

No. `oracle-review.sh --status <pr>` finds the run and prints the exact `--harvest` command;
harvesting collects the finished review without spending anything new. Reservations live 6 h.

### Which model does the reviewing?

Whatever Pro model your account has selected (`PRO_GATE_MODEL_STRATEGY=current`); every run
reports the model it actually used, and a weak-model guard refuses mini/nano/instant
resolutions.

### Can I run it without the daemon?

Yes. `/pro-gate <pr>` is fully standalone; the daemon only adds the label-triggered
unattended mode, and it is off until you opt in with versioned consent.

### Why drive a browser instead of calling an API?

The Pro reasoning tier has no API. The browser session is the only interface, so the
engine treats it as production infrastructure: locks, reservations, provenance nonces,
salvage, and a durable artifact store.

### How do I see what the gate has been doing?

`pro-gate-stats.sh` summarizes the ledger (clean rate, exit distribution, per-PR history);
`oracle-review.sh --status` shows live state; logs live in `~/.pro-review-daemon/logs/`.

## Release flow (maintainers)

Merging a PR that bumps `VERSION` + `plugin.json` ships it: `auto-release.yml` pushes the
tag, `release.yml` re-tests and publishes checksummed assets, and the release train promotes
the marketplace manifest and announces the release. Requires a fine-grained `RELEASE_PAT`
repo secret (contents: read/write); without it the workflows fall back to the manual
tag-push flow. A `## Highlights` bullet list at the top of a release body becomes the
announcement card's "What's new" section verbatim; otherwise the bullets are derived from
the auto-generated notes.

## Contributing

Issues and pull requests are welcome. For anything non-trivial, open an issue first so we
can agree on the approach before you spend time on it.

See [LICENSE](LICENSE) for terms.

## License

MIT; see [LICENSE](LICENSE).
