---
title: "An emptied file input is not proof of pickup; only the chip is"
date: "2026-09-28"
category: "conventions"
module: "pro-gate"
problem_type: "design_pattern"
component: "development_workflow"
severity: "high"
applies_when:
  - "Browser automation decides whether a page it does not own accepted input it injected, such as a file set on an input element or text typed into an editor"
  - "A completion or retry check reads page state that the target app may reset as a side effect of handling the input, whether or not it kept it"
  - "Choosing which signal a retry-on-drop loop treats as success, or adding a second, weaker signal to catch a slow primary one"
  - "Validating a browser-timing fix whose unit fakes and proof pages encode the same model of the page as the fix"
symptoms:
  - "Remote attachments fail intermittently with \"Attachment did not appear in ChatGPT composer\" and no error on the ChatGPT side"
  - "A pickup check reports the file taken on transfers ChatGPT dropped, so the retry meant to recover them never runs"
  - "The fix passes its unit fake and proof pages, then fails live in the production order"
tags:
  - pro-gate
  - oracle
  - attachment-pickup
  - silent-drop
  - file-input
  - chip-receipt
  - remote-attach
  - live-verification
---

# An emptied file input is not proof of pickup; only the chip is

## Context

pro-gate hands its review bundle to ChatGPT through Oracle. In remote-Chrome mode Oracle attaches the file by filling a composer file input and dispatching `change` (`uploadAttachmentViaDataTransfer`, Oracle `src/browser/actions/remoteFileTransfer.ts`). From 2026-09-24 those attachments failed intermittently with "Attachment did not appear in ChatGPT composer" (pro-gate #223). The cause was a race. Oracle could attach before the composer's file input existed or was wired, and ChatGPT then dropped the file without any error. The fix, upstream in steipete/oracle PR #521, waits for the file input and transfers again when ChatGPT did not pick the file up. That made one decision central: what counts as picked up?

The first answer was wrong. #521's earlier head, Oracle commit `69cb796b`, built on this host as Oracle 0.20.0-sb.3, counted a transfer as picked up when the chip appeared, or when ChatGPT's change handler had emptied the input Oracle filled. Its check read `(await transferredInput(runtime, evidenceId, fileName, "read")) === "consumed"` (0.20.0-sb.3 pin, `remoteFileTransfer.ts:126`). The theory was that the handler empties the input only when it takes the file. Live trials against chatgpt.com on 2026-09-27 disproved it. In the words of `2e55713c`'s commit message:

- "In every instrumented transfer (8), accepted or dropped, the handler emptied the input before the dispatch returned (1 file at dispatch, 0 after the handlers)."
- "The dropped transfers never showed a chip and never sent POST /backend-api/files, yet 69cb796b gave up on 4 of 7 trials in the production order (navigate, prompt ready, attach) without a retry".

The unit fake and the real-Chrome proof pages had passed, because they modelled the same wrong theory of the page. The sb.3 pin was cut at 15:21 EDT and replaced by the sb.4 pin at 15:49 the same afternoon. sb.3 was never the installed build.

`2e55713c`, the head of #521, counts pickup by the chip alone. This host runs it as the pinned build Oracle 0.20.0-sb.4.

## Guidance

1. **A signal the failure path also produces is not evidence of success.** Before an observable becomes a completion check against a page you do not own, confirm live that the failure path does not produce it too. The emptied input fires on keep and on drop alike, so it carries no information, and no amount of logic layered on it recovers a correct decision.
2. **Gate on the artifact only success produces.** Here that is the attachment chip or its evidence receipt. On the network side it is the file upload request. `2e55713c` (`remoteFileTransfer.ts:115-131`) polls for the chip and nothing else:

   ```ts
   for (;;) {
     if (await isAttachmentVisible(runtime, fileName, evidenceId, { countFileInput: false })) {
       return true;
     }
     if (Date.now() >= deadline) {
       return false;
     }
     await delay(200);
   }
   ```

   `countFileInput: false` keeps Oracle's own FileList out too. That FileList is present on both paths for the same reason.
3. **Do not add the ambiguous signal back as weaker corroboration.** The emptied-input branch was added to catch a chip that was still rendering. It is exactly what hid the real drops.
4. **When nothing separates a slow success from a failure, bound the wait and state the cost.**
   - Oracle waits 0.5 s after the transfer (`remoteFileTransfer.ts:72`), then polls for the chip for `PICKUP_WAIT_MS = 3_000` (`:23`).
   - On a timeout it empties the input only if the input still holds this transfer's file (`:149-153`), then transfers again, up to `MAX_TRANSFERS = 3` (`:24`, `:73-81`).
   - The cost is that a file ChatGPT accepted, but whose chip takes longer than 3.5 s, is sent again. A unit test pins that cost ("sends the file again when its chip is slower than the pickup wait", Oracle `tests/browser/remoteFileTransfer.test.ts:198-206`).
   - The commit message records how often it happened live: "In the 10 accepted live transfers the chip was already showing at the first check, 0.5 s after the transfer."
5. **Validate against the live production-order reproduction, not only the fake.** After the correction the unit fake gained a `dropped: "emptied"` mode (Oracle `tests/browser/remoteFileTransfer.test.ts:17-23`), and the proof script gained an emptied-drop page. The commit message says both fail on `69cb796b`. Both were written only after a live run showed the handler's real behaviour.

## Why This Matters

A wrong pickup check fails in the worst direction. It reports success exactly on the drops, so the retry that exists to recover them never runs. The failure then surfaces about 10 s later as the original error ("Attachment did not appear in ChatGPT composer."), so the fix looks as if it did nothing.

For pro-gate, the seam is Oracle's, so pro-gate cannot fix it and depends on the pinned build.
- #521 was open at `2e55713c` as of 2026-09-28, and npm's latest `@steipete/oracle` was still 0.21.3, which predates it. Installing Oracle from npm on this host brings the race back.
- pro-gate records the Oracle build in each delivery condition. `pg_oracle_identity` (`lib/pro-gate-lib.sh:1250-1264`) reads `oracle --version`, and `pg_delivery_condition_digest` (`:1266-1268`) folds it in. A changed build is therefore a changed condition for the `delivery-failed-unchanged` stop.

## When to Apply

- Browser automation that decides whether a page accepted input it does not own: file inputs, rich editors, uploads.
- Any success check that reads state the target app may clear or reset while handling the input.
- Choosing, or adding, a signal for a retry-on-drop loop.
- Not needed when the app returns an explicit acknowledgement for the operation (an API response or a dedicated event) that only success produces.

## Examples

Evidence behind the rule, by class:

| Class | What it shows | Source |
|---|---|---|
| Live, production order | `69cb796b` failed 4 of 7 trials; all 8 instrumented transfers emptied the input, kept or dropped | `2e55713c` commit message |
| Live, final build | "A build of it attached 14 of 14 live, with one upload each", with no drop in the sample, so the live retry itself was not exercised | #521 body |
| Unit fake | `dropped: "held"` (no handler runs) and `dropped: "emptied"` (the handler empties and keeps nothing); the slow-chip resend | Oracle `tests/browser/remoteFileTransfer.test.ts:14-23`, `:198-206` |
| Real-Chrome proof pages | held drop, emptied drop, 2 s chip, re-render | Oracle `scripts/attachment-send-proof.mjs` at `2e55713c` |

All Oracle paths and commits here are in steipete/oracle at #521's head `2e55713c` unless another commit is named.

The held-FileList drop, where no handler runs, did not occur in the 2026-09-27 instrumented transfers: all 8 emptied the input. Only the fake and a proof page cover it.

## Related

- [Separate review lifecycle, applicability, capacity, and input trust](separate-review-lifecycle-applicability-capacity-and-input-trust.md): the same rule of requiring positive proof and inferring nothing from absence, applied to releasing review slots.
- [A dead-owner lock reclaim must prove death, not infer it from absence](a-dead-owner-lock-reclaim-must-prove-death-not-infer-it-from-absence.md): the same rule for lock reclaim.
- [Ownership lives on the verdict line, not at the end of the answer](ownership-lives-on-the-verdict-line-not-at-the-end-of-the-answer.md): a structural proxy that stood in for the real ownership signal.
- StartupBros-com/dotfiles `docs/solutions/best-practices/a-stub-proves-wiring-only-a-live-run-proves-a-cooperative-contract.md`: why the fake could not catch this. A stub built to the same theory as the fix proves only the wiring.
- pro-gate #223 tracks the attachment failures, and steipete/oracle#521 is the upstream fix.
