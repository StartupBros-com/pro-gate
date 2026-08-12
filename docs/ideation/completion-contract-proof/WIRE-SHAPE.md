# WIRE-SHAPE.md — rosetta's `evaluateProTurnCompletion` contract, from source and tests

Established directly from rosetta's own code and tests. No field, value, or shape below is
invented — every claim cites a `file:line`.

## 0. Provenance

- Repo: `/tmp/ce-ideate-7c3f1a9e/repos/rosetta` (`https://github.com/SyntaxSmith/rosetta.git`, MIT)
- Commit: **`12ed925a5381a9b2baad591f718182a059052f72`** — `fix: verify Pro turn completion before
  returning`, Sun Aug 2 00:25:11 2026 +0800. Full history present (not a shallow clone); this is
  `HEAD` and the tip of `main`. `package.json` version at this commit: `0.3.2`.
- This is the commit that *introduced* `src/pro-final.ts` and both test suites discussed below
  (`git show --stat 12ed925` shows `src/pro-final.ts` as a 189-line addition and both
  `tests/client.test.ts` / `tests/sse.test.ts` gaining the Pro-completion `describe` blocks in the
  same commit).

## 1. Every field `evaluateProTurnCompletion` reads, with citation

Source: `src/pro-final.ts` (function body: lines 62–171; the descent helper: lines 173–189).

| Field (dotted path from a mapping node) | Read at | Required value / check |
|---|---|---|
| `turnExchangeId` (function's 2nd argument, a plain string, NOT read off the mapping) | `pro-final.ts:66` | must be truthy, else immediate `{done:false, reason:"missing turn_exchange_id"}` |
| `node.message` (node-level; presence check) | `pro-final.ts:72` | skip node if `message` is falsy |
| `message.author.role` | `pro-final.ts:73` | must be exactly `"assistant"`, else skip node |
| `message.metadata.turn_exchange_id` | `pro-final.ts:74` | must `===` the passed `turnExchangeId`, else skip node — **this is the only filter that selects a turn's nodes out of the whole mapping** |
| `message.content.content_type` | `pro-final.ts:83` (want `"reasoning_recap"`), `pro-final.ts:95` (want `"text"`), `pro-final.ts:118` (want `"thoughts"` or `"code"`) | see below |
| `message.recipient` | `pro-final.ts:84`, `pro-final.ts:96` | must be exactly `"all"` for both the reasoning-recap candidate and the terminal-text candidate |
| `message.status` | `pro-final.ts:85`, `pro-final.ts:97` | must be exactly `"finished_successfully"` for both candidates |
| `message.end_turn` | `pro-final.ts:86`, `pro-final.ts:98` | must be exactly `true` (strict `===`, not truthy) for both candidates |
| `message.metadata.reasoning_status` | `pro-final.ts:87` (want `"reasoning_ended"` on the recap), `pro-final.ts:120` (want `"is_reasoning"` on an *active-reasoning* node) | drives both the positive recap gate and the negative "still reasoning" gate |
| `message.metadata.finish_details.type` | `pro-final.ts:99`, and read again at `pro-final.ts:169` for the return value | must be exactly `"stop"` on the terminal text candidate |
| `message.id` | `pro-final.ts:100–101`, then `pro-final.ts:159` | must be a non-empty string on the terminal text candidate; becomes `finalMessageId` in the return value |
| `message.content.parts` | `pro-final.ts:102–104`, then `pro-final.ts:157–158` | must be an `Array`, `parts[0]` must be a non-empty `string`; that string becomes `finalText` |
| `message.metadata.model_slug` | `pro-final.ts:168` | passed straight through as `modelSlug` in the return value (not validated, may be `undefined`) |
| **node key** (the `Record<string, ConversationMappingNode>` key, i.e. the object property name under which the node sits in `mapping`) | `pro-final.ts:71` (`Object.entries(mapping)`), `pro-final.ts:108/125/143` (`isDescendantOf(mapping, key, otherKey)`) | **this is the node's true identity for graph purposes** — see §3 |
| `node.parent` | `pro-final.ts:183` (inside `isDescendantOf`) | string key of the parent node, or `null`/`undefined` to mean "root" |

Fields that exist on the exported TypeScript interfaces but are **never read** by the algorithm
(confirmed by grep — zero occurrences in `pro-final.ts`):
- `node.id` (`pro-final.ts:24`) — declared, unused. Only `message.id` (a *different* field, nested
  one level deeper) is read.
- `node.children` (`pro-final.ts:26`) — declared, unused. Descent is entirely parent-pointer-driven
  (see §3); nothing ever walks `children` arrays.
- `message.create_time` (`pro-final.ts:10`) — declared, unused *inside this function*. The comment
  at `pro-final.ts:49–52` and a matching comment in the REST-poll caller
  (`client.ts:1625–1627`, "Server timestamps can be equal or arrive out of order — the observed
  reasoning_recap and final text share one timestamp") explicitly document that timestamp/creation
  order was tried and rejected as a completion signal.

## 2. `ConversationMapping` as the function actually consumes it

This is `src/pro-final.ts:6–30` (the exported interfaces), annotated with which parts are load-
bearing per §1 above:

```typescript
// The REST response body itself (see §4) is `{ mapping: ConversationMapping }`;
// client.ts casts it: `resp.body as { mapping?: ConversationMapping }` (client.ts:1608).
// There is NO runtime schema validation anywhere on this response — no zod, despite zod being
// a dependency (package.json) and used elsewhere in the repo. Every field access below is a
// plain optional-chain read; a missing/malformed field silently fails a filter rather than
// throwing, which is why the function fails CLOSED (returns done:false) instead of crashing.

type ConversationMapping = Record<string /* node key, load-bearing identity, see §3 */, ConversationMappingNode>;

interface ConversationMappingNode {
  id?: string;                    // declared, NEVER read by the algorithm
  parent?: string | null;         // load-bearing: sole edge used for descent (§3)
  children?: string[];            // declared, NEVER read by the algorithm
  message?: ConversationMappingMessage | null;
}

interface ConversationMappingMessage {
  id?: string;                    // load-bearing on the terminal-text candidate only: must be non-empty string; returned as finalMessageId
  author?: { role?: string };     // load-bearing: role must be "assistant" to be considered at all
  recipient?: string;             // load-bearing: must be "all" on both recap and terminal-text candidates
  create_time?: number;           // declared, deliberately NOT used for completion proof (see §1)
  content?: {
    content_type?: string;        // load-bearing: "reasoning_recap" | "text" | "thoughts" | "code" are the four values the algorithm branches on
    parts?: unknown[];            // load-bearing on terminal text: must be Array with parts[0] a non-empty string
  };
  status?: string;                 // load-bearing: must be "finished_successfully" on recap + terminal-text candidates
  end_turn?: boolean | null;       // load-bearing: must be === true (strict) on recap + terminal-text candidates
  metadata?: {
    model_slug?: string;                        // passed through to output only, not validated
    turn_exchange_id?: string;                  // load-bearing: the ONLY per-node turn filter
    poll_interval_ms?: number;                  // NOT read by pro-final.ts (read by the REST-poll loop in client.ts:1619-1622 to tune cadence)
    reasoning_status?: string;                  // load-bearing: "reasoning_ended" (on recap) | "is_reasoning" (on thoughts/code, negative gate)
    finish_details?: { type?: string };         // load-bearing: type must be "stop" on terminal-text candidate
  } & Record<string, unknown>;                  // ChatGPT sends more metadata keys; deliberately ignored (file header comment, pro-final.ts:3-4)
}

interface ProTurnCompletion {
  done: boolean;
  finalText?: string;      // == terminal candidate's message.content.parts[0]
  finalMessageId?: string; // == terminal candidate's message.id
  modelSlug?: string;      // == terminal candidate's message.metadata.model_slug (unvalidated passthrough)
  finishReason?: string;   // == terminal candidate's message.metadata.finish_details.type
  reason?: string;         // present only when done: false — human-readable rejection cause
}
```

Optionality note: every field above is optional in the TS interface (ChatGPT's real payload has
far more fields — file header comment, `pro-final.ts:3–4`, "ChatGPT adds many unrelated fields to
these objects; the verifier deliberately ignores them"). The function treats every optional field
as absent-safe via `?.` chains; nothing throws on a missing field, it just fails a filter.

## 3. Graph / parent-child structure — this is what the contract actually turns on

**The node's identity for descent purposes is the `Record` key it sits under in `mapping`, NOT
`node.id` and NOT `message.id`.** Evidence:
- `pro-final.ts:71`: `for (const [key, node] of Object.entries(mapping))` — `key` (the map key) is
  carried forward as `KeyedMessage.key` (`pro-final.ts:41-44`) for every subsequent graph operation.
- `pro-final.ts:108, 125, 143`: every `isDescendantOf(mapping, keyA, keyB)` call passes these
  `Record` keys, never `node.id` or `message.id`.
- `isDescendantOf` (`pro-final.ts:173-189`) walks **only** `mapping[currentKey]?.parent`
  (`pro-final.ts:183`) — a string that is expected to equal some *other node's Record key* — up the
  chain until it either matches `ancestorKey` (descendant confirmed) or hits a falsy `parent`
  (root reached, not a descendant) or revisits an already-seen key (cycle guard, `seen` Set,
  `pro-final.ts:179-182`, returns `false` rather than looping forever).
- There is no forward/`children`-based traversal anywhere in the file. Ancestry is proven exactly
  once, bottom-up, per candidate pair.

This means a fixture MUST make `node.parent` values reference the exact same strings used as the
`mapping` object's own keys (real ChatGPT payloads use the message UUID as both — e.g.
`tests/client.test.ts`'s `activeMapping()`/`finalMapping()` use short mnemonic keys like `"thoughts"`,
`"recap"`, `"final"` for readability and set `parent` to those same mnemonic strings — proving the
algorithm doesn't care whether the keys are real UUIDs, only that they're internally consistent).
`node.id` / `message.id` can be — and in the hand-written fixtures often are — a *different* string
from the map key (e.plain `finalMapping()`'s `final` node sits at map key `"final"` but its
`message.id` is `"final-text-message"`; see `tests/client.test.ts:92-107`). Only `message.id` is
externally meaningful (it's what's returned as `finalMessageId`); the map key and `node.parent` are
purely internal plumbing for the descent check.

### The exact topology the algorithm requires (positive case)

```
<zero or more nodes, any content_type, any turn_exchange_id>
        |
   (ancestor, same turn_exchange_id)
   content_type: "reasoning_recap"
   recipient: "all", status: "finished_successfully", end_turn: true
   metadata.reasoning_status: "reasoning_ended"
        |
   ... zero or more intermediate nodes allowed on the path ...
        |
   (descendant of the recap above — graph descent via .parent chain, NOT sibling, NOT incomparable)
   content_type: "text"
   recipient: "all", status: "finished_successfully", end_turn: true
   metadata.finish_details.type: "stop"
   message.id: non-empty string
   content.parts: [non-empty string, ...]
        |
   MUST be a leaf among "structurally safe" candidates (pro-final.ts:141-151): if two or more
   terminal-text nodes are mutually non-descendant ("incomparable"), the whole call fails closed
   with "ambiguous terminal text branches (<n>)".
```

Additional graph-shaped rejection: any node with `content_type` `"thoughts"` or `"code"` AND
`metadata.reasoning_status === "is_reasoning"` (an "active reasoning" node, `pro-final.ts:117-121`)
must be a **descendant of** the terminal-text candidate (i.e. it happened strictly before, on the
path leading up to it) — `pro-final.ts:123-131`. If it is anything else — a sibling branch, a
descendant of the terminal-text node (i.e. reasoning resumed *after* the "final" text), or simply
graph-incomparable — the candidate is rejected. This is the mechanism that defeats the
false-positive Pro's UI is known to produce: a short preamble that itself carries
`end_turn:true`/`finished_successfully`/`finish_details.type:"stop"` but is followed by more
`is_reasoning` nodes.

## 4. REST wire endpoint that supplies the mapping (context, from `client.ts`)

Not part of `pro-final.ts` itself, but this is the call site that feeds it real data, confirming
the mapping's place in the real backend response:

- `GET /backend-api/conversation/{conversationId}` (`client.ts:1587-1592`), auth via
  `Authorization: Bearer {accessToken}`.
- Response body is cast as `{ mapping?: ConversationMapping }` (`client.ts:1608`) — i.e. the real
  ChatGPT backend wraps the whole node graph under a top-level `"mapping"` key.
  `body.mapping ?? {}` — an absent `mapping` key degrades to an empty mapping (turn simply won't be
  found; not an error).
- `evaluateProTurnCompletion(mapping, handoff.turnExchangeId)` is invoked fresh on every poll tick
  (`client.ts:1648`), on the *entire* mapping (not filtered before the call — filtering by
  `turn_exchange_id` happens inside `pro-final.ts`, per §1).
- `handoff.turnExchangeId` (the 2nd argument) originates from a `stream_handoff` SSE event's
  `turn_exchange_id` field (`extractStreamHandoff`, `client.ts:1194-1220`, specifically
  `client.ts:1212`) — i.e. it is captured once from the *initial* SSE bootstrap and then used
  verbatim as the invariant key for every subsequent REST poll.
- Poll cadence: default 5000ms, tightened if any turn node carries
  `message.metadata.poll_interval_ms` in `[1000, intervalMs)` (`client.ts:1553`, `1619-1622`) — this
  field is real backend guidance per `client.ts:1531-1535`'s comment about ChatGPT's 2026-05 change
  shipping `poll_interval_ms` + `poll_on_websocket_inactivity_ms` as "the prescribed recovery" when
  the WebSocket handshake is rejected (403).
- Idle/stall handling: a poll loop with no *turn-signature* change (a sorted digest of
  `key:content_type:status:reasoning_status:finish_type:partLength` for every turn node,
  `client.ts:1628-1642` — explicitly NOT `create_time`-based) for `POLL_IDLE_FLOOR_MS` (6 minutes,
  `client.ts:1565`) throws `INCOMPLETE Pro turn` rather than returning a guess.

## 5. Rosetta's own tests for this contract

Two suites, added in the **same commit** as `pro-final.ts` (`12ed925`):

### `tests/sse.test.ts` — `describe("Pro turn final-state verification", ...)` (lines 208–360)

Unit-level, calls `evaluateProTurnCompletion` directly with hand-built `ConversationMapping`
literals via an `assistantNode(id, parent, contentType, options)` helper (`sse.test.ts:30-66`).
7 test cases, letter-labeled (`A`, `B`, `D`, `E`, one unlabeled — "rejects a terminal-looking text
if newer is_reasoning thoughts follow it" — and `G`; letters `C`/`F` live in the other file, see
below — the shared lettering across two files indicates a single original enumerated scenario list
`A`–`H` that was split by implementation location, not independently invented per file):

| Label | Scenario | Expects |
|---|---|---|
| A | Short end_turn text root, `thoughts`/`is_reasoning` child, no recap at all | `done:false, reason:"trusted reasoning_ended signal not present"` |
| B | `preamble` text root + `thoughts`/`is_reasoning` child, no recap | `done:false` (also asserts `isProStreamPhaseBoundaryEvent` for `message_stream_complete` / `last_token` marker types, from `client.ts`) |
| D | Two-stage: `stage1`→`thoughts1`(reasoning)→`stage2`→`thoughts2`(reasoning), no recap ever | `done:false` |
| E | `thoughts`(reasoning)→`recap`(reasoning_ended)→`final`(text,stop) — the canonical positive case | `{done:true, finalText:"完整最终回答", finalMessageId:"final", modelSlug:"gpt-5-6-pro", finishReason:"stop"}` |
| (unlabeled) | `recap`(reasoning_ended)→`candidate`(text,stop)→`resumed`(thoughts,is_reasoning) — reasoning resumes AFTER a terminal-looking text | `done:false, reason:"active or graph-incomparable reasoning remains for final text candidate"` |
| G | A full prior turn (different `turn_exchange_id`) fully completed, PLUS the current turn's own thoughts→recap→final, PLUS a trailing next-turn thoughts node (different `turn_exchange_id`) | `{done:true, finalText:"当前轮完整答案", finalMessageId:"currentFinal"}` — proves turn-id isolation both backward and forward |
| H | Instant (non-Pro) SSE aggregation succeeds without any Pro reasoning metadata at all | exercises `aggregateAssistantMessage`, not `evaluateProTurnCompletion` — the "non-Pro control" case |

### `tests/client.test.ts` — `describe("Pro stream-to-REST completion gate", ...)` (lines 208–288)

Integration-level: builds a full mocked `ChromeClient`/`RosettaSession` harness
(`makeStreamHarness`, `client.test.ts:113-206`) simulating CDP `Network.webSocketCreated` /
`webSocketFrameReceived` / `webSocketClosed` events plus the `/backend-api/conversation/:id` REST
GET, and drives the real `streamSecondLeg` / `pollConversationForFinal` exports end-to-end. Uses
two named mapping fixtures, `activeMapping()` (`client.test.ts:28-58`, still-reasoning, no recap —
the negative control) and `finalMapping()` (`client.test.ts:60-109`, full
thoughts→recap→final-text-with-`finish_details.type:"stop"` — the positive control, `id`/`parent`
using mnemonic string keys distinct from `message.id`, confirming §3's "map key ≠ message.id"
claim). Cases:

| Label | Scenario | Expects |
|---|---|---|
| B | `message_stream_complete` WS event arrives, but REST mapping (`activeMapping`) is still reasoning | rejects `"Aborted while polling conversation"` (test aborts the controller after the first conversation GET); confirms REST poll is consulted at all, not just the WS terminator |
| C | WebSocket closes entirely, mapping is `activeMapping()` (still reasoning) | same rejection — closing the socket must NOT be treated as completion |
| (unlabeled) | WS delivers final text frame AND REST mapping is `finalMapping()` | `streamSecondLeg` resolves `{text:"完整最终回答", messageId:"final-text-message"}`, `onChunk` fires **exactly once** with the full text (no duplicate streaming once REST-verified) |
| (unlabeled) | Mapping never resolves past `activeMapping()`, fake timers advanced past the idle floor | `pollConversationForFinal` rejects `"INCOMPLETE Pro turn"` |

Both suites are literally the closest thing to ground truth for the ChatGPT wire format that exists
in this repo — see §6 for how much independent corroboration that carries.

## 6. Test run — actual pass/fail output

```
$ cd /tmp/ce-ideate-7c3f1a9e/repos/rosetta && pnpm install --frozen-lockfile && pnpm test
```

`pnpm install --frozen-lockfile`: `Lockfile is up to date, resolution step is skipped` / `Already up
to date` (node_modules were already present and consistent with the committed lockfile).

`pnpm test` (`vitest run`, vitest v2.1.9):

```
 ✓ tests/state.test.ts (11 tests) 5ms
 ✓ tests/sse.test.ts (25 tests) 6ms
 ✓ tests/client.test.ts (6 tests) 12ms
 ✓ tests/upload.test.ts (12 tests) 1036ms

 Test Files  4 passed (4)
      Tests  54 passed (54)
   Start at  01:58:14
   Duration  1.35s
```

**All 54 tests pass**, including all 7 completion-gate cases in `sse.test.ts` and all 4 in
`client.test.ts` (the remaining tests in those two files are unrelated SSE-parsing / thread-
persistence coverage). Full raw output saved at `/tmp/prove-contract/rosetta-test-output-clean.txt`
(ANSI-stripped) and `/tmp/prove-contract/rosetta-test-output.txt` (raw). This is meaningful evidence
the contract is internally self-consistent with its author's own understanding of the wire format —
it is NOT independent evidence that the wire format itself is correct (see §7).

## 7. Real-traffic evidence vs. hand-written — be precise about what this repo actually proves

No HAR files, no recorded-frame directory, no `*.fixture.json`, nothing under `assets/` besides
three PNGs (icon/promo images). Confirmed by exhaustive search:
`find . -iname "*.har" -o -iname "*fixture*" -o -iname "*recorded*" -o -iname "*replay*"` (excluding
`node_modules`) returns nothing. `find . -name "*.json" -not -path "./node_modules/*"` returns only
`package.json`/`tsconfig*.json`.

**The completion-gate fixtures themselves are 100% hand-authored TypeScript object literals**
(`assistantNode()` helper calls in `sse.test.ts`, inline object literals in `client.test.ts`) — not
captured/replayed real traffic, despite README.md:342's claim that "Wire-shape regressions are
caught by a captured-frame replay test" (this line has existed since the repo's earliest README
revisions per `git log -p --follow -- README.md`, tracking every `content_type`/model-slug rename
along the way, e.g. `gpt-5-5-pro`→`gpt-5-6-pro`) — no such file exists anywhere in the current tree
or its history for THIS suite. Treat that README line as aspirational/inaccurate for the completion
gate specifically, not as evidence of a literal capture file.

That said, three independent signals in the surrounding code suggest the *shape itself* (as opposed
to the literal test bytes) is reverse-engineered from real sessions, not imagined wholesale:
1. `pro-final.ts:52`: "The live mapping observed in August 2026 instead has this structural
   contract" — dated, specific claim of direct observation.
2. `client.ts:1289` and `client.ts:1403`: two *separate* wire-protocol comment blocks explicitly
   dated "reverse-engineered 2026-04-30" for the WS frame envelope and send pipeline — unrelated to
   `pro-final.ts` but establishes the author's general methodology (dated reverse-engineering notes
   throughout, not one-off).
3. `sse.test.ts:196-198`: a citation-stripping test comments "Format observed live (probed via xxd
   on a real attachment response)" with the exact private-use-area codepoints (`U+E200`/`U+E202`/
   `U+E201`) — direct, checkable evidence of at least one real-traffic byte-level capture elsewhere
   in the same test file, using the same general test-authoring style as the completion-gate tests.
4. `client.ts:1531-1535` and `:1619-1622`: dated claim that ChatGPT's actual 2026-05 backend change
   added `poll_interval_ms`/`poll_on_websocket_inactivity_ms` to message metadata as "the prescribed
   recovery" for a WS 403 — a specific, falsifiable claim about server behavior, and the field is
   wired into the real poll-interval-tuning logic (not just decorative).

Net assessment: the field NAMES, VALUES, and STRUCTURAL CONTRACT (reasoning_recap →
graph-descendant terminal text) carry circumstantial-but-multiply-corroborated evidence of being
reverse-engineered against real ChatGPT Pro sessions across several months (dated comments,
2026-04 through 2026-08, consistent methodology, one directly-verifiable xxd-probed byte sequence
elsewhere in the same file). The literal TEST FIXTURES are synthetic reconstructions built to
exercise that believed contract, not raw captures — so treat rosetta's tests as "the author's
best-effort encoding of the real shape, self-consistent and passing," not as "recorded ground
truth." A fixture-builder should preserve every field/value documented in §1–§4 (which trace to the
dated observation comments) rather than only what happens to appear in the literal test object
literals (which are illustrative examples of that contract, not an exhaustive enumeration of real
payload noise — recall `pro-final.ts:3-4`'s explicit "ChatGPT adds many unrelated fields ... the
verifier deliberately ignores them").

## 8. Files copied for this task

- `/tmp/prove-contract/pro-final.ts` — verbatim copy of `src/pro-final.ts` @ `12ed925`
- `/tmp/prove-contract/sse.ts` — verbatim copy of `src/sse.ts` @ `12ed925`
- `/tmp/prove-contract/fixtures-from-rosetta/sse.test.ts` — verbatim copy of `tests/sse.test.ts`
- `/tmp/prove-contract/fixtures-from-rosetta/client.test.ts` — verbatim copy of `tests/client.test.ts`
- `/tmp/prove-contract/rosetta-test-output.txt` / `-clean.txt` — raw and ANSI-stripped `pnpm test` output
