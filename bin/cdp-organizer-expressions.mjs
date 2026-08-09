// Browser-side UI actions used by cdp-salvage.mjs's marker-scoped organizer.
//
// These expressions intentionally interact with ChatGPT's rendered controls. Do not replace
// them with fetch/XHR calls: the organizer must inherit the signed-in UI's permissions and
// remain unable to mutate a conversation that its marker scan did not first prove we own.

const MARKER_SAFE_RE = /^pg-run-[A-Za-z0-9.-]+$/;
const CONVERSATION_URL_RE = /^https:\/\/chatgpt\.com\/c\//;
const MUTATION_TOKEN_RE = /^[A-Za-z0-9.-]+$/;
const LEASE_REGISTRY = '__proGateOrganizerLeases';

export const ORGANIZER_MUTATION_LEASE_MS = 10_000;

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
    const leaseRegistry = globalThis[leaseRegistryName] ??= Object.create(null);
    leaseRegistry[expectedMarker] = {
      token: mutationToken,
      expiresAt: mutationExpiresAt,
    };
    const mutationLeaseActive = () => {
      const lease = globalThis[leaseRegistryName]?.[expectedMarker];
      return lease?.token === mutationToken && Date.now() < lease.expiresAt;
    };
    const releaseMutationLease = () => {
      if (globalThis[leaseRegistryName]?.[expectedMarker]?.token === mutationToken) {
        delete globalThis[leaseRegistryName][expectedMarker];
      }
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
    const normalizeReviewBytes = (value) => String(value ?? '')
      .replace(/\r\n?/g, '\n').replace(/\n$/, '');
    const stripMarkerEcho = (value) => String(value ?? '').split('\n').map((line) => {
      const token = '(run marker: ' + expectedMarker + ')';
      const at = line.indexOf(token);
      if (at < 0) return line;
      return (line.slice(0, at) + line.slice(at + token.length)).replace(/[ \t]+$/, '');
    }).join('\n');
    const extractFinalReview = (text) => {
      const lines = text.split('\n');
      let verdictIdx = -1;
      for (let i = lines.length - 1; i >= 0; i -= 1) {
        if (/^\s*[*_>#-]*\s*VERDICT[*_\s]*:/i.test(lines[i])) {
          verdictIdx = i;
          break;
        }
      }
      if (verdictIdx < 0) return null;
      let start = -1;
      for (let i = verdictIdx; i >= 0; i -= 1) {
        if (/^\s*[*_>#-]*\s*(P0\s*[:\-]|P0\b|\[P[0-3]\])/i.test(lines[i].trim())) start = i;
      }
      if (start < 0) start = Math.max(0, verdictIdx - 120);
      return lines.slice(start, verdictIdx + 1).join('\n').trim();
    };
    const validateTarget = () => {
      if (!mutationLeaseActive()) return 'mutation-lease-expired';
      if (typeof location !== 'object' || location.href !== expectedUrl) return 'target-url-drift';
      const text = String(document.body?.innerText ?? '');
      if (lastExactMarkerAt(text, expectedMarker) < 0) return 'target-marker-missing';
      const lines = text.split('\n');
      let verdictLine = '';
      for (let i = lines.length - 1; i >= 0; i -= 1) {
        if (/^\s*[*_>#-]*\s*VERDICT[*_\s]*:/i.test(lines[i])) {
          verdictLine = lines[i];
          break;
        }
      }
      const verdictAt = verdictLine ? text.lastIndexOf(verdictLine) : -1;
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
        if (lastExactMarkerAt(text.slice(verdictAt + verdictLine.length), expectedMarker) >= 0) {
          return 'target-answer-incomplete';
        }
        const answerMarker = verdictLine.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
        if (!answerMarker) return 'target-answer-marker-missing';
        if (answerMarker !== expectedMarker) return 'target-cross-bound';
        const renderedReview = extractFinalReview(text);
        if (!renderedReview || normalizeReviewBytes(stripMarkerEcho(renderedReview)) !== expectedFinalReview) {
          return 'target-result-mismatch';
        }
      }
      return null;
    };
  `;
}

export function buildCancelOrganizerMutationExpression(marker, mutationToken) {
  if (!MARKER_SAFE_RE.test(marker ?? '')) throw new TypeError('a safe run marker is required');
  if (!MUTATION_TOKEN_RE.test(mutationToken ?? '')) {
    throw new TypeError('a safe mutation token is required');
  }
  return `/* pro-gate-organizer:cancel */\n(() => {\n  const registry = globalThis[${JSON.stringify(LEASE_REGISTRY)}];\n  if (registry?.[${JSON.stringify(marker)}]?.token === ${JSON.stringify(mutationToken)}) {\n    delete registry[${JSON.stringify(marker)}];\n  }\n  return registry?.[${JSON.stringify(marker)}]?.token !== ${JSON.stringify(mutationToken)};\n})()`;
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
