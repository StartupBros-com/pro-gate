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
      // #215 skeptic r2 D1: set to a message when this ONE evaluate must answer with a CDP error
      // frame instead of a value, so a fixture can reproduce a failed read without a 5s bail.
      let evaluateError = null;
      let armMutation = null;
      let applyMutation = null;
      if (expression.includes('pro-gate:review-text') && opts.document) {
        value = runInNewContext(expression, { document: opts.document });
      } else if (expression.includes('pro-gate:terminal-infrastructure')) {
        value = opts.infrastructureError ?? null;
      } else if (expression.includes('pro-gate:throttle-modal')) {
        // #215 skeptic r2 D1: a dialog read can FAIL as well as come back empty — an evaluate
        // timeout, a websocket error, a detached target, a dialog momentarily not laid out.
        // Production cannot tell those apart from "no dialog" unless the failure is carried out of
        // tabThrottleModal, so a fixture must be able to produce one SELECTIVELY (per tab, per
        // invocation). opts.throttleModalFails (true, or (id, url) => boolean) makes this one
        // evaluate answer with a CDP error frame — exactly the shape evaluateTab turns into
        // { ok: false, reason: 'evaluate-failed' } — so the fixture stays deterministic and never
        // waits out the 5s bail.
        const modalReadFails = typeof opts.throttleModalFails === 'function'
          ? opts.throttleModalFails(id, scratch?.url ?? extra?.url ?? 'https://chatgpt.com/c/mock-conversation') === true
          : opts.throttleModalFails === true;
        if (modalReadFails) evaluateError = 'mock: throttle-modal evaluate failed';
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
        socket.write(wsTextFrame(JSON.stringify(evaluateError
          ? { id: request.id, error: { message: evaluateError } }
          : { id: request.id, result: { result: { value } } })));
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

{ // #215 gate r2 P2 (bin/cdp-salvage.mjs:531 throttleAlreadyCharged): a NEW throttle episode on a
  // recovered tab was suppressed as an old stale modal. Once an unowned (url, modal) pair was
  // charged, nothing ever invalidated its fingerprint — a later scan could observe that same
  // conversation fully rendered with no throttle at all, and if throttling returned with the same
  // modal text at that URL the existence check swallowed it. The sequence
  // throttled -> healthy -> throttled therefore wrote only the FIRST cooldown, and TTL could not
  // bound it (pruneThrottleSeen protects the fingerprint the current scan is observing, however
  // old its record). With another run's marker beneath the modal and no owned conversation found,
  // the returning episode then fell through to the confirmed-absent exit 4 while the account was
  // actively limited — the engine left without a fresh cooldown. Fixed by retiring a URL's
  // fingerprints as soon as a scan positively observes that URL healthy; uninterrupted stale
  // sightings still deduplicate, and a URL that is healthy AND throttled in the same scan is not
  // healthy at all.
  const r2Url = 'https://chatgpt.com/c/mock-215-r2-returning-modal';
  const r2Modal = "You're making requests too quickly. [#215 gate r2 P2 fixture]";
  const r2Foreign = 'pg-run-another-run-215r2';
  const r2ThrottledText = `ChatGPT\n${r2Foreign}\n${r2Modal}\nAnother run's conversation beneath the modal.\n`;
  const r2HealthyText = `ChatGPT\n${r2Foreign}\nAnother run's conversation, fully rendered, no limiter in sight.\n`;
  // An old-format record: every build before this fix wrote an EMPTY record file, so its URL can
  // never be recovered from it. It must be attributable to no URL at all — retired only by TTL.
  const r2LegacyModal = "You're making requests too quickly. [#215 gate r2 P2 old-format record]";
  const oldMtime215r2 = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };

  const home215r2 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedThrottleSeen(home215r2, r2Url, r2LegacyModal);   // written empty, exactly as old builds wrote it

  // (a1) First sighting of this modal on an unowned tab carrying ANOTHER run's marker: charged.
  const cdp215r2a = await mockCdp('__NO_TABS__', [{ id: 'r2tab', url: r2Url }], {
    tabText: () => r2ThrottledText,
    throttleModal: () => r2Modal,
  });
  const r215r2a = await runSalvageInHome(home215r2, [MARKER, '3'], cdp215r2a.port);
  cdp215r2a.stop();
  check('#215 gate r2 P2 (a1) the first sighting of an unowned modal takes the throttle exit (5)',
    r215r2a.status === 5, `status=${r215r2a.status} stderr=${r215r2a.stderr?.slice(-400)}`);
  check('#215 gate r2 P2 (a1) the first sighting records its (url, modal) fingerprint',
    throttleSeenHas(home215r2, r2Url, r2Modal),
    `dir=${fs.existsSync(throttleSeenDir(home215r2)) ? fs.readdirSync(throttleSeenDir(home215r2)) : null}`);

  // (a2) The SAME tab at the SAME URL, now fully rendered with no throttle surface anywhere: the
  // episode this scan observes is over, so its fingerprint must not go on suppressing the next one.
  const cooldownPath215r2 = path.join(home215r2, 'throttle.cooldown');
  oldMtime215r2(cooldownPath215r2);
  const mtimeBefore215r2b = fs.statSync(cooldownPath215r2).mtimeMs;
  const cdp215r2b = await mockCdp('__NO_TABS__', [{ id: 'r2tab', url: r2Url }], {
    tabText: () => r2HealthyText,
  });
  const r215r2b = await runSalvageInHome(home215r2, [MARKER, '3'], cdp215r2b.port);
  cdp215r2b.stop();
  const mtimeAfter215r2b = fs.statSync(cooldownPath215r2).mtimeMs;
  check('#215 gate r2 P2 (a2) a healthy observation of that URL takes no throttle exit',
    r215r2b.status !== 5, `status=${r215r2b.status} stderr=${r215r2b.stderr?.slice(-400)}`);
  check('#215 gate r2 P2 (a2) a healthy observation of that URL does not write a cooldown of its own',
    mtimeAfter215r2b === mtimeBefore215r2b, `before=${mtimeBefore215r2b} after=${mtimeAfter215r2b}`);
  check("#215 gate r2 P2 (a2) a healthy observation retires that URL's charged fingerprint",
    !throttleSeenHas(home215r2, r2Url, r2Modal),
    `dir=${fs.existsSync(throttleSeenDir(home215r2)) ? fs.readdirSync(throttleSeenDir(home215r2)) : null}`);
  check('#215 gate r2 P2 (d) an old-format EMPTY record for the same URL is never retired by a healthy observation',
    throttleSeenHas(home215r2, r2Url, r2LegacyModal),
    `dir=${fs.existsSync(throttleSeenDir(home215r2)) ? fs.readdirSync(throttleSeenDir(home215r2)) : null}`);

  // (a3) The same modal text returns at the same URL after that healthy observation. This is a
  // NEW episode of the limiter, not a stale repeat of the first: it must charge its own cooldown
  // and take the throttle exit, never the confirmed-absent exit 4 the finding describes.
  oldMtime215r2(cooldownPath215r2);
  const cooldownBefore215r2c = fs.readFileSync(cooldownPath215r2, 'utf8');
  const mtimeBefore215r2c = fs.statSync(cooldownPath215r2).mtimeMs;
  const cdp215r2c = await mockCdp('__NO_TABS__', [{ id: 'r2tab', url: r2Url }], {
    tabText: () => r2ThrottledText,
    throttleModal: () => r2Modal,
  });
  const r215r2c = await runSalvageInHome(home215r2, [MARKER, '3'], cdp215r2c.port);
  cdp215r2c.stop();
  const mtimeAfter215r2c = fs.statSync(cooldownPath215r2).mtimeMs;
  check('#215 gate r2 P2 (a3) a modal returning after a healthy observation takes the throttle exit (5), not confirmed-absent (4)',
    r215r2c.status === 5, `status=${r215r2c.status} stderr=${r215r2c.stderr?.slice(-400)}`);
  check('#215 gate r2 P2 (a3) the returning episode writes a NEW cooldown',
    mtimeAfter215r2c > mtimeBefore215r2c && r215r2c.cooldown !== cooldownBefore215r2c,
    `before=${mtimeBefore215r2c}/${cooldownBefore215r2c?.trim()} after=${mtimeAfter215r2c}/${r215r2c.cooldown?.trim()}`);
  fs.rmSync(home215r2, { recursive: true, force: true });

  // (b) Control — deduplication of UNINTERRUPTED stale sightings is unchanged: with no healthy
  // observation in between, the second scan of the same unchanged modal is still suppressed and
  // its record still stands. This is the behaviour the retire pass must not weaken.
  const homeCtl215r2 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpCtl215r2a = await mockCdp('__NO_TABS__', [{ id: 'r2tab', url: r2Url }], {
    tabText: () => r2ThrottledText,
    throttleModal: () => r2Modal,
  });
  const rCtl215r2a = await runSalvageInHome(homeCtl215r2, [MARKER, '3'], cdpCtl215r2a.port);
  cdpCtl215r2a.stop();
  check('#215 gate r2 P2 (b) control: the first of two uninterrupted stale sightings takes the throttle exit (5)',
    rCtl215r2a.status === 5, `status=${rCtl215r2a.status} stderr=${rCtl215r2a.stderr?.slice(-400)}`);
  const cooldownPathCtl215r2 = path.join(homeCtl215r2, 'throttle.cooldown');
  oldMtime215r2(cooldownPathCtl215r2);
  const mtimeBeforeCtl215r2 = fs.statSync(cooldownPathCtl215r2).mtimeMs;
  const cdpCtl215r2b = await mockCdp('__NO_TABS__', [{ id: 'r2tab', url: r2Url }], {
    tabText: () => r2ThrottledText,
    throttleModal: () => r2Modal,
  });
  const rCtl215r2b = await runSalvageInHome(homeCtl215r2, [MARKER, '3'], cdpCtl215r2b.port);
  cdpCtl215r2b.stop();
  const mtimeAfterCtl215r2 = fs.statSync(cooldownPathCtl215r2).mtimeMs;
  check('#215 gate r2 P2 (b) control: an uninterrupted repeat of the same modal is still suppressed (no throttle exit)',
    rCtl215r2b.status !== 5, `status=${rCtl215r2b.status}`);
  check('#215 gate r2 P2 (b) control: an uninterrupted repeat still does not rewrite the cooldown',
    mtimeAfterCtl215r2 === mtimeBeforeCtl215r2, `before=${mtimeBeforeCtl215r2} after=${mtimeAfterCtl215r2}`);
  check('#215 gate r2 P2 (b) control: the suppressed repeat leaves its fingerprint record in place',
    throttleSeenHas(homeCtl215r2, r2Url, r2Modal),
    `dir=${fs.existsSync(throttleSeenDir(homeCtl215r2)) ? fs.readdirSync(throttleSeenDir(homeCtl215r2)) : null}`);
  fs.rmSync(homeCtl215r2, { recursive: true, force: true });

  // (c) Same-scan exclusion: one healthy tab and one throttled tab at the SAME URL in ONE scan.
  // A conversation that is throttled right now is not healthy, whatever a sibling tab renders, so
  // the record this very scan is checking must survive — retiring it here would re-admit the
  // sighting the dedupe just suppressed and charge a second cooldown for one unchanged episode.
  const homeSame215r2 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpSame215r2a = await mockCdp('__NO_TABS__', [{ id: 'r2tab', url: r2Url }], {
    tabText: () => r2ThrottledText,
    throttleModal: () => r2Modal,
  });
  const rSame215r2a = await runSalvageInHome(homeSame215r2, [MARKER, '3'], cdpSame215r2a.port);
  cdpSame215r2a.stop();
  check('#215 gate r2 P2 (c) same-scan: the sighting is charged once before the mixed scan',
    rSame215r2a.status === 5 && throttleSeenHas(homeSame215r2, r2Url, r2Modal),
    `status=${rSame215r2a.status}`);
  const cooldownPathSame215r2 = path.join(homeSame215r2, 'throttle.cooldown');
  oldMtime215r2(cooldownPathSame215r2);
  const mtimeBeforeSame215r2 = fs.statSync(cooldownPathSame215r2).mtimeMs;
  const cdpSame215r2b = await mockCdp('__NO_TABS__', [
    { id: 'r2same-healthy', url: r2Url },
    { id: 'r2same-modal', url: r2Url },
  ], {
    tabText: (url, id) => (id === 'r2same-modal' ? r2ThrottledText : r2HealthyText),
    throttleModal: (id) => (id === 'r2same-modal' ? r2Modal : null),
  });
  const rSame215r2b = await runSalvageInHome(homeSame215r2, [MARKER, '3'], cdpSame215r2b.port);
  cdpSame215r2b.stop();
  const mtimeAfterSame215r2 = fs.statSync(cooldownPathSame215r2).mtimeMs;
  check('#215 gate r2 P2 (c) same-scan: a URL healthy on one tab and throttled on another in the SAME scan takes no throttle exit',
    rSame215r2b.status !== 5, `status=${rSame215r2b.status} stderr=${rSame215r2b.stderr?.slice(-400)}`);
  check('#215 gate r2 P2 (c) same-scan: that scan does not rewrite the cooldown',
    mtimeAfterSame215r2 === mtimeBeforeSame215r2, `before=${mtimeBeforeSame215r2} after=${mtimeAfterSame215r2}`);
  check('#215 gate r2 P2 (c) same-scan: the fingerprint that scan is still observing is NOT retired',
    throttleSeenHas(homeSame215r2, r2Url, r2Modal),
    `dir=${fs.existsSync(throttleSeenDir(homeSame215r2)) ? fs.readdirSync(throttleSeenDir(homeSame215r2)) : null}`);
  fs.rmSync(homeSame215r2, { recursive: true, force: true });

  // Organizer variant of (a): the organizer builds the same listed-tab reads/throttleHits pair and
  // shares the same dedupe store, so the same three-state sequence must reach the same answer —
  // pre-fix its returning episode reported no throttle at all and left the cooldown untouched.
  const orgTitle215r2 = 'pro-gate review: PR #215 gate r2 P2 [pro-gate]';
  const homeOrg215r2 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, orgTitle215r2)(homeOrg215r2);   // no memo url -> no scratch recovery path
  const cdpOrg215r2a = await mockCdp('__NO_TABS__', [{ id: 'r2tab', url: r2Url }], {
    tabText: () => r2ThrottledText,
    throttleModal: () => r2Modal,
  });
  const rOrg215r2a = await runSalvageInHome(homeOrg215r2, ['--organize', MARKER, '5'], cdpOrg215r2a.port);
  cdpOrg215r2a.stop();
  check('#215 gate r2 P2 (organizer a1) the first sighting reports reason=throttle and records its fingerprint',
    /reason=throttle/.test(rOrg215r2a.stdout) && throttleSeenHas(homeOrg215r2, r2Url, r2Modal),
    `stdout=${rOrg215r2a.stdout} stderr=${rOrg215r2a.stderr?.slice(-300)}`);
  const cooldownPathOrg215r2 = path.join(homeOrg215r2, 'throttle.cooldown');
  oldMtime215r2(cooldownPathOrg215r2);
  const mtimeBeforeOrg215r2b = fs.statSync(cooldownPathOrg215r2).mtimeMs;
  const cdpOrg215r2b = await mockCdp('__NO_TABS__', [{ id: 'r2tab', url: r2Url }], {
    tabText: () => r2HealthyText,
  });
  const rOrg215r2b = await runSalvageInHome(homeOrg215r2, ['--organize', MARKER, '5'], cdpOrg215r2b.port);
  cdpOrg215r2b.stop();
  const mtimeAfterOrg215r2b = fs.statSync(cooldownPathOrg215r2).mtimeMs;
  check('#215 gate r2 P2 (organizer a2) a healthy organizer scan does not write a cooldown of its own',
    mtimeAfterOrg215r2b === mtimeBeforeOrg215r2b && !/reason=throttle/.test(rOrg215r2b.stdout),
    `before=${mtimeBeforeOrg215r2b} after=${mtimeAfterOrg215r2b} stdout=${rOrg215r2b.stdout}`);
  check("#215 gate r2 P2 (organizer a2) a healthy organizer scan retires that URL's charged fingerprint",
    !throttleSeenHas(homeOrg215r2, r2Url, r2Modal),
    `dir=${fs.existsSync(throttleSeenDir(homeOrg215r2)) ? fs.readdirSync(throttleSeenDir(homeOrg215r2)) : null}`);
  oldMtime215r2(cooldownPathOrg215r2);
  const mtimeBeforeOrg215r2c = fs.statSync(cooldownPathOrg215r2).mtimeMs;
  const cdpOrg215r2c = await mockCdp('__NO_TABS__', [{ id: 'r2tab', url: r2Url }], {
    tabText: () => r2ThrottledText,
    throttleModal: () => r2Modal,
  });
  const rOrg215r2c = await runSalvageInHome(homeOrg215r2, ['--organize', MARKER, '5'], cdpOrg215r2c.port);
  cdpOrg215r2c.stop();
  const mtimeAfterOrg215r2c = fs.statSync(cooldownPathOrg215r2).mtimeMs;
  check('#215 gate r2 P2 (organizer a3) a modal returning after a healthy organizer scan reports reason=throttle again',
    /reason=throttle/.test(rOrg215r2c.stdout), `stdout=${rOrg215r2c.stdout} stderr=${rOrg215r2c.stderr?.slice(-300)}`);
  check('#215 gate r2 P2 (organizer a3) the returning organizer episode writes a NEW cooldown',
    mtimeAfterOrg215r2c > mtimeBeforeOrg215r2c, `before=${mtimeBeforeOrg215r2c} after=${mtimeAfterOrg215r2c}`);
  fs.rmSync(homeOrg215r2, { recursive: true, force: true });
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

// =================================================================================================
// #215 skeptic r2: four defects two independent local skeptics found in the retire-on-healthy
// change (commit 4e1fb0d), plus the test-only gap D5 they found in its own coverage.
// =================================================================================================
const ageCooldown215 = (p) => { const t = new Date(Date.now() - 3_600_000); fs.utimesSync(p, t, t); };

{ // #215 skeptic r2 D1 (P2) (bin/cdp-salvage.mjs tabThrottleModal / scanThrottleHealth): a FAILED
  // dialog read counted as positive proof of health. tabThrottleModal returned null both for "no
  // dialog" and for EVERY read failure (evaluate timeout, websocket error, detached target, a
  // dialog momentarily not laid out), and isThrottlePage can never fire on a marker-bearing
  // conversation page (it rejects any text carrying a pg-run marker at all). So a single flaky
  // evaluate over a still-throttled stale tab made scanThrottleHealth count that URL healthy,
  // retire its charged fingerprint, and re-arm a fresh 900s account cooldown on the next scan —
  // the exact #208 livelock, reached through read flakiness rather than a real new episode.
  // Both halves are covered: (a) the body still carries the limiter copy, (b) it does not and the
  // failed read is the only signal. Neither may retire anything.
  const d1Url = 'https://chatgpt.com/c/mock-215-d1-unreadable-modal';
  const d1Modal = "You're making requests too quickly. [#215 skeptic r2 D1 fixture]";
  const d1Foreign = 'pg-run-another-run-215d1';
  const d1ThrottledText = `ChatGPT\n${d1Foreign}\n${d1Modal}\nAnother run's conversation beneath the modal.\n`;
  const d1HealthyText = `ChatGPT\n${d1Foreign}\nAnother run's conversation, fully rendered, no limiter in sight.\n`;

  // (a) The limiter is still on screen AND still in the body text; only the dialog read fails.
  const homeD1a = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpD1a1 = await mockCdp('__NO_TABS__', [{ id: 'd1tab', url: d1Url }], {
    tabText: () => d1ThrottledText,
    throttleModal: () => d1Modal,
  });
  const rD1a1 = await runSalvageInHome(homeD1a, [MARKER, '3'], cdpD1a1.port);
  cdpD1a1.stop();
  check('#215 skeptic r2 D1a (1) the first sighting of the unowned modal takes the throttle exit and charges its fingerprint',
    rD1a1.status === 5 && throttleSeenHas(homeD1a, d1Url, d1Modal),
    `status=${rD1a1.status} stderr=${rD1a1.stderr?.slice(-300)}`);
  const cooldownD1a = path.join(homeD1a, 'throttle.cooldown');
  ageCooldown215(cooldownD1a);
  const mtimeD1a2Before = fs.statSync(cooldownD1a).mtimeMs;
  const cdpD1a2 = await mockCdp('__NO_TABS__', [{ id: 'd1tab', url: d1Url }], {
    tabText: () => d1ThrottledText,
    throttleModal: () => d1Modal,
    throttleModalFails: () => true,   // the dialog IS there; this scan simply could not read it
  });
  const rD1a2 = await runSalvageInHome(homeD1a, [MARKER, '3'], cdpD1a2.port);
  cdpD1a2.stop();
  const mtimeD1a2After = fs.statSync(cooldownD1a).mtimeMs;
  check('#215 skeptic r2 D1a (2) a tab whose modal read FAILED is never counted healthy, so its charged fingerprint survives',
    throttleSeenHas(homeD1a, d1Url, d1Modal),
    `status=${rD1a2.status} dir=${fs.existsSync(throttleSeenDir(homeD1a)) ? fs.readdirSync(throttleSeenDir(homeD1a)) : null}`);
  check('#215 skeptic r2 D1a (2) the failed-read scan writes no cooldown of its own',
    mtimeD1a2After === mtimeD1a2Before, `before=${mtimeD1a2Before} after=${mtimeD1a2After}`);
  ageCooldown215(cooldownD1a);
  const mtimeD1a3Before = fs.statSync(cooldownD1a).mtimeMs;
  const cdpD1a3 = await mockCdp('__NO_TABS__', [{ id: 'd1tab', url: d1Url }], {
    tabText: () => d1ThrottledText,
    throttleModal: () => d1Modal,
  });
  const rD1a3 = await runSalvageInHome(homeD1a, [MARKER, '3'], cdpD1a3.port);
  cdpD1a3.stop();
  const mtimeD1a3After = fs.statSync(cooldownD1a).mtimeMs;
  check('#215 skeptic r2 D1a (3) the unchanged stale modal does NOT re-arm the account cooldown after a failed read',
    mtimeD1a3After === mtimeD1a3Before && rD1a3.status !== 5,
    `before=${mtimeD1a3Before} after=${mtimeD1a3After} status=${rD1a3.status}`);
  fs.rmSync(homeD1a, { recursive: true, force: true });

  // (b) The body carries NO limiter copy, so THROTTLE_RE cannot rescue this case: the failed
  // dialog read is the only signal there is, and "unknown" must not be laundered into "healthy".
  const homeD1b = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpD1b1 = await mockCdp('__NO_TABS__', [{ id: 'd1tab', url: d1Url }], {
    tabText: () => d1ThrottledText,
    throttleModal: () => d1Modal,
  });
  const rD1b1 = await runSalvageInHome(homeD1b, [MARKER, '3'], cdpD1b1.port);
  cdpD1b1.stop();
  check('#215 skeptic r2 D1b (1) the first sighting of the unowned modal charges its fingerprint',
    rD1b1.status === 5 && throttleSeenHas(homeD1b, d1Url, d1Modal),
    `status=${rD1b1.status} stderr=${rD1b1.stderr?.slice(-300)}`);
  const cooldownD1b = path.join(homeD1b, 'throttle.cooldown');
  ageCooldown215(cooldownD1b);
  const mtimeD1b2Before = fs.statSync(cooldownD1b).mtimeMs;
  const cdpD1b2 = await mockCdp('__NO_TABS__', [{ id: 'd1tab', url: d1Url }], {
    tabText: () => d1HealthyText,
    throttleModalFails: () => true,
  });
  const rD1b2 = await runSalvageInHome(homeD1b, [MARKER, '3'], cdpD1b2.port);
  cdpD1b2.stop();
  const mtimeD1b2After = fs.statSync(cooldownD1b).mtimeMs;
  check('#215 skeptic r2 D1b (2) readable body text plus an UNREADABLE dialog is unknown, not healthy: the fingerprint survives',
    throttleSeenHas(homeD1b, d1Url, d1Modal),
    `status=${rD1b2.status} dir=${fs.existsSync(throttleSeenDir(homeD1b)) ? fs.readdirSync(throttleSeenDir(homeD1b)) : null}`);
  check('#215 skeptic r2 D1b (2) the unknown-dialog scan writes no cooldown of its own',
    mtimeD1b2After === mtimeD1b2Before, `before=${mtimeD1b2Before} after=${mtimeD1b2After}`);
  ageCooldown215(cooldownD1b);
  const mtimeD1b3Before = fs.statSync(cooldownD1b).mtimeMs;
  const cdpD1b3 = await mockCdp('__NO_TABS__', [{ id: 'd1tab', url: d1Url }], {
    tabText: () => d1ThrottledText,
    throttleModal: () => d1Modal,
  });
  const rD1b3 = await runSalvageInHome(homeD1b, [MARKER, '3'], cdpD1b3.port);
  cdpD1b3.stop();
  const mtimeD1b3After = fs.statSync(cooldownD1b).mtimeMs;
  check('#215 skeptic r2 D1b (3) the same modal after an unknown-dialog scan does NOT re-arm the account cooldown',
    mtimeD1b3After === mtimeD1b3Before && rD1b3.status !== 5,
    `before=${mtimeD1b3Before} after=${mtimeD1b3After} status=${rD1b3.status}`);
  fs.rmSync(homeD1b, { recursive: true, force: true });

  // (c) Control for the SAME machinery in the other direction: a genuinely healthy scan — dialog
  // read SUCCEEDED and returned no dialog — still retires, so the D1 guard did not simply
  // disable retire-on-healthy. (This is the r2 fix's own headline behaviour, re-asserted here
  // against the same fixture the two failed-read cases use.)
  const homeD1c = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpD1c1 = await mockCdp('__NO_TABS__', [{ id: 'd1tab', url: d1Url }], {
    tabText: () => d1ThrottledText,
    throttleModal: () => d1Modal,
  });
  const rD1c1 = await runSalvageInHome(homeD1c, [MARKER, '3'], cdpD1c1.port);
  cdpD1c1.stop();
  const cdpD1c2 = await mockCdp('__NO_TABS__', [{ id: 'd1tab', url: d1Url }], {
    tabText: () => d1HealthyText,
  });
  await runSalvageInHome(homeD1c, [MARKER, '3'], cdpD1c2.port);
  cdpD1c2.stop();
  check('#215 skeptic r2 D1c control: a SUCCESSFUL dialog read that finds no dialog still retires the fingerprint',
    rD1c1.status === 5 && !throttleSeenHas(homeD1c, d1Url, d1Modal),
    `first=${rD1c1.status} dir=${fs.existsSync(throttleSeenDir(homeD1c)) ? fs.readdirSync(throttleSeenDir(homeD1c)) : null}`);
  fs.rmSync(homeD1c, { recursive: true, force: true });
}

{ // #215 skeptic r2 D2 (P3) (bin/cdp-salvage.mjs scanThrottleHealth vs. the main scan's hit
  // filter): the two deliberately DISAGREE about one shape — a tab whose dialog read succeeded
  // but whose text read came back empty. The hit filter refuses to charge it (a modal with no
  // readable page beneath it cannot be attributed), while the health pass counts it as a throttle
  // surface and blocks retire for that URL. This check pins that divergence down as intended
  // behaviour: under-retire is the safe direction, so the record must survive.
  const d2Url = 'https://chatgpt.com/c/mock-215-d2-modal-without-text';
  const d2Modal = "You're making requests too quickly. [#215 skeptic r2 D2 fixture]";
  const d2Foreign = 'pg-run-another-run-215d2';
  const d2ThrottledText = `ChatGPT\n${d2Foreign}\n${d2Modal}\nAnother run's conversation beneath the modal.\n`;
  const d2HealthyText = `ChatGPT\n${d2Foreign}\nAnother run's conversation, fully rendered, no limiter in sight.\n`;
  const homeD2 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpD2a = await mockCdp('__NO_TABS__', [{ id: 'd2tab', url: d2Url }], {
    tabText: () => d2ThrottledText,
    throttleModal: () => d2Modal,
  });
  const rD2a = await runSalvageInHome(homeD2, [MARKER, '3'], cdpD2a.port);
  cdpD2a.stop();
  check('#215 skeptic r2 D2 (1) the sighting is charged before the mixed scan',
    rD2a.status === 5 && throttleSeenHas(homeD2, d2Url, d2Modal), `status=${rD2a.status}`);
  const cooldownD2 = path.join(homeD2, 'throttle.cooldown');
  ageCooldown215(cooldownD2);
  const mtimeD2Before = fs.statSync(cooldownD2).mtimeMs;
  const cdpD2b = await mockCdp('__NO_TABS__', [
    { id: 'd2modal', url: d2Url },
    { id: 'd2healthy', url: d2Url },
  ], {
    tabText: (url, id) => (id === 'd2modal' ? '' : d2HealthyText),
    throttleModal: (id) => (id === 'd2modal' ? d2Modal : null),
  });
  const rD2b = await runSalvageInHome(homeD2, [MARKER, '3'], cdpD2b.port);
  cdpD2b.stop();
  const mtimeD2After = fs.statSync(cooldownD2).mtimeMs;
  check('#215 skeptic r2 D2 (2) a successful dialog read over an EMPTY text read still blocks retire for that URL',
    throttleSeenHas(homeD2, d2Url, d2Modal),
    `status=${rD2b.status} dir=${fs.existsSync(throttleSeenDir(homeD2)) ? fs.readdirSync(throttleSeenDir(homeD2)) : null}`);
  check('#215 skeptic r2 D2 (2) that same shape is still not a charged hit (no new cooldown)',
    mtimeD2After === mtimeD2Before, `before=${mtimeD2Before} after=${mtimeD2After}`);
  fs.rmSync(homeD2, { recursive: true, force: true });
}

{ // #215 skeptic r2 D3 (P3) (organizer memo-recovery scratch path): with a remembered URL and no
  // open tab, the scratch render is the ONLY observation the organizer ever makes — and scratch
  // renders were excluded from retire by design. So throttle -> healthy -> throttle charged only
  // the first cooldown: invocation 3 reported reason=throttle again with NO fresh cooldown, and
  // the engine's mtime-based clock (pg_cooldown_remaining_secs, 900s) reported nothing left while
  // the limiter was live. Fixed by retiring exactly the ONE rendered URL's records when that
  // render reaches a DECISIVE non-throttle outcome with a successful text read.
  const d3Url = 'https://chatgpt.com/c/mock-215-d3-organizer-memo';
  const d3Modal = "You're making requests too quickly. [#215 skeptic r2 D3 organizer fixture]";
  const d3Foreign = 'pg-run-another-run-215d3org';
  const d3ThrottledText = `ChatGPT\n${d3Foreign}\n${d3Modal}\nAnother run's conversation beneath the modal.\n`;
  const d3HealthyText = `ChatGPT\n${d3Foreign}\nAnother run's conversation, fully rendered, no limiter in sight.\n`;
  const d3Title = 'pro-gate review: PR #215 skeptic r2 D3 [pro-gate]';
  const homeD3 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, d3Title, d3Url)(homeD3);

  const cdpD3a = await mockCdp('__NO_TABS__', [], {
    renderText: () => d3ThrottledText,
    throttleModal: () => d3Modal,
  });
  const rD3a = await runSalvageInHome(homeD3, ['--organize', MARKER, '5'], cdpD3a.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpD3a.stop();
  check('#215 skeptic r2 D3 (organizer 1) a throttled memo render reports reason=throttle and charges its fingerprint',
    /reason=throttle/.test(rD3a.stdout) && throttleSeenHas(homeD3, d3Url, d3Modal),
    `stdout=${rD3a.stdout} stderr=${rD3a.stderr?.slice(-300)}`);
  const cooldownD3 = path.join(homeD3, 'throttle.cooldown');
  ageCooldown215(cooldownD3);
  const mtimeD3bBefore = fs.statSync(cooldownD3).mtimeMs;
  const cdpD3b = await mockCdp('__NO_TABS__', [], {
    renderText: () => d3HealthyText,
  });
  const rD3b = await runSalvageInHome(homeD3, ['--organize', MARKER, '5'], cdpD3b.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpD3b.stop();
  const mtimeD3bAfter = fs.statSync(cooldownD3).mtimeMs;
  check("#215 skeptic r2 D3 (organizer 2) a DECISIVE healthy memo render retires that one URL's charged fingerprint",
    !throttleSeenHas(homeD3, d3Url, d3Modal),
    `stdout=${rD3b.stdout} dir=${fs.existsSync(throttleSeenDir(homeD3)) ? fs.readdirSync(throttleSeenDir(homeD3)) : null}`);
  check('#215 skeptic r2 D3 (organizer 2) the healthy memo render writes no cooldown of its own',
    mtimeD3bAfter === mtimeD3bBefore && !/reason=throttle/.test(rD3b.stdout),
    `before=${mtimeD3bBefore} after=${mtimeD3bAfter} stdout=${rD3b.stdout}`);
  ageCooldown215(cooldownD3);
  const mtimeD3cBefore = fs.statSync(cooldownD3).mtimeMs;
  const cdpD3c = await mockCdp('__NO_TABS__', [], {
    renderText: () => d3ThrottledText,
    throttleModal: () => d3Modal,
  });
  const rD3c = await runSalvageInHome(homeD3, ['--organize', MARKER, '5'], cdpD3c.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpD3c.stop();
  const mtimeD3cAfter = fs.statSync(cooldownD3).mtimeMs;
  check('#215 skeptic r2 D3 (organizer 3) the returning limiter reports reason=throttle AND writes a NEW cooldown',
    /reason=throttle/.test(rD3c.stdout) && mtimeD3cAfter > mtimeD3cBefore,
    `stdout=${rD3c.stdout} before=${mtimeD3cBefore} after=${mtimeD3cAfter}`);
  fs.rmSync(homeD3, { recursive: true, force: true });
}

{ // #215 skeptic r2 D3 (P3), main scan: the same three-invocation sequence through the OTHER
  // memo-recovery path — the remembered-URL seeded render, which likewise never retired.
  const d3mUrl = 'https://chatgpt.com/c/mock-215-d3-main-memo';
  const d3mModal = "You're making requests too quickly. [#215 skeptic r2 D3 main fixture]";
  const d3mForeign = 'pg-run-another-run-215d3main';
  const d3mThrottledText = `ChatGPT\n${d3mForeign}\n${d3mModal}\nAnother run's conversation beneath the modal.\n`;
  const d3mOursText = `ChatGPT\nrun marker: ${MARKER}\nstill thinking, no verdict yet\n`;
  const homeD3m = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedMemo(MARKER, d3mUrl)(homeD3m);

  const cdpD3ma = await mockCdp('__NO_TABS__', [], {
    renderText: () => d3mThrottledText,
    throttleModal: () => d3mModal,
  });
  const rD3ma = await runSalvageInHome(homeD3m, [MARKER, '3'], cdpD3ma.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpD3ma.stop();
  check('#215 skeptic r2 D3 (main 1) a throttled remembered render takes the throttle exit and charges its fingerprint',
    rD3ma.status === 5 && throttleSeenHas(homeD3m, d3mUrl, d3mModal),
    `status=${rD3ma.status} stderr=${rD3ma.stderr?.slice(-300)}`);
  const cooldownD3m = path.join(homeD3m, 'throttle.cooldown');
  ageCooldown215(cooldownD3m);
  const mtimeD3mbBefore = fs.statSync(cooldownD3m).mtimeMs;
  const cdpD3mb = await mockCdp('__NO_TABS__', [], {
    renderText: () => d3mOursText,
  });
  const rD3mb = await runSalvageInHome(homeD3m, [MARKER, '3'], cdpD3mb.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpD3mb.stop();
  const mtimeD3mbAfter = fs.statSync(cooldownD3m).mtimeMs;
  check("#215 skeptic r2 D3 (main 2) a DECISIVE healthy remembered render retires that one URL's charged fingerprint",
    !throttleSeenHas(homeD3m, d3mUrl, d3mModal),
    `status=${rD3mb.status} dir=${fs.existsSync(throttleSeenDir(homeD3m)) ? fs.readdirSync(throttleSeenDir(homeD3m)) : null}`);
  check('#215 skeptic r2 D3 (main 2) that healthy render still reports the conversation live (exit 3) and writes no cooldown',
    rD3mb.status === 3 && mtimeD3mbAfter === mtimeD3mbBefore,
    `status=${rD3mb.status} before=${mtimeD3mbBefore} after=${mtimeD3mbAfter}`);
  ageCooldown215(cooldownD3m);
  const mtimeD3mcBefore = fs.statSync(cooldownD3m).mtimeMs;
  const cdpD3mc = await mockCdp('__NO_TABS__', [], {
    renderText: () => d3mThrottledText,
    throttleModal: () => d3mModal,
  });
  const rD3mc = await runSalvageInHome(homeD3m, [MARKER, '3'], cdpD3mc.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpD3mc.stop();
  const mtimeD3mcAfter = fs.statSync(cooldownD3m).mtimeMs;
  check('#215 skeptic r2 D3 (main 3) the returning limiter takes the throttle exit (5) AND writes a NEW cooldown',
    rD3mc.status === 5 && mtimeD3mcAfter > mtimeD3mcBefore,
    `status=${rD3mc.status} before=${mtimeD3mcBefore} after=${mtimeD3mcAfter} stderr=${rD3mc.stderr?.slice(-300)}`);
  fs.rmSync(homeD3m, { recursive: true, force: true });
}

{ // #215 skeptic r2 D4 (P3) (bin/cdp-salvage.mjs recordThrottleSeen): the record's create and its
  // content write were ONE writeFileSync, and the path joined the rollback list only after both
  // succeeded. A content-write failure after the create (ENOSPC is the real-world one) therefore
  // left an EMPTY file behind that the rollback could not remove and that — being empty — is
  // exempt from retire-on-healthy, suppressing that fingerprint for the whole 7-day TTL while the
  // catch still returned "charge me". Fixed by splitting create (openSync 'wx', still the sole
  // race arbiter) from the content write and pushing the path BETWEEN them.
  //
  // (a) No deterministic way exists in this harness to fail an fs.writeSync to an already-open fd
  // on a normal filesystem (a read-only mount needs privileges; a directory at the path is EEXIST
  // on the create, not a write failure; RLIMIT_FSIZE would kill the child by SIGXFSZ and break
  // every other write it makes). So the ORDER itself is asserted against the shipped source —
  // weaker than an execution proof, and labelled as such.
  const d4Source = fs.readFileSync(SALVAGE, 'utf8');
  const d4Start = d4Source.indexOf('function recordThrottleSeen(');
  const d4Body = d4Start < 0 ? '' : d4Source.slice(d4Start, d4Source.indexOf('\nfunction ', d4Start + 1));
  const d4OpenAt = d4Body.indexOf("fs.openSync(recordPath, 'wx')");
  const d4PushAt = d4Body.indexOf('pendingThrottleSeenRecords.push(recordPath)');
  const d4WriteAt = d4Body.indexOf('fs.writeFileSync(fd');
  check('#215 skeptic r2 D4 (a, source order) recordThrottleSeen creates the record, then rollback-tracks it, then writes its content',
    d4OpenAt >= 0 && d4PushAt > d4OpenAt && d4WriteAt > d4PushAt,
    `open=${d4OpenAt} push=${d4PushAt} write=${d4WriteAt}`);
  check('#215 skeptic r2 D4 (a, source order) no single writeFileSync both creates and fills the record',
    d4Body.length > 0 && !/fs\.writeFileSync\(\s*recordPath/.test(d4Body),
    `body=${d4Body.slice(0, 200)}`);

  // (b) Execution control for the rollback the reordering protects: when the COOLDOWN write
  // itself fails (its path is a directory -> EISDIR), the provisional record must be removed, so
  // the sighting stays re-chargeable instead of silently suppressed with no cooldown behind it.
  const d4Url = 'https://chatgpt.com/c/mock-215-d4-rollback';
  const d4Modal = "You're making requests too quickly. [#215 skeptic r2 D4 fixture]";
  const d4Foreign = 'pg-run-another-run-215d4';
  const d4Text = `ChatGPT\n${d4Foreign}\n${d4Modal}\nAnother run's conversation beneath the modal.\n`;
  const homeD4 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  fs.mkdirSync(path.join(homeD4, 'throttle.cooldown'), { recursive: true });
  const cdpD4 = await mockCdp('__NO_TABS__', [{ id: 'd4tab', url: d4Url }], {
    tabText: () => d4Text,
    throttleModal: () => d4Modal,
  });
  const rD4 = await runSalvageInHome(homeD4, [MARKER, '3'], cdpD4.port);
  cdpD4.stop();
  check('#215 skeptic r2 D4 (b) a failed cooldown write rolls the provisional record back and says so',
    !throttleSeenHas(homeD4, d4Url, d4Modal) && /could not be written/.test(rD4.stderr ?? ''),
    `status=${rD4.status} dir=${fs.existsSync(throttleSeenDir(homeD4)) ? fs.readdirSync(throttleSeenDir(homeD4)) : null} stderr=${rD4.stderr?.slice(-300)}`);
  check('#215 skeptic r2 D4 (b) the sighting still takes the throttle exit (5) even though the cooldown write failed',
    rD4.status === 5, `status=${rD4.status} stderr=${rD4.stderr?.slice(-300)}`);
  fs.rmSync(homeD4, { recursive: true, force: true });
}

{ // #215 skeptic r2 D5 (P3, coverage): scanThrottleHealth has TWO guards on the same-scan clause,
  // and every existing fixture holds exactly ONE fingerprint per URL — where both guards are the
  // same guard and neither is proven to do anything on its own. This fixture separates them: URL
  // X holds TWO charged fingerprints (two distinct modal texts) and the scan under test sees only
  // ONE of them under a dialog. The unobserved record is in NO protectedKeys set this scan builds,
  // so only the URL-level "throttled anywhere this scan -> not healthy" exclusion can save it.
  const d5Url = 'https://chatgpt.com/c/mock-215-d5-two-fingerprints';
  const d5ModalA = "You're making requests too quickly. [#215 skeptic r2 D5 fixture A]";
  const d5ModalB = "You're making requests too quickly. [#215 skeptic r2 D5 fixture B]";
  const d5Foreign = 'pg-run-another-run-215d5';
  const d5TextA = `ChatGPT\n${d5Foreign}\n${d5ModalA}\nAnother run's conversation beneath modal A.\n`;
  const d5TextB = `ChatGPT\n${d5Foreign}\n${d5ModalB}\nAnother run's conversation beneath modal B.\n`;
  const d5HealthyText = `ChatGPT\n${d5Foreign}\nAnother run's conversation, fully rendered, no limiter in sight.\n`;
  const homeD5 = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpD5a = await mockCdp('__NO_TABS__', [
    { id: 'd5a', url: d5Url },
    { id: 'd5b', url: d5Url },
  ], {
    tabText: (url, id) => (id === 'd5a' ? d5TextA : d5TextB),
    throttleModal: (id) => (id === 'd5a' ? d5ModalA : d5ModalB),
  });
  const rD5a = await runSalvageInHome(homeD5, [MARKER, '3'], cdpD5a.port);
  cdpD5a.stop();
  check('#215 skeptic r2 D5 (1) one scan charges BOTH fingerprints at that URL and exits 5 once',
    rD5a.status === 5 && throttleSeenHas(homeD5, d5Url, d5ModalA) && throttleSeenHas(homeD5, d5Url, d5ModalB),
    `status=${rD5a.status} dir=${fs.existsSync(throttleSeenDir(homeD5)) ? fs.readdirSync(throttleSeenDir(homeD5)) : null}`);
  const cooldownD5 = path.join(homeD5, 'throttle.cooldown');
  ageCooldown215(cooldownD5);
  const mtimeD5Before = fs.statSync(cooldownD5).mtimeMs;
  const cdpD5b = await mockCdp('__NO_TABS__', [
    { id: 'd5a', url: d5Url },
    { id: 'd5b', url: d5Url },
  ], {
    tabText: (url, id) => (id === 'd5a' ? d5TextA : d5HealthyText),
    throttleModal: (id) => (id === 'd5a' ? d5ModalA : null),
  });
  const rD5b = await runSalvageInHome(homeD5, [MARKER, '3'], cdpD5b.port);
  cdpD5b.stop();
  const mtimeD5After = fs.statSync(cooldownD5).mtimeMs;
  check('#215 skeptic r2 D5 (2) a fingerprint this scan never observed is saved by the URL-level exclusion alone',
    throttleSeenHas(homeD5, d5Url, d5ModalB),
    `status=${rD5b.status} dir=${fs.existsSync(throttleSeenDir(homeD5)) ? fs.readdirSync(throttleSeenDir(homeD5)) : null}`);
  check('#215 skeptic r2 D5 (2) the fingerprint this scan IS observing survives too, and no second cooldown is charged',
    throttleSeenHas(homeD5, d5Url, d5ModalA) && mtimeD5After === mtimeD5Before,
    `before=${mtimeD5Before} after=${mtimeD5After}`);
  fs.rmSync(homeD5, { recursive: true, force: true });
}

{ // #215 skeptic r2c A (P2) (bin/cdp-salvage.mjs freshRenderText / openOrganizerScratch): D1 taught
  // the LISTED-tab classifier to tell "could not look" from "no dialog", and D3 opened the two
  // memo-recovery RENDERS to retire-on-healthy — but those renders kept the old, blinder test:
  // the thin tabThrottleModal (null for a failed read AND for no dialog) combined with
  // isThrottlePage, which by construction can never fire on a page carrying a pg-run marker. So a
  // render over a STILL-LIMITED conversation reached a "decisive" non-throttle reason
  // (foreign-marker on the main path, stale-memo on the organizer path), retired that URL's
  // charged fingerprint, and let the very next scan re-arm a fresh 900s account cooldown on an
  // unchanged limiter — the #208 livelock, through the one path D3 had just made retire-capable.
  // Two ways in, both covered here: (A-main/A-organizer) the dialog read FAILS while the limiter
  // is unchanged, and (A-body) nothing fails at all — the dialog element read succeeds and finds
  // no dialog while the body text still carries the limiter copy, which the listed-tab classifier
  // already counts as a throttle surface (THROTTLE_RE, D1) and the render half did not.
  // The guard is on the RETIRE only: the charge branches still test isThrottlePage || modal, so a
  // conversation that merely QUOTES the limiter copy never newly charges a cooldown.
  const r2cUrl = 'https://chatgpt.com/c/mock-215-r2c-a-main';
  const r2cModal = "You're making requests too quickly. [#215 skeptic r2c A main fixture]";
  const r2cForeign = 'pg-run-another-run-215r2ca';
  const r2cThrottled = `ChatGPT\n${r2cForeign}\n${r2cModal}\nAnother run's conversation beneath the modal.\n`;
  const r2cHealthy = `ChatGPT\n${r2cForeign}\nAnother run's conversation, fully rendered, no limiter in sight.\n`;

  // (A-main) remembered-URL seeded render, three invocations: charge -> failed dialog read over an
  // UNCHANGED limiter -> the same limiter again.
  const homeR2cA = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedMemo(MARKER, r2cUrl)(homeR2cA);
  const cdpR2cA1 = await mockCdp('__NO_TABS__', [], {
    renderText: () => r2cThrottled,
    throttleModal: () => r2cModal,
  });
  const rR2cA1 = await runSalvageInHome(homeR2cA, [MARKER, '3'], cdpR2cA1.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cA1.stop();
  check('#215 skeptic r2c A (main 1) the throttled remembered render takes the throttle exit and charges its fingerprint',
    rR2cA1.status === 5 && throttleSeenHas(homeR2cA, r2cUrl, r2cModal),
    `status=${rR2cA1.status} stderr=${rR2cA1.stderr?.slice(-300)}`);
  const cooldownR2cA = path.join(homeR2cA, 'throttle.cooldown');
  ageCooldown215(cooldownR2cA);
  const mtimeR2cA2Before = fs.statSync(cooldownR2cA).mtimeMs;
  const cdpR2cA2 = await mockCdp('__NO_TABS__', [], {
    renderText: () => r2cThrottled,
    throttleModal: () => r2cModal,
    throttleModalFails: () => true,   // the dialog IS there; this render simply could not read it
  });
  const rR2cA2 = await runSalvageInHome(homeR2cA, [MARKER, '3'], cdpR2cA2.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cA2.stop();
  const mtimeR2cA2After = fs.statSync(cooldownR2cA).mtimeMs;
  check('#215 skeptic r2c A (main 2) a remembered render whose dialog read FAILED never retires the charged fingerprint',
    throttleSeenHas(homeR2cA, r2cUrl, r2cModal),
    `status=${rR2cA2.status} dir=${fs.existsSync(throttleSeenDir(homeR2cA)) ? fs.readdirSync(throttleSeenDir(homeR2cA)) : null}`);
  check('#215 skeptic r2c A (main 2) that unreadable render writes no cooldown of its own',
    mtimeR2cA2After === mtimeR2cA2Before, `before=${mtimeR2cA2Before} after=${mtimeR2cA2After}`);
  ageCooldown215(cooldownR2cA);
  const mtimeR2cA3Before = fs.statSync(cooldownR2cA).mtimeMs;
  const cdpR2cA3 = await mockCdp('__NO_TABS__', [], {
    renderText: () => r2cThrottled,
    throttleModal: () => r2cModal,
  });
  const rR2cA3 = await runSalvageInHome(homeR2cA, [MARKER, '3'], cdpR2cA3.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cA3.stop();
  const mtimeR2cA3After = fs.statSync(cooldownR2cA).mtimeMs;
  check('#215 skeptic r2c A (main 3) the UNCHANGED limiter does not re-arm a fresh account cooldown after that failed read',
    mtimeR2cA3After === mtimeR2cA3Before,
    `before=${mtimeR2cA3Before} after=${mtimeR2cA3After} status=${rR2cA3.status} stderr=${rR2cA3.stderr?.slice(-300)}`);
  fs.rmSync(homeR2cA, { recursive: true, force: true });

  // (A-organizer) the organizer's memo scratch render, same three-invocation shape. Its decisive
  // reason here is stale-memo (another run's marker under the modal the read could not see).
  const r2cOrgUrl = 'https://chatgpt.com/c/mock-215-r2c-a-organizer';
  const r2cOrgModal = "You're making requests too quickly. [#215 skeptic r2c A organizer fixture]";
  const r2cOrgForeign = 'pg-run-another-run-215r2caorg';
  const r2cOrgThrottled = `ChatGPT\n${r2cOrgForeign}\n${r2cOrgModal}\nAnother run's conversation beneath the modal.\n`;
  const r2cOrgTitle = 'pro-gate review: PR #215 skeptic r2c A [pro-gate]';
  const homeR2cB = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedOrganizer(MARKER, r2cOrgTitle, r2cOrgUrl)(homeR2cB);
  const cdpR2cB1 = await mockCdp('__NO_TABS__', [], {
    renderText: () => r2cOrgThrottled,
    throttleModal: () => r2cOrgModal,
  });
  const rR2cB1 = await runSalvageInHome(homeR2cB, ['--organize', MARKER, '5'], cdpR2cB1.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cB1.stop();
  check('#215 skeptic r2c A (organizer 1) the throttled memo render reports reason=throttle and charges its fingerprint',
    /reason=throttle/.test(rR2cB1.stdout) && throttleSeenHas(homeR2cB, r2cOrgUrl, r2cOrgModal),
    `stdout=${rR2cB1.stdout} stderr=${rR2cB1.stderr?.slice(-300)}`);
  const cooldownR2cB = path.join(homeR2cB, 'throttle.cooldown');
  ageCooldown215(cooldownR2cB);
  const mtimeR2cB2Before = fs.statSync(cooldownR2cB).mtimeMs;
  const cdpR2cB2 = await mockCdp('__NO_TABS__', [], {
    renderText: () => r2cOrgThrottled,
    throttleModal: () => r2cOrgModal,
    throttleModalFails: () => true,
  });
  const rR2cB2 = await runSalvageInHome(homeR2cB, ['--organize', MARKER, '5'], cdpR2cB2.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cB2.stop();
  const mtimeR2cB2After = fs.statSync(cooldownR2cB).mtimeMs;
  check('#215 skeptic r2c A (organizer 2) a memo render whose dialog read FAILED never retires the charged fingerprint',
    throttleSeenHas(homeR2cB, r2cOrgUrl, r2cOrgModal),
    `stdout=${rR2cB2.stdout} dir=${fs.existsSync(throttleSeenDir(homeR2cB)) ? fs.readdirSync(throttleSeenDir(homeR2cB)) : null}`);
  check('#215 skeptic r2c A (organizer 2) that unreadable memo render writes no cooldown of its own',
    mtimeR2cB2After === mtimeR2cB2Before, `before=${mtimeR2cB2Before} after=${mtimeR2cB2After}`);
  ageCooldown215(cooldownR2cB);
  const mtimeR2cB3Before = fs.statSync(cooldownR2cB).mtimeMs;
  const cdpR2cB3 = await mockCdp('__NO_TABS__', [], {
    renderText: () => r2cOrgThrottled,
    throttleModal: () => r2cOrgModal,
  });
  const rR2cB3 = await runSalvageInHome(homeR2cB, ['--organize', MARKER, '5'], cdpR2cB3.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cB3.stop();
  const mtimeR2cB3After = fs.statSync(cooldownR2cB).mtimeMs;
  check('#215 skeptic r2c A (organizer 3) the UNCHANGED limiter does not re-arm a fresh cooldown through the organizer path',
    mtimeR2cB3After === mtimeR2cB3Before,
    `before=${mtimeR2cB3Before} after=${mtimeR2cB3After} stdout=${rR2cB3.stdout}`);
  fs.rmSync(homeR2cB, { recursive: true, force: true });

  // (A-body) no read failure anywhere: the dialog ELEMENT read succeeds and finds nothing while
  // the body text still carries the limiter copy. scanThrottleHealth already calls that a throttle
  // surface for listed tabs (D1's THROTTLE_RE clause); the render half must agree.
  const r2cBodyUrl = 'https://chatgpt.com/c/mock-215-r2c-a-body-copy';
  const r2cBodyModal = "You're making requests too quickly. [#215 skeptic r2c A body fixture]";
  const r2cBodyForeign = 'pg-run-another-run-215r2cabody';
  const r2cBodyText = `ChatGPT\n${r2cBodyForeign}\n${r2cBodyModal}\nAnother run's conversation beneath the modal.\n`;
  const homeR2cC = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedMemo(MARKER, r2cBodyUrl)(homeR2cC);
  const cdpR2cC1 = await mockCdp('__NO_TABS__', [], {
    renderText: () => r2cBodyText,
    throttleModal: () => r2cBodyModal,
  });
  const rR2cC1 = await runSalvageInHome(homeR2cC, [MARKER, '3'], cdpR2cC1.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cC1.stop();
  check('#215 skeptic r2c A (body 1) the sighting is charged before the body-copy-only render',
    rR2cC1.status === 5 && throttleSeenHas(homeR2cC, r2cBodyUrl, r2cBodyModal),
    `status=${rR2cC1.status} stderr=${rR2cC1.stderr?.slice(-300)}`);
  const cdpR2cC2 = await mockCdp('__NO_TABS__', [], { renderText: () => r2cBodyText });  // read OK, no dialog
  const rR2cC2 = await runSalvageInHome(homeR2cC, [MARKER, '3'], cdpR2cC2.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cC2.stop();
  check('#215 skeptic r2c A (body 2) body text still carrying the limiter copy is not health evidence on the render path either',
    throttleSeenHas(homeR2cC, r2cBodyUrl, r2cBodyModal),
    `status=${rR2cC2.status} dir=${fs.existsSync(throttleSeenDir(homeR2cC)) ? fs.readdirSync(throttleSeenDir(homeR2cC)) : null}`);
  fs.rmSync(homeR2cC, { recursive: true, force: true });

  // (A-control) the other direction, against the SAME fixture: a render whose dialog read
  // SUCCEEDED, found no dialog, over body text with no limiter copy in it still retires. Without
  // this the guard above could have been written as "never retire" and every check still passed.
  // (The existing '#215 skeptic r2 D3 (organizer 2)' and '(main 2)' checks are also this control,
  // on the marker-found reason; this one covers foreign-marker, the reason A-main subverts.)
  const homeR2cD = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  seedMemo(MARKER, r2cUrl)(homeR2cD);
  const cdpR2cD1 = await mockCdp('__NO_TABS__', [], {
    renderText: () => r2cThrottled,
    throttleModal: () => r2cModal,
  });
  const rR2cD1 = await runSalvageInHome(homeR2cD, [MARKER, '3'], cdpR2cD1.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cD1.stop();
  const cdpR2cD2 = await mockCdp('__NO_TABS__', [], { renderText: () => r2cHealthy });
  const rR2cD2 = await runSalvageInHome(homeR2cD, [MARKER, '3'], cdpR2cD2.port, SCRATCH_SAMPLE_TEST_ENV);
  cdpR2cD2.stop();
  check('#215 skeptic r2c A (control) a decisive render with a SUCCESSFUL dialog read and no limiter copy still retires',
    rR2cD1.status === 5 && !throttleSeenHas(homeR2cD, r2cUrl, r2cModal),
    `first=${rR2cD1.status} second=${rR2cD2.status} dir=${fs.existsSync(throttleSeenDir(homeR2cD)) ? fs.readdirSync(throttleSeenDir(homeR2cD)) : null}`);
  fs.rmSync(homeR2cD, { recursive: true, force: true });
}

{ // #215 skeptic r2c B (P3) (bin/cdp-salvage.mjs recordThrottleSeen): D4 split the record's create
  // from its content write and pushed the rollback registration BETWEEN them — which makes a
  // failed content write rollback-TRACKED but never rolled BACK, because the only thing that
  // drains that list is recordThrottle, and recordThrottle only rolls back when the COOLDOWN write
  // fails. On the real-world path (ENOSPC on the record, cooldown file already present and
  // rewritable) the catch returns "charge me", the cooldown write SUCCEEDS, the pending list is
  // cleared on success, and the zero-byte record stays: attributable to no URL, so exempt from
  // retire-on-healthy, and protected from TTL/capacity pruning whenever the fingerprint is
  // observed. That is a 7-day silent suppression of a live limiter, arrived at through the very
  // fix meant to prevent it. (fs.writeSync also does not loop on short writes the way
  // writeFileSync does, so it could strand a TRUNCATED record too.)
  //
  // Unlike D4, this failure IS forceable: the record's content write is the only write in the
  // child whose payload is a bare conversation URL, so a --import preload can fail exactly that
  // one call with ENOSPC and leave every other write (cooldown, memo, stdout) alone. The preload
  // patches both fs.writeSync and the fd form of fs.writeFileSync, so the same fixture exercises
  // the shipped code before and after that swap.
  const ENOSPC_PRELOAD = [
    "import fs from 'node:fs';",
    "const isRecordWrite = (data) => typeof data === 'string' && data.startsWith('https://chatgpt.com/c/');",
    "const enospc = () => { const err = new Error('mock: no space left on device'); err.code = 'ENOSPC'; throw err; };",
    'const realWriteSync = fs.writeSync;',
    'fs.writeSync = function (fd, data, ...rest) {',
    "  if (typeof fd === 'number' && isRecordWrite(data)) enospc();",
    '  return realWriteSync.call(fs, fd, data, ...rest);',
    '};',
    'const realWriteFileSync = fs.writeFileSync;',
    'fs.writeFileSync = function (file, data, options) {',
    "  if (typeof file === 'number' && isRecordWrite(data)) enospc();",
    '  return realWriteFileSync.call(fs, file, data, options);',
    '};',
    '',
  ].join('\n');
  const r2cBDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-enospc-'));
  const r2cBPreload = path.join(r2cBDir, 'fail-record-write.mjs');
  fs.writeFileSync(r2cBPreload, ENOSPC_PRELOAD);
  const r2cBEnv = {
    NODE_OPTIONS: [process.env.NODE_OPTIONS, `--import ${pathToFileURL(r2cBPreload).href}`].filter(Boolean).join(' '),
  };

  const r2cBUrl = 'https://chatgpt.com/c/mock-215-r2c-b-enospc';
  const r2cBModal = "You're making requests too quickly. [#215 skeptic r2c B fixture]";
  const r2cBForeign = 'pg-run-another-run-215r2cb';
  const r2cBText = `ChatGPT\n${r2cBForeign}\n${r2cBModal}\nAnother run's conversation beneath the modal.\n`;
  const homeR2cE = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  const cdpR2cE1 = await mockCdp('__NO_TABS__', [{ id: 'r2cbtab', url: r2cBUrl }], {
    tabText: () => r2cBText,
    throttleModal: () => r2cBModal,
  });
  const rR2cE1 = await runSalvageInHome(homeR2cE, [MARKER, '3'], cdpR2cE1.port, r2cBEnv);
  cdpR2cE1.stop();
  check('#215 skeptic r2c B (1) a record whose CONTENT write fails is unlinked, not stranded as a zero-byte file',
    !throttleSeenHas(homeR2cE, r2cBUrl, r2cBModal),
    `status=${rR2cE1.status} dir=${fs.existsSync(throttleSeenDir(homeR2cE)) ? fs.readdirSync(throttleSeenDir(homeR2cE)) : null}`);
  check('#215 skeptic r2c B (1, control) that sighting still charges its cooldown and takes the throttle exit (5)',
    rR2cE1.status === 5 && (rR2cE1.cooldown ?? '').length > 0,
    `status=${rR2cE1.status} cooldown=${JSON.stringify(rR2cE1.cooldown)} stderr=${rR2cE1.stderr?.slice(-300)}`);
  const cooldownR2cE = path.join(homeR2cE, 'throttle.cooldown');
  ageCooldown215(cooldownR2cE);
  const mtimeR2cEBefore = fs.statSync(cooldownR2cE).mtimeMs;
  const cdpR2cE2 = await mockCdp('__NO_TABS__', [{ id: 'r2cbtab', url: r2cBUrl }], {
    tabText: () => r2cBText,
    throttleModal: () => r2cBModal,
  });
  const rR2cE2 = await runSalvageInHome(homeR2cE, [MARKER, '3'], cdpR2cE2.port);   // writes succeed again
  cdpR2cE2.stop();
  const mtimeR2cEAfter = fs.statSync(cooldownR2cE).mtimeMs;
  check('#215 skeptic r2c B (2) the fingerprint stays re-chargeable instead of silently suppressed for the 7-day TTL',
    rR2cE2.status === 5 && mtimeR2cEAfter > mtimeR2cEBefore,
    `status=${rR2cE2.status} before=${mtimeR2cEBefore} after=${mtimeR2cEAfter} stderr=${rR2cE2.stderr?.slice(-300)}`);
  fs.rmSync(homeR2cE, { recursive: true, force: true });
  fs.rmSync(r2cBDir, { recursive: true, force: true });

  // Source-order companions to D4's, for the branch the execution proof above exercises: the
  // rollback-list removal and the unlink both live AFTER the content write (i.e. in the catch),
  // and the content write uses writeFileSync's short-write loop rather than a bare writeSync.
  const r2cSource = fs.readFileSync(SALVAGE, 'utf8');
  const r2cStart = r2cSource.indexOf('function recordThrottleSeen(');
  const r2cBody = r2cStart < 0 ? '' : r2cSource.slice(r2cStart, r2cSource.indexOf('\nfunction ', r2cStart + 1));
  const r2cWriteAt = r2cBody.indexOf('fs.writeFileSync(fd');
  const r2cSpliceAt = r2cBody.indexOf('pendingThrottleSeenRecords.splice(');
  const r2cUnlinkAt = r2cBody.indexOf('fs.unlinkSync(recordPath)');
  check('#215 skeptic r2c B (a, source order) a failed content write drops the path from the rollback list and unlinks the record',
    r2cWriteAt >= 0 && r2cSpliceAt > r2cWriteAt && r2cUnlinkAt > r2cSpliceAt,
    `write=${r2cWriteAt} splice=${r2cSpliceAt} unlink=${r2cUnlinkAt}`);
  check('#215 skeptic r2c B (a, source order) the content write loops on short writes (writeFileSync, not writeSync)',
    r2cBody.length > 0 && !/fs\.writeSync\(/.test(r2cBody),
    `body=${r2cBody.slice(0, 200)}`);
}


process.exit(failures === 0 ? 0 : 1);
