---
date: 2026-08-12
topic: upstream-contribution-plan
mode: repo-grounded
---

# Upstream contribution plan: oracle's Pro-turn structural completion contract

Arbiter pass over two refutations of the prior recommendation ("open an RFC issue on
`steipete/oracle` before building anything"). Verdict: that recommendation is **overruled on
sequencing** by the contributor-cost lens (`refuted=true`, `severity=major`) and **upheld on
content** by the maintainer lens (`refuted=false`, `severity=minor`) for whenever an upstream ask
does go out. Both are reconciled below, not split.

---

## 1. Direct answers

**(a) Is local dogfooding needed before submitting? Yes, and it is available to start today —
the "impossible, the code is inert" framing in the prior recommendation was wrong.** Dogfooding
was never blocked on `steipete`. It was blocked on nobody having written commit (b), the capture
wiring, yet — and writing it requires zero external permission. `bin/oracle-review.sh:1384` and
`bin/pro-gate-doctor.sh:12` already resolve `ORACLE_BIN="${PRO_GATE_ORACLE_BIN:-oracle}"`, a
path override built for exactly this: point it at a local fork build's `dist/bin/oracle-cli.js`
and pro-gate runs against it with no publish rights, no fork-parity rebase beyond what's already
scoped, and no npm registry involved. `bin/pro-gate-stats.sh:86` already computes
`salvage_rate_pct` from the run ledger — the exact metric this whole initiative targets — so the
measurement instrument is also already built. This is also not a new idea invented for this
arbitration: `docs/ideation/2026-08-12-chatgpt-web-bridge-decisions.md` (Q3) and
`docs/ideation/2026-08-12-completion-contract-proof.md`, both already in this worktree, settled
on exactly this build-then-dogfood-then-measure plan independently, and the operator's current
two commits (`018374f7` inert port, `486b20eb` fail-open fix) are literally that plan's commits
(a) and (a2). Commit (b) — the wiring — is the next scheduled step, not a step gated on asking
permission first.

**(b) Does upstream want this? Plausibly, eventually — but that question cannot be resolved by
asking, and shouldn't be asked yet.** Recon supports genuine appetite: zero competing/duplicate
work exists anywhere in `steipete/oracle`'s issues, PRs, or code; the maintainer personally
re-touches this exact completion-detection boundary constantly (13 adjacent PRs in ~5 weeks per
`/tmp/oracle-fit/PRIOR-ART.md`); `docs/browser-mode.md:84` and `navigation.ts` already establish
in-page `/backend-api/*` fetches with token-redaction as the *official* login-detection pattern,
so a browser-side bearer relay is philosophically compatible with taste already on record. But
the two closest analogs to what would be submitted *today* are both rejections on the exact
failure mode this submission currently has: PR #287 stalled a month on missing live proof, and
PR #321 was closed for "safety surface too large for the proof given." Sending an RFC now doesn't
change that; RFC issues (the #355 precedent) get engagement when steipete has bandwidth, which is
bursty, not continuous, and even a "yes, interesting" reply wouldn't substitute for the live-proof
bar he personally enforced twice on the operator's own PR #301 (5 bot review cycles, 8 maintainer
hardening commits, a maintainer-run live Pro proof at the merge SHA). "Does upstream want this"
resolves the moment there is a working, dogfooded diff with real `salvaged`-rate numbers behind
it — not before, and no amount of additional GitHub research changes that.

---

## 2. Recommended move

1. **Build commit (b)** on the existing fork branch `feat/pro-turn-completion-contract`: `Fetch`
   interception to capture `turn_exchange_id` at submit, then an **in-page**
   `Runtime.evaluate(fetch('/backend-api/conversation/<id>', {credentials:'include'}))` poll —
   matching the same-file precedent already in `navigation.ts` for `/api/auth/session` /
   `/backend-api/me`, so the bearer token never leaves the browser (Q3's hard constraint). Wire
   `evaluateProTurnCompletion` as a **fallback signal alongside** `assistantResponse.ts`'s
   `classifyTurnTerminal`/`TERMINAL_GATE_CONFIG` (PR #301's DOM gate), not a replacement. Gate
   behind `ORACLE_STRUCTURAL_COMPLETION=1`, default off.
2. **Do the five-minute technical check first, inside step 1, not before it:** while
   signed in, confirm whether `/backend-api/conversation/<id>` requires `Authorization: Bearer`
   the same way issue #241 established `/backend-api/me` now does. This determines whether the
   in-page relay needs the token at all or can stay cookie-only; either way it's a fact the wiring
   code needs, so check it while writing the wiring, not as a separate upstream-facing step.
3. **`pnpm build`, point `PRO_GATE_ORACLE_BIN`** at the local fork's `dist/bin/oracle-cli.js`.
   Non-destructive, doesn't touch the pnpm-managed global `@steipete/oracle@0.17.2` install
   pro-gate uses in production.
4. **Dogfood on pro-gate's own PRs**, flag on, and read `bin/pro-gate-stats.sh`'s
   `salvage_rate_pct` against the recorded baseline (100% salvage, 12 days to 2026-08-03). Target
   ≥20 clean runs, matching the baseline's own sample size, before judging. Watch the two
   secondary signals the proof doc names: a new stall cluster near the 6-minute
   `POLL_IDLE_FLOOR_MS` region (defect A1, no-recap-ever, unresolved by construction), and a
   rising same-PR retry rate on second-or-later rounds (defect A6, fail-closed on regenerate,
   described in §4 below).
5. **Go/no-go on the numbers, not on a maintainer's opinion.** If `salvaged` doesn't measurably
   improve, stop — revert the flag, do not send anything upstream, do not proceed to Q4. If it
   does improve, *then* decide whether to go upstream, and if so, send a PR (drafted in §3 below),
   not an RFC issue — by that point there is exactly what clawsweeper asked for twice on #301:
   live proof, not a design pitch.
6. **Independent of all of the above, with zero dependency on oracle's decision:** send the
   rosetta bug reports now (§4). They cost nothing, don't touch oracle, and are good citizenship
   regardless of what steipete decides.

### What changed because of the refutations

The **contributor-cost lens** (`refuted=true`, `severity=major`) is upheld and controls the
sequencing change. Its core correction — dogfooding needs the operator to *build*, not to *ask* —
is right, evidenced by a lever (`PRO_GATE_ORACLE_BIN`) and an instrument (`pro-gate-stats.sh`)
that already exist, and by a same-worktree decision doc that had already reached this plan
independently before this arbitration started. It's also right that the prior recommendation's
RFC draft omitted a second real defect (A6, fail-closed on regenerate — found by the
completion-contract-proof pass, which the original recommendation predates) and the specific
`#241`-adjacent auth unknown, both of which a five-minute local check resolves faster than any
GitHub round-trip.

The **maintainer lens** (`refuted=false`, `severity=minor`) is right about content but was
evaluating the wrong artifact at the wrong time: its three fixes (state explicitly how the network
signal composes with the #301 DOM gate; disclose the polling/rate-limit exposure of repeatedly
hitting a private endpoint for a multi-minute turn, anchored to the existing
`autoReattachIntervalMs`/`--browser-auto-reattach-interval` precedent; arrive with the concrete
attribution mitigation instead of an open question) are preserved but retargeted into the §3 PR
draft below, to be spent once there's proof to attach, not spent on a pre-code permission request.

---

## 3. Ready-to-send drafts

**Do not send anything to `steipete/oracle` yet.** The draft below is complete and correct as
prose, but its Validation section requires real numbers from the dogfood run in §2 that do not
exist at the time of writing this plan. Sending it before that data exists reproduces exactly the
failure pattern of PR #287 (stalled a month, missing proof) and PR #321 (closed, "safety surface
too large for the proof given"). Fill in the bracketed line, delete the bracket, and only then
open the PR.

### PR title
```
fix(browser): add structural (backend-api) completion proof for Pro turns, behind ORACLE_STRUCTURAL_COMPLETION
```

### PR body

```markdown
## Problem

#301 (merged 2026-07-11, mine) replaced "stop button absent + text stable" with a DOM-based
positive terminal gate (`classifyTurnTerminal`/`TERMINAL_GATE_CONFIG`) to stop ChatGPT Pro's short
reasoning preamble from being captured as the final answer. It's been in production since 0.16.0
and it helped, but it hasn't closed the bug: #333 ("completed ChatGPT response is never captured
when thinking indicator is absent"), #284 ("thinking-state detection can miss (ChatGPT UI
drift)"), and #326 ("loses completed Pro answer after recoverable CDP disconnect") all landed
*after* #301 shipped, all against the same subsystem. The DOM layer keeps needing hardening
because CSS/visibility timing is inherently absence-based proof — it infers "done" from the
absence of "still working" signals, and every UI refresh can silently invalidate that inference.

## What this adds

A second, independent completion signal read from server state instead of the DOM: the
conversation mapping at `/backend-api/conversation/<turn_exchange_id's conversation>`. ChatGPT's
Pro turns emit a `reasoning_recap` node with `metadata.reasoning_status: "reasoning_ended"` before
the real terminal `text` node with `recipient: "all"` and `finish_details.type: "stop"` — a
structural graph relationship (`reasoning_recap` must graph-precede the terminal text, and no
`is_reasoning` sibling may remain incomparable with it) that's true regardless of what the DOM
currently renders. `evaluateProTurnCompletion()` in `src/browser/actions/proTurnCompletion.ts`
implements exactly that check and fails closed on any ambiguity — a same-turn `is_reasoning` node,
an unresolvable multi-branch tie — rather than ever returning a preamble.

**This is wired as a fallback signal alongside `classifyTurnTerminal`, not a replacement.** The
DOM gate stays live for when the REST poll is unreachable (rate-limited, schema drift, or a
non-Pro model where the mapping shape may differ — this function only activates when
`client.ts`'s existing `stream_handoff` gate confirms a Pro turn). If you'd rather see a different
composition (network-signal-primary with DOM as fallback, vs. today's DOM-primary with network as
corroboration), that's a one-line flip in the poll loop and I'm glad to send it either way — the
current shape is a starting position, not a claim there's only one right answer.

## Provenance

The completion-graph contract (`evaluateProTurnCompletion`) is ported from
[SyntaxSmith/rosetta](https://github.com/SyntaxSmith/rosetta), `src/pro-final.ts` @
`12ed925a5381a9b2baad591f718182a059052f72` (MIT). I ported it verbatim first (this PR's base
commit) specifically so the diff against the original stays reviewable, then patched one bug I
found in it (below) with every deviation marked `DEVIATION:` inline. Full MIT copyright + permission
notice is reproduced in `UPSTREAM.md` alongside the file, not just a header pointer, since a header
pointer alone doesn't satisfy the license's own text. rosetta is a single-maintainer, ~3-month-old
package (62 npm downloads/week) — not something I'd suggest taking as a dependency (and doing so
would also pull a second full ChatGPT-driving engine into oracle's process, composer automation
and a live CoT WebSocket, that could race this browser session) — but its completion-contract
logic is small, sound once patched, and worth having in-tree with attribution rather than
reinvented. I've filed the underlying bug against rosetta itself
(SyntaxSmith/rosetta#<TBD — see the two draft issues in this repo's ideation doc>), independent of
this PR.

## Bugs found while proving this out (both fixed here, neither existed in the DOM gate)

1. **Fail-open** (fixed, `DEVIATION` comment at the veto site): the original's active-reasoning
   veto only recognized `content_type === "thoughts" || content_type === "code"` as "still
   reasoning." A resumed-reasoning node tagged with any other `content_type` but
   `reasoning_status: "is_reasoning"` was invisible to the veto, so a mid-reasoning progress text
   could satisfy the terminal shape and get returned as final — reproducing the exact bug #301
   exists to fix. Fixed by keying the veto on `reasoning_status` alone (a strict superset of what
   the original caught). Regression test included.
2. **Fail-closed on regenerate** (documented, *not* fixed here, scoped out): the function never
   reads a `current_node` pointer. A regenerate/retry under the same `turn_exchange_id` — which
   pro-gate hits routinely, since it reuses conversations across review rounds — produces two
   independent complete `recap → final` branches, and the leaf-ambiguity check rejects both,
   because neither is a structural descendant of the other's `thoughts`/`code` node. The function
   can't yet tell "stray abandoned branch" from "genuinely complete regenerated answer the UI is
   currently showing." The real fix needs `client.ts`'s response type extended past `{mapping}` to
   carry `current_node` as a tie-breaker — real new surface, tracked as a named follow-up, not a
   blocker here, because the failure mode is bounded: it falls through to the DOM gate exactly as
   a stall does today, never a silent wrong answer.

## Design constraint enforced at the call site

A `{done: false}` result from this function must never, by itself, trigger a fresh Pro turn. It
must fall through to the existing DOM signal / eventual salvage path, same as any other stall
today. A false-negative that spawned a second Pro consult would burn a real Pro-tier turn on an
already-finished answer; a false-negative that falls back to today's path costs nothing beyond
today's baseline. This is enforced in the poll loop at `<call site file:line>` and covered by
`<test name>`.

## Polling behavior

The in-page poll runs at a fixed interval (`<N>`ms) with backoff on non-2xx, mirroring the
existing `autoReattachIntervalMs`/`--browser-auto-reattach-interval` pattern already in
`config.ts`/`browserDefaults.ts` rather than inventing a new cadence primitive. It stops polling
the instant the DOM gate independently confirms completion, so the two signals race to "done,"
they don't both run for the full turn.

## What's NOT proven

- **Fixture fidelity.** The unit-test fixtures (8 scenarios + 2 adversarial cases, in
  `proTurnCompletion.test.ts`) are hand-authored object literals corroborated by dated
  incident-tracking comments, not captured ChatGPT wire traffic — rosetta ships no HAR/replay
  fixtures either, and I don't have one to contribute. A wire-shape change invisible to any
  existing test fails closed (falls to the DOM gate), which is safe, but silently, so it's worth
  a second pair of eyes on the parsing assumptions specifically.
- **The long-run stall case.** Per this project's own recorded post-deploy notes, oracle already
  runs long Pro consultations in a detached worker, so the CLI can be silent by design on long
  runs; pro-gate's external 600s watchdog fires before *any* internal signal — DOM or REST — can
  report completion in that case. This PR plausibly helps short/medium runs and plausibly does not
  touch that long-run tail; the dogfood numbers below reflect that split where visible.

## Validation

Dogfooded against pro-gate's own PR reviews with the flag on, `PRO_GATE_ORACLE_BIN` pointed at a
local build of this branch, against pro-gate's `salvaged`-rate ledger metric (the fraction of
clean runs that needed post-hoc CDP salvage instead of capturing the answer in-run — the direct
measurement of the bug both #301 and this PR target).

[INSERT BEFORE SENDING — do not send with this line unfilled: N clean dogfood runs over
`<date range>`, primary-capture rate `<baseline>%` → `<after>%`, sourced from
`pro-gate-stats.sh`'s `salvage_rate_pct`, plus the two secondary-metric checks (no new stall
cluster near the 6-minute idle floor; no rise in same-PR-round retries) from
`$PRO_GATE_HOME/ledger.jsonl`.]

Happy to share the raw ledger rows or adjust anything about the composition/interval/scope above —
this is offered as one worked answer to the chronic capture problem, not a take-it-or-leave-it
diff.
```

**Why not an RFC issue instead:** an RFC without wiring or proof attached is asking the maintainer
to evaluate a hypothetical against the exact bar (#287, #321) that closes hypotheticals without
proof. A PR with dogfooded numbers gives him something concrete to redirect, narrow, or merge —
strictly more useful in less of his time, and it mirrors the only process that has actually worked
on this subsystem before (#301).

---

## 4. The rosetta bugs: report now, independent of oracle

**Yes, send both — today, with no dependency on the oracle decision above.** These are real,
regression-tested findings against someone else's shipped MIT code, rosetta has had zero issues or
PRs in its entire history (so there's no existing thread to duplicate or clutter), and reporting
costs nothing regardless of what `steipete/oracle` decides. Filing them is also better OSS
citizenship groundwork than anything aimed at oracle: it demonstrates the operator engages
upstream on both ends of a dependency chain, not just the one they want something from.

Two separate issues (one bug each — easier to triage, and defect 1 ships with a ready patch while
defect 2 doesn't):

### Issue 1

**Title:** `Active-reasoning veto misses resumed reasoning outside the {thoughts, code} content_type allowlist (fail-open)`

**Body:**
```markdown
`evaluateProTurnCompletion`'s active-reasoning veto only treats a node as "still reasoning" when
*both* conditions hold:

```ts
(message.content?.content_type === "thoughts" ||
  message.content?.content_type === "code") &&
message.metadata?.reasoning_status === "is_reasoning"
```

(`src/pro-final.ts`, current `main`.)

If a resumed-reasoning node carries `reasoning_status: "is_reasoning"` but a `content_type` other
than `thoughts`/`code` — a plausible future/renamed node type, and per the file's own doc comment
one of only four `content_type` values the algorithm branches on — the veto doesn't see it. A
terminal-shaped interim text produced while that node is active then passes every other check
(reasoning_ended precedes it, it's a leaf, it's the only leaf) and gets returned as
`{done: true, ...}` — a false-positive TERMINAL on a mid-reasoning progress text. This reproduces
the exact bug this function's design comment says it exists to prevent
("Pro can emit several short progress texts carrying both flags and then resume reasoning").

**Reproduction:** a mapping with `recap(reasoning_ended)` → a terminal-shaped interim text →
resumed reasoning tagged `content_type: "reasoning"` (not `thoughts`/`code`),
`reasoning_status: "is_reasoning"`. Current code returns
`{done: true, finalText: "Quick take: looks fine at a glance."}`. Expected: `{done: false}`.

**Suggested fix** (strictly more conservative — catches a superset of what the current check
catches, so it can't introduce a new fail-closed regression):

```ts
const activeReasoning = turnMessages.filter(({ message }) =>
  message.metadata?.reasoning_status === "is_reasoning"
);
```

i.e. drop the `content_type` restriction and key the veto on `reasoning_status` alone, matching
what the file's own comments describe as the actual state signal (`content_type` selects node
*kind*, `reasoning_status` is the real reasoning-state gate).

Found while porting this file into `steipete/oracle` (attributed, MIT, `src/pro-final.ts` @
`12ed925a5`) as a completion-detection fallback signal for a browser automation project. Happy to
open a PR with this fix + a regression test if that's useful — let me know your preference on
whether you'd rather review a diff or take the one-line change directly.
```

### Issue 2

**Title:** `Leaf-ambiguity check fails closed on a genuinely complete regenerated answer (no current_node tie-break)`

**Body:**
```markdown
`evaluateProTurnCompletion` never reads a `current_node` field. When a conversation has two
independent, both-complete `recap → terminal-text` branches under the same `turn_exchange_id` —
which happens on a regenerate/retry, a real and not-uncommon topology — the leaf-ambiguity check:

```ts
const leafCandidates = structurallySafe.filter((candidate) =>
  !structurallySafe.some((other) =>
    other.key !== candidate.key && isDescendantOf(mapping, other.key, candidate.key)
  )
);
if (leafCandidates.length !== 1) {
  return { done: false, reason: `ambiguous terminal text branches (${leafCandidates.length})` };
}
```

rejects **both** candidates as ambiguous, because neither is a graph descendant of the other. This
is correct behavior for a genuinely stray/abandoned branch (a real ambiguity), but it's the wrong
answer for a regenerate where the UI is currently displaying one specific, fully complete branch —
the function has no way to distinguish the two cases from the mapping alone.

The standard ChatGPT web-client contract exposes a `current_node` pointer at the top level of the
conversation response for exactly this purpose (which branch the UI is currently showing) — worth
confirming whether the raw `/backend-api/conversation/<id>` response your `client.ts` fetches
already carries it; if so, it's not currently read (`client.ts`'s cast to
`{mapping?: ConversationMapping}` discards anything outside `mapping`, and neither `src/` nor
`tests/` reference `current_node` anywhere).

**Reproduction:** two complete `recap → final` branches under one `turn_exchange_id`, neither a
descendant of the other. Current: `{done: false, reason: "ambiguous terminal text branches (2)"}`
for both candidates. Expected: accept the branch pointed to by `current_node`, if present.

I don't have a fix ready for this one — it needs the response type widened past `{mapping}` and
the tie-break threaded through as a new parameter, which felt like more of a design call than a
drive-by patch — but wanted to flag it since it's a real gap and I hit it building a caller around
this function. Happy to attempt a PR if you'd rather have a starting point than a blank page; also
happy to just leave this as a tracked issue if you'd rather design the API surface yourself.

(Filed alongside a related fail-open finding in the same function — see #<issue-1-number> — found
during the same porting/review pass.)
```

---

## 5. What NOT to do

- Do not open the RFC issue on `steipete/oracle` now. It would ask a maintainer to evaluate a
  hypothetical against a bar (#287, #321) that specifically closes hypotheticals without proof —
  strictly worse than waiting for the dogfood numbers and sending the PR in §3 instead.
- Do not send the §3 PR with the `[INSERT BEFORE SENDING]` line unfilled. That reproduces the
  exact failure pattern the recon found twice.
- Do not skip building/dogfooding commit (b) on the theory that "asking first is more polite" —
  the operator doesn't need permission to fix their own tool, and `PRO_GATE_ORACLE_BIN` +
  `pro-gate-stats.sh` already make that path safe, local, and measurable.
- Do not extract the bearer token Node-side at any point in the wiring — it must stay in-page
  (`Runtime.evaluate(fetch(...))`), matching production oracle's own stated constraint in
  `navigation.ts` and Q3's hard requirement.
- Do not fold `current_node` plumbing (rosetta Issue 2 / defect A6) into commit (b)'s first cut —
  it's real new surface, correctly scoped out as a named follow-up in the completion-contract-proof
  doc, not a blocker for the dogfood-and-measure step.
- Do not take `@syntaxsmith/rosetta` as an npm dependency in oracle — already ruled out in the
  2026-08-12 decisions doc (second full ChatGPT-driving engine, can race oracle's own session).
- Do not flip `ORACLE_STRUCTURAL_COMPLETION` to default-on, or proceed to the Q4 interactive-
  consult work, until the dogfood window's `salvaged` rate has measurably improved — restated from
  Q3/the proof doc, unchanged by this arbitration.
