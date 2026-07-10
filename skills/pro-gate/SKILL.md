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
attaches to the Xvfb Chrome). Verify setup any time with `pro-gate-doctor.sh`. (The `oracle-reviewer`
agent is a thin relay over the same engine for other pipelines — when the caller contract here
changes, update `agents/oracle-reviewer.md` in the same PR.)

**Detached vs dead sessions — different rules:**
- **Ground truth is the BROWSER, not oracle's log.** oracle can miss the thinking state after
  ChatGPT UI drift (seen 2026-07-02: it logged `no thinking status detected` for 10 min while the
  review was mid-thought). Before treating ANY run as dead, check for a live conversation tab:
  `curl -s localhost:9222/json` — a `chatgpt.com/c/...` page tab whose text matches the PR means
  the run is LIVE or DONE and quota is SPENT: never re-run.
- **Detached but thinking** (conversation tab exists / output growing): NEVER re-run. Prefer
  `node $PRO_GATE_HOME/cdp-salvage.mjs "<pr-url-or-pull/NNN>" <secs>` — it waits for the
  `VERDICT:` line in the tab and prints the review. (`oracle session <slug> --harvest` can bind a
  STALE tab target after a watchdog kill and harvest nothing — trust the CDP path.)
- **Dead submission** (no conversation tab matching the PR AND the run log shows oracle never got
  as far as `Launching browser mode` / `Acquired ChatGPT browser slot`): no quota consumed, so
  kill the process tree and re-run safely. If the log DOES show a browser slot/session, the prompt
  landed and quota is SPENT even without a visible tab (transient CDP/render hiccup): do NOT
  re-run, salvage instead. The engine now fails closed here on its own. Note: the engine runs
  oracle with `--browser-archive=never`, so a landed conversation's `/c/` tab stays findable by
  marker (and the engine closes it on finish); a missing tab is therefore a stronger "never
  landed" signal.
- **Engine ≥v0.14 does all of this itself**: hard-cap/stall/no-think watchdogs, a CDP
  probe-before-kill at the no-think timeout (live tab → frees the slot, SUPPRESSES the retry,
  collects via cdp-salvage with the full budget), and cdp-salvage as last resort before failing.
  Manual salvage is only needed on engines older than v0.13 or when Chrome itself died.
  Tune with `PRO_GATE_NOTHINK_SECS` / `PRO_GATE_STALL_SECS` (default 600) and
  `PRO_GATE_TIMEOUT_GRACE` (default +120s on the hard cap).
- **Engine ≥v0.18 is also throttle-aware**: salvage page-loads are budgeted per URL,
  foreign conversations are blacklisted persistently, the throttle interstitial trips a global
  cooldown instead of a retry, and every phase lands in `<out>.status` for polling.
- **Engine >=v0.20 never destroys a still-generating review**: when the salvage budget ends
  while the model is still reasoning, the run exits 9 (`in-progress`), leaves the conversation
  tab open, and `--harvest <marker>` collects the finished review later with NO new spend. An
  oversized diff is refused up front (exit 11) instead of burning a slot it cannot convert.

**Codex on Windows:** run the engine through WSL, not native PowerShell path syntax. Use WSL repo paths
such as `/home/will/SITES/<repo>` and invoke commands with `wsl -e bash -lc '...'`; the default engine
home is `/home/will/.pro-review-daemon`.

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
- **Concurrency is handled for you:** `oracle-review.sh` holds a counting semaphore —
  **serialized by default** (`PRO_GATE_MAX_CONCURRENCY=1`; raise it only if your account
  demonstrably tolerates parallel Pro chats). Concurrent `/pro-gate` calls (e.g. 10 agents at
  once) QUEUE, each waiting up to `PRO_GATE_LOCK_WAIT` (default 40 min). A separate per-PR
  guard stops the same PR being reviewed twice at once.
- **Concurrency is ADAPTIVE (engine ≥v0.19):** `PRO_GATE_MAX_CONCURRENCY` is a ceiling, not the
  live value — the ramp governor starts low, earns +1 level per `PRO_GATE_RAMP_STREAK` (default 5)
  clean runs, and drops to 1 instantly on any throttle. Check the live level + run history any
  time with `pro-gate-stats.sh` (`--tail 10` for recent runs); every run lands in
  `$PRO_GATE_HOME/ledger.jsonl`. Note oracle itself caps browser tabs (3 in ≤0.15.x) — ceilings
  above that just queue inside oracle.
- **ChatGPT throttle cooldown (engine ≥v0.18):** if ChatGPT serves its "requests too quickly /
  temporarily limited" interstitial, the engine writes `$PRO_GATE_HOME/throttle.cooldown` and every
  new run DEFERS (exit 8, no quota spent) until it expires (`PRO_GATE_THROTTLE_COOLDOWN`, default
  900s). Never delete the cooldown file to force a run — hammering extends the throttle.

## 3. Run the review

Launch the engine in the background (it blocks ~10-30 min) and poll its **status file**:

```bash
"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"/oracle-review.sh \
  --pr <num|url> --repo <repo> --input <mode> \
  --out "${TMPDIR:-/tmp}/pro-gate-<num>.md" --timeout 30m
```

Run with `run_in_background: true` and a long Bash timeout. The engine writes single-line JSON to
`<out>.status` at every phase change (`preflight → waiting-slot → launching → … → done|failed|deferred|in-progress|oversized`):
poll THAT, not engine logs. Phase `done` ⇒ read `--out` (the `[Pn] file:line` blocks ending in a
`VERDICT:` line). `failed`/`deferred`/`in-progress`/`oversized` are terminal for this invocation:
do NOT relaunch on `throttled`/`salvaging` phases; the engine is still working. While waiting,
never spawn a second oracle run for the same PR. The status JSON carries `marker` (the run's
conversation correlation id): you need it for `--harvest`.

Engine exit codes: `0` review ready · `2` bad usage · `3` oracle/browser missing · `4` repo not
found · `5` diff fetch failed · `6` ran but no usable review (quota may be spent — check the PR
conversation in ChatGPT before re-running) · `7` lock timeout · `8` deferred, NO quota spent
(box unfit or throttle cooldown: safe to retry later) · `9` in-progress: the slot IS spent but
the model was still generating when the salvage budget ran out; the conversation tab is left
open: NEVER relaunch, harvest instead (below) · `11` oversized diff, NO quota spent: scope
the payload (below) instead of re-running.

**Exit 9 (`in-progress`): harvest, don't respend.** GPT-5.5 Pro can reason for 45-90+ minutes
on a heavy payload (observed 65 min on 2026-07-09): longer than the engine can hold a review
slot. The engine frees the slot, leaves the run's conversation tab open, and puts the marker in
the status JSON. Wait ~10 min, then collect with:

```bash
STATUS=<out>.status
MARKER="$(jq -r .marker "$STATUS" 2>/dev/null || sed -nE 's/.*"marker":"([^"]+)".*/\1/p' "$STATUS")"
"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"/oracle-review.sh \
  --harvest "$MARKER" --out <out> --timeout 20m
```

Harvest exits: `0` review ready · `9` reservation retained, try again later (still generating,
or absent this pass but under the consecutive-miss threshold) · `8` deferred (cooldown: retry
after) · `6` conversation confirmed gone after repeated misses (review lost; only NOW is a
fresh run justified) · `7` another collector already holds this marker (wait for it; do not
race it) · `3` runtime/CDP trouble; reservation and tab kept (retry once the browser is
healthy). Repeat harvests are free: no Pro quota is spent. Reservations are keyed by
repo-scoped PR identity, so identical PR numbers in different repositories never cross.

**Exit 11 (`oversized`): scope the gate.** Huge diffs (default guard: >6000 lines,
`PRO_GATE_MAX_DIFF_LINES`) do not converge in any review budget; blind reruns just burn
20-60 min Pro sessions. Scope the final gate to the delta that has NOT already cleared earlier
tiers, with full-file context for the trust boundary:

```bash
git -C <repo> diff <last-gated-sha>..<head> > delta.patch
"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"/oracle-review.sh \
  --diff delta.patch --repo <repo> --extra-files 'lib/critical-*.sh' --out <out>
```

## 4. Synthesize

Parse the findings into P0/P1/P2/P3. Treat Pro Extended as high-trust but not infallible: for any
P0/P1, sanity-check it against the actual code before acting (it occasionally misreads context).
Drop or down-rank anything clearly wrong; keep the rest. Present a short table (severity · file:line ·
issue · your confidence) plus the verdict.

## 5. Act (per mode)

- **review-only:** post the findings as a PR comment (`gh pr comment <num> --body-file`) and stop.
- **auto-fix:** route confirmed P0/P1 (and clear P2s) to the **best available fixer**, in order:
  (1) if the Compound Engineering plugin is installed → `/ce-work` (native tiering since CE 3.17.1
  routes to codex when appropriate; skip if the codex doghouse `~/.codex/.doghouse` is tripped);
  (2) else if `codex` is on PATH → `codex exec`;
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
