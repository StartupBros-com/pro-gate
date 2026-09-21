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
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';
import { runInNewContext } from 'node:vm';

import {
  buildArchiveConversationExpression,
  buildCancelOrganizerMutationExpression,
  buildRenameConversationExpression,
  buildThrottleModalExpression,
  ORGANIZER_MUTATION_LEASE_MS,
} from '../bin/cdp-organizer-expressions.mjs';
import {
  parseTestPollMs,
  TEST_POLL_MS_MIN,
  TEST_POLL_MS_MAX,
  parseTestRenderSampleMs,
  TEST_RENDER_SAMPLE_MS_MIN,
  TEST_RENDER_SAMPLE_MS_MAX,
} from '../bin/cdp-test-timing.mjs';

const SALVAGE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'cdp-salvage.mjs');
const LIBRARY = path.join(path.dirname(SALVAGE), '..', 'lib', 'pro-gate-lib.sh');
const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function bindCapture(bytes, marker) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-dom-bind-'));
  const capture = path.join(home, 'capture.txt');
  fs.writeFileSync(capture, bytes);
  const result = spawnSync(
    'bash',
    ['-c', '. "$1"; pg_capture_bind "$2" "$3"', 'browser-capture-fixture', LIBRARY, capture, marker],
    {
      env: { ...process.env, PRO_GATE_HOME: home },
      encoding: 'utf8',
    },
  );
  if (result.stderr) process.stderr.write(result.stderr);
  const retained = fs.readFileSync(capture, 'utf8');
  fs.rmSync(home, { recursive: true, force: true });
  return { ...result, retained };
}

// A small rendered control fixture for executing the real independent mutation expression.
// Drift happens after its first ownership check, when it discovers the sidebar menu control.
function organizerExpressionFixture(
  body,
  { document = null, driftText = null, title = 'unchanged title' } = {},
) {
  const events = [];
  let currentText = body;
  let sidebarReads = 0;
  class Element {
    getBoundingClientRect() {
      return { width: 20, height: 20, left: 0, top: 0, right: 20 };
    }
    getAttribute(name) {
      return name === 'aria-label' ? 'Open conversation options' : null;
    }
    dispatchEvent(event) {
      events.push(event.type);
    }
  }
  const button = new Element();
  const row = { querySelectorAll: () => [button] };
  const link = new Element();
  link.getAttribute = (name) => (name === 'href' ? '/c/mock-conversation' : null);
  link.closest = () => row;
  link.textContent = title;
  const fixtureDocument = document ?? {
    body: {
      get innerText() {
        return currentText;
      },
    },
  };
  const priorQuery = fixtureDocument.querySelectorAll?.bind(fixtureDocument);
  fixtureDocument.querySelectorAll = (selector) => {
    if (selector === '[data-message-author-role]') return priorQuery?.(selector) ?? [];
    if (selector === 'a[href]') {
      sidebarReads += 1;
      if (driftText !== null) currentText = driftText;
      return [link];
    }
    return [];
  };
  fixtureDocument.dispatchEvent = (event) => events.push(event.type);
  class FixtureEvent {
    constructor(type) {
      this.type = type;
    }
  }
  return {
    events,
    sidebarReads: () => sidebarReads,
    context: {
      document: fixtureDocument,
      location: { href: 'https://chatgpt.com/c/mock-conversation' },
      window: { innerWidth: 1200 },
      URL,
      setTimeout,
      HTMLElement: Element,
      HTMLInputElement: Element,
      getComputedStyle: () => ({ visibility: 'visible', display: 'block' }),
      MouseEvent: FixtureEvent,
      KeyboardEvent: FixtureEvent,
      InputEvent: FixtureEvent,
      Event: FixtureEvent,
    },
  };
}

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
  const httpRequests = [];         // request-order proof for scratch open/list/close cleanup
  const ui = opts.ui ?? { title: null, archived: false, events: [] };
  ui.events ??= [];
  const mutationTokens = new Map();
  const mutationExpiries = new Map();
  const revokedMutationTokens = new Set();
  let primaryPolls = 0;
  let primaryDomPolls = 0;
  let jsonListCalls = 0;   // All /json hits, retained for pass 5's production-vs-fast contrast.
  let successfulJsonListCalls = 0;
  let outerJsonListCalls = 0;   // Lists made when no disposable scratch target is open.
  let scratchJsonListCalls = 0; // Lists that observe an open scratch target during its render.
  const jsonListEvents = [];
  const trackCdpDeadlineEvents = opts.trackCdpDeadlineEvents === true;
  let stoppedAfterPrimaryDomPoll = null;
  let stopped = false;
  let server = null;
  const stop = (cb) => {
    if (stopped || !server?.listening) {
      if (cb) queueMicrotask(cb);
      return;
    }
    stopped = true;
    server.close(cb);
  };
  server = createServer((req, res) => {
    httpRequests.push(`${req.method} ${req.url}`);
    if (req.url === '/json/version') { res.end(JSON.stringify({ Browser: 'MockChrome/1.0' })); return; }
    if (req.url?.startsWith('/json/new')) {
      const port = server.address().port;
      const url = decodeURIComponent(req.url.slice(req.url.indexOf('?') + 1));
      // opts.putNewFails models a pre-v111 Chrome, which has no PUT /json/new and answers with a
      // plain-text (non-JSON) error instead — the exact shape that used to make
      // fetchJsonBeforeDeadline's unconditional response.json() throw before the caller ever
      // reached its own response.ok check and tried the documented GET fallback below.
      if (opts.putNewFails && req.method === 'PUT') {
        res.statusCode = 404;
        res.end('Not Found (pre-v111 Chrome has no PUT /json/new)');
        return;
      }
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
      jsonListCalls += 1;
      const scratchOpen = created.some((t) => !closed.includes(t.id));
      const listSource = scratchOpen ? 'scratch' : 'outer';
      if (opts.hangScratchList && scratchOpen) return;
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
      if (opts.failScratchList && scratchOpen) {
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
      const listed = tabText === '__NO_TABS__' || closed.includes('tab1')
        ? [...extras, ...scratch]
        : [{
          id: 'tab1', type: 'page', url: 'https://chatgpt.com/c/mock-conversation',
          webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/tab1`,
        }, ...extras, ...scratch];
      res.end(JSON.stringify(listed));
      // Only shortened deadline fixtures opt into these diagnostic events. Ordinary fixtures keep
      // the original mock's hot request path and only retain jsonListCalls for pass 5's contrast.
      if (trackCdpDeadlineEvents) {
        successfulJsonListCalls += 1;
        if (listSource === 'scratch') scratchJsonListCalls += 1;
        else outerJsonListCalls += 1;
        jsonListEvents.push({
          count: successfulJsonListCalls,
          source: listSource,
          tabIds: listed.map((tab) => tab.id),
        });
      }
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
      // #215 gate r7 P2: a synchronous window INSIDE the child's scan. The hook runs before this
      // evaluate is answered, so anything it does to PRO_GATE_HOME is on disk strictly before the
      // child can act on the response — the only way a test can model another writer touching the
      // sidecar mid-scan without a second salvage process.
      opts.onEvaluate?.(id, request.params?.expression ?? '');
      let value = tabText;
      if (id === 'tab1' && opts.primaryText) {
        primaryPolls += 1;
        value = opts.primaryText(tabText, primaryPolls) ?? value;
      }
      // opts.tabText lets a test give LISTED tabs distinct bodies (tab id or url -> text);
      // without it every listed tab serves the same text, which cannot express "one tab is
      // ours and another is foreign" — the shape #68's ordering regression needs.
      if (extra && opts.tabText) value = opts.tabText(extra.url, extra.id) ?? value;
      const expression = request.params?.expression ?? '';
      // A scratch "sample" is one DOM text read. The salvage also evaluates element probes
      // (terminal-infrastructure, throttle-modal) against the same target each poll; those are
      // answered by sentinel below and must not advance the ordered sample count fixtures assert.
      // #162: gate on the page-text read itself. This predicate was `=== 'document.body.innerText'`
      // when it was written; tabText has since moved to the pro-gate:review-text expression, which
      // made the gate dead — renderText stopped firing at all and every scratch fixture served the
      // listed tab's body instead of its own. Match what tabText actually sends, so adding a new
      // element probe still cannot advance the count.
      if (scratch && opts.renderText && expression.includes('pro-gate:review-text')) {
        const n = (pollsByTab.get(id) ?? 0) + 1;
        pollsByTab.set(id, n);
        value = opts.renderText(scratch.url, n);
      }
      let delayMs = 0;
      let armMutation = null;
      let applyMutation = null;
      if (expression.includes('pro-gate:review-text') && opts.document) {
        value = runInNewContext(expression, { document: opts.document });
      } else if (expression.includes('pro-gate:terminal-infrastructure')) {
        value = opts.infrastructureError ?? null;
      } else if (expression.includes('pro-gate:throttle-modal')) {
        // #162: an ELEMENT read distinct from the page text. With no fixture value the evaluator
        // sees no dialog — never the body — so quoted throttle copy cannot leak into a match.
        value = typeof opts.throttleModal === 'function'
          ? (opts.throttleModal(id, scratch?.url ?? extra?.url ?? 'https://chatgpt.com/c/mock-conversation') ?? null)
          : (opts.throttleModal ?? null);
      } else if (expression.includes('pro-gate-organizer:rename')) {
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
      const primaryDomPoll = id === 'tab1' && request.method === 'Runtime.evaluate' &&
        expression.includes('pro-gate:review-text');
      const response = () => {
        if (armLate) armMutation();
        applyMutation?.();
        socket.write(wsTextFrame(JSON.stringify({
          id: request.id,
          result: { result: { value } },
        })));
        // Pass 7's later-outage fixture may stop only after the child consumed the successful
        // outer list enough to issue the listed primary tab's DOM poll. Scheduling after the
        // response is written preserves that successful-read-before-outage ordering.
        if (primaryDomPoll) {
          primaryDomPolls += 1;
          const stopAfter = Number(opts.stopAfterPrimaryDomPoll);
          if (
            Number.isInteger(stopAfter) && stopAfter >= 1 &&
            stoppedAfterPrimaryDomPoll === null && primaryDomPolls >= stopAfter &&
            outerJsonListCalls >= 1
          ) {
            stoppedAfterPrimaryDomPoll = primaryDomPolls;
            queueMicrotask(() => stop());
          }
        }
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
    httpRequests,
    ui,
    get jsonListCalls() { return jsonListCalls; },
    get successfulJsonListCalls() { return successfulJsonListCalls; },
    get outerJsonListCalls() { return outerJsonListCalls; },
    get scratchJsonListCalls() { return scratchJsonListCalls; },
    get primaryDomPolls() { return primaryDomPolls; },
    get jsonListEvents() { return jsonListEvents.map((event) => ({ ...event, tabIds: [...event.tabIds] })); },
    get stoppedAfterPrimaryDomPoll() { return stoppedAfterPrimaryDomPoll; },
    setText: (value) => {
      if (value !== tabText) {
        const closedAt = closed.indexOf('tab1');
        if (closedAt >= 0) closed.splice(closedAt, 1);
      }
      tabText = value;
    },
    stop,
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
    const childEnv = { ...process.env, PRO_GATE_HOME: home, ...extraEnv };
    // Explicit undefined removes an inherited environment key for boundary tests. It lets a test
    // prove the child has no test mode at all instead of merely replacing it with another string.
    for (const [name, value] of Object.entries(childEnv)) {
      if (value === undefined) delete childEnv[name];
    }
    const child = spawn(process.execPath, [SALVAGE, ...expandedArgs, String(port)], {
      env: childEnv,
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
      // #170: a line COUNT cannot tell a retained conviction from one this run rewrote — both
      // are "> 0". The sidecar's second field is the conversation URL and, after a conviction
      // deleted conversation-urls/<marker>, the only surviving copy of it, so tests that care
      // about survival compare the exact bytes.
      const crossboundBody = (() => {
        try {
          return fs.readdirSync(path.join(home, 'crossbound'))
            .map((f) => read(path.join('crossbound', f)) ?? '').join('');
        } catch { return ''; }
      })();
      fs.rmSync(home, { recursive: true, force: true });
      resolve({
        status, stdout, stderr, elapsedMs: Date.now() - startedAt,
        memoUrl: memoUrl?.trim() ?? null, memos, blacklist, cooldown, crossbound, crossboundBody,
      });
    });
  });
}

// #208: a repeat-sighting test needs the SAME PRO_GATE_HOME across two salvage invocations, so the
// second run's throttle-seen dedupe can see what the first run recorded — runSalvage's per-call
// mkdtempSync-then-rmSync home cannot express that. This runs the same child machinery against a
// caller-supplied home and leaves it (and any files inside it, e.g. throttle.cooldown's mtime) in
// place afterward; the caller owns cleanup via fs.rmSync.
function runSalvageInHome(home, args, port, extraEnv = {}) {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    const expandedArgs = args.map((arg) => arg.replace(/^PG_HOME\//, `${home}/`));
    const childEnv = { ...process.env, PRO_GATE_HOME: home, ...extraEnv };
    for (const [name, value] of Object.entries(childEnv)) {
      if (value === undefined) delete childEnv[name];
    }
    const child = spawn(process.execPath, [SALVAGE, ...expandedArgs, String(port)], {
      env: childEnv,
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    const killer = setTimeout(() => child.kill('SIGKILL'), Number(extraEnv.PRO_GATE_TEST_CHILD_TIMEOUT_MS ?? 90_000));
    child.on('close', (status) => {
      clearTimeout(killer);
      const read = (rel) => { try { return fs.readFileSync(path.join(home, rel), 'utf8'); } catch { return null; } };
      resolve({
        status, stdout, stderr, elapsedMs: Date.now() - startedAt,
        cooldown: read('throttle.cooldown'),
      });
    });
  });
}

// #208 gate r2 P2: production replaced the single throttle.cooldown.seen FILE (loaded once per
// invocation and rewritten wholesale — the exact shared-mutable-state race #208 gate r2 P2
// closes) with one record file per (url, hash) fingerprint in a DIRECTORY, created via
// fs.writeFileSync(path, '', { flag: 'wx' }) so a concurrent writer can never clobber another's
// sighting. These three helpers mirror throttleSeenRecordPath/throttleAlreadyCharged/
// recordThrottleSeen in bin/cdp-salvage.mjs byte-for-byte (same hash-of-url-and-hash key), so
// tests read and seed the SAME on-disk shape production does, not a second test-only format.
const throttleSeenDir = (home) => path.join(home, 'throttle.cooldown.seen.d');
const throttleSeenRecordPath = (home, url, text) => {
  const hash = createHash('sha256').update(text ?? '').digest('hex');
  const key = createHash('sha256').update(`${url}\n${hash}`).digest('hex');
  return path.join(throttleSeenDir(home), key);
};
const throttleSeenHas = (home, url, text) => fs.existsSync(throttleSeenRecordPath(home, url, text));
const seedThrottleSeen = (home, url, text) => {
  fs.mkdirSync(throttleSeenDir(home), { recursive: true });
  fs.writeFileSync(throttleSeenRecordPath(home, url, text), '', { flag: 'wx' });
};

// Deliberately opt in only scratch fixtures that need it: hydration/order checks, hung-close
// cleanup, and static decisive 3s canonical revalidations. The latter have no required first/second
// state transition; their old 2.5s sample left only 500ms of scheduler slack before the assertion.
// The override is merged into the spawned child alone; this test process and all regular salvage
// fixtures keep their inherited environment.
const SCRATCH_SAMPLE_TEST_ENV = Object.freeze({
  PRO_GATE_TEST_MODE: 'ci-fixture',
  PRO_GATE_TEST_RENDER_SAMPLE_MS: String(TEST_RENDER_SAMPLE_MS_MIN),
});
function runScratchSalvage(args, port, seed, extraEnv = {}) {
  return runSalvage(args, port, seed, { ...extraEnv, ...SCRATCH_SAMPLE_TEST_ENV });
}

// Pass 7's deadline fixtures opt in by semantic class, never through the parent environment or
// every salvage child. Fast polling preserves multiple main-list observations inside a short
// deadline; fast scratch sampling preserves ordered render observations when that fixture needs
// them before the same deadline arrives.
const FAST_POLL_TEST_ENV = Object.freeze({
  PRO_GATE_TEST_MODE: 'ci-fixture',
  PRO_GATE_TEST_POLL_MS: String(TEST_POLL_MS_MIN),
});
const FAST_CDP_DEADLINE_TEST_ENV = Object.freeze({
  ...FAST_POLL_TEST_ENV,
  PRO_GATE_TEST_RENDER_SAMPLE_MS: String(TEST_RENDER_SAMPLE_MS_MIN),
});
function runFastPollSalvage(args, port, seed, extraEnv = {}) {
  return runSalvage(args, port, seed, { ...extraEnv, ...FAST_POLL_TEST_ENV });
}
function runFastCdpDeadlineSalvage(args, port, seed, extraEnv = {}) {
  return runSalvage(args, port, seed, { ...extraEnv, ...FAST_CDP_DEADLINE_TEST_ENV });
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
// #167: mirrors bin/cdp-salvage.mjs's asciiFold. The engine's pg_strip_nonce and the browser-side
// stripMarkerEcho both remove the echo case-insensitively, so this test-side reimplementation must
// too — otherwise a lowercased-echo fixture would produce durable bytes the finalizer's own strip
// disagrees with, and the fixture would fail as result-mismatch for a reason that is not the code.
const testAsciiFold = (value) => String(value ?? '').replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
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
  const token = `(run marker: ${marker})`;
  const foldedToken = testAsciiFold(token);
  return lines.slice(start, verdict + 1).map((line) => {
    const at = testAsciiFold(line).indexOf(foldedToken);
    return at < 0 ? line : `${line.slice(0, at)}${line.slice(at + token.length)}`;
  }).join('\n')
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

// Deadline fixtures use this test-private proof so a shorter test deadline never turns an
// ordered scratch render into a single lucky sample. The mock supplies 1-based sample counts.
function hasConsecutiveSamples(samples, minimum) {
  return samples.length >= minimum && samples.every((sample, index) => sample === index + 1);
}

const MARKER = 'pg-run-test-1234567890-42';
// #167: a marker embeds ROUND_KEY, which preserves letter case from owner/repo text
// ("pg-run-StartupBros-com-pro-gate-166-..."). Fixtures that vary the ECHO's case need a marker
// whose case can actually vary — MARKER is already all-lowercase and cannot express the bug.
const MIXED_MARKER = 'pg-run-Test-Case-1234567890-43';

{ // Direct poll-parser boundary coverage (bin/cdp-test-timing.mjs), called in-process — no spawn. Every
  // one of these is real production input shape: an unset/empty/malformed
  // PRO_GATE_TEST_POLL_MS must fall back to cdp-salvage.mjs's own literal 20_000, never this
  // parser's return value, so `null` here is the only value that preserves that default.
  check('parseTestPollMs: unset (undefined) is rejected', parseTestPollMs(undefined) === null);
  check('parseTestPollMs: empty string is rejected', parseTestPollMs('') === null);
  check('parseTestPollMs: "0" is rejected', parseTestPollMs('0') === null);
  check('parseTestPollMs: negative is rejected', parseTestPollMs('-50') === null);
  check('parseTestPollMs: non-numeric is rejected', parseTestPollMs('abc') === null);
  check('parseTestPollMs: fractional form is rejected', parseTestPollMs('100.5') === null);
  check('parseTestPollMs: whitespace-padded form is rejected', parseTestPollMs(' 100 ') === null);
  check('parseTestPollMs: leading-zero form is rejected', parseTestPollMs('0100') === null);
  check('parseTestPollMs: leading-zero at the minimum is rejected',
    parseTestPollMs(`0${TEST_POLL_MS_MIN}`) === null);
  check('parseTestPollMs: a non-string input type is rejected', parseTestPollMs(100) === null);
  check('parseTestPollMs: below the minimum bound is rejected',
    parseTestPollMs(String(TEST_POLL_MS_MIN - 1)) === null);
  check('parseTestPollMs: above the maximum bound is rejected',
    parseTestPollMs(String(TEST_POLL_MS_MAX + 1)) === null);
  check('parseTestPollMs: the maximum bound equals production POLL_MS', TEST_POLL_MS_MAX === 20_000);
  check('parseTestPollMs: the exact minimum bound is honored',
    parseTestPollMs(String(TEST_POLL_MS_MIN)) === TEST_POLL_MS_MIN);
  check('parseTestPollMs: the exact maximum bound is honored',
    parseTestPollMs(String(TEST_POLL_MS_MAX)) === TEST_POLL_MS_MAX);
  check('parseTestPollMs: a valid mid-range value is honored',
    parseTestPollMs('5000') === 5_000);
  check('parseTestPollMs: a valid value can only ever shorten, never extend, the cadence',
    parseTestPollMs(String(TEST_POLL_MS_MAX)) <= 20_000);
}

{ // Direct render-parser boundary coverage (bin/cdp-test-timing.mjs), called in-process — no spawn.
  // A null result makes cdp-salvage.mjs retain its literal 2_500ms production sample interval.
  check('parseTestRenderSampleMs: unset (undefined) is rejected', parseTestRenderSampleMs(undefined) === null);
  check('parseTestRenderSampleMs: empty string is rejected', parseTestRenderSampleMs('') === null);
  check('parseTestRenderSampleMs: "0" is rejected', parseTestRenderSampleMs('0') === null);
  check('parseTestRenderSampleMs: negative is rejected', parseTestRenderSampleMs('-50') === null);
  check('parseTestRenderSampleMs: non-numeric is rejected', parseTestRenderSampleMs('abc') === null);
  check('parseTestRenderSampleMs: fractional form is rejected', parseTestRenderSampleMs('100.5') === null);
  check('parseTestRenderSampleMs: whitespace-padded form is rejected', parseTestRenderSampleMs(' 100 ') === null);
  check('parseTestRenderSampleMs: leading-zero form is rejected', parseTestRenderSampleMs('050') === null);
  check('parseTestRenderSampleMs: a non-string input type is rejected', parseTestRenderSampleMs(100) === null);
  check('parseTestRenderSampleMs: below the minimum bound is rejected',
    parseTestRenderSampleMs(String(TEST_RENDER_SAMPLE_MS_MIN - 1)) === null);
  check('parseTestRenderSampleMs: above the maximum bound is rejected',
    parseTestRenderSampleMs(String(TEST_RENDER_SAMPLE_MS_MAX + 1)) === null);
  check('parseTestRenderSampleMs: the maximum bound equals production sample interval',
    TEST_RENDER_SAMPLE_MS_MAX === 2_500);
  check('parseTestRenderSampleMs: the exact minimum bound is honored',
    parseTestRenderSampleMs(String(TEST_RENDER_SAMPLE_MS_MIN)) === TEST_RENDER_SAMPLE_MS_MIN);
  check('parseTestRenderSampleMs: the exact maximum bound is honored',
    parseTestRenderSampleMs(String(TEST_RENDER_SAMPLE_MS_MAX)) === TEST_RENDER_SAMPLE_MS_MAX);
  check('parseTestRenderSampleMs: a valid mid-range value is honored',
    parseTestRenderSampleMs('500') === 500);
  check('parseTestRenderSampleMs: a valid value can only ever shorten, never extend, sampling',
    parseTestRenderSampleMs(String(TEST_RENDER_SAMPLE_MS_MAX)) <= 2_500);
}

{ // Direct runtime boundary proof for the fresh-render cadence. A four-second deadline leaves
  // startup slack for one production 2,500ms sample; exact fixture mode gets a second 50ms sample.
  const rememberedUrl = 'https://chatgpt.com/c/render-timing-boundary';
  const review = `run marker: ${MARKER}\n[P1] render.ts:1: proof\n  Why: timing boundary\nVERDICT: SHIP: done.`;
  async function renderTimingBoundary(mode) {
    const samples = [];
    const cdp = await mockCdp('__NO_TABS__', [], {
      renderText: (_url, n) => {
        samples.push(n);
        return n === 1 ? 'Chat history\nNew chat\nSidebar only' : review;
      },
    });
    const result = await runSalvage([MARKER, '4'], cdp.port, seedMemo(MARKER, rememberedUrl), {
      PRO_GATE_TEST_MODE: mode,
      PRO_GATE_TEST_RENDER_SAMPLE_MS: String(TEST_RENDER_SAMPLE_MS_MIN),
    });
    cdp.stop();
    return { result, samples };
  }

  const noMode = await renderTimingBoundary(undefined);
  check('a valid render override without test mode retains the production 2,500ms sample cadence',
    noMode.samples.join(',') === '1' && noMode.result.elapsedMs >= 2_200,
    `samples=${noMode.samples} elapsed=${noMode.result.elapsedMs} status=${noMode.result.status}`);

  const wrongMode = await renderTimingBoundary('not-ci-fixture');
  check('a valid render override with a wrong mode retains the production 2,500ms sample cadence',
    wrongMode.samples.join(',') === '1' && wrongMode.result.elapsedMs >= 2_200,
    `samples=${wrongMode.samples} elapsed=${wrongMode.result.elapsedMs} status=${wrongMode.result.status}`);

  const exactMode = await renderTimingBoundary('ci-fixture');
  check('exact ci-fixture mode honors the valid rapid render override',
    exactMode.result.status === 0 && exactMode.samples.join(',') === '1,2' && exactMode.result.elapsedMs < 1_000,
    `samples=${exactMode.samples} elapsed=${exactMode.result.elapsedMs} status=${exactMode.result.status}`);
}

{ // still generating: marker matches, no VERDICT -> exit 3, tab NOT closed
  const cdp = await mockCdp(`run marker: ${MARKER}\nReasoning about the diff...`);
  const r = await runSalvage([MARKER, '3'], cdp.port);
  check('still-generating exits 3', r.status === 3, `status=${r.status} stderr=${r.stderr?.slice(0, 200)}`);
  check('still-generating leaves the source tab open after closing its scratch revalidation',
    !cdp.closed.includes('tab1') && cdp.closed.includes('scratch1'), `closed=${cdp.closed}`);
  check('still-generating names the conversation', /still-generating: .*mock-conversation/.test(r.stderr ?? ''));
  cdp.stop();
}

{ // exact-owned terminal ChatGPT infrastructure UI: charged, but nothing remains to harvest
  const messages = [
    'A network error occurred',
    'Something went wrong while generating the response',
    'There was an error generating a response',
  ];
  for (const message of messages) {
    const cdp = await mockCdp(`run marker: ${MARKER}\n${message}`, [], { infrastructureError: message });
    const r = await runSalvage([MARKER, '3'], cdp.port);
    check(`exact-owned terminal UI exits 10: ${message}`, r.status === 10,
      `status=${r.status} stderr=${r.stderr?.slice(0, 240)}`);
    check(`terminal UI names bounded outcome: ${message}`,
      r.stderr?.includes(`terminal-infrastructure: ${message}`), r.stderr);
    check(`terminal UI names its conclusion as terminal-infrastructure: ${message}`,
      /^evidence-kind: terminal-infrastructure$/m.test(r.stderr ?? ''), r.stderr);
    check(`terminal UI leaves source tab for caller cleanup: ${message}`, !cdp.closed.includes('tab1'),
      `closed=${cdp.closed}`);
    cdp.stop();
  }
}

{ // planted negatives: assistant/prompt text has no structured error UI and cannot settle the run
  const messages = [
    'A network error occurred',
    'Something went wrong while generating the response',
    'There was an error generating a response',
  ];
  for (const message of messages) {
    const assistantText = await mockCdp(`run marker: ${MARKER}\n${message}`);
    const assistantResult = await runSalvage([MARKER, '3'], assistantText.port);
    check(`assistant error phrase stays generating: ${message}`, assistantResult.status === 3,
      `status=${assistantResult.status} stderr=${assistantResult.stderr?.slice(0, 200)}`);
    assistantText.stop();
  }

  const beforeMarker = await mockCdp(`A network error occurred\nrun marker: ${MARKER}\nReasoning continues...`, [], { infrastructureError: 'A network error occurred' });
  const beforeResult = await runSalvage([MARKER, '3'], beforeMarker.port);
  check('structured error before the exact marker stays generating', beforeResult.status === 3,
    `status=${beforeResult.status} stderr=${beforeResult.stderr?.slice(0, 200)}`);
  beforeMarker.stop();
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
  const r = await runScratchSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
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
  const observations = [];
  const cdp = await mockCdp(staleSource, [], {
    renderText: (url, n) => {
      observations.push(n);
      return url === canonicalUrl && n === 1 ? markerOnlyScratch : serverReview;
    },
  });
  const r = await runScratchSalvage([MARKER, '8'], cdp.port, seedMemo(MARKER, canonicalUrl));
  check('readable stale source waits past a marker-only canonical scratch sample', r.status === 0,
    `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('marker-hydration revalidation samples marker-only text first then the later verdict exactly once',
    observations.join(',') === '1,2', `observations=${observations}`);
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
  // This 3s canonical revalidation has one static decisive sample; use the pass-6 test seam so
  // scheduler jitter cannot consume the original 500ms post-sample slack.
  const r = await runScratchSalvage(['--probe', MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
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
  const r = await runScratchSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
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
  const r = await runScratchSalvage(['--probe', MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
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
  const ownResult = await runScratchSalvage(['--probe', MARKER, '3'], ownCdp.port, seedMemo(MARKER, canonicalUrl));
  check('probe keeps an old same-marker terminal verdict before the latest prompt generating',
    ownResult.status === 0 && /^probe-state: generating$/m.test(ownResult.stderr || ''),
    `status=${ownResult.status} stderr=${ownResult.stderr}`);
  ownCdp.stop();
}

{ // P1 (gate #91 r2): a retry reuses this run's exact marker, so an OLDER same-marker verdict
  // that a newer prompt marker has already superseded must not be emitted as harvest's result —
  // only --probe checked probeComplete; the plain harvest path emitted on kind alone and would
  // report last round's review as this run's, retiring the reservation while the real answer was
  // still generating.
  const canonicalUrl = 'https://chatgpt.com/c/mock-conversation';
  const staleTerminal = [
    `run marker: ${MARKER}`,
    'Reasoning about the old round...',
    `VERDICT: SHIP — stale round must never be emitted. (run marker: ${MARKER})`,
    `run marker: ${MARKER}`,
    'newer round still generating...',
  ].join('\n');
  const cdp = await mockCdp(staleTerminal, [], {});
  const r = await runSalvage([MARKER, '3'], cdp.port);
  check('a stale same-marker verdict before the latest prompt does not exit 0', r.status !== 0,
    `status=${r.status} stdout=${r.stdout?.slice(0, 200)} stderr=${r.stderr?.slice(0, 300)}`);
  check('a stale same-marker verdict is never printed as the harvested review',
    !/SHIP — stale round/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 300)}`);
  check('a stale same-marker verdict keeps the run still-generating (exit 3)', r.status === 3,
    `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  cdp.stop();

  // Once the newer prompt's own VERDICT lands after the newest marker, THAT review — and only
  // that one — is what harvest emits.
  const newerFinal = [
    `run marker: ${MARKER}`,
    'Reasoning about the old round...',
    `VERDICT: SHIP — stale round must never be emitted. (run marker: ${MARKER})`,
    `run marker: ${MARKER}`,
    '[P1] src/new.mjs:5 — newer finding, real',
    '  Why: real bug',
    `VERDICT: FIX-FIRST — newer round is final. (run marker: ${MARKER})`,
  ].join('\n');
  // Reuse the readable-stale-source -> canonical-scratch-revalidation path (U1): production
  // samples every 2.5s with no render-interval throttle, unlike the remembered-URL seeded render
  // (90s). This focused fixture opts its spawned child into the 50ms test-only sample seam.
  const observations = [];
  const seededCdp = await mockCdp(staleTerminal, [], {
    renderText: (_url, n) => {
      observations.push(n);
      return n === 1 ? staleTerminal : newerFinal;
    },
  });
  const seededResult = await runScratchSalvage([MARKER, '8'], seededCdp.port, seedMemo(MARKER, canonicalUrl));
  check('the stale terminal sample is observed before exactly one later terminal sample',
    observations.join(',') === '1,2', `observations=${observations}`);
  check('the superseded verdict is skipped and the newer verdict is emitted instead',
    seededResult.status === 0 && /VERDICT: FIX-FIRST — newer round is final/.test(seededResult.stdout ?? ''),
    `status=${seededResult.status} stdout=${seededResult.stdout?.slice(0, 300)}`);
  check('the stale verdict text never reaches stdout',
    !/SHIP — stale round/.test(seededResult.stdout ?? ''), `stdout=${seededResult.stdout?.slice(0, 300)}`);
  seededCdp.stop();
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
    const r = await runScratchSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, canonicalUrl));
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
  const throttleResult = await runScratchSalvage([MARKER, '3'], throttled.port, seedMemo(MARKER, canonicalUrl));
  check('throttled canonical scratch takes the existing throttle exit', throttleResult.status === 5,
    `status=${throttleResult.status} stderr=${throttleResult.stderr}`);
  check('throttled canonical scratch names its conclusion as throttle',
    /^evidence-kind: throttle$/m.test(throttleResult.stderr ?? ''), `stderr=${throttleResult.stderr}`);
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
  const crossBoundResult = await runScratchSalvage([MARKER, '3'], crossBound.port, seedMemo(MARKER, canonicalUrl));
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
  const foreignResult = await runScratchSalvage([MARKER, '3'], foreignOnly.port, seedMemo(MARKER, canonicalUrl));
  check('foreign canonical scratch is rejected as a decisive stale memo', foreignResult.status === 4,
    `status=${foreignResult.status} stderr=${foreignResult.stderr}`);
  check('foreign canonical scratch forgets and blacklists the stale memo',
    foreignResult.memos.length === 0 && /mock-conversation/.test(foreignResult.blacklist ?? ''),
    `memos=${JSON.stringify(foreignResult.memos)} blacklist=${foreignResult.blacklist}`);
  foreignOnly.stop();
}

{ // P1: the one-shot canonical revalidation must be spent on the REMEMBERED conversation (A),
  // never on whichever marker-bearing owned-incomplete tab the scan happens to reach first (B).
  // Before this fix, a retry-created duplicate tab at a different URL (B) — still incomplete,
  // still carrying our marker — would consume the single scratch navigation every cycle and
  // permanently suppress the remembered-URL pass, so a completed, PAID review already sitting at
  // A was reported as still generating forever. Evidence must be attributed to the URL actually
  // rendered (A), not the tab that merely triggered the pass (B).
  const knownUrlA = 'https://chatgpt.com/c/known-conversation-a';
  const duplicateTabB = `run marker: ${MARKER}\nduplicate retry tab, still reasoning...`;
  const terminalReviewA = [
    `run marker: ${MARKER}`,
    '[P1] src/known.mjs:1 — finished on the canonical conversation',
    'P2: none',
    `VERDICT: FIX-FIRST — recovered from A, not B. (run marker: ${MARKER})`,
  ].join('\n');
  const wrongUrlRendered = 'run marker: pg-run-other-9999999999-9\nWRONG URL WAS RENDERED';
  const terminalCdp = await mockCdp(duplicateTabB, [], {
    renderText: (url) => (url === knownUrlA ? terminalReviewA : wrongUrlRendered),
  });
  // Static terminal scratch evidence has no delayed state to preserve; the 50ms test seam avoids
  // a flaky 2.5s sample landing after this fixture's 3s invocation deadline.
  const terminalResult = await runScratchSalvage([MARKER, '3'], terminalCdp.port, seedMemo(MARKER, knownUrlA));
  check('the one revalidation renders the remembered conversation A, not the duplicate tab B',
    terminalCdp.created.length === 1 && terminalCdp.created[0]?.url === knownUrlA,
    `created=${JSON.stringify(terminalCdp.created)}`);
  check('a terminal render of A is emitted and attributed to A', terminalResult.status === 0 &&
    /^matched-url https:\/\/chatgpt\.com\/c\/known-conversation-a$/m.test(terminalResult.stderr ?? ''),
    `status=${terminalResult.status} stderr=${terminalResult.stderr?.slice(0, 300)}`);
  check('a terminal render of A names its conclusion as terminal',
    /^evidence-kind: terminal$/m.test(terminalResult.stderr ?? ''), `stderr=${terminalResult.stderr?.slice(0, 300)}`);
  check('the emitted review body is A\'s, not B\'s',
    terminalResult.stdout.trim() === terminalReviewA.split('\n').slice(1).join('\n'),
    `stdout=${terminalResult.stdout?.slice(0, 300)}`);
  check('the duplicate tab B is never navigated, closed, or promoted in A\'s place',
    !terminalCdp.closed.includes('tab1') &&
      !terminalCdp.requests.some((request) => request.method === 'Page.navigate'),
    `closed=${terminalCdp.closed} requests=${JSON.stringify(terminalCdp.requests)}`);
  terminalCdp.stop();

  const crossBoundAnswerA = [
    `run marker: ${MARKER}`,
    '[P1] foreign/source.mjs:1 — another run',
    'VERDICT: FIX-FIRST — not ours. (run marker: pg-run-other-repo-42-1111111111-9)',
  ].join('\n');
  const crossBoundCdp = await mockCdp(duplicateTabB, [], {
    renderText: (url) => (url === knownUrlA ? crossBoundAnswerA : duplicateTabB),
  });
  const crossBoundResult = await runScratchSalvage([MARKER, '3'], crossBoundCdp.port, seedMemo(MARKER, knownUrlA));
  check('the one revalidation renders A, not B, for the cross-bound case',
    crossBoundCdp.created.length === 1 && crossBoundCdp.created[0]?.url === knownUrlA,
    `created=${JSON.stringify(crossBoundCdp.created)}`);
  check('a cross-bound render of A is rejected and blacklisted as A',
    crossBoundResult.memos.length === 0 &&
      (crossBoundResult.blacklist ?? '').includes(`${MARKER}\t${knownUrlA}`),
    `memos=${JSON.stringify(crossBoundResult.memos)} blacklist=${crossBoundResult.blacklist}`);
  check('B is not promoted into A\'s place as the new recovery handle',
    crossBoundResult.memoUrl !== 'https://chatgpt.com/c/mock-conversation' &&
      !(crossBoundResult.blacklist ?? '').includes('mock-conversation'),
    `memoUrl=${crossBoundResult.memoUrl} blacklist=${crossBoundResult.blacklist}`);
  check('the duplicate tab B stays open and unnavigated, and the still-generating exit reflects it',
    crossBoundResult.status === 3 && !crossBoundCdp.closed.includes('tab1') &&
      !crossBoundCdp.requests.some((request) => request.method === 'Page.navigate'),
    `status=${crossBoundResult.status} closed=${crossBoundCdp.closed} requests=${JSON.stringify(crossBoundCdp.requests)}`);
  check('the cross-bound rejection of A is recorded for --status', crossBoundResult.crossbound > 0,
    `crossbound=${crossBoundResult.crossbound}`);
  crossBoundCdp.stop();
}

{
  // Mixed results remain intact as diagnostic capture evidence for the engine's provenance gate.
  const foreign = 'pg-run-other-repo-2619-1111111111-9';
  const ours = ['P0: none', 'P1: none', 'VERDICT: SHIP — ours. (run marker: ' + MARKER + ')'];
  const theirs = [
    '[P0] other/a.ts:1 — foreign finding',
    'VERDICT: FIX-FIRST — theirs. (run marker: ' + foreign + ')',
  ];
  const dual = ['P0: none', 'VERDICT: SHIP (run marker: ' + MARKER + ') (run marker: ' + foreign + ')'];
  for (const [layout, answer] of [
    ['foreign first', [...theirs, '', ...ours]],
    ['foreign last', [...ours, '', ...theirs]],
    ...['- **VERDICT:**', '## **VERDICT:**'].flatMap((label) => {
      const formattedTheirs = theirs.map((line) => line.replace('VERDICT:', label));
      const formattedOurs = ours.map((line) => line.replace('VERDICT:', label));
      return [
        [label + ' foreign first', [...formattedTheirs, '', ...formattedOurs]],
        [label + ' foreign last', [...formattedOurs, '', ...formattedTheirs]],
      ];
    }),
    ['dual marker verdict', dual],
    ['foreign verdict without heading', [theirs[1], ...ours]],
    ['owned verdict without heading', [...theirs, ours[2]]],
    ['own marker mentioned in a finding', [...theirs, '[P1] src/own.ts:4 — run marker: ' + MARKER, ...ours]],
    [
      'fenced compact prompt example',
      [...theirs, '[P1] src/own.ts:4 — prompt example', '~~~', 'run marker: ' + MARKER, '~~~', ...ours],
    ],
    [
      'fenced engine prompt example',
      [
        ...theirs,
        '[P1] src/own.ts:4 — prompt example',
        '~~~',
        '(run marker: ' + MARKER + ' — internal correlation id)',
        '~~~',
        ...ours,
      ],
    ],
  ]) {
    const body = 'run marker: ' + MARKER + '\n' + answer.join('\n');
    const cdp = await mockCdp(body);
    const capture = await runSalvage([MARKER, '3'], cdp.port);
    check(
      'mixed capture keeps every byte for engine rejection (' + layout + ')',
      capture.status === 0 && capture.stdout === answer.join('\n') + '\n',
      'status=' + capture.status + ' stdout=' + JSON.stringify(capture.stdout),
    );
    const binding = bindCapture(capture.stdout, MARKER);
    check(
      'browser mixed evidence fails shell binding without rewriting (' + layout + ')',
      binding.status === 2 && binding.retained === capture.stdout,
      'status=' + binding.status + ' stderr=' + binding.stderr,
    );
    check(
      'mixed capture preserves conversation evidence (' + layout + ')',
      cdp.closed.length === 0 && capture.crossbound === 0 && capture.blacklist === null,
      'closed=' + cdp.closed + ' blacklist=' + capture.blacklist,
    );
    const probe = await runSalvage(['--probe', MARKER, '3'], cdp.port);
    check(
      'mixed capture never proves completed review ownership (' + layout + ')',
      probe.status === 0 &&
        probe.stderr.includes('probe-state: generating') &&
        !probe.stderr.includes('probe-state: complete'),
      'status=' + probe.status + ' stderr=' + probe.stderr,
    );
    cdp.stop();
    for (const owner of [MARKER, foreign]) {
      for (const mode of ['organize', 'finalize', 'close']) {
        const mutationCdp = await mockCdp(body);
        const args = mode === 'finalize' ? finalizerArgs(owner) : ['--' + mode, owner, '3'];
        const result = await runSalvage(
          args,
          mutationCdp.port,
          seedOrganizer(owner, 'pro-gate review: mixed', null, durableReview(ours.join('\n'), owner)),
        );
        check(
          'shared mixed conversation cannot mutate for either owner (' +
            layout +
            ', ' +
            owner +
            ', ' +
            mode +
            ')',
          result.status === 0 && mutationCdp.ui.events.length === 0 && mutationCdp.closed.length === 0,
          'status=' + result.status + ' stdout=' + result.stdout + ' closed=' + mutationCdp.closed,
        );
        mutationCdp.stop();
      }
    }
  }
}

{
  // Reference text never creates cross-task ownership, and extraction keeps the complete finding.
  const foreign = 'pg-run-other-repo-2619-1111111111-9';
  const example = 'VERDICT: SHIP — incident. (run marker: ' + foreign + ')';
  const tick = String.fromCharCode(96);
  for (const [kind, reference] of [
    ['prose marker', ['The incident used (run marker: ' + foreign + ').']],
    ['inline verdict quote', ['The incident said "' + example + '".']],
    ['blockquote', ['> ' + example]],
    ['indented block', ['    ' + example]],
    ['tab indented block', ['\t' + example]],
    ['backtick fence', [tick.repeat(3) + 'text', example, tick.repeat(3)]],
    ['tilde fence', ['~~~text', example, '~~~']],
    ['long fence with short embedded fence', [tick.repeat(4), tick.repeat(3), example, tick.repeat(4)]],
    ['other fence cannot close code', [tick.repeat(3), '~~~', example, tick.repeat(3)]],
    ['heading without decision', ['VERDICT: example from ' + foreign]],
  ]) {
    const answer = [
      'P0: none',
      '[P1] src/real.sh:4 — reference example',
      ...reference,
      'and the finding continues',
      '[P2] src/other.sh:9 — another finding',
      'VERDICT: FIX-FIRST — ours. (run marker: ' + MARKER + ')',
    ].join('\n');
    const cdp = await mockCdp('run marker: ' + MARKER + '\n' + answer);
    const r = await runSalvage([MARKER, '3'], cdp.port);
    check(
      'ordinary owned answer preserves exact capture bytes (' + kind + ')',
      r.status === 0 && r.stdout === answer + '\n',
      'status=' + r.status + ' stdout=' + JSON.stringify(r.stdout),
    );
    const probe = await runSalvage(['--probe', MARKER, '3'], cdp.port);
    check(
      'inert references preserve owned completion (' + kind + ')',
      probe.status === 0 && probe.stderr.includes('probe-state: complete'),
      'stderr=' + probe.stderr,
    );
    cdp.stop();
  }
}

{
  for (const label of ['- **VERDICT:**', '## **VERDICT:**']) {
    const answer = 'P0: none\n' + label + ' SHIP — ours. (run marker: ' + MARKER + ')';
    const cdp = await mockCdp('run marker: ' + MARKER + '\n' + answer);
    const capture = await runSalvage([MARKER, '3'], cdp.port);
    const binding = bindCapture(capture.stdout, MARKER);
    check(
      'formatted owned verdict publishes byte-preserving capture (' + label + ')',
      capture.status === 0 &&
        capture.stdout === answer + '\n' &&
        binding.status === 0 &&
        binding.retained === capture.stdout,
      'status=' + capture.status + ' bind=' + binding.status + ' stdout=' + capture.stdout,
    );
    const probe = await runSalvage(['--probe', MARKER, '3'], cdp.port);
    check(
      'formatted owned verdict proves completion (' + label + ')',
      probe.status === 0 && probe.stderr.includes('probe-state: complete'),
      'stderr=' + probe.stderr,
    );
    cdp.stop();
  }
}

{
  // Execute the actual CDP expression against rendered DOM nodes. innerText has lost the quote
  // syntax; the blockquote/pre context must survive the capture so the shell agrees with CDP.
  const foreign = 'pg-run-old-2619-1111111111-9';
  const example = 'VERDICT: SHIP — incident. (run marker: ' + foreign + ')';
  const node = (tag, innerText, children = [], role = null) => ({
    innerText,
    textContent: innerText,
    children,
    matches: (selector) => selector.split(', ').includes(tag),
    getAttribute: (attribute) => (attribute === 'data-message-author-role' ? role : null),
  });
  for (const tag of ['blockquote', 'pre', 'code']) {
    const answer = [
      'P0: none',
      '[P1] src/real.sh:4 — incident example',
      example,
      '[P2] src/other.sh:9 — another finding',
      'VERDICT: FIX-FIRST — ours. (run marker: ' + MARKER + ')',
    ];
    const ownAnswer = node(
      'div',
      answer.join('\n'),
      answer.map((line, index) => node(index === 2 ? tag : 'p', line)),
      'assistant',
    );
    const turns = [
      node('div', 'run marker: ' + foreign, [], 'user'),
      node('div', 'P0: none\n' + example, [], 'assistant'),
      node('div', 'Please review this change. run marker: ' + MARKER, [], 'user'),
      ownAnswer,
    ];
    const document = {
      body: node('body', turns.map((turn) => turn.innerText).join('\n'), turns),
      querySelectorAll: () => turns,
    };
    const cdp = await mockCdp(document.body.innerText, [], { document });
    const capture = await runSalvage([MARKER, '3'], cdp.port);
    const expected = answer.map((line, index) => (index === 2 ? '> ' + line : line)).join('\n');
    check(
      'rendered ' + tag + ' retains context and full finding bytes',
      capture.status === 0 && capture.stdout === expected + '\n',
      'status=' + capture.status + ' stdout=' + JSON.stringify(capture.stdout),
    );
    const binding = bindCapture(capture.stdout, MARKER);
    check(
      'actual DOM ' + tag + ' capture passes shell binding without rewriting',
      binding.status === 0 && binding.retained === capture.stdout,
      'status=' + binding.status + ' stderr=' + binding.stderr,
    );
    const probe = await runSalvage(['--probe', MARKER, '3'], cdp.port);
    check(
      'rendered ' + tag + ' example is inert and old scrollback is excluded',
      probe.status === 0 && probe.stderr.includes('probe-state: complete'),
      'stderr=' + probe.stderr,
    );
    check(
      'DOM context capture executes the actual review-text expression',
      cdp.requests.some((request) => request.params?.expression?.includes('pro-gate:review-text')),
      'requests=' + cdp.requests.length,
    );
    cdp.stop();
    const title = 'unchanged title';
    const fixture = organizerExpressionFixture(document.body.innerText, { document, title });
    const expression = buildRenameConversationExpression(title, {
      marker: MARKER,
      conversationUrl: 'https://chatgpt.com/c/mock-conversation',
      mutationToken: 'dom-reference.' + tag,
      mutationExpiresAt: Date.now() + 10_000,
      expectedReview: durableReview(capture.stdout, MARKER),
    });
    const finalized = await runInNewContext(expression, fixture.context);
    check(
      'independent finalization guard accepts the same rendered ' + tag + ' bytes',
      finalized.status === 'already' && fixture.sidebarReads() > 0 && fixture.events.length === 0,
      'result=' + JSON.stringify(finalized),
    );
  }

  for (const [kind, code, suffix] of [
    ['unsigned example', 'VERDICT: SHIP', ''],
    ['verdict label fragment', 'VERDICT: FIX-FIRST', ' — ours. (run marker: ' + MARKER + ')'],
    ['signed verdict fragment', 'VERDICT: FIX-FIRST (run marker: ' + MARKER + ')', ' — ours.'],
  ]) {
    const real = 'VERDICT: FIX-FIRST — ours. (run marker: ' + MARKER + ')';
    const lines = ['P0: none', '[P1] src/real.sh:4 — regression', ...(suffix ? [] : [real]), code + suffix];
    const last = node('p', code + suffix, [node('span', code, [node('code', code)])]);
    const turns = [
      node('div', 'run marker: ' + MARKER, [], 'user'),
      node('div', lines.join('\n'), [...lines.slice(0, -1).map((line) => node('p', line)), last], 'assistant'),
    ];
    const document = {
      body: node('body', turns.map((turn) => turn.innerText).join('\n'), turns),
      querySelectorAll: () => turns,
    };
    const cdp = await mockCdp(document.body.innerText, [], { document });
    const capture = await runSalvage([MARKER, '3'], cdp.port);
    const expected = (suffix ? lines : lines.slice(0, -1)).join('\n') + '\n';
    const binding = bindCapture(capture.stdout, MARKER);
    check(
      'DOM inline-code context distinguishes ' + kind + ' without changing authority',
      capture.status === 0 && capture.stdout === expected && binding.status === 0,
      'status=' + capture.status + ' bind=' + binding.status + ' stdout=' + JSON.stringify(capture.stdout),
    );
    cdp.stop();
  }

  const verdictNode = (marker, summary, wrapMarker) => {
    const signature = '(run marker: ' + marker + ')';
    const line = 'VERDICT: SHIP — ' + summary + '. ' + signature;
    return node(
      'p',
      line,
      wrapMarker ? [node('span', marker, [node('code', marker)])] : [],
    );
  };
  const reviewDocument = (answerNodes) => {
    const assistant = node(
      'div',
      answerNodes.map((answerNode) => answerNode.innerText).join('\n'),
      answerNodes,
      'assistant',
    );
    const turns = [node('div', 'run marker: ' + MARKER, [], 'user'), assistant];
    return {
      body: node('body', turns.map((turn) => turn.innerText).join('\n'), turns),
      querySelectorAll: () => turns,
    };
  };

  {
    const answerNodes = [node('p', 'P0: none'), verdictNode(MARKER, 'ours', true)];
    const answer = answerNodes.map((answerNode) => answerNode.innerText).join('\n');
    const document = reviewDocument(answerNodes);
    const cdp = await mockCdp(document.body.innerText, [], { document });
    const capture = await runSalvage([MARKER, '3'], cdp.port);
    check(
      'DOM code-wrapped own marker preserves exact review bytes',
      capture.status === 0 && capture.stdout === answer + '\n',
      'status=' + capture.status + ' stdout=' + JSON.stringify(capture.stdout),
    );
    const binding = bindCapture(capture.stdout, MARKER);
    check(
      'DOM code-wrapped own marker passes shell binding unchanged',
      binding.status === 0 && binding.retained === capture.stdout,
      'status=' + binding.status + ' stderr=' + binding.stderr,
    );
    const probe = await runSalvage(['--probe', MARKER, '3'], cdp.port);
    check(
      'DOM code-wrapped own marker proves completed review ownership',
      probe.status === 0 && probe.stderr.includes('probe-state: complete'),
      'status=' + probe.status + ' stderr=' + probe.stderr,
    );
    cdp.stop();
    const fixture = organizerExpressionFixture(document.body.innerText, { document });
    const expression = buildRenameConversationExpression('unchanged title', {
      marker: MARKER,
      conversationUrl: 'https://chatgpt.com/c/mock-conversation',
      mutationToken: 'dom-code-own.finalize',
      mutationExpiresAt: Date.now() + 10_000,
      expectedReview: durableReview(capture.stdout, MARKER),
    });
    const finalized = await runInNewContext(expression, fixture.context);
    check(
      'independent finalization guard accepts DOM code-wrapped own marker bytes',
      finalized.status === 'already' && fixture.sidebarReads() > 0 && fixture.events.length === 0,
      'result=' + JSON.stringify(finalized),
    );
  }

  {
    const foreign = 'pg-run-other-repo-2619-1111111111-9';
    const ours = [node('p', 'P0: none'), verdictNode(MARKER, 'ours', false)];
    const theirs = [
      node('p', '[P0] other/a.ts:1 — foreign finding'),
      verdictNode(foreign, 'theirs', true),
    ];
    for (const [layout, answerNodes] of [
      ['foreign first', [...theirs, ...ours]],
      ['foreign last', [...ours, ...theirs]],
    ]) {
      const answer = answerNodes.map((answerNode) => answerNode.innerText).join('\n');
      const document = reviewDocument(answerNodes);
      const cdp = await mockCdp(document.body.innerText, [], { document });
      const capture = await runSalvage([MARKER, '3'], cdp.port);
      check(
        'DOM code-wrapped foreign marker preserves mixed review bytes (' + layout + ')',
        capture.status === 0 && capture.stdout === answer + '\n',
        'status=' + capture.status + ' stdout=' + JSON.stringify(capture.stdout),
      );
      const binding = bindCapture(capture.stdout, MARKER);
      check(
        'DOM code-wrapped foreign marker fails shell binding unchanged (' + layout + ')',
        binding.status === 2 && binding.retained === capture.stdout,
        'status=' + binding.status + ' stderr=' + binding.stderr,
      );
      const probe = await runSalvage(['--probe', MARKER, '3'], cdp.port);
      check(
        'DOM code-wrapped foreign marker keeps probe generating (' + layout + ')',
        probe.status === 0 &&
          probe.stderr.includes('probe-state: generating') &&
          !probe.stderr.includes('probe-state: complete'),
        'status=' + probe.status + ' stderr=' + probe.stderr,
      );
      cdp.stop();
      for (const action of ['rename', 'archive']) {
        const fixture = organizerExpressionFixture(document.body.innerText, { document });
        const target = {
          marker: MARKER,
          conversationUrl: 'https://chatgpt.com/c/mock-conversation',
          mutationToken: 'dom-code-mixed.' + action + '.' + layout.replace(' ', '-'),
          mutationExpiresAt: Date.now() + 10_000,
          expectedReview: action === 'archive'
            ? durableReview(ours.map((answerNode) => answerNode.innerText).join('\n'), MARKER)
            : null,
        };
        const expression = action === 'rename'
          ? buildRenameConversationExpression('unchanged title', target)
          : buildArchiveConversationExpression(target);
        const result = await runInNewContext(expression, fixture.context);
        check(
          'independent ' + action + ' guard rejects DOM code-wrapped mixed review (' + layout + ')',
          result.status === 'skipped' &&
            result.reason === 'target-mixed-review' &&
            fixture.sidebarReads() === 0 &&
            fixture.events.length === 0,
          'result=' + JSON.stringify(result) + ' events=' + fixture.events,
        );
      }
    }
  }

  const answer = [
    'P0: none',
    example,
    '[P1] src/real.sh:4 — a literal prompt marker in a finding',
    'run marker: ' + MARKER,
    'VERDICT: SHIP — ours. (run marker: ' + MARKER + ')',
  ].join('\n');
  const turns = [node('div', 'run marker: ' + MARKER, [], 'user'), node('div', answer, [], 'assistant')];
  const document = {
    body: node('body', turns.map((turn) => turn.innerText).join('\n'), turns),
    querySelectorAll: () => turns,
  };
  const cdp = await mockCdp(document.body.innerText, [], { document });
  const capture = await runSalvage([MARKER, '3'], cdp.port);
  const binding = bindCapture(capture.stdout, MARKER);
  check(
    'DOM user-turn scope cannot be reset by a literal prompt marker inside the answer',
    capture.status === 0 && capture.stdout === answer + '\n' && binding.status === 2,
    'status=' + capture.status + ' stdout=' + JSON.stringify(capture.stdout) + ' bind=' + binding.status,
  );
  cdp.stop();
}

{
  // The live DOM can drift after the collector validated it. Execute the actual renderer guard
  // and prove neither rename nor archive dispatches even its first event after mixed drift.
  const foreign = 'pg-run-other-repo-2619-1111111111-9';
  const ours = completedReview(MARKER);
  const theirs = 'P0: none\nVERDICT: FIX-FIRST (run marker: ' + foreign + ')';
  for (const [layout, mixed] of [
    ['foreign first', theirs + '\n' + ours],
    ['foreign last', ours + '\n' + theirs],
  ]) {
    for (const action of ['rename', 'archive']) {
      const fixture = organizerExpressionFixture('run marker: ' + MARKER + '\n' + ours, {
        driftText: 'run marker: ' + MARKER + '\n' + mixed,
      });
      const target = {
        marker: MARKER,
        conversationUrl: 'https://chatgpt.com/c/mock-conversation',
        mutationToken: 'mixed-drift.' + action,
        mutationExpiresAt: Date.now() + 10_000,
        expectedReview: action === 'archive' ? durableReview(ours, MARKER) : null,
      };
      const expression =
        action === 'rename'
          ? buildRenameConversationExpression('new title', target)
          : buildArchiveConversationExpression(target);
      const result = await runInNewContext(expression, fixture.context);
      check(
        'independent ' + action + ' guard rejects mixed DOM drift before effect (' + layout + ')',
        result.status === 'skipped' &&
          result.reason === 'target-mixed-review' &&
          fixture.sidebarReads() > 0 &&
          fixture.events.length === 0,
        'result=' + JSON.stringify(result) + ' events=' + fixture.events,
      );
    }
  }
}

{
  // Text-only old foreign scrollback stays outside a newly completed owned response.
  const foreign = 'pg-run-other-repo-2619-1111111111-9';
  const old = ['[P0] other/a.ts:1 — old finding', 'VERDICT: FIX-FIRST (run marker: ' + foreign + ')'];
  const answer = ['P0: none', 'P1: none', 'VERDICT: SHIP — ours. (run marker: ' + MARKER + ')'];
  const body = [
    ...old,
    '(run marker: ' + MARKER + ' — internal correlation id, echo on the verdict line)',
    ...answer,
  ].join('\n');
  const cdp = await mockCdp(body);
  const capture = await runSalvage([MARKER, '3'], cdp.port);
  check(
    'old foreign scrollback is excluded from a clean new answer',
    capture.status === 0 && capture.stdout === answer.join('\n') + '\n',
    'stdout=' + capture.stdout,
  );
  const probe = await runSalvage(['--probe', MARKER, '3'], cdp.port);
  check(
    'clean new answer after old foreign scrollback proves completion',
    probe.status === 0 && probe.stderr.includes('probe-state: complete'),
    'stderr=' + probe.stderr,
  );
  cdp.stop();
  const staleCdp = await mockCdp([...old, 'run marker: ' + MARKER].join('\n'));
  const stale = await runSalvage([MARKER, '3'], staleCdp.port);
  check(
    'old foreign answer preceding a still-pending prompt preserves chronology',
    stale.status === 0 && stale.stderr.includes('answer-chronology precedes-prompt'),
    'status=' + stale.status + ' stderr=' + stale.stderr,
  );
  staleCdp.stop();
}

{ // P1 (gate #91 r3): --probe must not report the conversation ABSENT just because the one-shot
  // revalidation was spent on a DIFFERENT remembered URL (A) that comes back cross-bound or
  // foreign, while the tab actually scanned (B) is demonstrably ours and still generating. Before
  // this fix, B's owned-incomplete evidence was only ever emitted to probe from the line AFTER
  // these rejections' `continue` (never reached), so probe fell through to the deadline with no
  // positive signal this cycle, exited 4 (absent), and the engine's miss counter could ultimately
  // release a live review for a double-spending retry.
  const knownUrlA = 'https://chatgpt.com/c/known-conversation-a';
  const duplicateTabB = `run marker: ${MARKER}\nduplicate retry tab, still reasoning...`;

  const crossBoundAnswerA = [
    `run marker: ${MARKER}`,
    '[P1] foreign/source.mjs:1 — another run',
    'VERDICT: FIX-FIRST — not ours. (run marker: pg-run-other-repo-42-1111111111-9)',
  ].join('\n');
  const crossBoundCdp = await mockCdp(duplicateTabB, [], {
    renderText: (url) => (url === knownUrlA ? crossBoundAnswerA : duplicateTabB),
  });
  const crossBoundResult = await runScratchSalvage(['--probe', MARKER, '3'], crossBoundCdp.port, seedMemo(MARKER, knownUrlA));
  check('probe reports tab B present and generating despite A\'s cross-bound rejection',
    crossBoundResult.status === 0 && /^probe-state: generating$/m.test(crossBoundResult.stderr || ''),
    `status=${crossBoundResult.status} stderr=${crossBoundResult.stderr}`);
  check('probe emits no review body for the cross-bound-A case', crossBoundResult.stdout === '',
    `stdout=${crossBoundResult.stdout}`);
  check('the one revalidation still only ever rendered A', crossBoundCdp.created.length === 1 &&
    crossBoundCdp.created[0]?.url === knownUrlA, `created=${JSON.stringify(crossBoundCdp.created)}`);
  crossBoundCdp.stop();

  const foreignOnlyA = 'run marker: pg-run-other-repo-42-1111111111-9\nVERDICT: SHIP — foreign.';
  const foreignCdp = await mockCdp(duplicateTabB, [], {
    renderText: (url) => (url === knownUrlA ? foreignOnlyA : duplicateTabB),
  });
  const foreignResult = await runScratchSalvage(['--probe', MARKER, '3'], foreignCdp.port, seedMemo(MARKER, knownUrlA));
  check('probe reports tab B present and generating despite A\'s foreign rejection',
    foreignResult.status === 0 && /^probe-state: generating$/m.test(foreignResult.stderr || ''),
    `status=${foreignResult.status} stderr=${foreignResult.stderr}`);
  foreignCdp.stop();
}

{ // P1 regression guard: with no remembered conversation, knownUrl is null so revalidateUrl
  // reduces to tab.url — the readable owned-incomplete tab's own URL is revalidated exactly as
  // before this fix.
  const ownUrl = 'https://chatgpt.com/c/mock-conversation';
  const staleTabOnly = `run marker: ${MARKER}\nno memo yet, still reasoning...`;
  const cdp = await mockCdp(staleTabOnly, [], {
    renderText: (url) => (url === ownUrl ? staleTabOnly : 'unexpected'),
  });
  const r = await runSalvage([MARKER, '3'], cdp.port);   // NO seeded memo
  check('with no remembered conversation, revalidation still targets the readable tab\'s own URL',
    cdp.created.length === 1 && cdp.created[0]?.url === ownUrl && r.status === 3,
    `created=${JSON.stringify(cdp.created)} status=${r.status}`);
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
    // The test child opts into the 50ms test-only sample interval so target disappearance reaches
    // its cleanup path promptly. Production still samples after 2.5s; these established timeout
    // arguments stay deliberately unchanged in this pass.
    const r = await runScratchSalvage(args, cdp.port, seedMemo(MARKER, priorUrl), {
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
    const openAt = cdp.httpRequests.findIndex((request) => request.startsWith('PUT /json/new?'));
    const listAt = cdp.httpRequests.findIndex((request, index) => index > openAt && request === 'GET /json');
    const closeAt = cdp.httpRequests.findIndex((request, index) => index > listAt && request === 'GET /json/close/scratch1');
    check(`${label} scratch cleanup preserves open then list then close ordering`,
      openAt >= 0 && listAt > openAt && closeAt > listAt,
      `httpRequests=${cdp.httpRequests.join(',')}`);
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

{ // P2: a Chrome that answers PUT /json/new with a non-JSON error must still fall through to the
  // documented pre-v111 GET fallback in freshRenderText's path, not read as scratch-open-failed.
  const review = `run marker: ${MARKER}\n[P0] a.ts:1: boom\n  Why: real\nVERDICT: FIX-FIRST: bad.`;
  const cdp = await mockCdp('__NO_TABS__', [], { renderText: () => review, putNewFails: true });
  const r = await runSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/remembered'));
  check('a non-JSON PUT error still reaches the GET fallback and recovers the review', r.status === 0,
    `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('the GET-recovered review is printed', /VERDICT: FIX-FIRST/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 160)}`);
  check('the scratch tab was actually opened (via GET, after PUT failed)',
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
  const observations = [];
  const cdp = await mockCdp('__NO_TABS__', [], {
    renderText: (_url, n) => {
      observations.push(n);
      return n === 1 ? shell : review;
    },
  });
  const r = await runScratchSalvage([MARKER, '30'], cdp.port, seedMemo(MARKER, 'https://chatgpt.com/c/remembered'));
  check('a pre-hydration render is not treated as a miss', r.status === 0, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('shell/sidebar is retained as the first sample until the second sample hydrates the review',
    observations.join(',') === '1,2', `observations=${observations}`);
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
  //
  // This scenario's decisive exit is reached inside the FIRST scan, through the pre-existing
  // one-shot revalidateReadableStaleSource() -> freshRenderText() scratch-render path (bounded by
  // its own untouched 2.5s sampling floor / 25s render budget), which returns a terminal VERDICT
  // and calls process.exit(0) before the outer loop's POLL_MS sleep is ever reached — confirmed
  // directly: an isolated A/B run of this exact scenario measured ~2.57-2.58s wall time and
  // jsonListCalls=2 identically with and without a PRO_GATE_TEST_POLL_MS override (4 consecutive
  // runs, <15ms spread). So this test intentionally carries NO override — the poll-cadence lever
  // has nothing to speed up here, and adding one would misrepresent what the test proves. The
  // 1.5s tab-death mutation and 40s deadline are unrelated to POLL_MS and are left exactly as in
  // the original fixture.
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

{ // Direct runtime boundary proof for the poll override. A valid value must have no effect until
  // the exact fixture token is present; the stable state also proves rapid re-polling never changes
  // the exit classification.
  const stableText = `run marker: ${MARKER}\nstill reasoning, nothing ever resolves...`;
  const fastCdp = await mockCdp(stableText);
  const fastResult = await runSalvage([MARKER, '2'], fastCdp.port, undefined,
    { PRO_GATE_TEST_MODE: 'ci-fixture', PRO_GATE_TEST_POLL_MS: String(TEST_POLL_MS_MIN) });
  check('exact ci-fixture mode honors the valid rapid-poll override and retains exit 3',
    fastResult.status === 3 && fastCdp.jsonListCalls >= 5,
    `status=${fastResult.status} jsonListCalls=${fastCdp.jsonListCalls}`);
  fastCdp.stop();

  const noModeCdp = await mockCdp(stableText);
  const noModeResult = await runSalvage([MARKER, '2'], noModeCdp.port, undefined, {
    PRO_GATE_TEST_MODE: undefined,
    PRO_GATE_TEST_POLL_MS: String(TEST_POLL_MS_MIN),
  });
  check('a valid poll override without test mode retains the production 20,000ms cadence',
    noModeResult.status === 3 && noModeCdp.jsonListCalls === 2,
    `status=${noModeResult.status} jsonListCalls=${noModeCdp.jsonListCalls}`);
  noModeCdp.stop();

  const wrongModeCdp = await mockCdp(stableText);
  const wrongModeResult = await runSalvage([MARKER, '2'], wrongModeCdp.port, undefined, {
    PRO_GATE_TEST_MODE: 'not-ci-fixture',
    PRO_GATE_TEST_POLL_MS: String(TEST_POLL_MS_MIN),
  });
  check('a valid poll override with a wrong mode retains the production 20,000ms cadence',
    wrongModeResult.status === 3 && wrongModeCdp.jsonListCalls === 2,
    `status=${wrongModeResult.status} jsonListCalls=${wrongModeCdp.jsonListCalls}`);
  wrongModeCdp.stop();

  const slowCdp = await mockCdp(stableText);
  const slowResult = await runSalvage([MARKER, '2'], slowCdp.port);   // no override: production cadence
  check('the same stable state classifies identically without the override (exit 3)',
    slowResult.status === 3, `status=${slowResult.status} stderr=${slowResult.stderr?.slice(0, 300)}`);
  // Exactly 2, deterministically, not 1: one main-loop scan (production's 20s cadence never
  // fires a second poll inside this 2s deadline) plus the pre-existing, unrelated post-loop
  // "revalidate at the deadline" fetch (still-generating && not seeded, lines ~1472-1487) that
  // runs before every exit-3 report. Neither call comes from the poll-cadence lever itself.
  check('production cadence yields two scans, not a rapid re-poll',
    slowCdp.jsonListCalls === 2, `jsonListCalls=${slowCdp.jsonListCalls}`);
  slowCdp.stop();
}

{ // gate P1: proven SERVER-SIDE liveness must outlive later empty tab scans. The remembered
  // render proves the conversation is alive but unfinished; subsequent scans see no tabs. The
  // fast test-only cadences leave enough 3s-deadline room to prove both phases, not just exit 3.
  const rememberedUrl = 'https://chatgpt.com/c/remembered';
  const samples = [];
  const cdp = await mockCdp('__NO_TABS__', [], {
    trackCdpDeadlineEvents: true,
    renderText: (_url, n) => {
      samples.push(n);
      return `run marker: ${MARKER}\nstill reasoning...`;
    },
  });
  const r = await runFastCdpDeadlineSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, rememberedUrl));
  check('server-side liveness survives later empty scans (exit 3)', r.status === 3, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('still-generating says it was proven server-side',
    /proven server-side/.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(-300)}`);
  check('server-side liveness records its owned scratch sample before later scans',
    hasConsecutiveSamples(samples, 1) && samples.length === 1, `samples=${samples}`);
  check('server-side liveness makes multiple later empty outer scans',
    cdp.outerJsonListCalls >= 3 && cdp.jsonListEvents.filter((event) =>
      event.source === 'outer' && event.tabIds.length === 0).length >= 3,
    `outerLists=${cdp.outerJsonListCalls} events=${JSON.stringify(cdp.jsonListEvents)}`);
  check('server-side liveness reaches the shortened deadline with its recovery state intact',
    r.elapsedMs >= 2_500 && r.memoUrl === rememberedUrl && r.blacklist === null &&
      r.crossbound === 0 && r.stdout === '',
    `elapsed=${r.elapsedMs} memo=${r.memoUrl} blacklist=${r.blacklist} crossbound=${r.crossbound} stdout=${r.stdout}`);
  cdp.stop();
}

{ // gate P1: an INCONCLUSIVE remembered render (shell that never hydrates) must not be laundered
  // into a confirmed absence by a successful tab listing. It consumes the short deadline by
  // repeatedly sampling the undecided shell, so the samples themselves prove the ordered state.
  const rememberedUrl = 'https://chatgpt.com/c/remembered';
  const shell = `Skip to content\nChat history\nNew chat\n${'Another conversation\n'.repeat(30)}`;
  const samples = [];
  const cdp = await mockCdp('__NO_TABS__', [], {
    trackCdpDeadlineEvents: true,
    renderText: (_url, n) => {
      samples.push(n);
      return shell;
    },
  });
  const r = await runFastCdpDeadlineSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, rememberedUrl));
  check('an undecided remembered conversation exits 7, not 4', r.status === 7, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('undecided remembered shell is sampled repeatedly and in order before exit',
    hasConsecutiveSamples(samples, 5) && cdp.scratchJsonListCalls >= 5,
    `samples=${samples} scratchLists=${cdp.scratchJsonListCalls}`);
  check('undecided remembered shell reaches the deadline without absence mutation',
    r.elapsedMs >= 2_500 && r.memoUrl === rememberedUrl && r.blacklist === null &&
      r.crossbound === 0 && r.stdout === '',
    `elapsed=${r.elapsedMs} memo=${r.memoUrl} blacklist=${r.blacklist} crossbound=${r.crossbound} stdout=${r.stdout}`);
  cdp.stop();
}

{ // ...but a memo that decisively points at ANOTHER run's conversation IS a real negative. A
  // foreign scratch sample makes that decision promptly; empty outer scans still carry it to the
  // deadline without turning it into a blacklist or a cross-bind conviction.
  const rememberedUrl = 'https://chatgpt.com/c/remembered';
  const samples = [];
  const cdp = await mockCdp('__NO_TABS__', [], {
    trackCdpDeadlineEvents: true,
    renderText: (_url, n) => {
      samples.push(n);
      return 'run marker: pg-run-someone-else-1111111111-9\na different review entirely';
    },
  });
  const r = await runFastCdpDeadlineSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, rememberedUrl));
  check('a stale memo pointing at another run still exits 4', r.status === 4, `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('a stale foreign remembered render records its decisive first sample',
    hasConsecutiveSamples(samples, 1) && samples.length === 1,
    `samples=${samples}`);
  check('a stale foreign memo remains a memo, not a blacklist or cross-bind mutation',
    r.memoUrl === rememberedUrl && r.memos.length === 1 && r.blacklist === null &&
      r.crossbound === 0 && r.stdout === '',
    `memo=${r.memoUrl} memos=${JSON.stringify(r.memos)} blacklist=${r.blacklist} crossbound=${r.crossbound} stdout=${r.stdout}`);
  check('a stale foreign memo continues through multiple empty scans to the deadline',
    r.elapsedMs >= 2_500 && cdp.outerJsonListCalls >= 3,
    `elapsed=${r.elapsedMs} outerLists=${cdp.outerJsonListCalls}`);
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
  // discarded, not re-memoized — and must NOT be returned as our review. Its first scratch
  // sample is decisive, while later empty scans prove the terminal state lasts to deadline.
  const rememberedUrl = 'https://chatgpt.com/c/crossbound';
  const samples = [];
  const cdp = await mockCdp('__NO_TABS__', [], {
    trackCdpDeadlineEvents: true,
    renderText: (_url, n) => {
      samples.push(n);
      return FOREIGN_ANSWER(MARKER);
    },
  });
  const r = await runFastCdpDeadlineSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, rememberedUrl));
  check('cross-bound memo is not accepted as our review', r.status !== 0, `status=${r.status}`);
  check('cross-bound memo exits 4 (decisive), not 7/3', r.status === 4, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  check('cross-bound memo is reported as another run\'s answer',
    /ANOTHER run's completed answer/.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(-400)}`);
  check('cross-bound memo names its conclusion as cross-bound',
    /^evidence-kind: cross-bound$/m.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(-400)}`);
  check('the poisoned memo file is deleted', (r.memos ?? []).length === 0, `memos=${JSON.stringify(r.memos)}`);
  check('no foreign review text is emitted on stdout',
    !/VERDICT/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 200)}`);
  check('cross-bound memo observes the decisive scratch sample before deleting state',
    hasConsecutiveSamples(samples, 1) && samples.length === 1,
    `samples=${samples}`);
  check('cross-bound memo writes marker-scoped blacklist and cross-bind evidence',
    (r.blacklist ?? '').includes(`${MARKER}\t${rememberedUrl}`) && r.crossbound > 0,
    `blacklist=${r.blacklist} crossbound=${r.crossbound}`);
  check('cross-bound memo keeps scanning empty tabs through the shortened deadline',
    r.elapsedMs >= 2_500 && cdp.outerJsonListCalls >= 3,
    `elapsed=${r.elapsedMs} outerLists=${cdp.outerJsonListCalls}`);
  cdp.stop();
}

{ // Same page shape, but arriving as an OPEN TAB rather than a memo: also refused. The
  // blacklisted source stays open; repeated fast outer scans must not re-emit or rehabilitate it.
  const sourceUrl = 'https://chatgpt.com/c/mock-conversation';
  const cdp = await mockCdp(FOREIGN_ANSWER(MARKER), [], { trackCdpDeadlineEvents: true });
  const r = await runFastPollSalvage([MARKER, '3'], cdp.port);
  check('an open tab with our marker but another run\'s answer is refused', r.status !== 0, `status=${r.status}`);
  check('open-tab cross-bind never emits the foreign review',
    !/VERDICT/.test(r.stdout ?? ''), `stdout=${r.stdout?.slice(0, 200)}`);
  check('open-tab cross-bind remains a decisive exit 4 and preserves the source tab',
    r.status === 4 && /ANOTHER run's completed answer/.test(r.stderr ?? '') && !cdp.closed.includes('tab1'),
    `status=${r.status} stderr=${r.stderr?.slice(-400)} closed=${cdp.closed}`);
  check('open-tab cross-bind records marker-scoped blacklist and cross-bind state',
    (r.blacklist ?? '').includes(`${MARKER}\t${sourceUrl}`) && r.crossbound > 0,
    `blacklist=${r.blacklist} crossbound=${r.crossbound}`);
  check('open-tab cross-bind makes multiple later lists through the shortened deadline',
    r.elapsedMs >= 2_500 && cdp.outerJsonListCalls >= 3,
    `elapsed=${r.elapsedMs} outerLists=${cdp.outerJsonListCalls}`);
  cdp.stop();
}

{ // #170: round TWO of the open-tab cross-bind above, with that run's state already on disk.
  // The conviction blacklisted its own URL, so this scan skips the tab BEFORE any marker
  // comparison and records no hits — emptiness produced by the suppression itself, not by the
  // conviction going stale. Deleting the sidecar on that emptiness made the two records
  // disagree: the append-only blacklist kept hiding the conversation while --status downgraded
  // "STUCK (cross-bound)" to "collect it for FREE", and the sidecar's URL — the only surviving
  // copy, since the conviction deleted conversation-urls/<marker> in the same breath — was gone.
  const sourceUrl = 'https://chatgpt.com/c/mock-conversation';
  const conviction = `2026-01-01T00:00:00.000Z\t${sourceUrl}\tpg-run-other-repo-42-1111111111-9\n`;
  const seedConvicted = (home) => {
    fs.mkdirSync(path.join(home, 'crossbound'), { recursive: true });
    fs.writeFileSync(path.join(home, 'crossbound', MARKER), conviction);
    fs.writeFileSync(path.join(home, 'salvage-nonmatching.txt'), `${MARKER}\t${sourceUrl}\n`);
  };
  const cdp = await mockCdp(FOREIGN_ANSWER(MARKER), [], { trackCdpDeadlineEvents: true });
  const r = await runFastPollSalvage([MARKER, '3'], cdp.port, seedConvicted);
  check('the blacklist skips the convicted tab before it can be re-classified',
    r.status === 4 && !/ANOTHER run's completed answer/.test(r.stderr ?? ''),
    `status=${r.status} stderr=${r.stderr?.slice(-400)}`);
  check('a blacklisted marker\'s sidecar survives a scan that finds nothing',
    r.crossbound > 0, `crossbound=${r.crossbound} stderr=${r.stderr?.slice(-300)}`);
  check('the surviving sidecar keeps the original conversation URL and foreign marker verbatim',
    r.crossboundBody === conviction, `body=${JSON.stringify(r.crossboundBody)}`);
  check('the blacklist entry that produced the empty scan is still there, so the records agree',
    (r.blacklist ?? '').includes(`${MARKER}\t${sourceUrl}`), `blacklist=${r.blacklist}`);
  cdp.stop();
}

{ // #170: making the sidecar durable would strand a review that FINISHED, because the invocation
  // that notices completion is pg_reservation_reconcile's periodic --probe, and probe was excluded
  // from the exit flush outright. --status ranks a conviction above `complete`, so the operator
  // would be told "STUCK ... retrying cannot bind" about a harvest that would in fact succeed.
  // A probe that PROVED ownership holds exactly the proof the flush requires, so it may now clear.
  const convictedUrl = 'https://chatgpt.com/c/convicted-duplicate';
  const conviction = `2026-01-01T00:00:00.000Z\t${convictedUrl}\tpg-run-other-repo-42-1111111111-9\n`;
  const seedConvicted = (home) => {
    fs.mkdirSync(path.join(home, 'crossbound'), { recursive: true });
    fs.writeFileSync(path.join(home, 'crossbound', MARKER), conviction);
    fs.writeFileSync(path.join(home, 'salvage-nonmatching.txt'), `${MARKER}\t${convictedUrl}\n`);
  };
  const ours = [
    `run marker: ${MARKER}`,
    '[P1] lib/z.sh:1 — ours',
    'P2: none',
    'P3: none',
    `VERDICT: SHIP — ours. (run marker: ${MARKER})`,
  ].join('\n');
  const doneCdp = await mockCdp(ours);
  const done = await runSalvage(['--probe', MARKER, '10'], doneCdp.port, seedConvicted);
  check('a probe that proves ownership reports the review complete',
    done.status === 0 && /^probe-state: complete$/m.test(done.stderr ?? ''),
    `status=${done.status} stderr=${done.stderr?.slice(-300)}`);
  check('the seed really was in place (blacklist entry survived the probe)',
    (done.blacklist ?? '').includes(`${MARKER}\t${convictedUrl}`), `blacklist=${done.blacklist}`);
  check('a probe that proves ownership clears the conviction instead of stranding it',
    done.crossbound === 0, `crossbound=${done.crossbound} body=${JSON.stringify(done.crossboundBody)}`);
  doneCdp.stop();

  // The other half of the contract: a probe that proves NOTHING stays read-only. It must neither
  // clear the conviction nor record one — the property the blanket exclusion used to guarantee.
  const openCdp = await mockCdp('__NO_TABS__', [], { trackCdpDeadlineEvents: true });
  const open = await runFastPollSalvage(['--probe', MARKER, '3'], openCdp.port, seedConvicted);
  check('a probe that proves nothing leaves the conviction exactly as it found it',
    open.crossboundBody === conviction, `body=${JSON.stringify(open.crossboundBody)} status=${open.status}`);
  openCdp.stop();
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

{ // #167: the marker was EXTRACTED case-insensitively but COMPARED case-sensitively, so a model
  // that lowercased its own echo read as a different run: the conversation was blacklisted, its
  // memo discarded, and this run's finished, PAID answer became unrecoverable. Both directions of
  // case drift are pinned — a model can shout as easily as it can whisper.
  //
  // The fold is safe because two genuinely different runs cannot differ ONLY in letter case: a
  // marker ends in "-<launch epoch>-<pid>" and one process has exactly one of each. The refusal
  // half of that argument is pinned immediately below, including a sibling run that folds to
  // nearly the same string and must still be refused.
  const answerWithEcho = (echo) => [
    `run marker: ${MIXED_MARKER}`,
    '',
    '[P1] lib/thing.sh:3 — a real finding',
    'P2: none',
    'P3: none',
    `VERDICT: FIX-FIRST — ours. (run marker: ${echo})`,
  ].join('\n');

  for (const [label, echo] of [
    ['a lowercased', MIXED_MARKER.toLowerCase()],
    ['an uppercased', MIXED_MARKER.toUpperCase()],
  ]) {
    const cdp = await mockCdp(answerWithEcho(echo));
    const r = await runSalvage([MIXED_MARKER, '20'], cdp.port);
    check(`${label} self-echo binds positively rather than convicting (exit 0)`, r.status === 0,
      `status=${r.status} stderr=${r.stderr?.slice(-400)}`);
    check(`${label} self-echo's review reaches stdout`, /VERDICT: FIX-FIRST/.test(r.stdout ?? ''),
      `stdout=${r.stdout?.slice(0, 200)}`);
    check(`${label} self-echo is never convicted cross-bound or blacklisted`,
      (r.crossbound ?? 0) === 0 && (r.blacklist ?? '') === '',
      `crossbound=${r.crossbound} blacklist=${r.blacklist}`);
    cdp.stop();
  }

  // NON-NEGOTIABLE: case is the only thing the fold may ignore. A marker for another repo, and a
  // SIBLING run of this same round that differs only in its pid, must both still be refused.
  for (const [label, foreign] of [
    ['a foreign marker', 'pg-run-other-repo-42-1111111111-9'],
    ['an uppercased foreign marker', 'PG-RUN-OTHER-REPO-42-1111111111-9'],
    ['a sibling run of the same round', 'pg-run-test-case-1234567890-44'],
  ]) {
    const cdp = await mockCdp(answerWithEcho(foreign));
    const r = await runSalvage([MIXED_MARKER, '3'], cdp.port);
    check(`${label} is still refused, never emitted as ours`,
      r.status !== 0 && !/VERDICT/.test(r.stdout ?? ''),
      `status=${r.status} stdout=${r.stdout?.slice(0, 200)}`);
    check(`${label} is still convicted as a cross-bind`, r.crossbound > 0,
      `crossbound=${r.crossbound} stderr=${r.stderr?.slice(-300)}`);
    cdp.stop();
  }
}

{ // #167: --close matches the tab by marker too. A conversation whose rendered text carries only
  // a case-drifted occurrence used to be left open, leaking a /c/ tab per run.
  const cdp = await mockCdp(
    `run marker: ${MIXED_MARKER.toLowerCase()}\nVERDICT: SHIP — ours. (run marker: ${MIXED_MARKER.toLowerCase()})`,
  );
  const r = await runSalvage(['--close', MIXED_MARKER, '10'], cdp.port);
  check('--close closes a conversation tab whose marker differs only in case',
    r.status === 0 && cdp.closed.includes('tab1'), `status=${r.status} closed=${cdp.closed}`);
  cdp.stop();
}

{ // #169 gate r1 P2: the fold above corrects the COMPARISON; it does not retract a conviction an
  // older pro-gate already reached. That conviction persisted "<marker>\t<url>" to
  // salvage-nonmatching.txt and deleted conversation-urls/<marker> — and both tab scans consult
  // the blacklist BEFORE the folded comparison, while the remembered-URL branch has no memo left.
  // So an already-convicted run stays unreachable after the upgrade, which is why v0.45.0's notes
  // document a per-run correction instead of promising that a harvest heals it.
  //
  // These three checks ARE that paragraph's proof. If the first goes red because salvage recovers
  // unaided, the release note is what changes; if either of the others goes red, the documented
  // procedure no longer works and the note is wrong.
  const CONVICTED_URL = 'https://chatgpt.com/c/mock-conversation';
  const convicted = [
    `run marker: ${MIXED_MARKER}`,
    'P0: none',
    'P1: none',
    'P2: none',
    'P3: none',
    `VERDICT: SHIP — ours. (run marker: ${MIXED_MARKER.toLowerCase()})`,
  ].join('\n');
  // Another run's conviction, left in place throughout: the documented correction removes ONE
  // line, and the recoveries below must succeed without touching anybody else's.
  const strangersLine = 'pg-run-other-repo-42-1111111111-9\thttps://chatgpt.com/c/someone-else\n';
  const writeBlacklist = (lines) => (home) =>
    fs.writeFileSync(path.join(home, 'salvage-nonmatching.txt'), lines);

  const stuck = await mockCdp(convicted);
  const stuckResult = await runSalvage([MIXED_MARKER, '3'], stuck.port,
    writeBlacklist(`${strangersLine}${MIXED_MARKER}\t${CONVICTED_URL}\n`));
  check('a pre-upgrade cross-bind conviction still hides a case-drifted self-echo after the fold fix',
    stuckResult.status !== 0 && !/VERDICT/.test(stuckResult.stdout ?? ''),
    `status=${stuckResult.status} stdout=${stuckResult.stdout?.slice(0, 200)}`);
  stuck.stop();

  // Documented step 3, tab still open: dropping that one line is what lets the scan classify the
  // conversation at all, and the fold then binds it.
  const openTab = await mockCdp(convicted);
  const openResult = await runSalvage([MIXED_MARKER, '20'], openTab.port, writeBlacklist(strangersLine));
  check("dropping only that run's blacklist line recovers the review from an open tab",
    openResult.status === 0 && /VERDICT: SHIP/.test(openResult.stdout ?? ''),
    `status=${openResult.status} stderr=${openResult.stderr?.slice(-300)}`);
  openTab.stop();

  // ...and with no tab left, the restored memo is the only handle there is — which is why the
  // documented correction rewrites conversation-urls/<marker> as well as dropping the line.
  const noTab = await mockCdp('__NO_TABS__', [], { renderText: () => convicted });
  const noTabResult = await runSalvage([MIXED_MARKER, '30'], noTab.port, (home) => {
    writeBlacklist(strangersLine)(home);
    seedMemo(MIXED_MARKER, CONVICTED_URL)(home);
  });
  check('restoring the URL memo recovers the review once no tab carries it',
    noTabResult.status === 0 && /VERDICT: SHIP/.test(noTabResult.stdout ?? ''),
    `status=${noTabResult.status} stderr=${noTabResult.stderr?.slice(-300)}`);
  noTab.stop();
}

{ // A still-generating conversation (our marker, NO completed verdict yet) must remain
  // "live", not be mistaken for a cross-bind: the foreign check only fires on a COMPLETE answer.
  // Its canonical scratch revalidation deliberately keeps sampling owned-incomplete evidence to
  // the deadline, so the shortened child records several ordered samples before exit 3.
  const sourceUrl = 'https://chatgpt.com/c/mock-conversation';
  const samples = [];
  const cdp = await mockCdp(`run marker: ${MARKER}\nthinking hard, no verdict yet`, [], {
    trackCdpDeadlineEvents: true,
    renderText: (_url, n) => {
      samples.push(n);
      return `run marker: ${MARKER}\nthinking hard, no verdict yet`;
    },
  });
  const r = await runFastCdpDeadlineSalvage([MARKER, '3'], cdp.port);
  check('still-generating stays exit 3 under the new check', r.status === 3, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  check('still-generating names its conclusion as owned-incomplete',
    /^evidence-kind: owned-incomplete$/m.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(-300)}`);
  check('still-generating samples owned-incomplete scratch state repeatedly and in order',
    hasConsecutiveSamples(samples, 5) && cdp.scratchJsonListCalls >= 5,
    `samples=${samples} scratchLists=${cdp.scratchJsonListCalls}`);
  check('still-generating reaches the deadline with a live source and untouched rejection state',
    r.elapsedMs >= 2_500 && cdp.outerJsonListCalls >= 2 && r.memoUrl === sourceUrl &&
      r.blacklist === null && r.crossbound === 0 && !cdp.closed.includes('tab1'),
    `elapsed=${r.elapsedMs} outerLists=${cdp.outerJsonListCalls} memo=${r.memoUrl} blacklist=${r.blacklist} crossbound=${r.crossbound} closed=${cdp.closed}`);
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
  // from merely-ambiguous (#68 gate P2). This separately proves the full deletion/blacklist/
  // sidecar contract under the short deadline rather than relying on the earlier cross-bind case.
  const rememberedUrl = 'https://chatgpt.com/c/crossbound2';
  const samples = [];
  const cdp = await mockCdp('__NO_TABS__', [], {
    trackCdpDeadlineEvents: true,
    renderText: (_url, n) => {
      samples.push(n);
      return FOREIGN_ANSWER(MARKER);
    },
  });
  const r = await runFastCdpDeadlineSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, rememberedUrl));
  check('a conviction is recorded in crossbound/<marker>', (r.crossbound ?? 0) > 0,
    `crossbound=${r.crossbound} stderr=${r.stderr?.slice(-300)}`);
  check('conviction keeps the decisive cross-bound exit and rejects all foreign output',
    r.status === 4 && !/VERDICT/.test(r.stdout ?? ''),
    `status=${r.status} stdout=${r.stdout}`);
  check('conviction deletes the poisoned memo and records its marker-scoped blacklist',
    r.memos.length === 0 && (r.blacklist ?? '').includes(`${MARKER}\t${rememberedUrl}`),
    `memos=${JSON.stringify(r.memos)} blacklist=${r.blacklist}`);
  check('conviction observes its decisive scratch sample then later empty deadline scans',
    hasConsecutiveSamples(samples, 1) && samples.length === 1 && r.elapsedMs >= 2_500 &&
      cdp.outerJsonListCalls >= 3,
    `samples=${samples} elapsed=${r.elapsedMs} outerLists=${cdp.outerJsonListCalls}`);
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

{ // #68 gate r2 P3: flat-text fallback keeps the first no-role run marker line as the prompt
  // boundary, so a later `run marker: <ours>` cannot erase an earlier foreign verdict.
  const foreign = 'pg-run-foreigntest-2619-1111111111-9';
  const promptBoundaryDrift = [
    `run marker: ${MARKER}`,
    '[P1] lib/example.sh:1 — mixed review sample',
    `VERDICT: FIX-FIRST — foreign run's claim. (run marker: ${foreign})`,
    '[P1] lib/example.sh:2 — prompt marker appears in findings text',
    `run marker: ${MARKER}`,
    'P2: none',
    `VERDICT: SHIP — ours. (run marker: ${MARKER})`,
  ].join('\n');
  const promptBoundaryCapture = promptBoundaryDrift.split('\n').slice(1).join('\n');
  const cdp = await mockCdp(promptBoundaryDrift);
  const capture = await runSalvage([MARKER, '15'], cdp.port);
  const binding = bindCapture(capture.stdout, MARKER);
  check(
    'flat-text foreign verdict survives a later own-marker line and fails shell binding',
    capture.status === 0 &&
      capture.stdout === promptBoundaryCapture + '\n' &&
      binding.status === 2 &&
      binding.retained === capture.stdout,
    'status=' + capture.status + ' bind=' + binding.status + ' stdout=' + JSON.stringify(capture.stdout),
  );
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

{ // gate round-2 P1: one EARLY successful listing must not mask a later CDP outage. Shutdown
  // waits for the child to open the listed primary tab and issue its DOM poll, so the fixture proves
  // the child consumed that successful outer list rather than merely racing res.end().
  const cdp = await mockCdp('some other conversation, no marker here', [], {
    trackCdpDeadlineEvents: true,
    stopAfterPrimaryDomPoll: 1,
  });
  const r = await runFastPollSalvage([MARKER, '3'], cdp.port);
  const failedLists = (r.stderr.match(/CDP list failed/g) ?? []).length;
  check('a later CDP outage is not masked by an early successful scan', r.status === 7, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  check('later-outage fixture records child primary-tab DOM consumption before shutdown',
    cdp.successfulJsonListCalls >= 1 && cdp.outerJsonListCalls >= 1 && cdp.primaryDomPolls >= 1 &&
      cdp.stoppedAfterPrimaryDomPoll === 1 && cdp.jsonListEvents[0]?.source === 'outer',
    `successful=${cdp.successfulJsonListCalls} outer=${cdp.outerJsonListCalls} primaryPolls=${cdp.primaryDomPolls} stoppedAfter=${cdp.stoppedAfterPrimaryDomPoll} events=${JSON.stringify(cdp.jsonListEvents)}`);
  check('later-outage fixture records at least one failed list after that consumed success',
    failedLists >= 1 && r.elapsedMs >= 2_500,
    `failedLists=${failedLists} elapsed=${r.elapsedMs} stderr=${r.stderr?.slice(-500)}`);
  cdp.stop();
}

{ // gate round-2 P1: the remembered conversation's tab is LISTED but its renderer is dead, and
  // re-rendering it proves it carries another run's marker. blacklist() no-ops on a remembered
  // URL, and the seeded branch is skipped while the tab is listed — so staleness has to be
  // recorded here or the reservation sits "inconclusive" forever instead of releasing.
  const rememberedUrl = 'https://chatgpt.com/c/mock-conversation';
  const samples = [];
  const cdp = await mockCdp('', [], {   // '' => renderer returns nothing => dead tab
    trackCdpDeadlineEvents: true,
    renderText: (_url, n) => {
      samples.push(n);
      return 'run marker: pg-run-someone-else-2222222222-3\nanother review entirely';
    },
  });
  const r = await runFastCdpDeadlineSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, rememberedUrl));
  check('a dead remembered tab proven foreign still exits 4', r.status === 4, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  check('dead remembered tab observes its decisive foreign scratch sample',
    hasConsecutiveSamples(samples, 1) && samples.length === 1,
    `samples=${samples}`);
  check('dead remembered foreign result retains its memo but avoids blacklist and cross-bind state',
    r.memoUrl === rememberedUrl && r.memos.length === 1 && r.blacklist === null &&
      r.crossbound === 0 && r.stdout === '' && !cdp.closed.includes('tab1'),
    `memo=${r.memoUrl} memos=${JSON.stringify(r.memos)} blacklist=${r.blacklist} crossbound=${r.crossbound} stdout=${r.stdout} closed=${cdp.closed}`);
  check('dead remembered tab continues listing through the shortened deadline after foreign proof',
    r.elapsedMs >= 2_500 && cdp.outerJsonListCalls >= 3,
    `elapsed=${r.elapsedMs} outerLists=${cdp.outerJsonListCalls}`);
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
  check('CDP down names its conclusion as browser-down',
    /^evidence-kind: browser-down$/m.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(0, 200)}`);
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

{ // P2: a Chrome that answers PUT /json/new with a non-JSON error must still fall through to the
  // documented pre-v111 GET fallback in openOrganizerScratch's path too, not read as
  // memo-open-failed.
  const title = 'pro-gate review: PR #71 r6c [pro-gate]';
  const remembered = 'https://chatgpt.com/c/tabless-owned-put-fails';
  const cdp = await mockCdp('__NO_TABS__', [], {
    renderText: () => `run marker: ${MARKER}\nserver-side conversation`,
    putNewFails: true,
  });
  const r = await runSalvage(
    ['--organize', MARKER, '5'],
    cdp.port,
    seedOrganizer(MARKER, title, remembered),
  );
  check('a non-JSON PUT error still reaches the GET fallback and opens the memo scratch tab',
    /source=memo rename=renamed/.test(r.stdout), `stdout=${r.stdout}`);
  check('the memo scratch tab was actually opened (via GET, after PUT failed)',
    cdp.created.length === 1 && cdp.created[0]?.url === remembered,
    `created=${JSON.stringify(cdp.created)}`);
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

{ // #167, mutation authority. organizerOwnership/finalizerOwnership are deliberately stricter
  // than salvage extraction, and their "exact marker echo" rule used to mean case-exact: a
  // lowercased self-echo returned cross-bound, so the run's own conversation was never renamed,
  // archived or closed. "Exact" now means token-exact, not case-exact.
  //
  // The finalizer case doubles as the strip contract's only end-to-end pin. Its accepted bytes
  // come from the ENGINE, whose pg_strip_nonce removed the echo case-insensitively; the browser
  // side must fold identically or the byte comparison lands on result-mismatch instead of ok.
  const title = 'pro-gate review: PR #167 r1 [pro-gate]';
  const lowerEcho = completedReview(MIXED_MARKER.toLowerCase(), 'case-drifted echo');
  const organizeCdp = await mockCdp(`run marker: ${MIXED_MARKER}\n${lowerEcho}`);
  const organizeResult = await runSalvage(
    ['--organize', MIXED_MARKER, '5'],
    organizeCdp.port,
    seedOrganizer(MIXED_MARKER, title),
  );
  check('organizer grants rename authority on a lowercased self-echo',
    /rename=renamed/.test(organizeResult.stdout) && /reason=ok/.test(organizeResult.stdout),
    `stdout=${organizeResult.stdout}`);
  check('organizer applies the exact title for a lowercased self-echo',
    organizeCdp.ui.title === title, `title=${organizeCdp.ui.title}`);
  organizeCdp.stop();

  const finalizeTitle = 'pro-gate review: PR #167 r2 [pro-gate]';
  const finalizeCdp = await mockCdp(`run marker: ${MIXED_MARKER}\n${lowerEcho}`);
  const finalizeResult = await runSalvage(
    finalizerArgs(MIXED_MARKER),
    finalizeCdp.port,
    seedOrganizer(MIXED_MARKER, finalizeTitle, null, durableReview(lowerEcho, MIXED_MARKER)),
  );
  check('finalizer accepts a lowercased self-echo and agrees with the engine-stripped bytes',
    /rename=renamed archive=archived close=closed reason=ok/.test(finalizeResult.stdout),
    `stdout=${finalizeResult.stdout}`);
  finalizeCdp.stop();

  // And still refuses a genuinely foreign echo, whatever its case: /i widens EXTRACTION, never
  // acceptance. Without this, an over-broad fold could grant mutation authority over another
  // run's live conversation.
  const foreignTitle = 'pro-gate review: PR #167 r3 [pro-gate]';
  const foreignEcho = completedReview('PG-RUN-OTHER-REPO-42-1111111111-9', 'not ours');
  const foreignCdp = await mockCdp(`run marker: ${MIXED_MARKER}\n${foreignEcho}`);
  const foreignResult = await runSalvage(
    ['--organize', MIXED_MARKER, '5'],
    foreignCdp.port,
    seedOrganizer(MIXED_MARKER, foreignTitle),
  );
  check('organizer still refuses an uppercased FOREIGN echo',
    /reason=cross-bound/.test(foreignResult.stdout) && foreignCdp.ui.events.length === 0,
    `stdout=${foreignResult.stdout} events=${JSON.stringify(foreignCdp.ui.events)}`);
  foreignCdp.stop();
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
      /matchAll\(\/pg-run-\[A-Za-z0-9.-\]\+\/gi\)/.test(renameExpression) &&
      /target-newer-run-marker/.test(renameExpression));
  // #167: the browser-side ownership check is a textual TWIN of cdp-salvage.mjs's, inlined into
  // a String.raw template because the page cannot import. A fix applied to one copy and not the
  // other is invisible at runtime until the organizer silently refuses to rename a conversation
  // whose only fault is that the model lowercased its own echo. Assert the fold is present here
  // AND that no bare case-sensitive comparison survives in the emitted source.
  check('browser-side marker identity is ASCII-case-folded, not byte-exact',
    /const asciiFold = /.test(renameExpression) &&
      /const sameMarker = /.test(renameExpression) &&
      /sameMarker\(answerMarker, expectedMarker\)/.test(renameExpression) &&
      !/answerMarker !== expectedMarker/.test(renameExpression));
  check('browser-side marker search folds the haystack, keeping indexes into the original text',
    /const haystack = asciiFold\(text\)/.test(renameExpression) &&
      /const needle = asciiFold\(wanted\)/.test(renameExpression) &&
      !/text\.indexOf\(wanted, from\)/.test(renameExpression));
  check('browser-side marker-echo strip folds the lookup but slices the original line',
    /asciiFold\(line\)\.indexOf\(asciiFold\(token\)\)/.test(renameExpression) &&
      !/const at = line\.indexOf\(token\)/.test(renameExpression));
  check('archive expression excludes destructive and reverse actions',
    /label\.includes\('delete'\)/.test(archiveExpression) &&
      /label\.includes\('unarchive'\)/.test(archiveExpression) &&
      /label\.includes\('restore'\)/.test(archiveExpression));
  check('archive expression verifies confirmation rather than trusting a click',
    /verifyArchivedStateFromMenu/.test(archiveExpression) && /hasArchiveToast/.test(archiveExpression));
  const formattedFixture = organizerExpressionFixture(
    `run marker: ${MARKER}\nP0: none\n**VERDICT:** SHIP (run marker: ${MARKER})`,
    { title: dangerousTitle },
  );
  const formattedResult = await runInNewContext(renameExpression, formattedFixture.context);
  check('UI mutation ownership accepts the same formatted VERDICT labels as salvage',
    formattedResult.status === 'already' && formattedFixture.sidebarReads() > 0,
    `result=${JSON.stringify(formattedResult)}`);
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

{ // #162: the throttle-modal page expression itself, executed against a minimal DOM stand-in. The
  // mock browsers answer this expression by sentinel, so this is the only place its element
  // scoping (dialog-only, marker-free, visible, bounded) is actually exercised.
  const expression = buildThrottleModalExpression();
  const modal = "Too many requests. You're making requests too quickly. We've temporarily limited access to your conversations to protect your data. Please wait a few minutes before trying again.";
  const node = (text, { rects = 1 } = {}) => ({
    innerText: text, textContent: text, getClientRects: () => Array.from({ length: rects }),
  });
  const evaluate = (dialogs) => new Function('document', `return ${expression};`)({ querySelectorAll: () => dialogs });
  check('modal expression carries the mock sentinel', expression.includes('pro-gate:throttle-modal'));
  check('modal expression reads the throttle copy from a visible dialog', evaluate([node(modal)]) === modal,
    `got=${evaluate([node(modal)])}`);
  check('modal expression sees no dialog on a page that only quotes the copy in its body', evaluate([]) === null);
  check('modal expression ignores a dialog that renders a run marker',
    evaluate([node(`${modal}\nrun marker: ${MARKER}`)]) === null);
  check('modal expression ignores a hidden dialog', evaluate([node(modal, { rects: 0 })]) === null);
  check('modal expression ignores an unrelated dialog', evaluate([node('Rename conversation\nSave')]) === null);
  check('modal expression ignores an oversized dialog', evaluate([node(`${modal}\n${'x'.repeat(2100)}`)]) === null);
  check('modal expression picks the throttle dialog among several',
    evaluate([node('Share link'), node(modal), node('Archive?')]) === modal);
  // The caller re-runs THROTTLE_RE over the returned value: a match that sits past any fixed
  // prefix must survive the round trip whole, or the modal goes undetected again.
  const latePhrase = `${'Before you continue, please read this notice. '.repeat(8)}${modal}`;
  check('modal expression returns the whole dialog text so a late match survives the caller recheck',
    latePhrase.length > 300 && latePhrase.length < 2000 && evaluate([node(latePhrase)]) === latePhrase,
    `length=${latePhrase.length}`);
}

{ // #162: ChatGPT's "Too many requests" modal shown OVER a real review conversation. The page is
  // long (far past the interstitial guard's 5,000 characters) and carries this run's marker, so
  // whole-page text shape can never call it a throttle; before this fix --probe read it as
  // `generating` for six hours (PR #148, 2026-09-05) and --harvest exited 9 at its deadline.
  const modal = "Too many requests. You're making requests too quickly. We've temporarily limited access to your conversations to protect your data. Please wait a few minutes before trying again.";
  const reasoning = Array.from({ length: 120 }, (_, i) =>
    `Reviewed concurrency risks in module ${i}: lock ordering, retry budgets, and reservation TTL handling.`).join('\n');
  const conversation = `${modal}\nrun marker: ${MARKER}\n${reasoning}\nReviewed concurrency risks`;
  check('modal fixture is longer than the interstitial guard and carries the marker',
    conversation.length > 5000 && conversation.includes(MARKER), `length=${conversation.length}`);

  const probed = await mockCdp(conversation, [], { throttleModal: modal });
  const r = await runSalvage(['--probe', MARKER, '3'], probed.port);
  check('probe under the throttle modal stays live (exit 0: a retry would double-spend)', r.status === 0,
    `status=${r.status} stderr=${r.stderr?.slice(0, 300)}`);
  check('probe under the throttle modal reports the closed throttled state, never generating',
    /^probe-state: throttled$/m.test(r.stderr || '') && !/^probe-state: generating$/m.test(r.stderr || ''),
    `stderr=${r.stderr?.slice(0, 300)}`);
  check('probe under the throttle modal writes the account cooldown naming the modal',
    /modal over tab/.test(r.cooldown ?? ''), `cooldown=${r.cooldown}`);
  check('probe under the throttle modal opens no scratch render against the limited account',
    probed.created.length === 0 && !probed.closed.includes('tab1'),
    `created=${JSON.stringify(probed.created)} closed=${probed.closed}`);
  probed.stop();

  const harvested = await mockCdp(conversation, [], { throttleModal: modal });
  const h = await runSalvage([MARKER, '3'], harvested.port);
  check('salvage under the throttle modal takes the existing throttle exit (5) and keeps the tab',
    h.status === 5 && !harvested.closed.includes('tab1') && /modal over tab/.test(h.cooldown ?? ''),
    `status=${h.status} closed=${harvested.closed} cooldown=${h.cooldown}`);
  check('salvage under the throttle modal prints no review', h.stdout === '', `stdout=${h.stdout}`);
  harvested.stop();

  // Planted negative: the same page shape with NO dialog element — the review merely quotes the
  // limiter's copy. Text shape alone would flag it; element detection must not.
  const quoting = `run marker: ${MARKER}\n${reasoning}\nThe engine's guard matches "You're making requests too quickly" and `
    + '"temporarily limited access to your conversations"; both phrases appear here as review text.';
  const quoted = await mockCdp(quoting);
  const q = await runSalvage(['--probe', MARKER, '3'], quoted.port);
  check('quoted throttle copy without a dialog still probes as generating with no cooldown',
    q.status === 0 && /^probe-state: generating$/m.test(q.stderr || '') && q.cooldown === null,
    `status=${q.status} cooldown=${q.cooldown} stderr=${q.stderr?.slice(0, 300)}`);
  quoted.stop();
  const finished = await mockCdp(`${quoting}\nP1: none\nVERDICT: SHIP — quotes the limiter copy. (run marker: ${MARKER})`);
  const d = await runSalvage([MARKER, '3'], finished.port);
  check('quoted throttle copy inside a finished review is still extracted (exit 0, no cooldown)',
    d.status === 0 && /VERDICT: SHIP/.test(d.stdout) && d.cooldown === null,
    `status=${d.status} cooldown=${d.cooldown} stdout=${d.stdout.slice(0, 120)}`);
  finished.stop();

  // The original interstitial guard's own false-positive case: a SHORT marker-less page quoting
  // the copy is the interstitial, and a long marker-bearing page quoting it is not.
  const shortQuote = `The guard matches "temporarily limited access to your conversations".`;
  check('interstitial guard still treats a short marker-less page with the copy as the interstitial',
    shortQuote.length < 5000 && !/pg-run-/.test(shortQuote));
  const interstitial = await mockCdp(shortQuote);
  const i = await runSalvage(['--probe', MARKER, '3'], interstitial.port);
  check('short marker-less page with the copy keeps the existing interstitial exit (5)',
    i.status === 5 && /tab /.test(i.cooldown ?? ''), `status=${i.status} cooldown=${i.cooldown}`);
  interstitial.stop();

  // The modal over ANOTHER run's conversation proves the limiter, not our conversation's
  // existence: probe must not answer "live" for a page that renders a foreign marker.
  const foreign = `${modal}\nrun marker: pg-run-other-1111111111-1\n${reasoning}`;
  const foreignCdp = await mockCdp(foreign, [], { throttleModal: modal });
  const f = await runSalvage(['--probe', MARKER, '3'], foreignCdp.port);
  check("probe: modal over another run's conversation proves only the limiter (exit 5, cooldown written)",
    f.status === 5 && /modal over tab/.test(f.cooldown ?? '') && !/^probe-state:/m.test(f.stderr || ''),
    `status=${f.status} cooldown=${f.cooldown} stderr=${f.stderr?.slice(0, 200)}`);
  foreignCdp.stop();

  // The modal is account-wide, so with several tabs open it covers all of them. Ownership must be
  // decided over the whole scan: a foreign conversation listed FIRST must not hide the proof that
  // the second tab renders this run's marker.
  const ownUrl = 'https://chatgpt.com/c/ours-under-the-modal';
  const twoTabs = await mockCdp(`${modal}\nrun marker: pg-run-other-1111111111-1\n${reasoning}`,
    [{ id: 'ours', url: ownUrl }],
    { tabText: (url, id) => (id === 'ours' ? conversation : null), throttleModal: () => modal });
  const two = await runSalvage(['--probe', MARKER, '3'], twoTabs.port);
  check('probe: a foreign tab listed ahead of ours under the same modal still proves our conversation (live, throttled)',
    two.status === 0 && /^probe-state: throttled$/m.test(two.stderr || '') && two.stderr.includes(`live conversation: ${ownUrl}`),
    `status=${two.status} stderr=${two.stderr?.slice(0, 300)}`);
  check('two-tab modal names the owned tab in the cooldown', (two.cooldown ?? '').includes(ownUrl), `cooldown=${two.cooldown}`);
  twoTabs.stop();
  const twoTabsBlacklisted = await mockCdp(`${modal}\nrun marker: pg-run-other-1111111111-1\n${reasoning}`,
    [{ id: 'ours', url: ownUrl }],
    { tabText: (url, id) => (id === 'ours' ? conversation : null), throttleModal: () => modal });
  const seedBlacklist = (home) => fs.writeFileSync(path.join(home, 'salvage-nonmatching.txt'), `${MARKER}\t${ownUrl}\n`);
  const blk = await runSalvage(['--probe', MARKER, '3'], twoTabsBlacklisted.port, seedBlacklist);
  check('probe: a blacklisted marker-bearing tab under the modal proves only the limiter (exit 5)',
    blk.status === 5 && !/^probe-state:/m.test(blk.stderr || ''), `status=${blk.status} stderr=${blk.stderr?.slice(0, 200)}`);
  twoTabsBlacklisted.stop();

  // A remembered conversation re-rendered in a scratch tab can come up under the modal too:
  // the render must stop on the element, not fall through to "marker found, still generating".
  const canonicalUrl = 'https://chatgpt.com/c/mock-conversation';
  const scratchModal = await mockCdp('__NO_TABS__', [], {
    renderText: () => conversation,
    throttleModal: (id) => (id.startsWith('scratch') ? modal : null),
  });
  const sr = await runScratchSalvage(['--probe', MARKER, '3'], scratchModal.port, seedMemo(MARKER, canonicalUrl));
  check('remembered render under the throttle modal probes as live but throttled',
    sr.status === 0 && /^probe-state: throttled$/m.test(sr.stderr || '') && /remembered render/.test(sr.cooldown ?? ''),
    `status=${sr.status} cooldown=${sr.cooldown} stderr=${sr.stderr?.slice(0, 300)}`);
  check('remembered render under the throttle modal closes its scratch tab',
    scratchModal.created.length === 1 && scratchModal.closed.includes(scratchModal.created[0].id),
    `created=${JSON.stringify(scratchModal.created)} closed=${scratchModal.closed}`);
  scratchModal.stop();
}

{ // #208: an abandoned throttle modal on an UNOWNED tab (another run's stale, hours-old
  // conversation) is account-wide throttle evidence, but nothing ever closes that tab or clears
  // its modal — so a caller that waits out `seconds_remaining` and retries has the sweep re-detect
  // the exact same stale sighting and rewrite throttle.cooldown again, forever (observed: 3
  // attempts / 1h45m, pushbot PR #3225). A sidecar (throttle.cooldown.seen) fingerprints (tab url,
  // sha256 of modal/page text) pairs a scan has already charged, so a repeat of the SAME stale
  // sighting is ignored instead of re-arming the timer. Planted negative: an OWNED sighting (this
  // run's exact marker under the modal) must keep re-arming unconditionally every time — #162's
  // existing contract — never routed through this dedupe at all.
  const modal = "Too many requests. You're making requests too quickly. We've temporarily limited access to your conversations to protect your data. Please wait a few minutes before trying again.";
  const reasoning = Array.from({ length: 120 }, (_, i) =>
    `Reviewed concurrency risks in module ${i}: lock ordering, retry budgets, and reservation TTL handling.`).join('\n');
  const foreign = `${modal}\nrun marker: pg-run-other-1111111111-1\n${reasoning}`;
  const oldMtime = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };

  // (1) First unowned modal sighting: cooldown written, exit 5, tab recorded in the seen sidecar.
  const home1 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdp1a = await mockCdp(foreign, [], { throttleModal: modal });
  const first = await runSalvageInHome(home1, [MARKER, '3'], cdp1a.port);
  check('#208 (1) first unowned throttle modal sighting takes the throttle exit (5)', first.status === 5,
    `status=${first.status} stderr=${first.stderr?.slice(0, 200)}`);
  check('#208 (1) first unowned throttle modal sighting writes the cooldown naming the modal',
    /modal over tab/.test(first.cooldown ?? ''), `cooldown=${first.cooldown}`);
  check('#208 (1) first unowned throttle modal sighting records the tab in the seen sidecar',
    throttleSeenHas(home1, 'https://chatgpt.com/c/mock-conversation', modal),
    `throttleSeen=${fs.existsSync(throttleSeenDir(home1)) ? fs.readdirSync(throttleSeenDir(home1)) : null}`);
  cdp1a.stop();

  // (2) A retry that finds the exact same stale tab (same url, same modal text) must not rewrite
  // the cooldown: the sentinel mtime (artificially aged so any rewrite is unmistakable) survives,
  // the run does not take the throttle exit, and stderr names the stale tab it ignored.
  const cooldownPath1 = path.join(home1, 'throttle.cooldown');
  oldMtime(cooldownPath1);
  const mtimeBefore1 = fs.statSync(cooldownPath1).mtimeMs;
  const cdp1b = await mockCdp(foreign, [], { throttleModal: modal });
  const second = await runSalvageInHome(home1, [MARKER, '3'], cdp1b.port);
  const mtimeAfter1 = fs.statSync(cooldownPath1).mtimeMs;
  check('#208 (2) a repeat sighting of the same stale tab does not rewrite the cooldown file',
    mtimeAfter1 === mtimeBefore1, `before=${mtimeBefore1} after=${mtimeAfter1}`);
  check('#208 (2) a repeat sighting of the same stale tab does not take the throttle exit',
    second.status !== 5, `status=${second.status}`);
  check('#208 (2) a repeat sighting of the same stale tab names the stale tab on stderr',
    /stale throttle modal on unowned tab https:\/\/chatgpt\.com\/c\/mock-conversation already charged/.test(second.stderr || ''),
    `stderr=${second.stderr?.slice(0, 300)}`);
  cdp1b.stop();

  // (4) A genuinely new unowned sighting — a DIFFERENT tab carrying the same modal text — is not
  // suppressed by (2)'s dedupe: the cooldown is rewritten and the tab is charged, because the seen
  // key is (url, hash), not the hash alone.
  const secondForeignUrl = 'https://chatgpt.com/c/another-stale-conversation';
  const secondForeignText = `${modal}\nrun marker: pg-run-other-2222222222-2\n${reasoning}`;
  const cdp1c = await mockCdp('__NO_TABS__', [{ id: 'other2', url: secondForeignUrl }],
    { tabText: () => secondForeignText, throttleModal: () => modal });
  const fourth = await runSalvageInHome(home1, [MARKER, '3'], cdp1c.port);
  check('#208 (4) a new unowned modal on a different tab takes the throttle exit (5)', fourth.status === 5,
    `status=${fourth.status} stderr=${fourth.stderr?.slice(0, 200)}`);
  check('#208 (4) a new unowned modal on a different tab rewrites the cooldown naming that tab',
    (fourth.cooldown ?? '').includes(secondForeignUrl), `cooldown=${fourth.cooldown}`);
  check('#208 (4) a new unowned modal on a different tab is added to the seen sidecar',
    throttleSeenHas(home1, secondForeignUrl, modal),
    `throttleSeen=${fs.existsSync(throttleSeenDir(home1)) ? fs.readdirSync(throttleSeenDir(home1)) : null}`);
  cdp1c.stop();

  // (5) A stale, already-charged tab listed FIRST must not hide a genuinely new foreign modal
  // listed behind it: the whole-scan fallback walks the unowned hits in list order, the dedupe
  // gate skips the stale one (still named on stderr), and the new tab is the one charged.
  const thirdForeignUrl = 'https://chatgpt.com/c/third-stale-conversation';
  const thirdForeignText = `${modal}\nrun marker: pg-run-other-3333333333-3\n${reasoning}`;
  const cdp1d = await mockCdp(foreign, [{ id: 'other3', url: thirdForeignUrl }],
    { tabText: (url) => (url === thirdForeignUrl ? thirdForeignText : undefined), throttleModal: () => modal });
  const fifth = await runSalvageInHome(home1, [MARKER, '3'], cdp1d.port);
  check('#208 (5) a stale tab listed first does not hide a new unowned modal behind it: throttle exit (5)',
    fifth.status === 5, `status=${fifth.status} stderr=${fifth.stderr?.slice(0, 300)}`);
  check('#208 (5) the new tab behind the stale one is the tab charged in the cooldown',
    (fifth.cooldown ?? '').includes(thirdForeignUrl), `cooldown=${fifth.cooldown}`);
  check('#208 (5) the stale tab listed first is still named as ignored on stderr',
    /stale throttle modal on unowned tab https:\/\/chatgpt\.com\/c\/mock-conversation already charged/.test(fifth.stderr || ''),
    `stderr=${fifth.stderr?.slice(0, 300)}`);
  cdp1d.stop();
  fs.rmSync(home1, { recursive: true, force: true });

  // (3) Planted negative: an OWNED sighting (this run's exact marker under the modal) re-arms the
  // cooldown unconditionally on EVERY repeat — #162's existing contract — never deduped like an
  // unowned sighting. Same stale-mtime technique as (2), opposite expected outcome.
  const owned = `${modal}\nrun marker: ${MARKER}\n${reasoning}\nReviewed concurrency risks`;
  const home3 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdp3a = await mockCdp(owned, [], { throttleModal: modal });
  const owned1 = await runSalvageInHome(home3, ['--probe', MARKER, '3'], cdp3a.port);
  check('#208 (3) planted negative: first owned modal sighting writes the cooldown',
    /modal over tab/.test(owned1.cooldown ?? ''), `cooldown=${owned1.cooldown}`);
  cdp3a.stop();
  const cooldownPath3 = path.join(home3, 'throttle.cooldown');
  oldMtime(cooldownPath3);
  const mtimeBefore3 = fs.statSync(cooldownPath3).mtimeMs;
  const cdp3b = await mockCdp(owned, [], { throttleModal: modal });
  const owned2 = await runSalvageInHome(home3, ['--probe', MARKER, '3'], cdp3b.port);
  const mtimeAfter3 = fs.statSync(cooldownPath3).mtimeMs;
  check('#208 (3) planted negative: an owned throttle modal re-arms the cooldown on every repeat (never deduped)',
    mtimeAfter3 > mtimeBefore3, `before=${mtimeBefore3} after=${mtimeAfter3}`);
  check('#208 (3) owned repeat still reports the closed throttled state, never generating',
    owned2.status === 0 && /^probe-state: throttled$/m.test(owned2.stderr || ''), `status=${owned2.status} stderr=${owned2.stderr?.slice(0, 200)}`);
  cdp3b.stop();
  fs.rmSync(home3, { recursive: true, force: true });

  // Also exercise the per-tab isThrottlePage trip site (site 2, distinct from the whole-scan modal
  // fallback exercised above): a short marker-less interstitial page, with no modal element at
  // all, must be deduped the same way on a repeat.
  const home5 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdp5a = await mockCdp(modal);
  const site2First = await runSalvageInHome(home5, [MARKER, '3'], cdp5a.port);
  check('#208 (site 2: isThrottlePage) first unowned interstitial sighting takes the throttle exit',
    site2First.status === 5 && /tab https:\/\/chatgpt\.com\/c\/mock-conversation/.test(site2First.cooldown ?? ''),
    `status=${site2First.status} cooldown=${site2First.cooldown}`);
  cdp5a.stop();
  const cooldownPath5 = path.join(home5, 'throttle.cooldown');
  oldMtime(cooldownPath5);
  const mtimeBefore5 = fs.statSync(cooldownPath5).mtimeMs;
  const cdp5b = await mockCdp(modal);
  const site2Second = await runSalvageInHome(home5, [MARKER, '3'], cdp5b.port);
  const mtimeAfter5 = fs.statSync(cooldownPath5).mtimeMs;
  check('#208 (site 2: isThrottlePage) a repeat interstitial sighting on the same tab does not rewrite the cooldown',
    mtimeAfter5 === mtimeBefore5, `before=${mtimeBefore5} after=${mtimeAfter5}`);
  check('#208 (site 2: isThrottlePage) a repeat interstitial sighting does not take the throttle exit',
    site2Second.status !== 5, `status=${site2Second.status}`);
  cdp5b.stop();
  fs.rmSync(home5, { recursive: true, force: true });
}

{ // #208 gate r1 P1 regression: a marker-less stale tab whose WHOLE PAGE TEXT satisfies
  // isThrottlePage while it ALSO carries a distinct throttle modal used to fingerprint under TWO
  // different hashes depending on which trip site reached it first — the whole-scan modal
  // fallback always hashed the modal text, but the (pre-fix) per-tab isThrottlePage check hashed
  // the raw page text instead. The seen sidecar recognized only the MOST RECENT of the two
  // hashes for a URL (replace, not append), so the tab kept "newly" tripping every other
  // invocation forever — the exact livelock #208 was supposed to end. Fixed by (a) hashing the
  // modal text everywhere a modal is present (including this classifier branch and the per-tab
  // site), (b) never re-classifying a modal-bearing tab through the per-tab interstitial check
  // (the whole-scan block already decided it), and (c) a bounded multi-hash-per-URL sidecar as a
  // second line of defense.
  const modalText = "You're making requests too quickly. Temporarily limited access to your conversations.";
  const pageText = `ChatGPT\nAccount limits\n${modalText}\nPlease try again shortly.\n`;
  const oldMtime = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };

  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));

  // Run 1: first sighting of this stale tab takes the throttle exit and writes the cooldown.
  const cdpA = await mockCdp(pageText, [], { throttleModal: modalText });
  const first = await runSalvageInHome(home, [MARKER, '3'], cdpA.port);
  check('#208 P1 (1) first sighting of a marker-less modal+interstitial page takes the throttle exit (5)',
    first.status === 5, `status=${first.status} stderr=${first.stderr?.slice(0, 300)}`);
  cdpA.stop();

  // Run 2: the SAME stale tab, completely unchanged — sentinel mtime aged so any rewrite is
  // unmistakable. On the pre-fix script this is where the second fingerprint (raw page text)
  // trips as "new" and rewrites the cooldown (RED).
  const cooldownPath = path.join(home, 'throttle.cooldown');
  oldMtime(cooldownPath);
  const mtimeBefore2 = fs.statSync(cooldownPath).mtimeMs;
  const cdpB = await mockCdp(pageText, [], { throttleModal: modalText });
  const second = await runSalvageInHome(home, [MARKER, '3'], cdpB.port);
  const mtimeAfter2 = fs.statSync(cooldownPath).mtimeMs;
  check('#208 P1 (2) an unchanged stale tab does not rewrite the cooldown on the next pass',
    mtimeAfter2 === mtimeBefore2, `before=${mtimeBefore2} after=${mtimeAfter2}`);
  check('#208 P1 (2) an unchanged stale tab does not take the throttle exit on the next pass',
    second.status !== 5, `status=${second.status}`);
  cdpB.stop();

  // Run 3: same stale tab again. The pre-fix bug alternated hash sites every OTHER pass, so a
  // single repeat could get lucky; a third pass confirms convergence, not alternation.
  oldMtime(cooldownPath);
  const mtimeBefore3 = fs.statSync(cooldownPath).mtimeMs;
  const cdpC = await mockCdp(pageText, [], { throttleModal: modalText });
  const third = await runSalvageInHome(home, [MARKER, '3'], cdpC.port);
  const mtimeAfter3 = fs.statSync(cooldownPath).mtimeMs;
  check('#208 P1 (3) a third pass over the same unchanged stale tab still does not rewrite the cooldown',
    mtimeAfter3 === mtimeBefore3, `before=${mtimeBefore3} after=${mtimeAfter3}`);
  check('#208 P1 (3) a third pass over the same unchanged stale tab still does not take the throttle exit',
    third.status !== 5, `status=${third.status}`);
  cdpC.stop();
  fs.rmSync(home, { recursive: true, force: true });

  // Planted negative: an OWNED tab of the same shape (marker present, modal present) must keep
  // re-arming the cooldown on EVERY pass — #162's existing contract, never routed through this
  // dedupe at all. A marker anywhere in the text also makes isThrottlePage(text) false (it
  // requires no run marker, ours or foreign), so this exercises the modal branch, not the
  // interstitial branch above — the two must not be conflated.
  const ownedText = `ChatGPT\nAccount limits\n${modalText}\nrun marker: ${MARKER}\nPlease try again shortly.\n`;
  const homeOwned = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpOwnedA = await mockCdp(ownedText, [], { throttleModal: modalText });
  const ownedFirst = await runSalvageInHome(homeOwned, ['--probe', MARKER, '3'], cdpOwnedA.port);
  check('#208 P1 planted negative: first owned sighting writes the cooldown',
    /modal over tab/.test(ownedFirst.cooldown ?? ''), `cooldown=${ownedFirst.cooldown}`);
  cdpOwnedA.stop();
  const cooldownPathOwned = path.join(homeOwned, 'throttle.cooldown');
  oldMtime(cooldownPathOwned);
  const mtimeBeforeOwned = fs.statSync(cooldownPathOwned).mtimeMs;
  const cdpOwnedB = await mockCdp(ownedText, [], { throttleModal: modalText });
  const ownedSecond = await runSalvageInHome(homeOwned, ['--probe', MARKER, '3'], cdpOwnedB.port);
  const mtimeAfterOwned = fs.statSync(cooldownPathOwned).mtimeMs;
  check('#208 P1 planted negative: an owned tab of the same shape re-arms the cooldown on every repeat',
    mtimeAfterOwned > mtimeBeforeOwned, `before=${mtimeBeforeOwned} after=${mtimeAfterOwned}`);
  check('#208 P1 planted negative: owned repeat still reports the closed throttled state',
    ownedSecond.status === 0 && /^probe-state: throttled$/m.test(ownedSecond.stderr || ''),
    `status=${ownedSecond.status} stderr=${ownedSecond.stderr?.slice(0, 200)}`);
  cdpOwnedB.stop();
  fs.rmSync(homeOwned, { recursive: true, force: true });
}

{ // #208 gate r1 P1 (item 3): the same modal-preferred-fingerprint fix in classifyEvidence's
  // interstitial branch (~1376) is reachable through the existing remembered-URL scratch-render
  // recovery path — a THIRD trip site, distinct from the two exercised above. Run 1 sees the tab
  // OPEN (whole-scan modal fallback trips on the modal hash and remembers the URL). Run 2 sees
  // the SAME tab CLOSED, so the v0.25 remembered-conversation recovery scratch-renders that URL
  // and reaches classifyEvidence's interstitial branch instead — a genuinely different site than
  // run 1's, for the SAME unchanged conversation. Pre-fix that branch hashed the raw page text,
  // disagreeing with run 1's modal-text hash, so it read as "new" and re-tripped (the same
  // two-site alternation #208 was supposed to end, just through this pair of sites instead of
  // the whole-scan-fallback/per-tab pair covered above).
  const modalText3 = "You're making requests too quickly. Temporarily limited access to your conversations.";
  const pageText3 = `ChatGPT\nAccount limits\n${modalText3}\nA scratch render of the remembered conversation.\n`;
  const canonicalUrl3 = 'https://chatgpt.com/c/mock-conversation';
  const oldMtime3 = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };

  const home3 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedMemo(MARKER, canonicalUrl3)(home3);

  // Run 1: the tab is OPEN — trips via the whole-scan modal fallback (site 1), hashing the modal
  // text. This site already hashed the modal text both before and after the fix; it is not the
  // regression, it is what establishes the "already charged" fingerprint run 2 must agree with.
  const cdpS1 = await mockCdp(pageText3, [], { throttleModal: modalText3 });
  const scratchFirst = await runSalvageInHome(home3, [MARKER, '3'], cdpS1.port);
  check('#208 P1 (classifier/scratch) run 1: the open tab takes the throttle exit (5) via the whole-scan modal fallback',
    scratchFirst.status === 5, `status=${scratchFirst.status} stderr=${scratchFirst.stderr?.slice(0, 300)}`);
  cdpS1.stop();

  // Run 2: the SAME tab is now CLOSED (__NO_TABS__) but the memo still remembers its URL, so the
  // remembered-conversation recovery scratch-renders it — reaching classifyEvidence's
  // interstitial branch (site 3) for the identical unchanged page.
  const cooldownPath3 = path.join(home3, 'throttle.cooldown');
  oldMtime3(cooldownPath3);
  const mtimeBeforeS = fs.statSync(cooldownPath3).mtimeMs;
  const cdpS2 = await mockCdp('__NO_TABS__', [], {
    renderText: () => pageText3,
    throttleModal: (id) => (id.startsWith('scratch') ? modalText3 : null),
  });
  const scratchSecond = await runSalvageInHome(home3, [MARKER, '3'], cdpS2.port, SCRATCH_SAMPLE_TEST_ENV);
  const mtimeAfterS = fs.statSync(cooldownPath3).mtimeMs;
  check('#208 P1 (classifier/scratch) run 2: the remembered-URL re-render of the same unchanged page does not rewrite the cooldown',
    mtimeAfterS === mtimeBeforeS, `before=${mtimeBeforeS} after=${mtimeAfterS}`);
  check('#208 P1 (classifier/scratch) run 2: the remembered-URL re-render of the same unchanged page does not take the throttle exit',
    scratchSecond.status !== 5, `status=${scratchSecond.status}`);
  cdpS2.stop();
  fs.rmSync(home3, { recursive: true, force: true });
}

{ // #208 gate r1 P2 regression: --organize checked only throttleHits[0]. With an already-charged
  // unowned tab listed FIRST and a genuinely new unowned modal listed behind it, tripThrottleUnowned
  // returned false for the first hit and the block exited without ever examining the second, so
  // --organize proceeded toward scratch navigation/rename/archive without updating the cooldown.
  // Fixed by walking ALL unowned hits in list order, mirroring the main loop's whole-scan walk.
  const title = 'pro-gate review: PR #208 organizer P2 [pro-gate]';
  const staleUrl = 'https://chatgpt.com/c/mock-conversation';    // primary tab, listed FIRST
  const newUrl = 'https://chatgpt.com/c/organizer-new-throttle'; // extra tab, listed SECOND
  const staleModal = "You're making requests too quickly. Temporarily limited access to your conversations.";
  const newModal = staleModal; // same account-wide copy; the dedupe key is (url, hash), not hash alone
  const staleText = 'ChatGPT interstitial (stale tab)';
  const newText = 'ChatGPT interstitial (new tab)';

  // A stale unowned sighting was already charged by an earlier organizer scan.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, title)(home);
  seedThrottleSeen(home, staleUrl, staleModal);

  const cdp = await mockCdp(staleText, [{ id: 'new1', url: newUrl }], {
    tabText: (url) => (url === newUrl ? newText : undefined),
    throttleModal: (id) => (id === 'new1' ? newModal : staleModal),
  });
  const r = await runSalvageInHome(home, ['--organize', MARKER, '5'], cdp.port);
  check('#208 P2 organizer: a new unowned modal behind an already-charged stale one still reports reason=throttle',
    /reason=throttle/.test(r.stdout), `stdout=${r.stdout} stderr=${r.stderr?.slice(0, 300)}`);
  check('#208 P2 organizer: the already-charged stale tab listed first is still named as ignored on stderr',
    r.stderr?.includes(`stale throttle modal on unowned tab ${staleUrl} already charged`),
    `stderr=${r.stderr?.slice(0, 400)}`);
  check('#208 P2 organizer: the new tab behind the stale one is newly recorded in the seen sidecar',
    throttleSeenHas(home, newUrl, newModal),
    `throttleSeen=${fs.existsSync(throttleSeenDir(home)) ? fs.readdirSync(throttleSeenDir(home)) : null}`);
  check('#208 P2 organizer: no rename/archive mutation happened',
    cdp.ui.events.length === 0, `events=${JSON.stringify(cdp.ui.events)}`);
  cdp.stop();
  fs.rmSync(home, { recursive: true, force: true });

  // Planted negative: with BOTH sightings already charged, no unowned hit is newly admitted, so
  // the organizer falls through as though no modal were present — no reason=throttle, no cooldown.
  const home2 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, title)(home2);
  seedThrottleSeen(home2, staleUrl, staleModal);
  seedThrottleSeen(home2, newUrl, newModal);
  const cdp2 = await mockCdp(staleText, [{ id: 'new1', url: newUrl }], {
    tabText: (url) => (url === newUrl ? newText : undefined),
    throttleModal: (id) => (id === 'new1' ? newModal : staleModal),
  });
  const r2 = await runSalvageInHome(home2, ['--organize', MARKER, '5'], cdp2.port);
  // #208 gate r2 P1: this scenario is now the organizer's "absence-like conclusion" case the P1
  // fix explicitly targets ("Apply the same rule to the organizer's throttled-but-ignored case if
  // it can reach an absence-like conclusion"). Neither staleModal nor newModal carries any run
  // marker (ours or foreign), so both are non-foreign unowned throttle sightings; with no
  // recovery URL at all (seedOrganizer was called with no memo url), the organizer must now
  // report the inconclusive throttle reason rather than silently falling through as if nothing
  // were seen — even though every sighting this scan found was already charged and no NEW cooldown
  // is written. Pre-fix, this same scenario asserted the opposite (no reason=throttle); that
  // assertion is intentionally flipped here to match the mandated behavior change, not weakened.
  check('#208 gate r2 P1 organizer: with every sighting already charged and no recovery URL, the organizer still reports the inconclusive throttle reason',
    /reason=throttle/.test(r2.stdout), `stdout=${r2.stdout}`);
  check('#208 gate r2 P1 organizer: with every sighting already charged, no NEW cooldown is written',
    r2.cooldown === null, `cooldown=${r2.cooldown}`);
  cdp2.stop();
  fs.rmSync(home2, { recursive: true, force: true });

  // Genuinely fresh planted negative: an organizer scan with NO throttle involvement at all (no
  // modal, no interstitial, nothing already charged) must not report reason=throttle and must not
  // write a cooldown — preserving honest planted-negative coverage for the "nothing happened" case
  // now that the previous scenario's truth value has correctly flipped to reason=throttle.
  const home2b = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, title)(home2b);
  const cdp2b = await mockCdp('__NO_TABS__');
  const r2b = await runSalvageInHome(home2b, ['--organize', MARKER, '5'], cdp2b.port);
  check('#208 gate r2 P1 organizer planted negative: with no throttle involvement at all, the organizer does not report reason=throttle',
    !/reason=throttle/.test(r2b.stdout) && /reason=owned-target-not-found/.test(r2b.stdout),
    `stdout=${r2b.stdout} stderr=${r2b.stderr?.slice(0, 300)}`);
  check('#208 gate r2 P1 organizer planted negative: with no throttle involvement at all, no cooldown is written',
    r2b.cooldown === null, `cooldown=${r2b.cooldown}`);
  cdp2b.stop();
  fs.rmSync(home2b, { recursive: true, force: true });
}

{ // #208 gate r2 P1 (main scan): a markerless throttle INTERSTITIAL (no modal element — the bare
  // isThrottlePage check) on an unowned tab must not let a repeat, already-charged sighting fall
  // through to a confirmed-absent exit 4 — that wrongly spends a paid review's finite
  // recovery-miss budget on nothing but the account limiter. A repeat sighting of the SAME
  // markerless tab must retreat to exit 7 (inconclusive), name why on stderr, and must NOT
  // rewrite the cooldown (cooldown dedup is a rate-limit decision, not an ownership one).
  const interstitialUrl = 'https://chatgpt.com/c/mock-interstitial-tab';
  const interstitialText = "You're making requests too quickly. Please wait a few minutes before trying again.";
  const oldMtimeI = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };

  const homeI = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpI1 = await mockCdp('__NO_TABS__', [{ id: 'interstitial1', url: interstitialUrl }], {
    tabText: () => interstitialText,
  });
  const firstI = await runSalvageInHome(homeI, [MARKER, '3'], cdpI1.port);
  check('#208 gate r2 P1 interstitial: first unowned interstitial sighting takes the throttle exit (5)',
    firstI.status === 5, `status=${firstI.status} stderr=${firstI.stderr?.slice(0, 200)}`);
  check('#208 gate r2 P1 interstitial: first sighting records the tab in the seen sidecar',
    throttleSeenHas(homeI, interstitialUrl, interstitialText),
    `dir=${fs.existsSync(throttleSeenDir(homeI)) ? fs.readdirSync(throttleSeenDir(homeI)) : null}`);
  cdpI1.stop();

  const cooldownPathI = path.join(homeI, 'throttle.cooldown');
  oldMtimeI(cooldownPathI);
  const mtimeBeforeI = fs.statSync(cooldownPathI).mtimeMs;
  const cdpI2 = await mockCdp('__NO_TABS__', [{ id: 'interstitial1', url: interstitialUrl }], {
    tabText: () => interstitialText,
  });
  const secondI = await runSalvageInHome(homeI, [MARKER, '3'], cdpI2.port);
  const mtimeAfterI = fs.statSync(cooldownPathI).mtimeMs;
  check('#208 gate r2 P1 interstitial: a repeat sighting of the same interstitial does not exit confirmed-absent (4)',
    secondI.status === 7, `status=${secondI.status} stderr=${secondI.stderr?.slice(0, 300)}`);
  check('#208 gate r2 P1 interstitial: a repeat sighting reports evidence-kind: inconclusive, naming the throttle surface',
    /evidence-kind: inconclusive/.test(secondI.stderr || '') &&
      /inconclusive: an unowned throttle surface was observed this scan/.test(secondI.stderr || ''),
    `stderr=${secondI.stderr?.slice(0, 400)}`);
  check('#208 gate r2 P1 interstitial: a repeat sighting does not rewrite the cooldown',
    mtimeAfterI === mtimeBeforeI, `before=${mtimeBeforeI} after=${mtimeAfterI}`);
  cdpI2.stop();
  fs.rmSync(homeI, { recursive: true, force: true });

  // Planted negative: the SAME two-invocation shape, but the page underneath carries ANOTHER
  // run's exact marker — positively someone else's conversation, not merely "not proven to
  // belong to us". That is the one case the P1 rule allows to be disregarded when deciding
  // absence: a repeat sighting of it must still correctly reach the confirmed-absent exit 4.
  const foreignInterstitialUrl = 'https://chatgpt.com/c/mock-foreign-interstitial-tab';
  const reasoningFiller = Array.from({ length: 120 }, (_, i) =>
    `Reviewed concurrency risks in module ${i}: lock ordering, retry budgets, and reservation TTL handling.`).join('\n');
  const foreignModalText = "Too many requests. You're making requests too quickly. We've temporarily limited access to your conversations to protect your data.";
  const foreignPageText = `${foreignModalText}\nrun marker: pg-run-other-9999999999-9\n${reasoningFiller}`;

  const homeF = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpF1 = await mockCdp('__NO_TABS__', [{ id: 'foreignint1', url: foreignInterstitialUrl }], {
    tabText: () => foreignPageText,
    throttleModal: () => foreignModalText,
  });
  const firstF = await runSalvageInHome(homeF, [MARKER, '3'], cdpF1.port);
  check('#208 gate r2 P1 planted negative: first foreign-marked modal sighting takes the throttle exit (5)',
    firstF.status === 5, `status=${firstF.status} stderr=${firstF.stderr?.slice(0, 200)}`);
  cdpF1.stop();

  const cdpF2 = await mockCdp('__NO_TABS__', [{ id: 'foreignint1', url: foreignInterstitialUrl }], {
    tabText: () => foreignPageText,
    throttleModal: () => foreignModalText,
  });
  const secondF = await runSalvageInHome(homeF, [MARKER, '3'], cdpF2.port);
  check('#208 gate r2 P1 planted negative: a repeat sighting of a POSITIVELY FOREIGN modal still reaches confirmed-absent (4), not inconclusive',
    secondF.status === 4, `status=${secondF.status} stderr=${secondF.stderr?.slice(0, 400)}`);
  check('#208 gate r2 P1 planted negative: the repeat foreign sighting is not reported as inconclusive',
    !/evidence-kind: inconclusive/.test(secondF.stderr || ''), `stderr=${secondF.stderr?.slice(0, 400)}`);
  cdpF2.stop();
  fs.rmSync(homeF, { recursive: true, force: true });
}

{ // #208 gate r2 P1 (organizer variant): "Apply the same rule to the organizer's
  // throttled-but-ignored case if it can reach an absence-like conclusion." A single unowned,
  // markerless throttle sighting with NO recovery URL at all (no memo, no open owned tab) charges
  // the cooldown and reports reason=throttle on its first scan — already-working #162/#208
  // behavior. A SECOND organizer scan of the exact same tab (nothing ever clears the
  // interstitial) finds the sighting already charged and must not silently fall through to
  // reason=owned-target-not-found, an absence-like conclusion that wrongly implies nothing was
  // ever seen: it must keep reporting the inconclusive reason=throttle framing, without writing a
  // NEW cooldown.
  const title = 'pro-gate review: PR #208 organizer P1 [pro-gate]';
  const orgInterstitialUrl = 'https://chatgpt.com/c/mock-organizer-interstitial';
  const orgInterstitialText = "You're making requests too quickly. Please wait a few minutes before trying again.";
  const oldMtimeOP1 = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };

  const homeOP1 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, title)(homeOP1); // no memo url -> no recovery path at all

  const cdpOP1a = await mockCdp('__NO_TABS__', [{ id: 'orgint1', url: orgInterstitialUrl }], {
    tabText: () => orgInterstitialText,
  });
  const orgFirst = await runSalvageInHome(homeOP1, ['--organize', MARKER, '5'], cdpOP1a.port);
  check('#208 gate r2 P1 organizer: first unowned interstitial sighting reports reason=throttle',
    /reason=throttle/.test(orgFirst.stdout), `stdout=${orgFirst.stdout} stderr=${orgFirst.stderr?.slice(0, 300)}`);
  check('#208 gate r2 P1 organizer: first sighting writes the cooldown',
    orgFirst.cooldown !== null, `cooldown=${orgFirst.cooldown}`);
  cdpOP1a.stop();

  const cooldownPathOP1 = path.join(homeOP1, 'throttle.cooldown');
  oldMtimeOP1(cooldownPathOP1);
  const mtimeBeforeOP1 = fs.statSync(cooldownPathOP1).mtimeMs;
  const cdpOP1b = await mockCdp('__NO_TABS__', [{ id: 'orgint1', url: orgInterstitialUrl }], {
    tabText: () => orgInterstitialText,
  });
  const orgSecond = await runSalvageInHome(homeOP1, ['--organize', MARKER, '5'], cdpOP1b.port);
  const mtimeAfterOP1 = fs.statSync(cooldownPathOP1).mtimeMs;
  check('#208 gate r2 P1 organizer: a repeat sighting with no recovery URL still reports reason=throttle, not owned-target-not-found',
    /reason=throttle/.test(orgSecond.stdout), `stdout=${orgSecond.stdout} stderr=${orgSecond.stderr?.slice(0, 300)}`);
  check('#208 gate r2 P1 organizer: a repeat sighting does not rewrite the cooldown',
    mtimeAfterOP1 === mtimeBeforeOP1, `before=${mtimeBeforeOP1} after=${mtimeAfterOP1}`);
  cdpOP1b.stop();
  fs.rmSync(homeOP1, { recursive: true, force: true });
}

{ // #208 gate r2 P2 (store level): concurrent scans (probe+harvest, or two overlapping probes)
  // used to overwrite each other's remembered throttle sightings because the OLD sidecar
  // (throttle.cooldown.seen) was loaded ONCE per invocation and rewritten WHOLESALE — a second
  // writer's own load-then-mutate-then-rewrite could always land after the first's and silently
  // drop whichever sighting lost the race. The fix replaces that single file with one
  // independently-created record file per (url, hash) fingerprint
  // (fs.writeFileSync(..., {flag:'wx'})), so two writers can never clobber each other and there
  // is no shared in-memory snapshot to go stale. This proves the guarantee at the store level: a
  // record written DIRECTLY (standing in for a concurrent writer) survives a REAL invocation's
  // own in-flight charge untouched, and a later invocation recognizes that directly-written
  // record as already charged instead of re-admitting it.
  const recordAUrl = 'https://chatgpt.com/c/mock-race-record-a';
  const recordAText = "You're making requests too quickly. [race fixture A]";
  const recordCUrl = 'https://chatgpt.com/c/mock-race-record-c';
  const recordCText = "You're making requests too quickly. [race fixture C]";
  const recordBUrl = 'https://chatgpt.com/c/mock-race-record-b';
  const recordBText = "You're making requests too quickly. [race fixture B]";

  const homeRace = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  // A stands in for a fingerprint an earlier or sibling scan already charged.
  seedThrottleSeen(homeRace, recordAUrl, recordAText);

  // A REAL invocation admits B for a genuinely new sighting. Started but not yet awaited, so the
  // synchronous injection of C below lands while B's scan is still in flight, mirroring a second
  // concurrent writer racing the first.
  const cdpRace = await mockCdp('__NO_TABS__', [{ id: 'race-b', url: recordBUrl }], {
    tabText: () => recordBText,
  });
  const bPromise = runSalvageInHome(homeRace, [MARKER, '3'], cdpRace.port);
  // A DIFFERENT writer's record, injected synchronously while B's scan is in flight.
  seedThrottleSeen(homeRace, recordCUrl, recordCText);
  const bResult = await bPromise;
  cdpRace.stop();

  check('#208 gate r2 P2 store: the real invocation admits its own new sighting (exit 5)',
    bResult.status === 5, `status=${bResult.status} stderr=${bResult.stderr?.slice(0, 200)}`);
  check('#208 gate r2 P2 store: A (seeded before the in-flight scan) survives untouched',
    throttleSeenHas(homeRace, recordAUrl, recordAText),
    `dir=${fs.existsSync(throttleSeenDir(homeRace)) ? fs.readdirSync(throttleSeenDir(homeRace)) : null}`);
  check("#208 gate r2 P2 store: B (the in-flight scan's own new sighting) is durably recorded",
    throttleSeenHas(homeRace, recordBUrl, recordBText),
    `dir=${fs.existsSync(throttleSeenDir(homeRace)) ? fs.readdirSync(throttleSeenDir(homeRace)) : null}`);
  check("#208 gate r2 P2 store: C (a concurrent writer's record injected mid-flight) is not clobbered by the in-flight scan's own write",
    throttleSeenHas(homeRace, recordCUrl, recordCText),
    `dir=${fs.existsSync(throttleSeenDir(homeRace)) ? fs.readdirSync(throttleSeenDir(homeRace)) : null}`);

  // Planted "no re-charge" check: a follow-up invocation whose only tab carries C's EXACT
  // fingerprint must recognize it as already charged and must not re-admit it (no throttle exit,
  // no cooldown rewrite) — proving the read side recognizes a record written by any writer, not
  // only ones this same process created.
  const cooldownPathRace = path.join(homeRace, 'throttle.cooldown');
  const oldMtimeRace = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };
  oldMtimeRace(cooldownPathRace);
  const mtimeBeforeRace = fs.statSync(cooldownPathRace).mtimeMs;
  const cdpFollowup = await mockCdp('__NO_TABS__', [{ id: 'race-c', url: recordCUrl }], {
    tabText: () => recordCText,
  });
  const followup = await runSalvageInHome(homeRace, [MARKER, '3'], cdpFollowup.port);
  const mtimeAfterRace = fs.statSync(cooldownPathRace).mtimeMs;
  check("#208 gate r2 P2 store planted negative: a follow-up scan of C's exact fingerprint is not re-admitted",
    followup.status !== 5, `status=${followup.status}`);
  check("#208 gate r2 P2 store planted negative: a follow-up scan of C's exact fingerprint does not rewrite the cooldown",
    mtimeAfterRace === mtimeBeforeRace, `before=${mtimeBeforeRace} after=${mtimeAfterRace}`);
  cdpFollowup.stop();
  fs.rmSync(homeRace, { recursive: true, force: true });
}

{ // #208 gate r2 P2 (batch, main scan): one already-open BATCH of >=2 distinct new unowned
  // throttle modal sightings in a SINGLE scan must record every one of their fingerprints before
  // exiting, not merely the first — the old whole-scan walk called process.exit(5) on the FIRST
  // newly-admitted hit, so hit #2 was never charged and a later invocation re-admitted it as
  // though it had never been seen (one already-observed batch cost N separate cooldowns, one
  // newly-discovered tab at a time, instead of the ONE this single scan should have charged).
  const batchUrlTwo = 'https://chatgpt.com/c/mock-batch-tab-two';
  const batchModalOne = "You're making requests too quickly. [batch fixture one]";
  const batchModalTwo = "You're making requests too quickly. [batch fixture two]";
  const batchTextOne = `${batchModalOne}\nAccount limits.`;
  const batchTextTwo = `${batchModalTwo}\nAccount limits.`;

  const homeBatch = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpBatch = await mockCdp(batchTextOne, [{ id: 'batch-two', url: batchUrlTwo }], {
    tabText: (url) => (url === batchUrlTwo ? batchTextTwo : batchTextOne),
    throttleModal: (id) => (id === 'batch-two' ? batchModalTwo : batchModalOne),
  });
  const batchFirst = await runSalvageInHome(homeBatch, [MARKER, '3'], cdpBatch.port);
  check('#208 gate r2 P2 batch (main scan): the batch takes the throttle exit (5)',
    batchFirst.status === 5, `status=${batchFirst.status} stderr=${batchFirst.stderr?.slice(0, 200)}`);
  check('#208 gate r2 P2 batch (main scan): the FIRST tab in the batch is recorded in the seen sidecar',
    throttleSeenHas(homeBatch, 'https://chatgpt.com/c/mock-conversation', batchModalOne),
    `dir=${fs.existsSync(throttleSeenDir(homeBatch)) ? fs.readdirSync(throttleSeenDir(homeBatch)) : null}`);
  check('#208 gate r2 P2 batch (main scan): the SECOND tab in the same batch is ALSO recorded, not left for a later invocation to rediscover',
    throttleSeenHas(homeBatch, batchUrlTwo, batchModalTwo),
    `dir=${fs.existsSync(throttleSeenDir(homeBatch)) ? fs.readdirSync(throttleSeenDir(homeBatch)) : null}`);
  cdpBatch.stop();

  // Follow-up scan of JUST the second tab (still open, same modal) — the definitive proof: if
  // the batch's second hit was durably recorded during the FIRST scan (this fix), this repeat is
  // recognized as already charged and does not re-admit it as though it had never been seen.
  const cooldownPathBatch = path.join(homeBatch, 'throttle.cooldown');
  const oldMtimeBatch = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };
  oldMtimeBatch(cooldownPathBatch);
  const mtimeBeforeBatch = fs.statSync(cooldownPathBatch).mtimeMs;
  const cdpBatchFollowup = await mockCdp('__NO_TABS__', [{ id: 'batch-two', url: batchUrlTwo }], {
    tabText: () => batchTextTwo,
    throttleModal: () => batchModalTwo,
  });
  const batchFollowup = await runSalvageInHome(homeBatch, [MARKER, '3'], cdpBatchFollowup.port);
  const mtimeAfterBatch = fs.statSync(cooldownPathBatch).mtimeMs;
  check("#208 gate r2 P2 batch (main scan): the batch's SECOND hit, recorded in the SAME first scan, is not re-admitted by a later scan",
    batchFollowup.status !== 5, `status=${batchFollowup.status}`);
  check('#208 gate r2 P2 batch (main scan): the follow-up scan of the second hit does not rewrite the cooldown',
    mtimeAfterBatch === mtimeBeforeBatch, `before=${mtimeBeforeBatch} after=${mtimeAfterBatch}`);
  cdpBatchFollowup.stop();
  fs.rmSync(homeBatch, { recursive: true, force: true });
}

{ // #208 gate r2 P2 (batch, organizer variant): the same fix, applied to the organizer's
  // throttleHits walk — a batch of >=2 distinct new unowned sightings in one organizer scan must
  // record all of them before returning, not merely the first.
  const title = 'pro-gate review: PR #208 organizer P2 batch [pro-gate]';
  const orgBatchUrlTwo = 'https://chatgpt.com/c/mock-organizer-batch-two';
  const orgBatchTextOne = "You're making requests too quickly. [organizer batch fixture one]";
  const orgBatchTextTwo = "You're making requests too quickly. [organizer batch fixture two]";

  const homeOrgBatch = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, title)(homeOrgBatch);
  const cdpOrgBatch = await mockCdp(orgBatchTextOne, [
    { id: 'org-batch-two', url: orgBatchUrlTwo },
  ], {
    tabText: (url) => (url === orgBatchUrlTwo ? orgBatchTextTwo : orgBatchTextOne),
  });
  const orgBatchFirst = await runSalvageInHome(homeOrgBatch, ['--organize', MARKER, '5'], cdpOrgBatch.port);
  check('#208 gate r2 P2 batch (organizer): the batch reports reason=throttle',
    /reason=throttle/.test(orgBatchFirst.stdout), `stdout=${orgBatchFirst.stdout} stderr=${orgBatchFirst.stderr?.slice(0, 300)}`);
  cdpOrgBatch.stop();

  // Follow-up organizer scan of JUST the second tab: the definitive proof it was durably
  // recorded during the first (batched) scan, not left for this scan to rediscover as new. The
  // r2 P1 fix now makes reason=throttle appear on an ignored-but-inconclusive repeat too, so the
  // discriminator here is the cooldown mtime and the "already charged" stderr line, not the
  // reason field.
  const cooldownPathOrgBatch = path.join(homeOrgBatch, 'throttle.cooldown');
  const oldMtimeOrgBatch = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };
  oldMtimeOrgBatch(cooldownPathOrgBatch);
  const mtimeBeforeOrgBatch = fs.statSync(cooldownPathOrgBatch).mtimeMs;
  const cdpOrgBatchFollowup = await mockCdp('__NO_TABS__', [{ id: 'org-batch-two', url: orgBatchUrlTwo }], {
    tabText: () => orgBatchTextTwo,
  });
  const orgBatchFollowup = await runSalvageInHome(homeOrgBatch, ['--organize', MARKER, '5'], cdpOrgBatchFollowup.port);
  const mtimeAfterOrgBatch = fs.statSync(cooldownPathOrgBatch).mtimeMs;
  check("#208 gate r2 P2 batch (organizer): the batch's SECOND hit, recorded in the SAME first scan, does not rewrite the cooldown on a later scan",
    mtimeAfterOrgBatch === mtimeBeforeOrgBatch, `before=${mtimeBeforeOrgBatch} after=${mtimeAfterOrgBatch}`);
  check('#208 gate r2 P2 batch (organizer): the follow-up scan names the second tab as already charged, not freshly charged',
    orgBatchFollowup.stderr?.includes(`stale throttle modal on unowned tab ${orgBatchUrlTwo} already charged`),
    `stderr=${orgBatchFollowup.stderr?.slice(0, 400)}`);
  cdpOrgBatchFollowup.stop();
  fs.rmSync(homeOrgBatch, { recursive: true, force: true });
}

{ // #208 gate r3 P2 (finding 1a): TWO markerless interstitials (no modal element on either tab)
  // in the SAME scan must cost exactly one cooldown, batched together, not one cooldown per tab
  // across separate invocations. Pre-fix, only the whole-scan MODAL fallback batched; a
  // marker-less interstitial was still tripped one at a time by the per-tab loop, which called
  // process.exit(5) on the FIRST hit — so the second tab's fingerprint was never even reached,
  // let alone recorded, in the same scan.
  const interstitialUrlOne = 'https://chatgpt.com/c/mock-interstitial-batch-one';
  const interstitialUrlTwo = 'https://chatgpt.com/c/mock-interstitial-batch-two';
  const interstitialTextOne = "You're making requests too quickly. [r3 interstitial batch one]";
  const interstitialTextTwo = "You're making requests too quickly. [r3 interstitial batch two]";
  const oldMtimeR3a = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };

  const homeR3a = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpR3aFirst = await mockCdp('__NO_TABS__', [
    { id: 'interstitial-one', url: interstitialUrlOne },
    { id: 'interstitial-two', url: interstitialUrlTwo },
  ], {
    tabText: (url) => (url === interstitialUrlTwo ? interstitialTextTwo : interstitialTextOne),
  });
  const r3aFirst = await runSalvageInHome(homeR3a, [MARKER, '3'], cdpR3aFirst.port);
  check('#208 gate r3 P2 (1a) a batch of two unowned interstitials takes the throttle exit (5)',
    r3aFirst.status === 5, `status=${r3aFirst.status} stderr=${r3aFirst.stderr?.slice(0, 200)}`);
  check('#208 gate r3 P2 (1a) the FIRST interstitial in the batch is recorded in the seen sidecar',
    throttleSeenHas(homeR3a, interstitialUrlOne, interstitialTextOne),
    `dir=${fs.existsSync(throttleSeenDir(homeR3a)) ? fs.readdirSync(throttleSeenDir(homeR3a)) : null}`);
  check('#208 gate r3 P2 (1a) the SECOND interstitial in the SAME scan is ALSO recorded, not left for a later invocation to rediscover',
    throttleSeenHas(homeR3a, interstitialUrlTwo, interstitialTextTwo),
    `dir=${fs.existsSync(throttleSeenDir(homeR3a)) ? fs.readdirSync(throttleSeenDir(homeR3a)) : null}`);
  cdpR3aFirst.stop();

  // Follow-up scan of BOTH tabs, unchanged: the definitive proof. If the second tab's
  // fingerprint was durably recorded during the FIRST scan (this fix), this repeat recognizes
  // both as already charged and writes no second cooldown.
  const cooldownPathR3a = path.join(homeR3a, 'throttle.cooldown');
  oldMtimeR3a(cooldownPathR3a);
  const mtimeBeforeR3a = fs.statSync(cooldownPathR3a).mtimeMs;
  const cdpR3aSecond = await mockCdp('__NO_TABS__', [
    { id: 'interstitial-one', url: interstitialUrlOne },
    { id: 'interstitial-two', url: interstitialUrlTwo },
  ], {
    tabText: (url) => (url === interstitialUrlTwo ? interstitialTextTwo : interstitialTextOne),
  });
  const r3aSecond = await runSalvageInHome(homeR3a, [MARKER, '3'], cdpR3aSecond.port);
  const mtimeAfterR3a = fs.statSync(cooldownPathR3a).mtimeMs;
  check('#208 gate r3 P2 (1a) a follow-up scan of both unchanged interstitials does not take the throttle exit',
    r3aSecond.status !== 5, `status=${r3aSecond.status}`);
  check('#208 gate r3 P2 (1a) a follow-up scan of both unchanged interstitials does not rewrite the cooldown',
    mtimeAfterR3a === mtimeBeforeR3a, `before=${mtimeBeforeR3a} after=${mtimeAfterR3a}`);
  cdpR3aSecond.stop();
  fs.rmSync(homeR3a, { recursive: true, force: true });
}

{ // #208 gate r3 P2 (finding 1b): a MIXED batch — one modal hit and one marker-less interstitial
  // hit on a DIFFERENT tab, both new in the same scan — must also cost exactly one cooldown.
  // Pre-fix, the modal hit alone tripped the whole-scan modal fallback and called
  // process.exit(5) immediately, so the per-tab loop (where the interstitial hit was tripped)
  // never even ran in that same process: the interstitial's fingerprint was never recorded,
  // costing its own separate cooldown on the very next invocation.
  const mixedModalUrl = 'https://chatgpt.com/c/mock-mixed-modal';
  const mixedInterstitialUrl = 'https://chatgpt.com/c/mock-mixed-interstitial';
  const mixedModalText = "You're making requests too quickly. [r3 mixed modal]";
  const mixedInterstitialText = "You're making requests too quickly. [r3 mixed interstitial]";
  const oldMtimeR3b = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };

  const homeR3b = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpR3bFirst = await mockCdp('__NO_TABS__', [
    { id: 'mixed-modal', url: mixedModalUrl },
    { id: 'mixed-interstitial', url: mixedInterstitialUrl },
  ], {
    tabText: (url) => (url === mixedInterstitialUrl ? mixedInterstitialText : mixedModalText),
    throttleModal: (id) => (id === 'mixed-modal' ? mixedModalText : null),
  });
  const r3bFirst = await runSalvageInHome(homeR3b, [MARKER, '3'], cdpR3bFirst.port);
  check('#208 gate r3 P2 (1b) a mixed modal+interstitial batch takes the throttle exit (5)',
    r3bFirst.status === 5, `status=${r3bFirst.status} stderr=${r3bFirst.stderr?.slice(0, 200)}`);
  check('#208 gate r3 P2 (1b) the modal hit is recorded in the seen sidecar (fingerprint = modal text)',
    throttleSeenHas(homeR3b, mixedModalUrl, mixedModalText),
    `dir=${fs.existsSync(throttleSeenDir(homeR3b)) ? fs.readdirSync(throttleSeenDir(homeR3b)) : null}`);
  check('#208 gate r3 P2 (1b) the interstitial hit on the OTHER tab is ALSO recorded in the SAME scan (fingerprint = page text)',
    throttleSeenHas(homeR3b, mixedInterstitialUrl, mixedInterstitialText),
    `dir=${fs.existsSync(throttleSeenDir(homeR3b)) ? fs.readdirSync(throttleSeenDir(homeR3b)) : null}`);
  cdpR3bFirst.stop();

  const cooldownPathR3b = path.join(homeR3b, 'throttle.cooldown');
  oldMtimeR3b(cooldownPathR3b);
  const mtimeBeforeR3b = fs.statSync(cooldownPathR3b).mtimeMs;
  const cdpR3bSecond = await mockCdp('__NO_TABS__', [
    { id: 'mixed-modal', url: mixedModalUrl },
    { id: 'mixed-interstitial', url: mixedInterstitialUrl },
  ], {
    tabText: (url) => (url === mixedInterstitialUrl ? mixedInterstitialText : mixedModalText),
    throttleModal: (id) => (id === 'mixed-modal' ? mixedModalText : null),
  });
  const r3bSecond = await runSalvageInHome(homeR3b, [MARKER, '3'], cdpR3bSecond.port);
  const mtimeAfterR3b = fs.statSync(cooldownPathR3b).mtimeMs;
  check('#208 gate r3 P2 (1b) a follow-up scan of the same unchanged mixed batch does not take the throttle exit',
    r3bSecond.status !== 5, `status=${r3bSecond.status}`);
  check('#208 gate r3 P2 (1b) a follow-up scan of the same unchanged mixed batch does not rewrite the cooldown',
    mtimeAfterR3b === mtimeBeforeR3b, `before=${mtimeBeforeR3b} after=${mtimeAfterR3b}`);
  cdpR3bSecond.stop();
  fs.rmSync(homeR3b, { recursive: true, force: true });
}

{ // #208 gate r3 P2 (finding 2a): PRO_GATE_THROTTLE_SEEN_MAX must actually change the enforced
  // cap. Pre-fix the constant is a hardcoded 512, so setting the env var has NO effect at all —
  // this only shows up once the on-disk count exceeds whichever cap really governs, so seed
  // three unrelated dummy fingerprints (below the true default of 512, but above an override of
  // 2) and fire the prune via one unrelated trigger hit. Pre-fix: all three dummies survive
  // (3 is nowhere near the hardcoded 512). Post-fix with the override honored: cap=2 trims the
  // three down to two survivors.
  const homeOverride = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const overrideDummyUrl = (i) => `https://chatgpt.com/c/mock-cap-override-dummy-${i}`;
  const overrideDummyText = (i) => `dummy filler text ${i} unrelated to this scan`;
  for (let i = 0; i < 3; i += 1) seedThrottleSeen(homeOverride, overrideDummyUrl(i), overrideDummyText(i));
  const overrideTriggerUrl = 'https://chatgpt.com/c/mock-cap-override-trigger';
  const overrideTriggerText = "You're making requests too quickly. [r3 cap-override trigger]";
  const cdpOverride = await mockCdp('__NO_TABS__', [{ id: 'override-trigger', url: overrideTriggerUrl }], {
    tabText: () => overrideTriggerText, throttleModal: () => overrideTriggerText,
  });
  await runSalvageInHome(homeOverride, [MARKER, '3'], cdpOverride.port, { PRO_GATE_THROTTLE_SEEN_MAX: '2' });
  cdpOverride.stop();
  const overrideSurvivors = [0, 1, 2].filter((i) => throttleSeenHas(homeOverride, overrideDummyUrl(i), overrideDummyText(i))).length;
  check('#208 gate r3 P2 (2a) PRO_GATE_THROTTLE_SEEN_MAX=2 trims three unrelated fingerprints down to two survivors',
    overrideSurvivors === 2,
    `survivors=${overrideSurvivors} dir=${fs.existsSync(throttleSeenDir(homeOverride)) ? fs.readdirSync(throttleSeenDir(homeOverride)) : null}`);
  fs.rmSync(homeOverride, { recursive: true, force: true });
}

{ // #208 gate r3 P2 (finding 2b): the capacity trim must never evict a fingerprint the CURRENT
  // scan itself is about to check, even at the true DEFAULT cap of 512 (no override involved).
  // Simulate "this exact three-tab batch was already charged in an earlier scan" by seeding
  // their three records directly with an older mtime, then pad the sidecar with 510 unrelated,
  // NEWER-mtime filler records so the total (513) exceeds 512 by exactly one. When this
  // unchanged batch is rescanned: pre-fix, the prune (no notion of "currently observed") evicts
  // the globally oldest record — one of THIS batch's own three, because the 510 filler records
  // are all newer — the evicted tab then reads as newly-charged and the batch wrongly re-trips
  // the throttle exit (5) for a completely unchanged set of stale tabs. Post-fix, all three
  // batch fingerprints are protected before the prune ever runs, so only the 510 (below-cap)
  // filler records are eligible, nothing is evicted, and the unchanged batch costs no new charge.
  const homeDefault = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const defCapUrlOne = 'https://chatgpt.com/c/mock-cap512-one';
  const defCapUrlTwo = 'https://chatgpt.com/c/mock-cap512-two';
  const defCapUrlThree = 'https://chatgpt.com/c/mock-cap512-three';
  const defCapModalText = "You're making requests too quickly. [r3 cap-512 fixture]";
  const defBatch = [
    [defCapUrlOne, defCapModalText],
    [defCapUrlTwo, defCapModalText],
    [defCapUrlThree, defCapModalText],
  ];
  const oldBatchMtime = new Date(Date.now() - 600_000); // 10 minutes ago: "already charged earlier"
  for (const [url, text] of defBatch) {
    seedThrottleSeen(homeDefault, url, text);
    const p = throttleSeenRecordPath(homeDefault, url, text);
    fs.utimesSync(p, oldBatchMtime, oldBatchMtime);
  }
  // 510 unrelated filler records, seeded with the default (fresh, "now") mtime — newer than the
  // batch above — pushing the sidecar to 513 total (512 default cap + 1).
  for (let i = 0; i < 510; i += 1) {
    seedThrottleSeen(homeDefault, `https://chatgpt.com/c/mock-cap512-filler-${i}`, `filler text ${i}`);
  }
  const batchMtimesBefore = defBatch.map(([url, text]) => fs.statSync(throttleSeenRecordPath(homeDefault, url, text)).mtimeMs);

  const cdpDefault = await mockCdp('__NO_TABS__', [
    { id: 'cap512-one', url: defCapUrlOne },
    { id: 'cap512-two', url: defCapUrlTwo },
    { id: 'cap512-three', url: defCapUrlThree },
  ], { tabText: () => defCapModalText, throttleModal: () => defCapModalText });
  const rescan = await runSalvageInHome(homeDefault, [MARKER, '3'], cdpDefault.port);
  cdpDefault.stop();
  const batchMtimesAfter = defBatch.map(([url, text]) => fs.statSync(throttleSeenRecordPath(homeDefault, url, text)).mtimeMs);

  check('#208 gate r3 P2 (2b) rescanning the same unchanged three-tab batch above the default cap does not take the throttle exit',
    rescan.status !== 5, `status=${rescan.status} stderr=${rescan.stderr?.slice(0, 300)}`);
  check('#208 gate r3 P2 (2b) none of the three batch fingerprints were evicted-and-recreated (mtimes unchanged)',
    batchMtimesBefore.every((t, i) => t === batchMtimesAfter[i]),
    `before=${JSON.stringify(batchMtimesBefore)} after=${JSON.stringify(batchMtimesAfter)}`);
  fs.rmSync(homeDefault, { recursive: true, force: true });
}

{ // #209 gate r6 P1 (bin/cdp-salvage.mjs:626, finding 1): a CLOSED remembered URL's scratch
  // render shows ANOTHER run's marker beneath an ALREADY-RECORDED modal — classifyEvidence
  // returns { kind: 'throttle', foreign: true }. tripThrottleEvidence's early return (already
  // charged; no NEW cooldown, no exit(5)) is correct, but the remembered-render caller only ever
  // routed `kind: 'foreign'` into the stale-memo branch, so this positive foreign evidence never
  // marked the memo stale: knownUrl stayed the same dead foreign URL forever, and every LATER
  // probe re-rendered it and hit the generic "inconclusive, re-rendered Nx" exit (7) instead of
  // ever converging on confirmed-absent (4).
  const modalText1 = "You're making requests too quickly. [r6 P1 remembered-render fixture]";
  const foreignPageText1 = `ChatGPT\npg-run-another-run-777\n${modalText1}\nAnother run's conversation beneath the modal.\n`;
  const seedUrl1 = 'https://chatgpt.com/c/mock-remembered-foreign-r6';

  const home1 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedMemo(MARKER, seedUrl1)(home1);
  // The (url, modal-text) fingerprint is already charged by an earlier scan — this is what
  // forces tripThrottleUnowned's early return at bin/cdp-salvage.mjs:626 instead of a fresh
  // exit(5); the bug is what happens to the evidence object AFTER that early return.
  seedThrottleSeen(home1, seedUrl1, modalText1);

  const cdp1 = await mockCdp('__NO_TABS__', [], {
    renderText: () => foreignPageText1,
    throttleModal: () => modalText1,
  });
  const r1 = await runSalvageInHome(home1, [MARKER, '3'], cdp1.port, SCRATCH_SAMPLE_TEST_ENV);
  cdp1.stop();
  check('#209 gate r6 P1 (1) an already-recorded foreign modal beneath the remembered URL does not take the throttle exit',
    r1.status !== 5, `status=${r1.status}`);
  check('#209 gate r6 P1 (1) an already-recorded foreign modal beneath the remembered URL reaches confirmed-absent, not stuck inconclusive',
    r1.status === 4, `status=${r1.status} stderr=${r1.stderr?.slice(-400)}`);
  check('#209 gate r6 P1 (1) the memo is reported stale on stderr',
    /stale memo/.test(r1.stderr || ''), `stderr=${r1.stderr?.slice(-400)}`);
  fs.rmSync(home1, { recursive: true, force: true });

  // Planted negative: the same already-recorded-modal shape but MARKERLESS (no run marker, ours
  // or foreign, anywhere on the underlying page) must stay inconclusive (7) as before — a bare
  // repeat interstitial is rate-limit noise, not positive proof the memo belongs to someone else.
  const modalText1b = "You're making requests too quickly. [r6 P1 markerless remembered-render fixture]";
  const markerlessPageText1 = `ChatGPT\n${modalText1b}\nNo run marker anywhere on this page.\n`;
  const seedUrl1b = 'https://chatgpt.com/c/mock-remembered-markerless-r6';

  const home1b = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedMemo(MARKER, seedUrl1b)(home1b);
  seedThrottleSeen(home1b, seedUrl1b, modalText1b);

  const cdp1b = await mockCdp('__NO_TABS__', [], {
    renderText: () => markerlessPageText1,
    throttleModal: () => modalText1b,
  });
  const r1b = await runSalvageInHome(home1b, [MARKER, '3'], cdp1b.port, SCRATCH_SAMPLE_TEST_ENV);
  cdp1b.stop();
  check('#209 gate r6 P1 planted negative: an already-recorded MARKERLESS modal stays inconclusive (7), not confirmed-absent',
    r1b.status === 7, `status=${r1b.status} stderr=${r1b.stderr?.slice(-400)}`);
  check('#209 gate r6 P1 planted negative: the memo is NOT reported stale',
    !/stale memo/.test(r1b.stderr || ''), `stderr=${r1b.stderr?.slice(-400)}`);
  fs.rmSync(home1b, { recursive: true, force: true });
}

{ // Round-1 fixer verification (P1): the #209 gate r6 P1 fix above only widened the
  // REMEMBERED-RENDER caller's foreign-memo gate. The CANONICAL-SCRATCH-REVALIDATION caller (the
  // one-shot revalidation the scan spends on knownUrl when an owned-incomplete DUPLICATE tab is
  // also open, bin/cdp-salvage.mjs ~1855) has the IDENTICAL gap: a scratch render of knownUrl
  // that lands `{kind: 'throttle', foreign: true}` is just as decisive as `kind: 'foreign'`
  // proof the memo is stale, but this sibling site only ever matched `fresh?.kind === 'foreign'`.
  // Before the fix, tripThrottleEvidence's already-charged early return correctly skipped a
  // fresh cooldown, but the code right after it never routed the evidence into rejectForeign, so
  // the memo kept pointing at the condemned URL forever — permanently wasting the scan's one-shot
  // canonical revalidation on it every later invocation instead of ever forgetting it.
  const knownUrlSib = 'https://chatgpt.com/c/known-conversation-r6p1-sibling';
  const duplicateTabSib = `run marker: ${MARKER}\nduplicate retry tab, still reasoning (r6 P1 sibling)...`;
  const modalTextSib = "You're making requests too quickly. [r6 P1 sibling fixture]";
  const foreignPageTextSib = `ChatGPT\npg-run-another-run-r6sib\n${modalTextSib}\nAnother run's conversation beneath the modal.\n`;

  const seedSib = (home) => {
    seedMemo(MARKER, knownUrlSib)(home);
    // Already charged by an earlier scan — forces tripThrottleEvidence's early return (no fresh
    // exit(5)) so the test isolates what happens to the evidence AFTER that return, exactly as
    // the sibling #209 gate r6 P1 fixture above does.
    seedThrottleSeen(home, knownUrlSib, modalTextSib);
  };
  const cdpSib = await mockCdp(duplicateTabSib, [], {
    renderText: (url) => (url === knownUrlSib ? foreignPageTextSib : duplicateTabSib),
    throttleModal: (id) => (id.startsWith('scratch') ? modalTextSib : null),
  });
  const rSib = await runScratchSalvage([MARKER, '3'], cdpSib.port, seedSib);
  cdpSib.stop();
  check('canonical-scratch sibling (1): an already-recorded foreign modal beneath the remembered URL does not take a fresh throttle exit',
    rSib.status !== 5, `status=${rSib.status}`);
  check('canonical-scratch sibling (1): the stale memo is forgotten, not left pointing at the condemned URL forever',
    rSib.memos.length === 0, `memos=${JSON.stringify(rSib.memos)} memoUrl=${rSib.memoUrl}`);
  check('canonical-scratch sibling (1): the condemned URL is blacklisted',
    (rSib.blacklist ?? '').includes(knownUrlSib), `blacklist=${rSib.blacklist}`);
  check('canonical-scratch sibling (1): stderr names canonical scratch as the source of the rejection',
    /canonical scratch .*carries a DIFFERENT run's marker/.test(rSib.stderr || ''), `stderr=${rSib.stderr?.slice(-400)}`);

  // Planted negative: the same already-recorded-modal shape but MARKERLESS (no run marker at
  // all, ours or foreign) must leave the memo untouched — a bare repeat interstitial is
  // rate-limit noise, not positive proof the memo belongs to someone else (design invariant:
  // markerless repeats stay inconclusive).
  const markerlessPageTextSib = `ChatGPT\n${modalTextSib}\nNo run marker anywhere on this page.\n`;
  const cdpSibNeg = await mockCdp(duplicateTabSib, [], {
    renderText: (url) => (url === knownUrlSib ? markerlessPageTextSib : duplicateTabSib),
    throttleModal: (id) => (id.startsWith('scratch') ? modalTextSib : null),
  });
  const rSibNeg = await runScratchSalvage([MARKER, '3'], cdpSibNeg.port, seedSib);
  cdpSibNeg.stop();
  check('canonical-scratch sibling planted negative: a MARKERLESS repeat leaves the memo untouched',
    rSibNeg.memos.length === 1 && rSibNeg.memoUrl === knownUrlSib,
    `memos=${JSON.stringify(rSibNeg.memos)} memoUrl=${rSibNeg.memoUrl}`);
  check('canonical-scratch sibling planted negative: no DIFFERENT-run-marker rejection is reported',
    !/carries a DIFFERENT run's marker/.test(rSibNeg.stderr || ''), `stderr=${rSibNeg.stderr?.slice(-400)}`);
}

{ // #209 gate r6 P2 (bin/cdp-salvage.mjs:1309, finding 2): openOrganizerScratch's throttle
  // return used to carry no ownership information at all, so the caller called
  // recordThrottle('organizer scratch') UNCONDITIONALLY whenever a scratch render hit any
  // throttle surface — an already-charged, unowned sighting recovered through scratch could
  // re-arm the cooldown every single scan. Fixed by carrying the scratch result's url,
  // fingerprint text and ownership back and applying the same central unowned gate every other
  // throttle trip site in this file already uses.
  const title2 = 'pro-gate review: PR #208 organizer scratch r6 [pro-gate]';
  const recoveryUrl2 = 'https://chatgpt.com/c/organizer-scratch-r6';
  const scratchModalText2 = "You're making requests too quickly. [r6 P2 organizer scratch fixture]";

  // (a) Unowned: the scratch render's underlying page carries ANOTHER run's marker, and this
  // exact (url, modal-text) fingerprint was already charged by an earlier scan.
  const homeA = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, title2, recoveryUrl2)(homeA);
  seedThrottleSeen(homeA, recoveryUrl2, scratchModalText2);
  const foreignScratchText2 = `ChatGPT\npg-run-someone-elses-run-999\n${scratchModalText2}\nAnother run's conversation.\n`;
  const cdpA = await mockCdp('__NO_TABS__', [], {
    renderText: () => foreignScratchText2,
    throttleModal: () => scratchModalText2,
  });
  const rA = await runSalvageInHome(homeA, ['--organize', MARKER, '5'], cdpA.port);
  cdpA.stop();
  check('#209 gate r6 P2 (2) organizer scratch: an unowned already-charged sighting still reports reason=throttle',
    /reason=throttle/.test(rA.stdout), `stdout=${rA.stdout} stderr=${rA.stderr?.slice(0, 400)}`);
  check('#209 gate r6 P2 (2) organizer scratch: an unowned already-charged sighting does NOT re-arm the cooldown',
    rA.cooldown === null, `cooldown=${rA.cooldown}`);
  fs.rmSync(homeA, { recursive: true, force: true });

  // (b) Owned: the scratch render's underlying page carries THIS run's own marker beneath the
  // modal — always re-arms unconditionally, even though nothing was ever pre-charged.
  const ownedScratchText2 = `ChatGPT\nrun marker: ${MARKER}\n${scratchModalText2}\nOur own conversation.\n`;
  const homeB = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, title2, recoveryUrl2)(homeB);
  const cdpB = await mockCdp('__NO_TABS__', [], {
    renderText: () => ownedScratchText2,
    throttleModal: () => scratchModalText2,
  });
  const rB = await runSalvageInHome(homeB, ['--organize', MARKER, '5'], cdpB.port);
  cdpB.stop();
  check('#209 gate r6 P2 (2) organizer scratch: an owned sighting still reports reason=throttle',
    /reason=throttle/.test(rB.stdout), `stdout=${rB.stdout} stderr=${rB.stderr?.slice(0, 400)}`);
  check('#209 gate r6 P2 (2) organizer scratch: an owned sighting always re-arms the cooldown',
    rB.cooldown !== null && /organizer scratch/.test(rB.cooldown), `cooldown=${rB.cooldown}`);
  fs.rmSync(homeB, { recursive: true, force: true });
}

{ // #209 gate r6 P2 (bin/cdp-salvage.mjs:525, finding 3): the fingerprint record was committed
  // (recordThrottleSeen's 'wx' create) before the cooldown was ever attempted (recordThrottle).
  // A failed or interrupted cooldown write left that record behind with no cooldown to show for
  // it, silently suppressing the sighting forever. Force the write to fail deterministically
  // (independent of uid/permissions) by pointing PRO_GATE_COOLDOWN_FILE at a path that already
  // exists as a DIRECTORY — fs.writeFileSync on it always throws EISDIR — at a path distinct
  // from the real default cooldown file, so a later unblocked scan can still write it for real.
  const staleUrl3 = 'https://chatgpt.com/c/mock-cooldown-write-fail';
  const modalText3 = "You're making requests too quickly. [r6 P2 cooldown-write-fail fixture]";
  const home3 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const blockedCooldownPath = path.join(home3, 'blocked-cooldown-r6');
  fs.mkdirSync(blockedCooldownPath, { recursive: true });

  const cdp3a = await mockCdp('__NO_TABS__', [{ id: 'fail1', url: staleUrl3 }], {
    tabText: () => modalText3,
    throttleModal: () => modalText3,
  });
  const rFirst = await runSalvageInHome(home3, [MARKER, '3'], cdp3a.port,
    { PRO_GATE_COOLDOWN_FILE: blockedCooldownPath });
  cdp3a.stop();
  check('#209 gate r6 P2 (3) a genuinely new unowned sighting still takes the throttle exit even when the cooldown write fails',
    rFirst.status === 5, `status=${rFirst.status} stderr=${rFirst.stderr?.slice(-400)}`);
  check('#209 gate r6 P2 (3) a failed cooldown write is reported on stderr, not claimed as a success',
    /could not be written/.test(rFirst.stderr || '') && !/cooldown written to/.test(rFirst.stderr || ''),
    `stderr=${rFirst.stderr?.slice(-500)}`);
  check('#209 gate r6 P2 (3) the fingerprint record is rolled back, not left behind, after the failed write',
    !throttleSeenHas(home3, staleUrl3, modalText3),
    `throttleSeen=${fs.existsSync(throttleSeenDir(home3)) ? fs.readdirSync(throttleSeenDir(home3)) : null}`);

  // Second scan of the SAME unchanged tab, this time with the real cooldown path unblocked: the
  // sighting must be re-chargeable (not permanently suppressed by an orphaned "seen" record),
  // and this time the write actually succeeds.
  const cdp3b = await mockCdp('__NO_TABS__', [{ id: 'fail1', url: staleUrl3 }], {
    tabText: () => modalText3,
    throttleModal: () => modalText3,
  });
  const rSecond = await runSalvageInHome(home3, [MARKER, '3'], cdp3b.port);
  cdp3b.stop();
  check('#209 gate r6 P2 (3) the same unchanged sighting is re-chargeable on a later scan instead of suppressed forever',
    rSecond.status === 5, `status=${rSecond.status} stderr=${rSecond.stderr?.slice(-400)}`);
  check('#209 gate r6 P2 (3) the later, unblocked scan actually writes the real cooldown file',
    rSecond.cooldown !== null && /modal over tab/.test(rSecond.cooldown), `cooldown=${rSecond.cooldown}`);
  fs.rmSync(home3, { recursive: true, force: true });
}

{ // #215 gate r1 P1 (bin/cdp-salvage.mjs:1779 main scan, :1341 organizer): a BLACKLISTED tab
  // whose page carries THIS run's own exact marker beneath the throttle modal was misclassified
  // as FOREIGN throttle evidence. `ownedHit` correctly excludes blacklisted URLs from positive
  // ownership, but the batch mapping immediately after it asked only
  // `FOREIGN_MARKER_RE.test(hit.text)` — and that pattern matches ANY pg-run marker, this run's
  // included. The hit therefore reached tripThrottleUnownedBatch with `foreign: true`, the one
  // case allowed to skip setting inconclusiveThrottleSeen. With the sighting already charged (so
  // no fresh exit 5) and the tab loop skipping the blacklisted URL, the scan fell all the way
  // through to the confirmed-absent exit 4 — spending a paid review's finite recovery-miss budget
  // on a limiter that never supplied ANOTHER run's marker, the exact distinction the #208 absence
  // guard exists to preserve. classifyEvidence already held the reference predicate
  // (`foreign: !owned && FOREIGN_MARKER_RE.test(text)`); both batch mappings now match it, while
  // keeping blacklisted URLs excluded from positive ownership.
  const blSelfUrl = 'https://chatgpt.com/c/mock-blacklisted-self-marked-215';
  const blForeignUrl = 'https://chatgpt.com/c/mock-blacklisted-foreign-215';
  const modalText215 = "You're making requests too quickly. [#215 gate r1 P1 fixture]";
  const selfMarkedPage215 = `ChatGPT\nrun marker: ${MARKER}\n${modalText215}\nOur own conversation beneath the modal.\n`;
  const foreignMarkedPage215 = `ChatGPT\npg-run-another-run-215\n${modalText215}\nAnother run's conversation beneath the modal.\n`;
  // Blacklisted (the per-marker nonMatching list) AND already charged: the two preconditions the
  // finding names. Nothing else is seeded — no memo, no second candidate — so the only way out of
  // the scan is the absence-vs-inconclusive decision this test is about.
  const seedBlacklistedCharged215 = (home, url) => {
    fs.writeFileSync(path.join(home, 'salvage-nonmatching.txt'), `${MARKER}\t${url}\n`);
    seedThrottleSeen(home, url, modalText215);
  };

  const homeSelf215 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedBlacklistedCharged215(homeSelf215, blSelfUrl);
  const cdpSelf215 = await mockCdp('__NO_TABS__', [{ id: 'bl215', url: blSelfUrl }], {
    tabText: () => selfMarkedPage215,
    throttleModal: () => modalText215,
  });
  const rSelf215 = await runSalvageInHome(homeSelf215, ['--probe', MARKER, '3'], cdpSelf215.port);
  cdpSelf215.stop();
  check("#215 gate r1 P1 main scan: a blacklisted tab carrying THIS run's own marker under an already-charged modal stays inconclusive (7), not confirmed-absent (4)",
    rSelf215.status === 7, `status=${rSelf215.status} stderr=${rSelf215.stderr?.slice(-500)}`);
  check('#215 gate r1 P1 main scan: the repeat probe names the unowned throttle surface as its reason',
    /^evidence-kind: inconclusive$/m.test(rSelf215.stderr || '')
      && /inconclusive: an unowned throttle surface was observed this scan/.test(rSelf215.stderr || ''),
    `stderr=${rSelf215.stderr?.slice(-500)}`);
  check('#215 gate r1 P1 main scan: the already-charged sighting neither writes nor rewrites the cooldown',
    rSelf215.cooldown === null, `cooldown=${rSelf215.cooldown}`);
  check('#215 gate r1 P1 main scan: the blacklisted self-marked tab is never reported as positive ownership',
    !/live conversation:/.test(rSelf215.stderr || '') && !/probe-state:/.test(rSelf215.stderr || ''),
    `stderr=${rSelf215.stderr?.slice(-500)}`);
  fs.rmSync(homeSelf215, { recursive: true, force: true });

  // Planted negative: the SAME blacklisted, already-charged shape, but the page beneath the modal
  // carries a genuinely OTHER run's marker. That is positively someone else's conversation — the
  // one case #208 gate r2 P1 allows to be disregarded when deciding absence — so it must keep
  // today's behaviour and still reach the confirmed-absent exit 4.
  const homeForeign215 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedBlacklistedCharged215(homeForeign215, blForeignUrl);
  const cdpForeign215 = await mockCdp('__NO_TABS__', [{ id: 'bl215f', url: blForeignUrl }], {
    tabText: () => foreignMarkedPage215,
    throttleModal: () => modalText215,
  });
  const rForeign215 = await runSalvageInHome(homeForeign215, ['--probe', MARKER, '3'], cdpForeign215.port);
  cdpForeign215.stop();
  check("#215 gate r1 P1 planted negative: a blacklisted tab carrying ANOTHER run's marker is still foreign evidence and reaches confirmed-absent (4)",
    rForeign215.status === 4, `status=${rForeign215.status} stderr=${rForeign215.stderr?.slice(-500)}`);
  check('#215 gate r1 P1 planted negative: the repeat foreign sighting is not reported as inconclusive',
    !/evidence-kind: inconclusive/.test(rForeign215.stderr || ''), `stderr=${rForeign215.stderr?.slice(-500)}`);
  check('#215 gate r1 P1 planted negative: the already-charged foreign sighting does not write the cooldown',
    rForeign215.cooldown === null, `cooldown=${rForeign215.cooldown}`);
  fs.rmSync(homeForeign215, { recursive: true, force: true });

  // Organizer variant: the same misclassification lived in the organizer's own batch mapping.
  // With the sighting already charged, no memo and no other candidate, the organizer used to fall
  // through to reason=provenance-rejected — an absence-like conclusion — instead of the
  // inconclusive reason=throttle framing #208 gate r2 P1 installed for exactly this case.
  const orgTitle215 = 'pro-gate review: PR #215 gate r1 P1 [pro-gate]';
  const homeOrgSelf215 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, orgTitle215)(homeOrgSelf215); // no memo url -> no recovery path at all
  seedBlacklistedCharged215(homeOrgSelf215, blSelfUrl);
  const cdpOrgSelf215 = await mockCdp('__NO_TABS__', [{ id: 'bl215', url: blSelfUrl }], {
    tabText: () => selfMarkedPage215,
    throttleModal: () => modalText215,
  });
  const rOrgSelf215 = await runSalvageInHome(homeOrgSelf215, ['--organize', MARKER, '5'], cdpOrgSelf215.port);
  cdpOrgSelf215.stop();
  check("#215 gate r1 P1 organizer: a blacklisted tab carrying THIS run's own marker under an already-charged modal reports reason=throttle, not an absence-like provenance rejection",
    /reason=throttle/.test(rOrgSelf215.stdout), `stdout=${rOrgSelf215.stdout} stderr=${rOrgSelf215.stderr?.slice(-400)}`);
  check('#215 gate r1 P1 organizer: the already-charged sighting neither writes nor rewrites the cooldown',
    rOrgSelf215.cooldown === null, `cooldown=${rOrgSelf215.cooldown}`);
  fs.rmSync(homeOrgSelf215, { recursive: true, force: true });

  const homeOrgForeign215 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, orgTitle215)(homeOrgForeign215);
  seedBlacklistedCharged215(homeOrgForeign215, blForeignUrl);
  const cdpOrgForeign215 = await mockCdp('__NO_TABS__', [{ id: 'bl215f', url: blForeignUrl }], {
    tabText: () => foreignMarkedPage215,
    throttleModal: () => modalText215,
  });
  const rOrgForeign215 = await runSalvageInHome(homeOrgForeign215, ['--organize', MARKER, '5'], cdpOrgForeign215.port);
  cdpOrgForeign215.stop();
  check("#215 gate r1 P1 organizer planted negative: a blacklisted tab carrying ANOTHER run's marker is still foreign evidence, so the organizer does not report reason=throttle",
    !/reason=throttle/.test(rOrgForeign215.stdout), `stdout=${rOrgForeign215.stdout} stderr=${rOrgForeign215.stderr?.slice(-400)}`);
  check('#215 gate r1 P1 organizer planted negative: the already-charged foreign sighting does not write the cooldown',
    rOrgForeign215.cooldown === null, `cooldown=${rOrgForeign215.cooldown}`);
  fs.rmSync(homeOrgForeign215, { recursive: true, force: true });
}

{ // #215 gate r6 P2 (bin/cdp-salvage.mjs pruneThrottleSeen, choice `bounded-dedupe`): the seen
  // record's TTL is the SUPPRESSION HORIZON and has to apply to a fingerprint the current scan is
  // observing exactly as it does to one nobody is observing. Pre-fix the prune skipped every
  // protectedKeys entry BEFORE the TTL check, so a record the scan protects could never expire:
  // a stale tab nobody closes re-protected its own record on every invocation and was suppressed
  // forever rather than for THROTTLE_SEEN_TTL, and an orphan record left by a killed writer could
  // do the same. The reviewer named two outcomes — `bounded-dedupe` (expire on the horizon even
  // when observed; an unchanged stale tab re-arms at most once per horizon) and leaving the
  // suppression unbounded — and bounded-dedupe is what is implemented here.
  // (a) and (b) are the regression. (c) and (d) are controls that the other two rules did NOT
  // move: capacity protection is still scan-scoped (#208 gate r3 P2), and an aged record this
  // scan never observes still expires. Both controls hold pre-fix, and so does (b) — a pre-fix
  // (a) charges nothing, so (b)'s "no second cooldown" is vacuously true there. (a) is the only
  // one of the four that separates the two worlds, by construction.
  const modalTextR6 = "You're making requests too quickly. [#215 gate r6 bounded-dedupe fixture]";
  const pageTextR6 = `ChatGPT\nAccount limits\n${modalTextR6}\nPlease try again shortly.\n`;
  const primaryUrlR6 = 'https://chatgpt.com/c/mock-conversation';   // the mock's own primary tab
  const EIGHT_DAYS_MS_R6 = 8 * 24 * 60 * 60 * 1000;   // past the 7-day THROTTLE_SEEN_TTL default
  const ageRecordR6 = (p, ms) => { const t = new Date(Date.now() - ms); fs.utimesSync(p, t, t); };
  // Tolerant of a MISSING cooldown: the pre-fix (a) writes none, and a throwing statSync here
  // would abort the whole test file instead of failing one check.
  const cooldownMtimeR6 = (p) => { try { return fs.statSync(p).mtimeMs; } catch { return null; } };
  const ageCooldownR6 = (p) => { try { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); } catch {} };
  const recordMtimeR6 = (p) => { try { return fs.statSync(p).mtimeMs; } catch { return null; } };
  const seenDirListR6 = (home) => (fs.existsSync(throttleSeenDir(home)) ? fs.readdirSync(throttleSeenDir(home)).length : null);

  // (a) an unowned stale modal whose record is EIGHT days old: the horizon has passed, so this
  // unchanged tab re-arms — exit 5, a cooldown, and a freshly recreated record.
  const homeR6 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedThrottleSeen(homeR6, primaryUrlR6, modalTextR6);
  const recordPathR6 = throttleSeenRecordPath(homeR6, primaryUrlR6, modalTextR6);
  ageRecordR6(recordPathR6, EIGHT_DAYS_MS_R6);
  const recordMtimeBeforeR6a = recordMtimeR6(recordPathR6);
  const cdpR6a = await mockCdp(pageTextR6, [], { throttleModal: modalTextR6 });
  const r6a = await runSalvageInHome(homeR6, [MARKER, '3'], cdpR6a.port);
  cdpR6a.stop();
  const recordMtimeAfterR6a = recordMtimeR6(recordPathR6);
  check('#215 gate r6 bounded-dedupe (a) an unowned stale modal whose seen record is eight days old takes the throttle exit again (5)',
    r6a.status === 5, `status=${r6a.status} stderr=${r6a.stderr?.slice(-400)}`);
  check('#215 gate r6 bounded-dedupe (a) the re-armed sighting writes a cooldown',
    /^\d{4}-\d{2}-\d{2}T/.test(r6a.cooldown ?? ''), `cooldown=${r6a.cooldown}`);
  check('#215 gate r6 bounded-dedupe (a) the expired record is recreated fresh, restarting the horizon',
    recordMtimeAfterR6a !== null && recordMtimeAfterR6a > recordMtimeBeforeR6a + 60_000,
    `before=${recordMtimeBeforeR6a} after=${recordMtimeAfterR6a} records=${seenDirListR6(homeR6)}`);

  // (b) the very next scan, record now fresh: suppressed again, so the re-arm costs exactly one
  // cooldown per horizon and not one per scan. Cooldown mtime is aged first so any rewrite shows.
  const cooldownPathR6 = path.join(homeR6, 'throttle.cooldown');
  ageCooldownR6(cooldownPathR6);
  const cooldownBeforeR6b = cooldownMtimeR6(cooldownPathR6);
  const cdpR6b = await mockCdp(pageTextR6, [], { throttleModal: modalTextR6 });
  const r6b = await runSalvageInHome(homeR6, [MARKER, '3'], cdpR6b.port);
  cdpR6b.stop();
  const cooldownAfterR6b = cooldownMtimeR6(cooldownPathR6);
  check('#215 gate r6 bounded-dedupe (b) the scan right after the re-arm does not take the throttle exit',
    r6b.status !== 5, `status=${r6b.status} stderr=${r6b.stderr?.slice(-300)}`);
  check('#215 gate r6 bounded-dedupe (b) the scan right after the re-arm writes no second cooldown',
    cooldownAfterR6b === cooldownBeforeR6b, `before=${cooldownBeforeR6b} after=${cooldownAfterR6b}`);
  check('#215 gate r6 bounded-dedupe (b) the suppressed repeat still names the sighting as already charged',
    /already charged/.test(r6b.stderr || ''), `stderr=${r6b.stderr?.slice(-300)}`);
  fs.rmSync(homeR6, { recursive: true, force: true });

  // (c) control (#208 gate r3 P2 must survive): a FRESH observed record is still exempt from the
  // CAPACITY trim. It is seeded with the oldest mtime on disk — the exact record the trim picks
  // first — and the directory is pushed over an overridden cap of one. It must survive untouched
  // and charge nothing, while the unprotected fillers are cut to the cap (proof the trim ran).
  const homeCapR6 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedThrottleSeen(homeCapR6, primaryUrlR6, modalTextR6);
  const capRecordPathR6 = throttleSeenRecordPath(homeCapR6, primaryUrlR6, modalTextR6);
  ageRecordR6(capRecordPathR6, 600_000);   // 10 minutes: well inside the TTL, oldest on disk
  const capMtimeBeforeR6 = recordMtimeR6(capRecordPathR6);
  const capFillerUrlR6 = (i) => `https://chatgpt.com/c/mock-r6-cap-filler-${i}`;
  const capFillerTextR6 = (i) => `unrelated filler text ${i}`;
  for (let i = 0; i < 2; i += 1) seedThrottleSeen(homeCapR6, capFillerUrlR6(i), capFillerTextR6(i));
  const cdpR6c = await mockCdp(pageTextR6, [], { throttleModal: modalTextR6 });
  const r6c = await runSalvageInHome(homeCapR6, [MARKER, '3'], cdpR6c.port, { PRO_GATE_THROTTLE_SEEN_MAX: '1' });
  cdpR6c.stop();
  const capMtimeAfterR6 = recordMtimeR6(capRecordPathR6);
  const capFillerSurvivorsR6 = [0, 1].filter((i) => throttleSeenHas(homeCapR6, capFillerUrlR6(i), capFillerTextR6(i))).length;
  check('#215 gate r6 bounded-dedupe (c) control: an unexpired observed fingerprint survives a capacity trim at PRO_GATE_THROTTLE_SEEN_MAX=1, mtime untouched',
    capMtimeAfterR6 !== null && capMtimeAfterR6 === capMtimeBeforeR6,
    `before=${capMtimeBeforeR6} after=${capMtimeAfterR6} records=${seenDirListR6(homeCapR6)}`);
  check('#215 gate r6 bounded-dedupe (c) control: the capacity trim really ran — the unprotected fillers are cut to the cap',
    capFillerSurvivorsR6 === 1, `survivors=${capFillerSurvivorsR6} records=${seenDirListR6(homeCapR6)}`);
  check('#215 gate r6 bounded-dedupe (c) control: the protected fingerprint charges no new cooldown',
    r6c.cooldown === null && r6c.status !== 5, `status=${r6c.status} cooldown=${r6c.cooldown}`);
  fs.rmSync(homeCapR6, { recursive: true, force: true });

  // (d) control (pre-existing behaviour): an aged record this scan does NOT observe is expired by
  // the same prune, fired here by an unrelated, genuinely new throttle sighting.
  const homeUnobsR6 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const unobservedUrlR6 = 'https://chatgpt.com/c/mock-r6-unobserved';
  const unobservedTextR6 = 'an old sighting from a tab that is no longer open';
  seedThrottleSeen(homeUnobsR6, unobservedUrlR6, unobservedTextR6);
  ageRecordR6(throttleSeenRecordPath(homeUnobsR6, unobservedUrlR6, unobservedTextR6), EIGHT_DAYS_MS_R6);
  const cdpR6d = await mockCdp(pageTextR6, [], { throttleModal: modalTextR6 });
  const r6d = await runSalvageInHome(homeUnobsR6, [MARKER, '3'], cdpR6d.port);
  cdpR6d.stop();
  check('#215 gate r6 bounded-dedupe (d) control: a record aged past the TTL that this scan never observes is still expired',
    !throttleSeenHas(homeUnobsR6, unobservedUrlR6, unobservedTextR6), `records=${seenDirListR6(homeUnobsR6)}`);
  check('#215 gate r6 bounded-dedupe (d) control: the unrelated trigger sighting is charged and recorded',
    r6d.status === 5 && throttleSeenHas(homeUnobsR6, primaryUrlR6, modalTextR6),
    `status=${r6d.status} cooldown=${r6d.cooldown} records=${seenDirListR6(homeUnobsR6)}`);
  fs.rmSync(homeUnobsR6, { recursive: true, force: true });
}

{ // #215 gate r7 P2 (bin/cdp-salvage.mjs pruneThrottleSeen / removeThrottleSeenGeneration):
  // expiration and the capacity trim must delete ONLY the record generation they actually
  // stat'd. Pre-fix both deleted BY NAME: scan A could stat an expired record, scan B could
  // expire that same record, create its replacement with the 'wx' arbiter and publish the
  // cooldown that replacement gates — and A's unlink then destroyed B's fresh, committed
  // fingerprint. Pruning a fingerprint outside its own observed batch, A never recreates it, so
  // the next unchanged sighting charges a SECOND cooldown inside the same horizon.
  //
  // (h*) drive the production functions directly. The interleaving window lives INSIDE
  // pruneThrottleSeen — between its stat and its delete — and no mock CDP fixture can reach it.
  // bin/cdp-salvage.mjs is a CLI script with no exports, so the functions are sliced out of the
  // file BY NAME and evaluated verbatim in a vm context whose fs, path and THROTTLE_SEEN_*
  // constants this test controls; the interleaving is injected through that fs, at the exact
  // moment the pruner stats the record it is about to condemn. Nothing here is reimplemented: a
  // slice that no longer exists surfaces as a null function and a failing check, never as a
  // quietly different pruner.
  // (c*) then cover the same sidecar end-to-end through real salvage children.
  const salvageLinesR7 = fs.readFileSync(SALVAGE, 'utf8').split('\n');
  const sliceTopLevelR7 = (name) => {
    const start = salvageLinesR7.findIndex((line) => (
      line.startsWith(`function ${name}(`) || line.startsWith(`const ${name} = `)
    ));
    if (start < 0) return null;
    // A single-line const, or a function whose whole body is on its declaration line, IS the
    // slice; anything else runs to the first column-zero '}', which closes a top-level function.
    if (salvageLinesR7[start].startsWith('const ') || salvageLinesR7[start].trimEnd().endsWith('}')) {
      return salvageLinesR7[start];
    }
    const end = salvageLinesR7.findIndex((line, i) => i > start && line === '}');
    return end < 0 ? null : salvageLinesR7.slice(start, end + 1).join('\n');
  };
  const PRUNER_PARTS_R7 = ['THROTTLE_SEEN_EXPIRE_MARK', 'throttleSeenIsTemp', 'throttleSeenIsLock',
    'THROTTLE_SEEN_LOCK_STALE_MS', 'THROTTLE_SEEN_LOCK_WAIT_MS', 'withThrottleSeenLock',
    'removeThrottleSeenGeneration', 'pruneThrottleSeen'];
  const buildPrunerR7 = (dir, { ttlMs = 7 * 24 * 60 * 60 * 1000, max = 512, fsImpl = fs } = {}) => {
    const source = PRUNER_PARTS_R7.map(sliceTopLevelR7).filter((part) => part !== null).join('\n');
    const expose = '({ prune: typeof pruneThrottleSeen === "function" ? pruneThrottleSeen : null,'
      + ' removeGeneration: typeof removeThrottleSeenGeneration === "function" ? removeThrottleSeenGeneration : null })';
    return runInNewContext(`${source}\n${expose}`, {
      fs: fsImpl, path, process,
      THROTTLE_SEEN_DIR: dir, THROTTLE_SEEN_TTL_MS: ttlMs, THROTTLE_SEEN_MAX: max,
    });
  };
  const EIGHT_DAYS_R7 = 8 * 24 * 60 * 60 * 1000;   // past the 7-day THROTTLE_SEEN_TTL default
  const seenDirR7 = () => fs.mkdtempSync(path.join(os.tmpdir(), 'pg-r7-seen-'));
  // Record basenames are sha256 hex in production (throttleSeenKey); these are shaped the same so
  // the temp-vs-record predicate is exercised against realistic names.
  const keyR7 = (label) => createHash('sha256').update(`#215 gate r7 ${label}`).digest('hex');
  const seedRecordR7 = (dir, name, ageMs = 0) => {
    const p = path.join(dir, name);
    fs.writeFileSync(p, '', { flag: 'wx' });
    if (ageMs > 0) { const t = new Date(Date.now() - ageMs); fs.utimesSync(p, t, t); }
    return p;
  };
  const ageRecordR7 = (p, ms) => { const t = new Date(Date.now() - ms); fs.utimesSync(p, t, t); };
  const inoR7 = (p) => { try { return fs.statSync(p).ino; } catch { return null; } };
  const mtimeR7 = (p) => { try { return fs.statSync(p).mtimeMs; } catch { return null; } };
  const listR7 = (dir) => { try { return fs.readdirSync(dir); } catch { return []; } };
  const tempsR7 = (dir) => listR7(dir).filter((n) => n.includes('.expire.'));
  // The interleaving itself: the instant the pruner stats the record it is about to condemn,
  // another scan expires that generation and commits its REPLACEMENT through the same 'wx'
  // arbiter production uses. One shot — the finding describes a single interleaving, and a
  // repeating one would say nothing more. The replacement's mtime is `now` while every condemned
  // record below is seeded minutes or days old, so the two generations can never read as equal.
  const replaceOnStatR7 = (target, out) => {
    let fired = false;
    const proxy = Object.create(fs);
    proxy.statSync = (p, ...rest) => {
      const stat = fs.statSync(p, ...rest);
      if (!fired && p === target) {
        fired = true;
        try { fs.unlinkSync(target); } catch {}
        fs.writeFileSync(target, '', { flag: 'wx' });
        out.ino = fs.statSync(target).ino;
      }
      return stat;
    };
    return proxy;
  };

  // (h1) EXPIRATION path, the finding's exact sequence. Pre-fix the pruner unlinked by name and
  // destroyed the replacement it never looked at.
  const dirH1 = seenDirR7();
  const pathH1 = seedRecordR7(dirH1, keyR7('h1 expired'), EIGHT_DAYS_R7);
  const replacedH1 = { ino: null };
  buildPrunerR7(dirH1, { fsImpl: replaceOnStatR7(pathH1, replacedH1) }).prune?.(new Set());
  check("#215 gate r7 P2 (h1) expiration: a replacement committed between the pruner's stat and its delete survives, and it is the REPLACEMENT that survives",
    replacedH1.ino !== null && inoR7(pathH1) === replacedH1.ino,
    `replacementIno=${replacedH1.ino} onDiskIno=${inoR7(pathH1)} dir=${JSON.stringify(listR7(dirH1))}`);
  check('#215 gate r7 P2 (h1) expiration: declining to delete leaves no orphan temp behind',
    tempsR7(dirH1).length === 0, `dir=${JSON.stringify(listR7(dirH1))}`);
  fs.rmSync(dirH1, { recursive: true, force: true });

  // (h2) CAPACITY path: the same protection, on the other eviction. The trim's oldest-first
  // candidate is replaced during the stat pass, after its mtime was read and before it is cut.
  const dirH2 = seenDirR7();
  const pathOldH2 = seedRecordR7(dirH2, keyR7('h2 oldest'), 600_000);
  const nameMidH2 = keyR7('h2 mid');
  const nameNewH2 = keyR7('h2 newest');
  seedRecordR7(dirH2, nameMidH2, 300_000);
  seedRecordR7(dirH2, nameNewH2, 60_000);
  const replacedH2 = { ino: null };
  buildPrunerR7(dirH2, { max: 2, fsImpl: replaceOnStatR7(pathOldH2, replacedH2) }).prune?.(new Set());
  check("#215 gate r7 P2 (h2) capacity: a replacement committed between the trim's stat and its delete survives the trim",
    replacedH2.ino !== null && inoR7(pathOldH2) === replacedH2.ino,
    `replacementIno=${replacedH2.ino} onDiskIno=${inoR7(pathOldH2)} dir=${JSON.stringify(listR7(dirH2))}`);
  check('#215 gate r7 P2 (h2) capacity: the records the trim did not condemn are untouched, and no orphan temp is left',
    fs.existsSync(path.join(dirH2, nameMidH2)) && fs.existsSync(path.join(dirH2, nameNewH2)) && tempsR7(dirH2).length === 0,
    `dir=${JSON.stringify(listR7(dirH2))}`);
  fs.rmSync(dirH2, { recursive: true, force: true });

  // (h3) control: with nothing interleaving, the checked generation IS still deleted — the fix
  // must not buy safety by declining to expire anything.
  const dirH3 = seenDirR7();
  const nameExpiredH3 = keyR7('h3 expired');
  const nameLiveH3 = keyR7('h3 live');
  seedRecordR7(dirH3, nameExpiredH3, EIGHT_DAYS_R7);
  seedRecordR7(dirH3, nameLiveH3, 60_000);
  buildPrunerR7(dirH3).prune?.(new Set());
  check('#215 gate r7 P2 (h3) control: an expired record whose generation did not change is still deleted, the unexpired one survives, and no temp is left',
    !fs.existsSync(path.join(dirH3, nameExpiredH3)) && fs.existsSync(path.join(dirH3, nameLiveH3)) && tempsR7(dirH3).length === 0,
    `dir=${JSON.stringify(listR7(dirH3))}`);
  fs.rmSync(dirH3, { recursive: true, force: true });

  // (h4) control: the capacity trim still evicts oldest-first when nothing interleaves.
  const dirH4 = seenDirR7();
  const nameOldH4 = keyR7('h4 oldest');
  const nameMidH4 = keyR7('h4 mid');
  const nameNewH4 = keyR7('h4 newest');
  seedRecordR7(dirH4, nameOldH4, 600_000);
  seedRecordR7(dirH4, nameMidH4, 300_000);
  seedRecordR7(dirH4, nameNewH4, 60_000);
  buildPrunerR7(dirH4, { max: 2 }).prune?.(new Set());
  check('#215 gate r7 P2 (h4) control: with no interleaving the capacity trim still cuts the oldest unprotected record down to the cap, leaving no temp',
    !fs.existsSync(path.join(dirH4, nameOldH4)) && fs.existsSync(path.join(dirH4, nameMidH4))
      && fs.existsSync(path.join(dirH4, nameNewH4)) && tempsR7(dirH4).length === 0,
    `dir=${JSON.stringify(listR7(dirH4))}`);
  fs.rmSync(dirH4, { recursive: true, force: true });

  // (h5) the residual's cleanup: a temp left behind by a writer that died mid-swap ages out on
  // the same horizon, so an orphan can never accumulate.
  const dirH5 = seenDirR7();
  const nameLiveH5 = keyR7('h5 live');
  const nameTempH5 = `${keyR7('h5 orphan')}.expire.424242`;
  seedRecordR7(dirH5, nameTempH5, EIGHT_DAYS_R7);
  seedRecordR7(dirH5, nameLiveH5, 60_000);
  buildPrunerR7(dirH5).prune?.(new Set());
  check('#215 gate r7 P2 (h5) an orphan .expire. temp older than the TTL is deleted, and a live record beside it is untouched',
    !fs.existsSync(path.join(dirH5, nameTempH5)) && fs.existsSync(path.join(dirH5, nameLiveH5)),
    `dir=${JSON.stringify(listR7(dirH5))}`);
  fs.rmSync(dirH5, { recursive: true, force: true });

  // (h6) a temp is NOT a record: it suppresses nothing, so it must never occupy a capacity slot
  // (which would evict a real fingerprint in its place) and the trim must never pick it.
  const dirH6 = seenDirR7();
  const nameTempH6 = `${keyR7('h6 orphan')}.expire.424243`;
  const nameMidH6 = keyR7('h6 mid');
  const nameNewH6 = keyR7('h6 newest');
  seedRecordR7(dirH6, nameTempH6, 600_000);   // oldest on disk: the trim's first pick if counted
  seedRecordR7(dirH6, nameMidH6, 300_000);
  seedRecordR7(dirH6, nameNewH6, 60_000);
  buildPrunerR7(dirH6, { max: 2 }).prune?.(new Set());
  check('#215 gate r7 P2 (h6) an unexpired .expire. temp is never counted toward capacity, so the trim does not fire and does not pick it',
    fs.existsSync(path.join(dirH6, nameTempH6)),
    `dir=${JSON.stringify(listR7(dirH6))}`);
  check('#215 gate r7 P2 (h6) both real records survive a cap of two',
    fs.existsSync(path.join(dirH6, nameMidH6)) && fs.existsSync(path.join(dirH6, nameNewH6)),
    `dir=${JSON.stringify(listR7(dirH6))}`);
  fs.rmSync(dirH6, { recursive: true, force: true });

  // --- end-to-end through real salvage children -------------------------------------------
  const modalTriggerR7 = "You're making requests too quickly. [#215 gate r7 trigger]";
  const modalConcurrentR7 = "You're making requests too quickly. [#215 gate r7 concurrent writer]";
  const pageR7 = (modal) => `ChatGPT\nAccount limits\n${modal}\nPlease try again shortly.\n`;
  const primaryUrlR7 = 'https://chatgpt.com/c/mock-conversation';   // the mock's own primary tab

  // (c1) control, the e1a2195 behaviour: an expired record the scan IS observing still expires
  // and re-charges exactly once, and the swap leaves no temp behind.
  const homeC1 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedThrottleSeen(homeC1, primaryUrlR7, modalTriggerR7);
  const recordC1 = throttleSeenRecordPath(homeC1, primaryUrlR7, modalTriggerR7);
  ageRecordR7(recordC1, EIGHT_DAYS_R7);
  const mtimeBeforeC1 = mtimeR7(recordC1);
  const cdpC1 = await mockCdp(pageR7(modalTriggerR7), [], { throttleModal: modalTriggerR7 });
  const rC1 = await runSalvageInHome(homeC1, [MARKER, '3'], cdpC1.port);
  cdpC1.stop();
  const mtimeAfterC1 = mtimeR7(recordC1);
  check('#215 gate r7 P2 (c1) control: an expired record this scan observes still expires and re-charges once (exit 5 + cooldown)',
    rC1.status === 5 && /^\d{4}-\d{2}-\d{2}T/.test(rC1.cooldown ?? ''),
    `status=${rC1.status} cooldown=${rC1.cooldown} stderr=${rC1.stderr?.slice(-300)}`);
  check('#215 gate r7 P2 (c1) control: the expired record is replaced by a fresh one, restarting the horizon',
    mtimeAfterC1 !== null && mtimeBeforeC1 !== null && mtimeAfterC1 > mtimeBeforeC1 + 60_000,
    `before=${mtimeBeforeC1} after=${mtimeAfterC1} dir=${JSON.stringify(listR7(throttleSeenDir(homeC1)))}`);
  check('#215 gate r7 P2 (c1) control: a completed expiration leaves no temp in the sidecar directory',
    tempsR7(throttleSeenDir(homeC1)).length === 0, `dir=${JSON.stringify(listR7(throttleSeenDir(homeC1)))}`);
  fs.rmSync(homeC1, { recursive: true, force: true });

  // (c2) the same shape as (h1) but across real processes: another writer replaces an expired
  // record DURING the child's scan, for a fingerprint that child never observes. The replacement
  // must survive the scan's prune and must suppress the next sighting of it.
  const homeC2 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedThrottleSeen(homeC2, primaryUrlR7, modalConcurrentR7);
  const recordC2 = throttleSeenRecordPath(homeC2, primaryUrlR7, modalConcurrentR7);
  ageRecordR7(recordC2, EIGHT_DAYS_R7);
  // An aged record nobody replaces: its deletion is this test's proof that the child's prune ran
  // at all, and `existedAtReplace` below proves it ran AFTER the replacement landed. Without both
  // the survival check could pass vacuously on a prune that never looked.
  const unobservedUrlC2 = 'https://chatgpt.com/c/mock-r7-unobserved';
  const unobservedTextC2 = 'an old sighting from a tab nobody replaced';
  seedThrottleSeen(homeC2, unobservedUrlC2, unobservedTextC2);
  ageRecordR7(throttleSeenRecordPath(homeC2, unobservedUrlC2, unobservedTextC2), EIGHT_DAYS_R7);
  const concurrentC2 = { existedAtReplace: null, ino: null };
  const cdpC2 = await mockCdp(pageR7(modalTriggerR7), [], {
    throttleModal: modalTriggerR7,
    onEvaluate: (id, expression) => {
      if (concurrentC2.ino !== null || !expression.includes('pro-gate:review-text')) return;
      concurrentC2.existedAtReplace = fs.existsSync(recordC2);
      try { fs.unlinkSync(recordC2); } catch {}
      fs.writeFileSync(recordC2, '', { flag: 'wx' });
      concurrentC2.ino = fs.statSync(recordC2).ino;
    },
  });
  const rC2 = await runSalvageInHome(homeC2, [MARKER, '3'], cdpC2.port);
  cdpC2.stop();
  check("#215 gate r7 P2 (c2) ordering proof: the replacement landed while the record was still the expired one, and this scan's prune demonstrably ran",
    concurrentC2.existedAtReplace === true && !throttleSeenHas(homeC2, unobservedUrlC2, unobservedTextC2),
    `existedAtReplace=${concurrentC2.existedAtReplace} dir=${JSON.stringify(listR7(throttleSeenDir(homeC2)))}`);
  check("#215 gate r7 P2 (c2) a concurrent writer's replacement for a fingerprint this scan never observes survives the scan's prune",
    concurrentC2.ino !== null && inoR7(recordC2) === concurrentC2.ino,
    `replacementIno=${concurrentC2.ino} onDiskIno=${inoR7(recordC2)} dir=${JSON.stringify(listR7(throttleSeenDir(homeC2)))}`);
  check('#215 gate r7 P2 (c2) the scan still charges its own genuinely new sighting (exit 5 + cooldown)',
    rC2.status === 5 && /^\d{4}-\d{2}-\d{2}T/.test(rC2.cooldown ?? ''),
    `status=${rC2.status} cooldown=${rC2.cooldown} stderr=${rC2.stderr?.slice(-300)}`);
  const cooldownPathC2 = path.join(homeC2, 'throttle.cooldown');
  ageRecordR7(cooldownPathC2, 3_600_000);
  const cooldownBeforeC2 = mtimeR7(cooldownPathC2);
  const cdpC2b = await mockCdp(pageR7(modalConcurrentR7), [], { throttleModal: modalConcurrentR7 });
  const rC2b = await runSalvageInHome(homeC2, [MARKER, '3'], cdpC2b.port);
  cdpC2b.stop();
  check('#215 gate r7 P2 (c2) the next sighting of the replaced fingerprint is suppressed, not re-charged',
    rC2b.status !== 5 && mtimeR7(cooldownPathC2) === cooldownBeforeC2 && /already charged/.test(rC2b.stderr || ''),
    `status=${rC2b.status} before=${cooldownBeforeC2} after=${mtimeR7(cooldownPathC2)} stderr=${rC2b.stderr?.slice(-300)}`);
  fs.rmSync(homeC2, { recursive: true, force: true });
}

// v0.42 (#109): a synthetic placeholder such as https://chatgpt.com/c/WEB:<uuid> once passed the
// prefix-only memo check, was remembered as authoritative, and parked its run forever: the page
// behind it carries no marker, so every later pass was inconclusive and never counted a miss.
// The memo's conversation id must now be one path segment of letters, digits, and dashes, checked
// when a URL is remembered AND every time one is read.
const PLACEHOLDER_URLS = [
  'https://chatgpt.com/c/WEB:57cc5403-ad61-4ccd-af90-ad28a539081e',
  // A well-formed UUID after the prefix must still fail: the check anchors the whole segment.
  'https://chatgpt.com/c/WEB:b385e15b-9c62-4dca-bec7-0be2f579c0f3',
];
const REAL_ID_URL = 'https://chatgpt.com/c/6a959c8f-c95c-83ea-81b8-85a3ea5d6cbc';

{ // AE1: write time — a placeholder-URL tab that carries our marker is NEVER remembered.
  const placeholder = PLACEHOLDER_URLS[0];
  const cdp = await mockCdp('__NO_TABS__', [{ id: 'ph1', type: 'page', url: placeholder }], {
    tabText: () => `run marker: ${MARKER}\nthinking hard, no verdict yet`,
  });
  const r = await runFastPollSalvage([MARKER, '3'], cdp.port);
  check('placeholder tab still counts as our still-generating conversation (exit 3)', r.status === 3, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  check('placeholder URL is not remembered as a memo', r.memos.length === 0, `memos=${r.memos} memo=${r.memoUrl}`);
  check('rejection names the marker and the offending id',
    (r.stderr || '').includes('memo-rejected') && (r.stderr || '').includes(MARKER) && (r.stderr || '').includes('WEB:57cc5403'),
    `stderr=${r.stderr?.slice(-400)}`);
  cdp.stop();
}

{ // AE5: write time — a real conversation id is remembered exactly as before.
  const cdp = await mockCdp('__NO_TABS__', [{ id: 'real1', type: 'page', url: REAL_ID_URL }], {
    tabText: () => `run marker: ${MARKER}\nthinking hard, no verdict yet`,
  });
  const r = await runFastPollSalvage([MARKER, '3'], cdp.port);
  check('real-id tab is remembered', r.memoUrl === REAL_ID_URL, `memo=${r.memoUrl} status=${r.status}`);
  check('real-id memo has no rejection line', !/memo-rejected/.test(r.stderr || ''), `stderr=${r.stderr?.slice(-300)}`);
  cdp.stop();
}

for (const placeholder of PLACEHOLDER_URLS) {
  // AE2 (first pass): read time — a seeded placeholder memo is revoked in the SAME pass, the
  // pass rescans, and with no candidate carrying the marker it exits confirmed-absent (4), not
  // inconclusive (7). Before the fix the remembered render never rendered the marker and the
  // pass parked at exit 7 forever, never counting a miss.
  const cdp = await mockCdp('an unrelated page with no run marker at all');
  const r = await runFastPollSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, placeholder));
  const id = placeholder.split('/c/')[1];
  check(`placeholder memo ${id.slice(0, 12)} is revoked on read`, r.memos.length === 0, `memos=${r.memos} memo=${r.memoUrl}`);
  check(`revocation names the marker and id (${id.slice(0, 12)})`,
    (r.stderr || '').includes('memo-revoked') && (r.stderr || '').includes(MARKER) && (r.stderr || '').includes(id),
    `stderr=${r.stderr?.slice(-400)}`);
  check(`same pass reaches confirmed-absent after revoking ${id.slice(0, 12)}`, r.status === 4, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  check(`revocation pass names its conclusion as absent (${id.slice(0, 12)})`, /^evidence-kind: absent$/m.test(r.stderr || ''), `stderr=${r.stderr?.slice(-300)}`);
  cdp.stop();
}

{ // AE2 with a genuine candidate elsewhere: the placeholder is revoked and the pass binds the
  // genuine conversation instead of parking on the placeholder.
  const cdp = await mockCdp(`run marker: ${MARKER}\nthinking hard, no verdict yet`);
  const r = await runFastPollSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, PLACEHOLDER_URLS[0]));
  check('placeholder revoked when a genuine candidate exists', /memo-revoked/.test(r.stderr || ''), `stderr=${r.stderr?.slice(-300)}`);
  check('genuine candidate is bound and remembered', r.memoUrl === 'https://chatgpt.com/c/mock-conversation', `memo=${r.memoUrl}`);
  check('genuine still-generating candidate keeps exit 3', r.status === 3, `status=${r.status}`);
  cdp.stop();
}

{ // AE3: a real-id memo whose page renders WITHOUT the marker stays inconclusive and is kept:
  // a blank render is a transient, never a miss, and never a revocation.
  const cdp = await mockCdp('an unrelated page with no run marker at all');
  const r = await runFastPollSalvage([MARKER, '3'], cdp.port, seedMemo(MARKER, REAL_ID_URL));
  check('real-id blank render stays inconclusive (exit 7)', r.status === 7, `status=${r.status} stderr=${r.stderr?.slice(-300)}`);
  check('real-id memo is kept', r.memoUrl === REAL_ID_URL, `memo=${r.memoUrl}`);
  check('real-id memo is not revoked', !/memo-revoked/.test(r.stderr || ''), `stderr=${r.stderr?.slice(-300)}`);
  check('blank render names its conclusion as inconclusive', /^evidence-kind: inconclusive$/m.test(r.stderr || ''), `stderr=${r.stderr?.slice(-300)}`);
  cdp.stop();
}

{ // The organize step reads the memo too, so it revokes a placeholder as well.
  const cdp = await mockCdp(`run marker: ${MARKER}\nstill thinking`);
  const r = await runSalvage(['--organize', MARKER, '5'], cdp.port, seedOrganizer(MARKER, 'pro-gate review: PR #42 r1', PLACEHOLDER_URLS[0]));
  // The organize step then re-remembers the genuine conversation it found, so the memo is
  // replaced, not merely removed: what must never survive is the placeholder.
  check('organize revokes a placeholder memo', r.memoUrl !== PLACEHOLDER_URLS[0], `memos=${r.memos} memo=${r.memoUrl} status=${r.status}`);
  check('organize names the revoked id', /memo-revoked/.test(r.stderr || ''), `stderr=${r.stderr?.slice(-300)}`);
  cdp.stop();
}

{ // #170 on the same early-exit paths: the flush now has to DISTINGUISH. Unsupported stale
  // conviction -> cleared (the block above). Conviction the blacklist is still suppressing ->
  // kept. The check that decides this runs where --sweep-root and --close return, which is
  // ABOVE the `nonMatching` declaration — reading that Set from the hook would revive the exact
  // #76 dead-zone crash, so this asserts the retention AND the absence of a ReferenceError.
  const suppressedUrl = 'https://chatgpt.com/c/other';
  const stale = `2026-01-01T00:00:00.000Z\t${suppressedUrl}\tpg-run-someone-else\n`;
  const seedSuppressed = (home) => {
    fs.mkdirSync(path.join(home, 'crossbound'), { recursive: true });
    fs.writeFileSync(path.join(home, 'crossbound', MARKER), stale);
    fs.writeFileSync(path.join(home, 'salvage-nonmatching.txt'), `${MARKER}\t${suppressedUrl}\n`);
  };
  for (const mode of ['--sweep-root', '--close']) {
    const cdp = await mockCdp(`run marker: ${MARKER}\nstill thinking`,
      [{ id: 'root1', type: 'page', url: 'https://chatgpt.com/' }]);
    const r = await runSalvage([mode, MARKER, '10'], cdp.port, seedSuppressed);
    check(`${mode} consults the blacklist without a temporal-dead-zone crash`,
      !/ReferenceError/.test(r.stderr ?? ''), `stderr=${r.stderr?.slice(0, 300)}`);
    check(`${mode} keeps a conviction the blacklist is still suppressing`,
      r.crossboundBody === stale, `body=${JSON.stringify(r.crossboundBody)} stderr=${r.stderr?.slice(0, 300)}`);
    cdp.stop();
  }
}

{ // #206 gate r8 P2 finding B: rememberUrl()'s MEMO_KEEP eviction used to prune the oldest
  // memos with no regard for whether the marker's reservation was still retained (states
  // generating or superseded) -- so a memo that is a superseded run's ONLY recovery handle
  // could be evicted purely because 200 other memos happen to be newer. Eviction must protect
  // any memo whose marker still has a reservation file, and the cap must apply only to the
  // unprotected remainder.
  const seedMemoCohort = (entries) => (home) => { // entries: oldest-first [{marker, protectedMarker}]
    const dir = path.join(home, 'conversation-urls');
    fs.mkdirSync(dir, { recursive: true });
    const resDir = path.join(home, 'in-progress');
    entries.forEach(({ marker: m, protectedMarker }, i) => {
      const f = path.join(dir, m);
      fs.writeFileSync(f, 'https://chatgpt.com/c/seed-placeholder\n');
      const t = new Date(1700099000000 + i * 1000);
      fs.utimesSync(f, t, t);
      if (protectedMarker) {
        fs.mkdirSync(resDir, { recursive: true });
        fs.writeFileSync(path.join(resDir, m), 'seed-reservation\n');
      }
    });
  };
  const newAnswer = (m) => [
    `run marker: ${m}`, 'P1: none', 'P2: none', 'P3: none',
    `VERDICT: SHIP — ours. (run marker: ${m})`,
  ].join('\n');

  {
    // MEMO_KEEP+1 pre-seeded (1 protected, oldest of all, + 200 unprotected), then one more
    // rememberUrl publication for a brand-new marker. Unprotected count goes 200 -> 201, so
    // exactly one eviction happens; it must take the oldest UNPROTECTED memo, never the
    // protected one, even though the protected one is chronologically the very oldest.
    const PROTECTED = 'pg-run-memo-cap-protected-1700099000-1';
    const unprotected = Array.from({ length: 200 }, (_, i) => `pg-run-memo-cap-u-${i}-1700099000-1`);
    const cohort = [{ marker: PROTECTED, protectedMarker: true }, ...unprotected.map((m) => ({ marker: m }))];
    const NEW_MARKER = 'pg-run-memo-cap-new-1700099500-9';
    const cdp = await mockCdp(newAnswer(NEW_MARKER));
    const r = await runSalvage([NEW_MARKER, '20'], cdp.port, seedMemoCohort(cohort));
    const memoSet = new Set(r.memos);
    check('finding B: a protected marker survives MEMO_KEEP eviction even though it is the oldest memo',
      memoSet.has(PROTECTED), `memos.length=${r.memos.length} stderr=${r.stderr?.slice(-300)}`);
    check('finding B: the oldest UNPROTECTED memo is the one evicted, its neighbor and the new memo survive',
      !memoSet.has(unprotected[0]) && memoSet.has(unprotected[1]) && memoSet.has(NEW_MARKER),
      `memos.length=${r.memos.length} evicted0=${memoSet.has(unprotected[0])} kept1=${memoSet.has(unprotected[1])} new=${memoSet.has(NEW_MARKER)}`);
    check('finding B: total memo count is MEMO_KEEP+1 (1 protected + 200 unprotected) after the one eviction',
      r.memos.length === 201, `memos.length=${r.memos.length}`);
    cdp.stop();
  }
  {
    // Boundary: exactly MEMO_KEEP (200) unprotected entries after the new write evicts nothing,
    // even though the directory total (201) exceeds MEMO_KEEP once the protected entry is
    // counted -- protected entries never count toward the cap.
    const PROTECTED = 'pg-run-memo-cap-protected-b-1700099000-1';
    const unprotected = Array.from({ length: 199 }, (_, i) => `pg-run-memo-cap-ub-${i}-1700099000-1`);
    const cohort = [{ marker: PROTECTED, protectedMarker: true }, ...unprotected.map((m) => ({ marker: m }))];
    const NEW_MARKER = 'pg-run-memo-cap-newb-1700099500-9';
    const cdp = await mockCdp(newAnswer(NEW_MARKER));
    const r = await runSalvage([NEW_MARKER, '20'], cdp.port, seedMemoCohort(cohort));
    const memoSet = new Set(r.memos);
    check('finding B boundary: exactly MEMO_KEEP unprotected entries evicts nothing',
      memoSet.has(PROTECTED) && unprotected.every((m) => memoSet.has(m)) && memoSet.has(NEW_MARKER)
        && r.memos.length === 201,
      `memos.length=${r.memos.length} stderr=${r.stderr?.slice(-300)}`);
    cdp.stop();
  }
}

{ // #216 gate r1 P2: RESERVATION_DIR must honor PRO_GATE_RESERVATION_DIR the same way
  // lib/pro-gate-lib.sh's pg_reservation_dir() does (its sibling constants COMPLETED_DIR and
  // COOLDOWN_FILE already read `process.env.PRO_GATE_X ?? path.join(PG_HOME, ...)`). When an
  // operator or test relocates reservations via that override, a hardcoded PG_HOME/in-progress
  // check never finds the real reservation file, every memo reads as unprotected, and finding
  // B's eviction bug reappears under that configuration.
  const customResDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-resdir-override-'));
  const seedMemoCohortCustomResDir = (entries) => (home) => { // reservation files go in customResDir, not home
    const dir = path.join(home, 'conversation-urls');
    fs.mkdirSync(dir, { recursive: true });
    entries.forEach(({ marker: m, protectedMarker }, i) => {
      const f = path.join(dir, m);
      fs.writeFileSync(f, 'https://chatgpt.com/c/seed-placeholder\n');
      const t = new Date(1700099000000 + i * 1000);
      fs.utimesSync(f, t, t);
      if (protectedMarker) fs.writeFileSync(path.join(customResDir, m), 'seed-reservation\n');
    });
  };
  const newAnswer = (m) => [
    `run marker: ${m}`, 'P1: none', 'P2: none', 'P3: none',
    `VERDICT: SHIP — ours. (run marker: ${m})`,
  ].join('\n');

  const PROTECTED = 'pg-run-resdir-protected-1700099000-1';
  const unprotected = Array.from({ length: 200 }, (_, i) => `pg-run-resdir-u-${i}-1700099000-1`);
  const cohort = [{ marker: PROTECTED, protectedMarker: true }, ...unprotected.map((m) => ({ marker: m }))];
  const NEW_MARKER = 'pg-run-resdir-new-1700099500-9';
  const cdp = await mockCdp(newAnswer(NEW_MARKER));
  const r = await runSalvage([NEW_MARKER, '20'], cdp.port, seedMemoCohortCustomResDir(cohort),
    { PRO_GATE_RESERVATION_DIR: customResDir });
  const memoSet = new Set(r.memos);
  check('PRO_GATE_RESERVATION_DIR override: a protected marker under the relocated reservation dir survives MEMO_KEEP eviction',
    memoSet.has(PROTECTED), `memos.length=${r.memos.length} stderr=${r.stderr?.slice(-300)}`);
  cdp.stop();
  fs.rmSync(customResDir, { recursive: true, force: true });
}

{ // #216 gate r1 P2 (paid review, finding at bin/cdp-salvage.mjs:207): an EMPTY
  // PRO_GATE_RESERVATION_DIR disabled retained-memo protection outright. The shell's
  // pg_reservation_dir() is "${PRO_GATE_RESERVATION_DIR:-$PRO_GATE_HOME/in-progress}", which
  // falls back on empty as well as unset; JavaScript's `??` did not, so RESERVATION_DIR stayed
  // '', path.join('', marker) resolved against the process's working directory, every existsSync
  // missed, and every retained reservation read as unprotected -- finding B's eviction bug, back
  // under one configuration. The control for this is the non-empty override check above.
  const seedMemoCohortHomeReservations = (entries) => (home) => {
    const dir = path.join(home, 'conversation-urls');
    fs.mkdirSync(dir, { recursive: true });
    const resDir = path.join(home, 'in-progress');
    entries.forEach(({ marker: m, protectedMarker }, i) => {
      const f = path.join(dir, m);
      fs.writeFileSync(f, 'https://chatgpt.com/c/seed-placeholder\n');
      const t = new Date(1700099000000 + i * 1000);
      fs.utimesSync(f, t, t);
      if (protectedMarker) {
        fs.mkdirSync(resDir, { recursive: true });
        fs.writeFileSync(path.join(resDir, m), 'seed-reservation\n');
      }
    });
  };
  const newAnswer = (m) => [
    `run marker: ${m}`, 'P1: none', 'P2: none', 'P3: none',
    `VERDICT: SHIP — ours. (run marker: ${m})`,
  ].join('\n');

  const PROTECTED = 'pg-run-resdir-empty-protected-1700099000-1';
  const unprotected = Array.from({ length: 200 }, (_, i) => `pg-run-resdir-empty-u-${i}-1700099000-1`);
  const cohort = [{ marker: PROTECTED, protectedMarker: true }, ...unprotected.map((m) => ({ marker: m }))];
  const NEW_MARKER = 'pg-run-resdir-empty-new-1700099500-9';
  const cdp = await mockCdp(newAnswer(NEW_MARKER));
  const r = await runSalvage([NEW_MARKER, '20'], cdp.port, seedMemoCohortHomeReservations(cohort),
    { PRO_GATE_RESERVATION_DIR: '' });
  const memoSet = new Set(r.memos);
  check("#216 gate r1 P2: an EMPTY PRO_GATE_RESERVATION_DIR falls back to PRO_GATE_HOME/in-progress like the shell, so a protected marker still survives eviction",
    memoSet.has(PROTECTED), `memos.length=${r.memos.length} stderr=${r.stderr?.slice(-300)}`);
  check("#216 gate r1 P2: the empty override still evicts the oldest UNPROTECTED memo",
    !memoSet.has(unprotected[0]) && memoSet.has(unprotected[1]) && memoSet.has(NEW_MARKER)
      && r.memos.length === 201,
    `memos.length=${r.memos.length} evicted0=${memoSet.has(unprotected[0])} kept1=${memoSet.has(unprotected[1])}`);
  cdp.stop();
}

{ // #215 gate r8 P2 (bin/cdp-salvage.mjs throttleAlreadyCharged): admission is a plain existence
  // check on the record path — #215 gate r9 P2 replaced the round-8 fresh-temp heuristic
  // (throttleSeenFreshTemp) with claimThrottleSeen taking removeThrottleSeenGeneration's own
  // per-fingerprint lock across the existence-check-then-create, closing the round-8 window
  // directly instead of papering over it with a second, fuzzy on-disk signal. What remains
  // worth checking here: a rename-aside temp left over from an interrupted prune (crash,
  // ENOSPC, ...) is orphaned residue, not a record — admission must never treat it as a charge,
  // and it must age out through the ordinary TTL prune like any other temp, whether it is fresh
  // or old.
  const modalTextA1 = "You're making requests too quickly. [#215 gate r8 P2 fixture]";
  const pageTextA1 = `ChatGPT\nAccount limits\n${modalTextA1}\nPlease try again shortly.\n`;
  const primaryUrlA1 = 'https://chatgpt.com/c/mock-conversation';   // the mock's own primary tab
  // 90s: short enough for a 2-minute-old temp to be reaped by this scan's own one-shot prune
  // (production's default THROTTLE_SEEN_TTL is 7 days).
  const SHORT_TTL_R8 = { PRO_GATE_THROTTLE_SEEN_TTL: '90000' };

  // (A2) control: an orphan .expire. temp for this fingerprint, 2 minutes old — past this scan's
  // shortened 90s TTL. Admission never looks at temps at all (existence check only), so the
  // sighting charges normally, and that scan's own one-shot prune reaps the stale temp as an
  // ordinary TTL-expired orphan (#215 gate r7 P2 (h5) behaviour).
  const homeA2 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedThrottleSeen(homeA2, primaryUrlA1, modalTextA1);
  const recordPathA2 = throttleSeenRecordPath(homeA2, primaryUrlA1, modalTextA1);
  const tempPathA2 = `${recordPathA2}.expire.99999`;
  fs.renameSync(recordPathA2, tempPathA2);
  const agedAtA2 = new Date(Date.now() - 120_000);
  fs.utimesSync(tempPathA2, agedAtA2, agedAtA2);
  const cdpA2 = await mockCdp(pageTextA1, [], { throttleModal: modalTextA1 });
  const rA2 = await runSalvageInHome(homeA2, [MARKER, '3'], cdpA2.port, SHORT_TTL_R8);
  cdpA2.stop();
  check('#215 gate r8 P2 (A2) control: a temp aged past the grace and TTL charges the sighting normally (exit 5 + cooldown)',
    rA2.status === 5 && /^\d{4}-\d{2}-\d{2}T/.test(rA2.cooldown ?? ''),
    `status=${rA2.status} cooldown=${rA2.cooldown} stderr=${rA2.stderr?.slice(-400)}`);
  check("#215 gate r8 P2 (A2) control: the aged temp is reaped by that scan's own prune",
    !fs.existsSync(tempPathA2), `exists=${fs.existsSync(tempPathA2)}`);
  fs.rmSync(homeA2, { recursive: true, force: true });
}

{ // #215 gate r9 P1 (bin/cdp-salvage.mjs main scan loop, owned-incomplete canonical revalidation):
  // tripThrottleEvidence only RETURNS past a throttle sighting by falling through — never by
  // exiting the process — when that sighting was UNOWNED and ALREADY CHARGED (a repeat of a
  // fingerprint this or an earlier invocation already recorded). Before this fix, execution
  // reaching that point never remembered the canonical URL it had just proven readable: the very
  // next scan (this run's own retry, or the engine's next --harvest poll) had no tab AND no memo,
  // so recovery had to rely on the tab still being open rather than the URL this scan had just
  // demonstrated was readable. The fix routes that case through the same
  // rememberInconclusiveReadableSource the plain 'inconclusive' branch already uses.
  const ownedIncompleteTextP1 = `ChatGPT\nrun marker: ${MARKER}\nStill reasoning, no verdict yet...\n`;
  // Full THROTTLE_RE-matching interstitial (isThrottlePage), reused verbatim from the #208 gate
  // r1 P1 (classifier/scratch) fixture above: no modal option needed for the positive case, so
  // hashText === the raw text (classifyEvidence's interstitial branch: `throttleModal ?? text`).
  const staleThrottleTextP1 = "You're making requests too quickly. Temporarily limited access to your conversations.";
  const canonicalUrlP1 = 'https://chatgpt.com/c/mock-conversation';   // the mock's own primary tab

  // Run 1: no prior memo. The primary tab is owned-incomplete (our marker, no VERDICT), so the
  // scan spends its one canonical revalidation on tab.url itself — and this fingerprint is
  // pre-seeded as already charged, so tripThrottleUnowned ignores it without exiting.
  const homeP1 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedThrottleSeen(homeP1, canonicalUrlP1, staleThrottleTextP1);
  const cdpP1a = await mockCdp(ownedIncompleteTextP1, [], { renderText: () => staleThrottleTextP1 });
  const rP1a = await runSalvageInHome(homeP1, ['--probe', MARKER, '3'], cdpP1a.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpP1a.stop();
  check('#215 gate r9 P1 run 1: an already-charged non-foreign canonical throttle does not stop the probe from reporting generating',
    rP1a.status === 0 && /^probe-state: generating$/m.test(rP1a.stderr ?? ''),
    `status=${rP1a.status} stderr=${rP1a.stderr?.slice(-400)}`);
  const memoPathP1 = path.join(homeP1, 'conversation-urls', MARKER);
  check('#215 gate r9 P1 run 1: the canonical URL is remembered despite the throttle sighting being ignored, not newly charged',
    fs.existsSync(memoPathP1) && fs.readFileSync(memoPathP1, 'utf8').trim() === canonicalUrlP1,
    `memo=${fs.existsSync(memoPathP1) ? fs.readFileSync(memoPathP1, 'utf8').trim() : null}`);

  // Run 2: the SAME home, the tab now gone (mock lists no tab at all). Recovery must use the
  // remembered URL from run 1, not confirmed absence.
  const terminalReviewP1 = [
    `run marker: ${MARKER}`,
    '[P1] src/known.mjs:1 — recovered via the remembered URL',
    'P2: none',
    `VERDICT: FIX-FIRST — recovered, not absent. (run marker: ${MARKER})`,
  ].join('\n');
  const cdpP1b = await mockCdp('__NO_TABS__', [], { renderText: () => terminalReviewP1 });
  const rP1b = await runSalvageInHome(homeP1, [MARKER, '3'], cdpP1b.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpP1b.stop();
  check('#215 gate r9 P1 run 2: the tab is gone but the remembered URL recovers the finished review',
    rP1b.status === 0 && /VERDICT: FIX-FIRST — recovered, not absent\./.test(rP1b.stdout),
    `status=${rP1b.status} stdout=${rP1b.stdout?.slice(0, 300)} stderr=${rP1b.stderr?.slice(-300)}`);
  fs.rmSync(homeP1, { recursive: true, force: true });

  // Planted negative: the identical scenario, but the canonical scratch throttle is POSITIVELY
  // foreign (another run's exact marker under the modal). That case keeps today's behaviour — no
  // memo is ever written from a foreign surface, charged or not.
  const foreignMarkerP1 = 'pg-run-other-9999999999-9';
  const foreignPageTextP1 = `ChatGPT\nrun marker: ${foreignMarkerP1}\n${staleThrottleTextP1}\nPlease try again shortly.\n`;
  const homeP1c = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedThrottleSeen(homeP1c, canonicalUrlP1, staleThrottleTextP1);
  const cdpP1c = await mockCdp(ownedIncompleteTextP1, [], {
    renderText: () => foreignPageTextP1,
    throttleModal: (id) => (id.startsWith('scratch') ? staleThrottleTextP1 : null),
  });
  const rP1c = await runSalvageInHome(homeP1c, ['--probe', MARKER, '3'], cdpP1c.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpP1c.stop();
  check('#215 gate r9 P1 planted negative: a POSITIVELY foreign canonical throttle writes no memo',
    !fs.existsSync(path.join(homeP1c, 'conversation-urls', MARKER)),
    `status=${rP1c.status} stderr=${rP1c.stderr?.slice(-400)}`);
  fs.rmSync(homeP1c, { recursive: true, force: true });
}

{ // #215 gate r9 P2 (bin/cdp-salvage.mjs claimThrottleSeen / withThrottleSeenLock): admission
  // (the existence check) and creation (the 'wx' record write) must run as ONE unit per
  // fingerprint, or a concurrent prune's rename-verify-restore for that SAME fingerprint can
  // interleave between them — the round-9 finding named in claimThrottleSeen's own comment. A
  // per-fingerprint mkdirSync lock closes the window; it must reclaim a genuinely orphaned lock
  // (a holder that died mid-section), wait out a live one only up to its budget and then fail
  // open (every sidecar path in this file is fail-open), and never be mistaken for a record or a
  // temp by the prune that reaps everything else in this directory.
  //
  // (iii)/(iv)/baseline drive claimThrottleSeen/pruneThrottleSeen directly via the same
  // vm-evaluated-slice technique '#215 gate r7 P2' established (see its comment above for why: a
  // CLI script with no exports, sliced BY NAME — a missing slice surfaces as a null function and
  // a failing check, never a quietly different implementation). (i)/(ii) need a real spawned
  // process and a stderr assertion, which the vm harness cannot make observable (console.error
  // inside runInNewContext prints nothing the host process can see) — those go through real
  // salvage children instead, exactly like the r7 (c2) end-to-end pair.
  const salvageLinesR9 = fs.readFileSync(SALVAGE, 'utf8').split('\n');
  const sliceTopLevelR9 = (name) => {
    const start = salvageLinesR9.findIndex((line) => (
      line.startsWith(`function ${name}(`) || line.startsWith(`const ${name} = `)
    ));
    if (start < 0) return null;
    if (salvageLinesR9[start].startsWith('const ') || salvageLinesR9[start].trimEnd().endsWith('}')) {
      return salvageLinesR9[start];
    }
    const end = salvageLinesR9.findIndex((line, i) => i > start && line === '}');
    return end < 0 ? null : salvageLinesR9.slice(start, end + 1).join('\n');
  };
  const CLAIM_PARTS_R9 = ['THROTTLE_SEEN_EXPIRE_MARK', 'throttleSeenIsTemp', 'throttleSeenIsLock',
    'THROTTLE_SEEN_LOCK_STALE_MS', 'THROTTLE_SEEN_LOCK_WAIT_MS',
    'throttleSeenLockOwnerPath', 'throttleSeenLockOwnerAlive', 'withThrottleSeenLock',
    'removeThrottleSeenGeneration', 'pruneThrottleSeen', 'throttleSeenKey', 'throttleSeenRecordPath',
    'throttleAlreadyCharged', 'recordThrottleSeen', 'claimThrottleSeen'];
  const buildClaimR9 = (dir, { ttlMs = 7 * 24 * 60 * 60 * 1000, max = 512, fsImpl = fs } = {}) => {
    const source = CLAIM_PARTS_R9.map(sliceTopLevelR9).filter((part) => part !== null).join('\n');
    const expose = '({ claim: typeof claimThrottleSeen === "function" ? claimThrottleSeen : null,'
      + ' prune: typeof pruneThrottleSeen === "function" ? pruneThrottleSeen : null,'
      + ' withLock: typeof withThrottleSeenLock === "function" ? withThrottleSeenLock : null })';
    return runInNewContext(`${source}\n${expose}`, {
      fs: fsImpl, path, process, createHash,
      THROTTLE_SEEN_DIR: dir, THROTTLE_SEEN_TTL_MS: ttlMs, THROTTLE_SEEN_MAX: max,
      pendingThrottleSeenRecords: [], throttleSeenPruned: false,
    });
  };
  const seenDirR9 = () => fs.mkdtempSync(path.join(os.tmpdir(), 'pg-r9-seen-'));
  const keyR9 = (label) => createHash('sha256').update(`#215 gate r9 ${label}`).digest('hex');
  const hashR9 = (label) => createHash('sha256').update(`#215 gate r9 text ${label}`).digest('hex');
  const recordPathR9 = (dir, url, hash) => path.join(dir, createHash('sha256').update(`${url}\n${hash}`).digest('hex'));
  const EIGHT_DAYS_R9 = 8 * 24 * 60 * 60 * 1000;

  // baseline planted negative: with no contention, the first claim on a fingerprint charges it,
  // the second (identical url/hash) sees the record it just created and returns 'already'.
  const dirBaseR9 = seenDirR9();
  const urlBaseR9 = 'https://chatgpt.com/c/mock-r9-base';
  const hashBaseR9 = hashR9('baseline');
  const harnessBaseR9 = buildClaimR9(dirBaseR9);
  const firstBaseR9 = harnessBaseR9.claim?.(urlBaseR9, hashBaseR9, new Set());
  const secondBaseR9 = harnessBaseR9.claim?.(urlBaseR9, hashBaseR9, new Set());
  check('#215 gate r9 P2 baseline: with no contention claimThrottleSeen charges once then reports already',
    firstBaseR9 === 'charged' && secondBaseR9 === 'already',
    `first=${firstBaseR9} second=${secondBaseR9}`);
  fs.rmSync(dirBaseR9, { recursive: true, force: true });

  // (iii) a stale lock dir (mtime 10s old, past the 5s THROTTLE_SEEN_LOCK_STALE_MS) is a holder
  // that died mid-section, not live contention: it is reclaimed and the claim proceeds.
  const dirIiiR9 = seenDirR9();
  const urlIiiR9 = 'https://chatgpt.com/c/mock-r9-iii';
  const hashIiiR9 = hashR9('iii');
  const recordIiiR9 = recordPathR9(dirIiiR9, urlIiiR9, hashIiiR9);
  const lockIiiR9 = `${recordIiiR9}.lock`;
  fs.mkdirSync(lockIiiR9);
  const staleAtR9 = new Date(Date.now() - 10_000);
  fs.utimesSync(lockIiiR9, staleAtR9, staleAtR9);
  const resultIiiR9 = buildClaimR9(dirIiiR9).claim?.(urlIiiR9, hashIiiR9, new Set());
  check('#215 gate r9 P2 (iii) a stale lock dir is reclaimed and the claim proceeds',
    resultIiiR9 === 'charged', `result=${resultIiiR9}`);
  check('#215 gate r9 P2 (iii) the record now exists and the stale lock is gone',
    fs.existsSync(recordIiiR9) && !fs.existsSync(lockIiiR9),
    `dir=${JSON.stringify(fs.readdirSync(dirIiiR9))}`);
  fs.rmSync(dirIiiR9, { recursive: true, force: true });

  // (iii-b) two reclaimers judging the same dead lock: the reclaim must be atomic (rename aside,
  // then remove), so the one whose rename LOSES removes nothing and never re-creates the lock —
  // it falls through to the wait loop against the winner's fresh lock and, when that stays held
  // past the wait budget here, fails open. Simulated by an fs whose renameSync of a lock path
  // throws ENOENT (the winner already moved it). Pre-fix the loser rmSync'd the path in place,
  // which is exactly how it could delete a lock the winner had just re-created.
  const dirIiibR9 = seenDirR9();
  const urlIiibR9 = 'https://chatgpt.com/c/mock-r9-iii-b';
  const hashIiibR9 = hashR9('iii-b');
  const recordIiibR9 = recordPathR9(dirIiibR9, urlIiibR9, hashIiibR9);
  const lockIiibR9 = `${recordIiibR9}.lock`;
  fs.mkdirSync(lockIiibR9);
  fs.utimesSync(lockIiibR9, staleAtR9, staleAtR9);
  let loserRenamesR9 = 0;
  const fsLoserR9 = {
    ...fs,
    renameSync: (from, to) => {
      if (String(from).endsWith('.lock')) {
        loserRenamesR9 += 1;
        const err = new Error('ENOENT: simulated — another reclaimer renamed the dead lock aside first');
        err.code = 'ENOENT';
        throw err;
      }
      return fs.renameSync(from, to);
    },
  };
  const resultIiibR9 = buildClaimR9(dirIiibR9, { fsImpl: fsLoserR9 }).claim?.(urlIiibR9, hashIiibR9, new Set());
  const afterIiibR9 = fs.readdirSync(dirIiibR9);
  check('#215 gate r9 P2 (iii-b) a reclaimer that loses the rename removes nothing: the lock it judged dead is still on disk',
    loserRenamesR9 >= 1 && afterIiibR9.includes(path.basename(lockIiibR9)) && !afterIiibR9.some((n) => n.includes('.dead.')),
    `renames=${loserRenamesR9} result=${resultIiibR9} dir=${JSON.stringify(afterIiibR9)}`);
  check('#215 gate r9 P2 (iii-b) the losing reclaimer still charges exactly once through the fail-open path',
    resultIiibR9 === 'charged' && fs.existsSync(recordIiibR9),
    `result=${resultIiibR9} record=${fs.existsSync(recordIiibR9)}`);
  fs.rmSync(dirIiibR9, { recursive: true, force: true });

  // (iv) lock dirs are never counted as records or temps, and an aged one is reaped by the prune
  // — cleanly (rmdirSync), never by the record/temp rename-aside path, which corrupts a directory
  // it cannot unlink (EISDIR) instead of removing it: pre-fix that leaves a `<name>.expire.<pid>`
  // orphan on disk under the ORIGINAL lock's name prefix, not a clean removal.
  const dirIvR9 = seenDirR9();
  const nameLiveIvR9 = keyR9('iv live');
  fs.writeFileSync(path.join(dirIvR9, nameLiveIvR9), '', { flag: 'wx' });
  const liveAtR9 = new Date(Date.now() - 60_000);
  fs.utimesSync(path.join(dirIvR9, nameLiveIvR9), liveAtR9, liveAtR9);
  const nameFreshLockIvR9 = `${keyR9('iv fresh-lock')}.lock`;
  fs.mkdirSync(path.join(dirIvR9, nameFreshLockIvR9));
  const nameAgedLockIvR9 = `${keyR9('iv aged-lock')}.lock`;
  const pathAgedLockIvR9 = path.join(dirIvR9, nameAgedLockIvR9);
  fs.mkdirSync(pathAgedLockIvR9);
  const agedAtR9 = new Date(Date.now() - EIGHT_DAYS_R9);
  fs.utimesSync(pathAgedLockIvR9, agedAtR9, agedAtR9);
  buildClaimR9(dirIvR9).prune?.(new Set());
  const afterIvR9 = fs.readdirSync(dirIvR9);
  check('#215 gate r9 P2 (iv) the aged lock is cleanly reaped, not renamed aside into a corrupted orphan',
    !afterIvR9.some((n) => n === nameAgedLockIvR9 || n.startsWith(`${nameAgedLockIvR9}.`)),
    `dir=${JSON.stringify(afterIvR9)}`);
  check('#215 gate r9 P2 (iv) a fresh (unexpired) lock and the real record both survive the same prune',
    afterIvR9.includes(nameFreshLockIvR9) && afterIvR9.includes(nameLiveIvR9),
    `dir=${JSON.stringify(afterIvR9)}`);
  fs.rmSync(dirIvR9, { recursive: true, force: true });

  // --- end-to-end through real salvage children: (i) and (ii) need a stderr assertion, which the
  // vm harness cannot make observable ---------------------------------------------------------
  const modalTriggerR9i = "You're making requests too quickly. [#215 gate r9 (i) trigger]";
  const pageR9i = `ChatGPT\nAccount limits\n${modalTriggerR9i}\nPlease try again shortly.\n`;
  const primaryUrlR9 = 'https://chatgpt.com/c/mock-conversation';   // the mock's own primary tab

  // (i) the round-9 interleaving itself: another holder ACQUIRES the fingerprint's lock first and
  // only creates the record (then releases) after a delay — mid-critical-section, exactly like a
  // concurrent claimThrottleSeen call between its own existence check and its 'wx' create. The
  // record must NOT exist yet the instant the lock is taken: that is what makes this fixture
  // discriminating. Without the lock (pre-fix), the child's existence check runs immediately,
  // finds nothing (the other holder hasn't written the record yet), and its own 'wx' create wins
  // the race and charges a SECOND, wrongful cooldown before the other holder ever gets there —
  // exactly the round-9 finding. With the lock, the contended claim must wait, then OBSERVE the
  // record the other holder committed — 'already' — never publish a second cooldown for the
  // identical sighting.
  const homeIR9 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const recordIR9 = throttleSeenRecordPath(homeIR9, primaryUrlR9, modalTriggerR9i);
  const lockIR9 = `${recordIR9}.lock`;
  let firedIR9 = false;
  const cdpIR9 = await mockCdp(pageR9i, [], {
    throttleModal: modalTriggerR9i,
    onEvaluate: (id, expression) => {
      if (firedIR9 || !expression.includes('pro-gate:review-text')) return;
      firedIR9 = true;
      fs.mkdirSync(throttleSeenDir(homeIR9), { recursive: true });
      fs.mkdirSync(lockIR9);   // "holder A" acquires the lock; the record does not exist yet
      setTimeout(() => {
        // the record is only created now, mid-critical-section, well within the 250ms wait
        // budget — a racing pre-fix caller that never waited would already be gone by this point
        try { fs.writeFileSync(recordIR9, '', { flag: 'wx' }); } catch {}   // may already lose the race pre-fix
        try { fs.rmdirSync(lockIR9); } catch {}   // release, mirroring withThrottleSeenLock's finally
      }, 60);
    },
  });
  const rIR9 = await runSalvageInHome(homeIR9, [MARKER, '3'], cdpIR9.port);
  cdpIR9.stop();
  check('#215 gate r9 P2 (i) a lock contended by another holder is waited out, not raced past (no second exit-5/cooldown)',
    rIR9.status !== 5 && rIR9.cooldown === null,
    `status=${rIR9.status} cooldown=${rIR9.cooldown} stderr=${rIR9.stderr?.slice(-400)}`);
  check('#215 gate r9 P2 (i) the child observes the already-committed record once the lock releases',
    /already charged/.test(rIR9.stderr || ''), `stderr=${rIR9.stderr?.slice(-400)}`);
  const recordsAfterIR9 = fs.readdirSync(throttleSeenDir(homeIR9)).filter((n) => !n.endsWith('.lock'));
  check("#215 gate r9 P2 (i) exactly one record exists afterward — the other holder's, charged exactly once",
    recordsAfterIR9.length === 1, `records=${JSON.stringify(recordsAfterIR9)}`);
  fs.rmSync(homeIR9, { recursive: true, force: true });

  // (ii) a lock held past the wait budget (the holder never releases within this test) fails
  // open with the documented stderr line and still charges the sighting exactly once.
  const modalTriggerR9ii = "You're making requests too quickly. [#215 gate r9 (ii) trigger]";
  const pageR9ii = `ChatGPT\nAccount limits\n${modalTriggerR9ii}\nPlease try again shortly.\n`;
  const homeIiR9 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const recordIiR9 = throttleSeenRecordPath(homeIiR9, primaryUrlR9, modalTriggerR9ii);
  const lockIiR9 = `${recordIiR9}.lock`;
  let firedIiR9 = false;
  const cdpIiR9 = await mockCdp(pageR9ii, [], {
    throttleModal: modalTriggerR9ii,
    onEvaluate: (id, expression) => {
      if (firedIiR9 || !expression.includes('pro-gate:review-text')) return;
      firedIiR9 = true;
      fs.mkdirSync(throttleSeenDir(homeIiR9), { recursive: true });
      fs.mkdirSync(lockIiR9);   // held for the rest of this test — never released
    },
  });
  const rIiR9 = await runSalvageInHome(homeIiR9, [MARKER, '3'], cdpIiR9.port);
  cdpIiR9.stop();
  const expectedFailOpenMsgR9 = new RegExp('throttle-seen lock contended past 250ms for [0-9a-f]{64}; '
    + 'proceeding without it \\(fail-open\\)');
  check('#215 gate r9 P2 (ii) a lock held past the wait budget fails open and still charges (exit 5 + cooldown)',
    rIiR9.status === 5 && /^\d{4}-\d{2}-\d{2}T/.test(rIiR9.cooldown ?? ''),
    `status=${rIiR9.status} cooldown=${rIiR9.cooldown} stderr=${rIiR9.stderr?.slice(-500)}`);
  check('#215 gate r9 P2 (ii) the fail-open line names the contended fingerprint',
    expectedFailOpenMsgR9.test(rIiR9.stderr || ''), `stderr=${rIiR9.stderr?.slice(-500)}`);
  const recordsAfterIiR9 = fs.readdirSync(throttleSeenDir(homeIiR9)).filter((n) => !n.endsWith('.lock'));
  check('#215 gate r9 P2 (ii) exactly one record exists afterward — charged exactly once, not twice',
    recordsAfterIiR9.length === 1, `records=${JSON.stringify(recordsAfterIiR9)}`);
  fs.rmSync(lockIiR9, { recursive: true, force: true });
  fs.rmSync(homeIiR9, { recursive: true, force: true });
}

{ // #215 gate r9 verify (independent-verifier P1, bin/cdp-salvage.mjs withThrottleSeenLock): the
  // paid-review round-9 P1 finding — reclaim is stat -> rmdirSync -> mkdirSync with no fencing
  // and no positive check that the current holder is actually dead, so a holder whose critical
  // section merely runs longer than THROTTLE_SEEN_LOCK_STALE_MS gets its lock silently stolen by
  // a contender, and both run the SAME fingerprint's protected section at once. This can only be
  // demonstrated with a genuinely separate OS process holding the lock (a single-threaded vm
  // evaluation cannot represent "still alive, still running" for a different pid) — two REAL node
  // children share one THROTTLE_SEEN_DIR: HOLDER acquires immediately and sleeps well past
  // STALE_MS (5s) inside its critical section; CONTENDER starts once the lock is already older
  // than STALE_MS but HOLDER has not released. Pre-fix, CONTENDER's mkdirSync-after-rmdirSync
  // succeeds on its very first attempt (no wait, no stderr line) and its own release then removes
  // the directory HOLDER still believes it owns — observable as the lock (and HOLDER's original
  // owner token) vanishing mid-HOLD and CONTENDER never printing the contended/fail-open line.
  // Post-fix, CONTENDER finds HOLDER's recorded pid alive, declines to reclaim, waits out its
  // budget, and fails open loudly instead — HOLDER's own lock directory and original owner token
  // must survive, untouched, for the entire time HOLDER holds it.
  const driverDirR9v = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-r9-verify-'));
  const salvageLinesR9v = fs.readFileSync(SALVAGE, 'utf8').split('\n');
  const sliceTopLevelR9v = (name) => {
    const start = salvageLinesR9v.findIndex((line) => (
      line.startsWith(`function ${name}(`) || line.startsWith(`const ${name} = `)
    ));
    if (start < 0) return null;
    if (salvageLinesR9v[start].startsWith('const ') || salvageLinesR9v[start].trimEnd().endsWith('}')) {
      return salvageLinesR9v[start];
    }
    const end = salvageLinesR9v.findIndex((line, i) => i > start && line === '}');
    return end < 0 ? null : salvageLinesR9v.slice(start, end + 1).join('\n');
  };
  const LOCK_PARTS_R9V = ['THROTTLE_SEEN_LOCK_STALE_MS', 'THROTTLE_SEEN_LOCK_WAIT_MS',
    'throttleSeenLockOwnerPath', 'throttleSeenLockOwnerAlive', 'withThrottleSeenLock'];
  const extractedLockSrcR9v = LOCK_PARTS_R9V.map(sliceTopLevelR9v).filter((p) => p !== null).join('\n\n');
  check('#215 gate r9 verify setup: every named lock part was found in bin/cdp-salvage.mjs (no silent no-op slice)',
    LOCK_PARTS_R9V.every((name) => sliceTopLevelR9v(name) !== null),
    `missing=${JSON.stringify(LOCK_PARTS_R9V.filter((name) => sliceTopLevelR9v(name) === null))}`);
  const driverPathR9v = path.join(driverDirR9v, 'lock-driver.mjs');
  const driverSrcR9v = [
    "import fs from 'node:fs';",
    "import path from 'node:path';",
    "import { execSync } from 'node:child_process';",
    'const THROTTLE_SEEN_DIR = process.env.R9V_LOCK_DIR;',
    extractedLockSrcR9v,
    'const NAME = process.env.R9V_FP_NAME;',
    "const HOLD_MS = Number(process.env.R9V_HOLD_MS || '0');",
    'const LOG = process.env.R9V_ACTIVITY_LOG;',
    'function logLine(s) { fs.appendFileSync(LOG, `${s}\\n`); }',
    'withThrottleSeenLock(NAME, () => {',
    '  logLine(`ENTER ${process.pid} ${Date.now()}`);',
    '  if (HOLD_MS > 0) execSync(`sleep ${(HOLD_MS / 1000).toFixed(3)}`);',
    '  logLine(`EXIT ${process.pid} ${Date.now()}`);',
    '});',
  ].join('\n');
  fs.writeFileSync(driverPathR9v, driverSrcR9v);
  const lockDirR9v = path.join(driverDirR9v, 'seen');
  const activityLogR9v = path.join(driverDirR9v, 'activity.log');
  fs.writeFileSync(activityLogR9v, '');
  const fpNameR9v = createHash('sha256').update('#215 gate r9 verify fingerprint').digest('hex');
  const spawnDriverR9v = (holdMs) => new Promise((resolve) => {
    const child = spawn(process.execPath, [driverPathR9v], {
      env: {
        ...process.env,
        R9V_LOCK_DIR: lockDirR9v,
        R9V_FP_NAME: fpNameR9v,
        R9V_HOLD_MS: String(holdMs),
        R9V_ACTIVITY_LOG: activityLogR9v,
      },
    });
    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', () => resolve({ stderr }));
  });
  const sleepR9v = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });
  const waitForFileR9v = async (filePath, timeoutMs) => {
    const deadline = Date.now() + timeoutMs;
    while (!fs.existsSync(filePath) && Date.now() < deadline) { await sleepR9v(20); }
    return fs.existsSync(filePath);
  };

  const HOLD_MS_R9V = 7_000;   // comfortably past THROTTLE_SEEN_LOCK_STALE_MS (5s)
  const holderPromiseR9v = spawnDriverR9v(HOLD_MS_R9V);
  const lockPathR9v = `${path.join(lockDirR9v, fpNameR9v)}.lock`;
  const ownerPathR9v = path.join(lockPathR9v, 'owner');
  // Poll (not a fixed sleep) for HOLDER to actually acquire and write its owner token — robust
  // to slow process/ESM startup on a loaded machine.
  const holderReadyR9v = await waitForFileR9v(ownerPathR9v, 3_000);
  check('#215 gate r9 verify setup: HOLDER acquired the lock and wrote its owner token',
    holderReadyR9v, `ready=${holderReadyR9v}`);
  // Guarded: a broken/missing lock implementation (e.g. the pre-fix tree, where none of
  // LOCK_PARTS_R9V resolve and HOLDER's driver throws before ever writing this file) must FAIL
  // this and every later check cleanly, not crash the whole suite on an unguarded read.
  const holderTokenR9v = holderReadyR9v ? fs.readFileSync(ownerPathR9v, 'utf8') : null;
  // CONTENDER starts once the lock is already older than THROTTLE_SEEN_LOCK_STALE_MS (5s) but
  // well before HOLDER's own hold ends, leaving margin on both sides.
  await sleepR9v(5_300);
  const contenderResultR9v = await spawnDriverR9v(0);
  // Read HOLDER's lock state BEFORE HOLDER itself releases: a stolen-and-already-released lock
  // would be gone or hold a DIFFERENT token by now.
  const survivedR9v = fs.existsSync(ownerPathR9v);
  const survivingTokenR9v = survivedR9v ? fs.readFileSync(ownerPathR9v, 'utf8') : null;
  await holderPromiseR9v;   // let HOLDER finish and release cleanly before the next test/cleanup

  check("#215 gate r9 verify: HOLDER's lock directory is not destroyed while HOLDER still holds it",
    survivedR9v, `exists=${survivedR9v}`);
  check("#215 gate r9 verify: HOLDER's original owner token is unchanged — CONTENDER never reclaimed it",
    holderReadyR9v && survivingTokenR9v !== null && survivingTokenR9v === holderTokenR9v,
    `holder=${holderTokenR9v} surviving=${survivingTokenR9v}`);
  check('#215 gate r9 verify: CONTENDER printed the contended/fail-open line instead of silently reclaiming',
    new RegExp(`throttle-seen lock contended past 250ms for ${fpNameR9v}; proceeding without it \\(fail-open\\)`)
      .test(contenderResultR9v.stderr),
    `stderr=${contenderResultR9v.stderr}`);
  const activityR9v = fs.readFileSync(activityLogR9v, 'utf8').trim().split('\n').filter(Boolean);
  check('#215 gate r9 verify: activity log recorded both ENTER/EXIT pairs (both drivers actually ran)',
    activityR9v.length === 4, `log=${JSON.stringify(activityR9v)}`);

  // Planted negative: with no contention at all, a fresh lock acquires cleanly, writes an owner
  // token, and releases cleanly on its own — the ownership fencing must not turn the ordinary
  // uncontended path into a false failure.
  const uncontendedResultR9v = await spawnDriverR9v(0);
  check('#215 gate r9 verify planted negative: an uncontended acquire prints no contention line',
    !/contended/.test(uncontendedResultR9v.stderr), `stderr=${uncontendedResultR9v.stderr}`);
  check('#215 gate r9 verify planted negative: the lock directory is cleaned up after an uncontended release',
    !fs.existsSync(lockPathR9v), `exists=${fs.existsSync(lockPathR9v)}`);

  fs.rmSync(driverDirR9v, { recursive: true, force: true });
}

process.exit(failures === 0 ? 0 : 1);
