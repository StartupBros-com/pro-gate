---
name: pro-gate
description: Run a final-tier GPT-5.5 Pro Extended review of a pull request (the deepest, last gate after other review tiers), then route the findings to the best available fixer. Use when the user says "pro-gate", "pro review", "final review with Pro Extended", "oracle review this PR", or wants the heavyweight ChatGPT Pro Extended pass before merge. Drives a logged-in ChatGPT Pro browser session via oracle (oracle-review.sh). First run on a machine walks the member through a one-time guided setup.
argument-hint: "[pr-number-or-url] [setup] [review-only|auto-fix]"
---

# pro-gate — the deepest final code review (ChatGPT GPT-5.5 Pro)

The last and strongest review tier. After your other checks have run (e.g. `/token-eater`'s review,
`/ce-code-review`), this sends the change to **GPT-5.5 Pro Extended** — ChatGPT's most powerful
reasoning model, which is *web-only* and draws on a **separate usage pool from your coding agent** —
for what everything else missed, then fixes what it safely can and comments. It never merges.

**Where the pieces live.** The skill is at `<plugin-root>/skills/pro-gate/`. The one-time installer
is at the plugin root — `${CLAUDE_PLUGIN_ROOT}/install.sh` (fall back to `<this-skill-dir>/../../install.sh`
if that variable isn't set). Once setup has run, the **engine** lives in `~/.pro-review-daemon/`
(`oracle-review.sh`, `pro-gate-doctor.sh`) and every review runs from there.

## Audience first: the member just types `/pro-gate`

**The person running this is usually a non-technical House of Vibe member.** They do NOT know what
oracle, a browser bridge, a daemon, systemd, `.env`, or a "flag" is — and they must never need to.
They type `/pro-gate` (optionally with a PR number) and nothing else. **You (Claude) are the friendly
layer**: you handle setup conversationally with **plain-language, interactive multiple-choice
questions** (use the AskUserQuestion tool — the member clicks a choice, never types a flag), you run
the right commands yourself, and you report back in plain English. The technical contract below is
*yours* with the engine, never something you show the member.

## What it needs (say this once, plainly)

pro-gate's review comes from **GPT-5.5 Pro**, which only exists inside **ChatGPT Pro** (a paid
ChatGPT plan, ~$200/mo — there is no API for it). That's the one thing the setup can't install for
the member: they need a ChatGPT Pro account. **Everything else** — the `oracle` tool, the review
engine, the signed-in-browser bridge — the one-time guided setup installs and configures for them.
If they don't have ChatGPT Pro, say so kindly, point them at chatgpt.com, and offer to finish setup
whenever they're ready. Don't dead-end them with jargon.

## First run on this machine (not set up yet) → guided one-time setup

**Detect setup first.** It's already set up if the engine is deployed **and** the doctor passes:

```bash
[ -x "$HOME/.pro-review-daemon/oracle-review.sh" ] && bash "$HOME/.pro-review-daemon/pro-gate-doctor.sh"
```

If that succeeds → skip to **Later runs**. If not, walk the member through setup (this is the
"preflight" — friendly and one-time; the install itself is the persistence, so you won't ask again):

1. **ChatGPT Pro check.** Ask (AskUserQuestion, plain language): *"pro-gate uses ChatGPT's most
   powerful model to review your code. That needs a ChatGPT Pro plan — do you have one?"* → **Yes /
   Not sure / No**. On **No**, explain kindly + link chatgpt.com + stop gracefully (offer to resume
   later). On **Not sure**, continue — the sign-in step will make it obvious.
2. **Install (one command, you run it).** `bash "${CLAUDE_PLUGIN_ROOT}/install.sh"`. This installs
   the `oracle` tool, deploys the engine to `~/.pro-review-daemon/`, and sets up the signed-in-browser
   bridge for this platform. On **macOS** it uses the member's normal Chrome (no admin password). On
   **WSL/Linux** it sets up a background browser service and **may ask for the computer's admin
   password once** (systemd) — tell the member that's expected and what it's for.
3. **Sign in to ChatGPT (you walk them through it).**
   - **macOS:** *"Open Chrome and sign in at chatgpt.com. Make sure you can pick **GPT-5.5 Pro** in
     the model menu."* (oracle reuses that signed-in Chrome — nothing else to do.)
   - **WSL/Linux:** run `~/.pro-review-daemon/login-view.sh`, then *"open http://localhost:6080/vnc.html
     in your browser and sign in to ChatGPT Pro there."*
4. **Verify + report.** Run `bash "$HOME/.pro-review-daemon/pro-gate-doctor.sh"` and translate the
   result to plain English ("✅ pro-gate is ready" / "⚠️ it can't see your ChatGPT sign-in yet — let's
   redo the sign-in step"). Then continue to the actual review.

Setup is **per machine**, not per project — once `~/.pro-review-daemon/` exists and the doctor passes,
every later `/pro-gate` in any project skips straight to the review.

## Later runs (already set up) → just review

The member types `/pro-gate` (optionally a PR). Resolve the target, run the engine, synthesize, act,
and report — all per the engine contract below. No setup questions.

## Power-user arguments (optional — never required)

A technical user MAY pass these; parse and strip them, then proceed.

| Token | Effect |
|-------|--------|
| a PR number or URL | Review that PR (else: the current branch's PR; else ask). |
| `setup` | Re-run the guided setup / doctor (use after a sign-in expires or to reinstall). |
| `review-only` / `auto-fix` / `auto-fix+merge` | Override the mode (default: `auto-fix`). |

---

## Engine contract (how a review actually runs)

### 1. Resolve target + mode

- **PR:** from the argument (`/pro-gate <num|url>`), else the current branch's PR
  (`gh pr view --json number,url`), else ask which PR.
- **Repo:** the repo containing the PR (default: current dir; for a URL, the local checkout under
  `$PRO_GATE_REPOS_DIR`, default `~/SITES/<name>`).
- **Mode:** read `pro_gate_mode` from `<repo>/.compound-engineering/config.local.yaml`
  (`review-only` | `auto-fix` (default) | `auto-fix+merge`). A `mode` argument overrides it.
  `auto-fix+merge` requires the guarded-merge rules; if they aren't satisfied, fall back to
  `auto-fix` and leave the PR for the human. For a non-technical member, `auto-fix` (fix what's safe,
  push, comment, **never merge**) is the right default — don't offer `auto-fix+merge` unprompted.
- **Input:** `pro_gate_input` (`both` default | `bundle` | `connector`).

### 2. Guardrails (before spending a ~10-30 min Pro Extended slot)

- **Session up (WSL/Linux):** `curl -sf localhost:9222/json/version` — if down, start it
  (`sudo systemctl start oracle-chrome`) and sign in via `login-view.sh` if the profile reset.
  On **macOS** there's no pre-check — oracle drives the signed-in Chrome and errors clearly if the
  member isn't logged in. `pro-gate-doctor.sh` checks all of this; if it fails here, route the member
  back through the **setup** sign-in step in plain language rather than showing the raw error.
- **Usage (best-effort):** if codex auth is present, check `chatgpt.com/backend-api/wham/usage`;
  if the primary window is ≥90% or `limit_reached`, warn before burning a slot.
- **Concurrency is handled for you:** `oracle-review.sh` holds a lock, so many concurrent `/pro-gate`
  calls QUEUE and run one-at-a-time against the single ChatGPT account — safe, never parallel. Each
  waits up to `PRO_GATE_LOCK_WAIT`.

### 3. Run the review

Launch the engine in the background (it blocks ~10-30 min) and poll its `--out` file:

```bash
"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"/oracle-review.sh \
  --pr <num|url> --repo <repo> --input <mode> \
  --out "${TMPDIR:-/tmp}/pro-gate-<num>.md" --timeout 30m
```

Run with `run_in_background: true` and a long Bash timeout; poll the out file. While waiting, do not
spawn a second oracle run (one ChatGPT session, serialized). Tell the member plainly that the deepest
review takes ~10-30 minutes and they can step away. When it returns, the findings are the
`[Pn] file:line` blocks ending in a `VERDICT:` line. Never re-run a detached session — reattach with
`oracle session <slug>` (re-running double-spends the Pro Extended quota).

### 4. Synthesize

Parse the findings into P0/P1/P2/P3. Treat Pro Extended as high-trust but not infallible: for any
P0/P1, sanity-check it against the actual code before acting (it occasionally misreads context).
Drop or down-rank anything clearly wrong; keep the rest.

### 5. Act (per mode)

- **review-only:** post the findings as a PR comment (`gh pr comment <num> --body-file`) and stop.
- **auto-fix (default):** route confirmed P0/P1 (and clear P2s) to the **best available fixer**, in
  order: (1) Compound Engineering installed → `/ce-work-beta delegate:codex` (skip if the codex
  doghouse `~/.codex/.doghouse` is tripped); (2) else `codex` on PATH → `codex exec`; (3) else apply
  the edits yourself directly. Then run available tests/lint, commit `fix(pro-gate): <summary>`, push,
  and post a PR comment with the review + what was fixed. **Stop before merge — the human merges.**
- **auto-fix+merge:** after fixes converge, follow the guarded-merge rules: merge only when CI is
  green, no unresolved P0/P1, and the diff doesn't touch high-risk domains
  (auth/payments/migrations/secrets) — otherwise escalate to the human.

### 6. Re-review (optional)

If fixes were applied and `pro_gate_max_rounds > 1`, run one more pass on the updated diff. Reuse the
same ChatGPT conversation via `oracle ... --followup <slug>` to keep context (and cost) down.

## Plain-language reporting (what the member sees)

Translate the engine's output, scaled to how technical they are. Always state simply: **what the
review found** (in their words, grouped most-important-first), **what was fixed vs. left for them**,
that **nothing was merged** (they decide), and where to look (the PR). If the review couldn't run
(no ChatGPT Pro sign-in, usage limit), say what's needed in one friendly sentence and how to fix it —
never a raw stack trace. Leave the full Pro Extended review as a PR comment so there's an audit trail.

## Safety invariants

- **Never merges.** pro-gate reviews, fixes what's safe, pushes to the PR, and **stops before merge**
  — the human always merges. `auto-fix+merge` is opt-in and guarded (CI green, no open P0/P1, no
  high-risk diff), never the member default.
- **One ChatGPT session, serialized.** Concurrent runs queue behind a lock; never run two oracle
  sessions at once, and never re-run a detached session (it double-spends the Pro Extended quota) —
  reattach instead.
- **Findings are sanity-checked.** Pro Extended is high-trust but not infallible; verify P0/P1 against
  the real code before acting on it.
- **ChatGPT Pro is required and external.** Setup detects it and explains it kindly; it can't be
  installed for the member.

## Set-and-forget daemon (advanced / optional — not part of a member's first run)

Beyond the interactive `/pro-gate`, a background daemon can watch for PRs labeled `pro-review` and run
the whole pipeline unattended. It's a power-user feature: it needs `PRO_REVIEW_OWNERS` set in
`~/.pro-review-daemon/.env` and (on WSL/Linux) a systemd service. Install it with
`INSTALL_DAEMON=1 bash "${CLAUDE_PLUGIN_ROOT}/install.sh"`. Only mention this if the member explicitly
asks for hands-off / automatic reviews; otherwise keep them on the simple interactive path.

## Reference map

| File | What it's for |
|------|---------------|
| `${CLAUDE_PLUGIN_ROOT}/install.sh` | The one-time cross-platform installer (oracle + engine + browser bridge). |
| `~/.pro-review-daemon/oracle-review.sh` | **The engine** — assembles context, runs Pro Extended via oracle, returns findings. Lock-serialized. |
| `~/.pro-review-daemon/pro-gate-doctor.sh` | One-command setup verification (used by the setup detect + guardrails). |
| `~/.pro-review-daemon/login-view.sh` | WSL/Linux sign-in helper (VNC at http://localhost:6080/vnc.html). |
| `${CLAUDE_PLUGIN_ROOT}/.env.example` | All tunables (daemon owners, models, concurrency, browser mode). |
| `docs/SETUP-NOTES.md` | Platform mechanics + gotchas (incl. headless/server-Mac `remote-chrome`). |
