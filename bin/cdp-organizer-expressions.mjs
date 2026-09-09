// Browser-side UI actions used by cdp-salvage.mjs's marker-scoped organizer.
//
// These expressions intentionally interact with ChatGPT's rendered controls. Do not replace
// them with fetch/XHR calls: the organizer must inherit the signed-in UI's permissions and
// remain unable to mutate a conversation that its marker scan did not first prove we own.

const MARKER_SAFE_RE = /^pg-run-[A-Za-z0-9.-]+$/;
const CONVERSATION_URL_RE = /^https:\/\/chatgpt\.com\/c\//;
const MUTATION_TOKEN_RE = /^[A-Za-z0-9.-]+$/;
const LEASE_REGISTRY = '__proGateOrganizerLeases';
const REVOCATION_REGISTRY = '__proGateOrganizerRevocations';

export const ORGANIZER_MUTATION_LEASE_MS = 10_000;

// Shared by capture and the independent mutation guard. Preserve rendered reference context
// before classifying claims; priority-section numbering never establishes ownership.
export function readReviewText(document, marker) {
  const exact = (value) => [...value.matchAll(/pg-run-[A-Za-z0-9.-]+/g)].some((match) =>
    match[0] === marker && !/[A-Za-z0-9.-]/.test(value[match.index - 1] ?? ''));
  const read = (node, before = '', after = '') => {
    const text = node?.innerText ?? node?.textContent ?? '';
    // Inline fragments belong to the surrounding verdict/signature. Only a complete code
    // example on its own rendered line gets reference context, with or without a signature.
    const completeVerdictExample = node?.matches?.('code') && !before.trim() && !after.trim() &&
      text.split('\n').some((line) =>
        /^[*_# \t-]*VERDICT[*_ \t]*:[*_ \t]*(ship|fix-first|needs-discussion)([^a-z0-9_-]|$)/i.test(line));
    if (node?.matches?.('blockquote, pre') || completeVerdictExample) {
      return text.split('\n').map((line) => '> ' + line).join('\n');
    }
    let cursor = 0;
    let result = '';
    for (const child of node?.children ?? []) {
      const original = child.innerText ?? child.textContent ?? '';
      if (!original) continue;
      const at = text.indexOf(original, cursor);
      if (at < 0) continue;
      const lineBefore = (before + text.slice(0, at)).split('\n').at(-1);
      const lineAfter = (text.slice(at + original.length) + after).split('\n')[0];
      result += text.slice(cursor, at) + read(child, lineBefore, lineAfter);
      cursor = at + original.length;
    }
    return result + text.slice(cursor);
  };
  const turns = [...document.querySelectorAll('[data-message-author-role]')];
  let prompt = -1;
  for (let i = 0; i < turns.length; i++) {
    if (turns[i].getAttribute('data-message-author-role') === 'user' && exact(turns[i].innerText ?? '')) prompt = i;
  }
  if (prompt >= 0) return {
    text: 'run marker: ' + marker + '\n' + turns.slice(prompt + 1).map((turn) => read(turn)).join('\n\n'),
    promptAt: 0,
  };
  return { text: read(document.body), promptAt: null };
}

export function reviewVerdictClaims(text, marker) {
  const claims = [];
  const lines = text.split('\n');
  // A fence that is never closed is not a code block, it is a missing ```. Suppressing to
  // EOF hid this run's own terminal VERDICT and made a complete review read as "still
  // generating" (gate #166 r3 P1). Find the opener still open at EOF and demote just that
  // line to ordinary text. Kept in lockstep with pg_capture_verdict_claims in the library.
  let dangling = -1;
  {
    let scan = null;
    for (let i = 0; i < lines.length; i += 1) {
      const d = lines[i].match(/^[ ]{0,3}(`{3,}|~{3,})(.*)$/);
      if (!d) continue;
      if (/^(?: {4}|\t| {0,3}>)/.test(lines[i])) continue;
      if (!scan) { scan = d[1]; dangling = i; }
      else if (d[1][0] === scan[0] && d[1].length >= scan.length && !d[2].trim()) { scan = null; dangling = -1; }
    }
  }
  let fence = null;
  let at = 0;
  let promptAt = -1;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const start = at;
    at += line.length + 1;
    const delimiter = index === dangling ? null : line.match(/^[ ]{0,3}(`{3,}|~{3,})(.*)$/);
    if (fence) {
      if (delimiter && delimiter[1][0] === fence[0] && delimiter[1].length >= fence.length && !delimiter[2].trim()) fence = null;
      continue;
    }
    if (delimiter) { fence = delimiter[1]; continue; }
    if (/^(?: {4}|\t| {0,3}>)/.test(line)) continue;
    if (promptAt < 0 && (
      line === 'run marker: ' + marker ||
      line.startsWith('(run marker: ' + marker + ' — internal correlation id')
    )) promptAt = start;
    if (!/^[*_# \t-]*VERDICT[*_ \t]*:[*_ \t]*(ship|fix-first|needs-discussion)([^a-z0-9_-]|$)/i.test(line)) continue;
    const markers = [...line.matchAll(/\(run marker:[ \t]*(pg-run-[A-Za-z0-9.-]+)[ \t]*\)/gi)].map((match) => match[1]);
    claims.push({ line, at: start, markers });
  }
  return { claims, promptAt };
}

export function reviewTextContext(text, marker, promptAt = null) {
  const scanned = reviewVerdictClaims(text, marker);
  const all = scanned.claims;
  // DOM user-turn scope is authoritative. Legacy text sources retain the known prompt-line
  // shapes only; a prose marker mention cannot erase an earlier verdict.
  if (promptAt === null) promptAt = scanned.promptAt;
  const claims = all.filter((claim) => claim.at > promptAt);
  const markers = new Set(claims.flatMap((claim) => claim.markers.map((value) => value.toLowerCase())));
  const mixed = markers.has(marker.toLowerCase()) && [...markers].some((value) => value !== marker.toLowerCase());
  const verdict = claims.at(-1) ?? all.at(-1) ?? null;
  let review = null;
  if (verdict) {
    if (mixed) {
      const from = promptAt < 0 ? 0 : text.indexOf('\n', promptAt) + 1;
      review = text.slice(from, verdict.at + verdict.line.length).trim();
    } else {
      const lines = text.split('\n');
      let at = 0;
      let start = -1;
      let end = -1;
      for (let i = 0; i < lines.length; i++) {
        if (at === verdict.at) end = i;
        if (at <= verdict.at && (verdict.at < promptAt || at > promptAt) && start < 0 &&
            /^\s*[*_>#-]*\s*(P0\s*[:\-]|P0\b|\[P[0-3]\])/i.test(lines[i].trim())) start = i;
        at += lines[i].length + 1;
      }
      if (start < 0) start = Math.max(0, end - 120);
      review = lines.slice(start, end + 1).join('\n').trim();
    }
  }
  return { claims, verdict, mixed, review, promptAt };
}

function targetContext(marker, conversationUrl, {
  mutationToken,
  mutationExpiresAt,
  expectedReview = null,
} = {}) {
  if (!MARKER_SAFE_RE.test(marker ?? '')) throw new TypeError('a safe run marker is required');
  if (!CONVERSATION_URL_RE.test(conversationUrl ?? '')) {
    throw new TypeError('an exact ChatGPT conversation URL is required');
  }
  if (!MUTATION_TOKEN_RE.test(mutationToken ?? '')) {
    throw new TypeError('a safe mutation token is required');
  }
  if (!Number.isSafeInteger(mutationExpiresAt) || mutationExpiresAt <= 0) {
    throw new TypeError('a mutation expiry is required');
  }
  if (expectedReview !== null && typeof expectedReview !== 'string') {
    throw new TypeError('expected review bytes must be a string');
  }
  const conversationPath = new URL(conversationUrl).pathname;
  return String.raw`
    const expectedMarker = ${JSON.stringify(marker)};
    const expectedUrl = ${JSON.stringify(conversationUrl)};
    const expectedConversationPath = ${JSON.stringify(conversationPath)};
    const expectedFinalReview = ${JSON.stringify(expectedReview)};
    const mutationToken = ${JSON.stringify(mutationToken)};
    const mutationExpiresAt = ${mutationExpiresAt};
    const leaseRegistryName = ${JSON.stringify(LEASE_REGISTRY)};
    const revocationRegistryName = ${JSON.stringify(REVOCATION_REGISTRY)};
    const leaseRegistry = globalThis[leaseRegistryName] ??= Object.create(null);
    const revocationRegistry = globalThis[revocationRegistryName] ??= Object.create(null);
    const priorMutationLease = leaseRegistry[expectedMarker];
    const revokedUntil = Number(revocationRegistry[mutationToken] ?? 0);
    const mutationRevokedBeforeStart = Date.now() < revokedUntil;
    if (revokedUntil > 0 && !mutationRevokedBeforeStart) {
      delete revocationRegistry[mutationToken];
    }
    const mutationMayArm = Date.now() < mutationExpiresAt &&
      !mutationRevokedBeforeStart &&
      !(priorMutationLease?.token !== mutationToken &&
        priorMutationLease?.revoked !== true && Date.now() < priorMutationLease?.expiresAt);
    if (mutationMayArm) {
      leaseRegistry[expectedMarker] = {
        token: mutationToken,
        expiresAt: mutationExpiresAt,
        revoked: false,
      };
    }
    const mutationLeaseActive = () => {
      const lease = globalThis[leaseRegistryName]?.[expectedMarker];
      return lease?.token === mutationToken && lease.revoked !== true &&
        Date.now() < lease.expiresAt;
    };
    const releaseMutationLease = () => {
      if (globalThis[leaseRegistryName]?.[expectedMarker]?.token === mutationToken) {
        delete globalThis[leaseRegistryName][expectedMarker];
      }
      delete globalThis[revocationRegistryName]?.[mutationToken];
    };
    const isRunMarkerChar = (char) => /[A-Za-z0-9.-]/.test(char ?? '');
    const lastExactMarkerAt = (text, wanted) => {
      let found = -1;
      let from = 0;
      while (from <= text.length - wanted.length) {
        const at = text.indexOf(wanted, from);
        if (at < 0) break;
        const before = at > 0 ? text[at - 1] : '';
        const after = text[at + wanted.length] ?? '';
        if (!isRunMarkerChar(before) && !isRunMarkerChar(after)) found = at;
        from = at + 1;
      }
      return found;
    };
    const lastExactRunMarkerAt = (text) => {
      let found = -1;
      for (const match of text.matchAll(/pg-run-[A-Za-z0-9.-]+/g)) {
        const at = match.index;
        const before = at > 0 ? text[at - 1] : '';
        const after = text[at + match[0].length] ?? '';
        if (!isRunMarkerChar(before) && !isRunMarkerChar(after)) found = at;
      }
      return found;
    };
    const normalizeReviewBytes = (value) => String(value ?? '')
      .replace(/\r\n?/g, '\n').replace(/\n$/, '');
    const stripMarkerEcho = (value) => String(value ?? '').split('\n').map((line) => {
      const token = '(run marker: ' + expectedMarker + ')';
      const at = line.indexOf(token);
      if (at < 0) return line;
      return (line.slice(0, at) + line.slice(at + token.length)).replace(/[ \t]+$/, '');
    }).join('\n');
    const readReviewText = ${readReviewText.toString()};
    const reviewVerdictClaims = ${reviewVerdictClaims.toString()};
    const reviewTextContext = ${reviewTextContext.toString()};
    const validateTarget = () => {
      if (!mutationLeaseActive()) return 'mutation-lease-expired';
      if (typeof location !== 'object' || location.href !== expectedUrl) return 'target-url-drift';
      const captured = readReviewText(document, expectedMarker);
      const text = captured.text;
      const context = reviewTextContext(text, expectedMarker, captured.promptAt);
      if (context.mixed) return 'target-mixed-review';
      if (lastExactMarkerAt(text, expectedMarker) < 0) return 'target-marker-missing';
      const verdictLine = context.verdict?.line ?? '';
      const verdictAt = context.verdict?.at ?? -1;
      const ownMarkerAt = lastExactMarkerAt(text, expectedMarker);
      const promptMarkerAt = verdictAt >= 0
        ? lastExactMarkerAt(text.slice(0, verdictAt), expectedMarker)
        : -1;
      if (expectedFinalReview === null && verdictAt > ownMarkerAt) {
        const answerMarker = verdictLine.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
        if (!answerMarker) return 'target-answer-marker-missing';
        if (answerMarker !== expectedMarker) return 'target-cross-bound';
      }
      if (expectedFinalReview !== null) {
        if (verdictAt < 0 || promptMarkerAt < 0) return 'target-answer-incomplete';
        if (lastExactRunMarkerAt(text.slice(verdictAt + verdictLine.length)) >= 0) {
          return 'target-newer-run-marker';
        }
        const answerMarker = verdictLine.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
        if (!answerMarker) return 'target-answer-marker-missing';
        if (answerMarker !== expectedMarker) return 'target-cross-bound';
        const renderedReview = context.review;
        if (!renderedReview || normalizeReviewBytes(stripMarkerEcho(renderedReview)) !== expectedFinalReview) {
          return 'target-result-mismatch';
        }
      }
      return null;
    };
  `;
}

export function buildCancelOrganizerMutationExpression(marker, mutationToken, mutationExpiresAt) {
  if (!MARKER_SAFE_RE.test(marker ?? '')) throw new TypeError('a safe run marker is required');
  if (!MUTATION_TOKEN_RE.test(mutationToken ?? '')) {
    throw new TypeError('a safe mutation token is required');
  }
  if (!Number.isSafeInteger(mutationExpiresAt) || mutationExpiresAt <= 0) {
    throw new TypeError('a mutation expiry is required');
  }
  return `/* pro-gate-organizer:cancel */\n(() => {\n  const mutationToken = ${JSON.stringify(mutationToken)};\n  const mutationExpiresAt = ${mutationExpiresAt};\n  const registry = globalThis[${JSON.stringify(LEASE_REGISTRY)}] ??= Object.create(null);\n  const revocations = globalThis[${JSON.stringify(REVOCATION_REGISTRY)}] ??= Object.create(null);\n  revocations[mutationToken] = mutationExpiresAt;\n  const current = registry[${JSON.stringify(marker)}];\n  if (current?.token === mutationToken) current.revoked = true;\n  return current?.token !== mutationToken || current.revoked === true;\n})()`;
}

const interactionHelpers = String.raw`
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const normalize = (value) => String(value ?? '').replace(/\s+/g, ' ').trim().toLowerCase();
    const isVisible = (element) => {
      if (!element || !(element instanceof HTMLElement)) return false;
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
    };
    const labelFor = (element) => normalize([
      element?.getAttribute?.('aria-label'),
      element?.getAttribute?.('title'),
      element?.textContent,
    ].filter(Boolean).join(' '));
    const guardedDispatch = (element, event) => {
      const reason = validateTarget();
      if (reason) return reason;
      element.dispatchEvent(event);
      return null;
    };
    const guardedPress = (element) => {
      const rect = element.getBoundingClientRect();
      const eventInit = {
        bubbles: true,
        cancelable: true,
        view: window,
        clientX: rect.left + rect.width / 2,
        clientY: rect.top + rect.height / 2,
        button: 0,
      };
      const events = [];
      if (typeof PointerEvent === 'function') {
        events.push(new PointerEvent('pointerdown', {
          ...eventInit,
          buttons: 1,
          pointerId: 1,
          pointerType: 'mouse',
          isPrimary: true,
        }));
      }
      events.push(new MouseEvent('mousedown', { ...eventInit, buttons: 1 }));
      if (typeof PointerEvent === 'function') {
        events.push(new PointerEvent('pointerup', {
          ...eventInit,
          buttons: 0,
          pointerId: 1,
          pointerType: 'mouse',
          isPrimary: true,
        }));
      }
      events.push(new MouseEvent('mouseup', { ...eventInit, buttons: 0 }));
      events.push(new MouseEvent('click', { ...eventInit, buttons: 0 }));
      for (const event of events) {
        const reason = guardedDispatch(element, event);
        if (reason) return reason;
      }
      return null;
    };
    const dismiss = () => guardedDispatch(document, new KeyboardEvent('keydown', {
      key: 'Escape',
      code: 'Escape',
      bubbles: true,
    }));
    const findSidebarConversationLink = () => Array.from(document.querySelectorAll('a[href]'))
      .find((element) => {
        const href = element.getAttribute('href') ?? '';
        if (!href.startsWith('/c/') && !href.startsWith('https://chatgpt.com/c/')) return false;
        try {
          return new URL(href, location.href).pathname === expectedConversationPath;
        } catch {
          return false;
        }
      }) ?? null;
    const findSidebarMenuButton = () => {
      const link = findSidebarConversationLink();
      const row = link?.closest('li') ?? link?.parentElement;
      if (!row) return null;
      return Array.from(row.querySelectorAll('button,[role="button"]'))
        .find((element) => {
          if (!(element instanceof HTMLElement) || !isVisible(element)) return false;
          const label = labelFor(element);
          return label.includes('open conversation options') ||
            /^history-item-.*-options$/.test(element.getAttribute('data-testid') ?? '');
        }) ?? null;
    };
    const findOpenSidebarButton = () => Array.from(document.querySelectorAll('button,[role="button"]'))
      .find((element) => element instanceof HTMLElement && isVisible(element) &&
        labelFor(element).includes('open sidebar')) ?? null;
    const ensureSidebarMenuButton = async () => {
      let menuButton = findSidebarMenuButton();
      if (menuButton) return menuButton;
      const openSidebar = findOpenSidebarButton();
      if (!openSidebar || guardedPress(openSidebar)) return null;
      await sleep(350);
      menuButton = findSidebarMenuButton();
      return menuButton;
    };
    const findHeaderMenuButton = () => {
      const buttons = Array.from(document.querySelectorAll('button,[role="button"]'))
        .filter((element) => element instanceof HTMLElement && isVisible(element));
      const headerCandidates = buttons
        .map((element) => ({ element, label: labelFor(element), rect: element.getBoundingClientRect() }))
        .filter(({ label, rect }) =>
          rect.top < 180 &&
          rect.right > window.innerWidth - 420 &&
          (label.includes('more') ||
            label.includes('conversation options') ||
            label.includes('open menu') ||
            label.includes('więcej') ||
            label.includes('opcje')))
        .sort((a, b) => b.rect.right - a.rect.right);
      return headerCandidates[0]?.element ?? null;
    };
    const findConversationMenuButton = ({ allowHeader = true } = {}) =>
      findSidebarMenuButton() ?? (allowHeader ? findHeaderMenuButton() : null);
    const visibleMenuRoots = () => Array.from(document.querySelectorAll(
      '[role="menu"],[data-radix-menu-content],[data-testid*="menu" i]',
    )).filter((element) =>
      element instanceof HTMLElement && isVisible(element));
    const visibleMenuCandidates = () => visibleMenuRoots().flatMap((root) => Array.from(
      root.querySelectorAll('[role="menuitem"],[role="option"],button,div[tabindex],a'),
    )).filter((element) => element instanceof HTMLElement && isVisible(element));
    const visibleDialogs = () => Array.from(document.querySelectorAll('[role="dialog"]'))
      .filter((element) => element instanceof HTMLElement && isVisible(element));
`;

export function buildRenameConversationExpression(title, {
  marker,
  conversationUrl,
  mutationToken,
  mutationExpiresAt,
  expectedReview = null,
} = {}) {
  return `/* pro-gate-organizer:rename */
(() => {
  const expected = ${JSON.stringify(title)};
  ${targetContext(marker, conversationUrl, {
    mutationToken,
    mutationExpiresAt,
    expectedReview,
  })}
  ${interactionHelpers}
  const findRenameMenuItem = () => visibleMenuCandidates().find((element) => {
    const label = labelFor(element);
    if (!label || label.includes('delete')) return false;
    return label === 'rename' || label.includes('rename conversation') || label === 'zmień nazwę';
  }) ?? null;
  const findRenameInput = () => Array.from(document.querySelectorAll(
    'input[name="title-editor"],input[aria-label="Chat title"],input[aria-label="Tytuł czatu"]',
  )).find((element) => element instanceof HTMLInputElement && isVisible(element)) ??
    visibleDialogs().flatMap((dialog) => Array.from(dialog.querySelectorAll('input')))
      .find((element) => element instanceof HTMLInputElement && isVisible(element)) ?? null;
  const findSaveButton = () => visibleDialogs().flatMap((dialog) => Array.from(
    dialog.querySelectorAll('button,[role="button"]'),
  )).filter((element) => element instanceof HTMLElement && isVisible(element)).find((element) => {
    const label = labelFor(element);
    return label === 'save' || label === 'rename' || label === 'zapisz';
  }) ?? null;
  const commitInlineRename = (input) => {
    const focusError = validateTarget();
    if (focusError) return focusError;
    input.focus();
    const downError = guardedDispatch(input, new KeyboardEvent('keydown', {
      key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true,
    }));
    if (downError) return downError;
    return guardedDispatch(input, new KeyboardEvent('keyup', {
      key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true,
    }));
  };
  const openEditor = async () => {
    const targetError = validateTarget();
    if (targetError) return { error: targetError };
    const menuButton = await ensureSidebarMenuButton();
    if (!menuButton) return { error: 'conversation-menu-not-found' };
    const sidebarTitle = String(findSidebarConversationLink()?.textContent ?? '')
      .replace(/\s+/g, ' ').trim();
    if (sidebarTitle === expected) return { already: true };
    const menuError = guardedPress(menuButton);
    if (menuError) return { error: menuError };
    await sleep(350);
    const renameItem = findRenameMenuItem();
    if (!renameItem) {
      dismiss();
      return { error: 'rename-menu-item-not-found' };
    }
    const renameError = guardedPress(renameItem);
    if (renameError) {
      dismiss();
      return { error: renameError };
    }
    await sleep(350);
    const input = findRenameInput();
    if (!input) {
      dismiss();
      return { error: 'rename-input-not-found' };
    }
    return { input };
  };
  return (async () => {
    const editor = await openEditor();
    if (editor.already) {
      releaseMutationLease();
      return { status: 'already' };
    }
    if (!editor.input) {
      releaseMutationLease();
      return { status: 'skipped', reason: editor.error };
    }
    if (editor.input.value === expected) {
      dismiss();
      return { status: 'already' };
    }
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    if (!setter) {
      dismiss();
      return { status: 'skipped', reason: 'native-input-setter-not-found' };
    }
    const editError = validateTarget();
    if (editError) {
      dismiss();
      return { status: 'skipped', reason: editError };
    }
    setter.call(editor.input, expected);
    const inputError = guardedDispatch(editor.input, new InputEvent('input', {
      bubbles: true, inputType: 'insertText', data: expected,
    }));
    if (inputError) {
      dismiss();
      return { status: 'skipped', reason: inputError };
    }
    const changeError = guardedDispatch(editor.input, new Event('change', { bubbles: true }));
    if (changeError) {
      dismiss();
      return { status: 'skipped', reason: changeError };
    }
    const save = findSaveButton();
    if (save) {
      const saveError = guardedPress(save);
      if (saveError) {
        dismiss();
        return { status: 'skipped', reason: saveError };
      }
    } else if (editor.input.name === 'title-editor' ||
               normalize(editor.input.getAttribute('aria-label')).includes('chat title') ||
               normalize(editor.input.getAttribute('aria-label')).includes('tytuł czatu')) {
      const commitError = validateTarget();
      if (commitError) {
        dismiss();
        return { status: 'skipped', reason: commitError };
      }
      const commitDispatchError = commitInlineRename(editor.input);
      if (commitDispatchError) {
        dismiss();
        return { status: 'skipped', reason: commitDispatchError };
      }
    } else {
      dismiss();
      return { status: 'skipped', reason: 'rename-save-not-found' };
    }
    await sleep(500);
    const verification = await openEditor();
    if (verification.already) return { status: 'renamed' };
    if (!verification.input) return { status: 'skipped', reason: 'rename-not-verifiable' };
    const exact = verification.input.value === expected;
    dismiss();
    return exact
      ? { status: 'renamed' }
      : { status: 'skipped', reason: 'rename-not-confirmed' };
  })().catch((error) => ({
    status: 'failed',
    error: error instanceof Error ? error.message : String(error),
  })).finally(releaseMutationLease);
})()`;
}

export function buildArchiveConversationExpression({
  marker,
  conversationUrl,
  mutationToken,
  mutationExpiresAt,
  expectedReview = null,
} = {}) {
  return `/* pro-gate-organizer:archive */
(() => {
  ${targetContext(marker, conversationUrl, {
    mutationToken,
    mutationExpiresAt,
    expectedReview,
  })}
  ${interactionHelpers}
  const hasUnarchiveMenuItem = () => visibleMenuCandidates().some((element) => {
    const label = labelFor(element);
    return label.includes('unarchive') || label.includes('restore') ||
      label.includes('przywróć') || label.includes('przywroc');
  });
  const findArchiveMenuItem = () => visibleMenuCandidates().find((element) => {
    const label = labelFor(element);
    if (!label || label.includes('delete') || label.includes('unarchive') || label.includes('restore')) return false;
    return label === 'archive' || label.includes('archive conversation') || label === 'archiwizuj';
  }) ?? null;
  const findArchiveConfirmationButton = () => visibleDialogs().flatMap((dialog) => Array.from(
    dialog.querySelectorAll('button,[role="button"]'),
  )).filter((element) => element instanceof HTMLElement && isVisible(element)).find((element) => {
    const label = labelFor(element);
    if (!label || label.includes('delete') || label.includes('unarchive') || label.includes('restore')) return false;
    return label === 'archive' || label === 'archiwizuj' || label.includes('archive conversation');
  }) ?? null;
  const hasArchiveToast = () => Array.from(document.querySelectorAll(
    '[role="status"],[role="alert"],[data-testid*="toast"],[class*="toast"],[class*="snackbar"]',
  )).filter((element) => element instanceof HTMLElement && isVisible(element))
    .map((element) => labelFor(element)).some((label) =>
      label.includes('archived') || label.includes('conversation archived') ||
      label.includes('chat archived') || label.includes('zarchiwizowano') || label.includes('archiwum'));
  const verifyArchivedStateFromMenu = async () => {
    if (validateTarget()) return false;
    const menuButton = findConversationMenuButton();
    if (!menuButton || guardedPress(menuButton)) return false;
    await sleep(300);
    const archived = hasUnarchiveMenuItem();
    dismiss();
    return archived;
  };
  return (async () => {
    const targetError = validateTarget();
    if (targetError) return { status: 'skipped', reason: targetError };
    const menuButton = findConversationMenuButton();
    if (!menuButton) return { status: 'skipped', reason: 'conversation-menu-not-found' };
    const menuError = guardedPress(menuButton);
    if (menuError) return { status: 'skipped', reason: menuError };
    await sleep(350);
    if (hasUnarchiveMenuItem()) {
      dismiss();
      return { status: 'already' };
    }
    const archiveItem = findArchiveMenuItem();
    if (!archiveItem) {
      dismiss();
      return { status: 'skipped', reason: 'archive-menu-item-not-found' };
    }
    const archiveError = guardedPress(archiveItem);
    if (archiveError) {
      dismiss();
      return { status: 'skipped', reason: archiveError };
    }
    await sleep(350);
    const confirm = findArchiveConfirmationButton();
    if (confirm) {
      const confirmError = guardedPress(confirm);
      if (confirmError) {
        dismiss();
        return { status: 'skipped', reason: confirmError };
      }
      await sleep(500);
    }
    const verifyDeadline = Date.now() + 3000;
    while (Date.now() < verifyDeadline) {
      if (location.href !== expectedUrl || hasArchiveToast()) return { status: 'archived' };
      await sleep(150);
    }
    return await verifyArchivedStateFromMenu()
      ? { status: 'archived' }
      : { status: 'skipped', reason: 'archive-not-confirmed' };
  })().catch((error) => ({
    status: 'failed',
    error: error instanceof Error ? error.message : String(error),
  })).finally(releaseMutationLease);
})()`;
}
