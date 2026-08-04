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
  const server = createServer((req, res) => {
    if (req.url === '/json/version') { res.end(JSON.stringify({ Browser: 'MockChrome/1.0' })); return; }
    if (req.url?.startsWith('/json/new')) {
      const port = server.address().port;
      const url = decodeURIComponent(req.url.slice(req.url.indexOf('?') + 1));
      const id = `scratch${created.length + 1}`;
      created.push({ id, url });
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({
        id, type: 'page', url, webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${id}`,
      }));
      return;
    }
    if (req.url === '/json') {
      const port = server.address().port;
      res.setHeader('content-type', 'application/json');
      const extras = extraTabs.filter((t) => !closed.includes(t.id));
      const scratch = created.filter((t) => !closed.includes(t.id)).map((t) => ({
        id: t.id, type: 'page', url: t.url,
        webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/${t.id}`,
      }));
      if (tabText === '__NO_TABS__') { res.end(JSON.stringify([...extras, ...scratch])); return; }
      res.end(JSON.stringify([{
        id: 'tab1', type: 'page', url: 'https://chatgpt.com/c/mock-conversation',
        webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/tab1`,
      }, ...extras, ...scratch]));
      return;
    }
    if (req.url?.startsWith('/json/close/')) { closed.push(req.url.split('/').pop()); res.end('ok'); return; }
    res.statusCode = 404; res.end();
  });
  server.on('upgrade', (req, socket) => {
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + WS_MAGIC).digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
      + `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
    const id = (req.url ?? '').split('/').pop();
    const scratch = created.find((t) => t.id === id);
    // Any client frame (the Runtime.evaluate call) gets the canned innerText back.
    socket.on('data', () => {
      let value = tabText;
      if (scratch && opts.renderText) {
        const n = (pollsByTab.get(id) ?? 0) + 1;
        pollsByTab.set(id, n);
        value = opts.renderText(scratch.url, n);
      }
      socket.write(wsTextFrame(JSON.stringify({ id: 1, result: { result: { value } } })));
    });
    socket.on('error', () => {});
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port, closed, created, setText: (value) => { tabText = value; },
    stop: (cb) => server.close(cb),
  })));
}

// Async spawn: the mock CDP server lives in THIS process, so a blocking spawnSync would
// deadlock (the child's requests could never be served while the parent's loop is blocked).
// seed: optional (home) => void, to pre-populate PRO_GATE_HOME (remembered conversation URL,
// blacklist) before the run. The resolved result carries `home` contents read back before the
// directory is removed, so a test can assert what the salvage persisted.
function runSalvage(args, port, seed) {
  // Isolated PRO_GATE_HOME so blacklist/cooldown/URL-memo state never leaks between tests or
  // into a real deployment's home.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-salvage-test-'));
  if (seed) seed(home);
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [SALVAGE, ...args, String(port)], {
      env: { ...process.env, PRO_GATE_HOME: home },
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    const killer = setTimeout(() => child.kill('SIGKILL'), 90_000);
    child.on('close', (status) => {
      clearTimeout(killer);
      const read = (rel) => { try { return fs.readFileSync(path.join(home, rel), 'utf8'); } catch { return null; } };
      const memos = (() => {
        try { return fs.readdirSync(path.join(home, 'conversation-urls')); } catch { return []; }
      })();
      const memoUrl = memos.length ? read(path.join('conversation-urls', memos[0])) : null;
      const blacklist = read('salvage-nonmatching.txt');
      fs.rmSync(home, { recursive: true, force: true });
      resolve({ status, stdout, stderr, memoUrl: memoUrl?.trim() ?? null, memos, blacklist });
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
  check('still-generating leaves the tab open', cdp.closed.length === 0, `closed=${cdp.closed}`);
  check('still-generating names the conversation', /still-generating: .*mock-conversation/.test(r.stderr ?? ''));
  cdp.stop();
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
  check('probe never closes tabs', cdp.closed.length === 0, `closed=${cdp.closed}`);
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

process.exit(failures === 0 ? 0 : 1);
