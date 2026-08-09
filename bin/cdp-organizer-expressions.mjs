// Browser-side UI actions used by cdp-salvage.mjs's marker-scoped organizer.
//
// These expressions intentionally interact with ChatGPT's rendered controls. Do not replace
// them with fetch/XHR calls: the organizer must inherit the signed-in UI's permissions and
// remain unable to mutate a conversation that its marker scan did not first prove we own.

const MARKER_SAFE_RE = /^pg-run-[A-Za-z0-9.-]+$/;
const CONVERSATION_URL_RE = /^https:\/\/chatgpt\.com\/c\//;

function targetContext(marker, conversationUrl) {
  if (!MARKER_SAFE_RE.test(marker ?? '')) throw new TypeError('a safe run marker is required');
  if (!CONVERSATION_URL_RE.test(conversationUrl ?? '')) {
    throw new TypeError('an exact ChatGPT conversation URL is required');
  }
  const conversationPath = new URL(conversationUrl).pathname;
  return String.raw`
    const expectedMarker = ${JSON.stringify(marker)};
    const expectedUrl = ${JSON.stringify(conversationUrl)};
    const expectedConversationPath = ${JSON.stringify(conversationPath)};
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
    const validateTarget = () => {
      if (typeof location !== 'object' || location.href !== expectedUrl) return 'target-url-drift';
      const text = String(document.body?.innerText ?? '');
      const ownMarkerAt = lastExactMarkerAt(text, expectedMarker);
      if (ownMarkerAt < 0) return 'target-marker-missing';
      const lines = text.split('\n');
      let verdictLine = '';
      for (let i = lines.length - 1; i >= 0; i -= 1) {
        if (/^\s*[*_>#-]*\s*VERDICT[*_\s]*:/i.test(lines[i])) {
          verdictLine = lines[i];
          break;
        }
      }
      const verdictAt = verdictLine ? text.lastIndexOf(verdictLine) : -1;
      if (verdictAt > ownMarkerAt) {
        const answerMarker = verdictLine.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
        if (!answerMarker) return 'target-answer-marker-missing';
        if (answerMarker !== expectedMarker) return 'target-cross-bound';
      }
      return null;
    };
  `;
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
    const press = (element) => {
      const rect = element.getBoundingClientRect();
      const eventInit = {
        bubbles: true,
        cancelable: true,
        view: window,
        clientX: rect.left + rect.width / 2,
        clientY: rect.top + rect.height / 2,
        button: 0,
      };
      if (typeof PointerEvent === 'function') {
        element.dispatchEvent(new PointerEvent('pointerdown', {
          ...eventInit,
          buttons: 1,
          pointerId: 1,
          pointerType: 'mouse',
          isPrimary: true,
        }));
      }
      element.dispatchEvent(new MouseEvent('mousedown', { ...eventInit, buttons: 1 }));
      if (typeof PointerEvent === 'function') {
        element.dispatchEvent(new PointerEvent('pointerup', {
          ...eventInit,
          buttons: 0,
          pointerId: 1,
          pointerType: 'mouse',
          isPrimary: true,
        }));
      }
      element.dispatchEvent(new MouseEvent('mouseup', { ...eventInit, buttons: 0 }));
      element.dispatchEvent(new MouseEvent('click', { ...eventInit, buttons: 0 }));
    };
    const guardedPress = (element) => {
      const reason = validateTarget();
      if (reason) return reason;
      press(element);
      return null;
    };
    const dismiss = () => document.dispatchEvent(new KeyboardEvent('keydown', {
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

export function buildRenameConversationExpression(title, { marker, conversationUrl } = {}) {
  return `/* pro-gate-organizer:rename */
(() => {
  const expected = ${JSON.stringify(title)};
  ${targetContext(marker, conversationUrl)}
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
    input.focus();
    input.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true,
    }));
    input.dispatchEvent(new KeyboardEvent('keyup', {
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
    if (editor.already) return { status: 'already' };
    if (!editor.input) return { status: 'skipped', reason: editor.error };
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
    editor.input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: expected }));
    editor.input.dispatchEvent(new Event('change', { bubbles: true }));
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
      commitInlineRename(editor.input);
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
  }));
})()`;
}

export function buildArchiveConversationExpression({ marker, conversationUrl } = {}) {
  return `/* pro-gate-organizer:archive */
(() => {
  ${targetContext(marker, conversationUrl)}
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
  }));
})()`;
}
