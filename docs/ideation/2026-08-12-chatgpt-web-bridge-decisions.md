---
date: 2026-08-12
topic: chatgpt-web-bridge-decisions
supersedes_partially: 2026-08-11-chatgpt-web-bridge-adoption-ideation.html (idea 1 landing venue)
mode: repo-grounded
---

# Decisions: ChatGPT-web bridge expansion

Follow-on to the 2026-08-11 ideation. Four operator questions, settled by an 18-agent pass:
5 fact-finders, 4 designs, 8 adversarial skeptics (2 per design, security + feasibility lenses,
refute-by-default), 1 synthesis. 1.54M tokens, 0 agent errors.

## Correction to the 2026-08-11 ideation

**Idea 1's implementation path was wrong.** That doc proposed vendoring rosetta's completion
contract into `bin/cdp-salvage.mjs`. That is structurally non-functional: `cdp-salvage.mjs` only
connects *after* a 600s stall, by which time the `/backend-api/f/conversation` exchange has already
completed, and **CDP does not replay historical network events to a late-attaching client**. The
completion signal must be captured by a session that is Network-enabled for the whole turn — that
is oracle, not pro-gate.

The *diagnosis* in that doc stands unchanged and was independently re-verified twice. Only the
landing venue changes.

---

## Q1 — codex-chatgpt-web into the Codex harness: DECLINE

**The premise does not apply here.** Codex CLI on this box runs `preferred_auth_method="chatgpt"`
with no API key in `auth.json` — it already bills the ChatGPT Pro plan natively. There is no
quota arbitrage left to capture.

Adoption cost is real and lands in a fragile place: its install rewrites top-level
`openai_base_url` in `~/.codex/config.toml` to a local Bun daemon (default
`http://127.0.0.1:17841/v1`) and writes a `[features]` table. Prior art on this exact hazard:
the 2026-07-03 incident where pointing the default provider at a local daemon (`better_ccflare`)
silently killed all Codex delegation for days once its OAuth expired.

Both skeptics returned `refuted=false / severity=none`.

- Security: its own `docs/security-model.md` names "prompt injection and destructive tool use" as a
  principal risk of full mode; the session daemon has no bearer secret and is reachable by any
  same-OS-user process; ChatGPT session cookies are stored in plaintext at
  `~/.codex-chatgpt-web/browser/storage-state.json`.
- Feasibility: bus factor 1 (178 contributions vs 1); 20 releases in 16 days spanning two major
  versions; pins Bun 1.3.14 against this box's mise-managed 1.3.5; README states the browser flow
  was "manually exercised end-to-end on macOS and Windows 11" only; `scripts/install.sh` hard-exits
  non-Darwin on the terminal-only path; zero Linux-specific issue reports across 854 stars.

**Note on the operator's framing.** `~/dotfiles/codex/` holds only `README.md`, `hooks.json`,
`sync.sh`, `tests` — it is a config-sync surface, not an app install location. "Add it to dotfiles"
was a category mismatch regardless of the verdict.

**Action:** none. Leave `~/.codex/config.toml` untouched. If Pro throughput ever becomes the real
itch, start with `caam status && caam ls codex`, not a browser bridge.

---

## Q2 — ChatGPT Pro read/write repo access: DECLINE (new write/shell), and fix the docs

### On the platform question

OpenAI's documentation is internally contradictory as of 2026-08:

- `developers.openai.com` states developer-mode "full MCP … read and write" is available to
  Pro/Plus/Business/Enterprise/Education with no tier carve-out.
- `help.openai.com`'s more specific and more recently updated article and FAQ restrict full
  write actions to Business/Enterprise/Edu.

The latter is treated as operative. **Confidence: probable, not verified.** The live check that
would have settled it for this account aborted (see below).

### The finding that changes something

The security skeptic proved pro-gate's own stated tenet does not describe the shipped system.

> README tenet: "the browser-driven model gets NO filesystem or shell access … it receives a diff
> bundle + PR URL and returns text findings."

`bin/oracle-review.sh` hardcodes `INPUT="both"` and ships a live `@GitHub` connector directive
instructing the Pro model to autonomously fetch "surrounding code, callers, tests, and history"
beyond the diff. The model therefore has first-party read access beyond the diff bundle today.

**Verdict unchanged, framing overruled.** What was found is a first-party, OpenAI-hosted,
*read-only* GitHub connector scoped to one PR's repo context — categorically different from a
self-hosted MCP server exposing shell-as-the-local-user over a tunnel (devspace) or unauthenticated
fs/exec (local-mcp). Declining new write/shell access stands on three independent grounds: the
review-only tenet, the Pro-tier gating, and the blast radius of shipping this to other people.

Also worth recording so it is not re-litigated wrongly: `docs/SETUP-NOTES.md` records the GitHub
connector "CONFIRMED working" on the Pro tier pro-gate targets. **"Pro cannot use MCP tools" is
false as a blanket claim** — the gating applies to third-party/custom connectors specifically.

### Why write access adds little anyway

pro-gate already implements the safe version of what write access would buy: the model returns
findings as text and a separate trusted local agent applies them. Inbound write access does not add
capability so much as remove a safety property — and it creates the textbook confused-deputy setup,
since the model reads repo and web content and would then write files.

**Actions (2):**
1. Correct the tenet wording in `README.md` so it describes what actually ships.
2. Audit and document the `@GitHub` connector's real OAuth grant scope — single-repo or org-wide.
   Currently unaudited anywhere in the repo or docs.

---

## Q3 — rosetta: ADOPT, SCOPED — into oracle, not pro-gate

**Vetting result: PASSES every criterion** in `~/dotfiles/claude/harness/third-party-skill-vetting.md`.
No prompt injection, no self-updating instruction channel, no phone-home, no postinstall scripts —
verified by a real `pnpm install --frozen-lockfile` + `pnpm test` run. MIT.
(There is no `/harness-vet` command; the doc is the process.)

Port `pro-final.ts` verbatim from rosetta commit
`12ed925a5381a9b2baad591f718182a059052f72`, with MIT notice and an `UPSTREAM.md`.

### Three corrections forced by the refutation passes

1. **Landing venue.** `~/SITES/oracle` is 86 commits behind upstream at v0.15.2 — the version this
   project's own memory records as broken by the GPT-5.6 Work-tab UI — while pro-gate consumes the
   globally installed `@steipete/oracle@0.17.2` (dist-only, no `src/`). There is no build/publish
   path from fork to production. Rebase the fork to parity first, or scope directly against
   `steipete/oracle` upstream. Dogfooding against the stale fork proves nothing about production.
2. **The bearer token must never leave the browser.** The sketched design extracted it Node-side for
   out-of-band REST polling. Production oracle already forbids this in its own source
   (`dist/src/browser/actions/navigation.js:719-721`): *"`/api/auth/session` … exposes user presence
   without requiring the bearer token used by `/backend-api/*`. Never return or log its token."*
   Fix: run the REST poll in-page via `Runtime.evaluate(fetch(...))`. This is also rosetta's own
   rationale for issuing requests from inside Chrome (TLS fingerprint / challenge evasion).
3. **The cited test fixtures are the wrong ones.** `tests/fixtures/mockClientFactory.cjs` and
   `mockPolyClient.cjs` mock the OpenAI Responses SDK client, not CDP. Fetch-domain mock scaffolding
   must be built from scratch.

Additionally: `Fetch.enable`/`Fetch.requestPaused` *pauses* matching requests pending
`continueRequest`. If the pattern matches oracle's own conversation-send, a bug in the continue
logic can hang or corrupt the production request. This needs an itemized estimate — not a
"small and mechanical" label.

### Split into two commits with a hard gate

- **(a)** Land `pro-final.ts` + new Fetch-domain fixtures, **inert and unwired**. Cheap, fully
  reversible, zero behaviour change.
- **(b)** The capture glue: Fetch interception, `turn_exchange_id` capture at submit, in-page REST
  poll. Expensive and sticky — new credential-adjacent surface in oracle's request path. Do not
  start until (a) has landed, (b) has its own itemized estimate, and the design constraint
  "token stays browser-side, always" is explicit.

Dogfood (b) behind `ORACLE_STRUCTURAL_COMPLETION=1` (default off) on pro-gate's own PRs before
flipping the default. **If primary-capture rate does not measurably improve, stop here and do not
proceed to Q4.**

---

## Q4 — Interactive Pro consults: BUILD, SCOPED AND GATED

Separate skill, outside pro-gate's authority model, sharing pro-gate's concurrency semaphore
(`pg_lock_n "$PRO_GATE_HOME/oracle.lock"`) and cooldown/ramp state.

**Why not a pro-gate feature:** the engine is PR-shaped throughout. The round governor scores a
shrinking P0/P1 trajectory; ledger rows carry `pr`, `round_key`, `diff_lines`. None of that has
meaning without findings to shrink.

**Sequencing correction.** "Prove it in the review path first" buys *zero* safety margin against the
credential-exposure risk — that exposure lands the moment Fetch-interception ships for reviews,
before any consult code exists. It is retired by fixing Q3's design, not by ordering. Sequencing
still matters for reliability, just not for that risk.

**Precedent to respect.** This is the fourth proposal of the shape "build fragile automation into
pro-gate's most-reworked subsystem." The convention
`ship-the-legible-core-let-the-gate-decline-fragile-automation` records three prior instances
(OOM self-heal, launchd auto-update timer, CC-plugin hint) each built, gate-reviewed 2-3 rounds,
then dropped as too fragile for a distributable. A demand-proving spike is therefore a hard gate,
not a nice-to-have.

**MVP:** one flat rolling-window budget file, one reservation-marker namespace **distinct from PR
markers** (reusing the PR-shaped schema risks a third cross-bind incident). No lock/governor
plumbing until the spike shows real recurring usage.

**hov-marketplace: hold.** Shipping a product whose compute is a personal ChatGPT web session
carries ToS, reliability, and support exposure that personal use does not. Gate on weeks of personal
dogfood plus an explicit consent/risk disclosure, and keep it out of the build PR entirely.

---

## Sequencing

1. **Q1 and Q2 are independent and actionable now.** Q1 needs no action. Q2 is a documentation
   correction plus an OAuth-scope audit — cheap and reversible.
2. **Q3 blocks Q4 completely.** Within Q3, (a) is cheap and reversible; (b) is expensive and sticky.
3. **The `ORACLE_STRUCTURAL_COMPLETION=1` dogfood is the go/no-go for Q4.**
4. **Q4's spike is cheap; its plumbing is not.** Spike before plumbing.
5. **Marketplace distribution is last and separately gated.**

## Do not do this

- Do **not** vendor rosetta into `bin/cdp-salvage.mjs` — it only attaches after a 600s stall, and CDP
  does not replay historical network events. Structurally dead.
- Do **not** extract the bearer token Node-side for any of these ideas.
- Do **not** land the port against `~/SITES/oracle` at its current v0.15.2 / -86 commits state.
- Do **not** take `@syntaxsmith/rosetta` as an npm dependency — it pulls a second full
  ChatGPT-driving engine (composer automation, live CoT WebSocket) that can race oracle on the same
  tab, and violates the zero-npm-deps tenet.
- Do **not** reuse pro-gate's PR-shaped reservation-marker schema for consult markers.
- Do **not** build a devspace/local-mcp-style write/shell connector in any scoping.
- Do **not** install codex-chatgpt-web, sandboxed or otherwise.

## Open questions only the operator can answer

- **Risk appetite on the capture layer.** Even with the browser-side-token fix, oracle would begin
  talking to undocumented private `/backend-api/*` surface rather than only rendering pages. That is
  a ToS-posture judgment, not a fact this pass can settle.
- **Whether to upstream the Q3 fix to `steipete/oracle`.** Changes how much generality the patch
  needs from day one.
- **Real demand for interactive consults.** The spike-first gate assumes genuine recurring use.
- **hov-marketplace intent** — whether third-party distribution is worth the disclosure and support
  cost, or whether this stays personal-use.

## Unresolved: the live account check

The agent tasked with reading this account's actual ChatGPT connector UI **aborted before touching
the browser**, per its own guardrail: pre-flight found an in-flight pro-gate review (two entries in
`~/.pro-review-daemon/in-progress/`, a live oracle process driving ChatGPT for PR #142 on
`StartupBros-com/better-ccflare`). A lost Pro slot costs more than the answer.

Re-run when the box is idle. Until then, the Pro-tier connector gating remains **probable, not
verified** for this account.

## Topology reference

pro-gate's Xvfb Linux Chrome (port 9222) and wsl-cdp's real Windows browser (9223/9224) are
structurally isolated: different processes, different profiles, and therefore **separate,
non-shared ChatGPT login sessions**. Documented in commit `d45284e` and `.env.example`.
