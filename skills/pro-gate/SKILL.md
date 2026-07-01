---
name: pro-gate
description: Run a final-tier GPT-5.5 Pro Extended review of a pull request (the deepest, last gate after other review tiers), then route the findings to the best available fixer. Use when the user says "pro-gate", "pro review", "final review with Pro Extended", "oracle review this PR", or wants the heavyweight ChatGPT Pro Extended pass before merge. Drives a logged-in ChatGPT Pro browser session via oracle (oracle-review.sh).
---

# pro-gate — GPT-5.5 Pro Extended final review gate

The last and deepest review tier. After your earlier tiers (e.g. `/ce-code-review`, a cloud review)
and their fixes have run, this gate sends the change to **GPT-5.5 Pro Extended** (web-UI-only,
separate usage pool from the Codex fixer) for what they missed, then applies the fixes.

Engine: `oracle-review.sh` (in `$PRO_GATE_HOME`, default `~/.pro-review-daemon`) — the single source
of truth for the oracle call; cross-platform (macOS drives your signed-in Chrome natively; WSL/Linux
attaches to the Xvfb Chrome). Verify setup any time with `pro-gate-doctor.sh`. The engine now
**auto-salvages** a dropped session (a bounded reattach-harvest) and **retries a lost run once**, so
prefer reading its **exit code** (see §3) over manually re-running — a hand re-run while a session is
still generating double-spends the Pro Extended quota.

## 1. Resolve target + mode

- **PR:** from the argument (`/pro-gate <num|url>`), else the current branch's PR
  (`gh pr view --json number,url`), else ask which PR.
- **Repo:** the repo containing the PR (default: current dir; for a URL, the local checkout under
  `$PRO_GATE_REPOS_DIR`, default `~/SITES/<name>`).
- **Mode:** read `pro_gate_mode` from `<repo>/.compound-engineering/config.local.yaml`
  (`review-only` | `auto-fix` (default) | `auto-fix+merge`). A `mode:` argument overrides it.
  `auto-fix+merge` requires the guarded-merge rules; if they aren't satisfied, fall back to
  `auto-fix` and leave the PR for the human.
- **Input:** `pro_gate_input` (`both` default | `bundle` | `connector`).

## 2. Guardrails (before spending a ~10-30 min Pro Extended slot)

- **Session up (WSL/Linux):** `curl -sf localhost:9222/json/version` — if down, start it
  (`sudo systemctl start oracle-chrome`) and sign in via `login-view.sh` if the profile reset.
  On **macOS** there's no pre-check — oracle drives your signed-in Chrome and errors clearly if
  you're not logged in. `pro-gate-doctor.sh` checks all of this.
- **Usage (best-effort):** if codex auth is present, check `chatgpt.com/backend-api/wham/usage`;
  if the primary window is ≥90% or `limit_reached`, warn before burning a slot.
- **Concurrency is handled for you:** up to `PRO_GATE_MAX_CONCURRENCY` reviews (default **3**) run at
  once against the single ChatGPT account (it tolerates several parallel chats); extra callers QUEUE on
  a counting semaphore, each waiting up to `PRO_GATE_LOCK_WAIT` (default 40 min). A separate **per-PR
  guard** keeps the SAME pr from being reviewed twice at once (no double-spend on one diff), and the
  health-gate governs every slot — so a loaded box self-throttles below the cap instead of crashing.
  Set `PRO_GATE_MAX_CONCURRENCY=1` to force strict one-at-a-time.
- **The engine self-hardens (v0.1.1), so these are backstopped:** right before spending a slot it
  runs a **health gate** (Chrome reachable + not just-restarted/flapping + RAM headroom) and **defers
  with exit 8 — spending no slot — if the box is unfit**. A dropped connection is **auto-salvaged**
  (bounded reattach), a truly-lost run is **retried once** (with a health re-check), and lockfiles /
  generated files are **stripped from the payload**. Knobs: `PRO_GATE_MIN_UPTIME` (60s),
  `PRO_GATE_MIN_AVAIL_MB` (1024), `PRO_GATE_MAX_RETRIES` (1), `PRO_GATE_DIFF_FILTER` (1).

## 3. Run the review

Launch the engine in the background (it blocks ~10-30 min) and poll its `--out` file:

```bash
"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"/oracle-review.sh \
  --pr <num|url> --repo <repo> --input <mode> \
  --out "${TMPDIR:-/tmp}/pro-gate-<num>.md" --timeout 30m
```

Run with `run_in_background: true` and a long Bash timeout; poll the out file. While waiting, do not
spawn a second oracle run (one ChatGPT session, serialized). When it returns, the findings are the
`[Pn] file:line` blocks ending in a `VERDICT:` line.

**Act on the exit code — don't just check the out file:**
- `0` — findings written to `--out`. Proceed to Synthesize.
- `8` — **deferred, NO slot spent**: the box was unfit (Chrome down / just-restarted / memory-starved).
  Not a failure — don't burn a slot retrying blindly. Wait for it to settle and re-run, or run on the
  **mac-mini** (native Chrome). Tell the user why.
- `6` — ran but produced nothing even after auto-salvage + the one retry (genuine failure). Report it;
  a fresh re-run is reasonable (salvage already checked for a completed answer, so it won't double-spend).
- `7` — lock timeout: another review held the single session the whole `PRO_GATE_LOCK_WAIT`. Retry later.

## 4. Synthesize

Parse the findings into P0/P1/P2/P3. Treat Pro Extended as high-trust but not infallible: for any
P0/P1, sanity-check it against the actual code before acting (it occasionally misreads context).
Drop or down-rank anything clearly wrong; keep the rest. Present a short table (severity · file:line ·
issue · your confidence) plus the verdict.

## 5. Act (per mode)

- **review-only:** post the findings as a PR comment (`gh pr comment <num> --body-file`) and stop.
- **auto-fix:** route confirmed P0/P1 (and clear P2s) to the **best available fixer**, in order:
  (1) if the Compound Engineering plugin is installed → `/ce-work-beta delegate:codex` (skip if the
  codex doghouse `~/.codex/.doghouse` is tripped); (2) else if `codex` is on PATH → `codex exec`;
  (3) else → apply the edits yourself directly in this session. Then run available tests/lint, commit
  `fix(pro-gate): <summary>`, push, and post a PR comment with the review + what was fixed. Stop
  before merge — the human merges.
- **auto-fix+merge:** after fixes converge, follow the guarded-merge rules: merge only when CI is
  green, no unresolved P0/P1, and the diff doesn't touch high-risk domains
  (auth/payments/migrations/secrets) — otherwise escalate to the human.

## 6. Re-review (optional)

If fixes were applied and `pro_gate_max_rounds > 1`, run one more pass on the updated diff to confirm
the P0/P1 issues are resolved. Reuse the same ChatGPT conversation via `oracle ... --followup <slug>`
when possible to keep context (and cost) down.

Always leave an audit trail: the full Pro Extended review + the fix summary as a PR comment.
