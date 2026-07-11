---
name: oracle-pro-extended-setup
description: "Working setup for driving the ChatGPT Pro reasoning model headlessly via steipete/oracle on WSL: the durable browser session, the exact flags, and the gotchas"
metadata: 
  node_type: memory
  type: project
  originSessionId: d4eee309-7475-4a68-b52d-723f0ba767f0
---

Will automates ChatGPT **Pro** PR reviews via `@steipete/oracle` (CLI+MCP that drives a logged-in Chrome ChatGPT session; the Pro reasoning tier is web-UI-only, no API). Built 2026-06-29 as the "pro-gate" final-tier reviewer after CE + Cloud review. Plan: `~/.claude/plans/swirling-jumping-tarjan.md`. See [[codex-delegation-setup]] (the codex fixer leg).

**PROVEN working path (WSL2, NAT networking):** own the Chrome, oracle attaches via `--remote-chrome`.
- Install: `pnpm add -g @steipete/oracle` (v0.15.0; bins `oracle`, `oracle-mcp` in ~/.local/bin).
- **Durable browser session = systemd system unit `oracle-chrome.service`** (enabled+active, survives reboot) → `~/.pro-review-daemon/run-oracle-chrome.sh`: starts `Xvfb :99` then headful `google-chrome` with **required WSL flags `--no-sandbox --disable-gpu --disable-dev-shm-usage`**, `--remote-allow-origins='*'`, CDP on `127.0.0.1:9222`, against persistent profile `~/.oracle/browser-profile` (stays signed in). Config in `~/.pro-review-daemon/.env`.
- **One-time login:** `~/.pro-review-daemon/login-view.sh` brings up x11vnc(:99)+noVNC on `localhost:6080` (WSL forwards localhost to Windows → open `http://localhost:6080/vnc.html` in Windows browser, sign in once). Login persists in the profile across reboots.
- **Invoke a review:** `oracle -e browser --remote-chrome 127.0.0.1:9222 -m gpt-5.5-pro -p "..." --write-output <file>`. Confirmed evidence (captured from the run, preserved verbatim as the original proof): `requested=Pro; resolved=Pro Extended; verified=yes`, i.e. `-m gpt-5.5-pro` lands on the Pro thinking tier. ~18s for a trivial prompt; real reviews ~10min (oracle `--timeout auto`=60m for Pro; long runs detach → reattach with `oracle session <slug>`, never re-run).

**GOTCHAS (cost hours):**
- `oracle`'s OWN Chrome launch (incl. `oracle serve --manual-login`) is **broken under WSL** — it does NOT pass the sandbox flags, so its internal launch dies `ECONNREFUSED`. Fix: we launch Chrome ourselves with the flags and use `--remote-chrome`.
- Use `--remote-chrome 127.0.0.1:9222` **NOT `--browser-attach-running`** — the latter scans for a `DevToolsActivePort` file only under `~/.config`/`~/snap`, so a profile at `~/.oracle/browser-profile` is never matched ("No running browser with attach metadata matched"). `--remote-chrome` is a direct CDP connect, no file scan.
- Set `ORACLE_BROWSER_ALLOW_COOKIE_ERRORS=1` (no Keychain cookie store on WSL). `oracle serve` under WSL also needs `ORACLE_ALLOW_WSL_SERVE=1` (we don't use serve in this path).
- Cloudflare does NOT block the Xvfb headful Chrome (reaches real ChatGPT login page, not a challenge wall).
- Self-inflicted trap when scripting: `pkill -f "oracle serve"` / `pkill -f "websockify.*6080"` match the **running script's own bash cmdline** → kills the parent shell (exit 144). Use `pkill -x <procname>` (exact name) or kill by PID.
- `~/.oracle/config.json` (JSON5) sets browser defaults (engine, model, manualLoginProfileDir, keepBrowser); CLI flags override. `oracle serve` bypasses it.

**BUILT + VALIDATED (2026-06-29):**
- **Engine** `~/.pro-review-daemon/oracle-review.sh` — assembles `gh pr diff` + `--file` + the PR URL, prompt **leads with `@GitHub` to bind the connector** (Will confirmed pasting `@GitHub` tags it; oracle's CDP insertText carries it — connector fetches correctly, verified twice). `ORACLE_CHATGPT_URL` (→ `--chatgpt-url`) optionally routes through a connector-bound ChatGPT Project. Outputs P0–P3 findings + VERDICT.
- **`/pro-gate` skill** (`~/.claude/skills/pro-gate/`) + **`oracle-reviewer` agent** (`~/.claude/agents/`, soft-fail launcher). Proven on prbot#720 (found 2×P1 + a refactor-regression P2 in 8m).
- **GitHub connector CONFIRMED** working in the automated session (fetched private StartupBros-com PR data exactly).
- **Daemon** `pro-review-daemon.service` (systemd, enabled) — watches `gh search prs --owner StartupBros-com --label pro-review`, per new head SHA spawns headless `claude -p "/pro-gate"` (auto-fix → push → PR comment → **STOP before merge**; fixes-only, no auto-merge yet). Guardrails: oracle-chrome up, `~/.codex/.doghouse`, `/wham/usage`, `~/.pro-review-daemon/PAUSE`. Sweep-safe `/tmp` worktrees, SHA idempotency in `processed.tsv`, logs in `logs/`. Validated live on marketplace-deal-sniper#4 (real commit + comment, no merge).
- Config: `~/.pro-review-daemon/.env`. **M3 guarded auto-merge = deferred** by Will's choice (add once trusted).

**Hardening (2026-06-29, after best-practice + concurrency review):**
- **Concurrency: oracle has NO cross-process lock in `--remote-chrome` mode** (tab-lease registry only activates with `--browser-manual-login`). So N concurrent `oracle` processes would all hammer the one ChatGPT account → throttling. FIXED: `oracle-review.sh` holds a `flock` on `~/.pro-review-daemon/oracle.lock` → concurrent `/pro-gate` calls serialize (queue up to `PRO_GATE_LOCK_WAIT`=2400s). 10 agents at once = safe, run one-at-a-time. Verified.
- **Prompt false-positive control:** mandatory `<file>:<line>` citation per finding + explicit "Do NOT flag" list (style/CI-enforced/generated/pre-existing/speculative). Per Cloudflare/Anthropic review-at-scale patterns.
- **Daemon cost+resilience:** headless `claude -p` bills API credits (post-2026-06-15) → added `--max-budget-usd` (default $5/PR), `--fallback-model haiku`, and a per-PR failure cap (`MAX_FAILS`=3, then give up to avoid poison-PR retry loops).
- Prior art: Doodlestein `planning-workflow` skill = the human-driven version of this cross-model review ritual; pro-gate is the agent-native automation. This pattern is new as of 2026-06-29.
- Optional future (researched, NOT yet done): structured JSON output from the Pro model for deterministic dedup; a global PreToolUse hook to block `git push` until tests pass; OTEL telemetry per daemon run; auto-tripping circuit breaker on N consecutive failures.
