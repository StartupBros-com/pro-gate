#!/usr/bin/env node
// Standalone mock CDP browser for engine-level tests: serves /json/version (preflight),
// /json (one chatgpt.com/c/ tab whose innerText is the contents of the file in argv[1]),
// the tab's debugger WebSocket, /json/new (scratch tabs, so the salvage's remembered-URL
// recovery can reach a decisive answer the way a real browser does), and /json/close.
// Prints the chosen port on stdout.
// Usage: node tests/mock-cdp.mjs <source-text-file> [organizer-state-file] [scratch-text-file] [scratch-canonical-url] [second-tab-url] [second-tab-text-file]
// Optional scratch content is served only when the requested URL equals the canonical URL,
// preventing a wrong URL from producing a plausible recovery artifact.
// #216 gate r1 P2: the optional fifth argument adds ONE more listed conversation tab (id tab2) at
// that URL, serving the same body as the primary. One marker can legitimately own two
// conversations — a memoized one and a retry sibling — and no fixture could express that before,
// so nothing could distinguish "closed the one conversation we hold a handle for" from "closed
// everything owned", nor watch what a later pass does to the memo once one of the two is gone.
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
const secondTabUrl = process.argv[6] || null;
// #216 gate r2 P2: the optional SIXTH argument gives that second tab its own body. Until now it
// served the primary's text, so no fixture could express the shape the finding names -- a
// complete, correctly signed conversation A alongside a retry sibling B whose terminal verdict
// carries no marker echo. Absent, tab2 keeps serving the primary's text exactly as before.
const secondTabTextFile = process.argv[7] || null;
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
  if (id === 'tab2' && secondTabTextFile) {
    try { return fs.readFileSync(secondTabTextFile, 'utf8'); } catch { return ''; }
  }
  try { return fs.readFileSync(textFile, 'utf8'); } catch { return ''; }
}

function expectedTitleFromExpression(expression) {
  const match = expression.match(/^\s*const expected = (.+);$/m);
  if (!match) return null;
  try { return JSON.parse(match[1]); } catch { return null; }
}

const scratch = new Map();   // id -> url, for tabs opened via /json/new
let scratchSeq = 0;
let primaryClosed = false;
let primaryClosedText = null;
let secondClosed = false;

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
    // __NO_TABS__ means "this browser lists no conversation tab at all", so it hides the optional
    // second tab exactly as it hides the primary; only an explicit close hides one on its own.
    const second = secondTabUrl && !secondClosed && current !== '__NO_TABS__'
      ? [{
        id: 'tab2', type: 'page', url: secondTabUrl,
        webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/tab2`,
      }]
      : [];
    if (current === '__NO_TABS__' || primaryClosed) { res.end(JSON.stringify([...second, ...extras])); return; }
    res.end(JSON.stringify([{
      id: 'tab1', type: 'page', url: PRIMARY_URL,
      webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/tab1`,
    }, ...second, ...extras]));
    return;
  }
  if (req.url?.startsWith('/json/close/')) {
    const id = req.url.split('/').pop();
    if (id === 'tab1') {
      primaryClosed = true;
      try { primaryClosedText = fs.readFileSync(textFile, 'utf8'); } catch { primaryClosedText = null; }
    } else if (id === 'tab2') {
      secondClosed = true;
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
    }
    socket.write(wsTextFrame(JSON.stringify({ id: request.id, result: { result: { value } } })));
  }));
  socket.on('error', () => {});
});
server.listen(0, '127.0.0.1', () => process.stdout.write(`${server.address().port}\n`));
