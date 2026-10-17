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

| Feature                 | What it does                                                                                                                                                                                                                                                                                                          |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Frontier-model reviewer | The web-only Pro reasoning tier, which no API exposes, reviews every gated PR                                                                                                                                                                                                                                         |
| Separate usage pool     | Reviews never touch Claude Code or Codex limits; daemon fixer runs carry a hard `--max-budget-usd` cap (default $5/PR)                                                                                                                                                                                                |
| Spend protection        | Deferrals, oversized refusals, and round caps exit without spending a Pro slot; an interrupted run leaves a harvestable reservation instead of a wasted slot                                                                                                                                                          |
| Crash recovery          | `--status` rediscovers any run from a bare PR number; `--harvest` collects a review the model was still writing when your session died                                                                                                                                                                                |
| Verified provenance     | Every run embeds a nonce the model echoes back on its verdict line; a capture that doesn't match the run is rejected, never silently accepted                                                                                                                                                                         |
| Round controls          | Numeric grants are advisory by default: 2 rounds per change per rolling 24 h, +1 per shrinking re-review, up to 8; explicit settings enforce those limits. A separate churn stop covers positive P0/P1 counts that fail to shrink for two consecutive re-reviews; clean and P2/P3-only rounds do not accumulate churn |

An accepted current `FIX-FIRST` with proven zero open P0/P1 and at least one deferred P2/P3 hands off to the existing merge workflow
with reason `fix-first-deferred-p2-only`. Its facts include `open_blocking: 0`,
`deferred_findings` (P2/P3 severity and complete finding blocks in body order) and `deferred_count`.
Each block is bounded to 1,024 characters, including any `… [truncated N chars]` marker.
Unsupported blocking severity forms leave counts unavailable and require a fix. A standalone
`P0` or `P1` line counts the explicit same-severity `[Pn]` findings that follow it after optional
blank lines; an empty section, prose, a fence, another severity, or an unbracketed `path:line` line after a
`RESOLVED` finding there leaves counts unavailable. A reopen marker anywhere in a finding, its `RESOLVED`
headline included, keeps it open. A FIX-FIRST
with zero blockers and no deferred findings requires a re-review with reason `fix-first-without-findings`.
Any open P0/P1 still requires a fix; `rounds-not-converging` preempts both paths.

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
  Final acceptance requires the whole bounded nonce with exact, case-sensitive spelling.
  Browser-side foreign-content conviction compares case-insensitively so a case-only near-match
  remains unbound and recoverable instead of being blacklisted as foreign. Unverifiable results
  are surfaced for manual recovery, never guessed at.
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

## Retained review facts

A standalone consumer can inspect retained accepted reviews through the installed runtime:

```bash
"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/oracle-review.sh" \
  --review-facts --repo /path/to/checkout --pr 1983 --json
```

`--pr` also accepts a canonical PR URL. A numeric PR uses the checkout's canonical `origin`.
This command reads existing records only: it does not submit, collect, repair, score, clean up,
query the network/browser, spend a round, or override a stop. Invalid fresh-review input or
attachment policy does not block inspection. It requires local `git`, `jq`, and a SHA-256 tool,
not a signed-in browser or private consumer parser.

Inspection defaults to the checkout's current HEAD. `--candidate-head <full-sha>` instead
selects an explicit revision without switching branches. Matching that SHA alone is not proof:
current applicability still requires the complete accepted input proof. The same optional flag
on `--prepare-review-evidence` requires the live PR to name that exact head; it is rejected by
review execution, continuation, recovery and status modes. The GitHub adapter supplies its
live-checked reviewed SHA, so recording also works from a default-branch checkout.

The additive JSON schema is `review-facts/v1`. Consumers should check `schema` and `status`,
allow additional fields, and treat unavailable facts as unavailable, not zero.

| Field                               | Meaning                                                                                                                                         |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `schema`                            | `review-facts/v1`                                                                                                                               |
| `status`                            | `accepted`, `missing`, `invalid`, `incomplete`, or `ambiguous`                                                                                  |
| `reason`                            | Selection, acceptance, or applicability explanation                                                                                             |
| `repository` / `pr`                 | Requested `{host, owner, repo}` and numeric PR                                                                                                  |
| `selected_marker`                   | Selected completion marker; `null` when no unique selection is proven                                                                           |
| `candidate_head`                    | Explicit `--candidate-head`, otherwise checkout's current HEAD or `null` if unavailable; separate from the reviewed revision                    |
| `applicable`                        | `true` for complete matching current proof; `false` for known different head/evidence; `null` when proof is unavailable                         |
| `review`                            | Accepted facts below, or `null` for every unaccepted result                                                                                     |
| `review.canonical_identity`         | SHA-256 of the canonical accepted result binding, including its supported predecessor contract identity                                         |
| `review.charged_spend_epoch`        | Recorded charge epoch used for completion ordering                                                                                              |
| `review.reviewed_head`              | Accepted input binding's reviewed revision                                                                                                      |
| `review.evidence_mode`              | Retained `full-pr`, `scoped-delta`, `connector`, or `caller-patch` mode                                                                         |
| `review.evidence_identity`          | `relation:<sha256>` of the complete canonical repository/target/evidence relation                                                               |
| `review.artifact_digest`            | SHA-256 of the accepted artifact bytes                                                                                                          |
| `review.verdict`                    | `SHIP`, `FIX-FIRST`, or `NEEDS-DISCUSSION`; independent of applicability                                                                        |
| `review.named_choice`               | Recorded result-binding choice, or `null`; not an owner-policy selection                                                                        |
| `review.named_choices`              | Accepted artifact's valid named `{id, label, consequence}` alternatives for any verdict; `[]` when absent, `null` when malformed or unavailable |
| `review.open_p0` / `review.open_p1` | Open severity counts from the accepted artifact, not mutable round tuples                                                                       |

Selection discovers possibly relevant completions before acceptance validation, using existing
completion/result records, input metadata, and charged run sidecars. It orders by charged epoch,
then proven canonical result identity. An unproved epoch, unresolved identity tie, or newest
relevant missing/corrupt/unreadable record obstructs selection; it does not fall back to older
favorable evidence. Records attributed to another repository/PR do not obstruct this target.
`missing` means no relevant completion; `incomplete` means a selected completion lacks a required
accepted record; `invalid` means acceptance or attribution failed; `ambiguous` means ordering is
unproved. Retained SHIP acceptance requires a full-PR/scoped result whose head, base, and raw
digest match its historical input binding; fabricated connector/caller-patch SHIP is unaccepted.
This does not require fresh metadata or proof. Unaccepted results expose no verdict or counts
(`review: null`). These states return exit 0 as inspection results; incompatible flags or invalid
CLI targets return usage exit 2.

Historical acceptance is independent of current proof. Matching HEAD without complete proof
leaves `applicable: null`; a known non-match yields `false`. To check current applicability,
reuse the existing proof inputs: `--diff` for the exact reviewed bytes,
`PRO_GATE_REVIEW_ENDPOINT_PATCH` for the retained/prepared endpoint patch, and
`PRO_GATE_REVIEW_PR_EVIDENCE` for its PR metadata snapshot. Scoped evidence also requires
`PRO_GATE_REVIEW_FILTER_MANIFEST` and `--confirm`. `--input bundle|both|connector` selects the
proof mode (inspection defaults to `bundle`, independently of fresh-delivery policy).
Head equality alone proves nothing current: metadata, endpoint/payload bytes, and scoped
manifest/confirmation must match. SHIP also requires its base/head/raw-digest relationships;
connector and caller-patch reviews cannot supply SHIP handoff applicability. The check is a
file-only observation of supplied proof, not a fresh remote PR read.

Only those proof inputs may accompany `--review-facts --repo --pr --json`. Review, recovery,
status, output, timing, preparation, and decision/effect flags are usage errors, even when an
incompatible flag has an empty value. Facts supply review truth, never merge authority or
continuation policy. An accepted historical SHIP is not a current SHIP; even applicable SHIP
leaves CI and merge policy to the consumer. Synthetic CLI tests prove these runtime contracts,
not live model quality, marketplace release/installation, or a live SHIP verdict.

## Optional GitHub status integration

The runtime includes `record-pro-gate-verdict.mjs`. From the PR checkout, record an accepted
review at its exact revision, then check the recorded status:

```bash
node "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/record-pro-gate-verdict.mjs" \
  --pr 1983 --verdict SHIP --reviewed-sha <full-sha> --evidence <review-url>
node "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/record-pro-gate-verdict.mjs" \
  --verify-for-merge --pr 1983
```

This adapter requires Node.js, authenticated `gh`, and the public facts command's local tools.
It runs from either the repository's `bin/` directory or the installed runtime, resolving the
public command beside itself. It needs no private repository, owner scripts, or browser access.

Record flags are assertions, not evidence. The adapter calls the public facts command and
requires accepted facts, `applicable: true`, the same repository/PR, matching candidate and
reviewed revisions, and the asserted verdict. Only a current, choice-free `SHIP` can record
`success`; accepted current `FIX-FIRST` and `NEEDS-DISCUSSION` record `failure`. Historical,
missing, corrupt, ambiguous, mismatched, or choice-bearing SHIP evidence cannot record success.
The evidence URL is the status link, not a substitute for accepted review evidence.
`--input bundle|both|connector` forwards the existing public proof mode (default `bundle`).
Accepted current connector progress can record a non-SHIP failure, never successful SHIP.

For fresh proof, recording invokes the existing `--prepare-review-evidence` command separately
from inspection. Its private temporary files are cleaned on completion or failure. You may
instead supply an existing explicit `PRO_GATE_REVIEW_ENDPOINT_PATCH` /
`PRO_GATE_REVIEW_PR_EVIDENCE` pair; the adapter snapshots that pair privately so metadata and
public inspection certify the same bytes. Either way, the proof's target must match the live PR
head and base repository/ref, and its base SHA must equal either the live branch tip or the PR's
own base snapshot (`base.sha`, which GitHub refreshes only when the PR syncs and which the daemon
binds completed reviews to). Both are read from GitHub at recording time, never from the proof; a
proof base matching neither is refused. The status records the base the review ran against, so
verification's overlap window runs from that reviewed base to the current tip and includes any
commits that landed between the PR's snapshot and recording. Head, base tip, and default branch
are checked again before posting exactly one status at the reviewed SHA.

Full-PR recording defaults the reviewed payload to the prepared endpoint patch. Scoped recording
must preserve its own reviewed payload and confirmation; it never substitutes full-PR bytes:

```bash
PRO_GATE_REVIEW_FILTER_MANIFEST=/path/to/manifest \
  node "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/record-pro-gate-verdict.mjs" \
    --pr 1983 --verdict SHIP --reviewed-sha <full-sha> --evidence <review-url> \
    --diff /path/to/reviewed.patch --confirm /path/to/prior-review.md
```

Verification requires a successful SHIP status on the current head, bound to the same base
repository/ref and the current default branch. It accepts an unchanged base, or an advanced
base whose changes do not overlap the PR's files; both sides of renames count. Missing or
ambiguous status reads, retargets, overlapping changes, and movement during rechecks refuse.
Exit 0 means a status was recorded (including an honest failure status), or an advisory check
passed. Exit 1 means recording/verification failed. Neither mode grants merge permission,
changes rulesets, readies a PR, or merges it. `--owner-state` is explicitly unsupported;
owner exceptions and merge policy remain downstream.

Downstream code can import `checkGitBaseAdvance(tree, originalBase, currentBase, head)` for the
same local-object comparison without reading statuses, fetching, or granting an exception.
`originalBase` accepts the recorded 12-character abbreviation or a full 40-character SHA;
`currentBase` and `head` require full SHAs. It returns a promise of
`{ok, unchanged, overlap, commitCount}` and rejects missing/ambiguous git objects.
`checkBaseAdvance({...})` exposes that comparison with the same SHA inputs and injectable
`getInterveningFiles`, `getPrChangedFiles`, and `getInterveningCommitCount` callbacks.
The callbacks must include both rename paths. This is a shared comparison utility, not an
owner-policy interface.

`createGitBaseAccess(tree)` supplies the matching `fetchBase(ref)` and
`getBaseTipSha(ref)` callbacks for callers that also need to refresh a base. Fetching
explicitly updates the same fully qualified remote-tracking ref that is read, even
when the checkout's configured fetch mapping excludes that branch. Call `fetchBase`
before each read and propagate failures; `getBaseTipSha` alone is a local read, not
proof of freshness. This helper adds no status or owner policy.

Synthetic tests exercise public acceptance and the local installed adapter with fake GitHub
requests. They do not prove live status posting, model review quality, a marketplace release,
or merge authorization. Version-matched release and private-consumer migration remain separate.

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
                                                                  # P0/P1/P2 RESOLVED or STILL-PRESENT first
oracle-review.sh --brief <task-file> --diff <patch> --repo <dir>  # custom task body: spend the slot on an
                                                                  # analysis other than the default review
oracle-review.sh --recover <PR|URL|marker> [--repo <dir>] [--out <file>] [--timeout <dur>]
                                                                  # recover an existing run only; no fresh slot
oracle-review.sh --harvest <run-marker> --out <file>              # expert/degradation collection of an exit-9 run
oracle-review.sh --status [<pr|url|marker>] [--json]              # expert diagnostics: read-only rediscovery,
                                                                  # machine-readable with --json
oracle-review.sh --prepare-review-evidence <new-dir> --pr <url|number> [--repo <dir>]
                                                                  # prepare PR proof; no review or charge
```

For typed bundle/scoped decisions, prepare evidence with the runtime rather than deriving the PR
base from the feature branch's upstream. `--prepare-review-evidence` writes `endpoint.patch` and
`pr-evidence.json` into a **new** directory and prints their absolute paths as JSON. It checks GitHub
metadata before and after fetching the comparison, and requires local HEAD to match the PR head.
The diff is fetched from GitHub's compare API using the **exact base and head commit IDs**, not the
mutable PR diff endpoint, which can lag a push even when PR metadata is already current. A retarget,
base-tip movement, or head change during preparation fails without submitting a review. The snapshot
records the GitHub base **tip and ref**, not a locally inferred merge-base; its format is
`github-compare-diff`, addressed as `BASE_OID...HEAD_OID`. Shallow and fork checkouts need no local
copy of the base commit when the PR URL identifies the target repository.

Pass the resulting files as `PRO_GATE_REVIEW_ENDPOINT_PATCH` and `PRO_GATE_REVIEW_PR_EVIDENCE`, with
`--diff` naming the reviewed payload. Full-PR proof requires byte-identical endpoint and reviewed
payloads; scoped review retains its separate payload, filtering manifest, and prior-review
confirmation. Missing scoped inputs never turn a partial payload into full-PR authority.
Proof-bound full/scoped runs retain those exact payload bytes through submission: automatic diff
hygiene does not remove generated or lockfile changes after preparation. Consequently a classic
`--pr` bundle review now includes the complete comparison. `PRO_GATE_DIFF_FILTER` still controls
ordinary caller-patch and brief reviews, which do not earn full-PR proof. The existing size limits
apply to the payload actually sent. Only a scoped delta review, which confirms an earlier full review,
can omit files through its manifest; a first review covers every change, so a PR whose generated
changes push it past the hard line limit must be split or run with a raised limit.
Keep those same inputs across query/effect. Advisory queries remain file-only; guarded effects check
GitHub again before a charge or result-binding repair. A query is not a live GitHub freshness check:
prepare current evidence again before the final merge-workflow handoff. Pro-gate never merges.

Older full/scoped bindings remain readable for exact-attempt recovery, but lack authoritative PR
metadata. At the same head they cannot grant current merge eligibility or automatically buy a
replacement review. Do not rewrite those immutable records to bypass the stop. Custom typed callers
must adopt the preparation command and both proof paths before upgrading; a raw patch alone now
returns `prepare-matching-review-evidence` rather than claiming a proven PR relation.

`--brief` replaces the built-in reviewer persona with a task body you supply, so a Pro slot can be
spent on an analysis the engine does not otherwise ship — an architecture critique, a migration-risk
read, a security-only deep dive. It requires `--diff` and is **refused together with `--pr`**: round
budget, the per-change guard, supersession and recovery are all keyed on change identity, so a brief
sharing a PR's identity would spend that PR's rounds, serialize against the real review, and could be
handed back by `--recover <PR>` in place of it. Brief runs always take a diff-derived identity.

The engine appends its own contract footer — the findings format, the terminal `VERDICT:` line, and
the run marker — because the return path is review-shaped end to end: a capture is accepted only when
it carries a `[Pn]` marker and one of `SHIP | FIX-FIRST | NEEDS-DISCUSSION`. Before publication or
replay, ownership validation rejects an answer that supplies authoritative verdicts for different
runs, in either order, including one verdict claiming two run markers. The ownership check leaves
accepted text untouched. Markers in ordinary prose and quoted, fenced, or indented verdict examples
are reference text; older conversation history before this run's prompt is outside the response.
Rejected captures remain available for diagnosis, and rejection does not release the charged run
or make a fresh review eligible after a timeout. Existing authoritative lifecycle proofs still
govern release. So a brief inherits a severity-ranked-analysis contract: findings as `[P0]`–`[P3]`, and a
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
are released. A classic `--pr` run reviewed against a caller-supplied `--diff` installs the same
kind of target-only binding and is reclaimable the same way once its bound head moves. A fresh run
that finds no free slot runs this same proof and transition on the exited runs holding capacity,
at most once per `PRO_GATE_RECONCILE_INTERVAL` and never while it holds the reservation guard, so
a merged, closed or moved-on PR's reservation no longer waits for someone to run `--recover`. The
slot-wait report still names `--recover` for a holder whose GitHub state could not be read. Historical
reservations keyed as literal `diff` are canonicalized during that exact
transition only after immutable identity and charge agree. For pre-v0.31 empty spend fields, exact
immutable binding and canonical run metadata are revalidated under the reservation lock before the
proven charge is filled; marker mint time is not charge evidence. Other missing or mismatched proof
remains fail-closed.
When ChatGPT's "Too many requests" modal covers the conversation, the probe reports it as
`throttled` rather than generating: the reservation keeps its miss count, the account cooldown
engages, reservation probes pause until it clears, and `--harvest` defers with exit 8 instead of
waiting out its window. A typed query during that cooldown returns `stop-without-new-review` /
`account-cooldown-active` with the seconds remaining in `facts.cooldown`. A modal that is not
this run's own is charged once per conversation-and-text fingerprint per seven days
(`PRO_GATE_THROTTLE_SEEN_TTL`, records under `throttle.cooldown.seen.d/`), so a stale notice
left on an abandoned tab cannot re-arm the cooldown on every attempt; a modal over the run's
own conversation always re-arms it.
When Oracle's own session record proves a fresh review's Send was never dispatched (an attachment
that never registered, for example), the required durable terminal disposition records the
attempt-time evidence relation, input mode, `PRO_GATE_BROWSER_ATTACHMENTS` and Oracle build before
refunding the round. It retains either a valid condition/count or an explicit unavailable state,
even if the optional legacy delivery sidecar cannot be written. If the disposition cannot be
published, charge and recovery ownership remain; interrupted cleanup can resume from the durable
record. Cleanup retries use that immutable published count and condition, even if the caller's
configuration has changed. Predecessor lookup excludes the current attempt before selecting
history, and an intervening sent attempt (including one later superseded) breaks the no-send
streak. Unknown-send attempts remain charged. These records prove no send, never delivery success.

After two failed deliveries in a row under one known condition (proven no-sends, or since v0.60.0
sends that produced no ChatGPT conversation), the typed query returns
`stop-without-new-review` / `delivery-failed-unchanged`. Unreadable history or an unknown current
build instead produces `delivery-state-unavailable`, with `facts.delivery.failed_unchanged: null`.
A proven change in relation, input, attachment policy, or a previously known Oracle build can
permit a new grant, subject to the other guards. Learning a formerly unknown build alone is not
proof of change. An operator's `PRO_GATE_FORCE_ROUND=1` can bypass the known repeated-failure
count; it cannot bypass unavailable evidence. A Cloudflare challenge records a separate
`not-applicable` delivery snapshot and remains governed by account cooldown.

Existing v1 delivery sidecars and `PRO_GATE_DELIVERY_CONDITION_DIR` remain supported. A v1
disposition with no sidecar is explicitly `legacy-untracked`, with a null count, and retains the
legacy admission behavior. In v0.58 and earlier, a failed or missing sidecar write is
indistinguishable from truly old untracked history or a Cloudflare refund. That absence cannot be
reconstructed as proof of changed conditions; new no-send dispositions retain the uncertainty.
Missing or malformed binding/GitHub proof leaves the review generating. Its plain states
are **Review ready**, **Checking for completed review**, **Still working**, **Review superseded**,
**No review remains**, and **Browser needs attention**. `Review superseded` means old-head or closed-PR
proof released capacity without refunding; `No review remains` means terminal proof released recovery
ownership. Re-query the typed decision instead of deleting state. A readable or open tab can be stale,
so the engine safely revalidates the canonical server conversation without changing the source tab.

Use direct `--status --json` and direct `--harvest` above for expert automation or degradation
diagnosis; ordinary callers should use `/pro-gate recover` instead.

Saved skeletons queried through `--review-decision` return a complete
`stop-without-new-review` envelope with reason `template-verdict` and execution class
`report-only` (typed-query exit 0). The rejected candidate in `.facts.completed_results`
names its marker and artifact digest, with `shape:"template-verdict"` and `applicable:false`.
Selection still uses newest charged epoch, then canonical identity: a newer grounded review
supersedes an older skeleton, while a newest skeleton stops. Preserve branch work and relay
the reason without inferring a retry. Identifiers in trailing unified-diff hunk context count
as reviewed vocabulary; a header without context contributes none, and nothing on the VERDICT
line does. A completion whose input binding predates retained vocabulary (contract digests
before v0.62.0) is judged on its own shape: grounded historical reviews stay accepted,
skeletons stay refused.

Since v0.64.0 a harvest that refuses a completed, current response also stops typed instead of
recovering it forever. The refusal itself is unchanged: a skeleton without a grounded diff
reference still exits 6, a review without the run-marker echo still exits 9, and the charge,
reservation and input binding are kept. What changes is evidence. When the CDP helper proved the
bytes it printed are the finished last assistant response after this attempt's marked prompt (no
generation running, no loading or busy marker in the answer's turn, finished-turn actions present,
identical text on a re-read about 2.5 s
later, and the same conversation URL as the attempt's memo), the harvest also writes one
write-once record (mode 0600) at `$PRO_GATE_HOME/rejected-captures/<marker>`. It binds the exact
bytes and their SHA-256 to the marker, charged epoch, input binding and conversation URL. The next
`--review-decision` then returns `stop-without-new-review` with reason `rejected-capture`
(`report-only`, exit 0). Its `.facts.completed_results` row has `shape:"rejected-capture"`,
`applicable:false` and the capture digest. The stop applies only while no other attempt is active
or holds the reservation. A newer applicable completion supersedes it, and other live work still
routes to recovery. The stop never resumes the attempt: a later vocabulary or classifier repair
leaves it stopped, an explicit `--harvest` may reinspect the conversation, and a collected,
accepted result then drives the decision. Anything short of that proof keeps today's recovery
path: a generating, unfinished, foreign or stale response, a changed re-read, or a missing or
invalid record.

### Exit codes

| Code | Meaning                                                                                                                                                                                                                              | Slot spent? |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- |
| 0    | Review ready (P0–P3 findings + `VERDICT:` line)                                                                                                                                                                                      | yes         |
| 2    | Bad usage                                                                                                                                                                                                                            | no          |
| 3    | Oracle/browser/CDP failure; run state kept                                                                                                                                                                                           | no          |
| 4    | Repo not found                                                                                                                                                                                                                       | no          |
| 5    | Diff fetch failed                                                                                                                                                                                                                    | no          |
| 6    | No usable current review. Check `detail`/`attempt`: recoverable work must be harvested; `not-submitted` was refunded; `submitted-terminal`, `recovery-exhausted`, or `superseded` remains charged but permits a fresh typed decision | maybe       |
| 7    | A wait for exclusive access expired: another run holds this change, every account slot is busy, or the reservation handoff guard could not be acquired. stderr names which, and no review is submitted in any of the three           | no          |
| 8    | Deferred: box unfit, low memory, or throttle cooldown (including ChatGPT's rate-limit modal over a live conversation); retry later                                                                                                   | no          |
| 9    | In-progress: the model was still generating and the tab stays open. `--harvest` by marker; never submit a new review for it                                                                                                          | yes         |
| 11   | Oversized diff, past `PRO_GATE_DIFF_HARD_MAX` (default 25,000 lines): scope the payload                                                                                                                                              | no          |
| 12   | An explicitly enabled round policy denied this change. Default unset configuration is advisory; inspect `--status` for policy source                                                                                                 | no          |

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

Connector delivery can drive fix rounds but never attests an allow. Merge eligibility binds the
bytes the engine delivered, and a connector observation carries no such proof, so a
connector-delivered `SHIP` reduces to `stop-without-new-review` with reason
`result-not-bindable-for-mode` (the facts name the mode and marker) rather than a merge handoff or
an endless collect. Use `bundle` or `both` for the final round.

| Variable                            | Default                           | What it controls                                                                                                                                                                                                                         |
| ----------------------------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PRO_GATE_INPUT_POLICY`             | `bundle-only`                     | `bundle-only` permits only bundled review input; `connector-enabled` opts into connector-capable input                                                                                                                                   |
| `PRO_REVIEW_INPUT`                  | _(empty/inherit engine)_          | Optional daemon-wide explicit `bundle`, `both`, or `connector` input mode                                                                                                                                                                |
| `PRO_REVIEW_OWNERS`                 | _(required for daemon)_           | GitHub owners the daemon may watch                                                                                                                                                                                                       |
| `PRO_REVIEW_MAX_BUDGET_USD`         | `5`                               | Hard $ ceiling per PR for headless fixer runs                                                                                                                                                                                            |
| `PRO_GATE_ROUND_GUARD`              | _(unset/advisory)_                | Set `1` for hard trajectory enforcement; `0` forces advisory/off even when limit knobs exist                                                                                                                                             |
| `PRO_GATE_ROUNDS_BASE`              | `2` advisory                      | Computed base grant shown in status; explicitly setting it enables enforcement (`0` = lockdown)                                                                                                                                          |
| `PRO_GATE_ROUNDS_CEILING`           | `8` advisory                      | Computed trajectory ceiling; explicitly setting it enables enforcement                                                                                                                                                                   |
| `PRO_GATE_MAX_ROUNDS_PER_PR`        | _(unset)_                         | Explicit legacy flat-cap enforcement (`0` = lockdown; invalid values fall back to `2`)                                                                                                                                                   |
| `PRO_GATE_ROUNDS_WINDOW`            | `24h`                             | The rolling telemetry/enforcement window                                                                                                                                                                                                 |
| `PRO_GATE_ROUNDS_CONTINUE`          | _(unset)_                         | Set `1` for the configured invocation to bypass churn while preserving enforced numeric limits, including exhausted and zero budgets. Stateless: there is no durable one-use counter. Cooldown, provenance and ownership still apply     |
| `PRO_GATE_MAX_DIFF_LINES`           | `6000`                            | Above this a run proceeds but usually lands in-progress → harvest                                                                                                                                                                        |
| `PRO_GATE_DIFF_HARD_MAX`            | `25000`                           | Above this the engine refuses (exit 11, no spend)                                                                                                                                                                                        |
| `PRO_GATE_MAX_CONCURRENCY`          | `1`                               | Ceiling for parallel Pro chats; a ramp governor earns up to it on clean streaks                                                                                                                                                          |
| `PRO_GATE_RESERVATION_TTL`          | `21600`                           | Minimum age before confirmed exact-marker misses may exhaust recovery; elapsed time alone never releases it                                                                                                                              |
| `PRO_GATE_DIRLOCK_ORPHAN_GRACE`     | `5`                               | No-flock platforms only: seconds an unmarked guard directory must sit before a reclaimer may remove it                                                                                                                                   |
| `PRO_GATE_BROWSER_MEM_PRESSURE_PCT` | `85`                              | Percent of the browser cgroup's effective limit (the smaller finite of `memory.high` and `memory.max`; `max` means unlimited) at which two consecutive samples arm the pressure sentinel and the health gate defers a slot with no spend |
| `PRO_GATE_BROWSER_MEM_SAMPLE_SECS`  | `5`                               | Seconds between browser cgroup samples                                                                                                                                                                                                   |
| `PRO_GATE_BROWSER_MEM_PRESSURE_TTL` | `60`                              | Seconds a pressure sentinel stays fresh; a stale or absent sentinel never defers a slot                                                                                                                                                  |
| `PRO_GATE_CGROUP_PATH`              | _(read from `/proc/self/cgroup`)_ | Browser cgroup directory to sample; absent, unreadable or unlimited (`max`) files mean no pressure, never a refusal                                                                                                                      |
| `PRO_GATE_TIMEOUT`                  | `60m`                             | Default `--timeout` for a fresh review, sized to the ledger's p90 review time; an explicit `--timeout` wins                                                                                                                              |
| `PRO_GATE_LOCK_WAIT`                | `3900`                            | How long a queued review waits for an account capacity slot before giving up                                                                                                                                                             |
| `PRO_GATE_CHANGE_LOCK_WAIT`         | _(derived)_                       | Wait for the same-change guard; defaults to the holder's whole guarded lifetime (`15710` at stock settings)                                                                                                                              |
| `PRO_GATE_HARVEST_TIMEOUT`          | `45m`                             | Default `--timeout` for `--harvest`/`--recover` and the value harvest hints print; one pass now usually collects                                                                                                                         |
| `PRO_GATE_REQUIRE_NONCE`            | `1`                               | Reject any capture that doesn't echo this run's nonce (`0` restores path-overlap matching)                                                                                                                                               |
| `PRO_GATE_MODEL_STRATEGY`           | `current`                         | Review with whatever Pro model the account has selected; the run reports the one it used                                                                                                                                                 |
| `PRO_GATE_CHAT_RENAME`              | `1` remote / prompt-only native   | Apply and verify the exact canonical PR/round title through ChatGPT's rendered UI                                                                                                                                                        |
| `PRO_GATE_CHAT_ARCHIVE`             | `1`                               | Archive through ChatGPT's rendered UI only after marker-addressed durable exit-0 success                                                                                                                                                 |
| `PRO_GATE_KEEP_TABS`                | `0`                               | Exact value `1` permits rename but suppresses both server archive and local tab close                                                                                                                                                    |
| `PRO_GATE_BROWSER_ARCHIVE`          | `never`                           | Passed unchanged to Oracle; `auto`/`always` can archive before pro-gate validates durable recovery state                                                                                                                                 |
| `PRO_GATE_BROWSER_ATTACHMENTS`      | `auto`                            | Oracle file-delivery policy: `auto` uses Oracle's inline/upload selection, `never` keeps supported text files inline, and `always` uploads. Empty/unset uses `auto`; review input policy is unchanged.                                   |

### Conversation lifecycle

The remote-browser organizer never calls a ChatGPT backend API. It first proves the open or
remembered conversation carries this run's marker and not another run's completed answer, then
uses the visible menu, title input, save, and archive controls. UI drift is best-effort and cannot
change the review result.

| Remote outcome/configuration                                 |                 Exact rename | Server archive | Local tab close |
| ------------------------------------------------------------ | ---------------------------: | -------------: | --------------: |
| Exit 0, readable marker-addressed durable result (defaults)  |                          yes |            yes |             yes |
| Same, `PRO_GATE_CHAT_ARCHIVE=0`                              |                          yes |             no |             yes |
| Same, `PRO_GATE_CHAT_RENAME=0`                               |                           no |            yes |             yes |
| Same, `PRO_GATE_KEEP_TABS=1`                                 |                          yes |             no |              no |
| Exit 3, 6, or 9 with a proven owned conversation             |                          yes |             no |              no |
| Volatile-only result or ambiguous/foreign/cross-bound target | at most a proven safe rename |             no |              no |

Invalid values for the two new boolean controls warn and disable only that mutation. The older
`PRO_GATE_KEEP_TABS` and `PRO_GATE_BROWSER_ARCHIVE` surfaces keep their exact historical
semantics. Native mode keeps the prompt's title hint and does not run remote-CDP organization.

## Repo map

| Path                                | What it is                                                                                                          |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `bin/oracle-review.sh`              | **The engine**: assembles context, runs the review, captures/salvages/harvests the verdict                          |
| `bin/cdp-salvage.mjs`               | Marker-owned CDP salvage and conversation organizer: recover, exact-rename, archive, and local cleanup decisions    |
| `bin/cdp-organizer-expressions.mjs` | Auditable ChatGPT UI expressions for exact rename and archive; no backend API calls                                 |
| `bin/cdp-test-timing.mjs`           | Test-only timing override parsers that cdp-salvage.mjs imports; production keeps its own defaults                   |
| `bin/pro-gate-doctor.sh`            | One-command setup verification (deps, versions, browser, consent)                                                   |
| `bin/pro-gate-stats.sh`             | Ledger stats: clean rate, exits, per-PR history                                                                     |
| `bin/pro-gate-autoupdate.sh`        | The opt-in hourly skew-follower                                                                                     |
| `lib/pro-gate-lib.sh`               | Platform detection, locks, canonical attempt lifecycle, reservations, terminal dispositions, round telemetry/policy |
| `skills/pro-gate/SKILL.md`          | The `/pro-gate` skill, the authoritative caller guide                                                               |
| `agents/oracle-reviewer.md`         | Thin relay agent for other pipelines                                                                                |
| `daemon/daemon.sh`                  | Label-gated watcher (per-SHA idempotent, cost/failure caps)                                                         |
| `daemon/run-oracle-chrome.sh`       | WSL/Linux durable Xvfb Chrome (CDP)                                                                                 |
| `install.sh`                        | Cross-platform installer (see flags in [Installation](#installation))                                               |

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
  Independent of that policy mode, a change whose open-P0/P1 trajectory has not shrunk for 2
  consecutive re-reviews gets a typed `stop-without-new-review` / `rounds-not-converging` decision
  in place of a new round grant or a fix dispatch — this is a churn signal, not a budget one, so it
  fires even in advisory mode. A clean round (zero open P0/P1) ends the chain, so successive clean
  reviews of new heads never accumulate a streak. `PRO_GATE_ROUNDS_CONTINUE=1` bypasses churn for
  the configured invocation, exposing the uncollapsed numeric grant without enlarging it. When
  numeric enforcement is enabled, unused headroom is still required; exhausted, base-zero and
  cap-zero budgets remain closed. The override is stateless, not a durable one-use allowance.
  `PRO_GATE_FORCE_ROUND=1` alone does not bypass the separate churn stop. Both overrides are
  operator-only: agents must never set, export or script them. The daemon and wrapper end a run
  on any `stop-without-new-review` reason the same way.
- **Merge authority**: the daemon never merges directly; it stops after pushing fixes and
  commenting. The surrounding agent may arm squash auto-merge only after local verification,
  adversarial review, and required exact-head CI are green.

## Troubleshooting

### Doctor reports a plugin/runtime version skew

Run the installer line the error printed (it targets the plugin's exact version). If the
doctor says the _runtime_ is ahead, update the plugin instead; the installer would
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
let changed/current evidence receive a fresh typed decision. Unknown post-click fate stays recoverable,
with one exception: when Oracle's own exact-session record shows the send never reached a ChatGPT
conversation and left the composer empty, and the final scan finds none, the attempt settles as `recovery-exhausted` (proof
`no-conversation-after-send`, ledger reason `no-conversation`). Since v0.60.0 it counts as a failed delivery and its round is
refunded, so two in a row under unchanged conditions stop typed with `delivery-failed-unchanged`; when its Oracle build or
evidence relation is unknown it keeps its charge instead.
Each unresolved reservation also carries `classification` (what the latest collection pass concluded:
`owned-incomplete`, `inconclusive`, `browser-down`, `absent`, `cross-bound`, `throttle`, `terminal`,
`terminal-infrastructure`), `classified_at`, and `ttl_remaining_secs`, so a parked run and a genuinely
generating one no longer read alike. A remembered conversation URL whose id is not a real conversation
id (a `WEB:<uuid>` placeholder) is revoked on read and the pass rescans; nothing is terminalized from age alone.
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

1. `auto-release.yml` pushes the tag; `release.yml` waits for the merge's own CI run on
   `main`, including its `trusted check` job, to pass for that exact commit, runs the
   release suites, packages and uploads checksummed assets, then leaves the release a
   **draft** and prints the repin tuple
   (plugin, version, sha, releaseId, releaseTag).
2. Merge the repin PR against `StartupBros-com/hov-marketplace`. Its hourly **Repin
   reconcile** workflow opens that PR once the draft's assets are complete; dispatch the
   workflow with `only_plugin=pro-gate` instead of waiting for the tick, and merge once both
   required checks pass. A bot repin that changes only pin fields (source sha, version,
   releaseId, releaseTag) takes no review round: hov-marketplace's required **Pinned
   sources** check already proves, before the merge, that the tag resolves to the pinned
   commit, so a reviewer would only re-read the pin. A card PR that also changes copy gets a
   normal review. The card is updated by a merged PR and never by a push from CI — a
   standing credential able to write the distribution manifest is the one whose compromise
   reaches every installed client.
3. Run the **Publish staged release** workflow (or `gh release edit vX.Y.Z --draft=false`).
   The workflow re-reads the live card and refuses unless the card names exactly this
   release, so a mistimed run cannot publish something undistributed; this runs after the
   repin merged, so it keeps the release a draft but cannot undo a wrong pin. The
   `gh release edit` path skips that card check.
4. Publishing fires the release train once: it verifies distribution and announces. The
   train only ever _reads_ the marketplace — it holds no deploy credential.

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
