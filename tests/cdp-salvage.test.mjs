#!/usr/bin/env node
// Regression tests for bin/cdp-salvage.mjs against a mock CDP endpoint (no ChatGPT, no
// Chrome). Covers the exit-code contract the engine depends on:
//   0 = review extracted (tab left open; the CALLER closes it after validating the capture)
//   3 = marker-matched conversation live but no VERDICT at deadline (tab left open)
//   4 = scanned successfully, nothing matched  -> feeds the engine's "conversation gone" counter
//   7 = inconclusive: CDP never answered      -> must NOT feed that counter
//   probe: 0 as soon as the marker matches
// and the v0.25 recovery contract: a conversation whose TAB is gone is still reachable through
// the remembered conversation URL, so a Chrome restart cannot turn a finished review into a
// "lost" one.
// Run: node tests/cdp-salvage.test.mjs
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';

import {
  buildArchiveConversationExpression,
  buildCancelOrganizerMutationExpression,
  buildRenameConversationExpression,
  ORGANIZER_MUTATION_LEASE_MS,
} from '../bin/cdp-organizer-expressions.mjs';

const SALVAGE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'cdp-salvage.mjs');
const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// Minimal RFC6455 server-side text frame (unmasked, handles lengths up to 64KiB).
function wsTextFrame(payload) {
  const data = Buffer.from(payload, 'utf8');
  if (data.length < 126) return Buffer.concat([Buffer.from([0x81, data.length]), data]);
  const head = Buffer.alloc(4);
  head[0] = 0x81; head[1] = 126; head.writeUInt16BE(data.length, 2);
  return Buffer.concat([head, data]);
}

// Chrome's WebSocket client masks frames and may send more than one request per connection.
// Decode the actual request so the mock can echo its CDP id and model organizer state instead
// of accidentally passing only clients that hard-code id=1.
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

function expressionJsonValue(expression, name) {
  const match = expression.match(new RegExp(`^\\s*const ${name} = (.+);$`, 'm'));
  if (!match) return null;
  try { return JSON.parse(match[1]); } catch { return null; }
}

const expectedTitleFromExpression = (expression) => expressionJsonValue(expression, 'expected');
const mutationTokenFromExpression = (expression) => expressionJsonValue(expression, 'mutationToken');
const mutationExpiresAtFromExpression = (expression) => expressionJsonValue(expression, 'mutationExpiresAt');

// One mock CDP browser: /json lists a single conversation tab whose DOM text is `tabText`;
// the tab's debugger WebSocket answers every message with that text. /json/close records.
// extraTabs (id/url objects) are appended verbatim for tab-hygiene tests.
// opts.renderText(url, nthPoll) supplies the DOM text for scratch tabs opened via /json/new,
// so a test can model a real conversation page load — including one that serves shell/sidebar
// markup on the first poll and the conversation itself only later.
function mockCdp(initialText, extraTabs = [], opts = {}) {
  let tabText = initialText;
  const closed = [];
  const created = [];              // scratch tabs opened via /json/new
  const pollsByTab = new Map();    // scratch tab id -> how many times its DOM has been read
  const requests = [];
  const ui = opts.ui ?? { title: null, archived: false, events: [] };
  ui.events ??= [];
  const mutationTokens = new Map();
  const mutationExpiries = new Map();
  const revokedMutationTokens = new Set();
  let primaryPolls = 0;
  const server = createServer((req, res) => {
    if (req.url === '/json/version') { res.end(JSON.stringify({ Browser: 'MockChrome/1.0' })); return; }
    if (req.url?.startsWith('/json/new')) {
      const port = server.address().port;
      const url = decodeURIComponent(req.url.slice(req.url.indexOf('?') + 1));
      const id = `scratch${created.length + 1}`;
      created.push({ id, url });
      if (opts.hangScratchOpen) return;
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({
        id, type: 'page', url, webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${id}`,
      }));
      return;
    }
    if (req.url === '/json') {
      if (opts.hangScratchList && created.some((t) => !closed.includes(t.id))) return;
      const port = server.address().port;
      res.setHeader('content-type', 'application/json');
      // Extras are listed verbatim EXCEPT that a caller-supplied tab with no debugger URL
      // gets one, so opts.tabText can give listed tabs distinct bodies. Without this an extra
      // tab is unreadable and silently becomes a "dead tab" — which is what tab-hygiene tests
      // (sweep-root, foreign-tab-left-open) rely on, so only fill it in when tabText is used.
      const extras = extraTabs.filter((t) => !closed.includes(t.id)).map((t) => (
        opts.tabText && !t.webSocketDebuggerUrl
          ? { type: 'page', ...t, webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${t.id}` }
          : t
      ));
      if (opts.failScratchList && created.some((t) => !closed.includes(t.id))) {
        res.statusCode = 503; res.end('scratch list unavailable'); return;
      }
      const scratch = created.filter((t) => !closed.includes(t.id)).flatMap((t) => {
        const override = opts.scratchTarget?.(t, pollsByTab.get(t.id) ?? 0);
        if (override === null) return [];
        return [{
          id: t.id, type: 'page', url: t.url,
          webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${t.id}`,
          ...(override ?? {}),
        }];
      });
      if (tabText === '__NO_TABS__' || closed.includes('tab1')) {
        res.end(JSON.stringify([...extras, ...scratch]));
        return;
      }
      res.end(JSON.stringify([{
        id: 'tab1', type: 'page', url: 'https://chatgpt.com/c/mock-conversation',
        webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/tab1`,
      }, ...extras, ...scratch]));
      return;
    }
    if (req.url?.startsWith('/json/close/')) {
      closed.push(req.url.split('/').pop());
      if (opts.hangScratchClose && req.url.split('/').pop().startsWith('scratch')) return;
      res.end('ok');
      return;
    }
    res.statusCode = 404; res.end();
  });
  server.on('upgrade', (req, socket) => {
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + WS_MAGIC).digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
      + `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
    const id = (req.url ?? '').split('/').pop();
    const scratch = created.find((t) => t.id === id);
    const extra = extraTabs.find((t) => t.id === id);
    socket.on('data', wsClientTextDecoder((payload) => {
      let request;
      try { request = JSON.parse(payload); } catch { return; }
      requests.push(request);
      let value = tabText;
      if (id === 'tab1' && opts.primaryText) {
        primaryPolls += 1;
        value = opts.primaryText(tabText, primaryPolls) ?? value;
      }
      // opts.tabText lets a test give LISTED tabs distinct bodies (tab id or url -> text);
      // without it every listed tab serves the same text, which cannot express "one tab is
      // ours and another is foreign" — the shape #68's ordering regression needs.
      if (extra && opts.tabText) value = opts.tabText(extra.url, extra.id) ?? value;
      if (scratch && opts.renderText) {
        const n = (pollsByTab.get(id) ?? 0) + 1;
        pollsByTab.set(id, n);
        value = opts.renderText(scratch.url, n);
      }
      const expression = request.params?.expression ?? '';
      let delayMs = 0;
      let armMutation = null;
      let applyMutation = null;
      if (expression.includes('pro-gate-organizer:rename')) {
        const expected = expectedTitleFromExpression(expression);
        const token = mutationTokenFromExpression(expression);
        const expiresAt = mutationExpiresAtFromExpression(expression);
        armMutation = () => {
          if (revokedMutationTokens.has(`${id}:${token}`)) return;
          mutationTokens.set(id, token);
          mutationExpiries.set(id, expiresAt);
        };
        if (ui.renameResult) value = ui.renameResult;
        else if (ui.title === expected) value = { status: 'already' };
        else {
          value = { status: 'renamed' };
          applyMutation = () => {
            if (
              mutationTokens.get(id) !== token ||
              Date.now() >= mutationExpiries.get(id)
            ) return;
            ui.title = expected;
            ui.events.push({ action: 'rename', id });
          };
        }
        delayMs = Number(ui.renameDelayMs ?? 0);
      } else if (expression.includes('pro-gate-organizer:archive')) {
        const token = mutationTokenFromExpression(expression);
        const expiresAt = mutationExpiresAtFromExpression(expression);
        armMutation = () => {
          if (revokedMutationTokens.has(`${id}:${token}`)) return;
          mutationTokens.set(id, token);
          mutationExpiries.set(id, expiresAt);
        };
        if (ui.archiveResult) value = ui.archiveResult;
        else if (ui.archived) value = { status: 'already' };
        else {
          value = { status: 'archived' };
          applyMutation = () => {
            if (
              mutationTokens.get(id) !== token ||
              Date.now() >= mutationExpiries.get(id)
            ) return;
            ui.archived = true;
            ui.events.push({ action: 'archive', id });
          };
        }
        delayMs = Number(ui.archiveDelayMs ?? 0);
      } else if (expression.includes('pro-gate-organizer:cancel')) {
        const token = expressionJsonValue(expression, 'token') ??
          expressionJsonValue(expression, 'mutationToken');
        if (!ui.cancelUnconfirmed && token) {
          revokedMutationTokens.add(`${id}:${token}`);
          if (mutationTokens.get(id) === token) mutationTokens.delete(id);
        }
        value = ui.cancelUnconfirmed ? false : true;
      }
      const armLate = ui.armMutationAfterDelay && armMutation;
      const response = () => {
        if (armLate) armMutation();
        applyMutation?.();
        socket.write(wsTextFrame(JSON.stringify({
          id: request.id,
          result: { result: { value } },
        })));
      };
      if (armMutation && !armLate) armMutation();
      if (delayMs > 0) setTimeout(response, delayMs);
      else response();
    }));
    socket.on('error', () => {});
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port,
    closed,
    created,
    requests,
    ui,
    setText: (value) => {
      if (value !== tabText) {
        const closedAt = closed.indexOf('tab1');
        if (closedAt >= 0) closed.splice(closedAt, 1);
      }
      tabText = value;
    },
    stop: (cb) => server.close(cb),
  })));
}

// Async spawn: the mock CDP server lives in THIS process, so a blocking spawnSync would
// deadlock (the child's requests could never be served while the parent's loop is blocked).
// seed: optional (home) => void, to pre-populate PRO_GATE_HOME (remembered conversation URL,
// blacklist) before the run. The resolved result carries `home` contents read back before the
// directory is removed, so a test can assert what the salvage persisted.
function runSalvage(args, port, seed, extraEnv = {}) {
  // Isolated PRO_GATE_HOME so blacklist/cooldown/URL-memo state never leaks between tests or
  // into a real deployment's home.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  if (seed) seed(home);
  return new Promise((resolve) => {
    const startedAt = Date.now();
    const expandedArgs = args.map((arg) => arg.replace(/^PG_HOME\//, `${home}/`));
    const child = spawn(process.execPath, [SALVAGE, ...expandedArgs, String(port)], {
      env: { ...process.env, PRO_GATE_HOME: home, ...extraEnv },
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    const killer = setTimeout(() => child.kill('SIGKILL'), Number(extraEnv.PRO_GATE_TEST_CHILD_TIMEOUT_MS ?? 90_000));
    child.on('close', (status) => {
      clearTimeout(killer);
      const read = (rel) => { try { return fs.readFileSync(path.join(home, rel), 'utf8'); } catch { return null; } };
      const memos = (() => {
        try { return fs.readdirSync(path.join(home, 'conversation-urls')); } catch { return []; }
      })();
      const memoUrl = memos.length ? read(path.join('conversation-urls', memos[0])) : null;
      const blacklist = read('salvage-nonmatching.txt');
      const cooldown = read('throttle.cooldown');
      // #68: convictions recorded for --status to read back (one line per cross-bind hit).
      const crossbound = (() => {
        try {
          return fs.readdirSync(path.join(home, 'crossbound'))
            .reduce((n, f) => n + (read(path.join('crossbound', f)) ?? '').split('\n').filter(Boolean).length, 0);
        } catch { return 0; }
      })();
      fs.rmSync(home, { recursive: true, force: true });
      resolve({
        status, stdout, stderr, elapsedMs: Date.now() - startedAt,
        memoUrl: memoUrl?.trim() ?? null, memos, blacklist, cooldown, crossbound,
      });
    });
  });
}

// Write a remembered-conversation memo, exactly as a previous invocation would have.
function seedMemo(marker, url) {
  return (home) => {
    fs.mkdirSync(path.join(home, 'conversation-urls'), { recursive: true });
    fs.writeFileSync(path.join(home, 'conversation-urls', marker), `${url}\n`);
  };
}

function seedOrganizer(marker, title, url = null, review = null) {
  return (home) => {
    fs.mkdirSync(path.join(home, 'conversation-titles'), { recursive: true });
    fs.writeFileSync(path.join(home, 'conversation-titles', marker), `${title}\n`);
    if (url) seedMemo(marker, url)(home);
    if (review !== null) {
      fs.mkdirSync(path.join(home, 'completed'), { recursive: true });
      fs.writeFileSync(path.join(home, 'completed', marker), `${review}\n`);
    }
  };
}

const completedReview = (marker, summary = 'owned') => [
  'P0: none',
  'P1: none',
  'P2: none',
  'P3: none',
  `VERDICT: SHIP — ${summary}. (run marker: ${marker})`,
].join('\n');
const durableReview = (review, marker) => {
  const lines = review.split('\n');
  let verdict = -1;
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if (/^\s*[*_>#-]*\s*VERDICT[*_\s]*:/i.test(lines[i])) { verdict = i; break; }
  }
  let start = -1;
  for (let i = verdict; i >= 0; i -= 1) {
    if (/^\s*[*_>#-]*\s*(P0\s*[:\-]|P0\b|\[P[0-3]\])/i.test(lines[i].trim())) start = i;
  }
  if (start < 0) start = Math.max(0, verdict - 120);
  return lines.slice(start, verdict + 1).join('\n')
    .replace(`(run marker: ${marker})`, '')
    .replace(/[ \t]+$/gm, '')
    .trim();
};
const finalizerArgs = (marker, { archive = true, rename = true, acceptedUrl = null } = {}) => {
  const args = ['--organize', '--finalize', '--result-file', `PG_HOME/completed/${marker}`];
  if (acceptedUrl) args.push('--accepted-url', acceptedUrl);
  if (archive) args.push('--archive');
  if (!rename) args.push('--no-rename');
  return [...args, marker, '5'];
};

let failures = 0;
function check(name, cond, detail) {
  if (cond) { console.log(`ok - ${name}`); return; }
  failures += 1; console.log(`FAIL - ${name}${detail ? `: ${detail}` : ''}`);
}

const MARKER = 'pg-run-test-1234567890-42';

{ // still generating: marker matches, no VERDICT -> exit 3, tab NOT closed
  const cdp = await mockCdp(`run marker: ${MARKER}\nReasoning about the diff...`);
  const r = await runSalvage([MARKER, '3'], cdp.port);
  check('still-generating exits 3', r.status === 3, `status=${r.status} stderr=${r.stderr?.slice(0, 200)}`);
  check('still-generating leaves the source tab open after closing its scratch revalidation',
    !cdp.closed.includes('tab1') && cdp.closed.includes('scratch1'), `closed=${cdp.closed}`);
  check('still-generating names the conversation', /still-generating: .*mock-conversation/.test(r.stderr ?? ''));
  cdp.stop();
}

{ // U1: production-shaped divergence. The listed source is readable and marker-owned but stale;
  // the same canonical URL, rendered in a scratch tab, contains the completed server answer.
  // Recovery must never refresh, close, or otherwise mutate the source target.
  const canonicalUrl = 'https://chatgpt.com/c/mock-conversation';
  const staleSource = `run marker: ${MARKER}\nReasoning about the diff...`;
  const serverReview = [
    `run marker: ${MARKER}`,
    '[P1] src/stale-source.mjs:10 — server-complete finding',
    'P2: none',
    `VERDICT: FIX-FIRST — recovered from the canonical conversation. (run marker: ${MARKER})`,
  ].join('\n');
  const cdp = await mockCdp(staleSource, [], { renderText: (url) => url === canonicalUrl ? serverReview : '' });
  const r = await runSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
  check('readable stale source recovers the canonical scratch review', r.status === 0,
    `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  const expectedReview = serverReview.split('\n').slice(1).join('\n');
  check('readable stale source prints the canonical scratch review bytes', r.stdout.trim() === expectedReview,
    `stdout=${r.stdout?.slice(0, 300)}`);
  check('readable stale source opens and closes one canonical scratch target',
    cdp.created.length === 1 && cdp.created[0]?.url === canonicalUrl && cdp.closed.includes(cdp.created[0].id),
    `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
  check('readable stale source stays open and unnavigated',
    !cdp.closed.includes('tab1') && !cdp.requests.some((request) => request.method === 'Page.navigate'),
    `closed=${cdp.closed} requests=${JSON.stringify(cdp.requests)}`);
  cdp.stop();
}

{ // U1 regression: ChatGPT can hydrate our prompt marker before its completed answer. The readable
  // source is stale, so its one canonical scratch revalidation must sample past marker-only text.
  const canonicalUrl = 'https://chatgpt.com/c/mock-conversation';
  const staleSource = `run marker: ${MARKER}\nReasoning about the diff...`;
  const markerOnlyScratch = `run marker: ${MARKER}\nAnswer is still hydrating...`;
  const serverReview = [
    `run marker: ${MARKER}`,
    '[P1] src/stale-source.mjs:10 — hydrated server-complete finding',
    'P2: none',
    `VERDICT: FIX-FIRST — recovered after marker hydration. (run marker: ${MARKER})`,
  ].join('\n');
  const cdp = await mockCdp(staleSource, [], {
    renderText: (url, n) => url === canonicalUrl && n === 1 ? markerOnlyScratch : serverReview,
  });
  const r = await runSalvage([MARKER, '8'], cdp.port, seedMemo(MARKER, canonicalUrl));
  check('readable stale source waits past a marker-only canonical scratch sample', r.status === 0,
    `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('marker-hydration revalidation emits the later nonce-bearing verdict',
    r.stdout.trim() === serverReview.split('\n').slice(1).join('\n'), `stdout=${r.stdout?.slice(0, 300)}`);
  check('marker-hydration revalidation closes only its scratch target',
    cdp.created.length === 1 && cdp.closed.includes('scratch1') && !cdp.closed.includes('tab1'),
    `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
  cdp.stop();
}

{ // U1 probe must defer its normal early exit until the same bounded canonical revalidation.
  const canonicalUrl = 'https://chatgpt.com/c/mock-conversation';
  const staleSource = `run marker: ${MARKER}\nReasoning about the diff...`;
  const serverReview = [
    `run marker: ${MARKER}`,
    'P1: none',
    `VERDICT: SHIP — server-complete. (run marker: ${MARKER})`,
  ].join('\n');
  const cdp = await mockCdp(staleSource, [], { renderText: (url) => url === canonicalUrl ? serverReview : '' });
  const r = await runSalvage(['--probe', MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
  check('probe revalidates a readable stale source and remains live (exit 0)', r.status === 0,
    `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('probe classifies fresh owned terminal evidence as complete', /^probe-state: complete$/m.test(r.stderr || ''),
    `stderr=${r.stderr?.slice(0, 300)}`);
  check('probe emits no review body after stale-source revalidation', r.stdout === '', `stdout=${r.stdout}`);
  check('probe closes only its canonical scratch target',
    cdp.created.length === 1 && cdp.closed.includes(cdp.created[0].id) && !cdp.closed.includes('tab1'),
    `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
  cdp.stop();
}

{ // U1: an owned incomplete scratch remains live and must not consume a second stale render.
  const canonicalUrl = 'https://chatgpt.com/c/mock-conversation';
  const cdp = await mockCdp(`run marker: ${MARKER}\nstale readable source`, [], {
    renderText: () => `run marker: ${MARKER}\nstill generating on the server`,
  });
  const r = await runSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
  check('same-marker incomplete scratch remains still-generating', r.status === 3, `status=${r.status} stderr=${r.stderr}`);
  check('same-marker incomplete scratch is attempted only once', cdp.created.length === 1 && cdp.closed.includes('scratch1'),
    `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
  check('incomplete scratch keeps the canonical memo and avoids blacklist/cross-bind mutation',
    r.memoUrl === canonicalUrl && r.blacklist === null && r.crossbound === 0,
    `memo=${r.memoUrl} blacklist=${r.blacklist} crossbound=${r.crossbound}`);
  cdp.stop();
}

{ // U1: an old foreign-marked verdict before our latest prompt is not this run's completion.
  const canonicalUrl = 'https://chatgpt.com/c/mock-conversation';
  const oldBeforePrompt = [
    'P1: old/source.mjs:1 — old answer',
    'VERDICT: SHIP — old. (run marker: pg-run-old-round-1111111111-1)',
    `run marker: ${MARKER}`,
    'new answer still generating',
  ].join('\n');
  const cdp = await mockCdp(`run marker: ${MARKER}\nstale readable source`, [], { renderText: () => oldBeforePrompt });
  const r = await runSalvage(['--probe', MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
  check('probe keeps an old foreign-marked scratch verdict generating',
    r.status === 0 && /^probe-state: generating$/m.test(r.stderr || ''), `status=${r.status} stderr=${r.stderr}`);
  check('old verdict ordering closes only one scratch', cdp.created.length === 1 && !cdp.closed.includes('tab1'),
    `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
  cdp.stop();

  const oldOwnedBeforePrompt = [
    `run marker: ${MARKER}`,
    'P1: old/source.mjs:1 — old answer from this same run marker',
    `VERDICT: SHIP — old. (run marker: ${MARKER})`,
    `run marker: ${MARKER}`,
    'new answer still generating',
  ].join('\n');
  const ownCdp = await mockCdp(`run marker: ${MARKER}\nstale readable source`, [], {
    renderText: () => oldOwnedBeforePrompt,
  });
  const ownResult = await runSalvage(['--probe', MARKER, '3'], ownCdp.port, seedMemo(MARKER, canonicalUrl));
  check('probe keeps an old same-marker terminal verdict before the latest prompt generating',
    ownResult.status === 0 && /^probe-state: generating$/m.test(ownResult.stderr || ''),
    `status=${ownResult.status} stderr=${ownResult.stderr}`);
  ownCdp.stop();
}

{ // U1: scratch transport and hydration failures are inconclusive, never a memo or blacklist mutation.
  const canonicalUrl = 'https://chatgpt.com/c/mock-conversation';
  const source = `run marker: ${MARKER}\nstale readable source`;
  const login = 'Log in\nSign up\nContinue with Google';
  const cases = [
    ['canonical URL drift', { scratchTarget: () => ({ url: 'https://chatgpt.com/c/wrong-conversation' }) }],
    ['scratch target disappearance', { scratchTarget: () => null }],
    ['scratch CDP listing failure', { failScratchList: true }],
    ['login wall', { renderText: () => login }],
    ['pre-hydration shell', { renderText: () => 'Chat history\nNew chat\nSidebar only' }],
  ];
  for (const [name, opts] of cases) {
    const cdp = await mockCdp(source, [], opts);
    const r = await runSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
    check(`${name} is inconclusive while the readable source remains live`, r.status === 3,
      `status=${r.status} stderr=${r.stderr}`);
    check(`${name} keeps memo and avoids blacklist/cross-bind mutation`,
      r.memoUrl === canonicalUrl && r.blacklist === null && r.crossbound === 0,
      `memo=${r.memoUrl} blacklist=${r.blacklist} crossbound=${r.crossbound}`);
    check(`${name} closes only the disposable scratch`,
      cdp.created.length === 1 && cdp.closed.includes('scratch1') && !cdp.closed.includes('tab1'),
      `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
    cdp.stop();
  }
}

{ // U1: throttle and cross-bound scratch outcomes retain their existing safety consequences.
  const canonicalUrl = 'https://chatgpt.com/c/mock-conversation';
  const source = `run marker: ${MARKER}\nstale readable source`;
  const throttle = "You're making requests too quickly. Temporarily limited access to your conversations.";
  const throttled = await mockCdp(source, [], { renderText: () => throttle });
  const throttleResult = await runSalvage([MARKER, '3'], throttled.port, seedMemo(MARKER, canonicalUrl));
  check('throttled canonical scratch takes the existing throttle exit', throttleResult.status === 5,
    `status=${throttleResult.status} stderr=${throttleResult.stderr}`);
  check('throttled canonical scratch writes cooldown and closes only scratch',
    /canonical scratch/.test(throttleResult.cooldown ?? '') && throttled.closed.includes('scratch1') && !throttled.closed.includes('tab1'),
    `cooldown=${throttleResult.cooldown} closed=${throttled.closed}`);
  throttled.stop();

  const foreignAnswer = [
    `run marker: ${MARKER}`,
    '[P1] foreign/source.mjs:1 — another run',
    'VERDICT: FIX-FIRST — not ours. (run marker: pg-run-other-repo-42-1111111111-9)',
  ].join('\n');
  const crossBound = await mockCdp(source, [], { renderText: () => foreignAnswer });
  const crossBoundResult = await runSalvage([MARKER, '3'], crossBound.port, seedMemo(MARKER, canonicalUrl));
  check('cross-bound canonical scratch is never emitted as our review',
    crossBoundResult.status !== 0 && !/VERDICT/.test(crossBoundResult.stdout ?? ''),
    `status=${crossBoundResult.status} stdout=${crossBoundResult.stdout}`);
  check('cross-bound canonical scratch forgets and blacklists the stale canonical memo',
    crossBoundResult.memos.length === 0 && /mock-conversation/.test(crossBoundResult.blacklist ?? ''),
    `memos=${JSON.stringify(crossBoundResult.memos)} blacklist=${crossBoundResult.blacklist}`);
  check('cross-bound canonical scratch closes only scratch',
    crossBound.closed.includes('scratch1') && !crossBound.closed.includes('tab1'), `closed=${crossBound.closed}`);
  crossBound.stop();

  const foreignOnly = await mockCdp(source, [], {
    renderText: () => 'run marker: pg-run-other-repo-42-1111111111-9\nVERDICT: SHIP — foreign.',
  });
  const foreignResult = await runSalvage([MARKER, '3'], foreignOnly.port, seedMemo(MARKER, canonicalUrl));
  check('foreign canonical scratch is rejected as a decisive stale memo', foreignResult.status === 4,
    `status=${foreignResult.status} stderr=${foreignResult.stderr}`);
  check('foreign canonical scratch forgets and blacklists the stale memo',
    foreignResult.memos.length === 0 && /mock-conversation/.test(foreignResult.blacklist ?? ''),
    `memos=${JSON.stringify(foreignResult.memos)} blacklist=${foreignResult.blacklist}`);
  foreignOnly.stop();
}

{ // P1: a readable incomplete source must not overwrite a prior genuine memo before its one
  // canonical scratch revalidation has ruled out a cross-bound answer.
  const priorUrl = 'https://chatgpt.com/c/prior-genuine';
  const source = `run marker: ${MARKER}\nstale readable source`;
  const crossBoundAnswer = [
    `run marker: ${MARKER}`,
    '[P1] foreign/source.mjs:1 — another run',
    'VERDICT: FIX-FIRST — not ours. (run marker: pg-run-other-repo-42-1111111111-9)',
  ].join('\n');
  const cdp = await mockCdp(source, [], { renderText: () => crossBoundAnswer });
  const r = await runSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, priorUrl));
  check('cross-bound stale scratch rejects source A without replacing prior memo B',
    r.status === 7 && r.memoUrl === priorUrl && r.memos.length === 1,
    `status=${r.status} memo=${r.memoUrl} memos=${JSON.stringify(r.memos)} stderr=${r.stderr}`);
  check('cross-bound stale scratch records its diagnostic despite readable source A', r.crossbound > 0,
    `crossbound=${r.crossbound} stderr=${r.stderr}`);
  check('cross-bound stale scratch rejects A without mutating its source target',
    /mock-conversation/.test(r.blacklist ?? '') && !cdp.closed.includes('tab1') &&
      !cdp.requests.some((request) => request.method === 'Page.navigate'),
    `blacklist=${r.blacklist} closed=${cdp.closed} requests=${JSON.stringify(cdp.requests)}`);
  cdp.stop();
}

{ // P1: an unresponsive scratch-open endpoint is absence of fresh evidence, not permission to
  // overrun the caller deadline or mutate a readable source's prior recovery handle.
  const priorUrl = 'https://chatgpt.com/c/prior-genuine';
  const source = `run marker: ${MARKER}\nstale readable source`;
  for (const [label, args, expectedStatus] of [
    ['normal', [MARKER, '3'], 3],
    ['probe', ['--probe', MARKER, '3'], 0],
  ]) {
    const cdp = await mockCdp(source, [], { hangScratchOpen: true });
    const r = await runSalvage(args, cdp.port, seedMemo(MARKER, priorUrl), {
      PRO_GATE_TEST_CHILD_TIMEOUT_MS: '6000',
    });
    // Bound relaxed from 4_500: against a 3s deadline and a 6000ms SIGKILL fallback, 4_500 left
    // only ~1.5s of slack for spawn + timer jitter, and this is the only upper-bound wall-clock
    // assertion in a file whose other elapsed assertions are lower-bound only. 5_500 still proves
    // the process beat the SIGKILL fallback with margin to spare.
    check(`${label} scratch-open timeout returns before its watchdog fallback`,
      r.status === expectedStatus && r.elapsedMs < 5_500,
      `status=${r.status} elapsed=${r.elapsedMs}ms stderr=${r.stderr}`);
    check(`${label} scratch-open timeout leaves source and recovery state unchanged`,
      r.memoUrl === priorUrl && r.blacklist === null && r.crossbound === 0 && !cdp.closed.includes('tab1'),
      `memo=${r.memoUrl} blacklist=${r.blacklist} crossbound=${r.crossbound} closed=${cdp.closed}`);
    cdp.stop();
  }
}

{ // P1: an unresponsive scratch LIST poll (headers never arrive at all) is likewise absence of
  // fresh evidence, not permission to overrun the caller deadline. Regression lock: before this
  // test existed, opts.hangScratchList was defined in the mock but no test ever set it, so
  // reverting the /json list-poll's fetchJsonBeforeDeadline binding back to a bare fetch() would
  // fail nothing.
  const priorUrl = 'https://chatgpt.com/c/prior-genuine';
  const source = `run marker: ${MARKER}\nstale readable source`;
  for (const [label, args, expectedStatus] of [
    ['normal', [MARKER, '3'], 3],
    ['probe', ['--probe', MARKER, '3'], 0],
  ]) {
    const cdp = await mockCdp(source, [], { hangScratchList: true });
    const r = await runSalvage(args, cdp.port, seedMemo(MARKER, priorUrl), {
      PRO_GATE_TEST_CHILD_TIMEOUT_MS: '6000',
    });
    check(`${label} scratch-list timeout returns before its watchdog fallback`,
      r.status === expectedStatus && r.elapsedMs < 5_500,
      `status=${r.status} elapsed=${r.elapsedMs}ms stderr=${r.stderr}`);
    check(`${label} scratch-list timeout leaves source and recovery state unchanged`,
      r.memoUrl === priorUrl && r.blacklist === null && r.crossbound === 0 && !cdp.closed.includes('tab1'),
      `memo=${r.memoUrl} blacklist=${r.blacklist} crossbound=${r.crossbound} closed=${cdp.closed}`);
    cdp.stop();
  }
}

{ // P1: an unresponsive scratch CLOSE (the fix-A cleanup attempt in freshRenderText's finally
  // block) must not be allowed to hang the process either, and — the regression lock for fix A —
  // the close must actually be ATTEMPTED even though the peer never replies. scratchTarget
  // returning null makes the scratch target vanish from the /json listing (mirroring a
  // disappeared tab) so freshRenderText reaches its cleanup finally without ever reading decisive
  // text, keeping this test's second assertion (unchanged recovery state) meaningful the same way
  // the scratch-open and scratch-list variants above are.
  const priorUrl = 'https://chatgpt.com/c/prior-genuine';
  const source = `run marker: ${MARKER}\nstale readable source`;
  for (const [label, args, expectedStatus] of [
    ['normal', [MARKER, '3'], 3],
    ['probe', ['--probe', MARKER, '3'], 0],
  ]) {
    const cdp = await mockCdp(source, [], { hangScratchClose: true, scratchTarget: () => null });
    // This variant is the slowest of the three by construction: the render loop must burn its
    // 2.5s sample before the target-disappeared return, and only THEN does the cleanup close
    // spend its own 2s grace against a peer that never replies (~4.5s before spawn overhead).
    // So it gets a proportionally later kill fallback and ceiling rather than the 6000/5_500 the
    // open- and list-timeout variants use, where the abort lands at the 3s caller deadline.
    const r = await runSalvage(args, cdp.port, seedMemo(MARKER, priorUrl), {
      PRO_GATE_TEST_CHILD_TIMEOUT_MS: '9000',
    });
    check(`${label} scratch-close timeout returns before its watchdog fallback`,
      r.status === expectedStatus && r.elapsedMs < 7_000,
      `status=${r.status} elapsed=${r.elapsedMs}ms stderr=${r.stderr}`);
    check(`${label} scratch-close timeout leaves source and recovery state unchanged`,
      r.memoUrl === priorUrl && r.blacklist === null && r.crossbound === 0 && !cdp.closed.includes('tab1'),
      `memo=${r.memoUrl} blacklist=${r.blacklist} crossbound=${r.crossbound} closed=${cdp.closed}`);
    check(`${label} scratch-close cleanup was attempted despite no reply`,
      cdp.closed.includes('scratch1'),
      `closed=${cdp.closed}`);
    cdp.stop();
  }
}

{ // completed review: marker + Pn block + VERDICT -> exit 0, review on stdout, tab LEFT OPEN
  const review = `run marker: ${MARKER}\n[P1] src/x.sh:10: bug\n  Why: real\nP2: none\nVERDICT: SHIP: clean.`;
  const cdp = await mockCdp(review);
  const r = await runSalvage([MARKER, '30'], cdp.port);
  check('completed review exits 0', r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(0, 200)}`);
  check('review block printed', /VERDICT: SHIP/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 120)}`);
  // v0.25: the salvage no longer closes on its OWN looser heuristic. The caller re-checks the
  // capture with pg_is_review (stricter: Pn block AND a trailing VERDICT) and only then closes,
  // via pg_finish. Closing here destroyed conversations whose capture the caller then rejected,
  // leaving the engine to report a perfectly intact review as lost.
  check('completed review leaves the tab for the caller to close', !cdp.closed.includes('tab1'), `closed=${cdp.closed}`);
  check('completed review remembers the conversation URL',
    r.memoUrl === 'https://chatgpt.com/c/mock-conversation', `memoUrl=${r.memoUrl}`);
  cdp.stop();
}

{ // THE REPORTED BUG: conversation finished, but its tab is gone (Chrome restarted). The
  // remembered URL must re-render it instead of reporting the review lost.
  const review = `run marker: ${MARKER}\n[P0] a.ts:1: boom\n  Why: real\nVERDICT: FIX-FIRST: bad.`;
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => review });
  const r = await runSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/remembered'));
  check('tabless conversation is recovered from the remembered URL', r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('recovered review is printed', /VERDICT: FIX-FIRST/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 160)}`);
  check('recovery re-rendered the remembered URL',
    cdp.created.some((t) => t.url === 'https://chatgpt.com/c/remembered'), `created=${JSON.stringify(cdp.created)}`);
  cdp.stop();
}

{ // probe: same recovery, so reservation reconciliation cannot release a live run's slot (and
  // let the next fresh run double-spend) merely because Chrome restarted.
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => `run marker: ${MARKER}\nthinking...` });
  const r = await runSalvage(['--probe', MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/remembered'));
  check('probe finds a tabless conversation via the remembered URL', r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  cdp.stop();
}

{ // hydration race: the first DOM read returns chatgpt.com's shell + sidebar (well over the old
  // 200-char "loaded" threshold, carrying none of the conversation). It must not be mistaken for
  // a non-matching page — that false negative burnt the tiny per-URL render budget.
  const shell = 'Skip to content\nChat history\nChatGPT Pro\nNew chat\nLibrary\nScheduled\nPlugins\nMore\n'
    + `Pinned\n${'Some earlier conversation title\n'.repeat(40)}`;
  const review = `run marker: ${MARKER}\n[P2] b.ts:2: nit\n  Why: real\nVERDICT: SHIP: fine.`;
  check('shell alone clears the old 200-char gate', shell.length > 200, `len=${shell.length}`);
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: (_url, n) => (n === 1 ? shell : review) });
  const r = await runSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/remembered'));
  check('a pre-hydration render is not treated as a miss', r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('the review is read once the page hydrates', /VERDICT: SHIP/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 160)}`);
  cdp.stop();
}

{ // a legacy GLOBAL blacklist entry (bare URL, written by a DIFFERENT run) must not hide our
  // own conversation: "not run A's" says nothing about run B.
  const review = `run marker: ${MARKER}\n[P1] c.ts:3: bug\n  Why: real\nVERDICT: SHIP: ok.`;
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => review });
  const r = await runSalvage([MARKER, '30'], cdp.port, (home) => {
    seedMemo(MARKER, 'https://chatgpt.com/c/remembered')(home);
    fs.writeFileSync(path.join(home, 'salvage-nonmatching.txt'), 'https://chatgpt.com/c/remembered\n');
  });
  check('a legacy global blacklist entry does not hide our conversation', r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  cdp.stop();
}

{ // gate P1: a URL learned THIS invocation must be usable immediately. The tab matches, then
  // dies (Chrome restart mid-salvage — the exact failure this file exists for). Recovery must
  // engage on the URL just learned, not wait for the next invocation.
  const cdp = await mockCdp(`run marker: ${MARKER}\nthinking...`, [], {
    renderText: () => `run marker: ${MARKER}\n[P1] z.ts:1: bug\n  Why: real\nVERDICT: SHIP: ok.`,
  });
  // kill the tab shortly after the first scan has matched it
  setTimeout(() => cdp.setText('__NO_TABS__'), 1_500);
  const r = await runSalvage([MARKER, '40'], cdp.port);   // NO seeded memo: it must be learned
  check('a URL learned this invocation is used for recovery', r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('the learned URL is the one re-rendered',
    cdp.created.some((t) => t.url === 'https://chatgpt.com/c/mock-conversation'), `created=${JSON.stringify(cdp.created)}`);
  cdp.stop();
}

{ // gate P1: proven SERVER-SIDE liveness must outlive a later empty tab scan. The remembered
  // render proves the conversation is alive but unfinished; subsequent scans see no tabs. That
  // must end as still-generating (3), not a confirmed miss (4) that pushes toward "gone".
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => `run marker: ${MARKER}\nstill reasoning...` });
  const r = await runSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/remembered'));
  check('server-side liveness survives later empty scans (exit 3)', r.status === 3, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('still-generating says it was proven server-side',
    /proven server-side/.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(-300)}`);
  cdp.stop();
}

{ // gate P1: an INCONCLUSIVE remembered render (shell that never hydrates) must not be laundered
  // into a confirmed absence by a successful tab listing.
  const shell = `Skip to content\nChat history\nNew chat\n${'Another conversation\n'.repeat(30)}`;
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => shell });
  const r = await runSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/remembered'));
  check('an undecided remembered conversation exits 7, not 4', r.status === 7, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  cdp.stop();
}

{ // ...but a memo that decisively points at ANOTHER run's conversation IS a real negative.
  const cdp = await mockCdp('__NO_TABS__', [], {
    renderText: () => 'run marker: pg-run-someone-else-1111111111-9\na different review entirely',
  });
  const r = await runSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/remembered'));
  check('a stale memo pointing at another run still exits 4', r.status === 4, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  cdp.stop();
}

// ── #67: cross-bound memo. A page can carry OUR marker (it rides the submitted prompt) while
// the completed ANSWER belongs to another run. Two live incidents memoized exactly such a page
// as "ours"; since a remembered URL is exempt from blacklisting, the memo stayed poisoned and
// every later harvest re-rejected the same foreign answer while the reservation never retired.
const FOREIGN_ANSWER = (m) => [
  `pro-gate review: PR #999 r1 [other-repo]`,
  `run marker: ${m}`,                       // OUR marker, in the prompt echoed on the page
  '',
  '[P1] apps/other/thing.ts:12 — something in ANOTHER change',
  'P2: none',
  'P3: none',
  'VERDICT: FIX-FIRST — not ours. (run marker: pg-run-other-repo-42-1111111111-9)',
].join('\n');

{ // The cross-bind itself: a remembered URL whose completed answer is another run's must be
  // discarded, not re-memoized — and must NOT be returned as our review.
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => FOREIGN_ANSWER(MARKER) });
  const r = await runSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/crossbound'));
  check('cross-bound memo is not accepted as our review', r.status !== 0, `status=${r.status}`);
  check('cross-bound memo exits 4 (decisive), not 7/3', r.status === 4, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  check('cross-bound memo is reported as another run\'s answer',
    /ANOTHER run's completed answer/.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(-400)}`);
  check('the poisoned memo file is deleted', (r.memos ?? []).length === 0, `memos=${JSON.stringify(r.memos)}`);
  check('no foreign review text is emitted on stdout',
    !/VERDICT/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 200)}`);
  cdp.stop();
}

{ // Same page shape, but arriving as an OPEN TAB rather than a memo: also refused.
  const cdp = await mockCdp(FOREIGN_ANSWER(MARKER));
  const r = await runSalvage([MARKER, '20'], cdp.port);
  check('an open tab with our marker but another run\'s answer is refused', r.status !== 0, `status=${r.status}`);
  check('open-tab cross-bind never emits the foreign review',
    !/VERDICT/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 200)}`);
  cdp.stop();
}

{ // NON-NEGOTIABLE: the fix must not make us laxer. A page carrying our marker AND our own
  // nonce echo is still accepted exactly as before.
  const ours = [
    `run marker: ${MARKER}`,
    '',
    '[P1] lib/thing.sh:3 — a real finding',
    'P2: none',
    'P3: none',
    `VERDICT: FIX-FIRST — ours. (run marker: ${MARKER})`,
  ].join('\n');
  const cdp = await mockCdp(ours);
  const r = await runSalvage([MARKER, '20'], cdp.port);
  check('our own nonce-bearing review is still returned (exit 0)', r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  check('our review reaches stdout', /VERDICT: FIX-FIRST/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 200)}`);
  cdp.stop();
}

{ // A still-generating conversation (our marker, NO completed verdict yet) must remain
  // "live", not be mistaken for a cross-bind: the foreign check only fires on a COMPLETE answer.
  const cdp = await mockCdp(`run marker: ${MARKER}\nthinking hard, no verdict yet`);
  const r = await runSalvage([MARKER, '12'], cdp.port);
  check('still-generating stays exit 3 under the new check', r.status === 3, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  cdp.stop();
}

{ // #68 gate P1 (POSITION): a REUSED conversation can hold an older nonce-bearing verdict
  // ABOVE our freshly-submitted prompt while our answer is still generating. extractReview()
  // takes the LAST verdict, which here is the OLD one — convicting on it would blacklist and
  // forget the genuine LIVE conversation. Order decides: foreign verdict BEFORE our marker.
  const scrollback = [
    '[P1] old/thing.ts:1 — a previous round in this same chat',
    'P2: none',
    'P3: none',
    'VERDICT: FIX-FIRST — earlier round. (run marker: pg-run-old-round-1111111111-1)',
    '',
    `run marker: ${MARKER}`,                 // OUR prompt comes AFTER the old verdict
    'thinking about the new diff...',
  ].join('\n');
  const cdp = await mockCdp(scrollback);
  const r = await runSalvage([MARKER, '12'], cdp.port);
  // cdp-salvage owns TAB OWNERSHIP, the engine owns nonce validation: the old verdict is
  // returned (exit 0) and the ENGINE's nonce check then sets it aside as unbound-AMBIGUOUS,
  // the retryable state. What must NOT happen here is a conviction — blacklisting/forgetting
  // the live conversation — or a crossbound sidecar, which would mark it terminally stuck.
  check('an OLDER verdict above our prompt is returned for engine adjudication', r.status === 0,
    `status=${r.status} stderr=${r.stderr?.slice(-400)}`);
  check('the live conversation is not convicted', !/ANOTHER run's completed answer/.test(r.stderr ?? ''),
    `stderr=${r.stderr?.slice(-400)}`);
  check('no crossbound sidecar is written for scrollback', (r.crossbound ?? 0) === 0,
    `crossbound=${r.crossbound}`);
  cdp.stop();
}

{ // A convicted cross-bind records a sidecar so --status can distinguish terminally-stuck
  // from merely-ambiguous (#68 gate P2).
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => FOREIGN_ANSWER(MARKER) });
  const r = await runSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/crossbound2'));
  check('a conviction is recorded in crossbound/<marker>', (r.crossbound ?? 0) > 0,
    `crossbound=${r.crossbound} stderr=${r.stderr?.slice(-300)}`);
  cdp.stop();
}

{ // #68 gate r2 P1: ownership comes from the VERDICT LINE ONLY. A genuine nonce-less answer
  // whose FINDINGS quote another run's marker (routine in this repo — reviews cite incident
  // markers verbatim) must NOT be convicted as cross-bound.
  const quotesAMarker = [
    `run marker: ${MARKER}`,
    '',
    '[P1] bin/x.mjs:10 — the pushbot#1334 incident (pg-run-StartupBros-com-pushbot-1334-1785810900-1553112) shows this',
    'P2: none',
    'P3: none',
    'VERDICT: FIX-FIRST — a real review that merely quotes a marker.',
  ].join('\n');
  const cdp = await mockCdp(quotesAMarker);
  const r = await runSalvage([MARKER, '15'], cdp.port);
  check('a finding QUOTING a foreign marker is not a cross-bind', (r.crossbound ?? 0) === 0,
    `crossbound=${r.crossbound} stderr=${r.stderr?.slice(-400)}`);
  check('the quoting review is returned, not convicted', r.status === 0,
    `status=${r.status} stderr=${r.stderr?.slice(-400)}`);
  cdp.stop();
}

{ // #68 gate r2 P2: a conviction is per-CANDIDATE. If another tab turns out to be genuinely
  // ours, the marker must not stay flagged terminally cross-bound.
  const foreignTab = { id: 'foreign1', url: 'https://chatgpt.com/c/foreign-one' };
  const ours = [
    `run marker: ${MARKER}`,
    '[P1] lib/y.sh:2 — ours',
    'P2: none',
    'P3: none',
    `VERDICT: SHIP — ours. (run marker: ${MARKER})`,
  ].join('\n');
  // The listed conversation tab is ours; an additional tab holds another run's answer.
  const cdp = await mockCdp(ours, [foreignTab]);
  const r = await runSalvage([MARKER, '15'], cdp.port);
  check('proving ownership clears any per-candidate conviction', (r.crossbound ?? 0) === 0,
    `crossbound=${r.crossbound} stderr=${r.stderr?.slice(-400)}`);
  check('our review is still returned alongside a foreign tab', r.status === 0, `status=${r.status}`);
  cdp.stop();
}

{ // #68 gate r3 P2: terminal cross-bound state must be ORDER-INDEPENDENT. Give each tab a
  // DIFFERENT body — one cross-bound, one genuinely ours — and assert the verdict is the same
  // whichever the scan happens to classify first. Writing mid-scan made this depend on /json
  // order, so a live review could be labelled STUCK purely by tab ordering.
  const oursBody = [
    `run marker: ${MARKER}`,
    '[P1] lib/z.sh:1 — ours',
    'P2: none',
    'P3: none',
    `VERDICT: SHIP — ours. (run marker: ${MARKER})`,
  ].join('\n');
  for (const foreignFirst of [true, false]) {
    // tab1 (listed first) carries one body; the extra tab carries the other. Swapping which
    // is which flips scan order without changing anything else.
    const first = foreignFirst ? FOREIGN_ANSWER(MARKER) : oursBody;
    const second = foreignFirst ? oursBody : FOREIGN_ANSWER(MARKER);
    const cdp = await mockCdp(first, [{ id: 't-second', url: 'https://chatgpt.com/c/tab-second' }],
      { tabText: () => second });
    const r = await runSalvage([MARKER, '15'], cdp.port);
    check(`cross-bound state is order-independent (foreignFirst=${foreignFirst}): not stuck`,
      (r.crossbound ?? 0) === 0, `crossbound=${r.crossbound} status=${r.status} stderr=${r.stderr?.slice(-300)}`);
    check(`our review is found regardless of order (foreignFirst=${foreignFirst})`,
      r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
    cdp.stop();
  }
}

{ // gate round-2 P1: one EARLY successful listing must not mask a later CDP outage. Scan once
  // (before the conversation appears), then lose Chrome for the rest of the window — that ends
  // inconclusive (7), not a confirmed absence (4).
  const cdp = await mockCdp('some other conversation, no marker here');
  setTimeout(() => cdp.stop(), 3_000);   // Chrome dies after the first successful scan
  const r = await runSalvage([MARKER, '30'], cdp.port);
  check('a later CDP outage is not masked by an early successful scan', r.status === 7, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
}

{ // gate round-2 P1: the remembered conversation's tab is LISTED but its renderer is dead, and
  // re-rendering it proves it carries another run's marker. blacklist() no-ops on a remembered
  // URL, and the seeded branch is skipped while the tab is listed — so staleness has to be
  // recorded here or the reservation sits "inconclusive" forever instead of releasing.
  const cdp = await mockCdp('', [], {   // '' => renderer returns nothing => dead tab
    renderText: () => 'run marker: pg-run-someone-else-2222222222-3\nanother review entirely',
  });
  const r = await runSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/mock-conversation'));
  check('a dead remembered tab proven foreign still exits 4', r.status === 4, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  cdp.stop();
}

{ // browser down for the whole window -> inconclusive (7), never "gone" (4): the engine's
  // miss counter must not advance on absence of evidence.
  const dead = await mockCdp('__NO_TABS__');
  const deadPort = dead.port;
  await new Promise((resolve) => dead.stop(resolve));
  const r = await runSalvage([MARKER, '3'], deadPort);
  check('CDP down exits 7 (inconclusive), not 4', r.status === 7, `status=${r.status} stderr=${r.stderr?.slice(0, 200)}`);
  check('inconclusive names the cause', /inconclusive/.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(0, 200)}`);
}

{ // nothing matches the marker -> exit 4 (foreign conversation left alone)
  const cdp = await mockCdp('run marker: pg-run-other-1111111111-7\nsomething else entirely');
  const r = await runSalvage([MARKER, '3'], cdp.port);
  check('no match exits 4', r.status === 4, `status=${r.status}`);
  check('foreign tab left open', cdp.closed.length === 0, `closed=${cdp.closed}`);
  cdp.stop();
}

{ // probe: marker match -> exit 0 immediately, no close
  const cdp = await mockCdp(`run marker: ${MARKER}\nstill thinking`);
  const r = await runSalvage(['--probe', MARKER, '10'], cdp.port);
  check('probe exits 0 on match', r.status === 0, `status=${r.status}`);
  check('probe never closes the source tab', !cdp.closed.includes('tab1'), `closed=${cdp.closed}`);
  // A conversation still being written occupies the account, so its reservation must keep its
  // slot. The state rides as a LINE, not an exit code: the no-think and pre-retry watchdogs read
  // rc 0 as "demonstrably live", and any other code would fall through them toward a retry
  // against an already-spent slot (#82).
  check('probe reports generating while no VERDICT has landed',
    /^probe-state: generating$/m.test(r.stderr || ''), `stderr=${(r.stderr || '').slice(0, 300)}`);
  cdp.stop();
}

{ // probe: a FINISHED review still probes as present forever (ChatGPT keeps conversations
  // server-side), which is exactly why presence alone must not hold account capacity (#82).
  const cdp = await mockCdp(`run marker: ${MARKER}\nP0: none\n\nVERDICT: SHIP — fine. (run marker: ${MARKER})`);
  const r = await runSalvage(['--probe', MARKER, '10'], cdp.port);
  check('probe still exits 0 when the review is complete', r.status === 0, `status=${r.status}`);
  check('probe reports complete once an owned VERDICT is present',
    /^probe-state: complete$/m.test(r.stderr || ''), `stderr=${(r.stderr || '').slice(0, 300)}`);
  cdp.stop();
}

{ // A VERDICT that does not belong to this run must never release its capacity: the reservation
  // would be freed while the account is still generating, overbooking the next run.
  const cdp = await mockCdp('run marker: pg-run-someone-else-1700000009-77\nVERDICT: SHIP — theirs.');
  const r = await runSalvage(['--probe', MARKER, '10'], cdp.port);
  check('foreign VERDICT never reports complete for our marker',
    !/^probe-state: complete$/m.test(r.stderr || ''), `status=${r.status} stderr=${(r.stderr || '').slice(0, 300)}`);
  cdp.stop();
}

{ // latest-scan semantics: the marker is seen, then a healthy /json reports no tabs.
  // The run must NOT claim "still generating" (3) off that stale sighting — that check still
  // holds. But it must not claim "gone" (4) either: v0.25 learned this conversation's URL from
  // the sighting, and a vanished TAB is not evidence about ChatGPT's server-side state. With no
  // budget left to re-render it decisively, the honest answer is inconclusive (7), which keeps
  // the reservation and counts no miss. Pre-v0.25 this asserted 4.
  const cdp = await mockCdp(`run marker: ${MARKER}\nstill thinking`);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-disappear-'));
  const child = spawn(process.execPath, [SALVAGE, MARKER, '3', String(cdp.port)], {
    env: { ...process.env, PRO_GATE_HOME: home },
  });
  let stderr = '';
  child.stderr.on('data', (d) => { stderr += d; });
  // First scan observes the marker; then a healthy target list proves the TAB disappeared.
  setTimeout(() => cdp.setText('__NO_TABS__'), 500);
  const status = await new Promise((resolve) => child.on('close', resolve));
  fs.rmSync(home, { recursive: true, force: true });
  check('a vanished tab is never reported as still-generating', status !== 3, `status=${status} stderr=${stderr.slice(0, 200)}`);
  check('a vanished tab is inconclusive, not "gone"', status === 7, `status=${status} stderr=${stderr.slice(0, 200)}`);
  cdp.stop();
}

{ // --sweep-root closes idle root tabs, keeps /c/ tabs, never empties Chrome
  const roots = [
    { id: 'root1', type: 'page', url: 'https://chatgpt.com/' },
    { id: 'root2', type: 'page', url: 'https://chatgpt.com/?model=gpt-5-5-pro' },
    { id: 'blank1', type: 'page', url: 'about:blank' },
  ];
  const cdp = await mockCdp(`run marker: ${MARKER}\nstill thinking`, roots);
  const r = await runSalvage(['--sweep-root', '-', '10'], cdp.port);
  check('sweep-root exits 0', r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(0, 200)}`);
  check('sweep-root closes only root tabs', cdp.closed.includes('root1') && cdp.closed.includes('root2'), `closed=${cdp.closed}`);
  check('sweep-root keeps conversation and blank tabs', !cdp.closed.includes('tab1') && !cdp.closed.includes('blank1'), `closed=${cdp.closed}`);
  cdp.stop();
}

{ // --sweep-root leaves one tab alive when roots are all Chrome has
  const roots = [
    { id: 'rootA', type: 'page', url: 'https://chatgpt.com/' },
    { id: 'rootB', type: 'page', url: 'https://chatgpt.com/' },
  ];
  const cdp = await mockCdp('__NO_TABS__', roots);
  const r = await runSalvage(['--sweep-root', '-', '10'], cdp.port);
  check('sweep-root keeps a survivor tab', r.status === 0 && cdp.closed.length === 1, `status=${r.status} closed=${cdp.closed}`);
  cdp.stop();
}

// ── v0.32: marker-owned conversation organization. These checks exercise the real CLI/CDP
// request path while the mock models only the UI's state transitions. A static innerText reply
// is no longer enough: request ids, rename state, archive state, and action ordering all matter.
{
  const title = 'pro-gate review: PR #71 r1 [pro-gate]';
  const cdp = await mockCdp(`run marker: ${MARKER}\nstill generating`);
  const r = await runSalvage(['--organize', MARKER, '5'], cdp.port, seedOrganizer(MARKER, title));
  check('organizer rename exits 0', r.status === 0, `status=${r.status} stderr=${r.stderr}`);
  check('organizer applies the exact title', cdp.ui.title === title, `title=${cdp.ui.title}`);
  check('rename-only organizer leaves the owned tab open', cdp.closed.length === 0, `closed=${cdp.closed}`);
  check('rename-only organizer never archives', !cdp.ui.archived, `ui=${JSON.stringify(cdp.ui)}`);
  check('organizer emits one bounded structured result',
    r.stdout.trim().split('\n').length === 1 &&
      /^organizer source=open rename=renamed archive=disabled close=skipped reason=ok$/.test(r.stdout.trim()),
    `stdout=${r.stdout}`);
  check('CDP mock decoded and echoed nonconstant request ids',
    new Set(cdp.requests.map((request) => request.id)).size > 1,
    `ids=${cdp.requests.map((request) => request.id).join(',')}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r2 [pro-gate]';
  const ui = { title, archived: false, events: [] };
  const cdp = await mockCdp(`run marker: ${MARKER}\ncomplete`, [], { ui });
  const r = await runSalvage(['--organize', MARKER, '5'], cdp.port, seedOrganizer(MARKER, title));
  check('an exact existing title is reported already', /rename=already/.test(r.stdout), `stdout=${r.stdout}`);
  check('an exact existing title causes no title mutation', ui.events.length === 0, `events=${JSON.stringify(ui.events)}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r2b [pro-gate]';
  const nonceLessAnswer = [
    `run marker: ${MARKER}`,
    '[P1] bin/x.mjs:1 — completed but unbound',
    'P2: none',
    'P3: none',
    'VERDICT: FIX-FIRST — marker echo omitted.',
  ].join('\n');
  const cdp = await mockCdp(nonceLessAnswer);
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(nonceLessAnswer, MARKER)),
  );
  check('nonce-less completed answers never grant organizer mutation authority',
    /reason=answer-marker-missing/.test(r.stdout), `stdout=${r.stdout}`);
  check('ambiguous completed ownership leaves title archive and tabs untouched',
    cdp.ui.events.length === 0 && !cdp.ui.archived && cdp.closed.length === 0,
    `ui=${JSON.stringify(cdp.ui)} closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r2c [pro-gate]';
  const oldScrollback = [
    '[P1] old/x.mjs:1 — old answer',
    'P2: none',
    'P3: none',
    'VERDICT: FIX-FIRST — old marker omitted.',
    `run marker: ${MARKER}`,
    'new answer still generating',
  ].join('\n');
  const cdp = await mockCdp(oldScrollback);
  const r = await runSalvage(['--organize', MARKER, '5'], cdp.port, seedOrganizer(MARKER, title));
  check('an old nonce-less verdict above the newest prompt does not block safe rename',
    /rename=renamed archive=disabled close=skipped reason=ok/.test(r.stdout), `stdout=${r.stdout}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r3 [pro-gate]';
  const ours = { id: 'ours2', url: 'https://chatgpt.com/c/ours-two' };
  const cdp = await mockCdp(FOREIGN_ANSWER(MARKER), [ours], {
    tabText: () => `run marker: ${MARKER}\nour model is still generating`,
  });
  const r = await runSalvage(['--organize', MARKER, '5'], cdp.port, seedOrganizer(MARKER, title));
  check('organizer selects a genuine owned tab beside a cross-bound tab', /rename=renamed/.test(r.stdout), `stdout=${r.stdout}`);
  check('organizer action targets only the genuine tab',
    cdp.ui.events.length === 1 && cdp.ui.events[0].id === 'ours2',
    `events=${JSON.stringify(cdp.ui.events)}`);
  check('organizer leaves the cross-bound tab open', !cdp.closed.includes('tab1'), `closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r4 [pro-gate]';
  const second = { id: 'oursB', url: 'https://chatgpt.com/c/ours-b' };
  const body = `run marker: ${MARKER}\nowned conversation`;
  const cdp = await mockCdp(body, [second], { tabText: () => body });
  const r = await runSalvage(['--organize', MARKER, '5'], cdp.port, seedOrganizer(MARKER, title));
  check('two distinct owned URLs fail closed as ambiguous', /reason=ambiguous-owned-targets/.test(r.stdout), `stdout=${r.stdout}`);
  check('ambiguity performs no UI action', cdp.ui.events.length === 0, `events=${JSON.stringify(cdp.ui.events)}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r5 [pro-gate]';
  const remembered = 'https://chatgpt.com/c/remembered-owned';
  const second = { id: 'remembered-tab', url: remembered };
  const body = `run marker: ${MARKER}\nowned conversation`;
  const cdp = await mockCdp(body, [second], { tabText: () => body });
  const r = await runSalvage(
    ['--organize', MARKER, '5'],
    cdp.port,
    seedOrganizer(MARKER, title, remembered),
  );
  check('remembered URL resolves multiple owned targets', /rename=renamed/.test(r.stdout), `stdout=${r.stdout}`);
  check('remembered URL is preferred exactly', cdp.ui.events[0]?.id === 'remembered-tab', `events=${JSON.stringify(cdp.ui.events)}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r6 [pro-gate]';
  const remembered = 'https://chatgpt.com/c/tabless-owned';
  const cdp = await mockCdp('__NO_TABS__', [], {
    renderText: () => `run marker: ${MARKER}\nserver-side conversation`,
  });
  const r = await runSalvage(
    ['--organize', MARKER, '5'],
    cdp.port,
    seedOrganizer(MARKER, title, remembered),
  );
  check('organizer recovers a tabless owned conversation from its memo', /source=memo rename=renamed/.test(r.stdout), `stdout=${r.stdout}`);
  check('rename-only memo recovery keeps its owned scratch renderer open',
    cdp.created.length === 1 && !cdp.closed.includes(cdp.created[0].id),
    `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r6b [pro-gate]';
  const remembered = 'https://chatgpt.com/c/tabless-finalized';
  const body = [
    `run marker: ${MARKER}`,
    'P0: none',
    'P1: none',
    'P2: none',
    'P3: none',
    `VERDICT: SHIP — owned. (run marker: ${MARKER})`,
  ].join('\n');
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => body });
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, remembered, durableReview(body, MARKER)),
  );
  check('authorized memo finalization archives and closes its owned scratch',
    /source=memo rename=renamed archive=archived close=closed reason=ok/.test(r.stdout),
    `stdout=${r.stdout}`);
  check('authorized finalization closes the accepted memo scratch exactly once',
    cdp.created.length === 1 && cdp.closed.filter((id) => id === cdp.created[0].id).length === 1,
    `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r7 [pro-gate]';
  const remembered = 'https://chatgpt.com/c/stale-owned';
  const cdp = await mockCdp('__NO_TABS__', [], {
    renderText: () => 'run marker: pg-run-different-1234567890-2\nforeign conversation',
  });
  const r = await runSalvage(
    ['--organize', MARKER, '5'],
    cdp.port,
    seedOrganizer(MARKER, title, remembered),
  );
  check('stale memo is rejected without mutation', /reason=stale-memo/.test(r.stdout) && cdp.ui.events.length === 0, `stdout=${r.stdout}`);
  check('stale memo scratch is closed', cdp.created.length === 1 && cdp.closed.includes(cdp.created[0].id), `closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r8 [pro-gate]';
  const body = completedReview(MARKER);
  const cdp = await mockCdp(`run marker: ${MARKER}\n${body}`);
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(body, MARKER)),
  );
  check('finalizer renames then archives then closes',
    /rename=renamed archive=archived close=closed reason=ok/.test(r.stdout),
    `stdout=${r.stdout}`);
  check('finalizer records ordered UI actions',
    cdp.ui.events.map((event) => event.action).join(',') === 'rename,archive',
    `events=${JSON.stringify(cdp.ui.events)}`);
  check('finalizer closes only its selected owned tab',
    cdp.closed.length === 1 && cdp.closed[0] === 'tab1',
    `closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r8a [pro-gate]';
  const newerMarker = 'pg-run-test-1234567891-43';
  const accepted = completedReview(MARKER);
  const reusedConversation = [
    `run marker: ${MARKER}`,
    accepted,
    '',
    `pro-gate review: PR #71 r9 [pro-gate]`,
    `(run marker: ${newerMarker})`,
    'newer review still generating',
  ].join('\n');
  const cdp = await mockCdp(reusedConversation);
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(accepted, MARKER)),
  );
  check('a newer exact run marker after the accepted verdict blocks finalization',
    /reason=newer-run-marker/.test(r.stdout), `stdout=${r.stdout}`);
  check('newer in-progress work prevents every older-run mutation and local close',
    cdp.ui.events.length === 0 && !cdp.ui.archived && cdp.closed.length === 0,
    `events=${JSON.stringify(cdp.ui.events)} closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r8aa [pro-gate]';
  const markerLookalike = 'xpg-run-test-1234567891-43';
  const accepted = completedReview(MARKER);
  const cdp = await mockCdp(`run marker: ${MARKER}\n${accepted}\nquoted ${markerLookalike}`);
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(accepted, MARKER)),
  );
  check('an embedded marker-like substring does not create a false freshness conflict',
    /archive=archived close=closed reason=ok/.test(r.stdout), `stdout=${r.stdout}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r8ab [pro-gate]';
  const newerMarker = 'pg-run-test-1234567892-44';
  const accepted = completedReview(MARKER);
  const owned = `run marker: ${MARKER}\n${accepted}`;
  const advanced = `${owned}\nrun marker: ${newerMarker}\nnewer review still generating`;
  const cdp = await mockCdp(owned, [], {
    primaryText: (initial, n) => (n >= 4 ? advanced : initial),
  });
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(accepted, MARKER)),
  );
  check('a newer marker appearing after rename blocks archive and close',
    /rename=renamed archive=skipped close=skipped reason=newer-run-marker/.test(r.stdout),
    `stdout=${r.stdout}`);
  check('freshness drift preserves the newer run after the already-dispatched rename',
    cdp.ui.events.map((event) => event.action).join(',') === 'rename' &&
      !cdp.ui.archived && cdp.closed.length === 0,
    `events=${JSON.stringify(cdp.ui.events)} closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r8b [pro-gate]';
  const duplicate = { id: 'same-url-duplicate', url: 'https://chatgpt.com/c/mock-conversation' };
  const body = [
    `run marker: ${MARKER}`,
    'P0: none',
    'P1: none',
    'P2: none',
    'P3: none',
    `VERDICT: SHIP — owned. (run marker: ${MARKER})`,
  ].join('\n');
  const cdp = await mockCdp(body, [duplicate], { tabText: () => body });
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(body, MARKER)),
  );
  check('same-URL owned duplicate tabs finalize successfully',
    /archive=archived close=closed reason=ok/.test(r.stdout), `stdout=${r.stdout}`);
  check('finalizer revalidates and closes every owned tab at the selected exact URL',
    cdp.closed.length === 2 && cdp.closed.includes('tab1') && cdp.closed.includes('same-url-duplicate'),
    `closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r8c [pro-gate]';
  const duplicate = { id: 'same-url-drifted', url: 'https://chatgpt.com/c/mock-conversation' };
  const owned = [
    `run marker: ${MARKER}`,
    'P0: none',
    'P1: none',
    'P2: none',
    'P3: none',
    `VERDICT: SHIP — owned. (run marker: ${MARKER})`,
  ].join('\n');
  const foreign = 'run marker: pg-run-other-1234567890-9\nforeign conversation';
  let duplicateReads = 0;
  const cdp = await mockCdp(owned, [duplicate], {
    tabText: (_url, id) => {
      if (id !== duplicate.id) return owned;
      duplicateReads += 1;
      return duplicateReads === 1 ? owned : foreign;
    },
  });
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(owned, MARKER)),
  );
  check('same-URL duplicate ownership drift blocks local cleanup',
    /close=failed reason=answer-incomplete/.test(r.stdout), `stdout=${r.stdout}`);
  check('duplicate ownership drift leaves every same-URL tab open',
    cdp.closed.length === 0, `closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r9 [pro-gate]';
  const body = completedReview(MARKER);
  const ui = { title: null, archived: true, events: [] };
  const unrelated = { id: 'root-unrelated', type: 'page', url: 'https://chatgpt.com/' };
  const cdp = await mockCdp(`run marker: ${MARKER}\n${body}`, [unrelated], { ui });
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(body, MARKER)),
  );
  check('already-archived state is idempotent', /archive=already close=closed/.test(r.stdout), `stdout=${r.stdout}`);
  check('finalization never closes an unrelated tab', !cdp.closed.includes('root-unrelated'), `closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r10 [pro-gate]';
  const body = completedReview(MARKER);
  const ui = {
    title: null,
    archived: false,
    events: [],
    archiveResult: { status: 'skipped', reason: 'archive-menu-item-not-found' },
  };
  const cdp = await mockCdp(`run marker: ${MARKER}\n${body}`, [], { ui });
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(body, MARKER)),
  );
  check('archive selector drift is reported once and remains nonfatal',
    /archive=skipped close=closed reason=archive-archive-menu-item-not-found/.test(r.stdout),
    `stdout=${r.stdout}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r11 [pro-gate]';
  const body = `run marker: ${MARKER}\n${completedReview(MARKER)}`;
  const foreign = 'run marker: pg-run-different-1234567890-4\nforeign conversation';
  const cdp = await mockCdp(body, [], {
    primaryText: (initial, n) => (n >= 4 ? foreign : initial),
  });
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(completedReview(MARKER), MARKER)),
  );
  check('ownership drift after rename blocks archive and close',
    /archive=skipped close=skipped reason=answer-incomplete/.test(r.stdout),
    `stdout=${r.stdout}`);
  check('ownership drift leaves the target recoverable', cdp.closed.length === 0 && !cdp.ui.archived, `closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r12 [pro-gate]';
  const body = completedReview(MARKER);
  const cdp = await mockCdp(`run marker: ${MARKER}\n${body}`);
  const r = await runSalvage(
    finalizerArgs(MARKER, { rename: false }),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(body, MARKER)),
  );
  check('rename suppression does not suppress archive or local cleanup',
    /rename=disabled archive=archived close=closed reason=ok/.test(r.stdout),
    `stdout=${r.stdout}`);
  check('rename suppression performs only the archive UI action',
    cdp.ui.events.map((event) => event.action).join(',') === 'archive',
    `events=${JSON.stringify(cdp.ui.events)}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r13 [pro-gate]';
  const body = `run marker: ${MARKER}\nstill generating`;
  const cdp = await mockCdp(body);
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(completedReview(MARKER), MARKER)),
  );
  check('finalization rejects a live same-marker page that rename would accept',
    /reason=answer-incomplete/.test(r.stdout), `stdout=${r.stdout}`);
  check('live finalization rejection performs no mutation or close',
    cdp.ui.events.length === 0 && cdp.closed.length === 0, `events=${JSON.stringify(cdp.ui.events)} closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r14 [pro-gate]';
  const rendered = completedReview(MARKER, 'rendered bytes');
  const durable = durableReview(completedReview(MARKER, 'different durable bytes'), MARKER);
  const cdp = await mockCdp(`run marker: ${MARKER}\n${rendered}`);
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, null, durable),
  );
  check('durable byte mismatch blocks finalization', /reason=result-mismatch/.test(r.stdout), `stdout=${r.stdout}`);
  check('byte mismatch leaves title archive and tab untouched',
    cdp.ui.events.length === 0 && !cdp.ui.archived && cdp.closed.length === 0,
    `events=${JSON.stringify(cdp.ui.events)} closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r15 [pro-gate]';
  const accepted = 'https://chatgpt.com/c/accepted-result';
  const live = `run marker: ${MARKER}\nstill generating`;
  const completed = `run marker: ${MARKER}\n${completedReview(MARKER)}`;
  const cdp = await mockCdp(live, [], { renderText: (url) => url === accepted ? completed : '' });
  const r = await runSalvage(
    finalizerArgs(MARKER, { acceptedUrl: accepted }),
    cdp.port,
    seedOrganizer(MARKER, title, null, durableReview(completedReview(MARKER), MARKER)),
  );
  check('accepted capture URL outranks a different live same-marker conversation',
    /source=memo rename=renamed archive=archived close=closed reason=ok/.test(r.stdout), `stdout=${r.stdout}`);
  check('accepted URL finalization leaves the unrelated live URL open',
    !cdp.closed.includes('tab1') && cdp.created[0]?.url === accepted, `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r16 [pro-gate]';
  const remembered = 'https://chatgpt.com/c/wrong-remembered-result';
  const first = `run marker: ${MARKER}\n${completedReview(MARKER)}`;
  const second = { id: 'second-result', url: 'https://chatgpt.com/c/second-result' };
  const cdp = await mockCdp(first, [second], { tabText: () => first });
  const r = await runSalvage(
    finalizerArgs(MARKER),
    cdp.port,
    seedOrganizer(MARKER, title, remembered, durableReview(completedReview(MARKER), MARKER)),
  );
  check('remembered URL cannot resolve multiple byte-matching finalizer URLs',
    /reason=ambiguous-owned-targets/.test(r.stdout), `stdout=${r.stdout}`);
  check('ambiguous finalizer performs no mutation', cdp.ui.events.length === 0, `events=${JSON.stringify(cdp.ui.events)}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r17 [pro-gate]';
  const remembered = 'https://chatgpt.com/c/should-not-open-under-throttle';
  const throttle = "You're making requests too quickly. Temporarily limited access to your conversations.";
  const cdp = await mockCdp(throttle);
  const r = await runSalvage(
    ['--organize', MARKER, '5'],
    cdp.port,
    seedOrganizer(MARKER, title, remembered),
  );
  check('organizer stops immediately when any scanned page is a throttle interstitial',
    /reason=throttle/.test(r.stdout), `stdout=${r.stdout}`);
  check('throttle evidence prevents remembered-URL scratch traffic',
    cdp.created.length === 0 && cdp.ui.events.length === 0, `created=${JSON.stringify(cdp.created)}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r17b [pro-gate]';
  const remembered = 'https://chatgpt.com/c/throttled-scratch';
  const throttle = "You're making requests too quickly. Temporarily limited access to your conversations.";
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => throttle });
  const r = await runSalvage(
    ['--organize', MARKER, '5'],
    cdp.port,
    seedOrganizer(MARKER, title, remembered),
  );
  check('scratch-render throttle evidence stops organization',
    /reason=throttle/.test(r.stdout) && cdp.ui.events.length === 0,
    `stdout=${r.stdout} events=${JSON.stringify(cdp.ui.events)}`);
  check('scratch-render throttle evidence writes the account cooldown before returning',
    /organizer scratch/.test(r.cooldown ?? ''), `cooldown=${r.cooldown}`);
  check('throttled organizer scratch is closed',
    cdp.created.length === 1 && cdp.closed.includes(cdp.created[0].id),
    `created=${JSON.stringify(cdp.created)} closed=${cdp.closed}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r18 [pro-gate]';
  const ui = { title: null, archived: false, events: [], renameDelayMs: 300 };
  const cdp = await mockCdp(`run marker: ${MARKER}\nstill generating`, [], { ui });
  const startedAt = Date.now();
  const r = await runSalvage(
    ['--organize', MARKER, '5'],
    cdp.port,
    seedOrganizer(MARKER, title),
    {
      PRO_GATE_TEST_MUTATION_EVALUATE_MS: '100',
      PRO_GATE_TEST_MUTATION_LEASE_MS: '250',
    },
  );
  const elapsedMs = Date.now() - startedAt;
  await new Promise((resolve) => setTimeout(resolve, 100));
  check('timed-out UI mutation reports failure after revocation and absolute lease expiry',
    elapsedMs >= 225 &&
    /rename=failed.*reason=rename-evaluate-failed/.test(r.stdout) &&
      cdp.requests.some((request) => request.params?.expression?.includes('pro-gate-organizer:cancel')),
    `stdout=${r.stdout} requests=${cdp.requests.length}`);
  check('positively cancelled renderer work cannot mutate after its CDP timeout',
    ui.events.length === 0 && ui.title === null, `ui=${JSON.stringify(ui)}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r18b [pro-gate]';
  const ui = {
    title: null,
    archived: false,
    events: [],
    renameDelayMs: 300,
    armMutationAfterDelay: true,
  };
  const cdp = await mockCdp(`run marker: ${MARKER}\nstill generating`, [], { ui });
  const startedAt = Date.now();
  const r = await runSalvage(
    ['--organize', MARKER, '5'],
    cdp.port,
    seedOrganizer(MARKER, title),
    {
      PRO_GATE_TEST_MUTATION_EVALUATE_MS: '100',
      PRO_GATE_TEST_MUTATION_LEASE_MS: '250',
    },
  );
  const elapsedMs = Date.now() - startedAt;
  await new Promise((resolve) => setTimeout(resolve, 100));
  check('cancellation-before-arm holds serialization through the absolute lease expiry',
    elapsedMs >= 225 && /reason=rename-evaluate-failed/.test(r.stdout),
    `elapsedMs=${elapsedMs} stdout=${r.stdout}`);
  check('a queued expression cannot arm and mutate after its token was revoked',
    ui.events.length === 0 && ui.title === null, `ui=${JSON.stringify(ui)}`);
  cdp.stop();
}

{
  const title = 'pro-gate review: PR #71 r19 [pro-gate]';
  const ui = {
    title: null,
    archived: false,
    events: [],
    renameDelayMs: 300,
    cancelUnconfirmed: true,
  };
  const cdp = await mockCdp(`run marker: ${MARKER}\nstill generating`, [], { ui });
  const startedAt = Date.now();
  const r = await runSalvage(
    ['--organize', MARKER, '5'],
    cdp.port,
    seedOrganizer(MARKER, title),
    {
      PRO_GATE_TEST_MUTATION_EVALUATE_MS: '100',
      PRO_GATE_TEST_MUTATION_LEASE_MS: '250',
    },
  );
  const elapsedMs = Date.now() - startedAt;
  await new Promise((resolve) => setTimeout(resolve, 100));
  check('unconfirmed cancellation holds the organizer through absolute lease expiry',
    elapsedMs >= 225 && /reason=rename-evaluate-failed/.test(r.stdout),
    `elapsedMs=${elapsedMs} stdout=${r.stdout}`);
  check('expired renderer work cannot mutate after cancellation acknowledgement is lost',
    ui.events.length === 0 && ui.title === null, `ui=${JSON.stringify(ui)}`);
  cdp.stop();
}

{
  const cdp = await mockCdp('__NO_TABS__');
  const r = await runSalvage(['--organize', MARKER, '5'], cdp.port, seedOrganizer(MARKER, 'unused'));
  check('an operational organizer failure still exits 0', r.status === 0, `status=${r.status}`);
  check('an operational organizer failure emits exactly one structured line',
    r.stdout.trim().split('\n').length === 1 && /reason=owned-target-not-found$/.test(r.stdout.trim()),
    `stdout=${r.stdout} stderr=${r.stderr}`);
  cdp.stop();
}

{
  const dangerousTitle = 'pro-gate review: PR #71 r13 [repo "quoted" \\ literal]';
  const target = {
    marker: MARKER,
    conversationUrl: 'https://chatgpt.com/c/mock-conversation',
    mutationToken: 'test-token.1',
    mutationExpiresAt: Date.now() + ORGANIZER_MUTATION_LEASE_MS,
  };
  const renameExpression = buildRenameConversationExpression(dangerousTitle, target);
  const archiveExpression = buildArchiveConversationExpression(target);
  const cancelExpression = buildCancelOrganizerMutationExpression(
    MARKER,
    target.mutationToken,
    target.mutationExpiresAt,
  );
  check('rename expression serializes the exact title as data',
    expectedTitleFromExpression(renameExpression) === dangerousTitle,
    `expression=${renameExpression.slice(0, 160)}`);
  check('organizer expressions contain no ChatGPT backend API path',
    !/backend-api|XMLHttpRequest|\bfetch\s*\(/i.test(`${renameExpression}\n${archiveExpression}\n${cancelExpression}`));
  check('UI mutations carry an expiring browser lease and a revocation tombstone',
    /mutationLeaseActive/.test(renameExpression) &&
      /guardedDispatch/.test(renameExpression) &&
      /pro-gate-organizer:cancel/.test(cancelExpression) &&
      /revocations\[mutationToken\] = mutationExpiresAt/.test(cancelExpression) &&
      /current\.revoked = true/.test(cancelExpression) &&
      /revocationRegistry\[mutationToken\]/.test(renameExpression) &&
      /mutationRevokedBeforeStart/.test(renameExpression) &&
      /priorMutationLease/.test(renameExpression));
  check('mutation lease expires before the CDP mutation deadline', ORGANIZER_MUTATION_LEASE_MS < 15_000);
  check('rename expression uses native input state and exact verification',
    /HTMLInputElement\.prototype/.test(renameExpression) && /status: 'already'/.test(renameExpression));
  check('organizer scopes the rendered sidebar menu to the exact conversation URL',
    /expectedConversationPath/.test(renameExpression) &&
      /findSidebarConversationLink/.test(renameExpression) &&
      /new URL\(href, location\.href\)\.pathname === expectedConversationPath/.test(renameExpression) &&
      /ensureSidebarMenuButton/.test(renameExpression) &&
      /findOpenSidebarButton/.test(renameExpression));
  check('inline ChatGPT title editors commit through the rendered keyboard path',
    /input\[name="title-editor"\]/.test(renameExpression) &&
      /commitInlineRename/.test(renameExpression) &&
      /key: 'Enter'/.test(renameExpression));
  check('exact sidebar title short-circuits a second editor open',
    /sidebarTitle === expected/.test(renameExpression) &&
      /editor\.already/.test(renameExpression) &&
      /verification\.already/.test(renameExpression));
  check('browser-side ownership rejects a terminal verdict without an exact marker echo',
    /target-answer-marker-missing/.test(renameExpression) &&
      /expectedFinalReview === null[\s\S]*verdictAt > ownMarkerAt/.test(renameExpression));
  check('browser-side finalization rejects any newer exact run marker',
    /lastExactRunMarkerAt/.test(renameExpression) &&
      /matchAll\(\/pg-run-\[A-Za-z0-9.-\]\+\/g\)/.test(renameExpression) &&
      /target-newer-run-marker/.test(renameExpression));
  check('archive expression excludes destructive and reverse actions',
    /label\.includes\('delete'\)/.test(archiveExpression) &&
      /label\.includes\('unarchive'\)/.test(archiveExpression) &&
      /label\.includes\('restore'\)/.test(archiveExpression));
  check('archive expression verifies confirmation rather than trusting a click',
    /verifyArchivedStateFromMenu/.test(archiveExpression) && /hasArchiveToast/.test(archiveExpression));
  check('UI mutation ownership accepts the same formatted VERDICT labels as salvage',
    /\[\*_>#-\]/.test(renameExpression) && /VERDICT\[\*_\\s\]/.test(renameExpression));
}

{ // #76: the exit hook must actually RUN on the early-exit paths, not just leave a 0 status.
  // It was registered above the `const`/`let` state it reads, so --sweep-root and --close died
  // in the temporal dead zone ("Cannot access 'ownershipProven' before initialization") AFTER
  // process.exit had already fixed the status. Both --sweep-root tests above stayed green
  // through it, because the crash only reaches stderr. So assert the flush's EFFECT: a stale
  // conviction from an earlier run must be cleared, which only happens if flushCrossBind ran.
  const stale = '2026-01-01T00:00:00.000Z\thttps://chatgpt.com/c/other\tpg-run-someone-else\n';
  const seedStale = (home) => {
    fs.mkdirSync(path.join(home, 'crossbound'), { recursive: true });
    fs.writeFileSync(path.join(home, 'crossbound', MARKER), stale);
  };
  for (const mode of ['--sweep-root', '--close']) {
    const cdp = await mockCdp(`run marker: ${MARKER}\nstill thinking`,
      [{ id: 'root1', type: 'page', url: 'https://chatgpt.com/' }]);
    const r = await runSalvage([mode, MARKER, '10'], cdp.port, seedStale);
    check(`${mode} exits without a temporal-dead-zone crash`,
      !/ReferenceError/.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(0, 300)}`);
    check(`${mode} still runs the exit flush and clears a stale conviction`,
      r.crossbound === 0, `crossbound=${r.crossbound} stderr=${r.stderr?.slice(0, 300)}`);
    cdp.stop();
  }
}

process.exit(failures === 0 ? 0 : 1);
