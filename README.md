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
to the best available fixer, and posts the review on the PR. The gate stops before merge; after
local verification and adversarial review are green, the surrounding agent may arm guarded squash
auto-merge, with required hosted CI on the exact head remaining the final authority.

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
# In any Claude Code session: review, fix, and comment; guarded auto-merge is a surrounding workflow effect
/pro-gate 1292

# Or drive the engine directly
~/.pro-review-daemon/oracle-review.sh --pr 1292 --repo ~/SITES/myrepo --out /tmp/review.md

# Recover an already-started review without a new slot; accepts a PR, URL, or exact marker
/pro-gate recover 1292
~/.pro-review-daemon/oracle-review.sh --recover <PR|URL|marker> --repo ~/SITES/myrepo --out /tmp/review.md

# Expert diagnostics: rediscover state from nothing but the PR number
~/.pro-review-daemon/oracle-review.sh --status 1292 --json

# Expert/degradation route: collect an exit-9 run directly; no new slot spent
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
        │  5. validate + durably save the verdict        │
        │  6. name/archive the marker-owned chat         │  ← only after durable success
        │  7. fix confirmed P0/P1 → push                 │  ← CE → codex → Claude Code
        │  8. post the review as a PR comment            │
        │     …stop before merge; surrounding gate may  │
        │        arm CI-gated squash auto-merge          │
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
  conversation reachable for 6 h so `--harvest` can collect it. If immutable proof later shows
  that review targets an old head or merged/closed PR, it remains charged and optionally
  collectable but stops occupying capacity.
- **Fail closed, recover explicitly.** A plugin/runtime version skew blocks the run.
  Captures must echo the run's nonce. Unverifiable results are surfaced for manual
  recovery, never guessed at.
- **Clean up only after durable success.** Remote-browser conversations get an exact,
  marker-owned title. Server archive and local tab close happen only after the validated
  review is readable from marker-addressed durable storage; failed and in-progress runs stay
  recoverable.
- **Review-only engine authority.** The gate never merges directly, and committed work stays on
  the branch at any stop. The surrounding agent may arm guarded squash auto-merge only after local
  verification and adversarial review are green; missing required CI or unresolved blocking
  findings prevent arming. Human-only effects remain human-controlled.
- **One engine, thin surfaces.** The skill, relay agent, and daemon share the runtime contract;
  caller contracts change in the same PR as the engine.

## Typed review-decision contract

The interactive skill and Oracle relay dispatch the runtime's closed `review-decision/v1` contract,
not independently inferred verdicts, phases, exit codes, recoverability, or round state. The
contract binds normalized facts and results to one of eight actions: collect an existing result,
recover existing work, run a granted review, fix findings, prepare matching evidence, stop, hand
off to the existing merge workflow, or ask a named product choice.

Only a named product choice can prompt; its answer is freshness-validated and never independently
authorizes a runtime effect. Missing, malformed, unknown, stale, or version/corpus-mismatched
decisions stop and show the exact matching runtime update path rather than starting a fresh review.
Raw review and repository text are untrusted adapter input and are never used as action policy.

This changes neither review provenance nor merge authority: the runtime remains the Oracle
transport and the gate stops before merge. A surrounding agent may arm guarded auto-merge only
after its own verification/review gates pass; exact-head required CI remains the final authority.

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
confirm your Pro model is selectable, then run the doctor and `/pro-gate <pr>`. The default
bundle-only delivery does not request the GitHub connector; enable it only for the explicit
connector-enabled opt-in below.

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
/pro-gate recover <PR|URL|marker>       # recover an existing review; never starts a fresh one
gh pr edit <n> --add-label pro-review   # daemon: review → fix → comment; surrounding agent owns guarded merge
touch ~/.pro-review-daemon/PAUSE        # pause the daemon; logs in ~/.pro-review-daemon/logs/
```

### Engine commands

`oracle-review.sh` is the single source of truth for "how we call oracle for a review":
the skill, the relay agent, and the daemon all go through it.

```bash
oracle-review.sh --pr <url|number> [--repo <dir>] [--input both|bundle|connector]
                 [--out <file>] [--timeout <dur>] [--extra-files <glob>]
                 # omitted --input follows PRO_GATE_INPUT_POLICY (bundle-only by default)
oracle-review.sh --diff <patchfile> --repo <dir> [--pr <n>] ...   # review a local diff; pass --pr
                                                                  # too so budget/locks stay the PR's
oracle-review.sh --confirm <prior-review-file> ...                # confirming pass: verify every prior
                                                                  # P0/P1 RESOLVED or STILL-PRESENT first
oracle-review.sh --brief <task-file> --diff <patch> --repo <dir>  # custom task body: spend the slot on an
                                                                  # analysis other than the default review
oracle-review.sh --recover <PR|URL|marker> [--repo <dir>] [--out <file>] [--timeout <dur>]
                                                                  # recover an existing run only; no fresh slot
oracle-review.sh --harvest <run-marker> --out <file>              # expert/degradation collection of an exit-9 run
oracle-review.sh --status [<pr|url|marker>] [--json]              # expert diagnostics: read-only rediscovery,
                                                                  # machine-readable with --json
```

`--brief` replaces the built-in reviewer persona with a task body you supply, so a Pro slot can be
spent on an analysis the engine does not otherwise ship — an architecture critique, a migration-risk
read, a security-only deep dive. It requires `--diff` and is **refused together with `--pr`**: round
budget, the per-change guard, supersession and recovery are all keyed on change identity, so a brief
sharing a PR's identity would spend that PR's rounds, serialize against the real review, and could be
handed back by `--recover <PR>` in place of it. Brief runs always take a diff-derived identity.

The engine appends its own contract footer — the findings format, the terminal `VERDICT:` line, and
the run marker — because the return path is review-shaped end to end: a capture is accepted only when
it carries a `[Pn]` marker and one of `SHIP | FIX-FIRST | NEEDS-DISCUSSION`, and the collector bounds
its extraction at the verdict line. An answer lacking that shape is discarded and its slot held until
recovery. So a brief inherits a severity-ranked-analysis contract: findings as `[P0]`–`[P3]`, and a
verdict reading as no-blockers / fix-these-first / needs-a-decision. Briefs are capped at 64 KiB;
attach bulk context with `--extra-files`.

Be precise about what that footer buys. It is a **cooperative contract, not an enforced one.** The
brief body and the footer are instructions at the same authority level, so a brief can request an
incompatible format, tell the model to disregard what follows, or simply dictate its own verdict —
verdict extraction greps the terminal line and cannot distinguish a reasoned verdict from a dictated
one. What makes this safe today is narrower than "the engine controls the shape": briefs are
operator-authored, and no typed decision path consumes a brief run's verdict, because `--brief` is
deliberately **not** exposed through the `pro-gate` skill or the relay agent. Treat that non-exposure
as a security boundary — wiring `--brief` into a surface that feeds `review-decision/v1` would make a
caller-authored `SHIP` reachable by the merge gate.

One trade-off of the required `--diff`-only form, unchanged from earlier versions and not specific to
briefs: `pg_run_meta_write` requires a PR number, so any run without `--pr` logs `could not persist
recovery charge metadata` and has degraded `--recover`. A brief run that ends in-progress is
harvestable by its exact marker but cannot be found by repository-qualified recovery.

`recover` accepts exactly one decimal PR number, canonical PR URL, or exact `pg-run-...` marker.
It selects an exact marker directly; a repository-qualified URL or PR number with canonical
repository proof selects the unique newest charged run. A bare PR without repository proof,
multiple repositories, tied candidates, or conflicting ordering returns disambiguation and takes
no action. Recovery first returns a verified completed artifact and otherwise performs only the
existing marker harvest; it never dispatches a `--pr` review, creates a new slot, or spends a new
round. For pre-v0.37 canonical run-meta whose reservation is missing, recovery reconstructs only
that original charged attempt's reservation and applies the existing TTL plus spaced exact-marker
miss proof in the same no-spend invocation. Before browser recovery, an immutable input binding plus
GitHub `MERGED`/`CLOSED` state or a different current head can move the reservation to `superseded`:
the charge, marker, URL, and optional audit harvest remain, while capacity and current-head ownership
are released. Historical reservations keyed as literal `diff` are canonicalized during that exact
transition only after immutable identity and charge agree. For pre-v0.31 empty spend fields, exact
immutable binding and canonical run metadata are revalidated under the reservation lock before the
proven charge is filled; marker mint time is not charge evidence. Other missing or mismatched proof
remains fail-closed.
Missing or malformed binding/GitHub proof leaves the review generating. Its plain states
are **Review ready**, **Checking for completed review**, **Still working**, **Review superseded**,
**No review remains**, and **Browser needs attention**. `Review superseded` means old-head or closed-PR
proof released capacity without refunding; `No review remains` means terminal proof released recovery
ownership. Re-query the typed decision instead of deleting state. A readable or open tab can be stale,
so the engine safely revalidates the canonical server conversation without changing the source tab.

Use direct `--status --json` and direct `--harvest` above for expert automation or degradation
diagnosis; ordinary callers should use `/pro-gate recover` instead.

### Exit codes

| Code | Meaning | Slot spent? |
|---|---|---|
| 0 | Review ready (P0–P3 findings + `VERDICT:` line) | yes |
| 2 | Bad usage | no |
| 3 | Oracle/browser/CDP failure; run state kept | no |
| 4 | Repo not found | no |
| 5 | Diff fetch failed | no |
| 6 | No usable current review. Check `detail`/`attempt`: recoverable work must be harvested; `not-submitted` was refunded; `submitted-terminal`, `recovery-exhausted`, or `superseded` remains charged but permits a fresh typed decision | maybe |
| 7 | Per-change lock timeout (another run holds this change) | no |
| 8 | Deferred: box unfit, low memory, or throttle cooldown; retry later | no |
| 9 | In-progress: the model was still generating and the tab stays open. `--harvest` by marker; never submit a new review for it | yes |
| 11 | Oversized diff, past `PRO_GATE_DIFF_HARD_MAX` (default 25,000 lines): scope the payload | no |
| 12 | An explicitly enabled round policy denied this change. Default unset configuration is advisory; inspect `--status` for policy source | no |

## Configuration

All tunables live in [`.env.example`](.env.example) with inline docs; the engine reads
`~/.pro-review-daemon/.env`.

### Input delivery policy

`PRO_GATE_INPUT_POLICY=bundle-only` is the safe default: omitted `--input` attaches the reviewed
diff as a bundle and Pro-Gate does not request connector delivery. To enable connector delivery,
make the one-time, explicit opt-in `PRO_GATE_INPUT_POLICY=connector-enabled`; omitted input then
uses `both`, while explicit `bundle`, `both`, and `connector` remain available. Any other nonempty
policy value is rejected before review setup. The daemon's `PRO_REVIEW_INPUT` is empty by default so
it inherits this policy; set it only for an explicit daemon-wide mode.

Bundle-only prevents Pro-Gate from requesting connector delivery but cannot attest to or revoke
external ChatGPT browser connector grants. Known connector-bound browser or project permissions
remain an operator trust boundary.

| Variable | Default | What it controls |
|---|---|---|
| `PRO_GATE_INPUT_POLICY` | `bundle-only` | `bundle-only` permits only bundled review input; `connector-enabled` opts into connector-capable input |
| `PRO_REVIEW_INPUT` | *(empty/inherit engine)* | Optional daemon-wide explicit `bundle`, `both`, or `connector` input mode |
| `PRO_REVIEW_OWNERS` | *(required for daemon)* | GitHub owners the daemon may watch |
| `PRO_REVIEW_MAX_BUDGET_USD` | `5` | Hard $ ceiling per PR for headless fixer runs |
| `PRO_GATE_ROUND_GUARD` | *(unset/advisory)* | Set `1` for hard trajectory enforcement; `0` forces advisory/off even when limit knobs exist |
| `PRO_GATE_ROUNDS_BASE` | `3` advisory | Computed base grant shown in status; explicitly setting it enables enforcement (`0` = lockdown) |
| `PRO_GATE_ROUNDS_CEILING` | `8` advisory | Computed trajectory ceiling; explicitly setting it enables enforcement |
| `PRO_GATE_MAX_ROUNDS_PER_PR` | *(unset)* | Explicit legacy flat-cap enforcement (`0` = lockdown) |
| `PRO_GATE_ROUNDS_WINDOW` | `24h` | The rolling telemetry/enforcement window |
| `PRO_GATE_MAX_DIFF_LINES` | `6000` | Above this a run proceeds but usually lands in-progress → harvest |
| `PRO_GATE_DIFF_HARD_MAX` | `25000` | Above this the engine refuses (exit 11, no spend) |
| `PRO_GATE_MAX_CONCURRENCY` | `1` | Ceiling for parallel Pro chats; a ramp governor earns up to it on clean streaks |
| `PRO_GATE_RESERVATION_TTL` | `21600` | Minimum age before confirmed exact-marker misses may exhaust recovery; elapsed time alone never releases it |
| `PRO_GATE_REQUIRE_NONCE` | `1` | Reject any capture that doesn't echo this run's nonce (`0` restores path-overlap matching) |
| `PRO_GATE_MODEL_STRATEGY` | `current` | Review with whatever Pro model the account has selected; the run reports the one it used |
| `PRO_GATE_CHAT_RENAME` | `1` remote / prompt-only native | Apply and verify the exact canonical PR/round title through ChatGPT's rendered UI |
| `PRO_GATE_CHAT_ARCHIVE` | `1` | Archive through ChatGPT's rendered UI only after marker-addressed durable exit-0 success |
| `PRO_GATE_KEEP_TABS` | `0` | Exact value `1` permits rename but suppresses both server archive and local tab close |
| `PRO_GATE_BROWSER_ARCHIVE` | `never` | Passed unchanged to Oracle; `auto`/`always` can archive before pro-gate validates durable recovery state |

### Conversation lifecycle

The remote-browser organizer never calls a ChatGPT backend API. It first proves the open or
remembered conversation carries this run's marker and not another run's completed answer, then
uses the visible menu, title input, save, and archive controls. UI drift is best-effort and cannot
change the review result.

| Remote outcome/configuration | Exact rename | Server archive | Local tab close |
|---|---:|---:|---:|
| Exit 0, readable marker-addressed durable result (defaults) | yes | yes | yes |
| Same, `PRO_GATE_CHAT_ARCHIVE=0` | yes | no | yes |
| Same, `PRO_GATE_CHAT_RENAME=0` | no | yes | yes |
| Same, `PRO_GATE_KEEP_TABS=1` | yes | no | no |
| Exit 3, 6, or 9 with a proven owned conversation | yes | no | no |
| Volatile-only result or ambiguous/foreign/cross-bound target | at most a proven safe rename | no | no |

Invalid values for the two new boolean controls warn and disable only that mutation. The older
`PRO_GATE_KEEP_TABS` and `PRO_GATE_BROWSER_ARCHIVE` surfaces keep their exact historical
semantics. Native mode keeps the prompt's title hint and does not run remote-CDP organization.

## Repo map

| Path | What it is |
|---|---|
| `bin/oracle-review.sh` | **The engine**: assembles context, runs the review, captures/salvages/harvests the verdict |
| `bin/cdp-salvage.mjs` | Marker-owned CDP salvage and conversation organizer: recover, exact-rename, archive, and local cleanup decisions |
| `bin/cdp-organizer-expressions.mjs` | Auditable ChatGPT UI expressions for exact rename and archive; no backend API calls |
| `bin/pro-gate-doctor.sh` | One-command setup verification (deps, versions, browser, consent) |
| `bin/pro-gate-stats.sh` | Ledger stats: clean rate, exits, per-PR history |
| `bin/pro-gate-autoupdate.sh` | The opt-in hourly skew-follower |
| `lib/pro-gate-lib.sh` | Platform detection, locks, canonical attempt lifecycle, reservations, terminal dispositions, round telemetry/policy |
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
- **Convergence**: identical code plus identical evidence never runs again. Round count,
  open-P0/P1 trajectory, churn, and elapsed time remain visible advice, but default unset
  configuration does not ration unobservable ChatGPT subscription capacity. Operators who need
  hard automation containment can explicitly enable the trajectory governor, flat cap, or lockdown.
- **Merge authority**: the daemon never merges directly; it stops after pushing fixes and
  commenting. The surrounding agent may arm squash auto-merge only after local verification,
  adversarial review, and required exact-head CI are green.

## Troubleshooting

### Doctor reports a plugin/runtime version skew

Run the installer line the error printed (it targets the plugin's exact version). If the
doctor says the *runtime* is ahead, update the plugin instead; the installer would
downgrade the runtime.

### Exit 9 (`in-progress`)

Not a failure. The slot is spent and the model is still writing; the run printed the exact
`--harvest` command. Collect with that (or find it later via `--status <pr>`). Never submit
a new review for the same change while the reservation lives; that would spend a second slot
on the same question. Its marker-owned conversation may already have the exact run title, but
it is deliberately neither archived nor closed.

### Exit 6 (`no usable review`)

Read `--status --json` before acting. A canonical `attempt` reports one truth: active/recoverable
work must be collected; `not-submitted` was positively proven and refunded; `submitted-terminal`
or `recovery-exhausted` retains its charge but no longer owns recovery; `superseded` retains its
charge and optional audit harvest but owns neither capacity nor the current head. Those settled states
let changed/current evidence receive a fresh typed decision. Unknown post-click fate stays recoverable.
Never delete state, quarantine files, or use a force flag as diagnosis. On a low-memory box, free
memory before retrying.

### Exit 3 / CDP unreachable (WSL2/Linux)

The durable Chrome is down. `systemctl --user start oracle-chrome` (or rerun
`login-view.sh` if the session was signed out), then retry; run state was kept.

### Exit 12 (`round-capped`)

This exit occurs only when an operator explicitly enabled round enforcement through the guard,
flat cap, governor values, or lockdown. Inspect `--status --json` for `rounds[].policy`. A deliberate
one-invocation override remains `PRO_GATE_FORCE_ROUND=1`; committed fixes stay on the branch.

## Limitations

- **One account, one review at a time** by default: runs queue behind a lock, and a busy
  gate is latency-bound by the Pro model itself (p50 ≈ 23 min, p90 ≈ 47 min).
- **Coupled to the ChatGPT web UI.** UI changes have broken capture before; the salvage,
  harvest, and nonce layers exist to recover from exactly that, but a redesign can still
  require an engine update.
- **The macOS native path is designed but not yet validated on real hardware.** WSL2/Linux
  is where all production use has run.
- **Auto-merge is surrounding-workflow authority, not a pro-gate effect.** Agents may arm guarded
  squash auto-merge after local verification and adversarial review are green; unresolved blocking
  findings or missing exact-head required CI prevent arming.

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

Merging a PR that bumps `VERSION` + `plugin.json` ships it, in two halves — the release is
**staged first and published second**, because the marketplace card has to name a release id
that only exists once the release does:

1. `auto-release.yml` pushes the tag; `release.yml` re-tests, packages and uploads
   checksummed assets, then leaves the release a **draft** and prints the repin tuple
   (plugin, version, sha, releaseId, releaseTag).
2. Open that repin PR against `StartupBros-com/hov-marketplace` and merge it. The card is
   updated by a reviewed PR and never by a push from CI — a standing credential able to
   write the distribution manifest is the one whose compromise reaches every installed
   client.
3. Run the **Publish staged release** workflow (or `gh release edit vX.Y.Z --draft=false`).
   It re-reads the live card and refuses unless the card names exactly this release, so a
   mistimed run cannot publish something undistributed.
4. Publishing fires the release train once: it verifies distribution and announces. The
   train only ever *reads* the marketplace — it holds no deploy credential.

Publishing before step 2 is what made every release fail its own distribution guard and need
an announce re-fire; that is why step 1 stops at a draft. Requires a fine-grained
`RELEASE_PAT` repo secret (contents: read/write); without it the workflows fall back to the
manual tag-push flow. A `## Highlights` bullet list at the top of a release body becomes the
announcement card's "What's new" section verbatim; otherwise the bullets are derived from
the auto-generated notes.

## Contributing

Issues and pull requests are welcome. For anything non-trivial, open an issue first so we
can agree on the approach before you spend time on it.

See [LICENSE](LICENSE) for terms.

## License

MIT; see [LICENSE](LICENSE).
