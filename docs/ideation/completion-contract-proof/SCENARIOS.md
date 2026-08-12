# Scenario specs: pro-gate/oracle capture failures as conversation-graph fixtures

Purpose: precise, testable specs of ChatGPT Pro conversation-mapping states, keyed to the
`evaluateProTurnCompletion(mapping, turnExchangeId)` contract in rosetta's
`src/pro-final.ts` (cloned at `/tmp/ce-ideate-7c3f1a9e/repos/rosetta`, MIT, zero imports).
Every scenario states: (1) what oracle's DOM-only logic in
`~/SITES/oracle/src/browser/actions/assistantResponse.ts` concludes and why, (2) the correct
answer, (3) a concrete `ConversationMapping` graph a fixture-builder can construct verbatim.

**Status labels used throughout:**
- `DOCUMENTED PRODUCTION INCIDENT` — cited to a pro-gate CHANGELOG entry, memory file, or code
  comment describing something that actually happened.
- `PLAUSIBLE EDGE CASE (proposed)` — not independently observed in pro-gate's history; grounded
  in the contract's own stated design intent, ChatGPT's known conversation-mapping data model
  (branching via multi-child nodes), or pro-gate's own documented risk surface (e.g. weak-model
  fallback), but I did not find a ledger row / CHANGELOG line / commit proving it fired.

All content below was read directly from the cited files; nothing is inferred from titles alone.

---

## S1. Preamble mistaken for final (the chronic bug)

**Status: DOCUMENTED PRODUCTION INCIDENT.**
Citations: memory `oracle-preamble-completion-rootcause.md` (root-cause writeup, 2026-07-09);
memory `pro-gate-archive-probe-double-spend.md` ("oracle (0.15.2) captures the model's opening
'plan bubble' preamble as the final message (146-199 byte artifact, no Pn/VERDICT) and exits
0"); `~/SITES/oracle/src/browser/actions/assistantResponse.ts:30-32` (current code's own
comment: "never on the mere 'stop control absent + text stable' inference, which a settled
GPT-5.5 Pro preamble satisfies during the brief gap before it enters its thinking/tool phase").

**Two layers — describe both, they are different vintages of the same bug shape:**

1. **Historical (pre-fix) mechanism**, exactly as memory documents it: `pollAssistantCompletion`
   finalized on `(!shortAnswer && stableEnough)` without requiring the finished-action bar. A
   146-199 char preamble landed in the `longAnswer` bucket (40-500 chars;
   `MIN_CONFIDENT_ANSWER_LENGTH=16`), so the short-capture guard (#293) never engaged. Fixed by
   commits `9ed1d8a9` ("finalize assistant turns on positive completion proof, not stop-absent +
   stable"), `dd2efd52`, `220d9b09`, `5bcdc558` (`~/SITES/oracle` git log, read-only). This is the
   code path that produced the measured "100% of clean runs completed via salvage" days.
2. **Current residual mechanism**, still live in installed `oracle@0.17.2` (confirmed present in
   `~/.local/share/pnpm/global/5/node_modules/@steipete/oracle/dist/src/browser/actions/assistantResponse.js:15-54`,
   matching fork source `assistantResponse.ts:91-136`): `classifyTurnTerminal` now requires
   **proofA** (debounced finished-action bar) or **proofB** (`!thinkingActive && len>=16 &&
   stableMs>=1200 && quietMs>=12000`, `assistantResponse.ts:126-133`). The root-cause memory's
   own convergence loop (R3, 2026-07-09) found this still has a DOM ceiling: "proofB is
   inherently absence-based … recreates the bug under selector drift." `thinkingStatus.ts:431`
   itself calls the stop-button check "Last-resort liveness fallback: selector drift can hide
   every thinking [indicator]." So today, S1 still fires whenever whatever DOM signal
   `thinkingActive`/`stopVisible` depend on fails to detect that reasoning has resumed — the
   settled preamble then sits "quiet" for the full 12s window and proofB finalizes it. The
   `pro-gate-gpt56-worktab-friction.md` memory shows selector drift on this exact surface is not
   hypothetical (VERDICT-line regex and Cloudflare-interstitial detection both broke on a UI
   refresh within the same period).

**What oracle's DOM logic concludes today:** if `thinkingActive` misreads false during the
resumed-reasoning window, `TERMINAL` — it returns the 146-199 char preamble as the final review.
This is wrong: reasoning has not ended, and the real answer (with real Pn/VERDICT findings)
arrives minutes later.

**Correct answer:** `INCOMPLETE` at the moment the preamble is the only assistant node; `done:
true` only once the real answer lands.

**Graph at the moment oracle wrongly finalizes** (mapping snapshot via
`GET /backend-api/conversation/<id>`, `turn_exchange_id = "turn-s1"`):

```jsonc
{
  "preamble": {
    "id": "preamble", "parent": null, "children": ["resumedThoughts"],
    "message": {
      "id": "msg-preamble-1a2b",
      "author": { "role": "assistant" },
      "recipient": "all",
      "content": { "content_type": "text",
        "parts": ["I'll review this PR's diff for correctness, then check test coverage and the release checklist before giving a verdict."] },
      // 146-199 chars, matches the measured incident range.
      "status": "finished_successfully",
      "end_turn": true,
      "metadata": {
        "turn_exchange_id": "turn-s1",
        "finish_details": { "type": "stop" },
        "model_slug": "gpt-5-6-pro"
        // NOTE: no "reasoning_status" key on this node — that is the point. It carries every
        // completion-ish flag (end_turn, finished_successfully, finish_details.type=stop) that
        // oracle's DOM heuristics and a naive end_turn/stream-terminator check would trust.
      }
    }
  },
  "resumedThoughts": {
    "id": "resumedThoughts", "parent": "preamble", "children": [],
    "message": {
      "id": "msg-thoughts-2c3d",
      "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "thoughts", "parts": [] },
      "status": "finished_successfully", "end_turn": false,
      "metadata": { "turn_exchange_id": "turn-s1", "reasoning_status": "is_reasoning" }
    }
  }
}
```

At this snapshot, `evaluateProTurnCompletion(mapping, "turn-s1")` walks: `turnMessages` =
[preamble, resumedThoughts] (both share `turn_exchange_id`); `reasoningEnded` = filter for
`content_type==="reasoning_recap"` → **empty**, because no such node exists yet. Returns
`{ done: false, reason: "trusted reasoning_ended signal not present" }` — correct, regardless
of how many completion-shaped flags the preamble node carries. This is the load-bearing
guarantee: the contract never even inspects `end_turn`/`finish_details` on `preamble` until a
`reasoning_recap` exists, closing exactly the hole `pro-final.ts:49-52`'s docstring calls out.

**Graph minutes later, once the real answer lands** (same mapping, two more nodes appended):

```jsonc
{
  // ...preamble, resumedThoughts unchanged...
  "recap": {
    "id": "recap", "parent": "resumedThoughts", "children": ["final"],
    "message": {
      "id": "msg-recap-4e5f", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "reasoning_recap", "parts": [] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-s1", "reasoning_status": "reasoning_ended" }
    }
  },
  "final": {
    "id": "final", "parent": "recap", "children": [],
    "message": {
      "id": "msg-final-6g7h", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "text",
        "parts": ["[P1] lib/foo.sh:42 — ...\n\nVERDICT: FIX-FIRST — needs the null guard (run marker: pg-run-abc-123)"] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-s1", "finish_details": { "type": "stop" }, "model_slug": "gpt-5-6-pro" }
    }
  }
}
```

Trace: `reasoningEnded = [recap]`. `terminalTexts` = both `preamble` and `final` structurally
match the terminal-text filter (both have `content_type:"text"`, `recipient:"all"`,
`status:"finished_successfully"`, `end_turn:true`, `finish_details.type:"stop"`). `preamble` is
excluded by `afterReasoningEnded` (it is an *ancestor* of `recap`, not a descendant).
`activeReasoning = [resumedThoughts]`; `final` is a descendant of `resumedThoughts` (via
`recap`) so it survives `structurallySafe`. `leafCandidates = [final]` (singleton) →
`{ done: true, finalText: <final's text>, finalMessageId: "msg-final-6g7h", finishReason:
"stop" }`. Correctly ignores the preamble even though it structurally "looks terminal" too.

---

## S2. Genuine terminal answer

**Status: baseline acceptance case** (the contract must not regress on the simple happy path).
Directly mirrors rosetta's own shipped fixture "E: returns only the terminal text node after
trusted reasoning_ended" — `tests/sse.test.ts:266-288`.

**What oracle's DOM logic concludes today:** eventually `TERMINAL`, correctly — proofA/proofB
both agree once the real answer has genuinely settled and no further DOM mutation occurs. No
mismatch on this path (when it is not defeated by S1's selector-drift residual).

**Correct answer:** `done: true`, unconditionally.

**Graph** (`turn_exchange_id = "turn-s2"`, single unbroken chain, no preamble at all — the model
went straight into reasoning):

```jsonc
{
  "thoughts": {
    "id": "thoughts", "parent": null, "children": ["recap"],
    "message": {
      "id": "msg-thoughts", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "thoughts", "parts": [] },
      "status": "finished_successfully", "end_turn": false,
      "metadata": { "turn_exchange_id": "turn-s2", "reasoning_status": "is_reasoning" }
    }
  },
  "recap": {
    "id": "recap", "parent": "thoughts", "children": ["final"],
    "message": {
      "id": "msg-recap", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "reasoning_recap", "parts": [] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-s2", "reasoning_status": "reasoning_ended" }
    }
  },
  "final": {
    "id": "final", "parent": "recap", "children": [],
    "message": {
      "id": "msg-final", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "text", "parts": ["P0: none\nP1: none\n\nVERDICT: SHIP — clean diff (run marker: pg-run-abc-123)"] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-s2", "finish_details": { "type": "stop" }, "model_slug": "gpt-5-6-pro" }
    }
  }
}
```

`evaluateProTurnCompletion(mapping, "turn-s2")` → `{ done: true, finalText: "P0: none...",
finalMessageId: "msg-final", finishReason: "stop" }`. This is literally rosetta's test E.

---

## S3. Cross-bind (foreign turn's completed answer on our page)

**Status: DOCUMENTED PRODUCTION INCIDENT.**
Citations: `CHANGELOG.md:278-302` (v0.31.1, issue #67); `bin/cdp-salvage.mjs:431-464`
(`foreignAnswerMarker`, with the exact mapping in its own comment: **"pro-gate#66 <-
pushbot#1336, pushbot#1334 <- pushbot#1323"**); `skills/pro-gate/SKILL.md:271-292` (the
three-state `--status` taxonomy and the explicit warning against
`PRO_GATE_REQUIRE_NONCE=0`).

Root cause per CHANGELOG: `cdp-salvage` decided "this conversation is ours" from **a bare
full-page substring match on the run marker**, and the marker rides the submitted *prompt* text,
not the answer. A mis-navigated/reused render could show our prompt above someone else's
finished answer, and because a remembered URL is exempt from the blacklist, the memo stayed
poisoned permanently (pushbot#1334: four unbindable harvests then exit 6, the only unresolved
exit-9 marker in ~800 ledger rows).

**Two distinguishable shapes — both are needed, because pro-gate's actual v0.31.1 fix had to
tell them apart (SKILL.md:277-285: `unbindable-ambiguous` vs `cross-bound`):**

### S3a — genuine cross-bind (malignant)

A completed answer belonging to a **different** run/marker sits **after** our prompt in the
same rendered page/conversation (e.g. two pro-gate runs raced onto the same Chrome tab/URL).
`turn_exchange_id` differs; the foreign turn's VERDICT line echoes a foreign marker.

```jsonc
{
  "ourPrompt": {
    // Our submitted user turn. embeds "(run marker: pg-run-ours-777)" only in the PROMPT text
    // an operator/oracle would grep — the graph model has no user-authored VERDICT text, so
    // represent this as: our turn_exchange_id exists but has produced NO assistant node yet.
    "id": "ourPrompt", "parent": null, "children": [],
    "message": {
      "id": "msg-user-ours", "author": { "role": "user" }, "recipient": "all",
      "content": { "content_type": "text", "parts": ["Review PR #1336 diff... (run marker: pg-run-ours-777)"] },
      "status": "finished_successfully", "end_turn": null,
      "metadata": { "turn_exchange_id": "turn-ours" }
    }
  },
  "foreignThoughts": {
    "id": "foreignThoughts", "parent": "ourPrompt", "children": ["foreignRecap"],
    "message": {
      "id": "msg-foreign-thoughts", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "thoughts", "parts": [] },
      "status": "finished_successfully", "end_turn": false,
      "metadata": { "turn_exchange_id": "turn-foreign-1323", "reasoning_status": "is_reasoning" }
    }
  },
  "foreignRecap": {
    "id": "foreignRecap", "parent": "foreignThoughts", "children": ["foreignFinal"],
    "message": {
      "id": "msg-foreign-recap", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "reasoning_recap", "parts": [] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-foreign-1323", "reasoning_status": "reasoning_ended" }
    }
  },
  "foreignFinal": {
    "id": "foreignFinal", "parent": "foreignRecap", "children": [],
    "message": {
      "id": "msg-foreign-final", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "text",
        "parts": ["[P0] auth.go:88 — token leak\n\nVERDICT: FIX-FIRST — critical (run marker: pg-run-theirs-1323)"] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-foreign-1323", "finish_details": { "type": "stop" } }
    }
  }
}
```

**What cdp-salvage's page-text heuristic concludes today (pre-#68 fix / without the position
check):** finds our marker `pg-run-ours-777` anywhere on the page → treats the *whole page* as
ours → `extractReview()` scans backward for the LAST `VERDICT:` line, finds `foreignFinal`'s →
returns pushbot#1323's review (a different repo's finding, `auth.go:88`) as if it were our
PR #1336 review. **This is the exact incident.** The post-fix `foreignAnswerMarker()` (current
code) improves this to "convict only if the foreign verdict's text-position is after the last
occurrence of our marker" — still a **text-position** heuristic operating on flattened
`innerText`, not a structural graph relationship.

**What `evaluateProTurnCompletion` concludes, by construction:** call it with `"turn-ours"`.
Line `pro-final.ts:74`: `if (message.metadata?.turn_exchange_id !== turnExchangeId) continue;`
— every `foreign*` node is filtered out before any other logic runs. `turnMessages` for
`"turn-ours"` is empty (no assistant node yet) → `{ done: false, reason: "no assistant nodes
for current turn_exchange_id" }`. The foreign completed answer is structurally invisible to a
query scoped to our own `turn_exchange_id`; there is no code path by which it could be returned
as ours. Cross-bind becomes a category error, not a heuristic to get right or wrong.

### S3b — benign reused conversation (must NOT be convicted)

An **older, already-completed** turn (possibly literally a prior pro-gate round on the same PR)
sits *before* our prompt in the same conversation; ours is still generating or completes later.
This is exactly rosetta's own shipped fixture, test G — `tests/sse.test.ts:311-345`
("ignores completed and active nodes from different turn_exchange_ids"). Graph (abbreviated,
field shapes as in that test): `oldRecap`(`turn:"previous-turn"`, `reasoning_ended`) →
`oldFinal`(`turn:"previous-turn"`, text, `finish_details.type:"stop"`) → `currentThoughts`
(`turn:PRO_TURN`, `is_reasoning`) → `currentRecap`(`turn:PRO_TURN`, `reasoning_ended`) →
`currentFinal`(`turn:PRO_TURN`, text, `finish_details.type:"stop"`) → `nextThoughts`
(`turn:"next-turn"`, `is_reasoning`). `evaluateProTurnCompletion(mapping, PRO_TURN)` returns
`{ done: true, finalText: "当前轮完整答案", finalMessageId: "currentFinal" }` — correctly
skips both the older and the (hypothetical) next turn's nodes. cdp-salvage's own comment at
`cdp-salvage.mjs:453-459` names this exact risk under its old-verdict-above-prompt heading and
is why the position check (`foreignAt < lastMarkerAt → not foreign`) exists at all — SKILL.md's
`unbindable-ambiguous` state (`SKILL.md:277-279`) is pro-gate's operational label for this same
shape when the older answer lacks a nonce echo.

---

## S4. Reasoning-sibling ambiguity (graph-incomparable branch)

**Status: PLAUSIBLE EDGE CASE (proposed).** Not a documented pro-gate incident — oracle's DOM
capture only ever sees one rendered turn path, so it has no notion of "sibling branch" at all;
this failure mode is specific to adopting the REST mapping, which (per ChatGPT's own data
model, visible in every fixture above via the `children: [...]` array) supports multiple
children per node, i.e. branches — created by "regenerate response"/retry, which pro-gate's own
conversation-reuse pattern (S3b, round-2+ re-review on the same conversation) makes plausible.
Grounded directly in the contract's own docstring intent: `pro-final.ts:57-58`, "reject any
candidate followed by (**or graph-incomparable with**) an `is_reasoning` thoughts/code node from
the same turn," and the code at `pro-final.ts:123-131`. Rosetta's shipped tests cover the
**descendant** case (a resumed child, `tests/sse.test.ts:290-309`) and the **repeated-stage**
case (`tests/sse.test.ts:249-264`) but not a true sibling/branch case — this scenario fills that
gap.

**Graph**: a `reasoning_recap` node has **two children** — one is a plausible terminal text, the
other is an `is_reasoning` node from a parallel/incomparable branch (e.g. a stray regenerate
branch that never got pruned from the mapping):

```jsonc
{
  "recap": {
    "id": "recap", "parent": null, "children": ["candidateA", "thoughtsSiblingB"],
    "message": {
      "id": "msg-recap", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "reasoning_recap", "parts": [] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-s4", "reasoning_status": "reasoning_ended" }
    }
  },
  "candidateA": {
    "id": "candidateA", "parent": "recap", "children": [],
    "message": {
      "id": "msg-candidate-a", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "text", "parts": ["P0: none\n\nVERDICT: SHIP (run marker: pg-run-abc-123)"] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-s4", "finish_details": { "type": "stop" } }
    }
  },
  "thoughtsSiblingB": {
    "id": "thoughtsSiblingB", "parent": "recap", "children": [],
    "message": {
      "id": "msg-thoughts-sibling-b", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "thoughts", "parts": [] },
      "status": "finished_successfully", "end_turn": false,
      "metadata": { "turn_exchange_id": "turn-s4", "reasoning_status": "is_reasoning" }
    }
  }
}
```

`candidateA` and `thoughtsSiblingB` are both direct children of `recap` — neither is an
ancestor/descendant of the other; `isDescendantOf(mapping, "candidateA",
"thoughtsSiblingB")` returns `false` (their common ancestor is `recap`, but neither key equals
the other's `parent` chain). **What oracle's DOM logic would conclude (hypothetically, if it
tried to reason about the graph at all):** it cannot — DOM capture reads whatever single turn is
currently *rendered*, so if the UI happens to display the `candidateA` branch (ChatGPT shows one
branch at a time with pagination arrows), oracle would see a settled, terminal-shaped text with
no visible "still thinking" indicator for the *other* branch and finalize `candidateA` — the DOM
has no way to know a sibling branch's `thoughtsSiblingB` node exists at all, since it isn't in
the currently-selected branch's rendered DOM subtree.

**Correct answer:** `INCOMPLETE` — fail closed, per `pro-final.ts:123-131`:
`structurallySafe` filters `afterReasoningEnded` candidates to those where `isDescendantOf`
holds for every active-reasoning node; since `thoughtsSiblingB` is neither ancestor nor
descendant of `candidateA`, `candidateA` is excluded. `structurallySafe.length === 0` →
`{ done: false, reason: "active or graph-incomparable reasoning remains for final text
candidate" }`. A contract that instead only checked "is any `is_reasoning` node a *descendant*"
would wrongly accept `candidateA` here — this is the precise case that catches that bug.

---

## S5. In-progress (mid-reasoning, no recap yet)

**Status: baseline rejection case**, directly the shape rosetta's own suite already tests:
`tests/sse.test.ts:209-231` ("A: rejects the observed short end_turn text while later thoughts
are still reasoning") and `:233-247` ("B: message_stream_complete ends only the stream phase
when mapping is still reasoning") / `tests/client.test.ts:28-58` (`activeMapping()`, reused by
the `streamSecondLeg` polling-rejection test at `tests/client.test.ts:208-225`).

Operationally this is the case pro-gate's stall/no-think watchdog (`bin/oracle-review.sh:1754-
1800`, `PRO_GATE_STALL_SECS=600`, `PRO_GATE_NOTHINK_SECS=600`) exists to survive blindly for up
to 10 minutes, because DOM heuristics cannot cheaply/definitively distinguish "still reasoning"
from "settled and done" — see S1. A REST-graph contract answers this with a single poll.

**Graph** (`turn_exchange_id = "turn-s5"`; a short end_turn-flagged text stage, with reasoning
that is demonstrably still active as its child — no `reasoning_recap` node exists anywhere in
the mapping):

```jsonc
{
  "stage": {
    "id": "stage", "parent": null, "children": ["thoughts"],
    "message": {
      "id": "16ced1a1-139f-42b9-99c9-3758d40810f9", "author": { "role": "assistant" },
      "recipient": "all",
      "content": { "content_type": "text",
        "parts": ["12 mechanisms surveyed; narrowing candidates to structural expansion, minimal write-set..."] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-s5" }
    }
  },
  "thoughts": {
    "id": "thoughts", "parent": "stage", "children": [],
    "message": {
      "id": "f6544ce3-44ec-48b2-880d-386a6fa4cacb", "author": { "role": "assistant" },
      "recipient": "all",
      "content": { "content_type": "thoughts", "parts": [] },
      "status": "finished_successfully", "end_turn": false,
      "metadata": { "turn_exchange_id": "turn-s5", "reasoning_status": "is_reasoning" }
    }
  }
}
```

**What oracle's DOM logic concludes today:** correctly `INCOMPLETE` in the common case (the
stop control / thinking indicator are visible and detected) — but see S1's residual: if either
selector misses the resumed-reasoning state, this exact shape is where it wrongly flips to
`TERMINAL`. S1 and S5 are the same underlying graph topology observed at two different DOM-signal
reliability states; they are listed separately because a fixture suite needs both the "DOM
signals work, correctly rejected" case (S5) and the "DOM signals fail, wrongly accepted" case
(S1) to prove the graph contract is invariant to that failure.

**Correct answer:** `evaluateProTurnCompletion` returns `{ done: false, reason: "trusted
reasoning_ended signal not present" }` — `reasoningEnded` is empty because no
`reasoning_recap` node exists, so the check short-circuits before it ever inspects `stage`'s
`end_turn`/`status` flags. Unconditionally correct regardless of DOM signal reliability.

---

## S6. Weak/instant-model dispatch (no Pro handoff at all)

**Status: PLAUSIBLE EDGE CASE (proposed) — but grounded in a real, currently-active pro-gate
risk, not a hypothetical.** Citations: `lib/pro-gate-lib.sh:573-599` (`pg_derive_model_warn`,
`PRO_GATE_MODEL_WEAK_PATTERN="mini|nano|instant"` — an advisory-only weak-model denylist that
already exists because `PRO_GATE_MODEL_STRATEGY=current` (the documented default,
`bin/oracle-review.sh:1779`) submits to *whatever* model the account currently has selected, not
provably Pro); `docs/SETUP-NOTES.md:16` (the `select` strategy fails against GPT-5.6's unified
model picker, per evidence dossier §5, which is *why* `current` remains the default and the
model is not guaranteed in advance). Rosetta itself has not been integrated into pro-gate, so
no pro-gate ledger row documents this against rosetta specifically — the risk is inferred from
pro-gate's own documented non-determinism about which model actually answers.

**The mechanism:** rosetta's `client.ts` only invokes `evaluateProTurnCompletion` when the
bootstrap SSE contained a `stream_handoff` event (`extractStreamHandoff`, `client.ts:1194-1206`,
gated at `client.ts:509`, `:1648`) — i.e., only genuine Pro turns enter the graph-verification
path at all. A non-Pro/"instant" model's turn is a plain SSE stream ending in
`message_stream_complete`/`[DONE]`, handled by `aggregateAssistantMessage` directly, and **never
produces a `reasoning_recap` node** — confirmed by rosetta's own test H,
`tests/sse.test.ts:347-360`: `{"message":{"id":"instant", ..., "status":
"finished_successfully","end_turn":true}}` with **no `metadata.reasoning_status` field
anywhere**, and the test asserts this aggregates to a normal successful result without ever
calling `evaluateProTurnCompletion`.

**What goes wrong if a pro-gate integration calls the graph contract unconditionally** (e.g. a
defensive "always verify via REST" wrapper that does not first check for a `stream_handoff`):
graph contains exactly one assistant text node, terminal-shaped (`end_turn:true`,
`status:"finished_successfully"`, possibly even `finish_details.type:"stop"` depending on
what a non-Pro turn's mapping carries) but **no `reasoning_recap` node ever will exist**, because
this model never emits one.

```jsonc
{
  "instantFinal": {
    "id": "instantFinal", "parent": null, "children": [],
    "message": {
      "id": "instant", "author": { "role": "assistant" }, "recipient": "all",
      "content": { "content_type": "text", "parts": ["P0: none\n\nVERDICT: SHIP (run marker: pg-run-abc-123)"] },
      "status": "finished_successfully", "end_turn": true,
      "metadata": { "turn_exchange_id": "turn-s6" }
      // no reasoning_status anywhere in this mapping — this model doesn't do visible reasoning.
    }
  }
}
```

`evaluateProTurnCompletion(mapping, "turn-s6")` → `reasoningEnded.length === 0` →
`{ done: false, reason: "trusted reasoning_ended signal not present" }` — **forever**, since
this node will never gain a `reasoning_recap` sibling/ancestor no matter how long you poll.
Combined with `client.ts`'s own fail-closed poll timeout (`pollingIncompleteError`,
`client.ts:1691-1704`, "INCOMPLETE Pro turn … No stage text was returned or persisted"), a
caller that always routes through the Pro-only verifier would misreport a **correct, complete,
already-returned answer** as a hung/incomplete turn and burn the full poll budget before failing
— a false negative, the mirror image of S1's false positive. **Correct answer:** the dispatch
layer must gate entry to `evaluateProTurnCompletion` on the presence of a `stream_handoff` (as
rosetta's own `client.ts` already does); a fixture/integration test for this scenario should
assert the *caller*, not `pro-final.ts` itself, correctly short-circuits to plain SSE
aggregation when no handoff occurred — `pro-final.ts` behaving as shown above is not a bug in
the verifier, it is a bug waiting to happen in whatever pro-gate-side adapter decides when to
call it.

---

## Cross-reference: incidents mined but NOT modeled as separate graph scenarios

For completeness, two more pro-gate history items surfaced during this dig that are real and
citable but are not conversation-*graph* shapes (they are engine/DOM-selector concerns a
graph-based contract doesn't by itself fix), so they're noted here rather than given fixtures:

- **Archive-then-vanish double-spend** (`pro-gate-archive-probe-double-spend.md`,
  DOCUMENTED, fixed in pro-gate PR #11): once oracle mis-captured S1's preamble as final and
  exited 0, `--browser-archive auto` archived the tab; the marker probe then read "gone" and
  pro-gate's fail-open retry-on-any-nonzero-exit double-spent a slot on the same bug. This is a
  downstream *consequence* of S1 in the engine's retry logic, not an additional graph state —
  worth flagging to whoever wires a rosetta-based capture into pro-gate: fixing S1 alone doesn't
  guarantee no double-spend unless the caller's archive/retry policy is also sound.
- **GPT-5.6 "Work" tab false-Cloudflare + missed-VERDICT-regex** (`pro-gate-gpt56-worktab-
  friction.md`, DOCUMENTED): `isCloudflareInterstitial`'s selector match and the `^VERDICT:`
  anchor both broke against a UI restyle. These are pure DOM/text-parsing brittleness, not
  conversation-graph states — notably, rosetta's approach sidesteps both by construction:
  Cloudflare/auth errors are classified from the actual HTTP response code
  (`classifyError`, evidence-rosetta.md §10, `client.ts:~2000-2021`), and the VERDICT text is
  read from `content.parts[0]` of a structurally-identified node, never regex-matched out of
  rendered markdown.
