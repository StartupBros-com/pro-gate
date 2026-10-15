#!/usr/bin/env node
// Standalone mock CDP browser for engine-level tests: serves /json/version (preflight),
// /json (one chatgpt.com/c/ tab whose innerText is the contents of the file in argv[1]),
// the tab's debugger WebSocket, /json/new (scratch tabs, so the salvage's remembered-URL
// recovery can reach a decisive answer the way a real browser does), and /json/close.
// Prints the chosen port on stdout.
// Usage: node tests/mock-cdp.mjs <source-text-file> [organizer-state-file] [scratch-text-file] [scratch-canonical-url]
// Optional scratch content is served only when the requested URL equals the canonical URL,
// preventing a wrong URL from producing a plausible recovery artifact.
// State records created/closed browser targets independently from organizer events.
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import fs from 'node:fs';

const textFile = process.argv[2];
if (!textFile) { console.error('usage: mock-cdp.mjs <tab-text-file>'); process.exit(2); }
const stateFile = process.argv[3] || null;
const scratchTextFile = process.argv[4] || null;
const PRIMARY_URL = 'https://chatgpt.com/c/mock-conversation';
const scratchCanonicalUrl = process.argv[5] || PRIMARY_URL;
const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function wsTextFrame(payload) {
  const data = Buffer.from(payload, 'utf8');
  if (data.length < 126) return Buffer.concat([Buffer.from([0x81, data.length]), data]);
  const head = Buffer.alloc(4);
  head[0] = 0x81; head[1] = 126; head.writeUInt16BE(data.length, 2);
  return Buffer.concat([head, data]);
}

function wsClientTextDecoder(onText) {
  let buffered = Buffer.alloc(0);
  return (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    for (;;) {
      if (buffered.length < 2) return;
      const opcode = buffered[0] & 0x0f;
      const masked = (buffered[1] & 0x80) !== 0;
      let length = buffered[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffered.length < 4) return;
        length = buffered.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffered.length < 10) return;
        length = Number(buffered.readBigUInt64BE(2));
        offset = 10;
      }
      const maskBytes = masked ? 4 : 0;
      if (buffered.length < offset + maskBytes + length) return;
      const mask = masked ? buffered.subarray(offset, offset + 4) : null;
      offset += maskBytes;
      const payload = Buffer.from(buffered.subarray(offset, offset + length));
      buffered = buffered.subarray(offset + length);
      if (mask) for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
      if (opcode === 1) onText(payload.toString('utf8'));
      if (opcode === 8) return;
    }
  };
}

let memoryState = { title: null, archived: false, events: [] };
function readState() {
  if (!stateFile) return memoryState;
  try { return JSON.parse(fs.readFileSync(stateFile, 'utf8')); } catch { return { title: null, archived: false, events: [] }; }
}

function writeState(state) {
  if (!stateFile) {
    memoryState = state;
    return;
  }
  try { fs.writeFileSync(stateFile, `${JSON.stringify(state)}\n`); } catch {}
}

function recordBrowserTarget(field, target) {
  const state = readState();
  state[field] = [...(state[field] ?? []), target];
  writeState(state);
}

function textForTarget(id) {
  if (id.startsWith('scratch') && scratchTextFile) {
    // A target id proves only that Chrome opened a tab. The requested canonical URL is what
    // binds its body to the recovery candidate; mismatch must remain inconclusive/foreign.
    if (scratch.get(id) !== scratchCanonicalUrl) return 'Mock scratch URL mismatch: no conversation content.';
    try { return fs.readFileSync(scratchTextFile, 'utf8'); } catch { return ''; }
  }
  try { return fs.readFileSync(textFile, 'utf8'); } catch { return ''; }
}

function expectedTitleFromExpression(expression) {
  const match = expression.match(/^\s*const expected = (.+);$/m);
  if (!match) return null;
  try { return JSON.parse(match[1]); } catch { return null; }
}

// #271 (U5): when the state file carries `dom`, the shipped review-text expression runs against a
// small ChatGPT-shaped document instead of receiving flat text, so response-scope facts come from
// production code rather than from the fixture. Spec: {href, generating, turns:[{role, text,
// actions}]}. Selectors cover the forms ChatGPT/Oracle use: tag, [attr], [attr="v"], [attr^="v"],
// [attr*="v" i], :not(...), comma lists and descendant combinators. Anything else throws.
function splitTop(source, separator) {
  const parts = [];
  let depth = 0; let quote = null; let start = 0;
  for (let i = 0; i < source.length; i += 1) {
    const ch = source[i];
    if (quote) { if (ch === quote) quote = null; continue; }
    if (ch === '"' || ch === "'") quote = ch;
    else if (ch === '(' || ch === '[') depth += 1;
    else if (ch === ')' || ch === ']') depth -= 1;
    else if (depth === 0 && separator.test(ch)) { parts.push(source.slice(start, i)); start = i + 1; }
  }
  parts.push(source.slice(start));
  return parts.map((part) => part.trim()).filter(Boolean);
}

function matchesCompound(element, compound) {
  const head = compound.match(/^([a-z][a-z0-9-]*|\*)?/i)[0];
  if (head && head !== '*' && element.tagName !== head.toUpperCase()) return false;
  let rest = compound.slice(head.length);
  while (rest) {
    let part = rest.match(/^\[\s*([\w-]+)\s*(?:([\^*]?=)\s*"([^"]*)"\s*(i)?)?\s*\]/);
    if (part) {
      const [, name, op, want, fold] = part;
      const value = element.getAttribute(name);
      if (value === null) return false;
      const have = fold ? value.toLowerCase() : value;
      const need = fold ? want.toLowerCase() : want;
      if (op === '=' && have !== need) return false;
      if (op === '^=' && !have.startsWith(need)) return false;
      if (op === '*=' && !have.includes(need)) return false;
    } else if ((part = rest.match(/^:not\(((?:[^()]|\([^()]*\))*)\)/))) {
      if (matchesSelectorList(element, part[1])) return false;
    } else {
      throw new Error(`mock DOM: unsupported selector ${JSON.stringify(compound)}`);
    }
    rest = rest.slice(part[0].length);
  }
  return true;
}

function matchesSelector(element, selector) {
  const compounds = splitTop(selector, /\s/);
  if (!matchesCompound(element, compounds.at(-1))) return false;
  let ancestor = element.parentElement;
  for (let i = compounds.length - 2; i >= 0; i -= 1) {
    while (ancestor && !matchesCompound(ancestor, compounds[i])) ancestor = ancestor.parentElement;
    if (!ancestor) return false;
    ancestor = ancestor.parentElement;
  }
  return true;
}

function matchesSelectorList(element, list) {
  return splitTop(list, /,/).some((selector) => matchesSelector(element, selector));
}

class FakeElement {
  constructor(tag, attributes = {}, text = '', children = []) {
    this.tagName = tag.toUpperCase();
    this.attributes = attributes;
    this.ownText = text;
    this.children = children;
    this.parentElement = null;
    for (const child of children) child.parentElement = this;
  }
  getAttribute(name) { return Object.hasOwn(this.attributes, name) ? String(this.attributes[name]) : null; }
  hasAttribute(name) { return Object.hasOwn(this.attributes, name); }
  get innerText() {
    return this.children.length
      ? this.children.map((child) => child.innerText).filter(Boolean).join('\n\n')
      : this.ownText;
  }
  get textContent() { return this.innerText; }
  matches(selector) { return matchesSelectorList(this, selector); }
  closest(selector) {
    for (let node = this; node; node = node.parentElement) if (node.matches(selector)) return node;
    return null;
  }
  querySelectorAll(selector) {
    const found = [];
    const walk = (node) => {
      for (const child of node.children) {
        if (child.matches(selector)) found.push(child);
        walk(child);
      }
    };
    walk(this);
    return found;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
}

function fakeDocument(spec) {
  const button = (testid, label) => new FakeElement('button', { 'data-testid': testid, 'aria-label': label });
  const articles = (spec.turns ?? []).map((turn, index) => new FakeElement('article', {
    'data-testid': `conversation-turn-${index + 1}`,
  }, '', [
    new FakeElement('div', { 'data-message-author-role': turn.role, 'data-message-id': `mock-${index + 1}` }, turn.text ?? ''),
    ...(turn.actions ? [new FakeElement('div', {}, '', turn.role === 'assistant'
      ? [button('copy-turn-action-button', 'Copy'), button('good-response-turn-action-button', 'Good response'),
        button('bad-response-turn-action-button', 'Bad response')]
      : [button('copy-turn-action-button', 'Copy')])] : []),
  ]));
  const composer = new FakeElement('form', {}, '', [spec.generating
    ? button('stop-button', 'Stop streaming')
    : button('send-button', 'Send prompt')]);
  const body = new FakeElement('body', {}, '', [new FakeElement('main', {}, '', articles), composer]);
  return {
    body,
    location: { href: spec.href ?? PRIMARY_URL },
    querySelectorAll: (selector) => body.querySelectorAll(selector),
    querySelector: (selector) => body.querySelector(selector),
  };
}

function evaluateReviewText(expression, spec) {
  try {
    const document = fakeDocument(spec);
    return new Function('document', 'location', `return (${expression});`)(document, document.location);
  } catch (error) {
    console.error(`mock DOM evaluation failed: ${error?.message ?? error}`);
    return null;
  }
}

const scratch = new Map();   // id -> url, for tabs opened via /json/new
let scratchSeq = 0;
let primaryClosed = false;
let primaryClosedText = null;

const server = createServer((req, res) => {
  if (req.url === '/json/version') { res.end(JSON.stringify({ Browser: 'MockChrome/1.0' })); return; }
  // A real Chrome can always open a conversation URL in a fresh tab; that is how the salvage
  // reaches a conversation whose own tab is gone. Without this the recovery can never resolve
  // either way, and every outcome collapses to "inconclusive".
  if (req.url?.startsWith('/json/new')) {
    const port = server.address().port;
    const url = decodeURIComponent(req.url.slice(req.url.indexOf('?') + 1));
    const id = `scratch${++scratchSeq}`;
    scratch.set(id, url);
    recordBrowserTarget('created', { id, url });
    console.error(`opened ${id} ${url}`);
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({
      id, type: 'page', url, webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${id}`,
    }));
    return;
  }
  if (req.url === '/json') {
    const port = server.address().port;
    const current = fs.readFileSync(textFile, 'utf8');
    if (primaryClosed && current !== primaryClosedText) {
      primaryClosed = false;
      primaryClosedText = null;
    }
    res.setHeader('content-type', 'application/json');
    const extras = [...scratch].map(([id, url]) => ({
      id, type: 'page', url, webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${id}`,
    }));
    if (current === '__NO_TABS__' || primaryClosed) { res.end(JSON.stringify(extras)); return; }
    res.end(JSON.stringify([{
      id: 'tab1', type: 'page', url: PRIMARY_URL,
      webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/tab1`,
    }, ...extras]));
    return;
  }
  if (req.url?.startsWith('/json/close/')) {
    const id = req.url.split('/').pop();
    if (id === 'tab1') {
      primaryClosed = true;
      try { primaryClosedText = fs.readFileSync(textFile, 'utf8'); } catch { primaryClosedText = null; }
    } else {
      scratch.delete(id);
    }
    recordBrowserTarget('closed', id);
    console.error(`closed ${id}`); res.end('ok'); return;
  }
  res.statusCode = 404; res.end();
});
server.on('upgrade', (req, socket) => {
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + WS_MAGIC).digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
    + `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.on('data', wsClientTextDecoder((payload) => {
    let request;
    try { request = JSON.parse(payload); } catch { return; }
    const targetId = (req.url ?? '').split('/').pop() ?? '';
    const text = textForTarget(targetId);
    const expression = request.params?.expression ?? '';
    let value = text;
    if (expression.includes('pro-gate:terminal-infrastructure')) {
      value = readState().infrastructureError ?? null;
    } else if (expression.includes('pro-gate:throttle-modal')) {
      // #162: the modal is an ELEMENT read, distinct from the page text: without an explicit
      // fixture value the evaluator must see no dialog, never the body text.
      value = readState().throttleModal ?? null;
    } else if (expression.includes('pro-gate-organizer:rename')) {
      const state = readState();
      const expected = expectedTitleFromExpression(expression);
      if (state.renameResult) value = state.renameResult;
      else if (state.title === expected) value = { status: 'already' };
      else {
        state.title = expected;
        state.events = [...(state.events ?? []), { action: 'rename', tab: (req.url ?? '').split('/').pop() }];
        writeState(state);
        console.error('renamed conversation');
        value = { status: 'renamed' };
      }
    } else if (expression.includes('pro-gate-organizer:archive')) {
      const state = readState();
      if (state.archiveResult) value = state.archiveResult;
      else if (state.archived) value = { status: 'already' };
      else {
        state.archived = true;
        state.events = [...(state.events ?? []), { action: 'archive', tab: (req.url ?? '').split('/').pop() }];
        writeState(state);
        console.error('archived conversation');
        value = { status: 'archived' };
      }
    } else if (targetId === 'tab1' && expression.includes('pro-gate:review-text')) {
      const dom = readState().dom;
      if (dom) value = evaluateReviewText(expression, dom);
    }
    socket.write(wsTextFrame(JSON.stringify({ id: request.id, result: { result: { value } } })));
  }));
  socket.on('error', () => {});
});
server.listen(0, '127.0.0.1', () => process.stdout.write(`${server.address().port}\n`));
