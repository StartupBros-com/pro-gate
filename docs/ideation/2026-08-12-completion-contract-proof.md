---
date: 2026-08-12
topic: completion-contract-proof
mode: repo-grounded
---

# rosetta's completion contract: what the proof pass actually established, and the operator's next action

Follow-on to `2026-08-12-chatgpt-web-bridge-decisions.md` (Q3: "ADOPT, SCOPED — into oracle, not
pro-gate"). That doc scoped the landing venue and commit split from static reading. This pass
built and ran the real `evaluateProTurnCompletion` function against fixtures and adversarial
inputs. Result: **the mechanical semantics are proven correct** against every documented pro-gate
incident shape, **and** the adversarial pass found two real defects in the algorithm itself —
one fail-open, one fail-closed — that Q3 did not know about and that change the PR plan. Nothing
here contradicts Q3's venue/token/commit-split findings; this narrows what ships in commit (a).

No ChatGPT Pro slots were spent producing this document. All work was against local files, a
cloned copy of rosetta, and a standalone Node harness.

---

## 1. What is now proven

**Proven — the ported function is byte-identical to rosetta's real source.**
`diff -u pro-final.ts pro-final.mjs` shows only TypeScript type annotations/interfaces removed
(all unread at runtime); every executable line, string, and comment is unchanged. Independently
re-diffed and confirmed. `pro-final.ts` in the harness directory is byte-identical to the file at
commit `12ed925a5381a9b2baad591f718182a059052f72` in the actual rosetta clone (`git rev-parse HEAD`
matches; `diff` exit 0).

**Proven — the function behaves correctly on every documented incident shape.** 8/8 fixtures
passed against the verified-identical copy, run with `node harness.mjs` (exit 0, no try/catch, no
weakened assertions — every pass/fail is a strict multi-field check on `finalText`,
`finalMessageId`, `finishReason`, or an exact `reason` string):

| Scenario | Status | Result |
|---|---|---|
| S1a preamble mistaken for final | DOCUMENTED (oracle-preamble-completion-rootcause.md) | correctly rejects (`done:false`) |
| S1b same conversation, real answer lands later | DOCUMENTED | correctly returns the real answer, ignores the ancestor preamble |
| S2 genuine terminal answer, no preamble | baseline | correctly accepts |
| S3a cross-bind, foreign turn's answer in same mapping | DOCUMENTED (CHANGELOG.md v0.31.1 #67) | correctly rejects — immune by construction (`turn_exchange_id` filter) |
| S3b benign reused conversation, older completed turn | required flip side of the v0.31.1 fix | correctly returns only the current turn's answer |
| S4 reasoning-sibling ambiguity | PLAUSIBLE (proposed) | correctly fails closed |
| S5 in-progress, no recap yet | baseline | correctly rejects |
| S6 weak/instant model, no `reasoning_status` anywhere | PLAUSIBLE (grounded in `PRO_GATE_MODEL_STRATEGY=current`) | correctly rejects (would hang forever if a caller routed it here unconditionally — a dispatch-gating requirement, not a `pro-final.ts` bug) |

A discriminating-power control: an always-`{done:false}` stub run against the same harness
assertions scored 0/8 — every accept case requires exact `finalText`/`finalMessageId`, every
reject case requires an exact `reason` string, so the harness cannot be satisfied by a stub.

**Proven — two real defects in the algorithm, found by adversarial fixtures against the same
verified-identical copy, both empirically run (not reasoned about):**

1. **Fails OPEN, reproducing the exact S1 bug it exists to fix.** The active-reasoning veto at
   `pro-final.ts:117–121` is a hardcoded allowlist: it only treats a node as "still reasoning" if
   `content_type` is exactly `"thoughts"` or `"code"` **and** `metadata.reasoning_status` is
   `"is_reasoning"`. A fixture with `recap(reasoning_ended)` → a terminal-shaped interim text →
   resumed reasoning tagged `content_type:"reasoning"` (not `thoughts`/`code`) but
   `reasoning_status:"is_reasoning"` returns `{done:true, finalText:"Quick take: looks fine at a
   glance."}` — a false-positive TERMINAL on a mid-reasoning progress text, defeated by one
   `content_type` value the veto's two-string allowlist doesn't recognize. This is not a
   contrived edge case: `WIRE-SHAPE.md` itself documents `content_type` as "the four values the
   algorithm branches on" (`reasoning_recap`, `text`, `thoughts`, `code`) — any fifth value
   OpenAI ships for a renamed or new resumed-work node type (a plausible product change, not a
   wire-format break) silently reopens the exact bug this contract was built to close.

2. **Fails CLOSED on a genuinely complete, UI-displayed answer, in a shape pro-gate is known to
   hit routinely.** `evaluateProTurnCompletion` never reads a `current_node` field (confirmed
   absent from every field cited in `WIRE-SHAPE.md`, and absent from rosetta's own source and test
   suites entirely — `grep -rl current_node` across rosetta's `src/` and `tests/` returns
   nothing). Two independent, both-complete `recap → final` branches under the same
   `turn_exchange_id` (a regenerate/retry — pro-gate reuses conversations across review rounds,
   per its own architecture) cause the veto to reject **both** candidates
   (`"active or graph-incomparable reasoning remains for final text candidate"`), because neither
   final text is a descendant of the *other* branch's `thoughts`/`code` node. The function cannot
   distinguish "stray abandoned branch" (S4, correctly rejected) from "genuinely complete
   regenerated answer the UI is currently showing" (wrongly rejected) — the one field the real
   ChatGPT API is understood to expose for exactly this purpose is never plumbed through.

**Explicitly NOT proven:**

- **Real-traffic fidelity.** Rosetta ships zero HAR/recorded/replay fixtures anywhere in its
  repo or history (a README claim to the contrary has no corresponding file). Every fixture in
  this proof — including the 6 sourced from `SCENARIOS.md` — is a hand-authored TypeScript object
  literal, circumstantially corroborated by dated code comments, not validated against captured
  ChatGPT traffic. The proof shows the *function* behaves as designed against these shapes; it
  does not show the shapes are what the real API sends.
- **Whether a genuinely complete Pro turn can ever land with no `reasoning_recap` at all**
  (adversarial fixture A1: a lone finished text node, no recap, ever). No test anywhere in
  rosetta's own suite, `WIRE-SHAPE.md`, or `SCENARIOS.md` exercises this as an accept case. If it
  happens for trivial prompts or a mid-turn silent model downgrade, the function returns
  `done:false` **permanently** for that turn — unresolvable from a single mapping snapshot, since
  "recap hasn't landed yet" and "recap will never land" are indistinguishable without polling
  over time.
- **Whether the raw `/backend-api/conversation/<id>` response actually carries a top-level
  `current_node` field.** This is the standard ChatGPT web-client contract, but nothing in this
  proof bundle or in rosetta's source confirms it — `client.ts`'s own cast
  (`resp.body as {mapping?: ConversationMapping}`) discards anything outside `mapping`, so even if
  the raw JSON has it, no code path in rosetta reads it today.
- **Integration into oracle.** This proves `evaluateProTurnCompletion` in isolation. It is not an
  integration test of the function wired into oracle's poll loop, CDP session, or `client.ts`'s
  dispatch gating.
- **Whether this closes pro-gate's dominant current failure mode.** Per
  `pro-gate-v030-post-deploy-verification.md`, oracle 0.17.0 already runs long Pro consultations
  in a detached worker, so the CLI is often silent by design on long runs — pro-gate's external
  600s watchdog kills the process before *any* internal signal, DOM or REST, can report
  completion. Swapping the completion-signal source doesn't touch that process-visibility problem.
  The plausible win is on short/medium runs where the CLI stays attached; the long-run
  stall→salvage pattern would plausibly persist unchanged. This is reasoned, not measured.

---

## 2. Whether to proceed

**Proceed with landing the contract — but not verbatim, and not by wiring it live.** The two
defects above are real algorithm bugs, not vendoring or venue problems, and both must be fixed
before commit (b) (the capture glue) is written — Q3's plan is amended, not reversed:

- **Defect 1 (fail-open) is the harder blocker.** It reproduces the chronic bug under a plausible
  future/renamed node type. Fix: widen the active-reasoning veto to key on
  `metadata?.reasoning_status === "is_reasoning"` alone, dropping the `content_type ===
  "thoughts" || content_type === "code"` restriction (`pro-final.ts:117–121`). This is strictly
  more conservative (catches a superset of what the original caught) and matches the contract's
  own documented design intent per `WIRE-SHAPE.md`: `reasoning_status` is "the positive recap gate
  and the negative still-reasoning gate" — the true signal — while `content_type` selects node
  *kind*, not reasoning *state*. Ship as a deviation from upstream rosetta, documented inline, with
  a regression test built from adversarial fixture A2 asserting `done:false`.
- **Defect 2 (fail-closed on regenerate) requires a caller-level design constraint, not just a
  `pro-final.ts` patch.** Per the task's own framing: a missing/ambiguous signal must be a
  distinct outcome, not folded into blanket `INCOMPLETE`. Concretely: `INCOMPLETE Pro turn` from
  this function must **never**, by itself, trigger a caller retry with a fresh Pro turn — it must
  fall through to the existing DOM signal / eventual CDP salvage, exactly as today's architecture
  already does on a stall. A false-negative `INCOMPLETE` that spawns a second Pro consult would
  burn a real Pro slot on an already-finished answer; a false-negative that instead falls back to
  today's salvage path costs nothing beyond today's baseline. This must be an explicit, written
  design note in the PR, checked in review, since nothing in `pro-final.ts` enforces it — it lives
  entirely in whatever caller wraps this function.
- **The `current_node` plumbing (the real fix for defect 2) is out of scope for commit (a)/(a2)**
  and should not block them: it requires extending `client.ts`'s response type beyond `{mapping}`
  and passing the pointer into the tie-break logic as a third argument — real new surface, not a
  documented one-liner. Track it as a named follow-up gate on commit (b), not a precondition for
  landing the inert vendor commit.
- **Defect A1 (no-recap-ever) is not fixable inside `pro-final.ts`** — a single snapshot cannot
  distinguish "not yet" from "never." The mitigation is caller-side debounce (poll again after a
  short window before trusting a sustained "no recap, no reasoning" state), mirroring the pattern
  oracle's own DOM gate already uses (`barConfirmCycles` — N stable poll cycles before trusting an
  absence signal). Document as a commit (b) design requirement; not a blocker for (a).

No case where the contract fails closed on a *baseline, undisputed* complete turn (S1b, S2, S3b
all correctly accept) — the fail-closed defect is scoped to the regenerate/reused-conversation
topology specifically, which is real and known-common for pro-gate but not universal.

---

## 3. The exact PR plan

**Repo/branch.** Fresh branch off `steipete/oracle` `main` (current upstream tip, currently
0.17.2 per `npm view`), **not** `StartupBros/oracle`'s stale fork (v0.15.2, its
`fix/completion-terminal-gate` work already merged and superseded upstream as PR #301 — see
`VENUE.md` §2). Mirror PR #301's process: same maintainer, same repo, a normal upstream
contribution. Branch name: `feat/pro-turn-completion-contract`.

**Files.**
- `src/browser/actions/proTurnCompletion.ts` — the ported+patched contract (co-located with
  `assistantResponse.ts`, `thinkingStatus.ts`, the existing DOM completion-detection files it
  supplements). New file, MIT notice, `UPSTREAM.md` pointer to rosetta commit
  `12ed925a5381a9b2baad591f718182a059052f72`.
- `src/browser/actions/proTurnCompletion.test.ts` — regression fixtures: the 8 scenarios from
  this proof (S1a/S1b/S2/S3a/S3b/S4/S5/S6) plus the two adversarial cases (A2 as a must-reject
  regression test post-fix; A1 documented as a known-unresolved case with an explicit `.skip` or
  comment, not silently dropped).
- Fetch-domain mock scaffolding for the in-page REST poll — built from scratch per Q3 finding 3
  (`tests/fixtures/mockClientFactory.cjs`/`mockPolyClient.cjs` mock the OpenAI SDK client, not
  CDP, so they don't transfer).

**Commit (a) — inert, unwired, zero behavior change.**
Vendor `proTurnCompletion.ts` verbatim from rosetta (for clean upstream diffability/provenance)
+ new test file + `UPSTREAM.md`. Not imported anywhere. Fully reversible.

**Commit (a2) — the two fixes, still unwired.**
Widen the active-reasoning veto (defect 1) with the A2 regression test. Add the explicit
caller-contract design note as a code comment on the exported function (defect 2's constraint:
"a `done:false` result MUST NOT independently trigger a fresh Pro turn"). Still zero behavior
change — nothing calls this function yet.

**Commit (b) — the capture glue. Expensive, sticky, new credential-adjacent surface.**
Fetch interception to capture `turn_exchange_id` at submit, then an **in-page** REST poll
(`Runtime.evaluate`-driven `fetch('/backend-api/conversation/<id>', {credentials:'include'})`,
matching the existing in-page-fetch pattern oracle already uses for `/api/auth/session` and
`/backend-api/me` in `navigation.ts:788,848` — including that pattern's own learned Cloudflare
body-sniffing fallback, since `/backend-api/*` is documented to sit behind the same bot
mitigation). The bearer token never leaves the browser — Q3's hard constraint, now with a direct
same-file precedent to copy rather than invent. Wire this as a **fallback signal alongside**
`assistantResponse.ts`'s existing `classifyTurnTerminal`/`TERMINAL_GATE_CONFIG`, not a
replacement — the DOM gate stays live for when the REST poll is unreachable (rate-limited, schema
drift, non-Pro turns per S6). Do not start commit (b) until (a2) has landed and its own itemized
estimate for the `Fetch.enable`/`Fetch.requestPaused` continue-logic risk exists (Q3's own open
item — a bug there can hang or corrupt oracle's own conversation-send request).

**Env-var gate.** `ORACLE_STRUCTURAL_COMPLETION=1`, default off (Q3's naming, unchanged). Staged
locally in pro-gate via the already-wired `PRO_GATE_ORACLE_BIN` path override — point it at a
local build of the fork branch's `dist/bin/oracle-cli.js`, no publish rights needed, no touching
the pnpm-managed global install (`VENUE.md` §3).

**Getting in front of a real run without burning slots.**
1. `pnpm test` on the new fixtures — zero Pro spend, catches regressions before any live run.
2. Dogfood on pro-gate's *own* PRs only, flag on, `PRO_GATE_ORACLE_BIN` pointed at the local
   build. Pro-gate's existing 600s stall watchdog and salvage path are the safety net if the REST
   poll misbehaves — worst case reproduces today's baseline, not a new failure mode, *provided*
   the defect-2 caller-contract (no auto-retry on `INCOMPLETE`) is actually honored in the glue
   code, which is why it's a named review-gate item for commit (b), not just a comment.
3. Only after a clean dogfood run count (see §4) does the flag default flip.

---

## 4. The measurement plan

Read from `$PRO_GATE_HOME/ledger.jsonl` (`pg_ledger_append`, one line per finished/deferred run —
`bin/oracle-review.sh:840–858`). Confirmed real fields on every row: `ts, pr, repo, exit, outcome,
secs, attempts, conc, ceiling, live, salvaged, diff_lines, out, model, marker, round_key, sha256`.

**Primary metric: primary-capture rate.**
```
1 − mean(salvaged) over rows where outcome == "clean"
```
`salvaged` (0/1) is set exactly where a run recovered via `cdp-salvage.mjs` (probe hit, reattach,
or post-stall capture — `bin/oracle-review.sh:907,1123,1207,1982,2105`) rather than the primary
in-run capture path. This is the direct, already-instrumented measurement of the bug this whole
initiative targets — no new instrumentation needed.

**Baseline.** Per the grounding memory: 100% of clean runs completed via salvage rather than
primary capture over the 12 days to 2026-08-03 (0/22 on one day). Compare the flag-on dogfood
window's `salvaged` rate against that baseline over an equivalent run count (aim for ≥20 clean
runs before judging, matching the baseline's own sample size).

**Secondary metrics, same file, to catch the two proven defects in production:**
- `secs` distribution on `salvaged=0` rows, specifically watching for a **new upper cluster**
  near the 6-minute idle-floor timeout region (rosetta's own `POLL_IDLE_FLOOR_MS`) — that would be
  defect A1 (no-recap-ever) manifesting as a stall on a genuinely trivial, already-complete answer
  that today's DOM gate would have caught instantly.
- `outcome == "failed"` rate and `attempts` count, specifically on `marker`/`round_key` pairs
  known to be a *second or later* round on the same PR (pro-gate's own reuse-across-rounds
  pattern) — a rise here is the observable signature of defect 2 (regenerate fail-closed) causing
  a wasted retry instead of an accept.
- Any `model` field showing a non-Pro/`current` strategy hitting the new code path at all would be
  S6's dispatch-gating failure — should never happen if commit (b)'s gate on `stream_handoff`
  presence (Q3 finding, `client.ts:1194–1206` in rosetta) is correctly ported.

**Go/no-go, restated from Q3 with the added defect-watch:** if `salvaged` rate does not
measurably improve over the baseline within the dogfood window, stop — do not flip the default,
do not proceed to Q4. If either secondary metric regresses (new stall cluster, or rising
same-PR retry rate), that is evidence of defect A1 or defect 2 surfacing in production even after
the (a2) mitigations — revert the flag, do not patch around it live.

---

## 5. Residual risks the operator accepts by proceeding

1. **Fixture fidelity is unverified against real traffic.** Every fixture (this proof's and
   rosetta's own 54 tests) is hand-authored TypeScript, not captured ChatGPT wire data. A wire-shape
   difference invisible to any existing test (e.g., `parts[0]` becoming a `{type,text}` object
   instead of a bare string under a Responses-API-style content change) fails closed — safe, but
   as a **silent, full, permanent capability loss** with no alerting, indistinguishable from a
   generic stall until someone notices the `salvaged` rate climb back to baseline.
2. **Defect 2's real fix (`current_node` plumbing) is deferred, not shipped.** Until it lands,
   regenerated/reused-conversation turns can fail closed and fall back to salvage — bounded cost
   (today's baseline), not silent data loss, but a bounded regression is still a regression from
   "REST signal always wins" to "REST signal sometimes no-ops back to DOM," which is a lower
   bar than the initiative's stated goal.
3. **Defect 1's fix is a documented deviation from upstream rosetta, not a patch rosetta itself
   has accepted.** No upstream PR to rosetta has been filed; if rosetta's maintainer later ships a
   different fix (or a real fifth `content_type`) for the same gap, oracle's fork and rosetta
   diverge silently unless someone re-diffs on each rosetta bump.
4. **No `zod` or other runtime schema validation exists on the REST response anywhere in the
   inherited design** (`client.ts:1608`'s cast is unchecked). A malformed or throttled response
   body could throw inside the poll loop rather than degrading gracefully; this needs its own
   guard in commit (b), not covered by anything proven here.
5. **The initiative's stated core problem — long-run silent detached-worker stalls hitting the
   600s watchdog before any signal can report — is plausibly untouched.** The measurement plan in
   §4 will show this directly (no `secs` improvement in the long-run tail even if the overall
   `salvaged` rate improves for short/medium runs); the operator should expect a partial win, not
   full closure of the chronic bug, and should not be surprised if long-run pain persists after
   this ships.
6. **New credential-adjacent surface in oracle's request path** (`Fetch.enable`/
   `Fetch.requestPaused` interception) is inherently riskier than the DOM-only status quo — a bug
   in the continue-logic can hang or corrupt oracle's own conversation-send request, a failure
   mode DOM-only completion detection cannot cause by construction. Q3 already flagged this as
   needing its own itemized estimate; this proof pass did not reduce that risk, only confirmed the
   completion-signal logic itself (once patched) is sound in isolation.
