# Completion-contract proof artifacts

Evidence for `../2026-08-12-completion-contract-proof.md`. **Nothing here is a dependency.**
No file in `bin/`, `lib/`, `skills/`, `agents/` or `daemon/` imports any of it, and nothing here
runs as part of pro-gate. These are reproducible evidence artifacts for a decision, kept in-repo
only because `/tmp` is cleared on reboot and re-deriving them costs another multi-agent pass.

The contract itself is destined for **oracle**, not pro-gate — see
`../2026-08-12-chatgpt-web-bridge-decisions.md` §Q3 and `VENUE.md`.

## Provenance

`pro-final.mjs` is `src/pro-final.ts` from **SyntaxSmith/rosetta** (MIT), commit
`12ed925a5381a9b2baad591f718182a059052f72`, with TypeScript type annotations and interface
declarations stripped so it runs under plain `node`. **No logic was changed.** Verify:

```bash
diff <(git -C /path/to/rosetta show 12ed925a:src/pro-final.ts) pro-final.mjs
```

Every differing line is a type annotation removal or the signature line it sat on.

## Reproduce

```bash
node harness.mjs        # 8 documented/baseline scenarios -> expect 8/8
node adversarial.mjs    # drift + defect fixtures, prints each verdict
node verify/harness-stub.mjs   # discriminating-power control -> expect 0/8
```

The stub control matters: it swaps the real function for one that always returns `{done:false}`
and re-runs the same assertions. It scores **0/8**, which is what makes the 8/8 meaningful — the
assertions check exact `finalText` / `finalMessageId` / `reason` values, so a degenerate
implementation cannot satisfy them.

## What the runs show

- `harness.mjs` — 8/8. The contract correctly rejects the preamble that pro-gate's oracle
  historically captured as a review (S1a), correctly returns the real answer once it lands (S1b),
  and is immune by construction to the cross-bind shape that hit pushbot#1334 and pro-gate#66
  (S3a), while still accepting a benign reused conversation (S3b).
- `adversarial.mjs` — two real defects in rosetta's algorithm, both reproduced by execution:
  - **A2, fails OPEN.** The active-reasoning veto (`pro-final.ts:117-121`) allowlists
    `content_type` of exactly `"thoughts"` or `"code"`. A resumed-reasoning node tagged
    `reasoning_status:"is_reasoning"` but `content_type:"reasoning"` is invisible to it, and the
    function returns `{done:true, finalText:"Quick take: looks fine at a glance."}` — reproducing
    the exact premature-capture bug the contract exists to prevent.
  - **A6, fails CLOSED.** Two genuinely-complete `recap -> final` branches under one
    `turn_exchange_id` (a regenerate — pro-gate reuses conversations across review rounds) reject
    *both*. The function never reads `current_node`, so it cannot tell "stray abandoned branch"
    from "the finished answer the UI is currently displaying."
  - Wire-drift fixtures (renamed fields, `parts[0]` becoming an object) all fail **closed** — safe,
    but silently, which is its own operational risk.

## Files

| File | What it is |
|---|---|
| `harness.mjs` | 8 scenario fixtures + strict assertions |
| `adversarial.mjs` | drift and defect fixtures (A1-A6) |
| `pro-final.mjs` | rosetta's contract, type-stripped, logic-identical |
| `verify/harness-stub.mjs` | same assertions against a degenerate stub |
| `verify/stub-always-incomplete.mjs` | the stub |
| `WIRE-SHAPE.md` | every field the contract reads, with `file:line` |
| `SCENARIOS.md` | incident-grounded scenario specs |
| `VENUE.md` | fork vs upstream landing analysis |
| `CONNECTOR-SCOPE.md` | `@GitHub` connector OAuth grant audit |

## Caveat that limits all of it

Rosetta ships **no** recorded/HAR/replay fixtures — every fixture here and in rosetta's own 54
tests is hand-authored. This proves the *function* behaves as designed against these shapes; it
does **not** prove the shapes match live ChatGPT traffic. Capturing one real
`/backend-api/conversation/<id>` response and diffing it against `WIRE-SHAPE.md` would close that
gap and is the single highest-value follow-up.
