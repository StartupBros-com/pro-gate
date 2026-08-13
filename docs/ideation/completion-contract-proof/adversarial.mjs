// Adversarial fixtures attacking coverage + production fitness of
// evaluateProTurnCompletion, run against the verified-identical copy at
// /tmp/prove-contract/pro-final.mjs (byte-diffed clean against
// src/pro-final.ts @ 12ed925a5381a9b2baad591f718182a059052f72).

import { evaluateProTurnCompletion } from "./pro-final.mjs";

let failures = 0;

function show(name, mapping, turn, note, expected) {
  const t0 = process.hrtime.bigint();
  const actual = evaluateProTurnCompletion(mapping, turn);
  const t1 = process.hrtime.bigint();
  console.log(`\n=== ${name} ===`);
  console.log(`note: ${note}`);
  console.log(`nodes: ${Object.keys(mapping).length}, elapsed: ${Number(t1 - t0) / 1e6}ms`);
  console.log(`result: ${JSON.stringify(actual)}`);
  const matches = expected(actual);
  if (!matches) {
    failures += 1;
    console.error(`ASSERTION FAILED: ${name}`);
  }
  return actual;
}

function expectIncomplete(expectedReason) {
  return (actual) => actual.done === false && (!expectedReason || actual.reason === expectedReason);
}

// ---------------------------------------------------------------------
// A1. Genuinely finished Pro turn that NEVER emits a reasoning_recap node
// at all -- e.g. a trivial one-word Pro request. No test anywhere in
// rosetta's own suite, WIRE-SHAPE.md, or SCENARIOS.md exercises "Pro
// completes without ever producing a recap" as an ACCEPT case.
// ---------------------------------------------------------------------
{
  const mapping = {
    onlyFinal: {
      id: "onlyFinal", parent: null, children: [],
      message: {
        id: "msg-only-final", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["pong"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a1", finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
  };
  show(
    "A1-no-recap-ever-trivial-answer",
    mapping,
    "turn-a1",
    "A short, genuinely complete Pro answer with NO reasoning_recap node anywhere. If real GPT-5.6 " +
      "Pro ever answers this way for trivial prompts, this call returns done:false FOREVER (no " +
      "recap will ever land), so the REST-poll caller spins until POLL_IDLE_FLOOR_MS (6 min) and " +
      "throws INCOMPLETE Pro turn on a genuinely-finished answer -- a false negative burning wall-" +
      "clock time (and, on any caller that retries with a fresh turn, a second Pro invocation).",
    expectIncomplete("trusted reasoning_ended signal not present"),
  );
}

// ---------------------------------------------------------------------
// A2. THE MONEY SHOT: a resumed-reasoning node that uses a content_type
// OTHER than the two hardcoded strings ("thoughts" | "code") the active-
// reasoning veto checks (pro-final.ts:117-121). WIRE-SHAPE.md itself
// labels content_type "the four values the algorithm branches on" -- a
// fifth value for a future/renamed resumed-work node is invisible to the
// veto. This reproduces the ORIGINAL S1 preamble bug through a topology
// the "fix" does not defend against: recap(reasoning_ended) -> premature
// terminal-shaped text -> resumed reasoning under an unrecognized
// content_type -> (real answer not landed yet).
// ---------------------------------------------------------------------
{
  const mapping = {
    recap: {
      id: "recap", parent: null, children: ["interimText"],
      message: {
        id: "msg-recap", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a2", reasoning_status: "reasoning_ended" },
      },
    },
    interimText: {
      id: "interimText", parent: "recap", children: ["newReasoningNode"],
      message: {
        id: "msg-interim", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["Quick take: looks fine at a glance."] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a2", finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
    // A future/renamed resumed-work node. Same reasoning_status flag Pro
    // is documented to use for active reasoning, but content_type is
    // "reasoning" instead of "thoughts"/"code" -- e.g. a plausible future
    // rename, or a new connector/tool-call phase node type.
    newReasoningNode: {
      id: "newReasoningNode", parent: "interimText", children: [],
      message: {
        id: "msg-new-reasoning", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-a2", reasoning_status: "is_reasoning" },
      },
    },
  };
  const r = show(
    "A2-unrecognized-resumed-reasoning-content-type",
    mapping,
    "turn-a2",
    "recap(reasoning_ended) -> terminal-shaped interim text -> resumed reasoning tagged " +
      "reasoning_status:is_reasoning but content_type:'reasoning' (not 'thoughts'/'code'). The " +
      "veto's allowlist is exactly {thoughts, code} (pro-final.ts:117-121), so this active-" +
      "reasoning node is INVISIBLE to it. Real answer has not landed. EXPECTED (correct): " +
      "done:false. If ACTUAL is done:true, the 'fix' silently reproduces the exact bug it was " +
      "built to close, via any future/renamed resumed-work content_type.",
    expectIncomplete("active or graph-incomparable reasoning remains for final text candidate"),
  );
  console.log(
    r.done === true
      ? "CONFIRMED: fails OPEN -- returns the premature interim text as if final."
      : "did not reproduce (contract rejected it)",
  );
}

// ---------------------------------------------------------------------
// A3. Multi-round conversation at scale: 6 prior completed rounds (each
// thoughts->recap->final, own turn_exchange_id) + the current round
// in-progress (recap landed, no final text yet) + one more round queued
// after (thoughts only). ~25 nodes. Verifies scoping holds under load
// pro-gate's "conversation reuse across review rounds" produces, and
// checks it doesn't degrade badly with N.
// ---------------------------------------------------------------------
{
  const mapping = {};
  const ROUNDS = 6;
  for (let i = 0; i < ROUNDS; i++) {
    const t = `round-${i}`;
    mapping[`${t}-thoughts`] = {
      id: `${t}-thoughts`, parent: i === 0 ? null : `round-${i - 1}-final`, children: [`${t}-recap`],
      message: {
        id: `${t}-thoughts`, author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] }, status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: t, reasoning_status: "is_reasoning" },
      },
    };
    mapping[`${t}-recap`] = {
      id: `${t}-recap`, parent: `${t}-thoughts`, children: [`${t}-final`],
      message: {
        id: `${t}-recap`, author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] }, status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: t, reasoning_status: "reasoning_ended" },
      },
    };
    mapping[`${t}-final`] = {
      id: `${t}-final`, parent: `${t}-recap`, children: [],
      message: {
        id: `${t}-final-msgid`, author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: [`round ${i} verdict text`] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: t, finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    };
  }
  const currentTurn = "round-current";
  mapping["current-thoughts"] = {
    id: "current-thoughts", parent: `round-${ROUNDS - 1}-final`, children: ["current-recap"],
    message: {
      id: "current-thoughts", author: { role: "assistant" }, recipient: "all",
      content: { content_type: "thoughts", parts: [] }, status: "finished_successfully", end_turn: false,
      metadata: { turn_exchange_id: currentTurn, reasoning_status: "is_reasoning" },
    },
  };
  mapping["current-recap"] = {
    id: "current-recap", parent: "current-thoughts", children: [],
    message: {
      id: "current-recap", author: { role: "assistant" }, recipient: "all",
      content: { content_type: "reasoning_recap", parts: [] }, status: "finished_successfully", end_turn: true,
      metadata: { turn_exchange_id: currentTurn, reasoning_status: "reasoning_ended" },
    },
  };
  // No final text for current turn yet -- correct answer is INCOMPLETE.
  show(
    "A3-six-prior-rounds-current-recap-only",
    mapping,
    currentTurn,
    "6 fully-completed prior rounds (each its own turn_exchange_id) precede the current in-" +
      "progress round, which has only reached recap (no final text yet). Expected: done:false " +
      "('no terminal recipient=all text after trusted reasoning_ended'), NOT a match against any " +
      "prior round's final text.",
    expectIncomplete("no terminal recipient=all text after trusted reasoning_ended"),
  );
}

// ---------------------------------------------------------------------
// A4. Field-drift fail-closed sweep: single-field mutations of the S2
// baseline-accept mapping, each checked to confirm it fails CLOSED
// (done:false) rather than silently passing or throwing.
// ---------------------------------------------------------------------
function baselineS2() {
  return {
    thoughts: {
      id: "thoughts", parent: null, children: ["recap"],
      message: {
        id: "msg-thoughts", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-a4", reasoning_status: "is_reasoning" },
      },
    },
    recap: {
      id: "recap", parent: "thoughts", children: ["final"],
      message: {
        id: "msg-recap", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a4", reasoning_status: "reasoning_ended" },
      },
    },
    final: {
      id: "final", parent: "recap", children: [],
      message: {
        id: "msg-final", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["VERDICT: SHIP"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a4", finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
  };
}

const drifts = [
  ["recipient missing on final (undefined !== 'all')", (m) => { delete m.final.message.recipient; }],
  ["end_turn: null instead of true on final", (m) => { m.final.message.end_turn = null; }],
  ["content_type capitalized 'Text' on final", (m) => { m.final.message.content.content_type = "Text"; }],
  ["finish_details.type renamed 'completed'", (m) => { m.final.message.metadata.finish_details.type = "completed"; }],
  ["reasoning_status renamed 'reasoningEnded' (camelCase) on recap", (m) => { m.recap.message.metadata.reasoning_status = "reasoningEnded"; }],
  ["content_type renamed 'reasoningRecap' (camelCase) on recap", (m) => { m.recap.message.content.content_type = "reasoningRecap"; }],
  ["parts[0] is an object {type,text} instead of a string (Responses-API-style)", (m) => { m.final.message.content.parts = [{ type: "output_text", text: "VERDICT: SHIP" }]; }],
];
for (const [label, mutate] of drifts) {
  const m = baselineS2();
  mutate(m);
  let result, threw = false;
  try {
    result = evaluateProTurnCompletion(m, "turn-a4");
  } catch (e) {
    threw = true;
    result = { threw: String(e) };
  }
  console.log(`\n=== A4-drift: ${label} ===`);
  console.log(`result: ${JSON.stringify(result)}`);
  const safe = !threw && result.done === false;
  if (!safe) {
    failures += 1;
    console.error(`ASSERTION FAILED: A4-drift ${label}`);
  }
  console.log(threw ? "THROWS (uncaught exception, not a clean fail-closed)" : (safe ? "fails closed (safe)" : "FAILS OPEN (unsafe)"));
}

// ---------------------------------------------------------------------
// A5. Disconnected subgraph: a terminal-shaped text node exists with the
// right turn_exchange_id and passes every per-node check, but its parent
// chain does NOT lead back to the reasoningEnded recap at all (different
// root entirely -- e.g. a data anomaly, or two independent recap/final
// pairs under the same turn_exchange_id due to a retried send).
// ---------------------------------------------------------------------
{
  const mapping = {
    recap: {
      id: "recap", parent: null, children: [],
      message: {
        id: "msg-recap", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a5", reasoning_status: "reasoning_ended" },
      },
    },
    // Same turn_exchange_id, but parented under a totally separate root --
    // not a descendant of `recap` at all.
    strayFinal: {
      id: "strayFinal", parent: "someOtherRoot", children: [],
      message: {
        id: "msg-stray-final", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["stray answer text"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a5", finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
  };
  show(
    "A5-disconnected-subgraph-same-turn-id",
    mapping,
    "turn-a5",
    "A terminal-shaped text node shares the turn_exchange_id and passes every field check, but " +
      "its parent chain doesn't lead back to the recap (parent points to a node absent from the " +
      "mapping). Expected: done:false ('no terminal recipient=all text after trusted " +
      "reasoning_ended') -- confirms ancestry, not just turn-id + field match, is load-bearing.",
    expectIncomplete("no terminal recipient=all text after trusted reasoning_ended"),
  );
}

// ---------------------------------------------------------------------
// A6. Regenerate-after-completion: user regenerates an ALREADY-COMPLETE
// Pro answer. Both branches finish (two independent recap->final chains
// under the same turn_exchange_id, siblings off a common ancestor). Real,
// user-triggered ChatGPT behavior (the "regenerate" button), distinct
// from S4's stray-reasoning-sibling case (there, one branch never reached
// a terminal text at all).
// ---------------------------------------------------------------------
{
  const mapping = {
    root: { id: "root", parent: null, children: ["thoughtsA", "thoughtsB"], message: null },
    thoughtsA: {
      id: "thoughtsA", parent: "root", children: ["recapA"],
      message: {
        id: "msg-thoughtsA", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] }, status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-a6", reasoning_status: "is_reasoning" },
      },
    },
    recapA: {
      id: "recapA", parent: "thoughtsA", children: ["finalA"],
      message: {
        id: "msg-recapA", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] }, status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a6", reasoning_status: "reasoning_ended" },
      },
    },
    finalA: {
      id: "finalA", parent: "recapA", children: [],
      message: {
        id: "msg-finalA", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["VERDICT: SHIP (first generation)"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a6", finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
    thoughtsB: {
      id: "thoughtsB", parent: "root", children: ["recapB"],
      message: {
        id: "msg-thoughtsB", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] }, status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-a6", reasoning_status: "is_reasoning" },
      },
    },
    recapB: {
      id: "recapB", parent: "thoughtsB", children: ["finalB"],
      message: {
        id: "msg-recapB", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] }, status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a6", reasoning_status: "reasoning_ended" },
      },
    },
    finalB: {
      id: "finalB", parent: "recapB", children: [],
      message: {
        id: "msg-finalB", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["VERDICT: FIX-FIRST (regenerated)"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-a6", finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
  };
  show(
    "A6-regenerate-both-branches-complete-same-turn-id",
    mapping,
    "turn-a6",
    "User hit 'regenerate' on an already-complete Pro answer; ChatGPT's UI selects the newer " +
      "branch (finalB) and would show ONLY that to a human, but both branches share turn_exchange_id " +
      "(no per-branch id in this contract) and both are genuinely complete. Expected per the " +
      "documented leaf-tie-break rule: 'ambiguous terminal text branches (2)' -- done:false, even " +
      "though a real complete answer (finalB, the one the UI shows) exists. This is a plausible " +
      "false-negative source distinct from S4: not a stray/never-finished branch, but two FINISHED " +
      "branches, because the contract has no signal for 'which branch is current' (no current_node " +
      "field is read -- confirmed absent from every field this function touches, WIRE-SHAPE.md S1).",
    expectIncomplete(),
  );
}

console.log("\n" + "=".repeat(100));
console.log(`Adversarial fixture run complete: ${failures === 0 ? "all assertions passed" : `${failures} assertion(s) failed`}.`);
if (failures > 0) process.exitCode = 1;
