---
name: pro-gate
description: Run a final-tier ChatGPT Pro review of a pull request (the deepest, last gate after other review tiers), then route the findings to the best available fixer. Use when the user says "pro-gate", "pro review", "final review with the Pro model", "oracle review this PR", or wants the heavyweight ChatGPT Pro pass before merge. Drives a logged-in ChatGPT Pro browser session via oracle (oracle-review.sh).
---

# pro-gate: final-tier ChatGPT Pro review gate

The last and deepest review tier. After your earlier tiers (e.g. `/ce-code-review`, a cloud review)
and their fixes have run, this gate sends the change to **the ChatGPT Pro reasoning model**
(web-UI-only, separate usage pool from the Codex fixer) for what they missed, then applies the fixes.
The exact model follows whatever Pro model the account has selected; the run reports the one it used.

Engine: `oracle-review.sh` (in `$PRO_GATE_HOME`, default `~/.pro-review-daemon`) — the single source
of truth for the oracle call; cross-platform (macOS drives your signed-in Chrome natively; WSL/Linux
attaches to the Xvfb Chrome). Verify setup any time with `pro-gate-doctor.sh`. (The `oracle-reviewer`
agent is a thin relay over the same engine for other pipelines — when the caller contract here
changes, update `agents/oracle-reviewer.md` in the same PR.)

## Runtime precheck

Before every review, resolve this plugin's promoted version from
`${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`, then run the doctor with that expectation:

```bash
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")"
PRO_GATE_EXPECTED_VERSION="$PLUGIN_VERSION" \
  "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/pro-gate-doctor.sh"
```

If the runtime or its `VERSION` record is missing, or the installed version differs, stop before
running the engine. Route the operator to the exact matching release, never `latest`:

```bash
curl -fsSL "https://raw.githubusercontent.com/StartupBros-com/pro-gate/v${PLUGIN_VERSION}/install.sh?$(date +%s)" \
  | bash -s -- --version "$PLUGIN_VERSION"
```

The doctor states which side is ahead. **If it reports the runtime is AHEAD of the plugin, that
command DOWNGRADES the runtime** (it always targets the plugin's version) — in that case update the
active plugin to the runtime's version instead, and only run the downgrade if you truly mean it.

The plugin is the only owner of this skill and `agents/oracle-reviewer.md`; `install.sh` installs
runtime files only. Do not copy either artifact into a global Claude skills or agents directory.
Daemon and dangerous automatic-fixer execution remain disabled unless the operator separately accepts
the versioned disclosure during installation.

**Detached vs dead sessions — different rules:**
- **Lost track of a run entirely (compaction, a new session, a dead tab)? Inspect state
  first, then let the engine route you.** All of this works with zero prior context; use the
  defaulted home everywhere, `PG_HOME="${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"`:
  `ls "$PG_HOME/in-progress/"` (filenames ARE harvest markers; each file's first
  tab-separated field is the change key — a matching entry means your review is still
  collectable for free), `"$PG_HOME/pro-gate-stats.sh" --tail 10` for recent outcomes, and
  the ledger (`"$PG_HOME/ledger.jsonl"`, `out` field) for a COMPLETED run's findings path —
  if the review already finished, read that file; run nothing. When a matching reservation
  EXISTS (WSL/Linux remote-chrome only — native/macOS never creates reservations),
  re-running the identical fresh-run command is safe on engine ≥v0.22: it reconciles
  reservations before spending anything and redirects itself to harvest, printing the exact
  `--harvest '<marker>' --out … --timeout 20m` command and exiting 9 with NO new spend. With
  NO reservation, a fresh run is a real spend (the round budget counts it): launch one only
  deliberately, never as a probe. Every "never relaunch" rule in this file means "never
  bypass the engine" (raw `oracle` calls, deleting cooldown/lock/reservation files) — but
  the engine's redirect protects in-progress runs only, not completed or native-mode ones.
  Declare a review lost only when the HARVEST path itself says so (its exit 6 after
  repeated confirmed misses) — never because you lost the marker or the `--out` path.
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
  tab open, and `--harvest <marker>` collects the finished review later with NO new spend. A
  large diff (over `PRO_GATE_MAX_DIFF_LINES`, default 6000) rides that same path: it proceeds and
  is expected to land `in-progress`, to be harvested. Only a diff past the hard ceiling
  (`PRO_GATE_DIFF_HARD_MAX`, default 25000) is refused up front (exit 11), no slot spent.

**Codex on Windows:** run the engine through WSL, not native PowerShell path syntax. Use WSL repo paths
such as `/home/<username>/SITES/<repo>` and invoke commands with `wsl -e bash -lc '...'`; the default
engine home is `$HOME/.pro-review-daemon`.

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
- **Rounds:** `pro_gate_rounds_policy` (`converge` default | `bounded`) — how many engine
  runs this gate may spend (section 6). `converge` continues while rounds are strictly
  narrowing the findings, inside the engine's own per-change budget; `bounded` is the classic
  fixed ceiling. An explicitly set `pro_gate_max_rounds` is a hard ceiling under EITHER
  policy — a legacy config that sets only `pro_gate_max_rounds: 2` keeps its two-run cap
  under `converge` too. Only `bounded` supplies a default (2) when the key is absent.

  ```yaml
  # <repo>/.compound-engineering/config.local.yaml — every key optional
  pro_gate_mode: auto-fix          # review-only | auto-fix (default) | auto-fix+merge
  pro_gate_input: both             # both (default) | bundle | connector
  pro_gate_rounds_policy: converge # converge (default) | bounded
  pro_gate_max_rounds: 2           # hard ceiling under BOTH policies when set; bounded defaults to 2
  ```

  A missing file, missing key, or unparseable value means the documented default — never infer
  a stricter or looser policy from a malformed config.

## 2. Guardrails (before spending a ~10-30 min Pro review slot)

- **Session up (WSL/Linux):** `curl -sf localhost:9222/json/version` — if down, start it
  (`sudo systemctl start oracle-chrome`) and sign in via `login-view.sh` if the profile reset.
  On **macOS** there's no pre-check — oracle drives your signed-in Chrome and errors clearly if
  you're not logged in. `pro-gate-doctor.sh` checks all of this.
- **Low-memory machines (the review runs a real browser):** the Pro review drives a headless
  Chrome that needs memory headroom. On a small or busy machine the engine either DEFERS up front
  (exit 8, no quota spent) with a plain-language "low on memory" message, or — if memory runs out
  mid-review — Chrome restarts and the run ends exit 6 with a "review browser restarted mid-review,
  likely out of memory" note. Since v0.25 that restart is usually survivable: the engine remembers
  the conversation URL and re-renders it, so `--harvest` still collects the review even though the
  tab died with Chrome. It also prints a heads-up NOTE before a run when memory is tight but not
  blocking. Thresholds: `PRO_GATE_MIN_AVAIL_MB` (default 1024), `PRO_GATE_MAX_SWAP_PCT` (default
  97, the hard defer), `PRO_GATE_SWAP_WARN_PCT` (default 80, the soft heads-up). For users: close
  other apps / browser tabs / AI tools to free memory. `pro-gate-doctor.sh` reports the live state.
- **Usage (best-effort):** if codex auth is present, check `chatgpt.com/backend-api/wham/usage`;
  if the primary window is ≥90% or `limit_reached`, warn before burning a slot.
- **Concurrency is handled for you:** `oracle-review.sh` holds a counting semaphore —
  **serialized by default** (`PRO_GATE_MAX_CONCURRENCY=1`; raise it only if your account
  demonstrably tolerates parallel Pro chats). Concurrent `/pro-gate` calls (e.g. 10 agents at
  once) QUEUE, each waiting up to `PRO_GATE_LOCK_WAIT` (default 40 min). A separate per-change
  guard (engine ≥v0.22: keyed by PR, or repo+branch for `--diff`) stops the same change being
  reviewed twice at once.
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
- **Review round budget (engine ≥v0.22):** unbounded review→fix→re-review loops have burned
  10-16 Pro slots on a single PR in one day (8h+ of wall clock; every other queued PR starves).
  The engine refuses a fresh run for a PR (repo+branch for `--diff`) that already spent
  `PRO_GATE_MAX_ROUNDS_PER_PR` (default 4) slots inside the rolling `PRO_GATE_ROUNDS_WINDOW`
  (default 24h): exit 12, NO quota spent. Harvests never count against it. This is the backstop,
  not the plan: design the gate around section 6's convergence policy so you never hit it.

## 3. Run the review

Launch the engine in the background (it blocks ~10-30 min) and poll its **status file**:

```bash
"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"/oracle-review.sh \
  --pr <num|url> --repo <repo> --input <mode> \
  --out "${TMPDIR:-/tmp}/pro-gate-<num>.md" --timeout 30m
```

Run with `run_in_background: true`, and mind the clocks: real wall time is 10-47+ min (ledger
p90 ≈ 47 min), longer than many tools' own command caps (Claude Code's Bash tool kills at
30 min), so poll in short cycles — re-issue a fresh poll command every minute or two rather
than one long sleep — and never wrap the LAUNCH itself in a caller-side timeout shorter than
`--timeout` plus the lock wait. If your wrapper gets killed anyway, the engine keeps running
and the slot may already be spent: read the status file next, never relaunch on reflex. The
wait is free time — do useful parallel work and check back. The engine writes single-line JSON to
`<out>.status` at every phase change (`preflight → waiting-slot → launching → … → done|failed|deferred|in-progress|oversized|round-capped`):
poll THAT, not engine logs. Phase `done` ⇒ read `--out` (the `[Pn] file:line` blocks ending in a
`VERDICT:` line). `failed`/`deferred`/`in-progress`/`oversized`/`round-capped` are terminal for
this invocation: do NOT relaunch on `throttled`/`salvaging` phases; the engine is still working.
While waiting, never spawn a second oracle run for the same PR. The status JSON carries `marker`
(the run's conversation correlation id): you need it for `--harvest`.

Engine exit codes: `0` review ready · `2` bad usage · `3` oracle/browser missing · `4` repo not
found · `5` diff fetch failed · `6` ran but no usable review (quota may be spent — check the PR
conversation in ChatGPT before re-running; on a low-memory box this often means the review browser
restarted mid-run — the status `detail` says so, the review may still exist, free memory and retry
rather than blindly re-run) · `7` lock timeout · `8` deferred, NO quota spent
(box unfit, low memory, or throttle cooldown: safe to retry later) · `9` in-progress: the slot IS spent but
the model was still generating when the salvage budget ran out; the conversation tab is left
open: never submit a NEW review for it — harvest instead (below; a same-PR fresh-run
invocation is safe, the engine self-redirects to this harvest) · `11` oversized diff (past the hard ceiling
`PRO_GATE_DIFF_HARD_MAX`), NO quota spent: scope the payload (below); a merely large diff instead
proceeds and lands `in-progress` for harvest · `12` round budget exhausted, NO quota spent: this
PR/branch already used its review rounds for the window (section 6): do NOT re-run; post the
still-unresolved findings for the human, or set `PRO_GATE_FORCE_ROUND=1` for one deliberate
extra run. Committed fixes STAY on the branch (section 6, disposition). The exit-12 status `detail` also reports the change's last completed review as
"N P0 / M P1 unconfirmed by a re-review" when known: if it names an OPEN P0, put that at the
top of your escalation comment and explicitly ask the human whether to grant
`PRO_GATE_FORCE_ROUND=1`.

**Exit 9 (`in-progress`): harvest, don't respend.** The Pro model can reason for 45-90+ minutes
on a heavy payload (observed 65 min on 2026-07-09): longer than the engine can hold a review
slot. The engine frees the slot, leaves the run's conversation tab open, and puts the marker in
the status JSON. Wait ~10 min, then collect with:

```bash
STATUS=<out>.status
MARKER="$(jq -r .marker "$STATUS" 2>/dev/null || sed -nE 's/.*"marker":"([^"]+)".*/\1/p' "$STATUS")"
"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"/oracle-review.sh \
  --harvest "$MARKER" --out <out> --timeout 20m
```

Harvest exits: `0` review ready · `9` reservation retained, try again later (still generating;
absent this pass but under the consecutive-miss threshold; or the browser was unreachable for
the whole pass, which counts as NO miss) · `8` deferred (cooldown: retry after) · `6`
conversation gone after repeated misses (only NOW is a fresh run justified) · `7` another
collector already holds this marker (wait for it; do not race it) · `3` runtime/CDP trouble;
reservation and tab kept (retry once the browser is healthy). Repeat harvests are free: no Pro
quota is spent. Reservations are keyed by repo-scoped PR identity, so identical PR numbers in
different repositories never cross.

**A lost TAB is not a lost review (v0.25).** ChatGPT keeps conversations server-side, so the
engine remembers each run's conversation URL the first time it proves which one is that run's,
and re-renders that URL when no open tab carries the marker. A Chrome restart — routine when the
box is short on memory — therefore no longer destroys a finished review. Before v0.25 it did:
"conversation gone" really meant "no open Chrome tab has it", and 46 of 200 logged runs were
declared lost while their reviews sat complete in ChatGPT. If you still get exit 6, open the
conversation in a browser before spending another Pro slot — and if the review IS there, that is
a bug worth reporting, not an expected outcome.

**Large diffs (v0.24): cook, don't refuse.** The deep think IS the point of this gate, and the
engine already harvests a review that outlasts the slot window for free. So past the *cook*
threshold (`PRO_GATE_MAX_DIFF_LINES`, default 6000) the run **proceeds**: expect it to exit 9
(`in-progress`) and collect the verdict with `--harvest` (no new slot spent). A big diff is the
harvest path, not a wall. Only past the *hard ceiling* (`PRO_GATE_DIFF_HARD_MAX`, default 25000)
does the engine still refuse up front (exit 11, no spend): a payload that large risks context
overflow and is almost always a generated blob the filter missed.

**Exit 11 (`oversized`): scope the gate.** When you do hit the hard ceiling (or you deliberately
want to narrow a sprawling, unfocused diff rather than cook the whole thing), scope the final gate
to the delta that has NOT already cleared earlier tiers, with full-file context for the trust
boundary:

```bash
git -C <repo> diff <last-gated-sha>..<head> > delta.patch
"${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"/oracle-review.sh \
  --pr <num|url> --diff delta.patch --repo <repo> --extra-files 'lib/critical-*.sh' --out <out>
```

Keep `--pr` when the delta belongs to a PR (engine ≥v0.22.1): it keeps the change identity,
budget, lock, and reservations on the PR key instead of forking a second repo+branch identity.

## 4. Synthesize

Parse the findings into P0/P1/P2/P3. Treat the Pro review as high-trust but not infallible: for any
P0/P1, sanity-check it against the actual code before acting (it occasionally misreads context).
Drop or down-rank anything clearly wrong; keep the rest. Present a short table (severity · file:line ·
issue · your confidence) plus the verdict.

## 5. Act (per mode)

- **review-only:** post the findings as a PR comment (`gh pr comment <num> --body-file`), headed
  with the run's resolved model (the status file's `model` field, `jq -r .model <out>.status`;
  role-based text when unreadable, never a hardcoded version) and the `model_warn` note when it is
  non-empty, then stop.
- **auto-fix:** route confirmed P0/P1 (and clear P2s) to the **best available fixer**, in order:
  (1) if the Compound Engineering plugin is installed → `/ce-work` (native tiering since CE 3.17.1
  routes to codex when appropriate; skip if the codex doghouse `~/.codex/.doghouse` is tripped);
  (2) else if `codex` is on PATH → `codex exec`;
  (3) else → apply the edits yourself directly in this session. Then run available tests/lint, commit
  `fix(pro-gate): <summary>`, push, and post a PR comment with the review + what was fixed. Note in
  that comment which head SHA each engine run reviewed (section 6's final-commit rule needs it). Stop
  before merge — the human merges.
- **auto-fix+merge:** after fixes converge, follow the guarded-merge rules: merge only when CI is
  green, no unresolved P0/P1, and the diff doesn't touch high-risk domains
  (auth/payments/migrations/secrets) — otherwise escalate to the human.

## 6. Re-review (converge while it narrows, stop when it stops narrowing)

A Pro review of fresh code almost never comes back empty: every fix push is new code plus
reviewer nondeterminism, so "loop until clean" does NOT converge (observed: 10-16 rounds and
8h+ on one PR). But a fixed count regardless of trajectory throws away rounds that ARE
converging — multi-round gates whose later rounds resolved every prior finding have shipped
fully-clean PRs that a hard 2-round stop would have left open. The default policy is
**converge**: continue exactly as long as each round demonstrably narrows the problem.

Run a confirming pass — and continue to any round after it — ONLY while ALL of these hold
(they gate the FIRST confirming pass exactly like every later one):

- the previous verdict was non-terminal (not `SHIP`, not `NEEDS-DISCUSSION`) and confirmed
  P0/P1 fixes were applied in response to it (P2/P3-only fixes: commit, post, stop);
- no prior P0/P1 has come back after being fixed — every one RESOLVED or operator-settled;
- the new-P0/P1 count is strictly below the previous round's (shrinking, not churning; the
  first confirming pass has nothing to compare and passes this check trivially);
- the engine still grants rounds (no exit 12), and any explicitly configured
  `pro_gate_max_rounds` is not yet reached (it caps BOTH policies when set; `bounded`
  defaults it to 2).

Stop immediately when any of: verdict `SHIP`; a confirming pass reports no new P0/P1; a
finding you already fixed comes back (oscillation — the fixer and reviewer disagree and
another loop will not settle it: escalate, and the fix STAYS on the branch while the human
decides); the new-finding count did not shrink; verdict `NEEDS-DISCUSSION` (a human decision,
not a fix loop); engine exit 12; an explicitly configured `pro_gate_max_rounds` (or bounded
mode's default 2) is reached. On the last allowed round, still fix any new P0/P1 it
surfaced — they ship as "fixed, unconfirmed by a re-review" — and post new P2/P3 as notes.

Mechanics:

- Every pass MUST go through the engine (`oracle-review.sh`) like any other run, never
  through a direct `oracle --followup` call: the engine is the single source of truth for
  budget accounting, and a direct oracle call spends a Pro response the round budget never
  sees. The engine independently budgets ALL callers per change
  (`PRO_GATE_MAX_ROUNDS_PER_PR`, default 4 per rolling 24h, exit 12, section 2): the
  converge policy runs INSIDE that ceiling, it does not lift it.
- Run each confirming pass as:

  ```bash
  git -C <repo> diff <prev-round-head>..<fixed-head> > fix-delta.patch
  "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"/oracle-review.sh \
    --pr <num|url> --repo <repo> --diff fix-delta.patch \
    --confirm <prior-review.md> --out <outN> --timeout 30m
  ```

  KEEP `--pr` alongside `--diff`: without it the pass forks into a separate repo+branch
  identity with its own budget, lock, and reservations (engine ≥v0.22.1). `--confirm`
  attaches the prior review and instructs the model to verify EVERY prior P0/P1 as
  RESOLVED or STILL-PRESENT before reporting new findings, so an empty-looking response
  cannot be mistaken for confirmation.
- Stopping with unresolved P0/P1 is the DESIGNED outcome, not a failure: list them in the PR
  comment under **Unresolved (needs human decision)** so the human sees exactly what the gate
  could not settle, then end the gate. If the stop was engine exit 12 and its status detail
  reports an unconfirmed OPEN P0, lead the comment with that line and ask the human whether
  to grant `PRO_GATE_FORCE_ROUND=1` — that flag exists for exactly this case. It stays the
  human's call each time unless they have already granted extra rounds this session in so
  many words.

**Disposition of the work at ANY stop — read before touching the branch.** The gate reviews
code; it does not own the branch. When the gate stops — rounds exhausted, exit 12, a
confirming pass lost to infrastructure, findings still open — everything already committed or
pushed STAYS exactly as it is. Never revert, drop, narrow, or un-push work because review
budget ran out or a confirming pass could not be obtained: "fixed but unconfirmed" and
"stopped with unresolved P0/P1" are designed terminal states, and the code disposition they
call for is *leave it, disclose it, hand the decision to the human*. A revert is an
engineering decision, never a budget response: it is justified only when a review or a human
question shows the change's PREMISE is wrong — and even then, escalate with your
recommendation first (or leave the PR in draft with the recommendation posted) and let the
human rule unless they already have. The same applies one level up: an orchestrator whose
pro-gate step reports "stopped with unresolved findings" has received a normal terminal state
awaiting human sign-off, NOT a failure that licenses reverting commits or closing the PR.

**The final commit must be gated — or disclosed to the human.** Before merging, or before
declaring the gate complete, compare the PR's current REMOTE head against the head the last
engine run actually reviewed. Use the remote, not local git: record
`gh pr view <num> --json headRefOid -q .headRefOid` at the moment you launch each round, and
compare against a FRESH `headRefOid` at the end — the remote can move while a round waits on
locks or cooks, and a local `git rev-parse` cannot see that. Commits pushed after the final
gated round (last-round fixes, CI touch-ups, conflict resolutions) have never been
Pro-reviewed: either gate that delta (`--diff` of `<last-gated-head>..HEAD`, keeping `--pr`,
budget permitting) or say so explicitly in the PR comment under **Landed after the last
gated round**. Disclosure is a HUMAN-handoff path only: in `auto-fix+merge` mode an un-gated
head BLOCKS the automatic merge — gate the delta or escalate; never auto-merge a head the
model has not reviewed. Note each round's reviewed `headRefOid` in the audit-trail comment
as you go, so the final check is one `gh pr view` call.

Always leave an audit trail: the full Pro review + the fix summary as a PR comment. Head the
comment with the model the run resolved (the status file's `model` field, `jq -r .model <out>.status`;
role-based text when unreadable, never a hardcoded version), and include the status `model_warn`
downgrade note when it is non-empty.
