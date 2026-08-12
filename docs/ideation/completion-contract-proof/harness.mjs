// Proof harness for rosetta's evaluateProTurnCompletion contract against
// pro-gate's documented/plausible ChatGPT-web capture failure scenarios.
//
// Spec: /tmp/prove-contract/WIRE-SHAPE.md, /tmp/prove-contract/SCENARIOS.md
// Function under test: /tmp/prove-contract/pro-final.mjs (stripped, logic-identical
// copy of rosetta's src/pro-final.ts @ 12ed925a5381a9b2baad591f718182a059052f72)

import { evaluateProTurnCompletion } from "./pro-final.mjs";

const cases = [];

function record(entry) {
  cases.push(entry);
}

// ---------------------------------------------------------------------------
// S1a. Preamble mistaken for final — SNAPSHOT AT THE MOMENT ORACLE WRONGLY
// FINALIZES (only the preamble + resumed-reasoning nodes exist yet; the real
// answer has not landed). SCENARIOS.md lines 67-101.
// shape_source: SCENARIOS.md S1 first fixture (verbatim JSON, itself derived
// from WIRE-SHAPE.md's documented field contract).
// ---------------------------------------------------------------------------
{
  const mapping = {
    preamble: {
      id: "preamble", parent: null, children: ["resumedThoughts"],
      message: {
        id: "msg-preamble-1a2b",
        author: { role: "assistant" },
        recipient: "all",
        content: { content_type: "text",
          parts: ["I'll review this PR's diff for correctness, then check test coverage and the release checklist before giving a verdict."] },
        status: "finished_successfully",
        end_turn: true,
        metadata: {
          turn_exchange_id: "turn-s1",
          finish_details: { type: "stop" },
          model_slug: "gpt-5-6-pro",
        },
      },
    },
    resumedThoughts: {
      id: "resumedThoughts", parent: "preamble", children: [],
      message: {
        id: "msg-thoughts-2c3d",
        author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-s1", reasoning_status: "is_reasoning" },
      },
    },
  };
  const actual = evaluateProTurnCompletion(mapping, "turn-s1");
  record({
    name: "S1a-preamble-snapshot",
    scenario: "S1 (DOCUMENTED, oracle-preamble-completion-rootcause.md): preamble settled, reasoning has resumed but no reasoning_recap exists yet",
    expected: JSON.stringify({ done: false, reason: "trusted reasoning_ended signal not present" }),
    actual: JSON.stringify(actual),
    passed: actual.done === false && actual.reason === "trusted reasoning_ended signal not present",
    shape_source: "SCENARIOS.md lines 67-101 (verbatim)",
    oracle_dom_verdict: "TERMINAL (wrongly returns the 146-199 char preamble as the final review) if thinkingActive misreads false during the resumed-reasoning window (proofB residual, assistantResponse.ts:126-133)",
  });
}

// ---------------------------------------------------------------------------
// S1b. Same conversation, minutes later: the real answer has landed
// (recap + final appended). SCENARIOS.md lines 111-136.
// shape_source: SCENARIOS.md S1 second fixture (verbatim JSON).
// ---------------------------------------------------------------------------
{
  const mapping = {
    preamble: {
      id: "preamble", parent: null, children: ["resumedThoughts"],
      message: {
        id: "msg-preamble-1a2b",
        author: { role: "assistant" },
        recipient: "all",
        content: { content_type: "text",
          parts: ["I'll review this PR's diff for correctness, then check test coverage and the release checklist before giving a verdict."] },
        status: "finished_successfully",
        end_turn: true,
        metadata: {
          turn_exchange_id: "turn-s1",
          finish_details: { type: "stop" },
          model_slug: "gpt-5-6-pro",
        },
      },
    },
    resumedThoughts: {
      id: "resumedThoughts", parent: "preamble", children: ["recap"],
      message: {
        id: "msg-thoughts-2c3d",
        author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-s1", reasoning_status: "is_reasoning" },
      },
    },
    recap: {
      id: "recap", parent: "resumedThoughts", children: ["final"],
      message: {
        id: "msg-recap-4e5f", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-s1", reasoning_status: "reasoning_ended" },
      },
    },
    final: {
      id: "final", parent: "recap", children: [],
      message: {
        id: "msg-final-6g7h", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text",
          parts: ["[P1] lib/foo.sh:42 — ...\n\nVERDICT: FIX-FIRST — needs the null guard (run marker: pg-run-abc-123)"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-s1", finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
  };
  const actual = evaluateProTurnCompletion(mapping, "turn-s1");
  const expectedFinalText = "[P1] lib/foo.sh:42 — ...\n\nVERDICT: FIX-FIRST — needs the null guard (run marker: pg-run-abc-123)";
  record({
    name: "S1b-preamble-then-real-answer",
    scenario: "S1 (DOCUMENTED): same conversation minutes later — real answer has landed; must ignore the earlier ancestor preamble even though it also looks terminal-shaped",
    expected: JSON.stringify({ done: true, finalText: expectedFinalText, finalMessageId: "msg-final-6g7h", finishReason: "stop", modelSlug: "gpt-5-6-pro" }),
    actual: JSON.stringify(actual),
    passed: actual.done === true &&
      actual.finalText === expectedFinalText &&
      actual.finalMessageId === "msg-final-6g7h" &&
      actual.finishReason === "stop",
    shape_source: "SCENARIOS.md lines 111-136 (verbatim)",
    oracle_dom_verdict: "Would already have finalized TERMINAL on the preamble minutes earlier (S1a) and never re-poll to see this state at all — the real answer with actual Pn/VERDICT findings is never captured",
  });
}

// ---------------------------------------------------------------------------
// S2. Genuine terminal answer — baseline acceptance, mirrors rosetta's own
// test E (tests/sse.test.ts:266-288). SCENARIOS.md lines 164-194.
// shape_source: SCENARIOS.md S2 (verbatim JSON).
// ---------------------------------------------------------------------------
{
  const mapping = {
    thoughts: {
      id: "thoughts", parent: null, children: ["recap"],
      message: {
        id: "msg-thoughts", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-s2", reasoning_status: "is_reasoning" },
      },
    },
    recap: {
      id: "recap", parent: "thoughts", children: ["final"],
      message: {
        id: "msg-recap", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-s2", reasoning_status: "reasoning_ended" },
      },
    },
    final: {
      id: "final", parent: "recap", children: [],
      message: {
        id: "msg-final", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["P0: none\nP1: none\n\nVERDICT: SHIP — clean diff (run marker: pg-run-abc-123)"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-s2", finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
  };
  const actual = evaluateProTurnCompletion(mapping, "turn-s2");
  const expectedFinalText = "P0: none\nP1: none\n\nVERDICT: SHIP — clean diff (run marker: pg-run-abc-123)";
  record({
    name: "S2-genuine-terminal",
    scenario: "S2 (baseline): unbroken thoughts -> recap -> final chain, no preamble at all",
    expected: JSON.stringify({ done: true, finalText: expectedFinalText, finalMessageId: "msg-final", finishReason: "stop" }),
    actual: JSON.stringify(actual),
    passed: actual.done === true &&
      actual.finalText === expectedFinalText &&
      actual.finalMessageId === "msg-final" &&
      actual.finishReason === "stop",
    shape_source: "SCENARIOS.md lines 164-194 (verbatim); mirrors rosetta's own tests/sse.test.ts test E",
    oracle_dom_verdict: "Eventually TERMINAL, correctly (no mismatch on this path when not defeated by S1's residual)",
  });
}

// ---------------------------------------------------------------------------
// S3a. Cross-bind, malignant — foreign turn's completed answer sits after our
// prompt with a DIFFERENT turn_exchange_id. Query scoped to our own turn.
// SCENARIOS.md lines 226-269.
// shape_source: SCENARIOS.md S3a (verbatim JSON).
// ---------------------------------------------------------------------------
{
  const mapping = {
    ourPrompt: {
      id: "ourPrompt", parent: null, children: [],
      message: {
        id: "msg-user-ours", author: { role: "user" }, recipient: "all",
        content: { content_type: "text", parts: ["Review PR #1336 diff... (run marker: pg-run-ours-777)"] },
        status: "finished_successfully", end_turn: null,
        metadata: { turn_exchange_id: "turn-ours" },
      },
    },
    foreignThoughts: {
      id: "foreignThoughts", parent: "ourPrompt", children: ["foreignRecap"],
      message: {
        id: "msg-foreign-thoughts", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-foreign-1323", reasoning_status: "is_reasoning" },
      },
    },
    foreignRecap: {
      id: "foreignRecap", parent: "foreignThoughts", children: ["foreignFinal"],
      message: {
        id: "msg-foreign-recap", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-foreign-1323", reasoning_status: "reasoning_ended" },
      },
    },
    foreignFinal: {
      id: "foreignFinal", parent: "foreignRecap", children: [],
      message: {
        id: "msg-foreign-final", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text",
          parts: ["[P0] auth.go:88 — token leak\n\nVERDICT: FIX-FIRST — critical (run marker: pg-run-theirs-1323)"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-foreign-1323", finish_details: { type: "stop" } },
      },
    },
  };
  const actual = evaluateProTurnCompletion(mapping, "turn-ours");
  record({
    name: "S3a-cross-bind-malignant",
    scenario: "S3a (DOCUMENTED, CHANGELOG.md v0.31.1 #67 / pushbot#1336<-pushbot#1323): a different turn_exchange_id's completed foreign answer sits in the same mapping; query scoped to OUR turn_exchange_id",
    expected: JSON.stringify({ done: false, reason: "no assistant nodes for current turn_exchange_id" }),
    actual: JSON.stringify(actual),
    passed: actual.done === false && actual.reason === "no assistant nodes for current turn_exchange_id",
    shape_source: "SCENARIOS.md lines 226-269 (verbatim)",
    oracle_dom_verdict: "cdp-salvage's page-text heuristic (pre-fix: bare substring match; post-fix foreignAnswerMarker: text-position check) returns pushbot#1323's foreign review as if it were our PR#1336 review — this is the exact production incident",
  });
}

// ---------------------------------------------------------------------------
// S3b. Cross-bind, benign — reused conversation, an OLDER already-completed
// turn precedes ours; must NOT be convicted. SCENARIOS.md (lines 288-304)
// gives this only as abbreviated prose ("field shapes as in that test"),
// pointing at rosetta's OWN shipped test G (tests/sse.test.ts:311-345). So
// rather than reconstruct it from prose, this fixture is that literal test's
// mapping, hand-expanded field-by-field through its own `assistantNode()`
// helper (fixtures-from-rosetta/sse.test.ts:30-66) — i.e. de-sugared, not
// invented: every field value below (recipient default "all", status
// default "finished_successfully", end_turn default true for
// text/reasoning_recap, metadata.model_slug default "gpt-5-6-pro",
// PRO_TURN's literal UUID) is read directly off the helper's defaults and
// the test's own call sites (sse.test.ts:312-338), not chosen by me.
// shape_source: rosetta's own test G, expanded verbatim via its own helper —
// the closest thing to a non-hand-invented fixture in this whole harness.
// ---------------------------------------------------------------------------
{
  const PRO_TURN = "1dc9731f-4ea1-442c-885a-1f83606dddc1"; // sse.test.ts:28
  const mapping = {
    oldRecap: {
      id: "oldRecap", parent: null, children: [],
      message: {
        id: "oldRecap", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "previous-turn", reasoning_status: "reasoning_ended", finish_details: undefined, model_slug: "gpt-5-6-pro" },
      },
    },
    oldFinal: {
      id: "oldFinal", parent: "oldRecap", children: [],
      message: {
        id: "oldFinal", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["上一轮答案"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "previous-turn", reasoning_status: undefined, finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
    currentThoughts: {
      id: "currentThoughts", parent: "oldFinal", children: [],
      message: {
        id: "currentThoughts", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: PRO_TURN, reasoning_status: "is_reasoning", finish_details: undefined, model_slug: "gpt-5-6-pro" },
      },
    },
    currentRecap: {
      id: "currentRecap", parent: "currentThoughts", children: [],
      message: {
        id: "currentRecap", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: PRO_TURN, reasoning_status: "reasoning_ended", finish_details: undefined, model_slug: "gpt-5-6-pro" },
      },
    },
    currentFinal: {
      id: "currentFinal", parent: "currentRecap", children: [],
      message: {
        id: "currentFinal", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["当前轮完整答案"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: PRO_TURN, reasoning_status: undefined, finish_details: { type: "stop" }, model_slug: "gpt-5-6-pro" },
      },
    },
    nextThoughts: {
      id: "nextThoughts", parent: "currentFinal", children: [],
      message: {
        id: "nextThoughts", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "next-turn", reasoning_status: "is_reasoning", finish_details: undefined, model_slug: "gpt-5-6-pro" },
      },
    },
  };
  const actual = evaluateProTurnCompletion(mapping, PRO_TURN);
  record({
    name: "S3b-cross-bind-benign-reused-conversation",
    scenario: "S3b (mirrors rosetta's own shipped test G, tests/sse.test.ts:311-345 verbatim, expanded via its own assistantNode() helper): an older completed turn precedes ours, a next turn's reasoning follows ours, in the SAME mapping — must skip both and return only our own turn's answer",
    expected: JSON.stringify({ done: true, finalText: "当前轮完整答案", finalMessageId: "currentFinal", finishReason: "stop" }),
    actual: JSON.stringify(actual),
    passed: actual.done === true &&
      actual.finalText === "当前轮完整答案" &&
      actual.finalMessageId === "currentFinal" &&
      actual.finishReason === "stop",
    shape_source: "rosetta's own test G (fixtures-from-rosetta/sse.test.ts:311-345), hand-expanded field-by-field via its own assistantNode() helper (sse.test.ts:30-66) — not invented; SCENARIOS.md lines 288-304 only pointed at this test in abbreviated prose rather than giving verbatim JSON",
    oracle_dom_verdict: "N/A — pure DOM capture never sees the whole conversation's prior turns as a graph at all; this is a rosetta-only distinction. cdp-salvage's position-heuristic fix (v0.31.1) is the closest DOM-side analog and is designed to also treat this as benign.",
  });
}

// ---------------------------------------------------------------------------
// S4. Reasoning-sibling ambiguity — a reasoning_recap has two children: one a
// plausible terminal text, the other a graph-incomparable is_reasoning
// sibling. SCENARIOS.md lines 328-357.
// shape_source: SCENARIOS.md S4 (verbatim JSON).
// ---------------------------------------------------------------------------
{
  const mapping = {
    recap: {
      id: "recap", parent: null, children: ["candidateA", "thoughtsSiblingB"],
      message: {
        id: "msg-recap", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "reasoning_recap", parts: [] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-s4", reasoning_status: "reasoning_ended" },
      },
    },
    candidateA: {
      id: "candidateA", parent: "recap", children: [],
      message: {
        id: "msg-candidate-a", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["P0: none\n\nVERDICT: SHIP (run marker: pg-run-abc-123)"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-s4", finish_details: { type: "stop" } },
      },
    },
    thoughtsSiblingB: {
      id: "thoughtsSiblingB", parent: "recap", children: [],
      message: {
        id: "msg-thoughts-sibling-b", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "thoughts", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-s4", reasoning_status: "is_reasoning" },
      },
    },
  };
  const actual = evaluateProTurnCompletion(mapping, "turn-s4");
  record({
    name: "S4-reasoning-sibling-ambiguity",
    scenario: "S4 (PLAUSIBLE, proposed): reasoning_recap has two children — a terminal-looking text and a graph-incomparable is_reasoning sibling from a stray regenerate branch",
    expected: JSON.stringify({ done: false, reason: "active or graph-incomparable reasoning remains for final text candidate" }),
    actual: JSON.stringify(actual),
    passed: actual.done === false && actual.reason === "active or graph-incomparable reasoning remains for final text candidate",
    shape_source: "SCENARIOS.md lines 328-357 (verbatim)",
    oracle_dom_verdict: "Hypothetically TERMINAL on candidateA if that's the currently-rendered/selected branch — DOM capture has no visibility into the sibling branch's thoughtsSiblingB node at all, since ChatGPT's UI renders one branch at a time",
  });
}

// ---------------------------------------------------------------------------
// S5. In-progress, mid-reasoning, no recap yet. SCENARIOS.md lines 397-421.
// shape_source: SCENARIOS.md S5 (verbatim JSON).
// ---------------------------------------------------------------------------
{
  const mapping = {
    stage: {
      id: "stage", parent: null, children: ["thoughts"],
      message: {
        id: "16ced1a1-139f-42b9-99c9-3758d40810f9", author: { role: "assistant" },
        recipient: "all",
        content: { content_type: "text",
          parts: ["12 mechanisms surveyed; narrowing candidates to structural expansion, minimal write-set..."] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-s5" },
      },
    },
    thoughts: {
      id: "thoughts", parent: "stage", children: [],
      message: {
        id: "f6544ce3-44ec-48b2-880d-386a6fa4cacb", author: { role: "assistant" },
        recipient: "all",
        content: { content_type: "thoughts", parts: [] },
        status: "finished_successfully", end_turn: false,
        metadata: { turn_exchange_id: "turn-s5", reasoning_status: "is_reasoning" },
      },
    },
  };
  const actual = evaluateProTurnCompletion(mapping, "turn-s5");
  record({
    name: "S5-in-progress-no-recap",
    scenario: "S5 (baseline rejection, mirrors rosetta's own tests/sse.test.ts A/B): short end_turn-flagged text stage with reasoning demonstrably still active as its child; no reasoning_recap anywhere",
    expected: JSON.stringify({ done: false, reason: "trusted reasoning_ended signal not present" }),
    actual: JSON.stringify(actual),
    passed: actual.done === false && actual.reason === "trusted reasoning_ended signal not present",
    shape_source: "SCENARIOS.md lines 397-421 (verbatim)",
    oracle_dom_verdict: "Correctly INCOMPLETE in the common case (stop control / thinking indicator detected) — but this is the exact topology where S1's proofB selector-drift residual can wrongly flip to TERMINAL",
  });
}

// ---------------------------------------------------------------------------
// S6. Weak/instant-model dispatch — no Pro handoff, no reasoning_recap will
// EVER arrive for this turn_exchange_id. SCENARIOS.md lines 469-482.
// shape_source: SCENARIOS.md S6 (verbatim JSON).
// ---------------------------------------------------------------------------
{
  const mapping = {
    instantFinal: {
      id: "instantFinal", parent: null, children: [],
      message: {
        id: "instant", author: { role: "assistant" }, recipient: "all",
        content: { content_type: "text", parts: ["P0: none\n\nVERDICT: SHIP (run marker: pg-run-abc-123)"] },
        status: "finished_successfully", end_turn: true,
        metadata: { turn_exchange_id: "turn-s6" },
      },
    },
  };
  const actual = evaluateProTurnCompletion(mapping, "turn-s6");
  record({
    name: "S6-weak-instant-model-no-handoff",
    scenario: "S6 (PLAUSIBLE, grounded in PRO_GATE_MODEL_STRATEGY=current risk): a non-Pro/instant model's terminal-shaped answer with NO reasoning_status field anywhere in the mapping — correct if the caller never routes this turn through evaluateProTurnCompletion at all",
    expected: JSON.stringify({ done: false, reason: "trusted reasoning_ended signal not present" }),
    actual: JSON.stringify(actual),
    passed: actual.done === false && actual.reason === "trusted reasoning_ended signal not present",
    shape_source: "SCENARIOS.md lines 469-482 (verbatim)",
    oracle_dom_verdict: "N/A — no DOM-capture analog; oracle would just show the answer. The finding here is about the CALLER'S dispatch gate (client.ts's stream_handoff check), not a defect in pro-final.ts: this fixture demonstrates the function would hang polling forever on a correct-but-non-Pro answer if a naive integration called it unconditionally.",
  });
}

// ---------------------------------------------------------------------------
// Run + report
// ---------------------------------------------------------------------------
let allPassed = true;
console.log("=".repeat(100));
console.log("PROOF HARNESS: rosetta evaluateProTurnCompletion vs pro-gate/oracle capture scenarios");
console.log("=".repeat(100));
for (const c of cases) {
  if (!c.passed) allPassed = false;
  console.log(`\n[${c.passed ? "PASS" : "FAIL"}] ${c.name}`);
  console.log(`  scenario: ${c.scenario}`);
  console.log(`  shape_source: ${c.shape_source}`);
  console.log(`  expected:            ${c.expected}`);
  console.log(`  actual (verbatim):   ${c.actual}`);
  console.log(`  oracle DOM verdict:  ${c.oracle_dom_verdict}`);
}
console.log("\n" + "=".repeat(100));
console.log(`SUMMARY: ${cases.filter(c => c.passed).length}/${cases.length} cases passed`);
console.log("=".repeat(100));

if (!allPassed) {
  process.exitCode = 1;
}

// Machine-readable dump for downstream reporting.
console.log("\n__HARNESS_JSON_START__");
console.log(JSON.stringify(cases, null, 2));
console.log("__HARNESS_JSON_END__");
