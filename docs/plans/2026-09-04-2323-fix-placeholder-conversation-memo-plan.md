---
title: Placeholder Conversation Memos Never Pin a Slot - Plan
type: fix
date: 2026-09-04
topic: placeholder-conversation-memo
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

# Placeholder Conversation Memos Never Pin a Slot - Plan

## Goal Capsule

- **Objective:** A review run whose remembered conversation URL is not a real conversation can no longer hold a ChatGPT slot indefinitely, and an operator reading status can tell what kind of stall any unresolved run is in.
- **Means:** Check the shape of the conversation id when a URL is remembered and every time it is read; revoke a memo that fails so the pass rescans and, with nothing carrying the marker, takes the confirmed-absent path that already sweeps on TTL plus confirmed misses. Add the salvage classification and time remaining to status.
- **Product authority:** This plan owns the memo validity rule, the rescan behavior after a revocation, and the status fields. It does not change when a review may be declared finished, refunded, or released; issue #109's evidence-gated rule for verdict-less real conversations stands.
- **Open blockers:** None.
- **Stop conditions:** Stop and surface rather than guess if the shape check would reject any id observed in the live conversation-memo directory that later proved to be a real conversation, or if reaching the confirmed-absent path after a revocation would require touching the still-generating or inconclusive branches.

---

## Product Contract

### Summary

Make the harvest pass distrust a conversation memo whose id does not look like a real conversation id, at write time and at read time, and let the existing absence sweep finish the job once the memo is gone. Show the stall class and time remaining in status beside the age and miss fields it already has.

### Problem Frame

Since 2026-08-30 four reviews have pinned a ChatGPT slot for a day or more while reporting "Still working" (pushbot PRs 2284, 2333, 2307, 2368). Two of them remembered a synthetic placeholder URL, `https://chatgpt.com/c/WEB:<uuid>`, as the authoritative conversation for their marker. The page behind that URL is titled "ChatGPT" and is not a conversation, so every collection pass renders it, finds neither the run's marker nor a foreign one, classifies the result as inconclusive, and returns without advancing the miss counter, which is the engine's deliberate protection against transient rendering failures. The pass then exits still-in-progress and the reservation stays recoverable forever. The existing shape check on remembered URLs tests only the `https://chatgpt.com/c/` prefix, so the placeholder passes it. Nothing in status distinguishes this parked run from one whose model is genuinely still writing; the operator learns the difference by reading stderr and listing the state directory. Two placeholder memos and eight in-progress markers, the oldest 80 hours, sat in the state directory on 2026-09-04.

### Key Decisions

- **Validate the conversation id's shape, not the page's content.** The placeholder is distinguishable from a real id by syntax alone; "rendered without our marker" stays a transient that never counts as a miss, so the engine's fail-closed posture on blank renders is untouched. Governs R1, R2, R5.
- **Leave release logic and the still-generating branch alone.** (session-settled: user-approved — chosen over extending the still-generating branch with the TTL-plus-confirmed-miss sweep its sibling has: that branch is only entered for a page carrying the marker, so a sweep there could never reach the placeholder failure, and the change would have touched reservation release for no gain.) Governs R4, R5.
- **Stall detail lives in status only.** (session-settled: user-approved — chosen over adding detail to the recovery relay's state line: the relay's six fixed states are a contract other renderers already conform to.) Governs R6, R7.
- **A placeholder-only run gets no memo and rescans every pass.** (session-settled: user-approved — chosen over remembering the placeholder and revoking later: a bad memo remembered is the failure this plan removes.) Governs R1, R4.
- **Verdict-less real conversations stay held.** A real id whose page keeps rendering without the marker, or whose turn never ends, is not terminalized here; issue #109's re-scope requires positive evidence before any such run is released. Governs R5.

### Actors

- A1. The operator, who reads status, runs recovery by hand, and owns the ChatGPT account.
- A2. A caller of the runtime: the skill, relay, daemon, or the dotfiles loop script, which dispatch the typed decision and relay recovery states.
- A3. The engine's harvest and recovery pass, which reads and writes conversation memos and decides which lifecycle branch a pass takes.
- A4. The browser salvage helper, which renders candidate conversations, classifies what it sees, and remembers URLs for markers.

### Requirements

**Memo validity**

- R1. A conversation URL is remembered for a marker only when its conversation id has the shape of a real ChatGPT conversation id; a placeholder id such as `WEB:<uuid>` is never persisted.
- R2. Every read of a remembered URL re-applies the same shape check before the URL is trusted, and a memo that fails is revoked in that pass.
- R3. A rejected or revoked placeholder is named in the pass's diagnostics with the marker and the offending id, so the operator can see why the memo was dropped.

**Sweep and recovery**

- R4. After a revocation the same pass rescans candidates as if no memo existed; finding no conversation that carries the marker takes the existing confirmed-absent path, which advances the miss counter and releases the reservation only after the TTL and the configured number of confirmed misses.
- R5. The still-generating branch, the inconclusive branch's rule that a blank render never counts as a miss, and every charge and refund rule are unchanged.

**Status visibility**

- R6. Status output, human and JSON, reports for each unresolved attempt the salvage classification from its latest pass and the time remaining before the reservation TTL is satisfied, beside the age and miss fields it already carries.
- R7. The recovery relay's six state lines are unchanged; stall detail appears only in status output.

**Regression coverage**

- R8. Tests cover: a placeholder id is never remembered; a placeholder memo is revoked on read and the pass proceeds to rescan; a rescan with no candidate reaches the confirmed-absent path; a real-id memo whose page renders without the marker stays inconclusive and holds; status shows the classification and time remaining.

### Key Flows

- F1. Remembering a URL
  - **Trigger:** The salvage helper identifies the conversation it just submitted or found for a marker.
  - **Actors:** A4
  - **Steps:** The helper checks the id shape; a real id is remembered as before; a placeholder is not written and the rejection is logged with the marker and id.
  - **Covered by:** R1, R3
- F2. A collection pass with a placeholder memo
  - **Trigger:** A harvest or recovery pass reads the memo for a marker whose remembered URL is a placeholder.
  - **Actors:** A3, A4
  - **Steps:** The shape check fails; the memo is revoked and logged; the pass rescans all candidates; with no conversation carrying the marker, the pass takes the confirmed-absent path and advances the miss counter; on later passes the same happens until the TTL and miss threshold are both met, when the reservation is recovery-exhausted with its charge retained.
  - **Covered by:** R2, R3, R4, R5
- F3. Reading status during a stall
  - **Trigger:** The operator runs status for a PR or marker with an unresolved attempt.
  - **Actors:** A1, A3
  - **Steps:** The entry shows the classification from the latest pass, the attempt's age, its miss count, and the time remaining before the TTL is satisfied; recovery through the skill still relays one of the six fixed states.
  - **Covered by:** R6, R7

### Acceptance Examples

- AE1. Placeholder never remembered
  - **Covers R1, R3.**
  - **Given** a run whose first captured URL is `https://chatgpt.com/c/WEB:57cc5403-ad61-4ccd-af90-ad28a539081e`
  - **When** the salvage helper would remember it
  - **Then** no memo is written for the marker and the log names the rejected id.
- AE2. Placeholder memo drains through the absence sweep
  - **Covers R2, R3, R4, R5.**
  - **Given** an existing memo `https://chatgpt.com/c/WEB:5789ac7a-755a-4385-82db-0c1eb37ccf88` for a marker whose reservation is 21 hours old with zero misses
  - **When** three collection passes run at least the configured interval apart
  - **Then** the first pass revokes the memo and rescans, each pass records one confirmed miss, and after the third pass the reservation is recovery-exhausted with its charged round retained and its capacity released.
- AE3. Real id, blank render, still held
  - **Covers R5.**
  - **Given** a memo `https://chatgpt.com/c/6a959c8f-c95c-83ea-81b8-85a3ea5d6cbc` whose page renders without the marker
  - **When** a collection pass reads it
  - **Then** the memo is kept, the pass is inconclusive, the miss counter does not advance, and the reservation stays recoverable.
- AE4. Status shows the stall
  - **Covers R6, R7.**
  - **Given** an unresolved attempt classified owned-incomplete on its latest pass, three hours old, with no misses and a six-hour TTL
  - **When** the operator runs status
  - **Then** the entry shows owned-incomplete, the age, zero misses, and three hours remaining; running recovery through the skill still relays "Still working".
- AE5. Real ids are unaffected
  - **Covers R1.**
  - **Given** a captured URL with a canonical conversation id
  - **When** the salvage helper remembers it
  - **Then** the memo is written exactly as before this change.

### Success Criteria

- The conversation-memo directory on the operator's box holds zero memos with a non-conversation id after one upgrade cycle, with no manual deletion.
- Every reservation that held a placeholder memo at upgrade time reaches recovery-exhausted through the absence path within the TTL plus three confirmed misses.
- Charge and refund counts for runs without a placeholder memo are unchanged across the release.
- An operator can tell a parked run from a generating one from status alone.

### Scope Boundaries

- A completion predicate for a real conversation that never emits a verdict is out; it stays evidence-gated per issue #109.
- A real-id memo whose page keeps rendering without the marker stays held; distinguishing a dead page from a transient render is a harder problem this plan does not take on.
- The stall classification as a ledger field waits for the ledger row schema in the hygiene batch.
- The still-generating branch, the inconclusive branch's no-miss rule, and the reservation guard are not modified.
- Wait sizing shipped separately in v0.41.0 and is not revisited here.

### Dependencies and Assumptions

- The shape of a real ChatGPT conversation id is a 36-character hexadecimal-and-dash identifier, as every canonical memo on the operator's box shows; planning verifies this against the live memo directory before fixing the check.
- oracle 0.18.0 is the installed browser driver; before choosing the classification vocabulary for R6, planning reads what oracle already records about incomplete captures, reattach, and heartbeat liveness so the status field neither duplicates nor contradicts it.
- The confirmed-absent path's TTL and miss threshold keep their current defaults; this plan relies on them rather than tuning them.

### Outstanding Questions

**Deferred to Planning**

- The exact id pattern the shape check accepts, verified against live memos.
- Whether revocation reuses the existing provenance-rejection helper or a sibling that logs the shape failure distinctly.
- Where the R6 classification is sourced, the salvage helper's evidence kind or its sub-reason, and its closed vocabulary.
- How time remaining is derived in status from the reservation's creation time and the TTL.

### Sources

- Issue #109 and its comments of 2026-08-31 (root cause: a `WEB:<uuid>` placeholder persisted as the authoritative memo) and 2026-09-01 (re-scope: no terminalizer from age, TTL, missing verdict, or absent spinner alone).
- `bin/cdp-salvage.mjs` lines 45-49 (a remembered URL is authoritative and exempt from the blacklist and render cap), 171 and 260 (the prefix-only shape check), 1122-1128 (a page with no marker classifies as inconclusive), 1196-1199 (classification collapses to generating), 1466-1476 and 1519-1526 (the remembered-URL branch and its inconclusive exit).
- `bin/oracle-review.sh` lines 2600-2607 (the unbindable branch's TTL-plus-miss gate), 2658-2662 (the still-generating branch), the confirmed-absent case near 2681, the inconclusive case that deliberately skips the miss counter, and the status block at 1107-1562 with the per-reservation object at 1272.
- `lib/pro-gate-lib.sh` lines 1261-1288 (one confirmed-absent observation; release needs misses and TTL together) and 2298-2305 (provenance rejection removes the memo so the next pass rescans).
- `tests/cdp-salvage.test.mjs` lines 1424-1442 (repeated sampling of a still-generating conversation is asserted as correct and stays so).
- `docs/ideation/2026-09-04-pro-gate-ideation-refresh.html`, idea 2.
- `docs/solutions/conventions/separate-review-lifecycle-applicability-capacity-and-input-trust.md` for the lifecycle rules this plan must not cross.
