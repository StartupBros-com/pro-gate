/**
 * Minimal conversation-mapping shapes used to prove that a Pro turn has
 * actually finished. ChatGPT adds many unrelated fields to these objects; the
 * verifier deliberately ignores them.
 */



/**
 * Decide whether one exact Pro turn has reached a trustworthy final state.
 *
 * Important: `end_turn`, `finished_successfully`, stream terminators, and
 * create_time ordering are not completion proof. Pro can emit several short
 * progress texts carrying both flags and then resume reasoning. The live
 * mapping observed in August 2026 instead has this structural contract:
 *
 *   ... reasoning nodes -> reasoning_recap(reasoning_ended)
 *       -> recipient=all text(finish_details.type=stop)
 *
 * We therefore require that topology and reject any candidate followed by (or
 * graph-incomparable with) an `is_reasoning` thoughts/code node from the same
 * turn. Failing closed is intentional: an unverifiable response must not be
 * returned or persisted as though it were the final answer.
 */
export function evaluateProTurnCompletion(
  mapping,
  turnExchangeId,
) {
  if (!turnExchangeId) {
    return { done: false, reason: "missing turn_exchange_id" };
  }

  const turnMessages = [];
  for (const [key, node] of Object.entries(mapping)) {
    const message = node.message;
    if (!message || message.author?.role !== "assistant") continue;
    if (message.metadata?.turn_exchange_id !== turnExchangeId) continue;
    turnMessages.push({ key, message });
  }

  if (turnMessages.length === 0) {
    return { done: false, reason: "no assistant nodes for current turn_exchange_id" };
  }

  const reasoningEnded = turnMessages.filter(({ message }) =>
    message.content?.content_type === "reasoning_recap" &&
    message.recipient === "all" &&
    message.status === "finished_successfully" &&
    message.end_turn === true &&
    message.metadata?.reasoning_status === "reasoning_ended"
  );
  if (reasoningEnded.length === 0) {
    return { done: false, reason: "trusted reasoning_ended signal not present" };
  }

  const terminalTexts = turnMessages.filter(({ message }) => {
    const parts = message.content?.parts;
    return message.content?.content_type === "text" &&
      message.recipient === "all" &&
      message.status === "finished_successfully" &&
      message.end_turn === true &&
      message.metadata?.finish_details?.type === "stop" &&
      typeof message.id === "string" &&
      message.id.length > 0 &&
      Array.isArray(parts) &&
      typeof parts[0] === "string" &&
      parts[0].length > 0;
  });

  const afterReasoningEnded = terminalTexts.filter(({ key }) =>
    reasoningEnded.some((ended) => isDescendantOf(mapping, key, ended.key))
  );
  if (afterReasoningEnded.length === 0) {
    return {
      done: false,
      reason: "no terminal recipient=all text after trusted reasoning_ended",
    };
  }

  const activeReasoning = turnMessages.filter(({ message }) =>
    (message.content?.content_type === "thoughts" ||
      message.content?.content_type === "code") &&
    message.metadata?.reasoning_status === "is_reasoning"
  );

  const structurallySafe = afterReasoningEnded.filter((candidate) =>
    activeReasoning.every((active) => {
      if (isDescendantOf(mapping, candidate.key, active.key)) return true;
      // Active reasoning after the candidate is a definite early-preamble
      // signature. An incomparable same-turn branch is also not proof of
      // completion, so reject it conservatively.
      return false;
    })
  );
  if (structurallySafe.length === 0) {
    return {
      done: false,
      reason: "active or graph-incomparable reasoning remains for final text candidate",
    };
  }

  // Prefer the leaf-most safe terminal text by ancestry, never by create_time.
  // Multiple incomparable leaves mean the branch is ambiguous, so fail closed.
  const leafCandidates = structurallySafe.filter((candidate) =>
    !structurallySafe.some((other) =>
      other.key !== candidate.key && isDescendantOf(mapping, other.key, candidate.key)
    )
  );
  if (leafCandidates.length !== 1) {
    return {
      done: false,
      reason: `ambiguous terminal text branches (${leafCandidates.length})`,
    };
  }

  const finalCandidate = leafCandidates[0];
  if (!finalCandidate) {
    return { done: false, reason: "terminal text candidate disappeared" };
  }
  const parts = finalCandidate.message.content?.parts;
  const finalText = Array.isArray(parts) && typeof parts[0] === "string" ? parts[0] : "";
  const finalMessageId = finalCandidate.message.id;
  if (!finalMessageId || !finalText) {
    return { done: false, reason: "terminal text is missing id or content" };
  }

  return {
    done: true,
    finalText,
    finalMessageId,
    modelSlug: finalCandidate.message.metadata?.model_slug,
    finishReason: finalCandidate.message.metadata?.finish_details?.type,
  };
}

function isDescendantOf(
  mapping,
  descendantKey,
  ancestorKey,
) {
  if (descendantKey === ancestorKey) return false;
  const seen = new Set();
  let currentKey = descendantKey;
  while (currentKey && !seen.has(currentKey)) {
    seen.add(currentKey);
    const parent = mapping[currentKey]?.parent;
    if (!parent) return false;
    if (parent === ancestorKey) return true;
    currentKey = parent;
  }
  return false;
}
